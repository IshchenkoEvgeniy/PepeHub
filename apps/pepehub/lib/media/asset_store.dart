import 'dart:io';

import '../reader/reading_book_visibility.dart';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/repository.dart';
import '../audio/audio_library_repository.dart';
import '../audio/audio_import.dart';
import '../audio/audio_link.dart';
import '../reader/epub.dart';
import '../reader/book_formats.dart';
import '../reader/text_book.dart';
import '../reader/pdf_support.dart';

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
  }) async {
    final id = await AudioLinkService(repository)
        .connect(files, root: root, title: title, replaceBookId: replaceBookId);
    await repository.db.customStatement('DELETE FROM metadata WHERE key=?', ['audio-cover-missing:$id']);
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

  /// Reading caches are temporary; only a published import in the store's
  /// root is an independent copy. Also finds imports demoted by older scans.
  Future<LocalAsset?> managedBookCopy(LocalAsset asset) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(asset.hash)) return null;
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

  Future<LocalAsset> importEpub(XFile selected) => importBook(selected);

  Future<LocalAsset> importBook(XFile selected) {
    final format = bookFormat(selected.name);
    return _importFile(
      selected,
      maxBytes: (format == 'pdf' ? 256 : 64) * 1024 * 1024,
      format: format,
    );
  }

  Future<LocalAsset> _importFile(
    XFile selected, {
    required int maxBytes,
    required String format,
  }) async {
    final audio = format == 'audio';
    final extension = _bookExtension(selected.name);
    if (audio && !audioExtensions.contains(extension.substring(1))) {
      throw ArgumentError('Неподдерживаемый аудиоформат');
    }
    final expected = await selected.length();
    if (expected < (audio ? 12 : 1) || expected > maxBytes) {
      throw ArgumentError('Недопустимый размер файла');
    }
    await directory.create(recursive: true);
    final temporary = File(p.join(directory.path, '${uuid.v4()}.part'));
    final digestSink = _DigestSink(), header = <int>[];
    final hasher = sha256.startChunkedConversion(digestSink);
    final sink = temporary.openWrite();
    var size = 0;
    try {
      await for (final chunk in selected.openRead()) {
        size += chunk.length;
        if (size > maxBytes) {
          throw ArgumentError('Файл превышает лимит размера');
        }
        if (header.length < 12) header.addAll(chunk.take(12 - header.length));
        hasher.add(chunk);
        sink.add(chunk);
        // Backpressure: keep memory bounded while copying multi-gigabyte audio.
        await sink.flush();
      }
      await sink.close();
      hasher.close();
      if (size != expected) throw StateError('Файл изменился во время импорта');
      final mp3 =
          header.length >= 3 &&
          ((header[0] == 73 && header[1] == 68 && header[2] == 51) ||
              (header[0] == 255 && (header[1] & 224) == 224));
      final mp4 =
          header.length >= 8 &&
          String.fromCharCodes(header.sublist(4, 8)) == 'ftyp';
      final signature = String.fromCharCodes(header);
      final validAudio = switch (extension) {
        '.mp3' => mp3,
        '.m4a' || '.m4b' => mp4,
        '.aac' =>
          header.length >= 2 && header[0] == 255 && (header[1] & 246) == 240,
        '.ogg' || '.opus' => signature.startsWith('OggS'),
        '.flac' => signature.startsWith('fLaC'),
        '.wav' =>
          signature.startsWith('RIFF') && signature.substring(8, 12) == 'WAVE',
        _ => false,
      };
      if (audio && !validAudio) {
        throw ArgumentError('Содержимое файла не соответствует аудиоформату');
      }
      final temporaryPath = temporary.path;
      EpubBook? parsed;
      if (format == 'pdf') {
        if (!signature.startsWith('%PDF-')) {
          throw const FormatException('Это не PDF');
        }
        await validatePdf(temporaryPath);
      } else if (!audio) {
        parsed = await loadTextBook(temporaryPath, selected.name);
      }
      final hash = digestSink.digest!.toString();
      final existing = await byHash(hash);
      if (existing != null) {
        if ((await repository.record(existing.bookId))?.deleted != false) {
          throw StateError(
            'Эта книга удалена из библиотеки. Автоматическое восстановление отключено.',
          );
        }
        if (!audio) {
          final target = File(_managedBookPath(existing));
          await _publishCopy(temporary, target, hash, size);
          await repository.db.transaction(() async {
            await repository.db.customStatement(
              'UPDATE local_assets SET path=?,bytes=? WHERE id=?',
              [target.path, size, existing.id],
            );
            await repository.setMeta(
              'reading-imported:${existing.bookId}',
              '1',
            );
            await repository.setMeta(
              'reading-library-hidden:${existing.bookId}',
              '0',
            );
            await repository.setMeta(
              'reading-user-hidden:${existing.bookId}',
              '0',
            );
            await ReadingBookVisibility(repository).available(existing.bookId);
          });
          return LocalAsset(
            id: existing.id,
            bookId: existing.bookId,
            filename: existing.filename,
            path: target.path,
            hash: hash,
            bytes: size,
          );
        }
        // Re-import can repair a removed local file, but never overwrites an existing one.
        if (!existing.path.startsWith('content:') &&
            !await File(existing.path).exists()) {
          await temporary.rename(existing.path);
        }
        return existing;
      }
      final target = File(p.join(directory.path, '$hash$extension'));
      await _publishCopy(temporary, target, hash, size);
      final asset = LocalAsset(
        id: uuid.v4(),
        bookId: uuid.v4(),
        filename: p.basename(selected.name),
        path: target.path,
        hash: hash,
        bytes: size,
      );
      final title = (parsed?.title ?? p.basenameWithoutExtension(selected.name))
          .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
          .trim();
      await repository.db.transaction(() async {
        await repository.put('book', asset.bookId, {
          'title': title.isEmpty
              ? 'Книга'
              : title.substring(0, title.length.clamp(0, 500)),
          'authors':
              parsed?.authors
                  .map(
                    (a) => a.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim(),
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
          [
            asset.id,
            asset.bookId,
            asset.filename,
            asset.path,
            asset.hash,
            asset.bytes,
          ],
        );
        if (!audio) {
          await repository.setMeta('reading-imported:${asset.bookId}', '1');
          await repository.setMeta(
            'reading-library-hidden:${asset.bookId}',
            '0',
          );
        }
        if (audio) {
          await AudioLibraryRepository(repository.db).registerSingleTrack(
            bookId: asset.bookId,
            assetId: asset.id,
            hash: asset.hash,
            path: asset.path,
            filename: asset.filename,
            bytes: asset.bytes,
          );
        }
      });
      return asset;
    } finally {
      await sink.close();
      if (await temporary.exists()) await temporary.delete();
    }
  }
}
