import 'package:drift/drift.dart';

/// SQL expressions shared by the schema and by the queries that must repeat
/// them verbatim: SQLite uses an expression or partial index only for
/// identical terms. Changing an indexed expression needs a new migration step.
abstract final class SchemaSql {
  /// Listening start of an `audio_event` in epoch milliseconds.
  static const audioEventAt =
      "CAST(ROUND(unixepoch(json_extract(payload,'\$.at'),'subsec')*1000) AS INTEGER)";

  /// Listening end of an `audio_event` in epoch milliseconds.
  static const audioEventEnd =
      "($audioEventAt+COALESCE(CAST(json_extract(payload,'\$.wallMs') AS INTEGER),0))";

  /// Rows covered by `records_audio_day_v2`. A query must contain this exact
  /// condition to use the index; damaged payloads are never indexed.
  static const audioEventRows = "type='audio_event' AND json_valid(payload)";
  static const audioEventBook = "json_extract(payload,'\$.bookId')";
  static const audioEventDay = "json_extract(payload,'\$.localDay')";

  /// Predicates shared by video indexes and readers. Invalid JSON must never
  /// prevent the mandatory schema migration or a later indexed write.
  static const videoLessonRows =
      "type='video_lesson' AND deleted=0 AND json_valid(payload)";
  static const videoIntervalRows =
      "type='video_interval' AND deleted=0 AND json_valid(payload)";
  static const videoAnnotationRows =
      "type='video_annotation' AND deleted=0 AND json_valid(payload)";
  static const videoSubtitleRows =
      "type='video_subtitle' AND deleted=0 AND json_valid(payload)";

  /// Start of a `video_interval` in epoch milliseconds.
  static const videoIntervalStart =
      "COALESCE(json_extract(payload,'\$.startEpochMs'),"
      "CAST(ROUND(unixepoch(json_extract(payload,'\$.startedAt'),'subsec')*1000) AS INTEGER))";

  /// Reading notes live in `metadata`; a damaged value is indexed as `{}`.
  static const noteJson =
      "CASE WHEN json_valid(value) THEN value ELSE '{}' END";
}

/// Schema version 4: every table, index and trigger that feature modules used
/// to create lazily on first use. Version 3 databases may already contain some
/// of them, so each statement is idempotent, and read models are backfilled
/// only when their table is new — existing totals are never counted twice.
/// Runs inside the migration transaction: a failure leaves version 3 intact.
Future<void> createFeatureSchema(GeneratedDatabase db) async {
  await _readingSpans(db);
  await _audioDailyTotals(db);
  await _recordIndexes(db);
  await _peerSync(db);
  await _cloudTransport(db);
  await _exportRevisions(db);
}

/// Invalidate only the affected book's exported source metadata. Sync's own
/// queue/baseline writes do not invalidate it, and unchanged upserts are cheap.
Future<void> _exportRevisions(GeneratedDatabase db) async {
  await db.customStatement(
    'CREATE TABLE IF NOT EXISTS library_source_revisions_v1('
    'book_id TEXT PRIMARY KEY NOT NULL,revision INTEGER NOT NULL)',
  );
  String bump(String select) =>
      'INSERT INTO library_source_revisions_v1(book_id,revision) '
      "SELECT book_id,1 FROM ($select) WHERE book_id IS NOT NULL AND book_id<>'' "
      'ON CONFLICT(book_id) DO UPDATE SET revision=revision+1;';
  String meta(String row) {
    final selects = <String>[];
    for (final prefix in [
      'reading-book:',
      'reading-dates:',
      'audio-book:',
      'audio-status-override:',
    ]) {
      selects.add(
        "SELECT substr($row.key,${prefix.length + 1}) AS book_id WHERE substr($row.key,1,${prefix.length})='$prefix'",
      );
    }
    selects.add(
      "SELECT json_extract(CASE WHEN json_valid($row.value) THEN $row.value ELSE '{}' END,'\$.bookId') AS book_id "
      "WHERE substr($row.key,1,16)='reading-session:'",
    );
    for (final prefix in ['reader:', 'reading-index:']) {
      selects.add(
        "SELECT book_id FROM local_assets WHERE sha256=substr($row.key,${prefix.length + 1}) "
        "AND substr($row.key,1,${prefix.length})='$prefix'",
      );
    }
    selects.add(
      "SELECT e.book_id FROM audio_resources r JOIN audio_tracks t ON t.asset_hash=r.sha256 "
      "JOIN audio_editions e ON e.id=t.edition_id WHERE r.sha256=substr($row.key,16) "
      "AND substr($row.key,1,15)='audio-metadata:'",
    );
    selects.add(
      "SELECT id AS book_id FROM records WHERE type='book' "
      "AND substr($row.key,1,18)='obsidian-activity:'",
    );
    return selects.join(' UNION ');
  }

  String record(String row) =>
      "SELECT CASE WHEN $row.type='book' THEN $row.id ELSE "
      "json_extract(CASE WHEN json_valid($row.payload) THEN $row.payload ELSE '{}' END,'\$.bookId') END AS book_id "
      "WHERE $row.type IN ('book','audio_event','session')";
  for (final (table, select) in <(String, String Function(String))>[
    ('records', record),
    ('metadata', meta),
    ('local_assets', (row) => 'SELECT $row.book_id'),
    ('audio_editions', (row) => 'SELECT $row.book_id AS book_id'),
    (
      'audio_progress',
      (row) => 'SELECT book_id FROM audio_editions WHERE id=$row.edition_id',
    ),
    (
      'audio_tracks',
      (row) => 'SELECT book_id FROM audio_editions WHERE id=$row.edition_id',
    ),
    (
      'audio_resources',
      (row) =>
          'SELECT e.book_id FROM audio_tracks t JOIN audio_editions e ON e.id=t.edition_id WHERE t.asset_hash=$row.sha256',
    ),
  ]) {
    for (final (event, rows) in [
      ('INSERT', ['NEW']),
      ('UPDATE', ['OLD', 'NEW']),
      ('DELETE', ['OLD']),
    ]) {
      final unchanged = table == 'metadata' && event == 'UPDATE'
          ? 'WHEN OLD.value IS NOT NEW.value'
          : '';
      await db.customStatement(
        'CREATE TRIGGER IF NOT EXISTS export_${table}_${event.toLowerCase()}_v1 '
        'AFTER $event ON $table $unchanged BEGIN ${bump(rows.map(select).join(' UNION '))} END',
      );
    }
  }
}

Future<bool> _tableExists(GeneratedDatabase db, String name) async =>
    await db
        .customSelect(
          "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
          variables: [Variable(name)],
        )
        .getSingleOrNull() !=
    null;

/// Numeric projection of reading spans, kept current by metadata triggers.
Future<void> _readingSpans(GeneratedDatabase db) async {
  final fresh = !await _tableExists(db, 'reading_span_index_v1');
  await db.customStatement(
    'CREATE TABLE IF NOT EXISTS reading_span_index_v1('
    'session_key TEXT NOT NULL, ordinal INTEGER NOT NULL, start_us INTEGER NOT NULL, '
    'finish_us INTEGER NOT NULL, active_ms INTEGER NOT NULL, PRIMARY KEY(session_key,ordinal))',
  );
  await db.customStatement(
    'CREATE INDEX IF NOT EXISTS reading_span_finish_v1 '
    'ON reading_span_index_v1(finish_us)',
  );
  await db.customStatement(
    'CREATE TABLE IF NOT EXISTS reading_span_dirty_v1('
    'session_key TEXT PRIMARY KEY NOT NULL)',
  );
  for (final (kind, event, sources) in [
    ('insert', 'AFTER INSERT', ['NEW']),
    ('update', 'AFTER UPDATE', ['OLD', 'NEW']),
    ('delete', 'AFTER DELETE', ['OLD']),
  ]) {
    final enqueue = sources
        .map(
          (source) =>
              'INSERT INTO reading_span_dirty_v1(session_key) SELECT $source.key '
              "WHERE $source.key>='reading-session:' AND $source.key<'reading-session;' "
              'AND NOT EXISTS(SELECT 1 FROM reading_span_dirty_v1 WHERE session_key=$source.key);',
        )
        .join();
    await db.customStatement(
      'CREATE TRIGGER IF NOT EXISTS reading_span_${kind}_v1 '
      '$event ON metadata BEGIN $enqueue END',
    );
  }
  if (fresh) {
    await db.customStatement(
      'INSERT OR IGNORE INTO reading_span_dirty_v1 '
      "SELECT key FROM metadata WHERE key>='reading-session:' AND key<'reading-session;'",
    );
  }
}

String _audioField(String row, String field) =>
    "json_extract(CASE WHEN json_valid(${row}payload) THEN ${row}payload ELSE '{}' END,'\$.$field')";

String _audioCounted(String row) =>
    "${row}type='audio_event' AND ${row}deleted=0 AND "
    "${_audioField(row, 'kind')} IN ('listen','journal') AND ${_audioField(row, 'wallMs')}>0 AND "
    "typeof(${_audioField(row, 'bookId')})='text' AND typeof(${_audioField(row, 'localDay')})='text' AND "
    "(${_audioField(row, 'kind')}='journal' OR ${_audioField(row, 'endMs')}>${_audioField(row, 'positionMs')})";

/// Listening totals per day and book. Triggers cover native recording, edits,
/// tombstones, restores and peer/Obsidian writes in the same transaction.
Future<void> _audioDailyTotals(GeneratedDatabase db) async {
  final fresh = !await _tableExists(db, 'audio_daily_totals_v1');
  await db.customStatement(
    'CREATE TABLE IF NOT EXISTS audio_daily_totals_v1 '
    '(day TEXT NOT NULL,book_id TEXT NOT NULL,wall_ms INTEGER NOT NULL,PRIMARY KEY(day,book_id))',
  );
  String add(String row) =>
      'INSERT INTO audio_daily_totals_v1(day,book_id,wall_ms) '
      "SELECT ${_audioField(row, 'localDay')},${_audioField(row, 'bookId')},CAST(${_audioField(row, 'wallMs')} AS INTEGER) "
      'WHERE ${_audioCounted(row)} '
      'ON CONFLICT(day,book_id) DO UPDATE SET wall_ms=wall_ms+excluded.wall_ms;';
  String subtract(String row) =>
      'UPDATE audio_daily_totals_v1 SET wall_ms=wall_ms-CAST(${_audioField(row, 'wallMs')} AS INTEGER) '
      "WHERE day=${_audioField(row, 'localDay')} AND book_id=${_audioField(row, 'bookId')} AND ${_audioCounted(row)};"
      'DELETE FROM audio_daily_totals_v1 WHERE wall_ms<=0 '
      "AND day=${_audioField(row, 'localDay')} AND book_id=${_audioField(row, 'bookId')};";
  for (final entry in {
    'insert':
        "AFTER INSERT ON records WHEN NEW.type='audio_event' BEGIN ${add('NEW.')} END",
    'delete':
        "AFTER DELETE ON records WHEN OLD.type='audio_event' BEGIN ${subtract('OLD.')} END",
    'update':
        "AFTER UPDATE ON records WHEN OLD.type='audio_event' OR NEW.type='audio_event' BEGIN ${subtract('OLD.')}${add('NEW.')} END",
  }.entries) {
    await db.customStatement(
      'CREATE TRIGGER IF NOT EXISTS audio_daily_v1_${entry.key} ${entry.value}',
    );
  }
  if (fresh) {
    await db.customStatement(
      'INSERT INTO audio_daily_totals_v1(day,book_id,wall_ms) '
      "SELECT ${_audioField('', 'localDay')},${_audioField('', 'bookId')},SUM(CAST(${_audioField('', 'wallMs')} AS INTEGER)) "
      "FROM records WHERE ${_audioCounted('')} GROUP BY 1,2",
    );
  }
  await db.customStatement(
    "CREATE INDEX IF NOT EXISTS audio_event_time_v1 ON records "
    "(${SchemaSql.audioEventAt}) "
    "WHERE type='audio_event' AND deleted=0 AND json_valid(payload)",
  );
  await db.customStatement(
    "CREATE INDEX IF NOT EXISTS audio_event_end_v1 ON records (${SchemaSql.audioEventEnd}) "
    "WHERE type='audio_event' AND deleted=0 AND json_valid(payload)",
  );
}

/// Expression indexes over JSON records and notes.
Future<void> _recordIndexes(GeneratedDatabase db) async {
  // The version 3 index evaluated JSON for every record, so one damaged
  // payload of any type failed its creation and later inserts.
  await db.customStatement('DROP INDEX IF EXISTS records_audio_day');
  await db.customStatement(
    'CREATE INDEX IF NOT EXISTS records_audio_day_v2 ON records '
    '(${SchemaSql.audioEventBook},${SchemaSql.audioEventDay}) '
    'WHERE ${SchemaSql.audioEventRows}',
  );
  // Version 3 may already have the unguarded indexes. IF NOT EXISTS alone
  // would preserve those definitions, so rebuild them in the v4 transaction.
  for (final name in [
    'video_lesson_item',
    'video_interval_lesson',
    'video_interval_history',
    'video_annotation_lesson',
    'video_subtitle_lesson',
  ]) {
    await db.customStatement('DROP INDEX IF EXISTS $name');
  }
  await db.customStatement(
    "CREATE INDEX IF NOT EXISTS video_lesson_item ON records "
    "(json_extract(payload,'\$.itemId'),json_extract(payload,'\$.ordinal'),id) "
    'WHERE ${SchemaSql.videoLessonRows}',
  );
  await db.customStatement(
    "CREATE INDEX IF NOT EXISTS video_interval_lesson ON records "
    "(json_extract(payload,'\$.lessonId'),json_extract(payload,'\$.mediaVersion')) "
    'WHERE ${SchemaSql.videoIntervalRows}',
  );
  await db.customStatement(
    "CREATE INDEX IF NOT EXISTS video_interval_history ON records "
    "(${SchemaSql.videoIntervalStart} DESC,id DESC) "
    'WHERE ${SchemaSql.videoIntervalRows}',
  );
  await db.customStatement(
    "CREATE INDEX IF NOT EXISTS video_annotation_lesson ON records "
    r"(json_extract(payload,'$.lessonId'),json_extract(payload,'$.mediaVersion'),json_extract(payload,'$.startMs'),id) "
    'WHERE ${SchemaSql.videoAnnotationRows}',
  );
  await db.customStatement(
    "CREATE INDEX IF NOT EXISTS video_subtitle_lesson ON records "
    r"(json_extract(payload,'$.lessonId'),json_extract(payload,'$.mediaVersion'),json_extract(payload,'$.digest')) "
    'WHERE ${SchemaSql.videoSubtitleRows}',
  );
  for (final field in ['hash', 'bookId']) {
    await db.customStatement(
      "CREATE INDEX IF NOT EXISTS reading_notes_$field ON metadata "
      "(json_extract(${SchemaSql.noteJson},'\$.$field')) "
      "WHERE key>='reading-note:' AND key<'reading-note;'",
    );
  }
  await db.customStatement(
    "CREATE INDEX IF NOT EXISTS reading_sessions_book ON metadata "
    "(json_extract(value,'\$.bookId')) WHERE key>='reading-session:' "
    "AND key<'reading-session;' AND json_valid(value)",
  );
}

/// Folder exchange state and replicated application data between devices.
Future<void> _peerSync(GeneratedDatabase db) async {
  for (final statement in [
    'CREATE TABLE IF NOT EXISTS peer_sync_files(folder_id TEXT NOT NULL,path TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(folder_id,path))',
    'CREATE TABLE IF NOT EXISTS peer_sync_deletions(folder_id TEXT NOT NULL,path TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(folder_id,path))',
    'CREATE TABLE IF NOT EXISTS peer_sync_scan_cache(folder_id TEXT NOT NULL,path TEXT NOT NULL,root TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(folder_id,path))',
    'CREATE TABLE IF NOT EXISTS peer_sync_remote_index(device TEXT NOT NULL,folder TEXT NOT NULL,revision TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(device,folder))',
    'CREATE TABLE IF NOT EXISTS peer_app_versions(id TEXT PRIMARY KEY,entity_key TEXT NOT NULL,payload TEXT NOT NULL,active INTEGER NOT NULL)',
    'CREATE INDEX IF NOT EXISTS peer_app_heads ON peer_app_versions(entity_key,active)',
    'CREATE TABLE IF NOT EXISTS peer_app_projection(entity_key TEXT PRIMARY KEY,target TEXT NOT NULL,digest TEXT NOT NULL,clock TEXT NOT NULL,materialized INTEGER NOT NULL)',
    'CREATE INDEX IF NOT EXISTS peer_app_projection_target ON peer_app_projection(target) WHERE materialized=1',
    'CREATE TABLE IF NOT EXISTS peer_app_alias(kind TEXT NOT NULL,local_id TEXT NOT NULL,shared_id TEXT NOT NULL,data TEXT NOT NULL,PRIMARY KEY(kind,local_id))',
    'CREATE INDEX IF NOT EXISTS peer_app_shared ON peer_app_alias(kind,shared_id)',
  ]) {
    await db.customStatement(statement);
  }
}

/// Optional legacy cloud transport; its outbox archive is filled at startup.
Future<void> _cloudTransport(GeneratedDatabase db) async {
  await db.customStatement(
    'CREATE TABLE IF NOT EXISTS cloud_local_state(id TEXT PRIMARY KEY,digest TEXT NOT NULL)',
  );
  await db.customStatement(
    'CREATE TABLE IF NOT EXISTS legacy_cloud_outbox(operation_id TEXT PRIMARY KEY,entity_id TEXT NOT NULL,operation TEXT NOT NULL,state TEXT NOT NULL,receipt TEXT,attempted INTEGER NOT NULL,archived_at TEXT NOT NULL)',
  );
}
