import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pepehub/audio/audio_journal.dart';
import 'package:pepehub/audio/listening_analytics.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/activity_store.dart';
import 'package:pepehub/library/library_service.dart';
import 'package:pepehub/library/personal_library.dart';
import 'package:pepehub/reader/reading_activity.dart';
import 'package:pepehub/reader/reading_statistics_history.dart';
import 'package:pepehub/ui/activity_page.dart';
import 'package:pepehub/ui/book_activity_summary.dart';
import 'package:pepehub/ui/statistics_hub_page.dart';
import 'package:pepehub/ui/shelf_components.dart';

import 'video_player_tools_widget_test.dart' show ready;

Map<String, dynamic> _session(String id, DateTime date) => {
  'id': id,
  'bookId': id,
  'startedAt': date.toUtc().toIso8601String(),
  'closed': true,
  'spans': [
    {
      'start': date.toUtc().toIso8601String(),
      'end': date.add(const Duration(minutes: 5)).toUtc().toIso8601String(),
      'activeMs': 300000,
      'localDay': readingDay(date),
    },
  ],
};

void main() {
  testWidgets(
    'overview keeps a 40-day current streak across New Year in every scope',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final repo = Repository(db);
      addTearDown(db.close);
      final now = DateTime(2026, 1, 3, 18);
      final events = <Map<String, dynamic>>[],
          sessions = <Map<String, dynamic>>[];
      await tester.runAsync(() async {
        await repo.put('book', 'text', {'title': 'Текст', 'format': 'txt'});
        await repo.put('book', 'audio', {'title': 'Аудио', 'format': 'audio'});
        await db.transaction(() async {
          for (var i = 0; i < 40; i++) {
            final date = DateTime(now.year, now.month, now.day - i, 12);
            final session = {..._session('text', date), 'id': 'read-$i'};
            sessions.add(session);
            await repo.setMeta('reading-session:read-$i', jsonEncode(session));
            final event = <String, dynamic>{
              'kind': 'listen',
              'bookId': 'audio',
              'trackId': 'track',
              'at': date.toUtc().toIso8601String(),
              'localDay': readingDay(date),
              'offsetMinutes': date.timeZoneOffset.inMinutes,
              'positionMs': i * 300000,
              'endMs': (i + 1) * 300000,
              'wallMs': 300000,
              'mediaMs': 300000,
              'speed': 1.0,
            };
            events.add(event);
            await AudioJournal(repo).put('audio_event', 'audio-$i', event);
          }
        });
      });
      expect(readingStreak(readingTotals(sessions).days, now).current, 40);
      expect(analyzeListening({'events': events}).currentStreak(now), 40);
      await tester.pumpWidget(
        MaterialApp(
          home: StatisticsHubPage(
            repository: repo,
            clock: () => now,
            navigation: ShelfNavigation(
              current: PepeSection.statistics,
              onSelect: (_) {},
              onSettings: () {},
            ),
          ),
        ),
      );
      final dynamic state = tester.state(find.byType(StatisticsHubPage));
      await ready(tester, () => !state.loading);
      final panel = find.byKey(const ValueKey('statistics-streak'));
      for (final scope in ['all', 'reading', 'audio']) {
        await tester.tap(find.byKey(ValueKey('statistics-scope:$scope')));
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: panel, matching: find.text('40')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: panel,
            matching: find.textContaining('рекорд года 3'),
          ),
          findsOneWidget,
        );
      }
      await tester.tap(find.byTooltip('Предыдущий год'));
      await ready(tester, () => !state.loading);
      expect(
        find.descendant(of: panel, matching: find.text('37')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: panel,
          matching: find.textContaining('рекорд дней подряд за 2025'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'history recovers deleted titles and never displays an orphan source ID',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final repo = Repository(db);
      addTearDown(db.close);
      final date = DateTime(2026, 1, 1, 12);
      await repo.put('book', 'deleted', {
        'title': 'Сохранённое название',
        'format': 'txt',
      });
      // Some imported/legacy history still retains the deleted source header.
      await repo.db.customStatement('UPDATE records SET deleted=1 WHERE id=?', [
        'deleted',
      ]);
      await repo.put('book', 'tombstone', {'title': 'Erased', 'format': 'txt'});
      await repo.delete('book', 'tombstone');
      for (final id in ['deleted', 'tombstone', '3f2a-opaque-id']) {
        await repo.setMeta(
          'reading-session:$id',
          jsonEncode(_session(id, date)),
        );
      }
      final history = await ReadingStatisticsHistory.load(repo);
      expect(history.titles['deleted'], 'Сохранённое название');
      expect(history.titles['3f2a-opaque-id'], 'Книга без файла');
      expect(history.titles['tombstone'], 'Книга без файла');
      expect(await repo.bookHeaders(), isEmpty);
    },
  );

  testWidgets(
    'journal searches actual notes but excludes the native-row hint',
    (tester) async {
      final db = AppDatabase(NativeDatabase.memory());
      final repo = Repository(db);
      final client = MockClient((_) => throw StateError('No network'));
      final library = LibraryService(repo, client);
      addTearDown(() async {
        library.dispose();
        client.close();
        await db.close();
      });
      await tester.runAsync(() async {
        await repo.put('book', 'current', {
          'title': 'Сегодняшнее чтение',
          'format': 'txt',
        });
        await repo.setMeta(
          'reading-session:current',
          jsonEncode(_session('current', DateTime(2026, 1, 1, 12))),
        );
        final card = personalLibraryItem(uuid.v4(), 'book', {
          'title': 'Архив с заметкой',
          'status': 'finished',
        });
        await library.add(card, '');
        await library.loadCached();
        final id = uuid.v4();
        await library.history!.mutate((state) async {
          state['slots'][id] = {
            'value': ActivityStore.entry(
              id: id,
              itemId: card.id,
              mediaType: 'book',
              day: '2026-01-01',
              durationMs: 300000,
              progress: 0,
              unit: 'unknown',
              origin: 'obsidian',
              note: 'Моя сессия чтения',
            ),
            'revision': 0,
            'synced': null,
          };
        });
      });
      await tester.pumpWidget(
        MaterialApp(home: ActivityPage(library: library)),
      );
      final dynamic state = tester.state(find.byType(ActivityPage));
      await ready(tester, () => !state.loading);
      expect(find.byType(BookActivityDayTile), findsNWidgets(2));
      await tester.enterText(find.byType(TextField), 'сесс');
      await tester.pumpAndSettle();
      expect(find.byType(BookActivityDayTile), findsOneWidget);
      expect(find.text('Архив с заметкой'), findsOneWidget);
      expect(find.text('Сегодняшнее чтение'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
