import 'dart:io';

import 'package:path/path.dart' as p;

/// Only temporary, reproducible copies belong here. Covers and reading indexes
/// can contain user edits or anchor data and are deliberately preserved.
class StorageUsage {
  final Directory root;
  StorageUsage(this.root);

  Future<bool> _checkRoot() async {
    if (await FileSystemEntity.type(root.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return false;
    }
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw StateError('Хранилище недоступно или заменено ссылкой');
    }
    // The folder itself must not be a link (checked above without following
    // links). Links above it belong to the system: on Android the app's data
    // folder /data/user/0/<package> is a link to /data/data/<package>, and on
    // macOS /var points to /private/var. Compare against the resolved parent
    // so only a swapped final component is rejected.
    final parent = Directory(p.dirname(p.absolute(root.path)));
    if (!p.equals(
      await root.resolveSymbolicLinks(),
      p.join(await parent.resolveSymbolicLinks(), p.basename(root.path)),
    )) {
      throw StateError('Путь хранилища содержит ссылку');
    }
    return true;
  }

  Future<int> _size(Directory directory) async {
    if (await FileSystemEntity.type(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return 0;
    }
    var bytes = 0;
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File) bytes += (await entity.stat()).size;
    }
    return bytes;
  }

  Future<({int total, int temporary, int covers})> measure() async {
    if (!await _checkRoot()) return (total: 0, temporary: 0, covers: 0);
    // Streaming filesystem traversal; no records, tracks or text indexes loaded.
    final total = await _size(root);
    final temporary = await _size(
      Directory(p.join(root.path, 'reading-cache')),
    );
    var covers = 0;
    for (final name in ['covers', 'reading-covers', 'obsidian-covers']) {
      covers += await _size(Directory(p.join(root.path, name)));
    }
    return (total: total, temporary: temporary, covers: covers);
  }

  Future<int> clearTemporaryCopies() async {
    if (!await _checkRoot()) return 0;
    final cache = Directory(p.join(root.path, 'reading-cache'));
    if (!p.isWithin(p.absolute(root.path), p.absolute(cache.path))) {
      throw StateError('Неверный путь кэша');
    }
    if (await FileSystemEntity.type(cache.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return 0;
    }
    var freed = 0;
    // Never follow links or recursively delete directories. Remove only completed
    // content-addressed copies; active imports and partial writes remain intact.
    await for (final entity in cache.list(followLinks: false)) {
      if (entity is! File ||
          !RegExp(r'^[a-f0-9]{64}\.(pdf|epub|fb2|txt|rtf|zip)$')
              .hasMatch(p.basename(entity.path))) {
        continue;
      }
      final size = await entity.length();
      await entity.delete();
      freed += size;
    }
    return freed;
  }
}
