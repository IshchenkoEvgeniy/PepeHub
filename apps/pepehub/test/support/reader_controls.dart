import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/reader/reader_viewport.dart';

/// The text reader keeps its header and footer hidden while reading. Like a
/// reader, tap the middle of the page to bring them up (no-op when they are
/// already shown or when no text page is open).
Future<void> showReaderControls(WidgetTester tester) async {
  if (find.byKey(const ValueKey('reader-footer')).evaluate().isNotEmpty) {
    return;
  }
  final viewport = find.byType(ReaderViewport);
  if (viewport.evaluate().isEmpty) return;
  // A first tap may only clear a text selection, as it does for a reader.
  for (var attempt = 0; attempt < 3; attempt++) {
    final rect = tester.getRect(viewport.first);
    await tester.tapAt(Offset(rect.center.dx, rect.top + rect.height * .45));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    if (find.byKey(const ValueKey('reader-footer')).evaluate().isNotEmpty) {
      return;
    }
    await tester.pump(const Duration(milliseconds: 400));
  }
}

/// Turns the page: a swipe in page mode (it works with a selection on the
/// page), otherwise a tap in the right (or left) reading zone.
Future<void> turnReaderPage(WidgetTester tester, {bool back = false}) async {
  final pager = find.descendant(
    of: find.byType(ReaderViewport).first,
    matching: find.byType(PageView),
  );
  final rect = tester.getRect(find.byType(ReaderViewport).first);
  if (pager.evaluate().isNotEmpty) {
    await tester.dragFrom(
      Offset(back ? rect.left + 20 : rect.right - 20, rect.center.dy),
      Offset(back ? rect.width * .7 : -rect.width * .7, 0),
    );
    await tester.pumpAndSettle();
    return;
  }
  await tester.tapAt(
    Offset(back ? rect.left + 6 : rect.right - 6, rect.center.dy),
  );
  await tester.pump();
}

/// Taps a control of the reader's header or footer, revealing them first.
Future<void> tapReaderControl(WidgetTester tester, Finder control) async {
  // A confirmation («Выделение сохранено») can sit over the footer for a few
  // seconds; a reader would wait for it.
  final snack = find.byType(SnackBar);
  if (snack.evaluate().isNotEmpty) {
    ScaffoldMessenger.of(tester.element(snack.first)).removeCurrentSnackBar();
    await tester.pumpAndSettle();
  }
  await showReaderControls(tester);
  await tester.tap(control);
}
