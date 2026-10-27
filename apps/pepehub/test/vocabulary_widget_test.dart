import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/media/audio_player_scope.dart';
import 'package:pepehub/ui/audio_page.dart';
import 'package:pepehub/ui/app_theme.dart';
import 'package:pepehub/video/video_annotation_editor.dart';
import 'package:pepehub/video/video_player_page.dart';
import 'package:pepehub/video/video_repository.dart';
import 'package:pepehub/vocabulary/vocabulary_editor.dart';
import 'package:pepehub/vocabulary/vocabulary_page.dart';
import 'package:pepehub/vocabulary/vocabulary_repository.dart';

import 'reader_annotations_bookmarks_test.dart'
    as book
    show reader, select, asset;
import 'reader_improvements_test.dart' show settle;
import 'readme_screenshots_test.dart' show DocumentationPlayer;
import 'support/video_engine.dart';
import 'video_player_tools_widget_test.dart' show ready;

class StudyAudio extends DocumentationPlayer {
  StudyAudio(AssetStore assets, List<LocalAsset> tracks)
    : super(assets, tracks, null);
  int pauses = 0;
  @override
  Future<void> pause() async {
    pauses++;
    notifyListeners();
  }
}

void phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.display.size = const Size(360, 800);
  addTearDown(tester.view.display.resetSize);
  tester.view.devicePixelRatio = 1;
  tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.view.resetViewInsets);
}

Future<void> loadFonts(WidgetTester tester) => tester.runAsync(() async {
  for (final entry in {
    'Onest': 'assets/fonts/Onest.ttf',
    'Oswald': 'assets/fonts/Oswald.ttf',
    'CormorantGaramond': 'assets/fonts/CormorantGaramond.ttf',
    'MaterialIcons': '../../.tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  }.entries) {
    await (FontLoader(entry.key)
          ..addFont(File(entry.value).readAsBytes().then(ByteData.sublistView)))
        .load();
  }
});

void main() {
  testWidgets(
    'audio card captures chapter, file version and time and pauses the same queue',
    (tester) async {
      phone(tester);
      await loadFonts(tester);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = Repository(db),
          assets = AssetStore(Repository(db), Directory('unused-audio-card'));
      final player = StudyAudio(assets, [
        for (var i = 0; i < 2; i++)
          LocalAsset(
            id: 'track$i',
            bookId: 'audio-book',
            filename: '$i.mp3',
            path: 'unused',
            hash: 'hash$i',
            bytes: 1,
          ),
      ]);
      addTearDown(player.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.data(Brightness.dark),
          builder: (context, child) =>
              AudioPlayerScope(controller: player, child: child!),
          home: AudioPage(controller: player),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: 'audio page before creating a card',
      );
      expect(find.byKey(const ValueKey('audio-mini-player')), findsNothing);
      await tester.tap(find.byTooltip('Карточка Anki'));
      await tester.pumpAndSettle();
      expect(player.pauses, 1);
      await tester.enterText(
        find.byKey(const ValueKey('vocabulary-front')),
        'already',
      );
      await tester.enterText(
        find.byKey(const ValueKey('vocabulary-back')),
        'уже',
      );
      await tester.tap(find.text('Сохранить'));
      await ready(
        tester,
        () => find.byType(VocabularyEditor).evaluate().isEmpty,
      );
      final card = (await tester.runAsync(
        () => VocabularyRepository(repo).list(),
      ))!.single;
      expect(card.source!.kind, 'audio');
      expect(card.source!.trackId, 'track1');
      expect(card.source!.mediaVersion, 'hash1');
      expect(card.source!.positionMs, 1104000);
      expect(card.source!.detail, 'Глава 2');
      expect(player.current.id, 'track1');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'compact video card keeps frame visible, preserves input on rotation and freezes source time',
    (tester) async {
      phone(tester);
      await loadFonts(tester);
      final db = AppDatabase(NativeDatabase.memory());
      final repo = Repository(db), videos = VideoRepository(Repository(db));
      final vocabulary = VocabularyRepository(repo), engine = TestVideoEngine();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await ready(tester, () => engine.closed);
        await tester.runAsync(db.close);
      });
      final item = await videos.addSources(
        title: 'English',
        sources: const [VideoSourceDraft('lesson.mp4', 'Already and yet')],
      );
      final lessons = await videos.lessons(itemId: item.id),
          image = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: image,
          child: MaterialApp(
            theme: AppTheme.data(Brightness.dark),
            debugShowCheckedModeBanner: false,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(1.3)),
              child: child!,
            ),
            home: VideoPlayerPage(
              repository: videos,
              item: item,
              lessons: lessons,
              engineFactory: () => engine,
            ),
          ),
        ),
      );
      await ready(tester, () => engine.state.playing);
      engine.tick(65800);
      await tester.pump();
      await tester.tap(find.byTooltip('Быстрая заметка'));
      await ready(
        tester,
        () => find.byType(VideoAnnotationEditor).evaluate().isNotEmpty,
      );
      await tester.enterText(
        find.byKey(const ValueKey('video-annotation-body')),
        'He has already left.',
      );
      await tester.tap(find.byTooltip('Сделать карточку Anki'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('video-annotation-editor')),
        findsNothing,
      );
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('vocabulary-front')),
            )
            .controller!
            .text,
        'He has already left.',
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pumpAndSettle();
      final frame = tester.getRect(
        find.byKey(const ValueKey('video-visible-frame')),
      );
      final editor = tester.getRect(
        find.byKey(const ValueKey('vocabulary-editor')),
      );
      expect(frame.height, greaterThan(150));
      expect(frame.bottom, lessThanOrEqualTo(editor.top));
      expect(editor.bottom, lessThanOrEqualTo(480));
      await tester.enterText(
        find.byKey(const ValueKey('vocabulary-back')),
        'Он уже ушёл.',
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // Leave a reviewable image of the phone layout (the blank lower area is the IME).
      await tester.runAsync(() async {
        final shot =
            await (image.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await shot.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/video-preview/anki-card-phone.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        shot.dispose();
      });
      tester.view.physicalSize = const Size(800, 360);
      tester.view.viewInsets = const FakeViewPadding(bottom: 150);
      await tester.pumpAndSettle();
      final landscapeFrame = tester.getRect(
        find.byKey(const ValueKey('video-visible-frame')),
      );
      final landscapeEditor = tester.getRect(
        find.byKey(const ValueKey('vocabulary-editor')),
      );
      expect(landscapeFrame.right, lessThanOrEqualTo(landscapeEditor.left));
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('vocabulary-back')),
            )
            .controller!
            .text,
        'Он уже ушёл.',
      );
      engine.tick(70000);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await ready(
        tester,
        () => find.byType(VocabularyEditor).evaluate().isEmpty,
      );
      final card = (await tester.runAsync(vocabulary.list))!.single;
      expect(card.source!.positionMs, 65800);
      expect(card.source!.mediaId, lessons.single.id);
      expect(card.source!.mediaVersion, lessons.single.mediaVersion);
      expect(card.kind, VocabularyKind.sentence);
      expect(card.back, 'Он уже ушёл.');
      expect(
        await tester.runAsync(() => videos.annotations(lessons.single)),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await ready(tester, () => engine.closed);
    },
  );

  testWidgets(
    'vocabulary edits and filtered/selected exports preserve cards after save cancellation',
    (tester) async {
      phone(tester);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final vocabulary = VocabularyRepository(Repository(db));
      final first = await vocabulary.save(front: 'already', back: 'уже');
      final second = await vocabulary.save(front: 'not yet', back: 'ещё нет');
      final batches = <List<VocabularyCard>>[];
      await tester.pumpWidget(
        MaterialApp(
          home: VocabularyPage(
            repository: vocabulary,
            export: (cards) async {
              batches.add(cards);
              return false;
            },
          ),
        ),
      );
      await ready(tester, () => find.text('already').evaluate().isNotEmpty);
      await tester.enterText(
        find.byKey(const ValueKey('vocabulary-search')),
        'already',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('vocabulary-export')));
      await tester.pumpAndSettle();
      expect(batches.single.single.id, first.id);
      expect(find.textContaining('Экспортировано карточек'), findsNothing);
      expect((await tester.runAsync(vocabulary.list))!, hasLength(2));
      await tester.enterText(
        find.byKey(const ValueKey('vocabulary-search')),
        '',
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byKey(ValueKey('vocabulary-card-${second.id}')),
          matching: find.byType(Checkbox),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('vocabulary-search')),
        'already',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('vocabulary-export')));
      await tester.pumpAndSettle();
      expect(
        batches.last.single.id,
        second.id,
      ); // selection remains explicit across search.
      await tester.tap(find.byKey(ValueKey('vocabulary-card-${first.id}')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('vocabulary-back')),
        'уже, ранее',
      );
      await tester.tap(find.text('Сохранить'));
      await ready(
        tester,
        () => find.text('СЛОВАРЬ ANKI').evaluate().isNotEmpty,
      );
      final changed = (await tester.runAsync(vocabulary.list))!
          .singleWhere((c) => c.id == first.id);
      expect(changed.back, 'уже, ранее');
      await tester.tap(find.byTooltip('Новая карточка Anki'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('vocabulary-front')),
        'unsaved',
      );
      await tester.tap(find.byTooltip('Закрыть карточку'));
      await tester.pumpAndSettle();
      expect(find.text('Закрыть карточку без сохранения?'), findsOneWidget);
      await tester.tap(find.text('Продолжить писать'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('vocabulary-front')),
            )
            .controller!
            .text,
        'unsaved',
      );
      expect((await tester.runAsync(vocabulary.list))!, hasLength(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'book selection creates an Anki card without adding a reading note',
    (tester) async {
      phone(tester);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = Repository(db);
      await repo.setMeta('reader:appearance', '{"mode":"pages"}');
      await tester.pumpWidget(book.reader(repo));
      await settle(tester);
      await book.select(tester, 0, 4);
      await tester.tap(find.text('Ещё'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Карточка Anki'));
      await tester.pumpAndSettle();
      expect(find.byType(VocabularyEditor), findsOneWidget);
      final front = tester
          .widget<TextFormField>(find.byKey(const ValueKey('vocabulary-front')))
          .controller!
          .text;
      expect(front, isNotEmpty);
      await tester.enterText(
        find.byKey(const ValueKey('vocabulary-back')),
        'sea',
      );
      await tester.tap(find.text('Сохранить'));
      await ready(
        tester,
        () => find.byType(VocabularyEditor).evaluate().isEmpty,
      );
      final saved = (await tester.runAsync(
        () => VocabularyRepository(repo).list(),
      ))!.single;
      expect(saved.source!.kind, 'book');
      expect(saved.source!.mediaId, book.asset.bookId);
      expect(saved.source!.mediaVersion, book.asset.hash);
      expect(saved.front, front);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
