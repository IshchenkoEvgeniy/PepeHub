import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/main.dart';
import 'package:pepehub/media/asset_store.dart';

void main() {
  testWidgets(
    'remote cards have separate counts, explain sources and can be hidden without deleting history',
    (tester) async {
      tester.view.physicalSize = const Size(420, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = Repository(db);
      await repo.setMeta('library-section', 'reading');
      await repo.addBook('Manual plan', '', 'epub');
      await repo.put('book', 'remote-card', {
        'title': 'Remote book',
        'authors': [],
        'format': 'epub',
        'status': 'planned',
      });
      await repo.setMeta(
        'reading-note:keep',
        jsonEncode({'bookId': 'remote-card', 'text': 'Keep this note'}),
      );
      await db.customStatement(
        'CREATE TABLE peer_app_alias(kind TEXT,local_id TEXT,shared_id TEXT,data TEXT)',
      );
      await db.customStatement('INSERT INTO peer_app_alias VALUES(?,?,?,?)', [
        'book',
        'remote-card',
        'shared-card',
        jsonEncode({
          'descriptor': {
            'kind': 'book',
            'sources': [
              {
                'name': 'Remote.epub',
                'path': 'Books/Remote.epub',
                'folder': 'remote-folder',
              },
            ],
          },
        }),
      ]);
      await repo.setMeta(
        'peer-book-origin:shared-card',
        jsonEncode({'name': 'My phone', 'receivedAt': '2026-10-25T12:00:00Z'}),
      );
      await tester.pumpWidget(
        PepeHubApp(
          repository: repo,
          assets: AssetStore(repo, Directory('unused')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('book-card:remote-card')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('status-tab:all')),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('status-tab:remote')),
      );
      await tester.tap(find.byKey(const ValueKey('status-tab:remote')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('book-card:remote-card')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const ValueKey('book-card:remote-card')));
      await tester.pumpAndSettle();
      expect(find.text('Источник и файл'), findsOneWidget);
      expect(find.textContaining('Books/Remote.epub'), findsOneWidget);
      expect(find.textContaining('My phone'), findsOneWidget);
      await tester.tap(find.text('Закрыть'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Выбрать видимые книги'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Действия с выбранными'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Убрать из списка без удаления файлов'));
      await tester.pumpAndSettle();
      expect(await repo.meta('reading-library-hidden:remote-card'), '1');
      expect((await repo.record('remote-card'))!.deleted, false);
      expect(await repo.meta('reading-note:keep'), contains('Keep this note'));
      expect(await repo.records('book'), hasLength(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
