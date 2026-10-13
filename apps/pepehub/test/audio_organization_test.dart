import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/audio/audio_library_repository.dart';
import 'package:pepehub/audio/audio_library_sort.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/reader/reading_library.dart';
import 'package:pepehub/ui/library_page.dart';

LibraryRecord book(String id, String title, String author) =>
    LibraryRecord(id, 'book', 1, false, {
      'title': title,
      'authors': [author],
      'format': 'audio',
      'status': 'planned',
    });

void main() {
  test('audio sorting uses whole-book fractions, known durations and real activity dates', () {
    final books = [
      book('a', 'Alpha', 'Zoe'),
      book('b', 'Beta', 'Anna'),
      book('c', 'Gamma', 'Mike'),
    ];
    final summaries = <String, AudioBookSummary>{
      'a': (total: 10000, position: 1000, speed: 1),
      'b': (total: 2000, position: 1000, speed: 1),
      'c': (total: null, position: null, speed: 1),
    };
    final recent = {'b': DateTime(2026, 9, 20), 'a': DateTime(2026, 9, 21)};
    List<String> sorted(String order) =>
        (books.reversed.toList()..sort(
              (a, b) => compareAudioBooks(
                a,
                b,
                order: order,
                summaries: summaries,
                recent: recent,
              ),
            ))
            .map((b) => b.id)
            .toList();
    expect(sorted('title'), ['a', 'b', 'c']);
    expect(sorted('author'), ['b', 'c', 'a']);
    expect(sorted('progress'), ['b', 'a', 'c']);
    expect(sorted('duration'), ['b', 'a', 'c']);
    expect(sorted('duration-desc'), ['a', 'b', 'c']);
    expect(sorted('recent'), ['a', 'b', 'c']);
    summaries['a'] = (total: 2000, position: 1000, speed: 1);
    expect(sorted('progress'), ['a', 'b', 'c']);
  });

  testWidgets(
    'audio favorites and collections persist, combine filters and stay separate from books',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = Repository(db), library = ReadingLibrary(Repository(db));
      for (final b in [
        book('a', 'Alpha audio', 'Zoe'),
        book('b', 'Beta audio', 'Anna'),
        book('c', 'Aardvark audio', 'Boris'),
      ]) {
        await repo.put('book', b.id, b.payload!);
      }
      await repo.put('book', 'text', {
        'title': 'Text book',
        'authors': <String>[],
        'format': 'txt',
        'status': 'planned',
      });
      await library.update('reading-collection:same', {'name': 'Reading only'});
      await library.update('reading-book:text', {
        'favorite': true,
        'collections': ['same'],
      });
      await library.update('audio-collection:same', {'name': 'Audio only'});
      await library.update('audio-book:b', {
        'collections': ['same'],
      });
      await repo.setMeta('reading-sort', 'series');
      await db.customStatement('INSERT INTO audio_editions VALUES(?,?,1)', [
        'edition',
        'a',
      ]);
      await db.customStatement('INSERT INTO audio_resources VALUES(?,?,?)', [
        'hash',
        '/original/book.mp3',
        10,
      ]);
      await db.customStatement('INSERT INTO audio_tracks VALUES(?,?,?,?,?,?)', [
        'track',
        'edition',
        'hash',
        0,
        'Chapter',
        2000,
      ]);
      await db.customStatement(
        'INSERT INTO audio_progress VALUES(?,?,?,?,?,?)',
        ['edition', 'track', 800, 1, 1.0, '2026-09-21T12:00:00.000Z'],
      );
      expect(
        (await AudioLibraryRepository(db).lastPlayed())['a'],
        DateTime.utc(2026, 9, 21, 12),
      );
      Future<void> settle() => tester.pumpAndSettle();
      Future<void> tapVisible(Finder finder) async {
        await tester.ensureVisible(finder);
        await settle();
        await tester.tap(finder);
      }

      Future<void> bookMenu(String label) async {
        await tapVisible(find.byTooltip('Действия с книгой').first);
        await settle();
        await tester.tap(find.text(label));
        await settle();
      }

      Future<void> switchSection(String title) async {
        await tester.tap(find.byTooltip(title));
        await settle();
      }

      await tester.pumpWidget(MaterialApp(home: LibraryPage(repository: repo)));
      await settle();
      await tester.scrollUntilVisible(
        find.text('Alpha audio'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await bookMenu('В избранное');
      expect(find.text('★ Alpha audio'), findsOneWidget);
      await tester.tap(find.text('Избранное'));
      await settle();
      expect(find.text('Beta audio'), findsNothing);
      await bookMenu('Коллекции книги');
      expect(find.text('Reading only'), findsNothing);
      await tester.tap(find.text('Создать коллекцию'));
      await settle();
      await tester.enterText(find.byType(TextField), 'В дороге');
      await tester.tap(find.text('Сохранить'));
      await settle();
      final groups = await library.entries('audio-collection:');
      final created = groups.entries
          .singleWhere((e) => e.value['name'] == 'В дороге')
          .key;
      expect((await library.value('audio-book:a'))['collections'], [created]);
      // A book can belong to several collections, without affecting favorite.
      await tester.tap(
        find.descendant(
          of: find.ancestor(
            of: find.text('Audio only'),
            matching: find.byType(ListTile),
          ),
          matching: find.byType(Checkbox),
        ),
      );
      await settle();
      expect(
        (await library.value('audio-book:a'))['collections'],
        contains('same'),
      );
      await tester.tapAt(const Offset(5, 50));
      await settle();
      await tester.tap(find.text('Все коллекции').first);
      await settle();
      await tester.tap(find.text('В дороге').last);
      await settle();
      expect(find.text('★ Alpha audio'), findsOneWidget);
      expect(find.text('Beta audio'), findsNothing);
      await switchSection('Книги');
      expect(find.text('★ Text book'), findsOneWidget);
      expect(find.text('Audio only'), findsNothing);
      expect(
        tester.widget<FilterChip>(find.byType(FilterChip).first).selected,
        false,
      );
      await switchSection('Аудиокниги');
      await tester.tap(find.byTooltip('Сортировка аудиокниг'));
      await settle();
      await tester.tap(
        find.ancestor(
          of: find.text('По автору'),
          matching: find.byType(CheckedPopupMenuItem<String>),
        ),
      );
      await settle();
      expect(await repo.meta('audio-sort'), 'author');
      expect(await repo.meta('reading-sort'), 'series');
      expect(find.text('Сейчас слушаю'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Beta audio')).dy,
        lessThan(tester.getTopLeft(find.text('Aardvark audio')).dy),
      );
      // Recreate the screen: favorites, memberships and sort must survive.
      await tester.pumpWidget(const SizedBox());
      await settle();
      await tester.pumpWidget(MaterialApp(home: LibraryPage(repository: repo)));
      await settle();
      await tester.scrollUntilVisible(
        find.text('★ Alpha audio'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('★ Alpha audio'), findsOneWidget);
      expect(find.text('Сейчас слушаю'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Beta audio')).dy,
        lessThan(tester.getTopLeft(find.text('Aardvark audio')).dy),
      );
      await tester.tap(find.text('Коллекции'));
      await settle();
      final row = find.ancestor(
        of: find.text('В дороге'),
        matching: find.byType(ListTile),
      );
      await tester.tap(
        find.descendant(
          of: row,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await settle();
      await tester.tap(find.text('Переименовать'));
      await settle();
      await tester.enterText(find.byType(TextField), 'Поездки');
      await tester.tap(find.text('Сохранить'));
      await settle();
      expect(
        (await library.value('audio-collection:$created'))['name'],
        'Поездки',
      );
      final audioRow = find.ancestor(
        of: find.text('Audio only'),
        matching: find.byType(ListTile),
      );
      await tester.tap(
        find.descendant(
          of: audioRow,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await settle();
      await tester.tap(find.text('Удалить коллекцию'));
      await settle();
      expect(await repo.meta('audio-collection:same'), isNull);
      expect(
        (await library.value('reading-collection:same'))['name'],
        'Reading only',
      );
      expect((await library.value('audio-book:a'))['favorite'], true);
      expect((await library.value('audio-book:a'))['collections'], [created]);
      expect((await library.value('audio-book:b'))['collections'], isEmpty);
      expect((await library.value('reading-book:text'))['collections'], [
        'same',
      ]);
      expect(
        (await db
                .customSelect('SELECT position_ms FROM audio_progress')
                .getSingle())
            .read<int>('position_ms'),
        800,
      );
      expect((await repo.records('book')).length, 4);
      await tester.tapAt(const Offset(5, 50));
      await settle();
      await tester.tap(find.text('Избранное'));
      await settle();
      await bookMenu('Убрать из избранного');
      expect(find.text('Ничего не найдено'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    },
  );
}
