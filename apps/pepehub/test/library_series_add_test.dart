import 'dart:async';
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
import 'package:pepehub/library/series_draft.dart';
import 'package:pepehub/ui/app_theme.dart';
import 'package:pepehub/ui/library_series_editor_page.dart';
import 'package:pepehub/ui/library_groups_page.dart';
import 'package:pepehub/ui/obsidian_library_page.dart';
import 'package:pepehub/ui/shelf_components.dart';

import 'video_player_tools_widget_test.dart' show ready;

ObsidianLibraryItem volume(
  String id, {
  String type = 'book',
  String seriesId = 'cycle',
  Map<String, dynamic> values = const {},
}) => personalLibraryItem(id, type, {
  'title': 'Том $id',
  'author': ['Автор'],
  'series': 'Архипелаг',
  'seriesIndex': 1,
  'pepehub_series_id': seriesId,
  'status': 'finished',
  'unit': type == 'audiobook' ? 'minutes' : 'pages',
  ...values,
});

void main() {
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

  test('pasted titles preserve numeric titles and understand decimal volume numbers', () {
    expect(
      parseSeriesTitles(
        '\r\n0.5. Предыстория\r\n1) Северный путь\n\n- Ледяной берег\n1984',
      ),
      [
        (title: 'Предыстория', index: 0.5),
        (title: 'Северный путь', index: 1),
        (title: 'Ледяной берег', index: 2),
        (title: '1984', index: 3),
      ],
    );
    expect(
      parseSeriesTitles(
        'Дальний остров\nВозвращение',
        firstIndex: 4,
      ).map((e) => e.index),
      [4, 5],
    );
    final conflicts = seriesDraftConflicts([
      volume('first'),
      volume('second'),
      volume('audio', type: 'audiobook'),
    ], []);
    expect(conflicts, {'second': 'Номер тома повторяется в этом списке'});
  });

  test('batch saves independent mixed cards with unknown dates and no fabricated sessions', () async {
    await library.addSeries([
      volume('one', values: {'seriesIndex': 0.5}),
      volume(
        'two',
        type: 'audiobook',
        values: {
          'seriesIndex': 1,
          'status': 'paused',
          'progress': 30,
          'total': 120,
        },
      ),
      volume(
        'three',
        values: {'seriesIndex': 2, 'status': 'abandoned', 'rating': 7},
      ),
    ]);
    expect(library.visibleEntries, hasLength(3));
    expect(library.visibleEntries.every((e) => e.sourceBookId == null), isTrue);
    expect(
      library.visibleEntries.every(
        (e) =>
            e.item.value('endDate') == null &&
            e.item.value('startDate') == null,
      ),
      isTrue,
    );
    expect(
      groupLibrarySeries(library.visibleEntries).single.entries
          .map((e) => e.item.id),
      ['one', 'two', 'three'],
    );
    expect(await library.local.records('audio_event'), isEmpty);
    expect(await library.local.records('session'), isEmpty);
    expect(await library.history!.entries(), isEmpty);
    final raw = await library.local.meta(personalLibraryKey);
    for (final invalid in ['planned', 'active']) {
      await expectLater(
        library.addSeries([
          volume('bad', seriesId: 'bad', values: {'status': invalid}),
        ]),
        throwsArgumentError,
      );
      expect(await library.local.meta(personalLibraryKey), raw);
    }
  });

  test(
    'duplicate warnings never overwrite editions, trash, quotes or history',
    () async {
      final old = volume(
        'old',
        values: {
          'title': 'Северный путь',
          'cover': 'pepehub-cover:keep',
          'Custom': {
            'quotes': ['Сохранить'],
          },
        },
      );
      await library.repository.mutate((cards) async {
        cards['old'] = LibraryEntry(old);
      });
      final next = volume(
        'new',
        seriesId: 'new-cycle',
        values: {'title': '  северный   путь  '},
      );
      expect(
        seriesDraftConflicts([
          next,
        ], (await library.repository.entries()).values).keys,
        ['new'],
      );
      await expectLater(library.addSeries([next]), throwsStateError);
      expect(
        (await library.repository.entries())['old']!.item.toJson(),
        old.toJson(),
      );
      await library.addSeries([next], allowDuplicateIds: {'new'});
      expect(library.visibleEntries, hasLength(2));
      expect(groupLibrarySeries(library.visibleEntries), hasLength(2));
      await library.deleteCards(['old']);
      expect(
        seriesDraftConflicts([next], library.entries)['new'],
        contains('корзине'),
      );
    },
  );

  test(
    'extending a legacy series is atomic and preserves all existing data',
    () async {
      final old = volume(
        'old',
        values: {
          'pepehub_series_id': null,
          'cover': 'keep',
          'Custom': {
            'quotes': ['keep'],
          },
        },
      );
      await library.repository.mutate((cards) async {
        cards['old'] = LibraryEntry(old, sourceBookId: 'source-book');
      });
      await library.loadCached();
      await library.local.setMeta(
        'obsidian-activity:personal',
        jsonEncode({'version': 1, 'cursor': 0, 'slots': {}}),
      );
      final before = await library.local.meta(personalLibraryKey);
      final journal = await library.local.meta('obsidian-activity:personal');
      await db.customStatement(
        "CREATE TRIGGER fail_series BEFORE UPDATE ON metadata WHEN NEW.key='library-catalog-v1' BEGIN SELECT RAISE(ABORT,'simulated write failure'); END",
      );
      final next = volume(
        'two',
        seriesId: 'new-id',
        values: {'seriesIndex': 2},
      );
      await expectLater(
        library.addSeries([next], existingSeriesKey: 'series:архипелаг'),
        throwsA(anything),
      );
      expect(await library.local.meta(personalLibraryKey), before);
      expect((await library.repository.entries()).length, 1);
      await db.customStatement('DROP TRIGGER fail_series');
      await library.addSeries([next], existingSeriesKey: 'series:архипелаг');
      final kept = (await library.repository.entries())['old']!;
      expect(kept.sourceBookId, 'source-book');
      expect(kept.item.values['cover'], 'keep');
      expect(kept.item.values['Custom'], old.values['Custom']);
      expect(kept.item.modifiedAt, old.modifiedAt);
      expect(await library.local.meta('obsidian-activity:personal'), journal);
      expect(
        groupLibrarySeries(library.visibleEntries).single.key,
        'series-id:new-id',
      );
      await library.save('two', {
        ...next.values,
        'series': 'Другой цикл',
      }, original: next.values);
      expect(
        library.entries
            .singleWhere((e) => e.item.id == 'two')
            .item
            .values['pepehub_series_id'],
        isNull,
      );
    },
  );

  test(
    '1000 mixed volumes use one catalog write and do not read media indexes',
    () async {
      final log = <String>[];
      await runZoned(
        () async {
          final largeDb = AppDatabase(
            NativeDatabase.memory(logStatements: true),
          );
          final client = MockClient((_) => throw StateError('No network'));
          final large = LibraryService(Repository(largeDb), client);
          try {
            await large.repository.mutate((cards) async {
              for (var i = 0; i < 1000; i++) {
                cards['old-$i'] = LibraryEntry(
                  volume(
                    'old-$i',
                    type: i.isEven ? 'book' : 'audiobook',
                    seriesId: 'old',
                  ),
                );
              }
            });
            await large.loadCached();
            await largeDb.customStatement(
              'CREATE TEMP TABLE series_writes(count INTEGER)',
            );
            await largeDb.customStatement(
              'INSERT INTO series_writes VALUES(0)',
            );
            await largeDb.customStatement(
              "CREATE TEMP TRIGGER count_series_writes AFTER UPDATE ON metadata WHEN NEW.key='library-catalog-v1' BEGIN UPDATE series_writes SET count=count+1; END",
            );
            log.clear();
            await large.addSeries([
              for (var i = 0; i < 1000; i++)
                volume(
                  'new-$i',
                  type: i.isEven ? 'book' : 'audiobook',
                  seriesId: 'new',
                  values: {'seriesIndex': i + 1},
                ),
            ]);
            expect(large.visibleEntries, hasLength(2000));
            expect(
              (await largeDb
                      .customSelect('SELECT count FROM series_writes')
                      .getSingle())
                  .read<int>('count'),
              1,
            );
            expect(
              log.where(
                (s) =>
                    s.contains('FROM audio_tracks') ||
                    s.contains('reading-index:'),
              ),
              isEmpty,
            );
          } finally {
            large.dispose();
            client.close();
            await largeDb.close();
          }
        },
        zoneSpecification: ZoneSpecification(
          print: (_, parent, zone, line) => log.add(line),
        ),
      );
    },
  );

  testWidgets('library add menu opens the manual series workflow', (
    tester,
  ) async {
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
    await tester.tap(find.text('Добавить').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Серия'));
    await tester.pumpAndSettle();
    expect(find.byType(LibrarySeriesEditorPage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(library.entries, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final width in [390.0, 768.0, 1440.0]) {
    testWidgets('manual series preview edits without writing and fits $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        for (final font in ['Onest', 'Oswald', 'CormorantGaramond']) {
          await (FontLoader(font)..addFont(
                File('assets/fonts/$font.ttf')
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
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.data(Brightness.dark),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => RepaintBoundary(
                      key: boundary,
                      child: LibrarySeriesEditorPage(library: library),
                    ),
                  ),
                ),
                child: const Text('Начать'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Начать'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('series-name')),
        'Архипелаг',
      );
      await tester.enterText(
        find.byKey(const ValueKey('series-titles')),
        '0.5. Предыстория\n1. Северный путь\n2. Ледяной берег',
      );
      Future<void> shot(String stage) async {
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          image.dispose();
          await Directory('build/series-preview').create(recursive: true);
          await File('build/series-preview/$stage-${width.toInt()}.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
        });
      }

      await shot('input');
      await tester.tap(find.byKey(const ValueKey('series-primary')));
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(LibrarySeriesEditorPage));
      expect(state.volumes, hasLength(3));
      expect(
        await tester.runAsync(() => library.repository.entries()),
        isEmpty,
      );
      await shot('review');
      if (width == 390) {
        await tester.tap(find.byTooltip('Тип тома').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Аудиокнига').last);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byTooltip('Изменить том').first);
      await tester.pumpAndSettle();
      final title = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == 'Название',
      );
      await tester.enterText(title, 'До северного пути');
      await tester.tap(find.text('Применить к тому'));
      await tester.pumpAndSettle();
      expect(
        await tester.runAsync(() => library.repository.entries()),
        isEmpty,
      );
      expect(find.textContaining('До северного пути'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(state.reviewing, isFalse);
      await tester.tap(find.byKey(const ValueKey('series-primary')));
      await tester.pumpAndSettle();
      expect(find.textContaining('До северного пути'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('series-primary')));
      await ready(
        tester,
        () => find.byType(LibrarySeriesEditorPage).evaluate().isEmpty,
      );
      expect(library.visibleEntries, hasLength(3));
      if (width == 390) {
        expect(
          library.visibleEntries.where((e) => e.item.mediaType == 'audiobook'),
          hasLength(1),
        );
      }
      expect(
        library.visibleEntries.every((e) => e.item.value('endDate') == null),
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('1000 pasted volumes and saved group lists create rows lazily', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(home: LibrarySeriesEditorPage(library: library)),
    );
    await tester.enterText(
      find.byKey(const ValueKey('series-name')),
      'Большая серия',
    );
    await tester.enterText(
      find.byKey(const ValueKey('series-titles')),
      [for (var i = 0; i < 1000; i++) 'Том $i'].join('\n'),
    );
    await tester.tap(find.byKey(const ValueKey('series-primary')));
    await tester.pumpAndSettle();
    expect(
      find
          .byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key as ValueKey<String>).value.startsWith('series-volume:'),
          )
          .evaluate()
          .length,
      inInclusiveRange(1, 25),
    );
    library.entries = [
      for (var i = 0; i < 1000; i++)
        LibraryEntry(
          volume(
            '$i',
            type: i.isEven ? 'book' : 'audiobook',
            values: {'seriesIndex': i + 1},
          ),
        ),
    ];
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
    expect(find.byType(ListTile).evaluate().length, inInclusiveRange(1, 30));
    library.entries = [
      LibraryEntry(
        volume(
          'first',
          seriesId: 'first-cycle',
          values: {
            'series': 'Море, острова',
            'author': ['Автор А'],
            'seriesIndex': 0.5,
          },
        ),
      ),
      LibraryEntry(
        volume(
          'second',
          seriesId: 'second-cycle',
          values: {
            'series': 'Море, острова',
            'author': ['Автор Б'],
          },
        ),
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: LibraryGroupsPage(library: library, kind: 'series'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Море, острова'), findsNWidgets(2));
    await tester.tap(find.text('Море, острова').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('Том first'), findsOneWidget);
    expect(find.textContaining('Том second'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
