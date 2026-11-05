import 'dart:convert';

import 'package:drift/drift.dart' show Variable;

import '../data/repository.dart';
import '../library/activity_store.dart';
import '../library/library_repository.dart';
import '../library/models.dart';
import '../library/personal_library.dart';

const portableStatisticsKey = 'statistics-portable-v1';

Future<Map<String, dynamic>> portableStatistics(Repository repository) async =>
    {
      'books': <String, dynamic>{},
      'tracks': <String, dynamic>{},
      ...jsonDecode(
        await repository.meta(portableStatisticsKey) ??
            '{"activity":{},"works":{}}',
      ) as Map<String, dynamic>,
    };

/// Imported descriptions are statistics views, never additions to the library.
Future<List<LibraryEntry>> statisticsEntries(
  Repository repository,
  Iterable<LibraryEntry> local,
) async {
  final result = {for (final e in local) e.item.id: e};
  final catalog = await LibraryRepository(
    repository,
    personalLibraryNamespace,
    storageKey: personalLibraryKey,
  ).entries();
  final data = await portableStatistics(repository);
  for (final row in (data['works'] as Map).entries) {
    // Local visibility and deletion choices take precedence over an older export.
    if (catalog.containsKey(row.key)) continue;
    result.putIfAbsent(
      '${row.key}',
      () => LibraryEntry.fromJson(Map<String, dynamic>.from(row.value as Map)),
    );
  }
  return result.values.toList();
}

Future<List<Map<String, dynamic>>> portableActivity(
  Repository repository,
  String type,
) async {
  final data = await portableStatistics(repository);
  final rows = [
    for (final v in (data['activity'] as Map).values)
      Map<String, dynamic>.from(v as Map),
  ];
  if (rows.isEmpty) return [];
  final sourceKeys = <String, Set<String>>{};
  for (final row in rows) {
    final source = row['source'];
    if (source is Map && source['id'] is String) {
      (sourceKeys['${source['kind']}'] ??= {}).add(source['id']);
    }
  }
  final native = <String>{};
  for (final (kind, table, column, prefix) in [
    ('reader', 'metadata', 'key', 'reading-session:'),
    ('audio', 'records', 'id', ''),
    ('manual', 'records', 'id', ''),
  ]) {
    final ids = sourceKeys[kind];
    if (ids == null || ids.isEmpty) continue;
    for (final row
        in await repository.db
            .customSelect(
              'SELECT $column AS id FROM $table WHERE $column IN (SELECT ?||value FROM json_each(?))',
              variables: [Variable(prefix), Variable(jsonEncode(ids.toList()))],
            )
            .get()) {
      native.add('$kind:${row.read<String>('id').substring(prefix.length)}');
    }
  }
  final canonical = {
    for (final s
        in ((await ActivityStore(
                  repository,
                  personalLibraryNamespace,
                ).state())['slots']
                as Map)
            .values)
      s['value']['id'],
  };
  return [
    for (final row in rows)
      if (row['value']['mediaType'] == type &&
          row['counted'] != false &&
          row['value']['deleted'] != true &&
          !native.contains(
            '${row['source']?['kind']}:${row['source']?['id']}',
          ) &&
          !canonical.contains(row['value']['id']))
        row,
  ];
}

Map<String, dynamic> portableReadingSession(Map<String, dynamic> row) {
  final value = row['value'] as Map;
  final start = value['startedAt'] ?? '${value['day']}T12:00:00.000Z';
  final end =
      value['endedAt'] ??
      DateTime.parse(start as String)
          .add(Duration(milliseconds: (value['durationMs'] as num).toInt()))
          .toIso8601String();
  return {
    'id': value['id'],
    'bookId': row['bookId'],
    'startedAt': start,
    'day': value['day'],
    'timeKnown': value['startedAt'] != null,
    'source': 'import',
    'closed': true,
    'spans': [
      {
        'start': start,
        'end': end,
        'activeMs': value['durationMs'],
        'localDay': value['day'],
        'offsetMinutes': value['offsetMinutes'],
        'newChars': value['unit'] == 'characters' ? value['progress'] : 0,
      },
    ],
  };
}
