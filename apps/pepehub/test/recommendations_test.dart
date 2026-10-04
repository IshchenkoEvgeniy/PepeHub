import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/recommendations/book_catalog.dart';
import 'package:pepehub/recommendations/recommendation_store.dart';

http.Response response(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

const seed = CatalogBook(
  source: 'inventaire',
  sourceId: 'wd:Q123',
  sourceUrl: 'https://inventaire.io/entity/wd:Q123',
  data: {
    'title': 'Книга',
    'authors': ['Автор'],
  },
);

void main() {
  group('curated shelf', () {
    late AppDatabase db;
    late Repository repo;
    late RecommendationStore store;
    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      repo = Repository(db);
      store = RecommendationStore(repo);
    });
    tearDown(() => db.close());
    test(
      'defaults are created once and changes never enter the reading outbox',
      () async {
        final first = await store.load();
        expect(first.categories.length, 3);
        expect(
          (await store.load()).categories.map((c) => c.id),
          first.categories.map((c) => c.id),
        );
        await store.saveCategory('Мой топ');
        expect((await store.load()).categories.length, 4);
        expect(await repo.pendingCount(), 0);
        expect(await repo.records('book'), isEmpty);
      },
    );
    test('multiple categories own distinct ranks; deleting a category retains notes and books', () async {
      final shelf = await store.load();
      final a = shelf.categories[0].id, b = shelf.categories[1].id;
      await store.saveBook(
        RecommendedBook(
          id: 'one',
          catalog: seed,
          notes: 'Совет от друга',
          categories: {a: 2, b: 1},
          createdAt: '2026-10-03',
        ),
      );
      await store.saveCategory('Новый топ', id: b);
      await store.deleteCategory(a);
      final saved = (await store.load()).books.single;
      expect(saved.categories, {b: 1});
      expect(saved.notes, 'Совет от друга');
      expect(
        (await store.load()).categories.firstWhere((c) => c.id == b).name,
        'Новый топ',
      );
      await store.deleteCategory(b);
      expect((await store.load()).books.single.categories, isEmpty);
    });
    test('enrichment preserves corrections, notes, ranks, identifiers and timestamps', () async {
      final category = (await store.load()).categories.first.id;
      await store.saveBook(
        RecommendedBook(
          id: 'one',
          catalog: seed.withData({
            'title': 'Моё название',
            'authors': ['Мой автор'],
            'description': '',
            'coverUrl': 'https://example.com/local.jpg',
          }),
          notes: 'Личная заметка',
          categories: {category: 4},
          createdAt: 'original',
        ),
      );
      await store.fillMissing(
        'one',
        seed.withData({
          'title': 'Онлайн название',
          'authors': ['Онлайн автор'],
          'description': 'Описание',
          'coverUrl': 'https://example.com/remote.jpg',
          'pages': 300,
        }),
      );
      final book = (await store.load()).books.single;
      expect(book.catalog.title, 'Моё название');
      expect(book.catalog.authors, ['Мой автор']);
      expect(book.catalog.data['description'], 'Описание');
      expect(book.catalog.coverUrl, 'https://example.com/local.jpg');
      expect(book.notes, 'Личная заметка');
      expect(book.categories, {category: 4});
      expect(book.createdAt, 'original');
    });
    test('duplicates use source identifiers, not ambiguous titles', () async {
      await store.saveBook(
        const RecommendedBook(
          id: 'one',
          catalog: seed,
          notes: '',
          categories: {},
          createdAt: '',
        ),
      );
      await expectLater(
        store.saveBook(
          const RecommendedBook(
            id: 'two',
            catalog: seed,
            notes: '',
            categories: {},
            createdAt: '',
          ),
        ),
        throwsStateError,
      );
      await store.saveBook(
        RecommendedBook(
          id: 'two',
          catalog: CatalogBook(
            source: seed.source,
            sourceId: 'wd:Q124',
            sourceUrl: seed.sourceUrl,
            data: seed.data,
          ),
          notes: '',
          categories: {},
          createdAt: '',
        ),
      );
      expect((await store.load()).books.length, 2);
    });
    test('invalid rank, missing category, blank title and duplicate category fail atomically', () async {
      final category = (await store.load()).categories.first;
      await expectLater(
        store.saveCategory('  ${category.name.toUpperCase()} '),
        throwsStateError,
      );
      for (final categories in [
        {category.id: 0},
        {'unknown': 1},
      ]) {
        await expectLater(
          store.saveBook(
            RecommendedBook(
              id: 'one',
              catalog: seed,
              notes: '',
              categories: categories,
              createdAt: '',
            ),
          ),
          throwsA(isA<Error>()),
        );
      }
      await expectLater(
        store.saveBook(
          RecommendedBook(
            id: 'one',
            catalog: seed.withData({'title': ' '}),
            notes: '',
            categories: {},
            createdAt: '',
          ),
        ),
        throwsArgumentError,
      );
      expect((await store.load()).books, isEmpty);
    });
    test(
      'malformed saved data is reported without silently replacing the shelf',
      () async {
        await repo.setMeta(RecommendationStore.storageKey, '{broken');
        await expectLater(store.load(), throwsFormatException);
        expect(await repo.meta(RecommendationStore.storageKey), '{broken');
      },
    );
    test(
      'source choices persist including intentionally disabling all providers',
      () async {
        expect(await store.enabledSources(), catalogSources.keys.toSet());
        await store.setSources({'openlibrary'});
        expect(await RecommendationStore(repo).enabledSources(), {
          'openlibrary',
        });
        await store.setSources({});
        expect(await store.enabledSources(), isEmpty);
      },
    );
    test(
      'independent concurrent saves are serialized without losing a book',
      () async {
        await Future.wait(
          List.generate(
            6,
            (i) => store.saveBook(
              RecommendedBook(
                id: '$i',
                catalog: CatalogBook(
                  source: 'manual',
                  sourceId: '',
                  sourceUrl: '',
                  data: {'title': 'Книга $i'},
                ),
                notes: '',
                categories: {},
                createdAt: '',
              ),
            ),
          ),
        );
        expect((await store.load()).books.length, 6);
      },
    );
  });
  test('books and categories survive a database restart', () async {
    final directory = await Directory.systemTemp.createTemp(
      'pepehub-recommendations-',
    );
    final file = File('${directory.path}/books.sqlite');
    var db = AppDatabase(NativeDatabase(file));
    try {
      final store = RecommendationStore(Repository(db));
      final category = await store.saveCategory('Офлайн');
      await store.saveBook(
        RecommendedBook(
          id: 'offline',
          catalog: seed,
          notes: 'Сохранено',
          categories: {category: 1},
          createdAt: '',
        ),
      );
      await db.close();
      db = AppDatabase(NativeDatabase(file));
      final shelf = await RecommendationStore(Repository(db)).load();
      expect(shelf.books.single.notes, 'Сохранено');
      expect(shelf.categories.last.name, 'Офлайн');
    } finally {
      await db.close();
      await directory.delete(recursive: true);
    }
  });

  group('catalog adapters', () {
    test(
      'an unavailable genre dictionary still retains the Author.Today card',
      () async {
        final catalog = BookCatalog(
          MockClient(
            (request) async => request.url.path.endsWith('/genres')
                ? response({}, 503)
                : response({
                    'title': 'Матабар',
                    'authorFIO': 'Автор',
                    'annotation': 'Аннотация',
                    'genreId': 38,
                  }),
          ),
          interval: Duration.zero,
        );
        final result = await catalog.search(
          'https://author.today/work/337592',
          {'author.today'},
        );
        expect(result.books.single.title, 'Матабар');
        expect(result.books.single.data['description'], 'Аннотация');
        expect(result.books.single.data['fetchWarnings'], isNotEmpty);
      },
    );
    test(
      'failed edition lookup does not lose a work description or invent pages',
      () async {
        final catalog = BookCatalog(
          MockClient(
            (request) async => request.url.path.startsWith('/books/')
                ? response({}, 404)
                : response({'title': 'A work', 'description': 'Summary'}),
          ),
          interval: Duration.zero,
        );
        final full = await catalog.details(
          const CatalogBook(
            source: 'openlibrary',
            sourceId: '/works/OL1W',
            sourceUrl: 'https://openlibrary.org/works/OL1W',
            data: {
              'title': 'A work',
              'authors': ['Author'],
              'editionKey': '/books/OL2M',
            },
          ),
        );
        expect(full.data['description'], 'Summary');
        expect(full.data['pages'], isNull);
        expect(full.data['fetchWarnings'], isNotEmpty);
      },
    );
    test(
      'merging different works is rejected even when their titles match',
      () {
        expect(
          () => seed.fillMissing(
            const CatalogBook(
              source: 'inventaire',
              sourceId: 'wd:Q99',
              sourceUrl: '',
              data: {'title': 'Книга'},
            ),
          ),
          throwsArgumentError,
        );
      },
    );
    test(
      'a failing provider does not hide other results or imply no books found',
      () async {
        final catalog = BookCatalog(
          MockClient((request) async {
            if (request.url.host == 'inventaire.io') return response({}, 429);
            if (request.url.host == 'openlibrary.org') {
              return response({
                'docs': [
                  {
                    'key': '/works/OL1W',
                    'title': 'Mistborn',
                    'author_name': ['Sanderson'],
                    'cover_i': 42,
                  },
                ],
              });
            }
            return http.Response(
              '<input name="q"><div class="bookcard"><div class="bookcard-title"><a href="/work/337592">Матабар</a></div><div class="bookcard-authors"><a>Кирилл Клеванский</a></div><div class="cover-image"><img data-src="https://cm.author.today/book.jpg"></div></div>',
              200,
              headers: {'content-type': 'text/html; charset=utf-8'},
            );
          }),
          interval: Duration.zero,
        );
        final result = await catalog.search(
          'Mistborn',
          catalogSources.keys.toSet(),
        );
        expect(result.books.length, 2);
        expect(result.failures['inventaire'], contains('Лимит'));
        expect(result.books.first.source, 'openlibrary');
        expect(result.books.last.authors, ['Кирилл Клеванский']);
      },
    );
    test('Author.Today uses the displayed volume number, sanitized annotation and guest access', () async {
      final headers = <String?>[];
      final catalog = BookCatalog(
        MockClient((request) async {
          headers.add(request.headers['Authorization']);
          return request.url.path.endsWith('/genres')
              ? response([
                  {'id': 38, 'title': 'Боевое фэнтези'},
                ])
              : response({
                  'title': 'Матабар',
                  'authorFIO': 'Кирилл Клеванский',
                  'annotation':
                      '<p>Описание</p><script>bad()</script><p>Продолжение</p>',
                  'seriesTitle': 'Матабар',
                  'seriesOrder': 0,
                  'seriesWorkNumber': 1,
                  'genreId': 38,
                  'firstSubGenreId': 8,
                  'tags': ['магия'],
                  'textLength': 1080861,
                  'isFinished': true,
                  'coverUrl': 'https://cm.author.today/cover.jpg',
                });
        }),
        interval: Duration.zero,
      );
      final result = await catalog.search('https://author.today/work/337592', {
        'author.today',
      });
      final book = await catalog.details(result.books.single);
      expect(book.data['seriesNumber'], 1);
      expect(book.data['genres'], ['Боевое фэнтези']);
      expect(book.data['description'], 'Описание\nПродолжение');
      expect(book.data.containsKey('status'), false);
      expect(book.data['textLength'], 1080861);
      expect(headers, everyElement('Bearer guest'));
    });
    test(
      'Open Library distinguishes work data from the selected edition',
      () async {
        final paths = <String>[];
        final catalog = BookCatalog(
          MockClient((request) async {
            paths.add(request.url.path);
            if (request.url.path == '/search.json') {
              expect(request.url.queryParameters['q'], 'Гарри Поттер');
              expect(request.url.queryParameters['lang'], 'ru');
              return response({
                'docs': [
                  {
                    'key': '/works/OL1W',
                    'title': 'Original',
                    'author_name': ['Author'],
                    'editions': {
                      'docs': [
                        {
                          'key': '/books/OL2M',
                          'title': 'Перевод',
                          'language': ['rus'],
                        },
                      ],
                    },
                  },
                ],
              });
            }
            if (request.url.path == '/works/OL1W.json') {
              return response({
                'title': 'Original',
                'description': {'value': 'Full summary'},
                'subjects': ['Fantasy'],
              });
            }
            return response({
              'key': '/books/OL2M',
              'title': 'Перевод',
              'number_of_pages': 450,
              'isbn_13': ['9781234567897'],
              'publish_date': '2020',
              'publishers': ['Издатель'],
              'languages': [
                {'key': '/languages/rus'},
              ],
            });
          }),
          interval: Duration.zero,
        );
        final book = await catalog.details(
          (await catalog.search('Гарри Поттер', {'openlibrary'})).books.single,
        );
        expect(book.title, 'Перевод');
        expect(book.data['pages'], 450);
        expect(book.data['description'], 'Full summary');
        expect(book.data['isbn'], ['9781234567897']);
        expect(book.data['editionKey'], '/books/OL2M');
        expect(book.data['language'], 'rus');
        expect(paths, ['/search.json', '/works/OL1W.json', '/books/OL2M.json']);
      },
    );
    test('Inventaire resolves author, series and genre claims and retains the search cover', () async {
      final catalog = BookCatalog(
        MockClient((request) async {
          if (request.url.path.endsWith('/search')) {
            return response({
              'results': [
                {'uri': 'wd:Q123', 'label': 'Книга', 'image': '/img/book'},
              ],
            });
          }
          if (request.url.queryParameters['uris'] == 'wd:Q123') {
            return response({
              'entities': {
                'wd:Q123': {
                  'labels': {'ru': 'Книга'},
                  'claims': {
                    'wdt:P50': ['wd:Q1'],
                    'wdt:P179': ['wd:Q2'],
                    'wdt:P136': ['wd:Q3'],
                    'wdt:P577': ['2006-07-17'],
                  },
                },
              },
            });
          }
          return response({
            'entities': {
              'wd:Q1': {
                'labels': {'ru': 'Автор'},
              },
              'wd:Q2': {
                'labels': {'ru': 'Цикл'},
              },
              'wd:Q3': {
                'labels': {'ru': 'Фэнтези'},
              },
            },
          });
        }),
        interval: Duration.zero,
      );
      final book = await catalog.details(
        (await catalog.search('Книга', {'inventaire'})).books.single,
      );
      expect(book.authors, ['Автор']);
      expect(book.data['series'], 'Цикл');
      expect(book.data['genres'], ['Фэнтези']);
      expect(book.coverUrl, 'https://inventaire.io/img/book');
      expect(book.data['publicationDate'], '2006-07-17');
    });
    test(
      'untrusted pasted URLs do not trigger arbitrary network requests',
      () async {
        var calls = 0;
        final catalog = BookCatalog(
          MockClient((_) async {
            calls++;
            return response({});
          }),
          interval: Duration.zero,
        );
        for (final query in [
          'https://localhost/admin',
          'file:///etc/passwd',
          'https://author.today.evil.example/work/12',
        ]) {
          expect(
            (await catalog.search(query, catalogSources.keys.toSet())).books,
            isEmpty,
          );
        }
        expect(calls, 0);
        expect(safeWebUrl('javascript:alert(1)'), isNull);
        expect(safeWebUrl('https://127.0.0.1/cover'), isNull);
        expect(safeWebUrl('https://user:password@example.com/image'), isNull);
      },
    );
    test(
      'successful responses are cached, broken responses are retried',
      () async {
        var calls = 0;
        final transport = CatalogTransport(
          MockClient((_) async {
            calls++;
            return calls == 1 ? response({}, 503) : response({'ok': true});
          }),
          interval: Duration.zero,
        );
        final uri = Uri.https('openlibrary.org', '/search.json');
        await expectLater(transport.json(uri), throwsStateError);
        expect(await transport.json(uri), {'ok': true});
        expect(await transport.json(uri), {'ok': true});
        expect(calls, 2);
      },
    );
    test('HTML descriptions are plain text and source errors cannot corrupt the saved shelf', () {
      expect(
        catalogText({
          'value': '<p>Hello &amp; world</p><style>hidden</style><p>Next</p>',
        }),
        'Hello & world\nNext',
      );
      expect(catalogText(null), '');
    });
  });

  test(
    'live selected providers return searchable and usable metadata',
    () async {
      final client = http.Client();
      addTearDown(client.close);
      final catalog = BookCatalog(client);
      for (final source in catalogSources.keys) {
        final query = source == 'author.today' ? 'Матабар' : 'Mistborn';
        final results = await catalog.search(query, {source});
        expect(
          results.failures,
          isEmpty,
          reason: '$source: ${results.failures}',
        );
        expect(results.books, isNotEmpty, reason: source);
        final full = await catalog.details(results.books.first);
        expect(full.title, isNotEmpty);
        expect(full.authors, isNotEmpty, reason: source);
        expect(full.coverUrl, isNotNull, reason: source);
        if (source == 'author.today') {
          expect(full.data['description'], isNotEmpty);
          expect(full.data['genres'], isNotEmpty);
        }
      }
    },
    skip: Platform.environment['PEPEHUB_LIVE_CATALOG_TEST'] != '1',
  );
}
