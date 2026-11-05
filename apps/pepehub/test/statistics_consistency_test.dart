import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pepehub/audio/audio_daily_totals.dart';
import 'package:pepehub/audio/audio_journal.dart';
import 'package:pepehub/audio/audio_statistics_history.dart';
import 'package:pepehub/audio/listening_analytics.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/activity_store.dart';
import 'package:pepehub/library/book_calendar_data.dart';
import 'package:pepehub/library/journal_days.dart';
import 'package:pepehub/library/library_dates.dart';
import 'package:pepehub/library/library_service.dart';
import 'package:pepehub/library/models.dart';
import 'package:pepehub/library/personal_library.dart';
import 'package:pepehub/library/reading_insights.dart';
import 'package:pepehub/reader/reading_activity.dart';
import 'package:pepehub/reader/reading_statistics_data.dart';
import 'package:pepehub/reader/reading_statistics_history.dart';
import 'package:pepehub/statistics/activity_streak.dart';
import 'package:pepehub/statistics/statistics_period.dart';

String cardId(int i) =>
    '00000000-0000-4000-8000-${i.toString().padLeft(12, '0')}';
LibraryEntry card(int i, {String type = 'book', String? source}) =>
    LibraryEntry(
      personalLibraryItem(cardId(i), type, {
        'title': 'Произведение $i',
        'status': 'finished',
        'endDate': '2026-01-01',
      }),
      sourceBookId: source,
    );
Map<String, dynamic> session(
  String id,
  String book,
  String at,
  String day,
  int ms,
) => {
  'id': id,
  'bookId': book,
  'startedAt': at,
  'closed': true,
  'spans': [
    {
      'start': at,
      'end': DateTime.parse(at)
          .add(Duration(milliseconds: ms))
          .toIso8601String(),
      'activeMs': ms,
      'localDay': day,
    },
  ],
};
Map<String, dynamic> audio(String book, String at, String day, int ms) => {
  'kind': 'listen',
  'bookId': book,
  'trackId': 'track:$book',
  'at': at,
  'localDay': day,
  'offsetMinutes': 180,
  'positionMs': 0,
  'endMs': ms,
  'mediaMs': ms,
  'wallMs': ms,
  'speed': 1.0,
};
Map<String, dynamic> slot(
  int i,
  int item, {
  String type = 'book',
  int ms = 600000,
  String day = '2026-01-01',
  Map<String, dynamic>? source,
}) => {
  'value': ActivityStore.entry(
    id: cardId(i),
    itemId: cardId(item),
    mediaType: type,
    day: day,
    durationMs: ms,
    progress: 0,
    unit: 'unknown',
    origin: 'obsidian',
  ),
  'synced': null,
  'revision': 0,
  'source': ?source,
};
int sum(Iterable<int> values) => values.fold(0, (a, b) => a + b);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'completion dates share strict local-calendar parsing on every screen',
    () {
      for (final raw in [
        '31.02.2025',
        '2025-02-31',
        '2025-02-31T23:30:00Z',
        '2026-01-01T25:00:00Z',
        '29.02.2025',
        '2025-13-01',
        '',
        'text',
      ]) {
        expect(libraryDate(raw), isNull, reason: raw);
        expect(bookDate(raw), isNull, reason: raw);
        expect(
          libraryCompletionDate(
            personalLibraryItem('x', 'book', {'endDate': raw}),
          ),
          isNull,
          reason: raw,
        );
      }
      for (final raw in [
        '2025-12-31T23:30:00Z',
        '2026-01-01T00:30:00+03:00',
        '2026-01-01T00:30:00-03:00',
      ]) {
        final expected = DateTime.parse(raw).toLocal();
        final item = personalLibraryItem('x', 'book', {
          'endDate': raw,
          'startDate': raw,
        });
        expect(bookDate(raw), expected);
        expect(libraryCompletionDate(item), expected);
        expect(libraryStartDate(item), expected);
      }
      expect(libraryDate(' 29.02.2024 '), DateTime(2024, 2, 29));
      expect(libraryDate('2025-12-31'), DateTime(2025, 12, 31));
    },
  );

  test('annual goal counts rereads, excludes hidden/trash/plans and mirrors endDate once', () {
    final repeated = card(1)
      ..item.values['pepehub_completions'] = [
        {'date': '2025-12-31'},
        {'date': '2026-01-01'},
        {'date': '2026-03-01'},
      ];
    final hidden = card(2)..item.values['pepehub_hidden'] = true;
    final trash = card(3)..item.values['pepehub_deleted_at'] = '2026-01-02';
    final planned = card(4)..item.values['status'] = 'planned';
    final active = card(5)..item.values['status'] = 'active';
    final abandoned = card(6)..item.values['status'] = 'abandoned';
    abandoned.item.values['pepehub_completions'] = [
      {'date': '2026-04-01'},
    ];
    final entries = [
      repeated,
      hidden,
      trash,
      planned,
      active,
      abandoned,
      card(7, type: 'audiobook'),
    ];
    expect(annualCompletionCounts(entries, 2026), (
      reading: 3,
      audio: 1,
      total: 4,
    ));
    expect(
      sum(booksCompletedInYear(entries, 2026).map((b) => b.completions)),
      4,
    );
    expect(annualCompletionCounts(entries, 2025).total, 1);
  });

  test('reading, listening and overview share threshold, gaps, yesterday and year boundaries', () {
    final days = {
      '2024-12-31': 600000,
      '2025-01-01': 300000,
      '2025-01-02': 299999,
      '2025-01-03': 0,
      '2025-01-04': 300000,
      'invalid': 600000,
      '2025-02-31': 600000,
    };
    final now = DateTime(2025, 1, 5);
    final stats = AudioStats(const [])..days.addAll(days);
    final analysis = ListeningAnalytics(stats, stats, [], 0, 0, {});
    expect(activityStreak(days, now), (current: 1, best: 2));
    expect(readingStreak(days, now), activityStreak(days, now));
    expect(analysis.currentStreak(now), 1);
    expect(stats.longestStreak, 2);
    expect(activityStreak(days, now, year: 2024), (current: 0, best: 1));
    expect(activityStreak(days, now, year: 2025), (current: 1, best: 1));
    expect(activityStreak({'2025-01-05': 3000}, now), (current: 0, best: 0));
    expect(activityStreak({'2026-01-01': 600000}, now), (current: 0, best: 0));
    // UTC civil arithmetic remains consecutive through DST changes.
    expect(
      activityStreak({
        '2025-03-29': 300000,
        '2025-03-30': 300000,
        '2025-03-31': 300000,
      }, DateTime(2025, 4, 1)).current,
      3,
    );
  });

  test(
    'overview = reading + audio = calendar = per-book sums on one database',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      final repo = Repository(db);
      final client = MockClient((_) => throw StateError('No network'));
      final library = LibraryService(repo, client);
      final worker = ReadingStatisticsWorker();
      addTearDown(() async {
        worker.dispose();
        library.dispose();
        client.close();
        await db.close();
      });
      await repo.put('book', 'text', {'title': 'Текст', 'format': 'txt'});
      await repo.put('book', 'sound', {'title': 'Аудио', 'format': 'audio'});
      await library.repository.mutate((entries) async {
        for (final e in [
          card(1, source: 'text'),
          card(2),
          card(3, type: 'audiobook', source: 'sound'),
          card(4, type: 'audiobook'),
        ]) {
          entries[e.item.id] = e;
        }
      });
      await library.loadCached();
      await repo.setMeta(
        'reading-session:native',
        jsonEncode(
          session(
            'native',
            'text',
            '2025-12-31T23:30:00Z',
            '2026-01-01',
            600000,
          ),
        ),
      );
      // File removed, source history retained.
      await repo.setMeta(
        'reading-session:orphan',
        jsonEncode(
          session(
            'orphan',
            'missing',
            '2026-01-02T10:00:00Z',
            '2026-01-02',
            300000,
          ),
        ),
      );
      await repo.put('session', 'manual', {
        'kind': 'reading',
        'bookId': 'text',
        'startedAt': '2026-01-02T11:00:00Z',
        'endedAt': '2026-01-02T11:05:00Z',
        'activeSeconds': 300,
        'offsetMinutes': 180,
      });
      await library.history!.mutate((state) async {
        state['slots'] = {
          'standalone': slot(20, 2),
          'remote': slot(
            21,
            1,
            ms: 420000,
            source: {
              'kind': 'reader',
              'id': 'remote',
              'bookId': 'other-device',
            },
          ),
          'mirror': slot(
            22,
            1,
            ms: 600000,
            source: {'kind': 'reader', 'id': 'native', 'bookId': 'text'},
          ),
          'audio-card': slot(23, 4, type: 'audiobook', ms: 900000),
          'audio-mirror': slot(
            24,
            3,
            type: 'audiobook',
            source: {'kind': 'audio', 'id': 'native-audio', 'bookId': 'sound'},
          ),
          'older': slot(25, 2, day: '2025-12-31', ms: 120000),
          'deleted': slot(26, 2)..['value']['deleted'] = true,
        };
      });
      final nativeEvent = audio(
        'sound',
        '2025-12-31T23:30:00Z',
        '2026-01-01',
        1200000,
      );
      await AudioJournal(repo).put('audio_event', 'native-audio', nativeEvent);
      await AudioJournal(repo).put('audio_event', 'deleted-audio', nativeEvent);
      await AudioJournal(repo).deleteEvent('deleted-audio');
      await repo.put('session', 'deleted-manual', {
        'kind': 'reading',
        'bookId': 'text',
        'startedAt': '2026-01-02T15:00:00Z',
        'endedAt': '2026-01-02T15:30:00Z',
        'activeSeconds': 1800,
      });
      await repo.delete('session', 'deleted-manual');
      final history = await ReadingStatisticsHistory.load(repo);
      final summary = summarizeReadingCalendar({
        'sessions': history.sessions,
        'year': 2026,
      });
      expect(
        sum(summary.days.values),
        2220000,
      ); // native + orphan + manual + card + remote
      expect(summary.days.containsKey('2025-12-31'), false);
      expect(summary.allDays['2025-12-31'], 120000);
      expect(history.titles['missing'], 'Книга без файла');
      final detailed = await worker.analyze({
        'sessions': history.sessions,
        'now': DateTime(2026, 1, 3),
        'startDay': '2026-01-01',
        'endDay': '2027-01-01',
      });
      expect(detailed.total.milliseconds, sum(summary.days.values));
      expect(detailed.total.milliseconds, sum(detailed.total.books.values));
      final native = (await AudioDailyStore(repo).lifetime()).forYear(2026);
      final supplemental = await AudioStatisticsHistory.load(repo);
      final listening = analyzeListening({'events': supplemental.events});
      final audioDetail = analyzeListening({
        'events': [nativeEvent, ...supplemental.events],
        'startDay': '2026-01-01',
        'endDay': '2027-01-01',
      });
      final total = detailed.total.milliseconds + audioDetail.selected.wallMs;
      final calendar = await BookCalendarData.load(
        repository: repo,
        year: 2026,
        reading: [],
        foreignAudio: supplemental.events,
        audioHistory: supplemental,
        readingSummary: summary,
        nativeAudio: native,
        audioSummary: listening,
        readingTitles: history.titles,
        library: library,
      );
      expect(total, 4320000);
      expect(sum(calendar.days.values.map((day) => sum(day.values))), total);
      expect(
        calendar.archiveReading,
        isEmpty,
      ); // shared source is not added twice
      expect(
        sum(native.days.values) + sum(calendar.archiveAudio.values),
        audioDetail.selected.wallMs,
      );
      expect(calendar.books['missing']!.mediaType, 'book');
      expect(
        (await library.repository.entries()).length,
        4,
      ); // views never create archive cards
    },
  );

  test('journal includes current text/audio without adding them to the archive or mirroring twice', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final repo = Repository(db);
    final client = MockClient((_) => throw StateError('No network'));
    final library = LibraryService(repo, client);
    addTearDown(() async {
      library.dispose();
      client.close();
      await db.close();
    });
    for (final (id, format) in [
      ('current-text', 'txt'),
      ('current-audio', 'audio'),
      ('archived', 'txt'),
    ]) {
      await repo.put('book', id, {'title': id, 'format': format});
    }
    await library.repository.mutate((entries) async {
      entries[cardId(1)] = card(1, source: 'archived');
    });
    await library.loadCached();
    for (final id in ['current-text', 'archived']) {
      await repo.setMeta(
        'reading-session:$id',
        jsonEncode(
          session(id, id, '2026-11-05T10:00:00Z', '2026-11-05', 600000),
        ),
      );
    }
    await AudioJournal(repo).put(
      'audio_event',
      'current',
      audio('current-audio', '2026-11-05T10:00:00Z', '2026-11-05', 900000),
    );
    final journal = await JournalDays.outsideArchive(library);
    expect(journal.slots.map((s) => s['nativeBookId']).toSet(), {
      'current-text',
      'current-audio',
    });
    expect(
      sum(journal.slots.map((s) => s['value']['durationMs'] as int)),
      1500000,
    );
    expect(journal.titles['source:current-text'], 'current-text');
    expect((await library.repository.entries()).length, 1);
    expect(await repo.meta('obsidian-activity:personal'), isNull);
  });

  test('midnight rounding conserves every millisecond', () {
    final totals = ReadingTotals();
    totals.add(
      'book',
      DateTime(2026, 1, 1, 23, 59),
      DateTime(2026, 1, 3, 0, 1),
      17,
    );
    expect(sum(totals.days.values), totals.milliseconds);
  });

  test('periods use calendar days and charts retain the final partial day', () {
    expect(
      statisticsPeriodStart(DateTime(2026, 1, 4, 23), 7),
      DateTime(2025, 12, 29),
    );
    final window = statisticsChartWindow(
      DateTime(2026, 4, 1),
      period: -1,
      start: DateTime(2026, 1, 1, 15),
      end: DateTime(2026, 3, 5, 14),
    );
    expect(window.days, hasLength(60));
    expect(window.days.last, DateTime(2026, 3, 5));
    expect(window.limited, true);
    expect(
      statisticsChartWindow(
        DateTime(2026, 4, 1),
        period: -1,
        start: DateTime(2026, 3, 1),
        end: DateTime(2026, 3, 5),
      ).days.last,
      DateTime(2026, 3, 4),
    );
  });
}
