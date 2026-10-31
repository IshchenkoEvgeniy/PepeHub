import 'dart:isolate';

import 'reading_activity.dart';

class ReadingStatisticsData {
  final ReadingTotals total, all, global;
  final int week, previous;
  final ({int current, int best}) streak;
  final List<Map<String, dynamic>> shown;
  ReadingStatisticsData(
    this.total,
    this.all,
    this.global,
    this.week,
    this.previous,
    this.streak,
    this.shown,
  );
  factory ReadingStatisticsData.empty() => ReadingStatisticsData(
    ReadingTotals(),
    ReadingTotals(),
    ReadingTotals(),
    0,
    0,
    (current: 0, best: 0),
    [],
  );
}

class ReadingStatisticsWorker {
  Isolate? _isolate;
  Future<SendPort>? _ready;
  final _replies = <ReceivePort>{};
  bool _disposed = false;
  Future<SendPort> _start() async {
    final ready = ReceivePort();
    try {
      _isolate = await Isolate.spawn(_read, ready.sendPort);
      final port = await ready.first as SendPort;
      if (_disposed) {
        _isolate?.kill(priority: Isolate.immediate);
        throw StateError('Reading worker disposed');
      }
      return port;
    } finally {
      ready.close();
    }
  }

  Future<ReadingStatisticsData> analyze(Map<String, dynamic> request) async {
    if (_disposed) throw StateError('Reading worker disposed');
    final port = await (_ready ??= _start());
    if (_disposed) throw StateError('Reading worker disposed');
    final reply = ReceivePort();
    _replies.add(reply);
    try {
      port.send([reply.sendPort, request]);
      final result = await reply.first;
      if (result is ReadingStatisticsData) return result;
      throw StateError('$result');
    } finally {
      reply.close();
      _replies.remove(reply);
    }
  }

  void dispose() {
    _disposed = true;
    for (final reply in _replies) {
      reply.close();
    }
    _replies.clear();
    _isolate?.kill(priority: Isolate.immediate);
  }
}

void _read(SendPort ready) {
  final input = ReceivePort();
  ready.send(input.sendPort);
  var sessions = <Map<String, dynamic>>[];
  input.listen((message) {
    final reply = message[0] as SendPort;
    final request = message[1] as Map<String, dynamic>;
    try {
      if (request['sessions'] != null) {
        sessions = prepareReadingSessions(
          request['sessions'] as List<Map<String, dynamic>>,
        );
      }
      final start = request['start'] as DateTime?,
          end = request['end'] as DateTime?,
          book = request['book'] as String?;
      final now = request['now'] as DateTime;
      final shown = <Map<String, dynamic>>[];
      for (final session in groupReadingSessionsForDisplay(sessions)) {
        if (book != null && session['bookId'] != book) continue;
        final totals = readingTotals([session], start: start, end: end);
        if (totals.sessions == 0) continue;
        shown.add({
          ...session,
          'spans': const [],
          '_milliseconds': totals.milliseconds,
        });
      }
      shown.sort(
        (a, b) =>
            (b['startedAt'] as String).compareTo(a['startedAt'] as String),
      );
      final all = readingTotals(sessions, bookId: book);
      reply.send(
        ReadingStatisticsData(
          readingTotals(sessions, start: start, end: end, bookId: book),
          all,
          readingTotals(sessions),
          readingTotals(
            sessions,
            start: DateTime(now.year, now.month, now.day - 6),
            bookId: book,
          ).milliseconds,
          readingTotals(
            sessions,
            start: DateTime(now.year, now.month, now.day - 13),
            end: DateTime(now.year, now.month, now.day - 6),
            bookId: book,
          ).milliseconds,
          readingStreak(all.days, now),
          shown,
        ),
      );
    } catch (error, stack) {
      reply.send('$error\n$stack');
    }
  });
}

List<Map<String, dynamic>> prepareReadingSessions(
  List<Map<String, dynamic>> rows,
) => [
  for (final row in rows)
    {
      ...row,
      'events': const [],
      'ranges': const [],
      'spans': [
        for (final span in row['spans'] as List? ?? [])
          {
            ...span as Map,
            'start': span['start'] is DateTime
                ? span['start']
                : DateTime.parse(span['start'] as String),
            'end': span['end'] is DateTime
                ? span['end']
                : DateTime.parse(span['end'] as String),
          },
      ],
    },
];

class ReadingCalendarSummary {
  final Map<String, int> days, allDays;
  final Map<String, Map<String, int>> bookDays;
  ReadingCalendarSummary(this.days, this.allDays, this.bookDays);
}

ReadingCalendarSummary summarizeReadingCalendar(Map<String, dynamic> request) {
  final sessions = prepareReadingSessions(
    request['sessions'] as List<Map<String, dynamic>>,
  );
  final year = request['year'] as int;
  final days = <String, int>{}, bookDays = <String, Map<String, int>>{};
  final allDays = <String, int>{};
  for (final session in sessions) {
    final totals = readingTotals([session]);
    final book = bookDays.putIfAbsent(session['bookId'] as String, () => {});
    for (final e in totals.days.entries) {
      allDays[e.key] = (allDays[e.key] ?? 0) + e.value;
      if (e.key.startsWith('$year-')) {
        book[e.key] = (book[e.key] ?? 0) + e.value;
      }
    }
  }
  days.addAll(
    readingTotals(
      sessions,
      start: DateTime(year),
      end: DateTime(year + 1),
    ).days,
  );
  return ReadingCalendarSummary(days, allDays, bookDays);
}
