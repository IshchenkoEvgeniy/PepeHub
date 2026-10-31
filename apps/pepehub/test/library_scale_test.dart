import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:uuid/uuid.dart';
import 'package:pepehub/audio/audio_library_repository.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/library_service.dart';
import 'package:pepehub/library/models.dart';
import 'package:pepehub/library/personal_library.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/reader/reading_library.dart';
import 'package:pepehub/ui/app_theme.dart';
import 'package:pepehub/ui/library_page.dart';
import 'package:pepehub/ui/audio_cover.dart';
import 'package:pepehub/ui/obsidian_library_page.dart';
import 'package:pepehub/ui/shelf_components.dart';

import 'video_player_tools_widget_test.dart' show ready;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late Repository repo;
  late AssetStore assets;
  late Directory temp;
  final client = MockClient((_) => throw StateError('No network'));
  late LibraryService archive;
  var rawIndexBytes = 0;
  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = Repository(db);
    temp = await Directory.systemTemp.createTemp('pepehub-scale-');
    assets = AssetStore(repo, temp);
    archive = LibraryService(repo, client);
    final catalog = <String, LibraryEntry>{};
    await db.transaction(() async {
      final resource = 'a' * 64;
      await db.customStatement('INSERT INTO audio_resources VALUES(?,?,?)', [
        resource,
        '${temp.path}/track.mp3',
        1000,
      ]);
      for (var i = 0; i < 1000; i++) {
        final audio = i >= 500, id = 'source-$i';
        final title = 'Произведение ${i.toString().padLeft(4, '0')}';
        await db.customStatement('INSERT INTO records VALUES(?,?,?,?,?)', [
          id,
          'book',
          1,
          0,
          jsonEncode({
            'title': title,
            'authors': ['Автор ${i % 30}'],
            'format': audio ? 'audio' : 'epub',
            'status': 'planned',
          }),
        ]);
        final cardId = uuid.v5(Namespace.url.value, 'scale:$i');
        catalog[cardId] = LibraryEntry(
          personalLibraryItem(cardId, audio ? 'audiobook' : 'book', {
            'title': title,
            'author': ['Автор ${i % 30}'],
            'status': ['finished', 'paused', 'abandoned'][i % 3],
            'pepehub_auto_discovered': false,
            'pepehub_added_at': '2026-10-01T00:00:00Z',
          }),
        );
        if (audio) {
          final edition = 'edition-$i';
          await db.customStatement('INSERT INTO audio_editions VALUES(?,?,?)', [
            edition,
            id,
            1,
          ]);
          for (var track = 0; track < 100; track++) {
            final unknown =
                i == 500 && track == 99 ||
                i == 501 && track == 2 ||
                i == 502 && track == 30;
            await db.customStatement(
              'INSERT INTO audio_tracks VALUES(?,?,?,?,?,?)',
              [
                'track-$i-$track',
                edition,
                resource,
                track,
                'Глава $track',
                unknown
                    ? null
                    : i == 503 && track == 2
                    ? 0
                    : 1000,
              ],
            );
          }
          await db.customStatement(
            'INSERT INTO audio_progress VALUES(?,?,?,?,?,?)',
            [edition, 'track-$i-30', 500, 1, 1.0, '2026-10-01T10:00:00Z'],
          );
        } else {
          final hash = (i + 1).toRadixString(16).padLeft(64, '0');
          await db.customStatement(
            'INSERT INTO local_assets(id,book_id,filename,path,sha256,bytes) VALUES(?,?,?,?,?,?)',
            ['asset-$i', id, '$title.epub', '${temp.path}/$i.epub', hash, 1000],
          );
          final index = {
            'metadataVersion': 2,
            'title': title,
            'authors': ['Автор ${i % 30}'],
            'length': 40000,
            'starts': [0, 20000],
            'paragraphStarts': [
              for (var c = 0; c < 2; c++)
                [for (var p = 0; p < 1000; p++) p * 20],
            ],
            'chapters': ['Первая', 'Вторая'],
            'lengths': [20000, 20000],
          };
          final encoded = jsonEncode(index);
          rawIndexBytes += encoded.length;
          await repo.setMeta('reading-index:$hash', encoded);
          await repo.setMeta(
            'reader:$hash',
            jsonEncode({
              'chapter': 1,
              'paragraph': 300,
              'offset': 5,
              if (i.isOdd) 'textOffset': 3007,
            }),
          );
        }
      }
      // Alternative editions must never be appended to the active timeline.
      await db.customStatement('INSERT INTO audio_editions VALUES(?,?,?)', [
        'alternative',
        'source-504',
        1,
      ]);
      await db.customStatement('INSERT INTO audio_tracks VALUES(?,?,?,?,?,?)', [
        'alternative-track',
        'alternative',
        resource,
        0,
        'Другой перевод',
        999999,
      ]);
      await archive.repository.mutate(
        (entries) async => entries.addAll(catalog),
      );
    });
    await archive.loadCached();
  });
  tearDownAll(() async {
    archive.dispose();
    client.close();
    await db.close();
    await temp.delete(recursive: true);
  });

  test('500 books and 500 audiobooks use compact shelf projections with exact progress', () async {
    final watch = Stopwatch()..start();
    final texts = await assets.shelfAssets(audio: false);
    final audio = await assets.shelfAssets(audio: true);
    final summaries = await AudioLibraryRepository(db).bookSummaries();
    expect(texts, hasLength(500));
    expect(audio, hasLength(500));
    expect(summaries, hasLength(500));
    expect(summaries['source-504']!.total, 100000);
    expect(summaries['source-504']!.position, 30500);
    expect(summaries['source-500']!.total, isNull);
    expect(summaries['source-500']!.position, 30500);
    expect(summaries['source-501']!.position, isNull);
    expect(summaries['source-502']!.position, 30500);
    expect(summaries['source-503']!.position, isNull);
    final reading = ReadingLibrary(repo);
    final positions = await reading.entries('reader:');
    final index = await reading.shelfIndex(positions);
    final compact = jsonEncode(index).length;
    expect(index, hasLength(500));
    expect(compact, lessThan(rawIndexBytes ~/ 10));
    for (var i = 0; i < 20; i++) {
      final hash = (i + 1).toRadixString(16).padLeft(64, '0');
      expect(index[hash]!.containsKey('paragraphStarts'), isFalse);
      expect(
        readingFraction(index[hash]!, positions[hash]!),
        closeTo((20000 + (i.isOdd ? 3007 : 6005)) / 40000, .00000001),
      );
    }
    debugPrint(
      '1000 source works / 50001 tracks: shelf queries ${watch.elapsedMilliseconds} ms; index payload $rawIndexBytes -> $compact bytes',
    );
  });

  test(
    'reading projection matches full indexes at clamped and legacy positions',
    () async {
      final reading = ReadingLibrary(repo);
      const hash = 'projection-boundaries';
      final full = {
        'length': 100,
        'starts': [0, 50],
        'paragraphStarts': [
          [0, 10],
          [0, 20],
        ],
      };
      await repo.setMeta('reading-index:$hash', jsonEncode(full));
      try {
        for (final position in [
          {'chapter': -5, 'paragraph': -1, 'offset': 3},
          {'chapter': 99, 'paragraph': 99, 'offset': 2},
          {'chapter': 1, 'textOffset': 11},
          <String, dynamic>{},
        ]) {
          await repo.setMeta('reader:$hash', jsonEncode(position));
          final expected = readingFraction(full, position);
          final positions = await reading.entries('reader:');
          final index = await reading.shelfIndex(positions);
          expect(readingFraction(index[hash]!, positions[hash]!), expected);
        }
      } finally {
        await db.customStatement('DELETE FROM metadata WHERE key IN (?,?)', [
          'reader:$hash',
          'reading-index:$hash',
        ]);
      }
    },
  );

  testWidgets(
    '1000 archive entries build a bounded visible list, grid and filtered search',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.data(Brightness.dark),
          home: ObsidianLibraryPage(
            service: archive,
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
      int built() => find
          .byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                ((w.key as ValueKey<String>).value.startsWith('library-work:')),
          )
          .evaluate()
          .length;
      final initial = built();
      expect(initial, inInclusiveRange(1, 25));
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -2500));
      await tester.pumpAndSettle();
      expect(built(), lessThan(30));
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      position.jumpTo(0);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Показать карточками'));
      await tester.pumpAndSettle();
      expect(built(), lessThan(25));
      await tester.enterText(
        find.byKey(const ValueKey('library-search')),
        'Произведение 0999',
      );
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) => w is Text && w.data == 'Произведение 0999',
        ),
        findsOneWidget,
      );
      expect(built(), 1);
      expect(tester.takeException(), isNull);
      debugPrint(
        '1000 archive entries: $initial initial rows; lazy list/grid and search verified',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  for (final reading in [true, false]) {
    testWidgets(
      '500 ${reading ? 'text books' : 'audiobooks'} stay lazy and do not enter the personal archive',
      (tester) async {
        await repo.setMeta('library-section', reading ? 'reading' : 'audio');
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.data(Brightness.dark),
            home: LibraryPage(repository: repo, assets: assets),
          ),
        );
        final state = tester.state(find.byType(LibraryPage)) as dynamic;
        final LibraryService service = state.obsidianLibrary;
        try {
          await ready(tester, () => !state.loading && !service.loading);
          expect((state.books as List).length, 500);
          if (!reading) {
            final cover = tester.state(find.byType(AudioCover).first);
            final beforeBooks = state.books;
            repo.notifyExternalChange();
            await ready(tester, () => !identical(state.books, beforeBooks));
            expect(
              identical(tester.state(find.byType(AudioCover).first), cover),
              isTrue,
              reason: 'Unchanged artwork keeps its State across shelf reloads',
            );
          }
          expect(
            find.byTooltip('Действия с книгой').evaluate().length,
            inInclusiveRange(1, 20),
          );
          await tester.drag(
            find.byType(CustomScrollView),
            const Offset(0, -2000),
          );
          await tester.pumpAndSettle();
          expect(
            find.byTooltip('Действия с книгой').evaluate().length,
            lessThan(25),
          );
          expect(service.entries, hasLength(1000));
          expect(service.sourceDraft('source-0'), isNull);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await tester.runAsync(() => service.idle);
        }
      },
    );
  }
}
