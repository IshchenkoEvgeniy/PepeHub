import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/activity_store.dart';
import 'package:pepehub/library/library_repository.dart';
import 'package:pepehub/library/models.dart';
import 'package:pepehub/reader/reading_activity.dart';
import 'package:pepehub/audio/audio_journal.dart';
import 'package:pepehub/audio/listening_analytics.dart';

void main() {
  late Repository local;
  late AppDatabase db;
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    local = Repository(db);
  });
  tearDown(() => db.close());
  Future<String> link(String namespace, {String format = 'epub'}) async {
    final previous = (await local.records('book')).map((b) => b.id).toSet();
    await local.addBook('Книга', 'Автор', format);
    final book = (await local.records('book'))
        .singleWhere((b) => !previous.contains(b.id));
    final item = ObsidianLibraryItem.fromJson({
      'id': uuid.v4(),
      'path': 'Books/One.md',
      'collectionId': 'book',
      'mediaType': format == 'audio' ? 'audiobook' : 'book',
      'modifiedAt': 1,
      'values': {'Title': 'Книга'},
      'fields': [
        {'key': 'Title', 'field': 'title', 'kind': 'text'},
      ],
    });
    await LibraryRepository(local, namespace).mutate((entries) async {
      entries[item.id] = LibraryEntry(item, sourceBookId: book.id);
    });
    return book.id;
  }

  test('capture keeps local days and audible intervals; player summaries do not double count', () async {
    final reading = await link('one'),
        audio = await link('one', format: 'audio');
    await local.setMeta(
      'reading-session:session',
      jsonEncode({
        'bookId': reading,
        'closed': true,
        'spans': [
          {
            'start': '2026-10-02T20:59:00Z',
            'end': '2026-10-02T21:00:00Z',
            'newChars': 100,
            'localDay': '2026-10-02',
            'offsetMinutes': 180,
          },
          {
            'start': '2026-10-02T21:00:00Z',
            'end': '2026-10-02T21:02:00Z',
            'newChars': 200,
            'localDay': '2026-10-03',
            'offsetMinutes': 180,
          },
        ],
      }),
    );
    final journal = AudioJournal(local);
    await journal.put('audio_event', uuid.v4(), {
      'bookId': audio,
      'kind': 'listen',
      'at': '2026-10-02T21:10:00Z',
      'localDay': '2026-10-03',
      'offsetMinutes': 180,
      'wallMs': 60000,
      'mediaMs': 120000,
      'positionMs': 0,
      'endMs': 120000,
    });
    await local.put('session', uuid.v4(), {
      'bookId': audio,
      'kind': 'listening',
      'source': 'player',
      'startedAt': '2026-10-02T21:10:00Z',
      'endedAt': '2026-10-02T21:11:00Z',
      'activeSeconds': 60,
    });
    final store = ActivityStore(local, 'one');
    await store.capture();
    final rows = await store.entries();
    expect(rows.length, 3);
    expect(
      rows.fold<int>(0, (n, s) => n + (s['value']['durationMs'] as int)),
      240000,
    );
    expect(
      rows
          .where((s) => s['value']['mediaType'] == 'audiobook')
          .single['value']['progress'],
      2,
    );
    final before = await store.pending();
    await store.capture();
    expect(await store.pending(), before);
    expect(
      (await store.entries())
          .where((s) => s['value']['day'] == '2026-10-02')
          .length,
      1,
    );
    expect(await ActivityStore(local, 'two').entries(), isEmpty);
  });
  test('durable request IDs survive restart and acknowledgement preserves a newer offline edit', () async {
    final book = await link('one'), id = uuid.v4();
    await local.put('session', id, {
      'bookId': book,
      'kind': 'reading',
      'startedAt': '2026-10-03T10:00:00Z',
      'endedAt': '2026-10-03T10:10:00Z',
      'activeSeconds': 600,
      'note': 'first',
    });
    final store = ActivityStore(local, 'one');
    await store.capture();
    final op = (await store.pending()).single;
    expect(await ActivityStore(local, 'one').pending(), [op]);
    await local.put('session', id, {
      'bookId': book,
      'kind': 'reading',
      'startedAt': '2026-10-03T10:00:00Z',
      'endedAt': '2026-10-03T10:10:00Z',
      'activeSeconds': 600,
      'note': 'offline',
    });
    await store.capture();
    await store.receipts([
      {
        'operationId': op['operationId'],
        'status': 'applied',
        'record': {'entry': op['entry'], 'revision': 1, 'sequence': 1},
      },
    ]);
    final next = (await store.pending()).single;
    expect(next['baseRevision'], 1);
    expect(next['entry']['note'], 'offline');
    expect(next['operationId'], isNot(op['operationId']));
  });
  test('remote edits and deletion update native reading totals without resurrecting deleted spans', () async {
    final book = await link('one');
    await local.setMeta(
      'reading-session:session',
      jsonEncode({
        'bookId': book,
        'closed': true,
        'spans': [
          {
            'start': '2026-10-03T10:00:00Z',
            'end': '2026-10-03T10:10:00Z',
            'newChars': 100,
            'repeatChars': 20,
            'localDay': '2026-10-03',
            'offsetMinutes': 0,
          },
        ],
      }),
    );
    final store = ActivityStore(local, 'one');
    await store.capture();
    final op = (await store.pending()).single,
        value = Map<String, dynamic>.from(op['entry']);
    await store.receipts([
      {
        'operationId': op['operationId'],
        'status': 'applied',
        'record': {'entry': value, 'revision': 1, 'sequence': 1},
      },
    ]);
    final edit = {...value, 'durationMs': 300000, 'progress': 50};
    await store.receive([
      {'entry': edit, 'revision': 2, 'sequence': 2},
    ], 2);
    final data = jsonDecode(
      (await local.meta('reading-session:session'))!,
    ) as Map<String, dynamic>;
    expect(readingTotals([data]).milliseconds, 300000);
    expect(readingTotals([data]).newChars, 50);
    await store.capture();
    expect(await store.pending(), isEmpty);
    await store.receive([
      {
        'entry': {...edit, 'deleted': true},
        'revision': 3,
        'sequence': 3,
      },
    ], 3);
    final deleted = jsonDecode(
      (await local.meta('reading-session:session'))!,
    ) as Map<String, dynamic>;
    expect(readingTotals([deleted]).milliseconds, 0);
    expect(readingTotals([deleted]).repeatChars, 0);
    await store.capture();
    expect(await store.entries(), isEmpty);
    expect(await store.pending(), isEmpty);
  });
  test('foreign journal appears in statistics once; unknown audio positions do not claim coverage', () async {
    await link('one');
    await link('one', format: 'audio');
    await local.setMeta('obsidian-active-namespace', 'one');
    final links = (await LibraryRepository(
      local,
      'one',
    ).entries()).values.toList();
    final reading = links.firstWhere((e) => e.item.mediaType == 'book'),
        audio = links.firstWhere((e) => e.item.mediaType == 'audiobook');
    final values = [
      ActivityStore.entry(
        id: uuid.v4(),
        itemId: reading.item.id,
        mediaType: 'book',
        day: '2026-10-03',
        durationMs: 600000,
        progress: 20,
        unit: 'pages',
        origin: 'obsidian',
      ),
      ActivityStore.entry(
        id: uuid.v4(),
        itemId: audio.item.id,
        mediaType: 'audiobook',
        day: '2026-10-03',
        durationMs: 1200000,
        progress: 0,
        unit: 'minutes',
        origin: 'obsidian',
      ),
    ];
    final store = ActivityStore(local, 'one');
    await store.receive([
      for (var i = 0; i < values.length; i++)
        {'entry': values[i], 'revision': 1, 'sequence': i + 1},
    ], 2);
    await store.capture();
    expect(await store.pending(), isEmpty);
    final sessions = await ActivityStore.foreignReading(local);
    expect(readingTotals(sessions).milliseconds, 600000);
    expect(readingTotals(sessions).newChars, 0);
    expect(sessions.single['timeKnown'], false);
    final events = await ActivityStore.foreignAudio(local),
        stats = AudioStats(events);
    expect(stats.wallMs, 1200000);
    expect(stats.uniqueMs, 0);
    expect(stats.repeatedMs, 0);
    expect(stats.averageSpeed, 0);
    final analysis = analyzeListening({'events': events});
    expect(analysis.sessions.single.timeKnown, false);
    await local.setMeta('obsidian-active-namespace', 'two');
    expect(await ActivityStore.foreignReading(local), isEmpty);
  });
  test('concurrent source edits retain both journal versions and require explicit resolution', () async {
    final book = await link('one'), id = uuid.v4();
    await local.put('session', id, {
      'bookId': book,
      'kind': 'reading',
      'startedAt': '2026-10-03T10:00:00Z',
      'endedAt': '2026-10-03T10:10:00Z',
      'activeSeconds': 600,
      'note': 'first',
    });
    final store = ActivityStore(local, 'one');
    await store.capture();
    final op = (await store.pending()).single,
        value = Map<String, dynamic>.from(op['entry']);
    await store.receipts([
      {
        'operationId': op['operationId'],
        'status': 'applied',
        'record': {'entry': value, 'revision': 1, 'sequence': 1},
      },
    ]);
    await local.put('session', id, {
      ...(await local.record(id))!.payload!,
      'activeSeconds': 900,
    });
    await store.receive([
      {
        'entry': {...value, 'durationMs': 1200000},
        'revision': 2,
        'sequence': 2,
      },
    ], 2);
    expect((await store.entries()).single['conflict'], isNotNull);
    expect((await local.record(id))!.payload!['activeSeconds'], 900);
  });
  test('manual sessions split at saved local midnight and partial deletion preserves the other day', () async {
    final book = await link('one'), id = uuid.v4();
    await local.put('session', id, {
      'bookId': book,
      'kind': 'reading',
      'startedAt': '2026-10-02T20:59:00Z',
      'endedAt': '2026-10-02T21:01:00Z',
      'offsetMinutes': 180,
      'activeSeconds': 61,
      'note': 'night',
    });
    final store = ActivityStore(local, 'one');
    await store.capture();
    final operations = await store.pending();
    expect(operations.length, 2);
    expect(operations.map((o) => o['entry']['day']).toSet(), {
      '2026-10-02',
      '2026-10-03',
    });
    expect(
      operations.fold<int>(0, (n, o) => n + (o['entry']['durationMs'] as int)),
      61000,
    );
    await store.receipts([
      for (var i = 0; i < operations.length; i++)
        {
          'operationId': operations[i]['operationId'],
          'status': 'applied',
          'record': {
            'entry': operations[i]['entry'],
            'revision': 1,
            'sequence': i + 1,
          },
        },
    ]);
    final changed = {
      ...operations.last['entry'] as Map<String, dynamic>,
      'progress': 12,
      'note': 'edited',
    };
    await store.edit(changed['id'] as String, changed);
    await store.capture();
    expect((await store.pending()).single['entry']['progress'], 12);
    final update = (await store.pending()).single;
    await store.receipts([
      {
        'operationId': update['operationId'],
        'status': 'applied',
        'record': {'entry': update['entry'], 'revision': 2, 'sequence': 3},
      },
    ]);
    await store.receive([
      {
        'entry': {
          ...operations.first['entry'] as Map<String, dynamic>,
          'deleted': true,
        },
        'revision': 2,
        'sequence': 3,
      },
    ], 3);
    final row = await local.record(id);
    expect(row!.deleted, false);
    expect(
      ActivityStore.manualSpans(row.payload!)
          .where((s) => s['pepehubDeleted'] != true)
          .length,
      1,
    );
    await store.capture();
    expect(await store.pending(), isEmpty);
  });
}
