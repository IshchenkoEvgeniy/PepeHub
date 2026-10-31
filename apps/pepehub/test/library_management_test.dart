import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/library_exchange.dart';
import 'package:pepehub/library/library_repository.dart';
import 'package:pepehub/library/library_service.dart';
import 'package:pepehub/library/models.dart';
import 'package:pepehub/library/personal_library.dart';

void main() {
  test('cover normalization does not export unchanged vault paths, and pending acknowledgements preserve newer edits', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final local = Repository(db),
        client = MockClient((_) => throw StateError('No network'));
    addTearDown(client.close);
    final service = LibraryService(local, client);
    addTearDown(service.dispose);
    final remote = LibraryRepository(local, 'cached'),
        adapter = LibraryExchange(local, service.repository, 'cached');
    final hash = 'a' * 64;
    final item = ObsidianLibraryItem(
      id: '00000000-0000-4000-8000-000000000002',
      path: 'Books/Book.md',
      collectionId: 'book',
      mediaType: 'book',
      fields: const [
        LibraryField('Title', 'title', 'text'),
        LibraryField('Cover', 'cover', 'text'),
      ],
      values: const {'Title': 'Книга', 'Cover': 'Covers/Book.png'},
      coverAsset: {'hash': hash},
    );
    await remote.receive({
      'version': 1,
      'ready': true,
      'fields': item.fields.map((f) => f.toJson()).toList(),
      'collections': personalLibrarySchema['collections'],
      'items': [item.toJson()],
    });
    await adapter.importCached();
    await service.reload();
    final card = service.entries.single;
    await adapter.queue(card.item.id);
    expect((await remote.entries()).values.single.operation, isNull);
    await service.save(card.item.id, {
      ...card.item.values,
      'title': 'Первая правка',
    }, original: card.item.values);
    await adapter.queue(card.item.id);
    final pending = (await remote.entries()).values.single;
    expect(pending.operation!['values'], {'Title': 'Первая правка'});
    expect(pending.item.coverAsset?['hash'], hash);
    await adapter.importCached();
    await service.reload();
    final first = service.entries.single;
    await service.save(first.item.id, {
      ...first.item.values,
      'title': 'Новая правка',
    }, original: first.item.values);
    await remote.receipt(pending.item.id, {
      'operationId': pending.operation!['operationId'],
      'status': 'applied',
    });
    await adapter.importCached();
    await service.reload();
    expect(service.entries.single.item.title, 'Новая правка');
    expect(service.entries.single.item.value('cover'), 'pepehub-cover:$hash');
    expect((await adapter.bindings())[card.item.id]['conflicts'], isEmpty);
  });
  test('Obsidian coverAsset survives semantic conversion while a manual HTTPS cover wins', () {
    final hash = 'a' * 64;
    ObsidianLibraryItem card(String cover) => ObsidianLibraryItem(
      id: 'book',
      path: 'Books/Book.md',
      collectionId: 'book',
      mediaType: 'book',
      fields: const [LibraryField('Cover', 'cover', 'text')],
      values: {'Cover': cover},
      coverAsset: {'hash': hash},
    );
    expect(
      personalValues(card('Covers/Book.jpg'))['cover'],
      'pepehub-cover:$hash',
    );
    expect(personalValues(card('Covers/Book.jpg'))['pepehub_cover_asset'], {
      'hash': hash,
    });
    expect(
      personalValues(card('https://example.test/manual.png'))['cover'],
      'https://example.test/manual.png',
    );
  });
  test(
    'trash persists across connector pulls and restore keeps the same identity',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final local = Repository(db),
          client = MockClient((_) => throw StateError('No network'));
      addTearDown(client.close);
      final service = LibraryService(local, client);
      addTearDown(service.dispose);
      final remote = LibraryRepository(local, 'cached');
      final item = personalLibraryItem(
        '00000000-0000-4000-8000-000000000001',
        'book',
        {'title': 'Книга', 'status': 'finished'},
      );
      final snapshot = {
        'version': 1,
        'ready': true,
        'fields': personalLibraryFields.map((f) => f.toJson()).toList(),
        'collections': personalLibrarySchema['collections'],
        'items': [item.toJson()],
      };
      await remote.receive(snapshot);
      final adapter = LibraryExchange(local, service.repository, 'cached');
      await adapter.importCached();
      await service.reload();
      final id = service.completed.single.item.id;
      await service.favorite(id);
      expect(service.completed.single.item.values['pepehub_favorite'], isTrue);
      await service.deleteCards([id]);
      expect(service.completed, isEmpty);
      expect(service.trash.single.item.id, id);
      await remote.receive(snapshot);
      await adapter.importCached();
      await service.reload();
      expect(service.completed, isEmpty);
      expect(service.trash.single.item.id, id);
      expect((await remote.entries()).values.single.state, 'synced');
      await service.restoreCard(id);
      expect(service.completed.single.item.id, id);
      expect(service.trash, isEmpty);
    },
  );
}
