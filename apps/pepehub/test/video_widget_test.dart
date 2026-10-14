import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/main.dart';
import 'package:pepehub/video/video_library_page.dart';
import 'package:pepehub/video/video_import.dart';
import 'package:pepehub/video/video_player_page.dart';
import 'package:pepehub/video/video_repository.dart';
import 'package:pepehub/video/models.dart';
import 'package:pepehub/video/video_statistics_page.dart';
import 'package:pepehub/ui/shelf_components.dart';

import 'support/video_engine.dart';

void main() {
  testWidgets('statistics shows actual accelerated coverage on a phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final videos = VideoRepository(Repository(db));
    final item = await videos.addSources(
      title: 'Listening drill',
      sources: [const VideoSourceDraft('lesson.mp4', 'Listening drill')],
    );
    final lesson = (await videos.lessons(itemId: item.id)).single;
    final at = DateTime.now().subtract(const Duration(hours: 1));
    await videos.checkpoint(
      lesson: lesson,
      durationMs: 60000,
      progress: VideoProgress(
        lessonId: lesson.id,
        mediaVersion: lesson.mediaVersion,
        positionMs: 30000,
        speed: 2,
        updatedAt: at,
      ),
      intervals: [
        VideoInterval(
          id: 'watched',
          sessionId: 's',
          lessonId: lesson.id,
          mediaVersion: lesson.mediaVersion,
          mode: VideoActivityMode.visual,
          startedAt: at.toUtc(),
          offsetMinutes: at.timeZoneOffset.inMinutes,
          startMs: 0,
          endMs: 30000,
          wallMs: 15000,
          speed: 2,
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: VideoStatisticsPage(repository: videos, item: item),
      ),
    );
    for (
      var attempt = 0;
      attempt < 40 && find.text('Время воспроизведения').evaluate().isEmpty;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    expect(find.text('Время воспроизведения'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('video-metric:Время воспроизведения')),
        matching: find.text('15 с'),
      ),
      findsOneWidget,
    );
    expect(find.text('30 с'), findsWidgets);
    await tester.scrollUntilVisible(find.text('50.0% · 30 с из 1 мин'), 250);
    expect(find.text('50.0% · 30 с из 1 мин'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
  testWidgets(
    'course preview fits a phone with a keyboard and preserves modules',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final videos = VideoRepository(Repository(db));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(viewInsets: const EdgeInsets.only(bottom: 260)),
            child: child!,
          ),
          home: VideoLibraryPage(
            repository: videos,
            navigation: ShelfNavigation(
              current: PepeSection.video,
              onSelect: (_) {},
              onSettings: () {},
            ),
            chooseFiles: ({bool folder = false}) async =>
                const VideoImportSelection('English course', [
                  VideoSourceDraft(
                    'one.mp4',
                    'First lesson',
                    module: 'Module 1',
                  ),
                  VideoSourceDraft(
                    'two.mp4',
                    'Second lesson',
                    module: 'Module 2',
                  ),
                ], root: 'English'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Подключить папку'));
      await tester.pumpAndSettle();
      expect(find.text('Проверить видео и порядок уроков'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Подключить'));
      await tester.pumpAndSettle();
      final item = (await videos.items()).single;
      expect(item.title, 'English course');
      expect((await videos.lessons(itemId: item.id)).map((l) => l.module), [
        'Module 1',
        'Module 2',
      ]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('library renders on desktop and phone with real fonts', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      for (final entry in {
        'Onest': 'assets/fonts/Onest.ttf',
        'Oswald': 'assets/fonts/Oswald.ttf',
        'CormorantGaramond': 'assets/fonts/CormorantGaramond.ttf',
        'MaterialIcons': '../../.tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        await (FontLoader(entry.key)..addFont(
              File(entry.value).readAsBytes().then(ByteData.sublistView),
            ))
            .load();
      }
    });
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = Repository(db), videos = VideoRepository(Repository(db));
    await repo.setMeta('library-section', 'video');
    await repo.setMeta('appearance-settings', '{"textScale":1.3}');
    for (final title in [
      'English — Listening B1',
      'Основы Flutter',
      'Практика произношения',
    ]) {
      await videos.addSources(
        title: title,
        sources: [
          VideoSourceDraft('$title/one.mp4', 'Введение', module: 'Модуль 1'),
          VideoSourceDraft('$title/two.mp4', 'Практика', module: 'Модуль 1'),
        ],
      );
    }
    for (final layout in {
      'desktop': const Size(1280, 840),
      'phone': const Size(360, 800),
    }.entries) {
      tester.view.physicalSize = layout.value;
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: PepeHubApp(repository: repo),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final rendered =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final data = await rendered.toByteData(format: ui.ImageByteFormat.png);
        rendered.dispose();
        final output = File(
          'build/video-preview/video-library-${layout.key}.png',
        );
        await output.parent.create(recursive: true);
        await output.writeAsBytes(data!.buffer.asUint8List());
      });
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }
  });
  testWidgets(
    'video is a persistent section; a link can be added on a 360px phone',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = Repository(db);
      await tester.pumpWidget(PepeHubApp(repository: repo));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Видео'));
      await tester.pumpAndSettle();
      expect(find.byType(VideoLibraryPage), findsOneWidget);
      await tester.tap(find.text('Добавить ссылку'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField).first,
        'English lesson',
      );
      await tester.enterText(find.byType(TextFormField).last, 'javascript:bad');
      await tester.tap(find.text('Добавить'));
      await tester.pumpAndSettle();
      expect(find.text('Нужна прямая HTTP(S)-ссылка'), findsOneWidget);
      await tester.enterText(
        find.byType(TextFormField).last,
        'https://example.com/lesson.mp4',
      );
      await tester.tap(find.text('Добавить'));
      await tester.pumpAndSettle();
      expect(find.text('English lesson'), findsOneWidget);
      expect(await repo.meta('library-section'), 'video');
      expect(await repo.records('video_item'), hasLength(1));
      expect(await repo.pending(), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Книги'));
      await tester.pumpAndSettle();
      expect(find.byType(VideoLibraryPage), findsNothing);
      await tester.tap(find.byTooltip('Видео'));
      await tester.pumpAndSettle();
      expect(find.text('English lesson'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('saved video section restores and large text does not overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = Repository(db);
    await repo.setMeta('library-section', 'video');
    await repo.setMeta('appearance-settings', '{"textScale":1.3}');
    await tester.pumpWidget(PepeHubApp(repository: repo));
    await tester.pumpAndSettle();
    expect(find.byType(VideoLibraryPage), findsOneWidget);
    expect(find.text('Начните с видео или курса'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('player saves position before popping and releases its engine', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final videos = VideoRepository(Repository(db));
    final item = await videos.addSources(
      title: 'Lesson',
      sources: [const VideoSourceDraft('lesson.mp4', 'Lesson')],
    );
    final lessons = await videos.lessons(itemId: item.id);
    final engine = TestVideoEngine();
    await tester.pumpWidget(
      MaterialApp(
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
                  ),
                ),
              ),
              child: const Text('Library'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
    engine.tick(42000);
    await tester.pump();
    await tester.tap(find.byTooltip('Закрыть плеер'));
    await tester.pumpAndSettle();
    expect(find.text('Library'), findsOneWidget);
    expect((await videos.progress(lessons.single))!.positionMs, 42000);
    expect(engine.closed, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
