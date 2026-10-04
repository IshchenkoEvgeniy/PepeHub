import 'dart:convert';

import '../data/repository.dart';

const catalogSources = {
  'inventaire': 'Inventaire',
  'openlibrary': 'Open Library',
  'author.today': 'Author.Today',
};

class CatalogBook {
  final String source, sourceId, sourceUrl;
  final Map<String, dynamic> data;
  const CatalogBook({
    required this.source,
    required this.sourceId,
    required this.sourceUrl,
    required this.data,
  });
  String get title => data['title'] as String? ?? '';
  List<String> get authors => strings(data['authors']);
  String? get coverUrl => safeWebUrl(data['coverUrl']);
  String get sourceLabel => catalogSources[source] ?? 'Вручную';
  CatalogBook withData(Map<String, dynamic> next) => CatalogBook(
    source: source,
    sourceId: sourceId,
    sourceUrl: sourceUrl,
    data: next,
  );

  /// Enrichment only fills gaps. Local corrections and personal fields survive.
  CatalogBook fillMissing(CatalogBook other) {
    if (source != other.source || sourceId != other.sourceId) {
      throw ArgumentError(
        'Нельзя объединять разные карточки по одному названию',
      );
    }
    return withData({
      ...other.data,
      for (final entry in data.entries)
        if (entry.value != null &&
            entry.value != '' &&
            !(entry.value is List && (entry.value as List).isEmpty))
          entry.key: entry.value,
      // Diagnostics and fetch times describe the latest request, not a manual edit.
      for (final key in ['fetchWarnings', 'fetchedAt', 'sourceUpdatedAt'])
        if (other.data.containsKey(key)) key: other.data[key],
    });
  }

  Map<String, dynamic> toJson() => {
    'source': source,
    'sourceId': sourceId,
    'sourceUrl': sourceUrl,
    'data': data,
  };
  factory CatalogBook.fromJson(Map<String, dynamic> json) => CatalogBook(
    source: json['source'] as String,
    sourceId: json['sourceId'] as String,
    sourceUrl: json['sourceUrl'] as String,
    data: Map<String, dynamic>.from(json['data'] as Map),
  );
}

List<String> strings(dynamic value) => value is List
    ? value
          .whereType<String>()
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList()
    : value is String && value.trim().isNotEmpty
    ? [value.trim()]
    : [];

String? safeWebUrl(dynamic value, {Uri? base}) {
  if (value is! String || value.isEmpty || value.length > 4096) return null;
  Uri? uri;
  try {
    uri = base?.resolve(value) ?? Uri.tryParse(value);
  } on FormatException {
    return null;
  }
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.host == 'localhost' ||
      RegExp(r'^[\d.:]+$').hasMatch(uri.host) ||
      !uri.host.contains('.')) {
    return null;
  }
  return uri.toString();
}

class RecommendationCategory {
  final String id, name;
  const RecommendationCategory(this.id, this.name);
  Map<String, dynamic> toJson() => {'id': id, 'name': name};
  factory RecommendationCategory.fromJson(Map<String, dynamic> value) =>
      RecommendationCategory(value['id'] as String, value['name'] as String);
}

class RecommendedBook {
  final String id, notes, createdAt;
  final CatalogBook catalog;

  /// Each category owns its optional top position; a book can belong to many.
  final Map<String, int?> categories;
  const RecommendedBook({
    required this.id,
    required this.catalog,
    required this.notes,
    required this.categories,
    required this.createdAt,
  });
  RecommendedBook withCatalog(CatalogBook next) => RecommendedBook(
    id: id,
    catalog: next,
    notes: notes,
    categories: categories,
    createdAt: createdAt,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'catalog': catalog.toJson(),
    'notes': notes,
    'categories': categories,
    'createdAt': createdAt,
  };
  factory RecommendedBook.fromJson(Map<String, dynamic> value) =>
      RecommendedBook(
        id: value['id'] as String,
        catalog: CatalogBook.fromJson(
          Map<String, dynamic>.from(value['catalog'] as Map),
        ),
        notes: value['notes'] as String,
        createdAt: value['createdAt'] as String,
        categories: Map<String, int?>.from(value['categories'] as Map),
      );
}

class RecommendationShelf {
  final List<RecommendationCategory> categories;
  final List<RecommendedBook> books;
  const RecommendationShelf(this.categories, this.books);
  Map<String, dynamic> toJson() => {
    'version': 1,
    'categories': categories.map((c) => c.toJson()).toList(),
    'books': books.map((b) => b.toJson()).toList(),
  };
  factory RecommendationShelf.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const FormatException('Неизвестная версия подборок');
    }
    return RecommendationShelf(
      (json['categories'] as List)
          .map(
            (c) => RecommendationCategory.fromJson(
              Map<String, dynamic>.from(c as Map),
            ),
          )
          .toList(),
      (json['books'] as List)
          .map(
            (b) =>
                RecommendedBook.fromJson(Map<String, dynamic>.from(b as Map)),
          )
          .toList(),
    );
  }
}

/// The existing SQLite metadata table provides durable, transactional storage.
/// These curated lists never enter the reading-session or Obsidian-card outbox.
class RecommendationStore {
  final Repository repository;
  static const storageKey = 'recommendations-shelf-v1';
  RecommendationStore(this.repository);
  Future<RecommendationShelf> load() => repository.db.transaction(() async {
    final stored = await repository.meta(storageKey);
    if (stored != null) {
      return RecommendationShelf.fromJson(
        jsonDecode(stored) as Map<String, dynamic>,
      );
    }
    final initial = RecommendationShelf([
      RecommendationCategory(uuid.v4(), 'Хочу прочитать'),
      RecommendationCategory(uuid.v4(), 'Топ магической фантастики'),
      RecommendationCategory(uuid.v4(), 'Советовали друзья'),
    ], []);
    await _write(initial);
    return initial;
  });
  Future<void> _write(RecommendationShelf shelf) =>
      repository.setMeta(storageKey, jsonEncode(shelf.toJson()));
  Future<T> _change<T>(Future<T> Function(RecommendationShelf) action) =>
      repository.db.transaction(() async => action(await load()));

  Future<String> saveCategory(String name, {String? id}) =>
      _change((shelf) async {
        name = name.trim();
        if (name.isEmpty || name.length > 80) {
          throw ArgumentError('Название категории: от 1 до 80 символов');
        }
        if (shelf.categories.any(
          (c) => c.id != id && c.name.toLowerCase() == name.toLowerCase(),
        )) {
          throw StateError('Категория с таким названием уже есть');
        }
        if (id != null && !shelf.categories.any((c) => c.id == id)) {
          throw StateError('Категория удалена');
        }
        final nextId = id ?? uuid.v4();
        final categories = [...shelf.categories];
        final index = categories.indexWhere((c) => c.id == nextId);
        if (index < 0) {
          categories.add(RecommendationCategory(nextId, name));
        } else {
          categories[index] = RecommendationCategory(nextId, name);
        }
        await _write(RecommendationShelf(categories, shelf.books));
        return nextId;
      });
  Future<void> deleteCategory(String id) => _change((shelf) async {
    final books = shelf.books
        .map(
          (b) => RecommendedBook(
            id: b.id,
            catalog: b.catalog,
            notes: b.notes,
            createdAt: b.createdAt,
            categories: {...b.categories}..remove(id),
          ),
        )
        .toList();
    await _write(
      RecommendationShelf(
        shelf.categories.where((c) => c.id != id).toList(),
        books,
      ),
    );
  });
  Future<void> saveBook(RecommendedBook book) => _change((shelf) async {
    if (book.catalog.title.trim().isEmpty) {
      throw ArgumentError('Введите название книги');
    }
    if (book.catalog.sourceId.isNotEmpty &&
        shelf.books.any(
          (b) =>
              b.id != book.id &&
              b.catalog.source == book.catalog.source &&
              b.catalog.sourceId == book.catalog.sourceId,
        )) {
      throw StateError(
        'Эта карточка уже есть в подборках. Откройте её и добавьте категорию.',
      );
    }
    final valid = shelf.categories.map((c) => c.id).toSet();
    if (book.categories.keys.any((id) => !valid.contains(id))) {
      throw StateError('Категория удалена. Откройте карточку снова.');
    }
    if (book.categories.values.any(
      (rank) => rank != null && (rank < 1 || rank > 99999),
    )) {
      throw ArgumentError('Место в топе: от 1 до 99999');
    }
    await _write(
      RecommendationShelf(shelf.categories, [
        ...shelf.books.where((b) => b.id != book.id),
        book,
      ]),
    );
  });
  Future<void> fillMissing(String id, CatalogBook incoming) =>
      _change((shelf) async {
        await _write(
          RecommendationShelf(
            shelf.categories,
            shelf.books
                .map(
                  (b) => b.id == id
                      ? b.withCatalog(b.catalog.fillMissing(incoming))
                      : b,
                )
                .toList(),
          ),
        );
      });
  Future<void> deleteBook(String id) => _change(
    (shelf) async => _write(
      RecommendationShelf(
        shelf.categories,
        shelf.books.where((b) => b.id != id).toList(),
      ),
    ),
  );
  Future<Set<String>> enabledSources() async {
    final raw = await repository.meta('recommendations-sources');
    return raw == null
        ? catalogSources.keys.toSet()
        : strings(jsonDecode(raw)).where(catalogSources.containsKey).toSet();
  }

  Future<void> setSources(Set<String> sources) => repository.setMeta(
    'recommendations-sources',
    jsonEncode(sources.where(catalogSources.containsKey).toList()),
  );
}
