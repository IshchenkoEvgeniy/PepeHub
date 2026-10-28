import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/reader/reader_appearance.dart';
import 'package:pepehub/reader/reader_layout.dart';
import 'package:pepehub/reader/reader_selection_toolbar.dart';
import 'package:pepehub/reader/pdf_page_tools.dart';
import 'package:pepehub/ui/app_theme.dart';

import 'reader_improvements_test.dart' show size;

void main() {
  for (final screen in [
    const Size(320, 740),
    const Size(844, 390),
    const Size(1200, 900),
  ]) {
    for (final pdf in [false, true]) {
      testWidgets('appearance $screen pdf=$pdf fits and restores on cancel', (
        tester,
      ) async {
        size(tester, screen);
        tester.platformDispatcher.textScaleFactorTestValue = 1.4;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        ReaderPreferences? saved, preview;
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  child: const Text('Открыть'),
                  onPressed: () async {
                    saved = await showReaderAppearance(
                      context,
                      ReaderPreferences(mode: pdf ? 'scroll' : 'seamless'),
                      pdf: pdf,
                      onPreview: (v) => preview = v,
                      pdfPageTools: const Text('Масштаб PDF'),
                      pdfPreview: (_) => const Text('Страница PDF'),
                    );
                  },
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Открыть'));
        await tester.pumpAndSettle();
        for (final tab in [
          if (!pdf) 'Текст',
          'Страница',
          'Цвет',
          'Управление',
        ]) {
          final target = find.byKey(ValueKey('reader-appearance-tab:$tab'));
          await tester.ensureVisible(target);
          await tester.tap(target);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        await tester.ensureVisible(
          find.byKey(const ValueKey('reader-appearance-tab:Цвет')),
        );
        await tester.tap(
          find.byKey(const ValueKey('reader-appearance-tab:Цвет')),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Сепия'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Сепия'));
        await tester.pump(const Duration(milliseconds: 200));
        expect(preview?.palette, 'sepia');
        await tester.tap(find.text('Отменить'));
        await tester.pumpAndSettle();
        expect(saved, isNull);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
    'font stepper, live sample and done save the edited preferences',
    (tester) async {
      size(tester, const Size(390, 844));
      ReaderPreferences? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                child: const Text('Открыть'),
                onPressed: () async {
                  saved = await showReaderAppearance(
                    context,
                    const ReaderPreferences(),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Открыть'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Увеличить размер текста'));
      await tester.pump();
      expect(find.text('23'), findsOneWidget);
      final sample = tester.widget<Text>(
        find.text(
          'Їжак і ґанок. Є вечір.\nТихий вечер у реки.\nA quiet evening.',
        ),
      );
      expect(sample.style?.fontSize, 23);
      await tester.tap(find.text('Готово'));
      await tester.pumpAndSettle();
      expect(saved?.size, 23);
    },
  );

  testWidgets('quick cancel or back cannot reapply a pending live preview', (
    tester,
  ) async {
    size(tester, const Size(390, 844));
    var current = const ReaderPreferences();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              child: const Text('Открыть'),
              onPressed: () async {
                final original = current;
                final saved = await showReaderAppearance(
                  context,
                  original,
                  onPreview: (value) => current = value,
                );
                current = saved ?? original;
              },
            ),
          ),
        ),
      ),
    );
    for (final back in [false, true]) {
      await tester.tap(find.text('Открыть'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Увеличить размер текста'));
      await tester.pump(const Duration(milliseconds: 20));
      if (back) {
        await tester.binding.handlePopRoute();
      } else {
        await tester.tap(find.text('Отменить'));
      }
      await tester.pumpAndSettle();
      expect(current.size, 22);
    }
  });

  testWidgets('compact toolbar opens colors on demand and localizes copy', (
    tester,
  ) async {
    size(tester, const Size(360, 740));
    var copied = 0, highlighted = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Builder(
          builder: (context) => Scaffold(
            body: readerSelectionToolbar(
              context: context,
              width: 360,
              anchors: const TextSelectionToolbarAnchors(
                primaryAnchor: Offset(180, 300),
              ),
              palette: TextButton(
                onPressed: () => highlighted++,
                child: const Text('Синий'),
              ),
              buttonItems: [
                ContextMenuButtonItem(label: 'Выделить', onPressed: () {}),
                ContextMenuButtonItem(label: 'Заметка', onPressed: () {}),
                ContextMenuButtonItem(
                  type: ContextMenuButtonType.copy,
                  onPressed: () => copied++,
                ),
                ContextMenuButtonItem(label: 'Карточка Anki', onPressed: () {}),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.text('Copy'), findsNothing);
    expect(find.text('Синий'), findsNothing);
    await tester.tap(find.text('Выделить'));
    await tester.pumpAndSettle();
    expect(find.text('Синий'), findsOneWidget);
    await tester.tap(find.text('Синий'));
    expect(highlighted, 1);
    await tester.tap(find.text('Копировать'));
    expect(copied, 1);
    expect(tester.getRect(find.byType(Material).last).bottom, lessThan(300));
    expect(tester.takeException(), isNull);
  });

  test('white-margin detection includes images, keeps padding and ignores blank pages', () {
    final pixels = Uint8List(100 * 100 * 4)..fillRange(0, 100 * 100 * 4, 255);
    expect(pdfInkBounds(pixels, 100, 100), isNull);
    for (var y = 20; y < 80; y++) {
      for (var x = 30; x < 70; x++) {
        final i = (y * 100 + x) * 4;
        pixels[i] = 40;
        pixels[i + 1] = 80;
        pixels[i + 2] = 120;
      }
    }
    final bounds = pdfInkBounds(pixels, 100, 100)!;
    expect(bounds.left, closeTo(.28, .001));
    expect(bounds.right, closeTo(.72, .001));
    expect(bounds.top, closeTo(.18, .001));
    expect(bounds.bottom, closeTo(.82, .001));
    expect(pdfInkBounds(Uint8List(0), 100, 100), isNull);
  });

  testWidgets('appearance visual preview', (tester) async {
    size(tester, const Size(390, 844));
    final key = GlobalKey();
    await tester.runAsync(() async {
      await (FontLoader('MaterialIcons')..addFont(
            File(
              '../../.tools/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
      for (final font in {'Onest': 'Onest', 'ReaderLora': 'Lora'}.entries) {
        await (FontLoader(font.key)..addFont(
              File('assets/fonts/${font.value}.ttf')
                  .readAsBytes()
                  .then(ByteData.sublistView),
            ))
            .load();
      }
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.data(Brightness.dark, style: AppStyle.pine),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              child: const Text('Открыть'),
              onPressed: () => showReaderAppearance(
                context,
                const ReaderPreferences(palette: 'dark'),
              ),
            ),
          ),
        ),
        builder: (context, child) => RepaintBoundary(key: key, child: child!),
      ),
    );
    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final image =
          await (key.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final file = File('build/reader-appearance-redesign.png');
      await file.writeAsBytes(data!.buffer.asUint8List());
    });
  });
}
