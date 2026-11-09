import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/note_store.dart';
import 'package:pepehub/library/library_repository.dart';
import 'package:pepehub/library/models.dart';
import 'package:pepehub/reader/reading_library.dart';
import 'package:pepehub/audio/audio_journal.dart';
import 'package:pepehub/audio/audio_library_repository.dart';

void main() {
  late AppDatabase db;
  late Repository local;
  late String book;
  late LibraryItem item;
  late NoteStore store;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    local = Repository(db);
    await local.addBook('Книга', 'Автор', 'epub');
    book = (await local.records('book')).single.id;
    item = LibraryItem(
      id: uuid.v4(),
      path: 'Books/One.md',
      collectionId: 'book',
      mediaType: 'book',
      values: {'Title': 'Книга'},
      fields: const [LibraryField('Title', 'title', 'text')],
    );
    await LibraryRepository(local, 'one').mutate((entries) async {
      entries[item.id] = LibraryEntry(item, sourceBookId: book);
    });
    store = NoteStore(local, 'one');
  });
  tearDown(() => db.close());
  ReadingNote note({
    String? id,
    String comment = 'Мысль',
    String updated = '2026-10-03T10:00:00.000Z',
  }) => ReadingNote(
    id: id ?? uuid.v4(),
    bookId: book,
    hash: 'a' * 64,
    bookTitle: 'Книга',
    chapterTitle: 'Глава',
    quote: 'Цитата',
    comment: comment,
    color: 'pink',
    updated: updated,
    chapter: 1,
    start: 10,
    end: 16,
    tags: ['сюжет'],
    characters: ['Герой'],
  );
  Future<Map<String, dynamic>> acknowledge() async {
    final op = (await store.pending()).single;
    await store.receipts([
      {
        'operationId': op['operationId'],
        'status': 'applied',
        'record': {'entry': op['entry'], 'revision': 1, 'sequence': 1},
      },
    ]);
    return op['entry'] as Map<String, dynamic>;
  }

  test('capture all reader note fields; durable retries survive restart and retain newer offline edits', () async {
    final n = note();
    await ReadingLibrary(local).saveNote(n);
    await store.capture();
    final op = (await store.pending()).single, value = op['entry'];
    expect(value['text'], 'Мысль');
    expect(value['quote'], 'Цитата');
    expect(value['tags'], ['сюжет']);
    expect(value['characters'], ['Герой']);
    expect(value['anchor']['hash'], 'a' * 64);
    expect(await NoteStore(local, 'one').pending(), [op]);
    await ReadingLibrary(local).saveNote(
      note(
        id: n.id,
        comment: 'Правка офлайн',
        updated: '2026-10-03T11:00:00.000Z',
      ),
    );
    await store.capture();
    await store.receipts([
      {
        'operationId': op['operationId'],
        'status': 'applied',
        'record': {'entry': value, 'revision': 1, 'sequence': 1},
      },
    ]);
    expect((await store.pending()).single['entry']['text'], 'Правка офлайн');
    expect(await NoteStore(local, 'two').entries(), isEmpty);
  });
  test('incoming edits materialize in native notes, deletes propagate both ways and conflicts retain versions', () async {
    final n = note();
    await ReadingLibrary(local).saveNote(n);
    await store.capture();
    final initial = await acknowledge();
    final remote = {
      ...initial,
      'text': 'Из Obsidian',
      'tags': ['новый'],
      'characters': ['Персонаж'],
      'updatedAt': '2026-10-03T12:00:00.000Z',
    };
    await store.receive([
      {'entry': remote, 'revision': 2, 'sequence': 2},
    ], 2);
    expect((await ReadingLibrary(local).notes()).single.comment, 'Из Obsidian');
    await store.capture();
    expect(await store.pending(), isEmpty);
    await ReadingLibrary(local).saveNote(
      note(id: n.id, comment: 'Телефон', updated: '2026-10-03T13:00:00.000Z'),
    );
    await store.capture();
    final other = {
      ...remote,
      'text': 'Другой компьютер',
      'updatedAt': '2026-10-03T14:00:00.000Z',
    };
    await store.receive([
      {'entry': other, 'revision': 3, 'sequence': 3},
    ], 3);
    final slot = (await store.entries()).single;
    expect(slot['value']['text'], 'Телефон');
    expect(slot['conflict']['entry']['text'], 'Другой компьютер');
    await store.resolve(initial['id'] as String, useRemote: true);
    expect(
      (await ReadingLibrary(local).notes()).single.comment,
      'Другой компьютер',
    );
    await store.capture();
    expect(await store.pending(), isEmpty);
    await ReadingLibrary(local).deleteNote(n.id);
    await store.capture();
    expect((await store.pending()).single['entry']['deleted'], true);
  });
  test('foreign Markdown notes import once and remain editable without inventing a quote location', () async {
    final value = {
      'id': uuid.v4(),
      'itemId': item.id,
      'mediaType': 'book',
      'kind': 'markdown',
      'title': 'Заметки Obsidian',
      'quote': '',
      'text': '## Персонажи\nГерой',
      'tags': <String>[],
      'characters': ['Герой'],
      'color': 'yellow',
      'anchor': <String, dynamic>{},
      'origin': 'obsidian',
      'updatedAt': '2026-10-03T10:00:00.000Z',
      'deleted': false,
    };
    await store.receive([
      {'entry': value, 'revision': 1, 'sequence': 1},
    ], 1);
    await store.capture();
    await store.capture();
    expect(await store.pending(), isEmpty);
    final native = (await ReadingLibrary(local).notes()).single;
    expect(native.chapter, -1);
    expect(native.comment, value['text']);
    await ReadingLibrary(local).saveNote(
      ReadingNote.fromJson({
        ...native.toJson(),
        'comment': 'Из приложения',
        'updated': '2026-10-03T11:00:00.000Z',
      }),
    );
    await store.capture();
    expect((await store.pending()).single['entry']['kind'], 'markdown');
    expect((await store.pending()).single['entry']['anchor'], isEmpty);
    await store.receipts([
      {
        'operationId': (await store.pending()).single['operationId'],
        'status': 'applied',
        'record': {
          'entry': (await store.pending()).single['entry'],
          'revision': 2,
          'sequence': 2,
        },
      },
    ]);
    await store.receive([
      {
        'entry': {
          ...(await store.entries()).single['value'] as Map,
          'deleted': true,
        },
        'revision': 3,
        'sequence': 3,
      },
    ], 3);
    expect(await ReadingLibrary(local).notes(), isEmpty);
  });
  test(
    'audio thoughts preserve track hash, kind, time position and incoming text',
    () async {
      await local.db.customStatement(
        'UPDATE records SET payload=? WHERE id=?',
        [
          jsonEncode({'title': 'Книга', 'format': 'audio'}),
          book,
        ],
      );
      final audioItem = LibraryItem(
        id: item.id,
        path: item.path,
        collectionId: 'audiobook',
        mediaType: 'audiobook',
        values: item.values,
        fields: item.fields,
      );
      await LibraryRepository(local, 'one').mutate((entries) async {
        entries[item.id] = LibraryEntry(audioItem, sourceBookId: book);
      });
      final track = uuid.v4();
      await AudioLibraryRepository(db).registerSingleTrack(
        bookId: book,
        assetId: track,
        hash: 'b' * 64,
        path: 'track.mp3',
        filename: 'track.mp3',
        bytes: 123,
      );
      final id = await AudioJournal(local).saveNote(
        bookId: book,
        trackId: track,
        positionMs: 45000,
        kind: 'character',
        title: 'Герой',
        text: 'Характер',
      );
      await store.capture();
      final first = await acknowledge();
      expect(first['anchor']['trackHash'], 'b' * 64);
      expect(first['anchor']['positionMs'], 45000);
      expect(first['anchor']['noteKind'], 'character');
      await store.receive([
        {
          'entry': {
            ...first,
            'text': 'Характер из Obsidian',
            'updatedAt': '2026-10-03T15:00:00.000Z',
          },
          'revision': 2,
          'sequence': 2,
        },
      ], 2);
      expect(
        (await local.record(id))!.payload!['text'],
        'Характер из Obsidian',
      );
      await store.capture();
      expect(await store.pending(), isEmpty);
    },
  );
  test(
    'invalid incoming notes preserve the cursor and durable queue',
    () async {
      await ReadingLibrary(local).saveNote(note());
      await store.capture();
      final op = (await store.pending()).single;
      final invalid = {
        ...op['entry'] as Map,
        'anchor': {'path': 'C:/private'},
      };
      await expectLater(
        store.receive([
          {'entry': invalid, 'revision': 1, 'sequence': 1},
        ], 1),
        throwsFormatException,
      );
      expect((await store.state())['cursor'], 0);
      expect(await store.pending(), [op]);
      await expectLater(
        store.receipts([
          {
            'operationId': op['operationId'],
            'status': 'applied',
            'record': {'entry': invalid, 'revision': 1, 'sequence': 1},
          },
        ]),
        throwsFormatException,
      );
      expect(await store.pending(), [op]);
    },
  );
}
