import 'dart:convert';
import 'dart:isolate';

import 'package:drift/drift.dart' show Variable;

import '../data/library_rows.dart';
import '../data/repository.dart';
import 'models.dart';

Map<String, LibraryEntry> _decodeCatalog(String raw) =>
    (jsonDecode(raw) as Map<String, dynamic>).map(
      (id, value) => MapEntry(
        id,
        LibraryEntry.fromJson(Map<String, dynamic>.from(value as Map)),
      ),
    );
String _encodeCatalog(Map<String, LibraryEntry> entries) =>
    jsonEncode(entries.map((id, entry) => MapEntry(id, entry.toJson())));
Future<T> _catalogWork<T, P>(T Function(P) task, P input) =>
    Isolate.run(() => task(input));
String _encodeEntry(LibraryEntry entry) => jsonEncode(entry.toJson());
Map<String, LibraryEntry> _decodeRows(Map<String, String> rows) => rows.map(
  (id, raw) => MapEntry(
    id,
    LibraryEntry.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map)),
  ),
);
Map<String, String> _encodeRows(Map<String, LibraryEntry> entries) =>
    entries.map((id, entry) => MapEntry(id, _encodeEntry(entry)));

class _CatalogCache {
  final String raw;
  final Map<String, LibraryEntry> entries;
  final String revision;

  /// Raw rows of a row-stored catalog: what the next write compares with.
  final Map<String, String>? rows;
  _CatalogCache(this.raw, this.entries, this.revision, {this.rows});
}

/// Catalog of library cards in the transactional SQLite metadata store.
class LibraryRepository {
  static final _cache = Expando<Map<String, _CatalogCache>>();
  final Repository repository;
  final String namespace;
  final String? storageKey;
  LibraryRepository(this.repository, this.namespace, {this.storageKey});
  String get _key => storageKey ?? 'obsidian-library:$namespace';
  Future<String> _revision() async {
    final row = await repository.db
        .customSelect(
          'SELECT revision FROM library_catalog_revisions_v1 WHERE key=?',
          variables: [Variable(_key)],
        )
        .getSingleOrNull();
    if (row != null) return row.read<String>('revision');
    await repository.db.customStatement(
      'INSERT OR IGNORE INTO library_catalog_revisions_v1 VALUES(?,lower(hex(randomblob(16))))',
      [_key],
    );
    return _revision();
  }

  /// The personal catalog lives one row per card (see [LibraryRows]); the
  /// catalogs of the old connector keep their single metadata value.
  bool get _rows => LibraryRows.catalogStores.contains(_key);

  /// Whether this catalog has ever stored a card.
  Future<bool> stored() async => _rows
      ? await LibraryRows.hasRows(repository.db, _key) ||
            await repository.meta(_key) != null
      : await repository.meta(_key) != null;

  Future<Map<String, LibraryEntry>> entries() async {
    if (_rows) return _rowEntries();
    final revision = await _revision();
    final cache = _cache[repository.db] ??= {};
    final hit = cache[_key];
    if (hit?.revision == revision) {
      return Map.of(hit!.entries);
    }
    final raw = await repository.meta(_key) ?? '{}';
    final data = raw.length < 131072
        ? _decodeCatalog(raw)
        : await _catalogWork(_decodeCatalog, raw);
    cache[_key] = _CatalogCache(raw, Map.of(data), revision);
    return data;
  }

  Future<Map<String, LibraryEntry>> _rowEntries() async {
    var revision = await _revision();
    final cache = _cache[repository.db] ??= {};
    final hit = cache[_key];
    if (hit?.revision == revision && hit!.rows != null) {
      return Map.of(hit.entries);
    }
    // A value written in the old single-value format (an older backup, a
    // restore, a test) is the newest write: move it into rows first. Such a
    // write changes the revision too, so a cache hit never needs this check.
    if (await repository.meta(_key) != null) {
      await repository.db.transaction(
        () => LibraryRows.moveCatalog(
          repository.db,
          _key,
          encode: (_, value) => _encodeEntry(
            LibraryEntry.fromJson(Map<String, dynamic>.from(value as Map)),
          ),
        ),
      );
      revision = await _revision();
    }
    final rows = await LibraryRows.read(repository.db, _key);
    final data = rows.length < 200
        ? _decodeRows(rows)
        : await _catalogWork(_decodeRows, rows);
    cache[_key] = _CatalogCache('', Map.of(data), revision, rows: rows);
    return data;
  }

  Future<void> mutate(
    Future<void> Function(Map<String, LibraryEntry>) action,
  ) => repository.db.transaction(() async {
    final data = await entries();
    if (_rows) {
      final previous = _cache[repository.db]![_key]!.rows!;
      await action(data);
      final encoded = data.length < 100
          ? _encodeRows(data)
          : await _catalogWork(_encodeRows, data);
      // Only changed cards are written: one edit no longer rewrites the
      // whole catalog.
      await LibraryRows.write(repository.db, _key, previous, encoded);
      (_cache[repository.db] ??= {})[_key] = _CatalogCache(
        '',
        Map.of(data),
        await _revision(),
        rows: encoded,
      );
      return;
    }
    final previous = _cache[repository.db]![_key]!.raw;
    await action(data);
    final encoded = data.length < 100
        ? _encodeCatalog(data)
        : await _catalogWork(_encodeCatalog, data);
    if (previous != encoded) {
      await repository.setMeta(_key, encoded);
    }
    (_cache[repository.db] ??= {})[_key] = _CatalogCache(
      encoded,
      Map.of(data),
      await _revision(),
    );
  });
  Future<Map<String, dynamic>?> snapshot() async {
    final raw = await repository.meta('$_key:schema');
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<void> receiveChanges(Map<String, dynamic> page) => mutate((
    entries,
  ) async {
    final snapshot = await this.snapshot();
    if (snapshot == null ||
        snapshot['_indexId'] != page['indexId'] ||
        page['cursor'] is! int ||
        (page['cursor'] as int) < (snapshot['_cursor'] as int? ?? 0) ||
        page['changes'] is! List ||
        page['schema'] is! Map) {
      throw const FormatException('Некорректный индекс библиотеки');
    }
    final changes = page['changes'] as List;
    if (changes.length > 128) {
      throw const FormatException('Слишком большая страница библиотеки');
    }
    final decoded = <({String id, LibraryItem? item})>[];
    final ids = <String>{};
    for (final raw in changes) {
      if (raw is! Map ||
          raw['id'] is! String ||
          !ids.add(raw['id'] as String)) {
        throw const FormatException(
          'Некорректное изменение карточки библиотеки',
        );
      }
      final item = raw['item'] == null
          ? null
          : LibraryItem.fromJson(Map<String, dynamic>.from(raw['item'] as Map));
      if (item != null && item.id != raw['id']) {
        throw const FormatException('ID карточки библиотеки не совпадает');
      }
      decoded.add((id: raw['id'] as String, item: item));
    }
    final remote = {
      for (final item in snapshot['items'] as List)
        (item as Map)['id'] as String: Map<String, dynamic>.from(item),
    };
    for (final change in decoded) {
      final old = entries[change.id];
      if (change.item == null) {
        remote.remove(change.id);
        if (old != null) {
          entries[change.id] = old.operation != null
              ? LibraryEntry(
                  old.item,
                  state: old.state,
                  sourceBookId: old.sourceBookId,
                  message: old.message,
                  operation: old.operation,
                )
              : LibraryEntry(
                  old.item,
                  state: 'removed',
                  sourceBookId: old.sourceBookId,
                  message: 'Карточка больше не входит в библиотеку.',
                );
        }
      } else {
        remote[change.id] = change.item!.toJson();
        entries[change.id] = old?.operation != null
            ? LibraryEntry(
                old!.item,
                state: old.state,
                sourceBookId: old.sourceBookId,
                message: old.message,
                operation: old.operation,
                remote: change.item,
              )
            : LibraryEntry(change.item!, sourceBookId: old?.sourceBookId);
      }
    }
    final schema = Map<String, dynamic>.from(page['schema'] as Map);
    if (schema['version'] != 1 ||
        schema['fields'] is! List ||
        schema['collections'] is! List) {
      throw const FormatException('Некорректная схема библиотеки');
    }
    await repository.setMeta(
      '$_key:schema',
      jsonEncode({
        ...snapshot,
        ...schema,
        'items': remote.values.toList(),
        '_indexId': page['indexId'],
        '_cursor': page['cursor'],
      }),
    );
  });

  Future<void> receive(Map<String, dynamic> snapshot) =>
      mutate((entries) async {
        if (snapshot['version'] != 1 || snapshot['ready'] != true) return;
        final remote = {
          for (final data in snapshot['items'] as List)
            (data as Map)['id'] as String: LibraryItem.fromJson(
              Map<String, dynamic>.from(data),
            ),
        };
        for (final entry in remote.entries) {
          final old = entries[entry.key];
          entries[entry.key] = old?.operation != null
              ? LibraryEntry(
                  old!.item,
                  state: old.state,
                  sourceBookId: old.sourceBookId,
                  message: old.message,
                  operation: old.operation,
                  remote: entry.value,
                )
              : LibraryEntry(entry.value, sourceBookId: old?.sourceBookId);
        }
        for (final id in entries.keys.toList()) {
          final entry = entries[id]!;
          if (!remote.containsKey(id) && entry.operation != null) {
            entries[id] = LibraryEntry(
              entry.item,
              state: entry.state,
              sourceBookId: entry.sourceBookId,
              message: entry.message,
              operation: entry.operation,
            );
          }
          if (!remote.containsKey(id) && entry.operation == null) {
            // Keep the local card for inspection; never resurrect a remotely removed item.
            entries[id] = LibraryEntry(
              entry.item,
              state: 'removed',
              sourceBookId: entry.sourceBookId,
              message: 'Карточка больше не входит в библиотеку.',
            );
          }
        }
        await repository.setMeta('$_key:schema', jsonEncode(snapshot));
      });
  Future<void> receipt(String id, Map<String, dynamic> receipt) =>
      mutate((entries) async {
        final entry = entries[id];
        if (entry == null ||
            entry.operation?['operationId'] != receipt['operationId']) {
          return;
        }
        switch (receipt['status']) {
          case 'applied':
            entries[id] = LibraryEntry(
              entry.item,
              sourceBookId: entry.sourceBookId,
            );
          case 'conflict':
          case 'error':
            entries[id] = LibraryEntry(
              entry.item,
              state: receipt['status'] as String,
              sourceBookId: entry.sourceBookId,
              message: receipt['message'] as String?,
              operation: entry.operation,
              remote: entry.remote,
            );
        }
      });
}
