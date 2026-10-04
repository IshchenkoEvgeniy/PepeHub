import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pepehub/audio/audio_folder.dart';
import 'package:pepehub/audio/audio_journal.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/activity_store.dart';
import 'package:pepehub/library/cover_sync.dart';
import 'package:pepehub/library/library_repository.dart';
import 'package:pepehub/library/models.dart';
import 'package:pepehub/library/obsidian_sync_service.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/reader/reading_library.dart';
import 'package:pepehub/reader/reading_activity.dart';
import 'package:pepehub/reader/reading_roots.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late Repository local;
  late Directory directory;
  late AssetStore assets;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    local = Repository(db);
    directory = await Directory.systemTemp.createTemp('pepehub-app-review-');
    assets = AssetStore(local, directory);
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  ListeningSegment segment(int start) => ListeningSegment(
    'book',
    'track',
    start,
    start + 1000,
    1000,
    1,
    DateTime.utc(2026, 10, 4, 10).add(Duration(milliseconds: start)),
  );

  test(
    'continuing playback does not resurrect a deleted listening interval',
    () async {
      final journal = AudioJournal(local);
      await journal.appendListening(segment(0));
      final original = (await journal.list('audio_event')).single;
      await journal.deleteEvent(original.id);
      await journal.appendListening(segment(1000));
      expect((await local.record(original.id))!.deleted, isTrue);
      final remaining = (await journal.list('audio_event')).single;
      expect(remaining.id, isNot(original.id));
      expect(remaining.payload!['wallMs'], 1000);
      expect(remaining.payload!['positionMs'], 1000);
    },
  );

  test(
    'continuing playback preserves an externally corrected interval',
    () async {
      final journal = AudioJournal(local);
      await journal.appendListening(segment(0));
      final original = (await journal.list('audio_event')).single;
      await journal.put('audio_event', original.id, {
        ...original.payload!,
        'wallMs': 500,
        'note': 'Corrected in Obsidian',
      });
      await journal.appendListening(segment(1000));
      expect((await local.record(original.id))!.payload!['wallMs'], 500);
      expect(
        (await local.record(original.id))!.payload!['note'],
        'Corrected in Obsidian',
      );
      expect(await journal.list('audio_event'), hasLength(2));
    },
  );

  test(
    'legacy reading positions tolerate missing chapter paragraph indexes',
    () {
      final index = {
        'length': 1000,
        'starts': [0, 500],
        'lengths': [500, 500],
        'paragraphStarts': [
          [0],
        ],
      };
      expect(
        readingFraction(index, {'chapter': 1, 'paragraph': 0, 'offset': 10}),
        .51,
      );
      expect(
        readingFraction({...index, 'paragraphStarts': []}, {'chapter': 1}),
        .5,
      );
    },
  );

  test(
    'a missing local cover file never queues removal of the Obsidian cover',
    () async {
      final config = ObsidianConfig('https://example.test', 'secret');
      await local.addBook('Book', 'Author', 'epub');
      final book = (await local.records('book')).single;
      final cover = File('${directory.path}/cover.png');
      await cover.writeAsBytes(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1kAAAAASUVORK5CYII=',
        ),
      );
      await ReadingLibrary(local)
          .saveDetails(book.id, {'title': 'Book', 'cover': cover.path});
      final item = ObsidianLibraryItem(
        id: uuid.v4(),
        path: 'Books/Book.md',
        collectionId: 'book',
        mediaType: 'book',
        values: {'Cover': '[[Images/cover.png]]'},
        fields: const [LibraryField('Cover', 'cover', 'text')],
      );
      final repository = LibraryRepository(local, config.namespace);
      await repository.mutate((entries) async {
        entries[item.id] = LibraryEntry(item, sourceBookId: book.id);
      });
      final client = MockClient((_) async => http.Response('{}', 200));
      addTearDown(client.close);
      final covers = CoverSync(assets, client, config);
      expect(await covers.run(), isFalse);
      final state = await local.meta(
        'obsidian-cover-state:${config.namespace}',
      );
      await cover.delete();
      expect(await covers.run(), isFalse);
      final entry = (await repository.entries())[item.id]!;
      expect(entry.state, 'synced');
      expect(entry.item.value('cover'), '[[Images/cover.png]]');
      expect(
        await local.meta('obsidian-cover-state:${config.namespace}'),
        state,
      );
      expect(
        await local.meta('obsidian-cover-errors:${config.namespace}'),
        isNotEmpty,
      );
    },
  );

  test('refreshing a reading folder retains missing books so disconnect hides them', () async {
    final book = File('${directory.path}/Book.txt');
    await book.writeAsString('Book text');
    final roots = ReadingRoots(assets);
    final first = await roots.connect(
      AudioFolder('Books', [XFile(book.path)], root: directory.path),
    );
    final bookId = first.bookIds.single;
    await book.delete();
    final refreshed = await roots.connect(
      AudioFolder('Books', [], root: directory.path),
    );
    expect(refreshed.bookIds, contains(bookId));
    await roots.disconnect(refreshed);
    expect(await local.meta('reading-library-hidden:$bookId'), '1');
    expect((await local.record(bookId))!.deleted, isFalse);
  });

  Map<String, dynamic> activity() => ActivityStore.entry(
    id: uuid.v4(),
    itemId: uuid.v4(),
    mediaType: 'book',
    day: '2026-10-04',
    durationMs: 60000,
    progress: 100,
    unit: 'characters',
    origin: 'obsidian',
  );

  test(
    'a matching journal feed entry clears its stale pending operation',
    () async {
      final store = ActivityStore(local, 'review');
      final value = activity();
      await store.receive([
        {'entry': value, 'revision': 1, 'sequence': 1},
      ], 1);
      final changed = {...value, 'durationMs': 120000};
      await store.edit(value['id'] as String, changed);
      expect(await store.pending(), hasLength(1));
      await store.receive([
        {'entry': changed, 'revision': 2, 'sequence': 2},
      ], 2);
      expect(await store.pending(), isEmpty);
    },
  );

  test(
    'invalid journal data does not poison statistics or advance the cursor',
    () async {
      final store = ActivityStore(local, 'review');
      await expectLater(
        store.receive([
          {
            'entry': {...activity(), 'day': '2026-02-31'},
            'revision': 1,
            'sequence': 1,
          },
        ], 1),
        throwsFormatException,
      );
      expect((await store.state())['cursor'], 0);
      expect(await store.entries(), isEmpty);
    },
  );

  test(
    'a timed foreign reading entry without an end uses its actual start',
    () async {
      await local.addBook('Book', 'Author', 'epub');
      final book = (await local.records('book')).single;
      final item = ObsidianLibraryItem(
        id: uuid.v4(),
        path: 'Books/Book.md',
        collectionId: 'book',
        mediaType: 'book',
        values: const {},
        fields: const [],
      );
      await LibraryRepository(local, 'review').mutate((entries) async {
        entries[item.id] = LibraryEntry(item, sourceBookId: book.id);
      });
      await local.setMeta('obsidian-active-namespace', 'review');
      final value = {
        ...activity(),
        'itemId': item.id,
        'startedAt': '2026-10-04T10:00:00.000Z',
      };
      await ActivityStore(local, 'review').receive([
        {'entry': value, 'revision': 1, 'sequence': 1},
      ], 1);
      final session = (await ActivityStore.foreignReading(local)).single;
      final span = (session['spans'] as List).single as Map;
      expect(
        DateTime.parse(span['end']).difference(DateTime.parse(span['start'])),
        const Duration(minutes: 1),
      );
    },
  );

  test(
    'an audio cover cache disappearing does not delete remote artwork',
    () async {
      final config = ObsidianConfig('https://example.test', 'secret');
      await local.addBook('Audio', 'Author', 'audio');
      final book = (await local.records('book')).single;
      final cover = File('${directory.path}/audio-cover.png');
      await cover.writeAsBytes([1, 2, 3]);
      await local.setMeta('audio-cover:${book.id}', cover.path);
      final item = ObsidianLibraryItem(
        id: uuid.v4(),
        path: 'Books/Audio.md',
        collectionId: 'audio',
        mediaType: 'audiobook',
        values: {'Cover': '[[Images/audio.png]]'},
        fields: const [LibraryField('Cover', 'cover', 'text')],
      );
      final repository = LibraryRepository(local, config.namespace);
      await repository.mutate((entries) async {
        entries[item.id] = LibraryEntry(item, sourceBookId: book.id);
      });
      final client = MockClient((_) async => http.Response('{}', 200));
      addTearDown(client.close);
      final covers = CoverSync(assets, client, config);
      expect(await covers.run(), isFalse);
      await cover.delete();
      expect(await covers.run(), isFalse);
      expect((await repository.entries())[item.id]!.state, 'synced');
      // An explicit Hide action still queues a removal, even when the file is missing.
      await local.setMeta('audio-cover-hidden:${book.id}', 'true');
      expect(await covers.run(), isTrue);
      expect((await repository.entries())[item.id]!.operation!['values'], {
        'Cover': null,
      });
    },
  );

  test(
    'a journal page rolls back all entries when one record is invalid',
    () async {
      final store = ActivityStore(local, 'review');
      final original = activity();
      await store.receive([
        {'entry': original, 'revision': 1, 'sequence': 1},
      ], 1);
      final before = await local.meta(store.key);
      await expectLater(
        store.receive([
          {
            'entry': {...original, 'note': 'Remote update'},
            'revision': 2,
            'sequence': 2,
          },
          {
            'entry': {...activity(), 'durationMs': -1},
            'revision': 1,
            'sequence': 3,
          },
        ], 3),
        throwsFormatException,
      );
      expect(await local.meta(store.key), before);
      await expectLater(store.receive([], 0), throwsFormatException);
      expect(await local.meta(store.key), before);
    },
  );

  test(
    'a receipt for another journal item cannot acknowledge a local edit',
    () async {
      final store = ActivityStore(local, 'review');
      final value = activity();
      await store.receive([
        {'entry': value, 'revision': 1, 'sequence': 1},
      ], 1);
      await store.edit(value['id'] as String, {...value, 'note': 'Local edit'});
      final operation = (await store.pending()).single;
      await expectLater(
        store.receipts([
          {
            'operationId': operation['operationId'],
            'status': 'applied',
            'record': {'entry': activity(), 'revision': 2, 'sequence': 2},
          },
        ]),
        throwsFormatException,
      );
      expect(await store.pending(), [operation]);
    },
  );

  test(
    'a checkpoint exactly at midnight splits reading time between both days',
    () async {
      var now = DateTime(2026, 10, 3, 23, 59, 50);
      final tracker = ReadingActivity(
        local,
        bookId: 'book',
        hash: 'hash',
        length: 1000,
        clock: () => now,
      );
      await tracker.start(0, runTimer: false);
      now = now.add(const Duration(seconds: 10));
      tracker.tick();
      now = now.add(const Duration(seconds: 10));
      tracker.tick();
      await tracker.close();
      expect(readingTotals([tracker.snapshot()]).days, {
        '2026-10-03': 10000,
        '2026-10-04': 10000,
      });
    },
  );

  test('invalid journal receipts preserve pending changes', () async {
    final store = ActivityStore(local, 'review');
    final value = activity();
    await store.receive([
      {'entry': value, 'revision': 1, 'sequence': 1},
    ], 1);
    await store.edit(value['id'] as String, {...value, 'note': 'Local edit'});
    final operation = (await store.pending()).single;
    await expectLater(
      store.receipts([
        {
          'operationId': operation['operationId'],
          'status': 'applied',
          'record': {'entry': operation['entry'], 'revision': 0, 'sequence': 2},
        },
      ]),
      throwsFormatException,
    );
    expect(await store.pending(), [operation]);
  });
}
