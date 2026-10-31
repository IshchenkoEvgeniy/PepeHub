import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/library_service.dart';
import 'package:pepehub/library/models.dart';
import 'package:pepehub/main.dart';
import 'package:pepehub/ui/obsidian_library_page.dart';
import 'package:pepehub/ui/shelf_components.dart';

void main() {
  testWidgets('third section opens and restores after restart', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = Repository(db);
    await tester.pumpWidget(PepeHubApp(repository: repo));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Библиотека'));
    await tester.pumpAndSettle();
    expect(find.text('Добавить'), findsOneWidget);
    expect(await repo.meta('library-section'), 'metadata');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.pumpWidget(PepeHubApp(repository: repo));
    await tester.pumpAndSettle();
    expect(find.text('Добавить'), findsOneWidget);
    await tester.tap(find.byTooltip('Книги'));
    await tester.pumpAndSettle();
    expect(await repo.meta('library-section'), 'reading');
    expect(find.text('Подключить Obsidian'), findsNothing);
  });
  testWidgets(
    'authors and genres accept ordinary text instead of requiring JSON',
    (tester) async {
      Map<String, dynamic>? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryMetadataEditor(
            item: const ObsidianLibraryItem(
              id: 'id',
              path: '',
              collectionId: 'book',
              mediaType: 'book',
              values: {
                'Title': 'Книга',
                'Author': <String>[],
                'Genre': <String>[],
              },
              fields: [
                LibraryField('Title', 'title', 'text'),
                LibraryField('Author', 'author', 'list'),
                LibraryField('Genre', 'genre', 'list'),
              ],
            ),
            onSave: (value) async {
              saved = value;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Авторы'),
        'Кирилл Клеванский',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Жанры'),
        'Фэнтези; Приключения',
      );
      await tester.ensureVisible(find.text('Сохранить'));
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(saved!['Author'], ['Кирилл Клеванский']);
      expect(saved!['Genre'], ['Фэнтези', 'Приключения']);
      expect(find.textContaining('FormatException'), findsNothing);
    },
  );
  testWidgets(
    'editor shows blank fields and saves finish date, preserving other values',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final values = <String, dynamic>{
        'Title': 'Книга',
        'End Date': null,
        'Rating': null,
        'Notes': null,
      };
      final item = ObsidianLibraryItem(
        id: 'id',
        path: 'Books/Test.md',
        collectionId: 'book',
        mediaType: 'book',
        values: values,
        fields: const [
          LibraryField('Title', 'title', 'text'),
          LibraryField('End Date', 'endDate', 'text'),
          LibraryField('Rating', 'rating', 'text'),
          LibraryField('Notes', 'notes', 'text'),
        ],
      );
      Map<String, dynamic>? saved;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.4)),
            child: child!,
          ),
          home: LibraryMetadataEditor(
            item: item,
            onSave: (data) async {
              saved = data;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('metadata:End Date')), findsOneWidget);
      expect(find.byKey(const ValueKey('metadata:Rating')), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('metadata:End Date')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('metadata:End Date')),
        '2026-10-03',
      );
      await tester.ensureVisible(find.text('Сохранить'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(saved!['End Date'], '2026-10-03');
      expect(saved!['Rating'], isNull);
      expect(saved!['Notes'], isNull);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('cards distinguish book and audiobook and allow filtering', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final client = http.Client();
    addTearDown(client.close);
    final service = LibraryService(Repository(db), client);
    addTearDown(service.dispose);
    service.entries = [
      for (final type in ['book', 'audiobook'])
        LibraryEntry(
          ObsidianLibraryItem(
            id: type,
            path: '',
            collectionId: 'book',
            mediaType: type,
            values: {'Title': type, 'Status': 'finished'},
            fields: const [
              LibraryField('Title', 'title', 'text'),
              LibraryField('Status', 'status', 'text'),
            ],
          ),
        ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: ObsidianLibraryPage(
          service: service,
          navigation: ShelfNavigation(
            current: PepeSection.library,
            onSelect: (_) {},
            onSettings: () {},
          ),
          onSettings: () {},
        ),
      ),
    );
    expect(find.text('book'), findsOneWidget);
    expect(find.text('audiobook'), findsOneWidget);
    await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'Аудиокниги'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Аудиокниги'));
    await tester.pumpAndSettle();
    expect(find.text('book'), findsNothing);
    expect(find.text('audiobook'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
