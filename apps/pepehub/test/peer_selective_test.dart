import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pepehub/sync/peer/peer_folder_files_page.dart';
import 'package:pepehub/sync/peer/peer_models.dart';
import 'package:pepehub/vocabulary/vocabulary_repository.dart';

import 'app_sync_service_test.dart' show ServiceFixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  tearDownAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = false);
  test('metadata-only and selected download preserve local files and deletion approval while application data keeps syncing', () async {
    final a = ServiceFixture(), b = ServiceFixture();
    await a.open();
    await b.open();
    addTearDown(a.close);
    addTearDown(b.close);
    await a.service.setEnabled(true);
    await b.service.pair(a.service.invitation('127.0.0.1'));
    await File(p.join(a.shared.path, 'one.mp4')).writeAsBytes([1, 2, 3]);
    await File(p.join(a.shared.path, 'two.mp4')).writeAsBytes([4, 5, 6]);
    await a.service.addFolder(
      a.shared.path,
      'Course',
      sharedWith: {b.service.deviceId},
    );
    await b.service.addFolder(
      b.shared.path,
      'Course',
      id: a.service.folders.single.id,
      sharedWith: {a.service.deviceId},
      download: 'none',
    );
    await a.service.shareApplication(a.service.devices.single, true);
    await b.service.shareApplication(b.service.devices.single, true);
    await VocabularyRepository(a.repo)
        .save(front: 'only text', back: 'только текст');
    await b.service.syncDevice(b.service.devices.single);
    expect(b.service.error, isNull, reason: b.service.journal.export());
    expect(await b.shared.list().where((e) => e is File).toList(), isEmpty);
    expect(
      (await VocabularyRepository(b.repo).list()).single.front,
      'only text',
    );
    expect(
      await b.service.filesForSelection(b.service.folders.single),
      hasLength(2),
    );
    await b.service.configureFolder(
      b.service.folders.single,
      download: 'selected',
      selectedPaths: {'one.mp4'},
    );
    await b.service.syncDevice(b.service.devices.single);
    expect(await File(p.join(b.shared.path, 'one.mp4')).readAsBytes(), [
      1,
      2,
      3,
    ]);
    expect(await File(p.join(b.shared.path, 'two.mp4')).exists(), false);
    final saved = (await b.service.store.folders()).single;
    expect(saved.selectedPaths, {'one.mp4'});
    expect(saved.download, 'selected');
    await b.service.configureFolder(saved, download: 'none');
    await File(p.join(a.shared.path, 'one.mp4')).delete();
    await b.service.syncDevice(b.service.devices.single);
    expect(await File(p.join(b.shared.path, 'one.mp4')).exists(), true);
    expect(b.service.pendingDeletions, isEmpty);
    await b.service.configureFolder(
      b.service.folders.single,
      download: 'selected',
    );
    await b.service.syncDevice(b.service.devices.single);
    expect(b.service.pendingDeletions, hasLength(1));
    expect(await File(p.join(b.shared.path, 'one.mp4')).exists(), true);
  });

  test('folder policy keeps old all-download behavior and validates selected paths', () {
    final folder = PeerFolder(id: 'id', name: 'Course', root: '/root');
    expect(folder.receives('any.mp4'), true);
    final selected = folder.copyWith(
      download: 'selected',
      selectedPaths: {'Module 1'},
    );
    expect(selected.receives('Module 1/one.mp4'), true);
    expect(selected.receives('Module 10/one.mp4'), false);
    expect(
      () => folder.copyWith(selectedPaths: {'../outside'}),
      throwsFormatException,
    );
    expect(
      PeerFolder.fromJson(folder.toJson()..remove('download')).download,
      'all',
    );
  });

  testWidgets(
    'selective file page scrolls on a phone with keyboard and enlarged text',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = ServiceFixture();
      await tester.runAsync(fixture.open);
      addTearDown(() => tester.runAsync(fixture.close));
      late PeerFolder folder;
      await tester.runAsync(() async {
        await File(p.join(fixture.shared.path, 'Lesson.mp4'))
            .writeAsBytes([1, 2, 3]);
        await fixture.service.addFolder(
          fixture.shared.path,
          'English course',
          download: 'selected',
        );
        folder = fixture.service.folders.single;
      });
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.3),
              viewInsets: const EdgeInsets.only(bottom: 300),
            ),
            child: child!,
          ),
          home: PeerFolderFilesPage(service: fixture.service, folder: folder),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('Lesson.mp4'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Lesson.mp4'), findsOneWidget);
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
