import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;

import '../audio/audio_folder.dart';
import '../data/repository.dart';
import '../reader/reading_log.dart';
import '../sync/peer/peer_files.dart';
import '../sync/peer/peer_models.dart';
import 'asset_store.dart';

/// A local destination for explicitly imported text books, independent of the
/// personal archive and of any network transport. Original copies stay intact.
class ImportFolder {
  static const settingKey = 'import-books-folder-v1';
  final AssetStore assets;
  ImportFolder(this.assets);
  Repository get repo => assets.repository;

  Future<String?> load() => repo.meta(settingKey);

  Future<void> configure(String root) async {
    final normalized = root.startsWith('content://')
        ? root
        : p.normalize(p.absolute(root));
    await peerFileSystem(normalized).checkRoot();
    await repo.setMeta(settingKey, normalized);
    repo.notifyExternalChange();
  }

  Future<void> check() async {
    final root = await load();
    if (root != null) await peerFileSystem(root).checkRoot();
  }

  Future<void> clear() async {
    await repo.db.customStatement('DELETE FROM metadata WHERE key=?', [
      settingKey,
    ]);
    repo.notifyExternalChange();
  }

  static String safeName(String value) {
    var name = value
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f\x7f]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceAll(RegExp(r'[. ]+$'), '');
    if (name.isEmpty) name = 'Книга';
    if (RegExp(
      r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])(?:\.|$)',
      caseSensitive: false,
    ).hasMatch(name)) {
      name = '_$name';
    }
    return String.fromCharCodes(name.runes.take(90));
  }

  Future<String> _copy(String root, String relative, LocalAsset asset) async {
    final files = peerFileSystem(root);
    await files.checkRoot();
    final existing = await files.hash(relative);
    if (existing != null && existing != asset.hash) {
      throw StateError('В папке импорта уже есть другой файл: $relative');
    }
    if (existing == null) {
      final entry = PeerFileEntry(
        path: relative,
        hash: asset.hash,
        bytes: asset.bytes,
        clock: const {'00000000-0000-4000-8000-000000000001': 1},
      );
      final stage = await files.stage(entry);
      try {
        await stage.reset();
        var offset = 0;
        final source = asset.path.startsWith('content:')
            ? SafAudioFile(asset.path, asset.filename, asset.bytes).openRead()
            : File(asset.path).openRead();
        await for (final chunk in source) {
          if (offset + chunk.length > asset.bytes) {
            throw StateError('Размер файла изменился');
          }
          for (var start = 0; start < chunk.length; start += peerChunkSize) {
            final end = (start + peerChunkSize).clamp(0, chunk.length);
            await stage.append(offset, chunk.sublist(start, end));
            offset += end - start;
          }
        }
        if (offset != asset.bytes || await stage.hash() != asset.hash) {
          throw StateError('Копия книги не прошла проверку');
        }
        try {
          await stage.publish(null);
        } catch (_) {
          if (await files.hash(relative) != asset.hash) rethrow;
        }
      } finally {
        await stage.discard();
      }
    }
    return (await files.source(relative)) ??
        (throw StateError('Копия книги недоступна'));
  }

  Future<void> _register(String root, String bookId) async {
    final key = 'reading-library-root:${sha256.convert(utf8.encode(root))}';
    final raw = await repo.meta(key);
    final old = raw == null
        ? <String, dynamic>{}
        : jsonDecode(raw) as Map<String, dynamic>;
    final ids = {...(old['bookIds'] as List? ?? []).cast<String>(), bookId};
    await repo.setMeta(
      key,
      jsonEncode({
        ...old,
        'path': root,
        'title': old['title'] ?? 'Добавленные книги',
        'bookIds': ids.toList(),
        'presentBookIds': {
          ...(old['presentBookIds'] as List? ?? old['bookIds'] as List? ?? [])
              .cast<String>(),
          bookId,
        }.toList(),
      }),
    );
  }

  Future<({String path, String relative})> prepareBook(
    String root,
    LocalAsset asset, {
    String? previousName,
  }) async {
    final path = asset.path;
    if (!root.startsWith('content:') && p.isWithin(root, path)) {
      final relative = p.split(p.relative(path, from: root)).join('/');
      if (await peerFileSystem(root).hash(relative) == asset.hash) {
        return (path: path, relative: relative);
      }
      throw StateError('Файл изменился во время добавления');
    }
    if (root.startsWith('content:') && path.startsWith('content:')) {
      final tree = Uri.parse(root), source = Uri.parse(path);
      if (tree.authority == source.authority &&
          tree.pathSegments.length == 2 &&
          source.pathSegments.length >= 2) {
        final treeId = tree.pathSegments.last;
        final docId = source.pathSegments.last;
        final prefix = treeId.endsWith(':') ? treeId : '$treeId/';
        final relative = docId.startsWith(prefix)
            ? docId.substring(prefix.length)
            : p.basename(asset.filename);
        if (relative.isNotEmpty &&
            relative
                .split('/')
                .every(
                  (part) => part.isNotEmpty && part != '.' && part != '..',
                ) &&
            !relative.contains(r'\')) {
          final files = peerFileSystem(root);
          final inside = await files.source(relative);
          if (inside != null && Uri.parse(inside).pathSegments.last == docId) {
            if (await files.hash(relative) != asset.hash) {
              throw StateError('Файл изменился во время добавления');
            }
            return (path: inside, relative: relative);
          }
        }
      }
    }
    final name = previousName ?? asset.filename;
    final extension = name.toLowerCase().endsWith('.fb2.zip')
        ? '.fb2.zip'
        : p.extension(name).toLowerCase();
    final stem = name.substring(0, name.length - extension.length);
    final relative =
        '${safeName(stem)} [${asset.hash.substring(0, 16)}]$extension';
    return (path: await _copy(root, relative, asset), relative: relative);
  }

  Future<void> registerBook(
    String root,
    String relative,
    LocalAsset asset,
  ) async {
    await repo.setMeta(
      'reading-source-path:${asset.bookId}',
      jsonEncode({'root': root, 'relativePath': relative}),
    );
    await _register(root, asset.bookId);
  }

  Future<void> placeBook(LocalAsset asset) async {
    final root = await load();
    if (root == null) return;
    final destination = await prepareBook(root, asset);
    await repo.db.transaction(() async {
      await repo.db.customStatement(
        'UPDATE local_assets SET path=? WHERE id=?',
        [destination.path, asset.id],
      );
      await repo.setMeta(
        'reading-import-location:${asset.bookId}',
        jsonEncode({
          'path': destination.path,
          'hash': asset.hash,
          'bytes': asset.bytes,
        }),
      );
      await registerBook(root, destination.relative, asset);
    });
  }

  /// Only compact headers are read; no audio tracks or full text indexes.
  Future<List<String>> candidates() async {
    final rows = await repo.db
        .customSelect(
          "SELECT b.id FROM records b WHERE b.type='book' AND b.deleted=0 AND json_valid(b.payload) "
          "AND IFNULL(json_extract(b.payload,'\$.format'),'')!='audio' AND "
          "NOT EXISTS(SELECT 1 FROM metadata WHERE key='reading-deleted:'||b.id AND value='1') AND "
          "NOT EXISTS(SELECT 1 FROM metadata WHERE key='${Repository.removedShelfBookPrefix}'||b.id AND value='1') AND "
          "EXISTS(SELECT 1 FROM metadata WHERE key='reading-imported:'||b.id AND value='1') ORDER BY b.id",
        )
        .get();
    return [for (final row in rows) row.read<String>('id')];
  }

  Future<int> copyExisting({
    void Function(int done, int total)? onProgress,
  }) async {
    if (await load() == null) {
      throw StateError('Сначала выберите папку импорта');
    }
    await check();
    final ids = await candidates();
    var done = 0;
    for (final id in ids) {
      final rows = await repo.db
          .customSelect(
            'SELECT * FROM local_assets WHERE book_id=?',
            variables: [Variable(id)],
          )
          .get();
      for (final row in rows) {
        await placeBook(LocalAsset.fromRow(row));
      }
      done++;
      onProgress?.call(done, ids.length);
    }
    if (ids.isNotEmpty) await ReadingLog(repo).exportAll();
    repo.notifyExternalChange();
    return done;
  }
}

Future<String?> pickImportFolder() async => Platform.isAndroid
    ? ((await peerFilesChannel.invokeMapMethod<String, dynamic>(
            'pick',
          ))?['root']
          as String?)
    : getDirectoryPath(confirmButtonText: 'Выбрать папку импорта');
