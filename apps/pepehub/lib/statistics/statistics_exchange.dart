import 'dart:convert';
import 'dart:isolate';

import 'package:drift/drift.dart' show Variable;

import '../data/repository.dart';
import '../library/activity_store.dart';
import '../library/library_repository.dart';
import '../library/models.dart';
import '../library/personal_library.dart';
import '../library/library_dates.dart';
import '../library/library_features.dart';
import 'portable_history.dart';
import '../notifications/reminder_scheduler.dart';

Future<String> _encodeStatistics(Map<String, dynamic> data) => Isolate.run(() {
  if ((data['metadata'] as Map).length +
          (data['records'] as List).length +
          (data['activity'] as Map).length >
      200000) {
    throw const FormatException('Экспорт содержит больше 200000 записей');
  }
  final raw = const JsonEncoder.withIndent('  ').convert(data);
  if (utf8.encode(raw).length > 64 * 1024 * 1024) {
    throw const FormatException('Экспорт больше 64 МиБ');
  }
  return raw;
});

Future<Map<String, dynamic>> _decodeStatisticsInBackground(String raw) =>
    Isolate.run(() => _decodeStatistics(raw));

Future<Map<String, dynamic>> _validateStatisticsInBackground(
  Map<String, dynamic> input,
) => Isolate.run(() => _decodeStatistics(jsonEncode(input)));

bool _sameJson(String a, String b) {
  if (a == b) return true;
  try {
    return sameMetadataValue(jsonDecode(a), jsonDecode(b));
  } on FormatException {
    return false;
  }
}

bool _allowedKey(String key) =>
    key.startsWith('reading-session:') ||
    key.startsWith('reading-plan:') ||
    key.startsWith('obsidian-auto:personal:') ||
    key.startsWith('library-year-goal:personal:') ||
    ['reading-daily-goal', 'audio-listening-goals'].contains(key);
Map<String, dynamic> _decodeStatistics(String raw) {
  if (utf8.encode(raw).length > 64 * 1024 * 1024) {
    throw const FormatException('Файл больше 64 МиБ');
  }
  final data = jsonDecode(raw);
  if (data is! Map<String, dynamic> ||
      data['format'] != 'pepehub-complete-statistics' ||
      data['version'] != 1 ||
      data['metadata'] is! Map ||
      data['records'] is! List ||
      data['activity'] is! Map ||
      data['works'] is! Map ||
      data['books'] is! Map) {
    throw const FormatException(
      'Нужен единый экспорт статистики PepeHub версии 1',
    );
  }
  if ((data['metadata'] as Map).length +
          (data['records'] as List).length +
          (data['activity'] as Map).length >
      200000) {
    throw const FormatException('Слишком много записей');
  }
  bool id(dynamic value) =>
      value is String && value.isNotEmpty && value.length <= 512;
  bool integer(dynamic value) =>
      value is int && value >= 0 && value <= 864000000;
  bool day(dynamic value) =>
      value is String &&
      RegExp(r'^\d{4}-\d\d-\d\d$').hasMatch(value) &&
      libraryDate(value) != null;
  void offset(Map value) {
    final minutes = value['offsetMinutes'];
    if (minutes != null &&
        (minutes is! int || minutes < -1440 || minutes > 1440)) {
      throw const FormatException('Некорректный часовой пояс');
    }
  }

  void spans(dynamic values) {
    if (values is! List) throw const FormatException('Нет интервалов');
    for (final span in values) {
      if (span is! Map) throw const FormatException('Некорректный интервал');
      final start = DateTime.tryParse('${span['start']}'),
          end = DateTime.tryParse('${span['end']}');
      if (start == null ||
          end == null ||
          end.isBefore(start) ||
          (span['activeMs'] != null && !integer(span['activeMs'])) ||
          (span['localDay'] != null && !day(span['localDay']))) {
        throw const FormatException('Некорректное время сессии');
      }
      offset(span);
      for (final key in ['newChars', 'repeatChars']) {
        final v = span[key];
        if (v != null && (v is! num || !v.isFinite || v < 0)) {
          throw const FormatException('Некорректное продвижение');
        }
      }
    }
  }

  for (final e in (data['metadata'] as Map).entries) {
    if (e.key is! String || !_allowedKey(e.key) || e.value is! String) {
      throw const FormatException('Недопустимый ключ статистики');
    }
    if ((e.key as String).startsWith('reading-session:')) {
      final s = jsonDecode(e.value as String);
      if (s is! Map ||
          !id(s['bookId']) ||
          s['spans'] is! List ||
          DateTime.tryParse('${s['startedAt']}') == null) {
        throw const FormatException('Некорректная сессия');
      }
      spans(s['spans']);
      for (final field in ['id', 'sessionGroup', 'note']) {
        if (s[field] != null && s[field] is! String) {
          throw const FormatException('Некорректные поля сессии');
        }
      }
      if (s['endedAt'] != null &&
          DateTime.tryParse('${s['endedAt']}') == null) {
        throw const FormatException('Некорректное завершение сессии');
      }
    } else if ((e.key as String).startsWith('obsidian-auto:personal:')) {
      if (jsonDecode(e.value as String) is! Map) {
        throw const FormatException('Некорректная база автоматических полей');
      }
    } else if ((e.key as String).startsWith('reading-plan:')) {
      final plan = jsonDecode(e.value as String);
      if (plan is! Map ||
          plan['dailyMinutes'] is! int ||
          plan['dailyMinutes'] < 1 ||
          plan['dailyMinutes'] > 1440 ||
          plan['targetPercent'] is! int ||
          plan['targetPercent'] < 1 ||
          plan['targetPercent'] > 100) {
        throw const FormatException('Некорректный план');
      }
    } else if (e.key == 'audio-listening-goals') {
      final goal = jsonDecode(e.value as String);
      if (goal is! Map ||
          !integer(goal['dailyMinutes']) ||
          goal['dailyMinutes'] > 1440 ||
          !integer(goal['weeklyMinutes']) ||
          goal['weeklyMinutes'] > 10080) {
        throw const FormatException('Некорректная цель');
      }
    } else if ((int.tryParse(e.value as String) ?? -1) < 0 ||
        (int.tryParse(e.value as String) ?? 10001) >
            (e.key == 'reading-daily-goal' ? 1440 : 10000)) {
      throw const FormatException('Некорректная цель');
    }
  }
  final recordIds = <String>{};
  for (final row in data['records']) {
    if (row is! Map ||
        !id(row['id']) ||
        !recordIds.add(row['id']) ||
        !['audio_event', 'session'].contains(row['type']) ||
        row['deleted'] is! bool) {
      throw const FormatException('Некорректная запись');
    }
    final p = row['payload'];
    if (p == null && row['deleted'] == true) continue;
    if (p is! Map || !id(p['bookId'])) {
      throw const FormatException('Нет произведения записи');
    }
    offset(p);
    if (p['note'] != null && p['note'] is! String) {
      throw const FormatException('Некорректная заметка');
    }
    if (row['type'] == 'session') {
      final start = DateTime.tryParse('${p['startedAt']}'),
          end = DateTime.tryParse('${p['endedAt']}');
      if (!['reading', 'listening'].contains(p['kind']) ||
          start == null ||
          end == null ||
          end.isBefore(start) ||
          !integer(p['activeSeconds'])) {
        throw const FormatException('Некорректная ручная сессия');
      }
      if (p['activitySpans'] != null) spans(p['activitySpans']);
    } else if (DateTime.tryParse('${p['at']}') == null ||
        p['kind'] is! String ||
        p['trackId'] is! String ||
        (p['wallMs'] != null && !integer(p['wallMs'])) ||
        (p['localDay'] != null && !day(p['localDay']))) {
      throw const FormatException('Некорректное событие аудио');
    }
    if (row['type'] == 'audio_event') {
      for (final field in [
        'wallMs',
        'mediaMs',
        'positionMs',
        'endMs',
        'fromMs',
      ]) {
        if (p[field] != null && !integer(p[field])) {
          throw const FormatException('Некорректная позиция аудио');
        }
      }
      if (p['speed'] != null &&
          (p['speed'] is! num ||
              !(p['speed'] as num).isFinite ||
              p['speed'] <= 0 ||
              p['speed'] > 32)) {
        throw const FormatException('Некорректная скорость аудио');
      }
      if (p['kind'] == 'seek' &&
          p['fromMs'] != null &&
          !integer(p['positionMs'])) {
        throw const FormatException('Нет позиции перехода');
      }
      if (['listen', 'journal'].contains(p['kind']) &&
          (!integer(p['wallMs']) ||
              !integer(p['positionMs']) ||
              !integer(p['endMs']) ||
              !day(p['localDay']))) {
        throw const FormatException('Неполный интервал прослушивания');
      }
    }
  }
  for (final e in (data['activity'] as Map).entries) {
    if (e.value is! Map ||
        !validActivityValue(e.value['value']) ||
        e.key != e.value['value']['id'] ||
        !id(e.value['bookId']) ||
        e.value['title'] is! String ||
        (e.value['counted'] != null && e.value['counted'] is! bool) ||
        (e.value['source'] != null && e.value['source'] is! Map)) {
      throw const FormatException('Некорректный журнал');
    }
  }
  for (final e in (data['works'] as Map).entries) {
    final work = LibraryEntry.fromJson(
      Map<String, dynamic>.from(e.value as Map),
    );
    if (e.key != work.item.id ||
        !['book', 'audiobook'].contains(work.item.mediaType)) {
      throw const FormatException('Некорректное описание произведения');
    }
  }
  for (final e in (data['books'] as Map).entries) {
    if (!id(e.key) ||
        e.value is! Map ||
        e.value['title'] is! String ||
        (e.value['hash'] != null &&
            (e.value['hash'] is! String ||
                !RegExp(r'^[a-f0-9]{64}$').hasMatch(e.value['hash'])))) {
      throw const FormatException('Некорректный источник');
    }
  }
  final tracks = data['tracks'] ?? <String, dynamic>{};
  if (tracks is! Map ||
      tracks.entries.any(
        (e) =>
            !id(e.key) ||
            e.value is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(e.value),
      )) {
    throw const FormatException('Некорректные аудиотреки');
  }
  data['tracks'] = tracks;
  return data;
}

class StatisticsImportResult {
  final int added, unchanged, conflicts;
  const StatisticsImportResult(this.added, this.unchanged, this.conflicts);
  @override
  String toString() =>
      'Новых: $added · уже есть: $unchanged · конфликтов: $conflicts';
}

class StatisticsExchange {
  final Repository repository;
  StatisticsExchange(this.repository);
  Future<String> exportJson() async {
    final data = await repository.db.transaction(() async {
      final metadata = await repository.metadataPrefixes([
        'reading-session:',
        'reading-plan:',
        'obsidian-auto:personal:',
        'library-year-goal:personal:',
      ]);
      for (final key in ['reading-daily-goal', 'audio-listening-goals']) {
        final value = await repository.meta(key);
        if (value != null) metadata[key] = value;
      }
      final portable = await portableStatistics(repository);
      final catalog = await LibraryRepository(
        repository,
        personalLibraryNamespace,
        storageKey: personalLibraryKey,
      ).entries();
      final activity = Map<String, dynamic>.from(portable['activity'] as Map);
      for (final slot
          in ((await ActivityStore(
                    repository,
                    personalLibraryNamespace,
                  ).state())['slots']
                  as Map)
              .values) {
        final value = slot['value'] as Map, entry = catalog[value['itemId']];
        activity['${value['id']}'] = {
          'value': value,
          'source': slot['source'],
          'bookId': entry?.sourceBookId ?? 'card:${value['itemId']}',
          'title': entry?.item.title ?? 'Произведение без названия',
          'counted': entry?.sourceBookId != null
              ? slot['source'] == null ||
                    slot['source']['bookId'] != entry!.sourceBookId
              : entry != null &&
                    isLibraryArchiveItem(entry.item) &&
                    !isLibraryDeleted(entry.item),
        };
      }
      final books = Map<String, dynamic>.from(portable['books'] as Map);
      for (final row
          in await repository.db
              .customSelect(
                "SELECT b.id,json_extract(b.payload,'\$.title') AS title,MIN(a.sha256) AS hash FROM records b LEFT JOIN local_assets a ON a.book_id=b.id "
                "WHERE b.type='book' AND json_valid(b.payload) AND json_type(b.payload)='object' GROUP BY b.id",
              )
              .get()) {
        books[row.read<String>('id')] = {
          'title': row.readNullable<String>('title') ?? '',
          'hash': row.readNullable<String>('hash'),
        };
      }
      return <String, dynamic>{
        'format': 'pepehub-complete-statistics',
        'version': 1,
        'exportedAt': DateTime.now().toUtc().toIso8601String(),
        'metadata': metadata,
        'books': books,
        'tracks': {
          ...portable['tracks'] as Map,
          for (final row
              in await repository.db
                  .customSelect(
                    'SELECT id,sha256 AS hash FROM local_assets UNION ALL SELECT id,asset_hash AS hash FROM audio_tracks',
                  )
                  .get())
            row.read<String>('id'): row.read<String>('hash'),
        },
        'activity': activity,
        'works': {
          ...portable['works'] as Map,
          for (final e in catalog.entries) e.key: e.value.toJson(),
        },
        'records': [
          for (final row
              in await repository.db
                  .customSelect(
                    "SELECT * FROM records WHERE type='audio_event' OR (type='session' AND (deleted=1 OR (json_valid(payload) AND json_extract(payload,'\$.kind') IN ('reading','listening'))))",
                  )
                  .get())
            {
              'id': row.read<String>('id'),
              'type': row.read<String>('type'),
              'deleted': row.read<int>('deleted') != 0,
              'payload': jsonDecode(row.read<String>('payload')),
            },
        ],
      };
    });
    return _encodeStatistics(data);
  }

  Future<Map<String, dynamic>> decode(String raw) =>
      _decodeStatisticsInBackground(raw);
  Future<StatisticsImportResult> importData(
    Map<String, dynamic> input, {
    bool apply = false,
  }) async {
    // Validate even when called directly instead of through the file picker.
    final data = await _validateStatisticsInBackground(input);
    final result = await repository.db.transaction(() async {
      var added = 0, unchanged = 0, conflicts = 0;
      // Match hashes in batches; a large catalog must not issue one query per file.
      final aliases = {
        for (final row
            in await repository.db
                .customSelect(
                  "SELECT j.key AS source,MIN(a.book_id) AS target FROM json_each(?) j "
                  "JOIN local_assets a ON a.sha256=json_extract(j.value,'\$.hash') GROUP BY j.key",
                  variables: [Variable(jsonEncode(data['books']))],
                )
                .get())
          row.read<String>('source'): row.read<String>('target'),
      };
      String book(dynamic id) => aliases['$id'] ?? '$id';
      final trackAliases = {
        for (final row
            in await repository.db
                .customSelect(
                  'SELECT j.key AS source,COALESCE(MIN(t.id),MIN(a.id)) AS target FROM json_each(?) j '
                  'LEFT JOIN audio_tracks t ON t.asset_hash=j.value LEFT JOIN local_assets a ON a.sha256=j.value '
                  'WHERE t.id IS NOT NULL OR a.id IS NOT NULL GROUP BY j.key',
                  variables: [Variable(jsonEncode(data['tracks']))],
                )
                .get())
          row.read<String>('source'): row.read<String>('target'),
      };
      for (final e in (data['metadata'] as Map).entries) {
        var key = e.key as String, value = e.value as String;
        if (key.startsWith('reading-session:')) {
          final session = jsonDecode(value) as Map;
          session['bookId'] = book(session['bookId']);
          value = jsonEncode(session);
        } else if (key.startsWith('reading-plan:')) {
          key = 'reading-plan:${book(key.substring(13))}';
        }
        final old = await repository.meta(key);
        final same = old != null && _sameJson(old, value);
        if (old == null) {
          added++;
          if (apply) await repository.setMeta(key, value);
        } else if (same) {
          unchanged++;
        } else {
          conflicts++;
        }
      }
      for (final raw in data['records']) {
        final row = Map<String, dynamic>.from(raw as Map);
        final payload = row['payload'] == null
            ? null
            : Map<String, dynamic>.from(row['payload'] as Map);
        if (payload != null) payload['bookId'] = book(payload['bookId']);
        if (payload != null && row['type'] == 'audio_event') {
          for (final field in ['trackId', 'fromTrackId']) {
            if (trackAliases.containsKey(payload[field])) {
              payload[field] = trackAliases[payload[field]];
            }
          }
        }
        final old = await repository.record(row['id'] as String);
        if (old == null) {
          added++;
          if (apply) {
            await repository.db.customStatement(
              'INSERT INTO records VALUES(?,?,1,?,?)',
              [
                row['id'],
                row['type'],
                row['deleted'] == true ? 1 : 0,
                jsonEncode(payload),
              ],
            );
          }
        } else if (old.type == row['type'] &&
            old.deleted == row['deleted'] &&
            sameMetadataValue(old.payload, payload)) {
          unchanged++;
        } else {
          conflicts++;
        }
      }
      final portable = await portableStatistics(repository);
      final savedTracks = portable['tracks'] as Map;
      for (final e in (data['tracks'] as Map).entries) {
        final key = trackAliases[e.key] ?? e.key;
        if (!savedTracks.containsKey(key)) {
          added++;
          if (apply) savedTracks[key] = e.value;
        } else if (savedTracks[key] == e.value) {
          unchanged++;
        } else {
          conflicts++;
        }
      }
      for (final section in ['activity', 'works', 'books']) {
        final saved = portable[section] as Map;
        for (final e in (data[section] as Map).entries) {
          final value = Map<String, dynamic>.from(e.value as Map);
          final key = section == 'books' ? book(e.key) : e.key;
          if (section == 'activity') {
            value['bookId'] = book(value['bookId']);
          } else if (value['sourceBookId'] != null) {
            value['sourceBookId'] = book(value['sourceBookId']);
          }
          if (!saved.containsKey(key)) {
            added++;
            if (apply) saved[key] = value;
          } else if (sameMetadataValue(saved[key], value)) {
            unchanged++;
          } else {
            conflicts++;
          }
        }
      }
      if (apply) {
        await repository.setMeta(portableStatisticsKey, jsonEncode(portable));
      }
      return StatisticsImportResult(added, unchanged, conflicts);
    });
    if (apply) {
      repository.notifyExternalChange();
      await ReminderScheduler.restore(repository);
    }
    return result;
  }
}
