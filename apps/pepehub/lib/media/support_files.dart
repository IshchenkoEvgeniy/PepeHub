import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../audio/audio_folder.dart';

/// Read portable state one bounded file at a time, including recovery backups.
Future<List<({String name, Future<String> Function() read})>> supportFiles(
  String root,
) async {
  final result = <({String name, Future<String> Function() read})>[];
  if (root.startsWith('content:')) {
    final rows =
        await audioFolderChannel.invokeListMethod<dynamic>('supportFiles', {
          'root': root,
        }) ??
        [];
    for (final row in rows) {
      final file = SafAudioFile(
        row['uri'] as String,
        row['name'] as String,
        (row['size'] as num).toInt(),
      );
      result.add((
        name: row['name'] as String,
        read: () async {
          var size = 0;
          return utf8.decoder
              .bind(
                file.openRead().map((chunk) {
                  size += chunk.length;
                  if (size > 16 * 1024 * 1024) {
                    throw StateError('Журнал слишком большой');
                  }
                  return chunk;
                }),
              )
              .join();
        },
      ));
    }
  } else {
    final directory = Directory(p.join(root, '.pepehub'));
    if (!await directory.exists()) return result;
    await for (final entry in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entry is! File ||
          !(entry.path.endsWith('.json') || entry.path.endsWith('.json.bak'))) {
        continue;
      }
      final size = await entry.length();
      if (size <= 0 || size > 16 * 1024 * 1024) continue;
      result.add((
        name: p
            .relative(entry.path, from: directory.path)
            .replaceAll('\\', '/'),
        read: entry.readAsString,
      ));
      if (result.length > 10000) throw StateError('Слишком много журналов');
    }
  }
  result.sort((a, b) {
    final base = b.name
        .replaceFirst(RegExp(r'\.bak$'), '')
        .compareTo(a.name.replaceFirst(RegExp(r'\.bak$'), ''));
    if (base != 0) return base;
    return a.name.compareTo(b.name);
  });
  return result;
}
