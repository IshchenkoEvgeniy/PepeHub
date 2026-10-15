import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/audio/audio_roots.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/main.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/media/library_folder_preference.dart';
import 'package:pepehub/ui/shelf_components.dart';

import 'video_player_tools_widget_test.dart' show ready;

Future<void> section(WidgetTester tester, PepeSection next) async {
  await tester.tap(
    find.descendant(
      of: find.byType(ShelfBottomBar),
      matching: find.text(next.label),
    ),
  );
  await ready(tester, () {
    final bar = tester.widget<ShelfBottomBar>(find.byType(ShelfBottomBar));
    return bar.navigation.current == next &&
        bar.navigation.enabled &&
        find.byType(CircularProgressIndicator).evaluate().isEmpty &&
        find
            .byType(LinearProgressIndicator)
            .evaluate()
            .every((e) => (e.widget as LinearProgressIndicator).value != null);
  });
}

void main() {
  test(
    'preferences reject foreign/missing roots and clean obsolete defaults',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = Repository(db);
      final audio = LibraryFolderPreference(repo, reading: false);
      final reading = LibraryFolderPreference(repo, reading: true);
      final root = audioRootKey('/audio');
      await repo.setMeta(root, '{}');
      await audio.set(root);
      expect(await audio.load(), root);
      expect(await reading.load(), isNull);
      await expectLater(reading.set(root), throwsStateError);
      await repo.db.customStatement('DELETE FROM metadata WHERE key=?', [root]);
      expect(await audio.load(), isNull);
      expect(await repo.meta(audio.key), isNull);
    },
  );

  testWidgets(
    'default folder survives restart and section changes, is separate per shelf, and can be unpinned',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = Repository(db),
          assets = AssetStore(
            Repository(db),
            Directory('unused-default-folder'),
          );
      final rootA = audioRootKey('/English'), rootB = audioRootKey('/Books');
      const readingRoot = 'reading-library-root:reading';
      for (final (key, name) in [(rootA, 'English'), (rootB, 'Books')]) {
        await repo.setMeta(
          key,
          jsonEncode({'root': '/$name', 'title': name, 'bookIds': <String>[]}),
        );
      }
      await repo.setMeta(
        readingRoot,
        jsonEncode({
          'path': '/Reading',
          'title': 'Reading',
          'bookIds': <String>[],
        }),
      );
      await LibraryFolderPreference(repo, reading: true).set(readingRoot);
      Future<void> open() async {
        await tester.pumpWidget(
          PepeHubApp(key: UniqueKey(), repository: repo, assets: assets),
        );
        await ready(
          tester,
          () =>
              find
                  .byKey(const ValueKey('library-folder'))
                  .evaluate()
                  .isNotEmpty &&
              tester
                  .widget<ShelfBottomBar>(find.byType(ShelfBottomBar))
                  .navigation
                  .enabled,
        );
      }

      DropdownButton<String?> dropdown() =>
          tester.widget(find.byKey(const ValueKey('library-folder')));
      await open();
      expect(dropdown().value, isNull);
      await tester.tap(find.byKey(const ValueKey('library-folder')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('English').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('library-pin-folder')));
      await ready(
        tester,
        () => find
            .byTooltip('Открепить папку по умолчанию')
            .evaluate()
            .isNotEmpty,
      );
      expect(
        await tester.runAsync(
          () => LibraryFolderPreference(repo, reading: false).load(),
        ),
        rootA,
      );
      await section(tester, PepeSection.books);
      expect(dropdown().value, readingRoot);
      await section(tester, PepeSection.video);
      await section(tester, PepeSection.audio);
      expect(dropdown().value, rootA);
      await open();
      expect(dropdown().value, rootA);
      await tester.tap(find.byKey(const ValueKey('library-pin-folder')));
      await ready(
        tester,
        () => find
            .byTooltip('Открывать эту папку по умолчанию')
            .evaluate()
            .isNotEmpty,
      );
      await open();
      expect(dropdown().value, isNull);
      expect(
        await tester.runAsync(
          () => LibraryFolderPreference(repo, reading: true).load(),
        ),
        readingRoot,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
