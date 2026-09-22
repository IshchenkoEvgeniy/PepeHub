import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/reader/text_book.dart';
import 'package:pepehub/reader/reader_layout.dart';
import 'package:pepehub/reader/reader_viewport.dart';

import 'epub_test.dart' show fixture;

import 'package:pepehub/reader/epub.dart';

void main() {
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
        if (await file.exists())
          await (FontLoader(
            font.key,
          )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
      }
    });
    tester.view.physicalSize = const Size(430, 880);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
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
      expect(const ReaderPreferences().mode, 'scroll');
    },
  );
}
