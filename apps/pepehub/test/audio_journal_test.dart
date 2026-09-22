import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/audio/audio_journal.dart';

void main() {
  test('audible ranges exclude pauses and seeks, tolerate playback speed', () {
    final sampler = ListeningSampler();
    void sample(int mono, int position, bool audible, double speed) =>
        sampler.sample(
          bookId: 'b',
          trackId: 't',
          positionMs: position,
          monotonicMs: mono,
          speed: speed,
          audible: audible,
          at: DateTime(2026, 9, 16).add(Duration(milliseconds: mono)),
        );
    sample(0, 0, true, 2);
    sample(1000, 2000, true, 2);
    sample(1500, 3000, false, 2);
    sample(5000, 3000, false, 2);
    sample(5000, 90000, false, 1);
    sample(5000, 90000, true, 1);
    sample(6000, 91000, false, 1);
    final stats = AudioStats(sampler.pending.map((s) => s.data));
    expect(stats.wallMs, 2500);
    expect(stats.mediaMs, 4000);
    expect(stats.uniqueMs, 4000);
    expect(stats.repeatedMs, 0);
    sample(20000, 91000, true, 1);
    sample(40000, 111000, false, 1);
    expect(
      AudioStats(sampler.pending.map((s) => s.data)).wallMs,
      2500,
      reason: 'Long unobserved gaps are not invented',
    );
  });
  test('overlaps across speeds count once and tracks remain separate', () {
    Map<String, dynamic> segment(
      String track,
      int start,
      int end,
      int wall,
      String day,
    ) => {
      'kind': 'listen',
      'bookId': 'b',
      'trackId': track,
      'positionMs': start,
      'endMs': end,
      'wallMs': wall,
      'speed': 2.0,
      'localDay': day,
      'at': '${day}T10:00:00Z',
      'offsetMinutes': 180,
    };
    final stats = AudioStats([
      segment('t', 0, 10000, 5000, '2026-09-15'),
      segment('t', 5000, 15000, 5000, '2026-09-16'),
      segment('other', 0, 10000, 5000, '2026-09-16'),
      {
        'kind': 'seek',
        'trackId': 't',
        'fromTrackId': 't',
        'positionMs': 1000,
        'fromMs': 5000,
      },
    ]);
    expect(stats.wallMs, 15000);
    expect(stats.mediaMs, 30000);
    expect(stats.uniqueMs, 25000);
    expect(stats.repeatedMs, 5000);
    expect(stats.averageSpeed, 2);
    expect(stats.longestStreak, 2);
    expect(stats.backwardMs, 4000);
    expect(stats.hours[13], 15000);
  });
}
