import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/activity_store.dart';
import 'package:pepehub/library/book_trash.dart';
import 'package:pepehub/library/library_service.dart';
import 'package:pepehub/library/models.dart';
import 'package:pepehub/library/personal_library.dart';
import 'package:uuid/uuid.dart';

void main() {
  const uuid = Uuid();
  late AppDatabase db;
  late Repository local;
  late MockClient client;
  late LibraryService library;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    local = Repository(db);
    client = MockClient((_) => throw StateError('Offline'));
    library = LibraryService(local, client);
  });
  tearDown(() async {
    library.dispose();
    client.close();
    await db.close();
  });

  Future<String> book(String title) async {
    final id = uuid.v4();
    await local.put('book', id, {'title': title, 'format': 'audio'});
    return id;
  }

  /// A card the app keeps for a file: [status] planned/active is a service
  /// record, finished is a card the user added to the library.
  Future<String> card(String source, String status) async {
    final id = uuid.v4();
    await library.repository.mutate((cards) async {
      cards[id] = LibraryEntry(
        personalLibraryItem(id, 'audiobook', {
          'title': '$status $source',
          'status': status,
        }),
        sourceBookId: source,
      );
    });
    return id;
  }

  Future<void> journal(String itemId) => library.history!.receive([
    {
      'entry': ActivityStore.entry(
        id: uuid.v4(),
        itemId: itemId,
        mediaType: 'audiobook',
        day: '2026-10-04',
        durationMs: 60000,
        progress: 1,
        unit: 'minutes',
        origin: 'obsidian',
      ),
      'revision': 1,
      'sequence': 1,
    },
  ], 1);

  test('purging the trash removes the file service record, keeps the library card and statistics', () async {
    final gone = await book('Удаляемая');
    final kept = await book('Оставшаяся');
    final service = await card(gone, 'planned');
    final added = await card(gone, 'finished');
    final other = await card(kept, 'active');
    await journal(service);
    await local.setMeta('reading-book:$gone', '{}');
    await local.setMeta('audio-status-override:$gone', 'planned');
    await local.setMeta('reading-session:s1', '{"bookId":"$gone"}');
    await local.setMeta('audio-status-override:$kept', 'active');

    final trash = BookTrash(local);
    await trash.move([gone]);
    // In the trash nothing is lost yet.
    expect((await library.repository.entries()).keys, contains(service));
    await trash.purge([gone]);

    final cards = await library.repository.entries();
    expect(cards.keys, isNot(contains(service)));
    expect(cards.keys, containsAll([added, other]));
    expect(await library.history!.entries(itemId: service), isEmpty);
    expect(await local.meta('reading-book:$gone'), isNull);
    expect(await local.meta('audio-status-override:$gone'), isNull);
    expect(await local.meta('reading-session:s1'), isNotNull);
    expect(await local.meta('audio-status-override:$kept'), 'active');
  });

  test(
    'a one-time migration drops service records of books purged earlier',
    () async {
      final purged = await book('Удалена раньше');
      final trashed = await book('В корзине');
      final purgedService = await card(purged, 'planned');
      final purgedAdded = await card(purged, 'finished');
      final trashedService = await card(trashed, 'planned');
      final unknownService = await card('never-existed', 'planned');
      await local.delete('book', purged);
      await BookTrash(local).move([trashed]);

      await library.reload();
      final cards = await library.repository.entries();
      expect(cards.keys, isNot(contains(purgedService)));
      expect(
        cards.keys,
        containsAll([purgedAdded, trashedService, unknownService]),
      );
      expect(await local.meta('library-purged-book-drafts-v1'), '1');

      // Runs once: later records are left to the trash.
      final later = await card(purged, 'planned');
      await library.reload();
      expect((await library.repository.entries()).keys, contains(later));
    },
  );
}
