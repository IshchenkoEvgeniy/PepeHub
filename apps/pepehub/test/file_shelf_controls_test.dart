import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:pepehub/ui/app_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/audio/audio_library_sort.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/ui/catalog_search.dart';
import 'package:pepehub/ui/library_page.dart';

import 'support/flutter_fonts.dart';

class _Repository extends Repository {
  _Repository(super.db);
  int shelfReads = 0;
  @override
  Future<List<LibraryRecord>> shelfBooks({required bool audio}) {
    shelfReads++;
    return super.shelfBooks(audio: audio);
  }
}

class _Assets extends AssetStore {
  _Assets(Repository repository)
    : super(repository, Directory('unused-shelf-fixture'));
  int firstTrackReads = 0;
  @override
  Future<List<LocalAsset>> audioTracks(
    String bookId, {
    String? editionId,
    bool firstOnly = false,
  }) async {
    if (!firstOnly) {
      throw StateError('A shelf must never load complete track lists');
    }
    firstTrackReads++;
    return [];
  }
}

Map<String, dynamic> payload(
  String title, {
  bool audio = false,
  String format = 'epub',
}) => {
  'title': title,
  'authors': ['Фёдор Достоевский'],
  'format': audio ? 'audio' : format,
  'status': 'planned',
};

Finder shelfScroll() => find
    .descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    )
    .first;
Finder shelfCards() => find.byWidgetPredicate(
  (widget) =>
      widget.key is ValueKey<String> &&
      (widget.key! as ValueKey<String>).value.startsWith('book-card:'),
);

Future<void> tapVisible(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('catalog search shares case, ё/е and independent word matching', () {
    expect(
      matchesCatalogSearch(
        'Зелёный остров · Фёдор',
        catalogSearchTerms(' ФЕДОР   зеленый '),
      ),
      true,
    );
    expect(
      matchesCatalogSearch('Остров', catalogSearchTerms('зелёный')),
      false,
    );
    expect(catalogSearchTerms('  '), isEmpty);
  });

  test(
    'recently added uses local arrival order and survives metadata edits',
    () async {
      final db = AppDatabase(NativeDatabase.memory()), repo = Repository(db);
      addTearDown(db.close);
      await repo.put('book', 'old', payload('Z old'));
      await repo.put('book', 'audio-old', payload('Z audio old', audio: true));
      await repo.put('book', 'new', payload('A new'));
      await repo.put('book', 'audio-new', payload('A audio new', audio: true));
      final before = await repo.shelfBooks(audio: false);
      final oldOrder = before.firstWhere((b) => b.id == 'old').localOrder!;
      await repo.put('book', 'old', {
        ...payload('Changed old'),
        'status': 'paused',
      });
      final after = await repo.shelfBooks(audio: false);
      expect(after.firstWhere((b) => b.id == 'old').localOrder, oldOrder);
      after.sort((a, b) => b.localOrder!.compareTo(a.localOrder!));
      expect(after.map((b) => b.id), ['new', 'old']);
      final audio = await repo.shelfBooks(audio: true);
      audio.sort(
        (a, b) => compareAudioBooks(
          a,
          b,
          order: 'added',
          summaries: const {},
          recent: const {},
        ),
      );
      expect(audio.map((b) => b.id), ['audio-new', 'audio-old']);
    },
  );

  test('remaining listening time uses speed and treats missing durations/positions as unknown', () {
    expect(
      audioRemainingLabel((total: 31200000, position: 0, speed: 2)),
      'Осталось 4 ч 20 мин на 2.0×',
    );
    expect(
      audioRemainingLabel((total: 60000, position: 30000, speed: 1)),
      'Осталось 1 мин',
    );
    expect(
      audioRemainingLabel((total: 60000, position: 90000, speed: 1)),
      'Прослушано полностью',
    );
    expect(audioRemainingLabel((total: null, position: 0, speed: 1)), isNull);
    expect(
      audioRemainingLabel((total: 60000, position: null, speed: 1)),
      isNull,
    );
    expect(audioRemainingLabel((total: 0, position: 0, speed: 1)), isNull);
  });

  for (final audio in [false, true]) {
    testWidgets(
      'file shelf search, Ctrl+K, and 20-book paused/abandoned actions: audio=$audio',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final db = AppDatabase(NativeDatabase.memory()), repo = Repository(db);
        addTearDown(db.close);
        await repo.setMeta('library-section', audio ? 'audio' : 'reading');
        for (var i = 0; i < 20; i++) {
          await repo.put(
            'book',
            'book-$i',
            payload(i == 0 ? 'Зелёный остров' : 'Book $i', audio: audio),
          );
        }
        await repo.setMeta('reading-note:keep', '{"text":"Keep quote"}');
        await tester.pumpWidget(
          MaterialApp(home: LibraryPage(repository: repo)),
        );
        await tester.pumpAndSettle();
        final dynamic state = tester.state(find.byType(LibraryPage));
        expect(find.byType(TextField), findsOneWidget);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
          true,
        );
        await tester.enterText(find.byType(TextField), 'федор зеленый');
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pumpAndSettle();
        expect(shelfCards(), findsOneWidget);
        expect(find.text('Зелёный остров'), findsOneWidget);
        await tapVisible(tester, find.byTooltip('Очистить поиск'));
        for (final entry in {
          'Отложить': 'paused',
          'Бросить': 'abandoned',
        }.entries) {
          await tester.tap(find.byTooltip('Выбрать видимые книги'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Действия с выбранными'));
          await tester.pumpAndSettle();
          await tester.tap(find.text(entry.key));
          await tester.pumpAndSettle();
          expect(
            (await repo.shelfBooks(audio: audio))
                .every((b) => b.payload!['status'] == entry.value),
            true,
          );
          expect(state.selectedBooks, isEmpty);
        }
        expect(await repo.meta('reading-note:keep'), '{"text":"Keep quote"}');
        expect(state.obsidianLibrary.visibleEntries, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final size in [(360.0, 1.4), (1280.0, 1.0)]) {
    testWidgets(
      'format chip, new menu labels, added order, and independent persistent shelf views at $size',
      (tester) async {
        final (width, scale) = size;
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final db = AppDatabase(NativeDatabase.memory()), repo = _Repository(db);
        addTearDown(db.close);
        await repo.setMeta('library-section', 'reading');
        await repo.put('book', 'older', payload('A older EPUB'));
        await repo.put('book', 'newer', payload('Z newer PDF', format: 'pdf'));
        await repo.put('book', 'audio', payload('Аудиокнига', audio: true));
        final captureKey = GlobalKey();
        final output = Platform.environment['PEPEHUB_SHELF_SCREENSHOTS'];
        if (output != null) {
          await tester.runAsync(() async {
            for (final font in [
              'Onest',
              'Manrope',
              'Oswald',
              'CormorantGaramond',
            ]) {
              await (FontLoader(font)..addFont(
                    File('assets/fonts/$font.ttf')
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
        }
        Widget app() => MaterialApp(
          theme: AppTheme.data(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: RepaintBoundary(
            key: captureKey,
            child: LibraryPage(repository: repo),
          ),
        );
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();
        await tapVisible(tester, find.byKey(const ValueKey('shelf-filters')));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ChoiceChip, 'PDF'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Готово'));
        await tester.pumpAndSettle();
        expect(find.text('Формат: PDF'), findsOneWidget);
        expect(find.byKey(const ValueKey('book-card:older')), findsNothing);
        await tapVisible(tester, find.byTooltip('Сбросить формат'));
        expect(
          find.byKey(const ValueKey('active-format-filter')),
          findsNothing,
        );
        await tapVisible(tester, find.byTooltip('Сортировка книг'));
        await tester.tap(
          find.ancestor(
            of: find.text('Недавно добавленные'),
            matching: find.byType(CheckedPopupMenuItem<String>),
          ),
        );
        await tester.pumpAndSettle();
        expect(await repo.meta('reading-sort'), 'added');
        final keys = shelfCards()
            .evaluate()
            .map((e) => (e.widget.key! as ValueKey<String>).value)
            .toList();
        expect(keys.first, 'book-card:newer');
        await tapVisible(tester, find.byTooltip('Сортировка книг'));
        await tester.tap(find.byKey(const ValueKey('sort-reverse')));
        await tester.pumpAndSettle();
        expect(await repo.meta('reading-sort-reverse'), '1');
        expect(
          shelfCards()
              .evaluate()
              .map((e) => (e.widget.key! as ValueKey<String>).value)
              .first,
          isNot('book-card:newer'),
        );
        await tapVisible(tester, find.byTooltip('Сортировка книг'));
        await tester.tap(find.byKey(const ValueKey('sort-reverse')));
        await tester.pumpAndSettle();
        expect(await repo.meta('reading-sort-reverse'), '0');
        final reads = repo.shelfReads;
        await tapVisible(tester, find.byTooltip('Обложки'));
        expect(find.byType(SliverGrid), findsOneWidget);
        expect(await repo.meta('reading-shelf-view'), 'covers');
        expect(repo.shelfReads, reads);
        final tile = find.byKey(const ValueKey('book-card:newer'));
        await Scrollable.ensureVisible(tester.element(tile), alignment: .2);
        await tester.pumpAndSettle();
        await tester.tap(tile);
        await tester.pumpAndSettle();
        expect(find.text('Источник и файл'), findsOneWidget);
        await tester.tap(find.text('Закрыть'));
        await tester.pumpAndSettle();
        if (output != null) {
          await Scrollable.ensureVisible(
            tester.element(find.byKey(const ValueKey('book-card:newer'))),
            alignment: .1,
          );
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            final boundary =
                captureKey.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage(pixelRatio: 1.5);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            image.dispose();
            await Directory(output).create(recursive: true);
            await File('$output/shelf-${width.toInt()}-covers.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
          });
        }
        await tapVisible(tester, find.byTooltip('Добавить'));
        expect(find.text('Новая карточка без файла'), findsOneWidget);
        expect(find.text('Открыть файл…'), findsOneWidget);
        expect(find.text('Скрытые и недоступные'), findsOneWidget);
        await tester.tapAt(const Offset(5, 60));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Аудиокниги'));
        await tester.pumpAndSettle();
        await tapVisible(tester, find.byTooltip('Список'));
        expect(await repo.meta('audio-shelf-view'), 'list');
        await tester.tap(find.byTooltip('Книги'));
        await tester.pumpAndSettle();
        expect(find.byType(SliverGrid), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();
        expect(find.byType(SliverGrid), findsOneWidget);
        await tapVisible(tester, find.byTooltip('Список'));
        expect(find.byType(SliverGrid), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    '1000 books and 1000 audiobooks retain lazy views and compact indexes without full track reads',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase(NativeDatabase.memory()),
          repo = _Repository(db),
          assets = _Assets(repo);
      addTearDown(db.close);
      await repo.setMeta('library-section', 'reading');
      await db.transaction(() async {
        for (var i = 0; i < 1000; i++) {
          await db.customStatement('INSERT INTO records VALUES(?,?,1,0,?)', [
            'text-$i',
            'book',
            jsonEncode(payload('Книга ${i.toString().padLeft(4, '0')}')),
          ]);
          await db.customStatement(
            'INSERT INTO local_assets VALUES(?,?,?,?,?,?)',
            [
              'asset-$i',
              'text-$i',
              '$i.epub',
              '/unopened/$i.epub',
              'hash-$i',
              12,
            ],
          );
          await repo.setMeta(
            'reading-index:hash-$i',
            jsonEncode({
              'title': 'Книга ${i.toString().padLeft(4, '0')}',
              'authors': ['Фёдор'],
              'length': 10000,
              'starts': [0],
              if (i == 0) 'paragraphStarts': [List.generate(20000, (n) => n)],
            }),
          );
          await db.customStatement('INSERT INTO records VALUES(?,?,1,0,?)', [
            'audio-$i',
            'book',
            jsonEncode(
              payload('Аудио ${i.toString().padLeft(4, '0')}', audio: true),
            ),
          ]);
          await db.customStatement('INSERT INTO audio_editions VALUES(?,?,1)', [
            'edition-$i',
            'audio-$i',
          ]);
          for (var track = 0; track < 10; track++) {
            await db.customStatement(
              'INSERT INTO audio_resources VALUES(?,?,?)',
              ['audio-hash-$i-$track', '/unopened/$i/$track.mp3', 12],
            );
            await db.customStatement(
              'INSERT INTO audio_tracks VALUES(?,?,?,?,?,?)',
              [
                'track-$i-$track',
                'edition-$i',
                'audio-hash-$i-$track',
                track,
                'Track $track',
                3120000,
              ],
            );
          }
          await db.customStatement(
            'INSERT INTO audio_progress VALUES(?,?,?,?,?,?)',
            ['edition-$i', 'track-$i-0', 0, 1, 2.0, '2026-11-01T12:00:00Z'],
          );
        }
      });
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryPage(repository: repo, assets: assets),
        ),
      );
      await tester.pumpAndSettle();
      final dynamic state = tester.state(find.byType(LibraryPage));
      expect(state.books.length, 1000);
      expect(state.readingIndex['hash-0']['paragraphStarts'], isNull);
      expect(shelfCards().evaluate().length, lessThan(35));
      await tapVisible(tester, find.byTooltip('Обложки'));
      expect(shelfCards().evaluate().length, lessThan(35));
      await tester.tap(find.byTooltip('Аудиокниги'));
      await tester.pumpAndSettle();
      expect(state.books.length, 1000);
      expect(state.audioSummaries.length, 1000);
      await tester.scrollUntilVisible(
        find.text('Осталось 4 ч 20 мин на 2.0×').first,
        250,
        scrollable: shelfScroll(),
      );
      await tester.ensureVisible(
        find.text('Осталось 4 ч 20 мин на 2.0×').first,
      );
      expect(find.text('Осталось 4 ч 20 мин на 2.0×'), findsWidgets);
      expect(assets.firstTrackReads, lessThan(35));
      await tapVisible(tester, find.byTooltip('Обложки'));
      expect(shelfCards().evaluate().length, lessThan(35));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
