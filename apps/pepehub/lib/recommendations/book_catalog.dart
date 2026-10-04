import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;

import 'recommendation_store.dart';

class CatalogSearch {
  final List<CatalogBook> books;
  final Map<String, String> failures;
  const CatalogSearch(this.books, this.failures);
}

String catalogText(dynamic value) {
  if (value is Map) value = value['value'];
  if (value is! String) return '';
  final document = html.parse(
    value
        .substring(0, value.length.clamp(0, 100000))
        .replaceAll(
          RegExp(r'<\s*(?:br\s*/?|/p|/div)\s*>', caseSensitive: false),
          '\n',
        ),
  );
  for (final node in document.querySelectorAll('script,style')) {
    node.remove();
  }
  return (document.body?.text ?? '')
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r'\n\s*\n\s*\n+'), '\n\n')
      .trim();
}

int? _positive(dynamic value) {
  final number = int.tryParse('$value');
  return number != null && number > 0 ? number : null;
}

/// Bounded public requests, a small memory cache, and serial pacing per host.
/// A failed provider does not turn the whole search into a failure.
class CatalogTransport {
  final http.Client client;
  final Duration interval;
  final Map<String, Future<void>> _queues = {};
  final Map<String, DateTime> _started = {};
  final Map<String, ({DateTime time, String body})> _cache = {};
  int _cacheBytes = 0;
  void invalidate(Uri uri) {
    final removed = _cache.remove(uri.toString());
    if (removed != null) _cacheBytes -= removed.body.length * 2;
  }

  CatalogTransport(
    this.client, {
    this.interval = const Duration(milliseconds: 1100),
  });

  Future<String> get(Uri uri, {bool guest = false}) async {
    final cached = _cache[uri.toString()];
    if (cached != null &&
        DateTime.now().difference(cached.time) < const Duration(hours: 12)) {
      return cached.body;
    }
    final previous = _queues[uri.host] ?? Future<void>.value();
    final request = previous.then((_) async {
      final last = _started[uri.host];
      if (last != null) {
        final wait = interval - DateTime.now().difference(last);
        if (wait > Duration.zero) await Future<void>.delayed(wait);
      }
      _started[uri.host] = DateTime.now();
      return _request(uri, guest: guest);
    });
    _queues[uri.host] = request.then<void>((_) {}, onError: (Object _) {});
    return request;
  }

  Future<String> _request(Uri uri, {required bool guest}) async {
    final abort = Completer<void>();
    final request =
        http.AbortableRequest('GET', uri, abortTrigger: abort.future)
          ..headers.addAll({
            'User-Agent':
                'PepeHub/0.18 (+https://github.com/IshchenkoEvgeniy/PepeHub)',
            'Accept': uri.host == 'author.today'
                ? 'text/html'
                : 'application/json',
            if (guest) 'Authorization': 'Bearer guest',
          });
    try {
      return await (() async {
        final response = await client.send(request);
        if (response.statusCode != 200) {
          await response.stream.listen((_) {}).cancel();
          if (response.statusCode == 429) {
            throw StateError('Лимит запросов. Повторите поиск позже.');
          }
          if (response.statusCode == 404) {
            throw StateError('Карточка не найдена в источнике');
          }
          throw StateError('Источник недоступен (HTTP ${response.statusCode})');
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > 8 * 1024 * 1024) {
            throw StateError('Слишком большой ответ источника');
          }
          bytes.add(chunk);
        }
        final body = utf8.decode(bytes.takeBytes());
        invalidate(uri);
        if (body.length * 2 <= 12 * 1024 * 1024) {
          while (_cache.isNotEmpty &&
              (_cache.length >= 80 ||
                  _cacheBytes + body.length * 2 > 12 * 1024 * 1024)) {
            invalidate(Uri.parse(_cache.keys.first));
          }
          _cache[uri.toString()] = (time: DateTime.now(), body: body);
          _cacheBytes += body.length * 2;
        }
        return body;
      })().timeout(const Duration(seconds: 25));
    } finally {
      if (!abort.isCompleted) abort.complete();
    }
  }

  Future<Map<String, dynamic>> json(Uri uri, {bool guest = false}) async {
    try {
      return Map<String, dynamic>.from(
        jsonDecode(await get(uri, guest: guest)) as Map,
      );
    } catch (_) {
      invalidate(uri);
      rethrow;
    }
  }

  Future<List<dynamic>> list(Uri uri, {bool guest = false}) async {
    try {
      return jsonDecode(await get(uri, guest: guest)) as List;
    } catch (_) {
      invalidate(uri);
      rethrow;
    }
  }
}

class BookCatalog {
  final CatalogTransport transport;
  BookCatalog(
    http.Client client, {
    Duration interval = const Duration(milliseconds: 1100),
  }) : transport = CatalogTransport(client, interval: interval);

  Future<Map<String, dynamic>> _checkedJson(
    Uri uri,
    bool Function(Map<String, dynamic>) valid,
    String message, {
    bool guest = false,
  }) async {
    final value = await transport.json(uri, guest: guest);
    if (!valid(value)) {
      transport.invalidate(uri);
      throw FormatException(message);
    }
    return value;
  }

  Future<Map<String, dynamic>> _titledJson(Uri uri, {bool guest = false}) =>
      _checkedJson(
        uri,
        (value) => catalogText(value['title']).isNotEmpty,
        'Изменилась структура карточки источника',
        guest: guest,
      );

  String? _openLibraryKey(dynamic value, String kind, String suffix) {
    if (value is! String) return null;
    final key = value.startsWith('/') ? value : '/$kind/$value';
    return RegExp('^/$kind/OL\\d+$suffix\$').hasMatch(key) ? key : null;
  }

  Future<T?> _optional<T>(
    String label,
    List<String> warnings,
    Future<T> Function() request,
  ) async {
    try {
      return await request();
    } catch (e) {
      warnings.add('$label: ${_message(e)}');
      return null;
    }
  }

  Future<CatalogSearch> search(String query, Set<String> sources) async {
    query = query.trim();
    if (query.length < 2 || query.length > 300) {
      throw ArgumentError('Введите от 2 до 300 символов');
    }
    final books = <CatalogBook>[];
    final failures = <String, String>{};
    await Future.wait(
      sources.where(catalogSources.containsKey).map((source) async {
        try {
          final results = await switch (source) {
            'inventaire' => _inventaireSearch(query),
            'openlibrary' => _openLibrarySearch(query),
            _ => _authorSearch(query),
          };
          books.addAll(results);
        } catch (error) {
          failures[source] = _message(error);
        }
      }),
    );
    // Deterministic order even when the providers finish in a different order.
    books.sort((a, b) {
      final exactA = a.title.toLowerCase() == query.toLowerCase();
      final exactB = b.title.toLowerCase() == query.toLowerCase();
      if (exactA != exactB) return exactA ? -1 : 1;
      final source = catalogSources.keys
          .toList()
          .indexOf(a.source)
          .compareTo(catalogSources.keys.toList().indexOf(b.source));
      return source != 0 ? source : a.title.compareTo(b.title);
    });
    return CatalogSearch(books, failures);
  }

  Future<CatalogBook> details(CatalogBook book) async {
    final full = await switch (book.source) {
      'inventaire' => _inventaireDetails(book),
      'openlibrary' => _openLibraryDetails(book),
      'author.today' => _authorDetails(book.sourceId),
      _ => Future<CatalogBook>.value(book),
    };
    // Detail payloads sometimes omit an image or title present in search.
    final merged = full.fillMissing(book);
    return merged.withData({
      ...merged.data,
      'fetchWarnings': strings(full.data['fetchWarnings']),
      if (full.data.containsKey('sourceUpdatedAt'))
        'sourceUpdatedAt': full.data['sourceUpdatedAt'],
      'fetchedAt': DateTime.now().toUtc().toIso8601String(),
    });
  }

  bool _isLink(String query) =>
      RegExp(r'^[a-z][a-z\d+.-]*://', caseSensitive: false).hasMatch(query);
  Future<List<CatalogBook>> _authorSearch(String query) async {
    if (_isLink(query)) {
      final uri = Uri.tryParse(query);
      final id = uri?.host == 'author.today'
          ? RegExp(r'^/work/(\d+)/?$').firstMatch(uri!.path)?.group(1)
          : null;
      return id == null ? [] : [await _authorDetails(id)];
    }
    final uri = Uri.https('author.today', '/search', {
      'q': query,
      'category': 'works',
    });
    final body = await transport.get(uri);
    final document = html.parse(body);
    final found = <String, CatalogBook>{};
    for (final card in document.querySelectorAll('.bookcard, .book-row')) {
      final anchor = card.querySelector('.bookcard-title a, .book-title a');
      final id = RegExp(r'^/work/(\d+)$')
          .firstMatch(anchor?.attributes['href'] ?? '')
          ?.group(1);
      final title = catalogText(anchor?.text);
      if (id == null || title.isEmpty) continue;
      final image = card.querySelector('.cover-image img');
      found[id] = CatalogBook(
        source: 'author.today',
        sourceId: id,
        sourceUrl: 'https://author.today/work/$id',
        data: {
          'title': title,
          'authors': card
              .querySelectorAll('.bookcard-authors a, .book-author a')
              .map((a) => catalogText(a.text))
              .toSet()
              .toList(),
          'coverUrl': safeWebUrl(
            image?.attributes['data-src'] ?? image?.attributes['src'],
          ),
        },
      );
      if (found.length >= 12) break;
    }
    if (found.isEmpty &&
        (document.querySelector('input[name="q"]') == null ||
            body.toLowerCase().contains('cf-chl-'))) {
      transport.invalidate(uri);
      throw StateError(
        'Поиск сайта недоступен. Можно вставить ссылку author.today/work/…',
      );
    }
    return found.values.toList();
  }

  Future<CatalogBook> _authorDetails(String id) async {
    if (!RegExp(r'^\d+$').hasMatch(id)) {
      throw const FormatException('Неверный ID Author.Today');
    }
    final value = await _titledJson(
      Uri.https('api.author.today', '/v1/work/$id/details', {
        'recommendationsCount': '0',
      }),
      guest: true,
    );
    final warnings = <String>[];
    final rawGenres =
        await _optional(
          'Жанры',
          warnings,
          () => transport.list(
            Uri.https('api.author.today', '/v1/work/genres'),
            guest: true,
          ),
        ) ??
        [];
    final genreNames = {
      for (final g in rawGenres.whereType<Map>())
        '${g['id']}': catalogText(g['title']),
    };
    return CatalogBook(
      source: 'author.today',
      sourceId: id,
      sourceUrl: 'https://author.today/work/$id',
      data: {
        'title': catalogText(value['title']),
        'authors': [
          ...strings(value['authorFIO']),
          ...strings(value['coAuthorFIO']),
          ...strings(value['secondCoAuthorFIO']),
        ],
        'coverUrl': safeWebUrl(value['coverUrl']),
        'description': catalogText(value['annotation']),
        'genres': [
          for (final g in [
            value['genreId'],
            value['firstSubGenreId'],
            value['secondSubGenreId'],
            ...value['genres'] as List? ?? [],
          ])
            if (genreNames['$g'] != null) genreNames['$g'],
        ],
        'tags': strings(value['tags']),
        'series': catalogText(value['seriesTitle']),
        'seriesNumber': value['seriesWorkNumber'],
        'textLength': _positive(value['textLength']),
        'publicationDate': value['publishTime'],
        'publicationFinished': value['isFinished'],
        'publicationCompletedAt': value['finishTime'],
        'sourceUpdatedAt': value['lastUpdateTime'],
        'format': value['format'],
        'language': 'ru',
        'fetchWarnings': warnings,
      },
    );
  }

  Future<List<CatalogBook>> _inventaireSearch(String query) async {
    if (_isLink(query)) return [];
    final value = await _checkedJson(
      Uri.https('inventaire.io', '/api/search', {
        'types': 'works',
        'search': query,
        'lang': 'ru',
        'limit': '12',
      }),
      (value) => value['results'] is List,
      'Изменилась структура поиска Inventaire',
    );
    return [
      for (final row in (value['results'] as List? ?? []).whereType<Map>())
        if (_validEntity('${row['uri']}') &&
            catalogText(row['label']).isNotEmpty)
          CatalogBook(
            source: 'inventaire',
            sourceId: row['uri'] as String,
            sourceUrl: 'https://inventaire.io/entity/${row['uri']}',
            data: {
              'title': catalogText(row['label']),
              'shortDescription': catalogText(row['description']),
              'coverUrl': safeWebUrl(
                row['image'],
                base: Uri.https('inventaire.io'),
              ),
            },
          ),
    ];
  }

  bool _validEntity(String id) =>
      RegExp(r'^(wd:Q\d+|inv:[a-f\d]{32}|isbn:[\dXx-]+)$').hasMatch(id);
  Future<Map<String, dynamic>> _entities(List<String> uris) async {
    if (uris.any((id) => !_validEntity(id))) {
      throw const FormatException('Неверный ID Inventaire');
    }
    final response = await _checkedJson(
      Uri.https('inventaire.io', '/api/entities/by-uris', {
        'uris': uris.join('|'),
        'lang': 'ru',
      }),
      (value) => value['entities'] is Map,
      'Изменилась структура сущностей Inventaire',
    );
    return Map<String, dynamic>.from(response['entities'] as Map? ?? {});
  }

  String _label(dynamic entity) {
    final labels = entity is Map ? entity['labels'] : null;
    if (labels is! Map) return '';
    return catalogText(
      labels['ru'] ?? labels['en'] ?? labels.values.firstOrNull,
    );
  }

  Future<CatalogBook> _inventaireDetails(CatalogBook book) async {
    final entities = await _entities([book.sourceId]);
    final entity =
        entities[book.sourceId] as Map? ?? entities.values.firstOrNull as Map?;
    if (entity == null) throw StateError('Карточка не найдена в Inventaire');
    final claims = entity['claims'] as Map? ?? {};
    List<String> refs(String key) =>
        strings(claims[key]).where(_validEntity).toList();
    final authorIds = refs('wdt:P50'),
        seriesIds = refs('wdt:P179'),
        genreIds = refs('wdt:P136');
    final relatives = {
      ...authorIds,
      ...seriesIds,
      ...genreIds,
    }.take(30).toList();
    final warnings = <String>[];
    final labels = relatives.isEmpty
        ? <String, dynamic>{}
        : await _optional(
                'Авторы, цикл и жанры',
                warnings,
                () => _entities(relatives),
              ) ??
              {};
    List<String> names(List<String> ids) =>
        ids.map((id) => _label(labels[id])).where((s) => s.isNotEmpty).toList();
    final cover = entity['image'];
    final data = <String, dynamic>{
      'title': _label(entity),
      'authors': names(authorIds),
      'genres': names(genreIds),
      'series': names(seriesIds).join(' · '),
      'publicationDate': strings(claims['wdt:P577']).firstOrNull,
      'coverUrl': safeWebUrl(
        cover is Map ? cover['url'] : cover,
        base: Uri.https('inventaire.io'),
      ),
      'isbn': strings(claims['wdt:P212']),
      'pages': _positive((claims['wdt:P1104'] as List?)?.firstOrNull),
      'fetchWarnings': warnings,
    };
    final olId = strings(claims['wdt:P648']).firstOrNull;
    if (olId != null && RegExp(r'^OL\d+W$').hasMatch(olId)) {
      // A declared work identifier is safe to enrich; a matching title alone is not.
      final work = await _optional(
        'Аннотация Open Library',
        warnings,
        () => _titledJson(Uri.https('openlibrary.org', '/works/$olId.json')),
      );
      if (work != null) {
        data['description'] = catalogText(work['description']);
        data['openLibraryWork'] = olId;
      }
    }
    return book.withData(data);
  }

  Future<List<CatalogBook>> _openLibrarySearch(String query) async {
    if (_isLink(query)) {
      final uri = Uri.tryParse(query);
      if (uri?.host != 'openlibrary.org') return [];
      final match = RegExp(r'^/(works/OL\d+W|books/OL\d+M)(?:/[^/]*)?$')
          .firstMatch(uri!.path);
      if (match == null) return [];
      final path = '/${match[1]}';
      final seed = CatalogBook(
        source: 'openlibrary',
        sourceId: path,
        sourceUrl: 'https://openlibrary.org$path',
        data: const {},
      );
      return [await _openLibraryDetails(seed)];
    }
    final value = await _checkedJson(
      Uri.https('openlibrary.org', '/search.json', {
        'q': query,
        'lang': 'ru',
        'limit': '12',
        'fields': 'key,title,author_name,cover_i,first_publish_year,subject,editions,editions.key,editions.title,editions.language',
      }),
      (value) => value['docs'] is List,
      'Изменилась структура поиска Open Library',
    );
    final found = <CatalogBook>[];
    for (final row in (value['docs'] as List? ?? []).whereType<Map>()) {
      final key = _openLibraryKey(row['key'], 'works', 'W');
      if (key == null) continue;
      final edition =
          (row['editions'] is Map ? row['editions']['docs'] as List? : null)
              ?.whereType<Map>()
              .firstOrNull;
      final editionId = _openLibraryKey(edition?['key'], 'books', 'M');
      found.add(
        CatalogBook(
          source: 'openlibrary',
          sourceId: key,
          sourceUrl: 'https://openlibrary.org$key',
          data: {
            'title': catalogText(edition?['title'] ?? row['title']),
            'originalTitle': catalogText(row['title']),
            'authors': strings(row['author_name']),
            'genres': strings(row['subject']),
            'firstPublicationYear': row['first_publish_year'],
            'coverUrl': _positive(row['cover_i']) == null
                ? null
                : 'https://covers.openlibrary.org/b/id/${row['cover_i']}-L.jpg?default=false',
            'editionKey': ?editionId,
            'language': strings(edition?['language']).join(', '),
          },
        ),
      );
    }
    return found;
  }

  Future<CatalogBook> _openLibraryDetails(CatalogBook book) async {
    if (!RegExp(r'^/(works/OL\d+W|books/OL\d+M)$').hasMatch(book.sourceId)) {
      throw const FormatException('Неверный ID Open Library');
    }
    final record = await _titledJson(
      Uri.https('openlibrary.org', '${book.sourceId}.json'),
    );
    final warnings = <String>[];
    final directEdition = book.sourceId.startsWith('/books/');
    Map<String, dynamic> work = directEdition ? {} : record;
    Map<String, dynamic> edition = directEdition ? record : {};
    final editionKey = directEdition
        ? book.sourceId
        : _openLibraryKey(book.data['editionKey'], 'books', 'M');
    if (directEdition) {
      final references = record['works'] as List? ?? [];
      // Only follow an explicit, unambiguous parent relation, never a similar title.
      if (references.length == 1 && references.single is Map) {
        final key = _openLibraryKey(
          (references.single as Map)['key'],
          'works',
          'W',
        );
        if (key != null) {
          work =
              await _optional(
                'Сведения произведения',
                warnings,
                () => _titledJson(Uri.https('openlibrary.org', '$key.json')),
              ) ??
              {};
        }
      }
    } else if (editionKey != null) {
      edition =
          await _optional(
            'Данные выбранного издания',
            warnings,
            () => _titledJson(Uri.https('openlibrary.org', '$editionKey.json')),
          ) ??
          {};
    }
    final data = <String, dynamic>{
      'title': catalogText(edition['title'] ?? work['title']),
      'description': catalogText(edition['description']).isNotEmpty
          ? catalogText(edition['description'])
          : catalogText(work['description']),
      'genres': strings(work['subjects'] ?? edition['subjects']),
      'fetchWarnings': warnings,
    };
    final cover = (work['covers'] as List?)
        ?.where((v) => _positive(v) != null)
        .firstOrNull;
    if (cover != null) {
      data['coverUrl'] =
          'https://covers.openlibrary.org/b/id/$cover-L.jpg?default=false';
    }
    if (edition.isNotEmpty) {
      final editionCover = (edition['covers'] as List?)
          ?.where((v) => _positive(v) != null)
          .firstOrNull;
      if (editionCover != null) {
        data['coverUrl'] =
            'https://covers.openlibrary.org/b/id/$editionCover-L.jpg?default=false';
      }
      data.addAll({
        'title': catalogText(edition['title']),
        'editionKey':
            _openLibraryKey(edition['key'], 'books', 'M') ?? editionKey,
        'pages': _positive(edition['number_of_pages']),
        'isbn': [
          ...strings(edition['isbn_13']),
          ...strings(edition['isbn_10']),
        ],
        'publisher': strings(edition['publishers']).join(', '),
        'publicationDate': edition['publish_date'],
        'language': (edition['languages'] as List? ?? [])
            .whereType<Map>()
            .map((l) => '${l['key']}'.split('/').last)
            .join(', '),
      });
      if (data['description'] == '') {
        data['description'] = catalogText(edition['description']);
      }
    }
    if (book.authors.isEmpty) {
      final authors = <String>[];
      for (final ref
          in (edition['authors'] as List? ?? work['authors'] as List? ?? [])
              .whereType<Map>()
              .take(4)) {
        final key = ref['author'] is Map ? ref['author']['key'] : ref['key'];
        if (key is! String || !RegExp(r'^/authors/OL\d+A$').hasMatch(key)) {
          continue;
        }
        final author = await _optional(
          'Автор',
          warnings,
          () => transport.json(Uri.https('openlibrary.org', '$key.json')),
        );
        final name = catalogText(author?['name']);
        if (name.isNotEmpty) authors.add(name);
      }
      data['authors'] = authors;
    }
    return book.withData(data);
  }
}

String _message(Object error) => error is TimeoutException
    ? 'Источник не ответил вовремя. Повторите позже.'
    : error.toString().replaceFirst(
        RegExp(r'^(Bad state|Invalid argument\(s\)?|FormatException):\s*'),
        '',
      );
