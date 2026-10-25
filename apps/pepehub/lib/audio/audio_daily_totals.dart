import 'package:drift/drift.dart';

import '../data/repository.dart';

class AudioDailyTotals {
  final Map<String, int> days, books;
  const AudioDailyTotals(this.days, this.books);
}

/// Rebuildable read model. SQLite triggers cover native recording, edits,
/// tombstones, restores and peer/Obsidian writes through the same transaction.
class AudioDailyStore {
  final Repository repository;
  AudioDailyStore(this.repository);
  static final _ready = Expando<Future<void>>();
  static const _at =
      "CAST(ROUND(unixepoch(json_extract(payload,'\$.at'),'subsec')*1000) AS INTEGER)";
  static const _end =
      "($_at+COALESCE(CAST(json_extract(payload,'\$.wallMs') AS INTEGER),0))";
  static String _j(String row, String field) =>
      "json_extract(CASE WHEN json_valid(${row}payload) THEN ${row}payload ELSE '{}' END,'\$.$field')";
  static String _valid(String row) =>
      "${row}type='audio_event' AND ${row}deleted=0 AND "
      "${_j(row, 'kind')} IN ('listen','journal') AND ${_j(row, 'wallMs')}>0 AND "
      "typeof(${_j(row, 'bookId')})='text' AND typeof(${_j(row, 'localDay')})='text' AND "
      "(${_j(row, 'kind')}='journal' OR ${_j(row, 'endMs')}>${_j(row, 'positionMs')})";

  Future<void>
  ensure() => _ready[repository.db] ??= repository.db.transaction(() async {
    final existed = await repository.db
        .customSelect(
          "SELECT 1 FROM sqlite_master WHERE type='table' AND name='audio_daily_totals_v1'",
        )
        .getSingleOrNull();
    await repository.db.customStatement(
      'CREATE TABLE IF NOT EXISTS audio_daily_totals_v1 '
      '(day TEXT NOT NULL,book_id TEXT NOT NULL,wall_ms INTEGER NOT NULL,PRIMARY KEY(day,book_id))',
    );
    String add(String row) =>
        'INSERT INTO audio_daily_totals_v1(day,book_id,wall_ms) '
        "SELECT ${_j(row, 'localDay')},${_j(row, 'bookId')},CAST(${_j(row, 'wallMs')} AS INTEGER) "
        'WHERE ${_valid(row)} '
        'ON CONFLICT(day,book_id) DO UPDATE SET wall_ms=wall_ms+excluded.wall_ms;';
    String subtract(String row) =>
        'UPDATE audio_daily_totals_v1 SET wall_ms=wall_ms-CAST(${_j(row, 'wallMs')} AS INTEGER) '
        "WHERE day=${_j(row, 'localDay')} AND book_id=${_j(row, 'bookId')} AND ${_valid(row)};"
        'DELETE FROM audio_daily_totals_v1 WHERE wall_ms<=0 '
        "AND day=${_j(row, 'localDay')} AND book_id=${_j(row, 'bookId')};";
    for (final entry in {
      'insert':
          "AFTER INSERT ON records WHEN NEW.type='audio_event' BEGIN ${add('NEW.')} END",
      'delete':
          "AFTER DELETE ON records WHEN OLD.type='audio_event' BEGIN ${subtract('OLD.')} END",
      'update':
          "AFTER UPDATE ON records WHEN OLD.type='audio_event' OR NEW.type='audio_event' BEGIN ${subtract('OLD.')}${add('NEW.')} END",
    }.entries) {
      await repository.db.customStatement(
        'CREATE TRIGGER IF NOT EXISTS audio_daily_v1_${entry.key} ${entry.value}',
      );
    }
    if (existed == null) {
      await repository.db.customStatement(
        'INSERT INTO audio_daily_totals_v1(day,book_id,wall_ms) '
        "SELECT ${_j('', 'localDay')},${_j('', 'bookId')},SUM(CAST(${_j('', 'wallMs')} AS INTEGER)) "
        "FROM records WHERE ${_valid('')} GROUP BY 1,2",
      );
    }
    await repository.db.customStatement(
      "CREATE INDEX IF NOT EXISTS audio_event_time_v1 ON records "
      "($_at) "
      "WHERE type='audio_event' AND deleted=0 AND json_valid(payload)",
    );
    await repository.db.customStatement(
      "CREATE INDEX IF NOT EXISTS audio_event_end_v1 ON records ($_end) "
      "WHERE type='audio_event' AND deleted=0 AND json_valid(payload)",
    );
  });

  Future<AudioDailyTotals> lifetime() async {
    await ensure();
    final rows = await repository.db
        .customSelect(
          'SELECT day,book_id,wall_ms FROM audio_daily_totals_v1 WHERE wall_ms>0',
        )
        .get();
    return _totals(rows);
  }

  /// Clip only events intersecting the selected period, preserving the original
  /// analytics rules for unknown-time journals and saved timezone offsets.
  Future<AudioDailyTotals> period(DateTime start, DateTime end) async {
    await ensure();
    final rows = await repository.db
        .customSelect(
          '''
      WITH bounds(a,b) AS (VALUES (?,?)), events AS (
        SELECT json_extract(payload,'\$.kind') AS kind,
          json_extract(payload,'\$.bookId') AS book_id,
          json_extract(payload,'\$.localDay') AS saved_day,
          json_extract(payload,'\$.wallMs') AS wall,
          json_extract(payload,'\$.positionMs') AS pos,
          json_extract(payload,'\$.endMs') AS finish,
          COALESCE(json_extract(payload,'\$.offsetMinutes'),0) AS zone,
          json_extract(payload,'\$.timeKnown') IS NOT 0 AS known,
          $_at AS at
        FROM records WHERE type='audio_event' AND deleted=0 AND json_valid(payload)
          AND $_at<(SELECT b FROM bounds) AND $_end>=(SELECT a FROM bounds)
          AND typeof(json_extract(payload,'\$.bookId'))='text'
      ), clipped AS (
        SELECT *, CASE WHEN known THEN MAX(at,a) ELSE at END AS left_ms,
          CASE WHEN known THEN MIN(at+wall,b) ELSE at+wall END AS right_ms
        FROM events,bounds WHERE wall>0 AND kind IN ('listen','journal')
          AND ((known AND at<b AND at+wall>a) OR (NOT known AND at>=a AND at<b))
      ) SELECT CASE WHEN known THEN strftime('%Y-%m-%d',(left_ms+zone*60000)/1000.0,'unixepoch')
          ELSE saved_day END AS day, book_id, SUM(right_ms-left_ms) AS wall_ms
        FROM clipped WHERE right_ms>left_ms AND (kind='journal' OR
          ROUND(1.0*(finish-pos)*(right_ms-at)/wall)>ROUND(1.0*(finish-pos)*(left_ms-at)/wall))
        GROUP BY 1,2
    ''',
          variables: [
            Variable(start.millisecondsSinceEpoch),
            Variable(end.millisecondsSinceEpoch),
          ],
        )
        .get();
    return _totals(rows);
  }

  AudioDailyTotals _totals(List<QueryRow> rows) {
    final days = <String, int>{}, books = <String, int>{};
    for (final row in rows) {
      final day = row.read<String>('day'), book = row.read<String>('book_id');
      final wall = row.read<int>('wall_ms');
      days[day] = (days[day] ?? 0) + wall;
      books[book] = (books[book] ?? 0) + wall;
    }
    return AudioDailyTotals(days, books);
  }
}
