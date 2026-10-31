import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/ui/app_theme.dart';
import 'package:pepehub/ui/book_action_menu.dart';

void main() {
  for (final width in [360.0, 1280.0]) {
    testWidgets(
      'book actions group, hide and restore across reopening at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final repo = Repository(db);
        final boundary = GlobalKey();
        await tester.runAsync(() async {
          for (final entry in {
            'Onest': 'assets/fonts/Onest.ttf',
            'MaterialIcons': '../../.tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          }.entries) {
            await (FontLoader(entry.key)..addFont(
                  File(entry.value).readAsBytes().then(ByteData.sublistView),
                ))
                .load();
          }
        });
        Future<void> screenshot(String name) async {
          if (width != 360) return;
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            image.dispose();
            final file = File('build/ui-review/$name.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
          });
        }

        String? selected;
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: AppTheme.data(Brightness.dark, style: AppStyle.mono),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(1.3)),
                child: child!,
              ),
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () async {
                      selected = await showBookActionMenu(
                        context: context,
                        repository: repo,
                        title: 'Длинное название книги для проверки переноса',
                        available: {
                          for (final action in bookMenuActions)
                            if (action.id != 'restore-deleted')
                              action.id: action.label,
                        },
                      );
                    },
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          ),
        );
        Future<void> tap(Finder finder) async {
          await tester.ensureVisible(finder);
          await tester.tap(finder);
          await tester.pumpAndSettle();
        }

        await tap(find.text('Open'));
        expect(find.text('Карточка книги'), findsOneWidget);
        expect(find.text('Отметить начатой'), findsNothing);
        await screenshot('book-actions-phone');
        await tap(find.byTooltip('Настроить список действий'));
        await screenshot('book-actions-configure-phone');
        await tap(find.byKey(const ValueKey('book-menu-visible:favorite')));
        expect(
          jsonDecode((await repo.meta(bookMenuHiddenKeyFor()))!),
          contains('favorite'),
        );
        await tap(find.byTooltip('Готово'));
        expect(find.text('В избранное'), findsNothing);
        await tap(find.byTooltip('Закрыть'));
        await tap(find.text('Open'));
        expect(find.text('В избранное'), findsNothing);
        await tap(find.byTooltip('Настроить список действий'));
        await tap(find.byKey(const ValueKey('book-menu-visible:favorite')));
        await tap(find.byTooltip('Готово'));
        expect(find.text('В избранное'), findsOneWidget);
        await tap(find.text('Чтение и прогресс'));
        await tap(find.text('Отметить начатой'));
        expect(selected, 'active');
        expect(find.byType(Dialog), findsNothing);
        // Even with every item hidden, the configuration control remains available.
        await repo.setMeta(
          bookMenuHiddenKeyFor(),
          jsonEncode(bookMenuActions.map((a) => a.id).toList()),
        );
        await tap(find.text('Open'));
        expect(find.textContaining('Все действия скрыты'), findsOneWidget);
        await tap(find.byTooltip('Настроить список действий'));
        await tap(find.text('Показать все функции'));
        expect(jsonDecode((await repo.meta(bookMenuHiddenKeyFor()))!), isEmpty);
        await tap(find.byTooltip('Готово'));
        expect(find.text('Карточка книги'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
