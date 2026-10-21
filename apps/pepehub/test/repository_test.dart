import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/sync/sync_client.dart';

void main() {
  // Tests deliberately emulate separate devices with independent executors.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late AppDatabase db;
  late Repository repository;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repository = Repository(db);
    await repository.setCloudTracking(true);
  });
  tearDown(() async {
    await db.close();
  });
  Map<String, dynamic> entity(LibraryRecord b, int revision, String title) => {
    'entityId': b.id,
    'entityType': 'book',
    'revision': revision,
    'deleted': false,
    'payload': {...b.payload!, 'title': title},
  };

  test('local edit and outbox commit together, successive offline revisions are ordered', () async {
    await repository.addBook('Первая', 'Автор', 'epub');
    final b = (await repository.records('book')).single;
    await repository.put('book', b.id, {...b.payload!, 'title': 'Вторая'});
    final pending = await repository.pending();
    expect(pending.length, 2);
    expect(
      pending.map(
        (r) => (jsonDecode(r.read<String>('operation')) as Map)['baseRevision'],
      ),
      [0, 1],
    );
    expect((await repository.record(b.id))!.revision, 2);
  });
  test('queued data survives closing and reopening the database', () async {
    final directory = await Directory.systemTemp.createTemp('pepehub-test-');
    final file = File('${directory.path}/library.sqlite');
    final first = AppDatabase(NativeDatabase(file));
    await Repository(first).setCloudTracking(true);
    await Repository(first).addBook('Офлайн', 'Автор', 'audio');
    await first.close();
    final second = AppDatabase(NativeDatabase(file));
    try {
      expect((await Repository(second).records('book')).single.title, 'Офлайн');
      expect(await Repository(second).pendingCount(), 1);
    } finally {
      await second.close();
      await directory.delete(recursive: true);
    }
  });
  test(
    'lost HTTP response preserves outbox and retries the same operation ID',
    () async {
      await repository.addBook('Книга', '', 'epub');
      final op = jsonDecode(
        (await repository.pending()).single.read<String>('operation'),
      ) as Map<String, dynamic>;
      final ids = <String>[];
      var fail = true;
      final client = MockClient((request) async {
        if (request.url.path == '/v1/me') {
          return http.Response(jsonEncode({'deviceId': op['deviceId']}), 200);
        }
        if (request.url.path == '/v1/operations') {
          final posted = jsonDecode(request.body) as Map<String, dynamic>;
          ids.add(posted['operationId'] as String);
          if (fail) {
            fail = false;
            throw const SocketException('lost response');
          }
          return http.Response(
            jsonEncode({
              'operationId': posted['operationId'],
              'status': 'accepted',
              'current': {
                'entityId': posted['entityId'],
                'entityType': 'book',
                'revision': 1,
                'deleted': false,
                'payload': posted['payload'],
              },
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (request.url.path == '/v1/changes') {
          return http.Response(
            jsonEncode({
              'schemaVersion': 1,
              'changes': [],
              'cursor': 0,
              'hasMore': false,
            }),
            200,
          );
        }
        return http.Response('{"ok":true}', 200);
      });
      final sync = SyncClient(repository, client);
      final config = SyncConfig(
        'http://localhost:8787',
        op['deviceId'] as String,
        'x' * 64,
      );
      await expectLater(sync.run(config), throwsA(isA<SocketException>()));
      expect(await repository.pendingCount(), 1);
      await sync.run(config);
      expect(await repository.pendingCount(), 0);
      expect(ids, [op['operationId'], op['operationId']]);
      client.close();
    },
  );
  test('pull preserves unsent local edits and conflict resolution uses latest remote version', () async {
    await repository.addBook('Локальная', '', 'epub');
    final b = (await repository.records('book')).single;
    final op = jsonDecode(
      (await repository.pending()).single.read<String>('operation'),
    ) as Map<String, dynamic>;
    await repository.applyReceipt({
      'operationId': op['operationId'],
      'status': 'conflict',
      'current': entity(b, 1, 'Серверная'),
    });
    await repository.applyPage({
      'changes': [entity(b, 2, 'Новая серверная')],
      'cursor': 2,
    });
    expect((await repository.record(b.id))!.title, 'Локальная');
    expect(await repository.meta('cursor'), '2');
    expect((await repository.conflicts()).length, 1);
    await repository.useServerVersion(op['operationId'] as String);
    expect((await repository.record(b.id))!.title, 'Новая серверная');
    expect(await repository.pendingCount(), 0);
  });
  test('pending operation is retained when transaction fails', () async {
    await db.customStatement(
      "CREATE TRIGGER block_queue BEFORE INSERT ON outbox BEGIN SELECT RAISE(ABORT,'injected'); END",
    );
    await expectLater(
      repository.addBook('Не сохранена', '', 'epub'),
      throwsA(anything),
    );
    expect(await repository.records('book'), isEmpty);
    expect(await repository.pendingCount(), 0);
  });
  test(
    'manual session emits canonical UTC dates and bounded active duration',
    () async {
      await repository.addBook('Аудио', '', 'audio');
      await repository.addSession(
        (await repository.records('book')).single,
        20,
      );
      final s = (await repository.records('session')).single.payload!;
      expect(s['activeSeconds'], 1200);
      expect(s['kind'], 'listening');
      expect(
        s['startedAt'],
        matches(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$')),
      );
    },
  );
}
