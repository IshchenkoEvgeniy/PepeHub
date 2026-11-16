import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/database_files.dart';
import 'package:pepehub/data/library_rows.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/activity_store.dart';
import 'package:pepehub/library/library_repository.dart';
import 'package:pepehub/library/models.dart';
import 'package:pepehub/library/note_store.dart';
import 'package:pepehub/library/personal_library.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

LibraryEntry _card(String id, String title) => LibraryEntry(
  LibraryItem(
    id: id,
    path: '',
    collectionId: 'book',
    mediaType: 'book',
    modifiedAt: 1,
    values: {'title': title, 'status': 'finished'},
    fields: const [],
  ),
);

Map<String, dynamic> _slot(String id) => {
  'value': {
    'id': id,
    'itemId': 'card-0',
    'mediaType': 'book',
    'day': '2026-11-01',
    'durationSeconds': 60,
  },
};

void main() {
  late AppDatabase db;
  late Repository repo;
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = Repository(db);
  });
  tearDown(() => db.close());

  Future<int> writes(Future<void> Function() action) async {
    await db.customStatement(
      'CREATE TEMP TABLE IF NOT EXISTS row_writes(n INTEGER)',
    );
    await db.customStatement('DELETE FROM row_writes');
    await db.customStatement('INSERT INTO row_writes VALUES(0)');
    for (final event in ['INSERT', 'UPDATE', 'DELETE']) {
      await db.customStatement(
        'CREATE TEMP TRIGGER IF NOT EXISTS count_rows_$event AFTER $event ON library_rows_v1 '
        'BEGIN UPDATE row_writes SET n=n+1; END',
      );
    }
    await action();
    return (await db.customSelect('SELECT n FROM row_writes').getSingle())
        .read<int>('n');
  }

  test('editing one card of 1000 writes one row', () async {
    final catalog = LibraryRepository(
      repo,
      personalLibraryNamespace,
      storageKey: personalLibraryKey,
    );
    await catalog.mutate((cards) async {
      for (var i = 0; i < 1000; i++) {
        cards['card-$i'] = _card('card-$i', 'Книга $i');
      }
    });
    expect(await repo.meta(personalLibraryKey), isNull);
    final count = await writes(
      () => catalog.mutate((cards) async {
        cards['card-5'] = _card('card-5', 'Изменено');
      }),
    );
    expect(count, 1);
    expect(await writes(() => catalog.mutate((_) async {})), 0);
    final removed = await writes(
      () => catalog.mutate((cards) async => cards.remove('card-7')),
    );
    expect(removed, 1);
    final reread = await LibraryRepository(
      Repository(db),
      personalLibraryNamespace,
      storageKey: personalLibraryKey,
    ).entries();
    expect(reread, hasLength(999));
    expect(reread['card-5']!.item.values['title'], 'Изменено');
    expect(await catalog.stored(), isTrue);
  });

  test('a journal writes only the slots that changed', () async {
    for (final store in [
      ActivityStore(repo, personalLibraryNamespace),
      NoteStore(repo, personalLibraryNamespace),
    ]) {
      await store.mutate((state) async {
        final slots = state['slots'] as Map;
        for (var i = 0; i < 500; i++) {
          slots['s$i'] = _slot('s$i');
        }
      });
      final header = await repo.meta(store.key);
      expect(header, isNot(contains('slots')));
      final count = await writes(
        () => store.mutate((state) async {
          (state['slots'] as Map)['s3'] = _slot('changed');
        }),
      );
      expect(count, 1, reason: store.key);
      final state = await store.state();
      expect((state['slots'] as Map), hasLength(500));
      expect(state['slots']['s3']['value']['id'], 'changed');
      expect(state['version'], 1);
      expect(await repo.meta(store.key), header);
    }
  });

  test(
    'a journal value in the old format is read as the newest write',
    () async {
      final store = ActivityStore(repo, personalLibraryNamespace);
      await store.mutate((state) async {
        (state['slots'] as Map)['old'] = _slot('old');
      });
      await repo.setMeta(
        store.key,
        jsonEncode({
          'version': 1,
          'cursor': 4,
          'slots': {'restored': _slot('restored')},
        }),
      );
      final state = await store.state();
      expect((state['slots'] as Map).keys, ['restored']);
      expect(state['cursor'], 4);
      expect(await repo.meta(store.key), isNot(contains('slots')));
    },
  );

  test('schema 9 moves the catalog and journals without losing data', () async {
    final root = await Directory.systemTemp.createTemp('pepehub-v9');
    addTearDown(() => root.delete(recursive: true));
    final seed = await AppDatabase.openInDirectory(root.path);
    final cards = {
      for (var i = 0; i < 300; i++)
        'card-$i': _card('card-$i', 'Книга $i').toJson(),
    };
    final activity = {
      'version': 1,
      'cursor': 7,
      'slots': {for (var i = 0; i < 300; i++) 's$i': _slot('s$i')},
    };
    final notes = {'version': 1, 'cursor': 0, 'slots': <String, Object>{}};
    final seedRepo = Repository(seed);
    await seedRepo.meta('open');
    await seed.close();
    final raw = sqlite.sqlite3.open('${root.path}/$currentDatabaseFilename');
    raw.execute('DELETE FROM library_rows_v1');
    for (final (key, value) in [
      (personalLibraryKey, cards),
      ('obsidian-activity:personal', activity),
      ('obsidian-notes:personal', notes),
    ]) {
      raw.execute('INSERT INTO metadata VALUES(?,?)', [key, jsonEncode(value)]);
    }
    raw.execute('PRAGMA user_version=8');
    raw.close();

    final db = await AppDatabase.openInDirectory(root.path);
    try {
      final repo = Repository(db);
      expect(await repo.meta(personalLibraryKey), isNull);
      final rows = await LibraryRows.read(db, personalLibraryKey);
      expect(rows, hasLength(300));
      final catalog = await LibraryRepository(
        repo,
        personalLibraryNamespace,
        storageKey: personalLibraryKey,
      ).entries();
      expect(catalog.map((k, v) => MapEntry(k, v.toJson())), cards);
      // Insertion order survives, as in the JSON object it replaces.
      expect(catalog.keys.toList(), cards.keys.toList());
      expect(
        await ActivityStore(repo, personalLibraryNamespace).state(),
        activity,
      );
      expect(await NoteStore(repo, personalLibraryNamespace).state(), notes);
      // The move used the catalog's own encoding: nothing is rewritten.
      final before = await LibraryRows.read(db, personalLibraryKey);
      await LibraryRepository(
        repo,
        personalLibraryNamespace,
        storageKey: personalLibraryKey,
      ).mutate((_) async {});
      expect(await LibraryRows.read(db, personalLibraryKey), before);
    } finally {
      await db.close();
    }
  });
}
