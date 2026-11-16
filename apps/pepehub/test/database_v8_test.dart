import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/database_files.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/activity_store.dart';
import 'package:pepehub/library/book_trash.dart';
import 'package:pepehub/library/library_folder_storage.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// One audio edition with two tracks and a saved position for [bookId].
void _audioEdition(sqlite.Database raw, String bookId, String prefix) {
  raw.execute('INSERT INTO audio_editions VALUES(?,?,1)', [
    '$prefix-e',
    bookId,
  ]);
  for (var i = 0; i < 2; i++) {
    raw.execute('INSERT INTO audio_resources VALUES(?,?,10)', [
      '$prefix-h$i',
      '/audio/$prefix-$i.mp3',
    ]);
    raw.execute('INSERT INTO audio_tracks VALUES(?,?,?,?,?,1000)', [
      '$prefix-t$i',
      '$prefix-e',
      '$prefix-h$i',
      i,
      'Track $i',
    ]);
  }
  raw.execute('INSERT INTO audio_chapters VALUES(?,?,?,0,500)', [
    '$prefix-c',
    '$prefix-t0',
    'Chapter',
  ]);
  raw.execute('INSERT INTO audio_progress VALUES(?,?,100,1,1.0,?)', [
    '$prefix-e',
    '$prefix-t1',
    '2026-01-02 03:04:05',
  ]);
}

int _count(sqlite.Database raw, String sql) =>
    raw.select(sql).single.values.first as int;

void main() {
  group('version 8 upgrade', () {
    late Directory root;
    late File file;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('pepehub-v8');
      file = File('${root.path}/$currentDatabaseFilename');
    });
    tearDown(() => root.delete(recursive: true));

    Future<void> createVersion7() async {
      final db = await AppDatabase.openInDirectory(root.path);
      await Repository(db).meta('warm-up');
      await db.close();
      final raw = sqlite.sqlite3.open(file.path);
      try {
        // Undo the v8 objects so the file looks like a version 7 database.
        for (final row in raw.select(
          "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'guard_%'",
        )) {
          raw.execute('DROP TRIGGER ${row['name']}');
        }
        raw.execute('DROP INDEX audio_tracks_asset');
        raw.execute('DROP INDEX audio_progress_track');
        raw.execute('PRAGMA user_version=7');
      } finally {
        raw.close();
      }
    }

    test('removes manifests of purged audiobooks and keeps live ones', () async {
      await createVersion7();
      final raw = sqlite.sqlite3.open(file.path);
      raw.execute("INSERT INTO records VALUES('purged','book',2,1,'null')");
      raw.execute(
        "INSERT INTO records VALUES('live','book',1,0,'{\"title\":\"A\",\"format\":\"audio\"}')",
      );
      _audioEdition(raw, 'purged', 'p');
      _audioEdition(raw, 'live', 'l');
      // A resource shared with a live book must survive.
      raw.execute(
        "INSERT INTO audio_tracks VALUES('p-t2','p-e','l-h0',2,'Shared',1000)",
      );
      raw.close();

      final db = await AppDatabase.openInDirectory(root.path);
      await Repository(db).meta('open');
      await db.close();

      final check = sqlite.sqlite3.open(file.path);
      try {
        expect(
          check.select('PRAGMA user_version').single.values.first,
          currentDatabaseVersion,
        );
        expect(
          _count(
            check,
            "SELECT COUNT(*) FROM audio_editions WHERE book_id='purged'",
          ),
          0,
        );
        expect(
          _count(
            check,
            "SELECT COUNT(*) FROM audio_tracks WHERE edition_id='p-e'",
          ),
          0,
        );
        expect(
          _count(check, "SELECT COUNT(*) FROM audio_chapters WHERE id='p-c'"),
          0,
        );
        expect(
          _count(
            check,
            "SELECT COUNT(*) FROM audio_progress WHERE edition_id='p-e'",
          ),
          0,
        );
        expect(
          _count(
            check,
            "SELECT COUNT(*) FROM audio_resources WHERE sha256 LIKE 'p-%'",
          ),
          0,
        );
        expect(
          _count(
            check,
            "SELECT COUNT(*) FROM audio_resources WHERE sha256 LIKE 'l-%'",
          ),
          2,
        );
        expect(
          _count(
            check,
            "SELECT COUNT(*) FROM audio_tracks WHERE edition_id='l-e'",
          ),
          2,
        );
        // The old timestamp now sorts with new UTC values.
        expect(
          check
              .select(
                "SELECT updated_at FROM audio_progress WHERE edition_id='l-e'",
              )
              .single
              .values
              .first,
          '2026-01-02T03:04:05.000Z',
        );
        final plan = check
            .select(
              "EXPLAIN QUERY PLAN SELECT * FROM audio_tracks WHERE asset_hash='x'",
            )
            .map((r) => '${r['detail']}')
            .join();
        expect(plan, contains('audio_tracks_asset'));
        // One backup per source version, however many attempts.
        expect(
          File(
            '${root.path}/backups/before-v$currentDatabaseVersion-from-v7.sqlite',
          ).existsSync(),
          isTrue,
        );
      } finally {
        check.close();
      }
    });

    test('a failed upgrade does not add a backup on every start', () async {
      await createVersion7();
      final raw = sqlite.sqlite3.open(file.path);
      // Make the v8 step fail: its index name is taken by a table.
      raw.execute('CREATE TABLE audio_tracks_asset(x)');
      raw.close();
      for (var attempt = 0; attempt < 3; attempt++) {
        final db = await AppDatabase.openInDirectory(root.path);
        await expectLater(Repository(db).meta('open'), throwsA(anything));
        await db.close();
      }
      expect(Directory('${root.path}/backups').listSync(), hasLength(1));
      final check = sqlite.sqlite3.open(file.path);
      try {
        expect(check.select('PRAGMA user_version').single.values.first, 7);
      } finally {
        check.close();
      }
    });
  });

  group('integrity guards', () {
    late AppDatabase db;
    setUp(() => db = AppDatabase(NativeDatabase.memory()));
    tearDown(() => db.close());

    test('reject NULL keys and invalid deletion flags', () async {
      await expectLater(
        db.customStatement("INSERT INTO records VALUES(NULL,'book',1,0,'{}')"),
        throwsA(anything),
      );
      await expectLater(
        db.customStatement("INSERT INTO records VALUES('x','book',1,2,'{}')"),
        throwsA(anything),
      );
      await expectLater(
        db.customStatement("INSERT INTO metadata VALUES(NULL,'v')"),
        throwsA(anything),
      );
      // Valid writes still work.
      await Repository(db).setMeta('ok', '1');
      await Repository(db).addBook('Книга', 'Автор', 'epub');
    });
  });

  test(
    'purging an audiobook removes its manifest so the files can return',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = Repository(db);
      await repo.addBook('Аудио', 'Автор', 'audio');
      final id = (await repo.records('book')).single.id;
      await db.customStatement("INSERT INTO audio_editions VALUES('e',?,1)", [
        id,
      ]);
      await db.customStatement(
        "INSERT INTO audio_resources VALUES('h','/a.mp3',1)",
      );
      await db.customStatement(
        "INSERT INTO audio_tracks VALUES('t','e','h',0,'T',NULL)",
      );
      await db.customStatement(
        "INSERT INTO audio_progress VALUES('e','t',0,1,1.0,'2026-01-01T00:00:00Z')",
      );
      final trash = BookTrash(repo);
      await trash.move([id]);
      await trash.purge([id]);
      for (final table in [
        'audio_editions',
        'audio_tracks',
        'audio_progress',
        'audio_resources',
      ]) {
        final rows = await db
            .customSelect('SELECT COUNT(*) AS c FROM $table')
            .getSingle();
        expect(rows.read<int>('c'), 0, reason: table);
      }
    },
  );

  test(
    'an activity journal write leaves book export revisions alone',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = Repository(db);
      for (var i = 0; i < 5; i++) {
        await repo.addBook('Книга $i', 'Автор', 'epub');
      }
      Future<Map<String, int>> revisions() async => {
        for (final row
            in await db
                .customSelect(
                  'SELECT book_id,revision FROM library_source_revisions_v1',
                )
                .get())
          row.read<String>('book_id'): row.read<int>('revision'),
      };
      final before = await revisions();
      await repo.setMeta('obsidian-activity:personal', '{"slots":{}}');
      final after = await revisions();
      expect(after['#activity'], (before['#activity'] ?? 0) + 1);
      after.remove('#activity');
      before.remove('#activity');
      expect(after, before);
    },
  );

  test('an unchanged activity journal is not rewritten', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = Repository(db);
    final store = ActivityStore(repo, 'personal');
    await store.mutate(
      (data) async => (data['slots'] as Map)['a'] = {'value': {}},
    );
    final revision = await db
        .customSelect(
          "SELECT revision FROM library_source_revisions_v1 WHERE book_id='#activity'",
        )
        .getSingle();
    await store.mutate((_) async {});
    final again = await db
        .customSelect(
          "SELECT revision FROM library_source_revisions_v1 WHERE book_id='#activity'",
        )
        .getSingle();
    expect(again.read<int>('revision'), revision.read<int>('revision'));
  });

  group('card merge', () {
    String card(Map<String, Object?> values) =>
        jsonEncode({'id': 'c', 'values': values});
    final base = card({'rating': 3, 'endDate': '2026-01-01', 'notes': 'a'});

    test('keeps edits of different fields from both devices', () {
      final merged = mergeLibraryCard(
        card({'rating': 5, 'endDate': '2026-01-01', 'notes': 'a'}),
        card({'rating': 3, 'endDate': '2026-02-02', 'notes': 'a'}),
        base,
      );
      expect(jsonDecode(merged!)['values'], {
        'rating': 5,
        'endDate': '2026-02-02',
        'notes': 'a',
      });
    });

    test('keeps a field removed on one side removed', () {
      final merged = mergeLibraryCard(
        card({'rating': 3, 'endDate': '2026-01-01'}),
        card({'rating': 4, 'endDate': '2026-01-01', 'notes': 'a'}),
        base,
      );
      expect(jsonDecode(merged!)['values'], {
        'rating': 4,
        'endDate': '2026-01-01',
      });
    });

    test('reports the same field changed differently as a conflict', () {
      expect(
        mergeLibraryCard(
          card({'rating': 5, 'endDate': '2026-01-01', 'notes': 'a'}),
          card({'rating': 1, 'endDate': '2026-01-01', 'notes': 'a'}),
          base,
        ),
        isNull,
      );
    });
  });
}
