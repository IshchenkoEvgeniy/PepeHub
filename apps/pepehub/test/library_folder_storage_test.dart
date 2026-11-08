import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/activity_store.dart';
import 'package:pepehub/library/library_folder_storage.dart';
import 'package:pepehub/library/library_service.dart';
import 'package:pepehub/library/models.dart';
import 'package:pepehub/library/personal_library.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/reader/reading_library.dart';
import 'package:pepehub/sync/peer/peer_files.dart';
import 'package:pepehub/sync/peer/peer_models.dart';
import 'package:pepehub/ui/library_data_page.dart';

class _SlowFolderFiles extends LocalPeerFiles {
  final started = Completer<void>(), release = Completer<void>();
  _SlowFolderFiles(super.root);
  @override
  Future<File> publishFile(File staged, String destination) async {
    if (!started.isCompleted &&
        destination.replaceAll('\\', '/').contains('/objects/')) {
      started.complete();
      await release.future;
    }
    return super.publishFile(staged, destination);
  }
}

class _CountingFolderFiles extends LocalPeerFiles {
  int reads = 0;
  _CountingFolderFiles(super.root);
  @override
  Future<String?> hash(String path) {
    reads++;
    return super.hash(path);
  }

  @override
  Future<List<int>> read(String path, int offset, int count) {
    reads++;
    return super.read(path, offset, count);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root, shared;
  final services = <LibraryService>[];
  final databases = <AppDatabase>[];
  final previousWarnings = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  tearDownAll(
    () => driftRuntimeOptions.dontWarnAboutMultipleDatabases = previousWarnings,
  );

  LibraryService device({AppDatabase? database}) {
    final db = database ?? AppDatabase(NativeDatabase.memory());
    final repo = Repository(db);
    final client = MockClient((_) => throw StateError('No network'));
    final library = LibraryService(
      repo,
      client,
      assets: AssetStore(
        repo,
        Directory('${root.path}/device-${services.length}'),
      ),
    );
    services.add(library);
    if (!databases.contains(db)) databases.add(db);
    addTearDown(client.close);
    return library;
  }

  Future<String> add(
    LibraryService library, {
    bool audio = false,
    String title = 'Книга',
  }) async {
    final id = uuid.v4();
    await library.add(
      personalLibraryItem(id, audio ? 'audiobook' : 'book', {
        'title': title,
        'status': 'finished',
        'series': 'Серия',
        'pepehub_collections': ['Коллекция'],
      }),
      '',
    );
    return id;
  }

  Future<void> rename(LibraryService library, String id, String title) =>
      library.repository.mutate((cards) async {
        final old = cards[id]!;
        cards[id] = LibraryEntry(
          old.item.withValues({...old.item.values, 'title': title}),
          sourceBookId: old.sourceBookId,
        );
      });

  Future<Map<String, dynamic>> manifest() async => jsonDecode(
    await File('${shared.path}/PepeHub-library/library.json').readAsString(),
  ) as Map<String, dynamic>;

  Future<void> putDocument(String key, Object data) async {
    final file = File('${shared.path}/PepeHub-library/library.json');
    final catalog = await manifest();
    final bytes = utf8.encode(jsonEncode(data));
    final hash = sha256.convert(bytes).toString();
    final object = File(
      '${shared.path}/PepeHub-library/objects/${hash.substring(0, 2)}/$hash.json',
    );
    await object.parent.create(recursive: true);
    await object.writeAsBytes(bytes);
    (catalog['documents'] as Map)[key] = hash;
    await file.writeAsString(jsonEncode(catalog));
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('library-folder-');
    shared = await Directory('${root.path}/shared').create();
  });
  tearDown(() async {
    for (final library in services) {
      library.dispose();
    }
    for (final db in databases) {
      await db.close();
    }
    services.clear();
    databases.clear();
    await root.delete(recursive: true);
  });

  for (final type in ['book', 'audiobook']) {
    test(
      'moves native history, notes, trash and covers of $type to a fresh device',
      () async {
        final a = device();
        await a.local.addBook(
          'Источник',
          'Автор',
          type == 'book' ? 'epub' : 'audio',
        );
        final source = (await a.local.records('book')).single;
        final id = uuid.v4();
        final png = await File(
          'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png',
        ).readAsBytes();
        final hash = sha256.convert(png).toString();
        final cover = File(a.covers!.path(hash));
        await cover.parent.create(recursive: true);
        await cover.writeAsBytes(png);
        await a.add(
          personalLibraryItem(id, type, {
            'title': 'В архиве',
            'status': 'finished',
            'cover': 'pepehub-cover:$hash',
          }),
          source.id,
        );
        if (type == 'book') {
          await ReadingLibrary(a.local).saveNote(
            ReadingNote(
              id: uuid.v4(),
              bookId: source.id,
              hash: 'a' * 64,
              bookTitle: 'В архиве',
              chapterTitle: 'Глава',
              quote: 'Цитата',
              comment: 'Мысль',
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
          await a.local.put('audio_note', uuid.v4(), {
            'bookId': source.id,
            'text': 'Заметка',
            'at': '2026-10-29T10:00:00.000Z',
          });
        }
        await a.local.put('session', uuid.v4(), {
          'bookId': source.id,
          'kind': type == 'book' ? 'reading' : 'listening',
          'startedAt': '2026-10-29T10:00:00.000Z',
          'endedAt': '2026-10-29T10:05:00.000Z',
          'activeSeconds': 300,
        });
        await a.deleteCards([id]);
        await a.local.setMeta('library-year-goal:personal:2026', '40');
        await a.local.setMeta('obsidian-token', 'private-token');
        await a.folderStorage.connect(shared.path);
        expect((await a.repository.entries())[id]!.sourceBookId, source.id);
        final b = device();
        await b.folderStorage.connect(shared.path);
        expect(b.trash.single.item.id, id);
        expect(b.trash.single.sourceBookId, isNull);
        expect(await b.notes!.entries(), hasLength(1));
        expect(await b.history!.entries(), hasLength(1));
        final named = jsonDecode(
          await File('${shared.path}/PepeHub-library/Корзина/В архиве.json')
              .readAsString(),
        ) as Map;
        expect(named['notes'], hasLength(1));
        expect(named['history'], hasLength(1));
        expect(
          await File(b.coverPath(b.trash.single.item)!).readAsBytes(),
          png,
        );
        expect(await b.local.meta('library-year-goal:personal:2026'), '40');
        expect(await b.local.meta('obsidian-token'), isNull);
        expect(await b.local.records('book'), isEmpty);
        await b.folderStorage.synchronize(force: true);
        expect(await b.notes!.entries(), hasLength(1));
        final files = await Directory('${shared.path}/PepeHub-library/objects')
            .list(recursive: true)
            .where((f) => f is File)
            .toList();
        for (final file in files.cast<File>()) {
          final raw = await file.readAsString();
          expect(raw, isNot(contains('private-token')));
          expect(raw, isNot(contains('sourceBookId')));
        }
      },
    );
  }

  test(
    'unchanged files stay untouched; one edit writes one object and manifest',
    () async {
      final a = device();
      final id = await add(a);
      final audio = await add(a, audio: true);
      await a.folderStorage.connect(shared.path);
      final namedIds = <String>{};
      await for (final file in Directory(
        '${shared.path}/PepeHub-library/Книги/Серия',
      ).list()) {
        if (file is File) {
          namedIds.add(
            jsonDecode(await file.readAsString())['card']['id'] as String,
          );
        }
      }
      expect(namedIds, {id, audio});
      final before = await manifest();
      final file = File('${shared.path}/PepeHub-library/library.json');
      final stamp = (await file.stat()).modified;
      await a.folderStorage.synchronize(force: true);
      expect((await file.stat()).modified, stamp);
      await rename(a, id, 'Новое название');
      await a.folderStorage.synchronize();
      final after = await manifest();
      final old = before['documents'] as Map, next = after['documents'] as Map;
      expect(next.keys.where((key) => next[key] != old[key]), ['cards/$id']);
    },
  );

  test(
    'polling an unchanged folder reads no files; a new manifest is imported',
    () async {
      final a = device(), b = device();
      await add(a, title: 'Первая');
      final disk = _CountingFolderFiles(shared);
      final storage = LibraryFolderStorage(a, fileSystem: (_) => disk);
      addTearDown(storage.dispose);
      await storage.connect(shared.path);
      // The first poll confirms the manifest by content and remembers it.
      expect(await storage.synchronize(), isFalse);
      disk.reads = 0;
      expect(await storage.synchronize(), isFalse);
      expect(await storage.synchronize(), isFalse);
      expect(disk.reads, 0);
      expect(storage.error, isNull);

      await b.folderStorage.connect(shared.path);
      final added = await add(b, title: 'С другого устройства');
      await b.folderStorage.synchronize();
      expect(await storage.synchronize(), isTrue);
      expect(disk.reads, greaterThan(0));
      expect((await a.repository.entries()).keys, contains(added));
    },
  );

  test(
    'upgrades a legacy folder and keeps only archive cards in named files',
    () async {
      final app = device();
      final archived = await add(app, title: 'Первый том');
      await app.folderStorage.connect(shared.path);
      final folder = '${shared.path}/PepeHub-library';
      final excluded = <String, ObsidianLibraryItem>{};
      for (final status in ['planned', 'active']) {
        final id = uuid.v4();
        excluded[id] = personalLibraryItem(id, 'book', {
          'title': status,
          'status': status,
        });
        await putDocument('cards/$id', excluded[id]!.toJson());
      }
      final legacy = (await manifest())..['version'] = 1;
      await File('$folder/library.json').writeAsString(jsonEncode(legacy));
      await File('$folder/objects/book-files.json').delete();
      await app.repository.mutate((cards) async {
        for (final e in excluded.entries) {
          cards[e.key] = LibraryEntry(e.value);
        }
      });
      await app.folderStorage.synchronize(force: true);
      expect(app.folderStorage.error, isNull);
      final after = await manifest();
      expect(after['version'], 2);
      expect(
        (after['documents'] as Map).keys.where((k) => k.startsWith('cards/')),
        ['cards/$archived'],
      );
      expect((await app.repository.entries()).keys, containsAll(excluded.keys));
      expect(
        jsonDecode(
          await File('$folder/objects/library-before-named-books.json')
              .readAsString(),
        ),
        legacy,
      );
      expect(
        await File('$folder/Книги/Серия/Первый том.json').exists(),
        isTrue,
      );
      expect(
        await Directory('$folder/Книги')
            .list(recursive: true)
            .where((entry) => entry is File)
            .length,
        1,
      );
    },
  );

  test(
    'moves a renamed book to its new series and preserves unrelated files',
    () async {
      final app = device();
      final id = await add(app, title: 'Первый том');
      await app.folderStorage.connect(shared.path);
      final folder = '${shared.path}/PepeHub-library/Книги';
      final other = File('$folder/Серия/Свои данные.json');
      await other.writeAsString('unchanged');
      await app.repository.mutate((cards) async {
        final entry = cards[id]!;
        cards[id] = LibraryEntry(
          entry.item.withValues({
            ...entry.item.values,
            'title': 'Том: новый?',
            'series': 'Другая / серия',
          }),
        );
      });
      await app.folderStorage.synchronize();
      expect(app.folderStorage.error, isNull);
      expect(await File('$folder/Серия/Первый том.json').exists(), isFalse);
      expect(
        await File('$folder/Другая серия/Том новый.json').exists(),
        isTrue,
      );
      expect(await other.readAsString(), 'unchanged');
    },
  );

  test(
    'merges independent edits and requires a choice for the same card',
    () async {
      final a = device(), b = device();
      final one = await add(a), two = await add(a, audio: true);
      await a.folderStorage.connect(shared.path);
      await b.folderStorage.connect(shared.path);
      await rename(a, one, 'Правка A');
      await rename(b, two, 'Правка B');
      await a.folderStorage.synchronize();
      await b.folderStorage.synchronize();
      await a.folderStorage.synchronize();
      expect((await a.repository.entries())[two]!.item.title, 'Правка B');
      expect((await b.repository.entries())[one]!.item.title, 'Правка A');
      await rename(a, one, 'Одновременно A');
      await rename(b, one, 'Одновременно B');
      await a.folderStorage.synchronize();
      final before = await manifest();
      await expectLater(
        b.folderStorage.synchronize(),
        throwsA(isA<LibraryFolderConflict>()),
      );
      expect(await manifest(), before);
      expect((await b.repository.entries())[one]!.item.title, 'Одновременно B');
      await b.folderStorage.synchronize(
        preference: LibraryFolderPreference.folder,
      );
      expect((await b.repository.entries())[one]!.item.title, 'Одновременно A');
    },
  );

  test('missing or corrupt synchronized objects never replace the local cache', () async {
    final a = device(), b = device();
    final id = await add(a);
    await a.folderStorage.connect(shared.path);
    await b.folderStorage.connect(shared.path);
    await rename(a, id, 'Новая версия');
    await a.folderStorage.synchronize();
    final data = await manifest();
    final hash = (data['documents'] as Map)['cards/$id'] as String;
    final object = File(
      '${shared.path}/PepeHub-library/objects/${hash.substring(0, 2)}/$hash.json',
    );
    final bytes = await object.readAsBytes();
    await object.delete();
    await expectLater(b.folderStorage.synchronize(), throwsStateError);
    expect((await b.repository.entries())[id]!.item.title, 'Книга');
    await object.writeAsString('{}');
    await expectLater(b.folderStorage.synchronize(), throwsStateError);
    await object.writeAsBytes(bytes);
    await b.folderStorage.synchronize();
    expect((await b.repository.entries())[id]!.item.title, 'Новая версия');
  });

  test(
    'restart keeps unsaved edits and reloads selected folder automatically',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final a = device(database: db);
      final id = await add(a);
      await a.folderStorage.connect(shared.path);
      await rename(a, id, 'До перезапуска');
      a.dispose();
      services.remove(a);
      final restarted = device(database: db);
      await restarted.reload();
      expect(
        restarted.folderStorage.folder,
        shared.path.replaceAll('/', Platform.pathSeparator),
      );
      final b = device();
      await b.folderStorage.connect(shared.path);
      expect(b.entries.single.item.title, 'До перезапуска');
    },
  );

  test(
    'unavailable folder keeps pending edits; disconnect keeps local data',
    () async {
      final a = device();
      final id = await add(a);
      await a.folderStorage.connect(shared.path);
      final moved = await shared.rename('${root.path}/offline');
      await rename(a, id, 'Офлайн');
      await expectLater(a.folderStorage.synchronize(), throwsStateError);
      expect((await a.repository.entries())[id]!.item.title, 'Офлайн');
      await moved.rename(shared.path);
      await a.folderStorage.synchronize();
      await a.folderStorage.disconnect();
      expect(a.folderStorage.enabled, isFalse);
      expect((await a.repository.entries())[id]!.item.title, 'Офлайн');
      expect(
        await File('${shared.path}/PepeHub-library/library.json').exists(),
        isTrue,
      );
    },
  );

  test('SQL deletes are observed and native journals are captured after connection', () async {
    final a = device();
    await a.local.addBook('Источник', 'Автор', 'epub');
    final source = (await a.local.records('book')).single;
    final id = uuid.v4();
    await a.add(
      personalLibraryItem(id, 'book', {'title': 'Книга', 'status': 'finished'}),
      source.id,
    );
    await a.local.setMeta('library-year-goal:personal:2026', '42');
    await a.folderStorage.connect(shared.path);
    await a.local.db.customStatement('DELETE FROM metadata WHERE key=?', [
      'library-year-goal:personal:2026',
    ]);
    await a.local.put('session', uuid.v4(), {
      'bookId': source.id,
      'kind': 'reading',
      'startedAt': '2026-10-29T10:00:00.000Z',
      'endedAt': '2026-10-29T10:05:00.000Z',
      'activeSeconds': 300,
    });
    await a.folderStorage.synchronize();
    final b = device();
    await b.folderStorage.connect(shared.path);
    expect(await b.history!.entries(), hasLength(1));
    expect(await b.local.meta('library-year-goal:personal:2026'), isNull);
  });

  test('1000 books and audiobooks transfer with notes, history and unread series volumes', () async {
    final a = device(), b = device();
    final cards = <String, LibraryEntry>{},
        history = <String, dynamic>{},
        notes = <String, dynamic>{};
    for (var i = 0; i < 1000; i++) {
      final id = uuid.v4(), activity = uuid.v4(), note = uuid.v4();
      final type = i.isEven ? 'book' : 'audiobook';
      cards[id] = LibraryEntry(
        personalLibraryItem(id, type, {
          'title': 'Произведение $i',
          'series': 'Серия ${i % 10}',
          'status': ['finished', 'paused', 'abandoned', 'unread'][i % 4],
        }),
      );
      history[activity] = {
        'value': ActivityStore.entry(
          id: activity,
          itemId: id,
          mediaType: type,
          day: '2026-10-29',
          durationMs: 300000,
          progress: 5,
          unit: type == 'book' ? 'pages' : 'minutes',
          origin: 'app-manual',
        ),
      };
      notes[note] = {
        'portable': true,
        'value': {
          'id': note,
          'itemId': id,
          'mediaType': type,
          'kind': 'markdown',
          'title': 'Заметка $i',
          'quote': 'Цитата $i',
          'text': 'Мысль $i',
          'tags': [],
          'characters': [],
          'color': 'yellow',
          'anchor': {},
          'origin': 'obsidian',
          'updatedAt': '2026-10-29T10:00:00.000Z',
          'deleted': false,
        },
      };
    }
    await a.repository.mutate((saved) async => saved.addAll(cards));
    await a.history!.mutate((state) async => state['slots'] = history);
    await a.notes!.mutate((state) async => state['slots'] = notes);
    await a.folderStorage.connect(shared.path);
    await b.folderStorage.connect(shared.path);
    expect(b.entries, hasLength(1000));
    expect(b.unreadSeriesEntries, hasLength(250));
    expect(await b.history!.entries(), hasLength(1000));
    expect(await b.notes!.entries(), hasLength(1000));
    expect(await b.local.records('book'), isEmpty);
    final before = await manifest();
    await b.folderStorage.synchronize();
    expect(await manifest(), before);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('saves and imports automatically without an explicit refresh', () async {
    final a = device(), b = device();
    final id = await add(a);
    await a.folderStorage.connect(shared.path);
    await b.folderStorage.connect(shared.path);
    await rename(a, id, 'Автоматически');
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    while ((await b.repository.entries())[id]!.item.title != 'Автоматически') {
      if (DateTime.now().isAfter(deadline)) {
        fail('Automatic folder synchronization timed out');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(b.entries.single.item.title, 'Автоматически');
  });

  test(
    'permanent removal propagates without resurrecting a card on restart',
    () async {
      final a = device(), b = device();
      final id = await add(a);
      await a.folderStorage.connect(shared.path);
      await b.folderStorage.connect(shared.path);
      await a.purgeCards([id], includeVisible: true);
      await a.folderStorage.synchronize();
      await b.folderStorage.synchronize();
      expect(await b.repository.entries(), isEmpty);
      expect((await manifest())['documents'], isNot(contains('cards/$id')));
      b.dispose();
      services.remove(b);
      final restarted = device(database: b.local.db);
      await restarted.reload();
      expect(await restarted.repository.entries(), isEmpty);
    },
  );

  test(
    'Android SAF publishes and reloads the same portable folder format',
    () async {
      const uri = 'content://library/tree/shared';
      final disk = LocalPeerFiles(shared);
      final stages = <String, PeerStagingFile>{};
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(peerFilesChannel, (call) async {
        final args = call.arguments as Map;
        expect(args['root'], uri);
        final path = args['path'] as String?;
        switch (call.method) {
          case 'check':
            await disk.checkRoot();
            return null;
          case 'hash':
            return disk.hash(path!);
          case 'stat':
            final stamp = await disk.stamp(path!);
            return stamp == 'missing' ? null : stamp;
          case 'read':
            return Uint8List.fromList(
              await disk.read(
                path!,
                args['offset'] as int,
                args['count'] as int,
              ),
            );
          case 'stage_prepare':
            final hash = (args['stage'] as String).split('-').last;
            stages[path!] = await disk.stage(
              PeerFileEntry(
                path: path,
                hash: hash,
                bytes: 0,
                clock: const {'00000000-0000-4000-8000-000000000001': 1},
              ),
            );
            return stages[path]!.prepare();
          case 'stage_reset':
            await stages[path]!.reset();
            return null;
          case 'stage_append':
            await stages[path]!.append(
              args['offset'] as int,
              (args['bytes'] as List).cast<int>(),
            );
            return null;
          case 'stage_publish':
            await stages[path]!.publish(args['expected'] as String?);
            return null;
          case 'stage_discard':
            await stages[path]!.discard();
            return null;
          case 'remove':
            await disk.remove(path!, args['expected'] as String?);
            return null;
          default:
            throw StateError('Unexpected folder method ${call.method}');
        }
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(peerFilesChannel, null),
      );
      final a = device(), b = device();
      final id = await add(a, audio: true);
      await a.folderStorage.connect(uri);
      await b.folderStorage.connect(uri);
      expect(b.entries.single.item.id, id);
      await rename(a, id, 'Через SAF');
      await a.folderStorage.synchronize();
      await b.folderStorage.synchronize();
      expect((await b.repository.entries())[id]!.item.title, 'Через SAF');
      expect(a.folderStorage.error, isNull);
      expect(
        await File('${shared.path}/PepeHub-library/Книги/Серия/Книга.json')
            .exists(),
        isFalse,
      );
    },
  );

  for (final preference in LibraryFolderPreference.values) {
    test(
      'purge versus new journal resolves the whole work with $preference',
      () async {
        final a = device(), b = device();
        final id = await add(a);
        await a.folderStorage.connect(shared.path);
        await b.folderStorage.connect(shared.path);
        final activity = uuid.v4();
        await b.history!.mutate((state) async {
          (state['slots'] as Map)[activity] = {
            'value': ActivityStore.entry(
              id: activity,
              itemId: id,
              mediaType: 'book',
              day: '2026-10-29',
              durationMs: 300000,
              progress: 5,
              unit: 'pages',
              origin: 'app-manual',
            ),
          };
        });
        await a.deleteCards([id]);
        await a.purgeCards([id]);
        await a.folderStorage.synchronize();
        await expectLater(
          b.folderStorage.synchronize(),
          throwsA(isA<LibraryFolderConflict>()),
        );
        await b.folderStorage.synchronize(preference: preference);
        final retained = preference == LibraryFolderPreference.local;
        expect((await b.repository.entries()).containsKey(id), retained);
        expect(await b.history!.entries(), hasLength(retained ? 1 : 0));
      },
    );
  }

  test(
    'opens the selected archive directory without creating a nested archive',
    () async {
      final a = device(), b = device();
      final id = await add(a);
      await a.folderStorage.connect(shared.path);
      final selected = '${shared.path}/PepeHub-library';
      await b.folderStorage.connect(selected);
      expect(b.entries.single.item.id, id);
      expect(
        b.folderStorage.displayPath,
        selected.replaceAll('/', Platform.pathSeparator),
      );
      expect(await Directory('$selected/PepeHub-library').exists(), isFalse);
      b.dispose();
      services.remove(b);
      final restarted = device(database: b.local.db);
      await restarted.reload();
      expect(restarted.entries.single.item.id, id);
      expect(
        restarted.folderStorage.displayPath,
        selected.replaceAll('/', Platform.pathSeparator),
      );
    },
  );

  test('uses an empty directory named PepeHub-library directly', () async {
    final a = device();
    await add(a);
    final selected = await Directory('${shared.path}/PepeHub-library').create();
    await a.folderStorage.connect(selected.path);
    expect(await File('${selected.path}/library.json').exists(), isTrue);
    expect(
      await Directory('${selected.path}/PepeHub-library').exists(),
      isFalse,
    );
  });

  test(
    'relocates from an unavailable old directory using the working copy',
    () async {
      final a = device(), b = device();
      final id = await add(a);
      await a.folderStorage.connect(shared.path);
      await shared.rename('${root.path}/old-folder');
      await rename(a, id, 'После перемещения');
      final target = await Directory('${root.path}/new-folder').create();
      await a.folderStorage.connect(target.path);
      expect(a.folderStorage.warning, isNotNull);
      await b.folderStorage.connect(target.path);
      expect(b.entries.single.item.title, 'После перемещения');
    },
  );

  test(
    'disconnect flushes edits without waiting for the automatic save interval',
    () async {
      final a = device(), b = device();
      final id = await add(a);
      await a.folderStorage.connect(shared.path);
      await rename(a, id, 'Последняя правка');
      expect(await a.folderStorage.disconnect(), isTrue);
      await b.folderStorage.connect(shared.path);
      expect(b.entries.single.item.title, 'Последняя правка');
    },
  );

  test(
    'disconnect reports an unavailable disk and keeps unsaved edits locally',
    () async {
      final a = device();
      final id = await add(a);
      await a.folderStorage.connect(shared.path);
      await shared.rename('${root.path}/offline');
      await rename(a, id, 'Не потерять');
      expect(await a.folderStorage.disconnect(), isFalse);
      expect((await a.repository.entries())[id]!.item.title, 'Не потерять');
      expect(a.folderStorage.enabled, isFalse);
    },
  );

  test(
    'slow folder writes release SQLite and retry concurrent local edits',
    () async {
      final a = device(), b = device();
      final id = await add(a);
      final disk = _SlowFolderFiles(shared);
      final storage = LibraryFolderStorage(a, fileSystem: (_) => disk);
      addTearDown(storage.dispose);
      final pending = storage.connect(shared.path);
      await disk.started.future.timeout(const Duration(seconds: 5));
      try {
        await rename(
          a,
          id,
          'Во время сохранения',
        ).timeout(const Duration(seconds: 2));
      } finally {
        disk.release.complete();
      }
      await pending;
      await b.folderStorage.connect(shared.path);
      expect(b.entries.single.item.title, 'Во время сохранения');
    },
  );

  test(
    'rejects duplicate journal IDs before replacing any local data',
    () async {
      final a = device(), b = device();
      final one = await add(a), two = await add(a, audio: true);
      await a.folderStorage.connect(shared.path);
      final activity = uuid.v4();
      for (final pair in [(one, 'book'), (two, 'audiobook')]) {
        await putDocument('history/${pair.$1}', {
          activity: ActivityStore.entry(
            id: activity,
            itemId: pair.$1,
            mediaType: pair.$2,
            day: '2026-10-29',
            durationMs: 300000,
            progress: 5,
            unit: 'pages',
            origin: 'app-manual',
          ),
        });
      }
      final retained = await add(b, title: 'Локальная карточка');
      await expectLater(
        b.folderStorage.connect(shared.path),
        throwsFormatException,
      );
      expect((await b.repository.entries()).keys, [retained]);
      expect(await b.history!.entries(), isEmpty);
    },
  );

  test(
    'repairs a damaged local cover from the verified archive copy',
    () async {
      final a = device();
      final bytes = await File(
        'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png',
      ).readAsBytes();
      final hash = sha256.convert(bytes).toString();
      final cover = File(a.covers!.path(hash));
      await cover.parent.create(recursive: true);
      await cover.writeAsBytes(bytes);
      await a.add(
        personalLibraryItem(uuid.v4(), 'book', {
          'title': 'С обложкой',
          'status': 'finished',
          'cover': 'pepehub-cover:$hash',
        }),
        '',
      );
      await a.folderStorage.connect(shared.path);
      await cover.writeAsString('damaged cache');
      await a.folderStorage.synchronize(force: true);
      expect(await cover.readAsBytes(), bytes);
      expect(a.folderStorage.error, isNull);
    },
  );

  test(
    'failed relocation keeps the previous selection and working data',
    () async {
      final a = device();
      final id = await add(a);
      await a.folderStorage.connect(shared.path);
      final previous = a.folderStorage.folder;
      await shared.rename('${root.path}/offline');
      final invalid = await Directory('${root.path}/invalid').create();
      await File('${invalid.path}/library.json').writeAsString('{}');
      await expectLater(
        a.folderStorage.connect(invalid.path),
        throwsFormatException,
      );
      expect(a.folderStorage.folder, previous);
      expect(await a.local.meta('library-storage-folder-v1'), previous);
      expect(a.folderStorage.warning, isNull);
      expect((await a.repository.entries()).containsKey(id), isTrue);
    },
  );

  test('importing folder settings retains unrelated device metadata', () async {
    final a = device(), b = device();
    await add(a);
    await a.folderStorage.connect(shared.path);
    await b.local.setMeta('library-trash-retention-days-extra', 'device-only');
    await b.folderStorage.connect(shared.path);
    expect(
      await b.local.meta('library-trash-retention-days-extra'),
      'device-only',
    );
  });

  for (final settings in [
    {'library-trash-retention-days-extra': '30'},
    {'library-series-length:серия': '501'},
  ]) {
    test('rejects invalid archive settings $settings', () async {
      final a = device(), b = device();
      await add(a);
      await a.folderStorage.connect(shared.path);
      await putDocument('settings', settings);
      await expectLater(
        b.folderStorage.connect(shared.path),
        throwsFormatException,
      );
      expect(await b.repository.entries(), isEmpty);
      expect(b.folderStorage.enabled, isFalse);
    });
  }

  testWidgets(
    'folder controls fit a narrow screen and cancellation keeps the connection',
    (tester) async {
      final a = device();
      await tester.runAsync(() async {
        await add(a);
        await a.folderStorage.connect(shared.path);
      });
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(home: LibraryDataPage(library: a)));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Папка библиотеки'), findsOneWidget);
      expect(find.text('Обновить из папки'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Отключить папку'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(find.text('Отключить папку')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Отключить папку библиотеки?'), findsOneWidget);
      await tester.tap(find.text('Отмена'));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(a.folderStorage.enabled, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
