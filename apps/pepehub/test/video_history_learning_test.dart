import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/video/models.dart';
import 'package:pepehub/video/video_activity.dart';
import 'package:pepehub/video/video_repository.dart';

VideoInterval watched(
  VideoLesson lesson,
  String id,
  int start,
  int end,
  DateTime at,
) => VideoInterval(
  id: id,
  sessionId: 's',
  lessonId: lesson.id,
  mediaVersion: lesson.mediaVersion,
  mode: VideoActivityMode.visual,
  startedAt: at,
  offsetMinutes: 0,
  startMs: start,
  endMs: end,
  wallMs: end - start,
  speed: 1,
);

Future<void> save(
  VideoRepository videos,
  VideoLesson lesson,
  List<VideoInterval> intervals, {
  int position = 60000,
  int? duration = 60000,
}) => videos.checkpoint(
  lesson: lesson,
  durationMs: duration,
  progress: VideoProgress(
    lessonId: lesson.id,
    mediaVersion: lesson.mediaVersion,
    positionMs: position,
    speed: 1,
    updatedAt: DateTime.utc(2026, 10, 14),
  ),
  intervals: intervals,
);

void main() {
  test(
    'manual completion and understanding persist without fabricated coverage',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final videos = VideoRepository(Repository(db));
      final item = await videos.addSources(
        title: 'Lesson',
        sources: [const VideoSourceDraft('lesson.mp4', 'Lesson')],
      );
      final lesson = (await videos.lessons(itemId: item.id)).single;
      final at = DateTime.utc(2026, 10, 14);
      await save(videos, lesson, [watched(lesson, 'half', 0, 30000, at)]);
      expect((await videos.learningState(lesson)).coverageCompletedAt, isNull);
      await videos.setLearningState(
        lesson,
        manualComplete: true,
        understood: true,
        at: at,
      );
      final marked = await videos.learningState(lesson);
      expect(marked.manualCompletedAt, at);
      expect(marked.understoodAt, at);
      await videos.setLearningState(
        lesson,
        manualComplete: true,
        at: at.add(const Duration(days: 1)),
      );
      expect((await videos.learningState(lesson)).manualCompletedAt, at);
      final stats = analyzeVideo(
        VideoAnalysisRequest(await videos.intervals()),
      );
      expect(stats.lifetimeUniqueMs, 30000);
      await videos.setLearningState(
        lesson,
        manualComplete: false,
        understood: false,
      );
      expect((await videos.learningState(lesson)).manualCompletedAt, isNull);
      expect((await videos.learningState(lesson)).understoodAt, isNull);
      expect(await videos.intervals(), hasLength(1));
    },
  );

  test('coverage milestone records the crossing once and survives growing checkpoints', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final videos = VideoRepository(Repository(db));
    final item = await videos.addSources(
      title: 'Lesson',
      sources: [const VideoSourceDraft('lesson.mp4', 'Lesson')],
    );
    final lesson = (await videos.lessons(itemId: item.id)).single;
    final at = DateTime.utc(2026, 10, 14, 10);
    await save(videos, lesson, [watched(lesson, 'continuous', 0, 57000, at)]);
    final first = await videos.learningState(lesson);
    expect(first.coverageCompletedAt, at.add(const Duration(seconds: 57)));
    expect(first.coverageThreshold, 95);
    expect(first.manualCompletedAt, isNull);
    await save(videos, lesson, [watched(lesson, 'continuous', 0, 60000, at)]);
    expect(
      (await videos.learningState(lesson)).coverageCompletedAt,
      first.coverageCompletedAt,
    );
    expect(await videos.intervals(), hasLength(1));
  });

  test('learning decisions belong to a media version and do not enter book synchronization', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = Repository(db), videos = VideoRepository(Repository(db));
    final item = await videos.addSources(
      title: 'Lesson',
      sources: [const VideoSourceDraft('lesson.mp4', 'Lesson')],
    );
    final lesson = (await videos.lessons(itemId: item.id)).single;
    await videos.setLearningState(lesson, manualComplete: true);
    final replacement = {...lesson.toJson(), 'mediaVersion': 'replacement'};
    await db.customStatement('UPDATE records SET payload=? WHERE id=?', [
      jsonEncode(replacement),
      lesson.id,
    ]);
    final next = VideoLesson.fromJson(lesson.id, replacement);
    expect((await videos.learningState(next)).manualCompletedAt, isNull);
    await expectLater(
      videos.setLearningState(lesson, understood: true),
      throwsStateError,
    );
    expect((await videos.learningState(lesson)).manualCompletedAt, isNotNull);
    expect(await repo.pendingCount(), 0);
  });

  test('history keyset handles identical timestamps, old payloads and a growing checkpoint', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final videos = VideoRepository(Repository(db));
    final item = await videos.addSources(
      title: 'Lesson',
      sources: [const VideoSourceDraft('lesson.mp4', 'Lesson')],
    );
    final lesson = (await videos.lessons(itemId: item.id)).single;
    final at = DateTime.utc(2026, 10, 14, 10);
    await save(videos, lesson, [
      for (var i = 0; i < 45; i++)
        watched(
          lesson,
          'interval-${i.toString().padLeft(3, '0')}',
          i * 1000,
          (i + 1) * 1000,
          at,
        ),
    ], duration: 120000);
    await db.customStatement(
      "UPDATE records SET payload=json_remove(payload,'\$.startEpochMs','\$.endEpochMs') WHERE id=?",
      ['interval-020'],
    );
    final first = await videos.history(limit: 20);
    expect(first.intervals, hasLength(20));
    expect(first.next, isNotNull);
    final boundary = first.intervals.last;
    await save(videos, lesson, [
      watched(lesson, boundary.id, boundary.startMs, boundary.endMs + 100, at),
    ], duration: 120000);
    final second = await videos.history(limit: 20, before: first.next);
    final third = await videos.history(limit: 20, before: second.next);
    expect(third.intervals, hasLength(5));
    expect(third.next, isNull);
    expect(
      {
        ...first.intervals,
        ...second.intervals,
        ...third.intervals,
      }.map((i) => i.id).toSet(),
      hasLength(45),
    );
    expect(second.intervals.any((i) => i.id == boundary.id), isFalse);
    expect((await videos.history(lessonIds: {})).intervals, isEmpty);
  });

  test('history includes an interval spanning the chosen period and excludes deleted entries', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final videos = VideoRepository(Repository(db));
    final item = await videos.addSources(
      title: 'Lesson',
      sources: [const VideoSourceDraft('lesson.mp4', 'Lesson')],
    );
    final lesson = (await videos.lessons(itemId: item.id)).single;
    final at = DateTime.utc(2026, 10, 14, 10);
    await save(videos, lesson, [
      watched(lesson, 'wide', 0, 30000, at),
      watched(lesson, 'deleted', 0, 30000, at),
      watched(lesson, 'late', 0, 1000, at.add(const Duration(minutes: 1))),
    ]);
    await db.customStatement('UPDATE records SET deleted=1 WHERE id=?', [
      'deleted',
    ]);
    final page = await videos.history(
      start: at.add(const Duration(seconds: 5)),
      end: at.add(const Duration(seconds: 10)),
    );
    expect(page.intervals.map((i) => i.id), ['wide']);
  });

  test('preferences validate and retain independent daily, weekly and coverage goals', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final videos = VideoRepository(Repository(db));
    await videos.savePreferences(
      const VideoPreferences(
        dailyMinutes: 25,
        weeklyMinutes: 150,
        completionPercent: 90,
      ),
    );
    final value = await videos.preferences();
    expect(value.dailyMinutes, 25);
    expect(value.weeklyMinutes, 150);
    expect(value.completionPercent, 90);
    await expectLater(
      videos.savePreferences(const VideoPreferences(dailyMinutes: -1)),
      throwsArgumentError,
    );
    await expectLater(
      videos.savePreferences(const VideoPreferences(completionPercent: 0)),
      throwsArgumentError,
    );
    expect((await videos.preferences()).dailyMinutes, 25);
  });
}
