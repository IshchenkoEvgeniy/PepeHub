import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/reader/reading_library.dart';
import 'package:pepehub/ui/library_page.dart';
import 'package:pepehub/ui/shelf_book_details.dart';

List<String> cardTitles(WidgetTester tester) => [
  for (final element
      in find
          .byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith('book-card:'),
          )
          .evaluate())
    tester
        .widgetList<Text>(
          find.descendant(
            of: find.byWidget(element.widget),
            matching: find.byType(Text),
          ),
        )
        .first
        .data!
        .replaceFirst('★ ', ''),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('shelf book labels', () {
    test('remaining reading time uses the measured speed', () {
      expect(
        textRemainingLabel(length: 120000, fraction: 0, rate: 1000),
        '≈ 2 ч чтения',
      );
      expect(
        textRemainingLabel(length: 120000, fraction: .75, rate: 1000),
        'Осталось ≈ 30 мин',
      );
      expect(
        textRemainingLabel(length: 100000, fraction: .1, rate: 1000),
        'Осталось ≈ 1 ч 30 мин',
      );
      expect(textRemainingLabel(length: 0, fraction: .1, rate: 1000), isNull);
      expect(textRemainingLabel(length: 9, fraction: 1, rate: 1000), isNull);
      expect(textRemainingLabel(length: 9, fraction: 0, rate: null), isNull);
    });

    test('a tiny speed sample is not trusted', () {
      expect(readingRate(59000, 5000), isNull);
      expect(readingRate(60000, 200), isNull);
      expect(readingRate(120000, 2000), 1000);
    });

    test('last opened date reads naturally', () {
      final now = DateTime(2026, 11, 7, 18);
      expect(shelfDay(DateTime(2026, 11, 7, 9), now), 'сегодня');
      expect(shelfDay(DateTime(2026, 11, 6, 23), now), 'вчера');
      expect(shelfDay(DateTime(2026, 11, 3), now), '3 нояб.');
      expect(shelfDay(DateTime(2025, 5, 1), now), '1 мая 2025');
      expect(lastOpenedLabel('broken', now), isNull);
      expect(lastOpenedLabel(null, now), isNull);
    });
  });

  test('speed samples are summed per book in SQL', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = Repository(db);
    Future<void> session(String id, Map<String, Object?> value) =>
        repo.setMeta('reading-session:$id', jsonEncode(value));
    final base = {
      'bookId': 'b',
      'startedAt': '2026-11-01T10:00:00.000Z',
      'speedVersion': 1,
      'speedMoves': 3,
    };
    await session('1', {...base, 'speedActiveMs': 60000, 'speedChars': 900});
    await session('2', {...base, 'speedActiveMs': 30000, 'speedChars': 600});
    // Manual entries and legacy rows without speed tracking are ignored.
    await session('3', {
      ...base,
      'source': 'manual',
      'speedActiveMs': 60000,
      'speedChars': 99999,
    });
    await session('4', {
      ...base,
      'speedVersion': null,
      'speedActiveMs': 60000,
      'speedChars': 99999,
    });
    final samples = await ReadingLibrary(repo).speedSamples();
    expect(samples['b'], (ms: 90000, chars: 1500));
  });

  testWidgets(
    'shelf sorts by size and finish date, both directions keep unknown last',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final repo = Repository(db);
      addTearDown(db.close);
      for (final title in ['Средняя', 'Короткая', 'Длинная', 'Без размера']) {
        await repo.addBook(title, 'Автор', 'txt');
      }
      final books = {for (final b in await repo.records('book')) b.title: b};
      final lib = ReadingLibrary(repo);
      Future<void> overrides(String title, Map<String, Object?> value) =>
          lib.update('reading-book:${books[title]!.id}', {'overrides': value});
      await overrides('Короткая', {
        'length': 1000,
        'status': 'finished',
        'finishedAt': '2026-03-01T10:00:00.000Z',
      });
      await overrides('Средняя', {
        'length': 50000,
        'status': 'finished',
        'finishedAt': '2026-10-01T10:00:00.000Z',
      });
      await overrides('Длинная', {'length': 900000});
      await repo.setMeta('library-section', 'reading');
      await repo.setMeta('reading-sort', 'length');
      tester.view.physicalSize = const Size(500, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: LibraryPage(repository: repo)));
      await tester.pumpAndSettle();
      expect(cardTitles(tester), [
        'Короткая',
        'Средняя',
        'Длинная',
        'Без размера',
      ]);
      await repo.setMeta('reading-sort-reverse', '1');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(MaterialApp(home: LibraryPage(repository: repo)));
      await tester.pumpAndSettle();
      expect(cardTitles(tester), [
        'Длинная',
        'Средняя',
        'Короткая',
        'Без размера',
      ]);
      await repo.setMeta('reading-sort-reverse', '0');
      await repo.setMeta('reading-sort', 'finished');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(MaterialApp(home: LibraryPage(repository: repo)));
      await tester.pumpAndSettle();
      final finished = cardTitles(tester);
      expect(finished.take(2), ['Средняя', 'Короткая']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'started books stay in the list in the same order with and without filters',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final repo = Repository(db);
      addTearDown(db.close);
      for (final title in ['Первая', 'Вторая', 'Третья', 'Новая']) {
        await repo.addBook(title, 'Автор', 'txt');
      }
      final books = {for (final b in await repo.records('book')) b.title: b};
      final lib = ReadingLibrary(repo);
      for (final title in ['Первая', 'Вторая', 'Третья']) {
        await lib.update('reading-book:${books[title]!.id}', {
          'overrides': {'status': 'active', 'length': 120000},
        });
      }
      await repo.setMeta(
        'reading-session:s',
        jsonEncode({
          'bookId': books['Первая']!.id,
          'startedAt': '2026-11-01T10:00:00.000Z',
          'speedVersion': 1,
          'speedMoves': 5,
          'speedActiveMs': 120000,
          'speedChars': 2000,
        }),
      );
      await repo.setMeta('library-section', 'reading');
      tester.view.physicalSize = const Size(500, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: LibraryPage(repository: repo)));
      await tester.pumpAndSettle();
      // No "now reading" block: it pulled started books out of the list
      // only while no filter was set, so the shelf changed per folder.
      expect(find.text('Сейчас читаю'), findsNothing);
      expect(find.byKey(const ValueKey('continue-ribbon')), findsNothing);
      final all = cardTitles(tester);
      expect(all.toSet(), {'Первая', 'Вторая', 'Третья', 'Новая'});
      // 1000 characters a minute: 120 000 characters take two hours.
      expect(find.textContaining('≈ 2 ч чтения'), findsWidgets);
      expect(find.text('Читаю'), findsWidgets);
      expect(find.text('В процессе'), findsNothing);
      // A filter narrows the same list; resetting it restores the same order.
      await tester.tap(find.byKey(const ValueKey('shelf-filters')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('filter-favorites')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Готово'));
      await tester.pumpAndSettle();
      expect(find.text('Ничего не найдено'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('shelf-reset-filters')));
      await tester.pumpAndSettle();
      expect(cardTitles(tester), all);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
