import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/ui/book_picker.dart';
import 'package:pepehub/ui/pepe_widgets.dart';
import 'package:pepehub/ui/statistics_management_page.dart';

import 'video_player_tools_widget_test.dart' show ready;

class _SlowJournalRepository extends Repository {
  Completer<void>? journalGate;
  _SlowJournalRepository(super.db);
  @override
  Future<void> setMeta(String key, String value) async {
    if (key.startsWith('reading-log-error:')) await journalGate?.future;
    await super.setMeta(key, value);
  }
}

void main() {
  testWidgets(
    '2000 books remain searchable without building every picker row',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BookPicker(
              titles: {for (var i = 0; i < 2000; i++) '$i': 'Книга $i'},
              value: null,
              onChanged: (id) => selected = id,
            ),
          ),
        ),
      );
      await tester.tap(find.text('Все книги'));
      await tester.pumpAndSettle();
      expect(find.byType(ListTile).evaluate().length, lessThan(25));
      tester.view.viewInsets = FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'КНИГА 1999');
      await tester.pumpAndSettle();
      expect(find.text('Найдено: 1'), findsOneWidget);
      await tester.tap(find.text('Книга 1999'));
      await tester.pumpAndSettle();
      expect(selected, '1999');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('calendar brightness distinguishes short and long active days', (
    tester,
  ) async {
    final month = DateTime(2025, 1);
    final minutes = [0, 5, 15, 30, 60, 120, 240];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 350,
            child: PepeMonthCalendar(
              month: month,
              dayValue: (day) =>
                  day.day <= minutes.length ? minutes[day.day - 1] * 60000 : 0,
              title: 'Календарь',
              goalMinutes: 60,
              onPrevious: () {},
              onNext: () {},
              describe: (ms) => '$ms',
            ),
          ),
        ),
      ),
    );
    final colors = <Color>{};
    var previous = -1.0;
    for (var d = 2; d <= 7; d++) {
      final material = tester.widget<Material>(
        find
            .ancestor(of: find.text('$d'), matching: find.byType(Material))
            .first,
      );
      final color = material.color!;
      colors.add(color);
      expect(color.computeLuminance(), greaterThan(previous));
      previous = color.computeLuminance();
    }
    expect(colors, hasLength(6));
    expect(tester.takeException(), isNull);
  });

  for (final audio in [false, true]) {
    testWidgets(
      '${audio ? 'audio' : 'reading'} history groups days and removes single and bulk records immediately',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final db = AppDatabase(NativeDatabase.memory());
        final repo = _SlowJournalRepository(db);
        await tester.runAsync(() async {
          await db.transaction(() async {
            for (var i = 0; i < 1000; i++) {
              for (final format in ['epub', 'audio']) {
                await repo.put('book', '$format-$i', {
                  'title': '$format Книга $i',
                  'format': format,
                });
              }
            }
            for (var i = 0; i < 2; i++) {
              final at = DateTime(2026, 10, 30, 12, i).toUtc();
              if (audio) {
                await repo.put('audio_event', 'a$i', {
                  'kind': 'listen',
                  'bookId': 'audio-0',
                  'trackId': 't',
                  'at': at.toIso8601String(),
                  'wallMs': 60000,
                  'positionMs': 0,
                  'endMs': 60000,
                  'speed': 1.0,
                });
              } else {
                await repo.setMeta(
                  'reading-session:r$i',
                  jsonEncode({
                    'id': 'r$i',
                    'bookId': 'epub-0',
                    'startedAt': at.toIso8601String(),
                    'endedAt': at
                        .add(const Duration(minutes: 1))
                        .toIso8601String(),
                    'spans': [
                      {
                        'start': at.toIso8601String(),
                        'end': at
                            .add(const Duration(minutes: 1))
                            .toIso8601String(),
                        'activeMs': 60000,
                      },
                    ],
                  }),
                );
              }
            }
          });
        });
        dynamic state;
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: StatisticsManagementPage(
                repository: repo,
                initialTab: audio ? 1 : 0,
              ),
            ),
          );
          state = tester.state(find.byType(StatisticsManagementPage));
          await ready(tester, () => !state.loading);
          expect(state.readingBooks, hasLength(1000));
          expect(state.audioBooks, hasLength(1000));
          expect(state.tracks, isEmpty);
          expect(find.byTooltip('Действия'), findsNothing);
          expect(find.text('2 записей · 2 мин'), findsOneWidget);
          await tester.tap(find.text('2026-10-30'));
          await tester.pumpAndSettle();
          expect(find.byTooltip('Действия'), findsNWidgets(2));
          await tester.tap(find.byTooltip('Действия').first);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Удалить из статистики'));
          await tester.pumpAndSettle();
          repo.journalGate = Completer<void>();
          await tester.tap(find.text('Удалить'));
          await ready(
            tester,
            () =>
                !state.loading &&
                (audio ? state.audioEvents : state.reading).length == 1,
          );
          expect(find.text('1 записей · 1 мин'), findsOneWidget);
          if (!audio) {
            expect(state.mutating, isTrue); // folder export is still pending
          }
          repo.journalGate!.complete();
          await ready(tester, () => !state.mutating);
          await tester.tap(find.byType(Checkbox).first);
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Удалить выбранные'));
          await tester.pumpAndSettle();
          repo.journalGate = Completer<void>();
          await tester.tap(find.text('Удалить'));
          await ready(
            tester,
            () =>
                !state.loading &&
                (audio ? state.audioEvents : state.reading).isEmpty,
          );
          expect(find.text('2026-10-30'), findsNothing);
          repo.journalGate!.complete();
          await ready(tester, () => !state.mutating);
          expect(tester.takeException(), isNull);
        } finally {
          if (repo.journalGate?.isCompleted == false) {
            repo.journalGate!.complete();
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(db.close);
        }
      },
    );
  }
}
