import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pepehub/audio/audio_folder.dart';
import 'package:pepehub/audio/audio_journal.dart';
import 'package:pepehub/audio/audio_link.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/library_repository.dart';
import 'package:pepehub/library/models.dart';
import 'package:pepehub/library/note_store.dart';
import 'package:pepehub/library/obsidian_sync_service.dart';
import 'package:pepehub/media/asset_store.dart';

class LinkedNoteSource extends FolderAudioFile {
  LinkedNoteSource(super.path, super.relativePath);
  @override
  Future<int> length() async => 100;
  @override
  Stream<Uint8List> openRead([int? start, int? end]) =>
      throw StateError('Connecting or syncing notes must not read audio bytes');
}

void main() {
  late AppDatabase db;
  late Repository local;
  late NoteStore store;
  late ObsidianConfig config;
  late ObsidianLibraryItem item;
  late String book;
  late List<LocalAsset> tracks;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory(logStatements: true));
    local = Repository(db);
    book = await AudioLinkService(local).connect(
      [
        LinkedNoteSource('content://provider/tree/book/document/1', '01.mp3'),
        LinkedNoteSource('content://provider/tree/book/document/2', '02.mp3'),
      ],
      root: 'content://provider/tree/book',
      title: 'Linked audiobook',
    );
    tracks = await AssetStore(local, Directory('.')).audioTracks(book);
    config = ObsidianConfig('https://example.test', 'test-token');
    item = ObsidianLibraryItem(
      id: uuid.v4(),
      path: 'Audio/One.md',
      collectionId: 'audiobook',
      mediaType: 'audiobook',
      values: {'Title': 'Linked audiobook'},
      fields: const [],
    );
    await LibraryRepository(local, config.namespace).mutate((entries) async {
      entries[item.id] = LibraryEntry(item, sourceBookId: book);
    });
    store = NoteStore(local, config.namespace);
  });
  tearDown(() => db.close());

  Future<String> save({String? id, String text = 'Thought', int track = 1}) =>
      AudioJournal(local).saveNote(
        id: id,
        bookId: book,
        trackId: tracks[track].id,
        positionMs: 45000,
        kind: 'thought',
        title: 'Note',
        text: text,
      );

  test('linked audio notes use ordinal anchors without reading or exporting source URIs', () async {
    await save();
    await store.capture();
    final operation = (await store.pending()).single;
    expect(tracks[1].hash, startsWith('external:'));
    expect(operation['entry']['anchor'], {
      'positionMs': 45000,
      'noteKind': 'thought',
      'trackIndex': 1,
    });
    expect(validNoteValue(operation['entry']), true);
    expect(jsonEncode(operation), isNot(contains('content://')));
    expect(await store.pending(), [operation]);
  });
  test('capturing many notes reads tracks once per book and preserves note identities', () async {
    for (var i = 0; i < 20; i++) {
      await save(text: 'Thought $i', track: i % 2);
    }
    final queries = <String>[];
    await runZoned(
      () => store.capture(),
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) {
          if (line.contains('FROM audio_tracks')) queries.add(line);
        },
      ),
    );
    expect(queries, hasLength(1));
    final operations = await store.pending();
    expect(operations, hasLength(20));
    await store.capture();
    expect(await store.pending(), operations);
  });

  test('old rejected external-hash requests are repaired with a new durable UUID and latest text', () async {
    final id = await save();
    await store.capture();
    final operation = (await store.pending()).single;
    final bad = {
      ...operation['entry'] as Map,
      'anchor': {
        ...operation['entry']['anchor'] as Map,
        'trackHash': tracks[1].hash,
      },
    };
    await store.mutate((state) async {
      final slot = state['slots'][bad['id']];
      slot['value'] = bad;
      slot['native'] = bad;
      slot['operation'] = {...operation, 'entry': bad};
    });
    await save(id: id, text: 'Latest offline edit');
    await store.capture();
    final repaired = (await store.pending()).single;
    expect(repaired['operationId'], isNot(operation['operationId']));
    expect(repaired['entry']['id'], bad['id']);
    expect(repaired['baseRevision'], operation['baseRevision']);
    expect(repaired['entry']['text'], 'Latest offline edit');
    expect(validNoteValue(repaired['entry']), true);
    expect(await NoteStore(Repository(db), config.namespace).pending(), [
      repaired,
    ]);
    await store.receipts([
      {
        'operationId': repaired['operationId'],
        'status': 'applied',
        'record': {'entry': repaired['entry'], 'revision': 1, 'sequence': 1},
      },
    ]);
    expect(await store.pending(), isEmpty);
  });

  test(
    'a valid lost-response retry stays immutable while native text changes',
    () async {
      final id = await save();
      await store.capture();
      final original = (await store.pending()).single;
      await save(id: id, text: 'Later edit');
      await store.capture();
      expect(await store.pending(), [original]);
      await store.receipts([
        {
          'operationId': original['operationId'],
          'status': 'applied',
          'record': {'entry': original['entry'], 'revision': 1, 'sequence': 1},
        },
      ]);
      final next = (await store.pending()).single;
      expect(next['operationId'], isNot(original['operationId']));
      expect(next['baseRevision'], 1);
      expect(next['entry']['text'], 'Later edit');
    },
  );

  test('two linked-track notes complete HTTP exchange and remote edits return to the correct track', () async {
    final ids = [await save(track: 0), await save(track: 1)];
    await local.setMeta('obsidian-sync-history', 'false');
    final changes = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      expect(request.headers['Authorization'], 'Bearer test-token');
      Map<String, dynamic> body;
      if (request.url.path.endsWith('/library')) {
        body = {
          'version': 1,
          'ready': true,
          'items': [item.toJson()],
          'fields': [],
          'collections': [],
        };
      } else if (request.method == 'POST') {
        final operations =
            (jsonDecode(request.body) as Map)['operations'] as List;
        for (final operation in operations) {
          expect(validNoteValue(operation['entry']), true);
          expect(operation['entry']['anchor'].containsKey('trackHash'), false);
          changes.add({
            'entry': operation['entry'],
            'revision': 1,
            'sequence': changes.length + 1,
          });
        }
        body = {
          'version': 1,
          'receipts': [
            for (var i = 0; i < operations.length; i++)
              {
                'operationId': operations[i]['operationId'],
                'status': 'applied',
                'record': changes[i],
              },
          ],
        };
      } else {
        final secondTrack = changes.singleWhere(
          (c) => c['entry']['anchor']['trackIndex'] == 1,
        );
        final edited = {
          ...secondTrack,
          'revision': 2,
          'sequence': 3,
          'entry': {
            ...secondTrack['entry'] as Map,
            'text': 'Edited in Obsidian',
            'updatedAt': '2026-10-13T10:00:00.000Z',
          },
        };
        body = {
          'version': 1,
          'records': [...changes, edited],
          'cursor': 3,
          'hasMore': false,
        };
      }
      return http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    addTearDown(client.close);
    await ObsidianSyncService(
      LibraryRepository(local, config.namespace),
      client,
      config,
    ).run();
    expect(changes, hasLength(2));
    expect(await store.pending(), isEmpty);
    expect((await local.record(ids[0]))!.payload!['trackId'], tracks[0].id);
    expect((await local.record(ids[1]))!.payload!['trackId'], tracks[1].id);
    expect(
      (await local.record(ids[1]))!.payload!['text'],
      'Edited in Obsidian',
    );
    expect((await store.state())['cursor'], 3);
  });
}
