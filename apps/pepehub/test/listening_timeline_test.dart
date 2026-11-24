import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/audio/listening_timeline.dart';

Map<String, dynamic> _listen(
  DateTime at,
  String track,
  int from,
  int to, {
  int? wallMs,
}) => {
  'kind': 'listen',
  'at': at.toUtc().toIso8601String(),
  'trackId': track,
  'positionMs': from,
  'endMs': to,
  'wallMs': wallMs ?? to - from,
};

Map<String, dynamic> _seek(
  DateTime at,
  String fromTrack,
  int fromMs,
  String track,
  int ms,
  String reason,
) => {
  'kind': 'seek',
  'at': at.toUtc().toIso8601String(),
  'fromTrackId': fromTrack,
  'fromMs': fromMs,
  'trackId': track,
  'positionMs': ms,
  'reason': reason,
};

void main() {
  final evening = DateTime(2026, 11, 23, 22, 10);
  const minute = 60000;

  test('hourly listening records merge into one span per sitting', () {
    final days = buildListeningTimeline([
      // The journal splits a sitting at the hour.
      _listen(evening, 't7', 3 * minute, 50 * 60000 - 600000),
      _listen(
        evening.add(const Duration(minutes: 40)),
        't7',
        50 * 60000 - 600000,
        45 * minute,
      ),
      // A different track starts a new span.
      _listen(evening.add(const Duration(minutes: 46)), 't8', 0, 5 * minute),
    ]);
    expect(days, hasLength(1));
    final spans = days.single.entries.cast<ListenSpan>();
    expect(spans.map((s) => s.trackId), ['t8', 't7']);
    expect(spans.last.startMs, 3 * minute);
    expect(spans.last.endMs, 45 * minute);
  });

  test('a run of skips is one entry with its net effect', () {
    final at = evening;
    final days = buildListeningTimeline([
      _listen(at, 't1', 0, 10 * minute),
      _seek(
        at.add(const Duration(minutes: 10)),
        't1',
        600000,
        't1',
        585000,
        'rewind',
      ),
      // A few seconds heard between taps belong to the search.
      _listen(
        at.add(const Duration(minutes: 10, seconds: 1)),
        't1',
        585000,
        590000,
      ),
      _seek(
        at.add(const Duration(minutes: 10, seconds: 7)),
        't1',
        590000,
        't1',
        575000,
        'rewind',
      ),
      _seek(
        at.add(const Duration(minutes: 10, seconds: 8)),
        't1',
        575000,
        't1',
        560000,
        'rewind',
      ),
      _listen(
        at.add(const Duration(minutes: 10, seconds: 9)),
        't1',
        560000,
        900000,
      ),
      // A deliberate jump stays on its own.
      _seek(
        at.add(const Duration(minutes: 20)),
        't1',
        900000,
        't3',
        0,
        'chapter',
      ),
    ]);
    final entries = days.single.entries;
    expect(entries, hasLength(4));
    final chapter = entries.first as JumpEntry;
    expect(chapter.reason, 'chapter');
    expect(chapter.skip, isFalse);
    final skips = entries[2] as JumpEntry;
    expect(skips.count, 3);
    expect(skips.fromMs, 600000);
    expect(skips.toMs, 560000);
    expect(skips.deltaMs, -40000);
  });

  test('days come newest first and the sleep timer marks its span', () {
    final yesterday = evening.subtract(const Duration(days: 1));
    final days = buildListeningTimeline([
      _listen(evening, 't2', 0, minute),
      _listen(yesterday, 't1', 0, 30 * minute),
      {
        'kind': 'sleep_fired',
        'at': yesterday
            .add(const Duration(minutes: 30))
            .toUtc()
            .toIso8601String(),
      },
      {'kind': 'speed', 'at': evening.toUtc().toIso8601String()},
      {'kind': 'listen', 'at': 'broken'},
    ]);
    expect(days.map((d) => d.day.day), [23, 22]);
    expect((days.last.entries.single as ListenSpan).sleep, isTrue);
    expect((days.first.entries.single as ListenSpan).sleep, isFalse);
  });
}
