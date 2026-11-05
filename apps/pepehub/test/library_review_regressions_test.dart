import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/library_features.dart';
import 'package:pepehub/library/library_service.dart';
import 'package:pepehub/library/models.dart';
import 'package:pepehub/library/personal_library.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/ui/app_theme.dart';
import 'package:pepehub/ui/library_page.dart';
import 'package:pepehub/ui/library_trash_page.dart';
import 'package:pepehub/ui/obsidian_library_dashboard.dart';
import 'package:pepehub/ui/shelf_components.dart';

import 'video_player_tools_widget_test.dart' show ready;

void main() {
  late AppDatabase db;
  late Repository local;
  late LibraryService library;
  late Directory temp;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    local = Repository(db);
    temp = await Directory.systemTemp.createTemp('pepehub-audit-');
    final client = MockClient((_) => throw StateError('No network'));
    library = LibraryService(local, client, assets: AssetStore(local, temp));
    addTearDown(client.close);
  });
  tearDown(() async {
    library.dispose();
    await db.close();
    await temp.delete(recursive: true);
  });

  for (final populated in [false, true]) {
    testWidgets('trash opens when populated=$populated', (tester) async {
      String? deletedId;
      await tester.runAsync(library.loadCached);
      if (populated) {
        await tester.runAsync(() async {
          final draft = library.emptyDraft().withValues({
            'title': 'Deleted',
            'status': 'finished',
          });
          await library.add(draft, '');
          await library.deleteCards([draft.id]);
          deletedId = draft.id;
        });
      }
      await tester.pumpWidget(
        MaterialApp(home: LibraryTrashPage(service: library)),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (populated) {
        expect(find.text('Deleted'), findsOneWidget);
        await tester.tap(find.byTooltip('Восстановить'));
        await ready(tester, () => library.trash.isEmpty);
        expect(library.visibleEntries.single.item.id, deletedId);
      }
      expect(find.text('Корзина пуста'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final cover in ['https://example.test/new.png', '', null]) {
    test('explicit cover "$cover" overrides imported asset', () async {
      final hash = 'a' * 64;
      final file = File(library.covers!.path(hash));
      await file.parent.create(recursive: true);
      await file.writeAsBytes([1]);
      final draft = library.emptyDraft().withValues({
        'title': 'Imported',
        'status': 'finished',
        'cover': 'pepehub-cover:$hash',
        'pepehub_cover_asset': {'hash': hash},
      });
      await library.add(draft, '');
      final before = library.entries.single.item;
      await library.save(before.id, {
        ...before.values,
        'cover': cover,
      }, original: before.values);
      await library.reload();
      expect(library.entries.single.item.value('cover'), cover);
      expect(
        library.coverPath(library.entries.single.item),
        isNull,
        reason:
            'The old imported asset must not override an explicit cover edit',
      );
    });
  }

  test(
    'legacy artwork stays available while explicit references take priority',
    () async {
      final oldHash = 'a' * 64, newHash = 'b' * 64;
      final oldCover = File(library.covers!.path(oldHash));
      await oldCover.parent.create(recursive: true);
      await oldCover.writeAsBytes([1]);
      final imported = library.emptyDraft().withValues({
        'title': 'Imported',
        'cover': 'Covers/old.png',
        'pepehub_cover_asset': {'hash': oldHash},
      });
      expect(library.coverPath(imported), oldCover.path);
      expect(
        library.coverPath(
          imported.withValues({
            ...imported.values,
            'cover': 'https://example.test/new.png',
          }),
        ),
        isNull,
      );
      final explicit = imported.withValues({
        ...imported.values,
        'cover': 'pepehub-cover:$newHash',
      });
      expect(
        library.coverPath(explicit),
        isNull,
        reason: 'An unavailable replacement must not show the previous artwork',
      );
      final newCover = File(library.covers!.path(newHash));
      await newCover.writeAsBytes([2]);
      expect(library.coverPath(explicit), newCover.path);
    },
  );

  for (final type in ['book', 'audiobook']) {
    test('completion updates partial progress for $type', () async {
      final draft = personalLibraryItem(uuid.v4(), type, {
        'title': 'Partial',
        'status': 'paused',
        'total': 100,
        'progress': 20,
        'unit': type == 'book' ? 'pages' : 'minutes',
      });
      await library.add(draft, '');
      await library.editCards([draft.id], {'status': 'finished'});
      expect(library.entries.single.item.value('status'), 'finished');
      expect(
        library.entries.single.item.value('progress'),
        100,
        reason: 'Quick completion should match the metadata editor completion',
      );
      expect(libraryRereads(library.entries.single.item), 0);
      if (type == 'audiobook') {
        expect(
          library.entries.single.item.values['pepehub_audio_progress_ms'],
          6000000,
        );
      }
    });
  }

  test(
    'completion keeps explicit editor progress, known dates and unknown volume',
    () async {
      for (final total in [null, 100]) {
        final draft = personalLibraryItem(uuid.v4(), 'book', {
          'title': 'Partial',
          'status': 'paused',
          'total': total,
          'progress': 20,
          'endDate': '2025-05-06',
        });
        await library.add(draft, '');
        final before = library.entries
            .firstWhere((e) => e.item.id == draft.id)
            .item;
        if (total == null) {
          await library.editCards([draft.id], {'status': 'finished'});
        } else {
          await library.save(draft.id, {
            ...before.values,
            'status': 'finished',
            'progress': 80,
          }, original: before.values);
        }
        final after = library.entries
            .firstWhere((e) => e.item.id == draft.id)
            .item;
        expect(after.value('progress'), total == null ? 20 : 80);
        expect(after.value('endDate'), '2025-05-06');
        expect(libraryRereads(after), 0);
      }
    },
  );

  testWidgets('select shown includes visible unread series volumes', (
    tester,
  ) async {
    library.entries = [
      for (var i = 0; i < 1000; i++)
        LibraryEntry(
          personalLibraryItem(uuid.v4(), i.isEven ? 'book' : 'audiobook', {
            'title': 'Volume $i',
            'series': i < 2 ? 'Cycle' : 'Other $i',
            'status': i < 2 ? 'unread' : 'finished',
            'pepehub_series_id': i < 2 ? 'cycle' : 'other-$i',
          }),
        ),
    ];
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
    await tester.enterText(
      find.byKey(const ValueKey('library-search')),
      'Cycle',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Выбрать несколько книг'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Выбрать показанные'));
    await tester.pumpAndSettle();
    expect(
      find.text('Выбрано: 2'),
      findsOneWidget,
      reason:
          'Both matching media types must be selected, other works stay out',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final format in ['epub', 'audio']) {
    testWidgets('external $format updates refresh the displayed archive', (
      tester,
    ) async {
      late String sourceId;
      await tester.runAsync(() async {
        await local.addBook('Original title', '', format);
        sourceId = (await local.records('book')).single.id;
        final item = library.emptyDraft(audio: format == 'audio').withValues({
          'title': 'Original title',
          'status': 'finished',
        });
        await library.add(item, sourceId);
        await local.setMeta(
          'obsidian-auto:personal:${item.id}',
          '{"title":"Original title"}',
        );
        await local.setMeta('library-section', 'metadata');
      });
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryPage(repository: local, assets: library.assets),
        ),
      );
      final dynamic state = tester.state(find.byType(LibraryPage));
      final LibraryService live = state.obsidianLibrary;
      await ready(
        tester,
        () => !state.loading && !live.loading && live.entries.isNotEmpty,
      );
      await tester.runAsync(() => live.idle);
      final beforeBooks = state.books;
      await tester.runAsync(() async {
        final source = (await local.record(sourceId))!;
        await local.put('book', sourceId, {
          ...source.payload!,
          'title': 'Updated title',
        });
        for (var i = 0; i < 3; i++) {
          local.notifyExternalChange();
        }
      });
      await ready(tester, () => !identical(state.books, beforeBooks));
      await tester.runAsync(() => live.idle);
      await tester.pumpAndSettle();
      final shown = live.entries.single.item.title;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.runAsync(() => live.idle);
      expect(shown, 'Updated title');
    });
  }
}
