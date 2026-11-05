import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/activity_store.dart';
import 'package:pepehub/library/library_repository.dart';
import 'package:pepehub/library/personal_library.dart';
import 'package:pepehub/library/reading_insights.dart';
import 'package:pepehub/reader/reading_activity.dart';
import 'package:pepehub/reader/reading_statistics_data.dart';
import 'package:pepehub/reader/reading_statistics_history.dart';
import 'package:pepehub/audio/audio_journal.dart';
import 'package:pepehub/audio/audio_daily_totals.dart';
import 'package:pepehub/audio/audio_statistics_history.dart';
import 'package:pepehub/statistics/annual_summary.dart';
import 'package:pepehub/statistics/statistics_exchange.dart';
import 'package:pepehub/statistics/portable_history.dart';
import 'package:pepehub/ui/year_review_page.dart';

import 'statistics_consistency_test.dart'
    show card, cardId, session, audio, slot;

Future<int> readingMs(Repository repo) async =>
    readingTotals((await ReadingStatisticsHistory.load(repo)).sessions)
        .milliseconds;
Future<int> audioMs(Repository repo) async =>
    (await AudioDailyStore(
      repo,
    ).lifetime()).days.values.fold<int>(0, (a, b) => a + b) +
    AudioStats((await AudioStatisticsHistory.load(repo)).events).wallMs;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'reading compares equal rolling/calendar and precise custom periods',
    () async {
      final worker = ReadingStatisticsWorker();
      addTearDown(worker.dispose);
      final rows = [
        session('old', 'text', '2026-01-03T10:00:00Z', '2026-01-03', 1800000),
        session('new', 'text', '2026-01-10T10:00:00Z', '2026-01-10', 3600000),
      ];
      var data = await worker.analyze({
        'sessions': rows,
        'now': DateTime(2026, 1, 14),
        'startDay': '2026-01-08',
        'endDay': '2026-01-15',
      });
      expect(data.total.milliseconds, 3600000);
      expect(data.previousPeriod!.milliseconds, 1800000);
      expect(data.previousPeriod!.sessions, 1);
      data = await worker.analyze({
        'now': DateTime(2026, 1, 14),
        'start': DateTime.utc(2026, 1, 10, 10, 30),
        'end': DateTime.utc(2026, 1, 10, 11),
      });
      expect(data.total.milliseconds, 1800000);
      expect(data.previousPeriod!.milliseconds, 1800000);
      expect(
        (await worker.analyze({'now': DateTime(2026, 1, 14)})).previousPeriod,
        isNull,
      );
    },
  );

  AnnualSummary summary() {
    final a = card(1)
      ..item.values.addAll({
        'genre': ['Фантастика', 'фантастика'],
        'author': ['Автор', 'Другой автор'],
        'series': 'Серия',
        'rating': '4,5',
        'pepehub_completions': [
          {'date': '2026-01-01'},
          {'date': '2026-02-01'},
        ],
      });
    final b = card(2, type: 'audiobook')
      ..item.values.addAll({
        'genre': ['Фантастика'],
        'author': ['Автор'],
        'rating': 5,
      });
    return AnnualSummary(
      year: 2026,
      scope: 'all',
      entries: [a, b],
      readingDays: {'2026-01-01': 300000, '2026-01-02': 1000},
      audioDays: {'2026-01-02': 1500000},
      audioActivityDays: {'2026-01-02': 600000},
      bookTimes: {'a': 300000},
      titles: {'a': 'Книга'},
    );
  }

  test('annual groups deduplicate labels; rereads, best books and real-day records stay distinct', () {
    final data = summary();
    expect(data.books.length, 2);
    expect(data.completions, 3);
    expect(data.favoriteGenre!.books, 2);
    expect(data.favoriteGenre!.completions, 3);
    expect(annualCategories(data.books, 'author').first.books, 2);
    expect(
      annualCategories(data.books, 'series').map((c) => c.label),
      contains('Без серии'),
    );
    expect(data.bestBooks.first.rating, 5);
    expect(
      data.longestDay!.value,
      601000,
    ); // The manual estimate is not a record.
    expect(data.bestStreak(DateTime(2026, 1, 3)), 2);
  });
  testWidgets('year review exports a full-size PNG independent of viewport', (
    tester,
  ) async {
    final data = summary();
    final bytes = await tester.runAsync(() async {
      await (FontLoader('Onest')..addFont(
            File('assets/fonts/Onest.ttf')
                .readAsBytes()
                .then(ByteData.sublistView),
          ))
          .load();
      final bytes = await renderAnnualSummaryPng(data, DateTime(2026, 12, 31));
      final file = File('build/ui-review/year-review.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
      return bytes;
    });
    expect(bytes!.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 1080);
      expect(frame.image.height, greaterThan(1000));
      frame.image.dispose();
      codec.dispose();
    });
    await tester.pumpWidget(MaterialApp(home: YearReviewPage(summary: data)));
    await tester.pump();
    expect(find.byKey(const ValueKey('year-review-export')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    '1000 text and 1000 audio categories build only visible rows on a narrow screen',
    (tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final books = booksCompletedInYear([
        for (var i = 0; i < 2000; i++)
          card(i, type: i < 1000 ? 'book' : 'audiobook')
            ..item.values['genre'] = 'Жанр $i',
      ], 2026);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: AnnualCategoryPanel(
                title: 'Жанры',
                field: 'genre',
                books: books,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Все 2000'));
      await tester.pumpAndSettle();
      expect(find.byType(ListTile).evaluate().length, lessThan(40));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('one export round-trips reading, audio, rereads and detached cards without auto-adding a library', () async {
    final sourceDb = AppDatabase(NativeDatabase.memory()),
        targetDb = AppDatabase(NativeDatabase.memory());
    final source = Repository(sourceDb), target = Repository(targetDb);
    addTearDown(() async {
      await sourceDb.close();
      await targetDb.close();
    });
    await source.put('book', 'text', {'title': 'Текст', 'format': 'txt'});
    await source.put('book', 'sound', {'title': 'Аудио', 'format': 'audio'});
    await source.setMeta(
      'reading-session:native',
      jsonEncode(
        session('native', 'text', '2026-01-01T10:00:00Z', '2026-01-01', 600000),
      ),
    );
    await source.setMeta('reading-daily-goal', '30');
    await source.setMeta(
      'reading-plan:text',
      jsonEncode({'dailyMinutes': 20, 'targetPercent': 100}),
    );
    await AudioJournal(source).put(
      'audio_event',
      'listen',
      audio('sound', '2026-01-01T10:00:00Z', '2026-01-01', 900000),
    );
    await source.put('session', 'manual', {
      'bookId': 'text',
      'kind': 'reading',
      'startedAt': '2026-01-02T10:00:00Z',
      'endedAt': '2026-01-02T10:05:00Z',
      'activeSeconds': 300,
    });
    final catalog = LibraryRepository(
      source,
      personalLibraryNamespace,
      storageKey: personalLibraryKey,
    );
    await catalog.mutate((entries) async {
      entries[cardId(1)] = card(1);
      entries[cardId(2)] = card(2, type: 'audiobook');
      entries[cardId(3)] = card(3, source: 'text');
    });
    await ActivityStore(source, personalLibraryNamespace).mutate((state) async {
      state['slots'] = {
        'reading': slot(20, 1, ms: 120000),
        'audio': slot(21, 2, type: 'audiobook', ms: 180000),
        'mirror': slot(
          22,
          3,
          ms: 600000,
          source: {'kind': 'reader', 'id': 'native', 'bookId': 'text'},
        ),
        'deleted': slot(23, 1)..['value']['deleted'] = true,
      };
    });
    final beforeReading = await readingMs(source),
        beforeAudio = await audioMs(source);
    final exchange = StatisticsExchange(target);
    final data = await exchange.decode(
      await StatisticsExchange(source).exportJson(),
    );
    expect(
      (data['activity'] as Map).values.any(
        (v) => v['value']['deleted'] == true,
      ),
      true,
    );
    final preview = await exchange.importData(data);
    expect(preview.added, greaterThan(0));
    expect(
      await target.meta('reading-session:native'),
      isNull,
    ); // Preview never writes.
    await exchange.importData(data, apply: true);
    expect(await readingMs(target), beforeReading);
    expect(await audioMs(target), beforeAudio);
    expect(await target.meta('reading-plan:text'), isNotNull);
    expect(
      await LibraryRepository(
        target,
        personalLibraryNamespace,
        storageKey: personalLibraryKey,
      ).entries(),
      isEmpty,
    );
    expect((await statisticsEntries(target, [])).length, 3);
    final repeated = await exchange.importData(data, apply: true);
    expect(repeated.added, 0);
    expect(repeated.conflicts, 0);
    expect(await readingMs(target), beforeReading);
    // Re-import into the source does not count the canonical journal twice.
    await StatisticsExchange(source).importData(data, apply: true);
    expect(await readingMs(source), beforeReading);
    expect(await audioMs(source), beforeAudio);
    // A local tombstone takes precedence over the earlier portable snapshot.
    await ActivityStore(source, personalLibraryNamespace).mutate((state) async {
      state['slots']['reading']['value']['deleted'] = true;
    });
    expect(await readingMs(source), beforeReading - 120000);
    await catalog.mutate((entries) async {
      entries[cardId(1)]!.item.values['pepehub_deleted_at'] = '2026-11-05';
    });
    expect(
      (await statisticsEntries(
        source,
        [],
      )).where((e) => e.item.id == cardId(1)),
      isEmpty,
    );
    data['metadata']['reading-daily-goal'] = '45';
    expect((await exchange.importData(data, apply: true)).conflicts, 1);
    expect(await target.meta('reading-daily-goal'), '30');
    data['metadata']['library-catalog-v1'] = '{}';
    await expectLater(
      exchange.importData(data, apply: true),
      throwsFormatException,
    );
    expect(await target.meta('library-catalog-v1'), isNull);
    data['metadata'].remove('library-catalog-v1');
    data['records'][0]['payload']['offsetMinutes'] = 'bad';
    await expectLater(
      exchange.importData(data, apply: true),
      throwsFormatException,
    );
  });

  test('import maps physical books and tracks by content hash', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final repo = Repository(db);
    addTearDown(db.close);
    final hash = 'a' * 64;
    await repo.put('book', 'local', {'title': 'Local', 'format': 'audio'});
    await db.customStatement(
      'INSERT INTO local_assets(id,book_id,filename,path,sha256,bytes) VALUES(?,?,?,?,?,?)',
      ['local-track', 'local', 'file.mp3', 'missing.mp3', hash, 1],
    );
    final exchange = StatisticsExchange(repo);
    final data = {
      'format': 'pepehub-complete-statistics',
      'version': 1,
      'metadata': <String, dynamic>{},
      'records': [
        {
          'id': 'foreign-event',
          'type': 'audio_event',
          'deleted': false,
          'payload': {
            ...audio('foreign', '2026-01-01T10:00:00Z', '2026-01-01', 300000),
            'trackId': 'foreign-track',
          },
        },
      ],
      'activity': <String, dynamic>{},
      'works': <String, dynamic>{},
      'books': {
        'foreign': {'title': 'Remote', 'hash': hash},
      },
      'tracks': {'foreign-track': hash},
    };
    await exchange.importData(data, apply: true);
    expect((await repo.record('foreign-event'))!.payload!['bookId'], 'local');
    expect(
      (await repo.record('foreign-event'))!.payload!['trackId'],
      'local-track',
    );
    expect((await exchange.importData(data, apply: true)).added, 0);
    final again = await exchange.decode(await exchange.exportJson());
    expect(again['tracks']['local-track'], hash);
  });
}
