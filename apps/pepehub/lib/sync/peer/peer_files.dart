import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'peer_models.dart';

const peerFilesChannel = MethodChannel('app.pepehub/peer_files');

class PeerDiskFile {
  final String path, hash;
  final int bytes;
  const PeerDiskFile(this.path, this.hash, this.bytes);
}

abstract class PeerFileSystem {
  Future<List<PeerDiskFile>> scan();
  Future<String?> hash(String path);
  Future<List<int>> read(String path, int offset, int count);
  Future<void> publish(String path, File source, String? expectedHash);
  Future<void> remove(String path, String? expectedHash);
}

PeerFileSystem peerFileSystem(String root) => root.startsWith('content://')
    ? SafPeerFiles(root)
    : LocalPeerFiles(Directory(root));

Future<String> hashPeerFile(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

class LocalPeerFiles implements PeerFileSystem {
  final Directory root;
  LocalPeerFiles(this.root);
  Future<String> _base() async {
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw StateError('Общая папка недоступна или заменена ссылкой');
    }
    final base = await root.resolveSymbolicLinks();
    if (!p.equals(base, p.normalize(root.absolute.path))) {
      throw StateError('Путь общей папки изменён ссылкой');
    }
    return base;
  }

  Future<File> _file(String path, {bool parents = false}) async {
    peerPath(path);
    final base = await _base();
    var current = base;
    final parts = path.split('/');
    for (var n = 0; n < parts.length; n++) {
      current = p.join(current, parts[n]);
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type == FileSystemEntityType.link ||
          n < parts.length - 1 &&
              type != FileSystemEntityType.directory &&
              type != FileSystemEntityType.notFound) {
        throw StateError(
          'Путь содержит ссылку или неподходящий родительский файл',
        );
      }
      if (parents &&
          n < parts.length - 1 &&
          type == FileSystemEntityType.notFound) {
        await Directory(current).create();
      }
    }
    if (!p.isWithin(base, current)) {
      throw StateError('Путь за пределами общей папки');
    }
    return File(current);
  }

  @override
  Future<List<PeerDiskFile>> scan() async {
    await _base();
    if (!await root.exists()) {
      throw StateError('Общая папка недоступна; индекс сохранён');
    }
    final files = <PeerDiskFile>[], folded = <String>{};
    var visited = 0;
    Future<void> visit(Directory dir, String prefix, int depth) async {
      if (depth > 32) throw StateError('Больше 32 уровней вложенности');
      await for (final entry in dir.list(followLinks: false)) {
        if (++visited > 50000) {
          throw StateError('В общей папке больше 50000 элементов');
        }
        final name = p.basename(entry.path);
        if (peerIgnored(name)) continue;
        if (entry is Link) {
          throw StateError('Общая папка содержит ссылку: $name');
        }
        final path = peerPath('$prefix$name');
        if (!folded.add(path.toLowerCase())) {
          throw StateError('Имена различаются только регистром: $path');
        }
        if (entry is Directory) {
          await visit(entry, '$path/', depth + 1);
        } else if (entry is File) {
          final before = await entry.stat();
          final digest = await hashPeerFile(entry);
          final after = await entry.stat();
          if (before.size != after.size || before.modified != after.modified) {
            throw StateError('Файл меняется во время сканирования: $path');
          }
          files.add(PeerDiskFile(path, digest, after.size));
          if (files.length > peerMaxFiles) {
            throw StateError('В общей папке больше $peerMaxFiles файлов');
          }
        }
      }
    }

    await visit(root, '', 0);
    return files;
  }

  @override
  Future<String?> hash(String path) async {
    final file = await _file(path);
    return await file.exists() ? hashPeerFile(file) : null;
  }

  @override
  Future<List<int>> read(String path, int offset, int count) async {
    final file = await _file(path);
    final handle = await file.open();
    try {
      if (offset < 0 ||
          count < 1 ||
          count > peerChunkSize ||
          offset > await file.length()) {
        throw const FormatException('Неверный диапазон');
      }
      await handle.setPosition(offset);
      return await handle.read(count);
    } finally {
      await handle.close();
    }
  }

  Future<void> _check(String path, String? expected) async {
    if (await hash(path) != expected) {
      throw StateError('Локальный файл изменился во время передачи: $path');
    }
  }

  Future<Directory> _versions() async {
    final base = await _base();
    var path = base;
    for (final part in ['.pepehub', 'p2p', 'versions']) {
      path = p.join(path, part);
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type != FileSystemEntityType.directory &&
          type != FileSystemEntityType.notFound) {
        throw StateError('Служебная папка недоступна');
      }
      if (type == FileSystemEntityType.notFound) await Directory(path).create();
    }
    return Directory(path);
  }

  String _versionName(String path) {
    final name = p.basename(path);
    return '${DateTime.now().microsecondsSinceEpoch}-${peerStorageKey(path).substring(0, 12)}-${name.substring(0, name.length.clamp(0, 160))}';
  }

  @override
  Future<void> publish(String path, File source, String? expectedHash) async {
    final target = await _file(path, parents: true);
    final staging = File(
      p.join(
        (await _versions()).parent.path,
        '.pepehub-${DateTime.now().microsecondsSinceEpoch}.tmp',
      ),
    );
    await source.copy(staging.path);
    try {
      await _check(path, expectedHash);
      if (expectedHash != null) {
        await target.copy(p.join((await _versions()).path, _versionName(path)));
      }
      await _check(path, expectedHash);
      // A same-volume rename publishes only a fully verified file.
      await staging.rename(target.path);
    } finally {
      if (await staging.exists()) await staging.delete();
    }
  }

  @override
  Future<void> remove(String path, String? expectedHash) async {
    await _check(path, expectedHash);
    if (expectedHash == null) return;
    final target = await _file(path);
    await target.rename(p.join((await _versions()).path, _versionName(path)));
  }
}

class SafPeerFiles implements PeerFileSystem {
  final String root;
  const SafPeerFiles(this.root);
  @override
  Future<List<PeerDiskFile>> scan() async {
    final entries = await peerFilesChannel.invokeListMethod<Map>('scan', {
      'root': root,
    });
    if (entries == null) throw StateError('Общая папка недоступна');
    return [
      for (final e in entries)
        PeerDiskFile(
          peerPath(e['path'] as String),
          e['hash'] as String,
          e['bytes'] as int,
        ),
    ];
  }

  @override
  Future<String?> hash(String path) => peerFilesChannel.invokeMethod<String>(
    'hash',
    {'root': root, 'path': peerPath(path)},
  );
  @override
  Future<List<int>> read(String path, int offset, int count) async =>
      await peerFilesChannel.invokeMethod<Uint8List>('read', {
        'root': root,
        'path': peerPath(path),
        'offset': offset,
        'count': count,
      }) ??
      <int>[];
  @override
  Future<void> publish(String path, File source, String? expectedHash) =>
      peerFilesChannel.invokeMethod<void>('publish', {
        'root': root,
        'path': peerPath(path),
        'source': source.path,
        'expected': expectedHash,
      });
  @override
  Future<void> remove(String path, String? expectedHash) =>
      peerFilesChannel.invokeMethod<void>('remove', {
        'root': root,
        'path': peerPath(path),
        'expected': expectedHash,
      });
}
