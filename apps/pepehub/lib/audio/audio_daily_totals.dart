import 'package:drift/drift.dart';

import '../data/database_schema.dart';
import '../data/repository.dart';

class AudioDailyTotals {
  final Map<String, int> days, books;
  const AudioDailyTotals(this.days, this.books);
}

/// Rebuildable read model. The table, its triggers and the time indexes are
/// created by the schema migration (see `database_schema.dart`).
class AudioDailyStore {
  final Repository repository;
  AudioDailyStore(this.repository);
  static const _at = SchemaSql.audioEventAt;
  static const _end = SchemaSql.audioEventEnd;

  Future<AudioDailyTotals> lifetime() async {
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
