import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/recommendations/book_catalog.dart';
import 'package:pepehub/recommendations/recommendation_store.dart';
import 'package:pepehub/ui/recommendations_page.dart';

http.Response response(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

RecommendedBook card(
  String id, {
  String? title,
  String author = '',
  String date = '2026-01-01T00:00:00Z',
  Map<String, int?> categories = const {},
  String notes = 'Personal note',
  String description = '',
  String source = 'manual',
  String sourceId = '',
}) => RecommendedBook(
  id: id,
  notes: notes,
  createdAt: date,
  categories: categories,
  catalog: CatalogBook(
    source: source,
    sourceId: sourceId,
    sourceUrl: '',
    data: {
      'title': title ?? id,
      'authors': [if (author.isNotEmpty) author],
      'description': description,
    },
  ),
);

void main() {
  late AppDatabase db;
  late RecommendationStore store;
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    store = RecommendationStore(Repository(db));
  });
  tearDown(() => db.close());

  void size(WidgetTester tester, Size value) {
    tester.view.physicalSize = value;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  BookCatalog emptyCatalog() => BookCatalog(
    MockClient((_) async => response({'docs': []})),
    interval: Duration.zero,
  );

  Future<void> page(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: RecommendationsPage(store: store, catalog: emptyCatalog()),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('quick categories preserve the live note, metadata and retained ranks', () async {
    final categories = (await store.load()).categories;
    await store.saveBook(
      card('A', categories: {categories[0].id: 7, categories[1].id: 42}),
    );
    // A quick action opened before this edit must not write a stale card back.
    await store.saveBook(
      card(
        'A',
        title: 'Corrected title',
        notes: 'Latest note',
        categories: {categories[0].id: 7, categories[1].id: 42},
      ),
    );
    await store.setBookCategories('A', {categories[0].id, categories[2].id});
    final saved = (await store.load()).books.single;
    expect(saved.notes, 'Latest note');
    expect(saved.catalog.title, 'Corrected title');
    expect(saved.categories, {categories[0].id: 7, categories[2].id: null});
    final before = jsonEncode((await store.load()).toJson());
    await expectLater(
      store.setBookCategories('A', {'missing'}),
      throwsStateError,
    );
    expect(jsonEncode((await store.load()).toJson()), before);
  });

  test(
    'moving and dragging normalize only the selected top atomically',
    () async {
      final categories = (await store.load()).categories;
      final top = categories[0].id, other = categories[1].id;
      for (var i = 0; i < 3; i++) {
        await store.saveBook(
          card('ABC'[i], categories: {top: i + 10, other: 50 - i}),
        );
      }
      await store.saveBook(card('outside', categories: {other: 99}));
      await store.moveInTop(top, 'C', -1);
      var books = {for (final b in (await store.load()).books) b.id: b};
      expect(['A', 'C', 'B'].map((id) => books[id]!.categories[top]), [
        1,
        2,
        3,
      ]);
      await store.reorderTop(top, ['B', 'A', 'C']);
      books = {for (final b in (await store.load()).books) b.id: b};
      expect(['B', 'A', 'C'].map((id) => books[id]!.categories[top]), [
        1,
        2,
        3,
      ]);
      expect(['A', 'B', 'C'].map((id) => books[id]!.categories[other]), [
        50,
        49,
        48,
      ]);
      expect(books['outside']!.categories, {other: 99});
      expect(books['A']!.notes, 'Personal note');
      expect(books['A']!.createdAt, '2026-01-01T00:00:00Z');
      final before = jsonEncode((await store.load()).toJson());
      await expectLater(store.reorderTop(top, ['A', 'B']), throwsStateError);
      await expectLater(
        store.reorderTop(top, ['A', 'A', 'C']),
        throwsStateError,
      );
      expect(jsonEncode((await store.load()).toJson()), before);
    },
  );

  test(
    'catalog emits immutable partial results before a slow provider completes',
    () async {
      final slow = Completer<http.Response>();
      final first = Completer<CatalogSearch>();
      final client = MockClient(
        (request) async => request.url.host == 'inventaire.io'
            ? slow.future
            : response({
                'docs': [
                  {'key': '/works/OL1W', 'title': 'Fast'},
                ],
              }),
      );
      addTearDown(() {
        if (!slow.isCompleted) slow.complete(response({'results': []}));
        client.close();
      });
      final catalog = BookCatalog(client, interval: Duration.zero);
      var finished = false;
      final request = catalog.search(
        'Fast',
        {'inventaire', 'openlibrary'},
        onProgress: (progress) {
          if (!first.isCompleted) first.complete(progress);
        },
      );
      unawaited(request.then((_) => finished = true));
      final partial = await first.future;
      expect(finished, isFalse);
      expect(partial.books.single.title, 'Fast');
      expect(partial.completedSources, {'openlibrary'});
      slow.complete(
        response({
          'results': [
            {'uri': 'wd:Q123', 'label': 'Slow'},
          ],
        }),
      );
      final complete = await request;
      expect(complete.books, hasLength(2));
      expect(complete.completedSources, {'inventaire', 'openlibrary'});
      expect(partial.books, hasLength(1));
      expect(() => partial.books.clear(), throwsUnsupportedError);
    },
  );

  testWidgets(
    'empty category, uncategorized and search states are distinct and reset works',
    (tester) async {
      size(tester, const Size(390, 844));
      final top = (await store.load()).categories.first.id;
      await store.saveBook(card('Book', categories: {top: 1}));
      await page(tester);
      await tester.tap(
        find.widgetWithText(ChoiceChip, 'Советовали друзья (0)'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Подборка пуста'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Без категории'));
      await tester.pumpAndSettle();
      expect(find.text('Нет книг без категории'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Все книги'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '  missing  ');
      await tester.pumpAndSettle();
      expect(find.text('Ничего не найдено'), findsOneWidget);
      await tester.ensureVisible(find.text('Сбросить'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сбросить'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expect(find.text('Book'), findsOneWidget);
      expect((await store.load()).books, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'quick category menu changes membership without opening the editor',
    (tester) async {
      size(tester, const Size(1440, 1000));
      final categories = (await store.load()).categories;
      await store.saveBook(card('A', categories: {categories[0].id: 9}));
      await page(tester);
      await tester.tap(find.byKey(const ValueKey('recommendation-menu-A')));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await tester.tap(find.text('В подборки'));
      await tester.pumpAndSettle();
      expect(find.byType(RecommendationEditor), findsNothing);
      await tester.tap(
        find.byKey(ValueKey('quick-category-${categories[1].id}')),
      );
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      final saved = (await store.load()).books.single;
      expect(saved.categories, {categories[0].id: 9, categories[1].id: null});
      expect(saved.notes, 'Personal note');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'top move menu and real drag gesture persist order only in that category',
    (tester) async {
      size(tester, const Size(1440, 1100));
      final categories = (await store.load()).categories;
      final top = categories[0].id, other = categories[1].id;
      for (var i = 0; i < 3; i++) {
        await store.saveBook(
          card('ABC'[i], categories: {top: i + 1, other: 30 + i}),
        );
      }
      await page(tester);
      await tester.tap(find.text(categories[0].name));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('recommendation-menu-C')));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Поднять'));
      await tester.pumpAndSettle();
      var books = {for (final b in (await store.load()).books) b.id: b};
      expect(['A', 'C', 'B'].map((id) => books[id]!.categories[top]), [
        1,
        2,
        3,
      ]);
      final handles = find.byType(ReorderableDragStartListener);
      expect(handles, findsNWidgets(3));
      final from = tester.getCenter(handles.first);
      final to = Offset(
        from.dx,
        tester
                .getBottomRight(
                  find.byKey(const ValueKey('recommendation-row-B')),
                )
                .dy -
            5,
      );
      final gesture = await tester.startGesture(from);
      await tester.pump();
      for (var step = 1; step <= 12; step++) {
        await gesture.moveTo(from + (to - from) * (step / 12));
        await tester.pump(const Duration(milliseconds: 30));
      }
      await tester.pump(const Duration(milliseconds: 400));
      await gesture.up();
      await tester.pumpAndSettle();
      books = {for (final b in (await store.load()).books) b.id: b};
      expect(['C', 'B', 'A'].map((id) => books[id]!.categories[top]), [
        1,
        2,
        3,
      ]);
      expect(['A', 'B', 'C'].map((id) => books[id]!.categories[other]), [
        30,
        31,
        32,
      ]);
      await tester.enterText(find.byType(TextField), 'A');
      await tester.pumpAndSettle();
      expect(find.byType(ReorderableDragStartListener), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('recent and author sorting do not rewrite any ranks', (
    tester,
  ) async {
    size(tester, const Size(1440, 1100));
    final top = (await store.load()).categories.first.id;
    await store.saveBook(
      card(
        'A',
        author: 'Zebra',
        date: '2026-01-01T00:00:00Z',
        categories: {top: 2},
      ),
    );
    await store.saveBook(
      card(
        'B',
        author: 'Alpha',
        date: '2026-02-01T00:00:00Z',
        categories: {top: 1},
      ),
    );
    await page(tester);
    final before = jsonEncode((await store.load()).toJson());
    await tester.tap(find.byType(DropdownButtonFormField<RecommendationSort>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Недавно добавленные').last);
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('B')).dy,
      lessThan(tester.getTopLeft(find.text('A')).dy),
    );
    await tester.tap(find.byType(DropdownButtonFormField<RecommendationSort>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('По автору').last);
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('B')).dy,
      lessThan(tester.getTopLeft(find.text('A')).dy),
    );
    expect(jsonEncode((await store.load()).toJson()), before);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'mobile tap opens full read-only details before explicit editing',
    (tester) async {
      size(tester, const Size(390, 844));
      final description = List.generate(30, (i) => 'Paragraph $i.').join('\n');
      await store.saveBook(card('Book', description: description));
      await page(tester);
      await tester.ensureVisible(find.text('Book'));
      await tester.tap(find.text('Book'));
      await tester.pumpAndSettle();
      expect(find.byType(RecommendationDetailPage), findsOneWidget);
      expect(find.byType(TextFormField), findsNothing);
      expect(tester.widget<Text>(find.text(description)).maxLines, isNull);
      await tester.ensureVisible(find.text('Редактировать'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Редактировать'));
      await tester.pumpAndSettle();
      expect(find.byType(RecommendationEditor), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('recommendation-title')),
        'Corrected',
      );
      await tester.tap(find.text('Сохранить рекомендацию'));
      await tester.pumpAndSettle();
      expect(find.byType(RecommendationDetailPage), findsOneWidget);
      expect(find.text('Corrected'), findsOneWidget);
      expect((await store.load()).books.single.notes, 'Personal note');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'partial results are selectable while another source is pending and mark saved cards',
    (tester) async {
      size(tester, const Size(390, 844));
      await store.setSources({'inventaire', 'openlibrary'});
      await store.saveBook(
        card(
          'existing',
          title: 'Fast',
          source: 'openlibrary',
          sourceId: '/works/OL1W',
        ),
      );
      final slow = Completer<http.Response>();
      final client = MockClient((request) async {
        if (request.url.host == 'inventaire.io') return slow.future;
        return response(
          request.url.path == '/search.json'
              ? {
                  'docs': [
                    {'key': '/works/OL1W', 'title': 'Fast'},
                  ],
                }
              : {'title': 'Fast', 'description': 'Details'},
        );
      });
      addTearDown(() {
        if (!slow.isCompleted) slow.complete(response({'results': []}));
        client.close();
      });
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
      await tester.enterText(find.byType(TextField), 'Fast');
      await tester.tap(find.text('Искать'));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Inventaire · Ищет…'), findsOneWidget);
      expect(find.textContaining('Уже в подборках'), findsOneWidget);
      await tester.tap(find.widgetWithText(ListTile, 'Fast'));
      await tester.pumpAndSettle();
      expect(find.byType(RecommendationEditor), findsOneWidget);
      expect((await store.load()).books, hasLength(1));
      slow.complete(response({'results': []}));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'retry queries only the failed source and preserves the original search and other results',
    (tester) async {
      size(tester, const Size(390, 844));
      await store.setSources({'inventaire', 'openlibrary'});
      var inventaire = 0, openlibrary = 0;
      final queries = <String?>[];
      final client = MockClient((request) async {
        if (request.url.host == 'inventaire.io') {
          inventaire++;
          queries.add(request.url.queryParameters['search']);
          return inventaire == 1
              ? response({}, 429)
              : response({
                  'results': [
                    {'uri': 'wd:Q123', 'label': 'Recovered'},
                  ],
                });
        }
        openlibrary++;
        return response({
          'docs': [
            {'key': '/works/OL1W', 'title': 'Fast'},
          ],
        });
      });
      addTearDown(client.close);
      await tester.pumpWidget(
        MaterialApp(
          home: RecommendationSearchPage(
            store: store,
            catalog: BookCatalog(client, interval: Duration.zero),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Fast');
      await tester.tap(find.text('Искать'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'Fast'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Changed input');
      await tester.ensureVisible(
        find.byKey(const ValueKey('retry-inventaire')),
      );
      await tester.tap(find.byKey(const ValueKey('retry-inventaire')));
      await tester.pumpAndSettle();
      expect(inventaire, 2);
      expect(openlibrary, 1);
      expect(queries, ['Fast', 'Fast']);
      expect(find.widgetWithText(ListTile, 'Fast'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Recovered'), findsOneWidget);
      expect(find.byKey(const ValueKey('retry-inventaire')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a retry can finish while another provider is pending without reviving its old failure',
    (tester) async {
      size(tester, const Size(390, 844));
      await store.setSources({'inventaire', 'openlibrary'});
      final slow = Completer<http.Response>();
      var calls = 0;
      final client = MockClient((request) async {
        if (request.url.host == 'openlibrary.org') return slow.future;
        calls++;
        if (calls == 1) throw http.ClientException('offline');
        return response({
          'results': [
            {'uri': 'wd:Q123', 'label': 'Recovered'},
          ],
        });
      });
      addTearDown(() {
        if (!slow.isCompleted) slow.complete(response({'docs': []}));
        client.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: RecommendationSearchPage(
            store: store,
            catalog: BookCatalog(client, interval: Duration.zero),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Book');
      await tester.tap(find.text('Искать'));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Open Library · Ищет…'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('retry-inventaire')));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.widgetWithText(ListTile, 'Recovered'), findsOneWidget);
      expect(find.byKey(const ValueKey('retry-inventaire')), findsNothing);
      slow.complete(
        response({
          'docs': [
            {'key': '/works/OL1W', 'title': 'Slow'},
          ],
        }),
      );
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.widgetWithText(ListTile, 'Recovered'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Slow'), findsOneWidget);
      expect(find.byKey(const ValueKey('retry-inventaire')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [360.0, 860.0, 1180.0, 1440.0]) {
    testWidgets('recommendation controls fit width $width with larger text', (
      tester,
    ) async {
      size(tester, Size(width, 1000));
      await store.saveBook(
        card('Book', title: 'A long book title', author: 'An Author'),
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: RecommendationsPage(store: store, catalog: emptyCatalog()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('По названию'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
