import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/reader/reader_page.dart';

import 'support/flutter_fonts.dart';

void main() {
  for (final mode in ['pages', 'scroll']) {
    testWidgets(
      '«Ещё» expands the selection actions after a real long press ($mode)',
      (tester) async {
        tester.view.physicalSize = const Size(430, 900);
        tester.view.display.size = const Size(430, 900);
        addTearDown(tester.view.display.resetSize);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        late Directory temp;
        late AppDatabase db;
        late Repository repo;
        late dynamic asset;
        await tester.runAsync(() async {
          temp = await Directory.systemTemp.createTemp('more-');
          db = AppDatabase(NativeDatabase.memory());
          repo = Repository(db);
          await repo.setMeta('reader:appearance', jsonEncode({'mode': mode}));
          final file = File('${temp.path}/book.txt');
          await file.writeAsString(
            List.generate(80, (i) => 'Строка $i: Остров и море.').join('\n\n'),
          );
          asset = await AssetStore(
            repo,
            Directory('${temp.path}/assets'),
          ).importBook(XFile(file.path));
          final font = File('C:/Windows/Fonts/segoeui.ttf');
          if (await font.exists()) {
            await (FontLoader(
              'Roboto',
            )..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
          }
          final icons = File(materialIconsFont);
          if (await icons.exists()) {
            await (FontLoader(
              'MaterialIcons',
            )..addFont(icons.readAsBytes().then(ByteData.sublistView))).load();
          }
        });
        Future<void> settle() async {
          for (var i = 0; i < 8; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 30)),
            );
            await tester.pump(const Duration(milliseconds: 100));
          }
          await tester.pumpAndSettle();
        }

        try {
          await tester.pumpWidget(
            MaterialApp(
              home: ReaderPage(repository: repo, asset: asset),
            ),
          );
          await settle();
          final word = mode == 'pages'
              ? find.byType(SelectableText).hitTestable().first
              : find.textContaining('Остров', findRichText: true).first;
          await tester.longPress(word);
          await tester.pumpAndSettle();
          expect(find.text('Перевести'), findsNothing);
          await tester.tap(find.text('Ещё'));
          await tester.pumpAndSettle();
          expect(find.text('Перевести'), findsOneWidget);
          await tester.tap(find.text('Начать длинную цитату'));
          await tester.pumpAndSettle();
          // The action ran and closed the toolbar.
          expect(find.text('Перевести'), findsNothing);
          await tester.longPress(word);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Ещё'));
          await tester.pumpAndSettle();
          expect(find.text('Закончить здесь'), findsOneWidget);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(() async {
            await db.close();
            await temp.delete(recursive: true);
          });
        }
      },
    );
  }
}
