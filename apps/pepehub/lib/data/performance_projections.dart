import 'package:drift/drift.dart';

// These are disposable read models. Source metadata, journals and sync formats
// remain intact. Backfill runs once on the database executor, never per shelf.
Future<void> ensurePerformanceProjections(
  GeneratedDatabase db,
) => db.transaction(() async {
  Future<bool> exists(String name) async =>
      await db
          .customSelect(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
            variables: [Variable(name)],
          )
          .getSingleOrNull() !=
      null;
  final shelfExists = await exists('reading_shelf_v1');
  final sessionsExist = await exists('reading_statistics_sessions_v1');
  await db.customStatement(
    'CREATE TABLE IF NOT EXISTS reading_shelf_v1(key TEXT PRIMARY KEY,value TEXT NOT NULL,text_offset INTEGER NOT NULL)',
  );
  await db.customStatement(
    "CREATE TABLE IF NOT EXISTS reading_statistics_sessions_v1(key TEXT PRIMARY KEY,value TEXT NOT NULL,"
    "book_id TEXT GENERATED ALWAYS AS (json_extract(value,'\$.bookId')) STORED,"
    "started_at TEXT GENERATED ALWAYS AS (json_extract(value,'\$.startedAt')) STORED,"
    "start_ms INTEGER GENERATED ALWAYS AS (COALESCE(CAST(ROUND(unixepoch(json_extract(value,'\$.startedAt'),'subsec')*1000) AS INTEGER),0)) STORED,"
    "session_id TEXT GENERATED ALWAYS AS (substr(key,17)) STORED)",
  );
  await db.customStatement(
    'CREATE INDEX IF NOT EXISTS reading_statistics_time_v1 ON reading_statistics_sessions_v1(start_ms,session_id)',
  );
  await ensureReadingSessionBookIndex(db);
  await db.customStatement(
    'CREATE TABLE IF NOT EXISTS library_catalog_revisions_v1(key TEXT PRIMARY KEY,revision TEXT NOT NULL)',
  );
  for (final event in ['INSERT', 'UPDATE', 'DELETE']) {
    final row = event == 'DELETE' ? 'OLD' : 'NEW';
    final changed = event == 'UPDATE' ? 'AND OLD.value IS NOT NEW.value' : '';
    await db.customStatement(
      'CREATE TRIGGER IF NOT EXISTS catalog_revision_${event.toLowerCase()}_v1 AFTER $event ON metadata '
      'WHEN EXISTS(SELECT 1 FROM library_catalog_revisions_v1 WHERE key=$row.key) $changed '
      "BEGIN UPDATE library_catalog_revisions_v1 SET revision=lower(hex(randomblob(16))) WHERE key=$row.key; END",
    );
    for (final (name, prefix, end) in [
      ('shelf', 'reading-index:', 'reading-index;'),
      ('statistics', 'reading-session:', 'reading-session;'),
    ]) {
      final table = name == 'shelf'
          ? 'reading_shelf_v1'
          : 'reading_statistics_sessions_v1';
      final insert = event == 'DELETE'
          ? ''
          : name == 'shelf'
          ? _shelfProjection('i.key=NEW.key')
          : "INSERT INTO $table(key,value) SELECT key,json_remove(value,'\$.events','\$.ranges') FROM metadata WHERE key=NEW.key AND json_valid(value) AND json_type(CASE WHEN json_valid(value) THEN value ELSE '{}' END)='object';";
      await db.customStatement(
        'CREATE TRIGGER IF NOT EXISTS ${name}_projection_${event.toLowerCase()}_v1 AFTER $event ON metadata '
        "WHEN $row.key>='$prefix' AND $row.key<'$end' $changed BEGIN "
        'DELETE FROM $table WHERE key=$row.key; $insert END',
      );
    }
    final readerInsert = event == 'DELETE'
        ? _shelfProjection("i.key='reading-index:'||substr(OLD.key,8)")
        : _shelfProjection("i.key='reading-index:'||substr(NEW.key,8)");
    // Modern bookmarks already carry textOffset: no full index parsing is
    // needed at a checkpoint. Only legacy paragraph bookmarks need resolving.
    if (event != 'DELETE') {
      await db.customStatement(
        'CREATE TRIGGER IF NOT EXISTS shelf_position_${event.toLowerCase()}_v1 AFTER $event ON metadata '
        "WHEN NEW.key>='reader:' AND NEW.key<'reader;' AND json_valid(NEW.value) "
        "AND json_type(NEW.value,'\$.textOffset')='integer' $changed BEGIN "
        "UPDATE reading_shelf_v1 SET text_offset=json_extract(NEW.value,'\$.textOffset') WHERE key='reading-index:'||substr(NEW.key,8); END",
      );
    }
    final legacy = event == 'DELETE'
        ? ''
        : "AND (NOT json_valid(NEW.value) OR json_type(CASE WHEN json_valid(NEW.value) THEN NEW.value ELSE '{}' END,'\$.textOffset') IS NOT 'integer')";
    await db.customStatement(
      'CREATE TRIGGER IF NOT EXISTS shelf_legacy_position_${event.toLowerCase()}_v1 AFTER $event ON metadata '
      "WHEN $row.key>='reader:' AND $row.key<'reader;' $legacy $changed BEGIN $readerInsert END",
    );
  }
  if (!shelfExists) {
    await db.customStatement(
      _shelfProjection("i.key>='reading-index:' AND i.key<'reading-index;'"),
    );
  }
  if (!sessionsExist) {
    await db.customStatement(
      "INSERT INTO reading_statistics_sessions_v1(key,value) SELECT key,json_remove(value,'\$.events','\$.ranges') FROM metadata WHERE key>='reading-session:' AND key<'reading-session;' AND json_valid(value) AND json_type(CASE WHEN json_valid(value) THEN value ELSE '{}' END)='object'",
    );
  }
});

Future<void> ensureReadingSessionBookIndex(GeneratedDatabase db) =>
    db.customStatement(
      'CREATE INDEX IF NOT EXISTS reading_statistics_book_time_v1 ON reading_statistics_sessions_v1(book_id,start_ms,session_id)',
    );

String _shelfProjection(String where) =>
    '''
INSERT INTO reading_shelf_v1
WITH source AS MATERIALIZED (
  SELECT i.key,CASE WHEN json_valid(i.value) THEN i.value ELSE '{}' END AS document,
    CASE WHEN json_valid(p.value) THEN p.value ELSE '{}' END AS position
  FROM metadata i LEFT JOIN metadata p ON p.key='reader:'||substr(i.key,15)
  WHERE $where AND json_valid(i.value) AND json_type(CASE WHEN json_valid(i.value) THEN i.value ELSE '{}' END)='object'
), chapter AS MATERIALIZED (
  SELECT *,MIN(MAX(COALESCE(CAST(json_extract(position,'\$.chapter') AS INTEGER),0),0),
    MAX(COALESCE(json_array_length(document,'\$.starts'),0)-1,0)) AS c FROM source
), paragraph AS MATERIALIZED (
  SELECT *,MIN(MAX(COALESCE(CAST(json_extract(position,'\$.paragraph') AS INTEGER),0),0),
    MAX(COALESCE(json_array_length(document,'\$.paragraphStarts['||c||']'),0)-1,0)) AS p FROM chapter
)
SELECT key,json_remove(document,'\$.paragraphStarts','\$.lengths','\$.text',
  '\$.paragraphs','\$.chapters','\$.pdfPageLengths'),
  COALESCE(CAST(json_extract(position,'\$.textOffset') AS INTEGER),
    COALESCE(CAST(json_extract(document,'\$.paragraphStarts['||c||']['||p||']') AS INTEGER),0)
    +COALESCE(CAST(json_extract(position,'\$.offset') AS INTEGER),0))
FROM paragraph WHERE true ON CONFLICT(key) DO UPDATE SET value=excluded.value,text_offset=excluded.text_offset;
''';
