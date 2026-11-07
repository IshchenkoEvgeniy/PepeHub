import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/audio/audio_folder.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/reader/reading_roots.dart';
import 'package:pepehub/ui/reading_roots_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('book counts and folder summary read naturally', () {
    expect(bookCount(1), '1 книга');
    expect(bookCount(3), '3 книги');
    expect(bookCount(12), '12 книг');
    expect(bookCount(21), '21 книга');
    expect(bookCount(114), '114 книг');
    final now = DateTime(2026, 11, 7, 12);
    final root = ReadingRoot('k', '/books', 'Книги', [
      'a',
      'b',
      'c',
    ], lastScan: DateTime(2026, 11, 6, 20));
    expect(
      readingRootSummary(root, {'pdf': 1, 'epub': 2}, now),
      '3 книги · EPUB 2, PDF 1 · проверено вчера',
    );
    expect(
      readingRootSummary(ReadingRoot('k', '/b', 'B', []), const {}, now),
      '0 книг · ещё не проверялась',
    );
  });

  test('Android folder paths are readable', () {
    expect(
      readableFolderPath(
        'content://com.android.externalstorage.documents/tree/primary%3ADownload%2FBooks',
      ),
      'Память телефона / Download / Books',
    );
    expect(
      readableFolderPath(
        'content://com.android.externalstorage.documents/tree/1A2B-3C4D%3A%D0%9A%D0%BD%D0%B8%D0%B3%D0%B8',
      ),
      'Карта 1A2B-3C4D / Книги',
    );
    expect(readableFolderPath('C:/Books'), 'C:/Books');
    // An unexpected URI is shown as is rather than failing.
    expect(
      readableFolderPath('content://x/tree/%E0%A4'),
      'content://x/tree/%E0%A4',
    );
  });

  group('scan progress', () {
    late Directory dir;
    late AppDatabase db;
    late AssetStore assets;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('reading-scan-');
      db = AppDatabase(NativeDatabase.memory());
      assets = AssetStore(Repository(db), Directory('${dir.path}/managed'));
      final books = await Directory('${dir.path}/books').create();
      for (var i = 0; i < 25; i++) {
        await File('${books.path}/book-$i.txt').writeAsString('Книга $i');
      }
    });
    tearDown(() async {
      await db.close();
      await dir.delete(recursive: true);
    });

    test('reports every checked file', () async {
      final progress = ReadingScanProgress('Проверка');
      final seen = <int>[];
      progress.addListener(() => seen.add(progress.done));
      final root = await ReadingRoots(assets).connect(
        await scanAudioFolder('${dir.path}/books', books: true),
        progress: progress,
      );
      expect(root.bookIds, hasLength(25));
      expect(progress.total, 25);
      expect(progress.done, 25);
      expect(progress.cancellable, isFalse);
      expect(seen, containsAllInOrder([0, 10, 20, 24, 25]));
    });

    test('cancel leaves the library untouched', () async {
      final progress = ReadingScanProgress('Проверка');
      progress.addListener(() {
        if (progress.done >= 10) progress.cancel();
      });
      await expectLater(
        ReadingRoots(assets).connect(
          await scanAudioFolder('${dir.path}/books', books: true),
          progress: progress,
        ),
        throwsA(isA<ReadingScanCancelled>()),
      );
      expect(await ReadingRoots(assets).list(), isEmpty);
      expect(await assets.repository.records('book'), isEmpty);
    });
  });

  testWidgets('empty state explains folders; a folder opens the shelf', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('reading-roots-page-'),
    ))!;
    final db = AppDatabase(NativeDatabase.memory());
    final assets = AssetStore(Repository(db), Directory('${dir.path}/m'));
    String? picked = 'nothing';
    Future<void> open() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => picked = await Navigator.push<String>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ReadingRootsPage(assets: assets),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }

    await open();
    expect(find.byKey(const ValueKey('reading-roots-empty')), findsOneWidget);
    expect(find.text('Подключите папку с книгами'), findsOneWidget);
    expect(find.text('Папка добавленных книг'), findsOneWidget);

    final root = (await tester.runAsync(() async {
      final books = await Directory('${dir.path}/books').create();
      await File('${books.path}/one.txt').writeAsString('one');
      await File('${books.path}/two.epub').writeAsBytes([1, 2, 3]);
      return ReadingRoots(assets)
          .connect(await scanAudioFolder(books.path, books: true));
    }))!;
    await tester.pumpWidget(const SizedBox());
    await open();
    expect(find.byKey(const ValueKey('reading-roots-empty')), findsNothing);
    expect(
      find.text('2 книги · EPUB 1, TXT 1 · проверено сегодня'),
      findsOneWidget,
    );
    await tester.tap(find.text('books'));
    await tester.pumpAndSettle();
    expect(picked, root.key);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await db.close();
      await dir.delete(recursive: true);
    });
  });
}
