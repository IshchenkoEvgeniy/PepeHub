import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/sync/peer/app_sync_review_page.dart';
import 'package:pepehub/sync/peer/peer_service.dart';
import 'package:pepehub/ui/app_theme.dart';

import 'app_sync_test.dart' show AppFixture;
import 'peer_sync_test.dart' show MemorySecrets, deviceA, deviceB;
import 'video_player_tools_widget_test.dart' show ready;

void main() {
  testWidgets('TXT sync fragment follows the real single-line offset', (
    tester,
  ) async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    addTearDown(
      () => driftRuntimeOptions.dontWarnAboutMultipleDatabases = false,
    );
    final a = AppFixture(deviceA), b = AppFixture(deviceB);
    late PeerSyncService service;
    final source = [
      'Chapter 1',
      for (var i = 0; i < 400; i++) '  Paragraph $i with some text.',
      '  TARGET quote at the saved position.',
    ].join('\n');
    final target = source.indexOf('TARGET');
    late int index;
    await tester.runAsync(() async {
      await a.open();
      await b.open();
      final assets = AssetStore(
        b.repo,
        Directory('${b.files.root.path}/assets'),
      );
      for (final fixture in [a, b]) {
        await fixture.files.write('book.txt', utf8.encode(source));
        await fixture.files.replica.scan();
        final store = fixture == b
            ? assets
            : AssetStore(a.repo, Directory('${a.files.root.path}/assets'));
        final asset = await store.importBook(
          XFile('${fixture.files.root.path}/book.txt'),
        );
        await fixture.repo.setMeta(
          'reader:${asset.hash}',
          jsonEncode({'chapter': 0, 'textOffset': fixture == a ? target : 20}),
        );
      }
      await b.pull(a);
      await b.repo.setMeta('peer-sync-device', deviceB);
      await b.files.store.saveFolders([b.files.replica.folder]);
      service = PeerSyncService(
        b.files.store,
        assets: assets,
        secrets: MemorySecrets(),
        observeLifecycle: false,
      );
      await service.initialize();
      final issue = (await service.application!.issues()).singleWhere(
        (i) => i.key.startsWith('position:reader:'),
      );
      index = issue.versions.indexWhere(
        (v) => v.value!['textOffset'] == target,
      );
    });
    addTearDown(() async {
      service.dispose();
      await tester.runAsync(() async {
        await a.close();
        await b.close();
      });
    });
    await tester.pumpWidget(
      MaterialApp(home: AppSyncReviewPage(service: service)),
    );
    await ready(
      tester,
      () => find.text('Показать фрагмент').evaluate().length == 2,
    );
    final button = find.text('Показать фрагмент').at(index);
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pump();
    await ready(
      tester,
      () => find
          .byType(SelectableText)
          .evaluate()
          .any(
            (e) =>
                (e.widget as SelectableText).data?.contains('TARGET quote') ==
                true,
          ),
    );
    expect(find.textContaining('TARGET quote'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'phone reviews concurrent positions and explicitly applies one without losing the other before selection',
    (tester) async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      addTearDown(
        () => driftRuntimeOptions.dontWarnAboutMultipleDatabases = false,
      );
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final a = AppFixture(deviceA), b = AppFixture(deviceB);
      late PeerSyncService service;
      await tester.runAsync(() async {
        await a.open();
        await b.open();
        final first = await a.course(), second = await b.course();
        await a.position(first, 42000);
        await b.position(second, 9000);
        await b.pull(a);
        await b.repo.setMeta('peer-sync-device', deviceB);
        await b.files.store.saveFolders([b.files.replica.folder]);
        service = PeerSyncService(
          b.files.store,
          secrets: MemorySecrets(),
          observeLifecycle: false,
        );
        await service.initialize();
      });
      addTearDown(() async {
        service.dispose();
        await tester.runAsync(() async {
          await a.close();
          await b.close();
        });
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.data(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: AppSyncReviewPage(service: service),
        ),
      );
      await ready(
        tester,
        () => find.text('Позиция видео').evaluate().isNotEmpty,
      );
      expect(find.textContaining('0:00:42'), findsOneWidget);
      expect(find.textContaining('0:00:09'), findsOneWidget);
      expect(tester.takeException(), isNull);
      late int index;
      await tester.runAsync(() async {
        final issue = (await service.application!.issues()).singleWhere(
          (i) => i.key.startsWith('position:video:'),
        );
        index = issue.versions.indexWhere(
          (v) => v.value!['positionMs'] == 42000,
        );
      });
      final button = find.text('Использовать эту версию').at(index);
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Применить'));
      await tester.pump();
      await ready(
        tester,
        () => find
            .text('Спорных или ожидающих данных нет.')
            .evaluate()
            .isNotEmpty,
      );
      await tester.runAsync(() async {
        final lesson = (await b.videos.lessons()).single;
        expect((await b.videos.progress(lesson))!.positionMs, 42000);
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
