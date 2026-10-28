import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_selector/file_selector.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/library/automatic_metadata.dart';
import 'package:pepehub/library/library_mapper.dart';
import 'package:pepehub/library/library_repository.dart';
import 'package:pepehub/library/models.dart';
import 'package:pepehub/reader/reading_library.dart';
import 'package:pepehub/reader/text_book.dart';
import 'package:pepehub/audio/audio_library_repository.dart';
import 'package:pepehub/audio/audio_journal.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppDatabase db;
  late Repository local;
  late AssetStore assets;
  const channel = MethodChannel('app.pepehub/audio_folder');
  setUp(() async {
    root = await Directory.systemTemp.createTemp('pepehub-autofill-');
    db = AppDatabase(NativeDatabase.memory());
    local = Repository(db);
    assets = AssetStore(local, Directory('${root.path}/assets'));
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await db.close();
    await root.delete(recursive: true);
  });
  test('source position, measured reading time and real dates fill metadata without manual pages', () async {
    final source = File('${root.path}/book.txt');
    await source.writeAsString("Первая глава. ${'Содержимое книги. ' * 100}");
    final asset = await assets.importBook(XFile(source.path));
    await ReadingLibrary(local).index(assets, asset);
    final book = (await local.records('book')).single;
    await ReadingLibrary(local)
        .update('reader:${asset.hash}', {'chapter': 0, 'textOffset': 100});
    await ReadingLibrary(local).update('reading-dates:${book.id}', {
      'startedAt': '2026-10-01T10:00:00.000Z',
    });
    await ReadingLibrary(local).update('reading-session:one', {
      'bookId': book.id,
      'spans': [
        {
          'start': '2026-10-01T10:00:00.000Z',
          'end': '2026-10-01T10:15:00.000Z',
          'activeMs': 600000,
        },
        {
          'start': '2026-10-01T12:00:00.000Z',
          'end': '2026-10-01T12:05:00.000Z',
          'activeMs': 300000,
          'pepehubDeleted': true,
        },
      ],
    });
    final details = await AutomaticMetadata(assets).details(book);
    expect(details['unit'], 'characters');
    expect(details['progress'], 100);
    expect(details['total'], greaterThan(100));
    expect(details['readingTime'], '00:10:00');
    expect(details['startedAt'], '2026-10-01T10:00:00.000Z');
    await ReadingLibrary(local).update('reading-dates:${book.id}', {
      'finishedAt': '2026-10-02T13:00:00.000Z',
    });
    final finished = await AutomaticMetadata(assets).details(book);
    expect(finished['progress'], finished['total']);
    expect(finished['status'], 'finished');
    final mapped = LibraryMapper.fromBook(
      book,
      {
        'fields': [
          {'key': 'Start', 'field': 'startDate', 'kind': 'text'},
          {'key': 'End', 'field': 'endDate', 'kind': 'text'},
          {'key': 'Time spent', 'field': 'readingTime', 'kind': 'text'},
        ],
        'collections': [
          {'id': 'book', 'mediaType': 'book'},
        ],
      },
      finished,
      uuid.v4(),
    );
    expect(mapped.values['End'], '2026-10-02T13:00:00.000Z');
    expect(mapped.values['Time spent'], '00:10:00');
  });
  test('FB2 metadata includes language, genres, publisher, ISBN, publication date and artwork', () {
    final parsed = parseTextBook(
      Uint8List.fromList(
        utf8.encode(
          '<FictionBook><description><title-info><book-title>Название</book-title><author><first-name>Автор</first-name></author><genre>fantasy</genre><genre>adventure</genre><lang>ru</lang><src-lang>en</src-lang><date value="2020-01-02">2020</date><coverpage><image href="#cover"/></coverpage></title-info><publish-info><publisher>Издатель</publisher><year>2021</year><isbn>9781234567890</isbn></publish-info></description><body><section><p>Текст</p></section></body><binary id="cover">AQID</binary></FictionBook>',
        ),
      ),
      'book.fb2',
    );
    expect(parsed.metadata['language'], 'ru');
    expect(parsed.metadata['genres'], ['fantasy', 'adventure']);
    expect(parsed.metadata['publisher'], 'Издатель');
    expect(parsed.metadata['isbn'], '9781234567890');
    expect(parsed.metadata['publicationDate'], '2020-01-02');
    expect(parsed.cover, [1, 2, 3]);
  });
  test('audio metadata probes local/SAF tracks before playback and caches durations independently from listening time', () async {
    await local.addBook('Аудиокнига', '', 'audio');
    final book = (await local.records('book')).single;
    final tracks = [uuid.v4(), uuid.v4()];
    for (var i = 0; i < 2; i++) {
      if (i == 1) {
        await db.customStatement(
          'UPDATE audio_tracks SET ordinal=1 WHERE id=?',
          [tracks[0]],
        );
      }
      await AudioLibraryRepository(db).registerSingleTrack(
        bookId: book.id,
        assetId: tracks[i],
        hash: (i == 0 ? 'a' : 'b') * 64,
        path: i == 0
            ? '${root.path}/one.mp3'
            : 'content://provider/document/two',
        filename: 'track$i.mp3',
        bytes: 123,
      );
    }
    var probes = 0;
    final uris = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'metadata') return null;
          probes++;
          uris.add((call.arguments as Map)['uri'] as String);
          return {
            'durationMs': 600000,
            'author': 'Рассказчик',
            'writer': 'Автор книги',
            'genre': 'Fantasy',
            'year': '2021',
          };
        });
    await AudioJournal(local).put('audio_event', uuid.v4(), {
      'bookId': book.id,
      'kind': 'listen',
      'at': '2026-10-01T10:00:00Z',
      'wallMs': 60000,
      'mediaMs': 120000,
    });
    final details = await AutomaticMetadata(assets).details(book);
    expect(details['durationMinutes'], 20);
    expect(details['readingTime'], '00:01:00');
    expect(details['authors'], ['Автор книги']);
    expect(details['narrator'], 'Рассказчик');
    expect(uris.any((u) => u.startsWith('file:')), true);
    expect(uris.any((u) => u.startsWith('content:')), true);
    await AutomaticMetadata(assets).details(book);
    expect(probes, 2);
  });
  test('automatic refresh updates fields it filled but preserves a later manual Obsidian edit', () async {
    final file = File('${root.path}/book.txt');
    await file.writeAsString("Книга ${'текст ' * 100}");
    final asset = await assets.importBook(XFile(file.path));
    await ReadingLibrary(local).index(assets, asset);
    final book = (await local.records('book')).single;
    final schema = {
      'fields': [
        {'key': 'Progress', 'field': 'progress', 'kind': 'number'},
      ],
      'collections': [
        {'id': 'book', 'mediaType': 'book'},
      ],
    };
    final item = LibraryMapper.fromBook(book, schema, {}, uuid.v4());
    final repo = LibraryRepository(local, 'one');
    await repo.mutate((entries) async {
      entries[item.id] = LibraryEntry(item, sourceBookId: book.id);
    });
    await AutomaticMetadata(assets).refresh(repo, schema);
    final op = (await repo.entries())[item.id]!.operation!;
    expect(op['values']['Progress'], 0);
    await repo.receipt(item.id, {
      'operationId': op['operationId'],
      'status': 'applied',
    });
    await repo.mutate((entries) async {
      entries[item.id] = LibraryEntry(
        entries[item.id]!.item.withValues({'Progress': 77}),
        sourceBookId: book.id,
      );
    });
    await ReadingLibrary(local)
        .update('reader:${asset.hash}', {'chapter': 0, 'textOffset': 200});
    await AutomaticMetadata(assets).refresh(repo, schema);
    expect((await repo.entries())[item.id]!.item.values['Progress'], 77);
    expect((await repo.entries())[item.id]!.operation, isNull);
  });
  test(
    'autofill respects property aliases on each existing Obsidian card',
    () async {
      final file = File('${root.path}/book.txt');
      await file.writeAsString('Книга');
      final asset = await assets.importBook(XFile(file.path));
      await ReadingLibrary(local).index(assets, asset);
      final book = (await local.records('book')).single;
      final item = ObsidianLibraryItem(
        id: uuid.v4(),
        path: '',
        collectionId: 'book',
        mediaType: 'book',
        values: {'Прочитано': null},
        fields: const [LibraryField('Прочитано', 'progress', 'number')],
      );
      final repo = LibraryRepository(local, 'one');
      await repo.mutate((entries) async {
        entries[item.id] = LibraryEntry(item, sourceBookId: book.id);
      });
      await AutomaticMetadata(assets).refresh(repo, {
        'fields': [
          {'key': 'Progress', 'field': 'progress', 'kind': 'number'},
        ],
        'collections': [
          {'id': 'book', 'mediaType': 'book'},
        ],
      });
      final op = (await repo.entries())[item.id]!.operation!;
      expect(op['values'], {'Прочитано': 0});
    },
  );
}
