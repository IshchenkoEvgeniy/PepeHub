import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/activity_store.dart';
import 'package:pepehub/library/library_backup.dart';
import 'package:pepehub/library/library_service.dart';
import 'package:pepehub/library/models.dart';
import 'package:pepehub/library/personal_library.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/reader/reading_library.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late Repository local;
  late LibraryService library;
  late Directory root;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    local = Repository(db);
    root = await Directory.systemTemp.createTemp('library-backup-');
    final client = MockClient((_) => throw StateError('No network'));
    library = LibraryService(local, client, assets: AssetStore(local, root));
    addTearDown(() async {
      library.dispose();
      client.close();
      await db.close();
      await root.delete(recursive: true);
    });
  });

  Future<void> reinstall() async {
    library.dispose();
    await db.close();
    db = AppDatabase(NativeDatabase.memory());
    local = Repository(db);
    final client = MockClient((_) => throw StateError('No network'));
    addTearDown(client.close);
    library = LibraryService(
      local,
      client,
      assets: AssetStore(local, Directory('${root.path}/fresh')),
    );
  }

  test('ZIP includes the offline copy of an HTTPS cover', () async {
    final image = await File(
      'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png',
    ).readAsBytes();
    final hash = sha256.convert(image).toString();
    final cover = File(library.covers!.path(hash));
    await cover.parent.create(recursive: true);
    await cover.writeAsBytes(image);
    final id = uuid.v4();
    await library.add(
      personalLibraryItem(id, 'book', {
        'title': 'Сетевая обложка с локальной копией',
        'status': 'finished',
        'cover': 'https://example.test/cover.png',
        'pepehub_cover_asset': {'hash': hash},
      }),
      '',
    );
    expect(library.coverPath(library.entries.single.item), cover.path);
    final backup = LibraryBackup(library);
    final preview = backup.inspect(await backup.create());
    expect(preview.covers[hash], image);
    await cover.delete();
    await backup.restore(preview, replace: true);
    expect(await cover.readAsBytes(), image);
  });

  for (final type in ['book', 'audiobook']) {
    test(
      'ZIP captures uncached native history and notes of a trashed $type',
      () async {
        await local.addBook(
          'В корзине',
          'Автор',
          type == 'book' ? 'epub' : 'audio',
        );
        final source = (await local.records('book')).single;
        final id = uuid.v4();
        await library.add(
          personalLibraryItem(id, type, {
            'title': 'В корзине',
            'status': 'finished',
          }),
          source.id,
        );
        final noteId = uuid.v4();
        if (type == 'book') {
          await ReadingLibrary(local).saveNote(
            ReadingNote(
              id: noteId,
              bookId: source.id,
              hash: 'a' * 64,
              bookTitle: 'В корзине',
              chapterTitle: 'Глава',
              quote: 'Цитата до удаления',
              comment: 'Комментарий',
              color: 'yellow',
              updated: '2026-10-29T10:00:00.000Z',
              chapter: 0,
              start: 1,
              end: 7,
              tags: const [],
              characters: const [],
            ),
          );
        } else {
          await local.put('audio_note', noteId, {
            'bookId': source.id,
            'text': 'Аудиозаметка',
            'at': '2026-10-29T10:00:00.000Z',
          });
        }
        await local.put('session', uuid.v4(), {
          'bookId': source.id,
          'kind': type == 'book' ? 'reading' : 'listening',
          'startedAt': '2026-10-29T10:00:00.000Z',
          'endedAt': '2026-10-29T10:05:00.000Z',
          'activeSeconds': 300,
        });
        await library.deleteCards([id]);
        final backup = LibraryBackup(library);
        final preview = backup.inspect(await backup.create());
        expect(preview.notes['slots'], hasLength(1));
        expect(preview.history['slots'], hasLength(1));
        await reinstall();
        await LibraryBackup(library).restore(preview, replace: true);
        expect(library.trash.single.item.id, id);
        expect(library.trash.single.sourceBookId, isNull);
        await library.notes!.capture();
        await library.history!.capture();
        expect(await library.notes!.entries(), hasLength(1));
        expect(await library.history!.entries(), hasLength(1));
        expect(await local.records('book'), isEmpty);
      },
    );
  }

  test(
    '1000 books and audiobooks survive clean install, merge and replacement',
    () async {
      final cards = <String, LibraryEntry>{};
      final history = <String, dynamic>{}, notes = <String, dynamic>{};
      for (var i = 0; i < 1000; i++) {
        final id = uuid.v4(), type = i.isEven ? 'book' : 'audiobook';
        cards[id] = LibraryEntry(
          personalLibraryItem(id, type, {
            'title': 'Произведение $i',
            'status': ['finished', 'paused', 'abandoned'][i % 3],
            'series': 'Серия ${i % 10}',
            'pepehub_collections': ['Коллекция'],
            if (i % 20 == 0) 'pepehub_deleted_at': '2026-11-01T00:00:00Z',
          }),
        );
        final activityId = uuid.v4(), noteId = uuid.v4();
        history[activityId] = {
          'value': ActivityStore.entry(
            id: activityId,
            itemId: id,
            mediaType: type,
            day: '2026-10-29',
            durationMs: 300000,
            progress: 5,
            unit: type == 'book' ? 'pages' : 'minutes',
            origin: 'app-manual',
          ),
        };
        notes[noteId] = {
          'portable': true,
          'value': {
            'id': noteId,
            'itemId': id,
            'mediaType': type,
            'kind': 'markdown',
            'title': 'Заметка $i',
            'quote': 'Цитата $i',
            'text': 'Комментарий $i',
            'tags': ['Метка'],
            'characters': [],
            'color': 'yellow',
            'anchor': {},
            'origin': 'obsidian',
            'updatedAt': '2026-10-29T10:00:00.000Z',
            'deleted': false,
          },
        };
      }
      await library.repository.mutate((saved) async => saved.addAll(cards));
      await library.history!.mutate((state) async => state['slots'] = history);
      await library.notes!.mutate((state) async => state['slots'] = notes);
      await local.setMeta('library-series-length:серия', '12');
      await local.setMeta('library-year-goal:personal:2026', '40');
      await local.setMeta('library-trash-retention-days', '90');
      final backup = LibraryBackup(library);
      final preview = backup.inspect(await backup.create());
      expect(preview.cards, hasLength(1000));
      expect(preview.history['slots'], hasLength(1000));
      expect(preview.notes['slots'], hasLength(1000));
      await reinstall();
      final extra = uuid.v4();
      await library.add(
        personalLibraryItem(extra, 'book', {
          'title': 'Добавленная отдельно',
          'status': 'finished',
        }),
        '',
      );
      final recovery = LibraryBackup(library);
      await recovery.restore(preview);
      expect(library.entries, hasLength(1001));
      expect(library.trash, hasLength(50));
      await recovery.restore(preview, replace: true);
      expect(library.entries, hasLength(1000));
      expect(await library.repository.entries(), isNot(contains(extra)));
      expect(await library.history!.entries(), hasLength(1000));
      expect(await library.notes!.entries(), hasLength(1000));
      expect(await local.meta('library-series-length:серия'), '12');
      expect(await local.meta('library-year-goal:personal:2026'), '40');
      expect(await local.meta('library-trash-retention-days'), '90');
      expect(await local.records('book'), isEmpty);
      final roundtrip = recovery.inspect(await recovery.create());
      expect(
        roundtrip.cards.map((id, e) => MapEntry(id, e.toJson())),
        preview.cards.map((id, e) => MapEntry(id, e.toJson())),
      );
      expect(roundtrip.notes, preview.notes);
      expect(roundtrip.history, preview.history);
    },
  );
}
