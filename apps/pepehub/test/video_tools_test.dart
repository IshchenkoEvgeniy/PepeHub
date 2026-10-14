import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/video/models.dart';
import 'package:pepehub/video/video_activity.dart';
import 'package:pepehub/video/video_controller.dart';
import 'package:pepehub/video/video_repository.dart';
import 'package:pepehub/video/video_tools.dart';
import 'package:pepehub/video/video_fullscreen.dart';

import 'support/video_engine.dart';

class _Harness {
  final db = AppDatabase(NativeDatabase.memory());
  late final repository = Repository(db), videos = VideoRepository(repository);
  final TestVideoEngine engine;
  late VideoPlaybackController player;
  late List<VideoLesson> lessons;
  int ms = 0;
  _Harness({TestVideoEngine? engine}) : engine = engine ?? TestVideoEngine();
  Future<void> open() async {
    final item = await videos.addSources(
      title: 'English',
      sources: const [
        VideoSourceDraft('lesson1.mp4', 'Lesson 1'),
        VideoSourceDraft('lesson2.mp4', 'Lesson 2'),
      ],
    );
    lessons = await videos.lessons(itemId: item.id);
    player = VideoPlaybackController(
      repository: videos,
      engine: engine,
      lessons: lessons,
      checkpointPeriod: null,
      nowMonotonic: () => ms,
      now: () => DateTime.utc(2026, 10, 14).add(Duration(milliseconds: ms)),
    );
    await player.load(0);
  }

  Future<void> close() async {
    await player.close();
    player.dispose();
    await db.close();
  }
}

class _DelayedSeekEngine extends TestVideoEngine {
  int? target;
  @override
  Future<void> seek(int positionMs) async {
    seeks.add(positionMs);
    target = positionMs;
  }

  void acknowledge() {
    tick(target!, completed: false);
    target = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Windows and modern Android fullscreen use the native window protocol',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(VideoFullscreenHost.channel, (call) async {
            calls.add(call);
            return null;
          });
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(VideoFullscreenHost.channel, null);
      });
      for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
        debugDefaultTargetPlatformOverride = platform;
        await VideoFullscreenHost().setFullscreen(true);
        await VideoFullscreenHost().setFullscreen(false);
      }
      expect(calls.map((call) => call.method), everyElement('setFullscreen'));
      expect(calls.map((call) => call.arguments), [true, false, true, false]);
    },
  );
  test('timestamps retain milliseconds and reject malformed clocks', () {
    expect(parseVideoTimestamp('1:02:03.125'), 3723125);
    expect(parseVideoTimestamp('62:03,5'), 3723500);
    expect(parseVideoTimestamp(' 12.001 '), 12001);
    expect(videoTimestamp(3723125, precise: true), '1:02:03.125');
    expect(videoTimestamp(60000), '1:00');
    for (final value in [
      '',
      '-1',
      '1:60',
      '1:60:00',
      '1:02:03:04',
      '1e3',
      'NaN',
      '2.0001',
      'abc',
    ]) {
      expect(parseVideoTimestamp(value), isNull, reason: value);
    }
    expect(
      () => const VideoLoopSettings(startMs: 10, endMs: 400).validate(),
      throwsArgumentError,
    );
    expect(
      () => const VideoLoopSettings(
        startMs: 0,
        endMs: 500,
        totalPasses: 101,
      ).validate(),
      throwsArgumentError,
    );
    expect(
      () => const VideoLoopSettings(
        startMs: 0,
        endMs: 501,
      ).validate(durationMs: 500),
      throwsArgumentError,
    );
  });

  test('three accelerated passes persist real time and repeats without counting loop seeks', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.close);
    await h.player.setSpeed(2);
    await h.player.startLoop(
      const VideoLoopSettings(startMs: 10000, endMs: 12000, totalPasses: 3),
    );
    for (var pass = 0; pass < 3; pass++) {
      h.ms += 500;
      h.engine.tick(11000);
      h.ms += 500;
      h.engine.tick(12000);
      await h.player.flush();
    }
    expect(h.player.loopRunning, isFalse);
    expect(h.player.loopCompletedPasses, 3);
    expect(h.engine.state.playing, isFalse);
    expect(h.engine.seeks, [10000, 10000, 10000]);
    expect(h.player.seekHistory, isEmpty);
    final stats = analyzeVideo(
      VideoAnalysisRequest(await h.videos.intervals()),
    );
    expect(stats.wallMs, 3000);
    expect(stats.mediaMs, 6000);
    expect(stats.firstMs, 2000);
    expect(stats.repeatedMs, 4000);
    expect(stats.sessions, hasLength(1));
    final events = await h.repository.records('video_event');
    expect(
      events.where((e) => e.payload!['kind'] == 'loop-pass'),
      hasLength(3),
    );
    expect(
      events
          .where((e) => e.payload!['kind'] == 'seek')
          .every((e) => e.payload!['reason'].toString().startsWith('loop-')),
      isTrue,
    );
  });

  test(
    'delayed native positions cannot trigger duplicate loop passes',
    () async {
      final h = _Harness(engine: _DelayedSeekEngine());
      // Use the same delayed adapter throughout the controller lifetime.
      final delayed = h.engine as _DelayedSeekEngine;
      await h.open();
      addTearDown(h.close);
      await h.player.startLoop(
        const VideoLoopSettings(startMs: 5000, endMs: 7000, totalPasses: 3),
      );
      delayed.acknowledge();
      h.ms = 1000;
      delayed.tick(6000);
      h.ms = 2000;
      delayed.tick(7000);
      await h.player.flush();
      expect(h.player.loopCompletedPasses, 1);
      delayed.tick(7000, volume: 20);
      await h.player.flush();
      delayed.tick(7000, volume: 30);
      await h.player.flush();
      expect(h.player.loopCompletedPasses, 1);
      delayed.acknowledge();
      h.ms = 3000;
      delayed.tick(6000);
      h.ms = 4000;
      delayed.tick(7000);
      await h.player.flush();
      expect(h.player.loopCompletedPasses, 2);
    },
  );

  test('a pause for speaking contributes no watched time and resumes the next pass', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.close);
    await h.player.startLoop(
      const VideoLoopSettings(
        startMs: 5000,
        endMs: 6000,
        totalPasses: 2,
        pauseMs: 30,
      ),
    );
    h.ms = 1000;
    h.engine.tick(6000);
    await h.player.flush();
    expect(h.player.loopWaiting, isTrue);
    expect(h.engine.state.playing, isFalse);
    h.ms = 6000;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await h.player.flush();
    expect(h.player.loopWaiting, isFalse);
    expect(h.engine.state.playing, isTrue);
    h.ms = 7000;
    h.engine.tick(6000);
    await h.player.flush();
    final stats = analyzeVideo(
      VideoAnalysisRequest(await h.videos.intervals()),
    );
    expect(stats.wallMs, 2000);
    expect(stats.mediaMs, 2000);
    expect(stats.firstMs, 1000);
    expect(stats.repeatedMs, 1000);
  });

  test('waiting loops stay stopped after pause, seek, background, lesson change or close', () async {
    for (final action in ['pause', 'seek', 'background', 'next', 'close']) {
      final h = _Harness();
      await h.open();
      await h.player.startLoop(
        const VideoLoopSettings(startMs: 1000, endMs: 2000, pauseMs: 30),
      );
      h.ms = 1000;
      h.engine.tick(2000);
      await h.player.flush();
      switch (action) {
        case 'pause':
          await h.player.pause();
        case 'seek':
          await h.player.seek(30000);
        case 'background':
          await h.player.setForeground(false);
        case 'next':
          await h.player.next();
        case 'close':
          await h.player.close();
      }
      final seeks = List.of(h.engine.seeks), opens = h.player.index;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(h.player.loopRunning, isFalse, reason: action);
      expect(h.engine.seeks, seeks, reason: action);
      expect(h.player.index, opens);
      expect(
        (await h.videos.intervals()).fold<int>(0, (sum, i) => sum + i.wallMs),
        1000,
      );
      await h.close();
    }
  });

  test('an EOF repeat returns to A and manual navigation keeps a separate undo history', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.close);
    await h.player.startLoop(
      const VideoLoopSettings(startMs: 118000, endMs: 120000, totalPasses: 2),
    );
    h.ms = 1000;
    h.engine.tick(119000);
    h.ms = 2000;
    h.engine.tick(120000, playing: false, completed: true);
    await h.player.flush();
    expect(h.player.loopCompletedPasses, 1);
    expect(h.player.positionMs, 118000);
    expect(h.engine.state.playing, isTrue);
    await h.player.seek(50000);
    expect(h.player.loopRunning, isFalse);
    expect(h.player.seekHistory, hasLength(1));
    await h.player.skip(10000);
    await h.player.returnFromSeek();
    expect(h.player.positionMs, 50000);
    await h.player.returnFromSeek();
    expect(h.player.positionMs, 118000);
    expect(h.player.seekHistory, isEmpty);
    await h.player.toggleMute();
    expect(h.engine.state.volume, 0);
    await h.player.toggleMute();
    expect(h.engine.state.volume, 100);
    await h.player.next();
    expect(h.player.loop, isNull);
    expect(h.player.seekHistory, isEmpty);
  });

  test('annotation edits preserve identity and timestamps without writing playback or outbox', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.close);
    final lesson = h.lessons.first, created = DateTime.utc(2026, 10, 12);
    final note = await h.videos.saveAnnotation(
      lesson,
      title: ' Phrase ',
      body: ' Explanation ',
      startMs: 10000,
      endMs: 15000,
      at: created,
    );
    final updated = await h.videos.saveAnnotation(
      lesson,
      existing: note,
      title: 'Question',
      body: 'Why this tense?',
      startMs: 11000,
      endMs: 16000,
      at: created.add(const Duration(days: 1)),
    );
    expect(updated.id, note.id);
    expect(updated.revision, 2);
    expect(updated.createdAt, created);
    expect(updated.updatedAt, created.add(const Duration(days: 1)));
    expect((await h.videos.annotations(lesson)).single.body, 'Why this tense?');
    expect(await h.videos.intervals(), isEmpty);
    expect(await h.videos.progress(lesson), isNull);
    expect(await h.repository.pending(), isEmpty);
    await expectLater(
      h.videos.saveAnnotation(
        lesson,
        existing: note,
        title: 'Stale',
        startMs: 0,
      ),
      throwsStateError,
    );
    await expectLater(
      h.videos.deleteAnnotation(lesson, note),
      throwsStateError,
    );
  });

  test(
    'deletion undo is revision-bound and never restores over a later edit',
    () async {
      final h = _Harness();
      await h.open();
      addTearDown(h.close);
      final lesson = h.lessons.first;
      final note = await h.videos.saveAnnotation(
        lesson,
        title: 'Bookmark',
        startMs: 1000,
      );
      final deletion = await h.videos.deleteAnnotation(lesson, note);
      expect(await h.videos.annotations(lesson), isEmpty);
      await expectLater(
        h.videos.saveAnnotation(
          lesson,
          existing: note,
          title: 'Deleted',
          startMs: 0,
        ),
        throwsStateError,
      );
      await h.videos.restoreAnnotation(lesson, deletion);
      final restored = (await h.videos.annotations(lesson)).single;
      expect(restored.id, note.id);
      expect(restored.revision, 3);
      await h.videos.saveAnnotation(
        lesson,
        existing: restored,
        title: 'Later edit',
        startMs: 2000,
      );
      await expectLater(
        h.videos.restoreAnnotation(lesson, deletion),
        throwsStateError,
      );
      expect((await h.videos.annotations(lesson)).single.title, 'Later edit');
    },
  );

  test('annotation ranges respect stored duration and stay with their media version', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.close);
    final lesson = h.lessons.first;
    await h.player.flush();
    await expectLater(
      h.videos.saveAnnotation(lesson, title: '', startMs: 0),
      throwsArgumentError,
    );
    await expectLater(
      h.videos.saveAnnotation(lesson, title: 'Bad', startMs: -1),
      throwsArgumentError,
    );
    await expectLater(
      h.videos.saveAnnotation(lesson, title: 'Bad', startMs: 1000, endMs: 1000),
      throwsArgumentError,
    );
    await expectLater(
      h.videos.saveAnnotation(lesson, title: 'Beyond', startMs: 120001),
      throwsArgumentError,
    );
    final note = await h.videos.saveAnnotation(
      lesson,
      title: 'Source A',
      startMs: 1000,
    );
    final data = {
      ...(await h.repository.record(lesson.id))!.payload!,
      'mediaVersion': 'replacement',
    };
    await h.db.customStatement(
      'UPDATE records SET payload=?,revision=revision+1 WHERE id=?',
      [jsonEncode(data), lesson.id],
    );
    final replacement = VideoLesson.fromJson(lesson.id, data);
    expect(await h.videos.annotations(replacement), isEmpty);
    expect((await h.videos.annotations(lesson)).single.id, note.id);
    await expectLater(
      h.videos.deleteAnnotation(lesson, note),
      throwsStateError,
    );
    await expectLater(
      h.videos.saveAnnotation(
        replacement,
        existing: note,
        title: 'Wrong version',
        startMs: 0,
      ),
      throwsArgumentError,
    );
    // Restore the source so controller teardown can save its own valid checkpoint.
    await h.db.customStatement('UPDATE records SET payload=? WHERE id=?', [
      jsonEncode(lesson.toJson()),
      lesson.id,
    ]);
  });
}
