import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/main.dart';
import 'package:pepehub/video/video_discovery.dart';
import 'package:pepehub/video/video_discovery_page.dart';
import 'package:pepehub/video/video_discovery_scan.dart';
import 'package:pepehub/video/video_library_page.dart';
import 'package:pepehub/video/video_playlists.dart';
import 'package:pepehub/video/video_repository.dart';

class _FakeScanner implements VideoDiscoveryScanner {
  List<VideoCandidate> files;
  final scans = <({List<String> roots, bool device})>[];
  _FakeScanner(this.files);

  @override
  bool get supportsDevice => true;

  @override
  Future<({String root, String title})?> pickRoot() async =>
      (root: 'content://tree/movies', title: 'Movies');

  @override
  Future<VideoScanResult> scan({
    required List<({String root, String title})> roots,
    required bool device,
    void Function(int found)? onProgress,
  }) async {
    scans.add((roots: [for (final root in roots) root.root], device: device));
    onProgress?.call(files.length);
    return VideoScanResult(files);
  }

  @override
  Future<void> cancel() async {}
}

VideoCandidate _file(String path, {int size = 100}) =>
    VideoCandidate(source: 'uri:$path', path: path, size: size);

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('search proposes groups, adds the ticked ones and later '
      'offers new episodes for them on a 360px phone', (tester) async {
    _phone(tester);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final videos = VideoRepository(Repository(db));
    final scanner = _FakeScanner([
      _file('Movies/Friends.S01E01.mkv'),
      _file('Movies/Friends.S01E02.mkv'),
      _file('Movies/Курсы/Dart/01 Введение.mp4'),
      _file('Movies/Курсы/Dart/02 Типы.mp4'),
      _file('DCIM/Camera/VID_1.mp4'),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: VideoDiscoveryPage(repository: videos, scanner: scanner),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Добавить папку'));
    await tester.pumpAndSettle();
    expect(find.text('Movies'), findsOneWidget);
    await tester.tap(find.text('Найти видео'));
    await tester.pumpAndSettle();
    expect(scanner.scans.single.roots, ['content://tree/movies']);
    expect(find.textContaining('Найдено: 5'), findsOneWidget);
    // Groups are built lazily below the search settings.
    await tester.scrollUntilVisible(find.text('Friends'), 200);
    expect(find.text('Friends'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Dart'), 200);
    expect(find.text('Dart'), findsOneWidget);
    expect(tester.takeException(), isNull);

    Checkbox box(String key) => tester.widget<Checkbox>(
      find.descendant(
        of: find.byKey(ValueKey('discovery-group:$key')),
        matching: find.byType(Checkbox),
      ),
    );
    expect(box('series:friends').value, isTrue);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('discovery-group:camera')),
      200,
    );
    expect(box('camera').value, isFalse);

    await tester.tap(find.textContaining('Добавить выбранное'));
    await tester.pumpAndSettle();
    expect(find.text('Добавлено в медиатеку: 2'), findsOneWidget);
    final items = {for (final item in await videos.items()) item.title: item};
    expect(items.keys.toSet(), {'Friends', 'Dart'});
    expect(items['Friends']!.discoveryKey, 'series:friends');
    expect(items['Dart']!.folder, 'Movies/Курсы/Dart');

    // A new episode appears: the next search offers it for Friends.
    scanner.files = [...scanner.files, _file('Movies/Friends.S01E03.mkv')];
    await tester.scrollUntilVisible(find.text('Искать снова'), -200);
    await tester.tap(find.text('Искать снова'));
    await tester.pumpAndSettle();
    expect(find.textContaining('уже в медиатеке: 4'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.textContaining('Новое в медиатеке'),
      200,
    );
    expect(find.textContaining('Новое в медиатеке'), findsOneWidget);
    await tester.tap(find.textContaining('Добавить выбранное'));
    await tester.pumpAndSettle();
    expect(await videos.items(), hasLength(2));
    expect(await videos.lessons(itemId: items['Friends']!.id), hasLength(3));

    // Hiding keeps the camera group out of later searches. The snack bar
    // about the addition would cover the menu.
    tester
        .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
        .clearSnackBars();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byTooltip('Действия с группой'), 200);
    await tester.tap(find.byTooltip('Действия с группой').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Скрыть и не предлагать'));
    await tester.pumpAndSettle();
    expect((await videos.discoverySettings()).ignored, {'camera'});
    expect(find.text('Все найденные группы скрыты.'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('По папкам'), -200);
    await tester.tap(find.text('По папкам'));
    await tester.pumpAndSettle();
    // Folder groups have their own keys: hiding in smart mode keeps them.
    await tester.scrollUntilVisible(find.text('Camera'), 200);
    expect(find.text('Camera'), findsOneWidget);
    expect(find.textContaining('Папка'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('media list groups by folders and by playlists with large text '
      'on a 360px phone', (tester) async {
    _phone(tester);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = Repository(db), videos = VideoRepository(repo);
    await repo.setMeta('library-section', 'video');
    await repo.setMeta('appearance-settings', '{"textScale":1.3}');
    final dart = await videos.addSources(
      title: 'Dart',
      sources: [
        const VideoSourceDraft('a.mp4', 'Урок 1'),
        const VideoSourceDraft('b.mp4', 'Урок 2'),
      ],
      folder: 'Movies/Курсы/Dart',
    );
    await videos.addSources(
      title: 'Dune',
      sources: [const VideoSourceDraft('dune.mkv', 'Dune')],
      folder: 'Movies',
      single: true,
    );
    final lesson = (await videos.lessons(itemId: dart.id)).first;
    await videos.createPlaylist(
      'На вечер',
      section: 'video',
      entries: [lesson.id],
    );
    await tester.pumpWidget(PepeHubApp(repository: repo));
    await tester.pumpAndSettle();
    expect(find.byType(VideoLibraryPage), findsOneWidget);

    await tester.tap(find.text('Папки'));
    await tester.pumpAndSettle();
    expect(find.text('Movies/Курсы'), findsOneWidget);
    expect(find.text('Movies'), findsOneWidget);
    expect(await repo.meta('media-grouping'), 'folders');
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Плейлисты'));
    await tester.pumpAndSettle();
    expect(find.text('На вечер'), findsOneWidget);
    expect(find.text('Вне плейлистов'), findsOneWidget);
    expect(find.text('Dune'), findsOneWidget);
    expect(find.text('Dart'), findsNothing, reason: 'its lesson is listed');
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('На вечер'));
    await tester.pumpAndSettle();
    expect(find.byType(VideoPlaylistPage), findsOneWidget);
    expect(find.text('Урок 1'), findsOneWidget);
    await tester.tap(find.byTooltip('Убрать из плейлиста'));
    await tester.pumpAndSettle();
    expect((await videos.playlists()).single.entries, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
