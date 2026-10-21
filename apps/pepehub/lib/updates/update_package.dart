import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'update_manifest.dart';

Future<List<Map<String, Object>>> stageUpdatePackage(
  String zipPath,
  String stagePath,
) => Isolate.run(() => extractUpdatePackage(zipPath, stagePath));

bool safeUpdatePath(String value) {
  if (value.isEmpty ||
      value.length > 200 ||
      value.contains('\\') ||
      value.startsWith('/') ||
      value.contains(':') ||
      RegExp(r'[\x00-\x1f<>"|?*]').hasMatch(value)) {
    return false;
  }
  final parts = value.split('/');
  if (parts.any(
    (part) =>
        part.isEmpty ||
        part == '.' ||
        part == '..' ||
        part.endsWith('.') ||
        part.endsWith(' ') ||
        RegExp(
          r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\.|$)',
          caseSensitive: false,
        ).hasMatch(part),
  )) {
    return false;
  }
  return parts.first == 'data' && parts.length > 1 ||
      parts.length == 1 &&
          (value == 'pepehub.exe' || value.toLowerCase().endsWith('.dll'));
}

/// Runs in an isolate. A fresh staging directory keeps ZIP entries away from
/// the installed application and its local library until the helper commits.
Future<List<Map<String, Object>>> extractUpdatePackage(
  String zipPath,
  String stagingPath,
) async {
  final root = Directory(stagingPath);
  if (root.existsSync()) {
    throw const UpdateException('Каталог подготовки уже существует');
  }
  root.createSync();
  final input = InputFileStream(zipPath);
  try {
    final decoder = ZipDecoder();
    final archive = decoder.decodeStream(input);
    if (decoder.directory.fileHeaders.length > 12000 ||
        archive.length > 10000) {
      throw const UpdateException('Слишком много файлов в обновлении');
    }
    // Inspect original ZIP headers too: Archive merges duplicate filenames.
    final seen = <String>{};
    var total = 0;
    for (final header in decoder.directory.fileHeaders) {
      final entry = header.file!;
      final name = entry.filename;
      final directory = name.endsWith('/');
      final mode = header.externalFileAttributes >> 16;
      final safe = directory
          ? (name == 'data/' ||
                safeUpdatePath(name.substring(0, name.length - 1)))
          : safeUpdatePath(name);
      if ((mode & 0xf000) == 0xa000 || !seen.add(name.toLowerCase()) || !safe) {
        throw const UpdateException('Небезопасная структура архива обновления');
      }
      total += entry.uncompressedSize;
      if (entry.uncompressedSize < 0 ||
          entry.uncompressedSize > 536870912 ||
          total > 2147483648) {
        throw const UpdateException('Слишком большой распакованный пакет');
      }
    }
    final files = <Map<String, Object>>[];
    for (final entry in archive) {
      if (!entry.isFile) continue;
      if (entry.isSymbolicLink) {
        throw const UpdateException('Ссылки в пакете запрещены');
      }
      final target = File(p.joinAll([root.path, ...entry.name.split('/')]));
      target.parent.createSync(recursive: true);
      final output = OutputFileStream(target.path);
      try {
        entry.writeContent(output);
      } finally {
        output.closeSync();
      }
      if (target.lengthSync() != entry.size) {
        throw const UpdateException('Неверный размер распакованного файла');
      }
      final digest = (await sha256.bind(target.openRead()).first).toString();
      files.add({'path': entry.name, 'sha256': digest, 'bytes': entry.size});
    }
    if (!files.any((f) => f['path'] == 'pepehub.exe') ||
        !files.any((f) => f['path'] == 'flutter_windows.dll') ||
        !files.any((f) => (f['path'] as String).startsWith('data/'))) {
      throw const UpdateException('В архиве нет полного Windows-приложения');
    }
    return files;
  } finally {
    input.closeSync();
  }
}
