import 'models.dart';

/// How far a file or a whole video or course has been watched.
enum VideoWatchState { fresh, started, done }

/// Status filters of the media list, saved between launches.
const videoStatusLabels = {
  'all': 'Все',
  'new': 'Новые',
  'fresh': 'Не начаты',
  'started': 'В процессе',
  'done': 'Досмотрены',
};

/// Length filters of the media list, by the total length of an item.
const videoLengthLabels = {
  'all': 'Любая длина',
  'short': 'До 20 минут',
  'medium': '20–60 минут',
  'long': 'Дольше часа',
};

bool videoLengthMatches(String filter, int totalMs) => switch (filter) {
  'short' => totalMs > 0 && totalMs < 20 * 60000,
  'medium' => totalMs >= 20 * 60000 && totalMs <= 60 * 60000,
  'long' => totalMs > 60 * 60000,
  _ => true,
};

/// Progress saved for this very file, not for a replaced one.
VideoProgress? videoOwnProgress(
  VideoLesson lesson,
  Map<String, VideoProgress> progress,
) {
  final saved = progress[lesson.id];
  return saved?.mediaVersion == lesson.mediaVersion ? saved : null;
}

/// A file is done when marked so, when the watched share reached the
/// threshold, or when it was left in its last ten seconds.
VideoWatchState videoLessonState(
  VideoLesson lesson,
  Map<String, VideoProgress> progress,
  Map<String, VideoLearningState> learning,
) {
  final state = learning['${lesson.id}:${lesson.mediaVersion}'];
  if (state?.manualCompletedAt != null || state?.coverageCompletedAt != null) {
    return VideoWatchState.done;
  }
  final saved = videoOwnProgress(lesson, progress);
  if (saved == null || saved.positionMs <= 0) return VideoWatchState.fresh;
  final duration = lesson.durationMs;
  if (duration != null &&
      duration > 20000 &&
      saved.positionMs >= duration - 10000) {
    return VideoWatchState.done;
  }
  return VideoWatchState.started;
}

/// Done when every file is done, fresh when none was opened.
VideoWatchState videoItemState(
  Iterable<VideoLesson> lessons,
  Map<String, VideoProgress> progress,
  Map<String, VideoLearningState> learning,
) {
  var any = false, all = true, empty = true;
  for (final lesson in lessons) {
    empty = false;
    final state = videoLessonState(lesson, progress, learning);
    if (state != VideoWatchState.fresh) any = true;
    if (state != VideoWatchState.done) all = false;
  }
  if (empty || !any) return VideoWatchState.fresh;
  return all ? VideoWatchState.done : VideoWatchState.started;
}

/// One entry of «Продолжить просмотр».
class VideoContinueEntry {
  final VideoItem item;
  final VideoLesson lesson;

  /// Null when the entry is the next lesson after a finished one.
  final VideoProgress? progress;
  final DateTime watchedAt;
  const VideoContinueEntry(
    this.item,
    this.lesson,
    this.progress,
    this.watchedAt,
  );

  /// Hidden entries come back once something newer is watched.
  String get hideKey => '${item.id}@${watchedAt.toUtc().toIso8601String()}';
}

/// Per video or course: the file watched last when it is not finished,
/// otherwise the next unfinished file of a course. Newest first.
List<VideoContinueEntry> videoContinueEntries({
  required List<VideoItem> items,
  required Map<String, List<VideoLesson>> lessonsByItem,
  required Map<String, VideoProgress> progress,
  required Map<String, VideoLearningState> learning,
  Set<String> hidden = const {},
  int limit = 12,
}) {
  final entries = <VideoContinueEntry>[];
  for (final item in items) {
    final own = [
      for (final lesson in lessonsByItem[item.id] ?? const <VideoLesson>[])
        if (!lesson.isAudio) lesson,
    ];
    VideoLesson? last;
    VideoProgress? lastProgress;
    for (final lesson in own) {
      final saved = videoOwnProgress(lesson, progress);
      if (saved != null &&
          (lastProgress == null ||
              saved.updatedAt.isAfter(lastProgress.updatedAt))) {
        last = lesson;
        lastProgress = saved;
      }
    }
    if (last == null || lastProgress == null) continue;
    VideoContinueEntry? entry;
    final state = videoLessonState(last, progress, learning);
    if (state == VideoWatchState.started &&
        lastProgress.positionMs >= 5000 &&
        last.available) {
      entry = VideoContinueEntry(item, last, lastProgress, lastProgress.updatedAt);
    } else if (state == VideoWatchState.done) {
      final start = own.indexOf(last);
      for (var i = start + 1; i < own.length; i++) {
        if (own[i].available &&
            videoLessonState(own[i], progress, learning) !=
                VideoWatchState.done) {
          entry = VideoContinueEntry(
            item,
            own[i],
            videoOwnProgress(own[i], progress),
            lastProgress.updatedAt,
          );
          break;
        }
      }
    }
    if (entry != null && !hidden.contains(entry.hideKey)) entries.add(entry);
  }
  entries.sort((a, b) => b.watchedAt.compareTo(a.watchedAt));
  return entries.take(limit).toList();
}
