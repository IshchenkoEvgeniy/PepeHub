import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/video/models.dart';
import 'package:pepehub/video/video_activity.dart';

VideoLesson lesson(String id, int? duration, {String version = 'v1'}) =>
    VideoLesson(
      id: id,
      itemId: 'course',
      title: id,
      module: '',
      source: '$id.mp4',
      mediaVersion: version,
      ordinal: 0,
      durationMs: duration,
    );

VideoInterval span(
  String id,
  int start,
  int end, {
  required DateTime at,
  int? wallMs,
  String lessonId = 'lesson',
  String session = 'session',
  int offset = 0,
  VideoActivityMode mode = VideoActivityMode.visual,
}) => VideoInterval(
  id: id,
  sessionId: session,
  lessonId: lessonId,
  mediaVersion: 'v1',
  mode: mode,
  startedAt: at,
  offsetMinutes: offset,
  startMs: start,
  endMs: end,
  wallMs: wallMs ?? end - start,
  speed: wallMs == null ? 1 : (end - start) / wallMs,
);

void main() {
  test(
    'legacy long pause divides sessions; short pauses exclude active time',
    () {
      final at = DateTime.utc(2026, 10, 14, 10);
      final intervals = [
        span('one', 0, 10000, at: at),
        span(
          'two',
          10000,
          20000,
          at: at.add(const Duration(seconds: 30)),
          lessonId: 'second',
        ),
        span('three', 20000, 30000, at: at.add(const Duration(minutes: 10))),
      ];
      final stats = analyzeVideo(VideoAnalysisRequest(intervals));
      expect(stats.sessions, hasLength(2));
      final first = stats.sessionDetails.last;
      expect(first.wallMs, 20000);
      expect(first.elapsedMs, 40000);
      expect(first.breakMs, 20000);
      expect(first.lessonIds, {'lesson', 'second'});
      expect(stats.firstViewedAt, at);
      expect(
        stats.lastViewedAt,
        at.add(const Duration(minutes: 10, seconds: 10)),
      );
      final selected = analyzeVideo(
        VideoAnalysisRequest(
          intervals,
          start: at.add(const Duration(seconds: 5)),
          end: at.add(const Duration(seconds: 35)),
        ),
      );
      expect(selected.sessions, hasLength(1));
      expect(selected.sessionDetails.single.wallMs, 10000);
      expect(selected.sessionDetails.single.elapsedMs, 30000);
      expect(selected.sessionDetails.single.breakMs, 20000);
    },
  );

  test(
    'old intervals crossing midnight use their recorded offset when clipped',
    () {
      final at = DateTime.utc(2026, 10, 14, 20, 59, 58);
      final data = [span('old', 0, 10000, at: at, wallMs: 5000, offset: 180)];
      final all = analyzeVideo(VideoAnalysisRequest(data));
      expect(all.lifetimeDays, {'2026-10-14': 2000, '2026-10-15': 3000});
      final part = analyzeVideo(
        VideoAnalysisRequest(
          data,
          start: at.add(const Duration(seconds: 1)),
          end: at.add(const Duration(seconds: 3)),
        ),
      );
      expect(part.days, {'2026-10-14': 1000, '2026-10-15': 1000});
      expect(part.wallMs, 2000);
      expect(part.mediaMs, 4000);
    },
  );

  test('coverage map identifies actual replays and unplayed gaps', () {
    final result = videoCoverageRuns([
      (start: 0, end: 40),
      (start: 20, end: 60),
      (start: 80, end: 120),
    ], 100);
    expect(result.map((r) => (r.startMs, r.endMs, r.passes)), [
      (0, 20, 1),
      (20, 40, 2),
      (40, 60, 1),
      (60, 80, 0),
      (80, 100, 1),
    ]);
    expect(videoCoverageRuns([], 100).single.passes, 0);
    expect(videoCoverageRuns([], 0), isEmpty);
  });

  test('course coverage is duration-weighted; manual completion does not fill gaps', () {
    final short = lesson('short', 20000), long = lesson('long', 80000);
    final stats = analyzeVideo(
      VideoAnalysisRequest([
        span(
          'watched',
          0,
          20000,
          at: DateTime.utc(2026, 10, 14),
          lessonId: short.id,
        ),
      ]),
    );
    final plain = videoCourseCoverage([short, long], stats, 95, {});
    expect(plain.fraction, .2);
    expect(plain.completedLessons, 1);
    final manual = videoCourseCoverage(
      [short, long],
      stats,
      95,
      {
        'long:v1': VideoLearningState(
          lessonId: 'long',
          mediaVersion: 'v1',
          manualCompletedAt: DateTime.utc(2026, 10, 14),
        ),
      },
    );
    expect(manual.fraction, .2);
    expect(manual.completedLessons, 2);
    final unknown = videoCourseCoverage(
      [short, long, lesson('unknown', null)],
      stats,
      95,
      {},
    );
    expect(unknown.fraction, isNull);
    expect(unknown.unknownLessons, 1);
    expect(unknown.totalMs, 100000);
  });

  test(
    'first coverage milestone ignores repeats, audio and other media versions',
    () {
      final at = DateTime.utc(2026, 10, 14, 10);
      final current = lesson('lesson', 100000);
      final intervals = [
        span('first', 0, 50000, at: at),
        span('repeat', 0, 50000, at: at.add(const Duration(seconds: 100))),
        span(
          'new',
          50000,
          100000,
          wallMs: 25000,
          at: at.add(const Duration(seconds: 200)),
        ),
      ];
      expect(
        firstVideoCoverageCompletion(intervals, current, 95),
        at.add(const Duration(milliseconds: 222500)),
      );
      expect(
        firstVideoCoverageCompletion(
          intervals,
          lesson('lesson', 100000, version: 'v2'),
          95,
        ),
        isNull,
      );
      expect(
        firstVideoCoverageCompletion(
          [span('audio', 0, 100000, at: at, mode: VideoActivityMode.audio)],
          current,
          95,
        ),
        isNull,
      );
      expect(firstVideoCoverageCompletion([], current, 95), isNull);
      expect(
        firstVideoCoverageCompletion(intervals, lesson('lesson', null), 95),
        isNull,
      );
    },
  );

  test('streak survives a year boundary and excludes zero-activity days', () {
    final result = videoStreak({
      '2025-12-30': 1000,
      '2025-12-31': 1000,
      '2026-01-01': 1000,
      '2026-01-02': 0,
    }, DateTime.utc(2026, 1, 2));
    expect(result.current, 3);
    expect(result.best, 3);
    expect(
      videoStreak({'2026-01-01': 1000}, DateTime.utc(2026, 1, 4)).current,
      0,
    );
  });

  test('week comparison uses the same weekday and time; zero baseline has no percentage', () {
    final now = DateTime.utc(2026, 10, 14, 12);
    final intervals = [
      span('monday', 0, 10000, at: DateTime.utc(2026, 10, 12, 10)),
      span('today', 0, 20000, at: DateTime.utc(2026, 10, 14, 11)),
      span('later', 0, 30000, at: DateTime.utc(2026, 10, 14, 13)),
      span('previous', 0, 10000, at: DateTime.utc(2026, 10, 7, 11)),
      span('previous-later', 0, 30000, at: DateTime.utc(2026, 10, 7, 13)),
    ];
    final result = videoWeekComparison(intervals, now);
    expect(result.currentMs, 30000);
    expect(result.previousMs, 10000);
    expect(result.percentChange, 200);
    expect(videoWeekComparison([], now).percentChange, isNull);
  });

  test('global daily goal includes other courses while the page statistics stay scoped', () {
    final now = DateTime.utc(2026, 10, 14, 12);
    final result = analyzeVideoDashboard(
      VideoDashboardRequest(
        VideoAnalysisRequest(
          [
            span(
              'own',
              0,
              2000,
              at: now.subtract(const Duration(hours: 1)),
              lessonId: 'own',
            ),
            span(
              'other',
              0,
              8000,
              at: now.subtract(const Duration(hours: 2)),
              lessonId: 'other',
            ),
          ],
          lessonIds: {'own'},
        ),
        now,
      ),
    );
    expect(result.selected.wallMs, 2000);
    expect(result.todayMs, 10000);
    expect(result.globalWeekMs, 10000);
    expect(result.comparison.currentMs, 2000);
  });
}
