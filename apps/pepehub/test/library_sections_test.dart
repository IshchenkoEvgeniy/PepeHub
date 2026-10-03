import 'dart:io';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/main.dart';
import 'package:pepehub/media/asset_store.dart';

void main() {
  testWidgets(
    'drawer separates existing cards, folders, adding and reading statistics',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = Repository(db);
      await repo.addBook('Audio story', '', 'audio');
      await repo.addBook('Text story', '', 'epub');
      final records = await repo.records('book');
      await repo.addSession(
        records.firstWhere((b) => b.title == 'Audio story'),
        20,
      );
      await repo.addSession(
        records.firstWhere((b) => b.title == 'Text story'),
        5,
      );
      await repo.setMeta(
        'audio-library-root:a',
        jsonEncode({'root': '/audio', 'title': 'Audio folder', 'bookIds': []}),
      );
      await repo.setMeta(
        'reading-library-root:b',
        jsonEncode({
          'path': '/reading',
          'title': 'Reading folder',
          'bookIds': [],
        }),
      );
      await tester.pumpWidget(
        PepeHubApp(
          repository: repo,
          assets: AssetStore(repo, Directory('unused')),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Audio story'),
        240,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Audio story'), findsOneWidget);
      expect(find.text('Text story'), findsNothing);
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Книги'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Text story'),
        240,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Text story'), findsOneWidget);
      expect(find.text('Audio story'), findsNothing);
      expect(await repo.meta('library-section'), 'reading');
      await tester.tap(find.byTooltip('Добавить'));
      await tester.pumpAndSettle();
      expect(find.text('Импорт книги'), findsOneWidget);
      expect(find.text('Копировать аудиофайлы'), findsNothing);
      await tester.tapAt(const Offset(10, 400));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Папки библиотеки'));
      await tester.pumpAndSettle();
      expect(find.text('Reading folder'), findsOneWidget);
      expect(find.text('Audio folder'), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Статистика чтения'));
      await tester.pumpAndSettle();
      expect(find.text('5 мин'), findsWidgets);
      expect(find.text('Audio story'), findsNothing);
      expect(find.text('1 день'), findsOneWidget);
      await tester.tap(find.text('Произвольный'));
      await tester.pumpAndSettle();
      expect(find.text('Произвольный период'), findsOneWidget);
      await tester.tap(find.text('Применить'));
      await tester.pumpAndSettle();
      expect(find.text('5 мин'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
}
