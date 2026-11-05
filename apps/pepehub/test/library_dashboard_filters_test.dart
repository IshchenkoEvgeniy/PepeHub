import 'dart:convert';
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
import 'package:pepehub/library/library_features.dart';
import 'package:pepehub/library/library_service.dart';
import 'package:pepehub/library/models.dart';
import 'package:pepehub/library/personal_library.dart';
import 'package:pepehub/library/reading_insights.dart';
import 'package:pepehub/ui/app_theme.dart';
import 'package:pepehub/ui/obsidian_library_dashboard.dart';
import 'package:pepehub/ui/shelf_components.dart';

import 'video_player_tools_widget_test.dart' show ready;

int dateReads = 0;

class _TestLibrary extends LibraryService {
  _TestLibrary(super.local, super.client);
  void replaceEntries(List<LibraryEntry> value) {
    entries = value;
    notifyListeners();
  }
}

class _CountedItem extends ObsidianLibraryItem {
  _CountedItem(String id, String type, Map<String, dynamic> data)
    : super(
        id: id,
        path: '',
        collectionId: type,
        mediaType: type,
        fields: personalLibraryFields,
        values: data,
      );
  @override
  dynamic value(String field) {
    if (field == 'endDate') dateReads++;
    return super.value(field);
  }
}

void main() {
  late AppDatabase db;
  late Repository repo;
  late _TestLibrary library;
  late MockClient client;
  final year = DateTime.now().year;

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
    db = AppDatabase(NativeDatabase.memory());
    repo = Repository(db);
    client = MockClient((_) => throw StateError('Offline'));
    library = _TestLibrary(repo, client);
    library.entries = [
      entry(
        'one',
        values: {
          'endDate': '01.01.$year',
          'rating': '4,50',
          'rereadCount': 2,
          'pepehub_collections': ['Полка'],
          'pepehub_favorite': true,
        },
      ),
      entry(
        'two',
        type: 'audiobook',
        values: {
          'endDate': '$year-02-03',
          'rating': 8,
          'pepehub_collections': ['Полка'],
        },
      ),
      entry('old', values: {'endDate': '${year - 1}-01-01', 'rating': 9}),
      entry('paused', values: {'status': 'paused', 'rating': 6}),
      entry('abandoned', values: {'status': 'abandoned'}),
      entry(
        'unread',
        type: 'audiobook',
        values: {'status': 'unread', 'series': 'Серия'},
      ),
      entry(
        'hidden',
        type: 'audiobook',
        values: {
          'pepehub_hidden': true,
          'endDate': '$year-03-04',
          'rating': 10,
          'pepehub_collections': ['Скрытая'],
        },
      ),
    ];
  });
  tearDown(() async {
    library.dispose();
    client.close();
    await db.close();
  });

  Future<void> mount(
    WidgetTester tester, {
    double width = 390,
    GlobalKey? boundary,
  }) async {
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.data(Brightness.dark),
        home: RepaintBoundary(
          key: boundary,
          child: ObsidianLibraryPage(
            service: library,
            navigation: ShelfNavigation(
              current: PepeSection.library,
              onSelect: (_) {},
              onSettings: () {},
            ),
            onSettings: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String key, String value) async {
    tester
        .widget<DropdownButtonFormField<String>>(find.byKey(ValueKey(key)))
        .onChanged!(value);
    await tester.pumpAndSettle();
  }

  Future<void> removeFilter(WidgetTester tester, String key) => tap(
    tester,
    find.descendant(
      of: find.byKey(ValueKey('library-active-$key')),
      matching: find.byTooltip('Убрать фильтр'),
    ),
  );

  testWidgets(
    'all active filters remain visible when folded and reset independently',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester);
      expect(find.text('Показано 6 из 6'), findsOneWidget);
      expect(find.text('$year · книг: 1 · аудиокниг: 1'), findsOneWidget);
      expect(find.text('Завершено · 3'), findsOneWidget);
      await tap(tester, find.byTooltip('Фильтры библиотеки'));
      await choose(tester, 'library-year:all', '$year');
      await choose(tester, 'library-collection:all', 'Полка');
      await choose(tester, 'library-rating:all', '4');
      await choose(tester, 'library-search-scope:all', 'author');
      await tap(tester, find.byKey(const ValueKey('library-favorites-filter')));
      await tap(tester, find.widgetWithText(ChoiceChip, 'Книги'));
      await tester.enterText(
        find.byKey(const ValueKey('library-search')),
        'Автор',
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      await tap(tester, find.byTooltip('Скрыть фильтры'));
      expect(find.text('Показано 1 из 6'), findsOneWidget);
      for (final key in [
        'year',
        'collection',
        'rating',
        'favorites',
        'type',
        'scope',
        'search',
      ]) {
        expect(find.byKey(ValueKey('library-active-$key')), findsOneWidget);
      }
      await removeFilter(tester, 'year');
      expect(find.byKey(const ValueKey('library-active-year')), findsNothing);
      expect(
        find.byKey(const ValueKey('library-active-collection')),
        findsOneWidget,
      );
      await tap(tester, find.byKey(const ValueKey('library-reset-filters')));
      expect(
        find.byKey(const ValueKey('library-active-filters')),
        findsNothing,
      );
      expect(find.text('Показано 6 из 6'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'hidden mode is marked, excludes normal cards and stays out of the annual goal',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester);
      await tap(tester, find.byType(ExpansionTile));
      expect(find.text('$year · завершено 2'), findsOneWidget);
      expect(
        find.text('За всё время · книг: 2 · аудиокниг: 1'),
        findsOneWidget,
      );
      await tap(tester, find.byTooltip('Фильтры библиотеки'));
      await tap(tester, find.byKey(const ValueKey('library-hidden-filter')));
      await tap(tester, find.byTooltip('Скрыть фильтры'));
      expect(
        find.byKey(const ValueKey('library-active-hidden')),
        findsOneWidget,
      );
      expect(find.text('Показано 1 из 1'), findsOneWidget);
      expect(find.text('$year · завершено 2'), findsOneWidget);
      await removeFilter(tester, 'hidden');
      expect(find.text('Показано 6 из 6'), findsOneWidget);
      await tap(tester, find.byTooltip('Действия библиотеки'));
      expect(find.byType(PopupMenuItem<String>), findsNWidgets(6));
      expect(find.text('Только избранные'), findsNothing);
      expect(find.text('Скрытые карточки'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('completion-year filter and picker include every reread year', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    library.entries = [
      entry(
        'reread',
        values: {
          'endDate': '${year - 2}-05-01',
          'pepehub_completions': [
            {'date': '${year - 1}-06-01'},
            {'date': '$year-02-01'},
            {'date': '$year-03-01'},
            {'date': '31.02.${year + 1}'},
          ],
        },
      ),
      entry(
        'unknown',
        values: {
          'endDate': null,
          'pepehub_completions': [
            {'date': 'invalid'},
          ],
        },
      ),
    ];
    expect(annualCompletionCounts(library.entries, year).total, 2);
    await mount(tester);
    await tap(tester, find.byTooltip('Фильтры библиотеки'));
    final picker = tester.widget<DropdownButton<String>>(
      find.descendant(
        of: find.byKey(const ValueKey('library-year:all')),
        matching: find.byWidgetPredicate((w) => w is DropdownButton<String>),
      ),
    );
    expect(
      picker.items!.map((i) => i.value),
      containsAll(['${year - 2}', '${year - 1}', '$year']),
    );
    expect(picker.items!.any((i) => i.value == '${year + 1}'), false);
    await choose(tester, 'library-year:all', '$year');
    expect(find.text('Показано 1 из 2'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('library-work:reread')),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await choose(tester, 'library-year:$year', 'unknown');
    expect(find.text('Показано 1 из 2'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('library-work:unknown')),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('rating filters describe saved values without assuming a scale', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester);
    await tap(tester, find.byTooltip('Фильтры библиотеки'));
    expect(find.text('Значение из карточки'), findsOneWidget);
    expect(find.textContaining('Шкала 0–10'), findsNothing);
    final picker = tester.widget<DropdownButton<String>>(
      find.descendant(
        of: find.byKey(const ValueKey('library-rating:all')),
        matching: find.byWidgetPredicate((w) => w is DropdownButton<String>),
      ),
    );
    expect(
      picker.items!.where((i) => i.value == '4').single.child,
      isA<Text>().having((w) => w.data, 'label', 'От 4'),
    );
    final rated = entry(
      'rating',
      values: {'rating': '4,50', 'endDate': '$year-01-01'},
    );
    expect(booksCompletedInYear([rated], year).single.rating, 4.5);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'sorting retains status and list/grid share ratings and reread badges',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester);
      await tap(
        tester,
        find.byKey(const ValueKey('library-quick-status:paused')),
      );
      expect(find.text('Показано 1 из 6'), findsOneWidget);
      tester
          .widget<DropdownButton<String>>(
            find.byKey(const ValueKey('library-sort')),
          )
          .onChanged!('added');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('library-active-status')),
        findsOneWidget,
      );
      expect(find.text('Показано 1 из 6'), findsOneWidget);
      await removeFilter(tester, 'status');
      await tester.ensureVisible(find.text('Книга one'));
      expect(find.text('4.5'), findsOneWidget);
      expect(find.text('×2'), findsOneWidget);
      await tap(tester, find.byTooltip('Показать карточками'));
      await tester.ensureVisible(find.text('Книга one'));
      expect(find.text('4.5'), findsOneWidget);
      expect(find.text('×2'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('view survives a new page and service with the same repository', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester);
    await tap(tester, find.widgetWithText(ChoiceChip, 'Аудиокниги'));
    tester
        .widget<DropdownButton<String>>(
          find.byKey(const ValueKey('library-sort')),
        )
        .onChanged!('started');
    await tester.pumpAndSettle();
    await tap(tester, find.byTooltip('По убыванию'));
    await tap(tester, find.byTooltip('Показать карточками'));
    await tester.runAsync(() async {
      for (var i = 0; i < 30; i++) {
        final raw = await repo.meta('library-view-v1');
        if (raw != null && jsonDecode(raw)['grid'] == true) return;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      fail('View preferences were not saved');
    });
    final saved = jsonDecode(
      (await tester.runAsync<String?>(() => repo.meta('library-view-v1')))!,
    );
    expect(saved, {
      'grid': true,
      'sort': 'started',
      'descending': false,
      'type': 'audiobook',
    });
    final entries = library.entries;
    await tester.pumpWidget(const SizedBox.shrink());
    library.dispose();
    library = _TestLibrary(repo, client)..entries = entries;
    await mount(tester);
    await ready(
      tester,
      () => find.byTooltip('Показать списком').evaluate().isNotEmpty,
    );
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Аудиокниги'))
          .selected,
      isTrue,
    );
    expect(
      tester
          .widget<DropdownButton<String>>(
            find.byKey(const ValueKey('library-sort')),
          )
          .value,
      'started',
    );
    expect(find.byTooltip('По возрастанию'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('start-date sorting and rating normalization use the same values as filters and labels', () {
    final known = entry(
      'known',
      values: {'startDate': '02.01.$year', 'rating': '4,50'},
    );
    final later = entry(
      'later',
      values: {'startDate': '$year-02-01', 'rating': 8.0},
    );
    final unknown = entry('unknown');
    final entries = [unknown, later, known];
    entries.sort((a, b) => compareLibraryEntries(a, b, 'started'));
    expect(entries.map((e) => e.item.id), ['known', 'later', 'unknown']);
    entries.sort(
      (a, b) => compareLibraryEntries(a, b, 'started', descending: true),
    );
    expect(entries.map((e) => e.item.id), ['later', 'known', 'unknown']);
    expect(libraryRatingLabel(known.item), '★ 4.5');
    expect(libraryRatingLabel(later.item), '★ 8');
    expect(libraryRatingLabel(unknown.item), '—');
  });

  testWidgets(
    '1000 mixed cards reuse catalog facets when selecting rows and invalidate on changes',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      library.entries = [
        for (var i = 0; i < 1000; i++)
          LibraryEntry(
            _CountedItem('$i', i.isEven ? 'book' : 'audiobook', {
              'title': 'Книга ${i.toString().padLeft(4, '0')}',
              'status': 'finished',
              'endDate': '$year-01-01',
              'pepehub_collections': ['Полка ${i % 10}'],
            }),
          ),
      ];
      await mount(tester);
      await tap(tester, find.byTooltip('Фильтры библиотеки'));
      dateReads = 0;
      await tap(tester, find.byTooltip('Выбрать несколько книг'));
      expect(
        dateReads,
        0,
        reason: 'Selecting must not rescan all completion dates',
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('library-work:0')),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tap(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('library-work:0')),
          matching: find.byType(Checkbox),
        ),
      );
      expect(dateReads, 0);
      final before = library.entries;
      library.replaceEntries([
        ...before,
        entry(
          'new',
          values: {
            'endDate': '${year - 2}-01-01',
            'pepehub_collections': ['Новая'],
          },
        ),
      ]);
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.text('Показано 1001 из 1001'), findsOneWidget);
      final collections = tester.widget<DropdownButton<String>>(
        find.descendant(
          of: find.byKey(const ValueKey('library-collection:all')),
          matching: find.byWidgetPredicate((w) => w is DropdownButton<String>),
        ),
      );
      expect(collections.items!.any((e) => e.value == 'Новая'), isTrue);
      final years = tester.widget<DropdownButton<String>>(
        find.descendant(
          of: find.byKey(const ValueKey('library-year:all')),
          matching: find.byWidgetPredicate((w) => w is DropdownButton<String>),
        ),
      );
      expect(years.items!.any((e) => e.value == '${year - 2}'), isTrue);
      expect(dateReads, greaterThanOrEqualTo(1000));
      expect(find.byType(Checkbox).evaluate().length, lessThan(30));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final width in [390.0, 768.0, 1440.0]) {
    testWidgets('expanded filters fit width $width', (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        for (final family in ['Onest', 'Oswald', 'CormorantGaramond']) {
          await (FontLoader(family)..addFont(
                File('assets/fonts/$family.ttf')
                    .readAsBytes()
                    .then(ByteData.sublistView),
              ))
              .load();
        }
        await (FontLoader('MaterialIcons')..addFont(
              File(
                '../../.tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
              ).readAsBytes().then(ByteData.sublistView),
            ))
            .load();
      });
      final boundary = GlobalKey();
      await mount(tester, width: width, boundary: boundary);
      await tap(tester, find.byTooltip('Фильтры библиотеки'));
      final status = tester.getTopLeft(
        find.byKey(const ValueKey('library-status:all')),
      );
      final collection = tester.getTopLeft(
        find.byKey(const ValueKey('library-collection:all')),
      );
      final completionYear = tester.getTopLeft(
        find.byKey(const ValueKey('library-year:all')),
      );
      if (width >= 768) {
        expect(status.dy, collection.dy);
        expect(status.dy, completionYear.dy);
      } else {
        expect(collection.dy, greaterThan(status.dy));
      }
      expect(tester.takeException(), isNull);
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(0);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        await File('build/library-filters-${width.toInt()}.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
      });
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
