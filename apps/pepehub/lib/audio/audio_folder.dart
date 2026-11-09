import 'dart:io';
import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../reader/book_formats.dart';
import 'audio_import.dart' show naturalAudioOrder;

const audioFolderChannel = MethodChannel('app.pepehub/audio_folder');
bool isAudioSupportFolder(String name) =>
    name.toLowerCase() == '.pepehub' ||
    name.toLowerCase().startsWith('!smart audiobook player');

class AudioFolder {
  final String title;
  final List<XFile> files;
  final String? root;
  final int unsupportedFiles;
  int get foundFiles => files.length + unsupportedFiles;
  AudioFolder(this.title, this.files, {this.root, this.unsupportedFiles = 0});
}

/// The name is a relative display path, never an absolute source path.
class FolderAudioFile extends XFile {
  final String relativePath;
  FolderAudioFile(super.path, this.relativePath);
  @override
  String get name => relativePath;
}

class SafAudioFile extends FolderAudioFile {
  final int bytes;
  SafAudioFile(super.path, super.relativePath, this.bytes);
  @override
  Future<int> length() async => bytes;
  @override
  Stream<Uint8List> openRead([int? start, int? end]) async* {
    if (start != null || end != null) {
      throw UnsupportedError('SAF supports sequential import only');
    }
    final handle = await audioFolderChannel.invokeMethod<String>('open', {
      'uri': path,
    });
    if (handle == null) throw StateError('Не удалось открыть файл');
    try {
      while (true) {
        final chunk = await audioFolderChannel.invokeMethod<Uint8List>('read', {
          'handle': handle,
        });
        if (chunk == null || chunk.isEmpty) break;
        yield chunk;
      }
    } finally {
      await audioFolderChannel.invokeMethod<void>('close', {'handle': handle});
    }
  }
}

Future<AudioFolder> scanAudioFolder(
  String path, {
  int maxFiles = 10000,
  int maxEntries = 50000,
  bool books = false,
}) async {
  final root = Directory(path);
  final files = <XFile>[];
  var entries = 0, unsupported = 0;
  Future<void> visit(Directory directory, int depth) async {
    if (depth > 32) {
      throw StateError('Слишком много вложенных папок (максимум 32)');
    }
    await for (final entry in directory.list(followLinks: false)) {
      if (++entries > maxEntries) {
        throw StateError(
          'Слишком большая папка (максимум $maxEntries элементов)',
        );
      }
      if (entry is Directory) {
        if (isAudioSupportFolder(p.basename(entry.path))) continue;
        await visit(entry, depth + 1);
      } else if (entry is File &&
          (books ? bookExtensions : audioExtensions).any(
            (ext) => p.extension(entry.path).toLowerCase() == '.$ext',
          )) {
        files.add(
          FolderAudioFile(
            entry.path,
            p.relative(entry.path, from: root.path).replaceAll('\\', '/'),
          ),
        );
        if (files.length > maxFiles) {
          throw StateError(
            'В корневой папке допускается не более $maxFiles аудиофайлов',
          );
        }
      } else if (entry is File) {
        unsupported++;
      }
    }
  }

  await visit(root, 0);
  // Directory listings come back in file-system order (alphabetical on NTFS,
  // arbitrary on ext4 or on another device). Sort so the same folder gives the
  // same track order everywhere.
  files.sort((a, b) => naturalAudioOrder(a.name, b.name));
  return AudioFolder(
    p.basename(p.normalize(path)),
    files,
    root: p.normalize(p.absolute(path)),
    unsupportedFiles: unsupported,
  );
}

Future<AudioFolder?> pickAudioFolder({bool books = false}) async {
  if (Platform.isAndroid) {
    final result = await audioFolderChannel.invokeMapMethod<String, dynamic>(
      'pick',
      {'books': books},
    );
    if (result == null) return null;
    return AudioFolder(
      result['title'] as String,
      [
        for (final entry in result['files'] as List)
          SafAudioFile(
            entry['uri'] as String,
            entry['name'] as String,
            entry['size'] as int,
          ),
      ],
      root: result['root'] as String,
      unsupportedFiles: (result['unsupportedFiles'] as num?)?.toInt() ?? 0,
    );
  }
  final path = await getDirectoryPath();
  return path == null ? null : scanAudioFolder(path, books: books);
}

Future<AudioFolder> rescanAudioFolder(String root, {bool books = false}) async {
  if (!root.startsWith('content://')) {
    return scanAudioFolder(root, books: books);
  }
  final result = await audioFolderChannel.invokeMapMethod<String, dynamic>(
    'scan',
    {'root': root, 'books': books},
  );
  if (result == null) {
    throw StateError('Папка недоступна. Укажите путь заново.');
  }
  return AudioFolder(
    result['title'] as String,
    [
      for (final entry in result['files'] as List)
        SafAudioFile(
          entry['uri'] as String,
          entry['name'] as String,
          entry['size'] as int,
        ),
    ],
    root: root,
    unsupportedFiles: (result['unsupportedFiles'] as num?)?.toInt() ?? 0,
  );
}

/// A Windows path (`C:\…`, `C:/…`, `\\server\…`) is read as one on every
/// platform, so a URI does not depend on where the code happens to run.
Uri audioSourceUri(String path) => path.startsWith('content://')
    ? Uri.parse(path)
    : Uri.file(
        path,
        windows: RegExp(r'^([A-Za-z]:[\\/]|\\\\)').hasMatch(path) ? true : null,
      );

Future<bool> audioSourceExists(String path) async {
  if (!path.startsWith('content://')) {
    return File(path).exists().timeout(const Duration(seconds: 3));
  }
  try {
    return await audioFolderChannel
            .invokeMethod<bool>('exists', {'uri': path})
            .timeout(const Duration(seconds: 3)) ??
        false;
  } on MissingPluginException {
    // The Android activity can be gone while AudioService still plays. In
    // that case the native player's ContentDataSource checks access itself.
    return true;
  }
}
