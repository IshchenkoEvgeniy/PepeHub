import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/models.dart';
import 'package:pepehub/library/personal_library.dart';
import 'package:pepehub/statistics/year_progress.dart';
import 'package:pepehub/ui/annual_book_statistics.dart';

LibraryEntry finished(String id, String end, {String type = 'book'}) =>
    LibraryEntry(
      personalLibraryItem(id, type, {
        'title': 'Книга $id',
        'status': 'finished',
        'endDate': end,
        'pepehub_auto_discovered': false,
      }),
    );

void main() {
  test('Russian plurals', () {
    String days(int n) => ruPlural(n, 'день', 'дня', 'дней');
    expect([1, 2, 4, 5, 11, 12, 14, 21, 22, 25, 101, 111].map(days).toList(), [
      'день',
      'дня',
      'дня',
      'дней',
      'дней',
      'дней',
      'дней',
      'день',
      'дня',
      'дней',
      'день',
      'дней',
    ]);
  });

  test('comparison with last year uses the same dates', () {
    final now = DateTime(2026, 3, 10, 15);
    final cutoff = comparisonCutoff(2026, now);
    const days = {
      '2025-03-10': 10,
      '2025-03-11': 100,
      '2025-12-31': 1000,
      '2026-03-01': 7,
      'broken': 5,
    };
    expect(sumDaysInYear(days, 2025, cutoff: cutoff), 10);
    expect(sumDaysInYear(days, 2025), 1110);
    expect(sumDaysInYear(days, 2026, cutoff: cutoff), 7);
    expect(comparisonCutoff(2025, now), isNull);
    expect(
      countDatesInYear(
        [DateTime(2025, 2, 1), DateTime(2025, 3, 11), DateTime(2024, 1, 1)],
        2025,
        cutoff: cutoff,
      ),
      1,
    );
    expect(percentChange(118, 100), '+18%');
    expect(percentChange(95, 100), '−5%');
    expect(percentChange(100, 100), '±0%');
    expect(percentChange(5, 0), isNull);
    expect(countChange(3, 1), '+2');
    expect(countChange(1, 2), '−1');
    expect(countChange(2, 2), '±0');
  });

  test('average per month counts only the elapsed part of the year', () {
    // 1 November: ten months and a day, not eleven whole months.
    expect(
      averagePerMonth(10, 2026, DateTime(2026, 11, 1)),
      closeTo(10 / (305 * 12 / 365), 1e-9),
    );
    // A book on 2 January is not «30 per month».
    expect(averagePerMonth(1, 2026, DateTime(2026, 1, 2)), 1);
    expect(averagePerMonth(24, 2025, DateTime(2026, 6, 1)), 2);
    expect(averagePerMonth(3, 2027, DateTime(2026, 6, 1)), 0);
  });

  test('goal pace forecasts the year and the pace still needed', () {
    final now = DateTime(2026, 7, 2); // day 183 of 365
    final pace = goalPace(done: 6, goal: 12, year: 2026, now: now);
    expect(pace.projected, 12);
    expect(pace.remaining, 6);
    expect(pace.daysLeft, 183);
    expect(pace.daysPerCompletion, closeTo(30.5, 1e-9));
    expect(
      goalPaceText(pace, 12, 2026, now),
      'В этом темпе к 31 декабря выйдет около 12 из 12. '
      'Чтобы успеть — одно произведение каждые 30 дней.',
    );

    final reached = goalPace(done: 13, goal: 12, year: 2026, now: now);
    expect(reached.reached, isTrue);
    expect(goalPaceText(reached, 12, 2026, now), 'Цель выполнена.');

    final missed = goalPace(done: 9, goal: 12, year: 2025, now: now);
    expect(missed.projected, isNull);
    expect(missed.daysPerCompletion, isNull);
    expect(goalPaceText(missed, 12, 2025, now), 'Не хватило 3 произведений.');

    final lastDay = DateTime(2026, 12, 31);
    final rush = goalPace(done: 9, goal: 12, year: 2026, now: lastDay);
    expect(rush.daysLeft, 1);
    expect(
      goalPaceText(rush, 12, 2026, lastDay),
      contains('нужно 3 произведения в день'),
    );
  });

  testWidgets('one feed shows the goal pace and the change since last year', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final repo = Repository(db);
    addTearDown(db.close);
    await tester.runAsync(
      () => repo.setMeta('library-year-goal:personal:2026', '12'),
    );
    final now = DateTime(2026, 7, 2, 12);
    final entries = [
      for (var m = 1; m <= 6; m++)
        finished('n$m', '2026-0$m-10', type: m.isEven ? 'audiobook' : 'book'),
      for (var m = 1; m <= 4; m++) finished('o$m', '2025-0$m-10'),
      for (var m = 8; m <= 10; m++)
        finished('l$m', '2025-${m < 10 ? '0$m' : m}-10'),
    ];
    const hour = 3600000;
    const reading = {'2026-03-01': 12 * hour};
    const readingAll = {
      ...reading,
      '2025-03-01': 10 * hour,
      '2025-09-01': 50 * hour,
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnnualBookStatistics(
            repository: repo,
            completedEntries: entries,
            year: 2026,
            scope: 'all',
            readingDays: reading,
            audioDays: const {},
            readingAllDays: readingAll,
            audioAllDays: const {},
            clock: () => now,
            onScope: (_) {},
            onYear: (_) {},
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.text('Годовая статистика'), findsNothing);
    expect(find.text('6'), findsWidgets);
    expect(find.text('завершено · 3 кн., 3 ауд.'), findsOneWidget);
    expect(find.text('+2 к 2025 на эту дату'), findsOneWidget);
    expect(find.text('+20% к 2025 на эту дату'), findsOneWidget);
    expect(find.text('6 / 12'), findsOneWidget);
    expect(find.textContaining('выйдет около 12 из 12'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('statistics-goal-progress')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
