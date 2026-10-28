import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/reader/epub.dart';
import 'package:pepehub/reader/reader_bookmarks.dart';
import 'package:pepehub/reader/reader_bookmarks_page.dart';
import 'package:pepehub/reader/reader_contents.dart';
import 'package:pepehub/reader/reader_layout.dart';
import 'package:pepehub/reader/reader_page.dart';
import 'package:pepehub/reader/reader_viewport.dart';
import 'package:pepehub/reader/reading_library.dart';
import 'package:pepehub/reader/reading_notes_page.dart';

import 'reader_improvements_test.dart' show settle, size;

final document = ReaderDocument(
  const EpubBook('Book', [], [
    EpubChapter('a', 'Отправление', ['Море 🌊 и берег. Первый путь.']),
    EpubChapter('b', 'Остров', ['Остров и корабль. Второй путь.']),
    EpubChapter('c', 'Возвращение', ['Дом и сад. Третий путь.']),
  ]),
);

LocalAsset get asset => LocalAsset(
  id: 'asset',
  bookId: 'book',
  filename: 'Book.txt',
  path: 'unused',
  hash: 'annotation-book',
  bytes: 0,
);

Widget reader(Repository repo) => MaterialApp(
  home: ReaderPage(repository: repo, asset: asset, suppliedDocument: document),
);

Future<void> action(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip('Другие действия'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await settle(tester);
}

Future<void> select(WidgetTester tester, int start, int end) async {
  final target = find.byType(SelectableText).hitTestable().first;
  await tester.longPress(target);
  await tester.pumpAndSettle();
  final state = tester.state<EditableTextState>(
    find.descendant(of: target, matching: find.byType(EditableText)),
  );
  state.userUpdateTextEditingValue(
    state.textEditingValue.copyWith(
      selection: TextSelection(baseOffset: start, extentOffset: end),
    ),
    SelectionChangedCause.longPress,
  );
  await tester.pump();
  state.showToolbar();
  await tester.pumpAndSettle();
}

Iterable<Color> backgrounds(InlineSpan? span) sync* {
  if (span is TextSpan) {
    if (span.style?.backgroundColor != null) yield span.style!.backgroundColor!;
    for (final child in span.children ?? <InlineSpan>[]) {
      yield* backgrounds(child);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'old appearance defaults to visible yellow; new preferences roundtrip',
    () {
      final old = ReaderPreferences.fromJson({});
      expect(old.highlightColor, 'yellow');
      expect(old.showHighlights, isTrue);
      final next = ReaderPreferences.fromJson(
        old.copy(highlightColor: 'pink', showHighlights: false).toJson(),
      );
      expect(next.highlightColor, 'pink');
      expect(next.showHighlights, isFalse);
      expect(
        ReaderPreferences.fromJson({'highlightColor': 'invalid'})
            .highlightColor,
        'yellow',
      );
    },
  );

  test(
    'bookmarks persist independently across stores, books and position writes',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = Repository(db);
      final store = ReaderBookmarkStore(repo, 'first');
      await repo.setMeta('reader:first', '{"textOffset":8}');
      await repo.setMeta('reading-note:keep', '{"quote":"unchanged"}');
      final added = await Future.wait([
        store.add(title: '  Departure  ', chapter: 0, offset: 4),
        ReaderBookmarkStore(
          repo,
          'first',
        ).add(title: 'Island', chapter: 1, offset: 15),
        ReaderBookmarkStore(
          repo,
          'other',
        ).add(title: 'Other', chapter: 3, offset: 20),
      ]);
      await store.rename(added.first.id, 'New name');
      await repo.setMeta('reader:first', '{"textOffset":100}');
      final reloaded = await ReaderBookmarkStore(repo, 'first').list();
      expect(reloaded, hasLength(2));
      final renamed = reloaded.singleWhere((b) => b.id == added.first.id);
      expect(
        (renamed.title, renamed.chapter, renamed.offset, renamed.createdAt),
        ('New name', 0, 4, added.first.createdAt),
      );
      expect(
        (await ReaderBookmarkStore(repo, 'other').list()).single.id,
        added.last.id,
      );
      expect(await repo.meta('reading-note:keep'), '{"quote":"unchanged"}');
      expect(await repo.meta('reader:first'), '{"textOffset":100}');
    },
  );

  test('delete and undo retain anchors; stale rename cannot resurrect or overwrite', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final store = ReaderBookmarkStore(Repository(db), 'hash');
    final added = await store.add(title: '🌊 Sea', chapter: 2, offset: 42);
    final removed = (await store.delete(added.id))!;
    expect(await store.list(), isEmpty);
    await expectLater(store.rename(added.id, 'Stale'), throwsStateError);
    expect(await store.delete(added.id), isNull);
    await store.restore(removed);
    await store.rename(added.id, 'Restored name');
    await store.restore(removed);
    final saved = (await store.list()).single;
    expect(
      (saved.id, saved.title, saved.chapter, saved.offset),
      (added.id, 'Restored name', 2, 42),
    );
    await expectLater(
      store.add(title: ' ', chapter: 0, offset: 0),
      throwsFormatException,
    );
    await expectLater(
      store.add(title: 'Name', chapter: -1, offset: 0),
      throwsArgumentError,
    );
  });

  testWidgets(
    'phone bookmarks add, validate, rename, delete, undo and reopen exact position',
    (tester) async {
      size(tester, const Size(390, 844));
      final db = AppDatabase(NativeDatabase.memory());
      final repo = Repository(db);
      final store = ReaderBookmarkStore(repo, asset.hash);
      await repo.setMeta('reader:appearance', jsonEncode({'mode': 'pages'}));
      await repo.setMeta(
        'reader:${asset.hash}',
        jsonEncode({
          'layoutVersion': 2,
          'chapter': 1,
          'textOffset': 7,
          'pinnedChapter': {'chapter': 0, 'offset': 4},
        }),
      );
      try {
        await tester.pumpWidget(reader(repo));
        await settle(tester);
        await action(tester, 'Закладки');
        expect(find.byType(ReaderBookmarksPage), findsOneWidget);
        expect(find.text('Закладок пока нет'), findsOneWidget);
        await tester.tap(find.text('Запомнить текущее место'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextFormField), ' ');
        await tester.tap(find.text('Сохранить'));
        await tester.pumpAndSettle();
        expect(find.text('Введите название'), findsOneWidget);
        await tester.enterText(
          find.byType(TextFormField),
          'Встреча на острове',
        );
        await tester.tap(find.text('Сохранить'));
        await settle(tester);
        final saved = (await store.list()).single;
        expect((saved.chapter, saved.offset), (1, 7));
        await tester.tap(find.byTooltip('Действия с закладкой'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Переименовать'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextFormField), 'Встреча');
        await tester.tap(find.text('Сохранить'));
        await settle(tester);
        await tester.tap(find.byTooltip('Действия с закладкой'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Удалить закладку'));
        await settle(tester);
        expect(await store.list(), isEmpty);
        await tester.tap(find.text('Отменить'));
        await settle(tester);
        expect((await store.list()).single.title, 'Встреча');
        await tester.binding.handlePopRoute();
        await settle(tester);
        // Move away before following the saved bookmark.
        tester
            .widget<ReaderViewport>(find.byType(ReaderViewport))
            .onChapter(-1);
        await settle(tester);
        await action(tester, 'Закладки');
        await tester.tap(find.text('Встреча'));
        await settle(tester);
        final viewport = tester.widget<ReaderViewport>(
          find.byType(ReaderViewport),
        );
        expect(viewport.anchor, document.texts[0].length + 2 + 7);
        expect(
          viewport.text.substring(viewport.anchor),
          startsWith(document.texts[1].substring(7)),
        );
        final position =
            jsonDecode((await repo.meta('reader:${asset.hash}'))!) as Map;
        expect((position['chapter'], position['textOffset']), (1, 7));
        expect(position['pinnedChapter'], {'chapter': 0, 'offset': 4});
        expect(await ReadingLibrary(repo).notes(hash: asset.hash), isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await settle(tester);
        await db.close();
      }
    },
  );

  for (final width in [390.0, 1500.0]) {
    testWidgets(
      'contents search on $width keeps chapter indexes, no matches and clear',
      (tester) async {
        size(tester, Size(width, 900));
        final db = AppDatabase(NativeDatabase.memory());
        final repo = Repository(db);
        await repo.setMeta('reader:appearance', jsonEncode({'mode': 'pages'}));
        try {
          await tester.pumpWidget(reader(repo));
          await settle(tester);
          if (width < 1000) {
            await tester.tap(find.byTooltip('Оглавление'));
            await tester.pumpAndSettle();
          }
          final field = find.descendant(
            of: find.byType(ReaderContentsSearch),
            matching: find.byType(TextField),
          );
          await tester.enterText(field, 'нет такой главы');
          await tester.pumpAndSettle();
          expect(find.text('Главы не найдены'), findsOneWidget);
          await tester.tap(find.byTooltip('Сбросить поиск глав'));
          await tester.pumpAndSettle();
          expect(find.text('Главы не найдены'), findsNothing);
          await tester.enterText(field, 'ВОЗВРАЩЕНИЕ');
          await tester.pumpAndSettle();
          if (width < 1000) {
            addTearDown(tester.view.resetViewInsets);
            tester.view.viewInsets = const FakeViewPadding(bottom: 320);
            await tester.pumpAndSettle();
            expect(find.text('Возвращение').last.hitTestable(), findsOneWidget);
          }
          await tester.tap(find.text('Возвращение').last);
          await settle(tester);
          tester.view.resetViewInsets();
          final returned = tester.widget<ReaderViewport>(
            find.byType(ReaderViewport),
          );
          expect(returned.text.substring(returned.anchor), document.texts[2]);
          if (width < 1000) {
            await tester.tap(find.byTooltip('Оглавление'));
            await tester.pumpAndSettle();
          }
          await tester.enterText(field, '2');
          await tester.pumpAndSettle();
          await tester.tap(find.text('Остров').last);
          await settle(tester);
          final island = tester.widget<ReaderViewport>(
            find.byType(ReaderViewport),
          );
          expect(
            island.text.substring(island.anchor),
            startsWith(document.texts[1]),
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await settle(tester);
          await db.close();
        }
      },
    );
  }

  testWidgets(
    'quick palette remembers color after reopening; hiding preserves notes and viewport',
    (tester) async {
      size(tester, const Size(430, 900));
      final db = AppDatabase(NativeDatabase.memory());
      final repo = Repository(db);
      final library = ReadingLibrary(repo);
      await repo.setMeta('reader:appearance', jsonEncode({'mode': 'pages'}));
      try {
        await tester.pumpWidget(reader(repo));
        await settle(tester);
        final viewport = find.byType(ReaderViewport);
        final originalState = tester.state(viewport);
        await select(tester, 5, 7);
        await tester.tap(find.text('Выделить'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Выделить: синий'));
        await settle(tester);
        final note = (await library.notes(hash: asset.hash)).single;
        expect(
          (note.start, note.end, note.quote, note.color),
          (5, 7, '🌊', 'blue'),
        );
        expect(
          tester.widget<ReaderViewport>(viewport).preferences!.highlightColor,
          'blue',
        );
        expect(identical(tester.state(viewport), originalState), isTrue);
        final text = tester.widget<SelectableText>(
          find.byType(SelectableText).first,
        );
        expect(backgrounds(text.textSpan), contains(noteColors['blue']));
        await action(tester, 'Скрыть выделения');
        expect(identical(tester.state(viewport), originalState), isTrue);
        expect(
          backgrounds(
            tester
                .widget<SelectableText>(find.byType(SelectableText).first)
                .textSpan,
          ),
          isEmpty,
        );
        expect(
          (await library.notes(hash: asset.hash)).single.toJson(),
          note.toJson(),
        );
        await tester.pumpWidget(const SizedBox());
        await settle(tester);
        await tester.pumpWidget(reader(repo));
        await settle(tester);
        expect(
          tester.widget<ReaderViewport>(viewport).preferences!.showHighlights,
          isFalse,
        );
        await select(tester, 0, 4);
        await tester.tap(find.text('Выделить'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Выделить: синий'));
        await settle(tester);
        final saved = await library.notes(hash: asset.hash);
        expect(saved, hasLength(2));
        expect(saved.every((n) => n.color == 'blue'), isTrue);
        await action(tester, 'Показать выделения');
        expect(
          backgrounds(
            tester
                .widget<SelectableText>(find.byType(SelectableText).first)
                .textSpan,
          ),
          contains(noteColors['blue']),
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await settle(tester);
        await db.close();
      }
    },
  );

  testWidgets(
    'quick color in seamless flow keeps the selected chapter and source offset',
    (tester) async {
      size(tester, const Size(430, 900));
      final db = AppDatabase(NativeDatabase.memory());
      final repo = Repository(db);
      try {
        await tester.pumpWidget(reader(repo));
        await settle(tester);
        final viewport = tester.widget<ReaderViewport>(
          find.byType(ReaderViewport),
        );
        final start = document.texts.first.length + 2 + 9;
        viewport.onHighlight!(start, start + 7, 'pink');
        await settle(tester);
        final saved = (await ReadingLibrary(repo).notes(hash: asset.hash))
            .single;
        expect(
          (saved.chapter, saved.start, saved.end, saved.quote, saved.color),
          (1, 9, 16, 'корабль', 'pink'),
        );
        final before = saved.toJson();
        // A cross-chapter selection is rejected without a partial or misplaced note.
        tester.widget<ReaderViewport>(find.byType(ReaderViewport)).onHighlight!(
          0,
          start,
          'green',
        );
        await settle(tester);
        expect(
          (await ReadingLibrary(repo).notes(hash: asset.hash)).single.toJson(),
          before,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await settle(tester);
        await db.close();
      }
    },
  );

  testWidgets('hidden saved highlights do not hide a temporary search hit', (
    tester,
  ) async {
    size(tester, const Size(430, 900));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReaderViewport(
            text: 'Sea 🌊 and shore',
            style: const TextStyle(fontSize: 18),
            scaler: TextScaler.noScaling,
            width: 430,
            height: 700,
            margin: 24,
            anchor: 0,
            scrolling: false,
            firstChapter: true,
            lastChapter: true,
            onPosition: (_) {},
            onChapter: (_) {},
            highlightStart: 4,
            highlightEnd: 6,
            preferences: const ReaderPreferences(showHighlights: false),
          ),
        ),
      ),
    );
    await settle(tester);
    expect(
      backgrounds(
        tester
            .widget<SelectableText>(find.byType(SelectableText).first)
            .textSpan,
      ),
      contains(noteColors['yellow']),
    );
    expect(tester.takeException(), isNull);
  });
}
