import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/reader/epub.dart';
import 'package:pepehub/reader/text_book.dart';
import 'package:pepehub/reader/reading_library.dart';
import 'package:pepehub/reader/reading_notes_page.dart';
import 'package:pepehub/reader/reader_page.dart';
import 'package:pepehub/reader/reading_collections.dart';
import 'package:pepehub/ui/library_page.dart';

const pixel =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=';
Uint8List epub() {
  final archive = Archive();
  final files = {
    'mimetype': 'application/epub+zip',
    'META-INF/container.xml': '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>',
    'OPS/book.opf': '<package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>Морская книга</dc:title><dc:creator>Анна</dc:creator><meta property="belongs-to-collection" id="series">Острова</meta><meta property="group-position" refines="#series">2</meta></metadata><manifest><item id="text" href="text.xhtml" media-type="application/xhtml+xml"/><item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/></manifest><spine><itemref idref="text"/></spine></package>',
    'OPS/text.xhtml': '<html><body><h1>Прибытие</h1><p>Море и остров.</p><p>Море и остров.</p></body></html>',
  };
  for (final entry in files.entries) {
    archive.add(ArchiveFile.bytes(entry.key, utf8.encode(entry.value)));
  }
  archive.add(ArchiveFile.bytes('OPS/cover.png', base64Decode(pixel)));
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  test('EPUB3 and FB2 extract actual artwork and series without changing text', () {
    final book = parseEpub(epub());
    expect(book.title, 'Морская книга');
    expect(book.authors, ['Анна']);
    expect(book.series, 'Острова');
    expect(book.seriesNumber, '2');
    expect(book.cover, base64Decode(pixel));
    final fb = parseTextBook(
      Uint8List.fromList(
        utf8.encode(
          '<FictionBook xmlns:l="http://www.w3.org/1999/xlink"><description><title-info><book-title>Книга</book-title><author><first-name>Иван</first-name><last-name>Петров</last-name></author><sequence name="Серия" number="3"/><coverpage><image l:href="#cover"/></coverpage></title-info></description><body><section><p>Текст</p></section></body><binary id="cover" content-type="image/png">$pixel</binary></FictionBook>',
        ),
      ),
      'test.fb2',
    );
    expect(fb.series, 'Серия');
    expect(fb.seriesNumber, '3');
    expect(fb.authors, ['Иван Петров']);
    expect(fb.cover, base64Decode(pixel));
  });

  test('index preserves existing progress and notes through file relocation and retries', () async {
    final dir = await Directory.systemTemp.createTemp('reading-index-');
    final db = AppDatabase(NativeDatabase.memory());
    try {
      final repo = Repository(db), lib = ReadingLibrary(Repository(db));
      final source = File('${dir.path}/book.epub');
      await source.writeAsBytes(epub());
      final store = AssetStore(repo, Directory('${dir.path}/assets'));
      final asset = await store.importBook(XFile(source.path));
      await repo.setMeta(
        'reader:${asset.hash}',
        jsonEncode({'chapter': 0, 'paragraph': 2}),
      );
      await lib.index(store, asset);
      final index = await lib.value('reading-index:${asset.hash}');
      expect(index['series'], 'Острова');
      expect(
        await File(index['cover'] as String).readAsBytes(),
        base64Decode(pixel),
      );
      expect(
        readingFraction(index, await lib.value('reader:${asset.hash}')),
        greaterThan(.5),
      );
      await lib.update('reading-book:${asset.bookId}', {
        'favorite': true,
        'collections': ['one'],
      });
      await lib.update('reading-book:${asset.bookId}', {'favorite': false});
      expect((await lib.value('reading-book:${asset.bookId}'))['collections'], [
        'one',
      ]);
      await lib.index(store, asset, retry: true);
      expect((await lib.value('reader:${asset.hash}'))['paragraph'], 2);
      final moved = await File(asset.path).rename('${dir.path}/moved.epub');
      await lib.index(
        store,
        LocalAsset(
          id: asset.id,
          bookId: asset.bookId,
          filename: asset.filename,
          path: moved.path,
          hash: asset.hash,
          bytes: asset.bytes,
        ),
        retry: true,
      );
      expect(
        (await lib.value('reading-index:${asset.hash}'))['title'],
        'Морская книга',
      );
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  testWidgets(
    'save exact repeated selection, edit/search notes and jump after reopen',
    (tester) async {
      tester.view.physicalSize = const Size(430, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory dir;
      late AppDatabase db;
      late Repository repo;
      late LocalAsset asset;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('reading-notes-');
        db = AppDatabase(NativeDatabase.memory());
        repo = Repository(db);
        final file = File('${dir.path}/book.txt');
        await file.writeAsString('Повтор. Повтор. Остров и море.');
        asset = await AssetStore(
          repo,
          Directory('${dir.path}/assets'),
        ).importBook(XFile(file.path));
      });
      Future<void> settle() async {
        for (var i = 0; i < 6; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 60)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            home: ReaderPage(repository: repo, asset: asset),
          ),
        );
        await settle();
        await tester.longPress(find.byType(SelectableText).first);
        await tester.pumpAndSettle();
        final editable = tester.state<EditableTextState>(
          find.byType(EditableText).first,
        );
        editable.userUpdateTextEditingValue(
          const TextEditingValue(
            text: 'Повтор. Повтор. Остров и море.',
            selection: TextSelection(baseOffset: 8, extentOffset: 14),
          ),
          SelectionChangedCause.longPress,
        );
        await tester.pump();
        editable.showToolbar();
        await tester.pumpAndSettle();
        await tester.tap(find.text('Заметка'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Комментарий'),
          'Персонаж капитан',
        );
        await tester.tap(find.text('Сохранить'));
        await settle();
        final notes = (await tester.runAsync(
          () => ReadingLibrary(repo).notes(hash: asset.hash),
        ))!;
        expect(notes, hasLength(1));
        expect(notes.single.start, 8);
        expect(notes.single.quote, 'Повтор');
        await tester.tap(find.byTooltip('Заметки книги'));
        await settle();
        await tester.enterText(find.byType(TextField), 'капитан');
        await tester.pumpAndSettle();
        expect(find.text('Повтор'), findsOneWidget);
        await tester.tap(find.text('Повтор'));
        await settle();
        final pos = (await tester.runAsync(
          () => ReadingLibrary(repo).value('reader:${asset.hash}'),
        ))!;
        expect(pos['textOffset'], 8);
        await tester.pumpWidget(const SizedBox());
        await settle();
        await tester.pumpWidget(
          MaterialApp(
            home: ReaderPage(
              repository: repo,
              asset: asset,
              initialNote: notes.single,
            ),
          ),
        );
        await settle();
        expect(find.byType(SelectableText), findsWidgets);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(
          MaterialApp(
            home: ReadingNotesPage(repository: repo, bookIds: {asset.bookId}),
          ),
        );
        await settle();
        await tester.enterText(find.byType(TextField), 'КАПИТАН');
        await tester.pumpAndSettle();
        expect(find.text('Повтор'), findsOneWidget);
        await tester.tap(find.byTooltip('Действия с заметкой'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Удалить'));
        await settle();
        expect(
          (await tester.runAsync(() => ReadingLibrary(repo).notes()))!,
          isEmpty,
        );
        await tester.tap(find.text('Отменить'));
        await settle();
        expect(
          (await tester.runAsync(() => ReadingLibrary(repo).notes()))!,
          hasLength(1),
        );
        await tester.pumpWidget(const SizedBox());
        await settle();
      } finally {
        await tester.runAsync(() async {
          await db.close();
          await dir.delete(recursive: true);
        });
      }
    },
  );

  testWidgets(
    'library filters favorites and collections independently of audio',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final repo = Repository(db);
      addTearDown(db.close);
      await repo.addBook('Зебра', 'Ян', 'txt');
      await repo.addBook('Альфа', 'Анна', 'epub');
      await repo.addBook('Аудио', '', 'audio');
      final books = await repo.records('book');
      final zebra = books.firstWhere((b) => b.title == 'Зебра');
      await repo.setMeta('library-section', 'reading');
      final lib = ReadingLibrary(repo);
      await lib.update('reading-book:${zebra.id}', {
        'favorite': true,
        'collections': ['travel'],
      });
      await lib.update('reading-collection:travel', {'name': 'Путешествия'});
      await tester.pumpWidget(MaterialApp(home: LibraryPage(repository: repo)));
      await tester.pumpAndSettle();
      expect(find.text('Аудио'), findsNothing);
      expect(find.text('Альфа'), findsOneWidget);
      await tester.tap(find.text('Избранное'));
      await tester.pumpAndSettle();
      expect(find.text('Альфа'), findsNothing);
      expect(find.text('★ Зебра'), findsOneWidget);
      await tester.tap(find.text('Избранное'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Все коллекции').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Путешествия').last);
      await tester.pumpAndSettle();
      expect(find.text('Альфа'), findsNothing);
      expect(find.text('★ Зебра'), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () =>
                    showReadingCollections(context, repo, bookId: zebra.id),
                child: const Text('Открыть'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Открыть'));
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, true);
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(
        (await lib.value('reading-book:${zebra.id}'))['collections'],
        isEmpty,
      );
      expect((await lib.value('reading-book:${zebra.id}'))['favorite'], true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
