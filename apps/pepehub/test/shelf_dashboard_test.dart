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
import 'package:pepehub/library/library_service.dart';
import 'package:pepehub/library/models.dart';
import 'package:pepehub/library/obsidian_sync_service.dart';
import 'package:pepehub/ui/app_theme.dart';
import 'package:pepehub/ui/obsidian_library_dashboard.dart';
import 'package:pepehub/ui/shelf_components.dart';

const fields = [
  LibraryField('Title', 'title', 'text'),
  LibraryField('Author', 'author', 'text'),
  LibraryField('Series', 'series', 'text'),
  LibraryField('Status', 'status', 'text'),
  LibraryField('Progress', 'progress', 'number'),
  LibraryField('Total', 'total', 'number'),
  LibraryField('End Date', 'endDate', 'text'),
  LibraryField('Rating', 'rating', 'text'),
];

List<LibraryEntry> fixtures() => [
  for (final data in [
    [
      'dune',
      'Дюна',
      'Фрэнк Герберт',
      'Хроники Дюны',
      'book',
      'Чтение',
      180,
      600,
    ],
    [
      'ocean',
      'Морские истории',
      'Жюль Верн',
      'Путешествия',
      'audiobook',
      'finished',
      420,
      420,
    ],
    [
      'island',
      'Таинственный остров',
      'Жюль Верн',
      'Путешествия',
      'book',
      'planned',
      0,
      500,
    ],
    ['unknown', 'Новая запись', 'Автор', '', 'book', '', null, null],
  ])
    LibraryEntry(
      ObsidianLibraryItem(
        id: data[0] as String,
        path: 'Books/${data[0]}.md',
        collectionId: 'reading',
        mediaType: data[4] as String,
        fields: fields,
        values: {
          'Title': data[1],
          'Author': data[2],
          'Series': data[3],
          'Status': data[5],
          'Progress': data[6],
          'Total': data[7],
          'End Date': data[0] == 'ocean'
              ? '${DateTime.now().year}-03-12'
              : null,
          'Rating': data[0] == 'ocean' ? '4.5' : null,
        },
      ),
    ),
];

void main() {
  for (final size in [
    (1440.0, 1.0),
    (1100.0, 1.0),
    (390.0, 1.0),
    (390.0, 1.4),
  ]) {
    final (width, scale) = size;
    testWidgets(
      'dashboard fits $width at text scale $scale and keeps actual counts and empty values',
      (tester) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final repo = Repository(db);
        var requests = 0;
        final client = MockClient((request) async {
          requests++;
          throw StateError('Viewing the library must not send data');
        });
        addTearDown(client.close);
        final service = LibraryService(repo, client)
          ..config = ObsidianConfig('https://example.com', 'test-only')
          ..entries = fixtures();
        addTearDown(service.dispose);
        final key = GlobalKey();
        await tester.runAsync(() async {
          await (FontLoader('Manrope')..addFont(
                File('assets/fonts/Manrope.ttf')
                    .readAsBytes()
                    .then(ByteData.sublistView),
              ))
              .load();
          await (FontLoader('MaterialIcons')..addFont(
                File(
                  '../../.tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
                ).readAsBytes().then(ByteData.sublistView),
              ))
              .load();
        });
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              theme: AppTheme.data(Brightness.dark),
              home: ObsidianLibraryPage(
                service: service,
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
        expect(service.completed.length, 1);
        expect(service.inbox.length, 3);
        expect(find.text('В планах'), findsNothing);
        expect(find.byType(Badge), findsOneWidget);
        expect(find.text('Задать цель'), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (width != 1100 && scale == 1) {
          await tester.runAsync(() async {
            final rendered =
                key.currentContext!.findRenderObject() as RenderRepaintBoundary;
            final image = await rendered.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            image.dispose();
            await File(
              'build/shelf-${width == 1440 ? 'desktop' : 'mobile'}.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
          });
        }
        final query = find.byKey(const ValueKey('library-search'));
        await tester.ensureVisible(query);
        await tester.pumpAndSettle();
        await tester.enterText(query, 'Жюль');
        await tester.pumpAndSettle();
        expect(find.text('Дюна'), findsNothing);
        expect(find.text('Показано 1 из 1'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('library-search-scope:all')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('По серии').last);
        await tester.pumpAndSettle();
        expect(find.text('Ничего не найдено'), findsOneWidget);
        await tester.ensureVisible(find.text('Сбросить фильтры'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Сбросить фильтры'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('library-search-scope:all')),
          findsOneWidget,
        );
        await tester.ensureVisible(query);
        await tester.pumpAndSettle();
        await tester.enterText(query, 'Путешествия');
        await tester.pumpAndSettle();
        expect(find.text('Показано 1 из 1'), findsOneWidget);
        // Covers are the default view; the list can be switched on and off.
        expect(find.byType(GridView), findsOneWidget);
        await tester.ensureVisible(find.byTooltip('Показать списком'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Показать списком'));
        await tester.pumpAndSettle();
        expect(find.byType(GridView), findsNothing);
        await tester.tap(find.byTooltip('Показать карточками'));
        await tester.pumpAndSettle();
        expect(find.byType(GridView), findsOneWidget);
        expect(requests, 0);
        expect(await service.repository.entries(), isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      },
    );
  }
}
