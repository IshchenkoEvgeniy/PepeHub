import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pepehub/sync/peer/peer_files.dart';
import 'package:pepehub/sync/peer/peer_history.dart';
import 'package:pepehub/sync/peer/peer_local_history.dart';
import 'package:pepehub/sync/peer/peer_models.dart';

import 'app_sync_service_test.dart' show ServiceFixture;
import 'peer_sync_test.dart' show deviceA, folderId;

class RefusingCommitFiles extends LocalPeerFiles {
  RefusingCommitFiles(super.root, {super.history});
  @override
  Future<File> publishFile(File staged, String destination) async =>
      throw const FileSystemException('Simulated failed final rename');
}

class CleaningFailedCommitFiles extends LocalPeerFiles {
  CleaningFailedCommitFiles(super.root, {super.history});
  @override
  Future<File> publishFile(File staged, String destination) async {
    await maintainHistory(clear: true);
    throw const FileSystemException('Simulated failed final rename');
  }
}

class ChangingSourceFiles extends LocalPeerFiles {
  ChangingSourceFiles(super.root, {super.history});
  @override
  Future<String?> hash(String path) async {
    final digest = await super.hash(path);
    await File(p.join(root.path, path)).writeAsBytes([9]);
    return digest;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory base, root;
  final now = DateTime.utc(2026, 10, 18, 12);
  setUp(() async {
    base = await Directory.systemTemp.createTemp('pepe-history-test-');
    root = await Directory(p.join(base.path, 'shared')).create();
  });
  tearDown(() async {
    final actual = await base.resolveSymbolicLinks();
    final temp = await Directory.systemTemp.resolveSymbolicLinks();
    if (!p.isWithin(temp, actual) ||
        !p.basename(actual).startsWith('pepe-history-test-')) {
      throw StateError('Unexpected test cleanup root');
    }
    await base.delete(recursive: true);
  });

  Future<File> write(String relative, List<int> bytes) async {
    final file = File(p.join(root.path, relative));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    return file;
  }

  Future<File> version(int id, DateTime at, List<int> bytes) => write(
    '.pepehub/p2p/versions/v1-${at.millisecondsSinceEpoch}-${id.toRadixString(16).padLeft(32, '0')}-book.epub',
    bytes,
  );
  Future<void> replace(
    LocalPeerFiles files,
    List<int> previous,
    List<int> content,
  ) async {
    final entry = PeerFileEntry(
      path: 'book.epub',
      hash: peerDigest(content),
      bytes: content.length,
      clock: {deviceA: 1},
    );
    final staged = await files.stage(entry);
    await staged.prepare();
    await staged.append(0, content);
    await staged.publish(peerDigest(previous));
  }

  test('new and previously stored folders default to disabled history; explicit settings survive persistence', () {
    final folder = PeerFolder(id: folderId, name: 'Books', root: root.path);
    expect(folder.history.enabled, false);
    final legacy = folder.toJson()..remove('history');
    expect(PeerFolder.fromJson(legacy).history.enabled, false);
    final configured = folder.copyWith(
      history: const PeerHistorySettings(
        enabled: true,
        maxDays: 7,
        maxBytes: 123,
      ),
    );
    final restored = PeerFolder.fromJson(configured.toJson());
    expect(restored.history.toJson(), configured.history.toJson());
    expect(restored.copyWith(paused: true).history.enabled, true);
  });
  test('disabled history leaves no previous payload after replacement or confirmed deletion', () async {
    final files = LocalPeerFiles(root);
    await write('book.epub', [1, 2, 3]);
    await replace(files, [1, 2, 3], [4, 5]);
    expect(await File(p.join(root.path, 'book.epub')).readAsBytes(), [4, 5]);
    expect((await files.maintainHistory()).files, 0);
    expect(
      await Directory(p.join(root.path, '.pepehub/p2p/staging'))
          .list()
          .toList(),
      isEmpty,
    );
    await files.remove('book.epub', peerDigest([4, 5]));
    expect(await File(p.join(root.path, 'book.epub')).exists(), false);
    expect((await files.maintainHistory()).files, 0);
  });
  test(
    'cleanup during a failed publication preserves the rollback file',
    () async {
      await write('book.epub', [1]);
      final files = CleaningFailedCommitFiles(
        root,
        history: const PeerHistorySettings(enabled: true),
      );
      await expectLater(
        replace(files, [1], [2]),
        throwsA(isA<FileSystemException>()),
      );
      expect(await File(p.join(root.path, 'book.epub')).readAsBytes(), [1]);
    },
  );

  test('enabled history archives replacements and deletions in the service directory without copying current media', () async {
    final files = LocalPeerFiles(
      root,
      history: const PeerHistorySettings(enabled: true),
    );
    final original = await write('book.epub', [1, 2, 3]);
    await original.setLastModified(DateTime.utc(2001));
    await replace(files, [1, 2, 3], [4, 5]);
    expect((await files.maintainHistory()).files, 1);
    final archived = await Directory(p.join(root.path, '.pepehub/p2p/versions'))
        .list()
        .toList();
    expect(await (archived.single as File).readAsBytes(), [1, 2, 3]);
    expect(await files.scan(), hasLength(1));
    await files.remove('book.epub', peerDigest([4, 5]));
    expect((await files.maintainHistory()).files, 2);
    expect(await files.scan(), isEmpty);
    expect(await root.list().where((e) => e is File).toList(), isEmpty);
  });
  for (final enabled in [false, true]) {
    test(
      'concurrent source edits are restored rather than overwritten with history enabled=$enabled',
      () async {
        final files = ChangingSourceFiles(
          root,
          history: PeerHistorySettings(enabled: enabled),
        );
        await write('book.epub', [1, 2, 3]);
        await expectLater(replace(files, [1, 2, 3], [4]), throwsStateError);
        expect(await File(p.join(root.path, 'book.epub')).readAsBytes(), [9]);
        expect((await files.maintainHistory()).files, 0);
      },
    );
    test(
      'a failed final rename restores the original book with history enabled=$enabled',
      () async {
        final files = RefusingCommitFiles(
          root,
          history: PeerHistorySettings(enabled: enabled),
        );
        await write('book.epub', [1, 2, 3]);
        await expectLater(
          replace(files, [1, 2, 3], [4]),
          throwsA(isA<FileSystemException>()),
        );
        expect(await File(p.join(root.path, 'book.epub')).readAsBytes(), [
          1,
          2,
          3,
        ]);
        expect((await files.maintainHistory()).files, 0);
      },
    );
  }
  test('legacy copies move out of nested book folders and remain intact while history is disabled', () async {
    final stamp = now.subtract(const Duration(days: 90)).millisecondsSinceEpoch;
    final first = await write('.pepehub-version-$stamp-abcdef12-book.epub', [
      1,
      2,
    ]);
    final second = await write(
      'course/.pepehub-version-$stamp-abcdef34-lesson.pdf',
      [3],
    );
    final untouched = await write('.pepehub-version-unknown.txt', [9]);
    await write('current.epub', [4]);
    final files = LocalPeerFiles(root);
    final report = await files.maintainHistory(migrate: true, prune: true);
    expect(report.moved, 2);
    expect(report.files, 2);
    expect(report.legacy, 0);
    expect(report.removed, 0);
    expect(await first.exists(), false);
    expect(await second.exists(), false);
    expect(await untouched.readAsBytes(), [9]);
    final content = [
      for (final file in await Directory(
        p.join(root.path, '.pepehub/p2p/versions'),
      ).list().toList())
        ...(await (file as File).readAsBytes()),
    ]..sort();
    expect(content, [1, 2, 3]);
    expect((await files.scan()).single.path, 'current.epub');
    expect((await files.maintainHistory(migrate: true)).moved, 0);
  });
  test('age and byte limits remove the oldest versions using archival time, preserving the current book', () async {
    final old = await version(1, now.subtract(const Duration(days: 40)), [
      1,
      2,
      3,
    ]);
    final middle = await version(2, now.subtract(const Duration(days: 2)), [
      4,
      5,
      6,
      7,
    ]);
    final newest = await version(3, now.subtract(const Duration(days: 1)), [
      8,
      9,
      10,
      11,
      12,
    ]);
    await newest.setLastModified(DateTime.utc(2000));
    final current = await write('current.epub', [99]);
    final history = PeerLocalHistory(
      () async => root.path,
      const PeerHistorySettings(enabled: true, maxDays: 30, maxBytes: 8),
      now: () => now,
    );
    final report = await history.maintainHistory(prune: true);
    expect(report.removed, 2);
    expect(report.reclaimed, 7);
    expect(report.bytes, 5);
    expect(await old.exists(), false);
    expect(await middle.exists(), false);
    expect(await newest.readAsBytes(), [8, 9, 10, 11, 12]);
    expect(await current.readAsBytes(), [99]);
  });
  test('disabling history preserves old copies even if they exceed the configured limits', () async {
    final old = await version(1, now.subtract(const Duration(days: 90)), [
      1,
      2,
      3,
    ]);
    final history = PeerLocalHistory(
      () async => root.path,
      const PeerHistorySettings(maxDays: 1, maxBytes: 1),
      now: () => now,
    );
    expect((await history.maintainHistory(prune: true)).removed, 0);
    expect(await old.readAsBytes(), [1, 2, 3]);
  });
  test('explicit cleanup removes only recognized versions, preserving books, unknown files and unfinished transfers', () async {
    await version(1, now, [1]);
    final stamp = now.millisecondsSinceEpoch;
    final legacy = await write(
      'nested/.pepehub-version-$stamp-abcdef12-book.epub',
      [2],
    );
    final unknown = await write('.pepehub/p2p/versions/my-important-file.txt', [
      3,
    ]);
    final suspicious = await write(
      '.pepehub/p2p/versions/v1-not-a-version.epub',
      [4],
    );
    final stage = await write('.pepehub/p2p/staging/download.part', [5]);
    final current = await write('book.epub', [6]);
    final report = await LocalPeerFiles(root).maintainHistory(clear: true);
    expect(report.removed, 2);
    expect(report.files, 0);
    expect(report.unknown, 2);
    expect(await legacy.exists(), false);
    for (final file in [unknown, suspicious, stage, current]) {
      expect(await file.exists(), true);
    }
  });
  test(
    'cleanup never follows a history symlink outside the shared root',
    () async {
      if (Platform.isWindows) {
        markTestSkipped('Symbolic links need a Windows privilege');
        return;
      }
      final outside = File(p.join(base.path, 'outside.epub'));
      await outside.writeAsBytes([9]);
      final directory = await Directory(
        p.join(root.path, '.pepehub/p2p/versions'),
      ).create(recursive: true);
      await Link(
        p.join(
          directory.path,
          'v1-${now.millisecondsSinceEpoch}-${'a' * 32}-book.epub',
        ),
      ).create(outside.path);
      final report = await LocalPeerFiles(root).maintainHistory(clear: true);
      expect(report.removed, 0);
      expect(report.unknown, 1);
      expect(await outside.readAsBytes(), [9]);
    },
  );
  test('folder settings persist and migration runs while the sync network is disabled', () async {
    final fixture = ServiceFixture();
    await fixture.open();
    addTearDown(fixture.close);
    await fixture.service.addFolder(fixture.shared.path, 'Books');
    var folder = fixture.service.folders.single;
    expect(folder.history.enabled, false);
    final legacy = File(
      p.join(
        fixture.shared.path,
        '.pepehub-version-${now.millisecondsSinceEpoch}-abcdef12-book.epub',
      ),
    );
    await legacy.writeAsBytes([1]);
    final report = await fixture.service.manageHistory(folder);
    expect(report.moved, 1);
    expect(report.files, 1);
    expect(fixture.service.enabled, false);
    await fixture.service.configureFolder(
      folder,
      history: const PeerHistorySettings(enabled: true, maxDays: 90),
    );
    folder = (await fixture.service.store.folders()).single;
    expect(folder.history.enabled, true);
    expect(folder.history.maxDays, 90);
    await fixture.service.configureFolder(
      folder,
      history: const PeerHistorySettings(),
    );
    expect((await fixture.service.manageHistory(folder)).files, 1);
    expect((await fixture.service.manageHistory(folder, clear: true)).files, 0);
  });
  test('SAF maintenance and mutations carry the local policy through the native bridge', () async {
    final methods = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(peerFilesChannel, (call) async {
          methods.add(call.method);
          final args = call.arguments as Map;
          expect(args['root'], 'content://test/root');
          expect((args['history'] as Map)['enabled'], true);
          expect((args['history'] as Map)['maxDays'], 7);
          if (call.method == 'history') {
            return {'files': 2, 'bytes': 30, 'moved': 1};
          }
          return {
            'warnings': ['provider warning'],
          };
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(peerFilesChannel, null),
    );
    final warnings = <String>[];
    final files = SafPeerFiles(
      'content://test/root',
      history: const PeerHistorySettings(enabled: true, maxDays: 7),
      onHistoryWarning: warnings.add,
    );
    expect((await files.maintainHistory(migrate: true)).moved, 1);
    await files.remove('book.epub', peerDigest([1]));
    final stage = await files.stage(
      PeerFileEntry(
        path: 'book.epub',
        hash: peerDigest([2]),
        bytes: 1,
        clock: {deviceA: 1},
      ),
    );
    await stage.publish(peerDigest([1]));
    expect(methods, ['history', 'remove', 'stage_publish']);
    expect(warnings, hasLength(2));
  });
}
