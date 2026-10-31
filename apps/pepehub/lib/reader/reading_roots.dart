import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../audio/audio_folder.dart';
import '../media/asset_store.dart';
import '../media/verified_stream_copy.dart';
import '../media/library_folder_preference.dart';
import '../media/library_recovery.dart';
import '../data/repository.dart';
import 'book_formats.dart';
import 'reading_book_visibility.dart';

class ReadingRoot {
  final String key, path, title;
  final List<String> bookIds;
  final List<String>? presentBookIds;
  List<String> get availableIds => presentBookIds ?? bookIds;
  ReadingRoot(
    this.key,
    this.path,
    this.title,
    this.bookIds, {
    this.presentBookIds,
  });
}

class ReadingRoots {
  final AssetStore assets;
  ReadingRoots(this.assets);
  Future<List<ReadingRoot>> list() async {
    final rows = await assets.repository.db
        .customSelect(
          "SELECT key,value FROM metadata WHERE key>='reading-library-root:' AND key<'reading-library-root;'",
        )
        .get();
    return [
      for (final row in rows)
        _root(
          row.read<String>('key'),
          jsonDecode(row.read<String>('value')) as Map<String, dynamic>,
        ),
    ];
  }

  ReadingRoot _root(String key, Map<String, dynamic> value) => ReadingRoot(
    key,
    value['path'] as String,
    value['title'] as String,
    (value['bookIds'] as List).cast<String>(),
    presentBookIds: (value['presentBookIds'] as List?)?.cast<String>(),
  );
  Future<void> disconnect(ReadingRoot root) async {
    await assets.repository.db.transaction(() async {
      await LibraryFolderPreference(
        assets.repository,
        reading: true,
      ).replace(root.key, null);
      await assets.repository.db.customStatement(
        'DELETE FROM metadata WHERE key=?',
        [root.key],
      );
      final remaining = (await list()).expand((r) => r.availableIds).toSet();
      for (final id in root.bookIds) {
        if (!remaining.contains(id)) {
          final managed = await assets.restoreManagedBookCopy(id);
          final imported =
              managed ||
              await assets.repository.meta('reading-imported:$id') == '1';
          if (managed) {
            await ReadingBookVisibility(assets.repository).available(id);
          }
          if (managed) {
            await assets.repository.setMeta('reading-imported:$id', '1');
          }
          await assets.repository.setMeta(
            'reading-library-hidden:$id',
            imported &&
                    await assets.repository.meta('reading-user-hidden:$id') !=
                        '1'
                ? '0'
                : '1',
          );
          if (imported) {
            await assets.repository.db.customStatement(
              'DELETE FROM metadata WHERE key=?',
              ['reading-source-path:$id'],
            );
          }
        }
      }
    });
  }

  Future<ReadingRoot> connect(
    AudioFolder folder, {
    Map<String, ({String hash, int bytes})> verified = const {},
  }) async {
    final path = folder.root!;
    final key = 'reading-library-root:${sha256.convert(utf8.encode(path))}';
    final ids = <String>[];
    final present = <String>{};
    final candidates =
        <({String name, String path, String format, String hash, int size})>[];
    for (final file in folder.files) {
      final format = bookFormat(file.name);
      final declaredSize = await file.length();
      final maxSize = (format == 'pdf' ? 256 : 64) * 1024 * 1024;
      if (declaredSize > maxSize) {
        throw StateError('Недопустимый размер: ${file.name}');
      }
      var actualBytes = 0;
      final known = verified[file.name];
      if (known != null &&
          (known.bytes != declaredSize ||
              !RegExp(r'^[a-f0-9]{64}$').hasMatch(known.hash))) {
        throw StateError('Файл изменился: ${file.name}');
      }
      final hash = known != null
          ? known.hash
          : (await sha256
                    .bind(
                      file.openRead().map((chunk) {
                        actualBytes += chunk.length;
                        if (actualBytes > maxSize ||
                            declaredSize > 0 && actualBytes > declaredSize) {
                          throw StateError('Файл изменился: ${file.name}');
                        }
                        return chunk;
                      }),
                    )
                    .first)
                .toString();
      if (known != null) actualBytes = known.bytes;
      if (actualBytes == 0 || declaredSize > 0 && actualBytes != declaredSize) {
        throw StateError('Файл изменился: ${file.name}');
      }
      candidates.add((
        name: file.name,
        path: file.path,
        format: format,
        hash: hash,
        size: actualBytes,
      ));
    }
    await assets.repository.db.transaction(() async {
      final previous = await assets.repository.meta(key);
      if (previous != null) {
        // A temporarily missing file stays associated with its root and retains its notes/history.
        ids.addAll((jsonDecode(previous) as Map)['bookIds'].cast<String>());
      }
      for (final file in candidates) {
        final hash = file.hash, format = file.format, size = file.size;
        final existing = await assets.byHash(hash);
        if (existing != null &&
            (await assets.repository.record(existing.bookId))
                    ?.payload?['format'] ==
                'audio') {
          continue;
        }
        final id = existing?.bookId ?? uuid.v4();
        if (existing == null) {
          await assets.repository.put('book', id, {
            'title': p.basenameWithoutExtension(file.name),
            'authors': <String>[],
            'format': format,
            'status': 'planned',
          });
          await assets.repository.db.customStatement(
            'INSERT INTO local_assets(id,book_id,filename,path,sha256,bytes) VALUES(?,?,?,?,?,?)',
            [uuid.v4(), id, p.basename(file.name), file.path, hash, size],
          );
        } else {
          final managed = await assets.managedBookCopy(existing);
          if (managed != null || assets.isManagedBookPath(existing)) {
            await assets.repository.setMeta('reading-imported:$id', '1');
          }
          await assets.repository.db.customStatement(
            'UPDATE local_assets SET path=?,filename=? WHERE id=?',
            [
              managed?.path ?? file.path,
              managed?.filename ?? p.basename(file.name),
              existing.id,
            ],
          );
        }
        present.add(id);
        await ReadingBookVisibility(assets.repository).available(id);
        await assets.repository.setMeta(
          'reading-source-path:$id',
          jsonEncode({
            'root': path,
            'relativePath': file.name.replaceAll('\\', '/'),
          }),
        );
        if (!ids.contains(id)) ids.add(id);
      }
      // Keep historical IDs for reconnects, while removing absent sources from
      // the shelf. Independently imported copies and other roots remain usable.
      final other = (await list())
          .where((r) => r.key != key)
          .expand((r) => r.availableIds)
          .toSet();
      for (final id in ids.where(
        (id) => !present.contains(id) && !other.contains(id),
      )) {
        if (await assets.restoreManagedBookCopy(id)) {
          await ReadingBookVisibility(assets.repository).available(id);
        } else {
          await ReadingBookVisibility(assets.repository).deleted(id);
        }
      }
      await assets.repository.setMeta(
        key,
        jsonEncode({
          'path': path,
          'title': folder.title,
          'bookIds': ids,
          'presentBookIds': present.toList(),
        }),
      );
    });
    await recoverReadingRoot(assets, path, ids);
    return ReadingRoot(
      key,
      path,
      folder.title,
      ids,
      presentBookIds: present.toList(),
    );
  }

  Future<LocalAsset> forReading(LocalAsset asset) async {
    if (!asset.path.startsWith('content:')) return asset;
    final maxBytes =
        (bookFormat(asset.filename) == 'pdf' ? 256 : 64) * 1024 * 1024;
    if (asset.bytes <= 0 || asset.bytes > maxBytes) {
      throw StateError('Недопустимый размер книги. Обновите папку книг.');
    }
    // Text/PDF engines need a seekable local file. Cache only the opened book.
    final cache = Directory(p.join(assets.directory.path, 'reading-cache'));
    await cache.create(recursive: true);
    final file = File(
      p.join(cache.path, '${asset.hash}${p.extension(asset.filename)}'),
    );
    if (!await file.exists()) {
      final temporary = File('${file.path}.partial');
      try {
        final copied = await copyVerifiedStream(
          SafAudioFile(asset.path, asset.filename, asset.bytes).openRead(),
          temporary,
          expectedBytes: asset.bytes,
        );
        if (copied.hash != asset.hash) {
          throw StateError('Файл изменился. Обновите папку книг.');
        }
        await temporary.rename(file.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
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
}
