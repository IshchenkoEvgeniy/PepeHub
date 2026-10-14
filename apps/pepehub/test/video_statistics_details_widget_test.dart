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
import 'package:pepehub/ui/app_theme.dart';
import 'package:pepehub/video/models.dart';
import 'package:pepehub/video/video_repository.dart';
import 'package:pepehub/video/video_statistics_page.dart';

final now = DateTime(2026, 10, 14, 12);
Future<void> ready(WidgetTester tester, bool Function() predicate) async {
  for (var attempt = 0; attempt < 80 && !predicate(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  expect(
    predicate(),
    isTrue,
    reason: tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data)
        .where(
          (text) =>
              text != null &&
              (text.contains('Сегодня') ||
                  text.contains('Не удалось') ||
                  text.contains('Цел') ||
                  text.contains('Заверш')),
        )
        .join(' | '),
  );
  await tester.pumpAndSettle();
}

Finder get rootScroll => find.byType(Scrollable).first;

Future<void> store(
  VideoRepository videos,
  VideoLesson lesson,
  List<VideoInterval> intervals,
  int duration,
) => videos.checkpoint(
  lesson: lesson,
  durationMs: duration,
  progress: VideoProgress(
    lessonId: lesson.id,
    mediaVersion: lesson.mediaVersion,
    positionMs: duration,
    speed: 1,
    updatedAt: now,
  ),
  intervals: intervals,
);

VideoInterval segment(
  VideoLesson lesson,
  String id,
  int start,
  int end, {
  int second = 0,
}) => VideoInterval(
  id: id,
  sessionId: 'session',
  lessonId: lesson.id,
  mediaVersion: lesson.mediaVersion,
  mode: VideoActivityMode.visual,
  startedAt: now
      .subtract(const Duration(hours: 1))
      .add(Duration(seconds: second)),
  offsetMinutes: now.timeZoneOffset.inMinutes,
  startMs: start,
  endMs: end,
  wallMs: end - start,
  speed: 1,
);

void main() {
  testWidgets(
    'course refreshes manual completion while keeping weighted coverage unchanged',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = Repository(db), videos = VideoRepository(Repository(db));
      final item = await videos.addSources(
        title: 'English course',
        sources: [
          const VideoSourceDraft('intro.mp4', 'Introduction'),
          const VideoSourceDraft('lecture.mp4', 'Lecture'),
        ],
      );
      final lessons = await videos.lessons(itemId: item.id);
      await store(videos, lessons.first, [
        segment(lessons.first, 'short', 0, 20000),
      ], 20000);
      await store(videos, lessons.last, [], 80000);
      await repo.setMeta('library-section', 'video');
      await tester.pumpWidget(PepeHubApp(repository: repo));
      await tester.pumpAndSettle();
      await tester.tap(find.text('English course'));
      await ready(
        tester,
        () => find.text('Прогресс курса').evaluate().isNotEmpty,
      );
      expect(find.text('20.0% · 20 с из 1 мин'), findsOneWidget);
      expect(find.text('Завершено уроков: 1 из 2'), findsOneWidget);
      await tester.tap(find.byTooltip('Статистика курса'));
      await ready(
        tester,
        () => find.text('Время воспроизведения').evaluate().isNotEmpty,
      );
      final manual = find.byKey(ValueKey('video-manual-${lessons.last.id}'));
      await tester.scrollUntilVisible(manual, 350, scrollable: rootScroll);
      await tester.pumpAndSettle();
      final targetY = tester.getCenter(manual).dy;
      if (targetY > 720) {
        await tester.drag(rootScroll, const Offset(0, -200));
        await tester.pumpAndSettle();
      }
      await tester.tap(manual);
      await ready(
        tester,
        () =>
            manual.evaluate().isNotEmpty &&
            tester.widget<CheckboxListTile>(manual).value == true,
      );
      await tester.pageBack();
      await ready(
        tester,
        () => find.text('Завершено уроков: 2 из 2').evaluate().isNotEmpty,
      );
      expect(find.text('20.0% · 20 с из 1 мин'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('goals validate and history loads the next database page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final videos = _HistoryVideos(Repository(db));
    final item = await videos.addSources(
      title: 'Lesson',
      sources: [const VideoSourceDraft('lesson.mp4', 'Lesson')],
    );
    final lesson = (await videos.lessons(itemId: item.id)).single;
    await store(videos, lesson, [
      for (var i = 0; i < 40; i++)
        segment(lesson, 'part-$i', i * 1000, (i + 1) * 1000, second: i * 2),
    ], 60000);
    await tester.pumpWidget(
      MaterialApp(
        home: VideoStatisticsPage(repository: videos, now: () => now),
      ),
    );
    await ready(
      tester,
      () => find.text('Время воспроизведения').evaluate().isNotEmpty,
    );
    await tester.tap(find.byTooltip('Цели и порог просмотра'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).at(0), '2000');
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(find.text('Введите число от 0 до 1440'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).at(0), '20');
    await tester.enterText(find.byType(TextFormField).at(1), '140');
    await tester.enterText(find.byType(TextFormField).at(2), '90');
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Цели всей видеобиблиотеки'),
      350,
      scrollable: rootScroll,
    );
    await ready(
      tester,
      () => find.text('Сегодня: 40 с из 20 мин').evaluate().isNotEmpty,
    );
    expect((await videos.preferences()).completionPercent, 90);
    await tester.scrollUntilVisible(
      find.text('Ещё история'),
      400,
      scrollable: rootScroll,
    );
    await tester.tap(find.text('Ещё история'));
    await ready(
      tester,
      () =>
          videos.cursors.any((cursor) => cursor != null) &&
          find.text('Загрузка…').evaluate().isEmpty,
    );
    expect(videos.cursors.where((cursor) => cursor != null), hasLength(1));
    expect(find.text('Ещё история'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets(
    'advanced statistics render with real fonts at large text on phone and desktop',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        for (final entry in {
          'Onest': 'assets/fonts/Onest.ttf',
          'Oswald': 'assets/fonts/Oswald.ttf',
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
      final videos = VideoRepository(Repository(db));
      final item = await videos.addSources(
        title: 'English — Listening B1',
        sources: [
          const VideoSourceDraft('one.mp4', 'Understanding the conversation'),
          const VideoSourceDraft('two.mp4', 'Practice and review'),
        ],
      );
      final lessons = await videos.lessons(itemId: item.id);
      await store(videos, lessons.first, [
        segment(lessons.first, 'one', 0, 30000),
        segment(lessons.first, 'repeat', 20000, 40000, second: 60),
      ], 60000);
      await store(videos, lessons.last, [], 120000);
      await videos.savePreferences(
        const VideoPreferences(dailyMinutes: 20, weeklyMinutes: 140),
      );
      for (final layout in {
        'phone': const Size(360, 800),
        'desktop': const Size(1280, 900),
      }.entries) {
        tester.view.physicalSize = layout.value;
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: AppTheme.data(Brightness.dark),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(1.3)),
                child: child!,
              ),
              home: VideoStatisticsPage(
                repository: videos,
                item: item,
                now: () => now,
              ),
            ),
          ),
        );
        await ready(
          tester,
          () => find.text('Время воспроизведения').evaluate().isNotEmpty,
        );
        await capture(tester, key, 'statistics-${layout.key}');
        await tester.scrollUntilVisible(
          find.text('66.7% · 40 с из 1 мин'),
          350,
          scrollable: rootScroll,
        );
        expect(find.text('66.7% · 40 с из 1 мин'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await capture(tester, key, 'coverage-${layout.key}');
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
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
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final file = File('build/video-preview/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
    });

class _HistoryVideos extends VideoRepository {
  final List<VideoHistoryCursor?> cursors = [];
  _HistoryVideos(super.repository);
  @override
  Future<VideoHistoryPage> history({
    Set<String>? lessonIds,
    DateTime? start,
    DateTime? end,
    VideoHistoryCursor? before,
    int limit = 20,
  }) {
    cursors.add(before);
    return super.history(
      lessonIds: lessonIds,
      start: start,
      end: end,
      before: before,
      limit: limit,
    );
  }
}
