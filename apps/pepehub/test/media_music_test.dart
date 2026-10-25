import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/ui/shelf_components.dart';
import 'package:pepehub/video/media_formats.dart';
import 'package:pepehub/video/models.dart';
import 'package:pepehub/video/video_activity.dart';
import 'package:pepehub/video/video_controller.dart';
import 'package:pepehub/video/video_engine.dart';
import 'package:pepehub/video/video_folder_sync.dart';
import 'package:pepehub/video/video_import.dart';
import 'package:pepehub/video/video_library_page.dart';
import 'package:pepehub/video/video_player_page.dart';
import 'package:pepehub/video/video_repository.dart';
import 'package:pepehub/video/video_session.dart';

import 'support/video_engine.dart';

class MusicEngine extends TestVideoEngine {
  final modes = <bool>[];
  @override
  Future<void> setAudioOnly(bool enabled) async {
    modes.add(enabled);
  }
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

class Harness {
  final db = AppDatabase(NativeDatabase.memory());
  late final repository = Repository(db), videos = VideoRepository(repository);
  final engine = MusicEngine();
  late VideoPlaybackController player;
  int clock = 0;
  Future<void> open({bool mixed = false}) async {
    final item = await videos.addSources(
      title: 'Music',
      sources: [
        const VideoSourceDraft('one.mp3', 'One'),
        VideoSourceDraft(mixed ? 'two.mp4' : 'two.flac', 'Two'),
      ],
    );
    player = VideoPlaybackController(
      repository: videos,
      engine: engine,
      lessons: await videos.lessons(itemId: item.id),
      checkpointPeriod: null,
      nowMonotonic: () => clock,
      now: () => DateTime.utc(2026, 10, 21).add(Duration(milliseconds: clock)),
    );
    await player.load(0);
  }

  Future<void> close() async {
    await player.close();
    player.dispose();
    await db.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('music recognition covers paths, SAF, signed URLs and explicit opaque sources', () {
    for (final source in [
      r'L:\Music\Track.MP3',
      r'L:\Music\Track #1.MP3',
      'https://example.org/a.flac?token=x#part',
      'content://documents/document/primary%3AMusic%2FTrack.m4a',
      '/a/song.opus',
    ]) {
      expect(isMusicSource(source), isTrue, reason: source);
    }
    expect(
      isMusicSource('https://example.org/video.mp4?name=audio.mp3'),
      isFalse,
    );
    expect(
      videoDraft('content://provider/42', 'Disc 1/Track.MP3').isAudio,
      isTrue,
    );
    expect(
      videoDraft('content://provider/43', 'Music', audio: true).isAudio,
      isTrue,
    );
    const old = VideoLesson(
      id: 'old',
      itemId: 'item',
      title: 'Old',
      module: '',
      source: 'video.mp4',
      mediaVersion: 'v',
      ordinal: 0,
    );
    expect(
      VideoLesson.fromJson(old.id, old.toJson()..remove('audio')).isAudio,
      isFalse,
    );
    final opaque = VideoLesson.fromJson(old.id, {
      ...old.toJson(),
      'source': 'https://example.org/stream',
      'audio': true,
    });
    expect(VideoLesson.fromJson(opaque.id, opaque.toJson()).isAudio, isTrue);
    expect(PepeSection.video.label, 'Медиа');
  });

  test('mixed folder scan and refresh retain music types, natural order and existing progress', () async {
    final root = await Directory.systemTemp.createTemp('pepehub-media-');
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    for (final name in [
      'Track 10.MP3',
      'Track 2.flac',
      'lesson.mp4',
      '.pepehub/cache.mp3',
      'readme.txt',
    ]) {
      final file = File('${root.path}/$name');
      await file.parent.create(recursive: true);
      await file.writeAsBytes([1, 2, 3]);
    }
    final selected = await scanVideoFolder(root.path);
    expect(selected.sources.map((s) => s.title), [
      'lesson',
      'Track 2',
      'Track 10',
    ]);
    expect(selected.sources.where((s) => s.isAudio), hasLength(2));
    final repo = Repository(db), videos = VideoRepository(Repository(db));
    final item = await videos.addSources(
      title: selected.title,
      sources: selected.sources,
      root: selected.root,
    );
    final own = await videos.lessons(itemId: item.id);
    expect(own.where((l) => l.isAudio), hasLength(2));
    final music = own.last;
    await videos.checkpoint(
      lesson: music,
      durationMs: 120000,
      progress: VideoProgress(
        lessonId: music.id,
        mediaVersion: music.mediaVersion,
        positionMs: 10000,
        speed: 1,
        updatedAt: DateTime.utc(2026, 10, 21),
      ),
      intervals: [],
    );
    await File('${root.path}/Track 11.wav').writeAsBytes([4, 5, 6]);
    await (await previewVideoFolder(
      videos,
      item,
      await scanVideoFolder(root.path),
    )).apply({});
    final refreshed = await videos.lessons(itemId: item.id);
    expect(refreshed, hasLength(4));
    expect(refreshed.last.isAudio, isTrue);
    expect((await videos.progress(music))!.positionMs, 10000);
    expect(await repo.pending(), isEmpty);
    expect(
      await videos.addSources(
        title: 'Repeated',
        sources: [selected.sources.last],
      ),
      isA<VideoItem>(),
    );
    expect(await videos.items(), hasLength(1));
  });

  test('music is automatically audio-only, advances once and records listening in the background', () async {
    final h = Harness();
    await h.open();
    addTearDown(h.close);
    expect(h.player.audioOnly, isTrue);
    expect(h.engine.modes.last, isTrue);
    await h.player.setAudioOnly(false);
    expect(h.player.audioOnly, isTrue);
    await h.player.setForeground(false);
    expect(h.player.state.playing, isTrue);
    h.clock = 1000;
    h.engine.tick(1000);
    h.clock = 2000;
    h.engine.tick(2000);
    await h.player.flush();
    final stats = analyzeVideo(
      VideoAnalysisRequest(await h.videos.intervals()),
    );
    expect(stats.modeTime[VideoActivityMode.audio], 2000);
    expect(stats.modeTime[VideoActivityMode.visual] ?? 0, 0);
    h.engine.tick(120000, playing: false, completed: true);
    await h.player.flush();
    expect(h.player.index, 1);
    expect(h.player.state.playing, isTrue);
    expect(h.player.audioOnly, isTrue);
    h.engine.tick(120000, playing: false, completed: true);
    await h.player.flush();
    expect(h.player.index, 1);
    expect(h.player.state.completed, isTrue);
  });

  test('sleep at end stops a music playlist; mixed queues restore video presentation', () async {
    final h = Harness();
    await h.open();
    try {
      await h.player.setSleepTimer(null, untilLessonEnd: true);
      h.engine.tick(120000, playing: false, completed: true);
      await h.player.flush();
      expect(h.player.index, 0);
      expect(h.player.state.playing, isFalse);
      expect(h.player.sleepAtLessonEnd, isFalse);
    } finally {
      await h.close();
    }
    final mixed = Harness();
    await mixed.open(mixed: true);
    try {
      mixed.engine.tick(120000, playing: false, completed: true);
      await mixed.player.flush();
      expect(mixed.player.index, 0); // Music does not auto-open a video.
      await mixed.player.next();
      expect(mixed.player.audioOnly, isFalse);
      expect(mixed.engine.modes.last, isFalse);
      await mixed.player.setForeground(false);
      expect(mixed.player.state.playing, isFalse);
    } finally {
      await mixed.close();
    }
  });

  test('reopening restores a song while changing tracks starts them from the beginning', () async {
    final h = Harness();
    await h.open();
    try {
      h.engine.tick(42000);
      await h.player.flush();
      await h.player.close();
      h.player.dispose();
      h.player = VideoPlaybackController(
        repository: h.videos,
        engine: MusicEngine(),
        lessons: await h.videos.lessons(),
        checkpointPeriod: null,
      );
      await h.player.load(0);
      expect(h.player.positionMs, 42000);
      await h.player.next();
      expect(h.player.positionMs, 0);
      await h.player.previous();
      expect(h.player.positionMs, 0);
    } finally {
      await h.close();
    }
  });

  for (final width in [360.0, 1280.0]) {
    testWidgets(
      'media library imports and filters music, opens a playlist and fits $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 800);
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
        final videos = VideoRepository(Repository(db));
        await videos.addSources(
          title: 'Existing video',
          sources: [const VideoSourceDraft('film.mp4', 'Film')],
        );
        final session = VideoPlaybackSession(
          videos,
          engineFactory: MusicEngine.new,
        );
        final boundary = GlobalKey();
        Future<void> screenshot(String name) async {
          if (Platform.environment['PEPEHUB_MEDIA_SCREENSHOTS'] != '1') return;
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            image.dispose();
            final file = File('build/media-preview/$name-${width.round()}.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(data!.buffer.asUint8List());
          });
        }

        try {
          await tester.pumpWidget(
            RepaintBoundary(
              key: boundary,
              child: VideoSessionScope(
                session: session,
                child: MaterialApp(
                  debugShowCheckedModeBanner: false,
                  theme: ThemeData(
                    brightness: Brightness.dark,
                    fontFamily: 'Onest',
                  ),
                  home: VideoLibraryPage(
                    repository: videos,
                    navigation: ShelfNavigation(
                      current: PepeSection.video,
                      onSelect: (_) {},
                      onSettings: () {},
                    ),
                    chooseFiles: ({bool folder = false}) async =>
                        const VideoImportSelection('Evening music', [
                          VideoSourceDraft('one.mp3', 'First song'),
                          VideoSourceDraft('two.flac', 'Second song'),
                        ]),
                  ),
                ),
              ),
            ),
          );
          await settle(tester);
          await tester.tap(find.text('Добавить файлы'));
          await tester.pumpAndSettle();
          expect(
            find.text('Проверить музыку и порядок треков'),
            findsOneWidget,
          );
          await tester.tap(find.text('Подключить'));
          await settle(tester);
          await tester.tap(find.text('Добавить ссылку'));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byType(TextFormField).first,
            'Stream without extension',
          );
          await tester.enterText(
            find.byType(TextFormField).last,
            'https://example.org/stream?id=42',
          );
          await tester.tap(find.byType(SwitchListTile));
          await tester.tap(find.text('Добавить'));
          await settle(tester);
          expect(
            (await videos.lessons())
                .singleWhere(
                  (lesson) => lesson.title == 'Stream without extension',
                )
                .isAudio,
            isTrue,
          );
          final musicChip = find.widgetWithText(ChoiceChip, 'Музыка');
          await tester.ensureVisible(musicChip);
          await tester.pumpAndSettle();
          await tester.tap(musicChip);
          await settle(tester);
          expect(find.text('Existing video'), findsNothing);
          expect(find.text('Плейлист · треков: 2'), findsOneWidget);
          await screenshot('library');
          await tester.ensureVisible(find.text('Evening music'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Evening music'));
          await settle(tester);
          expect(find.byType(VideoPlayerPage), findsOneWidget);
          expect(session.controller!.audioOnly, isTrue);
          expect(find.byTooltip('Следующий трек'), findsOneWidget);
          expect(find.byTooltip('Дорожки и субтитры'), findsNothing);
          await tester.tap(find.byTooltip('Следующий трек'));
          await settle(tester);
          expect(session.controller!.index, 1);
          expect(find.text('Second song'), findsWidgets);
          expect(
            session.playbackState.value.controls,
            contains(MediaControl.skipToPrevious),
          );
          await tester.tap(find.byKey(const ValueKey('music-shuffle')));
          await settle(tester);
          expect(session.controller!.shuffleEnabled, isTrue);
          expect(session.controller!.playbackOrder, [1, 0]);
          expect(find.byTooltip('Выключить перемешивание'), findsOneWidget);
          await tester.tap(find.byTooltip('Следующий трек'));
          await settle(tester);
          expect(session.controller!.index, 0);
          await tester.tap(find.byTooltip('Предыдущий трек'));
          await settle(tester);
          expect(session.controller!.index, 1);
          await tester.tap(find.byTooltip('Плейлист и заметки'));
          await settle(tester);
          final order = session.controller!.playbackOrder;
          final firstRow = find.byKey(
            ValueKey(
              'video-lesson-${session.controller!.lessons[order.first].id}',
            ),
          );
          final secondRow = find.byKey(
            ValueKey(
              'video-lesson-${session.controller!.lessons[order.last].id}',
            ),
          );
          expect(
            tester.getTopLeft(firstRow).dy,
            lessThan(tester.getTopLeft(secondRow).dy),
          );
          await tester.tap(secondRow);
          await settle(tester);
          expect(session.controller!.index, 0);
          await tester.tap(find.byTooltip('Закрыть панель музыки'));
          await settle(tester);
          await screenshot('player');
          final position = session.controller!.positionMs;
          await tester.tap(find.byKey(const ValueKey('music-shuffle')));
          await settle(tester);
          expect(session.controller!.shuffleEnabled, isFalse);
          expect(session.controller!.index, 0);
          expect(session.controller!.positionMs, position);
          await tester.tap(find.byTooltip('Инструменты плеера'));
          await tester.pumpAndSettle();
          expect(find.text('Вернуться к видео'), findsNothing);
          expect(find.text('Размер и поворот'), findsNothing);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await settle(tester);
          await session.close();
          session.dispose();
          await db.close();
        }
      },
    );
  }

  final nativeLibrary = Platform.environment['PEPEHUB_TEST_LIBMPV'];
  test(
    'native decoder opens generated PCM music, plays and seeks without video',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'pepehub-music-native-',
      );
      addTearDown(() => root.delete(recursive: true));
      const rate = 16000, samples = rate * 8;
      final bytes = Uint8List(44 + samples * 2);
      // RIFF/WAVE, mono signed PCM16. No external fixture or encoder is required.
      final header = ByteData.sublistView(bytes);
      void ascii(int at, String value) =>
          bytes.setRange(at, at + value.length, value.codeUnits);
      ascii(0, 'RIFF');
      header.setUint32(4, bytes.length - 8, Endian.little);
      ascii(8, 'WAVE');
      ascii(12, 'fmt ');
      header.setUint32(16, 16, Endian.little);
      header.setUint16(20, 1, Endian.little);
      header.setUint16(22, 1, Endian.little);
      header.setUint32(24, rate, Endian.little);
      header.setUint32(28, rate * 2, Endian.little);
      header.setUint16(32, 2, Endian.little);
      header.setUint16(34, 16, Endian.little);
      ascii(36, 'data');
      header.setUint32(40, samples * 2, Endian.little);
      final file = await File('${root.path}/song.wav').writeAsBytes(bytes);
      MediaKit.ensureInitialized(libmpv: nativeLibrary);
      final native = Player(
        configuration: const PlayerConfiguration(vo: 'null', muted: true),
      );
      final engine = NativeVideoEngine(native, attachSurface: false);
      addTearDown(engine.close);
      await (native.platform as NativePlayer).setProperty('ao', 'null');
      final ready = native.stream.duration
          .firstWhere((d) => d.inSeconds == 8)
          .timeout(const Duration(seconds: 10));
      await engine.open(
        VideoLesson(
          id: 'music',
          itemId: 'music',
          title: 'Music',
          module: '',
          source: file.path,
          mediaVersion: 'v1',
          ordinal: 0,
        ),
        positionMs: 0,
        speed: 1,
      );
      await ready;
      await engine.setAudioOnly(true);
      final playing = native.stream.position
          .firstWhere((d) => d.inMilliseconds > 200)
          .timeout(const Duration(seconds: 10));
      await engine.play();
      await playing;
      await engine.pause();
      await engine.seek(2000);
      expect(engine.state.durationMs, 8000);
      expect(engine.state.positionMs, inInclusiveRange(1850, 2150));
      expect(await (native.platform as NativePlayer).getProperty('vid'), 'no');
    },
    skip: !Platform.isWindows || nativeLibrary == null
        ? 'Set PEPEHUB_TEST_LIBMPV to run the native decoder.'
        : false,
  );
}
