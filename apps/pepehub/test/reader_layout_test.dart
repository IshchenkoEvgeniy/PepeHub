import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/reader/reader_layout.dart';
import 'package:pepehub/reader/epub.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('page slices cover original text exactly and fit at different settings', () async {
    final text = List.generate(
      90,
      (i) =>
          '$i. Книга и море 🌊 — длинная строка с разными словами. ${'Продолжение рассказа. ' * 8}',
    ).join('\n\n');
    for (final config in [(18.0, 1.0), (30.0, 1.0), (18.0, 1.7)]) {
      final (size, scale) = config;
      final scaler = TextScaler.linear(scale);
      final style = TextStyle(fontSize: size, height: 1.6);
      final pages = await paginateReader(text, style, 260, 480, scaler);
      expect(pages.length, greaterThan(2));
      expect(pages.map((p) => text.substring(p.start, p.end)).join(), text);
      for (final page in pages) {
        final painter = TextPainter(
          text: TextSpan(
            text: text.substring(page.start, page.end).trimRight(),
            style: style,
          ),
          textDirection: TextDirection.ltr,
          textScaler: scaler,
        )..layout(maxWidth: 260);
        expect(
          painter.height,
          lessThanOrEqualTo(480),
          reason: 'Page ${page.start}..${page.end}',
        );
        painter.dispose();
        expect(
          page.end,
          text.length == page.end ? text.length : greaterThan(page.start),
        );
        if (page.end < text.length) {
          expect(
            text.codeUnitAt(page.end) < 0xDC00 ||
                text.codeUnitAt(page.end) > 0xDFFF,
            isTrue,
          );
        }
      }
    }
  });
  test('legacy paragraph anchors, chapter boundaries and literal search', () {
    final doc = ReaderDocument(
      const EpubBook('Test', [], [
        EpubChapter('a', 'A', ['Первая строка', 'Вторая строка']),
        EpubChapter('b', 'B', ['Финал [тест]']),
      ]),
    );
    final at = doc.offset(0, 1, 3);
    expect(doc.paragraphAt(0, at), (paragraph: 1, within: 3));
    expect(doc.locate(1), (chapter: 1, offset: 12));
    final hits = searchReader({'query': '[ТЕСТ]', 'texts': doc.texts});
    expect(hits.single['chapter'], 1);
    expect(
      doc.texts[1].substring(
        hits.single['offset'] as int,
        hits.single['end'] as int,
      ),
      '[тест]',
    );
    expect(
      searchReader({
        'query': 'a',
        'texts': ['a ' * 500],
      }),
      hasLength(200),
    );
  });
}
