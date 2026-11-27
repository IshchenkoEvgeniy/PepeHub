import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/ui/shelf_components.dart';
import 'package:pepehub/video/models.dart';
import 'package:pepehub/video/video_auto_discovery.dart';
import 'package:pepehub/video/video_course_page.dart';
import 'package:pepehub/video/video_library_page.dart';
import 'package:pepehub/video/video_media_actions.dart';
import 'package:pepehub/video/video_media_views.dart';
import 'package:pepehub/video/video_repository.dart';

class _Deleter implements VideoFileDeleter {
  final calls = <List<String>>[];
  Set<String> refuse = {};
  @override
  Future<({Set<String> deleted, Set<String> failed})> delete(
    List<String> sources,
  ) async {
    calls.add(sources);
    return (
      deleted: {
        for (final s in sources)
          if (!refuse.contains(s)) s,
      },
      failed: {
        for (final s in sources)
          if (refuse.contains(s)) s,
      },
    );
  }
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Lets the database answer between frames.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}

void main() {
  late AppDatabase db;
  late VideoRepository videos;
  setUp(() {
    VideoAutoDiscovery.reset();
    db = AppDatabase(NativeDatabase.memory());
    videos = VideoRepository(Repository(db));
  });
  tearDown(() => db.close());

  group('repository', () {
    test('renames items and files, refusing empty names', () async {
      final item = await videos.addSources(
        title: 'Old',
        sources: [const VideoSourceDraft('/a.mp4', 'A')],
      );
      final lesson = (await videos.lessons()).single;
      await videos.renameItem(item.id, '  Новое  ');
      await videos.renameLesson(lesson.id, 'Урок');
      expect((await videos.items()).single.title, 'Новое');
      expect((await videos.lessons()).single.title, 'Урок');
      expect(() => videos.renameItem(item.id, ' '), throwsArgumentError);
      expect(
        () => videos.renameLesson(lesson.id, 'x' * 301),
        throwsArgumentError,
      );
    });

    test('removing files empties and restores their course', () async {
      final course = await videos.addSources(
        title: 'Курс',
        sources: [
          const VideoSourceDraft('/a.mp4', 'A'),
          const VideoSourceDraft('/b.mp4', 'B'),
        ],
      );
      final [a, b] = await videos.lessons(itemId: course.id);
      final first = await videos.removeLessons([a.id]);
      expect(first.items, isEmpty);
      expect(await videos.items(), hasLength(1));
      final second = await videos.removeLessons([b.id]);
      expect(second.items, [course.id]);
      expect(await videos.items(), isEmpty);
      await videos.restoreRemoval(second);
      await videos.restoreRemoval(first);
      expect(await videos.lessons(itemId: course.id), hasLength(2));
    });

    test('merging keeps files, order, progress and course modules', () async {
      final single = await videos.addSources(
        title: 'Intro',
        sources: [const VideoSourceDraft('/intro.mp4', 'Intro')],
      );
      final course = await videos.addSources(
        title: 'Basics',
        sources: [
          const VideoSourceDraft('/1.mp4', 'One'),
          const VideoSourceDraft('/2.mp4', 'Two'),
        ],
      );
      final intro = (await videos.lessons(itemId: single.id)).single;
      final merged = await videos.mergeIntoCourse(
        title: 'Всё вместе',
        itemIds: [single.id, course.id],
      );
      expect(merged.kind, VideoItemKind.course);
      expect((await videos.items()).map((i) => i.title), ['Всё вместе']);
      final lessons = await videos.lessons(itemId: merged.id);
      expect(lessons.map((l) => l.title), ['Intro', 'One', 'Two']);
      expect(lessons.map((l) => l.module), ['', 'Basics', 'Basics']);
      expect(lessons.first.id, intro.id, reason: 'progress is keyed by it');
      expect(
        () => videos.mergeIntoCourse(title: 'x', itemIds: [merged.id]),
        throwsArgumentError,
      );
    });
  });

  test('media counts read naturally', () {
    expect(mediaCount(1, music: false), 'видео');
    expect(mediaCount(3, music: false, courses: true), '3 курса');
    expect(mediaCount(11, music: true), '11 треков');
    expect(mediaCount(21, music: true), '21 трек');
  });

  Future<void> addThree() => videos
      .addSources(
        title: 'Альфа',
        folder: 'Movies/A',
        sources: [const VideoSourceDraft('/m/a.mp4', 'Альфа')],
      )
      .then(
        (_) => videos.addSources(
          title: 'Бета',
          folder: 'Movies/B',
          sources: [const VideoSourceDraft('/m/b.mp4', 'Бета')],
        ),
      )
      .then(
        (_) => videos.addSources(
          title: 'Гамма',
          folder: 'Movies/C',
          sources: [const VideoSourceDraft('/m/c.mp4', 'Гамма')],
        ),
      );

  Widget library(_Deleter deleter) => MaterialApp(
    home: VideoLibraryPage(
      repository: videos,
      navigation: ShelfNavigation(
        current: PepeSection.video,
        onSelect: (_) {},
        onSettings: () {},
      ),
      deleter: deleter,
    ),
  );

  double top(WidgetTester tester, String text) =>
      tester.getTopLeft(find.text(text).first).dy;

  Future<void> choose(WidgetTester tester, Key menu, String label) async {
    await tester.tap(find.byKey(menu));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<String>, label));
    await _settle(tester);
  }

  testWidgets('folders follow the sort and every look renders on a phone', (
    tester,
  ) async {
    _phone(tester);
    await tester.runAsync(addThree);
    await tester.pumpWidget(library(_Deleter()));
    await _settle(tester);
    await tester.tap(find.text('Папки'));
    await _settle(tester);
    expect(top(tester, 'Movies/A'), lessThan(top(tester, 'Movies/C')));
    await choose(tester, const ValueKey('media-sort'), 'По названию Я–А');
    expect(top(tester, 'Movies/C'), lessThan(top(tester, 'Movies/A')));
    await choose(tester, const ValueKey('media-sort'), 'Недавно добавленные');
    expect(top(tester, 'Movies/C'), lessThan(top(tester, 'Movies/B')));

    for (final look in videoViewLabels.values) {
      await choose(tester, const ValueKey('media-view'), look);
      expect(find.text('Гамма'), findsOneWidget, reason: look);
      expect(tester.takeException(), isNull, reason: look);
    }
    expect(await videos.repository.meta('media-view'), 'cards');
    await tester.tap(find.text('Список'));
    await _settle(tester);
    await choose(tester, const ValueKey('media-view'), 'Плитка');
    expect(find.byType(SliverGrid), findsWidgets);
    // Two tiles side by side on a 360px phone: newest first.
    final gamma = tester.getTopLeft(find.text('Гамма'));
    final beta = tester.getTopLeft(find.text('Бета'));
    expect(beta.dy, gamma.dy);
    expect(beta.dx, greaterThan(gamma.dx + 100));
  });

  testWidgets('rename, select, merge, delete files and undo removal', (
    tester,
  ) async {
    _phone(tester);
    final deleter = _Deleter()..refuse = {'/m/b.mp4'};
    await tester.runAsync(addThree);
    await tester.pumpWidget(library(deleter));
    await _settle(tester);

    final alpha = (await tester.runAsync(videos.items))!.first;
    await tester.tap(find.byKey(ValueKey('media-item-menu:${alpha.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Переименовать…'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('media-title-field')),
      'Альфа 2',
    );
    await tester.tap(find.text('Сохранить'));
    await _settle(tester);
    expect(find.text('Альфа 2'), findsOneWidget);
    final renamed = (await tester.runAsync(videos.lessons))!
        .firstWhere((lesson) => lesson.source == '/m/a.mp4');
    expect(renamed.title, 'Альфа 2', reason: 'a single video renames its file');

    // Long press starts selection; select all; merge into a course.
    await tester.longPress(find.text('Бета'));
    await tester.pumpAndSettle();
    expect(find.text('Выбрано: 1'), findsOneWidget);
    await tester.tap(find.byTooltip('Выбрать все'));
    await tester.pumpAndSettle();
    expect(find.text('Выбрано: 3'), findsOneWidget);
    await tester.tap(find.text('Гамма'));
    await tester.pumpAndSettle();
    expect(find.text('Выбрано: 2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('selection-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Объединить в курс…'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('media-title-field')),
      'Курс АБ',
    );
    await tester.tap(find.text('Сохранить'));
    await _settle(tester);
    expect(find.text('Курс АБ'), findsOneWidget);
    expect(find.textContaining('Выбрано'), findsNothing);
    expect(await tester.runAsync(videos.items), hasLength(2));

    // Delete the course files: one file is refused and stays.
    final course = (await tester.runAsync(videos.items))!
        .firstWhere((i) => i.title == 'Курс АБ');
    await tester.tap(find.byKey(ValueKey('media-item-menu:${course.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Удалить с устройства…'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Файлов: 2'), findsOneWidget);
    await tester.tap(find.text('Удалить файлы'));
    await _settle(tester);
    expect(deleter.calls.single.toSet(), {'/m/a.mp4', '/m/b.mp4'});
    expect(find.textContaining('Удалено файлов: 1'), findsOneWidget);
    final left = await tester.runAsync(() => videos.lessons(itemId: course.id));
    expect(left!.map((l) => l.source), ['/m/b.mp4']);

    // Removing from the library offers «Вернуть».
    final gamma = (await tester.runAsync(videos.items))!
        .firstWhere((i) => i.title == 'Гамма');
    await tester.tap(find.byKey(ValueKey('media-item-menu:${gamma.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Убрать из медиатеки…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Убрать из медиатеки'));
    await _settle(tester);
    expect(find.text('Гамма'), findsNothing);
    await tester.tap(find.text('Вернуть'));
    await _settle(tester);
    expect(find.text('Гамма'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('course files sort, rename and get marked in a selection', (
    tester,
  ) async {
    _phone(tester);
    late VideoItem course;
    await tester.runAsync(() async {
      course = await videos.addSources(
        title: 'Курс',
        sources: [
          const VideoSourceDraft('/c/1.mp4', 'Б урок', durationMs: 60000),
          const VideoSourceDraft('/c/2.mp4', 'А урок', durationMs: 600000),
          const VideoSourceDraft('/c/3.mp4', 'В урок', durationMs: 120000),
        ],
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        home: VideoCoursePage(repository: videos, item: course),
      ),
    );
    await _settle(tester);
    expect(top(tester, 'Б урок'), lessThan(top(tester, 'А урок')));
    await choose(tester, const ValueKey('course-sort'), 'По названию А–Я');
    expect(top(tester, 'А урок'), lessThan(top(tester, 'Б урок')));
    await choose(tester, const ValueKey('course-sort'), 'Сначала короткие');
    expect(top(tester, 'Б урок'), lessThan(top(tester, 'В урок')));
    expect(top(tester, 'В урок'), lessThan(top(tester, 'А урок')));
    expect(await videos.repository.meta('course-sort'), 'duration-short');

    final lessons = (await tester.runAsync(
      () => videos.lessons(itemId: course.id),
    ))!;
    await tester.tap(find.byKey(ValueKey('lesson-menu:${lessons[0].id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Переименовать…'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('media-title-field')),
      'Введение',
    );
    await tester.tap(find.text('Сохранить'));
    await _settle(tester);
    expect(find.text('Введение'), findsOneWidget);

    await tester.longPress(find.text('Введение'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('В урок'));
    await tester.pumpAndSettle();
    expect(find.text('Выбрано: 2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('selection-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Отметить просмотренным'));
    await _settle(tester);
    expect(find.textContaining('Просмотрено'), findsWidgets);
    final states = (await tester.runAsync(videos.allLearningStates))!;
    expect(
      states.values.where((s) => s.manualCompletedAt != null),
      hasLength(2),
    );
    for (final look in videoViewLabels.values) {
      await choose(tester, const ValueKey('media-view'), look);
      expect(find.text('Введение'), findsOneWidget, reason: look);
      expect(tester.takeException(), isNull, reason: look);
    }
  });
}
