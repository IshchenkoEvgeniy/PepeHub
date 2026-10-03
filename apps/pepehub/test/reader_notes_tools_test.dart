import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/reader/epub.dart';
import 'package:pepehub/reader/text_book.dart';
import 'package:pepehub/reader/reading_library.dart';
import 'package:pepehub/reader/reading_notes_export.dart';
import 'package:pepehub/reader/reading_notes_page.dart';
import 'package:pepehub/reader/reader_layout.dart';
import 'package:pepehub/reader/reader_page.dart';
import 'package:pepehub/reader/reader_viewport.dart';
import 'package:pepehub/reader/reader_resources.dart';
import 'package:pepehub/ui/app_theme.dart';

const pixel =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=';
ReadingNote note({String id = 'n', String book = 'b', String color = 'blue'}) =>
    ReadingNote(
      id: id,
      bookId: book,
      hash: book,
      bookTitle: 'Морские истории',
      chapterTitle: 'Остров',
      quote: 'Слово <script> [ссылка](file:///secret)',
      comment: 'Капитан вернулся в порт.',
      color: color,
      updated: '2026-09-20T12:00:00Z',
      chapter: 0,
      start: 5,
      end: 48,
      tags: ['Сюжет', 'Идея'],
      characters: ['Капитан'],
    );

Uint8List resourceEpub() {
  final archive = Archive();
  for (final e in {
    'mimetype': 'application/epub+zip',
    'META-INF/container.xml': '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>',
    'OPS/book.opf': '<package><metadata><title>Истории</title></metadata><manifest><item id="text" href="text.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="text"/></spine></package>',
    'OPS/text.xhtml': '<html><body><h1>1. Глава</h1><p>Текст <a epub:type="noteref" href="notes.xhtml#n1">[1]</a> дальше.</p><img src="images/p.png" alt="Карта острова"/><img src="https://example.org/p.png"/></body></html>',
    'OPS/notes.xhtml': '<html><body><aside id="n1" epub:type="footnote">Пояснение автора</aside></body></html>',
  }.entries) {
    archive.add(ArchiveFile.bytes(e.key, utf8.encode(e.value)));
  }
  archive.add(ArchiveFile.bytes('OPS/images/p.png', base64Decode(pixel)));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  test(
    'old notes remain readable; labels and combined filters survive storage',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final lib = ReadingLibrary(Repository(db));
      final old = note().toJson()
        ..remove('tags')
        ..remove('characters');
      expect(ReadingNote.fromJson(old).tags, isEmpty);
      expect(normalizeNoteLabels([' Сюжет ', 'сюжет', '', 'Идея']), [
        'Сюжет',
        'Идея',
      ]);
      await lib.saveNote(note());
      await lib.saveNote(note(id: 'other', book: 'other', color: 'pink'));
      final scoped = await lib.notes(bookIds: {'b'});
      expect(scoped, hasLength(1));
      expect(
        filterReadingNotes(
          scoped,
          query: 'КАПИТАН',
          tag: 'сюжет',
          color: 'blue',
          character: 'капитан',
        ),
        hasLength(1),
      );
      expect(filterReadingNotes(scoped, color: 'pink'), isEmpty);
      expect(scoped.single.characters, ['Капитан']);
    },
  );
  test(
    'Markdown export escapes content; JSON retains exact positions and scope',
    () {
      final source = [note(), note(id: 'second', book: 'second')];
      final json = jsonDecode(exportReadingNotes(source, 'json')) as Map;
      expect(json['notes'], hasLength(2));
      expect(json['notes'][0]['start'], 5);
      expect(json['notes'][0]['quote'], source.first.quote);
      expect(json['notes'][0]['tags'], ['Сюжет', 'Идея']);
      final md = exportReadingNotes(source.take(1).toList(), 'md');
      expect(md, contains('&lt;script&gt;'));
      expect(md, contains(r'\[ссылка\]\(file:///secret\)'));
      expect(md, contains('Персонажи: Капитан'));
    },
  );
  test('tap zones roundtrip, clamp and support left-handed controls', () {
    final prefs = ReaderPreferences.fromJson(
      const ReaderPreferences()
          .copy(
            leftTap: 'next',
            rightTap: 'previous',
            centerTap: 'none',
            zoneWidth: .4,
          )
          .toJson(),
    );
    expect(prefs.tapAt(.1), 'next');
    expect(prefs.tapAt(.5), 'none');
    expect(prefs.tapAt(.9), 'previous');
    expect(
      ReaderPreferences.fromJson({'zoneWidth': .9, 'leftTap': 'invalid'})
          .zoneWidth,
      .4,
    );
    expect(ReaderPreferences.fromJson({}).centerTap, 'controls');
  });
  test('EPUB and FB2 keep original offsets while extracting local notes and artwork', () {
    final book = parseEpub(resourceEpub()), chapter = book.chapters.single;
    expect(chapter.paragraphs, ['1. Глава', 'Текст [1] дальше.']);
    final ref = chapter.footnotes.single;
    expect(
      chapter.paragraphs.join('\n\n').substring(ref.start, ref.end),
      '[1]',
    );
    expect(ref.text, 'Пояснение автора');
    expect(chapter.illustrations.single.bytes, base64Decode(pixel));
    expect(bookResourcePath('OPS/text.xhtml', '../../outside'), isNull);
    expect(bookResourcePath('OPS/text.xhtml', 'file:///x'), isNull);
    expect(bookResourcePath('OPS/text.xhtml', '//host/x'), isNull);
    final fb = parseTextBook(
      Uint8List.fromList(
        utf8.encode(
          '<FictionBook xmlns:l="http://www.w3.org/1999/xlink"><body><section><title><p>1. Глава</p></title><p>Текст <a type="note" l:href="#n1">1</a> дальше.</p><image l:href="#image"/></section></body><body name="notes"><section id="n1"><p>Пояснение автора</p></section></body><binary id="image">$pixel</binary></FictionBook>',
        ),
      ),
      'test.fb2',
    );
    final fc = fb.chapters.first, fn = fc.footnotes.single;
    expect(fn.start, fc.paragraphs.join('\n\n').indexOf('1 дальше'));
    expect(fn.text, 'Пояснение автора');
    expect(fc.illustrations.single.bytes, base64Decode(pixel));
  });
  testWidgets('footnote opens from actual text tap, gallery opens zoom view', (
    tester,
  ) async {
    final chapter = parseEpub(resourceEpub()).chapters.single;
    var opened = false;
    var controls = 0, position = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: SizedBox(
              width: 400,
              height: 600,
              child: ReaderViewport(
                text: chapter.paragraphs.join('\n\n'),
                style: const TextStyle(fontSize: 20),
                scaler: TextScaler.noScaling,
                width: 400,
                height: 600,
                margin: 20,
                anchor: 0,
                scrolling: false,
                firstChapter: true,
                lastChapter: true,
                onPosition: (v) => position = v,
                preferences: const ReaderPreferences(mode: 'pages'),
                onToggleControls: () => controls++,
                onChapter: (_) {},
                footnotes: chapter.footnotes,
                onFootnote: (n) {
                  opened = true;
                  showBookFootnote(context, n);
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final editable = tester.state<EditableTextState>(find.byType(EditableText));
    final box = editable.renderEditable
        .getBoxesForSelection(
          TextSelection(
            baseOffset: chapter.footnotes.single.start,
            extentOffset: chapter.footnotes.single.end,
          ),
        )
        .first
        .toRect();
    await tester.tapAt(editable.renderEditable.localToGlobal(box.center));
    await tester.pumpAndSettle();
    expect(opened, isTrue);
    expect(controls, 0);
    expect(find.text('Пояснение автора'), findsOneWidget);
    await tester.tap(find.byTooltip('Закрыть сноску'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(390, 400));
    await tester.pumpAndSettle();
    expect(position, chapter.paragraphs.join('\n\n').length);
    await tester.tapAt(const Offset(200, 400));
    await tester.pumpAndSettle();
    expect(controls, 1);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showChapterResources(context, chapter),
              child: const Text('Материалы'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Материалы'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Карта острова · увеличить'));
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'long quote survives page turns and fullscreen; notes filter and edit on phone',
    (tester) async {
      tester.view.physicalSize = const Size(430, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      late Directory temp;
      late AppDatabase db;
      late Repository repo;
      late LocalAsset asset;
      final sourceText = List.generate(
        80,
        (i) => 'Строка $i: Остров и море. Капитан продолжает путешествие.',
      ).join('\n\n');
      await tester.runAsync(() async {
        temp = await Directory.systemTemp.createTemp('notes-tools-');
        db = AppDatabase(NativeDatabase.memory());
        repo = Repository(db);
        await repo.setMeta('reader:appearance', jsonEncode({'mode': 'pages'}));
        final file = File('${temp.path}/book.txt');
        await file.writeAsString(sourceText);
        asset = await AssetStore(
          repo,
          Directory('${temp.path}/assets'),
        ).importBook(XFile(file.path));
        final font = File('C:/Windows/Fonts/segoeui.ttf');
        if (await font.exists()) {
          await (FontLoader(
            'Roboto',
          )..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
        }
        final icons = File(
          '../../.tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        );
        if (await icons.exists()) {
          await (FontLoader(
            'MaterialIcons',
          )..addFont(icons.readAsBytes().then(ByteData.sublistView))).load();
        }
      });
      Future<void> settle() async {
        for (var i = 0; i < 8; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
      }

      Future<void> select(int start, int end) async {
        final target = find.byType(SelectableText).hitTestable().first;
        await tester.longPress(target);
        await tester.pumpAndSettle();
        final field = find.descendant(
          of: target,
          matching: find.byType(EditableText),
        );
        final editable = tester.state<EditableTextState>(field);
        editable.userUpdateTextEditingValue(
          editable.textEditingValue.copyWith(
            selection: TextSelection(baseOffset: start, extentOffset: end),
          ),
          SelectionChangedCause.longPress,
        );
        await tester.pump();
        editable.showToolbar();
        await tester.pumpAndSettle();
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            home: ReaderPage(repository: repo, asset: asset),
          ),
        );
        await settle();
        await tester.tap(find.byTooltip('Полный экран'));
        await settle();
        expect(find.byType(AppBar), findsNothing);
        await tester.tap(find.byTooltip('Выйти из полного экрана'));
        await settle();
        await select(0, 6);
        expect(find.text('Начать длинную цитату'), findsNothing);
        await tester.tap(find.text('Ещё'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Начать длинную цитату'));
        await settle();
        await tester.tap(find.byTooltip('Следующая страница'));
        await settle();
        await select(0, 12);
        await tester.tap(find.text('Ещё'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Закончить здесь'));
        await tester.pumpAndSettle();
        for (final label in ['Комментарий', 'Теги', 'Персонажи']) {
          final field = find.widgetWithText(TextField, label);
          await tester.ensureVisible(field);
          await tester.tap(field);
          await tester.showKeyboard(field);
          tester.view.viewInsets = const FakeViewPadding(bottom: 300);
          await tester.pumpAndSettle();
          final editable = tester.state<EditableTextState>(
            find.descendant(of: field, matching: find.byType(EditableText)),
          );
          expect(
            editable.widget.focusNode.hasFocus,
            true,
            reason: 'Keyboard must not move focus away from $label',
          );
          await tester.enterText(field, 'Проверка ввода');
          await tester.pump();
          expect(editable.widget.controller.text, 'Проверка ввода');
          tester.view.viewInsets = const FakeViewPadding();
          await tester.pumpAndSettle();
        }
        await tester.enterText(
          find.widgetWithText(TextField, 'Теги'),
          'Сюжет, сюжет, Море',
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Персонажи'),
          'Капитан',
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Комментарий'),
          'Возвращение',
        );
        await tester.tap(find.text('Сохранить'));
        await settle();
        final saved = (await tester.runAsync(
          () => ReadingLibrary(repo).notes(hash: asset.hash),
        ))!.single;
        expect(saved.start, 0);
        expect(saved.end, greaterThan(100));
        expect(saved.quote, sourceText.substring(saved.start, saved.end));
        expect(saved.tags, ['Сюжет', 'Море']);
        expect(saved.characters, ['Капитан']);
        await tester.tap(find.byTooltip('Заметки книги'));
        await settle();
        await tester.tap(find.byTooltip('Фильтр по цвету'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Синий'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Действия с заметкой'), findsNothing);
        await tester.tap(find.byTooltip('Фильтр по цвету'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Все цвета'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'капитан');
        await tester.pumpAndSettle();
        expect(find.byTooltip('Действия с заметкой'), findsOneWidget);
        await tester.tap(find.byTooltip('Действия с заметкой'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Изменить'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Персонажи'),
          'Капитан, Анна',
        );
        await tester.tap(find.text('Сохранить'));
        await settle();
        expect(
          (await tester.runAsync(
            () => ReadingLibrary(repo).notes(hash: asset.hash),
          ))!.single.characters,
          ['Капитан', 'Анна'],
        );
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(const SizedBox());
        await settle();
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.data(Brightness.dark),
            home: RepaintBoundary(
              key: boundaryKey,
              child: ReadingNotesPage(repository: repo, hash: asset.hash),
            ),
          ),
        );
        await settle();
        await tester.runAsync(() async {
          final image =
              await (boundaryKey.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          await File('build/reading-notes-tools.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
        });
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await settle();
        await tester.runAsync(() async {
          await db.close();
          await temp.delete(recursive: true);
        });
      }
    },
  );
}
