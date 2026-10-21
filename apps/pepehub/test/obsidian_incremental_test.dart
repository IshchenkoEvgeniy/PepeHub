import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/library_repository.dart';
import 'package:pepehub/library/obsidian_sync_service.dart';
import 'package:pepehub/library/models.dart';

import 'obsidian_library_test.dart' show card, snapshot;

void main() {
  const index = '11111111-1111-4111-8111-111111111111',
      a = '22222222-2222-4222-8222-222222222222',
      b = '33333333-3333-4333-8333-333333333333';
  late AppDatabase db;
  late Repository local;
  late LibraryRepository repository;
  final config = ObsidianConfig('https://example.test', 'test-token');
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    local = Repository(db);
    repository = LibraryRepository(local, config.namespace);
    await local.setMeta('obsidian-sync-history', 'false');
    await local.setMeta('obsidian-sync-notes', 'false');
  });
  tearDown(() => db.close());
  http.Response json(
    Object value, {
    Map<String, String> headers = const {},
    int status = 200,
  }) => http.Response(
    jsonEncode(value),
    status,
    headers: {'content-type': 'application/json; charset=utf-8', ...headers},
  );

  test('one full bootstrap is followed by delta-only updates, deletion and an empty idle page', () async {
    var full = 0, pulls = 0;
    final initial = snapshot([card(a, title: 'A'), card(b, title: 'B')]);
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/changes')) {
        pulls++;
        expect(request.url.queryParameters['index'], index);
        return json({
          'version': 1,
          'indexId': index,
          'cursor': 3,
          'hasMore': false,
          'schema': {...initial}..remove('items'),
          'changes': pulls == 1
              ? [
                  {'id': a, 'item': card(a, title: 'Edited')},
                  {'id': b, 'item': null},
                ]
              : [],
        });
      }
      full++;
      return json(
        initial,
        headers: {'x-pepehub-index': index, 'x-pepehub-cursor': '1'},
      );
    });
    addTearDown(client.close);
    final service = ObsidianSyncService(repository, client, config);
    await service.run();
    await service.run();
    await service.run();
    expect(full, 1);
    expect(pulls, 2);
    final values = await repository.entries();
    expect(values[a]!.item.title, 'Edited');
    expect(values[b]!.state, 'removed');
    expect((await repository.snapshot())!['_cursor'], 3);
  });

  test(
    'delta keeps a pending local edit and rejects a malformed page atomically',
    () async {
      final initial = {
        ...snapshot([card(a, title: 'Original')]),
        '_indexId': index,
        '_cursor': 1,
      };
      await repository.receive(initial);
      await repository.mutate((entries) async {
        final old = entries[a]!;
        entries[a] = LibraryEntry(
          old.item.withValues({...old.item.values, 'Title': 'Local'}),
          state: 'pending',
          operation: {'operationId': b},
        );
      });
      final schema = {...snapshot([])}..remove('items');
      await repository.receiveChanges({
        'indexId': index,
        'cursor': 2,
        'schema': schema,
        'changes': [
          {'id': a, 'item': card(a, title: 'Remote')},
        ],
      });
      var entry = (await repository.entries())[a]!;
      expect(entry.item.title, 'Local');
      expect(entry.remote!.title, 'Remote');
      expect(entry.operation, isNotNull);
      await expectLater(
        repository.receiveChanges({
          'indexId': index,
          'cursor': 3,
          'schema': schema,
          'changes': [
            {'id': a, 'item': card(a, title: 'Should roll back')},
            {'id': b, 'item': card(a)},
          ],
        }),
        throwsFormatException,
      );
      entry = (await repository.entries())[a]!;
      expect(entry.remote!.title, 'Remote');
      expect((await repository.snapshot())!['_cursor'], 2);
    },
  );

  test('explicit cursor reset retrieves one fresh snapshot without deleting pending data', () async {
    await repository.receive({
      ...snapshot([card(a)]),
      '_indexId': index,
      '_cursor': 100,
    });
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      if (request.url.path.endsWith('/changes')) {
        return json({'reset': true}, status: 409);
      }
      return json(snapshot([card(a, title: 'After reset')]));
    });
    addTearDown(client.close);
    await ObsidianSyncService(repository, client, config).run();
    expect(calls, 2);
    expect((await repository.entries())[a]!.item.title, 'After reset');
  });
}
