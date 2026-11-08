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
      expect(find.byKey(const ValueKey('status-tab:remote')), findsNothing);
      final link = find.byKey(const ValueKey('open-unavailable'));
      expect(
        find.descendant(of: link, matching: find.textContaining(': 1')),
        findsOneWidget,
      );
      await tester.ensureVisible(link);
      await tester.tap(link);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('hidden-tab:2')));
      await tester.tap(find.byKey(const ValueKey('hidden-tab:2')));
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('hidden-row:remote-card'));
      expect(row, findsOneWidget);
      await tester.tap(
        find.descendant(of: row, matching: find.byTooltip('Удалить…')),
      );
      await tester.pumpAndSettle();
      // No file here, so the only choice is the trash.
      expect(find.text('Вместе с файлом'), findsNothing);
      await tester.tap(find.text('В корзину'));
      await tester.pumpAndSettle();
      expect(await repo.meta('book-shelf-removed:remote-card'), '1');
      expect((await repo.record('remote-card'))!.deleted, false);
      expect(await repo.meta('reading-note:keep'), contains('Keep this note'));
      expect(await repo.records('book'), hasLength(2));
      await tester.ensureVisible(find.byKey(const ValueKey('hidden-tab:3')));
      await tester.tap(find.byKey(const ValueKey('hidden-tab:3')));
      await tester.pumpAndSettle();
      expect(find.text('Remote book'), findsOneWidget);
      await tester.tap(find.byTooltip('Вернуть'));
      await tester.pumpAndSettle();
      expect(await repo.meta('book-shelf-removed:remote-card'), isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
