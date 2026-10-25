import 'dart:convert';
import 'dart:math';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/reader/epub.dart';
import 'package:pepehub/reader/reader_layout.dart';
import 'package:pepehub/reader/reader_layout_frame.dart';
import 'package:pepehub/reader/reader_page.dart';
import 'package:pepehub/reader/reader_ranges.dart';
import 'package:pepehub/reader/reader_viewport.dart';
import 'package:pepehub/reader/reader_progress_panel.dart';
import 'package:pepehub/reader/reading_activity.dart';
import 'package:pepehub/reader/reading_daily_totals.dart';

import 'reader_improvements_test.dart' show settle, size;

void main() {
  test(
    'interval lookup preserves overlap precedence and excludes touching edges',
    () {
      final random = Random(17);
      final ranges = [
        for (var i = 0; i < 300; i++)
          (start: random.nextInt(1000), length: random.nextInt(250) + 1, id: i),
      ];
      final index = ReaderRangeIndex(
        ranges,
        start: (range) => range.start,
        end: (range) => range.start + range.length,
      );
      for (var from = 0; from < 1200; from += 7) {
        expect(
          index.overlapping(from, from + 13),
          ranges
              .where(
                (range) =>
                    range.start < from + 13 &&
                    range.start + range.length > from,
              )
              .toList(),
        );
      }
      expect(index.overlapping(10, 10), isEmpty);
      expect(index.overlapping(20, 10), isEmpty);
    },
  );

  test('a distant footnote lookup does not revisit every earlier footnote', () {
    var inspected = 0;
    final index = ReaderRangeIndex(
      List.generate(10000, (i) => (start: i * 100, end: i * 100 + 3)),
      start: (range) {
        inspected++;
        return range.start;
      },
      end: (range) {
        inspected++;
        return range.end;
      },
    );
    inspected = 0;
    expect(index.overlapping(990000, 990004), [(start: 990000, end: 990003)]);
    expect(inspected, lessThan(20));
  });

  test(
    'identical chapter ticks do not repaint when only the slider changes',
    () {
      final painter = ReaderBookTicksPainter([0, .2, .7], Colors.blue);
      expect(
        painter.shouldRepaint(
          ReaderBookTicksPainter([0, .2, .7], Colors.blue),
        ),
        isFalse,
      );
      expect(
        painter.shouldRepaint(
          ReaderBookTicksPainter([0, .3, .7], Colors.blue),
        ),
        isTrue,
      );
    },
  );

  testWidgets(
    'resize keeps measured dimensions until the last resize settles',
    (tester) async {
      var width = 390.0;
      late StateSetter resize;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: StatefulBuilder(
            builder: (context, setState) {
              resize = setState;
              return Center(
                child: SizedBox(
                  width: width,
                  height: 500,
                  child: ReaderLayoutFrame(
                    builder: (_, box) => Text('${box.maxWidth}'),
                  ),
                ),
              );
            },
          ),
        ),
      );
      expect(find.text('390.0'), findsOneWidget);
      resize(() => width = 430);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('390.0'), findsOneWidget);
      resize(() => width = 470);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('390.0'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 181));
      expect(find.text('470.0'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'scroll reports do not rebuild text, and search reuses measured pages',
    (tester) async {
      size(tester, const Size(430, 900));
      final db = AppDatabase(NativeDatabase.memory()), repo = Repository(db);
      final document = ReaderDocument(
        EpubBook('Book', [], [
          EpubChapter('one', 'First', [
            'needle first. ${'A calm sea near the shore. ' * 8}',
            'needle second. ${'We continue to the island. ' * 8}',
            for (var i = 0; i < 6; i++) 'Another paragraph $i. ' * 10,
          ]),
        ]),
      );
      const asset = LocalAsset(
        id: 'a',
        bookId: 'b',
        filename: 'book.txt',
        path: 'unused',
        hash: 'performance',
        bytes: 0,
      );
      try {
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
        final state = tester.state(viewport);
        final original = tester.widget<ReaderViewport>(viewport);
        original.onPosition(7);
        await settle(tester);
        expect(identical(tester.widget(viewport), original), isTrue);
        expect(
          jsonDecode((await repo.meta('reader:${asset.hash}'))!)['textOffset'],
          7,
        );
        await tester.tap(find.byTooltip('Поиск по книге'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'needle');
        await settle(tester);
        expect(find.text('Совпадений: 2'), findsOneWidget);
        await tester.tap(find.byType(ListTile).first);
        await settle(tester);
        expect(identical(tester.state(viewport), state), isTrue);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        await tester.tap(find.byTooltip('Следующее совпадение'));
        await settle(tester);
        expect(identical(tester.state(viewport), state), isTrue);
        expect(
          tester.widget<ReaderViewport>(viewport).highlightStart,
          document.texts.single.indexOf('needle second'),
        );
        final beforeOverlay = tester.widget<ReaderViewport>(viewport);
        beforeOverlay.onBoundary!(0, false);
        await settle(tester);
        expect(identical(tester.state(viewport), state), isTrue);
        expect(
          tester.widget<ReaderViewport>(viewport).height,
          beforeOverlay.height,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await settle(tester);
        await db.close();
      }
    },
  );

  testWidgets('a thousand chapter marks do not create a widget per chapter', (
    tester,
  ) async {
    size(tester, const Size(430, 900));
    final db = AppDatabase(NativeDatabase.memory()), repo = Repository(db);
    await repo.setMeta('reader:appearance', '{"mode":"scroll"}');
    final document = ReaderDocument(
      EpubBook('Many chapters', [], [
        for (var i = 0; i < 1000; i++)
          EpubChapter('$i', 'Chapter $i', ['A calm sea.']),
      ]),
    );
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderPage(
            repository: repo,
            asset: const LocalAsset(
              id: 'many',
              bookId: 'many',
              filename: 'many.txt',
              path: 'unused',
              hash: 'many-chapters',
              bytes: 0,
            ),
            suppliedDocument: document,
          ),
        ),
      );
      await settle(tester);
      expect(find.byType(ReaderViewport), findsOneWidget);
      expect(find.byType(Positioned).evaluate().length, lessThan(30));
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await settle(tester);
      await db.close();
    }
  });

  test(
    'daily numeric totals preserve clipping and react to sync updates/deletion',
    () async {
      final db = AppDatabase(NativeDatabase.memory()), repo = Repository(db);
      addTearDown(db.close);
      final date = DateTime(2026, 10, 25);
      Map<String, dynamic> session(int seconds) => {
        'bookId': 'book',
        'spans': [
          {
            'start': date
                .subtract(const Duration(seconds: 20))
                .toUtc()
                .toIso8601String(),
            'end': date
                .add(Duration(seconds: seconds))
                .toUtc()
                .toIso8601String(),
            'activeMs': (seconds + 20) * 500,
          },
          {
            'start': date.toUtc().toIso8601String(),
            'end': date
                .add(const Duration(seconds: 60))
                .toUtc()
                .toIso8601String(),
            'pepehubDeleted': true,
          },
        ],
      };
      await repo.setMeta('reading-session:old', jsonEncode(session(40)));
      final totals = ReadingDailyTotals(repo);
      int expected(Map<String, dynamic> value) => readingTotals(
        [value],
        start: date,
        end: DateTime(2026, 10, 26),
      ).milliseconds;
      expect(await totals.day(date), expected(session(40)));
      expect(await totals.day(date), 20000);
      // Same direct metadata path as a synchronized replacement.
      await repo.setMeta('reading-session:old', jsonEncode(session(80)));
      expect(await totals.day(date), expected(session(80)));
      await repo.db.customStatement('UPDATE metadata SET key=? WHERE key=?', [
        'reading-session:renamed',
        'reading-session:old',
      ]);
      expect(await totals.day(date), 40000);
      await repo.setMeta('reading-session:bad', '{bad JSON');
      expect(await totals.day(date), 40000);
      await repo.db.customStatement('DELETE FROM metadata WHERE key=?', [
        'reading-session:renamed',
      ]);
      expect(await totals.day(date), 0);
    },
  );

  testWidgets(
    'rapid deliberate jumps coalesce journal exports and close flushes the last jump',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory()), repo = Repository(db);
      var exports = 0;
      final activity = ReadingActivity(
        repo,
        bookId: 'b',
        hash: 'h',
        length: 1000,
        export: (_) async {
          exports++;
        },
      );
      await activity.start(0, runTimer: false);
      expect(exports, 1);
      for (final at in [100, 200, 300]) {
        activity.move(at, jump: true, deferCheckpoint: true);
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(exports, 1);
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester);
      expect(exports, 2);
      activity.move(400, jump: true, deferCheckpoint: true);
      await activity.close();
      expect(exports, 3);
      await tester.pump(const Duration(seconds: 1));
      expect(exports, 3);
      final saved = jsonDecode(
        (await repo.meta('reading-session:${activity.id}'))!,
      );
      expect(saved['position'], 400);
      expect(
        (saved['events'] as List).where((e) => e['kind'] == 'jump'),
        hasLength(4),
      );
      expect(saved['newChars'], 0);
      await db.close();
    },
  );
}
