import 'dart:convert';

import 'package:drift/drift.dart' show Variable;

import 'models.dart';
import '../data/database_schema.dart';
import '../data/repository.dart';
import '../reader/reading_library.dart';
import '../audio/audio_journal.dart' show dayKey;
import 'library_repository.dart';
import 'personal_library.dart';
import 'library_features.dart';

class _Equality {
  const _Equality();
  bool equals(dynamic a, dynamic b) => sameMetadataValue(a, b);
}

const _equal = _Equality();

bool validActivityValue(dynamic value) {
  if (value is! Map) return false;
  const keys = [
    'id',
    'itemId',
    'mediaType',
    'day',
    'durationMs',
    'progress',
    'unit',
    'mediaMs',
    'startedAt',
    'endedAt',
    'offsetMinutes',
    'note',
    'origin',
    'deleted',
  ];
  final id = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );
  bool integer(dynamic v, int min, int max) => v is int && v >= min && v <= max;
  bool instant(dynamic v) =>
      v == null ||
      v is String &&
          RegExp(r'^\d{4}-\d\d-\d\dT.*Z$').hasMatch(v) &&
          DateTime.tryParse(v) != null;
  final day = value['day'];
  final date = day is String ? DateTime.tryParse('${day}T00:00:00Z') : null;
  final progress = value['progress'];
  if (value.length != keys.length ||
      value.keys.any((k) => !keys.contains(k)) ||
      value['id'] is! String ||
      !id.hasMatch(value['id']) ||
      value['itemId'] is! String ||
      !id.hasMatch(value['itemId']) ||
      !['book', 'audiobook'].contains(value['mediaType']) ||
      day is! String ||
      !RegExp(r'^\d{4}-\d\d-\d\d$').hasMatch(day) ||
      date == null ||
      dayKey(date) != day ||
      !integer(value['durationMs'], 0, 86400000) ||
      progress is! num ||
      !progress.isFinite ||
      progress < 0 ||
      progress > 1000000000 ||
      !['characters', 'pages', 'minutes', 'unknown'].contains(value['unit']) ||
      !integer(value['mediaMs'], 0, 864000000) ||
      !instant(value['startedAt']) ||
      !instant(value['endedAt']) ||
      value['offsetMinutes'] != null &&
          !integer(value['offsetMinutes'], -840, 840) ||
      value['note'] is! String ||
      (value['note'] as String).length > 10000 ||
      ![
        'app-reader',
        'app-audio',
        'app-manual',
        'obsidian',
      ].contains(value['origin']) ||
      value['deleted'] is! bool) {
    return false;
  }
  return value['startedAt'] == null ||
      value['endedAt'] == null ||
      !DateTime.parse(value['endedAt'])
          .isBefore(DateTime.parse(value['startedAt']));
}

class ActivityStore {
  final Repository local;
  final String namespace;
  final LibraryRepository? catalog;
  ActivityStore(this.local, this.namespace, {this.catalog});
  bool validEntry(dynamic value) => validActivityValue(value);
  String get key => 'obsidian-activity:$namespace';
  Future<Map<String, dynamic>> state() async =>
      jsonDecode(await local.meta(key) ?? '{"version":1,"cursor":0,"slots":{}}')
          as Map<String, dynamic>;
  Future<T> mutate<T>(Future<T> Function(Map<String, dynamic>) action) =>
      local.db.transaction(() async {
        final data = await state();
        final result = await action(data);
        await local.setMeta(key, jsonEncode(data));
        return result;
      });
  Future<List<Map<String, dynamic>>> entries({String? itemId}) async {
    final data = await state();
    return [
      for (final slot in (data['slots'] as Map).values)
        if ((slot['value']['deleted'] != true || slot['conflict'] != null) &&
            (itemId == null || slot['value']['itemId'] == itemId))
          Map<String, dynamic>.from(slot),
    ]..sort(
      (a, b) => '${b['value']['day']}${b['value']['startedAt'] ?? ''}'
          .compareTo('${a['value']['day']}${a['value']['startedAt'] ?? ''}'),
    );
  }

  /// Foreign sessions are views of the canonical journal, never copied into the local timer logs.
  /// That keeps native intervals and their remote mirror from being counted twice.
  static Future<List<Map<String, dynamic>>> foreign(
    Repository local,
    String mediaType,
  ) async {
    final personal = await local.meta(personalLibraryKey) != null;
    final namespace = personal
        ? personalLibraryNamespace
        : await local.meta('obsidian-active-namespace');
    if (namespace == null || namespace.isEmpty) return [];
    final links = await LibraryRepository(
      local,
      namespace,
      storageKey: personal ? personalLibraryKey : null,
    ).entries();
    final rows = await ActivityStore(local, namespace).entries();
    // A native session may arrive both directly and through its Obsidian mirror.
    // Only the sources these slots name are looked up, by primary key, so the
    // cost follows the Obsidian journal rather than the whole listening history.
    final wanted = <String, Set<String>>{};
    for (final slot in rows) {
      final source = slot['source'];
      if (source is Map && source['kind'] is String && source['id'] != null) {
        (wanted[source['kind'] as String] ??= {}).add('${source['id']}');
      }
    }
    final native = <String>{};
    Future<void> lookup(String kind, String sql, String prefix) async {
      final ids = wanted[kind];
      if (ids == null || ids.isEmpty) return;
      for (final row
          in await local.db
              .customSelect(
                sql,
                variables: [
                  Variable(jsonEncode([...ids])),
                ],
              )
              .get()) {
        native.add('$kind:${row.read<String>('id').substring(prefix.length)}');
      }
    }

    await lookup(
      'manual',
      "SELECT id FROM records WHERE type='session' "
          'AND id IN (SELECT value FROM json_each(?))',
      '',
    );
    await lookup(
      'audio',
      "SELECT id FROM records WHERE type='audio_event' "
          'AND id IN (SELECT value FROM json_each(?))',
      '',
    );
    await lookup(
      'reader',
      'SELECT key AS id FROM metadata '
          "WHERE key IN (SELECT 'reading-session:'||value FROM json_each(?))",
      'reading-session:',
    );
    await lookup(
      'reader',
      'SELECT target AS id FROM peer_app_projection WHERE materialized=1 '
          "AND target IN (SELECT 'm:reading-session:'||value FROM json_each(?))",
      'm:reading-session:',
    );
    return [
      for (final slot in rows)
        if ((slot['source'] == null ||
                slot['source']['bookId'] !=
                    links[slot['value']['itemId']]?.sourceBookId) &&
            !native.contains(
              '${slot['source']?['kind']}:${slot['source']?['id']}',
            ) &&
            slot['value']['deleted'] != true &&
            slot['value']['mediaType'] == mediaType &&
            links[slot['value']['itemId']]?.sourceBookId != null)
          {
            ...Map<String, dynamic>.from(slot['value']),
            'bookId': links[slot['value']['itemId']]!.sourceBookId,
          },
    ];
  }

  static Future<List<Map<String, dynamic>>> foreignReading(
    Repository local,
  ) async => [
    for (final value in await foreign(local, 'book'))
      {
        'id': value['id'],
        'bookId': value['bookId'],
        'source': 'obsidian',
        'closed': true,
        'day': value['day'],
        'timeKnown': value['startedAt'] != null,
        'startedAt': value['startedAt'] ?? '${value['day']}T12:00:00.000Z',
        'spans': [
          {
            'start': value['startedAt'] ?? '${value['day']}T12:00:00.000Z',
            'end':
                value['endedAt'] ??
                DateTime.parse(
                      value['startedAt'] as String? ??
                          '${value['day']}T12:00:00.000Z',
                    )
                    .add(Duration(milliseconds: value['durationMs'] as int))
                    .toIso8601String(),
            'activeMs': value['durationMs'],
            'newChars': value['unit'] == 'characters' ? value['progress'] : 0,
            'localDay': value['day'],
            'offsetMinutes': value['offsetMinutes'],
          },
        ],
      },
  ];
  static Future<List<Map<String, dynamic>>> foreignAudio(
    Repository local,
  ) async => [
    for (final value in await foreign(local, 'audiobook'))
      {
        'kind': 'journal',
        'bookId': value['bookId'],
        'trackId': 'journal:${value['id']}',
        'at': value['startedAt'] ?? '${value['day']}T12:00:00.000Z',
        'timeKnown': value['startedAt'] != null,
        'localDay': value['day'],
        'offsetMinutes': value['offsetMinutes'] ?? 0,
        'wallMs': value['durationMs'],
        'mediaMs': value['mediaMs'],
        'positionMs': 0,
        'endMs': value['mediaMs'],
        'speed': 1,
      },
  ];

  static Map<String, dynamic> entry({
    required String id,
    required String itemId,
    required String mediaType,
    required String day,
    required int durationMs,
    required num progress,
    required String unit,
    int mediaMs = 0,
    DateTime? start,
    DateTime? end,
    int? offset,
    String note = '',
    required String origin,
    bool deleted = false,
  }) => {
    'id': id,
    'itemId': itemId,
    'mediaType': mediaType,
    'day': day,
    'durationMs': durationMs.clamp(0, 86400000),
    'progress': progress,
    'unit': unit,
    'mediaMs': mediaMs.clamp(0, 864000000),
    'startedAt': start?.toUtc().toIso8601String(),
    'endedAt': end?.toUtc().toIso8601String(),
    'offsetMinutes': offset,
    'note': note,
    'origin': origin,
    'deleted': deleted,
  };

  static String _manualBase(Map<String, dynamic> data) => jsonEncode([
    data['startedAt'],
    data['endedAt'],
    data['activeSeconds'],
    data['note'],
  ]);
  static List<Map<String, dynamic>> manualSpans(Map<String, dynamic> data) {
    if (data['activitySpans'] is List &&
        data['activitySpansBase'] == _manualBase(data)) {
      return List<Map<String, dynamic>>.from(data['activitySpans'] as List);
    }
    final start = DateTime.tryParse('${data['startedAt']}')?.toUtc(),
        end = DateTime.tryParse('${data['endedAt']}')?.toUtc();
    if (start == null || end == null || !end.isAfter(start)) return [];
    final offset =
        (data['offsetMinutes'] as num?)?.toInt() ??
        start.toLocal().timeZoneOffset.inMinutes;
    final total = ((data['activeSeconds'] as num?)?.toInt() ?? 0) * 1000,
        elapsed = end.difference(start).inMilliseconds;
    final result = <Map<String, dynamic>>[];
    var at = start, assigned = 0;
    while (at.isBefore(end)) {
      final date = at.add(Duration(minutes: offset)),
          midnight = DateTime.utc(
            date.year,
            date.month,
            date.day + 1,
          ).subtract(Duration(minutes: offset));
      final until = midnight.isBefore(end) ? midnight : end;
      final cumulative =
          (total * until.difference(start).inMilliseconds / elapsed).round();
      result.add({
        'start': at.toIso8601String(),
        'end': until.toIso8601String(),
        'activeMs': cumulative - assigned,
        'localDay': dayKey(date),
        'offsetMinutes': offset,
        'note': data['note'] ?? '',
      });
      assigned = cumulative;
      at = until;
    }
    return result;
  }

  /// Only explicitly linked books enter this journal. Local book files never upload.
  Future<void> capture() => local.db.transaction(() async {
    final links =
        (await (catalog ?? LibraryRepository(local, namespace)).entries())
            .values
            .where(
              (e) =>
                  e.sourceBookId != null &&
                  (catalog == null || isLibraryArchiveItem(e.item)) &&
                  e.state == 'synced' &&
                  !isLibraryDeleted(e.item),
            );
    final byBook = {for (final link in links) link.sourceBookId!: link.item};
    final values = <String, Map<String, dynamic>>{},
        sources = <String, Map<String, dynamic>>{};
    void add(
      String bookId,
      String kind,
      String sourceId,
      Map<String, dynamic> value, {
      int? span,
    }) {
      final item = byBook[bookId];
      if (item == null) return;
      final id = uuid.v5(
        item.id,
        '$kind:$sourceId${span == null ? '' : ':$span'}',
      );
      values[id] = {
        ...value,
        'id': id,
        'itemId': item.id,
        'mediaType': item.mediaType,
      };
      sources[id] = {
        'kind': kind,
        'id': sourceId,
        'bookId': bookId,
        'span': ?span,
      };
    }

    for (final session in (await ReadingLibrary(
      local,
    ).entries('reading-session:')).entries) {
      final data = session.value, book = data['bookId'] as String?;
      if (book == null || !byBook.containsKey(book)) continue;
      final spans = data['spans'] as List? ?? [];
      for (var i = 0; i < spans.length; i++) {
        final span = spans[i] as Map;
        final start = DateTime.tryParse('${span['start']}'),
            end = DateTime.tryParse('${span['end']}');
        if (start == null || end == null || end.isBefore(start)) continue;
        final duration =
            (span['activeMs'] as num?)?.toInt() ??
            end.difference(start).inMilliseconds;
        if (duration <= 0 && span['pepehubDeleted'] != true) continue;
        final offset =
            (span['offsetMinutes'] as num?)?.toInt() ??
            start.toLocal().timeZoneOffset.inMinutes;
        add(
          book,
          'reader',
          session.key,
          entry(
            id: '',
            itemId: '',
            mediaType: 'book',
            day:
                span['localDay'] as String? ??
                dayKey(start.toUtc().add(Duration(minutes: offset))),
            durationMs: duration,
            progress: (span['newChars'] as num?) ?? 0,
            unit: 'characters',
            start: start,
            end: end,
            offset: offset,
            origin: 'app-reader',
            note: span['note'] as String? ?? '',
            deleted: span['pepehubDeleted'] == true,
          ),
          span: i,
        );
      }
    }
    // Only linked books are journaled: their listening events come through the
    // per-book index and their (few) manual sessions through records_type,
    // instead of decoding every audio_event and session ever recorded.
    final linked = jsonEncode([...byBook.keys]);
    final rows = await local.db
        .customSelect(
          'SELECT * FROM records WHERE ${SchemaSql.audioEventRows} '
          'AND ${SchemaSql.audioEventBook} IN (SELECT value FROM json_each(?)) '
          "AND json_extract(payload,'\$.kind')='listen' "
          'UNION ALL '
          "SELECT * FROM records WHERE type='session' AND json_valid(payload) "
          "AND json_extract(payload,'\$.bookId') IN (SELECT value FROM json_each(?)) "
          "AND json_extract(payload,'\$.kind') IN ('reading','listening') "
          "AND json_extract(payload,'\$.source') IS NOT 'player'",
          variables: [Variable(linked), Variable(linked)],
        )
        .get();
    for (final row in rows) {
      final record = LibraryRecord.fromRow(row), data = record.payload;
      if (data == null) continue;
      final book = data['bookId'] as String?;
      if (book == null || !byBook.containsKey(book)) continue;
      if (record.type == 'audio_event') {
        if (data['kind'] != 'listen') continue;
        final start = DateTime.tryParse('${data['at']}');
        if (start == null) continue;
        final duration = (data['wallMs'] as num?)?.toInt() ?? 0,
            media = (data['mediaMs'] as num?)?.toInt() ?? 0;
        add(
          book,
          'audio',
          record.id,
          entry(
            id: '',
            itemId: '',
            mediaType: 'audiobook',
            day: data['localDay'] as String? ?? dayKey(start.toLocal()),
            durationMs: duration,
            progress: media / 60000,
            unit: 'minutes',
            mediaMs: media,
            start: start,
            end: start.add(Duration(milliseconds: duration)),
            offset: (data['offsetMinutes'] as num?)?.toInt(),
            origin: 'app-audio',
            note: data['note'] as String? ?? '',
            deleted: record.deleted,
          ),
        );
      } else {
        if (!['reading', 'listening'].contains(data['kind']) ||
            data['source'] == 'player') {
          continue; // Audio intervals already account for player sessions.
        }
        final spans = manualSpans(data);
        for (var index = 0; index < spans.length; index++) {
          final span = spans[index];
          add(
            book,
            'manual',
            record.id,
            entry(
              id: '',
              itemId: '',
              mediaType: data['kind'] == 'reading' ? 'book' : 'audiobook',
              day: span['localDay'] as String,
              durationMs: span['activeMs'] as int,
              progress: (span['progress'] as num?) ?? 0,
              unit: (span['unit'] as String?) ?? 'unknown',
              mediaMs: (span['mediaMs'] as num?)?.toInt() ?? 0,
              start: DateTime.parse(span['start'] as String),
              end: DateTime.parse(span['end'] as String),
              offset: span['offsetMinutes'] as int?,
              note: span['note'] as String? ?? '',
              origin: 'app-manual',
              deleted: record.deleted || span['pepehubDeleted'] == true,
            ),
            span: index,
          );
        }
      }
    }
    await mutate((state) async {
      final slots = state['slots'] as Map<String, dynamic>;
      for (final e in values.entries) {
        final slot = slots[e.key] as Map<String, dynamic>?;
        if (slot == null) {
          slots[e.key] = {
            'value': e.value,
            'synced': null,
            'revision': 0,
            'source': sources[e.key],
            'native': e.value,
          };
        } else {
          // A canonical edit is an overlay until it is safely written to its native source.
          if (!_equal.equals(slot['native'], e.value)) {
            slot['value'] = e.value;
            slot['native'] = e.value;
          }
          slot['source'] = sources[e.key];
        }
      }
      for (final slot in slots.values) {
        final source = slot['source'] as Map?;
        if (source != null &&
            byBook.containsKey(source['bookId']) &&
            !values.containsKey(slot['value']['id']) &&
            slot['value']['deleted'] != true) {
          slot['value'] = {...slot['value'] as Map, 'deleted': true};
          slot['native'] = slot['value'];
        }
      }
    });
  });

  void preparePending(Map<String, dynamic> state) {}

  Future<List<Map<String, dynamic>>> pending() => mutate((state) async {
    preparePending(state);
    final ops = <Map<String, dynamic>>[];
    for (final slot in (state['slots'] as Map).values) {
      if (slot['conflict'] != null) continue;
      if (slot['operation'] == null &&
          !_equal.equals(slot['value'], slot['synced'])) {
        slot['operation'] = {
          'operationId': uuid.v4(),
          'baseRevision': slot['revision'],
          'entry': jsonDecode(jsonEncode(slot['value'])),
        };
      }
      if (slot['operation'] != null) {
        ops.add(Map<String, dynamic>.from(slot['operation']));
      }
    }
    return ops;
  });
  Future<void> receipts(List<dynamic> receipts) => mutate((state) async {
    for (final receipt in receipts) {
      if (receipt is! Map ||
          !['applied', 'conflict'].contains(receipt['status']) ||
          receipt['record'] is! Map ||
          !validEntry(receipt['record']['entry']) ||
          receipt['record']['revision'] is! int ||
          receipt['record']['revision'] <= 0) {
        throw const FormatException(
          'Некорректное подтверждение журнала. Очередь сохранена.',
        );
      }
      final slot = (state['slots'] as Map).values
          .where(
            (s) => s['operation']?['operationId'] == receipt['operationId'],
          )
          .firstOrNull;
      if (slot == null) continue;
      final sent = slot['operation']['entry'] as Map;
      if (receipt['record']['entry']['id'] != sent['id'] ||
          receipt['record']['entry']['itemId'] != sent['itemId'] ||
          receipt['record']['entry']['mediaType'] != sent['mediaType']) {
        throw const FormatException(
          'Подтверждение относится к другой записи. Очередь сохранена.',
        );
      }
      if (receipt['status'] == 'conflict' &&
          !_equal.equals(slot['value'], receipt['record']['entry'])) {
        slot['conflict'] = receipt['record'];
      } else if (receipt['status'] == 'applied' ||
          receipt['status'] == 'conflict') {
        slot['synced'] = receipt['record']['entry'];
        slot['revision'] = receipt['record']['revision'];
        slot.remove('operation');
      }
    }
  });
  Future<void> receive(List<dynamic> records, int cursor) =>
      mutate((state) async {
        final slots = state['slots'] as Map<String, dynamic>;
        if (cursor < (state['cursor'] as int)) {
          throw const FormatException('Курсор журнала откатился.');
        }
        for (final record in records) {
          if (record is! Map ||
              !validEntry(record['entry']) ||
              record['revision'] is! int ||
              record['revision'] <= 0 ||
              record['sequence'] is! int ||
              record['sequence'] <= 0 ||
              record['sequence'] > cursor) {
            throw const FormatException(
              'Некорректная запись журнала. Курсор сохранён.',
            );
          }
        }
        for (final record in records) {
          final value = Map<String, dynamic>.from(record['entry']),
              id = value['id'] as String;
          final slot = slots[id] as Map<String, dynamic>?;
          if (slot != null &&
              (record['revision'] as int) <= (slot['revision'] as int)) {
            continue;
          }
          if (slot != null &&
              !_equal.equals(slot['value'], slot['synced']) &&
              !_equal.equals(slot['value'], value)) {
            slot['conflict'] = record;
            continue;
          }
          if (slot != null && !await _applyNative(slot, value)) {
            slot['conflict'] = record;
            continue;
          }
          final next = {
            ...?slot,
            'value': value,
            'synced': value,
            'revision': record['revision'],
            if (slot?['source'] != null) 'native': value,
          };
          next.remove('operation');
          next.remove('conflict');
          slots[id] = next;
        }
        state['cursor'] = cursor;
      });
  Future<bool> _applyNative(
    Map<String, dynamic> slot,
    Map<String, dynamic> next,
  ) async {
    final source = slot['source'] as Map?;
    if (source == null) return true;
    final linked =
        (await (catalog ?? LibraryRepository(local, namespace))
                .entries())[next['itemId']]
            ?.sourceBookId;
    if (linked != source['bookId']) {
      slot.remove('source');
      slot.remove('native');
      return true;
    }
    final previous = slot['native'] as Map;
    if (_equal.equals(previous, next)) return true;
    if (source['kind'] == 'reader') {
      final key = 'reading-session:${source['id']}',
          data = await ReadingLibrary(local).value(key),
          spans = data['spans'] as List? ?? [],
          index = source['span'] as int;
      if (index >= spans.length || data['closed'] == false) return false;
      final span = Map<String, dynamic>.from(spans[index]),
          start = DateTime.tryParse('${span['start']}'),
          end = DateTime.tryParse('${span['end']}');
      final currentMs =
          (span['activeMs'] as num?)?.toInt() ??
          (start != null && end != null
              ? end.difference(start).inMilliseconds
              : 0);
      if (currentMs != previous['durationMs'] ||
          (span['newChars'] ?? 0) != previous['progress'] ||
          (span['note'] ?? '') != previous['note'] ||
          start?.toUtc().toIso8601String() != previous['startedAt'] ||
          end?.toUtc().toIso8601String() != previous['endedAt']) {
        return false;
      }
      spans[index] = {
        ...span,
        'activeMs': next['durationMs'],
        'newChars': next['progress'],
        'note': next['note'],
        'offsetMinutes': next['offsetMinutes'],
        'pepehubDeleted': next['deleted'],
        'localDay': next['day'],
        if (next['startedAt'] != null) 'start': next['startedAt'],
        if (next['endedAt'] != null) 'end': next['endedAt'],
      };
      await local.setMeta(key, jsonEncode({...data, 'spans': spans}));
    } else {
      final row = await local.record(source['id'] as String);
      if (row?.payload == null) return false;
      final data = {...row!.payload!};
      if (source['kind'] == 'manual') {
        final spans = manualSpans(data), index = source['span'] as int;
        if (index >= spans.length) return false;
        final span = spans[index];
        if (span['activeMs'] != previous['durationMs'] ||
            span['note'] != previous['note'] ||
            DateTime.parse(span['start'] as String).toUtc().toIso8601String() !=
                previous['startedAt']) {
          return false;
        }
        spans[index] = {
          ...span,
          'activeMs': next['durationMs'],
          'progress': next['progress'],
          'unit': next['unit'],
          'mediaMs': next['mediaMs'],
          'note': next['note'],
          'localDay': next['day'],
          'pepehubDeleted': next['deleted'],
          if (next['startedAt'] != null) 'start': next['startedAt'],
          if (next['endedAt'] != null) 'end': next['endedAt'],
        };
        data['activeSeconds'] =
            (spans
                        .where((s) => s['pepehubDeleted'] != true)
                        .fold<int>(
                          0,
                          (total, s) => total + (s['activeMs'] as int),
                        ) /
                    1000)
                .round();
        data['activitySpans'] = spans;
        data['activitySpansBase'] = _manualBase(data);
      } else {
        if (data['wallMs'] != previous['durationMs'] ||
            data['mediaMs'] != previous['mediaMs'] ||
            row.deleted != (previous['deleted'] == true) ||
            (data['note'] ?? '') != previous['note'] ||
            DateTime.tryParse('${data['at']}')?.toUtc().toIso8601String() !=
                previous['startedAt'] ||
            data['localDay'] != previous['day']) {
          return false;
        }
        data['wallMs'] = next['durationMs'];
        data['mediaMs'] = next['mediaMs'];
        data['endMs'] =
            ((data['positionMs'] as num?)?.toInt() ?? 0) +
            (next['mediaMs'] as int);
        data['localDay'] = next['day'];
        data['note'] = next['note'];
        data['offsetMinutes'] = next['offsetMinutes'];
        if (next['startedAt'] != null) data['at'] = next['startedAt'];
      }
      final deleted = source['kind'] == 'manual'
          ? (data['activitySpans'] as List).every(
              (s) => s['pepehubDeleted'] == true,
            )
          : next['deleted'] == true;
      await local.db.customStatement(
        'UPDATE records SET payload=?,deleted=?,revision=revision+1 WHERE id=?',
        [jsonEncode(data), deleted ? 1 : 0, row.id],
      );
    }
    return true;
  }

  Future<void> edit(String id, Map<String, dynamic> next) =>
      mutate((state) async {
        final slot = state['slots'][id] as Map<String, dynamic>;
        if (!validEntry(next) ||
            next['id'] != id ||
            next['itemId'] != slot['value']['itemId'] ||
            next['mediaType'] != slot['value']['mediaType']) {
          throw const FormatException('Некорректная правка записи журнала.');
        }
        if (slot['conflict'] != null) {
          throw StateError('Сначала разрешите конфликт журнала.');
        }
        if (!await _applyNative(slot, next)) {
          throw StateError(
            'Сессия изменилась. Синхронизируйте журнал и повторите правку.',
          );
        }
        slot['value'] = next;
        if (slot['source'] != null) slot['native'] = next;
      });
  Future<void> resolve(String id, {required bool useRemote}) => mutate((
    state,
  ) async {
    final slot = state['slots'][id] as Map<String, dynamic>,
        remote = slot['conflict'] as Map?;
    if (remote == null) return;
    final value = Map<String, dynamic>.from(remote['entry']);
    if (useRemote) {
      if (!await _applyNative(slot, value)) {
        throw StateError(
          'Локальная сессия изменилась. Обновите журнал перед выбором версии.',
        );
      }
      slot['value'] = value;
      if (slot['source'] != null) slot['native'] = value;
    }
    slot['synced'] = value;
    slot['revision'] = remote['revision'];
    slot.remove('operation');
    slot.remove('conflict');
  });
}
