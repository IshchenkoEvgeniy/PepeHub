import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/library_repository.dart';
import 'package:pepehub/library/library_service.dart';
import 'package:pepehub/library/models.dart';
import 'connector_namespace.dart';
import 'package:pepehub/recommendations/recommendation_store.dart';
import 'package:uuid/uuid.dart';

void main() {
  late AppDatabase db;
  late Repository local;
  late LibraryService service;
  final connection = LegacyConnector('https://example.test', 'test-token');
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
    await service.reload();
    expect(service.completed.single.item.id, identity);
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

}
