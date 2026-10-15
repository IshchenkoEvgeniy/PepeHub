import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/ui/app_theme.dart';
import 'package:pepehub/video/models.dart';
import 'package:pepehub/video/video_fullscreen.dart';
import 'package:pepehub/video/video_player_page.dart';
import 'package:pepehub/video/video_repository.dart';

import 'support/video_engine.dart';

class _Window extends VideoFullscreenHost {
  final List<bool> changes = [];
  @override
  Future<void> setFullscreen(bool enabled) async => changes.add(enabled);
}

Future<void> ready(WidgetTester tester, bool Function() condition) async {
  for (var n = 0; n < 60 && !condition(); n++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(condition(), isTrue);
  await tester.pumpAndSettle();
}

class _Fixture {
  bool closed = false;
  final db = AppDatabase(NativeDatabase.memory()),
      engine = TestVideoEngine(),
      window = _Window();
  late final videos = VideoRepository(Repository(db));
  late VideoItem item;
  late List<VideoLesson> lessons;
  Future<void> open(
    WidgetTester tester, {
    GlobalKey? boundary,
    bool large = false,
  }) async {
    addTearDown(() => close(tester));
    item = await videos.addSources(
      title: 'English — past perfect',
      sources: const [
        VideoSourceDraft('lesson.mp4', 'Past perfect in conversation'),
      ],
    );
    lessons = await videos.lessons(itemId: item.id);
    final app = MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.data(Brightness.dark),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(large ? 1.3 : 1)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.push<void>(
              context,
              MaterialPageRoute(
                builder: (_) => VideoPlayerPage(
                  repository: videos,
                  item: item,
                  lessons: lessons,
                  engineFactory: () => engine,
                  fullscreenHost: window,
                ),
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.pumpWidget(
      boundary == null ? app : RepaintBoundary(key: boundary, child: app),
    );
    await tester.tap(find.text('Open'));
    await ready(
      tester,
      () =>
          engine.state.playing &&
          find.byType(VideoPlayerPage).evaluate().isNotEmpty,
    );
  }

  Future<void> close(WidgetTester tester) async {
    if (closed) return;
    closed = true;
    await tester.pumpWidget(const SizedBox());
    await ready(tester, () => engine.closed);
    await db.close();
  }
}

void main() {
  testWidgets(
    'fullscreen and Escape preserve the engine, position and route until a second back',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = _Fixture();
      await fixture.open(tester);
      fixture.engine.tick(69000);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pumpAndSettle();
      expect(fixture.window.changes, [true]);
      expect(find.byType(AppBar), findsNothing);
      expect(fixture.engine.state.positionMs, 69000);
      expect(fixture.engine.seeks, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(fixture.window.changes, [true, false]);
      expect(find.byType(VideoPlayerPage), findsOneWidget);
      expect(fixture.engine.closed, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(fixture.engine.state.positionMs, 79000);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await ready(
        tester,
        () => fixture.engine.closed && find.text('Open').evaluate().isNotEmpty,
      );
      expect(
        (await fixture.videos.progress(fixture.lessons.single))!.positionMs,
        79000,
      );
      expect(tester.takeException(), isNull);
      await fixture.close(tester);
    },
  );

  testWidgets(
    'precise navigation, ranged notes, edits and deletion undo work on a phone',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = _Fixture();
      await fixture.open(tester);
      await tool(tester, 'seek');
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('video-seek-time')),
        '2:01',
      );
      await tester.tap(find.text('Перейти'));
      await tester.pumpAndSettle();
      expect(find.text('Время больше длительности видео'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('video-seek-time')),
        '1:10.125',
      );
      await tester.tap(find.text('Перейти'));
      await tester.pumpAndSettle();
      expect(fixture.engine.seeks.last, 70125);
      await tool(tester, 'note');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Параметры заметки'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('video-annotation-title')),
        'Past perfect',
      );
      await tester.enterText(
        find.byKey(const ValueKey('video-annotation-end')),
        '1:12.500',
      );
      await tester.tap(find.byTooltip('Скрыть параметры заметки'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('video-annotation-body')),
        'Use had + past participle',
      );
      await tester.tap(find.text('Сохранить'));
      await ready(
        tester,
        () => find
            .byKey(const ValueKey('video-annotation-editor'))
            .evaluate()
            .isEmpty,
      );
      await notesPanel(tester);
      await ready(
        tester,
        () => find.text('Past perfect').evaluate().isNotEmpty,
      );
      await tester.scrollUntilVisible(
        find.text('Past perfect'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      final note = (await fixture.videos.annotations(fixture.lessons.single))
          .single;
      expect(note.startMs, 70125);
      expect(note.endMs, 72500);
      await expose(tester, find.byTooltip('Действия с заметкой'));
      await tester.tap(find.byTooltip('Действия с заметкой'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Изменить'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('video-annotation-body')),
        'The action happened before another past event',
      );
      await tester.tap(find.text('Сохранить'));
      await ready(
        tester,
        () => find
            .text('The action happened before another past event')
            .evaluate()
            .isNotEmpty,
      );
      await expose(tester, find.byTooltip('Действия с заметкой'));
      await tester.tap(find.byTooltip('Действия с заметкой'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удалить'));
      await ready(
        tester,
        () => find.text('Заметка удалена').evaluate().isNotEmpty,
      );
      expect(await fixture.videos.annotations(fixture.lessons.single), isEmpty);
      await tester.tap(find.text('Отменить'));
      await ready(
        tester,
        () => find.text('Past perfect').evaluate().isNotEmpty,
      );
      expect(
        (await fixture.videos.annotations(fixture.lessons.single)).single.id,
        note.id,
      );
      await tester.tap(find.text('Past perfect'));
      await tester.pumpAndSettle();
      expect(fixture.engine.seeks.last, 70125);
      // Playback letters must remain ordinary input while searching notes.
      await tester.tap(find.byKey(const ValueKey('video-annotation-search')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(fixture.window.changes, isEmpty);
      expect(fixture.engine.state.playing, isFalse);
      expect(tester.takeException(), isNull);
      await fixture.close(tester);
    },
  );

  testWidgets(
    'repeat form validates short ranges and starts a finite loop from A',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = _Fixture();
      await fixture.open(tester);
      await tool(tester, 'loop');
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('video-loop-start')),
        '5',
      );
      await tester.enterText(
        find.byKey(const ValueKey('video-loop-end')),
        '5.1',
      );
      await tester.tap(find.text('Начать повтор'));
      await tester.pumpAndSettle();
      expect(fixture.engine.seeks, isEmpty);
      expect(find.textContaining('Фрагмент от 0,5 секунды'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('video-loop-end')), '7');
      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('3').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('video-loop-pause')),
        '2',
      );
      await tester.tap(find.text('Начать повтор'));
      await tester.pumpAndSettle();
      expect(fixture.engine.seeks, [5000]);
      expect(fixture.engine.state.playing, isTrue);
      expect(find.textContaining('A–B · 0/3'), findsOneWidget);
      await tester.tap(find.text('Остановить'));
      await tester.pumpAndSettle();
      expect(find.textContaining('A–B · 0/3'), findsNothing);
      expect(tester.takeException(), isNull);
      await fixture.close(tester);
    },
  );

  testWidgets(
    'player and fullscreen fit narrow portrait, landscape and desktop with real fonts',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.runAsync(() async {
        for (final font in {
          'Onest': 'assets/fonts/Onest.ttf',
          'Oswald': 'assets/fonts/Oswald.ttf',
          'MaterialIcons': '../../.tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        }.entries) {
          final loader = FontLoader(font.key)
            ..addFont(
              File(font.value)
                  .readAsBytes()
                  .then((bytes) => ByteData.sublistView(bytes)),
            );
          await loader.load();
        }
      });
      for (final layout in {
        'phone': const Size(360, 800),
        'landscape': const Size(800, 360),
        'desktop': const Size(1280, 900),
      }.entries) {
        tester.view.physicalSize = layout.value;
        final fixture = _Fixture(), boundary = GlobalKey();
        await fixture.open(tester, boundary: boundary, large: true);
        await capture(tester, boundary, 'player-${layout.key}');
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.pumpAndSettle();
        expect(fixture.window.changes, [true]);
        await capture(tester, boundary, 'fullscreen-${layout.key}');
        expect(tester.takeException(), isNull);
        await fixture.close(tester);
        expect(fixture.window.changes.last, isFalse);
      }
    },
  );
}

Future<void> capture(WidgetTester tester, GlobalKey key, String name) =>
    tester.runAsync(() async {
      final image =
          await (key.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final file = File('build/video-preview/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    });

Future<void> expose(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isNotEmpty) {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    return;
  }
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  if (tester.getCenter(finder).dy > tester.view.physicalSize.height - 100) {
    await tester.drag(find.byType(ListView).first, const Offset(0, -200));
    await tester.pumpAndSettle();
  }
}

Future<void> tool(WidgetTester tester, String id) async {
  await tester.tap(find.byTooltip('Инструменты плеера'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.byKey(ValueKey('video-tool-$id')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('video-tool-$id')));
  await ready(
    tester,
    () => find.byKey(ValueKey('video-tool-$id')).evaluate().isEmpty,
  );
}

Future<void> notesPanel(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Уроки, расшифровка и заметки'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.widgetWithText(Tab, 'Заметки'));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(Tab, 'Заметки'));
  await tester.pumpAndSettle();
}
