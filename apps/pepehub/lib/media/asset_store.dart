import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import '../reader/reading_book_visibility.dart';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/repository.dart';
import '../storage/folder_files.dart';
import '../audio/audio_import.dart';
import '../audio/audio_link.dart';
import '../reader/epub.dart';
import '../reader/book_formats.dart';
import '../reader/text_book.dart';
import '../reader/pdf_support.dart';
import '../reader/pdf_file_source.dart';
import '../audio/audio_folder.dart' show audioSourceExists;
import 'import_folder.dart';

class LocalAsset {
  final String id, bookId, filename, path, hash;
  final int bytes;
  const LocalAsset({
    required this.id,
    required this.bookId,
    required this.filename,
    required this.path,
    required this.hash,
    required this.bytes,
  });
  factory LocalAsset.fromRow(QueryRow row) => LocalAsset(
    id: row.read<String>('id'),
    bookId: row.read<String>('book_id'),
    filename: row.read<String>('filename'),
    path: row.read<String>('path'),
    hash: row.read<String>('sha256'),
    bytes: row.read<int>('bytes'),
  );
}

class _DigestSink implements Sink<Digest> {
  Digest? digest;
  @override
  void add(Digest value) {
    digest = value;
  }

  @override
  void close() {}
}

class AssetStore {
  final Repository repository;
  final Directory directory;
  AssetStore(this.repository, this.directory);
  late final audioImporter = AudioImportService(repository, directory);
  Future<LocalAsset> connectAudioFolder(
    List<XFile> files, {
    required String root,
    required String title,
    String? replaceBookId,
    bool restoreRemoved = false,
  }) async {
    final id = await AudioLinkService(repository).connect(
      files,
      root: root,
      title: title,
      replaceBookId: replaceBookId,
      restoreRemoved: restoreRemoved,
    );
    await repository.db.customStatement('DELETE FROM metadata WHERE key=?', [
      'audio-cover-missing:$id',
    ]);
    return (await audioTracks(id)).first;
  }

  static Future<AssetStore> open(Repository repository) async => AssetStore(
    repository,
    Directory(p.join((await getApplicationSupportDirectory()).path, 'audio')),
  );
  Future<List<LocalAsset>> list() async =>
      (await repository.db
              .customSelect(
                'SELECT * FROM local_assets WHERE id NOT IN (SELECT id FROM audio_tracks) UNION ALL SELECT t.id,e.book_id,t.title AS filename,r.path,r.sha256,r.bytes FROM audio_tracks t JOIN audio_editions e ON e.id=t.edition_id JOIN audio_resources r ON r.sha256=t.asset_hash ORDER BY filename',
              )
              .get())
          .map(LocalAsset.fromRow)
          .toList();

  /// A shelf needs file choices for texts and one opener per audiobook,
  /// not every track of every edition in the user's entire collection.
  Future<List<LocalAsset>> shelfAssets({required bool audio}) async {
    final sql = audio
        ? '''
      WITH choices AS (
        SELECT e.id,e.book_id,ROW_NUMBER() OVER(
          PARTITION BY e.book_id ORDER BY p.updated_at DESC,e.id) AS priority
        FROM audio_editions e LEFT JOIN audio_progress p ON p.edition_id=e.id
      )
      SELECT t.id,c.book_id,t.title AS filename,r.path,r.sha256,r.bytes
      FROM choices c JOIN audio_tracks t ON t.edition_id=c.id
      JOIN audio_resources r ON r.sha256=t.asset_hash
      WHERE c.priority=1 AND t.ordinal=(SELECT MIN(first.ordinal) FROM audio_tracks first WHERE first.edition_id=c.id)
      ORDER BY filename,t.id
    '''
        : '''
      SELECT a.* FROM local_assets a JOIN records b ON b.id=a.book_id
      WHERE b.type='book' AND b.deleted=0
        AND CASE WHEN json_valid(b.payload) THEN json_extract(b.payload,'\$.format') END <> 'audio'
      ORDER BY a.filename,a.id
    ''';
    return (await repository.db.customSelect(sql).get())
        .map(LocalAsset.fromRow)
        .toList();
  }

  Future<LocalAsset?> byHash(String hash) async {
    final row = await repository.db
        .customSelect(
          'SELECT * FROM local_assets WHERE sha256=?',
          variables: [Variable(hash)],
        )
        .getSingleOrNull();
    return row == null ? null : LocalAsset.fromRow(row);
  }

  String _bookExtension(String name) => name.toLowerCase().endsWith('.fb2.zip')
      ? '.fb2.zip'
      : p.extension(name).toLowerCase();

  String _managedBookPath(LocalAsset asset) =>
      p.join(directory.path, '${asset.hash}${_bookExtension(asset.filename)}');

  bool isManagedBookPath(LocalAsset asset) =>
      p.equals(p.absolute(asset.path), p.absolute(_managedBookPath(asset)));

  /// Reading caches are temporary. Independent imports can live in the chosen
  /// folder or in the legacy private store; both remain available for deletion.
  Future<LocalAsset?> managedBookCopy(
    LocalAsset asset, {
    bool legacyOnly = false,
  }) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(asset.hash)) return null;
    final raw = legacyOnly
        ? null
        : await repository.meta('reading-import-location:${asset.bookId}');
    if (raw != null) {
      final saved = jsonDecode(raw) as Map<String, dynamic>;
      final path = saved['path'] as String;
      if (saved['hash'] == asset.hash &&
          saved['bytes'] == asset.bytes &&
          await audioSourceExists(path)) {
        return LocalAsset(
          id: asset.id,
          bookId: asset.bookId,
          filename: asset.filename,
          path: path,
          hash: asset.hash,
          bytes: asset.bytes,
        );
      }
    }
    final file = File(_managedBookPath(asset));
    if (!await file.exists() || await file.length() != asset.bytes) return null;
    if (!isManagedBookPath(asset) &&
        (await sha256.bind(file.openRead(0, asset.bytes + 1)).first)
                .toString() !=
            asset.hash) {
      return null;
    }
    return LocalAsset(
      id: asset.id,
      bookId: asset.bookId,
      filename: asset.filename,
      path: file.path,
      hash: asset.hash,
      bytes: asset.bytes,
    );
  }

  Future<bool> restoreManagedBookCopy(String bookId) async {
    final rows = await repository.db
        .customSelect(
          'SELECT * FROM local_assets WHERE book_id=?',
          variables: [Variable(bookId)],
        )
        .get();
    var found = false;
    for (final row in rows) {
      final copy = await managedBookCopy(LocalAsset.fromRow(row));
      if (copy == null) continue;
      await repository.db.customStatement(
        'UPDATE local_assets SET path=? WHERE id=?',
        [copy.path, copy.id],
      );
      found = true;
    }
    return found;
  }

  Future<void> _publishCopy(
    File temporary,
    File target,
    String hash,
    int bytes,
  ) async {
    if (await target.exists()) {
      if (await target.length() != bytes ||
          (await sha256.bind(target.openRead()).first).toString() != hash) {
        throw StateError('Повреждена локальная копия. Исходник сохранён.');
      }
    } else {
      await temporary.rename(target.path);
    }
  }

  /// Copies only a user-selected file. Original paths never enter the sync payload.
  Future<LocalAsset> importAudio(
    XFile selected, {
    int maxBytes = 8 * 1024 * 1024 * 1024,
  }) => importAudioBook(
    [selected],
    title: p.basenameWithoutExtension(selected.name),
    maxFileBytes: maxBytes,
  );

  Future<LocalAsset> importAudioBook(
    List<XFile> files, {
    required String title,
    AudioImportControl? control,
    void Function(int, int)? onProgress,
    int maxFileBytes = 8 * 1024 * 1024 * 1024,
  }) async {
    final bookId = await audioImporter.importBook(
      files,
      title: title,
      control: control,
      onProgress: onProgress,
      maxFileBytes: maxFileBytes,
    );
    return (await audioTracks(bookId)).first;
  }

  Future<List<LocalAsset>> audioTracks(
    String bookId, {
    String? editionId,
    bool firstOnly = false,
  }) async =>
      (await repository.db
              .customSelect(
                'SELECT t.id,e.book_id,t.title AS filename,r.path,r.sha256,r.bytes FROM audio_tracks t JOIN audio_editions e ON e.id=t.edition_id JOIN audio_resources r ON r.sha256=t.asset_hash WHERE e.book_id=? ${editionId == null ? '' : 'AND e.id=?'} ORDER BY e.id,t.ordinal ${firstOnly ? 'LIMIT 1' : ''}',
                variables: [
                  Variable(bookId),
                  if (editionId != null) Variable(editionId),
                ],
              )
              .get())
          .map(LocalAsset.fromRow)
          .toList();

  Future<List<LocalAsset>> localBookAssets(
    String bookId, {
    bool firstOnly = false,
  }) async =>
      (await repository.db
              .customSelect(
                'SELECT * FROM local_assets WHERE book_id=? ${firstOnly ? 'LIMIT 1' : ''}',
                variables: [Variable(bookId)],
              )
              .get())
          .map(LocalAsset.fromRow)
          .toList();

  Future<LocalAsset> importEpub(XFile selected) => importBook(selected);

  Future<LocalAsset> importBook(XFile selected) =>
      _storeBook(selected, keepPrivateCopy: true);

  /// Adds a picked original, or writes it directly to the chosen import folder.
  Future<LocalAsset> addBook(XFile selected, {bool persistent = true}) =>
      _storeBook(selected, persistent: persistent);

  Future<LocalAsset> _storeBook(
    XFile selected, {
    bool keepPrivateCopy = false,
    bool persistent = true,
  }) async {
    final filename = p.basename(selected.name);
    final format = bookFormat(filename);
    final limit = (format == 'pdf' ? 256 : 64) * 1024 * 1024;
    final isDocument = selected.path.startsWith('content:');
    final folder = ImportFolder(this);
    final root = await folder.load();
    if (root == null && !persistent) {
      throw StateError(
        'Android предоставил временный доступ. Выберите оригинал через '
        '«Добавить файл книги» или настройте папку импорта.',
      );
    }
    if (root != null) await folderFileSystem(root).checkRoot();

    final expected = await selected.length();
    if (expected > limit || (!isDocument && expected <= 0)) {
      throw ArgumentError('Недопустимый размер файла');
    }
    final privateCopy = root == null && keepPrivateCopy;
    if (privateCopy) await directory.create(recursive: true);
    final temporary = privateCopy
        ? File(p.join(directory.path, '${uuid.v4()}.part'))
        : null;
    final sink = temporary?.openWrite();
    final digestSink = _DigestSink();
    final hasher = sha256.startChunkedConversion(digestSink);
    final header = <int>[];
    final textBytes = !privateCopy && format != 'pdf'
        ? BytesBuilder(copy: false)
        : null;
    var size = 0;
    try {
      await for (final chunk in selected.openRead()) {
        size += chunk.length;
        if (size > limit) throw ArgumentError('Файл превышает лимит размера');
        if (header.length < 5) header.addAll(chunk.take(5 - header.length));
        hasher.add(chunk);
        textBytes?.add(chunk);
        if (sink != null) {
          sink.add(chunk);
          await sink.flush();
        }
      }
      await sink?.close();
      hasher.close();
      if (size == 0 || expected > 0 && size != expected) {
        throw StateError('Файл пуст или изменился во время добавления');
      }
      final hash = digestSink.digest!.toString();
      final original = LocalAsset(
        id: uuid.v4(),
        bookId: uuid.v4(),
        filename: filename,
        path: isDocument
            ? selected.path
            : p.normalize(p.absolute(selected.path)),
        hash: hash,
        bytes: size,
      );
      final path = temporary?.path ?? original.path;
      EpubBook? parsed;
      if (format == 'pdf') {
        if (String.fromCharCodes(header) != '%PDF-') {
          throw const FormatException('Это не PDF');
        }
        if (isDocument && temporary == null) {
          final source = await PdfFileSource.open(original, this);
          try {
            await validatePdf(source.path);
          } finally {
            await source.close();
          }
        } else {
          await validatePdf(path);
        }
      } else {
        parsed = await loadTextBook(
          path,
          filename,
          sourceBytes: textBytes?.takeBytes(),
        );
      }

      Future<LocalAsset?> existingBook() async {
        final asset = await byHash(hash);
        if (asset != null &&
            (await repository.record(asset.bookId))?.deleted != false) {
          throw StateError(
            'Эта книга удалена. Автоматическое восстановление отключено.',
          );
        }
        return asset;
      }

      final previous = await existingBook();
      final destination = root == null
          ? null
          : await folder.prepareBook(
              root,
              original,
              previousName: previous?.filename,
            );
      return await repository.db.transaction(() async {
        final existing = await existingBook();
        final assetId = existing?.id ?? original.id;
        final bookId = existing?.bookId ?? original.bookId;
        var storedPath = destination?.path ?? original.path;
        if (temporary != null) {
          final target = File(
            existing == null
                ? p.join(directory.path, '$hash${_bookExtension(filename)}')
                : _managedBookPath(existing),
          );
          await _publishCopy(temporary, target, hash, size);
          storedPath = target.path;
        }
        final asset = LocalAsset(
          id: assetId,
          bookId: bookId,
          filename: root == null && temporary == null
              ? filename
              : existing?.filename ?? filename,
          path: storedPath,
          hash: hash,
          bytes: size,
        );
        if (existing == null) {
          final title = (parsed?.title ?? p.basenameWithoutExtension(filename))
              .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
              .trim();
          await repository.put('book', bookId, {
            'title': title.isEmpty
                ? 'Книга'
                : title.substring(0, title.length.clamp(0, 500)),
            'authors':
                parsed?.authors
                    .map(
                      (a) =>
                          a.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim(),
                    )
                    .where((a) => a.isNotEmpty)
                    .map((a) => a.substring(0, a.length.clamp(0, 200)))
                    .toList() ??
                <String>[],
            'format': format,
            'status': 'planned',
          });
          await repository.db.customStatement(
            'INSERT INTO local_assets(id,book_id,filename,path,sha256,bytes) VALUES(?,?,?,?,?,?)',
            [asset.id, bookId, asset.filename, storedPath, hash, size],
          );
        } else {
          await repository.db.customStatement(
            'UPDATE local_assets SET path=?,filename=?,bytes=? WHERE id=?',
            [storedPath, asset.filename, size, asset.id],
          );
        }
        await repository.setMeta('reading-imported:$bookId', '1');
        if (temporary == null) {
          await repository.setMeta(
            'reading-import-location:$bookId',
            jsonEncode({'path': storedPath, 'hash': hash, 'bytes': size}),
          );
        }
        if (root != null && destination != null) {
          await folder.registerBook(root, destination.relative, asset);
        }
        await repository.restoreRemovedShelfBook(bookId, audio: false);
        await repository.setMeta('reading-user-hidden:$bookId', '0');
        await ReadingBookVisibility(repository).available(bookId);
        return asset;
      });
    } finally {
      await sink?.close();
      if (temporary != null && await temporary.exists()) {
        await temporary.delete();
      }
    }
  }
}
