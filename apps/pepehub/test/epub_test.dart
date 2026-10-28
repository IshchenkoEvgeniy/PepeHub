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
import 'package:pepehub/reader/reader_page.dart';

Uint8List fixture({Map<String, String> overrides = const {}}) {
  final files = {
    'mimetype': 'application/epub+zip',
    'META-INF/container.xml': '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>',
    'OPS/book.opf': '<package xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>Тестовая книга</dc:title><dc:creator>Автор</dc:creator></metadata><manifest><item id="b" href="second.xhtml" media-type="application/xhtml+xml"/><item id="a" href="first.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="a"/><itemref idref="b"/></spine></package>',
    'OPS/first.xhtml': '<html><head><title>Начало</title></head><body><h1>Первая глава</h1><p>Первый &amp; второй</p><p>Последний абзац</p><script>BAD_SCRIPT</script></body></html>',
    'OPS/second.xhtml':
        '<html><body><h1>Вторая глава</h1><p>Конец</p></body></html>',
    ...overrides,
  };
  final archive = Archive();
  for (final file in files.entries) {
    archive.add(ArchiveFile.bytes(file.key, utf8.encode(file.value)));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  test(
    'EPUB follows spine order, reads metadata and removes executable content',
    () {
      final book = parseEpub(fixture());
      expect(book.title, 'Тестовая книга');
      expect(book.authors, ['Автор']);
      expect(book.chapters.map((c) => c.path), [
        'OPS/first.xhtml',
        'OPS/second.xhtml',
      ]);
      expect(book.chapters.first.paragraphs, [
        'Первая глава',
        'Первый & второй',
        'Последний абзац',
      ]);
    },
  );
  test('EPUB rejects malformed, encrypted, escaping and oversized content', () {
    expect(
      () => parseEpub(Uint8List.fromList([1, 2, 3])),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => parseEpub(
        fixture(overrides: {'META-INF/encryption.xml': '<encryption/>'}),
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => parseEpub(fixture(overrides: {'../outside': 'bad'})),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => parseEpub(
        fixture(overrides: {'OPS/first.xhtml': 'a' * (4 * 1024 * 1024 + 1)}),
      ),
      throwsA(isA<FormatException>()),
    );
  });
  test('EPUB import is atomic, deduplicated and preserves source', () async {
    final root = await Directory.systemTemp.createTemp('pepehub-epub-');
    final db = AppDatabase(NativeDatabase.memory());
    try {
      final repo = Repository(db), file = File('${root.path}/book.epub');
      final original = fixture();
      await file.writeAsBytes(original);
      final store = AssetStore(repo, Directory('${root.path}/assets'));
      final asset = await store.importEpub(XFile(file.path));
      expect((await store.importEpub(XFile(file.path))).id, asset.id);
      expect(await file.readAsBytes(), original);
      expect((await repo.record(asset.bookId))!.payload!['format'], 'epub');
      expect(await repo.pendingCount(), 0);
      await file.writeAsString('not a valid epub file');
      await expectLater(
        store.importEpub(XFile(file.path)),
        throwsA(isA<FormatException>()),
      );
      expect((await repo.records('book')).length, 1);
      expect(
        await store.directory
            .list()
            .where((f) => f.path.endsWith('.part'))
            .length,
        0,
      );
    } finally {
      await db.close();
      await root.delete(recursive: true);
    }
  });
  testWidgets(
    'reader restores exact paragraph and persists navigation and font',
    (tester) async {
      late Directory root;
      late AppDatabase db;
      late Repository repo;
      late LocalAsset asset;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('pepehub-reader-');
        db = AppDatabase(NativeDatabase.memory());
        repo = Repository(db);
        final file = File('${root.path}/book.epub');
        await file.writeAsBytes(fixture());
        asset = await AssetStore(
          repo,
          Directory('${root.path}/assets'),
        ).importEpub(XFile(file.path));
        await repo.setMeta(
          'reader:${asset.hash}',
          jsonEncode({'chapter': 0, 'paragraph': 1, 'fontSize': 24}),
        );
      });
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: ReaderPage(repository: repo, asset: asset),
          ),
        );
        // Loading can perform a second isolate pass for legacy anchor migration.
        for (var i = 0; i < 30; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pump();
          if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
        }
        await tester.pumpAndSettle();
        expect(find.textContaining('Первый & второй'), findsOneWidget);
        await tester.tap(find.byTooltip('Оглавление'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ListTile, 'Вторая глава'));
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pumpAndSettle();
        expect(find.textContaining('Конец'), findsWidgets);
        await tester.tap(find.byTooltip('Оформление чтения'));
        await tester.pumpAndSettle();
        for (var i = 0; i < 2; i++) {
          await tester.tap(find.byTooltip('Увеличить размер текста'));
          await tester.pump();
        }
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Готово'));
        await tester.tap(find.text('Готово'));
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final position = jsonDecode(
            (await repo.meta('reader:${asset.hash}'))!,
          );
          expect(position['chapter'], 1);
          expect(position['paragraph'], 0);
          expect(position['fontSize'], 26.0);
        });
        await tester.tap(find.byTooltip('Вернуться к прежнему месту'));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final position = jsonDecode(
            (await repo.meta('reader:${asset.hash}'))!,
          );
          expect(position['chapter'], 0);
          expect(position['paragraph'], 1);
        });
        await tester.pumpWidget(const SizedBox());
      } finally {
        await tester.runAsync(() async {
          await db.close();
          await root.delete(recursive: true);
        });
      }
    },
  );
}
