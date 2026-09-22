import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/main.dart';

import 'dart:io';
import 'dart:convert';

import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/audio/audio_roots.dart';

void main() {
  testWidgets(
    'root manager opens from library, renames and removes on a phone',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = Repository(db);
      final assets = AssetStore(repo, Directory('unused'));
      await repo.setMeta(
        audioRootKey('/Books'),
        jsonEncode({'root': '/Books', 'title': 'Books', 'bookIds': <String>[]}),
      );
      await tester.pumpWidget(PepeHubApp(repository: repo, assets: assets));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Папки библиотеки'));
      await tester.pumpAndSettle();
      expect(find.text('Books'), findsOneWidget);
      await tester.tap(find.text('Переименовать'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Моя полка');
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(find.text('Моя полка'), findsOneWidget);
      await tester.tap(find.text('Убрать из библиотеки'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Убрать'));
      await tester.pumpAndSettle();
      expect(await AudioRoots(assets).list(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('library form persists a card and narrow layout stays usable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repository = Repository(db);
    await tester.pumpWidget(PepeHubApp(repository: repository));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Добавить книгу'),
      250,
      scrollable: find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Добавить книгу'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField).first,
      'Книга для проверки',
    );
    await tester.tap(find.text('Добавить'));
    await tester.pumpAndSettle();
    expect(
      (await repository.records('book')).single.title,
      'Книга для проверки',
    );
    expect(tester.takeException(), isNull);
  });
}
