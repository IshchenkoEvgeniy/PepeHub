import 'dart:convert';
import 'dart:math';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/reader/epub.dart';
import 'package:pepehub/reader/reader_layout.dart';
import 'package:pepehub/reader/reader_page.dart';
import 'package:pepehub/reader/reader_viewport.dart';

import 'reader_improvements_test.dart' show settle, size;
import 'support/reader_controls.dart';

void main() {
  test('collapseBookWhitespace equals the \\s+ regular expression exactly', () {
    final pattern = RegExp(r'\s+');
    for (var c = 0; c < 0x10000; c++) {
      final value = 'a${String.fromCharCode(c)}${String.fromCharCode(c)}b';
      expect(
        collapseBookWhitespace(value),
        value.replaceAll(pattern, ' '),
        reason: 'U+${c.toRadixString(16)}',
      );
    }
    final random = Random(3);
    const alphabet = [
      'a', 'Я', ' ', '  ', '\t', '\n', '\r', ' ', '\u0085', '᠎', //
      ' ', ' ', '　', '﻿', '​', '🌊', '\ud83c',
    ];
    for (var i = 0; i < 5000; i++) {
      final value = [
        for (var j = random.nextInt(24); j > 0; j--)
          alphabet[random.nextInt(alphabet.length)],
      ].join();
      expect(collapseBookWhitespace(value), value.replaceAll(pattern, ' '));
    }
    const unchanged = 'Обычный текст с одиночными пробелами.';
    expect(identical(collapseBookWhitespace(unchanged), unchanged), isTrue);
  });

  test('indexed EPUB note targets match the original selector lookups', () {
    final document = html.parse(
      '<html><head><title id="t">x</title></head><body>'
      '<p id="n1">first</p><p id="n1">duplicate</p>'
      '<a name="n2"></a><p name="n2">later name</p><p id="n2">id wins</p>'
      '<aside id="Fn_3-a"><p>note</p></aside><p id="note.4">dot</p>'
      '<p id="5x">digit</p><a name="named_only"></a></body></html>',
    );
    dom(String id) {
      try {
        return document.getElementById(id) ??
            document
                .querySelectorAll('[name]')
                .where((e) => e.attributes['name'] == id)
                .firstOrNull;
      } on FormatException {
        return #error;
      }
    }

    for (final id in [
      't', 'n1', 'n2', 'Fn_3-a', 'note.4', '5x', 'named_only', 'missing', //
    ]) {
      Object? actual;
      try {
        actual = epubAnchorTarget(document, id);
      } on FormatException {
        actual = #error;
      }
      expect(actual, same(dom(id)), reason: id);
    }
  });

  testWidgets('streamed pages equal a complete pagination and can stop', (
    tester,
  ) async {
    final text = List.generate(
      300,
      (i) => 'Абзац $i. ${'Море было спокойным, корабль шёл к острову. ' * 4}',
    ).join('\n\n');
    const style = TextStyle(fontSize: 18, height: 1.35);
    // paginateReader yields to the event loop between pages.
    final all = (await tester.runAsync(
      () => paginateReader(text, style, 320, 500, TextScaler.noScaling),
    ))!;
    expect(all.length, greaterThan(20));
    final streamed = <ReaderSlice>[];
    final returned = (await tester.runAsync(
      () => paginateReader(
        text,
        style,
        320,
        500,
        TextScaler.noScaling,
        onPage: (page) async {
          streamed.add(page);
          return streamed.length < 5;
        },
      ),
    ))!;
    List<(int, int, double?)> bounds(List<ReaderSlice> pages) => [
      for (final p in pages) (p.start, p.end, p.height),
    ];
    expect(bounds(streamed), bounds(all.take(5).toList()));
    expect(bounds(returned), bounds(streamed));
  });

  testWidgets(
    'a book without chapters opens in page mode before laying out every page',
    (tester) async {
      size(tester, const Size(390, 844));
      final db = AppDatabase(NativeDatabase.memory()), repo = Repository(db);
      final paragraphs = [
        for (var i = 0; i < 8000; i++)
          'Абзац $i. ${'Море было спокойным, корабль шёл к острову. ' * 3}',
      ];
      final document = ReaderDocument(
        EpubBook('Одна глава', const [], [
          EpubChapter('all', 'Книга', paragraphs),
        ]),
      );
      final asset = LocalAsset(
        id: 'single',
        bookId: 'single',
        filename: 'single.html',
        path: '/missing/single.html',
        hash: 'single',
        bytes: 1,
      );
      await repo.setMeta('reader:appearance', jsonEncode({'mode': 'pages'}));
      int published() => tester
          .widget<PageView>(find.byType(PageView))
          .childrenDelegate
          .estimatedChildCount!;
      try {
        // About 1.2 million characters, roughly 1500 pages. Measuring all of
        // them before the first screen took tens of seconds.
        final opening = Stopwatch()..start();
        await tester.pumpWidget(
          MaterialApp(
            home: ReaderPage(
              repository: repo,
              asset: asset,
              suppliedDocument: document,
            ),
          ),
        );
        for (var i = 0; i < 10; i++) {
          await settle(tester);
          if (find.byType(PageView).evaluate().isNotEmpty) break;
        }
        expect(find.byType(ReaderViewport), findsOneWidget);
        expect(opening.elapsed, lessThan(const Duration(seconds: 8)));
        expect(find.textContaining('Абзац 0.'), findsOneWidget);
        // The whole chapter is several hundred pages.
        final first = published();
        expect(first, lessThan(64));
        // Turning pages lays out the following ones on demand.
        for (var i = 0; i < 24; i++) {
          await turnReaderPage(tester);
          await settle(tester);
        }
        expect(find.textContaining('25 из '), findsOneWidget);
        expect(published(), greaterThan(25));
        expect(published(), greaterThan(first));
        final saved = jsonDecode(
          (await repo.meta('reader:single'))!,
        ) as Map<String, dynamic>;
        expect(saved['textOffset'] as int, greaterThan(0));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await settle(tester);
        await db.close();
      }
    },
  );
}
