import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/reader/epub.dart';
import 'package:pepehub/reader/reader_layout.dart';
import 'package:pepehub/reader/reader_page.dart';
import 'package:pepehub/reader/reader_viewport.dart';

import 'reader_annotations_bookmarks_test.dart' show asset;
import 'reader_improvements_test.dart' show settle, size;

void main() {
  testWidgets('the status line counts real screens: +1 on every page turn', (
    tester,
  ) async {
    size(tester, const Size(390, 796));
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = Repository(db);
    await repo.setMeta('reader:appearance', jsonEncode({'mode': 'pages'}));
    // Chapters of different length, so chapter ends are short screens, and
    // paragraphs of different length, so screens hold different amounts.
    final book = ReaderDocument(
      EpubBook('Book', const [], [
        for (var c = 0; c < 4; c++)
          EpubChapter('c$c', 'Chapter $c', [
            for (var i = 0; i < 6 + c * 5; i++)
              'Paragraph $i. ${'Short line. ' * (i.isEven ? 3 : 25)}',
          ]),
      ]),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderPage(
          repository: repo,
          asset: asset,
          suppliedDocument: book,
        ),
      ),
    );
    await settle(tester);
    final pager = find.descendant(
      of: find.byType(ReaderViewport),
      matching: find.byType(PageView),
    );
    ({int page, int count}) status() {
      final text = tester
          .widget<Text>(find.byKey(const ValueKey('reader-status-place')))
          .data!
          .split('/');
      return (page: int.parse(text[0]), count: int.parse(text[1]));
    }

    final count = status().count;
    expect(status().page, 1);
    for (var turn = 1; turn < count; turn++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await settle(tester);
      expect(status(), (page: turn + 1, count: count), reason: "turn $turn");
      final screen = tester.widget<PageView>(pager).controller!.page!.round();
      // The number is the screen itself.
      expect(screen + 1, turn + 1);
    }
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  });
}
