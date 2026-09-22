import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/audio/listening_analytics.dart';
import 'package:pepehub/audio/book_timeline.dart';

Map<String, dynamic> listen(
  String book,
  String at,
  int start,
  int end, {
  int wall = 10000,
}) => {
  'kind': 'listen',
  'bookId': book,
  'trackId': '$book-track',
  'at': at,
  'localDay': at.substring(0, 10),
  'offsetMinutes': 0,
  'positionMs': start,
  'endMs': end,
  'wallMs': wall,
  'speed': 1.0,
};
Map<String, dynamic> event(String kind, String book, String at) => {
  'kind': kind,
  'bookId': book,
  'trackId': '$book-track',
  'at': at,
  'localDay': at.substring(0, 10),
  'positionMs': 0,
};
void main() {
  test('custom hours clip long listening and sessions, retaining earlier repeat history', () {
    final result = analyzeListening({
      'start': '2026-09-18T10:10:00Z',
      'end': '2026-09-18T10:20:00Z',
      'events': [
        listen('b', '2026-09-17T10:00:00Z', 0, 1800000, wall: 1800000),
        listen('b', '2026-09-18T10:00:00Z', 0, 3600000, wall: 1800000),
        event('pause', 'b', '2026-09-18T10:15:00Z'),
        event('seek', 'b', '2026-09-18T10:20:00Z'),
      ],
    });
    expect(result.selected.wallMs, 600000);
    expect(result.selected.mediaMs, 1200000);
    expect(result.firstHeardMs, 600000);
    expect(result.repeatedHistoryMs, 600000);
    expect(result.selected.pauses, 1);
    expect(result.selected.seeks, 0);
    expect(result.lifetime.wallMs, 3600000);
    expect(
      result.sessions.single.start,
      DateTime.parse('2026-09-18T10:10:00Z'),
    );
    expect(result.sessions.single.end, DateTime.parse('2026-09-18T10:20:00Z'));
  });
  test('timeline boundaries, unknown lengths and endpoint clamping', () {
    final timeline = BookTimeline([3000, 20000, 5000]);
    expect(timeline.totalMs, 28000);
    expect(timeline.locate(3000), (1, 0));
    expect(timeline.locate(99999), (2, 5000));
    expect(timeline.locate(-1), (0, 0));
    expect(timeline.positionMs(1, 4000), 7000);
    expect(timeline.positionMs(2, 99999), 28000);
    final missing = BookTimeline([3000, null, 5000]);
    expect(missing.totalMs, isNull);
    expect(missing.locate(5000), isNull);
    expect(missing.positionMs(2, 0), isNull);
    expect(missing.positionMs(1, 2000), 5000);
  });
  test(
    'period repeats include listening before cutoff; ranges never count twice',
    () {
      final analysis = analyzeListening({
        'book': 'b',
        'cutoff': '2026-09-16',
        'events': [
          listen('b', '2026-09-15T10:00:00Z', 0, 10000),
          listen('b', '2026-09-16T10:00:00Z', 5000, 15000),
          listen('b', '2026-09-16T10:00:10Z', 10000, 20000),
          listen('other', '2026-09-16T11:00:00Z', 0, 10000),
        ],
      });
      expect(analysis.firstHeardMs, 10000);
      expect(analysis.repeatedHistoryMs, 10000);
      expect(analysis.selected.mediaMs, 20000);
      expect(analysis.selected.uniqueMs, 15000);
      expect(analysis.lifetime.uniqueMs, 20000);
      expect(analysis.currentStreak(DateTime(2026, 9, 17)), 2);
      expect(analysis.currentStreak(DateTime(2026, 9, 18)), 0);
      expect(
        analysis.timeBetween(DateTime(2026, 9, 16), DateTime(2026, 9, 17)),
        20000,
      );
    },
  );
  test(
    'sessions merge short pauses but split on book switch, stop or long gap',
    () {
      final analysis = analyzeListening({
        'book': 'b',
        'cutoff': null,
        'events': [
          listen('b', '2026-09-16T10:00:00Z', 0, 10000),
          event('pause', 'b', '2026-09-16T10:00:10Z'),
          listen('b', '2026-09-16T10:04:00Z', 10000, 20000),
          listen('other', '2026-09-16T10:04:10Z', 0, 10000),
          listen('b', '2026-09-16T10:04:20Z', 20000, 30000),
          event('stop', 'b', '2026-09-16T10:04:30Z'),
          listen('b', '2026-09-16T10:04:40Z', 30000, 40000),
          listen('b', '2026-09-16T10:10:00Z', 40000, 50000),
        ],
      });
      expect(analysis.sessions, hasLength(4));
      final first = analysis.sessions.last;
      expect(first.wallMs, 20000);
      expect(first.elapsedMs, 250000);
      expect(first.pauses, 1);
      expect(analysis.selected.wallMs, 50000);
    },
  );
}
