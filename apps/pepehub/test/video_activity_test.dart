import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/video/models.dart';
import 'package:pepehub/video/video_activity.dart';

VideoInterval interval(
  String id,
  int start,
  int end, {
  DateTime? at,
  int? wall,
  String version = 'v1',
  VideoActivityMode mode = VideoActivityMode.visual,
}) => VideoInterval(
  id: id,
  sessionId: id,
  lessonId: 'lesson',
  mediaVersion: version,
  mode: mode,
  startedAt: at ?? DateTime.utc(2026, 10, 14, 10),
  offsetMinutes: 0,
  startMs: start,
  endMs: end,
  wallMs: wall ?? end - start,
  speed: 1,
);

void main() {
  test('three hours retain one interval ID while checkpoints grow', () {
    final sampler = VideoActivitySampler();
    final saved = <String, VideoInterval>{};
    final start = DateTime.utc(2026, 10, 14, 9);
    for (var ms = 0; ms <= 10800000; ms += 10000) {
      for (final update in sampler.sample(
        sessionId: 'session',
        lessonId: 'lesson',
        mediaVersion: 'v1',
        positionMs: ms,
        monotonicMs: ms,
        at: start.add(Duration(milliseconds: ms)),
        speed: 1,
        active: true,
      )) {
        saved[update.id] = update;
      }
    }
    expect(saved, hasLength(1));
    expect(saved.values.single.wallMs, 10800000);
    expect(saved.values.single.mediaMs, 10800000);
  });

  test('speed changes material volume; seeks and buffering do not add it', () {
    final sampler = VideoActivitySampler();
    var clock = 0;
    List<VideoInterval> sample(int position, {bool active = true}) {
      final result = sampler.sample(
        sessionId: 's',
        lessonId: 'lesson',
        mediaVersion: 'v1',
        positionMs: position,
        monotonicMs: clock,
        at: DateTime.utc(2026, 10, 14, 10).add(Duration(milliseconds: clock)),
        speed: 1.5,
        active: active,
      );
      clock += 2000;
      return result;
    }

    expect(sample(0), isEmpty);
    final first = sample(3000).single;
    expect(first.wallMs, 2000);
    expect(first.mediaMs, 3000);
    expect(
      sample(60000),
      isEmpty,
    ); // A large discontinuity cannot become coverage.
    final afterSeek = sample(63000).single;
    expect(afterSeek.startMs, 60000);
    expect(afterSeek.id, isNot(first.id));
    expect(sample(63000, active: false), isEmpty);
    expect(sample(63000, active: false), isEmpty);
    expect(sample(63000), isEmpty);
    expect(sample(66000).single.wallMs, 2000);
  });

  test(
    'midnight divides real time and media without creating extra volume',
    () {
      final sampler = VideoActivitySampler();
      final start = DateTime.utc(2026, 10, 14, 23, 59, 59);
      sampler.sample(
        sessionId: 's',
        lessonId: 'lesson',
        mediaVersion: 'v1',
        positionMs: 0,
        monotonicMs: 0,
        at: start,
        speed: 2,
        active: true,
      );
      final updates = sampler.sample(
        sessionId: 's',
        lessonId: 'lesson',
        mediaVersion: 'v1',
        positionMs: 4000,
        monotonicMs: 2000,
        at: start.add(const Duration(seconds: 2)),
        speed: 2,
        active: true,
      );
      expect(updates, hasLength(2));
      expect(updates.map((i) => i.localDay), ['2026-10-14', '2026-10-15']);
      expect(updates.map((i) => i.wallMs), [1000, 1000]);
      expect(updates.map((i) => i.mediaMs), [2000, 2000]);
    },
  );

  test(
    'period repeats include previous history and cut an accelerated interval',
    () {
      final old = interval('old', 0, 6000, at: DateTime.utc(2026, 10, 13));
      final today = interval('today', 0, 12000, wall: 6000);
      final all = analyzeVideo(
        VideoAnalysisRequest([today, old], start: DateTime.utc(2026, 10, 14)),
      );
      expect(all.wallMs, 6000);
      expect(all.mediaMs, 12000);
      expect(all.firstMs, 6000);
      expect(all.repeatedMs, 6000);
      final selected = analyzeVideo(
        VideoAnalysisRequest(
          [today, old],
          start: today.startedAt.add(const Duration(seconds: 2)),
          end: today.startedAt.add(const Duration(seconds: 4)),
        ),
      );
      expect(selected.wallMs, 2000);
      expect(selected.mediaMs, 4000);
      expect(selected.firstMs, 2000);
      expect(selected.repeatedMs, 2000);
      expect(selected.firstMs + selected.repeatedMs, selected.mediaMs);
    },
  );

  test(
    'replays preserve unique coverage; mode and media version are separate',
    () {
      final intervals = [
        interval('first', 0, 10000),
        interval('repeat', 5000, 15000, at: DateTime.utc(2026, 10, 14, 11)),
        interval('audio', 0, 10000, mode: VideoActivityMode.audio),
        interval('new-file', 0, 10000, version: 'v2'),
      ];
      final result = analyzeVideo(VideoAnalysisRequest(intervals));
      expect(result.mediaMs, 40000);
      expect(result.firstMs, 35000);
      expect(result.repeatedMs, 5000);
      expect(result.coverage['lesson:v1:visual'], [(start: 0, end: 15000)]);
      expect(result.modeTime[VideoActivityMode.audio], 10000);
      expect(result.coverage, hasLength(3));
    },
  );
}
