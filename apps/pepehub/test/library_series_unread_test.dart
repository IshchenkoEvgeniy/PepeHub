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
import 'package:pepehub/ui/app_theme.dart';
import 'package:pepehub/ui/library_groups_page.dart';
import 'package:pepehub/ui/library_batch_actions.dart';
import 'package:pepehub/library/library_backup.dart';
import 'package:pepehub/library/reading_insights.dart';
import 'package:pepehub/ui/library_series_editor_page.dart';
import 'package:pepehub/ui/library_work_page.dart';
import 'package:pepehub/ui/obsidian_library_dashboard.dart';
import 'package:pepehub/ui/obsidian_library_page.dart'
    show LibraryMetadataEditor;
import 'package:pepehub/ui/shelf_components.dart';

import 'library_series_add_test.dart' show volume;
import 'support/flutter_fonts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final font in ['Onest', 'Oswald', 'CormorantGaramond']) {
      await (FontLoader(font)..addFont(
            File('assets/fonts/$font.ttf')
                .readAsBytes()
                .then(ByteData.sublistView),
          ))
          .load();
    }
    await (FontLoader('MaterialIcons')..addFont(
          File(materialIconsFont).readAsBytes().then(ByteData.sublistView),
        ))
        .load();
  });
  late AppDatabase db;
  late LibraryService library;
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    final client = MockClient((_) => throw StateError('No network'));
    library = LibraryService(Repository(db), client);
    addTearDown(client.close);
  });
  tearDown(() async {
    library.dispose();
    await db.close();
  });

  Widget shelf() => MaterialApp(
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
  );

  testWidgets('unread-only mixed series stays visible, searchable and lazy', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    library.entries = [
      for (var i = 0; i < 1000; i++)
        LibraryEntry(
          volume(
            '$i',
            type: i.isEven ? 'book' : 'audiobook',
            values: {
              'title': 'Непрочитанный том ${i.toString().padLeft(4, '0')}',
              'seriesIndex': i + 1,
              'status': 'unread',
            },
          ),
        ),
    ];
    await tester.pumpWidget(shelf());
    await tester.pumpAndSettle();
    final series = find.byKey(const ValueKey('library-series:series-id:cycle'));
    expect(series, findsOneWidget);
    expect(find.textContaining('Завершено: 0 из 1000'), findsOneWidget);
    expect(library.completed, isEmpty);
    expect(library.visibleEntries, isEmpty);
    await tester.enterText(
      find.byKey(const ValueKey('library-search')),
      '0999',
    );
    await tester.pumpAndSettle();
    expect(series, findsOneWidget);
    await tester.tap(find.byTooltip('Развернуть серию'));
    await tester.pumpAndSettle();
    expect(find.text('Не прослушана'), findsOneWidget);
    await tester.tap(find.byTooltip('Очистить поиск'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Аудиокниги'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Книг: 0 · Аудиокниг: 500'), findsOneWidget);
    final rows = find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key as ValueKey<String>).value.startsWith('library-work:'),
    );
    expect(rows.evaluate().length, inInclusiveRange(1, 25));
    await tester.tap(find.byTooltip('Фильтры библиотеки'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('library-status:all')),
    );
    await tester.tap(find.byKey(const ValueKey('library-status:all')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Не прослушана').last);
    await tester.pumpAndSettle();
    expect(series, findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const ValueKey('library-group-series')),
    );
    await tester.tap(find.byKey(const ValueKey('library-group-series')));
    await tester.pumpAndSettle();
    expect(series, findsNothing);
    expect(rows, findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final save in [false, true]) {
    test(
      'first completion via ${save ? 'editor' : 'quick action'} fills progress without rereads',
      () async {
        await library.addSeries([
          volume(
            'first',
            type: 'audiobook',
            values: {'status': 'unread', 'total': 120, 'progress': 0},
          ),
        ]);
        if (save) {
          final before = library.entries.single.item;
          await library.save(before.id, {
            ...before.values,
            'status': 'finished',
          }, original: before.values);
        } else {
          await library.editCards(['first'], {}, reread: true);
        }
        final after = library.entries.single.item;
        expect(libraryStatus(after), 'finished');
        expect(after.value('progress'), 120);
        expect(libraryRereads(after), 0);
        expect(
          groupLibrarySeries(library.seriesEntries).single.listenedMinutes,
          120,
        );
        expect(
          booksCompletedInYear(
            library.entries,
            DateTime.now().year,
          ).single.completions,
          1,
        );
      },
    );
  }

  for (final type in ['book', 'audiobook', 'mixed', 'standalone']) {
    testWidgets(
      'quick $type status menu offers unread for series volumes only',
      (tester) async {
        library.entries = [
          LibraryEntry(
            volume(
              'one',
              type: type == 'audiobook' ? 'audiobook' : 'book',
              values: {if (type == 'standalone') 'series': null},
            ),
          ),
          if (type == 'mixed') LibraryEntry(volume('two', type: 'audiobook')),
        ];
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => libraryBatchAction(
                    context,
                    library,
                    library.entries.map((e) => e.item.id),
                    'status',
                  ),
                  child: const Text('Статус'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Статус'));
        await tester.pumpAndSettle();
        if (type == 'standalone') {
          expect(find.textContaining('Не прочитана'), findsNothing);
          expect(find.textContaining('Не прослушана'), findsNothing);
        } else {
          expect(
            find.text(
              seriesVolumeStatuses(type == 'mixed' ? 'all' : type)['unread']!,
            ),
            findsOneWidget,
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  test('backup keeps both unread media types and excludes them from completed statistics', () async {
    final ids = [library.emptyDraft().id, library.emptyDraft(audio: true).id];
    await library.addSeries([
      volume(ids[0], values: {'status': 'unread'}),
      volume(
        ids[1],
        type: 'audiobook',
        values: {'status': 'unread', 'seriesIndex': 2},
      ),
    ]);
    final backup = LibraryBackup(library);
    final preview = backup.inspect(await backup.create());
    expect(preview.cards.values.map((e) => libraryStatus(e.item)), [
      'unread',
      'unread',
    ]);
    expect(preview.cards.values.map((e) => e.item.mediaType).toSet(), {
      'book',
      'audiobook',
    });
    expect(
      booksCompletedInYear(preview.cards.values, DateTime.now().year),
      isEmpty,
    );
  });

  test('unstarted volumes persist outside archive, detect duplicates and become outcomes', () async {
    final first = volume(
      'first',
      type: 'audiobook',
      values: {'total': 90, 'progress': 90},
    );
    final unread = volume(
      'unread',
      values: {
        'seriesIndex': 2,
        'status': 'unread',
        'cover': 'keep-cover',
        'notes': 'Сохранить заметку',
      },
    );
    await library.addSeries([first]);
    await library.addSeries([unread], existingSeriesKey: 'series-id:cycle');
    await library.loadCached();
    expect(library.visibleEntries.map((e) => e.item.id), ['first']);
    expect(library.completed, hasLength(1));
    expect(library.inbox, isEmpty);
    expect(library.seriesEntries, hasLength(2));
    expect(
      library.unreadSeriesEntries.single.item.value('cover'),
      'keep-cover',
    );
    expect(
      groupLibrarySeries(library.seriesEntries).single.listenedMinutes,
      90,
    );
    await expectLater(
      library.addSeries([
        volume('duplicate', values: {'seriesIndex': 2, 'status': 'unread'}),
      ], existingSeriesKey: 'series-id:cycle'),
      throwsStateError,
    );
    await library.deleteCards(['unread']);
    expect(library.trash.single.item.id, 'unread');
    expect(library.seriesEntries, hasLength(1));
    await library.restoreCard('unread');
    expect(library.unreadSeriesEntries, hasLength(1));
    final saved = library.unreadSeriesEntries.single.item;
    await expectLater(
      library.save('unread', {
        ...saved.values,
        'series': '',
      }, original: saved.values),
      throwsArgumentError,
    );
    await library.editCards(['unread'], {'status': 'finished'});
    expect(library.completed, hasLength(2));
    expect(library.unreadSeriesEntries, isEmpty);
    final finished = library.entries
        .singleWhere((e) => e.item.id == 'unread')
        .item;
    expect(finished.value('endDate'), isNotEmpty);
    expect(finished.value('cover'), 'keep-cover');
    expect(finished.value('notes'), 'Сохранить заметку');
    expect(await library.local.records('audio_event'), isEmpty);
    expect(await library.local.records('session'), isEmpty);
  });

  test(
    'listening sum handles partial volumes, hours, missing and invalid values',
    () {
      final group = LibrarySeriesGroup('Серия', 'cycle', [
        LibraryEntry(
          volume(
            'minutes',
            type: 'audiobook',
            values: {'status': 'paused', 'progress': 30.5, 'total': 90},
          ),
        ),
        LibraryEntry(
          volume(
            'hours',
            type: 'audiobook',
            values: {'unit': 'hours', 'total': 2},
          ),
        ),
        LibraryEntry(
          volume(
            'unread',
            type: 'audiobook',
            values: {'status': 'unread', 'progress': 999, 'total': 999},
          ),
        ),
        LibraryEntry(volume('pages', values: {'progress': 500})),
        LibraryEntry(volume('unknown', type: 'audiobook')),
        LibraryEntry(
          volume('invalid', type: 'audiobook', values: {'progress': 'NaN'}),
        ),
        LibraryEntry(
          volume(
            'percent',
            type: 'audiobook',
            values: {'unit': 'percent', 'progress': 50, 'total': 100},
          ),
        ),
      ]);
      expect(group.listenedMinutes, 150.5);
      expect(metadataProgress(group.entries[2].item), 0);
      expect(metadataSeriesListeningLabel(group), 'Прослушано: 2 ч 30 мин');
    },
  );

  for (final type in ['book', 'audiobook']) {
    testWidgets(
      '$type series editor preserves unread status through individual edits',
      (tester) async {
        tester.view.physicalSize = const Size(390, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(home: LibrarySeriesEditorPage(library: library)),
        );
        await tester.enterText(
          find.byKey(const ValueKey('series-name')),
          'Серия',
        );
        if (type == 'audiobook') {
          await tester.tap(find.byKey(const ValueKey('series-type')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Аудиокниги').last);
          await tester.pumpAndSettle();
        }
        final label = seriesVolumeStatuses(type)['unread']!;
        await tester.ensureVisible(find.byKey(const ValueKey('series-status')));
        await tester.tap(find.byKey(const ValueKey('series-status')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('series-titles')),
          'Новый том',
        );
        await tester.tap(find.byKey(const ValueKey('series-primary')));
        await tester.pumpAndSettle();
        expect(find.textContaining('· $label'), findsOneWidget);
        await tester.tap(find.byTooltip('Изменить том'));
        await tester.pumpAndSettle();
        final editor = tester.widget<LibraryMetadataEditor>(
          find.byType(LibraryMetadataEditor),
        );
        expect(editor.item.value('status'), 'unread');
        expect(find.text(label), findsOneWidget);
        await tester.tap(find.text('Применить к тому'));
        await tester.pumpAndSettle();
        expect(find.textContaining('· $label'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final grid in [false, true]) {
    testWidgets(
      'series ${grid ? 'grid' : 'list'} shows covers and total, keeps unread nested',
      (tester) async {
        tester.view.physicalSize = const Size(390, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        library.entries = [
          LibraryEntry(
            volume(
              'one',
              type: 'audiobook',
              values: {'progress': 90, 'total': 90},
            ),
          ),
          LibraryEntry(
            volume(
              'two',
              type: 'audiobook',
              values: {
                'seriesIndex': 2,
                'status': 'paused',
                'progress': 30,
                'total': 90,
              },
            ),
          ),
          LibraryEntry(
            volume('three', values: {'seriesIndex': 3, 'status': 'unread'}),
          ),
        ];
        final boundary = GlobalKey();
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
        if (grid) {
          await tester.tap(find.byTooltip('Показать карточками'));
          await tester.pumpAndSettle();
        }
        expect(find.byTooltip('Добавить тома в серию'), findsNothing);
        // The grid card shows the count and listened time on one line.
        expect(
          find.textContaining(grid ? 'Завершено 1 из 3' : 'Завершено: 1 из 3'),
          findsOneWidget,
        );
        expect(
          find.textContaining(grid ? '2 аудиокниги · 2 ч' : 'Прослушано: 2 ч'),
          findsOneWidget,
        );
        final series = find.byKey(
          const ValueKey('library-series:series-id:cycle'),
        );
        expect(
          find.descendant(of: series, matching: find.byType(ShelfBookCover)),
          findsNWidgets(3),
        );
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          await Directory('build/series-preview').create(recursive: true);
          await File(
            'build/series-preview/unread-${grid ? 'grid' : 'list'}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
        });
        await tester.tap(find.byTooltip('Развернуть серию'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Не прочитана'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('Не прочитана'), findsOneWidget);
        expect(find.text('В планах'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(
          MaterialApp(
            home: LibraryGroupsPage(
              library: library,
              kind: 'series',
              name: 'Архипелаг',
              seriesKey: 'series-id:cycle',
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Добавить тома'), findsOneWidget);
        expect(find.textContaining('Не прочитана · Книга'), findsOneWidget);
        await tester.tap(find.textContaining('Том 3 ·'));
        await tester.pumpAndSettle();
        expect(find.byType(LibraryWorkPage), findsOneWidget);
        expect(find.text('Не прочитана'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
