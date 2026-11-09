import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pepehub/audio/audio_folder.dart';
import 'package:pepehub/main.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/reader/reading_book_actions.dart';
import 'package:pepehub/reader/reading_roots.dart';
import 'package:pepehub/reader/reading_library.dart';
import 'package:pepehub/ui/reading_hidden_books_page.dart';

import 'folder_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(audioFolderChannel, null));
  Future<(FolderFixture, AssetStore, File)> fixture({bool close = true}) async {
    final f = FolderFixture();
    await f.open();
    if (close) addTearDown(f.close);
    final assets = AssetStore(
      f.repository,
      Directory(p.join(f.base.path, 'managed')),
    );
    final file = await File(p.join(f.root.path, 'story.txt'))
        .writeAsString('An example book.');
    await ReadingRoots(assets)
        .connect(await scanAudioFolder(f.root.path, books: true));
    return (f, assets, file);
  }

  test('hide is local, survives refresh and restore retains file, notes and progress', () async {
    final (f, assets, file) = await fixture();
    final book = (await assets.list()).single;
    await f.repository.setMeta('reader:${book.hash}', 'saved position');
    await f.repository.setMeta('reading-note:test', 'saved note');
    await ReadingBookActions(assets).hide(book.bookId);
    await ReadingRoots(assets)
        .connect(await scanAudioFolder(f.root.path, books: true));
    expect(
      await f.repository.meta('reading-library-hidden:${book.bookId}'),
      '1',
    );
    expect(await file.exists(), true);
    expect((await f.repository.record(book.bookId))!.deleted, false);
    await ReadingBookActions(assets).hide(book.bookId, hidden: false);
    expect(
      await f.repository.meta('reading-library-hidden:${book.bookId}'),
      '0',
    );
    expect(await f.repository.meta('reader:${book.hash}'), 'saved position');
    expect(await f.repository.meta('reading-note:test'), 'saved note');
  });

  test('missing source disappears after folder refresh but imported copy stays usable', () async {
    final (f, assets, file) = await fixture();
    final linked = (await assets.list()).single;
    await file.delete();
    await ReadingRoots(assets)
        .connect(await scanAudioFolder(f.root.path, books: true));
    expect(
      await f.repository.meta('reading-library-hidden:${linked.bookId}'),
      '1',
    );
    await file.writeAsString('An example book.');
    final imported = await assets.importBook(
      FolderAudioFile(file.path, 'story.txt'),
    );
    await ReadingRoots(assets)
        .connect(await scanAudioFolder(f.root.path, books: true));
    await file.delete();
    await ReadingRoots(assets)
        .connect(await scanAudioFolder(f.root.path, books: true));
    expect(
      await f.repository.meta('reading-library-hidden:${linked.bookId}'),
      '0',
    );
    expect(await File(imported.path).exists(), true);
  });

  test('permanent delete removes selected source, independent copy and cache, preserving history and unrelated files', () async {
    final (f, assets, file) = await fixture();
    final imported = await assets.importBook(
      FolderAudioFile(file.path, 'story.txt'),
    );
    final cache = await Directory(
      p.join(assets.directory.path, 'reading-cache'),
    ).create(recursive: true);
    final cached = await File(p.join(cache.path, '${imported.hash}.txt'))
        .writeAsString('cached');
    final other = await File(p.join(f.root.path, 'unrelated.txt'))
        .writeAsString('keep');
    await f.repository.setMeta('reader:${imported.hash}', 'history');
    await ReadingBookActions(assets).deleteForever(imported.bookId);
    expect(await file.exists(), false);
    expect(await File(imported.path).exists(), false);
    expect(await cached.exists(), false);
    expect(await other.readAsString(), 'keep');
    expect(await f.repository.meta('reader:${imported.hash}'), 'history');
    expect(
      await f.repository.meta('reading-user-hidden:${imported.bookId}'),
      '0',
    );
    await ReadingBookActions(assets).deleteForever(imported.bookId);
  });

  test(
    'changed source is never silently deleted by an old library card',
    () async {
      final (f, assets, file) = await fixture();
      final book = (await assets.list()).single;
      await file.writeAsString('A replacement book');
      await expectLater(
        ReadingBookActions(assets).deleteForever(book.bookId),
        throwsStateError,
      );
      expect(await file.readAsString(), 'A replacement book');
      expect(
        await f.repository.meta('reading-user-hidden:${book.bookId}'),
        isNull,
      );
    },
  );

  const safRoot = 'content://books.test/tree/books';
  const safFile = '$safRoot/document/story';
  Future<(FolderFixture, AssetStore, File)> safFixture() async {
    final prepared = await fixture(close: false);
    final (f, assets, _) = prepared;
    final book = (await assets.list()).single;
    await ReadingLibrary(f.repository).index(assets, book);
    await f.repository.db.customStatement(
      'UPDATE local_assets SET path=? WHERE book_id=?',
      [safFile, book.bookId],
    );
    await f.repository.db.customStatement('DELETE FROM metadata WHERE key=?', [
      'reading-source-path:${book.bookId}',
    ]);
    return prepared;
  }

  test('SAF permission failures are typed and no copy is deleted before every preflight passes', () async {
    final (f, assets, _) = await safFixture();
    addTearDown(f.close);
    final book = (await assets.list()).single;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(audioFolderChannel, (call) async {
      calls.add(call);
      throw PlatformException(
        code: 'book_write_permission',
        message: 'Нужен доступ к папке',
        details: {'root': safRoot},
      );
    });
    await expectLater(
      ReadingBookActions(assets).deleteForever(book.bookId),
      throwsA(
        isA<ReadingBookWriteAccessRequired>().having(
          (e) => e.root,
          'root',
          safRoot,
        ),
      ),
    );
    expect(calls.single.arguments['checkOnly'], true);
    expect(
      await f.repository.meta('reading-user-hidden:${book.bookId}'),
      isNull,
    );
    expect(
      readingBookActionMessage(
        PlatformException(code: 'folder', message: 'Понятная ошибка'),
      ),
      'Понятная ошибка',
    );
  });

  for (final outcome in [
    'cancel-dialog',
    'cancel-picker',
    'granted',
    'changed',
  ]) {
    testWidgets('SAF delete recovers through the real book menu: $outcome', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final prepared = await tester.runAsync(safFixture);
      final (f, assets, file) = prepared!;
      addTearDown(() => tester.runAsync(f.close));
      final book = (await assets.list()).single;
      final calls = <MethodCall>[];
      var writable = false, changed = false;
      messenger.setMockMethodCallHandler(audioFolderChannel, (call) async {
        calls.add(call);
        if (call.method == 'exists') return true;
        if (call.method == 'requestBookWriteAccess') {
          expect(call.arguments['root'], safRoot);
          writable = outcome != 'cancel-picker';
          changed = outcome == 'changed';
          return writable;
        }
        if (call.method == 'deleteBookFile') {
          if (!writable) {
            throw PlatformException(
              code: 'book_write_permission',
              message: 'Нужен доступ к папке',
              details: {'root': safRoot},
            );
          }
          if (changed) {
            throw PlatformException(
              code: 'folder',
              message: 'Файл изменился. Обновите папку книг перед удалением.',
            );
          }
          return null;
        }
        return null;
      });
      await f.repository.setMeta('library-section', 'reading');
      await tester.pumpWidget(
        PepeHubApp(repository: f.repository, assets: assets),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Действия с книгой').first);
      await tester.tap(find.byTooltip('Действия с книгой').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Удалить…'));
      await tester.tap(find.text('Удалить…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Вместе с файлом'));
      await tester.pumpAndSettle();
      // Database/file preflights use the real event loop, even in a widget test.
      for (
        var attempt = 0;
        attempt < 20 && find.text('Нужен доступ к папке').evaluate().isEmpty;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pumpAndSettle();
      }
      expect(find.text('Нужен доступ к папке'), findsOneWidget);
      await tester.tap(
        find.text(outcome == 'cancel-dialog' ? 'Отмена' : 'Выбрать папку'),
      );
      for (var attempt = 0; attempt < 20; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pumpAndSettle();
        if (outcome == 'granted' &&
            await f.repository.meta('reading-user-hidden:${book.bookId}') ==
                '1') {
          break;
        }
        if (outcome == 'changed' &&
            find
                .text('Файл изменился. Обновите папку книг перед удалением.')
                .evaluate()
                .isNotEmpty) {
          break;
        }
      }
      final actualDeletes = calls.where(
        (c) =>
            c.method == 'deleteBookFile' && c.arguments['checkOnly'] == false,
      );
      expect(actualDeletes.length, outcome == 'granted' ? 1 : 0);
      expect(
        calls.where((c) => c.method == 'requestBookWriteAccess').length,
        outcome == 'cancel-dialog' ? 0 : 1,
      );
      expect(
        await f.repository.meta('reading-user-hidden:${book.bookId}'),
        outcome == 'granted' ? '0' : isNull,
      );
      // Only a book whose file went is moved to the trash.
      expect(
        await f.repository.meta('book-shelf-removed:${book.bookId}'),
        outcome == 'granted' ? '1' : isNull,
      );
      if (outcome == 'changed') {
        expect(find.textContaining('PlatformException'), findsNothing);
      }
      expect(await tester.runAsync(file.exists), true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  testWidgets(
    'book menu offers both removals and reveal; cancellation keeps file; hidden list restores shelf',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final prepared = await tester.runAsync(() => fixture(close: false));
      final (f, assets, file) = prepared!;
      addTearDown(() => tester.runAsync(f.close));
      final repo = f.repository;
      await tester.runAsync(() async {
        await ReadingLibrary(repo).index(assets, (await assets.list()).single);
      });
      await repo.setMeta('library-section', 'reading');
      await tester.pumpWidget(PepeHubApp(repository: repo, assets: assets));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Действия с книгой').first);
      await tester.tap(find.byTooltip('Действия с книгой').first);
      await tester.pumpAndSettle();
      if (find.text('Показать в проводнике').evaluate().isEmpty) {
        await tester.tap(find.text('Файлы и обмен'));
        await tester.pumpAndSettle();
      }
      expect(find.text('Показать в проводнике'), findsOneWidget);
      await tester.tap(find.text('Файлы и обмен'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Удалить…'));
      await tester.tap(find.text('Удалить…'));
      await tester.pumpAndSettle();
      expect(find.text('Удалить «story»?'), findsOneWidget);
      expect(find.text('Только из PepeHub'), findsOneWidget);
      expect(find.text('Вместе с файлом'), findsOneWidget);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(await tester.runAsync(file.exists), true);
      await tester.tap(find.byTooltip('Действия с книгой').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Скрыть с полки'));
      await tester.tap(find.text('Скрыть с полки'));
      await tester.pumpAndSettle();
      expect(
        await repo.meta(
          'reading-user-hidden:${(await assets.list()).single.bookId}',
        ),
        '1',
      );
      await tester.pumpWidget(
        MaterialApp(home: ReadingHiddenBooksPage(assets: assets)),
      );
      await tester.pumpAndSettle();
      expect(find.text('story'), findsOneWidget);
      await tester.tap(find.byTooltip('Вернуть на полку'));
      await tester.pumpAndSettle();
      expect(find.text('Скрытых книг нет'), findsOneWidget);
      expect(await tester.runAsync(file.exists), true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
