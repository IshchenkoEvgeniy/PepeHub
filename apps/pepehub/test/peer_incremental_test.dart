import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pepehub/sync/peer/peer_files.dart';
import 'package:pepehub/sync/peer/peer_replica.dart';
import 'package:pepehub/sync/peer/peer_scan_monitor.dart';
import 'package:pepehub/sync/peer/peer_wire.dart';
import 'package:pepehub/vocabulary/vocabulary_repository.dart';
import 'package:pepehub/reader/reading_book_actions.dart';

import 'app_sync_service_test.dart' show ServiceFixture;
import 'peer_sync_test.dart' show ReplicaFixture, deviceA;

class CountedFiles extends LocalPeerFiles {
  final hashed = <String>[];
  CountedFiles(super.root);
  @override
  Future<String> digest(File file) {
    hashed.add(p.basename(file.path));
    return super.digest(file);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  tearDownAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = false);

  test('persisted scan cache reads only changed files and explicit content verification reads all', () async {
    final f = ReplicaFixture(deviceA);
    await f.open();
    addTearDown(f.close);
    await f.write('a.txt', [1, 2, 3]);
    await f.write('b.txt', [4, 5, 6]);
    final files = CountedFiles(f.root);
    PeerReplica replica() => PeerReplica(
      store: f.store,
      folder: f.replica.folder,
      device: deviceA,
      files: files,
      work: f.base,
    );
    await replica().scan();
    expect(files.hashed, unorderedEquals(['a.txt', 'b.txt']));
    files.hashed.clear();
    await replica().scan();
    expect(files.hashed, isEmpty);
    await f.write('a.txt', [7, 8, 9, 10]);
    await replica().scan();
    expect(files.hashed, ['a.txt']);
    files.hashed.clear();
    await replica().scan(invalidated: {'b.txt'});
    expect(files.hashed, ['b.txt']);
    files.hashed.clear();
    await replica().scan(forceHash: true);
    expect(files.hashed, unorderedEquals(['a.txt', 'b.txt']));
    final before = await f.store.entries(f.replica.folder.id);
    await f.root.rename('${f.root.path}-offline');
    await expectLater(replica().scan(), throwsStateError);
    expect(
      (await f.store.entries(f.replica.folder.id))
          .map((k, v) => MapEntry(k, v.hash)),
      before.map((k, v) => MapEntry(k, v.hash)),
    );
  });

  test(
    'SAF forwards cached stamps and force flag without private media paths',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(peerFilesChannel, (call) async {
            calls.add(call);
            return [
              {
                'path': 'book.txt',
                'hash': 'a' * 64,
                'bytes': 3,
                'stamp': 'document:42',
              },
            ];
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(peerFilesChannel, null),
      );
      final files = SafPeerFiles('content://test/tree/books');
      final first = await files.scan();
      await files.scan(
        cached: {first.single.path: first.single},
        invalidated: {'book.txt'},
        forceHash: true,
      );
      final args = calls.last.arguments as Map;
      expect((args['cached'] as Map)['book.txt']['stamp'], 'document:42');
      expect(args['forceHash'], true);
      expect(args['invalidated'], ['book.txt']);
      expect(args.containsKey('privatePath'), false);
    },
  );

  test('watcher marks source changes, ignores support files and retains changes arriving during scan', () async {
    final root = await Directory.systemTemp.createTemp('pepe-monitor-');
    addTearDown(() => root.delete(recursive: true));
    var notifications = 0;
    final monitor = PeerScanMonitor(root.path, () => notifications++);
    monitor.start();
    addTearDown(monitor.close);
    monitor.completed(monitor.generation, DateTime.now());
    expect(monitor.due(DateTime.now()), false);
    final event = Completer<void>();
    final watch = root.watch().listen((_) {
      if (!event.isCompleted) event.complete();
    });
    addTearDown(watch.cancel);
    await File(p.join(root.path, 'book.txt')).writeAsString('changed');
    await event.future.timeout(const Duration(seconds: 5));
    for (var n = 0; n < 100 && notifications == 0; n++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(notifications, greaterThan(0));
    expect(monitor.due(DateTime.now()), true);
    final generation = monitor.generation;
    monitor.dirty();
    monitor.completed(generation, DateTime.now());
    expect(monitor.due(DateTime.now()), true);
    monitor.completed(monitor.generation, DateTime.now());
    expect(monitor.due(DateTime.now().add(const Duration(hours: 2))), true);
  });

  Future<(ServiceFixture, ServiceFixture)> pair({
    bool app = false,
    bool library = false,
  }) async {
    final a = ServiceFixture(), b = ServiceFixture();
    await a.open(library: library);
    await b.open(library: library);
    addTearDown(a.close);
    addTearDown(b.close);
    await a.service.setEnabled(true);
    await b.service.pair(a.service.invitation('127.0.0.1'));
    await File(p.join(a.shared.path, 'book.txt')).writeAsString('Book text');
    await a.service.addFolder(
      a.shared.path,
      'Books',
      sharedWith: {b.service.deviceId},
    );
    await b.service.addFolder(
      b.shared.path,
      'Books',
      id: a.service.folders.single.id,
      sharedWith: {a.service.deviceId},
    );
    if (app) {
      await a.service.shareApplication(a.service.devices.single, true);
      await b.service.shareApplication(b.service.devices.single, true);
    }
    return (a, b);
  }

  test('shelf file deletion preserves history, queues approval remotely and does not publish a zero-length book descriptor', () async {
    final (a, b) = await pair(app: true, library: true);
    await a.service.configureFolder(a.service.folders.single, library: 'books');
    await b.service.configureFolder(b.service.folders.single, library: 'books');
    await b.service.syncDevice(b.service.devices.single);
    expect(b.service.error, isNull);
    final book = (await a.repo.records('book')).single;
    await ReadingBookActions(a.service.assets!).deleteForever(book.id);
    a.service.localFilesChanged();
    await b.service.syncDevice(b.service.devices.single);
    expect(b.service.error, isNull, reason: b.service.journal.export());
    expect(b.service.pendingDeletions, hasLength(1));
    expect(await File(p.join(b.shared.path, 'book.txt')).exists(), true);
    expect(a.service.application!.codec.localProblems, isEmpty);
    await b.service.resolveDeletion(
      b.service.pendingDeletions.single,
      delete: true,
    );
    await b.service.syncDevice(b.service.devices.single);
    expect(b.service.error, isNull, reason: b.service.journal.export());
    expect(
      await b.repo.meta(
        'reading-library-hidden:${(await b.repo.records('book')).single.id}',
      ),
      '1',
    );
  });

  test('conditional manifest omits unchanged entries and manual exchange still detects external edits', () async {
    final (a, b) = await pair();
    final peer = b.service.devices.single;
    await b.service.syncDevice(peer);
    expect(b.service.error, isNull);
    final cached = await b.service.store.remoteIndex(
      peer.id,
      b.service.folders.single.id,
    );
    expect(cached, isNotNull);
    final reply = await peerRequest(
      host: peer.host,
      port: peer.port,
      channel: peer.channel,
      key: (await b.service.secrets.read(peer.channel))!,
      request: {
        'op': 'manifest',
        'folder': b.service.folders.single.id,
        'from': b.service.deviceId,
        'to': peer.id,
        'deleteApproval': 1,
        'knownRevision': cached!.revision,
      },
    );
    expect(reply['unchanged'], true);
    expect(reply.containsKey('entries'), false);
    await File(p.join(a.shared.path, 'book.txt'))
        .writeAsString('New edition with more text');
    await b.service.syncDevice(peer);
    expect(b.service.error, isNull);
    expect(
      await File(p.join(b.shared.path, 'book.txt')).readAsString(),
      'New edition with more text',
    );
  });

  test('automatic idle probes converge then perform no exchanges; local changes and application changes restart exchange', () async {
    final (a, b) = await pair(app: true);
    final initiator = a.service.deviceId.compareTo(b.service.deviceId) < 0
        ? a
        : b;
    final other = identical(initiator, a) ? b : a;
    for (var n = 0; n < 4; n++) {
      await initiator.service.checkForChanges();
    }
    expect(initiator.service.error, isNull);
    expect(initiator.service.lastExchange, isNotNull);
    final last = initiator.service.lastExchange;
    await initiator.service.checkForChanges();
    await other.service.checkForChanges();
    expect(initiator.service.lastExchange, last);
    await File(p.join(other.shared.path, 'added.txt'))
        .writeAsString('New file');
    other.service.localFilesChanged();
    await initiator.service.checkForChanges();
    expect(
      await File(p.join(initiator.shared.path, 'added.txt')).readAsString(),
      'New file',
    );
    await VocabularyRepository(other.repo).save(front: 'word', back: 'слово');
    other.service.localFilesChanged();
    await initiator.service.checkForChanges();
    expect(
      (await VocabularyRepository(initiator.repo).list()).single.front,
      'word',
    );
    await initiator.service.setAutoSync(false);
    final stopped = initiator.service.lastExchange;
    await initiator.service.checkForChanges();
    expect(initiator.service.lastExchange, stopped);
  });
}
