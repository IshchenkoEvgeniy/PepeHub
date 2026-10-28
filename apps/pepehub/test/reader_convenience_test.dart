import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/reader/reader_bookmarks.dart';
import 'package:pepehub/reader/reader_controls.dart';
import 'package:pepehub/reader/reader_layout.dart';
import 'package:pepehub/reader/reader_rebase.dart';
import 'package:pepehub/reader/reader_selectable_paragraph.dart';
import 'package:pepehub/reader/reader_viewport.dart';
import 'package:pepehub/reader/reading_library.dart';
import 'package:pepehub/reader/text_book.dart';

import 'reader_annotations_bookmarks_test.dart' show reader, asset, document;
import 'reader_improvements_test.dart' show settle, size;

Future<void> ctrl(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await settle(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('search folds ё and whitespace while preserving UTF-16 anchors', () {
    const text = '🌊 Ёлка\n  у\u00a0моря. [еще] и [ещё].';
    final hits = searchReader({
      'texts': [text],
      'query': 'елка у моря',
    });
    expect(hits.single['offset'], 3);
    expect(
      text.substring(hits.single['offset'], hits.single['end']),
      'Ёлка\n  у\u00a0моря',
    );
    expect(
      searchReader({
        'texts': [text],
        'query': '[ЕЩЁ]',
      }),
      hasLength(2),
    );
    expect(
      searchReader({
        'texts': [text],
        'query': '.*',
      }),
      isEmpty,
    );
    expect(readerExcerpt('a🌊b', 2, 2, before: 0, after: 0), '🌊');
    expect(const ReaderPreferences().palette, 'system');
    expect(ReaderPreferences.fromJson({'palette': 'dark'}).palette, 'dark');
  });

  test('TXT headings preserve exact source and migrate every saved anchor once', () async {
    const source =
        'Вступление 🌊\n\nГлава 1. Море\nПервая строка\nВторая строка\n\nCHAPTER II\nКонец.';
    final bytes = Uint8List.fromList(utf8.encode(source));
    final before = ReaderDocument(parseTextBook(bytes, 'b.txt', layout: 3));
    final after = ReaderDocument(parseTextBook(bytes, 'b.txt'));
    expect(after.book.chapters.map((c) => c.title), [
      'Вступление',
      'Глава 1. Море',
      'CHAPTER II',
    ]);
    expect(after.texts.join(), before.texts.single);
    final at = source.indexOf('Конец');
    final start = source.indexOf('Вторая');
    final end = at + 'Конец'.length;
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = Repository(db), library = ReadingLibrary(repo);
    await repo.setMeta('reader-layout-version:h', '3');
    await repo.setMeta(
      'reader:h',
      jsonEncode({
        'chapter': 0,
        'textOffset': at,
        'layoutVersion': 2,
        'returnTo': [
          {'chapter': 0, 'offset': start},
        ],
        'pinnedChapter': {'chapter': 0, 'offset': at},
      }),
    );
    await repo.setMeta(
      'reading-note:n',
      jsonEncode({
        'id': 'n',
        'hash': 'h',
        'chapter': 0,
        'start': start,
        'end': end,
        'quote': source.substring(start, end),
        'comment': 'Keep me',
      }),
    );
    await repo.setMeta(
      'reading-coverage:h',
      jsonEncode({
        'ranges': [
          [0, at],
        ],
      }),
    );
    final bookmark = await ReaderBookmarkStore(
      repo,
      'h',
    ).add(title: 'End', chapter: 0, offset: at);
    Future<ReaderDocument> noLegacy() async => throw StateError('Wrong layout');
    await migrateReaderLayout(
      library,
      'h',
      after,
      noLegacy,
      prior: () async => before,
    );
    final saved = await library.value('reader:h');
    expect(saved['chapter'], 2);
    expect(after.texts[2].substring(saved['textOffset']), startsWith('Конец'));
    final moved = (await ReaderBookmarkStore(repo, 'h').list()).single;
    expect(moved.id, bookmark.id);
    expect(moved.chapter, 2);
    expect(after.starts[moved.chapter] + moved.offset, at);
    final notes = (await library.entries('reading-note:')).values.toList()
      ..sort((a, b) => (a['chapter'] as int).compareTo(b['chapter'] as int));
    expect(notes, hasLength(2));
    expect(notes.map((n) => n['quote']).join(), source.substring(start, end));
    for (final n in notes) {
      expect(n['comment'], 'Keep me');
      expect(
        after.texts[n['chapter']].substring(n['start'], n['end']),
        n['quote'],
      );
    }
    expect((await library.value('reading-coverage:h'))['ranges'], [
      [0, at],
    ]);
    expect(await repo.meta('reader-layout-backup-5:h'), isNotNull);
    await migrateReaderLayout(library, 'h', after, noLegacy, prior: noLegacy);
    expect(await library.entries('reading-note:'), hasLength(2));
  });

  test(
    'TXT prose without explicit numbered heading keeps original paragraphs',
    () {
      const source =
          'Глава этой книги посвящена морю.\nПросто перенос.\n\nДругой абзац.';
      final book = parseTextBook(
        Uint8List.fromList(utf8.encode(source)),
        'b.txt',
      );
      expect(book.chapters, hasLength(1));
      expect(book.chapters.single.paragraphs, hasLength(2));
    },
  );

  testWidgets('settings preview, explicit save and dismissal cancel', (
    tester,
  ) async {
    size(tester, const Size(800, 1100));
    ReaderPreferences? result, preview;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showReaderSettings(
                  context,
                  const ReaderPreferences(),
                  onPreview: (v) => preview = v,
                );
              },
              child: const Text('Settings'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 8; i++) {
      await tester.tap(find.byTooltip('Увеличить размер текста'));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 200));
    expect(preview!.size, 30);
    await tester.tap(find.text('Готово'));
    await tester.pumpAndSettle();
    expect(result!.size, 30);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Увеличить размер текста'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.ensureVisible(find.text('Отменить'));
    await tester.tap(find.text('Отменить'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    Navigator.pop(tester.element(find.byType(BottomSheet)));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });

  testWidgets(
    'quick bookmark, keyboard font and book boundaries survive reopening',
    (tester) async {
      size(tester, const Size(900, 1000));
      final db = AppDatabase(NativeDatabase.memory()), repo = Repository(db);
      try {
        await tester.pumpWidget(reader(repo));
        await settle(tester);
        await tester.tap(find.byTooltip('Сохранить закладку'));
        await settle(tester);
        expect(
          await ReaderBookmarkStore(repo, asset.hash).list(),
          hasLength(1),
        );
        await ctrl(tester, LogicalKeyboardKey.equal);
        expect(
          (await ReadingLibrary(repo).value('reader:appearance'))['size'],
          24,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.end);
        await settle(tester);
        var saved = await ReadingLibrary(repo).value('reader:${asset.hash}');
        expect(saved['chapter'], 2);
        expect(saved['textOffset'], document.texts.last.length);
        await ctrl(tester, LogicalKeyboardKey.keyD);
        expect(
          await ReaderBookmarkStore(repo, asset.hash).list(),
          hasLength(2),
        );
        await tester.pumpWidget(const SizedBox());
        await settle(tester);
        await tester.pumpWidget(reader(repo));
        await settle(tester);
        expect(
          tester
              .widget<ReaderViewport>(find.byType(ReaderViewport))
              .preferences!
              .size,
          24,
        );
        expect(
          await ReaderBookmarkStore(repo, asset.hash).list(),
          hasLength(2),
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.home);
        await settle(tester);
        saved = await ReadingLibrary(repo).value('reader:${asset.hash}');
        expect((saved['chapter'], saved['textOffset']), (0, 0));
        await ctrl(tester, LogicalKeyboardKey.keyB);
        expect(find.textContaining('%'), findsWidgets);
        expect(find.textContaining('Море 🌊'), findsWidgets);
        await tester.tap(find.byTooltip('Добавить закладку'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'My place');
        await ctrl(tester, LogicalKeyboardKey.keyD);
        expect(
          await ReaderBookmarkStore(repo, asset.hash).list(),
          hasLength(2),
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await settle(tester);
        await db.close();
      }
    },
  );

  testWidgets(
    'mouse selects across paragraphs with repeated text and exact source offsets',
    (tester) async {
      size(tester, const Size(600, 800));
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      const text = 'Repeat 🌊 phrase.\n\nRepeat 🌊 phrase.\n\nThird paragraph.';
      (int, int)? annotated;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Scaffold(
            body: ReaderViewport(
              text: text,
              style: const TextStyle(fontSize: 18, height: 1.4),
              scaler: TextScaler.noScaling,
              width: 600,
              height: 800,
              margin: 20,
              anchor: 0,
              scrolling: true,
              compactFlow: true,
              firstChapter: true,
              lastChapter: true,
              onPosition: (_) {},
              onChapter: (_) {},
              onAnnotate: (start, end, _) => annotated = (start, end),
            ),
          ),
        ),
      );
      await settle(tester);
      final paragraphs = find.byType(ReaderSelectableParagraph);
      expect(paragraphs, findsNWidgets(3));
      final second = tester.getRect(paragraphs.at(1)),
          third = tester.getRect(paragraphs.at(2));
      final gesture = await tester.startGesture(
        Offset(second.left + 1, second.center.dy),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(Offset(third.right - 1, third.center.dy));
      await gesture.up();
      await tester.pumpAndSettle();
      await ctrl(tester, LogicalKeyboardKey.keyC);
      expect(copied, 'Repeat 🌊 phrase.\n\nThird paragraph.');
      final menu = await tester.startGesture(
        Offset(second.left + 8, second.center.dy),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await menu.up();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Выделить'));
      await tester.pumpAndSettle();
      expect(annotated, (text.indexOf('Repeat', 1), text.length));
      expect(
        text.substring(annotated!.$1, annotated!.$2),
        'Repeat 🌊 phrase.\n\nThird paragraph.',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('focused scroll text responds to arrow keys and page keys', (
    tester,
  ) async {
    size(tester, const Size(600, 800));
    final text = List.generate(
      80,
      (i) => 'Paragraph $i. ${'Readable words. ' * 8}',
    ).join('\n\n');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReaderViewport(
            text: text,
            style: const TextStyle(fontSize: 18, height: 1.4),
            scaler: TextScaler.noScaling,
            width: 600,
            height: 800,
            margin: 20,
            anchor: 0,
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
    await settle(tester);
    await tester.tap(find.byType(ReaderSelectableParagraph).first);
    await tester.pumpAndSettle();
    final list = tester.widget<ListView>(find.byType(ListView));
    final scroll = list.controller!;
    final before = scroll.offset;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(before));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(before, .1));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(200));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'selection retains its first paragraph while scrolling a long quote',
    (tester) async {
      size(tester, const Size(600, 500));
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final text = List.generate(
        60,
        (i) => 'Paragraph $i. ${'Some words here. ' * 4}',
      ).join('\n\n');
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: Scaffold(
            body: ReaderViewport(
              text: text,
              style: const TextStyle(fontSize: 18, height: 1.4),
              scaler: TextScaler.noScaling,
              width: 600,
              height: 500,
              margin: 20,
              anchor: 0,
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
      await settle(tester);
      final paragraphs = find.byType(ReaderSelectableParagraph);
      final second = tester.getRect(paragraphs.at(1)),
          fourth = tester.getRect(paragraphs.at(3));
      final firstKey = tester
          .widget<ReaderSelectableParagraph>(paragraphs.at(1))
          .key!;
      final gesture = await tester.startGesture(
        Offset(second.left + 1, second.top + 10),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(Offset(fourth.left + 100, fourth.top + 10));
      await tester.pumpAndSettle();
      await gesture.moveTo(const Offset(400, 550));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byKey(firstKey, skipOffstage: false), findsOneWidget);
      await gesture.moveTo(const Offset(400, 400));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      await ctrl(tester, LogicalKeyboardKey.keyC);
      expect(copied, startsWith('Paragraph 1.'));
      expect(copied, contains('Paragraph 10.'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Android selection toolbar annotates multiple paragraphs', (
    tester,
  ) async {
    size(tester, const Size(390, 800));
    const text = 'Первая строка.\n\nВторая строка 🌊.\n\nТретья строка.';
    (int, int)? annotated;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: Scaffold(
          body: ReaderViewport(
            text: text,
            style: const TextStyle(fontSize: 18, height: 1.4),
            scaler: TextScaler.noScaling,
            width: 390,
            height: 800,
            margin: 20,
            anchor: 0,
            scrolling: true,
            compactFlow: true,
            firstChapter: true,
            lastChapter: true,
            onPosition: (_) {},
            onChapter: (_) {},
            onAnnotate: (a, b, _) => annotated = (a, b),
          ),
        ),
      ),
    );
    await settle(tester);
    await tester.longPress(find.byType(ReaderSelectableParagraph).at(1));
    await tester.pumpAndSettle();
    tester
        .state<SelectableRegionState>(find.byType(SelectableRegion))
        .selectAll(SelectionChangedCause.toolbar);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Выделить'));
    await tester.pumpAndSettle();
    expect(annotated, (0, text.length));
    expect(tester.takeException(), isNull);
  });

  testWidgets('focused paged text accepts page navigation keys', (
    tester,
  ) async {
    size(tester, const Size(600, 800));
    var position = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReaderViewport(
            text: 'A long text for reading. ' * 500,
            style: const TextStyle(fontSize: 18, height: 1.4),
            scaler: TextScaler.noScaling,
            width: 600,
            height: 800,
            margin: 20,
            anchor: 0,
            scrolling: false,
            firstChapter: true,
            lastChapter: true,
            onPosition: (v) => position = v,
            onChapter: (_) {},
          ),
        ),
      ),
    );
    await settle(tester);
    await tester.tap(find.byType(SelectableText).first);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(position, greaterThan(0));
    final prior = position;
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(position, greaterThan(prior));
    expect(tester.takeException(), isNull);
  });
}
