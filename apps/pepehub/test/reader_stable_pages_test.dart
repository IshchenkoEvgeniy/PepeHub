import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/reader/epub.dart';
import 'package:pepehub/reader/reader_layout.dart';
import 'package:pepehub/reader/reader_layout_frame.dart';
import 'package:pepehub/reader/reader_page.dart';
import 'package:pepehub/reader/reader_progress_panel.dart';
import 'package:pepehub/reader/reader_selectable_paragraph.dart';
import 'package:pepehub/reader/reader_viewport.dart';

import 'reader_annotations_bookmarks_test.dart' show asset, document;
import 'reader_improvements_test.dart' show settle, size;

void main() {
  for (final mode in ['seamless', 'pages', 'compact', 'scroll']) {
    for (final screen in [const Size(390, 844), const Size(844, 390)]) {
      testWidgets(
        '$mode preserves real page breaks on $screen when Android resizes its view',
        (tester) async {
          final window = screen.width < screen.height
              ? Size(screen.width, screen.height - 48)
              : Size(screen.width - 48, screen.height);
          size(tester, window);
          tester.view.display.size = screen;
          addTearDown(tester.view.display.resetSize);
          final db = AppDatabase(NativeDatabase.memory());
          addTearDown(db.close);
          final repo = Repository(db);
          await repo.setMeta('reader:appearance', jsonEncode({'mode': mode}));
          final longBook = ReaderDocument(
            EpubBook('Book', const [], [
              EpubChapter('chapter', 'Chapter', [
                for (var i = 0; i < 100; i++)
                  'Paragraph $i. ${'Text that spans several lines. ' * 8}',
              ]),
            ]),
          );
          await tester.pumpWidget(
            MaterialApp(
              home: ReaderPage(
                repository: repo,
                asset: asset,
                suppliedDocument: longBook,
              ),
            ),
          );
          await settle(tester);
          final viewport = find.byType(ReaderViewport);
          final frame = find.byType(ReaderLayoutFrame);
          final list = find.descendant(
            of: viewport,
            matching: find.byType(mode == 'pages' ? PageView : ListView),
          );
          await tester.drag(
            list,
            mode == 'pages' ? const Offset(-330, 0) : const Offset(0, -500),
          );
          await settle(tester);
          final state = tester.state(viewport);
          final before = tester.widget<ReaderViewport>(viewport);
          expect(before.width, screen.width);
          expect(before.height, screen.height);
          if (mode == 'pages') {
            final arrows = tester.getRect(find.byTooltip('Следующая страница'));
            expect(arrows.right, lessThanOrEqualTo(window.width));
            expect(arrows.bottom, lessThanOrEqualTo(window.height));
          }
          final position = mode == 'pages'
              ? tester.widget<PageView>(list).controller!.page!
              : tester.widget<ListView>(list).controller!.offset;
          // Unlike padding-only tests, immersive mode changes Flutter's actual
          // physical viewport on Android devices with system navigation bars.
          await tester.tapAt(tester.getCenter(frame));
          await tester.pump();
          tester.view.physicalSize = screen;
          await settle(tester);
          expect(tester.state(viewport), same(state));
          expect(tester.widget<ReaderViewport>(viewport).key, before.key);
          expect(tester.widget<ReaderViewport>(viewport).height, screen.height);
          final fullscreenPosition = mode == 'pages'
              ? tester.widget<PageView>(list).controller!.page!
              : tester.widget<ListView>(list).controller!.offset;
          expect(fullscreenPosition, position);
          await tester.tapAt(tester.getCenter(frame));
          await tester.pump();
          tester.view.physicalSize = window;
          await settle(tester);
          expect(tester.state(viewport), same(state));
          expect(tester.widget<ReaderViewport>(viewport).key, before.key);
          await tester.pumpWidget(const SizedBox());
          await settle(tester);
        },
      );
    }
  }

  for (final mode in ['seamless', 'pages', 'compact', 'scroll']) {
    for (final screen in [const Size(390, 844), const Size(1400, 900)]) {
      testWidgets('$mode on $screen keeps pages while chrome changes', (
        tester,
      ) async {
        size(tester, screen);
        tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
        tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final repo = Repository(db);
        await repo.setMeta(
          'reader:appearance',
          jsonEncode({'mode': mode, 'pageHeightFactor': 1.3}),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: ReaderPage(
              repository: repo,
              asset: asset,
              suppliedDocument: document,
            ),
          ),
        );
        await settle(tester);
        final viewport = find.byType(ReaderViewport);
        final before = tester.widget<ReaderViewport>(viewport);
        final state = tester.state(viewport);
        expect(before.height, screen.height);
        expect(before.pageHeightFactor, 1.3);

        await tester.drag(find.byType(ReaderBottomPanel), const Offset(0, 70));
        await settle(tester);
        expect(find.byTooltip('Показать нижнюю панель'), findsOneWidget);
        expect(tester.state(viewport), same(state));
        expect(tester.widget<ReaderViewport>(viewport).key, before.key);

        final center = tester.getCenter(viewport);
        // Empty page space also supports the configured centre tap.
        await tester.tapAt(center);
        tester.view.padding = FakeViewPadding.zero;
        tester.view.viewPadding = FakeViewPadding.zero;
        await settle(tester);
        expect(tester.widget<ReaderViewport>(viewport).hideControls, isTrue);
        expect(tester.state(viewport), same(state));
        expect(tester.widget<ReaderViewport>(viewport).key, before.key);
        expect(find.byType(FloatingActionButton), findsNothing);
        expect(find.byType(ReaderProgressFooter), findsNothing);
        expect(find.byTooltip('Закрыть книгу'), findsNothing);

        await tester.tapAt(center);
        tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
        tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
        await settle(tester);
        expect(tester.widget<ReaderViewport>(viewport).hideControls, isFalse);
        expect(tester.state(viewport), same(state));
        expect(tester.widget<ReaderViewport>(viewport).key, before.key);
        expect(find.byTooltip('Закрыть книгу'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await settle(tester);
      });
    }
  }

  for (final scrolling in [true, false]) {
    testWidgets('text taps and footnotes work with scrolling=$scrolling', (
      tester,
    ) async {
      size(tester, const Size(390, 844));
      const text =
          'Before [4] after link.\n\nНожи и вилки все погнем,\n\nОбъедки разбросаем,';
      var toggles = 0, notes = 0, links = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderViewport(
              text: text,
              style: const TextStyle(fontSize: 20, height: 1.35),
              scaler: TextScaler.noScaling,
              width: 390,
              height: 844,
              margin: 24,
              anchor: 0,
              scrolling: scrolling,
              firstChapter: true,
              lastChapter: true,
              preferences: const ReaderPreferences(),
              footnotes: const [BookFootnote('[4]', 'Примечание', 7, 10)],
              markup: const [
                BookMarkup(17, 21, href: '#target'),
                BookMarkup(23, text.length, block: 'blockquote', italic: true),
              ],
              onFootnote: (_) => notes++,
              onLink: (_, _) => links++,
              onToggleControls: () => toggles++,
              onPosition: (_) {},
              onChapter: (_) {},
            ),
          ),
        ),
      );
      await settle(tester);
      Offset glyph(int start, int end) {
        final selection = TextSelection(baseOffset: start, extentOffset: end);
        if (scrolling) {
          final rich = find
              .descendant(
                of: find.byType(ReaderSelectableParagraph).first,
                matching: find.byType(RichText),
              )
              .first;
          final render = tester.renderObject<RenderParagraph>(rich);
          return render.localToGlobal(
            render.getBoxesForSelection(selection).first.toRect().center,
          );
        }
        final render = tester
            .state<EditableTextState>(find.byType(EditableText).first)
            .renderEditable;
        return render.localToGlobal(
          render.getBoxesForSelection(selection).first.toRect().center,
        );
      }

      await tester.tapAt(glyph(7, 10));
      await tester.pump();
      expect(notes, 1);
      expect(toggles, 0);
      await tester.tapAt(glyph(17, 21));
      await tester.pump();
      expect(links, 1);
      expect(toggles, 0);
      await tester.tapAt(glyph(11, 16));
      await tester.pump();
      expect(toggles, 1);
      await tester.longPressAt(glyph(11, 16));
      await tester.pumpAndSettle();
      expect(toggles, 1);
      expect(notes, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
