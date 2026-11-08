import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/book_trash.dart';
import 'package:pepehub/library/hidden_files.dart';

void main() {
  late AppDatabase db;
  late Repository repo;
  late BookTrash trash;
  late Map<String, String> ids;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = Repository(db);
    trash = BookTrash(repo);
    await repo.addBook('Книга', 'Автор', 'epub');
    await repo.addBook('Аудио', 'Автор', 'audio');
    await repo.addBook('Старая', 'Автор', 'txt');
    ids = {for (final b in await repo.records('book')) b.title: b.id};
  });
  tearDown(() => db.close());

  test('trash keeps the record and restores it to the shelf', () async {
    await trash.move([ids['Книга']!, ids['Аудио']!]);
    final listed = await trash.list();
    expect(listed.map((b) => b.title), unorderedEquals(['Книга', 'Аудио']));
    expect(listed.firstWhere((b) => b.title == 'Аудио').audio, isTrue);
    expect(listed.first.removedAt, isNotNull);
    // Removed books are on no shelf and not in the hidden panel.
    final shelf = (await repo.shelfBooks(audio: false)).map((b) => b.id);
    expect(
      await repo.meta('${Repository.removedShelfBookPrefix}${ids['Книга']}'),
      '1',
    );
    expect(shelf, contains(ids['Книга']));
    expect(
      (await hiddenFiles(repo)).map((f) => f.id),
      isNot(contains(ids['Книга'])),
    );
    await trash.restore([ids['Книга']!]);
    expect((await trash.list()).map((b) => b.title), ['Аудио']);
    expect(
      await repo.meta('${Repository.removedShelfBookPrefix}${ids['Книга']}'),
      isNull,
    );
  });

  test('a removal from an older version shows up in the trash', () async {
    // 0.30.19–0.30.22 «удалить только запись»: marker without a date.
    await repo.removeShelfBooks([ids['Старая']!]);
    final listed = await trash.list();
    expect(listed.single.title, 'Старая');
    expect(listed.single.removedAt, isNull);
  });

  test(
    'expired books are deleted for good, never right after an update',
    () async {
      await repo.removeShelfBooks([ids['Старая']!]);
      final now = DateTime(2026, 11, 8);
      expect(await trash.retentionDays(), 30);
      // The first run starts the clock for undated removals.
      expect(await trash.purgeExpired(now: now), 0);
      expect(await trash.list(), hasLength(1));
      await trash.move([ids['Книга']!]);
      expect(
        await trash.purgeExpired(now: now.add(const Duration(days: 29))),
        0,
      );
      expect(
        await trash.purgeExpired(
          now: DateTime.now().add(const Duration(days: 31)),
        ),
        2,
      );
      expect(await trash.list(), isEmpty);
      final left = (await repo.records('book')).map((b) => b.title);
      expect(left, ['Аудио']);
      await trash.setRetention(0);
      expect(await trash.retentionDays(), 0);
    },
  );
}
