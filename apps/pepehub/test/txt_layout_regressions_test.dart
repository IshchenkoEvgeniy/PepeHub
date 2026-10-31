import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/reader/epub.dart';
import 'package:pepehub/reader/reader_layout.dart';
import 'package:pepehub/reader/reader_rebase.dart';
import 'package:pepehub/reader/reading_library.dart';
import 'package:pepehub/reader/text_book.dart';
import 'package:pepehub/sync/peer/app_sync_presentation.dart';

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'hard-wrapped TXT keeps paragraphs and ignores headings inside them',
    () {
      for (final indent in ['', '  ']) {
        final paragraph = [
          '${indent}A paragraph starts here.',
          for (var i = 0; i < 12; i++) 'A hard-wrapped continuation line $i.',
          'Chapter 2',
          for (var i = 0; i < 12; i++) 'Another continuation line $i.',
        ].join('\n');
        final source = '$paragraph\n\n$paragraph';
        final old = ReaderDocument(
          parseTextBook(bytes(source), 'book.txt', layout: 5),
        );
        final next = ReaderDocument(parseTextBook(bytes(source), 'book.txt'));
        expect(next.book.chapters, hasLength(1));
        expect(next.book.chapters.single.paragraphs, hasLength(2));
        expect(next.book.chapters.single.paragraphSeparator, '\n\n');
        expect(next.texts, old.texts);
      }
    },
  );

  test(
    'single-line TXT context uses exact offsets after hundreds of lines',
    () {
      final source = [
        'Chapter 1',
        for (var i = 0; i < 400; i++) '  Paragraph $i with some text.',
        '  TARGET quote at the saved position.',
      ].join('\n');
      final chapter = parseTextBook(bytes(source), 'book.txt').chapters.single;
      expect(chapter.paragraphSeparator, '\n');
      expect(chapter.text, source);
      final context = readerPositionContext(
        chapter.text,
        source.indexOf('TARGET'),
      );
      expect(context, contains('TARGET quote'));
      expect(context, isNot(contains('Paragraph 390')));
    },
  );

  for (final oldSeparator in ['\n', '\n\n']) {
    for (final nextSeparator in ['\n', '\n\n']) {
      test(
        'layout 1 fallback maps $oldSeparator to $nextSeparator exactly',
        () async {
          ReaderDocument document(List<String> paragraphs, String separator) =>
              ReaderDocument(
                EpubBook('Book', [], [
                  EpubChapter(
                    'book',
                    'Book',
                    paragraphs,
                    paragraphSeparator: separator,
                  ),
                ]),
              );
          final before = document([
            'First line',
            'Second line',
            'Last line',
          ], oldSeparator);
          final next = document([
            'Inserted heading',
            'First  line',
            'Second line',
            'Last line',
          ], nextSeparator);
          final start = before.texts.single.indexOf('Second');
          final expected = next.texts.single.indexOf('Second');
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          final library = ReadingLibrary(Repository(db));
          await library.update('reader:book', {
            'chapter': 0,
            'textOffset': start,
          });
          await library.update('reading-note:n', {
            'hash': 'book',
            'chapter': 0,
            'start': start,
            'end': start + 11,
            'quote': 'Second line',
            'comment': 'Keep me',
          });
          await migrateReaderLayout(library, 'book', next, () async => before);
          expect((await library.value('reader:book'))['textOffset'], expected);
          final note = await library.value('reading-note:n');
          expect(
            next.texts.single.substring(
              note['start'] as int,
              note['end'] as int,
            ),
            'Second line',
          );
          expect(note['comment'], 'Keep me');
        },
      );
    }
  }

  for (final layout in [1, 5, 6]) {
    test(
      'background TXT index refresh rebases layout $layout without opening the reader',
      () async {
        final dir = await Directory.systemTemp.createTemp('txt-index-');
        final db = AppDatabase(NativeDatabase.memory());
        try {
          final repo = Repository(db), library = ReadingLibrary(repo);
          final store = AssetStore(repo, Directory('${dir.path}/assets'));
          const source =
              'Title\nChapter 1\n  First paragraph.\n  Second paragraph.\nChapter 2\n  Last paragraph.';
          final file = await File('${dir.path}/book.txt').writeAsString(source);
          final asset = await store.importBook(XFile(file.path));
          final before = ReaderDocument(
            parseTextBook(
              bytes(source),
              'book.txt',
              layout: layout == 1 ? 2 : layout,
              legacyProjection: layout == 1,
            ),
          );
          final after = ReaderDocument(
            parseTextBook(bytes(source), 'book.txt'),
          );
          var chapter = before.texts.indexWhere(
            (t) => t.contains('Last paragraph'),
          );
          final offset = before.texts[chapter].indexOf('Last paragraph');
          await library.update('reading-index:${asset.hash}', {
            'metadataVersion': 2,
            'starts': before.starts,
            'length': before.length,
            'cover': 'existing-cover.png',
            'chapters': [for (final c in before.book.chapters) c.title],
          });
          if (layout != 1) {
            await repo.setMeta(
              'reader-layout-version:${asset.hash}',
              '$layout',
            );
          }
          await library.update('reader:${asset.hash}', {
            'chapter': chapter,
            'textOffset': offset,
          });
          await library.update('reader-bookmark:${asset.hash}:b', {
            'chapter': chapter,
            'offset': offset,
          });
          await library.update('reading-note:n', {
            'hash': asset.hash,
            'chapter': chapter,
            'start': offset,
            'end': offset + 14,
            'quote': 'Last paragraph',
            'comment': 'Saved comment',
          });
          await library.update('reading-book:${asset.bookId}', {
            'favorite': true,
          });
          await library.update('reading-session:s', {
            'bookId': asset.bookId,
            'seconds': 123,
          });
          await library.index(store, asset, retry: true);
          final index = await library.shelfInfo(asset.hash);
          expect(index['starts'], after.starts);
          expect(index['layoutVersion'], currentBookLayout);
          expect(index['cover'], 'existing-cover.png');
          expect(index, isNot(contains('paragraphStarts')));
          final position = await library.value('reader:${asset.hash}');
          final note = await library.value('reading-note:n');
          chapter = position['chapter'] as int;
          expect(
            after.texts[chapter].substring(position['textOffset'] as int),
            startsWith('Last paragraph'),
          );
          expect(
            after.texts[note['chapter'] as int].substring(
              note['start'] as int,
              note['end'] as int,
            ),
            'Last paragraph',
          );
          final bookmark = await library.value(
            'reader-bookmark:${asset.hash}:b',
          );
          expect(bookmark['chapter'], chapter);
          expect(bookmark['offset'], position['textOffset']);
          expect(note['comment'], 'Saved comment');
          expect(
            (await library.value('reading-book:${asset.bookId}'))['favorite'],
            true,
          );
          expect((await library.value('reading-session:s'))['seconds'], 123);
          // An up-to-date index must not reread the source on the next shelf load.
          await File(asset.path).delete();
          await library.index(store, asset);
          expect((await library.shelfInfo(asset.hash))['error'], isNull);
        } finally {
          await db.close();
          await dir.delete(recursive: true);
        }
      },
    );
  }
}
