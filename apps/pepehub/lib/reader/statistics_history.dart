import 'dart:convert';
import 'dart:isolate';

import 'package:drift/drift.dart' show Variable;

import '../data/database_schema.dart';
import '../data/repository.dart';

class StatisticsHistoryRow {
  final String id, source;
  final Map<String, dynamic> data;
  StatisticsHistoryRow(this.id, this.source, this.data);
}

class StatisticsHistoryPage {
  final List<StatisticsHistoryRow> rows;
  final bool hasMore;
  StatisticsHistoryPage(this.rows, this.hasMore);
}

/// The list reads at most one page of payloads. A text search scans only small
/// headers, in an isolate, to preserve Unicode and local-date search semantics.
class StatisticsHistory {
  final Repository repository;
  StatisticsHistory(this.repository);
  Future<StatisticsHistoryPage> page({
    required bool reading,
    required Map<String, String> titles,
    String? bookId,
    String filter = 'all',
    int days = 0,
    bool newest = true,
    String search = '',
    int offset = 0,
    int limit = 100,
  }) async {
    final headers = <Map<String, dynamic>>[];
    final query = search.trim().toLowerCase();
    final cutoff = days <= 0
        ? null
        : DateTime.now().subtract(Duration(days: days)).millisecondsSinceEpoch;
    for (final source
        in reading ? ['automatic', 'manual'] : ['audio', 'legacy']) {
      if (reading && filter != 'all' && filter != source ||
          !reading && filter == 'legacy' && source != 'legacy' ||
          !reading &&
              !['all', 'legacy'].contains(filter) &&
              source == 'legacy') {
        continue;
      }
      final automatic = source == 'automatic', audio = source == 'audio';
      // Without a book filter SQLite may prefer records_type and sort the
      // entire history. The time index can stop after the requested page.
      final table = automatic
          ? 'reading_statistics_sessions_v1'
          : audio && bookId == null
          ? 'records INDEXED BY audio_event_time_v1'
          : 'records';
      final json = automatic ? 'value' : 'payload';
      final id = automatic ? 'session_id' : 'id';
      final at = automatic
          ? 'started_at'
          : "json_extract($json,'\$.${audio ? 'at' : 'startedAt'}')";
      final stamp = automatic
          ? 'start_ms'
          : audio
          ? SchemaSql.audioEventAt
          : "COALESCE(CAST(ROUND(unixepoch($at,'subsec')*1000) AS INTEGER),0)";
      final book = automatic ? 'book_id' : "json_extract($json,'\$.bookId')";
      final kind = audio ? "json_extract(payload,'\$.kind')" : "'$source'";
      final where = [
        if (!automatic)
          audio
              ? '${SchemaSql.audioEventRows} AND deleted=0'
              : "type='session' AND deleted=0 AND json_valid(payload) AND json_extract(payload,'\$.kind')='${reading ? 'reading' : 'listening'}'",
        if (bookId != null) '$book=?',
        if (cutoff != null) '$stamp>=?',
        if (audio && filter == 'listen')
          "json_extract(payload,'\$.kind')='listen'",
        if (audio && filter == 'events')
          "json_extract(payload,'\$.kind')!='listen'",
      ];
      final rows = await repository.db
          .customSelect(
            "SELECT $id AS id,'$source' AS source,$book AS bookId,$at AS at,$stamp AS stamp,$kind AS kind FROM $table "
            "${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'} ORDER BY stamp ${newest ? 'DESC' : 'ASC'},id ${newest ? 'DESC' : 'ASC'} ${query.isEmpty ? 'LIMIT ?' : ''}",
            variables: [
              if (bookId != null) Variable(bookId),
              if (cutoff != null) Variable(cutoff),
              if (query.isEmpty) Variable(offset + limit + 1),
            ],
          )
          .get();
      headers.addAll(rows.map((row) => row.data));
    }
    final selected = await Isolate.run(() {
      final matches =
          headers.where((row) {
            if (query.isEmpty) return true;
            final at = DateTime.tryParse('${row['at']}')?.toLocal();
            final date = at == null
                ? 'дата не указана'
                : '${at.year.toString().padLeft(4, '0')}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')} ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
            final label = row['source'] == 'automatic'
                ? 'автоматическая сессия'
                : row['source'] == 'manual'
                ? 'ручная сессия'
                : row['source'] == 'legacy'
                ? 'старая сессия'
                : historyEventName('${row['kind']}');
            return '${titles[row['bookId']] ?? ''} $label $date ${row['bookId'] ?? ''}'
                .toLowerCase()
                .contains(query);
          }).toList()..sort((a, b) {
            final order = ((a['stamp'] as num?) ?? 0).compareTo(
              (b['stamp'] as num?) ?? 0,
            );
            final tie = order != 0
                ? order
                : '${a['id']}'.compareTo('${b['id']}');
            return newest ? -tie : tie;
          });
      return matches.skip(offset).take(limit + 1).toList();
    });
    final raw = <(String, String, String)>[];
    for (final source in ['automatic', 'manual', 'audio', 'legacy']) {
      final ids = selected
          .take(limit)
          .where((r) => r['source'] == source)
          .map((r) => r['id'] as String)
          .toList();
      if (ids.isEmpty) continue;
      final automatic = source == 'automatic';
      final records = await repository.db
          .customSelect(
            automatic
                ? 'SELECT substr(key,17) AS id,value AS payload FROM reading_statistics_sessions_v1 WHERE key IN (${List.filled(ids.length, '?').join(',')})'
                : 'SELECT id,payload FROM records WHERE deleted=0 AND id IN (${List.filled(ids.length, '?').join(',')})',
            variables: [
              for (final id in ids)
                Variable(automatic ? 'reading-session:$id' : id),
            ],
          )
          .get();
      raw.addAll(
        records.map(
          (r) => (source, r.read<String>('id'), r.read<String>('payload')),
        ),
      );
    }
    final decoded = await Isolate.run(
      () => {
        for (final (source, id, payload) in raw)
          '$source:$id': StatisticsHistoryRow(
            id,
            source,
            jsonDecode(payload) as Map<String, dynamic>,
          ),
      },
    );
    return StatisticsHistoryPage([
      for (final row in selected.take(limit))
        ?decoded['${row['source']}:${row['id']}'],
    ], selected.length > limit);
  }
}

String historyEventName(String kind) =>
    const {
      'listen': 'Прослушивание',
      'chapter_completed': 'Завершена глава',
      'play': 'Воспроизведение',
      'pause': 'Пауза',
      'stop': 'Остановка',
      'seek': 'Перемотка',
      'speed': 'Скорость',
      'bookmark': 'Закладка',
      'sleep_set': 'Таймер установлен',
      'sleep_fired': 'Таймер сработал',
      'sleep_extended': 'Таймер продлён',
      'sleep_cancelled': 'Таймер отменён',
      'completed': 'Конец книги',
      'track_changed': 'Смена трека',
      'buffering': 'Буферизация',
      'error': 'Ошибка',
    }[kind] ??
    kind;
