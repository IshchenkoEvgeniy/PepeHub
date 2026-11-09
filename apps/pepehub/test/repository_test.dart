import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';

void main() {
  late AppDatabase db;
  late Repository repository;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repository = Repository(db);
  });
  tearDown(() async {
    await db.close();
  });

  test(
    'edits and deletions are written locally with increasing revisions',
    () async {
      await repository.addBook('Первая', '', 'epub');
      final book = (await repository.records('book')).single;
      await repository.put('book', book.id, {
        ...book.payload!,
        'title': 'Вторая',
      });
      final edited = (await repository.record(book.id))!;
      expect(edited.revision, book.revision + 1);
      expect(edited.title, 'Вторая');
      await repository.delete('book', book.id);
      final deleted = (await repository.record(book.id))!;
      expect(deleted.deleted, true);
      expect(deleted.revision, edited.revision + 1);
      expect(await repository.records('book'), isEmpty);
    },
  );
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
