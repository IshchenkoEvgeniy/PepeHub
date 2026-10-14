import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/video/models.dart';
import 'package:pepehub/video/video_activity.dart';
import 'package:pepehub/video/video_controller.dart';
import 'package:pepehub/video/video_repository.dart';

import 'support/video_engine.dart';

void main() {
  test('resuming after a long pause starts a new persisted session', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = Repository(db), videos = VideoRepository(Repository(db));
    final item = await videos.addSources(
      title: 'Lesson',
      sources: [const VideoSourceDraft('lesson.mp4', 'Lesson')],
    );
    final engine = TestVideoEngine();
    var ms = 0;
    final controller = VideoPlaybackController(
      repository: videos,
      engine: engine,
      lessons: await videos.lessons(itemId: item.id),
      checkpointPeriod: null,
      nowMonotonic: () => ms,
      now: () => DateTime.utc(2026, 10, 14).add(Duration(milliseconds: ms)),
    );
    await controller.load(0);
    final firstId = controller.sessionId;
    ms = 1000;
    engine.tick(1000);
    await controller.pause();
    ms = 181000;
    await controller.play();
    expect(controller.sessionId, firstId);
    ms = 182000;
    engine.tick(2000);
    await controller.pause();
    ms = 600000;
    await controller.play();
    expect(controller.sessionId, isNot(firstId));
    ms = 601000;
    engine.tick(3000);
    await controller.close();
    controller.dispose();
    final stats = analyzeVideo(VideoAnalysisRequest(await videos.intervals()));
    expect(stats.sessions, hasLength(2));
    expect(stats.wallMs, 3000);
    final events = await repo.records('video_event');
    expect(
      events.every((event) => event.payload!['sessionId'] is String),
      isTrue,
    );
  });

  test(
    'rapid next-lesson commands use the result of the preceding command',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final videos = VideoRepository(Repository(db));
      final item = await videos.addSources(
        title: 'Course',
        sources: [
          const VideoSourceDraft('one.mp4', 'One'),
          const VideoSourceDraft('two.mp4', 'Two'),
          const VideoSourceDraft('three.mp4', 'Three'),
        ],
      );
      final controller = VideoPlaybackController(
        repository: videos,
        engine: TestVideoEngine(),
        lessons: await videos.lessons(itemId: item.id),
        checkpointPeriod: null,
      );
      await controller.load(0);
      await Future.wait([controller.next(), controller.next()]);
      expect(controller.index, 2);
      expect(controller.current!.title, 'Three');
      await controller.previous();
      expect(controller.current!.title, 'Two');
      await controller.close();
      controller.dispose();
    },
  );
  test('rapid relative seeks serialize, coverage excludes jumps and position restores', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final videos = VideoRepository(Repository(db));
    final item = await videos.addSources(
      title: 'Lecture',
      sources: [const VideoSourceDraft('lecture.mp4', 'Lecture')],
    );
    final lessons = await videos.lessons(itemId: item.id);
    final engine = TestVideoEngine();
    var ms = 0;
    final controller = VideoPlaybackController(
      repository: videos,
      engine: engine,
      lessons: lessons,
      checkpointPeriod: null,
      nowMonotonic: () => ms,
      now: () => DateTime.utc(2026, 10, 14, 10).add(Duration(milliseconds: ms)),
    );
    await controller.load(0);
    ms = 1000;
    engine.tick(1000);
    ms = 5000;
    engine.tick(5000);
    await Future.wait([
      controller.skip(10000),
      controller.skip(10000),
      controller.skip(10000),
    ]);
    expect(engine.seeks, [15000, 25000, 35000]);
    await controller.setSpeed(2);
    ms = 6000;
    engine.tick(37000);
    await controller.close();
    controller.dispose();
    final stats = analyzeVideo(VideoAnalysisRequest(await videos.intervals()));
    expect(stats.wallMs, 6000);
    expect(stats.mediaMs, 7000);
    expect(stats.firstMs, 7000);
    expect(stats.repeatedMs, 0);
    expect((await videos.progress(lessons.single))!.positionMs, 37000);
    final resumedEngine = TestVideoEngine();
    final resumed = VideoPlaybackController(
      repository: videos,
      engine: resumedEngine,
      lessons: lessons,
      checkpointPeriod: null,
    );
    await resumed.load(0, play: false);
    expect(resumed.state.positionMs, 37000);
    expect(resumed.state.speed, 2);
    await resumed.close();
    resumed.dispose();
  });

  test('background and buffering add no time; reaching the end by seek creates no coverage', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final videos = VideoRepository(Repository(db));
    final item = await videos.addSources(
      title: 'Lesson',
      sources: [const VideoSourceDraft('lesson.mp4', 'Lesson')],
    );
    final lessons = await videos.lessons(itemId: item.id);
    final engine = TestVideoEngine();
    var ms = 0;
    final controller = VideoPlaybackController(
      repository: videos,
      engine: engine,
      lessons: lessons,
      checkpointPeriod: null,
      nowMonotonic: () => ms,
      now: () => DateTime.utc(2026, 10, 14).add(Duration(milliseconds: ms)),
    );
    await controller.load(0);
    ms = 2000;
    engine.tick(2000);
    engine.tick(2000, buffering: true);
    ms = 62000;
    engine.tick(2000, buffering: true);
    engine.tick(2000, buffering: false);
    ms = 63000;
    engine.tick(3000);
    await controller.setForeground(false);
    expect(engine.state.playing, isFalse);
    ms = 90000;
    engine.tick(3000);
    await controller.setForeground(true);
    expect(engine.state.playing, isFalse);
    await controller.seek(120000);
    engine.tick(120000, completed: true);
    await controller.close();
    controller.dispose();
    final stats = analyzeVideo(VideoAnalysisRequest(await videos.intervals()));
    expect(stats.wallMs, 3000);
    expect(stats.lifetimeUniqueMs, 3000);
    expect(stats.lifetimeUniqueMs, lessThan(engine.state.durationMs));
  });

  test(
    'storage failure retains pending intervals and failed close can retry',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final videos = _FailOnceVideos(Repository(db));
      final item = await videos.addSources(
        title: 'Lesson',
        sources: [const VideoSourceDraft('lesson.mp4', 'Lesson')],
      );
      final engine = TestVideoEngine();
      var ms = 0;
      final controller = VideoPlaybackController(
        repository: videos,
        engine: engine,
        lessons: await videos.lessons(itemId: item.id),
        checkpointPeriod: null,
        nowMonotonic: () => ms,
        now: () => DateTime.utc(2026, 10, 14).add(Duration(milliseconds: ms)),
      );
      await controller.load(0);
      ms = 2000;
      engine.tick(2000);
      videos.failNext = true;
      await expectLater(controller.flush(), throwsStateError);
      expect(controller.storageError, isNotNull);
      await controller.flush();
      expect((await videos.intervals()).single.wallMs, 2000);
      ms = 3000;
      engine.tick(3000);
      videos.failNext = true;
      await expectLater(controller.close(), throwsStateError);
      expect(engine.closed, isFalse);
      await controller.close();
      controller.dispose();
      expect(engine.closed, isTrue);
      expect((await videos.intervals()).single.wallMs, 3000);
    },
  );

  test(
    'failed next lesson does not overwrite the preceding lesson progress',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final videos = VideoRepository(Repository(db));
      final item = await videos.addSources(
        title: 'Course',
        sources: [
          const VideoSourceDraft('one.mp4', 'One'),
          const VideoSourceDraft('two.mp4', 'Two'),
        ],
      );
      final lessons = await videos.lessons(itemId: item.id);
      final engine = TestVideoEngine();
      final controller = VideoPlaybackController(
        repository: videos,
        engine: engine,
        lessons: lessons,
        checkpointPeriod: null,
      );
      await controller.load(0);
      engine.tick(42000);
      engine.failOpen = true;
      await expectLater(controller.load(1), throwsStateError);
      expect(controller.current, isNull);
      expect((await videos.progress(lessons.first))!.positionMs, 42000);
      expect(await videos.progress(lessons.last), isNull);
      await controller.close();
      controller.dispose();
    },
  );
}

class _FailOnceVideos extends VideoRepository {
  bool failNext = false;
  _FailOnceVideos(super.repository);
  @override
  Future<void> checkpoint({
    required VideoLesson lesson,
    required VideoProgress progress,
    required List<VideoInterval> intervals,
    int? durationMs,
  }) async {
    if (failNext) {
      failNext = false;
      throw StateError('Disk unavailable');
    }
    await super.checkpoint(
      lesson: lesson,
      progress: progress,
      intervals: intervals,
      durationMs: durationMs,
    );
  }
}
