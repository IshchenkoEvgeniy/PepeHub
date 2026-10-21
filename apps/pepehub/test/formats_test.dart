import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:enough_convert/enough_convert.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/reader/text_book.dart';

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));
Uint8List zip(Map<String, String> files) {
  final archive = Archive();
  for (final e in files.entries) {
    archive.add(ArchiveFile.bytes(e.key, bytes(e.value)));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

const fb2 =
    '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description><title-info><book-title>Книга</book-title><author><first-name>Анна</first-name><last-name>Волкова</last-name></author></title-info></description><body><section><title><p>Начало</p></title><p>До <emphasis>моря</emphasis></p><section><p>Вложенный текст</p></section><p>После</p></section><section><p>Конец</p></section></body></FictionBook>';

void main() {
  test('FB2 metadata, nested text and ZIP preserve reading order', () {
    for (final input in [
      (bytes(fb2), 'book.fb2'),
      (zip({'book.fb2': fb2}), 'book.fb2.zip'),
    ]) {
      final book = parseTextBook(input.$1, input.$2);
      expect(book.title, 'Книга');
      expect(book.authors, ['Анна Волкова']);
      expect(book.chapters.first.paragraphs, [
        'Начало',
        'До моря',
        'Вложенный текст',
        'После',
      ]);
      expect(book.chapters.last.paragraphs, ['Конец']);
    }
    expect(
      () => parseTextBook(zip({'a.fb2': fb2, 'b.fb2': fb2}), 'books.fb2.zip'),
      throwsFormatException,
    );
  });
  test('TXT supports UTF8, UTF16 and Cyrillic Windows1251', () {
    const text = 'Привет\n\nУкраїна';
    final utf16 = <int>[
      255,
      254,
      for (final c in text.codeUnits) ...[c & 255, c >> 8],
    ];
    for (final input in [
      bytes(text),
      Uint8List.fromList(utf16),
      Uint8List.fromList(const Windows1251Codec().encode(text)),
    ]) {
      expect(parseTextBook(input, 'notes.txt').chapters.single.paragraphs, [
        'Привет',
        'Україна',
      ]);
    }
    expect(
      () => parseTextBook(Uint8List.fromList([0, 1, 2, 3]), 'bad.txt'),
      throwsFormatException,
    );
  });
  test(
    'FB2 respects declared legacy encoding and rejects unknown encodings',
    () {
      final encoded = Uint8List.fromList(
        const Windows1251Codec().encode(
          '<?xml version="1.0" encoding="windows-1251"?>$fb2',
        ),
      );
      expect(parseTextBook(encoded, 'legacy.fb2').title, 'Книга');
      expect(
        () => parseTextBook(
          bytes('<?xml version="1.0" encoding="unknown"?>$fb2'),
          'bad.fb2',
        ),
        throwsFormatException,
      );
    },
  );
  test('HTML and Markdown render text without scripts or remote content', () {
    final html = parseTextBook(
      bytes(
        '<html><head><title>Заголовок</title></head><body><div>До<p>Абзац <b>жирный</b></p>После</div><script>BAD</script><img src="https://example.com/private"/></body></html>',
      ),
      'book.html',
    );
    expect(html.title, 'Заголовок');
    expect(html.chapters.single.paragraphs, ['До', 'Абзац жирный', 'После']);
    final md = parseTextBook(
      bytes('# Глава\n\n**Текст** и [ссылка](https://example.com)'),
      'notes.md',
    );
    expect(md.title, 'Глава');
    expect(md.chapters.single.paragraphs, ['Глава', 'Текст и ссылка']);
  });
  test('RTF extracts Unicode text and ignores formatting destinations', () {
    final book = parseTextBook(
      bytes(
        r'{\rtf1\ansi\ansicpg1251{\fonttbl{\f0 Arial;}}\uc1\u1055?\u1088?\u1080?\u1074?\u1077?\u1090?\par Second {\b paragraph}{\pict secret}{\*\unknown hidden}}',
      ),
      'book.rtf',
    );
    expect(book.chapters.single.paragraphs, ['Привет', 'Second paragraph']);
    expect(
      () => parseTextBook(bytes(r'{\rtf1 broken'), 'bad.rtf'),
      throwsFormatException,
    );
  });
  test(
    'DOCX joins text runs, keeps paragraph and table order, reads metadata',
    () {
      final docx = zip({
        'word/document.xml': '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Первая </w:t></w:r><w:r><w:t>строка</w:t></w:r></w:p><w:tbl><w:tr><w:tc><w:p><w:r><w:t>Ячейка</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:body></w:document>',
        'docProps/core.xml': '<core xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Документ</dc:title><dc:creator>Автор</dc:creator></core>',
      });
      final book = parseTextBook(docx, 'book.docx');
      expect(book.title, 'Документ');
      expect(book.authors, ['Автор']);
      expect(book.chapters.single.paragraphs, ['Первая строка', 'Ячейка']);
      expect(
        () => parseTextBook(zip({'../bad': 'escape'}), 'bad.docx'),
        throwsFormatException,
      );
    },
  );
  test('new book formats and audio containers import into the same durable library', () async {
    final root = await Directory.systemTemp.createTemp('pepehub-formats-');
    final db = AppDatabase(NativeDatabase.memory());
    try {
      final repo = Repository(db),
          store = AssetStore(Repository(db), Directory('${root.path}/assets'));
      for (final entry in {
        'book.fb2': bytes(fb2),
        'notes.txt': bytes('Текст'),
        'notes.md': bytes('# Заголовок'),
        'book.html': bytes('<p>HTML-текст</p>'),
      }.entries) {
        final file = File('${root.path}/${entry.key}');
        await file.writeAsBytes(entry.value);
        final asset = await store.importBook(XFile(file.path));
        expect(
          (await repo.record(asset.bookId))!.payload!['format'],
          entry.key.split('.').last,
        );
        expect(await file.readAsBytes(), entry.value);
      }
      for (final entry in {
        'flac': 'fLaC00000000',
        'ogg': 'OggS00000000',
        'opus': 'OggS11111111',
        'wav': 'RIFF0000WAVE',
        'aac': 'ADTS fixture',
      }.entries) {
        final file = File('${root.path}/audio.${entry.key}');
        await file.writeAsBytes(
          entry.key == 'aac'
              ? [255, 241, ...List<int>.filled(10, 0)]
              : bytes(entry.value),
        );
        final asset = await store.importAudio(XFile(file.path));
        expect((await repo.record(asset.bookId))!.payload!['format'], 'audio');
      }
      expect((await repo.records('book')).length, 9);
      expect(await repo.pendingCount(), 0);
    } finally {
      await db.close();
      await root.delete(recursive: true);
    }
  });
}
