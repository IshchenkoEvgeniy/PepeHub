import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';

import 'package:flutter/material.dart';
import 'package:pepehub/reader/reader_selectable_paragraph.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/reader/text_book.dart';
import 'package:pepehub/reader/reader_layout.dart';
import 'package:pepehub/reader/reader_viewport.dart';

import 'epub_test.dart' show fixture;

import 'package:pepehub/reader/epub.dart';

void main() {
  test('reader defaults to seamless flow without a scrollbar', () {
    const preferences = ReaderPreferences();
    expect(preferences.mode, 'seamless');
    expect(preferences.showScrollbar, isFalse);
    expect(ReaderPreferences.fromJson(const {}).mode, 'seamless');
    expect(ReaderPreferences.fromJson({'mode': 'compact'}).mode, 'compact');
    final adjusted = ReaderPreferences.fromJson({
      'size': 48,
      'pageHeightFactor': 1.3,
    });
    expect(adjusted.size, 48);
    expect(adjusted.pageHeightFactor, 1.3);
    expect(ReaderPreferences.fromJson(adjusted.toJson()).pageHeightFactor, 1.3);
    expect(ReaderPreferences.fromJson({'size': 100}).size, 56);
  });

  testWidgets('continuous flow separates screen pages within one chapter', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => Material(child: child!),
        home: SizedBox(
          width: 360,
          height: 520,
          child: ReaderViewport(
            text: List.filled(
              30,
              'A long paragraph fills the screen. ' * 10,
            ).join('\n\n'),
            style: const TextStyle(fontSize: 18, height: 1.4),
            scaler: TextScaler.noScaling,
            width: 360,
            height: 520,
            margin: 20,
            anchor: 0,
            scrolling: true,
            firstChapter: true,
            lastChapter: true,
            onPosition: (_) {},
            onChapter: (_) {},
          ),
        ),
      ),
    );
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.byType(Divider), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact flow opens deep in a book with visible text', (
    tester,
  ) async {
    final text = List.generate(
      240,
      (i) => 'Paragraph $i. ${'Readable text fills this paragraph. ' * 5}',
    ).join('\n\n');
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => Material(child: child!),
        home: SizedBox(
          width: 360,
          height: 520,
          child: ReaderViewport(
            text: text,
            style: const TextStyle(fontSize: 18, height: 1.4),
            scaler: TextScaler.noScaling,
            width: 360,
            height: 520,
            margin: 20,
            anchor: text.indexOf('Paragraph 170.'),
            scrolling: true,
            compactFlow: true,
            firstChapter: true,
            lastChapter: true,
            onPosition: (_) {},
            onChapter: (_) {},
          ),
        ),
      ),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    final visibleText = tester
        .widgetList<ReaderSelectableParagraph>(
          find.byType(ReaderSelectableParagraph),
        )
        .map((widget) => widget.span.toPlainText())
        .join();
    expect(visibleText, contains('Paragraph 170.'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('page turns open deep in a book with visible text', (
    tester,
  ) async {
    final text = List.generate(
      240,
      (i) => 'Paragraph $i. ${'Readable text fills this paragraph. ' * 5}',
    ).join('\n\n');
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => Material(child: child!),
        home: SizedBox(
          width: 360,
          height: 520,
          child: ReaderViewport(
            text: text,
            style: const TextStyle(fontSize: 18, height: 1.4),
            scaler: TextScaler.noScaling,
            width: 360,
            height: 520,
            margin: 20,
            anchor: text.indexOf('Paragraph 170.'),
            scrolling: false,
            firstChapter: true,
            lastChapter: true,
            onPosition: (_) {},
            onChapter: (_) {},
          ),
        ),
      ),
    );
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    final visibleText = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .map((widget) => widget.textSpan?.toPlainText() ?? widget.data ?? '')
        .join();
    expect(visibleText, contains('Paragraph 170.'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('code blocks fit in continuous, compact and paged layouts', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final introduction = 'An introduction to the example. ' * 12;
    final code = List.filled(
      12,
      '    <section epub:type="chapter">',
    ).join('\n');
    final text = '$introduction\n\n$code\n\nThe explanation continues.';
    final codeStart = introduction.length + 2;
    for (final mode in ['seamless', 'compact', 'pages']) {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => Material(child: child!),
          home: ReaderViewport(
            key: ValueKey(mode),
            text: text,
            markup: [
              BookMarkup(
                codeStart,
                codeStart + code.length,
                block: 'pre',
                code: true,
              ),
            ],
            style: const TextStyle(
              inherit: false,
              fontSize: 22,
              height: 1.35,
              textBaseline: TextBaseline.alphabetic,
            ),
            scaler: TextScaler.noScaling,
            width: 390,
            height: 740,
            margin: 24,
            anchor: codeStart + code.length ~/ 2,
            scrolling: mode != 'pages',
            compactFlow: mode == 'compact',
            firstChapter: true,
            lastChapter: true,
            onPosition: (_) {},
            onChapter: (_) {},
          ),
        ),
      );
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(
        find.byType(
          mode == 'pages' ? SelectableText : ReaderSelectableParagraph,
        ),
        findsWidgets,
        reason: mode,
      );
      expect(tester.takeException(), isNull, reason: mode);
    }
  });

  testWidgets('chapter divider is inline and scrollbar is optional', (
    tester,
  ) async {
    Future<void> render({required bool scrollbar}) async {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => Material(child: child!),
          home: SizedBox(
            width: 360,
            height: 640,
            child: ReaderViewport(
              text: 'Первая глава\n\nВторая глава',
              style: const TextStyle(fontSize: 20),
              scaler: TextScaler.noScaling,
              width: 360,
              height: 640,
              margin: 20,
              anchor: 0,
              scrolling: true,
              firstChapter: true,
              lastChapter: true,
              chapterBreaks: const [14],
              showScrollbar: scrollbar,
              onPosition: (_) {},
              onChapter: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await render(scrollbar: false);
    expect(find.byType(Divider), findsOneWidget);
    expect(find.byType(Scrollbar), findsNothing);
    await render(scrollbar: true);
    expect(find.byType(Scrollbar), findsOneWidget);
  });

  testWidgets('only linked words receive link color and underline', (
    tester,
  ) async {
    const text = 'Ссылка и обычный текст без выделения.';
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => Material(child: child!),
        home: SizedBox(
          width: 360,
          height: 640,
          child: ReaderViewport(
            text: text,
            markup: const [BookMarkup(0, 6, href: '#target')],
            style: const TextStyle(fontSize: 20, color: Color(0xff333333)),
            scaler: TextScaler.noScaling,
            width: 360,
            height: 640,
            margin: 20,
            anchor: 0,
            scrolling: true,
            firstChapter: true,
            lastChapter: true,
            onPosition: (_) {},
            onChapter: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final selectable = tester.widget<ReaderSelectableParagraph>(
      find.byType(ReaderSelectableParagraph).first,
    );
    final runs = selectable.span.children!.cast<TextSpan>();
    final linked = runs.firstWhere((run) => run.text == 'Ссылка');
    final regular = runs.firstWhere((run) => run.text!.contains('обычный'));
    expect(linked.style?.decoration, TextDecoration.underline);
    expect(regular.style?.decoration, isNull);
  });

  testWidgets(
    'continuous pages have dividers and compact flow keeps chapter boundary',
    (tester) async {
      final firstChapter = List.filled(
        18,
        'The first chapter has enough words to span several screen pages. ' * 5,
      ).join('\n\n');
      final secondChapter = 'The next chapter starts here.';
      final text = '$firstChapter\n\n$secondChapter';
      Future<void> render({required bool compact}) async {
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => Material(child: child!),
            home: SizedBox(
              width: 360,
              height: 520,
              child: ReaderViewport(
                key: ValueKey(compact),
                text: text,
                style: const TextStyle(fontSize: 18, height: 1.4),
                scaler: TextScaler.noScaling,
                width: 360,
                height: 520,
                margin: 20,
                anchor: compact ? firstChapter.length - 40 : 0,
                scrolling: true,
                compactFlow: compact,
                chapterBreaks: [firstChapter.length + 2],
                firstChapter: true,
                lastChapter: true,
                onPosition: (_) {},
                onChapter: (_) {},
              ),
            ),
          ),
        );
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 20));
        }
      }

      await render(compact: false);
      expect(find.byType(Divider), findsWidgets);
      expect(find.byType(Slider), findsNothing);
      expect(tester.takeException(), isNull);

      await render(compact: true);
      expect(find.byType(Divider), findsOneWidget);
      expect(find.byType(Slider), findsNothing);
      final list = find.byType(ListView);
      final fixedScreenRows = tester
          .widgetList<SizedBox>(
            find.descendant(of: list, matching: find.byType(SizedBox)),
          )
          .where((box) => box.height == 472)
          .length;
      expect(fixedScreenRows, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('rich page keeps typography and produces a visual preview', (
    tester,
  ) async {
    final source =
        '<h1>Чтение с оформлением</h1><p>Теперь книга сохраняет <b>выделение</b>, <i>курсив</i> и <a href="#code">ссылки</a>.</p><h2>Содержание</h2><ol><li>Иллюстрации внутри книги</li><li>Переходы между главами</li></ol><blockquote>Заметки остаются привязаны к тексту.</blockquote><h2 id="code">Пример кода</h2><pre>book.open();\n  reader.scroll();</pre>';
    final chapter = parseTextBook(
      Uint8List.fromList(utf8.encode(source)),
      'preview.html',
    ).chapters.single;
    await tester.runAsync(() async {
      for (final font in {
        'ReaderLora': 'assets/fonts/Lora.ttf',
        'Roboto': 'C:/Windows/Fonts/segoeui.ttf',
        'monospace': 'C:/Windows/Fonts/consola.ttf',
      }.entries) {
        final file = File(font.value);
        if (await file.exists()) {
          await (FontLoader(
            font.key,
          )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
        }
      }
    });
    tester.view.physicalSize = const Size(430, 880);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => Material(child: child!),
        home: RepaintBoundary(
          key: key,
          child: Scaffold(
            backgroundColor: const Color(0xfff3e8d0),
            body: ReaderViewport(
              text: chapter.paragraphs.join('\n\n'),
              markup: chapter.markup,
              style: const TextStyle(
                fontFamily: 'ReaderLora',
                fontSize: 20,
                height: 1.35,
                color: Color(0xff514531),
              ),
              scaler: TextScaler.noScaling,
              width: 430,
              height: 880,
              margin: 28,
              anchor: 0,
              scrolling: true,
              firstChapter: true,
              lastChapter: true,
              onPosition: (_) {},
              onChapter: (_) {},
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(find.text('1.'), findsOneWidget);
    expect(find.text('2.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final image =
          await (key.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/source-check/reader-rich-preview.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  });
  test('EPUB preserves headings, navigation, emphasis and code positions', () {
    final book = parseEpub(
      fixture(
        overrides: {
          'OPS/first.xhtml': '<html><body><h1 id="intro">Title</h1><nav><ol><li><a href="second.xhtml">Next</a></li></ol></nav><p>Some <b>bold</b> and <i>italic</i>.</p><pre>line one\n  line two</pre></body></html>',
        },
      ),
    );
    final chapter = book.chapters.first;
    final text = chapter.paragraphs.join('\n\n');
    expect(text, contains('Next'));
    expect(text, contains('line one\n  line two'));
    expect(
      chapter.markup.any((r) => r.heading == 1 && r.anchor == 'intro'),
      true,
    );
    expect(
      chapter.markup.any(
        (r) => r.bold && text.substring(r.start, r.end) == 'bold',
      ),
      true,
    );
    expect(chapter.markup.any((r) => r.href == 'second.xhtml'), true);
    expect(chapter.markup.any((r) => r.marker == '1.'), true);
  });
  test('HTML Markdown FB2 and RTF retain authored formatting', () {
    for (final source in <String, String>{
      'book.html': '<h1>Title</h1><p>A <strong>bold</strong> word.</p>',
      'book.md': '# Title\n\nA **bold** word.',
      'book.fb2': '<FictionBook><body><section><title><p>Title</p></title><p>A <strong>bold</strong> word.</p></section></body></FictionBook>',
      'book.rtf': r'{\rtf1 A {\b bold} word.}',
    }.entries) {
      final book = parseTextBook(
        Uint8List.fromList(utf8.encode(source.value)),
        source.key,
      );
      final chapter = book.chapters.first,
          text = book.chapters.first.paragraphs.join('\n\n');
      expect(
        chapter.markup.any(
          (r) => r.bold && text.substring(r.start, r.end) == 'bold',
        ),
        true,
        reason: source.key,
      );
    }
  });

  test('HTML reader separates table cells and definition-list blocks', () {
    const source =
        '<table><tr><th>Column A</th><th>Column B</th></tr><tr><td>First</td><td>Second</td></tr></table><dl><dt>Term</dt><dd>Definition</dd></dl><aside class="note"><p>Callout text.</p></aside>';
    final chapter = parseTextBook(
      Uint8List.fromList(utf8.encode(source)),
      'blocks.html',
    ).chapters.single;
    expect(chapter.paragraphs, [
      'Column A │ Column B',
      'First │ Second',
      'Term',
      'Definition',
      'Callout text.',
    ]);
    expect(
      chapter.markup.any(
        (range) =>
            range.block == 'aside' &&
            chapter.paragraphs.join('\n\n').substring(range.start, range.end) ==
                'Callout text.',
      ),
      isTrue,
    );
  });
  testWidgets(
    'scrolling has no next-page row and crosses chapters by gesture',
    (tester) async {
      var chapterChanges = 0;
      final text = List.filled(
        20,
        'A paragraph of text to scroll through.',
      ).join('\n\n');
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => Material(child: child!),
          home: Scaffold(
            body: SizedBox(
              width: 390,
              height: 650,
              child: ReaderViewport(
                text: text,
                style: const TextStyle(fontSize: 22, height: 1.35),
                scaler: TextScaler.noScaling,
                width: 390,
                height: 650,
                margin: 24,
                anchor: 0,
                scrolling: true,
                firstChapter: true,
                lastChapter: false,
                onPosition: (_) {},
                onChapter: (delta) => chapterChanges += delta,
              ),
            ),
          ),
        ),
      );
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }
      expect(find.byTooltip('Следующая страница'), findsNothing);
      final list = find.byType(ListView);
      for (var i = 0; i < 10 && chapterChanges == 0; i++) {
        await tester.drag(list, const Offset(0, -550));
        await tester.pumpAndSettle();
      }
      expect(chapterChanges, 1);
      expect(tester.takeException(), isNull);
      expect(const ReaderPreferences().mode, 'seamless');
    },
  );
}
