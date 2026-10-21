import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';

void main() {
  late AppDatabase db;
  late Repository repo;
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = Repository(db);
  });
  tearDown(() => db.close());
  Map<String, dynamic> remote(LibraryRecord book, int revision, String title) =>
      {
        'entityId': book.id,
        'entityType': 'book',
        'revision': revision,
        'deleted': false,
        'payload': {...book.payload!, 'title': title},
      };
  Future<Map<String, dynamic>> operation() async =>
      jsonDecode((await repo.pending()).single.read<String>('operation'))
          as Map<String, dynamic>;

  test(
    'default local edits, sessions and deletions create no cloud queue',
    () async {
      await repo.addBook('Local', '', 'epub');
      final book = (await repo.records('book')).single;
      for (var i = 0; i < 100; i++) {
        await repo.put('book', book.id, {
          ...book.payload!,
          'title': 'Local $i',
        });
      }
      await repo.addSession((await repo.record(book.id))!, 1);
      await repo.delete('book', book.id);
      expect(await repo.pendingCount(), 0);
      expect((await repo.record(book.id))!.deleted, true);
      expect(await repo.records('session'), hasLength(1));
    },
  );

  test('legacy frozen operations and conflict receipts are archived exactly and do not block local edits', () async {
    await repo.setCloudTracking(true);
    await repo.addBook('Legacy', '', 'epub');
    final book = (await repo.records('book')).single,
        queued = await operation();
    await repo.freezeOperation(queued['operationId'] as String);
    await repo.applyReceipt({
      'operationId': queued['operationId'],
      'status': 'conflict',
      'current': remote(book, 4, 'Cloud'),
    });
    final before = (await repo.conflicts()).single;
    await repo.setCloudTracking(false);
    await repo.initializeTransports();
    final archived = await db
        .customSelect('SELECT * FROM legacy_cloud_outbox')
        .getSingle();
    expect(
      archived.read<String>('operation'),
      before.read<String>('operation'),
    );
    expect(archived.read<String>('receipt'), before.read<String>('receipt'));
    expect(archived.read<int>('attempted'), 1);
    expect(await repo.pendingCount(), 0);
    await repo.put('book', book.id, {
      ...book.payload!,
      'title': 'Edit after migration',
    });
    expect((await repo.record(book.id))!.title, 'Edit after migration');
    await repo.initializeTransports();
    expect(
      await db.customSelect('SELECT * FROM legacy_cloud_outbox').get(),
      hasLength(1),
    );
  });

  test(
    'cloud baseline comes from server state, never the local or peer revision',
    () async {
      await repo.addBook('Peer', '', 'epub');
      final book = (await repo.records('book')).single;
      await db.customStatement('UPDATE records SET revision=57 WHERE id=?', [
        book.id,
      ]);
      await db.customStatement('INSERT INTO remote_records VALUES(?,?,?,?,?)', [
        book.id,
        'book',
        7,
        0,
        jsonEncode(book.payload),
      ]);
      await repo.setCloudTracking(true);
      await repo.prepareCloudChanges();
      expect((await operation())['baseRevision'], 7);
      await repo.put('book', book.id, {...book.payload!, 'title': 'More'});
      final operations = await repo.pending();
      expect(
        (jsonDecode(operations.last.read<String>('operation'))
            as Map)['baseRevision'],
        8,
      );
      expect((await repo.record(book.id))!.revision, 58);
    },
  );

  test('late cloud receipt preserves peer edit and queues it against the confirmed cloud baseline', () async {
    await repo.setCloudTracking(true);
    await repo.addBook('Original', '', 'epub');
    final book = (await repo.records('book')).single,
        queued = await operation();
    await db.customStatement(
      'UPDATE records SET revision=50,payload=? WHERE id=?',
      [
        jsonEncode({...book.payload!, 'title': 'New peer edit'}),
        book.id,
      ],
    );
    await repo.applyReceipt({
      'operationId': queued['operationId'],
      'status': 'accepted',
      'current': remote(book, 1, 'Original'),
    });
    expect((await repo.record(book.id))!.title, 'New peer edit');
    expect((await repo.record(book.id))!.revision, 50);
    await repo.prepareCloudChanges();
    expect((await operation())['baseRevision'], 1);
  });

  test('cloud page freezes unseen peer change against the prior baseline, preserving a real conflict', () async {
    await repo.setCloudTracking(true);
    await repo.addBook('Original', '', 'epub');
    final book = (await repo.records('book')).single,
        queued = await operation();
    await repo.applyReceipt({
      'operationId': queued['operationId'],
      'status': 'accepted',
      'current': remote(book, 1, 'Original'),
    });
    await db.customStatement(
      'UPDATE records SET revision=30,payload=? WHERE id=?',
      [
        jsonEncode({...book.payload!, 'title': 'Concurrent peer'}),
        book.id,
      ],
    );
    await repo.applyPage({
      'cursor': 2,
      'changes': [remote(book, 2, 'Concurrent cloud')],
    });
    expect((await repo.record(book.id))!.title, 'Concurrent peer');
    expect((await operation())['baseRevision'], 1);
    expect(((await operation())['payload'] as Map)['title'], 'Concurrent peer');
  });
}
