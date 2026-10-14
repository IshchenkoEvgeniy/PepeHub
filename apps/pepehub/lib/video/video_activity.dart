import 'dart:math' as math;

import 'package:uuid/uuid.dart';

import 'models.dart';

/// Engine-independent sampling. Discontinuities are excluded, never bridged.
class VideoActivitySampler {
  final String Function() newId;
  VideoActivitySampler({String Function()? newId})
    : newId = newId ?? const Uuid().v4;

  _Sample? _previous;
  VideoInterval? _current;

  void reset() {
    _previous = null;
    _current = null;
  }

  List<VideoInterval> sample({
    required String sessionId,
    required String lessonId,
    required String mediaVersion,
    required int positionMs,
    required int monotonicMs,
    required DateTime at,
    required double speed,
    required bool active,
    VideoActivityMode mode = VideoActivityMode.visual,
  }) {
    final next = _Sample(
      sessionId,
      lessonId,
      mediaVersion,
      positionMs,
      monotonicMs,
      at,
      speed,
      active,
      mode,
    );
    final previous = _previous;
    _previous = next;
    if (previous == null) return const [];
    final elapsed = monotonicMs - previous.monotonicMs;
    final moved = positionMs - previous.positionMs;
    final expected = elapsed * previous.speed;
    if (!previous.active ||
        !active ||
        previous.sessionId != sessionId ||
        previous.lessonId != lessonId ||
        previous.mediaVersion != mediaVersion ||
        previous.mode != mode ||
        previous.speed != speed ||
        !speed.isFinite ||
        speed <= 0 ||
        elapsed <= 0 ||
        elapsed > 15000 ||
        moved <= 0 ||
        (moved - expected).abs() > math.max(250, expected * .2)) {
      _current = null;
      return const [];
    }

    // Local midnight uses the saved offset, independent of the host timezone.
    final offset = previous.at.timeZoneOffset.inMinutes;
    final begin = previous.at.toUtc();
    final local = begin.add(Duration(minutes: offset));
    final midnight = DateTime.utc(
      local.year,
      local.month,
      local.day + 1,
    ).subtract(Duration(minutes: offset));
    final dayCut = midnight.difference(begin).inMilliseconds;
    final cuts = <int>[0, if (dayCut > 0 && dayCut < elapsed) dayCut, elapsed];
    final updates = <VideoInterval>[];
    for (var i = 1; i < cuts.length; i++) {
      final from = cuts[i - 1], to = cuts[i];
      final left = previous.positionMs + (moved * from / elapsed).round();
      final right = previous.positionMs + (moved * to / elapsed).round();
      if (right <= left) {
        _current = null;
        continue;
      }
      final start = begin.add(Duration(milliseconds: from));
      final old = _current;
      final continuous =
          old != null &&
          old.endMs == left &&
          old.offsetMinutes == offset &&
          old.localDay == videoDay(start.add(Duration(minutes: offset))) &&
          old.endedAt.difference(start).inMilliseconds.abs() <= 100;
      final interval = VideoInterval(
        id: continuous ? old.id : newId(),
        sessionId: sessionId,
        lessonId: lessonId,
        mediaVersion: mediaVersion,
        mode: mode,
        startedAt: continuous ? old.startedAt : start,
        offsetMinutes: offset,
        startMs: continuous ? old.startMs : left,
        endMs: right,
        wallMs: (continuous ? old.wallMs : 0) + to - from,
        speed: speed,
      );
      _current = interval;
      updates.add(interval);
    }
    return updates;
  }
}

class _Sample {
  final String sessionId, lessonId, mediaVersion;
  final int positionMs, monotonicMs;
  final DateTime at;
  final double speed;
  final bool active;
  final VideoActivityMode mode;
  const _Sample(
    this.sessionId,
    this.lessonId,
    this.mediaVersion,
    this.positionMs,
    this.monotonicMs,
    this.at,
    this.speed,
    this.active,
    this.mode,
  );
}

typedef VideoRange = ({int start, int end});

List<VideoRange> mergeVideoRange(List<VideoRange> ranges, int start, int end) {
  if (end <= start) return ranges;
  final sorted = [...ranges, (start: start, end: end)]
    ..sort((a, b) => a.start.compareTo(b.start));
  final merged = <VideoRange>[];
  for (final range in sorted) {
    if (merged.isEmpty || merged.last.end < range.start) {
      merged.add(range);
    } else {
      final old = merged.removeLast();
      merged.add((start: old.start, end: math.max(old.end, range.end)));
    }
  }
  return merged;
}

int videoRangeLength(List<VideoRange> ranges) =>
    ranges.fold(0, (sum, range) => sum + range.end - range.start);

int _overlap(List<VideoRange> ranges, int start, int end) => ranges.fold(
  0,
  (sum, range) =>
      sum +
      math.max(0, math.min(end, range.end) - math.max(start, range.start)),
);

class VideoAnalysisRequest {
  final List<VideoInterval> intervals;
  final Set<String>? lessonIds;
  final DateTime? start, end;
  final List<VideoLesson> lessons;
  const VideoAnalysisRequest(
    this.intervals, {
    this.lessonIds,
    this.start,
    this.end,
    this.lessons = const [],
  });
}

class VideoStats {
  int wallMs = 0, mediaMs = 0, firstMs = 0, repeatedMs = 0;
  final Set<String> sessions = {};
  final Map<String, int> days = {};
  final Map<String, int> lifetimeDays = {};
  DateTime? firstViewedAt, lastViewedAt;
  List<VideoSessionStats> sessionDetails = [];
  final Map<VideoActivityMode, int> modeTime = {};
  final Map<String, List<VideoRange>> coverage = {}, selectedCoverage = {};
  final Map<String, List<VideoCoverageRun>> coverageMaps = {};
  int get uniqueMs => selectedCoverage.values.fold(
    0,
    (sum, ranges) => sum + videoRangeLength(ranges),
  );
  int get lifetimeUniqueMs =>
      coverage.values.fold(0, (sum, ranges) => sum + videoRangeLength(ranges));
  int lessonCoverage(
    VideoLesson lesson, {
    VideoActivityMode mode = VideoActivityMode.visual,
  }) {
    final ranges =
        coverage['${lesson.id}:${lesson.mediaVersion}:${mode.name}'] ??
        const [];
    final duration = lesson.durationMs;
    return videoRangeLength(
      duration == null
          ? ranges
          : [
              for (final range in ranges)
                if (math.min(range.end, duration) > math.max(0, range.start))
                  (
                    start: math.max(0, range.start),
                    end: math.min(range.end, duration),
                  ),
            ],
    );
  }
}

class VideoSessionStats {
  final String id;
  DateTime start, end;
  int wallMs = 0, mediaMs = 0, firstMs = 0, repeatedMs = 0;
  final Set<String> lessonIds = {};
  VideoSessionStats(this.id, this.start, this.end);
  int get elapsedMs => end.difference(start).inMilliseconds;
  int get breakMs => math.max(0, elapsedMs - wallMs);
}

class _SessionCursor {
  int part = 0;
  DateTime end;
  _SessionCursor(this.end);
}

Iterable<({String day, int wallMs})> _daySlices(
  VideoInterval interval,
  int from,
  int to,
) sync* {
  var cursor = from;
  while (cursor < to) {
    final local = interval.startedAt.toUtc().add(
      Duration(milliseconds: cursor, minutes: interval.offsetMinutes),
    );
    final nextMidnight = DateTime.utc(
      local.year,
      local.month,
      local.day + 1,
    ).subtract(Duration(minutes: interval.offsetMinutes));
    final end = math.min(
      to,
      nextMidnight.difference(interval.startedAt).inMilliseconds,
    );
    if (end <= cursor) break;
    yield (day: videoDay(local), wallMs: end - cursor);
    cursor = end;
  }
}

/// History before the selected period is retained when identifying repeats.
VideoStats analyzeVideo(VideoAnalysisRequest request) {
  final result = VideoStats();
  final sessionCursors = <String, _SessionCursor>{};
  final sessionDetails = <String, VideoSessionStats>{};
  final passes = <String, List<VideoRange>>{};
  final intervals =
      request.intervals
          .where(
            (i) =>
                request.lessonIds == null ||
                request.lessonIds!.contains(i.lessonId),
          )
          .toList()
        ..sort((a, b) {
          final time = a.startedAt.compareTo(b.startedAt);
          return time != 0 ? time : a.id.compareTo(b.id);
        });
  for (final interval in intervals) {
    if (interval.wallMs <= 0 || interval.mediaMs <= 0) continue;
    final key = interval.coverageKey;
    final prior = result.coverage[key] ?? const <VideoRange>[];
    (passes[key] ??= []).add((start: interval.startMs, end: interval.endMs));
    final sessionCursor = sessionCursors[interval.sessionId];
    final cursor = sessionCursor ?? _SessionCursor(interval.endedAt);
    if (sessionCursor != null &&
        interval.startedAt.difference(cursor.end) >
            const Duration(minutes: 5)) {
      cursor.part++;
    }
    if (interval.endedAt.isAfter(cursor.end)) cursor.end = interval.endedAt;
    sessionCursors[interval.sessionId] = cursor;
    final sessionId = '${interval.sessionId}:${cursor.part}';
    for (final day in _daySlices(interval, 0, interval.wallMs)) {
      result.lifetimeDays[day.day] =
          (result.lifetimeDays[day.day] ?? 0) + day.wallMs;
    }
    if (result.firstViewedAt == null ||
        interval.startedAt.isBefore(result.firstViewedAt!)) {
      result.firstViewedAt = interval.startedAt;
    }
    if (result.lastViewedAt == null ||
        interval.endedAt.isAfter(result.lastViewedAt!)) {
      result.lastViewedAt = interval.endedAt;
    }
    final leftWall = request.start == null
        ? 0
        : request.start!
              .difference(interval.startedAt)
              .inMilliseconds
              .clamp(0, interval.wallMs);
    final rightWall = request.end == null
        ? interval.wallMs
        : request.end!
              .difference(interval.startedAt)
              .inMilliseconds
              .clamp(0, interval.wallMs);
    if (rightWall > leftWall) {
      final left =
          interval.startMs +
          (interval.mediaMs * leftWall / interval.wallMs).round();
      final right =
          interval.startMs +
          (interval.mediaMs * rightWall / interval.wallMs).round();
      final amount = right - left;
      final repeat = _overlap(prior, left, right);
      final wall = rightWall - leftWall;
      result.wallMs += wall;
      result.mediaMs += amount;
      result.firstMs += amount - repeat;
      result.repeatedMs += repeat;
      result.sessions.add(sessionId);
      final selectedStart = interval.startedAt.add(
        Duration(milliseconds: leftWall),
      );
      final selectedEnd = interval.startedAt.add(
        Duration(milliseconds: rightWall),
      );
      final session = sessionDetails.putIfAbsent(
        sessionId,
        () => VideoSessionStats(sessionId, selectedStart, selectedEnd),
      );
      if (selectedStart.isBefore(session.start)) session.start = selectedStart;
      if (selectedEnd.isAfter(session.end)) session.end = selectedEnd;
      session.wallMs += wall;
      session.mediaMs += amount;
      session.firstMs += amount - repeat;
      session.repeatedMs += repeat;
      session.lessonIds.add(interval.lessonId);
      for (final day in _daySlices(interval, leftWall, rightWall)) {
        result.days[day.day] = (result.days[day.day] ?? 0) + day.wallMs;
      }
      result.modeTime[interval.mode] =
          (result.modeTime[interval.mode] ?? 0) + wall;
      result.selectedCoverage[key] = mergeVideoRange(
        result.selectedCoverage[key] ?? const [],
        left,
        right,
      );
    }
    result.coverage[key] = mergeVideoRange(
      prior,
      interval.startMs,
      interval.endMs,
    );
  }
  result.sessionDetails = sessionDetails.values.toList()
    ..sort((a, b) => b.start.compareTo(a.start));
  for (final lesson in request.lessons) {
    final duration = lesson.durationMs;
    if (duration != null && duration > 0) {
      result.coverageMaps[lesson.id] = videoCoverageRuns(
        passes['${lesson.id}:${lesson.mediaVersion}:visual'] ?? const [],
        duration,
      );
    }
  }
  return result;
}

class VideoCoverageRun {
  final int startMs, endMs, passes;
  const VideoCoverageRun(this.startMs, this.endMs, this.passes);
}

/// A sweep counts actual passes; growing checkpoints still represent one pass.
List<VideoCoverageRun> videoCoverageRuns(
  List<VideoRange> ranges,
  int durationMs,
) {
  if (durationMs <= 0) return const [];
  final events = <int, int>{0: 0, durationMs: 0};
  for (final range in ranges) {
    final start = range.start.clamp(0, durationMs),
        end = range.end.clamp(0, durationMs);
    if (end <= start) continue;
    events[start] = (events[start] ?? 0) + 1;
    events[end] = (events[end] ?? 0) - 1;
  }
  final points = events.keys.toList()..sort();
  final result = <VideoCoverageRun>[];
  var count = 0;
  for (var i = 0; i + 1 < points.length; i++) {
    count += events[points[i]]!;
    if (result.isNotEmpty && result.last.passes == count) {
      final old = result.removeLast();
      result.add(VideoCoverageRun(old.startMs, points[i + 1], count));
    } else {
      result.add(VideoCoverageRun(points[i], points[i + 1], count));
    }
  }
  return result;
}

class VideoCourseCoverage {
  final int totalMs, watchedMs, unknownLessons, totalLessons, completedLessons;
  const VideoCourseCoverage(
    this.totalMs,
    this.watchedMs,
    this.unknownLessons,
    this.totalLessons,
    this.completedLessons,
  );
  double? get fraction =>
      unknownLessons == 0 && totalMs > 0 ? watchedMs / totalMs : null;
  int get remainingMs => totalMs - watchedMs;
}

VideoCourseCoverage videoCourseCoverage(
  List<VideoLesson> lessons,
  VideoStats stats,
  int threshold,
  Map<String, VideoLearningState> states,
) {
  var total = 0, covered = 0, unknown = 0, completed = 0;
  for (final lesson in lessons) {
    final duration = lesson.durationMs, watched = stats.lessonCoverage(lesson);
    if (duration == null || duration <= 0) {
      unknown++;
    } else {
      total += duration;
      covered += watched;
    }
    final manual =
        states['${lesson.id}:${lesson.mediaVersion}']?.manualCompletedAt !=
        null;
    if (manual ||
        (duration != null &&
            duration > 0 &&
            watched * 100 >= duration * threshold)) {
      completed++;
    }
  }
  return VideoCourseCoverage(
    total,
    covered,
    unknown,
    lessons.length,
    completed,
  );
}

/// Return the point at which unique visual coverage first reached the threshold.
/// Explicit completion marks and reaching the last frame are not inputs.
DateTime? firstVideoCoverageCompletion(
  List<VideoInterval> intervals,
  VideoLesson lesson,
  int threshold,
) {
  final duration = lesson.durationMs;
  if (duration == null || duration <= 0) return null;
  final target = (duration * threshold / 100).ceil();
  var covered = <VideoRange>[];
  final ordered =
      intervals
          .where(
            (i) =>
                i.lessonId == lesson.id &&
                i.mediaVersion == lesson.mediaVersion &&
                i.mode == VideoActivityMode.visual &&
                i.wallMs > 0 &&
                i.mediaMs > 0,
          )
          .toList()
        ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
  for (final interval in ordered) {
    final start = interval.startMs.clamp(0, duration),
        end = interval.endMs.clamp(0, duration);
    if (end <= start) continue;
    final before = videoRangeLength(covered);
    final updated = mergeVideoRange(covered, start, end);
    if (videoRangeLength(updated) >= target) {
      var remaining = target - before, position = start;
      for (final previous in covered) {
        if (previous.end <= position || previous.start >= end) continue;
        final gap = math.max(0, previous.start - position);
        if (remaining <= gap) break;
        remaining -= gap;
        position = math.max(position, previous.end);
      }
      final point = (position + remaining).clamp(start, end);
      final wall =
          ((point - interval.startMs) * interval.wallMs / interval.mediaMs)
              .round();
      return interval.startedAt.add(Duration(milliseconds: wall));
    }
    covered = updated;
  }
  return null;
}

({int current, int best}) videoStreak(Map<String, int> days, DateTime now) {
  final active = days.entries
      .where((entry) => entry.value > 0)
      .map((entry) => entry.key)
      .toSet();
  var date = DateTime.utc(now.year, now.month, now.day), current = 0;
  if (!active.contains(videoDay(date))) {
    date = date.subtract(const Duration(days: 1));
  }
  while (active.contains(videoDay(date))) {
    current++;
    date = date.subtract(const Duration(days: 1));
  }
  var best = 0, run = 0;
  DateTime? previous;
  for (final day in active.toList()..sort()) {
    final next = DateTime.parse('${day}T00:00:00Z');
    run =
        previous != null && next.difference(previous) == const Duration(days: 1)
        ? run + 1
        : 1;
    best = math.max(best, run);
    previous = next;
  }
  return (current: current, best: best);
}

DateTime _calendar(DateTime reference, int day, {bool includeTime = false}) =>
    reference.isUtc
    ? DateTime.utc(
        reference.year,
        reference.month,
        day,
        includeTime ? reference.hour : 0,
        includeTime ? reference.minute : 0,
        includeTime ? reference.second : 0,
        includeTime ? reference.millisecond : 0,
        includeTime ? reference.microsecond : 0,
      )
    : DateTime(
        reference.year,
        reference.month,
        day,
        includeTime ? reference.hour : 0,
        includeTime ? reference.minute : 0,
        includeTime ? reference.second : 0,
        includeTime ? reference.millisecond : 0,
        includeTime ? reference.microsecond : 0,
      );

class VideoWeekComparison {
  final int currentMs, previousMs;
  const VideoWeekComparison(this.currentMs, this.previousMs);
  double? get percentChange =>
      previousMs == 0 ? null : (currentMs - previousMs) * 100 / previousMs;
}

VideoWeekComparison videoWeekComparison(
  List<VideoInterval> intervals,
  DateTime now, {
  Set<String>? lessonIds,
}) {
  final monday = _calendar(now, now.day - now.weekday + 1);
  final previousMonday = _calendar(now, now.day - now.weekday + 1 - 7);
  final previousEnd = _calendar(now, now.day - 7, includeTime: true);
  int between(DateTime start, DateTime end) => intervals
      .where((i) => lessonIds == null || lessonIds.contains(i.lessonId))
      .fold(
        0,
        (sum, i) =>
            sum +
            math.max(
              0,
              math.min(
                    i.endedAt.millisecondsSinceEpoch,
                    end.millisecondsSinceEpoch,
                  ) -
                  math.max(
                    i.startedAt.millisecondsSinceEpoch,
                    start.millisecondsSinceEpoch,
                  ),
            ),
      );
  return VideoWeekComparison(
    between(monday, now),
    between(previousMonday, previousEnd),
  );
}

class VideoDashboardRequest {
  final VideoAnalysisRequest analysis;
  final DateTime now;
  const VideoDashboardRequest(this.analysis, this.now);
}

class VideoDashboard {
  final VideoStats selected;
  final ({int current, int best}) streak;
  final int todayMs, globalWeekMs;
  final VideoWeekComparison comparison;
  const VideoDashboard(
    this.selected,
    this.streak,
    this.todayMs,
    this.globalWeekMs,
    this.comparison,
  );
}

VideoDashboard analyzeVideoDashboard(VideoDashboardRequest request) {
  final stats = analyzeVideo(request.analysis);
  final all = request.analysis.lessonIds == null
      ? stats
      : analyzeVideo(VideoAnalysisRequest(request.analysis.intervals));
  return VideoDashboard(
    stats,
    videoStreak(stats.lifetimeDays, request.now),
    all.lifetimeDays[videoDay(request.now)] ?? 0,
    videoWeekComparison(request.analysis.intervals, request.now).currentMs,
    videoWeekComparison(
      request.analysis.intervals,
      request.now,
      lessonIds: request.analysis.lessonIds,
    ),
  );
}
