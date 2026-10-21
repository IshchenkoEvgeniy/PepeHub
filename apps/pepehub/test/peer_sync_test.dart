import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/sync/peer/peer_files.dart';
import 'package:pepehub/sync/peer/peer_models.dart';
import 'package:pepehub/sync/peer/peer_replica.dart';
import 'package:pepehub/sync/peer/peer_service.dart';
import 'package:pepehub/sync/peer/peer_sync_page.dart';
import 'package:pepehub/sync/peer/peer_store.dart';
import 'package:pepehub/sync/peer/peer_wire.dart';

const deviceA = '11111111-1111-4111-8111-111111111111';
const deviceB = '22222222-2222-4222-8222-222222222222';
const folderId = '33333333-3333-4333-8333-333333333333';

class MemorySecrets implements PeerSecrets {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class ReplicaFixture {
  final String id;
  final db = AppDatabase(NativeDatabase.memory());
  late final store = PeerStore(Repository(db));
  late Directory base, root;
  late PeerReplica replica;
  ReplicaFixture(this.id);
  Future<void> open() async {
    base = await Directory.systemTemp.createTemp('pepe-peer-test-');
    root = await Directory(p.join(base.path, 'shared')).create();
    await store.initialize();
    replica = PeerReplica(
      store: store,
      folder: PeerFolder(id: folderId, name: 'Course', root: root.path),
      device: id,
      files: LocalPeerFiles(root),
      work: Directory(p.join(base.path, 'work')),
    );
  }

  Future<void> write(String path, List<int> bytes) async {
    final file = File(p.join(root.path, path));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
  }

  Future<void> receive(ReplicaFixture source) async {
    for (final entry in (await source.store.entries(folderId)).values) {
      await replica.apply(
        entry,
        (path, hash, offset, count) =>
            source.replica.files.read(path, offset, count),
      );
    }
  }

  Future<void> close() async {
    await db.close();
    await base.delete(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Each fixture deliberately represents a different device with its own executor.
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  tearDownAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = false);
  testWidgets(
    'sync page fits a narrow phone with large text and no cloud gate',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase(NativeDatabase.memory());
      final service = PeerSyncService(
        PeerStore(Repository(db)),
        secrets: MemorySecrets(),
        observeLifecycle: false,
      );
      await tester.runAsync(service.initialize);
      service.devices = [
        const PeerDevice(
          id: deviceB,
          name: 'Мой компьютер с длинным названием',
          host: '192.168.0.102',
          port: peerPort,
          channel: folderId,
        ),
      ];
      service.folders = [
        PeerFolder(
          id: folderId,
          name: 'Английский язык',
          root: 'C:/courses/English',
          devices: {deviceB},
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: PeerSyncPage(service: service),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Прямая синхронизация'), findsOneWidget);
      expect(service.enabled, false);
      expect(service.port, 0);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(find.text('Добавить папку'), 250);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('Облако — дополнительный режим'),
        250,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      service.dispose();
      await tester.runAsync(db.close);
    },
  );
  test('portable paths reject traversal, private files, reserved names and alternate streams', () {
    for (final path in [
      '',
      '../a',
      '/a',
      'a/../b',
      'a\\b',
      'C:/a',
      'a:stream',
      'CON.txt',
      'dir/LPT1',
      '.pepehub/key',
      '.pepehub-version-x',
      'a./b',
      'a /b',
      'x\u0000y',
    ]) {
      expect(() => peerPath(path), throwsFormatException, reason: path);
    }
    expect(peerPath('Курс/Урок 1.mp4'), 'Курс/Урок 1.mp4');
    expect(comparePeerClocks({deviceA: 1}, {deviceA: 2}), -1);
    expect(comparePeerClocks({deviceA: 2}, {deviceA: 1}), 1);
    expect(comparePeerClocks({deviceA: 1}, {deviceB: 1}), 2);
    expect(comparePeerClocks({deviceA: 1}, {deviceA: 1}), 0);
    expect(mergePeerClocks({deviceA: 2}, {deviceA: 1, deviceB: 3}), {
      deviceA: 2,
      deviceB: 3,
    });
  });
  group('replicas', () {
    late ReplicaFixture a, b;
    setUp(() async {
      a = ReplicaFixture(deviceA);
      b = ReplicaFixture(deviceB);
      await a.open();
      await b.open();
    });
    tearDown(() async {
      await a.close();
      await b.close();
    });
    test(
      'two-way contents converge and repeated exchange is idempotent',
      () async {
        await a.write('course/lesson.txt', [1, 2, 3]);
        await b.write('notes.txt', [4, 5]);
        await a.replica.scan();
        await b.replica.scan();
        await b.receive(a);
        await a.receive(b);
        expect(
          await File(p.join(b.root.path, 'course/lesson.txt')).readAsBytes(),
          [1, 2, 3],
        );
        expect(await File(p.join(a.root.path, 'notes.txt')).readAsBytes(), [
          4,
          5,
        ]);
        final before = (await a.store.entries(folderId))
            .map((k, v) => MapEntry(k, v.toJson()));
        await a.receive(b);
        expect(
          (await a.store.entries(folderId))
              .map((k, v) => MapEntry(k, v.toJson())),
          before,
        );
      },
    );
    test('concurrent edits retain both versions and converge to the same canonical file', () async {
      await a.write('lesson.txt', [1]);
      await a.replica.scan();
      await b.receive(a);
      await a.write('lesson.txt', [2]);
      await b.write('lesson.txt', [3]);
      await a.replica.scan();
      await b.replica.scan();
      await a.receive(b);
      await b.receive(a);
      await a.receive(b);
      expect(
        await File(p.join(a.root.path, 'lesson.txt')).readAsBytes(),
        await File(p.join(b.root.path, 'lesson.txt')).readAsBytes(),
      );
      final entries = await a.store.entries(folderId);
      expect(entries.length, 2);
      final bytes = [
        for (final e in entries.values)
          (await File(p.join(a.root.path, e.path)).readAsBytes()).single,
      ]..sort();
      expect(bytes, [2, 3]);
      expect(
        (await b.store.entries(folderId)).keys.toSet(),
        entries.keys.toSet(),
      );
    });
    test(
      'deletion waits for confirmation and disabled history leaves no backup',
      () async {
        await a.write('lesson.txt', [1]);
        await a.replica.scan();
        await b.receive(a);
        await File(p.join(a.root.path, 'lesson.txt')).delete();
        await a.replica.scan();
        await b.receive(a);
        expect(await File(p.join(b.root.path, 'lesson.txt')).exists(), true);
        await b.replica.resolveDeletion(
          (await b.store.pendingDeletions()).single,
          delete: true,
        );
        expect(await File(p.join(b.root.path, 'lesson.txt')).exists(), false);
        final versions = Directory(
          p.join(b.root.path, '.pepehub/p2p/versions'),
        );
        expect(await versions.exists(), false);
        expect((await b.store.entries(folderId))['lesson.txt']!.deleted, true);
      },
    );
    test(
      'concurrent delete and edit preserves the edit on both devices',
      () async {
        await a.write('lesson.txt', [1]);
        await a.replica.scan();
        await b.receive(a);
        await File(p.join(a.root.path, 'lesson.txt')).delete();
        await b.write('lesson.txt', [9]);
        await a.replica.scan();
        await b.replica.scan();
        await b.receive(a);
        await a.receive(b);
        expect(await File(p.join(a.root.path, 'lesson.txt')).readAsBytes(), [
          9,
        ]);
        expect(await File(p.join(b.root.path, 'lesson.txt')).readAsBytes(), [
          9,
        ]);
      },
    );
    test('unavailable root cannot generate deletion records', () async {
      await a.write('lesson.txt', [1]);
      await a.replica.scan();
      final moved = p.join(a.base.path, 'disconnected');
      await a.root.rename(moved);
      await expectLater(a.replica.scan(), throwsStateError);
      expect((await a.store.entries(folderId))['lesson.txt']!.deleted, false);
    });
    test(
      'interrupted transfer resumes by chunk and verifies the final hash',
      () async {
        final bytes = List.generate(peerChunkSize * 2 + 17, (i) => i % 251);
        await a.write('video.mp4', bytes);
        final entry = (await a.replica.scan())['video.mp4']!;
        await expectLater(
          b.replica.apply(entry, (path, hash, offset, count) async {
            if (offset > 0) throw const SocketException('offline');
            return bytes.sublist(offset, offset + count);
          }),
          throwsA(isA<SocketException>()),
        );
        expect(await File(p.join(b.root.path, 'video.mp4')).exists(), false);
        final offsets = <int>[];
        await b.replica.apply(entry, (path, hash, offset, count) async {
          offsets.add(offset);
          return bytes.sublist(offset, offset + count);
        });
        expect(offsets.first, peerChunkSize);
        expect(
          await File(p.join(b.root.path, 'video.mp4')).readAsBytes(),
          bytes,
        );
      },
    );
    test('corrupt incoming content cannot replace a previous file', () async {
      await a.write('lesson.txt', [1]);
      await a.replica.scan();
      await b.receive(a);
      await a.write('lesson.txt', [2]);
      final entry = (await a.replica.scan())['lesson.txt']!;
      await expectLater(
        b.replica.apply(entry, (path, hash, offset, count) async => [8]),
        throwsStateError,
      );
      expect(await File(p.join(b.root.path, 'lesson.txt')).readAsBytes(), [1]);
    });
    test(
      'local edits made after scan are not overwritten by a transfer',
      () async {
        await a.write('lesson.txt', [1]);
        await a.replica.scan();
        await b.receive(a);
        await a.write('lesson.txt', [2]);
        final entry = (await a.replica.scan())['lesson.txt']!;
        await b.write('lesson.txt', [3]);
        await expectLater(
          b.replica.apply(entry, (path, hash, offset, count) async => [2]),
          throwsStateError,
        );
        expect(await File(p.join(b.root.path, 'lesson.txt')).readAsBytes(), [
          3,
        ]);
      },
    );
  });

  test('authenticated transport rejects wrong keys and unknown channels before handling requests', () async {
    final key = peerRandomKey();
    var calls = 0;
    final server = PeerWireServer(
      keyFor: (channel) async => channel == 'test' ? key : null,
      handle: (_, request, address) async {
        calls++;
        return {'value': request['value']};
      },
    );
    await server.start(address: InternetAddress.loopbackIPv4);
    addTearDown(server.close);
    Future<Map<String, dynamic>> send(String channel, String secret) =>
        peerRequest(
          host: '127.0.0.1',
          port: server.port,
          channel: channel,
          key: secret,
          request: {'value': 'private'},
        );
    expect((await send('test', key))['value'], 'private');
    await expectLater(send('test', peerRandomKey()), throwsA(anything));
    await expectLater(send('unknown', key), throwsA(anything));
    expect(calls, 1);
  });

  test('two independent services pair and exchange only explicitly shared folders without a cloud', () async {
    final base = await Directory.systemTemp.createTemp('pepe-peer-services-');
    final dbA = AppDatabase(NativeDatabase.memory()),
        dbB = AppDatabase(NativeDatabase.memory());
    final a = PeerSyncService(
      PeerStore(Repository(dbA)),
      secrets: MemorySecrets(),
      workDirectory: Directory(p.join(base.path, 'workA')),
      configuredPort: 0,
      bindAddress: InternetAddress.loopbackIPv4,
      observeLifecycle: false,
    );
    final b = PeerSyncService(
      PeerStore(Repository(dbB)),
      secrets: MemorySecrets(),
      workDirectory: Directory(p.join(base.path, 'workB')),
      configuredPort: 0,
      bindAddress: InternetAddress.loopbackIPv4,
      observeLifecycle: false,
    );
    addTearDown(() async {
      await a.setEnabled(false);
      await b.setEnabled(false);
      a.dispose();
      b.dispose();
      await dbA.close();
      await dbB.close();
      await base.delete(recursive: true);
    });
    await a.initialize();
    await b.initialize();
    expect(a.enabled, false);
    expect(a.port, 0);
    await a.setEnabled(true);
    await b.pair(a.invitation('127.0.0.1'));
    expect(a.devices.single.id, b.deviceId);
    expect(b.devices.single.id, a.deviceId);
    final rootA = await Directory(p.join(base.path, 'rootA')).create();
    final rootB = await Directory(p.join(base.path, 'rootB')).create();
    final secretRoot = await Directory(p.join(base.path, 'private')).create();
    await File(p.join(rootA.path, 'lesson.txt')).writeAsString('hello');
    await File(p.join(rootB.path, 'notes.txt')).writeAsString('world');
    await a.addFolder(secretRoot.path, 'Never shared');
    expect(await b.offeredFolders(b.devices.single), isEmpty);
    final oldPeer = b.devices.single;
    final oldKey = (await b.secrets.read(oldPeer.channel))!;
    await expectLater(
      peerRequest(
        host: '127.0.0.1',
        port: a.port,
        channel: oldPeer.channel,
        key: oldKey,
        request: {
          'op': 'manifest',
          'folder': a.folders.single.id,
          'from': b.deviceId,
          'to': a.deviceId,
        },
      ),
      throwsStateError,
    );
    await a.addFolder(rootA.path, 'English', sharedWith: {b.deviceId});
    final offer = (await b.offeredFolders(b.devices.single)).single;
    expect(offer.keys, unorderedEquals(['id', 'name']));
    await b.addFolder(
      rootB.path,
      'English',
      id: offer['id'] as String,
      sharedWith: {a.deviceId},
    );
    await b.syncDevice(b.devices.single);
    expect(b.error, isNull, reason: b.status);
    expect(
      await File(p.join(rootB.path, 'lesson.txt')).readAsString(),
      'hello',
    );
    expect(await File(p.join(rootA.path, 'notes.txt')).readAsString(), 'world');
    await a.configureFolder(a.folders.last, paused: true);
    expect(await b.offeredFolders(b.devices.single), isEmpty);
    await b.pair(a.invitation('127.0.0.1'));
    expect(b.devices.single.channel, isNot(oldPeer.channel));
    expect(a.folders.last.devices, contains(b.deviceId));
    await expectLater(
      peerRequest(
        host: '127.0.0.1',
        port: a.port,
        channel: oldPeer.channel,
        key: oldKey,
        request: {'op': 'folders', 'from': b.deviceId, 'to': a.deviceId},
      ),
      throwsA(anything),
    );
    await a.revoke(a.devices.single);
    await expectLater(b.offeredFolders(b.devices.single), throwsA(anything));
  });
}
