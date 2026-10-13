import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/main.dart';
import 'package:pepehub/recommendations/book_catalog.dart';
import 'package:pepehub/recommendations/recommendation_store.dart';
import 'package:pepehub/ui/recommendations_page.dart';

void main() {
  late AppDatabase db;
  late Repository repo;
  late RecommendationStore store;
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = Repository(db);
    store = RecommendationStore(repo);
  });
  tearDown(() => db.close());

  void mobile(WidgetTester tester) {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  BookCatalog emptyCatalog() => BookCatalog(
    MockClient((_) async => http.Response('{}', 200)),
    interval: Duration.zero,
  );

  testWidgets(
    'recommendations are a persistent app section and return to books',
    (tester) async {
      mobile(tester);
      await tester.pumpWidget(PepeHubApp(repository: repo));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Рекомендации'));
      await tester.pumpAndSettle();
      expect(find.text('РЕКОМЕНДАЦИИ'), findsOneWidget);
      expect(await repo.meta('library-section'), 'recommendations');
      await tester.tap(find.byTooltip('Книги'));
      await tester.pumpAndSettle();
      expect(await repo.meta('library-section'), 'reading');
      await tester.pumpWidget(const SizedBox());
      await repo.setMeta('library-section', 'recommendations');
      await tester.pumpWidget(PepeHubApp(repository: repo));
      await tester.pumpAndSettle();
      expect(find.text('РЕКОМЕНДАЦИИ'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'manual card keeps note focus while keyboard changes and saves distinct top positions',
    (tester) async {
      mobile(tester);
      final shelf = await store.load();
      await tester.pumpWidget(
        MaterialApp(
          home: RecommendationsPage(store: store, catalog: emptyCatalog()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Добавить вручную'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('recommendation-title')),
        'Мой будущий роман',
      );
      await tester.enterText(
        find.byKey(const ValueKey('recommendation-authors')),
        'Первый автор, Второй автор',
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('recommendation-notes')),
        220,
        scrollable: find
            .descendant(
              of: find.byType(RecommendationEditor),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.enterText(
        find.byKey(const ValueKey('recommendation-notes')),
        'Хочу прочитать',
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 250);
      await tester.pump();
      final note = tester.widget<TextFormField>(
        find.byKey(const ValueKey('recommendation-notes')),
      );
      expect(note.controller!.text, 'Хочу прочитать');
      expect(tester.binding.focusManager.primaryFocus?.hasFocus, isTrue);
      tester.view.viewInsets = FakeViewPadding.zero;
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      for (var i = 0; i < 2; i++) {
        final checkbox = find.widgetWithText(
          CheckboxListTile,
          shelf.categories[i].name,
        );
        await tester.scrollUntilVisible(
          checkbox,
          180,
          scrollable: find
              .descendant(
                of: find.byType(RecommendationEditor),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.ensureVisible(checkbox);
        await tester.pumpAndSettle();
        await tester.tap(checkbox);
        await tester.pumpAndSettle();
        final rank = find.byKey(ValueKey('rank-${shelf.categories[i].id}'));
        await tester.ensureVisible(rank);
        await tester.enterText(rank, '${i + 1}');
      }
      await tester.tap(find.text('Сохранить рекомендацию'));
      await tester.pumpAndSettle();
      final saved = (await store.load()).books.single;
      expect(saved.notes, 'Хочу прочитать');
      expect(saved.catalog.authors, ['Первый автор', 'Второй автор']);
      expect(saved.categories, {
        shelf.categories[0].id: 1,
        shelf.categories[1].id: 2,
      });
      expect(find.text('Мой будущий роман'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'search loads metadata into a reviewable card before saving and preserves notes on enrichment',
    (tester) async {
      mobile(tester);
      await store.setSources({'openlibrary'});
      final client = MockClient(
        (request) async => http.Response(
          jsonEncode(
            request.url.path == '/search.json'
                ? {
                    'docs': [
                      {
                        'key': '/works/OL1W',
                        'title': 'Found book',
                        'author_name': ['Author'],
                      },
                    ],
                  }
                : {
                    'title': 'Found book',
                    'description': {'value': '<p>Book summary</p>'},
                    'subjects': ['Fantasy'],
                  },
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: RecommendationsPage(
            store: store,
            catalog: BookCatalog(client, interval: Duration.zero),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Найти книгу в интернете'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Found book');
      await tester.tap(find.text('Искать'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'Found book'));
      await tester.pumpAndSettle();
      expect((await store.load()).books, isEmpty);
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('recommendation-description')),
            )
            .controller!
            .text,
        'Book summary',
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('recommendation-notes')),
        200,
        scrollable: find
            .descendant(
              of: find.byType(RecommendationEditor),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.enterText(
        find.byKey(const ValueKey('recommendation-notes')),
        'Друг посоветовал',
      );
      await tester.tap(find.text('Сохранить рекомендацию'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Found book'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Found book'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('recommendation-title')),
        'Моё название',
      );
      await tester.tap(find.text('Заполнить пустые поля из источника'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('recommendation-title')),
            )
            .controller!
            .text,
        'Моё название',
      );
      await tester.tap(find.text('Сохранить рекомендацию'));
      await tester.pumpAndSettle();
      final saved = (await store.load()).books.single;
      expect(saved.catalog.title, 'Моё название');
      expect(saved.notes, 'Друг посоветовал');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('uncategorized filter shows only books without categories', (
    tester,
  ) async {
    mobile(tester);
    final category = (await store.load()).categories.first.id;
    for (final named in ['Без категории', 'С категорией']) {
      await store.saveBook(
        RecommendedBook(
          id: named,
          catalog: CatalogBook(
            source: 'manual',
            sourceId: '',
            sourceUrl: '',
            data: {'title': named},
          ),
          notes: '',
          categories: named == 'С категорией' ? {category: null} : {},
          createdAt: '',
        ),
      );
    }
    await tester.pumpWidget(
      MaterialApp(
        home: RecommendationsPage(store: store, catalog: emptyCatalog()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Без категории'));
    await tester.pumpAndSettle();
    expect(find.text('С категорией'), findsNothing);
    expect(find.text('Без категории'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
