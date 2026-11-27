import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/ui/shelf_components.dart';
import 'package:pepehub/video/models.dart';
import 'package:pepehub/video/video_auto_discovery.dart';
import 'package:pepehub/video/video_covers.dart';
import 'package:pepehub/video/video_discovery.dart';
import 'package:pepehub/video/video_discovery_scan.dart';
import 'package:pepehub/video/video_library_page.dart';
import 'package:pepehub/video/video_media_actions.dart';
import 'package:pepehub/video/video_media_status.dart';
import 'package:pepehub/video/video_media_tools.dart';
import 'package:pepehub/video/video_repository.dart';

class _Deleter implements VideoFileDeleter {
  final calls = <List<String>>[];
  @override
  Future<({Set<String> deleted, Set<String> failed})> delete(
    List<String> sources,
  ) async {
    calls.add(sources);
    return (deleted: sources.toSet(), failed: <String>{});
  }
}

class _Sizer implements VideoFileSizer {
  final Map<String, int> known;
  _Sizer(this.known);
  @override
  Future<Map<String, int>> sizes(List<String> sources) async => {
    for (final source in sources)
      if (known[source] case final int size) source: size,
  };
}

class _Scanner implements VideoDiscoveryScanner {
  final List<VideoCandidate> files;
  _Scanner(this.files);
  @override
  bool get supportsDevice => false;
  @override
  Future<({String root, String title})?> pickRoot() async => null;
  @override
  Future<VideoScanResult> scan({
    required List<({String root, String title})> roots,
    required bool device,
    void Function(int found)? onProgress,
    bool quiet = false,
  }) async => VideoScanResult(files);
  @override
  Future<void> cancel() async {}
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle();
}

VideoProgress _at(VideoLesson lesson, int ms, DateTime when) => VideoProgress(
  lessonId: lesson.id,
  mediaVersion: lesson.mediaVersion,
  positionMs: ms,
  speed: 1,
  updatedAt: when,
);

void main() {
  late AppDatabase db;
  late VideoRepository videos;
  setUp(() {
    VideoAutoDiscovery.reset();
    db = AppDatabase(NativeDatabase.memory());
    videos = VideoRepository(Repository(db));
  });
  tearDown(() => db.close());

  Future<void> watch(VideoLesson lesson, int ms, DateTime when) =>
      videos.checkpoint(
        lesson: lesson,
        progress: _at(lesson, ms, when),
        intervals: const [],
      );

  group('watch state', () {
    test('files and items go fresh → started → done', () {
      const lesson = VideoLesson(
        id: 'l',
        itemId: 'i',
        title: 'L',
        module: '',
        source: '/l.mp4',
        mediaVersion: 'v',
        ordinal: 0,
        durationMs: 600000,
      );
      final now = DateTime(2026);
      expect(videoLessonState(lesson, {}, {}), VideoWatchState.fresh);
      expect(
        videoLessonState(lesson, {'l': _at(lesson, 1000, now)}, {}),
        VideoWatchState.started,
      );
      expect(
        videoLessonState(lesson, {'l': _at(lesson, 595000, now)}, {}),
        VideoWatchState.done,
      );
      final stale = VideoProgress(
        lessonId: 'l',
        mediaVersion: 'old',
        positionMs: 1000,
        speed: 1,
        updatedAt: now,
      );
      expect(videoLessonState(lesson, {'l': stale}, {}), VideoWatchState.fresh);
      expect(
        videoLessonState(lesson, {}, {
          'l:v': VideoLearningState(
            lessonId: 'l',
            mediaVersion: 'v',
            coverageCompletedAt: now,
          ),
        }),
        VideoWatchState.done,
      );
      expect(videoLengthMatches('short', 5 * 60000), isTrue);
      expect(videoLengthMatches('long', 5 * 60000), isFalse);
      expect(videoLengthMatches('medium', 30 * 60000), isTrue);
    });

    test('continue entries: last unfinished file or the next lesson', () async {
      final course = await videos.addSources(
        title: 'Курс',
        sources: [
          const VideoSourceDraft('/c1.mp4', 'Один', durationMs: 600000),
          const VideoSourceDraft('/c2.mp4', 'Два', durationMs: 600000),
        ],
      );
      final film = await videos.addSources(
        title: 'Фильм',
        sources: [
          const VideoSourceDraft('/f.mp4', 'Фильм', durationMs: 600000),
        ],
      );
      final [one, two] = await videos.lessons(itemId: course.id);
      final movie = (await videos.lessons(itemId: film.id)).single;
      await watch(one, 599000, DateTime.utc(2026, 1, 2));
      await watch(movie, 60000, DateTime.utc(2026, 1, 1));
      final lessons = await videos.lessons();
      final entries = videoContinueEntries(
        items: await videos.items(),
        lessonsByItem: {
          for (final item in await videos.items())
            item.id: [
              for (final lesson in lessons)
                if (lesson.itemId == item.id) lesson,
            ],
        },
        progress: await videos.allProgress(),
        learning: await videos.allLearningStates(),
      );
      expect(entries.map((e) => e.lesson.id), [two.id, movie.id]);
      expect(entries.first.progress, isNull, reason: 'the next lesson');
      final hidden = videoContinueEntries(
        items: await videos.items(),
        lessonsByItem: {
          film.id: [movie],
        },
        progress: await videos.allProgress(),
        learning: const {},
        hidden: {entries.last.hideKey},
      );
      expect(hidden, isEmpty);
    });
  });

  group('repository', () {
    test('automatic search marks new files until the item is opened', () async {
      final item = await videos.addSources(
        title: 'Сериал',
        sources: [const VideoSourceDraft('/s1.mp4', 'S1')],
        markNew: true,
      );
      final first = (await videos.lessons()).single;
      expect((await videos.items()).single.newLessons, [first.id]);
      await videos.addSources(
        title: 'Сериал',
        itemId: item.id,
        sources: [const VideoSourceDraft('/s2.mp4', 'S2')],
        markNew: true,
      );
      final updated = (await videos.items()).single;
      expect(updated.kind, VideoItemKind.course);
      expect(updated.newLessons, hasLength(2));
      await videos.clearNew(item.id);
      expect((await videos.items()).single.newLessons, isEmpty);
    });

    test('removed files stay in the trash and keep auto search away', () async {
      final course = await videos.addSources(
        title: 'Курс',
        sources: [
          const VideoSourceDraft('/t1.mp4', 'T1'),
          const VideoSourceDraft('/t2.mp4', 'T2'),
        ],
      );
      final single = await videos.addSources(
        title: 'Одно',
        sources: [const VideoSourceDraft('/one.mp4', 'Одно')],
      );
      final [t1, _] = await videos.lessons(itemId: course.id);
      await videos.removeLessons([t1.id]);
      await videos.removeItem(single.id);
      var trash = await videos.trash();
      expect(trash.map((e) => e.title), containsAll(['T1', 'Одно']));
      expect(trash.firstWhere((e) => e.title == 'T1').parentTitle, 'Курс');
      // Manual search offers removed files again, automatic search does not.
      expect((await videos.knownMedia()).sources, isNot(contains('/one.mp4')));
      expect(
        (await videos.knownMedia(includeRemoved: true)).sources,
        containsAll(['/one.mp4', '/t1.mp4']),
      );
      await videos.restoreTrash(trash.firstWhere((e) => e.title == 'Одно'));
      expect((await videos.items()).map((i) => i.title), contains('Одно'));
      expect((await videos.knownMedia()).sources, contains('/one.mp4'));
      trash = await videos.trash();
      expect(trash.map((e) => e.title), ['T1']);
      // Older than 30 days: gone from the trash, still ignored by auto search.
      expect(
        await videos.trash(now: DateTime.now().add(const Duration(days: 31))),
        isEmpty,
      );
      expect(await videos.trash(), isEmpty);
      expect(
        (await videos.knownMedia(includeRemoved: true)).sources,
        contains('/t1.mp4'),
      );
    });

    test('files deleted from the device do not go to the trash', () async {
      await videos.addSources(
        title: 'Удалённое',
        sources: [const VideoSourceDraft('/gone.mp4', 'Gone')],
      );
      final lesson = (await videos.lessons()).single;
      await videos.removeLessons([lesson.id], trash: false);
      expect(await videos.trash(), isEmpty);
    });

    test('auto search does not add back what the user removed', () async {
      await videos.saveDiscoverySettings(
        const VideoDiscoverySettings(
          roots: [(root: '/Movies', title: 'Movies')],
          auto: true,
        ),
      );
      final scanner = _Scanner([
        VideoCandidate(
          source: 'uri:Movies/Dune.mkv',
          path: 'Movies/Dune.mkv',
          size: 900000000,
        ),
      ]);
      final first = await VideoAutoDiscovery.search(videos, scanner);
      expect(first?.files, 1);
      final item = (await videos.items()).single;
      expect(item.newLessons, hasLength(1));
      await videos.removeItem(item.id);
      VideoAutoDiscovery.reset();
      final second = await VideoAutoDiscovery.search(videos, scanner);
      expect(second?.files ?? 0, 0);
      expect(await videos.items(), isEmpty);
    });

    test('duplicates by content or by name and size', () async {
      await videos.addSources(
        title: 'A',
        sources: [
          const VideoSourceDraft(
            '/a/x.mp4',
            'X',
            identity: VideoFileIdentity(100, 1, 'f1'),
          ),
        ],
      );
      await videos.addSources(
        title: 'B',
        sources: [
          const VideoSourceDraft(
            '/b/copy.mp4',
            'Copy',
            identity: VideoFileIdentity(100, 2, 'f1'),
          ),
        ],
      );
      await videos.addSources(
        title: 'C',
        sources: [const VideoSourceDraft('/c/y.mp4', 'Y', size: 50)],
      );
      await videos.addSources(
        title: 'D',
        sources: [const VideoSourceDraft('/d/y.mp4', 'Y2', size: 50)],
      );
      await videos.addSources(
        title: 'E',
        sources: [const VideoSourceDraft('/e/z.mp4', 'Z', size: 70)],
      );
      final groups = videoDuplicateGroups(await videos.fileFacts(audio: false));
      expect(groups, hasLength(2));
      expect(
        groups.map((g) => g.map((f) => f.lesson.source).toSet()),
        containsAll([
          {'/a/x.mp4', '/b/copy.mp4'},
          {'/c/y.mp4', '/d/y.mp4'},
        ]),
      );
    });

    test('one file in two places of the library is not a copy', () {
      VideoFileFact fact(String id, String source) => VideoFileFact(
        VideoLesson(
          id: id,
          itemId: 'i$id',
          title: id,
          module: '',
          source: source,
          mediaVersion: 'v',
          ordinal: 0,
        ),
        100,
        'head-tail-v1:f1',
        'x.mp4',
      );
      // The same path twice, once with other case on Windows, and a folder
      // link and a picked document of one Android file.
      final groups = videoDuplicateGroups([
        fact('a', r'C:\Video\x.mp4'),
        fact('b', 'c:/video/X.MP4'),
        fact(
          'c',
          'content://com.android.externalstorage.documents/tree/'
              'primary%3AMovies/document/primary%3AMovies%2Fx.mp4',
        ),
        fact(
          'd',
          'content://com.android.externalstorage.documents/document/'
              'primary%3AMovies%2Fx.mp4',
        ),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.map((f) => f.lesson.id), ['a', 'c']);

      // A media document may be the very file of a folder document.
      final media = fact(
        'm',
        'content://com.android.providers.media.documents/document/video%3A12',
      );
      expect(videoMaybeSameFile(media, groups.single[1]), isTrue);
      expect(videoMaybeSameFile(groups.single[0], groups.single[1]), isFalse);
    });

    test(
      'sizes are saved, skip and cover settings belong to the item',
      () async {
        final item = await videos.addSources(
          title: 'Курс',
          sources: [
            const VideoSourceDraft('/k1.mp4', 'K1'),
            const VideoSourceDraft('/k2.mp4', 'K2'),
          ],
        );
        final [k1, _] = await videos.lessons(itemId: item.id);
        await videos.saveFileSizes({k1.id: 1234});
        final facts = await videos.fileFacts(audio: false);
        expect(facts.firstWhere((f) => f.lesson.id == k1.id).size, 1234);

        expect(await videos.skipSettings(item.id), (introMs: 0, outroMs: 0));
        await videos.saveSkipSettings(item.id, introMs: 85000, outroMs: 30000);
        expect(await videos.skipSettings(item.id), (
          introMs: 85000,
          outroMs: 30000,
        ));
        expect(
          () => videos.saveSkipSettings(item.id, introMs: -1, outroMs: 0),
          throwsArgumentError,
        );

        final old = await videos.setCover(item.id, 'x.png');
        expect(old, isNull);
        expect((await videos.items()).single.cover, 'x.png');
        expect(await videos.setCover(item.id, null), 'x.png');
        expect((await videos.items()).single.cover, isNull);
      },
    );
  });

  test('covers are kept as files with safe names', () async {
    final folder = await Directory.systemTemp.createTemp('pepehub-covers');
    addTearDown(() => folder.delete(recursive: true));
    final covers = VideoCovers(directory: folder);
    final name = await covers.saveRaw(Uint8List.fromList([1, 2, 3]));
    expect(covers.file(name)!.existsSync(), isTrue);
    expect(covers.file('../evil.png'), isNull);
    await covers.discard(name);
    expect(covers.file(name)!.existsSync(), isFalse);
  });

  Widget library({_Deleter? deleter}) => MaterialApp(
    home: VideoLibraryPage(
      repository: videos,
      navigation: ShelfNavigation(
        current: PepeSection.video,
        onSelect: (_) {},
        onSettings: () {},
      ),
      deleter: deleter ?? _Deleter(),
    ),
  );

  testWidgets('continue shelf, filters and the new badge', (tester) async {
    _phone(tester);
    await tester.runAsync(() async {
      await videos.addSources(
        title: 'Начатый',
        sources: [
          const VideoSourceDraft('/p.mp4', 'Начатый', durationMs: 3600000 * 2),
        ],
      );
      await videos.addSources(
        title: 'Новинка',
        sources: [
          const VideoSourceDraft('/n.mp4', 'Новинка', durationMs: 60000),
        ],
        markNew: true,
      );
      await videos.addSources(
        title: 'Готовый',
        sources: [
          const VideoSourceDraft('/d.mp4', 'Готовый', durationMs: 600000),
        ],
      );
      final all = await videos.lessons();
      await watch(
        all.firstWhere((l) => l.source == '/p.mp4'),
        120000,
        DateTime.now().toUtc(),
      );
      await setLessonsWatched(videos, [
        all.firstWhere((l) => l.source == '/d.mp4'),
      ], true);
    });
    await tester.pumpWidget(library());
    await _settle(tester);
    expect(find.text('Продолжить просмотр'), findsOneWidget);
    expect(find.byKey(const ValueKey('continue-shelf')), findsOneWidget);
    expect(find.text('Новое'), findsOneWidget);

    Future<void> filter(String label) async {
      await tester.tap(find.byKey(const ValueKey('media-filter')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<String>, label),
      );
      await _settle(tester);
    }

    Iterable<String> titles() => [
      for (final item in tester.widgetList<Text>(find.byType(Text)))
        if (const ['Начатый', 'Новинка', 'Готовый'].contains(item.data))
          item.data!,
    ];

    await filter('Досмотрены');
    expect(titles(), ['Готовый']);
    await filter('В процессе');
    expect(titles(), contains('Начатый'));
    expect(titles(), isNot(contains('Готовый')));
    await filter('Новые');
    expect(titles(), ['Новинка']);
    await filter('Все');
    await filter('Дольше часа');
    expect(titles().toSet(), {'Начатый'});
    expect(await videos.repository.meta('media-length-filter'), 'long');
    await filter('Любая длина');

    // Hiding an entry of the shelf.
    await tester.longPress(
      find.descendant(
        of: find.byKey(const ValueKey('continue-shelf')),
        matching: find.text('Начатый'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Убрать из «Продолжить»'));
    await _settle(tester);
    expect(find.text('Продолжить просмотр'), findsNothing);
  });

  testWidgets('trash page restores a removed video', (tester) async {
    _phone(tester);
    await tester.runAsync(() async {
      final item = await videos.addSources(
        title: 'В корзину',
        sources: [const VideoSourceDraft('/r.mp4', 'В корзину')],
      );
      await videos.removeItem(item.id);
    });
    await tester.pumpWidget(
      MaterialApp(home: VideoTrashPage(repository: videos)),
    );
    await _settle(tester);
    expect(find.text('В корзину'), findsOneWidget);
    await tester.tap(find.text('Вернуть'));
    await _settle(tester);
    expect(find.text('Корзина пуста'), findsOneWidget);
    expect((await tester.runAsync(videos.items))!.map((i) => i.title), [
      'В корзину',
    ]);
  });

  testWidgets('storage page measures, sorts and deletes watched files', (
    tester,
  ) async {
    _phone(tester);
    final deleter = _Deleter();
    await tester.runAsync(() async {
      await videos.addSources(
        title: 'Маленький',
        sources: [const VideoSourceDraft('/s.mp4', 'Маленький', size: 1024)],
      );
      await videos.addSources(
        title: 'Большой',
        sources: [const VideoSourceDraft('/b.mp4', 'Большой')],
      );
      final big = (await videos.lessons()).firstWhere(
        (l) => l.source == '/b.mp4',
      );
      await setLessonsWatched(videos, [big], true);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: VideoStoragePage(
          repository: videos,
          deleter: deleter,
          sizer: _Sizer({'/b.mp4': 5 * 1024 * 1024}),
        ),
      ),
    );
    await _settle(tester);
    expect(find.textContaining('Видео занимают 5'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Большой')).dy,
      lessThan(tester.getTopLeft(find.text('Маленький')).dy),
    );
    await tester.tap(find.byKey(const ValueKey('storage-only-done')));
    await tester.pumpAndSettle();
    expect(find.text('Маленький'), findsNothing);
    final big = (await tester.runAsync(videos.items))!
        .firstWhere((i) => i.title == 'Большой');
    await tester.tap(find.byKey(ValueKey('storage-delete:${big.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Удалить файлы'));
    await _settle(tester);
    expect(deleter.calls.single, ['/b.mp4']);
    expect(find.text('Большой'), findsNothing);
  });

  testWidgets('duplicates page keeps the watched copy', (tester) async {
    _phone(tester);
    final deleter = _Deleter();
    await tester.runAsync(() async {
      await videos.addSources(
        title: 'Первая',
        sources: [const VideoSourceDraft('/1/v.mp4', 'Первая', size: 99)],
      );
      await videos.addSources(
        title: 'Вторая',
        sources: [const VideoSourceDraft('/2/v.mp4', 'Вторая', size: 99)],
      );
      final second = (await videos.lessons()).firstWhere(
        (l) => l.source == '/2/v.mp4',
      );
      await watch(second, 30000, DateTime.now().toUtc());
    });
    await tester.pumpWidget(
      MaterialApp(
        home: VideoDuplicatesPage(repository: videos, deleter: deleter),
      ),
    );
    await _settle(tester);
    expect(find.textContaining('Групп: 1'), findsOneWidget);
    await tester.tap(find.text('Оставить одну'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Удалить файлы'));
    await _settle(tester);
    expect(deleter.calls.single, ['/1/v.mp4']);
    expect(find.text('Повторяющихся файлов нет.'), findsOneWidget);
  });
}
