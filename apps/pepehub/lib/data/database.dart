import 'dart:io';
import 'dart:isolate';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'database_files.dart';
import 'database_schema.dart';
import 'performance_projections.dart';

class AppDatabase extends GeneratedDatabase {
  AppDatabase(super.executor);
  static Future<AppDatabase> open() async {
    final directory = await getApplicationSupportDirectory();
    return openInDirectory(directory.path);
  }

  static Future<AppDatabase> openInDirectory(String directoryPath) async {
    final path = await Isolate.run(() => prepareDatabaseFiles(directoryPath));
    return AppDatabase(NativeDatabase.createInBackground(File(path)));
  }

  @override
  int get schemaVersion => currentDatabaseVersion;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) => transaction(() async {
      await customStatement(
        'CREATE TABLE records (id TEXT PRIMARY KEY, type TEXT NOT NULL, revision INTEGER NOT NULL, deleted INTEGER NOT NULL, payload TEXT NOT NULL)',
      );
      await customStatement(
        'CREATE TABLE remote_records (id TEXT PRIMARY KEY, type TEXT NOT NULL, revision INTEGER NOT NULL, deleted INTEGER NOT NULL, payload TEXT NOT NULL)',
      );
      await customStatement(
        "CREATE TABLE outbox (sequence INTEGER PRIMARY KEY AUTOINCREMENT, operation_id TEXT NOT NULL UNIQUE, entity_id TEXT NOT NULL, operation TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'pending', receipt TEXT)",
      );
      await customStatement(
        'CREATE INDEX outbox_entity ON outbox(entity_id, sequence)',
      );
      await customStatement(
        'CREATE INDEX records_type ON records(type, deleted)',
      );
      await customStatement(
        'CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
      );
      await _addAudioSchema();
      await _addEditionSchema();
      await createFeatureSchema(this);
      await ensurePerformanceProjections(this);
      await customStatement('PRAGMA user_version = $currentDatabaseVersion');
    }),
    onUpgrade: (_, from, to) async {
      if (from > to) throw StateError('Нельзя открыть более новую схему базы');
      await transaction(() async {
        if (from < 2) await _addAudioSchema();
        if (from < 3) await _addEditionSchema();
        if (from < 4) await createFeatureSchema(this);
        if (from < 5) await ensurePerformanceProjections(this);
        if (from < 6) await ensureReadingSessionBookIndex(this);
        await customStatement('PRAGMA user_version = $currentDatabaseVersion');
      });
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA journal_mode = WAL');
      // Keep FULL durability: NORMAL can lose the latest committed progress
      // on power loss. WAL alone removes rollback-journal reader blocking.
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
  Future<void> _addEditionSchema() async {
    await customStatement(
      'CREATE TABLE audio_editions (id TEXT PRIMARY KEY, book_id TEXT NOT NULL, manifest_revision INTEGER NOT NULL CHECK(manifest_revision > 0))',
    );
    await customStatement(
      'CREATE INDEX audio_editions_book ON audio_editions(book_id)',
    );
    await customStatement(
      'CREATE TABLE audio_resources (sha256 TEXT PRIMARY KEY, path TEXT NOT NULL, bytes INTEGER NOT NULL CHECK(bytes >= 0))',
    );
    await customStatement(
      'CREATE TABLE audio_tracks (id TEXT PRIMARY KEY, edition_id TEXT NOT NULL REFERENCES audio_editions(id), asset_hash TEXT NOT NULL REFERENCES audio_resources(sha256), ordinal INTEGER NOT NULL CHECK(ordinal >= 0), title TEXT NOT NULL, duration_ms INTEGER CHECK(duration_ms >= 0), UNIQUE(edition_id, ordinal))',
    );
    await customStatement(
      'CREATE TABLE audio_chapters (id TEXT PRIMARY KEY, track_id TEXT NOT NULL REFERENCES audio_tracks(id), title TEXT NOT NULL, start_ms INTEGER NOT NULL CHECK(start_ms >= 0), end_ms INTEGER NOT NULL CHECK(end_ms > start_ms))',
    );
    await customStatement(
      'CREATE INDEX audio_chapters_track ON audio_chapters(track_id, start_ms)',
    );
    await customStatement(
      'CREATE TABLE audio_progress (edition_id TEXT PRIMARY KEY REFERENCES audio_editions(id), track_id TEXT NOT NULL REFERENCES audio_tracks(id), position_ms INTEGER NOT NULL CHECK(position_ms >= 0), manifest_revision INTEGER NOT NULL CHECK(manifest_revision > 0), speed REAL NOT NULL CHECK(speed >= 0.5 AND speed <= 3), updated_at TEXT NOT NULL)',
    );
    // Decode records rather than requiring SQLite JSON extensions. Tombstones
    // remain untouched; only known audio cards receive an edition.
    final books = await customSelect(
      "SELECT id,payload FROM records WHERE type='book'",
    ).get();
    for (final book in books) {
      final payload = jsonDecode(book.read<String>('payload'));
      if (payload is! Map || payload['format'] != 'audio') continue;
      final bookId = book.read<String>('id');
      final editionId = const Uuid().v5(
        Namespace.url.value,
        'pepehub:edition:$bookId',
      );
      await customStatement('INSERT INTO audio_editions VALUES(?,?,1)', [
        editionId,
        bookId,
      ]);
      final assets = await customSelect(
        'SELECT * FROM local_assets WHERE book_id=? ORDER BY filename,id',
        variables: [Variable(bookId)],
      ).get();
      var ordinal = 0;
      for (final asset in assets) {
        await customStatement(
          'INSERT OR IGNORE INTO audio_resources VALUES(?,?,?)',
          [
            asset.read<String>('sha256'),
            asset.read<String>('path'),
            asset.read<int>('bytes'),
          ],
        );
        await customStatement(
          'INSERT INTO audio_tracks VALUES(?,?,?,?,?,NULL)',
          [
            asset.read<String>('id'),
            editionId,
            asset.read<String>('sha256'),
            ordinal++,
            asset.read<String>('filename'),
          ],
        );
        if (ordinal == 1) {
          await customStatement(
            'INSERT INTO audio_progress SELECT ?,?,position_ms,1,speed,updated_at FROM playback_positions WHERE asset_hash=?',
            [editionId, asset.read<String>('id'), asset.read<String>('sha256')],
          );
        }
      }
    }
  }

  Future<void> _addAudioSchema() async {
    await customStatement(
      'ALTER TABLE outbox ADD COLUMN attempted INTEGER NOT NULL DEFAULT 0',
    );
    // Legacy clients did not record attempts: conservatively freeze existing payloads.
    await customStatement('UPDATE outbox SET attempted=1');
    await customStatement(
      'CREATE TABLE local_assets (id TEXT PRIMARY KEY, book_id TEXT NOT NULL, filename TEXT NOT NULL, path TEXT NOT NULL, sha256 TEXT NOT NULL UNIQUE, bytes INTEGER NOT NULL)',
    );
    await customStatement('CREATE INDEX assets_book ON local_assets(book_id)');
    await customStatement(
      'CREATE TABLE playback_positions (asset_hash TEXT PRIMARY KEY, position_ms INTEGER NOT NULL, speed REAL NOT NULL, updated_at TEXT NOT NULL)',
    );
  }
}
