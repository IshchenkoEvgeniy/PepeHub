import 'dart:convert';

import 'package:drift/drift.dart';

/// Large personal stores kept one row per item instead of one JSON value:
/// the library catalog (a row per card) and the activity and notes journals
/// (a row per slot). A change writes only the rows that changed.
///
/// `store` is the metadata key the value used to live under; a journal keeps
/// its small header (everything except `slots`) in that metadata key.
abstract final class LibraryRows {
  static const table = 'library_rows_v1';

  /// Stores moved to rows. Catalogs and journals of the old connector keep
  /// their metadata values: the legacy migration still reads them there.
  static const catalogStores = {'library-catalog-v1'};
  static const journalStores = {
    'obsidian-activity:personal',
    'obsidian-notes:personal',
  };

  static Future<void> createSchema(GeneratedDatabase db) async {
    await db.customStatement(
      'CREATE TABLE IF NOT EXISTS $table('
      // Rows keep insertion order like the JSON object they replace: an
      // upsert keeps its position, a new item goes last. An explicit INTEGER
      // PRIMARY KEY, because VACUUM may renumber an implicit rowid.
      'seq INTEGER PRIMARY KEY,'
      'store TEXT NOT NULL CHECK(store<>\'\'),'
      'id TEXT NOT NULL CHECK(id<>\'\'),'
      'value TEXT NOT NULL,'
      'UNIQUE(store,id))',
    );
    await db.customStatement(
      'CREATE INDEX IF NOT EXISTS library_rows_order_v1 ON $table(store,seq)',
    );
    // The catalog cache revision, as for the metadata value it replaces.
    await db.customStatement(
      'CREATE TABLE IF NOT EXISTS library_catalog_revisions_v1(key TEXT PRIMARY KEY,revision TEXT NOT NULL)',
    );
    for (final event in ['INSERT', 'UPDATE', 'DELETE']) {
      final row = event == 'DELETE' ? 'OLD' : 'NEW';
      final changed = event == 'UPDATE' ? 'AND OLD.value IS NOT NEW.value' : '';
      await db.customStatement(
        'CREATE TRIGGER IF NOT EXISTS library_rows_revision_${event.toLowerCase()}_v1 '
        'AFTER $event ON $table '
        'WHEN EXISTS(SELECT 1 FROM library_catalog_revisions_v1 WHERE key=$row.store) $changed '
        'BEGIN UPDATE library_catalog_revisions_v1 SET revision=lower(hex(randomblob(16))) '
        'WHERE key=$row.store; END',
      );
      // Same meaning as the metadata trigger for the activity journal: one
      // shared export revision, never every book.
      await db.customStatement(
        'CREATE TRIGGER IF NOT EXISTS library_rows_activity_${event.toLowerCase()}_v1 '
        "AFTER $event ON $table WHEN substr($row.store,1,18)='obsidian-activity:' $changed "
        'BEGIN INSERT INTO library_source_revisions_v1(book_id,revision) '
        "VALUES('#activity',1) ON CONFLICT(book_id) DO UPDATE SET revision=revision+1; END",
      );
    }
  }

  /// Rows of [store] as raw JSON text by id.
  static Future<Map<String, String>> read(
    GeneratedDatabase db,
    String store,
  ) async => {
    for (final row in await db
        .customSelect(
          'SELECT id,value FROM $table WHERE store=? ORDER BY seq',
          variables: [Variable(store)],
        )
        .get())
      row.read<String>('id'): row.read<String>('value'),
  };

  static Future<bool> hasRows(GeneratedDatabase db, String store) async =>
      await db
          .customSelect(
            'SELECT 1 FROM $table WHERE store=? LIMIT 1',
            variables: [Variable(store)],
          )
          .getSingleOrNull() !=
      null;

  /// Writes [next] over [previous]: only changed rows are upserted and only
  /// missing ones deleted. Run inside a transaction.
  static Future<int> write(
    GeneratedDatabase db,
    String store,
    Map<String, String> previous,
    Map<String, String> next,
  ) async {
    var written = 0;
    final removed = [
      for (final id in previous.keys)
        if (!next.containsKey(id)) id,
    ];
    for (var i = 0; i < removed.length; i += 500) {
      final chunk = removed.sublist(i, (i + 500).clamp(0, removed.length));
      await db.customStatement(
        'DELETE FROM $table WHERE store=? AND id IN '
        '(${List.filled(chunk.length, '?').join(',')})',
        [store, ...chunk],
      );
      written += chunk.length;
    }
    for (final e in next.entries) {
      if (previous[e.key] == e.value) continue;
      await db.customStatement(
        'INSERT INTO $table(store,id,value) VALUES(?,?,?) '
        'ON CONFLICT(store,id) DO UPDATE SET value=excluded.value',
        [store, e.key, e.value],
      );
      written++;
    }
    return written;
  }

  /// Moves a catalog value from `metadata` into rows, replacing any rows of
  /// that store. Returns false and leaves the value when it is not a JSON
  /// object: the catalog's loader reports damaged data as before.
  static Future<bool> moveCatalog(
    GeneratedDatabase db,
    String store, {
    String Function(String id, Object? value)? encode,
  }) async {
    final raw = await _meta(db, store);
    if (raw == null) return false;
    final Object? data;
    try {
      data = jsonDecode(raw);
    } on FormatException {
      return false;
    }
    if (data is! Map) return false;
    final previous = await read(db, store);
    await write(db, store, previous, {
      for (final e in data.entries)
        '${e.key}': encode?.call('${e.key}', e.value) ?? jsonEncode(e.value),
    });
    await db.customStatement('DELETE FROM metadata WHERE key=?', [store]);
    return true;
  }

  /// Moves a journal's `slots` from its metadata value into rows; the header
  /// stays in metadata. Returns false when there is nothing to move.
  static Future<bool> moveJournal(GeneratedDatabase db, String store) async {
    final raw = await _meta(db, store);
    if (raw == null) return false;
    final Object? data;
    try {
      data = jsonDecode(raw);
    } on FormatException {
      return false;
    }
    if (data is! Map || data['slots'] is! Map) return false;
    final slots = data.remove('slots') as Map;
    final previous = await read(db, store);
    await write(db, store, previous, {
      for (final e in slots.entries) '${e.key}': jsonEncode(e.value),
    });
    await db.customStatement('UPDATE metadata SET value=? WHERE key=?', [
      jsonEncode(data),
      store,
    ]);
    return true;
  }

  static Future<String?> _meta(GeneratedDatabase db, String key) async =>
      (await db
              .customSelect(
                'SELECT value FROM metadata WHERE key=?',
                variables: [Variable(key)],
              )
              .getSingleOrNull())
          ?.read<String>('value');

  /// Schema version 9: create the table and move the personal stores.
  static Future<void> migrate(GeneratedDatabase db) async {
    await createSchema(db);
    for (final store in catalogStores) {
      await moveCatalog(db, store);
    }
    for (final store in journalStores) {
      await moveJournal(db, store);
    }
  }
}
