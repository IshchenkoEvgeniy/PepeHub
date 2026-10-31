import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/reader/pdf_reader_page.dart';
import 'package:pepehub/reader/reading_library.dart';

import 'support/pdf_fixture.dart';
import 'video_player_tools_widget_test.dart' show ready;

class PositionRepository extends Repository {
  String? trackedHash;
  int positions = 0, indexes = 0;
  PositionRepository(super.db);
  @override
  Future<void> setMeta(String key, String value) {
    if (key == 'reader:$trackedHash') positions++;
    if (key == 'reading-index:$trackedHash') indexes++;
    return super.setMeta(key, value);
  }
}

void main() {
  final pdfium = Platform.environment['PEPEHUB_PDFIUM'];
  setUpAll(() {
    if (pdfium != null) {
      Pdfrx.pdfiumModulePath = pdfium;
      Pdfrx.cacheDirectoryPath = Directory.systemTemp.path;
    }
  });
  testWidgets(
    'PDF scroll coalesces positions, flushes on close and leaves an unchanged index alone',
    (tester) async {
      late Directory root;
      late AppDatabase db;
      late PositionRepository repo;
      late LocalAsset asset;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('pepe-pdf-position-');
        db = AppDatabase(NativeDatabase.memory());
        repo = PositionRepository(db);
        final file = File('${root.path}/source.pdf');
        await file.writeAsBytes(twoPagePdf());
        asset = await AssetStore(
          repo,
          Directory('${root.path}/assets'),
        ).importBook(XFile(file.path));
        await repo.setMeta(
          'reading-index:${asset.hash}',
          jsonEncode({
            'pdfPages': 2,
            'pdfCoverVersion': 1,
            'starts': [0, 17],
            'lengths': [17, 17],
            'length': 34,
          }),
        );
        repo.trackedHash = asset.hash;
      });
      dynamic state;
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: PdfReaderPage(repository: repo, asset: asset),
          ),
        );
        state = tester.state(find.byType(PdfReaderPage));
        await ready(tester, () => state.ready);
        expect(repo.indexes, 0);
        final before = repo.positions;
        final viewer = tester.widget<PdfViewer>(find.byType(PdfViewer));
        for (var i = 0; i < 100; i++) {
          viewer.params.onPageChanged?.call(i.isEven ? 1 : 2);
        }
        expect(repo.positions, before);
        await tester.pump(const Duration(milliseconds: 250));
        expect(repo.positions, before);
        await tester.pump(const Duration(milliseconds: 1000));
        var stored = false;
        (state.writes as Future).then((_) => stored = true);
        await ready(tester, () => stored);
        expect(repo.positions, before + 1);
        await tester.runAsync(() async {
          expect(
            (await ReadingLibrary(repo)
                .value('reader:${asset.hash}'))['chapter'],
            1,
          );
        });
        viewer.params.onPageChanged?.call(1);
        await tester.pumpWidget(const SizedBox.shrink());
        var closed = false;
        Future.wait<void>([
          state.writes as Future<void>,
          state.activity.writes as Future<void>,
        ]).then((_) => closed = true);
        await ready(tester, () => closed);
        await tester.runAsync(() async {
          expect(
            (await ReadingLibrary(repo)
                .value('reader:${asset.hash}'))['chapter'],
            0,
          );
        });
        expect(repo.positions, before + 2);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        if (state != null) {
          var drained = false;
          Future.wait<void>([
            state.writes as Future<void>,
            state.activity.writes as Future<void>,
          ]).then((_) => drained = true);
          await ready(tester, () => drained);
        }
        await tester.runAsync(() async {
          await db.close();
          await root.delete(recursive: true);
        });
      }
    },
    skip: pdfium == null,
  );
}
