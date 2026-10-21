import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pepehub/audio/audio_roots.dart';
import 'package:pepehub/reader/reading_roots.dart';
import 'package:pepehub/sync/peer/peer_deletions_page.dart';
import 'package:pepehub/sync/peer/peer_files.dart';
import 'package:pepehub/sync/peer/peer_models.dart';
import 'package:pepehub/sync/peer/peer_replica.dart';
import 'package:pepehub/sync/peer/peer_store.dart';
import 'package:pepehub/sync/peer/peer_wire.dart';
import 'package:pepehub/video/video_repository.dart';
import 'package:pepehub/video/models.dart';

import 'app_sync_service_test.dart' show ServiceFixture;
import 'peer_sync_test.dart' show ReplicaFixture, deviceA, deviceB, folderId;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  tearDownAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = false);

  Future<(ReplicaFixture, ReplicaFixture)> replicas() async {
    final a = ReplicaFixture(deviceA), b = ReplicaFixture(deviceB);
    await a.open();
    await b.open();
    addTearDown(a.close);
    addTearDown(b.close);
    await a.write('book.txt', [1, 2, 3]);
    await a.replica.scan();
    await b.receive(a);
    return (a, b);
  }

  Future<void> requestDelete(ReplicaFixture a, ReplicaFixture b) async {
    await File(p.join(a.root.path, 'book.txt')).delete();
    await a.replica.scan();
    await b.replica.scan();
    await b.receive(a);
  }

  Future<(ServiceFixture, ServiceFixture)> services({
    bool library = false,
  }) async {
    final a = ServiceFixture(), b = ServiceFixture();
    await a.open(library: library);
    await b.open(library: library);
    addTearDown(a.close);
    addTearDown(b.close);
    await a.service.setEnabled(true);
    await b.service.pair(a.service.invitation('127.0.0.1'));
    await a.service.addFolder(
      a.shared.path,
      'English',
      sharedWith: {b.service.deviceId},
    );
    await b.service.addFolder(
      b.shared.path,
      'English',
      id: a.service.folders.single.id,
      sharedWith: {a.service.deviceId},
    );
    return (a, b);
  }

  test('pending deletion survives repeated scans and reload without restoring the source until the user decides', () async {
    final (a, b) = await replicas();
    await requestDelete(a, b);
    final pending = (await b.store.pendingDeletions()).single;
    expect(await File(p.join(b.root.path, 'book.txt')).readAsBytes(), [
      1,
      2,
      3,
    ]);
    expect((await b.store.entry(folderId, 'book.txt'))!.deleted, false);
    await b.replica.scan();
    await b.receive(a);
    await a.receive(b);
    expect(await File(p.join(a.root.path, 'book.txt')).exists(), false);
    final reopened = PeerStore(b.store.repository);
    await reopened.initialize();
    expect((await reopened.pendingDeletions()).single.time, pending.time);
    await b.replica.resolveDeletion(pending, delete: true);
    expect(await File(p.join(b.root.path, 'book.txt')).exists(), false);
    expect(await b.store.pendingDeletions(), isEmpty);
    await expectLater(
      b.replica.resolveDeletion(pending, delete: true),
      throwsStateError,
    );
  });

  test('declining deletion preserves the file and propagates a newer restore version', () async {
    final (a, b) = await replicas();
    await requestDelete(a, b);
    await b.replica.resolveDeletion(
      (await b.store.pendingDeletions()).single,
      delete: false,
    );
    await a.receive(b);
    await b.receive(a);
    expect(await File(p.join(a.root.path, 'book.txt')).readAsBytes(), [
      1,
      2,
      3,
    ]);
    expect(await b.store.pendingDeletions(), isEmpty);
  });

  test(
    'stale approval cannot remove a file changed since the request',
    () async {
      final (a, b) = await replicas();
      await requestDelete(a, b);
      final pending = (await b.store.pendingDeletions()).single;
      await b.write('book.txt', [9, 8, 7]);
      await expectLater(
        b.replica.resolveDeletion(pending, delete: true),
        throwsStateError,
      );
      expect(await File(p.join(b.root.path, 'book.txt')).readAsBytes(), [
        9,
        8,
        7,
      ]);
      await b.receive(a);
      await a.receive(b);
      expect(await File(p.join(a.root.path, 'book.txt')).readAsBytes(), [
        9,
        8,
        7,
      ]);
    },
  );

  test('newer restored source invalidates an older deletion request', () async {
    final (a, b) = await replicas();
    await requestDelete(a, b);
    final old = (await b.store.pendingDeletions()).single;
    await a.write('book.txt', [4, 5, 6]);
    await a.replica.scan();
    await b.receive(a);
    expect(await b.store.pendingDeletions(), isEmpty);
    await expectLater(
      b.replica.resolveDeletion(old, delete: true),
      throwsStateError,
    );
    expect(await File(p.join(b.root.path, 'book.txt')).readAsBytes(), [
      4,
      5,
      6,
    ]);
  });

  test('received payload stays on the selected volume and completed private legacy copies are reclaimed', () async {
    final (a, b) = await replicas();
    expect(await b.replica.work.exists(), false);
    final parts = await Directory(p.join(b.root.path, '.pepehub/p2p/staging'))
        .list()
        .toList();
    expect(parts, isEmpty);
    final entry = (await b.store.entry(folderId, 'book.txt'))!;
    final old = File(
      p.join(b.replica.work.path, folderId, '${peerStageKey(entry)}.part'),
    );
    await old.parent.create(recursive: true);
    await old.writeAsBytes([1, 2, 3]);
    final unrelated = File(p.join(old.parent.path, 'unrelated.part'));
    await unrelated.writeAsString('keep');
    final reclaimed = await b.replica.cleanupLegacyStages(
      await b.replica.scan(),
    );
    expect(reclaimed, 3);
    expect(await old.exists(), false);
    expect(await unrelated.readAsString(), 'keep');
    expect(await File(p.join(b.root.path, 'book.txt')).readAsBytes(), [
      1,
      2,
      3,
    ]);
    expect(await a.replica.work.exists(), false);
  });

  test('legacy partial download migrates by chunks into the selected folder and resumes without re-downloading it', () async {
    final a = ReplicaFixture(deviceA), b = ReplicaFixture(deviceB);
    await a.open();
    await b.open();
    addTearDown(a.close);
    addTearDown(b.close);
    final content = List.generate(peerChunkSize * 2 + 7, (i) => i % 251);
    await a.write('lesson.bin', content);
    final entry = (await a.replica.scan()).values.single;
    final legacy = File(
      p.join(b.replica.work.path, folderId, '${peerStageKey(entry)}.part'),
    );
    await legacy.parent.create(recursive: true);
    await legacy.writeAsBytes(content.sublist(0, peerChunkSize));
    final requests = <int>[];
    await b.replica.apply(entry, (path, hash, offset, count) {
      requests.add(offset);
      return a.replica.files.read(path, offset, count);
    });
    expect(requests.first, peerChunkSize);
    expect(await legacy.exists(), false);
    expect(await b.replica.files.hash(entry.path), entry.hash);
    expect(
      await Directory(p.join(b.root.path, '.pepehub/p2p/staging'))
          .list()
          .toList(),
      isEmpty,
    );
  });

  test('SAF transfer sends chunks only to the chosen tree and publishes the same document without a private source path', () async {
    final a = ReplicaFixture(deviceA), b = ReplicaFixture(deviceB);
    await a.open();
    await b.open();
    addTearDown(a.close);
    addTearDown(b.close);
    final content = List.generate(peerChunkSize + 19, (i) => i % 251);
    await a.write('lesson.bin', content);
    final entry = (await a.replica.scan()).values.single;
    final methods = <String>[], accumulated = <int>[];
    var published = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(peerFilesChannel, (call) async {
          methods.add(call.method);
          final args = call.arguments as Map;
          expect(args['root'], 'content://test/selected');
          expect(args.containsKey('source'), false);
          switch (call.method) {
            case 'stage_prepare':
              return accumulated.length;
            case 'stage_append':
              expect(args['offset'], accumulated.length);
              final bytes = args['bytes'] as List<int>;
              expect(bytes.length, lessThanOrEqualTo(peerChunkSize));
              accumulated.addAll(bytes);
              return null;
            case 'stage_hash':
              return peerDigest(accumulated);
            case 'stage_publish':
              published = true;
              return null;
            default:
              throw StateError('Unexpected method ${call.method}');
          }
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(peerFilesChannel, null),
    );
    final replica = PeerReplica(
      store: b.store,
      folder: b.replica.folder,
      device: deviceB,
      files: const SafPeerFiles('content://test/selected'),
      work: b.replica.work,
    );
    await replica.apply(
      entry,
      (path, hash, offset, count) => a.replica.files.read(path, offset, count),
    );
    expect(published, true);
    expect(accumulated, content);
    expect(methods, isNot(contains('publish')));
    expect(await b.replica.work.exists(), false);
  });

  test('existing synchronized folder can attach books, audio and video without copying or duplicating media', () async {
    final (a, b) = await services(library: true);
    await File(p.join(a.shared.path, 'book.txt'))
        .writeAsString('Hello, world!');
    await File(p.join(a.shared.path, 'audio.mp3'))
        .writeAsBytes(List.generate(32, (i) => i));
    await File(p.join(a.shared.path, 'lesson.mp4'))
        .writeAsBytes(List.generate(32, (i) => i));
    await b.service.syncDevice(b.service.devices.single);
    expect(b.service.error, isNull);
    expect(await b.repo.records('book'), isEmpty);
    await b.service.configureFolder(b.service.folders.single, library: 'all');
    final assets = b.service.assets!;
    expect((await ReadingRoots(assets).list()).single.path, b.shared.path);
    expect((await AudioRoots(assets).list()).single.path, b.shared.path);
    expect((await VideoRepository(b.repo).items()).single.root, b.shared.path);
    final books = await b.repo.records('book');
    expect(books, hasLength(2), reason: b.service.journal.export());
    expect(
      (await assets.list()).every((a) => a.path.startsWith(b.shared.path)),
      true,
    );
    await b.service.syncDevice(b.service.devices.single);
    expect(await b.repo.records('book'), hasLength(2));
    expect(await VideoRepository(b.repo).items(), hasLength(1));
    await File(p.join(a.shared.path, 'next.txt')).writeAsString('Next book');
    await b.service.syncDevice(b.service.devices.single);
    expect(await b.repo.records('book'), hasLength(3));
    final oldLesson = (await VideoRepository(b.repo).lessons()).single;
    await File(p.join(a.shared.path, 'lesson.mp4'))
        .writeAsBytes(List.generate(33, (i) => 255 - i));
    await b.service.syncDevice(b.service.devices.single);
    final updatedLesson = (await VideoRepository(b.repo).lessons()).single;
    expect(updatedLesson.id, oldLesson.id);
    expect(updatedLesson.mediaVersion, isNot(oldLesson.mediaVersion));
    final privateMedia = await assets.directory.exists()
        ? await assets.directory.list(recursive: true).toList()
        : [];
    expect(
      privateMedia.whereType<File>().where(
        (f) => ['.txt', '.mp3', '.mp4', '.part'].contains(p.extension(f.path)),
      ),
      isEmpty,
    );
  });

  test('explicit Media folder destination imports music beside video without creating audiobooks', () async {
    final (a, b) = await services(library: true);
    await File(p.join(a.shared.path, 'song.mp3'))
        .writeAsBytes(List.generate(32, (i) => i));
    await File(p.join(a.shared.path, 'lesson.mp4'))
        .writeAsBytes(List.generate(32, (i) => i));
    await b.service.syncDevice(b.service.devices.single);
    await b.service.configureFolder(b.service.folders.single, library: 'video');
    final media = VideoRepository(b.repo);
    final lessons = await media.lessons();
    expect(lessons, hasLength(2));
    expect(lessons.where((lesson) => lesson.isAudio).single.title, 'song');
    expect(await b.repo.records('book'), isEmpty);
    await b.service.syncDevice(b.service.devices.single);
    expect(await media.items(), hasLength(1));
    expect(await media.lessons(), hasLength(2));
  });

  test('automatic library binding and application sync share identities without duplicate books or courses', () async {
    final (a, b) = await services(library: true);
    await File(p.join(a.shared.path, 'book.txt')).writeAsString('Study text');
    await File(p.join(a.shared.path, 'lesson.mp4'))
        .writeAsBytes(List.generate(64, (i) => i));
    await a.service.configureFolder(a.service.folders.single, library: 'all');
    await b.service.configureFolder(b.service.folders.single, library: 'all');
    final video = VideoRepository(a.repo),
        lesson = (await VideoRepository(a.repo).lessons()).single;
    await video.checkpoint(
      lesson: lesson,
      progress: VideoProgress(
        lessonId: lesson.id,
        mediaVersion: lesson.mediaVersion,
        positionMs: 42000,
        speed: 1.25,
        updatedAt: DateTime.now(),
      ),
      intervals: [],
    );
    await a.service.shareApplication(a.service.devices.single, true);
    await b.service.shareApplication(b.service.devices.single, true);
    await b.service.syncDevice(b.service.devices.single);
    expect(b.service.error, isNull, reason: b.service.journal.export());
    expect(await b.repo.records('book'), hasLength(1));
    final received = VideoRepository(b.repo),
        receivedLesson = (await VideoRepository(b.repo).lessons()).single;
    expect(await received.items(), hasLength(1));
    expect(
      (await received.progress(receivedLesson))?.positionMs,
      42000,
      reason: b.service.reports.join('\n'),
    );
    await b.service.syncDevice(b.service.devices.single);
    expect(await b.repo.records('book'), hasLength(1));
    expect(await received.items(), hasLength(1));
  });

  test('new sender withholds tombstones from receivers without deletion-confirmation support', () async {
    final (a, b) = await services();
    await File(p.join(a.shared.path, 'book.txt')).writeAsString('book');
    await b.service.syncDevice(b.service.devices.single);
    await File(p.join(a.shared.path, 'book.txt')).delete();
    final peer = b.service.devices.single,
        key = (await b.service.secrets.read(b.service.devices.single.channel))!;
    Future<Map<String, dynamic>> manifest(bool modern) => peerRequest(
      host: peer.host,
      port: peer.port,
      channel: peer.channel,
      key: key,
      request: {
        'op': 'manifest',
        'folder': a.service.folders.single.id,
        'from': b.service.deviceId,
        'to': a.service.deviceId,
        if (modern) 'deleteApproval': 1,
      },
    );
    expect((await manifest(false))['entries'], isEmpty);
    expect((await manifest(true))['entries'], hasLength(1));
    await b.service.syncDevice(b.service.devices.single);
    expect(b.service.pendingDeletions, hasLength(1));
    expect(await File(p.join(b.shared.path, 'book.txt')).exists(), true);
    await b.service.resolveDeletion(
      b.service.pendingDeletions.single,
      delete: false,
    );
    await b.service.syncDevice(b.service.devices.single);
    expect(
      await File(p.join(a.shared.path, 'book.txt')).readAsString(),
      'book',
    );
  });

  testWidgets(
    'phone explicitly confirms a pending deletion and leaves the file intact until the dialog is accepted',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late ServiceFixture a, b;
      await tester.runAsync(() async {
        a = ServiceFixture();
        b = ServiceFixture();
        await a.open();
        await b.open();
        await a.service.setEnabled(true);
        await b.service.pair(a.service.invitation('127.0.0.1'));
        await a.service.addFolder(
          a.shared.path,
          'English',
          sharedWith: {b.service.deviceId},
        );
        await b.service.addFolder(
          b.shared.path,
          'English',
          id: a.service.folders.single.id,
          sharedWith: {a.service.deviceId},
        );
        await File(p.join(a.shared.path, 'book.txt')).writeAsString('book');
        await b.service.syncDevice(b.service.devices.single);
        await File(p.join(a.shared.path, 'book.txt')).delete();
        await b.service.syncDevice(b.service.devices.single);
      });
      addTearDown(() => tester.runAsync(a.close));
      addTearDown(() => tester.runAsync(b.close));
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: PeerDeletionsPage(service: b.service),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Подтвердить удаление'));
      await tester.pumpAndSettle();
      expect(find.text('Удалить файл на этом устройстве?'), findsOneWidget);
      expect(
        await tester.runAsync(
          () => File(p.join(b.shared.path, 'book.txt')).exists(),
        ),
        true,
      );
      await tester.tap(find.text('Удалить'));
      await tester.pump();
      for (var n = 0; n < 200 && b.service.pendingDeletions.isNotEmpty; n++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(
        b.service.pendingDeletions,
        isEmpty,
        reason: b.service.journal.export(),
      );
      expect(
        await tester.runAsync(
          () => File(p.join(b.shared.path, 'book.txt')).exists(),
        ),
        false,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
