import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/library_exchange.dart';
import 'package:pepehub/library/library_repository.dart';
import 'package:pepehub/library/library_service.dart';
import 'package:pepehub/library/models.dart';
import 'package:pepehub/library/obsidian_sync_service.dart';
import 'package:pepehub/recommendations/recommendation_store.dart';
import 'package:uuid/uuid.dart';

void main() {
  late AppDatabase db;
  late Repository local;
  late LibraryService service;
  final connection = ObsidianConfig('https://example.test', 'test-token');
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    local = Repository(db);
    final client = MockClient(
      (_) => throw StateError('Local library must not make HTTP requests'),
    );
    service = LibraryService(local, client);
    addTearDown(client.close);
    addTearDown(service.dispose);
    addTearDown(db.close);
  });

  Map<String, dynamic> snapshot(
    String id, {
    String title = 'Книга',
    String status = 'Прочитано',
  }) => {
    'version': 1,
    'ready': true,
    'fields': [
      const LibraryField('Title', 'title', 'text').toJson(),
      const LibraryField('State', 'status', 'text').toJson(),
    ],
    'collections': [
      {
        'id': 'reading',
        'mediaType': 'book',
        'statuses': {'finished': 'Прочитано', 'planned': 'В планах'},
      },
    ],
    'items': [
      ObsidianLibraryItem(
        id: id,
        path: 'Books/$id.md',
        collectionId: 'reading',
        mediaType: 'book',
        fields: const [
          LibraryField('Title', 'title', 'text'),
          LibraryField('State', 'status', 'text'),
        ],
        values: {
          'Title': title,
          'State': status,
          'Custom': {'preserved': true},
        },
      ).toJson(),
    ],
  };

  test('manual completed cards work offline, retain unknown dates and survive restart', () async {
    await service.reload();
    final draft = service.emptyDraft().withValues({
      ...service.emptyDraft().values,
      'title': 'Прочитано давно',
      'rating': 9,
    });
    await service.add(draft, '');
    expect(service.completed.single.item.value('endDate'), isNotNull);
    expect(service.completed.single.item.value('rating'), 9);
    final client = MockClient((_) => throw StateError('No network'));
    addTearDown(client.close);
    final reopened = LibraryService(local, client);
    addTearDown(reopened.dispose);
    await reopened.reload();
    expect(reopened.completed.single.item.id, draft.id);
    expect(reopened.config, isNull);
    expect(reopened.error, isNull);
  });

  test('cached Obsidian cards migrate without connection and retain custom properties', () async {
    final remote = LibraryRepository(local, connection.namespace);
    final id = const Uuid().v4();
    await remote.receive(snapshot(id));
    await service.reload();
    expect(service.completed.single.item.title, 'Книга');
    expect(service.completed.single.item.values['Custom'], {'preserved': true});
    expect((await remote.entries())[id]!.item.path, 'Books/$id.md');
    final identity = service.completed.single.item.id;
    await service.connect(null);
    expect(service.completed.single.item.id, identity);
    expect(await local.meta('obsidian-library-enabled'), 'false');
  });

  test('remote removal preserves the personal card and does not queue resurrection', () async {
    final remote = LibraryRepository(local, connection.namespace);
    final id = const Uuid().v4();
    await remote.receive(snapshot(id));
    await service.reload();
    final adapter = LibraryExchange(
      local,
      service.repository,
      connection.namespace,
    );
    await remote.receive({...snapshot(id), 'items': <dynamic>[]});
    await adapter.importCached();
    await adapter.queue((await service.repository.entries()).keys.single);
    expect(
      (await service.repository.entries()).values.single.item.title,
      'Книга',
    );
    expect((await remote.entries())[id]!.operation, isNull);
  });

  test('planned imports move to existing recommendations without deleting their source', () async {
    final remote = LibraryRepository(local, connection.namespace);
    final id = const Uuid().v4();
    await remote.receive(snapshot(id, status: 'В планах'));
    await service.reload();
    expect(service.completed, isEmpty);
    expect(service.visibleEntries, isEmpty);
    final personalId = service.entries.single.item.id;
    await service.toRecommendations(personalId);
    await service.toRecommendations(personalId);
    expect(service.inbox, isEmpty);
    final shelf = await RecommendationStore(local).load();
    expect(shelf.books.single.catalog.title, 'Книга');
    expect(shelf.books.single.catalog.data['libraryId'], personalId);
    expect((await remote.entries())[id]!.item.value('status'), 'В планах');
    expect(service.fromRecommendation(shelf.books.single).id, personalId);
  });

  test('simultaneous edits remain local until explicitly resolved', () async {
    final remote = LibraryRepository(local, connection.namespace);
    final id = const Uuid().v4();
    await remote.receive(snapshot(id));
    await service.reload();
    final entry = service.entries.single;
    await service.save(entry.item.id, {
      ...entry.item.values,
      'title': 'Моя правка',
    }, original: entry.item.values);
    await remote.receive(snapshot(id, title: 'Правка Obsidian'));
    final adapter = LibraryExchange(
      local,
      service.repository,
      connection.namespace,
    );
    await adapter.importCached();
    expect(
      (await service.repository.entries())[entry.item.id]!.item.title,
      'Моя правка',
    );
    expect(
      (await adapter.bindings())[entry.item.id]['conflicts']['title'],
      'Правка Obsidian',
    );
    await adapter.resolve(entry.item.id, useRemote: true);
    expect(
      (await service.repository.entries())[entry.item.id]!.item.title,
      'Правка Obsidian',
    );
  });
}
