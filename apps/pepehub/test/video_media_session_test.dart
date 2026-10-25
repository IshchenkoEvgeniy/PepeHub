import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/shared_media_handler.dart';
import 'package:pepehub/video/models.dart';
import 'package:pepehub/video/video_activity.dart';
import 'package:pepehub/video/video_controller.dart';
import 'package:pepehub/video/video_repository.dart';
import 'package:pepehub/video/video_session.dart';

import 'support/video_engine.dart';

class _Timer implements Timer {
  final void Function() callback;
  bool active = true;
  _Timer(this.callback);
  @override
  bool get isActive => active;
  @override
  int get tick => 0;
  @override
  void cancel() {
    active = false;
  }

  void fire() {
    active = false;
    callback();
  }
}

class _Handler extends BaseAudioHandler {
  final List<String> calls = [];
  @override
  Future<void> play() async {
    calls.add('play');
  }

  @override
  Future<void> seek(Duration position) async {
    calls.add('seek:${position.inMilliseconds}');
  }
}

class _Harness {
  final db = AppDatabase(NativeDatabase.memory());
  late final repository = Repository(db), videos = VideoRepository(repository);
  final engine = TestVideoEngine();
  final timers = <_Timer>[];
  late VideoPlaybackController player;
  late VideoItem item;
  late List<VideoLesson> lessons;
  int clock = 0;
  Future<void> open() async {
    item = await videos.addSources(
      title: 'Course',
      sources: const [
        VideoSourceDraft('one.mp4', 'One'),
        VideoSourceDraft('two.mp4', 'Two'),
      ],
    );
    lessons = await videos.lessons(itemId: item.id);
    player = VideoPlaybackController(
      repository: videos,
      engine: engine,
      lessons: lessons,
      checkpointPeriod: null,
      nowMonotonic: () => clock,
      now: () => DateTime.utc(2026, 10, 14).add(Duration(milliseconds: clock)),
      createSleepTimer: (_, callback) {
        final timer = _Timer(callback);
        timers.add(timer);
        return timer;
      },
    );
    await player.load(0);
  }

  Future<void> close() async {
    await player.close();
    player.dispose();
    await db.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'back-to-back gain and permanent loss cannot strand or restart the player',
    () async {
      final h = _Harness();
      await h.open();
      addTearDown(h.close);
      final begin = h.player.handleInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.duck),
      );
      final end = h.player.handleInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.duck),
      );
      await Future.wait([begin, end]);
      expect(h.player.state.playing, isTrue);
      final again = h.player.handleInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.duck),
      );
      final permanent = h.player.handleInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.unknown),
      );
      await Future.wait([again, permanent]);
      await h.player.handleInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      expect(h.player.state.playing, isFalse);
    },
  );
  test('temporary focus pause retains its request and resumes at the same position', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.close);
    h.engine.tick(42000);
    await h.player.handleInterruption(
      AudioInterruptionEvent(true, AudioInterruptionType.duck),
    );
    expect(h.player.state.playing, isFalse);
    expect(h.player.retainsAudioFocus, isTrue);
    await h.player.handleInterruption(
      AudioInterruptionEvent(true, AudioInterruptionType.duck),
    );
    await h.player.handleInterruption(
      AudioInterruptionEvent(false, AudioInterruptionType.duck),
    );
    expect(h.player.state.playing, isTrue);
    expect(h.player.positionMs, 42000);
    expect(h.player.retainsAudioFocus, isFalse);
  });
  test(
    'manual pause and permanent focus loss cancel a pending automatic resume',
    () async {
      final h = _Harness();
      await h.open();
      addTearDown(h.close);
      await h.player.handleInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.pause),
      );
      await h.player.pause();
      expect(h.player.retainsAudioFocus, isFalse);
      await h.player.handleInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      expect(h.player.state.playing, isFalse);
      await h.player.play();
      await h.player.handleInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.unknown),
      );
      await h.player.handleInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      expect(h.player.state.playing, isFalse);
      await h.player.play();
      expect(h.player.state.playing, isTrue);
    },
  );
  test('a late focus gain cannot bypass an expired sleep timer', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.close);
    await h.player.setSleepTimer(const Duration(seconds: 1));
    await h.player.handleInterruption(
      AudioInterruptionEvent(true, AudioInterruptionType.duck),
    );
    h.clock = 1500;
    await h.player.handleInterruption(
      AudioInterruptionEvent(false, AudioInterruptionType.duck),
    );
    expect(h.player.state.playing, isFalse);
    h.timers.last.fire();
    await h.player.flush();
    expect(h.player.state.playing, isFalse);
  });
  test('manual source change discards the old interruption intent', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.close);
    await h.player.handleInterruption(
      AudioInterruptionEvent(true, AudioInterruptionType.duck),
    );
    await h.player.load(1, play: false);
    await h.player.handleInterruption(
      AudioInterruptionEvent(false, AudioInterruptionType.duck),
    );
    expect(h.player.index, 1);
    expect(h.player.state.playing, isFalse);
  });
  test('audio in the background and visible PiP remain separate from hidden video time', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.close);
    h.clock = 1000;
    h.engine.tick(1000);
    await h.player.setAudioOnly(true);
    h.clock = 2000;
    h.engine.tick(2000);
    await h.player.setForeground(false);
    expect(h.engine.state.playing, isTrue);
    h.clock = 3000;
    h.engine.tick(3000);
    await h.player.setAudioOnly(false);
    expect(h.engine.state.playing, isFalse);
    h.clock = 4000;
    h.engine.tick(4000);
    await h.player.setPipVisible(true);
    await h.player.play();
    h.clock = 5000;
    h.engine.tick(5000);
    await h.player.setPipVisible(false);
    expect(h.engine.state.playing, isFalse);
    await h.player.flush();
    final stats = analyzeVideo(
      VideoAnalysisRequest(await h.videos.intervals()),
    );
    expect(stats.modeTime[VideoActivityMode.visual], 2000);
    expect(stats.modeTime[VideoActivityMode.audio], 2000);
    expect(stats.wallMs, 4000);
    expect(stats.lessonCoverage(h.lessons.first), 2000);
    expect(
      stats.lessonCoverage(h.lessons.first, mode: VideoActivityMode.audio),
      2000,
    );
  });
  test('a replaced sleep timer cannot pause playback; deadline timer cancels loops and persists', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.close);
    await h.player.setSleepTimer(const Duration(seconds: 1));
    await h.player.setSleepTimer(const Duration(seconds: 2));
    h.timers.first.fire();
    await h.player.flush();
    expect(h.engine.state.playing, isTrue);
    h.clock = 1000;
    h.engine.tick(1000);
    expect(h.player.sleepRemainingMs, 1000);
    h.timers.last.fire();
    await h.player.flush();
    expect(h.engine.state.playing, isFalse);
    expect(h.player.sleepRemainingMs, isNull);
    expect((await h.videos.progress(h.lessons.first))!.positionMs, 1000);
  });
  test('end-of-lesson sleep cancels on manual next lesson and stops at the current end', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.close);
    await h.player.setSleepTimer(null, untilLessonEnd: true);
    await h.player.next();
    expect(h.player.sleepAtLessonEnd, isFalse);
    await h.player.setSleepTimer(null, untilLessonEnd: true);
    h.engine.tick(120000, completed: true);
    await h.player.flush();
    expect(h.player.sleepAtLessonEnd, isFalse);
    expect(h.engine.state.playing, isFalse);
    expect((await h.videos.progress(h.lessons.last))!.positionMs, 120000);
  });
  test('the shared system handler changes owner without receiving stale book events', () async {
    final books = _Handler(), video = _Handler();
    final handler = SharedMediaHandler(books);
    addTearDown(handler.close);
    books.mediaItem.add(const MediaItem(id: 'book', title: 'Book'));
    await Future<void>.delayed(Duration.zero);
    handler.setOwner(video);
    video.mediaItem.add(const MediaItem(id: 'lesson', title: 'Lesson'));
    books.mediaItem.add(const MediaItem(id: 'old', title: 'Old book callback'));
    await Future<void>.delayed(Duration.zero);
    expect(handler.mediaItem.value?.id, 'lesson');
    await handler.play();
    await handler.seek(const Duration(seconds: 4));
    expect(video.calls, ['play', 'seek:4000']);
    expect(books.calls, isEmpty);
    handler.release(video);
    await handler.play();
    expect(books.calls, ['play']);
  });
  test(
    'mini session reopening and next lesson reuse the same decoder',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final store = VideoRepository(Repository(db));
      final item = await store.addSources(
        title: 'Course',
        sources: const [
          VideoSourceDraft('one', 'One'),
          VideoSourceDraft('two', 'Two'),
        ],
      );
      final lessons = await store.lessons(itemId: item.id);
      final engine = TestVideoEngine();
      var created = 0;
      final session = VideoPlaybackSession(
        store,
        engineFactory: () {
          created++;
          return engine;
        },
      );
      addTearDown(() async {
        await session.close();
        session.dispose();
        await db.close();
      });
      await session.open(item, lessons, 0);
      engine.tick(45000);
      session.attachPage();
      session.requestMini();
      session.detachPage();
      expect(session.inMini, isTrue);
      await session.open(item, lessons, 0);
      session.attachPage();
      expect(created, 1);
      expect(engine.state.positionMs, 45000);
      expect(engine.seeks, isEmpty);
      await session.open(item, lessons, 1);
      expect(created, 1);
      expect(session.controller!.current?.id, lessons.last.id);
    },
  );
  test('course reordering and renaming preserve media identity, progress and notes', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.close);
    h.clock = 1000;
    h.engine.tick(1000);
    await h.player.pause();
    final note = await h.videos.saveAnnotation(
      h.lessons.first,
      title: 'Quote',
      body: 'Keep this',
      startMs: 500,
    );
    final token = VideoRepository.structureToken(h.item, h.lessons);
    await h.videos.saveCourseStructure(
      h.item,
      title: 'Renamed course',
      token: token,
      ordered: [
        VideoLessonEdit(h.lessons.last.id, 'Second first', 'Module A'),
        VideoLessonEdit(h.lessons.first.id, 'First second', 'Module B'),
      ],
    );
    final next = await h.videos.lessons(itemId: h.item.id);
    expect(next.map((lesson) => lesson.id), [
      h.lessons.last.id,
      h.lessons.first.id,
    ]);
    expect(next.last.mediaVersion, h.lessons.first.mediaVersion);
    expect((await h.videos.progress(next.last))!.positionMs, 1000);
    expect((await h.videos.annotations(next.last)).single.id, note.id);
    await h.videos.setFavorite(h.item, true);
    expect((await h.videos.items()).single.title, 'Renamed course');
    await expectLater(
      h.videos.saveCourseStructure(
        h.item,
        title: 'Stale overwrite',
        token: token,
        ordered: [
          for (final lesson in h.lessons)
            VideoLessonEdit(lesson.id, lesson.title, lesson.module),
        ],
      ),
      throwsStateError,
    );
    expect(await h.repository.pending(), isEmpty);
  });
}
