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
import 'package:pepehub/video/video_annotation_editor.dart';
import 'package:pepehub/video/video_annotations.dart';
import 'package:pepehub/video/video_player_page.dart';
import 'package:pepehub/video/video_repository.dart';

import 'support/video_engine.dart';
import 'video_player_tools_widget_test.dart' show ready;

class _Engine extends TestVideoEngine {
  int opens = 0;
  @override
  Future<void> open(
    VideoLesson lesson, {
    required int positionMs,
    required double speed,
  }) async {
    opens++;
    await super.open(lesson, positionMs: positionMs, speed: speed);
  }
}

class _Fixture {
  bool _closed = false;
  final db = AppDatabase(NativeDatabase.memory()),
      engine = _Engine(),
      image = GlobalKey();
  late final videos = VideoRepository(Repository(db));
  late VideoLesson lesson;
  Future<void> open(WidgetTester tester) async {
    final item = await videos.addSources(
      title: 'English course',
      sources: const [VideoSourceDraft('english.mp4', 'Already and yet')],
    );
    lesson = (await videos.lessons(itemId: item.id)).single;
    await tester.pumpWidget(
      RepaintBoundary(
        key: image,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.data(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.3)),
            child: child!,
          ),
          home: VideoPlayerPage(
            repository: videos,
            item: item,
            lessons: [lesson],
            engineFactory: () => engine,
          ),
        ),
      ),
    );
    addTearDown(() => close(tester));
    await ready(tester, () => engine.state.playing);
    engine.tick(65800);
    await tester.pump();
  }

  Future<void> close(WidgetTester tester) async {
    if (_closed) return;
    _closed = true;
    await tester.pumpWidget(const SizedBox());
    await ready(tester, () => engine.closed);
    await tester.runAsync(db.close);
  }

  Future<void> note(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Быстрая заметка'));
    await ready(
      tester,
      () => find.byType(VideoAnnotationEditor).evaluate().isNotEmpty,
    );
  }

  Future<VideoAnnotation> saved(WidgetTester tester) async =>
      (await tester.runAsync(() => videos.annotations(lesson)))!.single;
}

void setupView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.view.resetViewInsets);
}

Future<void> save(WidgetTester tester) async {
  await tester.tap(find.text('Сохранить'));
  await ready(
    tester,
    () => find.byType(VideoAnnotationEditor).evaluate().isEmpty,
  );
}

void main() {
  testWidgets(
    'quick note keeps the frame and one focused field above a phone keyboard; metadata is automatic',
    (tester) async {
      setupView(tester, const Size(360, 800));
      final f = _Fixture();
      await f.open(tester);
      await f.note(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(TextFormField), findsOneWidget);
      expect(
        find.byKey(const ValueKey('video-annotation-title')),
        findsNothing,
      );
      final body = find.byKey(const ValueKey('video-annotation-body'));
      expect(
        tester
            .widget<EditableText>(
              find.descendant(of: body, matching: find.byType(EditableText)),
            )
            .focusNode
            .hasFocus,
        isTrue,
      );
      final frame = tester.getRect(
            find.byKey(const ValueKey('video-visible-frame')),
          ),
          editor = tester.getRect(
            find.byKey(const ValueKey('video-annotation-editor')),
          );
      expect(frame.height, greaterThan(180));
      expect(frame.bottom, lessThanOrEqualTo(editor.top));
      expect(tester.getRect(body).bottom, lessThanOrEqualTo(480));
      expect(tester.getCenter(find.text('Сохранить')).dy, lessThan(480));
      expect(f.engine.state.playing, isFalse);
      await tester.enterText(
        body,
        'He has already left.\nPresent perfect: уже ушёл.',
      );
      // Saving uses the action's captured time, not a later decoder callback.
      f.engine.tick(66500);
      await save(tester);
      final note = await f.saved(tester);
      expect(note.title, 'He has already left.');
      expect(note.body, 'He has already left.\nPresent perfect: уже ушёл.');
      expect(note.startMs, 65800);
      expect(note.endMs, isNull);
      expect(note.lessonId, f.lesson.id);
      expect(note.mediaVersion, f.lesson.mediaVersion);
      expect(f.engine.opens, 1);
      expect(f.engine.state.playing, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rotation preserves typed text and the decoder; landscape places the editor beside the frame',
    (tester) async {
      setupView(tester, const Size(360, 800));
      final f = _Fixture();
      await f.open(tester);
      await f.note(tester);
      final body = find.byKey(const ValueKey('video-annotation-body'));
      await tester.enterText(body, 'I have not finished yet.');
      tester.view.physicalSize = const Size(800, 360);
      tester.view.viewInsets = const FakeViewPadding(bottom: 150);
      await tester.pumpAndSettle();
      final frame = tester.getRect(
            find.byKey(const ValueKey('video-visible-frame')),
          ),
          editor = tester.getRect(
            find.byKey(const ValueKey('video-annotation-editor')),
          );
      expect(frame.width, greaterThan(400));
      expect(frame.right, lessThanOrEqualTo(editor.left));
      expect(editor.bottom, lessThanOrEqualTo(210));
      expect(
        tester.widget<TextFormField>(body).controller!.text,
        'I have not finished yet.',
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await ready(
        tester,
        () => find.byType(VideoAnnotationEditor).evaluate().isEmpty,
      );
      expect((await f.saved(tester)).body, 'I have not finished yet.');
      expect(f.engine.opens, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an empty quick note remains a bookmark; closing a typed draft asks before discarding',
    (tester) async {
      setupView(tester, const Size(360, 800));
      final f = _Fixture();
      await f.open(tester);
      await f.note(tester);
      await save(tester);
      final bookmark = await f.saved(tester);
      expect(bookmark.title, 'Фрагмент 1:05');
      expect(bookmark.body, isEmpty);
      await f.note(tester);
      await tester.enterText(
        find.byKey(const ValueKey('video-annotation-body')),
        'Do not lose this phrase',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Закрыть без сохранения?'), findsOneWidget);
      await tester.tap(find.text('Продолжить писать'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('video-annotation-body')),
            )
            .controller!
            .text,
        'Do not lose this phrase',
      );
      await tester.tap(find.byTooltip('Отменить заметку'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Не сохранять'));
      await tester.pumpAndSettle();
      expect(find.byType(VideoAnnotationEditor), findsNothing);
      expect((await f.saved(tester)).id, bookmark.id);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a failed concurrent edit keeps the draft and original metadata available for correction',
    (tester) async {
      setupView(tester, const Size(360, 800));
      final db = AppDatabase(NativeDatabase.memory()),
          videos = VideoRepository(Repository(db));
      addTearDown(db.close);
      final item = await videos.addSources(
        title: 'Course',
        sources: const [VideoSourceDraft('one.mp4', 'One')],
      );
      final lesson = (await videos.lessons(itemId: item.id)).single;
      final note = await videos.saveAnnotation(
        lesson,
        title: 'My manual title',
        body: 'Original',
        startMs: 1000,
        endMs: 2000,
        durationMs: 120000,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 260,
              child: VideoAnnotationEditor(
                repository: videos,
                draft: VideoAnnotationDraft(
                  lesson: lesson,
                  positionMs: 45000,
                  durationMs: 120000,
                  existing: note,
                ),
                onSaved: (_) =>
                    fail('A stale edit must not overwrite the newer note'),
                onCancel: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('video-annotation-body')),
        'Keep my unsaved correction',
      );
      await tester.runAsync(
        () => videos.saveAnnotation(
          lesson,
          existing: note,
          title: 'Newer title',
          body: 'Newer content',
          startMs: 1000,
          endMs: 2000,
          durationMs: 120000,
        ),
      );
      await tester.tap(find.text('Сохранить'));
      await ready(
        tester,
        () => find
            .textContaining('Заметка изменилась или уже удалена')
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
        'Keep my unsaved correction',
      );
      await tester.tap(find.byTooltip('Параметры заметки'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('video-annotation-title')),
            )
            .controller!
            .text,
        'My manual title',
      );
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('video-annotation-start')),
            )
            .controller!
            .text,
        '0:01.000',
      );
      expect(
        (await tester.runAsync(() => videos.annotations(lesson)))!.single.body,
        'Newer content',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'quick note layouts render with real fonts, large text and keyboard space on phone, landscape and desktop',
    (tester) async {
      setupView(tester, const Size(360, 800));
      await tester.runAsync(() async {
        for (final entry in {
          'Onest': 'assets/fonts/Onest.ttf',
          'MaterialIcons': '../../.tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        }.entries) {
          await (FontLoader(entry.key)..addFont(
                File(entry.value).readAsBytes().then(ByteData.sublistView),
              ))
              .load();
        }
      });
      for (final layout in {
        'phone': (const Size(360, 800), 320.0),
        'landscape': (const Size(800, 360), 150.0),
        'desktop': (const Size(1280, 900), 0.0),
      }.entries) {
        tester.view.physicalSize = layout.value.$1;
        tester.view.viewInsets = FakeViewPadding(bottom: layout.value.$2);
        final f = _Fixture();
        await f.open(tester);
        await f.note(tester);
        await tester.enterText(
          find.byKey(const ValueKey('video-annotation-body')),
          'I have already finished my work.\nЯ уже закончил свою работу.',
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final image =
              await (f.image.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          final file = File('build/video-preview/quick-note-${layout.key}.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(data!.buffer.asUint8List());
        });
        await f.close(tester);
      }
    },
  );
}
