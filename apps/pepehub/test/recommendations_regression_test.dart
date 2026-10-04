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

http.Response jsonResponse(Object data) => http.Response(
  jsonEncode(data),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
const openLibraryBook = CatalogBook(
  source: 'openlibrary',
  sourceId: '/works/OL1W',
  sourceUrl: 'https://openlibrary.org/works/OL1W',
  data: {
    'title': 'Book',
    'authors': ['Author'],
  },
);

void main() {
  test(
    'Open Library accepts bare work and edition IDs from search responses',
    () async {
      final catalog = BookCatalog(
        MockClient(
          (request) async => jsonResponse(
            request.url.path == '/search.json'
                ? {
                    'docs': [
                      {
                        'key': 'OL1W',
                        'title': 'Book',
                        'editions': {
                          'docs': [
                            {'key': 'OL2M', 'title': 'Book'},
                          ],
                        },
                      },
                    ],
                  }
                : {'title': 'Book', 'key': 'OL2M', 'number_of_pages': 250},
          ),
        ),
        interval: Duration.zero,
      );
      final result = (await catalog.search('Book', {
        'openlibrary',
      })).books.single;
      expect(result.sourceId, '/works/OL1W');
      expect(result.data['editionKey'], '/books/OL2M');
      expect((await catalog.details(result)).data['pages'], 250);
    },
  );

  test(
    'metadata retry updates fetch time without changing personal corrections',
    () {
      final stored = openLibraryBook.withData({
        'title': 'My correction',
        'fetchedAt': 'old',
        'fetchWarnings': ['old failure'],
      });
      final fresh = stored.fillMissing(
        openLibraryBook.withData({
          'title': 'Source title',
          'fetchedAt': 'new',
          'fetchWarnings': [],
        }),
      );
      expect(fresh.title, 'My correction');
      expect(fresh.data['fetchedAt'], 'new');
      expect(fresh.data['fetchWarnings'], isEmpty);
    },
  );

  testWidgets(
    'two save taps before the next frame create only one manual card',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final store = RecommendationStore(Repository(db));
      final shelf = await store.load();
      await tester.pumpWidget(
        MaterialApp(
          home: RecommendationEditor(
            store: store,
            catalog: BookCatalog(
              MockClient((_) async => jsonResponse({})),
              interval: Duration.zero,
            ),
            categories: shelf.categories,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('recommendation-title')),
        'Book',
      );
      await tester.tap(find.text('Сохранить рекомендацию'));
      await tester.tap(find.text('Сохранить рекомендацию'));
      await tester.pumpAndSettle();
      expect((await store.load()).books, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );
  test('a colon in a book title still performs a title search', () async {
    final queries = <String?>[];
    final catalog = BookCatalog(
      MockClient((request) async {
        queries.add(request.url.queryParameters['q']);
        return jsonResponse({
          'docs': [
            {'key': '/works/OL1W', 'title': 'Dune: Messiah'},
          ],
        });
      }),
      interval: Duration.zero,
    );
    final result = await catalog.search('Dune: Messiah', {'openlibrary'});
    expect(result.books, hasLength(1));
    expect(queries, ['Dune: Messiah']);
  });

  test('a successful retry clears obsolete source warnings', () async {
    var genreCalls = 0;
    final catalog = BookCatalog(
      MockClient((request) async {
        if (request.url.path.endsWith('/genres')) {
          genreCalls++;
          return genreCalls == 1
              ? http.Response('', 503)
              : jsonResponse([
                  {'id': 38, 'title': 'Фэнтези'},
                ]);
        }
        return jsonResponse({
          'title': 'Матабар',
          'authorFIO': 'Автор',
          'genreId': 38,
        });
      }),
      interval: Duration.zero,
    );
    const seed = CatalogBook(
      source: 'author.today',
      sourceId: '337592',
      sourceUrl: 'https://author.today/work/337592',
      data: {'title': 'Матабар'},
    );
    final incomplete = await catalog.details(seed);
    expect(incomplete.data['fetchWarnings'], isNotEmpty);
    final recovered = await catalog.details(incomplete);
    expect(recovered.data['genres'], ['Фэнтези']);
    expect(recovered.data['fetchWarnings'], isEmpty);
  });

  for (final source in ['openlibrary', 'inventaire']) {
    test('$source retries a structurally invalid search response', () async {
      var calls = 0;
      final catalog = BookCatalog(
        MockClient((_) async {
          calls++;
          if (calls == 1) {
            return jsonResponse({'error': 'Temporarily unavailable'});
          }
          return source == 'openlibrary'
              ? jsonResponse({
                  'docs': [
                    {'key': '/works/OL1W', 'title': 'Book'},
                  ],
                })
              : jsonResponse({
                  'results': [
                    {'uri': 'wd:Q1', 'label': 'Book'},
                  ],
                });
        }),
        interval: Duration.zero,
      );
      expect((await catalog.search('Book', {source})).failures, isNotEmpty);
      expect((await catalog.search('Book', {source})).books, hasLength(1));
      expect(calls, 2);
    });
  }

  test('an invalid details response is reported and can be retried', () async {
    var calls = 0;
    final catalog = BookCatalog(
      MockClient((_) async {
        calls++;
        return jsonResponse(
          calls == 1
              ? {'error': 'Temporarily unavailable'}
              : {'title': 'Book', 'description': 'Recovered'},
        );
      }),
      interval: Duration.zero,
    );
    await expectLater(catalog.details(openLibraryBook), throwsFormatException);
    expect(
      (await catalog.details(openLibraryBook)).data['description'],
      'Recovered',
    );
    expect(calls, 2);
  });

  test(
    'a work first publication year is not assigned to a selected edition',
    () async {
      final catalog = BookCatalog(
        MockClient((request) async {
          if (request.url.path == '/search.json') {
            return jsonResponse({
              'docs': [
                {
                  'key': '/works/OL1W',
                  'title': 'Book',
                  'first_publish_year': 1954,
                  'author_name': ['Author'],
                  'editions': {
                    'docs': [
                      {'key': '/books/OL2M', 'title': 'Перевод'},
                    ],
                  },
                },
              ],
            });
          }
          return jsonResponse({
            'key': request.url.path.replaceAll('.json', ''),
            'title': 'Перевод',
          });
        }),
        interval: Duration.zero,
      );
      final book = await catalog.details(
        (await catalog.search('Book', {'openlibrary'})).books.single,
      );
      expect(book.data['publicationDate'], isNull);
      expect(book.data['firstPublicationYear'], 1954);
    },
  );

  test('a direct edition link resolves its declared parent work for annotation and authors', () async {
    final catalog = BookCatalog(
      MockClient(
        (request) async => jsonResponse(switch (request.url.path) {
          '/books/OL2M.json' => {
            'key': '/books/OL2M',
            'title': 'Перевод',
            'works': [
              {'key': '/works/OL1W'},
            ],
            'number_of_pages': 450,
          },
          '/works/OL1W.json' => {
            'title': 'Original',
            'description': 'Work annotation',
            'authors': [
              {
                'author': {'key': '/authors/OL3A'},
              },
            ],
          },
          _ => {'name': 'Author'},
        }),
      ),
      interval: Duration.zero,
    );
    final result = await catalog.search('https://openlibrary.org/books/OL2M', {
      'openlibrary',
    });
    expect(result.books.single.data['description'], 'Work annotation');
    expect(result.books.single.authors, ['Author']);
    expect(result.books.single.title, 'Перевод');
    expect(result.books.single.data['pages'], 450);
  });

  testWidgets(
    'linking a manual card preserves author names containing commas',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final store = RecommendationStore(Repository(db));
      await store.setSources({'openlibrary'});
      const book = RecommendedBook(
        id: 'manual',
        catalog: CatalogBook(
          source: 'manual',
          sourceId: '',
          sourceUrl: '',
          data: {
            'title': 'Book',
            'authors': ['Doe, Jane'],
          },
        ),
        notes: 'Personal note',
        categories: {},
        createdAt: 'original',
      );
      await store.saveBook(book);
      final catalog = BookCatalog(
        MockClient(
          (request) async => jsonResponse(
            request.url.path == '/search.json'
                ? {
                    'docs': [
                      {
                        'key': '/works/OL1W',
                        'title': 'Book',
                        'author_name': ['Online author'],
                      },
                    ],
                  }
                : {'title': 'Book', 'description': 'Annotation'},
          ),
        ),
        interval: Duration.zero,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: RecommendationEditor(
            store: store,
            catalog: catalog,
            categories: (await store.load()).categories,
            book: book,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Найти сведения в интернете'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Искать'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'Book'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сохранить рекомендацию'));
      await tester.pumpAndSettle();
      final saved = (await store.load()).books.single;
      expect(saved.catalog.authors, ['Doe, Jane']);
      expect(saved.notes, 'Personal note');
    },
  );

  testWidgets(
    'a details request completing during back animation cannot close the underlying screen',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final store = RecommendationStore(Repository(db));
      await store.setSources({'openlibrary'});
      final details = Completer<http.Response>();
      final catalog = BookCatalog(
        MockClient(
          (request) async => request.url.path == '/search.json'
              ? jsonResponse({
                  'docs': [
                    {
                      'key': '/works/OL1W',
                      'title': 'Book',
                      'author_name': ['Author'],
                    },
                  ],
                })
              : details.future,
        ),
        interval: Duration.zero,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => RecommendationSearchPage(
                      store: store,
                      catalog: catalog,
                    ),
                  ),
                ),
                child: const Text('Underlying screen'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Underlying screen'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Book');
      await tester.tap(find.text('Искать'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'Book'));
      await tester.pump();
      await tester.pageBack();
      details.complete(jsonResponse({'title': 'Book'}));
      await tester.pumpAndSettle();
      expect(find.text('Underlying screen'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
