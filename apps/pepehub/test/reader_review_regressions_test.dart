import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/reader/epub.dart';
import 'package:pepehub/reader/reader_bookmarks.dart';
import 'package:pepehub/reader/reader_bookmarks_page.dart';
import 'package:pepehub/reader/reader_contents.dart';
import 'package:pepehub/reader/reader_controls.dart';
import 'package:pepehub/reader/reader_layout.dart';
import 'package:pepehub/reader/reader_page.dart';
import 'package:pepehub/reader/reader_rebase.dart';
import 'package:pepehub/reader/reader_viewport.dart';
import 'package:pepehub/reader/reading_activity.dart';
import 'package:pepehub/reader/reading_library.dart';
import 'package:pepehub/reader/text_book.dart';

import 'reader_annotations_bookmarks_test.dart' show asset;
import 'reader_improvements_test.dart' show settle, size;

class DelayedBookmarks extends ReaderBookmarkStore {
  int calls = 0;
  final gate = Completer<List<ReaderBookmark>>();
  DelayedBookmarks(super.repository, super.hash);
  @override
  Future<List<ReaderBookmark>> list() {
    if (++calls == 2) return gate.future;
    return super.list();
  }
}

class FailOneFinalPart extends Repository {
  bool failed = false;
  FailOneFinalPart(super.db);
  @override
  Future<void> setMeta(String key, String value) {
    if (!failed &&
        key.startsWith('reading-session:') &&
        jsonDecode(value)['closed'] == true) {
      failed = true;
      return Future.error(StateError('Temporary write failure'));
    }
    return super.setMeta(key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('TXT rejects prose headings, preserves paragraphs and migrates layout 4 anchors', () async {
    const source =
        'Вступление.\nчасть первая его жизни прошла в море.\nГлава 3 начиналась с того, что он ушёл.\n\nГлава 1. Море\nПервая строка.\n\nВторой абзац.\n\nCHAPTER II\nКонец 🌊.';
    final bytes = Uint8List.fromList(utf8.encode(source));
    final before = ReaderDocument(parseTextBook(bytes, 'b.txt', layout: 4));
    final after = ReaderDocument(parseTextBook(bytes, 'b.txt'));
    expect(
      before.book.chapters.length,
      greaterThan(after.book.chapters.length),
    );
    expect(after.book.chapters.map((c) => c.title), [
      'Вступление',
      'Глава 1. Море',
      'CHAPTER II',
    ]);
    expect(after.texts.join(), before.texts.join());
    expect(after.book.chapters[1].paragraphs[1], 'Второй абзац.');
    final heading = after.book.chapters[1].markup.single;
    expect(
      (heading.start, heading.end, heading.heading),
      (0, 'Глава 1. Море'.length, 1),
    );
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = Repository(db), library = ReadingLibrary(repo);
    final oldChapter = before.book.chapters.indexWhere(
      (c) => c.title.startsWith('Глава 3 начиналась'),
    );
    await repo.setMeta('reader-layout-version:h', '4');
    await repo.setMeta(
      'reader:h',
      jsonEncode({'chapter': oldChapter, 'textOffset': 5}),
    );
    final bookmark = await ReaderBookmarkStore(
      repo,
      'h',
    ).add(title: 'Keep', chapter: oldChapter, offset: 5);
    await migrateReaderLayout(
      library,
      'h',
      after,
      () async => throw StateError('Not layout 1'),
      sourceLayout: (layout) async {
        expect(layout, 4);
        return before;
      },
    );
    final saved = await library.value('reader:h');
    expect(saved['chapter'], 0);
    expect(
      after.starts[0] + saved['textOffset'],
      before.starts[oldChapter] + 5,
    );
    final moved = (await ReaderBookmarkStore(repo, 'h').list()).single;
    expect(moved.id, bookmark.id);
    expect(
      after.starts[moved.chapter] + moved.offset,
      before.starts[oldChapter] + 5,
    );
    expect(await repo.meta('reader-layout-backup-5:h'), isNotNull);
  });

  testWidgets(
    'highlight stays in its source chapter and both side panels follow scroll',
    (tester) async {
      size(tester, const Size(1450, 900));
      final d = ReaderDocument(
        EpubBook('Book', const [], [
          EpubChapter('a', 'First', ['Море и берег. ' * 120]),
          EpubChapter('b', 'Second', ['Остров и дом. ' * 120]),
        ]),
      );
      final db = AppDatabase(NativeDatabase.memory()), repo = Repository(db);
      final library = ReadingLibrary(repo);
      final notes = [
        for (var c = 0; c < 2; c++)
          ReadingNote(
            id: 'n$c',
            bookId: asset.bookId,
            hash: asset.hash,
            bookTitle: 'Book',
            chapterTitle: d.book.chapters[c].title,
            chapter: c,
            start: 0,
            end: 4,
            quote: d.texts[c].substring(0, 4),
            comment: 'Комментарий $c',
            color: 'green',
            updated: '2026-10-25T12:00:00Z',
          ),
      ];
      try {
        for (final note in notes) {
          await library.saveNote(note);
        }
        await tester.pumpWidget(
          MaterialApp(
            home: ReaderPage(
              repository: repo,
              asset: asset,
              suppliedDocument: d,
              initialNote: notes.first,
            ),
          ),
        );
        await settle(tester);
        final original = tester.widget<ReaderViewport>(
          find.byType(ReaderViewport),
        );
        expect(original.highlightStart, 0);
        expect(find.text('Комментарий 0'), findsOneWidget);
        original.onPosition(original.text.indexOf('Остров'));
        await tester.pump();
        expect(find.text('Комментарий 1'), findsOneWidget);
        expect(find.text('Комментарий 0'), findsNothing);
        final toc = tester.widget<ReaderContentsSearch>(
          find.byType(ReaderContentsSearch),
        );
        original.onPosition(original.text.indexOf('Остров') + 1);
        await tester.pump();
        expect(
          identical(
            toc,
            tester.widget<ReaderContentsSearch>(
              find.byType(ReaderContentsSearch),
            ),
          ),
          isTrue,
        );
        await tester.tap(find.byTooltip('Сохранить закладку'));
        await settle(tester);
        final rebuilt = tester.widget<ReaderViewport>(
          find.byType(ReaderViewport),
        );
        expect((rebuilt.highlightStart, rebuilt.highlightEnd), (0, 4));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await settle(tester);
        await db.close();
      }
    },
  );

  testWidgets('F3 loads the next batch and navigates to match 201', (
    tester,
  ) async {
    size(tester, const Size(430, 900));
    final d = ReaderDocument(
      EpubBook('Book', const [], [
        EpubChapter('a', 'Chapter', ['needle ' * 205]),
      ]),
    );
    final db = AppDatabase(NativeDatabase.memory()), repo = Repository(db);
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPage(repository: repo, asset: asset, suppliedDocument: d),
        ),
      );
      await settle(tester);
      await tester.tap(find.byTooltip('Поиск по книге'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'needle');
      await settle(tester);
      final page = tester.widget<ReaderSearch>(find.byType(ReaderSearch));
      expect(page.session!.hits, hasLength(200));
      Navigator.pop(
        tester.element(find.byType(ReaderSearch)),
        page.session!.hits.last,
      );
      await settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.f3);
      await settle(tester);
      expect(find.textContaining('201/205'), findsOneWidget);
      final saved = await ReadingLibrary(repo).value('reader:${asset.hash}');
      expect(saved['textOffset'], 200 * 'needle '.length);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await db.close();
    }
  });

  for (final busy in [false, true]) {
    testWidgets(
      'bookmark undo works ${busy ? 'during pending reload' : 'after route disposal'}',
      (tester) async {
        size(tester, const Size(430, 900));
        final db = AppDatabase(NativeDatabase.memory()), repo = Repository(db);
        final store = busy
            ? DelayedBookmarks(repo, 'h')
            : ReaderBookmarkStore(repo, 'h');
        final bookmark = await store.add(
          title: 'Keep me',
          chapter: 0,
          offset: 5,
        );
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => ReaderBookmarksPage(
                          store: store,
                          chapterTitles: const ['Chapter'],
                          chapter: 0,
                          offset: 0,
                        ),
                      ),
                    ),
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open'));
          await settle(tester);
          await tester.tap(find.byTooltip('Действия с закладкой'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Удалить закладку'));
          for (var i = 0; i < 15; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump(const Duration(milliseconds: 50));
          }
          final undo = tester
              .widget<SnackBar>(find.byType(SnackBar))
              .action!
              .onPressed;
          if (!busy) {
            await tester.binding.handlePopRoute();
            await settle(tester);
            expect(find.byType(ReaderBookmarksPage), findsNothing);
          }
          undo();
          for (var i = 0; i < 15; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump(const Duration(milliseconds: 50));
          }
          expect(
            await repo.meta('reader-bookmark:h:${bookmark.id}'),
            isNotNull,
          );
          if (store is DelayedBookmarks) {
            store.gate.complete([]);
            await settle(tester);
            expect(find.text('Keep me'), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
        } finally {
          if (store is DelayedBookmarks && !store.gate.isCompleted) {
            store.gate.complete([]);
          }
          await tester.pumpWidget(const SizedBox());
          await settle(tester);
          await db.close();
        }
      },
    );
  }

  test('bounded session parts retain every event and retry a failed finalized write', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = FailOneFinalPart(db), errors = <Object>[];
    final exported = <String, Map<String, dynamic>>{};
    var now = DateTime(2026, 10, 25, 12);
    final a = ReadingActivity(
      repo,
      bookId: 'b',
      hash: 'h',
      length: 1000,
      clock: () => now,
      onError: errors.add,
      export: (value) async {
        exported[value['id'] as String] = value;
      },
    );
    await a.start(0, runTimer: false);
    for (var i = 0; i < 300; i++) {
      now = now.add(const Duration(seconds: 3));
      a.move(100, chapterEnded: true, deferCheckpoint: true);
      a.move(0, jump: true, deferCheckpoint: true);
      expect(
        a.events.length,
        lessThanOrEqualTo(ReadingActivity.maxSegmentEvents),
      );
      expect(
        a.spans.length,
        lessThanOrEqualTo(ReadingActivity.maxSegmentSpans),
      );
    }
    await a.writes;
    expect(errors, hasLength(1));
    await a.close();
    final parts =
        (await ReadingLibrary(
          repo,
        ).entries('reading-session:')).values.toList()..sort(
          (a, b) =>
              (a['segmentNumber'] as int).compareTo(b['segmentNumber'] as int),
        );
    expect(parts.length, greaterThan(1));
    final events = parts.expand((p) => p['events'] as List).toList();
    expect(
      events,
      hasLength(602),
    ); // start + 300 chapter ends + 300 jumps + end
    expect(events.where((e) => e['kind'] == 'jump'), hasLength(300));
    expect(parts.every((p) => p['closed'] == true), isTrue);
    expect(exported.keys.toSet(), parts.map((p) => p['id']).toSet());
    for (final part in parts) {
      expect(exported[part['id']], part);
    }
    final total = readingTotals(parts);
    expect(
      (total.milliseconds, total.newChars, total.repeatChars, total.sessions),
      (900000, 100, 29900, 1),
    );
    expect(
      parts.fold<int>(0, (sum, p) => sum + (p['speedChars'] as int)),
      a.speedChars,
    );
    expect(
      parts.fold<int>(0, (sum, p) => sum + (p['speedActiveMs'] as int)),
      a.speedActiveMs,
    );
    final display = groupReadingSessionsForDisplay(parts);
    expect(display, hasLength(1));
    expect(readingTotals(display).milliseconds, total.milliseconds);
    expect(display.single['events'], isEmpty);
  });
}
