import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/audio/audio_journal.dart';
import 'package:pepehub/library/book_calendar_data.dart';
import 'package:pepehub/library/library_service.dart';
import 'package:pepehub/library/models.dart';
import 'package:pepehub/library/personal_library.dart';
import 'package:pepehub/library/reading_insights.dart';
import 'package:pepehub/ui/annual_book_statistics.dart';
import 'package:pepehub/ui/app_theme.dart';
import 'package:pepehub/ui/book_calendar.dart';
import 'package:pepehub/ui/activity_page.dart';
import 'package:pepehub/ui/library_work_page.dart';
import 'package:pepehub/ui/statistics_hub_page.dart';
import 'package:pepehub/ui/shelf_components.dart';

import 'video_player_tools_widget_test.dart' show ready;

Map<String, dynamic> slot(
  int i, {
  String item = 'a',
  String day = '2026-10-28',
  int duration = 14000,
  num progress = 0.5,
  bool deleted = false,
}) => {
  'value': {
    'id': '$i',
    'itemId': item,
    'day': day,
    'durationMs': duration,
    'progress': progress,
    'unit': 'minutes',
    'mediaType': 'audiobook',
    'note': '',
    'origin': 'app-audio',
    'deleted': deleted,
  },
};

LibraryEntry card(
  int i, {
  String status = 'finished',
  String? end = '2026-10-28',
}) => LibraryEntry(
  personalLibraryItem('card-$i', i.isEven ? 'book' : 'audiobook', {
    'title': 'Книга $i',
    'status': status,
    'startDate': '2026-09-21T17:56:52.710190Z',
    'endDate': end,
    'rating': i % 11,
    'total': 300,
    'progress': 300,
    'unit': i.isEven ? 'pages' : 'minutes',
    'pepehub_auto_discovered': false,
  }),
);

void main() {
  test('668 fragments become daily totals without losing intervals or mixing books', () {
    final original = [
      for (var i = 0; i < 668; i++) slot(i),
      slot(900, item: 'b'),
      slot(901, day: '2026-10-27'),
      slot(902, deleted: true),
      slot(903, duration: 0, progress: 0),
    ];
    final groups = groupBookActivity(original);
    expect(groups, hasLength(3));
    expect(groups.first.slots, hasLength(668));
    expect(groups.first.durationMs, 668 * 14000);
    expect(groups.first.progress['minutes'], 334);
    expect(original.first['value']['durationMs'], 14000);
    expect(bookActivityTime(14000), '< 1 мин');
    expect(bookDateLabel('2026-09-21T17:56:52.710190Z'), '21.09.2026');
    expect(bookDateLabel(''), 'Не указана');
  });

  test('annual outcomes exclude plans, missing dates and trash; rereads keep one rating vote', () {
    final repeated = card(5);
    repeated.item.values['pepehub_completions'] = [
      {'date': '2025-12-31'},
      {'date': '2026-01-10'},
      {'date': '2026-10-28'},
    ];
    final trash = card(6);
    trash.item.values['pepehub_deleted_at'] = '2026-10-29';
    final entries = [
      card(0),
      card(1),
      card(2, status: 'active'),
      card(3, status: 'planned'),
      card(4, end: null),
      repeated,
      trash,
    ];
    final year = booksCompletedInYear(entries, 2026);
    expect(year, hasLength(3));
    expect(year.singleWhere((b) => b.entry.item.id == 'card-5').completions, 2);
    expect(booksCompletedInYear(entries, 2025), hasLength(1));
    expect(booksCompletedInYear(entries, 2026, scope: 'audio'), hasLength(2));
  });

  test('calendar joins native and standalone history without counting linked mirrors twice', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final repo = Repository(db);
    final client = MockClient((_) => throw StateError('No network'));
    final library = LibraryService(repo, client);
    addTearDown(() async {
      library.dispose();
      client.close();
      await db.close();
    });
    await repo.put('book', 'native', {'title': 'Аудио', 'format': 'audio'});
    await library.repository.mutate((entries) async {
      entries['card-0'] = card(0);
      entries['card-1'] = LibraryEntry(card(1).item, sourceBookId: 'native');
      entries['card-2'] = card(2);
    });
    await library.loadCached();
    await library.history!.mutate((state) async {
      state['slots'] = {
        'a': slot(0, item: 'card-0', duration: 60000),
        'b': slot(1, item: 'card-1', duration: 120000),
        'c': slot(2, item: 'card-0', day: '2025-12-31', duration: 30000),
        'd': slot(3, item: 'card-0', duration: 600000, deleted: true),
      };
    });
    await AudioJournal(repo).put('audio_event', 'listen', {
      'kind': 'listen',
      'bookId': 'native',
      'trackId': 't',
      'positionMs': 0,
      'endMs': 120000,
      'mediaMs': 120000,
      'wallMs': 120000,
      'speed': 1,
      'at': '2026-10-28T12:00:00Z',
      'localDay': '2026-10-28',
      'offsetMinutes': 0,
    });
    final data = await BookCalendarData.load(
      repository: repo,
      year: 2026,
      reading: [],
      foreignAudio: [],
      library: library,
    );
    expect(data.days['2026-10-28']!['native'], 120000);
    expect(data.days['2026-10-28']!['card:card-0'], 60000);
    expect(data.days['2026-10-28']!['card:card-2'], 0);
    expect(data.completedDays['2026-10-28'], contains('card:card-2'));
    expect(data.archiveAudio.values.fold<int>(0, (a, b) => a + b), 60000);
    expect(data.archiveAudioAll['2025-12-31'], 30000);
    expect(data.days.containsKey('2025-12-31'), false);
  });

  for (final width in [360.0, 1100.0]) {
    testWidgets(
      'calendar and annual statistics fit $width and keep 1000 books lazy',
      (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final db = AppDatabase(NativeDatabase.memory());
        final repo = Repository(db);
        final client = MockClient((_) => throw StateError('No network'));
        final library = LibraryService(repo, client)
          ..entries = [for (var i = 0; i < 1000; i++) card(i)];
        addTearDown(() async {
          library.dispose();
          client.close();
          await db.close();
        });
        await tester.runAsync(() async {
          for (final name in [
            'Onest',
            'Oswald',
            'CormorantGaramond',
            'Manrope',
          ]) {
            await (FontLoader(name)..addFont(
                  File('assets/fonts/$name.ttf')
                      .readAsBytes()
                      .then(ByteData.sublistView),
                ))
                .load();
          }
        });
        final data = BookCalendarData();
        for (var i = 0; i < 1000; i++) {
          final entry = library.entries[i];
          data.books['$i'] = CalendarBook(
            '$i',
            entry.item.title,
            entry.item.mediaType,
            entry,
            null,
          );
          data.add('2026-10-28', '$i', 14000);
        }
        final boundary = GlobalKey();
        Future<void> shot(String name) async {
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            image.dispose();
            final file = File('build/ui-review/$name-$width.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
          });
        }

        Widget app(Widget child) => MaterialApp(
          theme: AppTheme.data(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: RepaintBoundary(
            key: boundary,
            child: Scaffold(body: SafeArea(child: child)),
          ),
        );
        await tester.pumpWidget(
          app(
            SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: BookCalendar(
                  year: 2026,
                  scope: 'all',
                  data: data,
                  library: library,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (var month = DateTime.now().month; month < 10; month++) {
          await tester.tap(find.byTooltip('Следующий месяц'));
          await tester.pumpAndSettle();
        }
        for (var month = DateTime.now().month; month > 10; month--) {
          await tester.tap(find.byTooltip('Предыдущий месяц'));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text('28'));
        await tester.pumpAndSettle();
        expect(find.text('Все книги за день · 1000'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await shot('book-calendar');
        await tester.pumpWidget(
          app(
            AnnualBookStatistics(
              repository: repo,
              library: library,
              year: 2026,
              scope: 'all',
              readingDays: const {'2026-10-28': 3600000},
              audioDays: const {'2026-10-28': 7200000},
              onScope: (_) {},
              onYear: (_) {},
            ),
          ),
        );
        await ready(
          tester,
          () => find.text('Завершённые книги по месяцам').evaluate().isNotEmpty,
        );
        await shot('annual-statistics');
        // Jump into the monthly list and ensure only visible cards are built.
        await tester.scrollUntilVisible(
          find.text('Книги за год'),
          400,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.drag(find.byType(ListView), const Offset(0, -500));
        await tester.pumpAndSettle();
        expect(
          find
              .byWidgetPredicate(
                (w) =>
                    w.key is ValueKey<String> &&
                    (w.key as ValueKey<String>).value.startsWith(
                      'annual-book:',
                    ),
              )
              .evaluate()
              .length,
          inInclusiveRange(1, 30),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('hub opens annual tab and journal groups one book by day', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final repo = Repository(db);
    final client = MockClient((_) => throw StateError('No network'));
    final library = LibraryService(repo, client);
    addTearDown(() async {
      library.dispose();
      client.close();
      await db.close();
    });
    await library.repository.mutate((entries) async {
      entries['card-1'] = card(1);
    });
    await library.loadCached();
    await library.history!.mutate((state) async {
      state['slots'] = {
        for (var i = 0; i < 668; i++) '$i': slot(i, item: 'card-1'),
      };
    });
    await tester.pumpWidget(
      MaterialApp(
        home: StatisticsHubPage(
          repository: repo,
          library: library,
          navigation: ShelfNavigation(
            current: PepeSection.statistics,
            onSelect: (_) {},
            onSettings: () {},
          ),
        ),
      ),
    );
    await ready(
      tester,
      () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
    );
    await tester.tap(find.text('Годовая статистика'));
    await tester.pumpAndSettle();
    expect(find.text('Завершённые книги по месяцам'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(
      MaterialApp(
        home: ActivityPage(library: library, itemId: 'card-1'),
      ),
    );
    await ready(tester, () => find.text('По дням').evaluate().isNotEmpty);
    expect(find.text('28.10.2026'), findsOneWidget);
    expect(find.textContaining('668 записей'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryWorkPage(library: library, itemId: 'card-1'),
      ),
    );
    await ready(
      tester,
      () => find.text('Карточка произведения').evaluate().isNotEmpty,
    );
    final list = find.byType(ListView).first;
    await tester.scrollUntilVisible(
      find.text('Начало: 21.09.2026'),
      300,
      scrollable: find
          .descendant(of: list, matching: find.byType(Scrollable))
          .first,
    );
    expect(find.textContaining('T17:56'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
