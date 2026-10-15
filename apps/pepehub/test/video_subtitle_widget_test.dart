import 'dart:convert';
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
import 'package:pepehub/video/video_player_page.dart';
import 'package:pepehub/video/video_repository.dart';
import 'package:pepehub/vocabulary/vocabulary_repository.dart';
import 'package:pepehub/video/video_subtitle_import.dart';
import 'package:pepehub/video/video_subtitles.dart';
import 'package:pepehub/video/video_transcript_panel.dart';

import 'video_subtitles_test.dart'
    show CaptionTestEngine, CaptionHarness, englishSrt, russianVtt;

Future<void> ready(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(condition(), isTrue);
  await tester.pumpAndSettle();
}

Future<void> expose(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      250,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> transcript(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Уроки, расшифровка и заметки'));
  await ready(
    tester,
    () => find.widgetWithText(Tab, 'Расшифровка').evaluate().isNotEmpty,
  );
  await tester.ensureVisible(find.widgetWithText(Tab, 'Расшифровка'));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(Tab, 'Расшифровка'));
  await tester.pumpAndSettle();
}

class _Fixture {
  final db = AppDatabase(NativeDatabase.memory()), engine = CaptionTestEngine();
  late final videos = VideoRepository(Repository(db));
  late VideoLesson lesson;
  bool closed = false;
  Future<void> open(
    WidgetTester tester, {
    bool seed = true,
    GlobalKey? boundary,
    bool large = false,
    VideoSubtitlePicker? picker,
  }) async {
    addTearDown(() => close(tester));
    final item = await videos.addSources(
      title: 'English B1',
      sources: const [VideoSourceDraft('english.mp4', 'Conversation')],
    );
    lesson = (await videos.lessons(itemId: item.id)).single;
    if (seed) {
      await tester.runAsync(() async {
        final original = await videos.importSubtitles(
          lesson,
          name: 'English.srt',
          text: englishSrt,
          format: VideoSubtitleFormat.srt,
        );
        final translation = await videos.importSubtitles(
          lesson,
          name: 'Russian.vtt',
          text: russianVtt,
          format: VideoSubtitleFormat.vtt,
        );
        await videos.savePlaybackSettings(
          lesson,
          VideoPlaybackSettings(
            subtitle: 'external:${original.id}',
            translation: translation.id,
            subtitleDelayMs: 500,
          ),
        );
      });
    }
    final app = MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.data(Brightness.dark),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(large ? 1.3 : 1)),
        child: child!,
      ),
      home: VideoPlayerPage(
        repository: videos,
        item: item,
        lessons: [lesson],
        engineFactory: () => engine,
        subtitlePicker: picker,
      ),
    );
    await tester.pumpWidget(
      boundary == null ? app : RepaintBoundary(key: boundary, child: app),
    );
    await ready(
      tester,
      () =>
          engine.state.playing &&
          find.byTooltip('Дорожки и субтитры').evaluate().isNotEmpty &&
          tester
                  .widget<IconButton>(
                    find.widgetWithIcon(
                      IconButton,
                      Icons.closed_caption_outlined,
                    ),
                  )
                  .onPressed !=
              null,
    );
    engine.tick(1500);
    await tester.pumpAndSettle();
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
    'track settings validate delays and restore dual captions on a phone',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final f = _Fixture();
      await f.open(tester);
      expect(find.text('Hello & welcome.'), findsOneWidget);
      expect(find.text('Привет!'), findsOneWidget);
      await expose(tester, find.byTooltip('Дорожки и субтитры'));
      await tester.tap(find.byTooltip('Дорожки и субтитры'));
      await ready(
        tester,
        () => find.text('Дорожки и субтитры').evaluate().isNotEmpty,
      );
      await tester.tap(find.byKey(const ValueKey('video-audio-track:auto')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Español · spa').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('video-subtitle-delay')),
        '61',
      );
      await tester.tap(find.text('Применить'));
      await tester.pumpAndSettle();
      expect(find.text('От -60 до 60 секунд'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('video-subtitle-delay')),
        '1.0',
      );
      await tester.tap(find.text('Применить'));
      await ready(
        tester,
        () => find.text('Дорожки и субтитры').evaluate().isEmpty,
      );
      final saved = (await tester.runAsync(
        () => f.videos.playbackSettings(f.lesson),
      ))!;
      expect(saved.audio, '2');
      expect(saved.subtitleDelayMs, 1000);
      expect(f.engine.selectedAudio, '2');
      expect(find.text('Hello & welcome.'), findsNothing);
      expect(find.text('Привет!'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'transcript search jumps with its offset, quotes a phrase, and starts A-B',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final f = _Fixture();
      await f.open(tester);
      await transcript(tester);
      await expose(
        tester,
        find.byKey(const ValueKey('video-transcript-search')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('video-transcript-search')),
        'already',
      );
      await tester.pumpAndSettle();
      await expose(tester, find.text('I had already finished.'));
      await tester.tap(find.text('I had already finished.'));
      await ready(tester, () => f.engine.seeks.isNotEmpty);
      expect(f.engine.seeks.last, 3500);
      await expose(tester, find.byTooltip('Действия с репликой'));
      await tester.tap(find.byTooltip('Действия с репликой'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Заметка с цитатой'));
      await ready(
        tester,
        () => find
            .byKey(const ValueKey('video-annotation-body'))
            .evaluate()
            .isNotEmpty,
      );
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('video-annotation-body')),
            )
            .controller!
            .text,
        'I had already finished.',
      );
      await tester.tap(find.text('Сохранить'));
      await ready(
        tester,
        () => find
            .byKey(const ValueKey('video-annotation-editor'))
            .evaluate()
            .isEmpty,
      );
      final note = (await tester.runAsync(
        () => f.videos.annotations(f.lesson),
      ))!.single;
      expect(note.startMs, 3500);
      expect(note.endMs, 5500);
      expect(note.body, 'I had already finished.');
      await expose(tester, find.byTooltip('Действия с репликой'));
      await tester.tap(find.byTooltip('Действия с репликой'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Карточка Anki'));
      await ready(
        tester,
        () => find
            .byKey(const ValueKey('vocabulary-front'))
            .evaluate()
            .isNotEmpty,
      );
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('vocabulary-front')),
            )
            .controller!
            .text,
        'I had already finished.',
      );
      await tester.enterText(
        find.byKey(const ValueKey('vocabulary-back')),
        'Я уже закончил.',
      );
      await tester.tap(find.text('Сохранить'));
      await ready(
        tester,
        () =>
            find.byKey(const ValueKey('vocabulary-editor')).evaluate().isEmpty,
      );
      final card = (await tester.runAsync(
        () => VocabularyRepository(f.videos.repository).list(),
      ))!.single;
      expect(card.source!.positionMs, 3500);
      expect(card.source!.endMs, 5500);
      expect(card.source!.mediaVersion, f.lesson.mediaVersion);
      expect(card.front, note.body);
      await expose(tester, find.byTooltip('Действия с репликой'));
      await tester.tap(find.byTooltip('Действия с репликой'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Повторить фразу'));
      await ready(
        tester,
        () => find
            .byKey(const ValueKey('video-loop-start'))
            .evaluate()
            .isNotEmpty,
      );
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('video-loop-start')),
            )
            .controller!
            .text,
        '0:03.500',
      );
      expect(
        tester
            .widget<TextFormField>(find.byKey(const ValueKey('video-loop-end')))
            .controller!
            .text,
        '0:05.500',
      );
      await tester.tap(find.text('Начать повтор'));
      await ready(tester, () => f.engine.state.playing);
      expect(f.engine.seeks.last, 3500);
      expect(f.engine.state.playing, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'file import rejects invalid subtitles and succeeds without changing the video source',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var picks = 0;
      final f = _Fixture();
      await f.open(
        tester,
        seed: false,
        picker: () async => VideoSubtitleFile(
          'English.srt',
          Uint8List.fromList(utf8.encode(picks++ == 0 ? 'broken' : englishSrt)),
        ),
      );
      await expose(tester, find.byTooltip('Дорожки и субтитры'));
      await tester.tap(find.byTooltip('Дорожки и субтитры'));
      await ready(
        tester,
        () => find.text('Дорожки и субтитры').evaluate().isNotEmpty,
      );
      Future<void> addFile() async {
        await tester.ensureVisible(
          find.byKey(const ValueKey('video-import-subtitles')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('video-import-subtitles')));
        await ready(
          tester,
          () => find.text('Добавить субтитры').evaluate().isNotEmpty,
        );
        await tester.tap(find.text('Добавить'));
      }

      await addFile();
      await ready(
        tester,
        () => find
            .textContaining('Блок субтитров без временного диапазона')
            .evaluate()
            .isNotEmpty,
      );
      expect(
        await tester.runAsync(() => f.videos.subtitles(f.lesson)),
        isEmpty,
      );
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      await addFile();
      await ready(
        tester,
        () => find.text('Добавить субтитры').evaluate().isEmpty,
      );
      expect(
        await tester.runAsync(() => f.videos.subtitles(f.lesson)),
        hasLength(1),
      );
      await tester.tap(find.text('Применить'));
      await ready(
        tester,
        () => find.text('Дорожки и субтитры').evaluate().isEmpty,
      );
      expect(f.engine.selectedSubtitle, 'no');
      expect(f.lesson.source, 'english.mp4');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'dual captions and transcript render with real fonts at large text',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
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
      for (final layout in {
        'phone': const Size(360, 800),
        'desktop': const Size(1280, 900),
      }.entries) {
        tester.view.physicalSize = layout.value;
        final f = _Fixture(), key = GlobalKey();
        await f.open(tester, boundary: key, large: true);
        await capture(tester, key, 'subtitle-player-${layout.key}');
        await transcript(tester);
        await expose(
          tester,
          find.byKey(const ValueKey('video-transcript-search')),
        );
        await capture(tester, key, 'transcript-${layout.key}');
        expect(tester.takeException(), isNull);
        await f.close(tester);
      }
    },
  );
  testWidgets(
    'native captions leave room for translation and identical text keeps both roles',
    (tester) async {
      final h = CaptionHarness();
      h.engine.nativeSubtitles = true;
      await tester.runAsync(h.prepare);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(h.close);
      });
      final translation = (await tester.runAsync(
        () => h.import('Russian.vtt', russianVtt, translation: true),
      ))!;
      await tester.runAsync(() => h.playback.seek(1500));
      final frameKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                key: frameKey,
                width: 320,
                height: 180,
                child: VideoCaptionOverlay(captions: h.captions),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final original = find.byKey(const ValueKey('video-caption-original'));
      final translated = find.byKey(
        const ValueKey('video-caption-translation'),
      );
      expect(original, findsNothing);
      expect(translated, findsOneWidget);
      expect(
        tester.getCenter(translated).dy,
        lessThan(tester.getTopLeft(find.byKey(frameKey)).dy + 90),
      );
      await tester.runAsync(
        () => h.captions.save(
          VideoPlaybackSettings(
            subtitle: 'external:${translation.id}',
            translation: translation.id,
          ),
        ),
      );
      await tester.pump();
      expect(original, findsOneWidget);
      expect(translated, findsOneWidget);
      expect(
        tester.widget<Text>(original).data,
        tester.widget<Text>(translated).data,
      );
      expect(tester.takeException(), isNull);
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
