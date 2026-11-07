import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pepehub/audio/audio_catalog.dart';
import 'package:pepehub/audio/audio_folder.dart';
import 'package:pepehub/audio/audio_roots.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/hidden_files.dart';
import 'package:pepehub/library/library_exchange.dart';
import 'package:pepehub/library/library_service.dart';
import 'package:pepehub/library/models.dart';
import 'package:pepehub/library/personal_library.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/reader/reading_roots.dart';
import 'package:pepehub/ui/hidden_deleted_page.dart';
import 'package:pepehub/ui/library_card_actions.dart';
import 'package:pepehub/ui/reading_roots_page.dart';

import 'video_player_tools_widget_test.dart' show ready;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late AppDatabase db;
  late Repository repo;
  late AssetStore assets;
  late LibraryService library;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('pepehub-folders-trash-');
    db = AppDatabase(NativeDatabase.memory());
    repo = Repository(db);
    assets = AssetStore(repo, Directory('${root.path}/managed'));
    final client = MockClient((_) => throw StateError('offline'));
    library = LibraryService(repo, client, assets: assets);
    addTearDown(client.close);
  });
  tearDown(() async {
    library.dispose();
    await db.close();
    await root.delete(recursive: true);
  });
  LibraryEntry card(
    String id, {
    String? deleted,
    String title = 'Card',
    bool audio = false,
    String? sourceBookId,
  }) => LibraryEntry(
    personalLibraryItem(id, audio ? 'audiobook' : 'book', {
      'title': title,
      'status': 'finished',
      'pepehub_deleted_at': deleted,
      'notes': 'Keep notes',
      'cover': 'pepehub-cover:${'a' * 64}',
    }),
    sourceBookId: sourceBookId,
  );

  test('reading scan reports unsupported, duplicate and unreadable files; refresh preserves a custom name and history', () async {
    final source = await Directory('${root.path}/source').create();
    await File('${source.path}/one.txt').writeAsString('one');
    await File('${source.path}/duplicate.txt').writeAsString('one');
    await File('${source.path}/bad.txt').writeAsString('');
    await File('${source.path}/image.jpg').writeAsBytes([1]);
    final manager = ReadingRoots(assets);
    var folder = await manager.connect(
      await scanAudioFolder(source.path, books: true),
      skipUnreadable: true,
    );
    expect(folder.report, containsPair('found', 4));
    expect(folder.report, containsPair('added', 1));
    expect(folder.report, containsPair('unsupported', 1));
    expect(folder.report, containsPair('duplicates', 1));
    expect(folder.report, containsPair('errors', 1));
    expect(folder.lastScan, isNotNull);
    final changesBeforeRename = repo.externalChanges.value;
    await manager.rename(folder, 'My books');
    expect(repo.externalChanges.value, greaterThan(changesBeforeRename));
    await repo.setMeta('reader:test-position', '{"chapter":4}');
    await File('${source.path}/bad.txt').delete();
    await File('${source.path}/new.txt').writeAsString('new book');
    folder = await manager.refresh((await manager.list()).single);
    expect(folder.title, 'My books');
    expect(folder.report, containsPair('added', 1));
    expect(folder.warnings, isEmpty);
    expect(await repo.meta('reader:test-position'), '{"chapter":4}');
    expect(library.entries, isEmpty); // A folder never adds archive cards.
  });

  test('audio scan reports files and detects missing sources without losing records', () async {
    final source = await Directory('${root.path}/source').create();
    final file = await File('${source.path}/one.mp3').writeAsBytes([1, 2, 3]);
    await File('${source.path}/other.bin').writeAsBytes([1]);
    final scan = await scanAudioFolder(source.path);
    await connectAudioCatalog(assets, scan, groupAudioCatalog(scan));
    final manager = AudioRoots(assets);
    final folder = (await manager.list()).single;
    expect(folder.data['lastScan'], isNotNull);
    await file.delete();
    final result = await manager.refresh(folder);
    expect(result.found, 1);
    expect(result.unsupported, 1);
    expect(result.warnings, isNotEmpty);
    expect(
      await repo.meta('audio-source-missing:${folder.bookIds.single}'),
      '1',
    );
    expect((await hiddenFiles(repo)).single.tab, 1);
    expect(await repo.record(folder.bookIds.single), isNotNull);
  });

  testWidgets(
    'disconnect requires confirmation and cancellation leaves all books available',
    (tester) async {
      final manager = ReadingRoots(assets);
      late File file;
      final folder = await tester.runAsync(() async {
        final source = await Directory('${root.path}/source').create();
        file = await File('${source.path}/one.txt').writeAsString('one');
        return manager.connect(await scanAudioFolder(source.path, books: true));
      });
      await tester.pumpWidget(
        MaterialApp(home: ReadingRootsPage(assets: assets)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Отключить папку'));
      await tester.pumpAndSettle();
      expect(find.text('Отключить папку книг?'), findsOneWidget);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(await manager.list(), hasLength(1));
      expect(
        await repo.meta('reading-library-hidden:${folder!.bookIds.single}'),
        '0',
      );
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Отключить папку'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Отключить'));
      await ready(
        tester,
        () =>
            (tester.state(find.byType(ReadingRootsPage)) as dynamic).busy ==
            false,
      );
      expect(await manager.list(), isEmpty);
      expect(await tester.runAsync(file.exists), true);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test('bulk restore keeps data; permanent purge only removes trash and its journal slots', () async {
    final deleted = DateTime.now().toUtc().toIso8601String();
    await library.repository.mutate((entries) async {
      entries.addAll({
        'one': card('one', deleted: deleted),
        'two': card('two', deleted: deleted, audio: true),
        'live': card('live'),
      });
    });
    for (final store in [library.history!, library.notes!]) {
      await store.mutate((state) async {
        state['slots'] = {
          for (final id in ['one', 'two', 'live'])
            id: {
              'value': {'itemId': id, 'text': 'Keep $id'},
            },
        };
      });
    }
    final file = await File('${root.path}/original.txt')
        .writeAsString('original');
    await repo.setMeta('reader:saved-position', 'keep');
    await library.restoreCards(['one', 'two']);
    expect(library.trash, isEmpty);
    expect(library.entries, hasLength(3));
    expect(library.entries.first.item.values['notes'], 'Keep notes');
    await library.deleteCards(['one']);
    expect(await library.purgeCards(['one', 'live']), 1);
    expect(
      (await library.repository.entries()).keys,
      containsAll(['two', 'live']),
    );
    for (final store in [library.history!, library.notes!]) {
      final slots = (await store.state())['slots'] as Map;
      expect(slots.keys, containsAll(['two', 'live']));
      expect(slots.containsKey('one'), false);
    }
    expect(await repo.meta('reader:saved-position'), 'keep');
    expect(await file.readAsString(), 'original');
  });

  test('auto cleanup is opt-in, removes only expired dates and keeps unknown/recent deletion dates', () async {
    final old = DateTime.now()
        .toUtc()
        .subtract(const Duration(days: 40))
        .toIso8601String();
    final recent = DateTime.now().toUtc().toIso8601String();
    await library.repository.mutate((entries) async {
      entries.addAll({
        'old': card('old', deleted: old),
        'recent': card('recent', deleted: recent),
        'unknown': card('unknown', deleted: 'legacy-unknown'),
      });
    });
    await library.loadCached();
    expect(library.trash, hasLength(3));
    await library.setTrashRetention(30);
    expect(
      (await library.repository.entries()).keys,
      unorderedEquals(['recent', 'unknown']),
    );
    await library.setTrashRetention(0);
    expect(await repo.meta('library-trash-retention-days'), '0');
  });

  test(
    'purge rolls back the card removal if associated journal cannot be changed',
    () async {
      await library.repository.mutate((entries) async {
        entries['one'] = card(
          'one',
          deleted: DateTime.now()
              .toUtc()
              .subtract(const Duration(days: 40))
              .toIso8601String(),
        );
      });
      await repo.setMeta(library.notes!.key, '{broken');
      await expectLater(library.purgeCards(['one']), throwsFormatException);
      expect((await library.repository.entries()).containsKey('one'), true);
      await expectLater(library.setTrashRetention(7), throwsFormatException);
      expect(await repo.meta('library-trash-retention-days'), isNull);
    },
  );

  for (final withFiles in [false, true]) {
    testWidgets(
      'permanent removal from an active card ${withFiles ? 'with' : 'without'} its source',
      (tester) async {
        final file = File('${root.path}/original.txt');
        final cover = File(library.covers!.path('a' * 64));
        final source = (await tester.runAsync(() async {
          await file.writeAsString('original');
          await cover.parent.create(recursive: true);
          await cover.writeAsBytes([1, 2, 3]);
          return assets.importBook(FolderAudioFile(file.path, 'original.txt'));
        }))!;
        await library.repository.mutate((entries) async {
          entries['one'] = card('one', sourceBookId: source.bookId);
          if (!withFiles) entries['two'] = card('two');
        });
        await repo.setMeta(
          'library-exchange:legacy',
          jsonEncode({
            'one': {
              'remoteId': 'remote-one',
              'base': {'title': 'Card'},
            },
          }),
        );
        await library.loadCached();
        var completed = false;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    completed = await deleteLibraryCards(context, library, [
                      'one',
                    ]);
                  },
                  child: const Text('Открыть удаление'),
                ),
              ),
            ),
          ),
        );
        Future<void> open() async {
          await tester.tap(find.text('Открыть удаление'));
          await tester.pumpAndSettle();
        }

        await open();
        if (withFiles) {
          await tester.tap(find.text('Удалить карточку и файлы…'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Отмена'));
          await tester.pumpAndSettle();
          expect(library.visibleEntries, hasLength(1));
          expect(await tester.runAsync(() => File(source.path).exists()), true);
          await open();
          await tester.tap(find.text('Удалить карточку и файлы…'));
          await tester.pumpAndSettle();
        }
        await tester.tap(
          find.text(
            withFiles ? 'Удалить карточку и файлы' : 'Удалить только карточку',
          ),
        );
        await ready(tester, () => completed);
        expect((await library.repository.entries()).containsKey('one'), false);
        expect(library.trash, isEmpty);
        expect(
          await tester.runAsync(() => File(source.path).exists()),
          !withFiles,
        );
        expect(await tester.runAsync(file.exists), true);
        expect(await tester.runAsync(cover.exists), !withFiles);
        final bindings = await LibraryExchange(
          repo,
          library.repository,
          'legacy',
        ).bindings();
        expect((bindings['one'] as Map)['detached'], true);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    '2000 hidden books/audio stay lazy; filtered bulk restore changes only the two selected files',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await repo.db.transaction(() async {
        for (var i = 0; i < 2000; i++) {
          final audio = i.isOdd;
          await repo.db.customStatement(
            'INSERT INTO records VALUES(?,?,1,0,?)',
            [
              'book-$i',
              'book',
              jsonEncode({
                'title': i < 2 ? 'Pair $i' : 'Book $i',
                'format': audio ? 'audio' : 'txt',
              }),
            ],
          );
          await repo.setMeta(
            '${audio ? 'audio' : 'reading'}-library-hidden:book-$i',
            '1',
          );
        }
      });
      await tester.pumpWidget(
        MaterialApp(home: HiddenDeletedPage(library: library)),
      );
      final dynamic state = tester.state(find.byType(HiddenDeletedPage));
      await ready(tester, () => !state.loading);
      expect(find.byType(ListTile).evaluate().length, lessThan(25));
      await tester.enterText(find.byType(TextField), 'Pair');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Корзина'));
      await tester.tap(find.text('Корзина'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Pair',
      );
      await tester.ensureVisible(find.text('Убранные'));
      await tester.tap(find.text('Убранные'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Выбрать найденные (2)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Вернуть выбранные (2)'));
      await ready(tester, () => !state.busy);
      expect(await repo.meta('reading-library-hidden:book-0'), '0');
      expect(await repo.meta('audio-library-hidden:book-1'), '0');
      expect(await repo.meta('reading-library-hidden:book-2'), '1');
      expect(library.entries, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final width in [360.0, 1280.0]) {
    testWidgets(
      'trash has search, mass restore, date and confirmed permanent removal at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 840);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await library.repository.mutate((entries) async {
          entries.addAll({
            'one': card(
              'one',
              title: 'Selected card',
              deleted: DateTime.now().toUtc().toIso8601String(),
            ),
            'two': card(
              'two',
              title: 'Other card',
              deleted: DateTime.now().toUtc().toIso8601String(),
            ),
          });
        });
        await tester.pumpWidget(
          MaterialApp(home: HiddenDeletedPage(library: library, initialTab: 3)),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('Удалено:'), findsWidgets);
        await tester.enterText(find.byType(TextField), 'Selected');
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Удалить окончательно'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Отмена'));
        await tester.pumpAndSettle();
        expect(library.trash, hasLength(2));
        await tester.tap(find.byTooltip('Удалить окончательно'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Удалить только карточку'));
        await ready(
          tester,
          () =>
              (tester.state(find.byType(HiddenDeletedPage)) as dynamic).busy ==
              false,
        );
        expect((await library.repository.entries()).keys, ['two']);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
