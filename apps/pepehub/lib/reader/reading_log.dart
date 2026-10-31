import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart' show Variable;

import 'package:path/path.dart' as p;

import '../audio/audio_folder.dart';
import '../data/repository.dart';
import 'reading_activity.dart';
import 'reading_library.dart';

// Recovery logs retain original events and index fields. Only the selected
// root/day crosses to this worker; parsing and encoding stay off the UI.
String _encodePacket(Map<String, dynamic> packet) {
  final metadata = packet['metadata'] as Map<String, String>;
  Map<String, dynamic> value(String key) =>
      jsonDecode(metadata[key] ?? '{}') as Map<String, dynamic>;
  final assets = packet['assets'] as List<(String, String)>;
  final hashes = {for (final (id, hash) in assets) id: hash};
  final manual = [
    for (final (id, raw) in packet['manual'] as List<(String, String)>)
      (id, jsonDecode(raw) as Map<String, dynamic>),
  ];
  final text = jsonEncode({
    'format': 'pepehub-reading-log',
    'version': 1,
    'day': packet['day'],
    'books': [
      for (final (id, hash) in assets)
        {
          'hash': hash,
          for (final prefix in ['reader', 'reading-coverage', 'reading-index'])
            prefix: value('$prefix:$hash'),
          'dates': value('reading-dates:$id'),
        },
    ],
    'sessions': [
      for (final raw in packet['sessions'] as List<String>) jsonDecode(raw),
    ],
    'manualSessions': [
      for (final (id, data) in manual)
        if (hashes.containsKey(data['bookId']))
          {'id': id, 'hash': hashes[data['bookId']], ...data},
    ],
  });
  if (utf8.encode(text).length > 16 * 1024 * 1024) {
    throw StateError(
      'Журнал чтения превышает 16 МиБ; данные сохранены в приложении.',
    );
  }
  return text;
}

Future<List<Map<String, dynamic>>> _exportDays(
  List<Map<String, dynamic>> headers,
) => Isolate.run(() {
  final unique = <String, Map<String, dynamic>>{};
  for (final row in headers) {
    final id = row['bookId'], start = DateTime.tryParse('${row['startedAt']}');
    if (id is String && start != null) {
      unique['$id:${readingDay(start.toLocal())}'] = row;
    }
  }
  return unique.values.toList();
});

class ReadingLog {
  final Repository repository;
  ReadingLog(this.repository);
  Future<void> export(Map<String, dynamic> session) async {
    try {
      await _export(session);
      await repository.setMeta('reading-log-error:${session['bookId']}', '');
    } catch (e) {
      await repository.setMeta('reading-log-error:${session['bookId']}', '$e');
      rethrow;
    }
  }

  Future<void> _export(Map<String, dynamic> session) async {
    final library = ReadingLibrary(repository);
    final day = readingDay(
      DateTime.parse(session['startedAt'] as String).toLocal(),
    );
    final roots = await library.entries('reading-library-root:');
    for (final root in roots.values) {
      final ids = (root['bookIds'] as List).cast<String>().toSet();
      if (!ids.contains(session['bookId'])) continue;
      if ((await repository.meta('reading-recovery-error:${root['path']}') ??
              '')
          .isNotEmpty) {
        throw StateError(
          'Журнал защищён до завершения восстановления истории.',
        );
      }
      final date = DateTime.parse(session['startedAt'] as String).toLocal();
      final from = DateTime(
        date.year,
        date.month,
        date.day,
      ).millisecondsSinceEpoch;
      final until = DateTime(
        date.year,
        date.month,
        date.day + 1,
      ).millisecondsSinceEpoch;
      final idsJson = jsonEncode(ids.toList());
      final automatic = await repository.db
          .customSelect(
            'SELECT m.value FROM reading_statistics_sessions_v1 s JOIN metadata m ON m.key=s.key '
            'WHERE s.book_id IN (SELECT value FROM json_each(?)) AND s.start_ms>=? AND s.start_ms<?',
            variables: [Variable(idsJson), Variable(from), Variable(until)],
          )
          .get();
      final manual = await repository.db
          .customSelect(
            "SELECT id,payload FROM records WHERE type='session' AND deleted=0 AND json_valid(payload) "
            "AND json_extract(payload,'\$.kind')='reading' AND json_extract(payload,'\$.bookId') IN (SELECT value FROM json_each(?)) "
            "AND unixepoch(json_extract(payload,'\$.startedAt'),'subsec')*1000>=? AND unixepoch(json_extract(payload,'\$.startedAt'),'subsec')*1000<?",
            variables: [Variable(idsJson), Variable(from), Variable(until)],
          )
          .get();
      final rows = await repository.db
          .customSelect(
            'SELECT book_id,sha256 FROM local_assets WHERE book_id IN (SELECT value FROM json_each(?))',
            variables: [Variable(idsJson)],
          )
          .get();
      final assets = [
        for (final row in rows)
          (row.read<String>('book_id'), row.read<String>('sha256')),
      ];
      final keys = [
        for (final (id, hash) in assets) ...[
          for (final prefix in ['reader', 'reading-coverage', 'reading-index'])
            '$prefix:$hash',
          'reading-dates:$id',
        ],
      ];
      final metadata = await repository.db
          .customSelect(
            'SELECT key,value FROM metadata WHERE key IN (SELECT value FROM json_each(?))',
            variables: [Variable(jsonEncode(keys))],
          )
          .get();
      final packet = <String, dynamic>{
        'day': day,
        'assets': assets,
        'metadata': {
          for (final row in metadata)
            row.read<String>('key'): row.read<String>('value'),
        },
        'sessions': [for (final row in automatic) row.read<String>('value')],
        'manual': [
          for (final row in manual)
            (row.read<String>('id'), row.read<String>('payload')),
        ],
      };
      final text = await Isolate.run(() => _encodePacket(packet));
      final path = root['path'] as String, name = 'reading-$day.json';
      if (path.startsWith('content:')) {
        await audioFolderChannel.invokeMethod<void>('readingJournal', {
          'root': path,
          'day': day,
          'name': name,
          'json': text,
          'replace': true,
        });
      } else {
        var directory = Directory(path);
        if (!await directory.exists()) {
          throw StateError('Папка чтения недоступна: $path');
        }
        for (final part in ['.pepehub', 'reading', 'logs', day]) {
          directory = Directory(p.join(directory.path, part));
          final type = await FileSystemEntity.type(
            directory.path,
            followLinks: false,
          );
          if (type != FileSystemEntityType.notFound &&
              type != FileSystemEntityType.directory) {
            throw StateError('Каталог журнала недоступен');
          }
          await directory.create();
        }
        final target = File(p.join(directory.path, name)),
            backup = File(p.join(directory.path, '$name.bak'));
        final temp = File('${target.path}.${uuid.v4()}.partial');
        try {
          await temp.writeAsString(text, flush: true);
          if (await target.exists()) {
            if (await backup.exists()) await backup.delete();
            await target.rename(backup.path);
          }
          await temp.rename(target.path);
        } finally {
          if (await temp.exists()) await temp.delete();
        }
      }
      await repository.setMeta(
        'reading-log-saved:${session['bookId']}',
        DateTime.now().toUtc().toIso8601String(),
      );
      await repository.setMeta(
        'reading-log-path:${session['bookId']}',
        '$path/.pepehub/reading/logs/$day/$name',
      );
    }
  }

  /// Rewrites every recorded day in each connected reading folder.
  Future<int> exportAll({String? bookId}) async {
    final roots = (await ReadingLibrary(
      repository,
    ).entries('reading-library-root:')).values.toList();
    final ids = {
      for (final root in roots) ...List<String>.from(root['bookIds'] as List),
    };
    if (ids.isEmpty || bookId != null && !ids.contains(bookId)) return 0;
    final wanted = jsonEncode(bookId == null ? ids.toList() : [bookId]);
    final automatic = await repository.db
        .customSelect(
          'SELECT book_id AS bookId,started_at AS startedAt FROM reading_statistics_sessions_v1 WHERE book_id IN (SELECT value FROM json_each(?))',
          variables: [Variable(wanted)],
        )
        .get();
    final manual = await repository.db
        .customSelect(
          "SELECT json_extract(payload,'\$.bookId') AS bookId,json_extract(payload,'\$.startedAt') AS startedAt "
          "FROM records WHERE type='session' AND deleted=0 AND json_valid(payload) AND json_extract(payload,'\$.kind')='reading' "
          "AND json_extract(payload,'\$.bookId') IN (SELECT value FROM json_each(?))",
          variables: [Variable(wanted)],
        )
        .get();
    final headers = [
      for (final row in [...automatic, ...manual]) row.data,
    ];
    final unique = await _exportDays(headers);
    final written = <String>{};
    for (final row in unique) {
      final day = readingDay(
        DateTime.parse(row['startedAt'] as String).toLocal(),
      );
      final paths = {
        for (final root in roots)
          if ((root['bookIds'] as List).contains(row['bookId']))
            '${root['path']}:$day',
      };
      if (paths.every(written.contains)) continue;
      await export(row);
      written.addAll(paths);
    }
    return written.length;
  }
}
