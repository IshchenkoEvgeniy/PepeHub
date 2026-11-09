import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/library_repository.dart';
import 'package:pepehub/library/library_service.dart';
import 'connector_namespace.dart';
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
    {'id': 'audiobook', 'mediaType': 'audiobook', 'title': 'Audio'},
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
  final config = LegacyConnector('https://example.test', 'test-token');
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    local = Repository(db);
    await local.setMeta('obsidian-sync-history', 'false');
    await local.setMeta('obsidian-sync-notes', 'false');
  });
  tearDown(() => db.close());
  test('cached legacy cards migrate once without automatically adding local sources', () async {
    for (var i = 0; i < 300; i++) {
      await local.addBook('Local $i', 'Автор', 'epub');
    }
    final cached = LibraryRepository(local, config.namespace);
    await cached.receive(
      snapshot([
        for (var i = 0; i < 120; i++)
          card(const Uuid().v5(Namespace.url.value, 'remote:$i')),
      ]),
    );
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      throw StateError('Unexpected network');
    });
    final service = LibraryService(local, client);
    addTearDown(service.dispose);
    addTearDown(client.close);
    await service.reload();
    await service.reload();
    expect(service.entries, hasLength(120));
    expect(requests, 0);
    expect(service.completed, isEmpty);
    final imported = service.entries.where(
      (e) => e.item.values['Custom'] != null,
    );
    expect(imported, hasLength(120));
    expect(imported.first.item.values['Custom'], {
      'tags': ['a'],
      'favorite': false,
    });
  });
  test('manual cards survive restart without files, a connector or a network queue', () async {
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      throw StateError('Unexpected network');
    });
    addTearDown(client.close);
    final service = LibraryService(local, client);
    await service.reload();
    final draft = service.emptyDraft(audio: true).withValues({
      ...service.emptyDraft(audio: true).values,
      'title': 'Аудиокнига',
      'status': 'finished',
      'unit': 'minutes',
      'total': 120,
      'progress': 120,
    });
    await service.add(draft, '');
    await service.add(draft, '');
    expect(service.completed.single.item.id, draft.id);
    expect(await LibraryRepository(local, config.namespace).entries(), isEmpty);
    service.dispose();
    final resumed = LibraryService(local, client);
    addTearDown(resumed.dispose);
    await resumed.reload();
    expect(resumed.completed.single.item.id, draft.id);
    expect(resumed.completed.single.item.mediaType, 'audiobook');
    expect(requests, 0);
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
        LegacyConnector('https://other.test', 'token').namespace,
      ).entries(),
      isEmpty,
    );
  });
}
