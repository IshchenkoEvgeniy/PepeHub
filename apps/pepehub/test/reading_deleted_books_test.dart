import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pepehub/audio/audio_folder.dart';
import 'package:pepehub/main.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/reader/reading_book_actions.dart';
import 'package:pepehub/reader/reading_book_visibility.dart';
import 'package:pepehub/reader/reading_library.dart';
import 'package:pepehub/reader/reading_roots.dart';
import 'package:pepehub/ui/reading_hidden_books_page.dart';

import 'peer_sync_test.dart' show ReplicaFixture, deviceA;
import 'video_player_tools_widget_test.dart' show ready;

Future<(ReplicaFixture, AssetStore, LocalAsset, File)> prepare() async {
  final fixture = ReplicaFixture(deviceA);
  await fixture.open();
  final assets = AssetStore(
    fixture.store.repository,
    Directory(p.join(fixture.base.path, 'managed')),
  );
  final file = await File(p.join(fixture.root.path, 'archived.txt'))
      .writeAsString('An archived book.');
  await File(p.join(fixture.root.path, 'live.txt'))
      .writeAsString('Another book stays readable.');
  await ReadingRoots(assets)
      .connect(await scanAudioFolder(fixture.root.path, books: true));
  final book = (await assets.list()).firstWhere(
    (a) => a.filename == 'archived.txt',
  );
  return (fixture, assets, book, file);
}

void main() {
  test('permanent file deletion archives the card and reconnect restores the same identity and history', () async {
    final (f, assets, book, file) = await prepare();
    addTearDown(f.close);
    final repo = f.store.repository;
    final record = (await repo.record(book.bookId))!;
    await repo.put('book', book.bookId, {
      ...record.payload!,
      'status': 'active',
    });
    await repo.setMeta('reader:${book.hash}', 'position');
    await repo.setMeta('reading-note:archive-test', 'saved note');
    await ReadingBookActions(assets).deleteForever(book.bookId);
    expect(await file.exists(), false);
    expect(await ReadingBookVisibility(repo).deletedIds(), {book.bookId});
    expect((await repo.record(book.bookId))!.deleted, false);
    expect((await repo.record(book.bookId))!.payload!['status'], 'active');
    expect(await File(p.join(f.root.path, 'live.txt')).exists(), true);
    await file.writeAsString('An archived book.');
    await ReadingRoots(assets)
        .connect(await scanAudioFolder(f.root.path, books: true));
    expect(await ReadingBookVisibility(repo).deletedIds(), isEmpty);
    expect(await repo.records('book'), hasLength(2));
    expect(await repo.meta('reading-library-hidden:${book.bookId}'), '0');
    expect(await repo.meta('reader:${book.hash}'), 'position');
    expect(await repo.meta('reading-note:archive-test'), 'saved note');
  });

  test('folder refresh archives a missing source; explicit reimport restores it without a duplicate', () async {
    final (f, assets, book, file) = await prepare();
    addTearDown(f.close);
    final repo = f.store.repository;
    await repo.setMeta('reader:${book.hash}', 'position');
    await file.delete();
    await ReadingRoots(assets)
        .connect(await scanAudioFolder(f.root.path, books: true));
    expect(await ReadingBookVisibility(repo).deletedIds(), {book.bookId});
    final replacement = await File(p.join(f.base.path, 'returned.txt'))
        .writeAsString('An archived book.');
    final restored = await assets.importBook(
      FolderAudioFile(replacement.path, 'returned.txt'),
    );
    expect(restored.bookId, book.bookId);
    expect(await ReadingBookVisibility(repo).deletedIds(), isEmpty);
    expect(await repo.records('book'), hasLength(2));
    expect(await repo.meta('reader:${book.hash}'), 'position');
  });

  test('a book enters deleted only after its last connected folder copy disappears', () async {
    final (f, assets, book, first) = await prepare();
    addTearDown(f.close);
    final roots = ReadingRoots(assets),
        state = ReadingBookVisibility(f.store.repository);
    final other = await Directory(p.join(f.base.path, 'second-source'))
        .create();
    final second = await File(p.join(other.path, 'same-book.txt'))
        .writeAsString('An archived book.');
    await roots.connect(await scanAudioFolder(other.path, books: true));
    await first.delete();
    await roots.connect(await scanAudioFolder(f.root.path, books: true));
    expect(await state.deletedIds(), isEmpty);
    await second.delete();
    await roots.connect(await scanAudioFolder(other.path, books: true));
    expect(await state.deletedIds(), {book.bookId});
    await first.writeAsString('An archived book.');
    await roots.connect(await scanAudioFolder(f.root.path, books: true));
    expect(await state.deletedIds(), isEmpty);
    expect(await f.store.repository.records('book'), hasLength(2));
  });

  test('disconnect and manual hiding do not mean deleted; a failed scan cannot change availability', () async {
    final (f, assets, book, file) = await prepare();
    addTearDown(f.close);
    final roots = ReadingRoots(assets),
        state = ReadingBookVisibility(f.store.repository);
    await ReadingBookActions(assets).hide(book.bookId);
    expect(await state.deletedIds(), isEmpty);
    await roots.disconnect((await roots.list()).single);
    expect(await state.deletedIds(), isEmpty);
    expect(await file.exists(), true);
    await roots.connect(await scanAudioFolder(f.root.path, books: true));
    expect(
      await f.store.repository.meta('reading-library-hidden:${book.bookId}'),
      '1',
    );
    await expectLater(
      () async => roots.connect(
        await scanAudioFolder(p.join(f.base.path, 'offline'), books: true),
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(await state.deletedIds(), isEmpty);
  });

  for (final size in [const Size(360, 800), const Size(1440, 1000)]) {
    testWidgets(
      'deleted category keeps history cards separate and offers import at $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = size.width < 900
            ? 1.5
            : 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final prepared = await tester.runAsync(prepare);
        final (f, assets, book, _) = prepared!;
        addTearDown(() => tester.runAsync(f.close));
        await tester.runAsync(() async {
          for (final asset in await assets.list()) {
            await ReadingLibrary(f.store.repository).index(assets, asset);
          }
          await ReadingBookActions(assets).deleteForever(book.bookId);
          await f.store.repository.setMeta('library-section', 'reading');
        });
        await tester.pumpWidget(
          PepeHubApp(repository: f.store.repository, assets: assets),
        );
        await tester.pumpAndSettle();
        final all = find.byKey(const ValueKey('status-tab:all'));
        expect(
          find.descendant(of: all, matching: find.text('1')),
          findsOneWidget,
        );
        expect(find.byKey(ValueKey('book-card:${book.bookId}')), findsNothing);
        final deleted = find.byKey(const ValueKey('status-tab:deleted'));
        await tester.ensureVisible(deleted);
        await tester.tap(deleted);
        await tester.pumpAndSettle();
        final card = find.byKey(ValueKey('book-card:${book.bookId}'));
        await tester.scrollUntilVisible(
          card,
          180,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('Файл удалён'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(card);
        await tester.pumpAndSettle();
        expect(find.text('Файл книги удалён'), findsOneWidget);
        expect(find.text('Добавить файл'), findsOneWidget);
        await tester.tap(find.text('Закрыть'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Действия с книгой').first);
        await tester.pumpAndSettle();
        expect(find.text('Добавить файл заново'), findsOneWidget);
        expect(find.text('Удалить навсегда…'), findsNothing);
        if (find.text('Карточка книги').evaluate().isEmpty) {
          await tester.tap(find.text('Книга и коллекции'));
          await tester.pumpAndSettle();
        }
        await tester.ensureVisible(find.text('Карточка книги'));
        await tester.tap(find.text('Карточка книги'));
        await tester.pump();
        await ready(
          tester,
          () => find.text('Сохранить карточку').evaluate().isNotEmpty,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(
          MaterialApp(home: ReadingHiddenBooksPage(assets: assets)),
        );
        await tester.pumpAndSettle();
        expect(find.text('Убранных книг нет'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
}
