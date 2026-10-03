import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/library_repository.dart';
import 'package:pepehub/library/library_service.dart';
import 'package:pepehub/library/obsidian_sync_service.dart';
import 'package:uuid/uuid.dart';

final fields = [
  {'key': 'Title', 'field': 'title', 'kind': 'text'},
  {'key': 'Author', 'field': 'author', 'kind': 'list'},
  {'key': 'Дата завершения', 'field': 'endDate', 'kind': 'text'},
];
Map<String, dynamic> card(String id, {String title = 'Одинаковое название'}) =>
    {
      'id': id,
      'path': 'Books/$id.md',
      'collectionId': 'book',
      'mediaType': 'book',
      'modifiedAt': 1,
      'fields': fields,
      'values': {
        'Title': title,
        'Author': ['Автор'],
        'Дата завершения': null,
        'Custom': {
          'tags': ['a'],
          'favorite': false,
        },
      },
    };
Map<String, dynamic> snapshot(List<Map<String, dynamic>> items) => {
  'version': 1,
  'ready': true,
  'items': items,
  'fields': fields,
  'collections': [
    {'id': 'book', 'mediaType': 'book', 'title': 'Books'},
  ],
};
http.Response jsonResponse(Object data) => http.Response(
  jsonEncode(data),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  late AppDatabase db;
  late Repository local;
  final config = ObsidianConfig('https://example.test', 'test-token');
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    local = Repository(db);
    await local.setMeta('obsidian-sync-history', 'false');
    await local.setMeta('obsidian-sync-notes', 'false');
  });
  tearDown(() => db.close());
  test('120 Obsidian cards are automatic, 300 local books never leave the app, and repeated pulls deduplicate', () async {
    for (var i = 0; i < 300; i++) {
      await local.addBook('Local $i', 'Автор', 'epub');
    }
    final data = snapshot([
      for (var i = 0; i < 120; i++)
        card(const Uuid().v5(Namespace.url.value, 'remote:$i')),
    ]);
    final requests = <String>[];
    final client = MockClient((request) async {
      requests.add(request.method);
      return jsonResponse(data);
    });
    final service = LibraryService(local, client);
    addTearDown(service.dispose);
    addTearDown(client.close);
    await service.connect(config);
    await service.sync();
    expect(service.error, isNull);
    expect(service.entries.length, 120);
    expect((await local.records('book')).length, 300);
    expect(requests, ['GET', 'GET']);
    expect(service.entries.first.item.values['Дата завершения'], isNull);
    expect(service.entries.first.item.values['Custom'], {
      'tags': ['a'],
      'favorite': false,
    });
  });
  test('manual creation survives network failure and restart; one UUID is retried without files', () async {
    final repo = LibraryRepository(local, config.namespace);
    await repo.receive(snapshot([]));
    await local.addBook('Local', 'Автор', 'audio');
    final book = (await local.records('book')).single;
    final client = MockClient(
      (_) async => throw http.ClientException('offline'),
    );
    final service = LibraryService(local, client);
    await service.connect(config);
    final draft = service.draft(book, {
      'durationMinutes': 120,
      'listenedMinutes': 3,
      'cover': 'C:/private/cover.png',
    });
    await service.add(draft, book.id);
    await service.add(draft, book.id);
    expect((await repo.entries()).length, 1);
    final pending = (await repo.entries()).values.single;
    expect(pending.pending, isTrue);
    expect(pending.operation!['values'], isNot(contains('cover')));
    final operationId = pending.operation!['operationId'];
    service.dispose();
    client.close();
    final received = <Map<String, dynamic>>[];
    final online = MockClient((request) async {
      if (request.method == 'POST') {
        received.add(jsonDecode(request.body) as Map<String, dynamic>);
      }
      return jsonResponse(
        request.url.path.endsWith('/library')
            ? snapshot([])
            : {'operationId': operationId, 'status': 'pending'},
      );
    });
    final resumed = LibraryService(local, online);
    addTearDown(resumed.dispose);
    addTearDown(online.close);
    await resumed.connect(config);
    await resumed.sync();
    expect(received.length, 2);
    expect(received.map((op) => op['operationId']).toSet(), {operationId});
    expect(received.map((op) => op['itemId']).toSet(), {draft.id});
    expect(resumed.entries.single.item.mediaType, 'audiobook');
  });
  test('blank finish date is editable and only changed fields go back; stale editor bases are retained', () async {
    final id = const Uuid().v4(), data = snapshot([card(const Uuid().v4())]);
    data['items'] = [card(id)];
    final posts = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      if (request.method == 'POST') {
        posts.add(jsonDecode(request.body) as Map<String, dynamic>);
      }
      return jsonResponse(
        request.url.path.endsWith('/library')
            ? data
            : {'operationId': posts.last['operationId'], 'status': 'pending'},
      );
    });
    final service = LibraryService(local, client);
    addTearDown(service.dispose);
    addTearDown(client.close);
    await service.connect(config);
    expect(service.error, isNull);
    final original = {...service.entries.single.item.values};
    (data['items'][0]['values'] as Map)['Title'] = 'Changed in Obsidian';
    await service.sync();
    await service.save(id, {
      ...original,
      'Дата завершения': '2026-10-03',
    }, original: original);
    expect(posts.single['values'], {'Дата завершения': '2026-10-03'});
    expect(posts.single['base'], {'Дата завершения': null});
    expect(service.entries.single.item.title, 'Changed in Obsidian');
    expect(service.entries.single.item.values['Дата завершения'], '2026-10-03');
  });
  test('conflict keeps local values and remote metadata; explicit resolution restores remote', () async {
    final repo = LibraryRepository(local, config.namespace),
        id = const Uuid().v4();
    await repo.receive(snapshot([card(id)]));
    final client = MockClient(
      (_) async => throw http.ClientException('offline'),
    );
    final service = LibraryService(local, client);
    addTearDown(service.dispose);
    addTearDown(client.close);
    await service.connect(config);
    final original = service.entries.single.item.values;
    await service.save(id, {
      ...original,
      'Title': 'Local edit',
    }, original: original);
    final queued = (await repo.entries())[id]!;
    await repo.receipt(id, {
      'operationId': queued.operation!['operationId'],
      'status': 'conflict',
      'message': 'Title changed',
    });
    await repo.receive(snapshot([card(id, title: 'Remote edit')]));
    await service.reload();
    expect(service.entries.single.item.title, 'Local edit');
    expect(service.entries.single.remote!.title, 'Remote edit');
    await service.useObsidian(id);
    expect(service.entries.single.item.title, 'Remote edit');
    expect(service.entries.single.operation, isNull);
  });
  test('renames preserve identity, deletions never enqueue creation, namespaces are isolated', () async {
    final repo = LibraryRepository(local, config.namespace),
        id = const Uuid().v4();
    await repo.receive(snapshot([card(id)]));
    await repo.receive(
      snapshot([
        {...card(id), 'path': 'Moved/Renamed.md'},
      ]),
    );
    expect((await repo.entries()).length, 1);
    expect((await repo.entries())[id]!.item.path, 'Moved/Renamed.md');
    await repo.receive(snapshot([]));
    expect((await repo.entries())[id]!.state, 'removed');
    expect((await repo.entries())[id]!.operation, isNull);
    expect(
      await LibraryRepository(
        local,
        ObsidianConfig('https://other.test', 'token').namespace,
      ).entries(),
      isEmpty,
    );
  });
  test(
    'API token requires HTTPS and is not forwarded through redirects',
    () async {
      expect(
        () => ObsidianConfig('http://example.test', 'token'),
        throwsFormatException,
      );
      expect(
        () => ObsidianConfig('https://user:password@example.test', 'token'),
        throwsFormatException,
      );
      expect(
        ObsidianConfig('http://localhost:8080', 'token').url,
        'http://localhost:8080',
      );
      final client = MockClient((request) async {
        expect(request.followRedirects, isFalse);
        return http.Response('', 302);
      });
      addTearDown(client.close);
      await expectLater(
        ObsidianSyncService(
          LibraryRepository(local, config.namespace),
          client,
          config,
        ).run(),
        throwsStateError,
      );
    },
  );
}
