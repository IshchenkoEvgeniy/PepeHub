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
import 'package:pepehub/ui/app_theme.dart';
import 'package:pepehub/ui/metadata_input.dart';
import 'package:pepehub/ui/library_metadata_editor.dart';
import 'package:pepehub/ui/shelf_components.dart';

import 'support/flutter_fonts.dart';

LibraryEntry card(
  String id, {
  String type = 'book',
  Map<String, dynamic> values = const {},
}) => LibraryEntry(
  personalLibraryItem(id, type, {
    'title': 'Книга $id',
    'author': ['Автор'],
    'status': 'finished',
    ...values,
  }),
);

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

  test(
    'series keep shelf order, normalize names and order numbered volumes first',
    () {
      final source = [
        card('ten', values: {'series': ' Большая  серия ', 'seriesIndex': 10}),
        card('single'),
        card('unknown', type: 'audiobook', values: {'series': 'большая серия'}),
        card(
          'two',
          type: 'audiobook',
          values: {'series': 'БОЛЬШАЯ СЕРИЯ', 'seriesIndex': 2},
        ),
        card('half', values: {'series': 'Большая серия', 'seriesIndex': 1.5}),
        card('other', values: {'series': 'Одиночная серия'}),
      ];
      final before = source.map((e) => e.toJson()).toList();
      final groups = groupLibrarySeries(source);
      expect(groups, hasLength(3));
      expect(groups.first.isSeries, isTrue);
      expect(groups.first.entries.map((e) => e.item.id), [
        'half',
        'two',
        'ten',
        'unknown',
      ]);
      expect(groups[1].entries.single.item.id, 'single');
      expect(groups.last.isSeries, isFalse);
      expect(source.map((e) => e.toJson()).toList(), before);
    },
  );

  test(
    'suggestions follow current archive, deletion, edits and restoration',
    () async {
      final kept = card(
        'kept',
        values: {
          'author': ['Общий автор'],
          'genre': ['Фантастика'],
          'series': 'Живая серия',
          'narrator': ['Первый чтец', 'Второй чтец'],
          'publisher': 'Издатель',
        },
      );
      final removed = card(
        'removed',
        type: 'audiobook',
        values: {
          'author': ['Удалённый автор', 'Общий автор'],
          'genre': ['Старый жанр'],
          'series': 'Старая серия',
          'narrator': 'Старый чтец',
          'language': 'Старый язык',
          'tags': ['Старый тег'],
        },
      );
      await library.repository.mutate((entries) async {
        entries.addAll({kept.item.id: kept, removed.item.id: removed});
        entries['draft'] = card(
          'draft',
          values: {
            'author': ['Из файлов'],
            'pepehub_source_only': true,
          },
        );
        entries['planned'] = card(
          'planned',
          values: {
            'author': ['В планах'],
            'status': 'planned',
          },
        );
      });
      await library.loadCached();
      expect(library.suggestions['author'], ['Общий автор', 'Удалённый автор']);
      await library.deleteCards(['removed']);
      expect(library.suggestions['author'], ['Общий автор']);
      expect(library.suggestions['genre'], ['Фантастика']);
      expect(library.suggestions['series'], ['Живая серия']);
      expect(library.suggestions['narrator'], ['Второй чтец', 'Первый чтец']);
      expect(library.suggestions['language'], isEmpty);
      expect(library.suggestions['tags'], isEmpty);
      expect(library.trash.single.item.values['narrator'], 'Старый чтец');
      await library.restoreCard('removed');
      expect(library.suggestions['author'], contains('Удалённый автор'));
      await library.editCards(
        ['removed'],
        {
          'author': ['Новый автор'],
        },
      );
      expect(library.suggestions['author'], isNot(contains('Удалённый автор')));
      expect(library.suggestions['author'], contains('Новый автор'));
    },
  );

  testWidgets(
    '1000 mixed series members stay lazy in list and grid and searchable while folded',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      library.entries = [
        for (var i = 0; i < 1000; i++)
          card(
            '$i',
            type: i.isEven ? 'book' : 'audiobook',
            values: {
              'title': 'Том ${i.toString().padLeft(4, '0')}',
              'series': 'Большая серия',
              'seriesIndex': i + 1,
              if (i % 4 == 0) 'status': 'unread',
            },
          ),
      ];
      Widget page() => MaterialApp(
        theme: AppTheme.data(Brightness.dark),
        home: LibraryArchivePage(
          service: library,
          navigation: ShelfNavigation(
            current: PepeSection.library,
            onSelect: (_) {},
            onSettings: () {},
          ),
          onSettings: () {},
        ),
      );
      int built() => find
          .byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key as ValueKey<String>).value.startsWith('library-work:'),
          )
          .evaluate()
          .length;
      final series = find.byKey(
        const ValueKey('library-series:series:большая серия'),
      );
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(series, findsOneWidget);
      expect(built(), 0);
      expect(find.textContaining('Книг: 500 · Аудиокниг: 500'), findsOneWidget);
      await tester.tap(find.byTooltip('Развернуть серию'));
      await tester.pumpAndSettle();
      expect(built(), inInclusiveRange(1, 25));
      expect(find.byKey(const ValueKey('library-work:0')), findsOneWidget);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
      await tester.pumpAndSettle();
      expect(built(), lessThan(30));
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      position.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Свернуть серию'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('library-search')),
        'Том 0999',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('library-work:999')), findsOneWidget);
      expect(series, findsNothing);
      await tester.tap(find.byTooltip('Очистить поиск'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Аудиокниги'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Книг: 0 · Аудиокниг: 500'), findsOneWidget);
      await tester.tap(find.byTooltip('Показать карточками'));
      await tester.pumpAndSettle();
      expect(series, findsOneWidget);
      expect(built(), 0);
      await tester.ensureVisible(series);
      await tester.pumpAndSettle();
      await tester.tap(series);
      await tester.pumpAndSettle();
      expect(built(), inInclusiveRange(1, 20));
      await tester.ensureVisible(
        find.byKey(const ValueKey('library-group-series')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-group-series')));
      await tester.pumpAndSettle();
      expect(series, findsNothing);
      expect(built(), inInclusiveRange(1, 20));
      await tester.runAsync(
        () async =>
            expect(await library.local.meta('library-group-series-v1'), '0'),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.pumpWidget(page());
      await tester.pumpAndSettle();
      expect(series, findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'legacy narrator text becomes editable tokens and saves all narrators without losing custom data',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final original = library.emptyDraft(audio: true).withValues({
        ...library.emptyDraft(audio: true).values,
        'title': 'Аудиокнига',
        'narrator': 'Первый чтец',
        'Custom': {
          'nested': ['Сохранить'],
        },
      });
      Map<String, dynamic>? saved;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.data(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.4)),
            child: child!,
          ),
          home: LibraryMetadataEditor(
            item: original,
            suggestions: const {
              'narrator': ['Второй чтец'],
            },
            onSave: (values) async => saved = values,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final tokens = find.byWidgetPredicate(
        (w) => w is MetadataTokensField && w.label == 'Чтецы',
      );
      expect(tokens, findsOneWidget);
      expect(find.text('Первый чтец'), findsOneWidget);
      final input = find.descendant(
        of: tokens,
        matching: find.byType(TextFormField),
      );
      await tester.ensureVisible(input);
      await tester.enterText(input, 'Второй');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Второй чтец'));
      await tester.pumpAndSettle();
      expect(find.text('Второй чтец'), findsOneWidget);
      await tester.enterText(input, 'Третий чтец; четвёртый чтец');
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(saved!['narrator'], [
        'Первый чтец',
        'Второй чтец',
        'Третий чтец',
        'четвёртый чтец',
      ]);
      expect(saved!['Custom'], original.values['Custom']);
      expect(saved!['status'], 'finished');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  if (const bool.fromEnvironment('LIBRARY_SCREENSHOTS')) {
    for (final width in [390.0, 768.0, 1440.0]) {
      testWidgets('library and editor visual review at $width', (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
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
                File(materialIconsFont)
                    .readAsBytes()
                    .then(ByteData.sublistView),
              ))
              .load();
        });
        final boundary = GlobalKey();
        Future<void> capture(String name) async {
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            image.dispose();
            await File('build/library-$name-${width.toInt()}.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
          });
          expect(tester.takeException(), isNull);
        }

        library.entries = [
          for (var i = 0; i < 24; i++)
            card(
              '$i',
              type: i.isEven ? 'book' : 'audiobook',
              values: {
                'title': 'Архив Буресвета · том ${i + 1}',
                'author': ['Брендон Сандерсон'],
                'series': 'Архив Буресвета',
                'seriesIndex': i + 1,
              },
            ),
          card(
            'standalone',
            values: {
              'title': 'Левая рука тьмы',
              'author': ['Урсула Ле Гуин'],
            },
          ),
        ];
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.data(Brightness.dark),
            home: RepaintBoundary(
              key: boundary,
              child: LibraryArchivePage(
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
        await capture('series');
        await tester.tap(find.byTooltip('Показать карточками'));
        await capture('series-grid');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        final draft = library.emptyDraft(audio: true);
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.data(Brightness.dark),
            home: RepaintBoundary(
              key: boundary,
              child: LibraryMetadataEditor(
                item: draft.withValues({
                  ...draft.values,
                  'title': 'Путь королей',
                  'author': ['Брендон Сандерсон'],
                  'narrator': ['Сергей Чонишвили', 'Алёна Долецкая'],
                  'series': 'Архив Буресвета',
                  'seriesIndex': 1,
                }),
                onSave: (_) async {},
              ),
            ),
          ),
        );
        await capture('editor');
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
    }
  }
}
