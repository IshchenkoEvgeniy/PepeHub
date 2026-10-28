import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/reader/epub.dart';
import 'package:pepehub/reader/reader_layout.dart';
import 'package:pepehub/reader/reader_page.dart';
import 'package:pepehub/reader/reader_selectable_paragraph.dart';

import 'epub_test.dart' show fixture;
import 'reader_annotations_bookmarks_test.dart' show asset;
import 'reader_improvements_test.dart' show settle, size;

const _noteText = 'Пояснение переводчика к четвёртой сноске.';
EpubBook _book(String target) => parseEpub(
  fixture(
    overrides: {
      'OPS/first.xhtml':
          '<html><body><p>${'Перед сноской идёт текст. ' * 5}'
          '<a href="contentnotes0.html#n_4">[4]</a> После сноски.</p>'
          '<p><a href="second.xhtml#part_4">[5]</a></p></body></html>',
      'OPS/second.xhtml':
          '<html><body><h1 id="part_4">Другая глава</h1></body></html>',
      'OPS/contentnotes0.html': '<html><body>$target</body></html>',
    },
  ),
);

void main() {
  for (final target in [
    '<p id="n_4">$_noteText</p>',
    '<p><a name="n_4">4</a> $_noteText</p>',
    '<a name="n_4"></a><p>$_noteText</p>'
        '<a name="n_5"></a><p>Другая сноска — не включать.</p>',
    '<div class="section"><div class="title"><p><a name="n_4">4</a></p></div>'
        '<p>$_noteText</p></div>'
        '<div class="section"><p id="n_5">Другая сноска — не включать.</p></div>',
  ]) {
    test(
      'legacy note markup extracts only the referenced explanation: $target',
      () {
        final chapter = _book(target).chapters.first;
        expect(chapter.footnotes, hasLength(1));
        final note = chapter.footnotes.single;
        expect(note.text, contains(_noteText));
        expect(note.text, isNot(contains('Другая сноска')));
        expect(
          chapter.paragraphs.join('\n\n').substring(note.start, note.end),
          '[4]',
        );
      },
    );
  }

  for (final mode in ['compact', 'pages']) {
    testWidgets('$mode opens the legacy note text instead of its URL', (
      tester,
    ) async {
      size(tester, const Size(390, 844));
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = Repository(db);
      await repo.setMeta('reader:appearance', jsonEncode({'mode': mode}));
      final book = _book('<p id="n_4">$_noteText</p>');
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPage(
            repository: repo,
            asset: asset,
            suppliedDocument: ReaderDocument(book),
          ),
        ),
      );
      await settle(tester);
      final note = book.chapters.first.footnotes.single;
      final selection = TextSelection(
        baseOffset: note.start,
        extentOffset: note.end,
      );
      late Offset tap;
      if (mode == 'pages') {
        final render = tester
            .state<EditableTextState>(find.byType(EditableText).first)
            .renderEditable;
        tap = render.localToGlobal(
          render.getBoxesForSelection(selection).first.toRect().center,
        );
      } else {
        final rich = find
            .descendant(
              of: find.byType(ReaderSelectableParagraph).first,
              matching: find.byType(RichText),
            )
            .first;
        final render = tester.renderObject<RenderParagraph>(rich);
        tap = render.localToGlobal(
          render.getBoxesForSelection(selection).first.toRect().center,
        );
      }
      await tester.tapAt(tap);
      await tester.pumpAndSettle();
      expect(find.text(_noteText), findsOneWidget);
      expect(find.text('Ссылка'), findsNothing);
      expect(find.text('contentnotes0.html#n_4'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
    });
  }
}
