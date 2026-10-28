import 'dart:convert';
import 'dart:isolate';

import 'package:drift/drift.dart';

import '../data/repository.dart';

typedef _Span = (int ordinal, int start, int end, int milliseconds);

// Only detached strings/numbers cross the isolate boundary, never a database.
Future<List<(String, List<_Span>)>> _projectSessions(
  List<(String, String?)> rows,
) =>
    Isolate.run(() => [for (final row in rows) (row.$1, _decodeSpans(row.$2))]);

List<_Span> _decodeSpans(String? raw) {
  Map? session;
  try {
    final value = raw == null ? null : jsonDecode(raw);
    if (value is Map) session = value;
  } on FormatException {
    // Corrupt imported metadata cannot strand the projection queue.
  }
  final spans = session?['spans'];
  if (spans is! List) return [];
  final result = <_Span>[];
  for (var i = 0; i < spans.length; i++) {
    final span = spans[i];
    if (span is! Map || span['pepehubDeleted'] == true) continue;
    final start = DateTime.tryParse('${span['start']}');
    final end = DateTime.tryParse('${span['end']}');
    if (start == null || end == null || !end.isAfter(start)) continue;
    final ms = span['activeMs'] is int
        ? span['activeMs'] as int
        : end.difference(start).inMilliseconds;
    if (ms > 0) {
      result.add((
        i,
        start.microsecondsSinceEpoch,
        end.microsecondsSinceEpoch,
        ms,
      ));
    }
  }
  return result;
}

/// Numeric projection of reading spans. The dirty queue also observes writes
/// from sync, deletion and recovery; repeated queries never parse old journals.
/// Tables and metadata triggers come from the schema migration.
class ReadingDailyTotals {
  final Repository repository;
  static final _refreshing = Expando<Future<void>>();
  ReadingDailyTotals(this.repository);

  Future<void> refresh() async {
    final previous = _refreshing[repository.db];
    if (previous != null) return previous;
    final work = _refresh();
    _refreshing[repository.db] = work;
    try {
      await work;
    } finally {
      if (identical(_refreshing[repository.db], work)) {
        _refreshing[repository.db] = null;
      }
    }
  }

  Future<void> _refresh() async {
    while (true) {
      final count = await repository.db.transaction(() async {
        final rows = await repository.db
            .customSelect(
              'SELECT d.session_key,m.value FROM reading_span_dirty_v1 d '
              'LEFT JOIN metadata m ON m.key=d.session_key LIMIT 20',
            )
            .get();
        if (rows.isEmpty) return 0;
        final projected = await _projectSessions([
          for (final row in rows)
            (
              row.read<String>('session_key'),
              row.readNullable<String>('value'),
            ),
        ]);
        for (final (key, spans) in projected) {
          await repository.db.customStatement(
            'DELETE FROM reading_span_index_v1 WHERE session_key=?',
            [key],
          );
          for (final (ordinal, start, end, ms) in spans) {
            await repository.db.customStatement(
              'INSERT INTO reading_span_index_v1 VALUES(?,?,?,?,?)',
              [key, ordinal, start, end, ms],
            );
          }
          await repository.db.customStatement(
            'DELETE FROM reading_span_dirty_v1 WHERE session_key=?',
            [key],
          );
        }
        return rows.length;
      });
      if (count < 20) return;
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<int> day(DateTime date) async {
    await refresh();
    final start = DateTime(
      date.year,
      date.month,
      date.day,
    ).microsecondsSinceEpoch;
    final end = DateTime(
      date.year,
      date.month,
      date.day + 1,
    ).microsecondsSinceEpoch;
    final row = await repository.db
        .customSelect(
          'SELECT CAST(COALESCE(SUM(ROUND(active_ms*1.0*'
          '(MIN(finish_us,?)-MAX(start_us,?))/(finish_us-start_us))),0) AS INTEGER) AS total '
          'FROM reading_span_index_v1 WHERE finish_us>? AND start_us<?',
          variables: [
            Variable(end),
            Variable(start),
            Variable(start),
            Variable(end),
          ],
        )
        .getSingle();
    return row.read<int>('total');
  }
}
