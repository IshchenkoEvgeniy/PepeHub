import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/audio/audio_library_repository.dart';
import 'package:pepehub/audio/models.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/database_files.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

// Reproduces the released schema independently of the current migration.
sqlite.Database legacyDatabase(String path) {
  final raw = sqlite.sqlite3.open(path);
  raw.execute('PRAGMA journal_mode=WAL');
  raw.execute(
    'CREATE TABLE records(id TEXT PRIMARY KEY,type TEXT NOT NULL,revision INTEGER NOT NULL,deleted INTEGER NOT NULL,payload TEXT NOT NULL)',
  );
  raw.execute(
    'CREATE TABLE remote_records(id TEXT PRIMARY KEY,type TEXT NOT NULL,revision INTEGER NOT NULL,deleted INTEGER NOT NULL,payload TEXT NOT NULL)',
  );
  raw.execute(
    "CREATE TABLE outbox(sequence INTEGER PRIMARY KEY AUTOINCREMENT,operation_id TEXT UNIQUE,entity_id TEXT,operation TEXT,state TEXT DEFAULT 'pending',receipt TEXT,attempted INTEGER NOT NULL DEFAULT 0)",
  );
  raw.execute('CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT)');
  raw.execute(
    'CREATE TABLE local_assets(id TEXT PRIMARY KEY,book_id TEXT NOT NULL,filename TEXT NOT NULL,path TEXT NOT NULL,sha256 TEXT NOT NULL UNIQUE,bytes INTEGER NOT NULL)',
  );
  raw.execute(
    'CREATE TABLE playback_positions(asset_hash TEXT PRIMARY KEY,position_ms INTEGER NOT NULL,speed REAL NOT NULL,updated_at TEXT NOT NULL)',
  );
  for (final entry in {
    'audio-book': 'audio',
    'missing-book': 'audio',
    'text-book': 'epub',
  }.entries) {
    raw.execute('INSERT INTO records VALUES(?,?,4,0,?)', [
      entry.key,
      'book',
      jsonEncode({
        'format': entry.value,
        'title': entry.key,
        'authors': [],
        'status': 'active',
      }),
    ]);
  }
  raw.execute("INSERT INTO records VALUES('session','session',2,0,?)", [
    jsonEncode({'bookId': 'audio-book', 'activeSeconds': 123}),
  ]);
  raw.execute("INSERT INTO metadata VALUES('device_id','old-device')");
  raw.execute(
    "INSERT INTO outbox(operation_id,entity_id,operation,attempted) VALUES('operation','session','frozen-payload',1)",
  );
  raw.execute(
    "INSERT INTO local_assets VALUES('track','audio-book','Книга.mp3','missing/original.mp3','hash-a',2048)",
  );
  raw.execute(
    "INSERT INTO local_assets VALUES('epub','text-book','Книга.epub','missing/original.epub','hash-e',4096)",
  );
  raw.execute(
    "INSERT INTO playback_positions VALUES('hash-a',42123,1.5,'2026-09-14T10:00:00Z')",
  );
  raw.execute('PRAGMA user_version=2');
  return raw;
}

void main() {
  late Directory root;
  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    root = await Directory.systemTemp.createTemp('pepehub-migration-');
  });
  tearDown(() async => root.delete(recursive: true));

  test('audio addresses reject invalid positions and chapter boundaries', () {
    expect(
      () => AudioLocator(
        bookId: 'b',
        editionId: 'e',
        trackId: 't',
        positionMs: -1,
        manifestRevision: 1,
      ),
      throwsArgumentError,
    );
    expect(
      () => AudioLocator(
        bookId: 'b',
        editionId: 'e',
        trackId: '',
        positionMs: 0,
        manifestRevision: 1,
      ),
      throwsArgumentError,
    );
    expect(
      () => AudioChapter(
        id: 'c',
        trackId: 't',
        title: '',
        startMs: 10,
        endMs: 10,
      ),
      throwsArgumentError,
    );
    final locator = AudioLocator(
      bookId: 'b',
      editionId: 'e',
      trackId: 't',
      positionMs: 42,
      manifestRevision: 1,
    );
    expect(() => AudioProgress(locator, double.nan), throwsArgumentError);
    expect(
      locator.toJson().keys,
      unorderedEquals([
        'bookId',
        'editionId',
        'trackId',
        'positionMs',
        'manifestRevision',
      ]),
    );
  });

  test('production opening snapshots committed WAL, preserves legacy and migrates once', () async {
    final raw = legacyDatabase('${root.path}/pepehub.sqlite');
    // Keep the source open: the backup must include committed WAL pages.
    AppDatabase? db;
    try {
      db = await AppDatabase.openInDirectory(root.path);
      final library = AudioLibraryRepository(db);
      final saved = await library.progressForTrack('track');
      expect(saved.locator.positionMs, 42123);
      expect(saved.speed, 1.5);
      expect(saved.locator.bookId, 'audio-book');
      expect(
        (await db.customSelect('SELECT * FROM audio_editions').get()).length,
        2,
      );
      expect(
        (await db.customSelect('SELECT * FROM audio_tracks').get()).length,
        1,
      );
      expect(
        (await db
                .customSelect("SELECT payload FROM records WHERE id='session'")
                .getSingle())
            .read<String>('payload'),
        jsonEncode({'bookId': 'audio-book', 'activeSeconds': 123}),
      );
      expect(
        (await db
                .customSelect('SELECT operation,attempted FROM outbox')
                .getSingle())
            .read<String>('operation'),
        'frozen-payload',
      );
      expect(
        (await db.customSelect('SELECT attempted FROM outbox').getSingle())
            .read<int>('attempted'),
        1,
      );
      expect(
        (await db
                .customSelect(
                  "SELECT value FROM metadata WHERE key='device_id'",
                )
                .getSingle())
            .read<String>('value'),
        'old-device',
      );
      expect(raw.select('PRAGMA user_version').single.values.first, 2);
      expect(
        raw.select(
          "SELECT name FROM sqlite_master WHERE name='audio_editions'",
        ),
        isEmpty,
      );
      final backups = Directory('${root.path}/backups')
          .listSync()
          .whereType<File>()
          .toList();
      expect(backups, hasLength(1));
      final copy = sqlite.sqlite3.open(
        backups.single.path,
        mode: sqlite.OpenMode.readOnly,
      );
      try {
        expect(copy.select('PRAGMA quick_check').single.values.first, 'ok');
        expect(
          copy
              .select('SELECT position_ms FROM playback_positions')
              .single['position_ms'],
          42123,
        );
        expect(copy.select('PRAGMA user_version').single.values.first, 2);
      } finally {
        copy.close();
      }
      await library.saveProgress(
        AudioProgress(
          AudioLocator(
            bookId: saved.locator.bookId,
            editionId: saved.locator.editionId,
            trackId: 'track',
            positionMs: 50000,
            manifestRevision: 1,
          ),
          2,
        ),
      );
      await db.close();
      db = null;
      // Old APK may keep using its database: never re-import its newer changes.
      raw.execute('UPDATE playback_positions SET position_ms=999');
      db = await AppDatabase.openInDirectory(root.path);
      expect(
        (await AudioLibraryRepository(db).progressForTrack('track'))
            .locator
            .positionMs,
        50000,
      );
      expect(Directory('${root.path}/backups').listSync(), hasLength(1));
      final restoredRoot = Directory('${root.path}/restored')..createSync();
      await backups.single.copy('${restoredRoot.path}/pepehub.sqlite');
      final restored = await AppDatabase.openInDirectory(restoredRoot.path);
      try {
        final originalProgress = await AudioLibraryRepository(restored)
            .progressForTrack('track');
        expect(originalProgress.locator.positionMs, 42123);
        expect(originalProgress.speed, 1.5);
      } finally {
        await restored.close();
      }
    } finally {
      await db?.close();
      raw.close();
    }
  });

  test(
    'migration failure rolls back all new tables and schema version',
    () async {
      final file = File('${root.path}/failure.sqlite');
      final raw = legacyDatabase(file.path);
      // Force failure after the first DDL statements, not before the migration.
      raw.execute('CREATE TABLE audio_chapters(existing TEXT)');
      raw.close();
      final db = AppDatabase(NativeDatabase(file));
      await expectLater(db.customSelect('SELECT 1').get(), throwsA(anything));
      await db.close();
      final check = sqlite.sqlite3.open(file.path);
      try {
        expect(check.select('PRAGMA user_version').single.values.first, 2);
        expect(
          check.select(
            "SELECT name FROM sqlite_master WHERE name='audio_editions'",
          ),
          isEmpty,
        );
        expect(
          check
              .select('SELECT position_ms FROM playback_positions')
              .single['position_ms'],
          42123,
        );
        expect(
          check.select('SELECT operation FROM outbox').single['operation'],
          'frozen-payload',
        );
      } finally {
        check.close();
      }
    },
  );

  test('future database version is rejected without rewriting it', () async {
    final path = '${root.path}/$currentDatabaseFilename';
    final raw = sqlite.sqlite3.open(path);
    raw.execute('PRAGMA user_version=99');
    raw.close();
    await expectLater(AppDatabase.openInDirectory(root.path), throwsStateError);
    final direct = AppDatabase(NativeDatabase(File(path)));
    await expectLater(direct.customSelect('SELECT 1').get(), throwsStateError);
    await direct.close();
    final check = sqlite.sqlite3.open(path);
    expect(check.select('PRAGMA user_version').single.values.first, 99);
    check.close();
  });

  test('shared bytes keep independent edition progress and reject cross-edition writes', () async {
    final db = AppDatabase(NativeDatabase.memory());
    try {
      final library = AudioLibraryRepository(db);
      for (final id in ['one', 'two']) {
        await library.registerSingleTrack(
          bookId: 'book-$id',
          assetId: id,
          hash: 'same-hash',
          path: 'same.mp3',
          filename: 'same.mp3',
          bytes: 100,
        );
      }
      final one = await library.progressForTrack('one'),
          two = await library.progressForTrack('two');
      await library.saveProgress(
        AudioProgress(
          AudioLocator(
            bookId: one.locator.bookId,
            editionId: one.locator.editionId,
            trackId: 'one',
            positionMs: 123,
            manifestRevision: 1,
          ),
          1.5,
        ),
      );
      expect((await library.progressForTrack('two')).locator.positionMs, 0);
      expect(
        (await db.customSelect('SELECT * FROM audio_resources').get()),
        hasLength(1),
      );
      await expectLater(
        library.saveProgress(
          AudioProgress(
            AudioLocator(
              bookId: one.locator.bookId,
              editionId: one.locator.editionId,
              trackId: two.locator.trackId,
              positionMs: 12,
              manifestRevision: 1,
            ),
            1,
          ),
        ),
        throwsArgumentError,
      );
      await expectLater(
        library.saveProgress(
          AudioProgress(
            AudioLocator(
              bookId: one.locator.bookId,
              editionId: one.locator.editionId,
              trackId: 'one',
              positionMs: 12,
              manifestRevision: 2,
            ),
            1,
          ),
        ),
        throwsStateError,
      );
    } finally {
      await db.close();
    }
  });
}
