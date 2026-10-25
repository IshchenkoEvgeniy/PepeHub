import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/reader/epub.dart';
import 'package:pepehub/reader/reader_bookmarks.dart';
import 'package:pepehub/reader/reader_layout.dart';
import 'package:pepehub/reader/reader_rebase.dart';
import 'package:pepehub/reader/reading_activity.dart';
import 'package:pepehub/reader/reading_library.dart';
import 'package:pepehub/reader/text_book.dart';

import 'epub_test.dart' show fixture;

const _opf =
    '<package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata>'
    '<dc:title>Книга</dc:title></metadata><manifest>'
    '<item id="a" href="text/a.xhtml" media-type="application/xhtml+xml"/>'
    '<item id="b" href="text/b.xhtml" media-type="application/xhtml+xml"/>'
    '<item id="c" href="text/c.xhtml" media-type="application/xhtml+xml"/>'
    '%NAV%</manifest><spine toc="ncx"><itemref idref="a"/><itemref idref="b"/>'
    '<itemref idref="c"/></spine></package>';

Uint8List _epub({String nav = '', Map<String, String> extra = const {}}) =>
    fixture(
      overrides: {
        'OPS/book.opf': _opf.replaceFirst('%NAV%', nav),
        'OPS/text/a.xhtml': '<html><head><title>Книга</title></head><body><p>Альфа</p></body></html>',
        'OPS/text/b.xhtml': '<html><head><title>Книга</title></head><body><h2>Вторая  \n глава</h2><p>Бета</p></body></html>',
        'OPS/text/c.xhtml': '<html><head><title>Своё имя</title></head><body><p>Гамма</p></body></html>',
        ...extra,
      },
    );

const _fb2 =
    '<FictionBook xmlns:l="http://www.w3.org/1999/xlink"><body>'
    '<title><p>Книга</p></title>'
    '<section><title><p>Часть первая</p></title><epigraph><p>Эпиграф</p></epigraph>'
    '<section><title><p>Глава 1</p><p>Начало</p></title>'
    '<p>Один <a type="note" l:href="#n1">1</a> текст.</p><p>Два.</p></section>'
    '<section><title><p>Глава 2</p></title><p>Три.</p><p>Четыре.</p></section>'
    '</section>'
    '<section><title><p>Часть вторая</p></title><p>Пять.</p></section>'
    '</body><body name="notes"><title><p>Примечания</p></title>'
    '<section id="n1"><title><p>1</p></title><p>Первая сноска</p></section>'
    '<section id="n2"><title><p>2</p></title><p>Вторая сноска</p></section>'
    '<section id="n3"><title><p>3</p></title><p>Третья сноска</p></section>'
    '</body></FictionBook>';

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));

void main() {
  group('EPUB chapter titles', () {
    test('come from nav, ignoring the book title repeated in <title>', () {
      final book = parseEpub(
        _epub(
          nav: '<item id="nav" href="nav.xhtml" properties="nav" media-type="application/xhtml+xml"/>',
          extra: {
            'OPS/nav.xhtml':
                '<html><body><nav epub:type="landmarks"><a href="text/a.xhtml">Не то</a></nav>'
                '<nav epub:type="toc"><ol><li><a href="text/a.xhtml#top">Пролог</a></li>'
                '<li><a href="text/b.xhtml">Глава   первая</a></li></ol></nav></body></html>',
          },
        ),
      );
      expect(book.chapters.map((c) => c.title), [
        'Пролог',
        'Глава первая',
        'Своё имя',
      ]);
    });

    test('come from NCX when there is no nav document', () {
      final book = parseEpub(
        _epub(
          nav: '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
          extra: {
            'OPS/toc.ncx':
                '<ncx><navMap><navPoint><navLabel><text>Первая</text></navLabel>'
                '<content src="text/a.xhtml"/><navPoint><navLabel><text>Вложенная</text>'
                '</navLabel><content src="text/a.xhtml#x"/></navPoint></navPoint>'
                '</navMap></ncx>',
          },
        ),
      );
      expect(book.chapters.map((c) => c.title), [
        'Первая',
        'Вторая глава',
        'Своё имя',
      ]);
    });

    test(
      'fall back to the first heading, never to the repeated book title',
      () {
        final book = parseEpub(_epub());
        expect(book.chapters.map((c) => c.title), [
          'Глава 1',
          'Вторая глава',
          'Своё имя',
        ]);
        // The original fixture: <title>Начало</title> before <h1>Первая глава</h1>.
        expect(parseEpub(fixture()).chapters.first.title, 'Первая глава');
      },
    );

    test('a broken navigation document does not prevent reading', () {
      final book = parseEpub(
        _epub(
          nav: '<item id="nav" href="missing.xhtml" properties="nav" media-type="application/xhtml+xml"/>',
        ),
      );
      expect(book.chapters, hasLength(3));
    });
  });

  group('EPUB compatibility', () {
    Uint8List book({
      String spineExtra = '',
      String manifestExtra = '',
      Map<String, String> files = const {},
    }) => fixture(
      overrides: {
        'OPS/book.opf':
            '<package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata>'
            '<dc:title>Книга</dc:title></metadata><manifest>'
            '<item id="a" href="first.xhtml" media-type="application/xhtml+xml"/>'
            '$manifestExtra</manifest><spine>$spineExtra<itemref idref="a"/>'
            '</spine></package>',
        ...files,
      },
    );

    test('font obfuscation is not DRM, real encryption still is', () {
      String encryption(String algorithm) =>
          '<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" '
          'xmlns:enc="http://www.w3.org/2001/04/xmlenc#"><enc:EncryptedData>'
          '<enc:EncryptionMethod Algorithm="$algorithm"/><enc:CipherData>'
          '<enc:CipherReference URI="OPS/font.otf"/></enc:CipherData>'
          '</enc:EncryptedData></encryption>';
      final fonts = parseEpub(
        book(
          files: {
            'META-INF/encryption.xml': encryption(
              'http://www.idpf.org/2008/embedding',
            ),
          },
        ),
      );
      expect(fonts.chapters.single.paragraphs, contains('Последний абзац'));
      expect(
        () => parseEpub(
          book(
            files: {
              'META-INF/encryption.xml': encryption(
                'http://www.w3.org/2001/04/xmlenc#aes128-cbc',
              ),
            },
          ),
        ),
        throwsFormatException,
      );
    });

    test('image and SVG pages in the reading order do not block the book', () {
      final parsed = parseEpub(
        book(
          manifestExtra:
              '<item id="cover" href="cover.png" media-type="image/png"/>'
              '<item id="svg" href="map.svg" media-type="image/svg+xml"/>'
              '<item id="html" href="extra.html" media-type="text/html"/>'
              '<item id="gone" href="missing.xhtml" media-type="application/xhtml+xml"/>',
          spineExtra:
              '<itemref idref="cover"/><itemref idref="svg"/>'
              '<itemref idref="gone"/><itemref idref="unknown"/>'
              '<itemref idref="html"/>',
          files: {
            'OPS/cover.png': 'PNG',
            'OPS/map.svg': '<svg/>',
            'OPS/extra.html':
                '<html><body><h1>Вставка</h1><p>Обычный HTML</p></body></html>',
          },
        ),
      );
      expect(parsed.chapters.map((c) => c.title), ['Вставка', 'Первая глава']);
      final cover = parsed.chapters.first.illustrations.single;
      expect(utf8.decode(cover.bytes), 'PNG');
      expect(cover.offset, 0);
    });

    test('an invalid UTF-8 byte does not make the book unreadable', () {
      final archive = Archive();
      final source = fixture();
      for (final file in ZipDecoder().decodeBytes(source)) {
        archive.add(
          file.name == 'OPS/first.xhtml'
              ? ArchiveFile.bytes(file.name, [
                  ...utf8.encode('<html><body><p>До '),
                  0xff,
                  ...utf8.encode(' после</p></body></html>'),
                ])
              : ArchiveFile.bytes(file.name, file.content),
        );
      }
      final parsed = parseEpub(
        Uint8List.fromList(ZipEncoder().encode(archive)),
      );
      expect(parsed.chapters.first.paragraphs.first, 'До \uFFFD после');
    });
  });

  group('FB2 chapters', () {
    test('nested sections are chapters and note bodies form one chapter', () {
      final book = parseTextBook(_bytes(_fb2), 'book.fb2');
      expect(book.chapters.map((c) => c.title), [
        'Вступление',
        'Часть первая',
        'Глава 1. Начало',
        'Глава 2',
        'Часть вторая',
        'Примечания',
      ]);
      final notes = book.chapters.last.paragraphs;
      expect(notes, contains('Первая сноска'));
      expect(notes, contains('Третья сноска'));
      final first = book.chapters[2];
      expect(first.footnotes.single.text, contains('Первая сноска'));
      final text = first.paragraphs.join('\n\n');
      expect(
        text.substring(first.footnotes.single.start),
        startsWith('1 текст'),
      );
    });

    test('layout 2 keeps the old chapters for rebasing saved anchors', () {
      final old = parseTextBook(_bytes(_fb2), 'book.fb2', layout: 2);
      expect(
        old.chapters,
        hasLength(7),
      ); // intro, 2 parts, 3 note sections, title
      final current = parseTextBook(_bytes(_fb2), 'book.fb2');
      expect(
        [for (final c in old.chapters) ...c.paragraphs],
        [for (final c in current.chapters) ...c.paragraphs],
      );
    });

    test(
      'saved position, notes, coverage and bookmarks move with the text',
      () async {
        final before = ReaderDocument(
          parseTextBook(_bytes(_fb2), 'book.fb2', layout: 2),
        );
        final after = ReaderDocument(parseTextBook(_bytes(_fb2), 'book.fb2'));
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final repo = Repository(db);
        final library = ReadingLibrary(repo);
        // Old chapter 1 is "Часть первая" with both nested chapters inside.
        final oldText = before.texts[1];
        final at = oldText.indexOf('Четыре');
        final quoteStart = oldText.indexOf('Три');
        await repo.setMeta('reader-layout-version:book', '2');
        await repo.setMeta(
          'reader:book',
          jsonEncode({
            'layoutVersion': 2,
            'chapter': 1,
            'textOffset': at,
            'returnTo': [
              {'chapter': 1, 'offset': quoteStart},
            ],
            'pinnedChapter': {'chapter': 1, 'offset': at},
          }),
        );
        await repo.setMeta(
          'reading-note:n',
          jsonEncode({
            'hash': 'book',
            'chapter': 1,
            'chapterTitle': 'Часть первая',
            'quote': 'Три.',
            'start': quoteStart,
            'end': quoteStart + 4,
          }),
        );
        await repo.setMeta(
          'reading-coverage:book',
          jsonEncode({
            'ranges': [
              [0, before.starts[1] + at],
            ],
          }),
        );
        final bookmark = await ReaderBookmarkStore(
          repo,
          'book',
        ).add(title: 'Здесь', chapter: 1, offset: at);

        await migrateReaderLayout(
          library,
          'book',
          after,
          () async => throw StateError('Layout 1 is not involved'),
          previous: () async => before,
        );

        final chapter = after.book.chapters.indexWhere(
          (c) => c.title == 'Глава 2',
        );
        final position = await library.value('reader:book');
        expect(position['chapter'], chapter);
        expect(
          after.texts[chapter].substring(position['textOffset'] as int),
          startsWith('Четыре'),
        );
        expect((position['returnTo'] as List).single['chapter'], chapter);
        expect((position['pinnedChapter'] as Map)['chapter'], chapter);
        final note = await library.value('reading-note:n');
        expect(note['chapter'], chapter);
        expect(note['chapterTitle'], 'Глава 2');
        expect(
          after.texts[chapter].substring(
            note['start'] as int,
            note['end'] as int,
          ),
          'Три.',
        );
        final covered =
            ((await library.value('reading-coverage:book'))['ranges'] as List)
                    .single
                as List;
        expect(
          covered[1],
          after.starts[chapter] + after.texts[chapter].indexOf('Четыре'),
        );
        final moved = (await ReaderBookmarkStore(repo, 'book').list()).single;
        expect(moved.id, bookmark.id);
        expect(moved.chapter, chapter);
        expect(
          after.texts[chapter].substring(moved.offset),
          startsWith('Четыре'),
        );
        expect(await repo.meta('reader-layout-backup-5:book'), isNotNull);
        expect(await repo.meta('reader-layout-version:book'), '5');

        // Runs once.
        await migrateReaderLayout(
          library,
          'book',
          after,
          () async => throw StateError('Already migrated'),
          previous: () async => throw StateError('Already migrated'),
        );
        expect((await library.value('reader:book'))['chapter'], chapter);
      },
    );
  });

  test('scroll updates inside one gesture count as one reading move', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    var now = DateTime(2026, 10, 25, 12);
    final activity = ReadingActivity(
      Repository(db),
      bookId: 'b',
      hash: 'h',
      length: 100000,
      clock: () => now,
    );
    await activity.start(0, runTimer: false);
    final moves = SettledReadingMoves(
      (at) => activity.move(at),
      delay: const Duration(milliseconds: 20),
    );
    // Read the first screen for 20 s, then one flick reports three updates.
    for (final position in [300, 900, 1500]) {
      now = now.add(
        Duration(seconds: position == 300 ? 20 : 0, milliseconds: 250),
      );
      moves.add(position);
    }
    await Future<void>.delayed(const Duration(milliseconds: 60));
    // Another screen read for 20 s, turned with a tap (animated page).
    now = now.add(const Duration(seconds: 20));
    moves.add(1600);
    now = now.add(const Duration(milliseconds: 180));
    moves.add(3000);
    moves.flush();
    expect(activity.fresh, 3000);
    // Fast flipping still does not count as reading.
    for (var i = 1; i <= 5; i++) {
      now = now.add(const Duration(milliseconds: 600));
      moves.add(3000 + i * 1500);
      moves.flush();
    }
    expect(activity.fresh, 3000);
    await activity.close();
  });
}
