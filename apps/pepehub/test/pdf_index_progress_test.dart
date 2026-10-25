import 'dart:io';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/reader/pdf_reader_page.dart';
import 'package:pepehub/reader/pdf_support.dart';
import 'package:pepehub/reader/reading_library.dart';

import 'support/pdf_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final pdfium = Platform.environment['PEPEHUB_PDFIUM'];
  setUpAll(() {
    if (pdfium != null) {
      Pdfrx.pdfiumModulePath = pdfium;
      Pdfrx.cacheDirectoryPath = Directory.systemTemp.path;
    }
  });
  test('large PDF indexing checkpoints numeric offsets, cancels and resumes the prefix', () async {
    final directory = await Directory.systemTemp.createTemp(
      'pdf-index-progress-',
    );
    final file = File('${directory.path}/large.pdf');
    await file.writeAsBytes(manyPagePdf(140));
    final document = await openLocalPdf(file.path);
    try {
      var stop = false;
      Map<String, dynamic>? saved;
      final first = await pdfStatisticsIndex(
        document,
        cancelled: () => stop,
        onProgress: (value) async {
          saved = value;
          stop = true;
        },
      );
      expect(first, isNull);
      expect(saved!['lengths'], hasLength(32));
      final prefix = (saved!['starts'] as List).toList();
      final checkpoints = <int>[];
      final complete = (await pdfStatisticsIndex(
        document,
        cancelled: () => false,
        partial: saved,
        onProgress: (value) async =>
            checkpoints.add((value['lengths'] as List).length),
      ))!;
      final pageLength =
          (await document.pages.first.loadStructuredText()).fullText.length;
      expect(complete['length'], pageLength * 140);
      expect((complete['starts'] as List).take(32).toList(), prefix);
      expect((complete['starts'] as List).last, pageLength * 139);
      expect(complete['lengths'], hasLength(140));
      expect(checkpoints, [64, 96, 128]);
      // Only integer arrays are retained, not glyphs or the book's text.
      expect(
        (complete['lengths'] as List).every((item) => item is int),
        isTrue,
      );
      expect(complete.containsKey('texts'), isFalse);
    } finally {
      await document.dispose();
      await directory.delete(recursive: true);
    }
  }, skip: pdfium == null);

  testWidgets(
    'a PDF over 100 pages resumes its index and enables character statistics',
    (tester) async {
      late Directory directory;
      late AppDatabase db;
      late Repository repo;
      late LocalAsset asset;
      await tester.runAsync(() async {
        directory = await Directory.systemTemp.createTemp('pdf-viewer-index-');
        final file = File('${directory.path}/large.pdf');
        await file.writeAsBytes(manyPagePdf(140));
        final native = await openLocalPdf(file.path);
        final pageLength =
            (await native.pages.first.loadStructuredText()).fullText.length;
        await native.dispose();
        db = AppDatabase(NativeDatabase.memory());
        repo = Repository(db);
        asset = LocalAsset(
          id: 'pdf',
          bookId: 'pdf',
          filename: 'large.pdf',
          path: file.path,
          hash: 'resumed-pdf-index',
          bytes: await file.length(),
        );
        await repo.setMeta(
          'reading-pdf-index-partial:${asset.hash}',
          jsonEncode({
            'pdfPages': 140,
            'pdfTextIndexVersion': 1,
            'lengths': List.filled(128, pageLength),
          }),
        );
      });
      Future<void> pumpIo() async {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 35)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            home: PdfReaderPage(repository: repo, asset: asset),
          ),
        );
        Map<String, dynamic> index = {};
        var reading = false;
        for (var i = 0; i < 100; i++) {
          await pumpIo();
          if (!reading) {
            reading = true;
            repo.meta('reading-index:${asset.hash}').then((raw) {
              if (raw != null) index = jsonDecode(raw) as Map<String, dynamic>;
              reading = false;
            });
          }
          if ((index['lengths'] as List?)?.length == 140) break;
        }
        expect(index['lengths'], hasLength(140));
        expect(index['length'] as int, greaterThan(0));
        expect(find.byType(PdfViewer), findsOneWidget);
        for (var i = 0; i < 12; i++) {
          await pumpIo();
        }
        final sessionsFuture = ReadingLibrary(repo).entries('reading-session:');
        for (var i = 0; i < 6; i++) {
          await pumpIo();
        }
        final sessions = await sessionsFuture;
        final active = sessions.values
            .where((session) => session['closed'] == false)
            .toList();
        expect(active, hasLength(1));
        expect(active.single['length'], index['length']);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        for (var i = 0; i < 12; i++) {
          await pumpIo();
        }
        await tester.runAsync(() async {
          await db.close();
          await directory.delete(recursive: true);
        });
      }
    },
    skip: pdfium == null,
  );
}
