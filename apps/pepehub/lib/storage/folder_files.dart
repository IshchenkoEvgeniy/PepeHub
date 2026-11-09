import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../diagnostics/user_message.dart';

// Files of a user-chosen folder (library folder, linked book folders):
// a plain directory on desktop, a Storage Access Framework tree on Android.
// Replacements are staged in a temporary file and renamed into place, so a
// file synchronization tool such as Syncthing never sees a half-written file.

/// Native Android access to Storage Access Framework folders.
const folderFilesChannel = MethodChannel('app.pepehub/folder_files');
const folderChunkSize = 256 * 1024;
const folderMaxFiles = 10000;

/// The Android side still accepts a version-history policy; it is always off.
const _noHistory = {
  'enabled': false,
  'maxDays': 30,
  'maxBytes': 500 * 1024 * 1024,
};

String folderPath(String value) {
  final parts = value.split('/');
  if (value.isEmpty ||
      value.length > 1024 ||
      parts.length > 32 ||
      parts.any(
        (part) =>
            part.isEmpty ||
            part == '.' ||
            part == '..' ||
            part.length > 240 ||
            part.endsWith('.') ||
            part.endsWith(' ') ||
            part.toLowerCase() == '.pepehub' ||
            part.toLowerCase().startsWith('.pepehub-') ||
            RegExp(r'[<>:"\\|?*\x00-\x1f\x7f]').hasMatch(part) ||
            RegExp(
              r'^(con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³])( *\.| *$)',
              caseSensitive: false,
            ).hasMatch(part),
      )) {
    throw const FormatException('Недопустимый относительный путь');
  }
  return value;
}

bool folderIgnored(String name) =>
    name.toLowerCase() == '.pepehub' ||
    name.toLowerCase().startsWith('.pepehub-') ||
    name.toLowerCase().startsWith('.syncthing.') ||
    name.toLowerCase().startsWith('~syncthing~') ||
    {'desktop.ini', 'thumbs.db', '.ds_store'}.contains(name.toLowerCase());

String folderStorageKey(String value) =>
    sha256.convert(utf8.encode(value)).toString();

class FolderFileEntry {
  final String path;
  final String? hash;
  final int bytes;
  final Map<String, int> clock;
  bool get deleted => hash == null;
  FolderFileEntry({
    required String path,
    required this.hash,
    required this.bytes,
    required Map<String, int> clock,
  }) : path = folderPath(path),
       clock = Map.unmodifiable(clock) {
    if (bytes < 0 ||
        bytes > 1 << 50 ||
        hash != null && !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash!) ||
        hash == null && bytes != 0 ||
        clock.isEmpty ||
        clock.length > 64 ||
        clock.entries.any(
          (e) =>
              !RegExp(r'^[a-f0-9-]{36}$').hasMatch(e.key) ||
              e.value < 1 ||
              e.value > 9007199254740991,
        )) {
      throw const FormatException('Некорректная версия файла');
    }
  }
  FolderFileEntry withClock(Map<String, int> value, {String? path}) =>
      FolderFileEntry(
        path: path ?? this.path,
        hash: hash,
        bytes: bytes,
        clock: value,
      );
  Map<String, dynamic> toJson() => {
    'path': path,
    'hash': hash,
    'bytes': bytes,
    'clock': clock,
  };
  factory FolderFileEntry.fromJson(Map<String, dynamic> json) => FolderFileEntry(
    path: json['path'] as String,
    hash: json['hash'] as String?,
    bytes: json['bytes'] as int,
    clock: Map<String, int>.from(json['clock'] as Map),
  );
}

class FolderDiskFile {
  final String path, hash;
  final int bytes;
  final String? stamp;
  const FolderDiskFile(this.path, this.hash, this.bytes, [this.stamp]);
  Map<String, dynamic> toJson() => {
    'path': path,
    'hash': hash,
    'bytes': bytes,
    'stamp': stamp,
  };
  factory FolderDiskFile.fromJson(Map<String, dynamic> value) => FolderDiskFile(
    value['path'] as String,
    value['hash'] as String,
    value['bytes'] as int,
    value['stamp'] as String?,
  );
}

abstract class FolderFileSystem {
  Future<void> checkRoot();
  Future<String?> source(String path);
  Future<List<FolderDiskFile>> scan({
    void Function(String path, int checked)? onProgress,
    Map<String, FolderDiskFile> cached = const {},
    Set<String> invalidated = const {},
    bool forceHash = false,
  });
  Future<String?> hash(String path);
  Future<List<int>> read(String path, int offset, int count);
  Future<FolderStagingFile> stage(FolderFileEntry entry);
  Future<void> remove(String path, String? expectedHash);
}

abstract class FolderStagingFile {
  Future<int> prepare();
  Future<void> reset();
  Future<void> append(int offset, List<int> bytes);
  Future<String> hash();
  Future<void> publish(String? expectedHash);
  Future<void> discard();
}

String folderStageKey(FolderFileEntry entry) {
  if (entry.deleted) throw StateError('Удалению не нужен временный файл');
  return '${folderStorageKey(entry.path)}-${entry.hash}';
}

FolderFileSystem folderFileSystem(
  String root, {
  void Function(String)? onWarning,
}) => root.startsWith('content://')
    ? SafFolderFiles(root, onWarning: onWarning)
    : LocalFolderFiles(Directory(root), onWarning: onWarning);

Future<String> hashFolderFile(File file) {
  final path = file.path;
  return Isolate.run(
    () async => (await sha256.bind(File(path).openRead()).first).toString(),
  );
}

class LocalFolderFiles implements FolderFileSystem {
  final Directory root;
  final void Function(String)? onWarning;
  LocalFolderFiles(this.root, {this.onWarning});

  Future<String> digest(File file) => hashFolderFile(file);
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
    folderPath(path);
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
  Future<List<FolderDiskFile>> scan({
    void Function(String path, int checked)? onProgress,
    Map<String, FolderDiskFile> cached = const {},
    Set<String> invalidated = const {},
    bool forceHash = false,
  }) async {
    await _base();
    if (!await root.exists()) {
      throw StateError('Общая папка недоступна; индекс сохранён');
    }
    final files = <FolderDiskFile>[], folded = <String>{};
    var visited = 0;
    Future<void> visit(Directory dir, String prefix, int depth) async {
      if (depth > 32) throw StateError('Больше 32 уровней вложенности');
      await for (final entry in dir.list(followLinks: false)) {
        if (++visited > 50000) {
          throw StateError('В общей папке больше 50000 элементов');
        }
        final name = p.basename(entry.path);
        if (folderIgnored(name)) continue;
        if (entry is Link) {
          throw StateError('Общая папка содержит ссылку: $name');
        }
        final path = folderPath('$prefix$name');
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
          files.add(FolderDiskFile(path, hash, after.size, stamp));
          if (files.length > folderMaxFiles) {
            throw StateError('В общей папке больше $folderMaxFiles файлов');
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
    return await file.exists() ? hashFolderFile(file) : null;
  }

  /// Cheap change marker: size and modification times, no file read.
  /// `missing` when the file does not exist.
  Future<String> stamp(String path) async {
    final stat = await (await _file(path)).stat();
    if (stat.type == FileSystemEntityType.notFound) return 'missing';
    return '${stat.size}:${stat.modified.microsecondsSinceEpoch}:'
        '${stat.changed.microsecondsSinceEpoch}';
  }

  @override
  Future<List<int>> read(String path, int offset, int count) async {
    final file = await _file(path);
    final handle = await file.open();
    try {
      if (offset < 0 ||
          count < 1 ||
          count > folderChunkSize ||
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
  Future<FolderStagingFile> stage(FolderFileEntry entry) async =>
      _LocalFolderStage(this, entry);

  @override
  Future<void> remove(String path, String? expectedHash) async {
    await _check(path, expectedHash);
    if (expectedHash == null) return;
    await (await _file(path)).delete();
  }
}

class _LocalFolderStage implements FolderStagingFile {
  final LocalFolderFiles files;
  final FolderFileEntry entry;
  _LocalFolderStage(this.files, this.entry);
  Future<File> _file() async {
    final file = File(
      p.join(
        (await files._support('staging')).path,
        '${folderStageKey(entry)}.part',
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
    if (offset < 0 || bytes.isEmpty || bytes.length > folderChunkSize) {
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
  Future<String> hash() async => hashFolderFile(await _file());
  @override
  Future<void> discard() async {
    final file = await _file();
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> publish(String? expectedHash) async {
    final target = await files._file(entry.path, parents: true),
        staging = await _file();
    if (await hashFolderFile(staging) != entry.hash) {
      throw StateError('Временный файл изменился до публикации');
    }
    await files._check(entry.path, expectedHash);
    File? previous;
    if (expectedHash != null) {
      final backupPath = p.join(
        (await files._support('staging')).path,
        'rollback-${const Uuid().v4()}.part',
      );
      previous = await target.rename(backupPath);
    }
    // The received file is already on the destination volume: no private cache
    // and no second full copy of the new payload are needed.
    try {
      if (previous != null && await hashFolderFile(previous) != expectedHash) {
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
        await previous.delete();
      } catch (e) {
        files.onWarning?.call(
          'Предыдущая версия осталась во временной папке: ${previous.path}: ${describeError(e)}',
        );
      }
    }
  }
}

class SafFolderFiles implements FolderFileSystem {
  @override
  Future<void> checkRoot() =>
      folderFilesChannel.invokeMethod<void>('check', {'root': root});
  final String root;
  final void Function(String)? onWarning;
  const SafFolderFiles(this.root, {this.onWarning});
  @override
  Future<String?> source(String path) => folderFilesChannel.invokeMethod<String>(
    'locate',
    {'root': root, 'path': folderPath(path)},
  );
  @override
  Future<List<FolderDiskFile>> scan({
    void Function(String path, int checked)? onProgress,
    Map<String, FolderDiskFile> cached = const {},
    Set<String> invalidated = const {},
    bool forceHash = false,
  }) async {
    final entries = await folderFilesChannel.invokeListMethod<Map>('scan', {
      'root': root,
      'cached': {for (final e in cached.entries) e.key: e.value.toJson()},
      'invalidated': invalidated.toList(),
      'forceHash': forceHash,
    });
    if (entries == null) throw StateError('Общая папка недоступна');
    return [
      for (final e in entries)
        FolderDiskFile(
          folderPath(e['path'] as String),
          e['hash'] as String,
          e['bytes'] as int,
          e['stamp'] as String?,
        ),
    ];
  }

  @override
  Future<String?> hash(String path) => folderFilesChannel.invokeMethod<String>(
    'hash',
    {'root': root, 'path': folderPath(path)},
  );

  /// Size and modification time from the document provider, no file read.
  /// `missing` when absent; null when the native side predates `stat`.
  Future<String?> stamp(String path) async {
    try {
      return await folderFilesChannel.invokeMethod<String>('stat', {
            'root': root,
            'path': folderPath(path),
          }) ??
          'missing';
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      if (error.message == 'Неизвестная операция') return null;
      rethrow;
    }
  }

  @override
  Future<List<int>> read(String path, int offset, int count) async =>
      await folderFilesChannel.invokeMethod<Uint8List>('read', {
        'root': root,
        'path': folderPath(path),
        'offset': offset,
        'count': count,
      }) ??
      <int>[];
  @override
  Future<FolderStagingFile> stage(FolderFileEntry entry) async =>
      _SafFolderStage(root, entry, onWarning);
  @override
  Future<void> remove(String path, String? expectedHash) async {
    final result = await folderFilesChannel.invokeMethod<Object?>('remove', {
      'root': root,
      'path': folderPath(path),
      'expected': expectedHash,
      'history': _noHistory,
    });
    if (result is Map) {
      for (final warning in result['warnings'] as List? ?? const []) {
        onWarning?.call(warning.toString());
      }
    }
  }
}

class _SafFolderStage implements FolderStagingFile {
  final String root;
  final FolderFileEntry entry;
  final void Function(String)? onWarning;
  _SafFolderStage(this.root, this.entry, this.onWarning);
  Map<String, dynamic> get arguments => {
    'root': root,
    'path': entry.path,
    'stage': folderStageKey(entry),
    'history': _noHistory,
  };
  @override
  Future<int> prepare() async => (await folderFilesChannel.invokeMethod<num>(
    'stage_prepare',
    arguments,
  ))!.toInt();
  @override
  Future<void> reset() =>
      folderFilesChannel.invokeMethod<void>('stage_reset', arguments);
  @override
  Future<void> append(int offset, List<int> bytes) =>
      folderFilesChannel.invokeMethod<void>('stage_append', {
        ...arguments,
        'offset': offset,
        'bytes': Uint8List.fromList(bytes),
      });
  @override
  Future<String> hash() async =>
      (await folderFilesChannel.invokeMethod<String>('stage_hash', arguments))!;
  @override
  Future<void> publish(String? expectedHash) async {
    final result = await folderFilesChannel.invokeMethod<Object?>(
      'stage_publish',
      {...arguments, 'expected': expectedHash},
    );
    if (result is Map) {
      for (final warning in result['warnings'] as List? ?? const []) {
        onWarning?.call(warning.toString());
      }
    }
  }

  @override
  Future<void> discard() =>
      folderFilesChannel.invokeMethod<void>('stage_discard', arguments);
}
