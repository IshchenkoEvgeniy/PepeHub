import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/video/models.dart';
import 'package:pepehub/video/video_compact_controls.dart';
import 'package:pepehub/video/video_controller.dart';
import 'package:pepehub/video/video_gestures.dart';
import 'package:pepehub/video/video_repository.dart';

import 'support/video_engine.dart';

class _FakeTimer implements Timer {
  final Duration duration;
  final void Function() callback;
  bool cancelled = false;
  _FakeTimer(this.duration, this.callback);
  void fire() {
    if (!cancelled) callback();
  }

  @override
  void cancel() => cancelled = true;
  @override
  bool get isActive => !cancelled;
  @override
  int get tick => 0;
}

Future<(VideoRepository, List<VideoLesson>)> _course(
  int count, {
  int? durationMs,
}) async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final videos = VideoRepository(Repository(db));
  final item = await videos.addSources(
    title: 'Курс',
    sources: [
      for (var i = 1; i <= count; i++)
        VideoSourceDraft('lesson$i.mp4', 'Урок $i', durationMs: durationMs),
    ],
  );
  return (videos, await videos.lessons(itemId: item.id));
}

void main() {
  group('end of a video lesson', () {
    late List<_FakeTimer> timers;
    VideoPlaybackController make(
      VideoRepository videos,
      List<VideoLesson> lessons,
      TestVideoEngine engine,
    ) {
      timers = [];
      final controller = VideoPlaybackController(
        repository: videos,
        engine: engine,
        lessons: lessons,
        checkpointPeriod: null,
        createSleepTimer: (duration, callback) {
          final timer = _FakeTimer(duration, callback);
          timers.add(timer);
          return timer;
        },
      );
      addTearDown(controller.dispose);
      return controller;
    }

    Future<void> finish(
      VideoPlaybackController controller,
      TestVideoEngine engine,
    ) async {
      engine.tick(120000, completed: true, playing: false);
      await controller.flush();
      await controller.flush();
    }

    test('counts down five seconds, then plays the next lesson', () async {
      final (videos, lessons) = await _course(3);
      final engine = TestVideoEngine();
      final controller = make(videos, lessons, engine);
      await controller.load(0);
      await controller.play();
      await finish(controller, engine);
      expect(controller.upNextIndex, 1);
      expect(timers.single.duration, VideoPlaybackController.upNextDelay);
      expect(controller.upNextRemainingMs, isNotNull);
      timers.single.fire();
      await controller.flush();
      expect(controller.current!.id, lessons[1].id);
      expect(controller.upNextIndex, isNull);
      expect(engine.state.playing, isTrue);
    });

    test('cancel, replay and the setting keep the finished lesson', () async {
      final (videos, lessons) = await _course(3);
      final engine = TestVideoEngine();
      final controller = make(videos, lessons, engine);
      await controller.load(0);
      await controller.play();
      await finish(controller, engine);
      controller.cancelUpNext();
      expect(controller.upNextIndex, isNull);
      timers.single.fire();
      await controller.flush();
      expect(controller.current!.id, lessons[0].id);

      await controller.play(); // Replays from the start.
      await finish(controller, engine);
      expect(controller.upNextIndex, 1);
      await controller.play();
      expect(controller.upNextIndex, isNull, reason: 'replay cancels');

      await videos.setAutoNext(false);
      await finish(controller, engine);
      expect(controller.upNextIndex, isNull);
      expect(await videos.autoNext(), isFalse);
    });

    test('opening titles are skipped, closing titles end the lesson', () async {
      final (videos, lessons) = await _course(2, durationMs: 120000);
      await videos.saveSkipSettings(
        lessons.first.itemId,
        introMs: 15000,
        outroMs: 20000,
      );
      final engine = TestVideoEngine();
      timers = [];
      final controller = VideoPlaybackController(
        repository: videos,
        engine: engine,
        lessons: lessons,
        checkpointPeriod: null,
        skipFor: (lesson) => videos.skipSettings(lesson.itemId),
        createSleepTimer: (duration, callback) {
          final timer = _FakeTimer(duration, callback);
          timers.add(timer);
          return timer;
        },
      );
      addTearDown(controller.dispose);
      await controller.load(0);
      expect(engine.state.positionMs, 15000, reason: 'opening titles');
      await controller.play();
      engine.tick(90000);
      await controller.flush();
      expect(controller.upNextIndex, isNull);
      engine.tick(100500);
      await controller.flush();
      await controller.flush();
      expect(engine.state.playing, isFalse, reason: 'credits are not played');
      expect(controller.upNextIndex, 1);
      final state = await videos.learningState(lessons.first);
      expect(state.manualCompletedAt, isNotNull);
      // A lesson watched before is not moved past the opening titles.
      await videos.checkpoint(
        lesson: lessons[1],
        progress: VideoProgress(
          lessonId: lessons[1].id,
          mediaVersion: lessons[1].mediaVersion,
          positionMs: 40000,
          speed: 1,
          updatedAt: DateTime.utc(2026),
        ),
        intervals: const [],
      );
      timers.last.fire();
      await controller.flush();
      expect(controller.current!.id, lessons[1].id);
      expect(engine.state.positionMs, 40000);
      // Left on the closing titles: starts over, after the opening titles.
      await controller.load(0);
      expect(engine.state.positionMs, 15000);
    });

    test(
      'the last lesson and the sleep timer end without a countdown',
      () async {
        final (videos, lessons) = await _course(2);
        final engine = TestVideoEngine();
        final controller = make(videos, lessons, engine);
        await controller.load(1);
        await controller.play();
        await finish(controller, engine);
        expect(controller.upNextIndex, isNull);

        await controller.load(0);
        await controller.play();
        await controller.setSleepTimer(null, untilLessonEnd: true);
        await finish(controller, engine);
        expect(controller.upNextIndex, isNull);
      },
    );
  });

  test(
    'a finished lesson reopens from the start; an unfinished one resumes',
    () async {
      final (videos, lessons) = await _course(2, durationMs: 120000);
      Future<int> reopen(int index, {required int leaveAt}) async {
        final engine = TestVideoEngine();
        final first = VideoPlaybackController(
          repository: videos,
          engine: engine,
          lessons: lessons,
          checkpointPeriod: null,
        );
        await first.load(index);
        await first.seek(leaveAt);
        await first.close();
        first.dispose();
        final again = TestVideoEngine();
        final second = VideoPlaybackController(
          repository: videos,
          engine: again,
          lessons: lessons,
          checkpointPeriod: null,
        );
        await second.load(index);
        final position = again.state.positionMs;
        await second.close();
        second.dispose();
        return position;
      }

      expect(await reopen(0, leaveAt: 115000), 0);
      expect(await reopen(1, leaveAt: 60000), 60000);
    },
  );

  test(
    'the watching speed carries over to lessons without their own',
    () async {
      final (videos, lessons) = await _course(3);
      final engine = TestVideoEngine();
      final controller = VideoPlaybackController(
        repository: videos,
        engine: engine,
        lessons: lessons,
        checkpointPeriod: null,
      );
      await controller.load(0);
      await controller.setSpeed(1.5);
      await controller.next();
      expect(engine.state.speed, 1.5);
      await controller.close();
      controller.dispose();

      // A new player starts an unwatched lesson at the course's last speed.
      final fresh = TestVideoEngine();
      final reopened = VideoPlaybackController(
        repository: videos,
        engine: fresh,
        lessons: lessons,
        checkpointPeriod: null,
      );
      await reopened.load(2);
      expect(fresh.state.speed, 1.5);
      await reopened.close();
      reopened.dispose();
    },
  );

  group('gestures', () {
    late List<String> calls;
    late double volume;
    final zoom = TransformationController();

    Future<void> pump(
      WidgetTester tester, {
      bool locked = false,
      bool brightness = true,
    }) async {
      calls = [];
      volume = 50;
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 400,
              height: 300,
              child: VideoGestureLayer(
                zoom: zoom,
                enabled: true,
                locked: locked,
                viewport: const ColoredBox(color: Colors.black),
                onTap: () => calls.add('tap'),
                onFullscreen: () => calls.add('fullscreen'),
                onSkip: (ms) => calls.add('skip $ms'),
                onHold: (holding) {
                  calls.add('hold $holding');
                  return true;
                },
                position: () => 30000,
                duration: () => 600000,
                onScrubStart: () => calls.add('scrub start'),
                onScrub: (_) {},
                onSeek: (ms) => calls.add('seek ${ms.round()}'),
                onScrubCancel: () => calls.add('scrub cancel'),
                volume: () => volume,
                onVolume: (value) => volume = value,
                brightness: brightness ? () async => .4 : null,
                onBrightness: brightness
                    ? (value) => calls.add('brightness')
                    : null,
                onZoomStart: () {},
                onZoomEnd: () {},
              ),
            ),
          ),
        ),
      );
    }

    Offset at(WidgetTester tester, double x, double y) =>
        tester.getTopLeft(find.byType(VideoGestureLayer)) + Offset(x, y);

    Future<void> doubleTap(
      WidgetTester tester,
      Offset position, {
      PointerDeviceKind kind = PointerDeviceKind.touch,
    }) async {
      await tester.tapAt(position, kind: kind);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(position, kind: kind);
      await tester.pump(const Duration(milliseconds: 60));
    }

    testWidgets('double taps seek on the sides, fullscreen in the middle', (
      tester,
    ) async {
      await pump(tester);
      await doubleTap(tester, at(tester, 360, 150));
      expect(calls, ['skip 10000']);
      expect(find.byKey(const ValueKey('video-gesture-seek')), findsOneWidget);
      expect(find.text('+10 с'), findsOneWidget);
      // A quick extra tap on the same side keeps seeking.
      await tester.tapAt(at(tester, 360, 150));
      await tester.pump(const Duration(milliseconds: 400));
      expect(calls, ['skip 10000', 'skip 10000']);
      expect(find.text('+20 с'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));

      await doubleTap(tester, at(tester, 40, 150));
      expect(calls.last, 'skip -10000');
      await tester.pump(const Duration(seconds: 1));
      await doubleTap(tester, at(tester, 200, 150));
      expect(calls.last, 'fullscreen');
      await tester.pump(const Duration(seconds: 1));
      await doubleTap(
        tester,
        at(tester, 360, 150),
        kind: PointerDeviceKind.mouse,
      );
      expect(calls.last, 'fullscreen', reason: 'a mouse keeps fullscreen');
      await tester.pump(const Duration(seconds: 1));

      // A single tap toggles the controls.
      calls.clear();
      await tester.tapAt(at(tester, 200, 150));
      await tester.pump(const Duration(milliseconds: 400));
      expect(calls, ['tap']);
    });

    testWidgets('holding plays at 2× until release', (tester) async {
      await pump(tester);
      final gesture = await tester.startGesture(at(tester, 200, 150));
      await tester.pump(const Duration(milliseconds: 700));
      expect(calls, ['hold true']);
      expect(find.byKey(const ValueKey('video-gesture-hold')), findsOneWidget);
      await gesture.up();
      await tester.pump();
      expect(calls, ['hold true', 'hold false']);
      expect(find.byKey(const ValueKey('video-gesture-hold')), findsNothing);
    });

    testWidgets('swipes scrub, change volume and brightness', (tester) async {
      await pump(tester);
      // Half the width scrubs one minute forward from 0:30.
      await tester.dragFrom(at(tester, 100, 150), const Offset(200, 0));
      await tester.pumpAndSettle();
      expect(calls, ['scrub start', 'seek 90000']);

      calls.clear();
      await tester.dragFrom(at(tester, 300, 250), const Offset(0, -105));
      await tester.pumpAndSettle();
      expect(volume, closeTo(100, 1));
      expect(calls, isEmpty);

      await tester.dragFrom(at(tester, 100, 250), const Offset(0, -60));
      await tester.pumpAndSettle();
      expect(calls, contains('brightness'));
      expect(volume, closeTo(100, 1), reason: 'the left side is brightness');
    });

    testWidgets('without brightness both sides change volume; locked does '
        'nothing', (tester) async {
      await pump(tester, brightness: false);
      await tester.dragFrom(at(tester, 100, 250), const Offset(0, 105));
      await tester.pumpAndSettle();
      expect(volume, closeTo(0, 1));

      await pump(tester, locked: true);
      await doubleTap(tester, at(tester, 360, 150));
      await tester.dragFrom(at(tester, 100, 150), const Offset(200, 0));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(volume, 50);
    });
  });

  testWidgets('a 360px phone keeps previous and next lesson buttons', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (videos, lessons) = await _course(3);
    final engine = TestVideoEngine();
    final controller = VideoPlaybackController(
      repository: videos,
      engine: engine,
      lessons: lessons,
      checkpointPeriod: null,
    );
    await controller.load(1);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(textTheme: Typography.material2021().white),
        home: Scaffold(
          backgroundColor: Colors.black,
          body: VideoCompactControls(
            player: controller,
            enabled: true,
            fullscreen: false,
            visible: true,
            locked: false,
            miniWindow: false,
            scrub: null,
            onBack: () {},
            onMore: () {},
            onStudy: () {},
            onCaptions: () {},
            onNote: () {},
            onFullscreen: () {},
            onLock: () {},
            onScrub: (_) {},
            onSeek: (_) {},
            onScrubStart: () {},
            perform: (action) => action(),
          ),
        ),
      ),
    );
    expect(find.byTooltip('Предыдущий урок'), findsOneWidget);
    expect(find.byTooltip('Следующий урок'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Следующий урок'));
    await tester.pumpAndSettle();
    expect(controller.current!.id, lessons[2].id);
    await tester.runAsync(controller.close);
    controller.dispose();
  });
}
