import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/video/models.dart';
import 'package:pepehub/video/video_discovery.dart';
import 'package:pepehub/video/video_repository.dart';

const _mb = 1024 * 1024;

VideoCandidate _file(
  String path, {
  int size = 100 * _mb,
  int? durationMs,
  int modifiedMs = 0,
}) => VideoCandidate(
  source: 'src:$path',
  path: path,
  size: size,
  durationMs: durationMs,
  modifiedMs: modifiedMs,
);

VideoDiscoveryResult _group(
  List<VideoCandidate> files, {
  VideoGrouping grouping = VideoGrouping.smart,
  Set<String> knownSources = const {},
  Set<String> knownFileKeys = const {},
  Map<String, String> existingKeys = const {},
}) => groupVideoCandidates(
  VideoDiscoveryRequest(
    files,
    grouping: grouping,
    knownSources: knownSources,
    knownFileKeys: knownFileKeys,
    existingKeys: existingKeys,
    existingTitles: {for (final id in existingKeys.values) id: 'Уже есть'},
  ),
);

VideoGroupProposal _byTitle(VideoDiscoveryResult result, String title) =>
    result.groups.singleWhere((group) => group.title == title);

void main() {
  group('smart grouping', () {
    test('series across folders get seasons as modules', () {
      final result = _group([
        _file('Movies/Сериалы/Friends.S02E01.1080p.WEB-DL.mkv'),
        _file('Movies/Сериалы/Friends.S01E02.1080p.WEB-DL.mkv'),
        _file('Download/Friends.S01E01.720p.mkv'),
      ]);
      final series = _byTitle(result, 'Friends');
      expect(series.kind, VideoGroupKind.series);
      expect(series.files.map((f) => f.candidate.name), [
        'Friends.S01E01.720p.mkv',
        'Friends.S01E02.1080p.WEB-DL.mkv',
        'Friends.S02E01.1080p.WEB-DL.mkv',
      ]);
      expect(series.files.map((f) => f.module), [
        'Сезон 1',
        'Сезон 1',
        'Сезон 2',
      ]);
      expect(result.groups, hasLength(1));
    });

    test('russian episode words and series named by folder', () {
      final result = _group([
        _file('Movies/Тёмные/Сезон 1/Серия 2.mp4'),
        _file('Movies/Тёмные/Сезон 1/Серия 1.mp4'),
        _file('Movies/Show/Season 1/S01E01.mkv'),
        _file('Movies/Show/Season 1/S01E02.mkv'),
      ]);
      final dark = _byTitle(result, 'Тёмные');
      expect(dark.kind, VideoGroupKind.series);
      expect(dark.files.map((f) => f.title), ['Серия 1', 'Серия 2']);
      expect(_byTitle(result, 'Show').files, hasLength(2));
    });

    test('words that only contain markers are not episodes', () {
      final result = _group([
        _file('Курсы/Йога/Step 05 Растяжка.mp4'),
        _file('Курсы/Йога/Deep 2 Дыхание.mp4'),
      ]);
      expect(
        result.groups.map((g) => g.kind),
        isNot(contains(VideoGroupKind.series)),
      );
    });

    test('numbered files and module folders make courses', () {
      final result = _group([
        _file('Курсы/Flutter/01 Основы/01 Введение.mp4'),
        _file('Курсы/Flutter/01 Основы/02 Виджеты.mp4'),
        _file('Курсы/Flutter/02 Практика/01 Проект.mp4'),
        _file('Курсы/Dart/Урок 2.mp4'),
        _file('Курсы/Dart/Урок 1.mp4'),
        _file('Курсы/Dart/Урок 10.mp4'),
      ]);
      final flutter = _byTitle(result, 'Flutter');
      expect(flutter.kind, VideoGroupKind.course);
      expect(flutter.folder, 'Курсы/Flutter');
      expect(flutter.files.map((f) => f.module), [
        '01 Основы',
        '01 Основы',
        '02 Практика',
      ]);
      final dart = _byTitle(result, 'Dart');
      expect(dart.kind, VideoGroupKind.course);
      expect(dart.files.map((f) => f.title), ['Урок 1', 'Урок 2', 'Урок 10']);
    });

    test('large unnumbered files are movies, small ones a collection', () {
      final result = _group([
        _file('Movies/Interstellar (2014) 1080p.mkv', size: 4000 * _mb),
        _file('Movies/Dune.2021.2160p.mkv', durationMs: 155 * 60 * 1000),
        _file('Movies/трейлер.mp4', size: 40 * _mb),
        _file('Movies/обзор.mp4', size: 60 * _mb),
      ]);
      expect(
        _byTitle(result, 'Interstellar (2014)').kind,
        VideoGroupKind.movie,
      );
      expect(_byTitle(result, 'Interstellar (2014)').single, isTrue);
      expect(_byTitle(result, 'Dune 2021').kind, VideoGroupKind.movie);
      final rest = _byTitle(result, 'Movies');
      expect(rest.kind, VideoGroupKind.collection);
      expect(rest.files, hasLength(2));
    });

    test('phone recordings, clips and duplicates are offered unticked', () {
      final november = DateTime(2026, 11, 3).millisecondsSinceEpoch;
      final result = _group([
        _file('DCIM/Camera/VID_1.mp4', modifiedMs: november),
        _file('DCIM/Camera/VID_2.mp4', modifiedMs: november),
        _file('Telegram/Telegram Video/a.mp4'),
        _file('Movies/Screenrecorder/rec.mp4'),
        _file('Download/meme.mp4', durationMs: 9000),
        _file('Download/Курс/01.mp4', size: 7),
        _file('Курсы/Копия/01.mp4', size: 7),
      ]);
      final camera = _byTitle(result, 'Камера · ноябрь 2026');
      expect(camera.files, hasLength(2));
      expect(camera.kind.selectedByDefault, isFalse);
      expect(_byTitle(result, 'Telegram').kind, VideoGroupKind.messenger);
      expect(_byTitle(result, 'Записи экрана').kind, VideoGroupKind.screen);
      expect(_byTitle(result, 'Короткие ролики').files, hasLength(1));
      final duplicates = _byTitle(result, 'Возможные дубликаты');
      expect(duplicates.files.single.candidate.path, 'Курсы/Копия/01.mp4');
      expect(result.groups.last.kind, VideoGroupKind.duplicates);
    });

    test('known media is skipped and earlier groups receive new files', () {
      final result = _group(
        [
          _file('Курсы/Dart/Урок 1.mp4'),
          _file('Курсы/Dart/Урок 2.mp4'),
          _file('Курсы/Dart/Урок 3.mp4', size: 55),
        ],
        knownSources: {'src:Курсы/Dart/Урок 1.mp4'},
        // The same file found earlier through Android's media index.
        knownFileKeys: {VideoKnownMedia.fileKey('Урок 3.mp4', 55)},
        existingKeys: {'folder:курсы/dart': 'item-1'},
      );
      expect(result.known, 2);
      final group = result.groups.single;
      expect(group.kind, VideoGroupKind.existing);
      expect(group.targetItemId, 'item-1');
      expect(group.title, 'Уже есть');
      expect(group.files.single.title, 'Урок 2');
      expect(group.single, isFalse);
    });

    test('one new episode joins a series already in the library', () {
      final result = _group(
        [_file('Download/Friends.S02E01.mkv')],
        existingKeys: {'series:friends': 'item-1'},
      );
      final group = result.groups.single;
      expect(group.kind, VideoGroupKind.existing);
      expect(group.targetItemId, 'item-1');
      expect(group.files.single.module, 'Сезон 2');
      // Without the series in the library one file is not a series.
      expect(
        _group([_file('Download/Friends.S02E01.mkv')]).groups.single.kind,
        isNot(VideoGroupKind.series),
      );
    });
  });

  test('folder grouping keeps every folder as it is', () {
    final result = _group([
      _file('Movies/Friends.S01E01.mkv'),
      _file('Download/Friends.S01E02.mkv'),
      _file('DCIM/Camera/VID_1.mp4'),
      _file('DCIM/Camera/VID_2.mp4'),
    ], grouping: VideoGrouping.folders);
    expect(
      {for (final group in result.groups) group.folder: group.files.length},
      {'Movies': 1, 'Download': 1, 'DCIM/Camera': 2},
    );
    expect(
      result.groups.every((group) => group.kind == VideoGroupKind.folder),
      isTrue,
    );
    expect(result.groups.map((g) => g.key), contains('folder:dcim/camera'));
  });

  test('ten thousand files group quickly and lose nothing', () {
    final files = <VideoCandidate>[
      for (var show = 0; show < 60; show++)
        for (var season = 1; season <= 3; season++)
          for (var episode = 1; episode <= 12; episode++)
            _file(
              'Сериалы/Show $show/Season $season/'
              'Show.$show.S${season.toString().padLeft(2, '0')}'
              'E${episode.toString().padLeft(2, '0')}.mkv',
              size: (show * 1000 + season * 100 + episode) * _mb,
            ),
      for (var course = 0; course < 200; course++)
        for (var lesson = 1; lesson <= 20; lesson++)
          _file(
            'Курсы/Курс $course/${lesson.toString().padLeft(2, '0')} Тема.mp4',
            size: 1000000 + course * 100 + lesson,
          ),
      for (var clip = 0; clip < 3840; clip++)
        _file(
          'DCIM/Camera/VID_$clip.mp4',
          size: 5000 + clip,
          modifiedMs: DateTime(2025, clip % 12 + 1).millisecondsSinceEpoch,
        ),
    ];
    expect(files, hasLength(10000));
    final watch = Stopwatch()..start();
    final result = _group(files);
    watch.stop();
    expect(
      watch.elapsed,
      lessThan(const Duration(seconds: 10)),
      reason: 'grouping took ${watch.elapsed}',
    );
    expect(result.groups.fold(0, (sum, g) => sum + g.files.length), 10000);
    expect(
      result.groups.where((g) => g.kind == VideoGroupKind.series),
      hasLength(60),
    );
    expect(
      result.groups.where((g) => g.kind == VideoGroupKind.course),
      hasLength(200),
    );
    expect(
      result.groups.where((g) => g.kind == VideoGroupKind.camera),
      hasLength(12),
    );
    expect(_byTitle(result, 'Show 7').files.first.module, 'Сезон 1');
  });

  test('folder sections come from stored folders, roots and sources', () {
    expect(
      videoFolderSection('Movies/Курсы/Flutter', course: true),
      'Movies/Курсы',
    );
    expect(videoFolderSection('Movies', course: false), 'Movies');
    expect(
      videoFolderSection(
        null,
        course: true,
        root: 'content://com.android.externalstorage.documents/tree/primary%3AMovies%2F%D0%9A%D1%83%D1%80%D1%81%D1%8B',
      ),
      'Movies',
    );
    expect(
      videoFolderSection(
        null,
        course: false,
        firstSource: 'content://com.android.externalstorage.documents/tree/1A2B-3C4D%3AVideo/document/1A2B-3C4D%3AVideo%2Fclip.mp4',
      ),
      'Карта памяти/Video',
    );
    expect(
      videoFolderSection(null, course: false, firstSource: r'C:\Videos\a.mp4'),
      'C:/Videos',
    );
    expect(
      videoFolderSection(
        null,
        course: false,
        firstSource: 'content://media/external/video/media/12',
      ),
      'Другие',
    );
    expect(
      videoFolderSection(
        null,
        course: false,
        firstSource: 'https://example.com/a.mp4',
      ),
      'Ссылки',
    );
  });

  group('repository', () {
    late AppDatabase db;
    late VideoRepository videos;
    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      videos = VideoRepository(Repository(db));
    });
    tearDown(() => db.close());

    test('found media keeps folder, key, size and duration', () async {
      final item = await videos.addSources(
        title: 'Dune',
        sources: [
          const VideoSourceDraft(
            'content://media/external/video/media/1',
            'Dune',
            relativeName: 'Movies/Dune.mkv',
            size: 4000,
            durationMs: 9000000,
          ),
        ],
        folder: 'Movies',
        discoveryKey: 'movie:movies/dune.mkv',
        single: true,
      );
      expect(item.kind, VideoItemKind.video);
      final saved = (await videos.items()).single;
      expect(saved.folder, 'Movies');
      expect(saved.discoveryKey, 'movie:movies/dune.mkv');
      expect((await videos.lessons()).single.durationMs, 9000000);
      final known = await videos.knownMedia();
      expect(
        known.contains('other-uri', 'Download/Dune.mkv', 4000),
        isTrue,
        reason: 'the same name and size through another source',
      );
      expect(known.contains('other-uri', 'Dune.mkv', 4001), isFalse);

      // A later search adds an episode: the video becomes a course.
      final grown = await videos.addSources(
        title: 'ignored',
        sources: [const VideoSourceDraft('content://x/2', 'Dune Part Two')],
        itemId: item.id,
      );
      expect(grown.kind, VideoItemKind.course);
      expect(await videos.lessons(itemId: item.id), hasLength(2));
      expect((await videos.items()).single.kind, VideoItemKind.course);
    });

    test('playlists keep order, skip repeats and survive removals', () async {
      final course = await videos.addSources(
        title: 'Курс',
        sources: [
          const VideoSourceDraft('a.mp4', 'A'),
          const VideoSourceDraft('b.mp4', 'B'),
          const VideoSourceDraft('c.mp4', 'C'),
        ],
      );
      final lessons = await videos.lessons(itemId: course.id);
      final [a, b, c] = [for (final lesson in lessons) lesson.id];
      final playlist = await videos.createPlaylist(
        'Вечер',
        section: 'video',
        entries: [c, a],
      );
      expect(await videos.addToPlaylist(playlist.id, [a, b]), 1);
      expect((await videos.playlists()).single.entries, [c, a, b]);

      // The screen showed only c and a (b's item was removed meanwhile):
      // reordering keeps b for a later restore.
      final saved = await videos.savePlaylistEntries(
        playlist.id,
        [a, c],
        shown: {a, c},
      );
      expect(saved.entries, [a, c, b]);
      final removed = await videos.savePlaylistEntries(
        playlist.id,
        [c],
        shown: {a, c, b},
      );
      expect(removed.entries, [c]);

      await videos.renamePlaylist(playlist.id, ' Утро ');
      expect((await videos.playlists()).single.title, 'Утро');
      await videos.deletePlaylist(playlist.id);
      expect(await videos.playlists(), isEmpty);
      expect(() => videos.addToPlaylist(playlist.id, [a]), throwsStateError);
      expect(
        () => videos.createPlaylist('  ', section: 'video'),
        throwsArgumentError,
      );
    });

    test('search settings round-trip', () async {
      await videos.saveDiscoverySettings(
        const VideoDiscoverySettings(
          roots: [(root: 'content://tree/a', title: 'Movies')],
          device: true,
          ignored: {'camera:2026-11'},
        ),
      );
      final settings = await videos.discoverySettings();
      expect(settings.roots.single.title, 'Movies');
      expect(settings.device, isTrue);
      expect(settings.ignored, {'camera:2026-11'});
    });
  });
}
