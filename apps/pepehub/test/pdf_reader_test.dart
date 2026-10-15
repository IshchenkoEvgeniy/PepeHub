import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/audio/audio_folder.dart';
import 'package:pepehub/reader/pdf_support.dart';
import 'package:pepehub/reader/pdf_reader_page.dart';
import 'package:pepehub/reader/reader_viewport.dart';
import 'package:pepehub/reader/reading_library.dart';

import 'support/pdf_fixture.dart';

// Reuse an existing native runtime. This suite never builds an application.
final pdfium = Platform.environment['PEPEHUB_PDFIUM'];
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    if (pdfium != null) {
      Pdfrx.pdfiumModulePath = pdfium;
      Pdfrx.cacheDirectoryPath = Directory.systemTemp.path;
    }
  });

  test(
    'PDF page-only progress works before text indexing, including scans',
    () {
      expect(
        readingFraction({'pdfPages': 10}, {'chapter': 4, 'textOffset': 0}),
        .4,
      );
      expect(
        readingFraction({'pdfPages': 10}, {'chapter': 9, 'pdfFinished': true}),
        1,
      );
      expect(readingFraction({'pdfPages': 10}, {}), 0);
    },
  );

  test('PDF first page becomes cover; indexing preserves manual cover and progress', () async {
    final root = await Directory.systemTemp.createTemp('pepehub-pdf-cover-');
    final db = AppDatabase(NativeDatabase.memory());
    try {
      final repo = Repository(db), library = ReadingLibrary(Repository(db));
      final source = File('${root.path}/sample.pdf');
      await source.writeAsBytes(twoPagePdf());
      final store = AssetStore(repo, Directory('${root.path}/assets'));
      final asset = await store.importBook(XFile(source.path));
      await repo.setMeta('pdf:${asset.hash}', '2');
      await library.update('reading-book:${asset.bookId}', {
        'overrides': {'title': 'Моя книга', 'cover': 'manual.png'},
      });
      await library.index(store, asset);
      final index = await library.value('reading-index:${asset.hash}');
      expect(index['error'], isNull);
      expect(index['pdfPages'], 2);
      final bytes = await File(index['cover'] as String).readAsBytes();
      expect(bytes.take(8).toList(), [137, 80, 78, 71, 13, 10, 26, 10]);
      final codec = await ui.instantiateImageCodec(bytes),
          frame = await codec.getNextFrame();
      expect(frame.image.width, 600);
      expect(frame.image.height, 450);
      final pixels = await frame.image.toByteData();
      expect(pixels!.buffer.asUint8List().any((v) => v < 100), isTrue);
      frame.image.dispose();
      codec.dispose();
      expect((await library.value('reader:${asset.hash}'))['chapter'], 1);
      var reads = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        audioFolderChannel,
        (call) async => switch (call.method) {
          'open' => 'pdf-test-handle',
          'read' => reads++ == 0 ? twoPagePdf() : null,
          'close' => null,
          _ => throw MissingPluginException(),
        },
      );
      try {
        await library.index(
          store,
          LocalAsset(
            id: asset.id,
            bookId: asset.bookId,
            filename: asset.filename,
            path: 'content://test/document/book',
            hash: asset.hash,
            bytes: asset.bytes,
          ),
          retry: true,
        );
        expect(
          (await library.value('reading-index:${asset.hash}'))['error'],
          isNull,
        );
        expect(
          await store.directory
              .list()
              .where((f) => f.path.endsWith('.partial'))
              .isEmpty,
          isTrue,
        );
      } finally {
        messenger.setMockMethodCallHandler(audioFolderChannel, null);
      }
      final doc = await openLocalPdf(asset.path);
      try {
        await expectLater(
          pdfReadingDocument(doc, 'Bounded', maxCharacters: 5),
          throwsFormatException,
        );
        await expectLater(
          pdfReadingDocument(doc, 'Cancelled', cancelled: () => true),
          throwsStateError,
        );
        final text = await pdfReadingDocument(doc, 'Test');
        expect(text.texts.length, 2);
        expect(text.texts.first, contains('PepeHub page one'));
        expect(text.texts.last, contains('PepeHub page two'));
        expect(text.starts[1], text.texts.first.length);
        final compact = await pdfStatisticsIndex(doc, cancelled: () => false);
        expect(compact!['length'], text.length);
        expect(compact['starts'], text.starts);
        expect(await pdfStatisticsIndex(doc, cancelled: () => true), isNull);
        await library.update('reading-index:${asset.hash}', pdfTextIndex(text));
      } finally {
        await doc.dispose();
      }
      await library.index(store, asset, retry: true);
      final card = await library.bookInfo(
        (await repo.record(asset.bookId))!,
        asset.hash,
      );
      expect(card['title'], 'Моя книга');
      expect(card['cover'], 'manual.png');
      expect(card['length'], greaterThan(0));
      expect((await library.value('reader:${asset.hash}'))['chapter'], 1);
    } finally {
      await db.close();
      await root.delete(recursive: true);
    }
  }, skip: pdfium == null);

  testWidgets('1500-page PDF is interactive before full statistics indexing', (
    tester,
  ) async {
    late Directory root;
    late AppDatabase db;
    late Repository repo;
    late LocalAsset asset;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('pepehub-large-pdf-');
      db = AppDatabase(NativeDatabase.memory());
      repo = Repository(db);
      final file = File('${root.path}/large.pdf');
      await file.writeAsBytes(manyPagePdf(1500));
      asset = LocalAsset(
        id: 'large',
        bookId: 'large',
        filename: 'large.pdf',
        path: file.path,
        hash: 'large-test',
        bytes: await file.length(),
      );
    });
    Future<void> settle() async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }

    try {
      await tester.pumpWidget(
        MaterialApp(
          home: PdfReaderPage(repository: repo, asset: asset),
        ),
      );
      var interactive = false;
      for (var i = 0; i < 60; i++) {
        await settle();
        final search = find.byWidgetPredicate(
          (w) => w is IconButton && w.tooltip == 'Поиск по книге',
        );
        if (search.evaluate().isNotEmpty &&
            tester.widget<IconButton>(search).onPressed != null) {
          interactive = true;
          break;
        }
      }
      expect(interactive, isTrue);
      expect(find.textContaining('/ 1500'), findsOneWidget);
      await tester.runAsync(() async {
        final index = await ReadingLibrary(repo)
            .value('reading-index:large-test');
        expect(index['pdfPages'], 1500);
        expect(index['starts'], isNull); // viewer did not wait for all text
      });
      await tester.tap(find.byTooltip('Зафиксировать масштаб и горизонталь'));
      for (var i = 0; i < 8; i++) {
        await settle();
      }
      final viewer = tester.widget<PdfViewer>(find.byType(PdfViewer));
      expect(viewer.params.panAxis, PanAxis.vertical);
      expect(viewer.params.scaleEnabled, isFalse);
      expect(viewer.params.layoutPages, isNull);
      await tester.runAsync(() async {
        expect(
          (await ReadingLibrary(repo).value('pdf-view:large-test'))['locked'],
          isTrue,
        );
      });
      await tester.tap(find.byTooltip('Разблокировать масштаб и движение'));
      await settle();
      expect(
        tester.widget<PdfViewer>(find.byType(PdfViewer)).params.scaleEnabled,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 15; i++) {
        await settle();
      }
      await tester.runAsync(() async {
        await db.close();
        await root.delete(recursive: true);
      });
    }
  }, skip: pdfium == null);

  testWidgets(
    'PDF restores position, searches, returns, saves a page note and opens reflow',
    (tester) async {
      late Directory root;
      late AppDatabase db;
      late Repository repo;
      late LocalAsset asset;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('pepehub-pdf-ui-');
        db = AppDatabase(NativeDatabase.memory());
        repo = Repository(db);
        final file = File('${root.path}/book.pdf');
        await file.writeAsBytes(twoPagePdf());
        asset = await AssetStore(
          repo,
          Directory('${root.path}/assets'),
        ).importBook(XFile(file.path));
        await repo.setMeta('pdf:${asset.hash}', '2');
      });
      Future<void> settle() async {
        for (var i = 0; i < 12; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 35)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      Future<void> waitForViewer() async {
        // The saved-page label is available before the asynchronous native
        // viewer is interactive. Do not tap a still-disabled navigation button.
        for (var i = 0; i < 20; i++) {
          await settle();
          final previous = find.byWidgetPredicate(
            (w) => w is IconButton && w.tooltip == 'Предыдущая страница',
          );
          if (previous.evaluate().isNotEmpty &&
              tester.widget<IconButton>(previous).onPressed != null) {
            return;
          }
        }
        fail('PDF viewer did not become interactive');
      }

      Future<void> menu(String title) async {
        await tester.tap(find.byType(PopupMenuButton<String>));
        await settle();
        await tester.tap(find.text(title));
        await settle();
      }

      Future<void> palette(String name) async {
        await menu('Оформление');
        await tester.tap(find.byType(DropdownButtonFormField<String>).first);
        await settle();
        await tester.tap(find.text(name).last);
        await settle();
        await tester.ensureVisible(find.text('Применить'));
        await settle();
        await tester.tap(find.text('Применить'));
        await settle();
      }

      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

      try {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: PdfReaderPage(repository: repo, asset: asset),
          ),
        );
        await waitForViewer();
        expect(find.textContaining('Страница 2 / 2'), findsOneWidget);
        await tester.tap(find.byTooltip('Предыдущая страница'));
        await settle();
        expect(find.textContaining('Страница 1 / 2'), findsOneWidget);
        await tester.tap(find.byTooltip('Поиск по книге'));
        await settle();
        await tester.enterText(find.byType(TextField), 'page two');
        await settle();
        expect(find.text('Совпадений: 1'), findsOneWidget);
        await tester.tap(find.text('Страница 2'));
        await settle();
        expect(find.textContaining('Страница 2 / 2'), findsOneWidget);
        await tester.tap(find.byTooltip('Вернуться на прежнее место'));
        await settle();
        expect(find.textContaining('Страница 1 / 2'), findsOneWidget);
        await menu('Заметка к странице');
        await tester.enterText(
          find.byType(TextField).first,
          'Мысль о первой странице',
        );
        await tester.tap(find.text('Сохранить'));
        await settle();
        await tester.runAsync(() async {
          final notes = await ReadingLibrary(repo).notes(hash: asset.hash);
          expect(notes.single.comment, 'Мысль о первой странице');
          expect(notes.single.chapter, 0);
        });
        final viewer = tester.widget<PdfViewer>(find.byType(PdfViewer));
        expect(
          viewer.params.textSelectionParams!.showContextMenuAutomatically,
          true,
        );
        expect(viewer.params.textSelectionParams!.magnifier!.enabled, false);
        expect(viewer.params.buildContextMenu, isNotNull);
        await tester.runAsync(() async {
          final native = viewer.controller!.document;
          final a = await native.pages[0].loadStructuredText();
          final b = await native.pages[1].loadStructuredText();
          await viewer.controller!.textSelectionDelegate
              .setTextSelectionPointRange(
                PdfTextSelectionRange.fromPoints(
                  PdfTextSelectionPoint(a, 0),
                  PdfTextSelectionPoint(b, 6),
                ),
              );
        });
        await settle();
        final actions = <ContextMenuButtonItem>[];
        viewer.params.customizeContextMenuItems!(
          PdfViewerContextMenuBuilderParams(
            isTextSelectionEnabled: true,
            anchorA: Offset.zero,
            textSelectionDelegate: viewer.controller!.textSelectionDelegate,
            dismissContextMenu: () {},
            contextMenuFor: PdfViewerPart.selectedText,
          ),
          actions,
        );
        expect(actions.single.label, 'Цитата / заметка');
        actions.single.onPressed!();
        await settle();
        await tester.enterText(find.byType(TextField).first, 'Общая цитата');
        await tester.tap(find.text('Сохранить'));
        await settle();
        await tester.runAsync(() async {
          final quotes = (await ReadingLibrary(repo).notes(hash: asset.hash))
              .where((n) => n.quote.isNotEmpty)
              .toList();
          expect(quotes.length, 2);
          expect(quotes.map((n) => n.chapter).toSet(), {0, 1});
          expect(quotes.every((n) => n.comment == 'Общая цитата'), isTrue);
        });
        await menu('Полный экран');
        expect(find.byTooltip('Выйти из полного экрана'), findsOneWidget);
        await tester.tap(find.byTooltip('Выйти из полного экрана'));
        await settle();
        await palette('Системная');
        final filtered = find
            .ancestor(
              of: find.byType(PdfViewer),
              matching: find.byType(ColorFiltered),
            )
            .first;
        final light = tester.widget<ColorFiltered>(filtered).colorFilter;
        expect(
          light,
          const ColorFilter.mode(Colors.transparent, BlendMode.srcOver),
        );
        tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
        await settle();
        expect(
          tester.widget<ColorFiltered>(filtered).colorFilter,
          isNot(light),
        );
        await palette('Сепия');
        await palette('Тёмная (инверсия страниц)');
        await tester.runAsync(() async {
          expect(await repo.meta('reader:appearance'), contains('dark'));
        });
        final beforeHiding = await tester.runAsync(
          () async => [
            for (final note in await ReadingLibrary(
              repo,
            ).notes(hash: asset.hash))
              note.toJson(),
          ],
        );
        await menu('Оформление');
        await tester.tap(find.byType(SwitchListTile));
        await settle();
        await tester.ensureVisible(find.text('Применить'));
        await settle();
        await tester.tap(find.text('Применить'));
        await settle();
        await tester.runAsync(() async {
          expect(
            (await ReadingLibrary(repo)
                .value('reader:appearance'))['showHighlights'],
            isFalse,
          );
          expect([
            for (final note in await ReadingLibrary(
              repo,
            ).notes(hash: asset.hash))
              note.toJson(),
          ], beforeHiding);
        });
        await menu('Текстовый режим');
        expect(
          tester
              .widget<ReaderViewport>(find.byType(ReaderViewport))
              .preferences!
              .showHighlights,
          isFalse,
        );
        expect(find.textContaining('PepeHub page one'), findsWidgets);
        await tester.binding.handlePopRoute();
        await settle();
        expect(find.textContaining('Страница 1 / 2'), findsOneWidget);
        await tester.runAsync(() async {
          final sessions = await ReadingLibrary(repo)
              .entries('reading-session:');
          expect(sessions.values.where((s) => s['closed'] == false).length, 1);
          expect(
            sessions.values.any(
              (s) => (s['events'] as List).any((e) => e['kind'] == 'jump'),
            ),
            isTrue,
          );
        });
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await settle();
        await tester.runAsync(() async {
          await db.close();
          await root.delete(recursive: true);
        });
      }
    },
    skip: pdfium == null,
  );
}
