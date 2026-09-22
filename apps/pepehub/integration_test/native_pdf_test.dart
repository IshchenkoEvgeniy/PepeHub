import 'dart:io';

import 'package:drift/native.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/reader/pdf_reader_page.dart';

import '../test/support/pdf_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native PDF imports, renders and restores page navigation', (
    tester,
  ) async {
    final root = await Directory.systemTemp.createTemp('pepehub-pdf-');
    final db = AppDatabase(NativeDatabase.memory());
    try {
      final repo = Repository(db), file = File('${root.path}/sample.pdf');
      await file.writeAsBytes(twoPagePdf());
      final store = AssetStore(repo, Directory('${root.path}/managed'));
      final asset = await store.importBook(XFile(file.path));
      expect((await repo.record(asset.bookId))!.payload!['format'], 'pdf');
      expect((await store.importBook(XFile(file.path))).id, asset.id);
      final doc = await PdfDocument.openFile(asset.path);
      try {
        expect(doc.pages.length, 2);
        final rendered = await doc.pages.first.render(width: 400, height: 300);
        expect(rendered, isNotNull);
        expect(rendered!.pixels.length, 400 * 300 * 4);
        expect(rendered.pixels.any((p) => p < 100), isTrue);
        rendered.dispose();
      } finally {
        await doc.dispose();
      }
      await repo.setMeta('pdf:${asset.hash}', '2');
      await tester.pumpWidget(
        MaterialApp(
          home: PdfReaderPage(repository: repo, asset: asset),
        ),
      );
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      for (
        var i = 0;
        i < 50 && find.textContaining('Страница 2 / 2').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      debugPrint(
        'PDF viewer status: ${tester.widgetList<Text>(find.byType(Text)).map((w) => w.data).toList()}',
      );
      expect(find.textContaining('Страница 2 / 2'), findsOneWidget);
      await tester.tap(find.byTooltip('Предыдущая страница'));
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      for (
        var i = 0;
        i < 50 && await repo.meta('pdf:${asset.hash}') != '1';
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(await repo.meta('pdf:${asset.hash}'), '1');
      await tester.pumpWidget(const SizedBox());
      // PDFium closes its native file handle on a background worker after unmount.
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await file.writeAsString('%PDF-1.4\nnot a valid document');
      await expectLater(store.importBook(XFile(file.path)), throwsA(anything));
      expect((await repo.records('book')).length, 1);
    } catch (error, stack) {
      debugPrint('PDF test failure before cleanup: $error\n$stack');
      rethrow;
    } finally {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle(const Duration(milliseconds: 200));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await db.close();
      for (var attempt = 0; ; attempt++) {
        try {
          await root.delete(recursive: true);
          break;
        } on FileSystemException {
          if (attempt == 9) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
    }
  });
}
