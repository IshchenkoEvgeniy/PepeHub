import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/reader/reader_progress_panel.dart';
import 'package:pepehub/reader/reader_viewport.dart';
import 'package:pepehub/reader/reading_library.dart';

import 'reader_annotations_bookmarks_test.dart' show reader, asset;
import 'reader_improvements_test.dart' show settle, size;
import 'support/reader_controls.dart';

void main() {
  testWidgets(
    'panel swipes do not seek and horizontal progress drag uses its final position',
    (tester) async {
      size(tester, const Size(390, 800));
      var seeks = <double>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            bottomNavigationBar: ReaderBottomPanel(
              child: ReaderProgressFooter(
                value: .2,
                ink: Colors.black,
                accent: Colors.teal,
                onChanged: (_) {},
                onChangeEnd: seeks.add,
                details: const [Text('20% книги')],
              ),
            ),
          ),
        ),
      );
      await tester.drag(find.text('20% книги'), const Offset(0, 60));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderProgressBar), findsNothing);
      expect(seeks, isEmpty);
      await tester.drag(
        find.byTooltip('Показать нижнюю панель'),
        const Offset(0, -60),
      );
      await tester.pumpAndSettle();
      final rect = tester.getRect(find.byType(ReaderProgressBar));
      final gesture = await tester.startGesture(
        Offset(rect.left + rect.width * .2, rect.center.dy),
      );
      await gesture.moveTo(Offset(rect.left + rect.width * .8, rect.center.dy));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(seeks.single, closeTo(.8, .02));
      expect(find.byTooltip('Показать нижнюю панель'), findsNothing);
      await tester.drag(find.text('20% книги'), const Offset(0, 60));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Показать нижнюю панель'));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderProgressBar), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final mode in ['pages', 'compact', 'scroll']) {
    testWidgets(
      '$mode: controls float over a fixed page and never move the text',
      (tester) async {
        size(tester, const Size(390, 800));
        final db = AppDatabase(NativeDatabase.memory()), repo = Repository(db);
        try {
          await repo.setMeta('reader:appearance', '{"mode":"$mode"}');
          await tester.pumpWidget(reader(repo));
          await settle(tester);
          // Reading: only the text and a quiet status line.
          expect(find.byType(ReaderProgressBar), findsNothing);
          expect(find.byTooltip('Поиск по книге').hitTestable(), findsNothing);
          expect(
            find.byKey(const ValueKey('reader-status-place')),
            findsOneWidget,
          );
          final viewport = find.byType(ReaderViewport);
          final state = tester.state(viewport);
          final rect = tester.getRect(viewport);
          final before = await ReadingLibrary(repo)
              .value('reader:${asset.hash}');

          await showReaderControls(tester);
          await settle(tester);
          expect(find.byType(ReaderProgressBar), findsOneWidget);
          expect(find.byType(Slider), findsNothing);
          expect(
            find.byTooltip('Поиск по книге').hitTestable(),
            findsOneWidget,
          );
          // Showing the controls neither re-measures nor moves the page.
          expect(identical(tester.state(viewport), state), isTrue);
          expect(tester.getRect(viewport), rect);

          await tester.tapAt(rect.center);
          await settle(tester);
          expect(find.byType(ReaderProgressBar), findsNothing);
          expect(identical(tester.state(viewport), state), isTrue);
          final after = await ReadingLibrary(repo)
              .value('reader:${asset.hash}');
          expect(
            (after['chapter'], after['textOffset']),
            (before['chapter'], before['textOffset']),
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await settle(tester);
          await db.close();
        }
      },
    );
  }
}
