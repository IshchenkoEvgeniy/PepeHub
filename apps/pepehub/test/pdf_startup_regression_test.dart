import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/reader/pdf_reader_page.dart';

import 'support/pdf_fixture.dart';
import 'video_player_tools_widget_test.dart' show ready;

class _SlowCheckpointRepository extends Repository {
  final checkpoint = Completer<void>();
  bool savingSession = false;
  _SlowCheckpointRepository(super.db);
  @override
  Future<void> setMeta(String key, String value) async {
    if (key.startsWith('reading-log-error:')) {
      savingSession = true;
      await checkpoint.future;
    }
    await super.setMeta(key, value);
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
    'saved page 1200 renders while the initial journal export is blocked',
    (tester) async {
      late AppDatabase db;
      late _SlowCheckpointRepository repo;
      late Directory root;
      late LocalAsset asset;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('pepe-pdf-startup-');
        db = AppDatabase(NativeDatabase.memory());
        repo = _SlowCheckpointRepository(db);
        final file = File('${root.path}/large.pdf');
        await file.writeAsBytes(manyPagePdf(1500));
        asset = LocalAsset(
          id: 'pdf',
          bookId: 'pdf',
          filename: 'large.pdf',
          path: file.path,
          hash: 'startup',
          bytes: await file.length(),
        );
        await repo.setMeta(
          'reader:startup',
          jsonEncode({'chapter': 1199, 'textOffset': 0}),
        );
        await repo.setMeta(
          'reading-index:startup',
          jsonEncode({
            'pdfPages': 1500,
            'length': 1500,
            'starts': List.generate(1500, (i) => i),
            'lengths': List.filled(1500, 1),
          }),
        );
      });
      dynamic state;
      try {
        final clock = Stopwatch()..start();
        await tester.pumpWidget(
          MaterialApp(
            home: PdfReaderPage(repository: repo, asset: asset),
          ),
        );
        state = tester.state(find.byType(PdfReaderPage));
        await ready(tester, () => state.ready && repo.savingSession);
        clock.stop();
        expect(repo.checkpoint.isCompleted, isFalse);
        expect(state.page, 1200);
        expect(find.textContaining('/ 1500'), findsOneWidget);
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (w) => w is IconButton && w.tooltip == 'Поиск по книге',
                ),
              )
              .onPressed,
          isNotNull,
        );
        debugPrint(
          '1500-page PDF restored page 1200 in ${clock.elapsedMilliseconds} ms with statistics still blocked',
        );
        repo.checkpoint.complete();
        var started = false;
        (state.activityStart as Future).then((_) => started = true);
        await ready(tester, () => started);
        expect(tester.takeException(), isNull);
      } finally {
        if (!repo.checkpoint.isCompleted) repo.checkpoint.complete();
        await tester.pumpWidget(const SizedBox.shrink());
        if (state != null) {
          var drained = false;
          Future.wait<void>([
            state.activityStart as Future<void>,
            state.writes as Future<void>,
          ]).then((_) async {
            await state.activity?.writes;
            drained = true;
          });
          await ready(tester, () => drained);
        }
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await db.close();
          await root.delete(recursive: true);
        });
      }
    },
    skip: pdfium == null,
  );
}
