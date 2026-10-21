import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'peer_models.dart';
import 'peer_history.dart';
import 'peer_local_history.dart';

const peerFilesChannel = MethodChannel('app.pepehub/peer_files');

class PeerDiskFile {
  final String path, hash;
  final int bytes;
  final String? stamp;
  const PeerDiskFile(this.path, this.hash, this.bytes, [this.stamp]);
  Map<String, dynamic> toJson() => {
    'path': path,
    'hash': hash,
    'bytes': bytes,
    'stamp': stamp,
  };
  factory PeerDiskFile.fromJson(Map<String, dynamic> value) => PeerDiskFile(
    value['path'] as String,
    value['hash'] as String,
    value['bytes'] as int,
    value['stamp'] as String?,
  );
}

abstract class PeerFileSystem {
  Future<void> checkRoot();
  Future<String?> source(String path);
  Future<List<PeerDiskFile>> scan({
    void Function(String path, int checked)? onProgress,
    Map<String, PeerDiskFile> cached = const {},
    Set<String> invalidated = const {},
    bool forceHash = false,
  });
  Future<String?> hash(String path);
  Future<List<int>> read(String path, int offset, int count);
  Future<PeerStagingFile> stage(PeerFileEntry entry);
  Future<void> remove(String path, String? expectedHash);
}

abstract class PeerStagingFile {
  Future<int> prepare();
  Future<void> reset();
  Future<void> append(int offset, List<int> bytes);
  Future<String> hash();
  Future<void> publish(String? expectedHash);
  Future<void> discard();
}

String peerStageKey(PeerFileEntry entry) {
  if (entry.deleted) throw StateError('Удалению не нужен временный файл');
  return '${peerStorageKey(entry.path)}-${entry.hash}';
}

PeerFileSystem peerFileSystem(
  String root, {
  PeerHistorySettings history = const PeerHistorySettings(),
  void Function(String)? onHistoryWarning,
}) => root.startsWith('content://')
    ? SafPeerFiles(root, history: history, onHistoryWarning: onHistoryWarning)
    : LocalPeerFiles(
        Directory(root),
        history: history,
        onHistoryWarning: onHistoryWarning,
      );

Future<String> hashPeerFile(File file) {
  final path = file.path;
  return Isolate.run(
    () async => (await sha256.bind(File(path).openRead()).first).toString(),
  );
}

class LocalPeerFiles implements PeerFileSystem, PeerHistoryStorage {
  final Directory root;
  final PeerHistorySettings history;
  final void Function(String)? onHistoryWarning;
  LocalPeerFiles(
    this.root, {
    this.history = const PeerHistorySettings(),
    this.onHistoryWarning,
  });
  late final historyStore = PeerLocalHistory(_base, history);
  @override
  Future<PeerHistorySummary> maintainHistory({
    bool migrate = false,
    bool prune = false,
    bool clear = false,
  }) => historyStore.maintainHistory(
    migrate: migrate,
    prune: prune,
    clear: clear,
  );
  Future<void> _pruneHistory() async {
    if (!history.enabled) return;
    try {
      final report = await maintainHistory(prune: true);
      for (final warning in report.warnings) {
        onHistoryWarning?.call(warning);
      }
    } catch (e) {
      onHistoryWarning?.call('Не удалось применить ограничения истории: $e');
    }
  }

  Future<String> digest(File file) => hashPeerFile(file);
  Future<File> publishFile(File staged, String destination) =>
      staged.rename(destination);
  @override
  Future<void> checkRoot() async {
    await _base();
  }

  @override
  Future<String?> source(String path) async {
    final file = await _file(path);
    return await file.exists() ? file.path : null;
  }

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
  Future<List<PeerDiskFile>> scan({
    void Function(String path, int checked)? onProgress,
    Map<String, PeerDiskFile> cached = const {},
    Set<String> invalidated = const {},
    bool forceHash = false,
  }) async {
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
          onProgress?.call(path, files.length);
          final before = await entry.stat();
          final stamp =
              '${before.modified.microsecondsSinceEpoch}:${before.changed.microsecondsSinceEpoch}';
          final old = cached[path];
          final reuse =
              !forceHash &&
              !invalidated.contains(path) &&
              old?.stamp == stamp &&
              old?.bytes == before.size &&
              RegExp(r'^[a-f0-9]{64}$').hasMatch(old!.hash);
          final hash = reuse ? old.hash : await digest(entry);
          final after = await entry.stat();
          if (before.size != after.size || before.modified != after.modified) {
            throw StateError('Файл меняется во время сканирования: $path');
          }
          files.add(PeerDiskFile(path, hash, after.size, stamp));
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

  Future<Directory> _support(String leaf) async {
    final base = await _base();
    var path = base;
    for (final part in ['.pepehub', 'p2p', leaf]) {
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

  @override
  Future<PeerStagingFile> stage(PeerFileEntry entry) async =>
      _LocalPeerStage(this, entry);

  @override
  Future<void> remove(String path, String? expectedHash) async {
    await _check(path, expectedHash);
    if (expectedHash == null) return;
    final target = await _file(path);
    if (history.enabled) {
      await target.rename(
        p.join(
          (await historyStore.directory(create: true))!.path,
          historyStore.name(path),
        ),
      );
      await _pruneHistory();
    } else {
      await target.delete();
    }
  }
}

class _LocalPeerStage implements PeerStagingFile {
  final LocalPeerFiles files;
  final PeerFileEntry entry;
  _LocalPeerStage(this.files, this.entry);
  Future<File> _file() async {
    final file = File(
      p.join(
        (await files._support('staging')).path,
        '${peerStageKey(entry)}.part',
      ),
    );
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.notFound) {
      throw StateError('Временный файл заменён ссылкой или папкой');
    }
    return file;
  }

  @override
  Future<int> prepare() async {
    final file = await _file();
    if (!await file.exists()) await file.create();
    return file.length();
  }

  @override
  Future<void> reset() async => (await _file()).writeAsBytes([]);
  @override
  Future<void> append(int offset, List<int> bytes) async {
    if (offset < 0 || bytes.isEmpty || bytes.length > peerChunkSize) {
      throw StateError('Неверный блок временного файла');
    }
    final file = await _file();
    if (await file.length() != offset) {
      throw StateError('Смещение временного файла изменилось');
    }
    final handle = await file.open(mode: FileMode.append);
    try {
      await handle.writeFrom(bytes);
    } finally {
      await handle.close();
    }
  }

  @override
  Future<String> hash() async => hashPeerFile(await _file());
  @override
  Future<void> discard() async {
    final file = await _file();
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> publish(String? expectedHash) async {
    final target = await files._file(entry.path, parents: true),
        staging = await _file();
    if (await hashPeerFile(staging) != entry.hash) {
      throw StateError('Временный файл изменился до публикации');
    }
    await files._check(entry.path, expectedHash);
    File? previous;
    if (expectedHash != null) {
      if (files.history.enabled) {
        await files.historyStore.directory(create: true);
      }
      // A pending rollback is not history yet: another engine may clear or
      // prune history while the replacement is still being committed.
      final backupPath = p.join(
        (await files._support('staging')).path,
        'rollback-${const Uuid().v4()}.part',
      );
      previous = await target.rename(backupPath);
    }
    // The received file is already on the destination volume: no private cache
    // and no second full copy of the new payload are needed.
    try {
      if (previous != null && await hashPeerFile(previous) != expectedHash) {
        throw StateError(
          'Локальный файл изменился во время замены: ${entry.path}',
        );
      }
      await files.publishFile(staging, target.path);
    } catch (_) {
      if (previous != null &&
          await FileSystemEntity.type(target.path, followLinks: false) ==
              FileSystemEntityType.notFound) {
        await previous.rename(target.path);
      }
      rethrow;
    }
    if (previous != null) {
      try {
        if (files.history.enabled) {
          await previous.rename(
            p.join(
              (await files.historyStore.directory(create: true))!.path,
              files.historyStore.name(entry.path),
            ),
          );
        } else {
          await previous.delete();
        }
      } catch (e) {
        files.onHistoryWarning?.call(
          'Предыдущая версия осталась во временной папке: ${previous.path}: $e',
        );
      }
    }
    await files._pruneHistory();
  }
}

class SafPeerFiles implements PeerFileSystem, PeerHistoryStorage {
  @override
  Future<void> checkRoot() =>
      peerFilesChannel.invokeMethod<void>('check', {'root': root});
  final String root;
  final PeerHistorySettings history;
  final void Function(String)? onHistoryWarning;
  const SafPeerFiles(
    this.root, {
    this.history = const PeerHistorySettings(),
    this.onHistoryWarning,
  });
  @override
  Future<PeerHistorySummary> maintainHistory({
    bool migrate = false,
    bool prune = false,
    bool clear = false,
  }) async => PeerHistorySummary.fromJson(
    (await peerFilesChannel.invokeMapMethod<String, dynamic>('history', {
      'root': root,
      'history': history.toJson(),
      'migrate': migrate,
      'prune': prune,
      'clear': clear,
    }))!,
  );
  @override
  Future<String?> source(String path) => peerFilesChannel.invokeMethod<String>(
    'locate',
    {'root': root, 'path': peerPath(path)},
  );
  @override
  Future<List<PeerDiskFile>> scan({
    void Function(String path, int checked)? onProgress,
    Map<String, PeerDiskFile> cached = const {},
    Set<String> invalidated = const {},
    bool forceHash = false,
  }) async {
    final entries = await peerFilesChannel.invokeListMethod<Map>('scan', {
      'root': root,
      'cached': {for (final e in cached.entries) e.key: e.value.toJson()},
      'invalidated': invalidated.toList(),
      'forceHash': forceHash,
    });
    if (entries == null) throw StateError('Общая папка недоступна');
    return [
      for (final e in entries)
        PeerDiskFile(
          peerPath(e['path'] as String),
          e['hash'] as String,
          e['bytes'] as int,
          e['stamp'] as String?,
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
  Future<PeerStagingFile> stage(PeerFileEntry entry) async =>
      _SafPeerStage(root, entry, history, onHistoryWarning);
  @override
  Future<void> remove(String path, String? expectedHash) async {
    final result = await peerFilesChannel.invokeMethod<Object?>('remove', {
      'root': root,
      'path': peerPath(path),
      'expected': expectedHash,
      'history': history.toJson(),
    });
    if (result is Map) {
      for (final warning in result['warnings'] as List? ?? const []) {
        onHistoryWarning?.call(warning.toString());
      }
    }
  }
}

class _SafPeerStage implements PeerStagingFile {
  final String root;
  final PeerFileEntry entry;
  final PeerHistorySettings history;
  final void Function(String)? onHistoryWarning;
  _SafPeerStage(this.root, this.entry, this.history, this.onHistoryWarning);
  Map<String, dynamic> get arguments => {
    'root': root,
    'path': entry.path,
    'stage': peerStageKey(entry),
    'history': history.toJson(),
  };
  @override
  Future<int> prepare() async => (await peerFilesChannel.invokeMethod<num>(
    'stage_prepare',
    arguments,
  ))!.toInt();
  @override
  Future<void> reset() =>
      peerFilesChannel.invokeMethod<void>('stage_reset', arguments);
  @override
  Future<void> append(int offset, List<int> bytes) =>
      peerFilesChannel.invokeMethod<void>('stage_append', {
        ...arguments,
        'offset': offset,
        'bytes': Uint8List.fromList(bytes),
      });
  @override
  Future<String> hash() async =>
      (await peerFilesChannel.invokeMethod<String>('stage_hash', arguments))!;
  @override
  Future<void> publish(String? expectedHash) async {
    final result = await peerFilesChannel.invokeMethod<Object?>(
      'stage_publish',
      {...arguments, 'expected': expectedHash},
    );
    if (result is Map) {
      for (final warning in result['warnings'] as List? ?? const []) {
        onHistoryWarning?.call(warning.toString());
      }
    }
  }

  @override
  Future<void> discard() =>
      peerFilesChannel.invokeMethod<void>('stage_discard', arguments);
}
