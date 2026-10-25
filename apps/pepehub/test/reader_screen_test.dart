import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:pepehub/reader/reader_selectable_paragraph.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/reader/reader_page.dart';

void main() {
  testWidgets(
    'reader paginates, searches and returns, scrolls and restores exact anchor',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory temp;
      late AppDatabase db;
      late Repository repo;
      late LocalAsset asset;
      await tester.runAsync(() async {
        temp = await Directory.systemTemp.createTemp('reader-screen-');
        db = AppDatabase(NativeDatabase.memory());
        repo = Repository(db);
        await repo.setMeta('reader:appearance', jsonEncode({'mode': 'pages'}));
        final source = File('${temp.path}/Морские истории.txt');
        await source.writeAsString(
          List.generate(
            60,
            (i) =>
                'Глава путешествия $i. ${'Море было спокойным, и мы продолжали путь к далёкому острову. ' * 7} Конец фрагмента $i.',
          ).join('\n\n'),
        );
        asset = await AssetStore(
          repo,
          Directory('${temp.path}/managed'),
        ).importBook(XFile(source.path));
        for (final font in {
          'ReaderLora': 'Lora',
          'Onest': 'Onest',
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
        final uiFont = File('C:/Windows/Fonts/segoeui.ttf');
        if (await uiFont.exists()) {
          for (final family in ['Roboto', 'Segoe UI']) {
            await (FontLoader(
              family,
            )..addFont(uiFont.readAsBytes().then(ByteData.sublistView))).load();
          }
        }
        final icons = File(
          '../../.tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        );
        if (await icons.exists()) {
          await (FontLoader(
            'MaterialIcons',
          )..addFont(icons.readAsBytes().then(ByteData.sublistView))).load();
        }
      });
      Future<void> settle() async {
        for (var i = 0; i < 12; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pumpAndSettle();
      }

      Future<Map<String, dynamic>> position() async => (await tester.runAsync(
        () async =>
            jsonDecode((await repo.meta('reader:${asset.hash}'))!)
                as Map<String, dynamic>,
      ))!;
      final key = GlobalKey();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: RepaintBoundary(
              key: key,
              child: ReaderPage(repository: repo, asset: asset),
            ),
          ),
        );
        await settle();
        expect(find.byType(PageView), findsOneWidget);
        await tester.tap(find.byTooltip('Следующая страница'));
        await settle();
        final before = await position();
        expect(before['textOffset'] as int, greaterThan(0));
        await tester.tap(find.byTooltip('Поиск по книге'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Конец фрагмента 50');
        await settle();
        expect(find.text('Совпадений: 1'), findsOneWidget);
        await tester.tap(find.byType(ListTile).first);
        await settle();
        expect(
          (await position())['textOffset'] as int,
          greaterThan(before['textOffset'] as int),
        );
        await tester.tap(find.byTooltip('Вернуться к прежнему месту'));
        await settle();
        expect((await position())['textOffset'], before['textOffset']);
        await tester.tap(find.byTooltip('Оформление чтения'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Без пустых мест'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Применить'));
        await tester.tap(find.text('Применить'));
        await settle();
        expect(find.byType(ReaderSelectableParagraph), findsWidgets);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Оформление чтения'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Перелистывание'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Применить'));
        await tester.tap(find.text('Применить'));
        await settle();
        expect(find.byType(PageView), findsOneWidget);
        expect(find.byType(SelectableText), findsWidgets);
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Оформление чтения'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Тёмная'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('По главам'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Применить'));
        await tester.tap(find.text('Применить'));
        await settle();
        expect(find.byType(PageView), findsNothing);
        expect((await position())['textOffset'], before['textOffset']);
        await tester.drag(find.byType(ListView).first, const Offset(0, -350));
        await settle();
        final after = await position();
        expect(
          after['textOffset'] as int,
          greaterThan(before['textOffset'] as int),
        );
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          await File('build/reader-010-dark.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
        });
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await settle();
        await tester.pumpWidget(
          MaterialApp(
            home: ReaderPage(repository: repo, asset: asset),
          ),
        );
        await settle();
        expect(find.byType(PageView), findsNothing);
        expect((await position())['textOffset'], after['textOffset']);
        tester.view.physicalSize = const Size(844, 390);
        await settle();
        expect((await position())['textOffset'], after['textOffset']);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await settle();
        await tester.runAsync(() async {
          await db.close();
          await temp.delete(recursive: true);
        });
      }
    },
  );
}
