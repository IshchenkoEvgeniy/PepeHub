import 'dart:async';
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
import 'package:pepehub/video/video_discovery.dart';
import 'package:pepehub/video/video_discovery_page.dart';
import 'package:pepehub/video/video_discovery_scan.dart';
import 'package:pepehub/video/video_library_page.dart';
import 'package:pepehub/video/video_repository.dart';
import 'package:pepehub/video/video_thumbnails.dart';

class _Checker implements VideoSourceChecker {
  Set<String> missing = {}, present = {};
  int calls = 0;
  @override
  Future<({Set<String> missing, Set<String> present})?> check(
    List<String> sources,
  ) async {
    calls++;
    return (
      missing: {
        for (final s in sources)
          if (missing.contains(s)) s,
      },
      present: {
        for (final s in sources)
          if (present.contains(s)) s,
      },
    );
  }
}

class _Scanner implements VideoDiscoveryScanner {
  List<VideoCandidate> files;
  final scans = <bool>[];
  _Scanner(this.files);
  @override
  bool get supportsDevice => true;
  @override
  Future<({String root, String title})?> pickRoot() async => null;
  @override
  Future<VideoScanResult> scan({
    required List<({String root, String title})> roots,
    required bool device,
    void Function(int found)? onProgress,
    bool quiet = false,
  }) async {
    scans.add(quiet);
    return VideoScanResult(files);
  }

  @override
  Future<void> cancel() async {}
}

class _Frames implements VideoFrameSource {
  final requests = <String>[];
  final pending = <String, Completer<Uint8List?>>{};
  @override
  int get concurrency => 1;
  @override
  Future<Uint8List?> frame(VideoLesson lesson) {
    requests.add(lesson.source);
    return (pending[lesson.source] = Completer<Uint8List?>()).future;
  }
}

VideoCandidate _file(String path, {int size = 1000}) =>
    VideoCandidate(source: 'uri:$path', path: path, size: size);

VideoLesson _lesson(String source) => VideoLesson(
  id: source,
  itemId: 'item',
  title: source,
  module: '',
  source: source,
  mediaVersion: 'v1',
  ordinal: 0,
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

  group('deleted files', () {
    test(
      'are hidden, forgotten by search and come back with the file',
      () async {
        final course = await videos.addSources(
          title: 'Курс',
          sources: [
            const VideoSourceDraft(
              '/videos/a.mp4',
              'A',
              relativeName: 'a.mp4',
              size: 10,
            ),
            const VideoSourceDraft(
              '/videos/b.mp4',
              'B',
              relativeName: 'b.mp4',
              size: 20,
            ),
            const VideoSourceDraft('https://example.com/c.mp4', 'C'),
          ],
        );
        final locals = await videos.localSources();
        expect(locals.map((l) => l.source), [
          '/videos/a.mp4',
          '/videos/b.mp4',
        ], reason: 'links are never checked');

        final checker = _Checker()..missing = {'/videos/b.mp4'};
        expect(await VideoAutoDiscovery.checkSources(videos, checker), 1);
        expect((await videos.lessons(hideMissing: true)).map((l) => l.title), [
          'A',
          'C',
        ]);
        final all = await videos.lessons(itemId: course.id);
        expect(
          all,
          hasLength(3),
          reason: 'the course editor keeps every lesson',
        );
        expect(all.firstWhere((l) => l.title == 'B').missing, isTrue);
        final known = await videos.knownMedia();
        expect(known.sources.contains('/videos/b.mp4'), isFalse);
        expect(known.contains('other', 'b.mp4', 20), isFalse);
        expect(known.contains('other', 'a.mp4', 10), isTrue);

        // Within a minute nothing is checked again.
        expect(await VideoAutoDiscovery.checkSources(videos, checker), 0);
        expect(checker.calls, 1);

        checker
          ..missing = {}
          ..present = {'/videos/b.mp4'};
        expect(
          await VideoAutoDiscovery.checkSources(videos, checker, force: true),
          1,
        );
        expect(await videos.lessons(hideMissing: true), hasLength(3));
        // Unknown answers change nothing.
        checker.present = {};
        expect(
          await VideoAutoDiscovery.checkSources(videos, checker, force: true),
          0,
        );
      },
    );

    test('a video whose only file is gone leaves the list', () async {
      await videos.addSources(
        title: 'Фильм',
        sources: [const VideoSourceDraft('/videos/film.mp4', 'Фильм')],
      );
      await videos.applySourceCheck(missing: {'/videos/film.mp4'}, present: {});
      expect(await videos.lessons(hideMissing: true), isEmpty);
      expect(await videos.items(), hasLength(1));
    });
  });

  test('items come in the order they were added', () async {
    for (final title in ['Б', 'А', 'В']) {
      await videos.addSources(
        title: title,
        sources: [VideoSourceDraft('/$title.mp4', title)],
      );
    }
    final first = (await videos.items()).first;
    await videos.setFavorite(first, true);
    expect((await videos.items()).map((i) => i.title), ['Б', 'А', 'В']);
  });

  test('automatic search setting round-trips', () async {
    await videos.saveDiscoverySettings(
      const VideoDiscoverySettings(device: true, auto: true),
    );
    expect((await videos.discoverySettings()).auto, isTrue);
    await videos.saveDiscoverySettings(
      const VideoDiscoverySettings(device: true),
    );
    expect((await videos.discoverySettings()).auto, isFalse);
  });

  group('automatic search', () {
    test('does nothing until turned on', () async {
      final scanner = _Scanner([_file('Movies/Dune.mkv')]);
      await videos.saveDiscoverySettings(
        const VideoDiscoverySettings(device: true),
      );
      expect(await VideoAutoDiscovery.search(videos, scanner), isNull);
      expect(scanner.scans, isEmpty);
    });

    test('adds what a manual search ticks and new episodes later', () async {
      final scanner = _Scanner([
        _file('Movies/Friends.S01E01.mkv'),
        _file('Movies/Friends.S01E02.mkv'),
        _file('Movies/Курсы/Dart/01 Введение.mp4'),
        _file('Movies/Курсы/Dart/02 Типы.mp4'),
        _file('Movies/Курсы/Go/01 Старт.mp4'),
        _file('Movies/Курсы/Go/02 Типы.mp4'),
        _file('DCIM/Camera/VID_1.mp4'),
        _file('Telegram/Telegram Video/clip.mp4'),
      ]);
      await videos.saveDiscoverySettings(
        const VideoDiscoverySettings(
          device: true,
          auto: true,
          ignored: {'folder:movies/курсы/go'},
        ),
      );
      final result = await VideoAutoDiscovery.search(videos, scanner);
      expect(scanner.scans, [true], reason: 'never asks for access');
      expect(result!.groups, 2);
      expect(result.files, 4);
      expect((await videos.items()).map((i) => i.title).toSet(), {
        'Friends',
        'Dart',
      });

      // Throttled, then a new episode joins the series.
      scanner.files = [...scanner.files, _file('Movies/Friends.S01E03.mkv')];
      expect(await VideoAutoDiscovery.search(videos, scanner), isNull);
      final next = await VideoAutoDiscovery.search(
        videos,
        scanner,
        force: true,
      );
      expect(next!.files, 1);
      final friends = (await videos.items()).firstWhere(
        (i) => i.title == 'Friends',
      );
      expect(await videos.lessons(itemId: friends.id), hasLength(3));
      expect(await videos.items(), hasLength(2));
    });

    test('waits while the search page is open', () async {
      final scanner = _Scanner([_file('Movies/Dune.mkv', size: 900 << 20)]);
      await videos.saveDiscoverySettings(
        const VideoDiscoverySettings(device: true, auto: true),
      );
      VideoAutoDiscovery.manualStarted();
      expect(await VideoAutoDiscovery.search(videos, scanner), isNull);
      VideoAutoDiscovery.manualEnded();
      expect((await VideoAutoDiscovery.search(videos, scanner))!.files, 1);
    });
  });

  group('thumbnails', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('pepehub-thumbs');
    });
    tearDown(() => dir.delete(recursive: true));

    test(
      'decode newest first, skip cancelled rows and reuse the disk',
      () async {
        final frames = _Frames();
        final thumbs = VideoThumbnails(
          source: frames,
          directory: () async => dir,
        );
        final a = _lesson('/a.mp4'),
            b = _lesson('/b.mp4'),
            c = _lesson('/c.mp4');
        final first = thumbs.load(a);
        await pumpEventQueue();
        expect(frames.requests, ['/a.mp4']);
        final second = thumbs.load(b);
        final third = thumbs.load(c);
        await pumpEventQueue();
        thumbs.cancel(b); // scrolled away before decoding
        expect(await second, isNull);
        frames.pending['/a.mp4']!.complete(Uint8List.fromList([1, 2, 3]));
        expect(await first, [1, 2, 3]);
        await pumpEventQueue();
        expect(frames.requests, ['/a.mp4', '/c.mp4']);
        frames.pending['/c.mp4']!.complete(null);
        expect(await third, isNull);
        expect(await thumbs.load(c), isNull, reason: 'failures are remembered');
        expect(thumbs.cached(a), [1, 2, 3]);

        // A new session reads the frame from disk without decoding.
        final again = _Frames();
        final reopened = VideoThumbnails(
          source: again,
          directory: () async => dir,
        );
        expect(await reopened.load(a), [1, 2, 3]);
        expect(again.requests, isEmpty);
        // Links, music and deleted files have no preview.
        expect(VideoThumbnails.supports(_lesson('https://x/y.mp4')), isFalse);
        expect(VideoThumbnails.supports(_lesson('/song.mp3')), isFalse);
      },
    );
  });

  testWidgets('the search page turns automatic search on', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: VideoDiscoveryPage(repository: videos, scanner: _Scanner([])),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Найти видео'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('discovery-auto')));
    await tester.pumpAndSettle();
    expect((await videos.discoverySettings()).auto, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('media list sorts, hides deleted files and adds found videos', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final checker = _Checker()..missing = {'/videos/gone.mp4'};
    final scanner = _Scanner([
      _file('Movies/Friends.S01E01.mkv'),
      _file('Movies/Friends.S01E02.mkv'),
    ]);
    await tester.runAsync(() async {
      for (final title in ['Бета', 'Альфа', 'Удалённое']) {
        await videos.addSources(
          title: title,
          sources: [
            VideoSourceDraft(
              title == 'Удалённое' ? '/videos/gone.mp4' : '/videos/$title.mp4',
              title,
              durationMs: title == 'Бета' ? 600000 : 60000,
            ),
          ],
        );
      }
      await videos.saveDiscoverySettings(
        const VideoDiscoverySettings(device: true, auto: true),
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        home: VideoLibraryPage(
          repository: videos,
          navigation: ShelfNavigation(
            current: PepeSection.video,
            onSelect: (_) {},
            onSettings: () {},
          ),
          sourceChecker: checker,
          discoveryScanner: scanner,
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    expect(find.text('Удалённое'), findsNothing);
    expect(find.textContaining('Автопоиск добавил видео: 2'), findsOneWidget);
    expect(find.text('Friends'), findsOneWidget);
    expect(find.byType(VideoThumbnail), findsNWidgets(3));
    expect(tester.takeException(), isNull);

    double top(String title) => tester.getTopLeft(find.text(title)).dy;
    // Nothing watched yet: «recent» falls back to the title.
    expect(top('Альфа'), lessThan(top('Бета')));

    Future<void> sortBy(String label) async {
      await tester.tap(find.byKey(const ValueKey('media-sort')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(CheckedPopupMenuItem<String>, label),
      );
      await tester.pumpAndSettle();
    }

    await sortBy('Недавно добавленные');
    expect(top('Friends'), lessThan(top('Альфа')));
    expect(top('Альфа'), lessThan(top('Бета')));
    await sortBy('По названию Я–А');
    expect(top('Бета'), lessThan(top('Альфа')));
    await sortBy('Сначала длинные');
    expect(top('Бета'), lessThan(top('Альфа')));
    expect(await videos.repository.meta('media-sort'), 'duration');
  });
}
