import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/main.dart';

Future<void> cover(
  WidgetTester tester,
  File file,
  String title,
  Color color,
) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      home: Center(
        child: RepaintBoundary(
          key: key,
          child: Container(
            width: 240,
            height: 350,
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [color, Color.lerp(color, Colors.black, .55)!],
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontFamily: 'TestUi',
                    fontSize: 28,
                    height: 1.3,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                const Spacer(),
                const Icon(Icons.auto_stories, color: Colors.white54, size: 90),
                const SizedBox(height: 30),
                const Text(
                  'PEPEHUB • DEMO',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject() as RenderRepaintBoundary)
            .toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await file.writeAsBytes(bytes!.buffer.asUint8List());
  });
}

void main() {
  testWidgets(
    'cover library fits phone; dark/light choice persists and status filters work',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase(NativeDatabase.memory());
      final repo = Repository(db);
      final temp = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('pepehub-design-'),
      ))!;
      final assets = AssetStore(repo, temp);
      await tester.runAsync(() async {
        final font = File('C:/Windows/Fonts/segoeui.ttf');
        if (await font.exists()) {
          for (final family in [
            'Roboto',
            'Segoe UI',
            '.SF UI Text',
            '.SF UI Display',
          ]) {
            await (FontLoader(
              family,
            )..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
          }
          await (FontLoader(
            'TestUi',
          )..addFont(font.readAsBytes().then(ByteData.sublistView))).load();
        }
        final icon = File(
          '../../.tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        );
        if (await icon.exists()) {
          await (FontLoader(
            'MaterialIcons',
          )..addFont(icon.readAsBytes().then(ByteData.sublistView))).load();
        }
        for (var i = 0; i < 4; i++) {
          const titles = [
            'Дюна — Фрэнк Герберт',
            'Морские истории — сборник рассказов',
            'Таинственный остров',
            'Путешествие к центру Земли',
          ];
          await repo.put('book', 'b$i', {
            'title': titles[i],
            'authors': <String>[],
            'format': 'audio',
            'status': i == 1 ? 'active' : 'planned',
          });
          final file = File('${temp.path}/cover-$i.png');
          await repo.setMeta('audio-cover:b$i', file.path);
          await db.customStatement('INSERT INTO audio_editions VALUES(?,?,1)', [
            'e$i',
            'b$i',
          ]);
          await db.customStatement(
            'INSERT INTO audio_resources VALUES(?,?,?)',
            ['external:t$i', '${temp.path}/book-$i.mp3', 1],
          );
          await db.customStatement(
            'INSERT INTO audio_tracks VALUES(?,?,?,?,?,?)',
            [
              't$i',
              'e$i',
              'external:t$i',
              0,
              'book-$i.mp3',
              (10 + i * 3) * 3600000,
            ],
          );
          await db.customStatement(
            'INSERT INTO audio_progress VALUES(?,?,?,?,?,?)',
            [
              'e$i',
              't$i',
              i == 1 ? 2300000 : 0,
              1,
              1.0,
              '2026-09-16T10:00:00Z',
            ],
          );
        }
        await repo.setMeta('appearance-theme', 'dark');
      });
      for (var i = 0; i < 4; i++) {
        await cover(
          tester,
          File('${temp.path}/cover-$i.png'),
          [
            'ДЮНА',
            'МОРСКИЕ\nИСТОРИИ',
            'ТАИНСТВЕННЫЙ\nОСТРОВ',
            'ПУТЕШЕСТВИЕ',
          ][i],
          [
            const Color(0xff87532a),
            const Color(0xff23535e),
            const Color(0xff384434),
            const Color(0xff473b69),
          ][i],
        );
      }
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: PepeHubApp(repository: repo, assets: assets),
        ),
      );
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        ThemeMode.dark,
      );
      Future<void> capture(String name) async {
        for (var i = 0; i < 10; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          await File('build/$name.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
        });
      }

      await capture('library-dark');
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      await capture('library-drawer');
      await tester.tap(find.text('Аудиокниги').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Начатые'));
      await tester.pumpAndSettle();
      expect(find.text('Дюна — Фрэнк Герберт'), findsNothing);
      expect(find.text('Морские истории — сборник рассказов'), findsOneWidget);
      await tester.tap(find.byTooltip('Тема оформления'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Светлая тема'));
      await tester.pumpAndSettle();
      expect(await repo.meta('appearance-theme'), 'light');
      await tester.tap(find.widgetWithText(ChoiceChip, 'Все').last);
      await tester.pumpAndSettle();
      await capture('library-light');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await db.close();
        await temp.delete(recursive: true);
      });
    },
  );
}
