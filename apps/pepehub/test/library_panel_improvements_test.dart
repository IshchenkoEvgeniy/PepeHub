import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/activity_store.dart';
import 'package:pepehub/library/library_features.dart';
import 'package:pepehub/library/library_service.dart';
import 'package:pepehub/library/models.dart';
import 'package:pepehub/library/personal_library.dart';
import 'package:pepehub/ui/app_theme.dart';
import 'package:pepehub/ui/obsidian_library_dashboard.dart';
import 'package:pepehub/ui/shelf_components.dart';
import 'package:uuid/uuid.dart';

class _TestLibrary extends LibraryService {
  _TestLibrary(super.local, super.client);
}

void main() {
  const uuid = Uuid();
  late AppDatabase db;
  late Repository local;
  late MockClient client;
  final year = DateTime.now().year;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    local = Repository(db);
    client = MockClient((_) => throw StateError('Offline'));
  });
  tearDown(() async {
    client.close();
    await db.close();
  });

  test('every user status is a library status; drafts stay outside', () {
    for (final status in ['active', 'planned', 'paused', 'abandoned']) {
      expect(
        isLibraryArchiveItem(
          personalLibraryItem('x', 'book', {'status': status}),
        ),
        isTrue,
        reason: status,
      );
    }
    expect(
      isLibraryArchiveItem(
        personalLibraryItem('x', 'book', {
          'status': 'active',
          'pepehub_auto_discovered': true,
        }),
      ),
      isFalse,
    );
  });

  test('journal fills only empty dates and reports changed cards', () async {
    final library = LibraryService(local, client);
    addTearDown(library.dispose);
    Future<String> add(Map<String, dynamic> values) async {
      final id = uuid.v4();
      await library.add(
        personalLibraryItem(id, 'audiobook', {
          'title': 'Книга $id',
          'author': ['Автор'],
          ...values,
        }),
        '',
      );
      return id;
    }

    final finished = await add({'status': 'finished'});
    final kept = await add({'status': 'finished', 'startDate': '2026-01-01'});
    final paused = await add({'status': 'paused'});
    final silent = await add({'status': 'finished'});
    // A finished card added today gets today's endDate; clear it as on
    // imported cards.
    for (final id in [finished, kept]) {
      final card = library.entries.firstWhere((e) => e.item.id == id);
      await library.save(id, {
        ...card.item.values,
        'endDate': null,
      }, original: card.item.values);
    }
    var sequence = 0;
    final records = [
      for (final (id, day) in [
        (finished, '2026-03-05'),
        (finished, '2026-03-01'),
        (finished, '2026-03-09'),
        (kept, '2026-02-02'),
        (paused, '2026-04-04'),
      ])
        {
          'entry': ActivityStore.entry(
            id: uuid.v4(),
            itemId: id,
            mediaType: 'audiobook',
            day: day,
            durationMs: 60000,
            progress: 1,
            unit: 'minutes',
            origin: 'obsidian',
          ),
          'revision': 1,
          'sequence': ++sequence,
        },
    ];
    await library.history!.receive(records, sequence);

    final changed = await library.fillDatesFromJournal([
      finished,
      kept,
      paused,
      silent,
    ]);
    expect(changed, 3);
    ObsidianLibraryItem item(String id) =>
        library.entries.firstWhere((e) => e.item.id == id).item;
    expect(item(finished).value('startDate'), '2026-03-01');
    expect(item(finished).value('endDate'), '2026-03-09');
    expect(item(kept).value('startDate'), '2026-01-01');
    expect(item(kept).value('endDate'), '2026-02-02');
    expect(item(paused).value('startDate'), '2026-04-04');
    expect('${item(paused).value('endDate') ?? ''}', isEmpty);
    expect(library.missingDates(item(finished)), isFalse);
    // No journal days: the empty start date stays empty.
    expect(library.missingDates(item(silent)), isTrue);
    expect(await library.fillDatesFromJournal([finished]), 0);
  });

  group('dashboard', () {
    late _TestLibrary library;
    LibraryEntry entry(
      String id, {
      String type = 'book',
      Map<String, dynamic> values = const {},
    }) => LibraryEntry(
      personalLibraryItem(id, type, {
        'title': 'Книга $id',
        'status': 'finished',
        'author': ['Автор'],
        ...values,
      }),
    );

    setUp(() {
      library = _TestLibrary(local, client);
      library.entries = [
        entry(
          'reading',
          values: {'status': 'active', 'progress': 40, 'total': 100},
        ),
        entry(
          'audio',
          type: 'audiobook',
          values: {
            'rating': 7,
            'format': 'Audiobook',
            'endDate': '$year-03-10',
          },
        ),
        entry(
          'v1',
          type: 'audiobook',
          values: {'series': 'Сага', 'seriesIndex': 1, 'rating': 8},
        ),
        entry(
          'v2',
          type: 'audiobook',
          values: {'series': 'Сага', 'seriesIndex': 2, 'status': 'unread'},
        ),
      ];
    });
    tearDown(() {
      library.dispose();
      libraryFilterRequest.value = null;
    });

    Future<void> mount(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.data(Brightness.dark),
          home: ObsidianLibraryPage(
            service: library,
            navigation: ShelfNavigation(
              current: PepeSection.library,
              onSelect: (_) {},
              onSettings: () {},
            ),
            onSettings: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('statuses, continue shelf, panel labels and series panel', (
      tester,
    ) async {
      await mount(tester);
      expect(find.textContaining('Показано '), findsNothing);
      expect(
        find.byKey(const ValueKey('library-quick-status:active')),
        findsOneWidget,
      );
      // No planned or paused cards: their chips are hidden.
      expect(
        find.byKey(const ValueKey('library-quick-status:planned')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('library-quick-status:paused')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('library-continue:reading')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('library-work:audio')));
      await tester.pumpAndSettle();
      expect(find.text('★ 7'), findsOneWidget);
      expect(find.text('Аудиокнига'), findsWidgets);
      expect(find.text('Audiobook'), findsNothing);
      expect(
        find.byKey(const ValueKey('library-detail-status:audio:finished')),
        findsOneWidget,
      );

      final series = find.byKey(const ValueKey('library-series:series:сага'));
      expect(series, findsOneWidget);
      await tester.tap(series);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('library-series-detail:series:сага')),
        findsOneWidget,
      );
      expect(find.text('Завершено 1 из 2'), findsWidgets);
      expect(find.text('Журнал серии'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('library-series-volume:v2')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a statistics month request filters completions', (
      tester,
    ) async {
      libraryFilterRequest.value = (year: year, month: 3);
      await mount(tester);
      expect(libraryFilterRequest.value, isNull);
      expect(find.byKey(const ValueKey('library-active-year')), findsOneWidget);
      expect(find.text('Показано 1 из 4'), findsOneWidget);
      expect(find.byKey(const ValueKey('library-work:audio')), findsOneWidget);
      libraryFilterRequest.value = (year: year, month: 1);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('library-work:audio')), findsNothing);
    });
  });
}
