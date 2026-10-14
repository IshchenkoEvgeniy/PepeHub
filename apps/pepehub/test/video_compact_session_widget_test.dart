import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/video/video_course_editor.dart';
import 'package:pepehub/video/video_fullscreen.dart';
import 'package:pepehub/video/video_mini_player.dart';
import 'package:pepehub/video/video_player_page.dart';
import 'package:pepehub/video/video_repository.dart';
import 'package:pepehub/video/video_session.dart';

import 'support/video_engine.dart';
import 'video_player_tools_widget_test.dart' show ready, tool;

class _Window extends VideoFullscreenHost {
  final changes = <String>[];
  @override
  Future<void> initialize() async {
    supportsMiniWindow = true;
    supportsPip = true;
  }

  @override
  Future<void> setMiniWindow(bool enabled) async {
    changes.add('mini:$enabled');
  }

  @override
  Future<void> setFullscreen(bool enabled) async {
    changes.add('full:$enabled');
  }

  void showPip(bool visible) {
    pip = visible;
    notifyListeners();
  }
}

void main() {
  testWidgets(
    'compact controls hide, lock and reuse the session across mini-player and native presentations',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase(NativeDatabase.memory()),
          engine = TestVideoEngine(),
          window = _Window();
      final videos = VideoRepository(Repository(db));
      final item = await videos.addSources(
        title: 'English',
        sources: const [
          VideoSourceDraft('one.mp4', 'One'),
          VideoSourceDraft('two.mp4', 'Two'),
        ],
      );
      final lessons = await videos.lessons(itemId: item.id);
      var created = 0;
      final session = VideoPlaybackSession(
        videos,
        window: window,
        engineFactory: () {
          created++;
          return engine;
        },
      );
      final navigator = GlobalKey<NavigatorState>();
      void open() => navigator.currentState!.push<void>(
        MaterialPageRoute(
          builder: (_) => VideoPlayerPage(
            repository: videos,
            item: item,
            lessons: lessons,
            initialIndex: session.controller?.index ?? 0,
            session: session,
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          builder: (context, child) => VideoSessionScope(
            session: session,
            child: Overlay.wrap(
              child: Stack(
                children: [
                  child!,
                  VideoMiniPlayer(session: session, onOpen: open),
                ],
              ),
            ),
          ),
          home: Scaffold(
            body: TextButton(onPressed: open, child: const Text('Library')),
          ),
        ),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        unawaited(session.close());
        await ready(tester, () => session.controller == null);
        session.dispose();
        await tester.runAsync(db.close);
      });
      await tester.tap(find.text('Library'));
      await ready(tester, () => engine.state.playing);
      engine.tick(42000);
      await tester.pump(const Duration(seconds: 5));
      expect(find.byKey(const ValueKey('video-play-pause')), findsNothing);
      expect(find.byType(ListView), findsNothing);
      await tester.tapAt(const Offset(180, 400));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byKey(const ValueKey('video-play-pause')), findsOneWidget);
      expect(engine.state.playing, isTrue);
      await tool(tester, 'lock');
      expect(find.byKey(const ValueKey('video-play-pause')), findsNothing);
      await tester.tap(find.byTooltip('Разблокировать управление'));
      await tester.pumpAndSettle();
      await tool(tester, 'audio');
      expect(session.controller!.audioOnly, isTrue);
      await tool(tester, 'timer');
      await tester.enterText(
        find.byKey(const ValueKey('video-sleep-minutes')),
        '0',
      );
      await tester.tap(find.text('Включить'));
      await tester.pumpAndSettle();
      expect(find.text('От 1 до 1440 минут'), findsOneWidget);
      await tester.tap(find.text('До конца урока'));
      await ready(tester, () => session.controller!.sleepAtLessonEnd);
      expect(engine.state.playing, isTrue);
      await tool(tester, 'mini');
      await ready(
        tester,
        () =>
            find.byType(VideoPlayerPage).evaluate().isEmpty &&
            find
                .byKey(const ValueKey('video-mini-player'))
                .evaluate()
                .isNotEmpty,
      );
      expect(engine.closed, isFalse);
      expect(created, 1);
      await tester.tap(find.byTooltip('Приостановить мини-плеер'));
      await ready(tester, () => !engine.state.playing);
      await tester.tap(find.byTooltip('Открыть видеоплеер'));
      await ready(
        tester,
        () => find.byType(VideoPlayerPage).evaluate().isNotEmpty,
      );
      expect(created, 1);
      expect(engine.state.positionMs, 42000);
      await tool(tester, 'audio');
      expect(session.controller!.audioOnly, isFalse);
      await tool(tester, 'window');
      expect(session.miniWindow, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();
      expect(session.miniWindow, isFalse);
      expect(window.changes, ['mini:true', 'mini:false', 'full:true']);
      window.showPip(true);
      await tester.pump();
      expect(find.byKey(const ValueKey('video-play-pause')), findsNothing);
      window.showPip(false);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await ready(tester, () => engine.closed);
      expect(
        (await tester.runAsync(() => videos.progress(lessons.first)))!
            .positionMs,
        42000,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'course structure editor validates, edits modules and saves manual order on a phone',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase(NativeDatabase.memory()),
          videos = VideoRepository(Repository(db));
      addTearDown(db.close);
      final item = await videos.addSources(
        title: 'Original',
        sources: const [
          VideoSourceDraft('one.mp4', 'One'),
          VideoSourceDraft('two.mp4', 'Two'),
        ],
      );
      final lessons = await videos.lessons(itemId: item.id);
      await tester.pumpWidget(
        MaterialApp(
          home: VideoCourseEditor(
            repository: videos,
            item: item,
            lessons: lessons,
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('video-edit-course-title')),
        'English B1',
      );
      await tester.tap(find.text('One'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('video-edit-lesson-title')),
        '',
      );
      await tester.tap(find.text('Готово'));
      await tester.pumpAndSettle();
      expect(find.text('Введите название'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('video-edit-lesson-title')),
        'Grammar',
      );
      await tester.enterText(
        find.byKey(const ValueKey('video-edit-lesson-module')),
        'Practice',
      );
      await tester.tap(find.text('Готово'));
      await tester.pumpAndSettle();
      final handle = tester.getCenter(
        find.byType(ReorderableDragStartListener).last,
      );
      final firstTop = tester
          .getTopLeft(find.widgetWithText(ListTile, 'Grammar'))
          .dy;
      final drag = await tester.startGesture(handle);
      await tester.pump(const Duration(milliseconds: 100));
      await drag.moveBy(const Offset(0, -24));
      await tester.pump();
      await drag.moveTo(Offset(handle.dx, firstTop - 60));
      await tester.pump(const Duration(milliseconds: 600));
      await drag.up();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сохранить'));
      await ready(
        tester,
        () => find.text('Структура курса').evaluate().isEmpty,
      );
      final saved = (await tester.runAsync(
        () => videos.lessons(itemId: item.id),
      ))!;
      expect(saved.map((lesson) => lesson.id), [
        lessons.last.id,
        lessons.first.id,
      ]);
      expect(saved.last.title, 'Grammar');
      expect(saved.last.module, 'Practice');
      expect((await tester.runAsync(videos.items))!.single.title, 'English B1');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
