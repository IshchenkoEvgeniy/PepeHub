import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:pepehub/reader/reader_selectable_paragraph.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/reader/epub.dart';
import 'package:pepehub/reader/reader_controls.dart';
import 'package:pepehub/reader/reader_layout.dart';
import 'package:pepehub/reader/reader_page.dart';
import 'package:pepehub/reader/reader_search.dart';
import 'package:pepehub/reader/reader_viewport.dart';
import 'package:pepehub/reader/reading_library.dart';

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

void size(WidgetTester tester, Size value) {
  tester.view.physicalSize = value;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'system palette follows the OS and column width preserves old preferences',
    () {
      final value = ReaderPreferences.fromJson({'palette': 'system'});
      expect(value.columnWidth, 900);
      expect(value.isDark(Brightness.light), isFalse);
      expect(value.isDark(Brightness.dark), isTrue);
      expect(value.copy(palette: 'dark').isDark(Brightness.light), isTrue);
      expect(value.copy(palette: 'light').isDark(Brightness.dark), isFalse);
      expect(
        ReaderPreferences.fromJson(value.copy(columnWidth: 640).toJson())
            .columnWidth,
        640,
      );
      expect(ReaderPreferences.fromJson({'columnWidth': 80}).columnWidth, 360);
      expect(
        ReaderPreferences.fromJson({'columnWidth': 5000}).columnWidth,
        1200,
      );
    },
  );

  test(
    'deep layout starts near the original anchor at a source word boundary',
    () {
      final text = List.generate(
        12000,
        (i) => 'Paragraph $i. Sea 🌊 and shore.',
      ).join('\n\n');
      final anchor = text.indexOf('Paragraph 11000.');
      final start = readerWindowStart(text, anchor);
      expect(start, greaterThan(text.length * .8));
      expect(anchor - start, inInclusiveRange(11000, 18000));
      expect(text.substring(start), startsWith('Paragraph '));
      expect(text.codeUnitAt(start), isNot(inInclusiveRange(0xDC00, 0xDFFF)));
      expect(readerWindowStart(text, 120), 0);
      final unbrokenParagraph = 'A story about the sea 🌊. ' * 3000;
      final local = readerWindowStart(unbrokenParagraph, 60000);
      expect(local, greaterThan(47000));
      expect(unbrokenParagraph[local - 1], ' ');
    },
  );

  test(
    'paragraph index keeps legacy newline boundaries and UTF-16 anchors',
    () {
      final document = ReaderDocument(
        const EpubBook('Book', [], [
          EpubChapter('a', 'A', ['', 'Sea 🌊', '', 'End']),
          EpubChapter('b', 'Image only', []),
        ]),
      );
      final paragraphs = document.book.chapters.first.paragraphs;
      for (var at = 0; at <= document.texts.first.length; at++) {
        var remaining = at;
        for (var i = 0; i < paragraphs.length; i++) {
          if (remaining <= paragraphs[i].length || i == paragraphs.length - 1) {
            expect(document.paragraphAt(0, at), (
              paragraph: i,
              within: remaining.clamp(0, paragraphs[i].length),
            ));
            break;
          }
          remaining -= paragraphs[i].length + 2;
        }
      }
      expect(document.offset(0, 1, 6), 8);
      expect(document.paragraphAt(1, 0), (paragraph: 0, within: 0));
      expect(document.offset(1, 0, 0), 0);
    },
  );

  test('superseded search and pending spawn are cancelled rather than returning stale hits', () async {
    final worker = ReaderSearchWorker();
    try {
      final first = worker.search(
        texts: ['old text ' * 100000],
        query: 'missing',
      );
      final second = worker.search(
        texts: ['Sea 🌊 [literal]'],
        query: '[literal]',
      );
      expect(await first, isNull);
      final result = (await second)!;
      expect(result.hits.single['offset'], 7);
      expect(result.hasMore, isFalse);
      final closing = worker.search(
        texts: ['another ' * 10000],
        query: 'another',
      );
      worker.cancel();
      expect(await closing, isNull);
    } finally {
      worker.cancel();
    }
  });

  test('search continuation and chapter scope keep exact UTF-16 offsets without duplicate matches', () async {
    final worker = ReaderSearchWorker();
    final texts = ['🌊 [ТЕСТ] ' * 230, '[тест] ' * 5];
    try {
      final first = (await worker.search(texts: texts, query: '[тест]'))!;
      expect(first.hits, hasLength(200));
      expect(first.hasMore, isTrue);
      final next = (await worker.search(
        texts: texts,
        query: '[тест]',
        after: first.hits.last,
      ))!;
      expect(next.hits, hasLength(35));
      expect(next.hasMore, isFalse);
      final all = [...first.hits, ...next.hits];
      expect(
        all.map((hit) => (hit['chapter'], hit['offset'])).toSet(),
        hasLength(235),
      );
      for (final hit in all) {
        expect(
          texts[hit['chapter'] as int]
              .substring(hit['offset'] as int, hit['end'] as int)
              .toLowerCase(),
          '[тест]',
        );
      }
      final scoped = (await worker.search(
        texts: texts,
        query: '[ТЕСТ]',
        chapter: 1,
      ))!;
      expect(scoped.hits, hasLength(5));
      expect(scoped.hits.every((hit) => hit['chapter'] == 1), isTrue);
    } finally {
      worker.cancel();
    }
  });

  testWidgets(
    'search can load beyond 200 hits, remember its query and clear results',
    (tester) async {
      size(tester, const Size(390, 844));
      final session = ReaderSearchSession();
      final document = ReaderDocument(
        EpubBook('Book', [], [
          EpubChapter('a', 'Chapter A', ['needle ' * 240]),
          const EpubChapter('b', 'Chapter B', ['needle at sea']),
        ]),
      );
      Widget search() => MaterialApp(
        home: ReaderSearch(
          document: document,
          currentChapter: 1,
          session: session,
        ),
      );
      await tester.pumpWidget(search());
      await tester.enterText(find.byType(TextField), 'needle');
      await settle(tester);
      expect(find.text('Совпадений: 200+'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Показать ещё совпадения'),
        3000,
        scrollable: find.byType(Scrollable).last,
        maxScrolls: 20,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Показать ещё совпадения'));
      await settle(tester);
      expect(session.hits, hasLength(241));
      expect(session.hasMore, isFalse);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Текущая глава'));
      await settle(tester);
      expect(find.text('Совпадений: 1'), findsOneWidget);
      expect(session.hits.single['chapter'], 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(search());
      await settle(tester);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'needle',
      );
      expect(find.text('Совпадений: 1'), findsOneWidget);
      await tester.tap(find.byTooltip('Очистить поиск'));
      await settle(tester);
      expect(session.query, isEmpty);
      expect(session.hits, isEmpty);
      expect(find.byType(ListTile), findsNothing);
    },
  );

  for (final mode in ['pages', 'seamless', 'compact']) {
    testWidgets(
      '$mode opens a deep anchor and can navigate to the preceding source window',
      (tester) async {
        size(tester, const Size(390, 844));
        final text = List.generate(
          4000,
          (i) => 'Paragraph $i. ${'The sea was calm. ' * 5}',
        ).join('\n\n');
        final original = text.indexOf('Paragraph 3600.');
        var anchor = original;
        int? earlier;
        late StateSetter update;
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return Material(
                  child: ReaderViewport(
                    key: ValueKey(anchor),
                    text: text,
                    style: const TextStyle(fontSize: 18, height: 1.35),
                    scaler: TextScaler.noScaling,
                    width: 390,
                    height: 844,
                    margin: 20,
                    anchor: anchor,
                    scrolling: mode != 'pages',
                    compactFlow: mode == 'compact',
                    firstChapter: true,
                    lastChapter: true,
                    onPosition: (_) {},
                    onChapter: (_) {},
                    onSeek: (value) => earlier = value,
                  ),
                );
              },
            ),
          ),
        );
        await settle(tester);
        final shown = tester
            .widgetList<ReaderSelectableParagraph>(
              find.byType(ReaderSelectableParagraph),
            )
            .map((text) => text.span.toPlainText())
            .followedBy(
              tester
                  .widgetList<SelectableText>(find.byType(SelectableText))
                  .map(
                    (text) => text.textSpan?.toPlainText() ?? text.data ?? '',
                  ),
            )
            .join();
        expect(shown, contains('Paragraph 3600.'));
        final start = readerWindowStart(text, original);
        update(() => anchor = start);
        await settle(tester);
        // This is a fresh window around the earlier anchor. Go to its first page.
        final currentStart = readerWindowStart(text, anchor);
        if (mode == 'pages') {
          final controller = tester
              .widget<PageView>(find.byType(PageView))
              .controller!;
          controller.jumpToPage(0);
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Предыдущая страница'));
        } else {
          final list = tester.widget<ListView>(find.byType(ListView).first);
          list.controller!.jumpTo(0);
          await tester.pumpAndSettle();
          await tester.drag(find.byType(ListView).first, const Offset(0, 120));
        }
        await settle(tester);
        expect(earlier, currentStart - 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'reader follows OS brightness without relayout, preserves notes and applies column width',
    (tester) async {
      size(tester, const Size(1500, 1000));
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final db = AppDatabase(NativeDatabase.memory());
      final repo = Repository(db);
      final asset = LocalAsset(
        id: 'asset',
        bookId: 'book',
        filename: 'Book.txt',
        path: 'unused',
        hash: 'reader-improvement',
        bytes: 0,
      );
      final document = ReaderDocument(
        const EpubBook('Book', [], [
          EpubChapter('a', 'Chapter', [
            'Sea 🌊 and shore. A marked quote.',
            'Another paragraph about the sea.',
          ]),
        ]),
      );
      final library = ReadingLibrary(repo);
      await repo.setMeta(
        'reader:appearance',
        jsonEncode({'palette': 'system', 'mode': 'pages'}),
      );
      await library.saveNote(
        ReadingNote(
          id: 'note',
          bookId: asset.bookId,
          hash: asset.hash,
          bookTitle: 'Book',
          chapterTitle: 'Chapter',
          quote: '🌊',
          comment: 'Keep this',
          color: 'yellow',
          updated: '2026-10-14T10:00:00Z',
          chapter: 0,
          start: 4,
          end: 6,
        ),
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: ReaderPage(
              repository: repo,
              asset: asset,
              suppliedDocument: document,
            ),
          ),
        );
        await settle(tester);
        final viewport = find.byType(ReaderViewport);
        final initialState = tester.state(viewport);
        expect(Theme.of(tester.element(viewport)).brightness, Brightness.light);
        tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
        await settle(tester);
        expect(Theme.of(tester.element(viewport)).brightness, Brightness.dark);
        expect(identical(tester.state(viewport), initialState), isTrue);
        await tester.tap(find.byTooltip('Оформление чтения'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Сепия'));
        await tester.ensureVisible(find.text('Применить'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Применить'));
        await settle(tester);
        expect(identical(tester.state(viewport), initialState), isTrue);
        await tester.tap(find.byTooltip('Оформление чтения'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('reader-column-width')),
        );
        await tester.pumpAndSettle();
        final slider = find.byKey(const ValueKey('reader-column-width'));
        final box = tester.getRect(slider);
        await tester.tapAt(Offset(box.left + 30, box.center.dy));
        await tester.ensureVisible(find.text('Применить'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Применить'));
        await settle(tester);
        expect(tester.widget<ReaderViewport>(viewport).width, lessThan(650));
        expect(identical(tester.state(viewport), initialState), isFalse);
        final saved = (await library.notes(hash: asset.hash)).single;
        expect(
          (saved.start, saved.end, saved.quote, saved.comment),
          (4, 6, '🌊', 'Keep this'),
        );
        final appearance =
            jsonDecode((await repo.meta('reader:appearance'))!) as Map;
        expect(appearance['columnWidth'] as num, lessThan(650));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await settle(tester);
        await db.close();
      }
    },
  );

  testWidgets(
    'next and previous matches navigate exact anchors and restore the query after reopening',
    (tester) async {
      size(tester, const Size(430, 900));
      final db = AppDatabase(NativeDatabase.memory()),
          document = ReaderDocument(
            const EpubBook('Book', [], [
              EpubChapter('a', 'Chapter', [
                'needle at the sea. needle near the shore.',
              ]),
            ]),
          );
      final repo = Repository(db);
      final asset = LocalAsset(
        id: 'a',
        bookId: 'b',
        filename: 'book.txt',
        path: 'unused',
        hash: 'search-reader',
        bytes: 0,
      );
      Widget page() => MaterialApp(
        home: ReaderPage(
          repository: repo,
          asset: asset,
          suppliedDocument: document,
        ),
      );
      try {
        await tester.pumpWidget(page());
        await settle(tester);
        await tester.tap(find.byTooltip('Поиск по книге'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'needle');
        await settle(tester);
        await tester.tap(find.byType(ListTile).first);
        await settle(tester);
        await tester.tap(find.byTooltip('Следующее совпадение'));
        await settle(tester);
        var position =
            jsonDecode((await repo.meta('reader:${asset.hash}'))!) as Map;
        expect(position['textOffset'], 19);
        await tester.tap(find.byTooltip('Предыдущее совпадение'));
        await settle(tester);
        position =
            jsonDecode((await repo.meta('reader:${asset.hash}'))!) as Map;
        expect(position['textOffset'], 0);
        await tester.sendKeyEvent(LogicalKeyboardKey.f3);
        await settle(tester);
        position =
            jsonDecode((await repo.meta('reader:${asset.hash}'))!) as Map;
        expect(position['textOffset'], 19);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.f3);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await settle(tester);
        position =
            jsonDecode((await repo.meta('reader:${asset.hash}'))!) as Map;
        expect(position['textOffset'], 0);
        await tester.pumpWidget(const SizedBox());
        await settle(tester);
        await tester.pumpWidget(page());
        await settle(tester);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await settle(tester);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'needle',
        );
        await settle(tester);
        expect(find.text('Совпадений: 2'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await settle(tester);
        await db.close();
      }
    },
  );
}
