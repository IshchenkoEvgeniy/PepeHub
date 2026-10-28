import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:enough_convert/enough_convert.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/reader/book_formats.dart';
import 'package:pepehub/reader/reader_bookmarks.dart';
import 'package:pepehub/reader/reader_page.dart';
import 'package:pepehub/reader/reader_viewport.dart';
import 'package:pepehub/reader/reading_library.dart';
import 'package:pepehub/reader/text_book.dart';
import 'package:pepehub/ui/app_theme.dart';

import 'reader_annotations_bookmarks_test.dart' show select;
import 'reader_improvements_test.dart' show settle, size;

// Exercise actual files/imports/parsers, rather than supplying a ReaderDocument.
// PDF has a separate native suite in pdf_reader_test.dart.
const _extensions = [
  'epub',
  'fb2',
  'fb2.zip',
  'zip',
  'txt',
  'md',
  'markdown',
  'html',
  'htm',
  'xhtml',
  'docx',
  'rtf',
];
const _needle = 'Контрольный маяк';
final _paragraphs = [
  for (var i = 0; i < 28; i++)
    'Абзац $i. ${'Море 🌊 было спокойным, корабль шёл к острову. ' * 5}'
        '${i == 23 ? _needle : 'Продолжение пути'}.',
];

Uint8List _zip(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.add(ArchiveFile.bytes(entry.key, utf8.encode(entry.value)));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List _fixture(String extension) {
  String escape(String value) => const HtmlEscape().convert(value);
  final html = _paragraphs.map((p) => '<p>${escape(p)}</p>').join();
  final fb2 =
      '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">'
      '<description><title-info><book-title>Матрица форматов</book-title>'
      '</title-info></description><body><section>$html</section></body>'
      '</FictionBook>';
  return switch (extension) {
    'epub' => _zip({
      'mimetype': 'application/epub+zip',
      'META-INF/container.xml':
          '<container><rootfiles>'
          '<rootfile full-path="OPS/book.opf"/></rootfiles></container>',
      'OPS/book.opf':
          '<package><metadata><title>Матрица форматов</title>'
          '</metadata><manifest><item id="text" href="text.xhtml" '
          'media-type="application/xhtml+xml"/></manifest>'
          '<spine><itemref idref="text"/></spine></package>',
      'OPS/text.xhtml': '<html><body>$html</body></html>',
    }),
    'fb2' => Uint8List.fromList(utf8.encode(fb2)),
    'fb2.zip' || 'zip' => _zip({'story.fb2': fb2}),
    'html' || 'htm' || 'xhtml' => Uint8List.fromList(
      utf8.encode(
        '<html><head><title>Матрица форматов</title></head>'
        '<body>$html</body></html>',
      ),
    ),
    'docx' => _zip({
      '[Content_Types].xml':
          '<Types xmlns="http://schemas.openxmlformats.org/'
          'package/2006/content-types"><Override PartName="/word/document.xml" '
          'ContentType="application/vnd.openxmlformats-officedocument.'
          'wordprocessingml.document.main+xml"/></Types>',
      'word/document.xml':
          '<w:document xmlns:w="http://schemas.openxmlformats.org/'
          'wordprocessingml/2006/main"><w:body>'
          '${_paragraphs.map((p) => '<w:p><w:r><w:t>${escape(p)}</w:t></w:r></w:p>').join()}'
          '</w:body></w:document>',
    }),
    'rtf' => Uint8List.fromList(
      utf8.encode(
        '${r'{\rtf1\ansi\uc1 '}'
        '${_paragraphs.map((p) => p.codeUnits.map((c) => c < 128 ? String.fromCharCode(c) : '\\u${c > 32767 ? c - 65536 : c}?').join()).join(r'\par ')}}',
      ),
    ),
    _ => Uint8List.fromList(utf8.encode(_paragraphs.join('\n\n'))),
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'matrix covers every registered text extension and preserves Unicode',
    () {
      expect(_extensions.toSet(), {
        ...bookExtensions.where((extension) => extension != 'pdf'),
        'fb2.zip',
      });
      for (final extension in _extensions) {
        final book = parseTextBook(_fixture(extension), 'story.$extension');
        expect(
          book.chapters.expand((c) => c.paragraphs).toList(),
          _paragraphs,
          reason: extension,
        );
      }
    },
  );

  test('TXT retains Cyrillic in UTF-16 BE, KOI8-R and declared KOI8-U', () {
    const text = 'Море и берег';
    final utf16 = Uint8List.fromList([
      254,
      255,
      for (final unit in text.codeUnits) ...[unit >> 8, unit & 255],
    ]);
    expect(parseTextBook(utf16, 'story.txt').chapters.single.paragraphs, [
      text,
    ]);
    for (final (codec, encoding) in [
      (const Koi8rCodec(), 'koi8-r'),
      (const Koi8uCodec(), 'koi8-u'),
    ]) {
      final html = Uint8List.fromList(
        codec.encode(
          '<html><head><meta charset="$encoding"></head><body>'
          '<p>$text</p></body></html>',
        ),
      );
      expect(parseTextBook(html, 'story.html').chapters.single.paragraphs, [
        text,
      ]);
    }
  });

  test(
    'characterization: imported HTML and Markdown lose adjacent images',
    () async {
      final root = await Directory.systemTemp.createTemp('reader-resources-');
      final db = AppDatabase(NativeDatabase.memory());
      try {
        final assets = AssetStore(
          Repository(db),
          Directory('${root.path}/managed'),
        );
        // Valid one-pixel PNG, entirely synthetic.
        await File('${root.path}/map.png').writeAsBytes(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
          ),
        );
        for (final (extension, content) in [
          ('html', '<p>Море</p><img src="map.png" alt="Карта"/>'),
          ('md', 'Море\n\n![Карта](map.png)'),
        ]) {
          final file = File('${root.path}/story.$extension');
          await file.writeAsString(content);
          final direct = await loadTextBook(file.path, 'story.$extension');
          expect(direct.chapters.single.illustrations, hasLength(1));
          final imported = await assets.importBook(XFile(file.path));
          final copied = await loadTextBook(imported.path, imported.filename);
          // Records the limitation, rather than claiming resource import works.
          expect(copied.chapters.single.illustrations, isEmpty);
          expect(
            copied.chapters.single.paragraphs,
            direct.chapters.single.paragraphs,
          );
          expect(await file.readAsString(), content);
        }
      } finally {
        await db.close();
        await root.delete(recursive: true);
      }
    },
  );

  test('DOCX retains headings, emphasis and embedded images; external images are ignored', () {
    final archive = ZipDecoder().decodeBytes(
      _zip({
        'word/document.xml':
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
            'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
            'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
            '<w:body><w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>'
            '<w:r><w:t>Глава</w:t></w:r></w:p><w:p>'
            '<w:r><w:rPr><w:b/></w:rPr><w:t>Жирный </w:t></w:r>'
            '<w:r><w:rPr><w:i/></w:rPr><w:t>курсив</w:t></w:r>'
            '<w:r><w:drawing><a:blip r:embed="local"/> '
            '<a:blip r:embed="remote"/></w:drawing></w:r>'
            '</w:p></w:body></w:document>',
        'word/_rels/document.xml.rels':
            '<Relationships>'
            '<Relationship Id="local" Target="media/map.png"/>'
            '<Relationship Id="remote" Target="https://example.org/map.png" TargetMode="External"/>'
            '</Relationships>',
      }),
    );
    final image = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
    );
    archive.add(ArchiveFile.bytes('word/media/map.png', image));
    final chapter = parseTextBook(
      Uint8List.fromList(ZipEncoder().encode(archive)),
      'story.docx',
    ).chapters.single;
    final text = chapter.paragraphs.join('\n\n');
    expect(chapter.paragraphs, ['Глава', 'Жирный курсив']);
    expect(chapter.markup.any((m) => m.heading == 1), isTrue);
    expect(
      chapter.markup.any(
        (m) => m.bold && text.substring(m.start, m.end) == 'Жирный ',
      ),
      isTrue,
    );
    expect(
      chapter.markup.any(
        (m) => m.italic && text.substring(m.start, m.end) == 'курсив',
      ),
      isTrue,
    );
    expect(chapter.illustrations.single.bytes, image);
  });

  test(
    'invalid inputs for every text extension leave no book or partial import',
    () async {
      final root = await Directory.systemTemp.createTemp('reader-invalid-');
      final db = AppDatabase(NativeDatabase.memory());
      try {
        final repo = Repository(db);
        final assets = AssetStore(repo, Directory('${root.path}/managed'));
        for (final extension in _extensions) {
          final file = File('${root.path}/bad.$extension');
          await file.writeAsBytes([0, 1, 2, 3]);
          await expectLater(
            assets.importBook(XFile(file.path)),
            throwsA(anything),
            reason: extension,
          );
          expect(await repo.records('book'), isEmpty, reason: extension);
          expect(
            await assets.directory.list().toList(),
            isEmpty,
            reason: extension,
          );
        }
      } finally {
        await db.close();
        await root.delete(recursive: true);
      }
    },
  );

  for (final width in [390.0, 1280.0]) {
    for (final extension in _extensions) {
      testWidgets('$extension on $width: import, navigate, search, annotate, '
          'bookmark, appearance and reopen', (tester) async {
        size(tester, Size(width, 844));
        late Directory root;
        late AppDatabase db;
        late Repository repo;
        late LocalAsset asset;
        late File source;
        final original = _fixture(extension);
        await tester.runAsync(() async {
          for (final font in {
            'Onest': 'Onest',
            // ReaderPage uses Flutter's platform UI font for its own theme.
            // Avoid Ahem's artificial square glyph widths in dropdowns.
            'Roboto': 'Onest',
            'Segoe UI': 'Onest',
            'ReaderLora': 'Lora',
            'Oswald': 'Oswald',
            'CormorantGaramond': 'CormorantGaramond',
          }.entries) {
            await (FontLoader(font.key)..addFont(
                  File('assets/fonts/${font.value}.ttf')
                      .readAsBytes()
                      .then(ByteData.sublistView),
                ))
                .load();
          }
          root = await Directory.systemTemp.createTemp('reader-matrix-');
          db = AppDatabase(NativeDatabase.memory());
          repo = Repository(db);
          await repo.setMeta(
            'reader:appearance',
            jsonEncode({'mode': 'pages'}),
          );
          source = File('${root.path}/story.$extension');
          await source.writeAsBytes(original);
          final assets = AssetStore(repo, Directory('${root.path}/managed'));
          asset = await assets.importBook(XFile(source.path));
          expect((await assets.importBook(XFile(source.path))).id, asset.id);
          expect(
            (await repo.record(asset.bookId))!.payload!['format'],
            bookFormat(source.path),
          );
        });

        Widget reader() => MaterialApp(
          theme: AppTheme.data(Brightness.dark, style: AppStyle.dusk),
          home: ReaderPage(repository: repo, asset: asset),
        );
        Future<Map<String, dynamic>> position() async => (await tester.runAsync(
          () async =>
              jsonDecode((await repo.meta('reader:${asset.hash}'))!)
                  as Map<String, dynamic>,
        ))!;

        try {
          await tester.pumpWidget(reader());
          for (var i = 0; i < 15; i++) {
            await settle(tester);
            if (find.byType(ReaderViewport).evaluate().isNotEmpty) break;
          }
          expect(find.byType(ReaderViewport), findsOneWidget);
          expect(find.byType(PageView), findsOneWidget);
          await tester.tap(find.byTooltip('Следующая страница'));
          await settle(tester);
          final beforeSearch = await position();
          expect(beforeSearch['textOffset'] as int, greaterThan(0));

          await tester.tap(find.byTooltip('Поиск по книге'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), _needle);
          await settle(tester);
          expect(find.text('Совпадений: 1'), findsOneWidget);
          await tester.tap(find.byType(ListTile).first);
          await settle(tester);
          final hit = await position();
          expect(
            hit['textOffset'] as int,
            greaterThan(beforeSearch['textOffset'] as int),
          );
          await tester.tap(find.byTooltip('Вернуться к прежнему месту'));
          await settle(tester);
          expect((await position())['textOffset'], beforeSearch['textOffset']);

          // Persist an actual selection, not a note injected into the database.
          final text = tester.widget<SelectableText>(
            find.byType(SelectableText).hitTestable().first,
          );
          // Native selection handles move by characters, never half an emoji.
          final quote = String.fromCharCodes(
            (text.data ?? text.textSpan!.toPlainText()).runes.take(6),
          );
          await select(tester, 0, quote.length);
          await tester.tap(find.text('Выделить'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Выделить: синий'));
          await settle(tester);
          final notes = (await tester.runAsync(
            () => ReadingLibrary(repo).notes(hash: asset.hash),
          ))!;
          expect(notes.single.quote, quote);
          expect(notes.single.color, 'blue');

          await tester.tap(find.byTooltip('Другие действия'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Закладки'));
          await settle(tester);
          await tester.tap(find.text('Запомнить текущее место'));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byType(TextFormField),
            'Проверка формата',
          );
          await tester.tap(find.text('Сохранить'));
          await settle(tester);
          final bookmark = (await tester.runAsync(
            () => ReaderBookmarkStore(repo, asset.hash).list(),
          ))!.single;
          expect(bookmark.offset, beforeSearch['textOffset']);
          await tester.binding.handlePopRoute();
          await settle(tester);

          await tester.tap(find.byTooltip('Оформление чтения'));
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('reader-appearance-tab:Цвет')),
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('Сепия'));
          await tester.tap(
            find.byKey(const ValueKey('reader-appearance-tab:Цвет')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Сепия'));
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('reader-appearance-tab:Страница')),
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('Без пустых мест'));
          await tester.tap(
            find.byKey(const ValueKey('reader-appearance-tab:Страница')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Без пустых мест'));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('Готово'));
          await tester.tap(find.text('Готово'));
          await settle(tester);
          expect(find.byType(PageView), findsNothing);
          final saved = await position();
          expect(saved['textOffset'], beforeSearch['textOffset']);

          await tester.pumpWidget(const SizedBox());
          await settle(tester);
          await tester.pumpWidget(reader());
          for (var i = 0; i < 15; i++) {
            await settle(tester);
            if (find.byType(ReaderViewport).evaluate().isNotEmpty) break;
          }
          final viewport = tester.widget<ReaderViewport>(
            find.byType(ReaderViewport),
          );
          expect(viewport.preferences!.palette, 'sepia');
          expect(viewport.preferences!.mode, 'compact');
          expect((await position())['textOffset'], saved['textOffset']);
          await tester.runAsync(() async {
            expect(
              (await ReadingLibrary(repo).notes(hash: asset.hash)).single
                  .toJson(),
              notes.single.toJson(),
            );
            expect(
              (await ReaderBookmarkStore(
                repo,
                asset.hash,
              ).list()).single.toJson(),
              bookmark.toJson(),
            );
            expect(await source.readAsBytes(), original);
          });
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await settle(tester);
          await tester.runAsync(() async {
            await db.close();
            await root.delete(recursive: true);
          });
        }
      });
    }
  }
}
