import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/reader/reading_activity.dart';
import 'package:pepehub/ui/reading_statistics_page.dart';
import 'package:pepehub/ui/pepe_widgets.dart';

import 'video_player_tools_widget_test.dart' show ready;

void main() {
  testWidgets(
    'reading statistics keeps 1000 text rows lazy beside 1000 large audio records',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase(NativeDatabase.memory());
      final repo = Repository(db);
      addTearDown(db.close);
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day, 10);
      final tracks = List.generate(
        60,
        (i) => {'id': '$i', 'title': 'аудио' * 80},
      );
      await tester.runAsync(() async {
        await db.transaction(() async {
          for (var i = 0; i < 1000; i++) {
            for (final audio in [false, true]) {
              await db.customStatement(
                'INSERT INTO records VALUES(?,?,1,0,?)',
                [
                  '${audio ? 'audio' : 'text'}-$i',
                  'book',
                  jsonEncode({
                    'title': '${audio ? 'Аудио' : 'Текст'} $i',
                    'format': audio ? 'audio' : 'txt',
                    if (audio) 'tracks': tracks,
                  }),
                ],
              );
            }
            await repo.setMeta(
              'reading-session:s-$i',
              jsonEncode({
                'id': 's-$i',
                'bookId': 'text-$i',
                'closed': true,
                'startedAt': start.toUtc().toIso8601String(),
                'spans': [
                  {
                    'start': start.toUtc().toIso8601String(),
                    'end': start
                        .add(const Duration(minutes: 5))
                        .toUtc()
                        .toIso8601String(),
                    'activeMs': 300000 + i,
                    'localDay': readingDay(start),
                  },
                ],
              }),
            );
          }
        });
      });
      await tester.pumpWidget(
        MaterialApp(home: ReadingStatisticsPage(repository: repo)),
      );
      await ready(
        tester,
        () => find
            .byKey(const ValueKey('reading-statistics-loading'))
            .evaluate()
            .isEmpty,
      );
      await tester.scrollUntilVisible(
        find.text('По книгам'),
        500,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 15,
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('reading-statistics-books')),
        findsOneWidget,
      );
      expect(find.byType(PepeShareRow).evaluate().length, lessThan(30));
      expect(
        find.byKey(const ValueKey('reading-statistics-book:text-0')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('reading-statistics-book:text-999')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
