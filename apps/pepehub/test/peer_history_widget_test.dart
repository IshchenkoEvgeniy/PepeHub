import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pepehub/sync/peer/peer_history_page.dart';
import 'package:pepehub/sync/peer/peer_sync_page.dart';

import 'app_sync_service_test.dart' show ServiceFixture;

void main() {
  testWidgets(
    'history opens from the sync page, defaults off, saves local limits and explicitly clears backups at large text',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late ServiceFixture fixture;
      late File current, legacy;
      await tester.runAsync(() async {
        fixture = ServiceFixture();
        await fixture.open();
        await fixture.service.addFolder(fixture.shared.path, 'English');
        current = File(p.join(fixture.shared.path, 'book.epub'));
        await current.writeAsBytes([1, 2, 3]);
        legacy = File(
          p.join(
            fixture.shared.path,
            '.pepehub-version-${DateTime.now().millisecondsSinceEpoch}-abcdef12-book.epub',
          ),
        );
        await legacy.writeAsBytes([9]);
      });
      Future<void> waitFor(bool Function() condition) async {
        for (var n = 0; n < 100 && !condition(); n++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        expect(condition(), true);
        await tester.pumpAndSettle();
      }

      Future<void> tapVisible(Finder target) async {
        if (target.evaluate().isEmpty) {
          await tester.scrollUntilVisible(target, 300);
        }
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        await tester.tap(target);
        await tester.pump();
      }

      try {
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!,
            ),
            home: PeerSyncPage(service: fixture.service),
          ),
        );
        await tester.pumpAndSettle();
        await tapVisible(find.text('История и очистка'));
        await waitFor(() => !fixture.service.busy && !legacy.existsSync());
        expect(find.byType(PeerHistoryPage), findsOneWidget);
        expect(
          tester
              .widget<SwitchListTile>(find.byKey(const Key('history-enabled')))
              .value,
          false,
        );
        expect(fixture.service.folders.single.history.enabled, false);
        expect(await tester.runAsync(legacy.exists), false);
        expect(tester.takeException(), null);

        await tapVisible(find.byKey(const Key('history-enabled')));
        await tapVisible(find.text('Сохранить настройки'));
        await waitFor(
          () =>
              fixture.service.folders.single.history.enabled &&
              !fixture.service.busy,
        );
        expect(fixture.service.folders.single.history.maxDays, 30);
        expect(
          fixture.service.folders.single.history.maxBytes,
          500 * 1024 * 1024,
        );
        await tapVisible(find.text('Очистить историю'));
        expect(find.text('Очистить историю версий?'), findsOneWidget);
        await tester.tap(find.text('Отмена'));
        await tester.pumpAndSettle();
        expect(find.textContaining('В истории: 1 файлов'), findsOneWidget);
        await tapVisible(find.text('Очистить историю'));
        await tester.tap(find.widgetWithText(FilledButton, 'Очистить историю'));
        await tester.pump();
        await waitFor(
          () =>
              find.textContaining('В истории: 0 файлов').evaluate().isNotEmpty,
        );
        expect(await tester.runAsync(current.readAsBytes), [1, 2, 3]);
        expect(tester.takeException(), null);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(fixture.close);
      }
    },
  );
}
