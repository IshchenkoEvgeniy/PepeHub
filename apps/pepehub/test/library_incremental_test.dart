
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/library_repository.dart';
import 'connector_namespace.dart';
import 'package:pepehub/library/models.dart';

import 'library_archive_test.dart' show card, snapshot;

void main() {
  const index = '11111111-1111-4111-8111-111111111111',
      a = '22222222-2222-4222-8222-222222222222',
      b = '33333333-3333-4333-8333-333333333333';
  late AppDatabase db;
  late Repository local;
  late LibraryRepository repository;
  final config = LegacyConnector('https://example.test', 'test-token');
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    local = Repository(db);
    repository = LibraryRepository(local, config.namespace);
    await local.setMeta('obsidian-sync-history', 'false');
    await local.setMeta('obsidian-sync-notes', 'false');
  });
  tearDown(() => db.close());
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

}
