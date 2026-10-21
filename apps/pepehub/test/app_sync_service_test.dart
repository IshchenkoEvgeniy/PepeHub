import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/sync/peer/peer_service.dart';
import 'package:pepehub/sync/peer/peer_store.dart';
import 'package:pepehub/sync/peer/peer_wire.dart';
import 'package:pepehub/video/models.dart';
import 'package:pepehub/video/video_repository.dart';
import 'package:pepehub/vocabulary/vocabulary_repository.dart';

import 'peer_sync_test.dart' show MemorySecrets;

class ServiceFixture {
  final db = AppDatabase(NativeDatabase.memory());
  late final repo = Repository(db);
  late final Directory directory, shared;
  late final PeerSyncService service;
  Future<void> open({bool library = false, bool background = false}) async {
    directory = await Directory.systemTemp.createTemp('pepe-app-service-');
    shared = await Directory(p.join(directory.path, 'shared')).create();
    service = PeerSyncService(
      PeerStore(repo),
      assets: library
          ? AssetStore(repo, Directory(p.join(directory.path, 'app-assets')))
          : null,
      secrets: MemorySecrets(),
      workDirectory: Directory(p.join(directory.path, 'work')),
      bindAddress: InternetAddress.loopbackIPv4,
      configuredPort: 0,
      observeLifecycle: false,
      backgroundWorker: background,
    );
    await service.initialize();
  }

  Future<void> close() async {
    await service.setEnabled(false);
    await service.close();
    service.dispose();
    await db.close();
    await directory.delete(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  tearDownAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = false);
  late ServiceFixture a, b;
  setUp(() async {
    a = ServiceFixture();
    b = ServiceFixture();
    await a.open();
    await b.open();
    await a.service.setEnabled(true);
    await b.service.pair(a.service.invitation('127.0.0.1'));
  });
  tearDown(() async {
    await a.close();
    await b.close();
  });
  test('application exchange requires permission on both devices and can operate without any shared files', () async {
    await VocabularyRepository(a.repo).save(front: 'already', back: 'уже');
    await b.service.syncDevice(b.service.devices.single);
    expect(await VocabularyRepository(b.repo).list(), isEmpty);
    await a.service.shareApplication(a.service.devices.single, true);
    await b.service.syncDevice(b.service.devices.single);
    expect(await VocabularyRepository(b.repo).list(), isEmpty);
    await b.service.shareApplication(b.service.devices.single, true);
    await b.service.syncDevice(b.service.devices.single);
    expect(b.service.error, isNull, reason: b.service.reports.join('\n'));
    expect((await VocabularyRepository(b.repo).list()).single.front, 'already');
    await b.service.syncDevice(b.service.devices.single);
    expect(await VocabularyRepository(b.repo).list(), hasLength(1));
    final peer = b.service.devices.single,
        key = (await b.service.secrets.read(b.service.devices.single.channel))!;
    await a.service.shareApplication(a.service.devices.single, false);
    await expectLater(
      peerRequest(
        host: peer.host,
        port: peer.port,
        channel: peer.channel,
        key: key,
        request: {
          'op': 'app_manifest',
          'from': b.service.deviceId,
          'to': a.service.deviceId,
        },
      ),
      throwsStateError,
    );
  });
  test('real direct TCP transfers a course file and then resumes its position on the other device', () async {
    final source = File(p.join(a.shared.path, 'lesson.mp4'));
    await source.writeAsBytes(List.generate(1024, (i) => i % 251));
    final video = VideoRepository(a.repo);
    final course = await video.addSources(
      title: 'English',
      root: a.shared.path,
      sources: [VideoSourceDraft(source.path, 'First lesson')],
    );
    final lesson = (await video.lessons(itemId: course.id)).single;
    await video.checkpoint(
      lesson: lesson,
      progress: VideoProgress(
        lessonId: lesson.id,
        mediaVersion: lesson.mediaVersion,
        positionMs: 42500,
        speed: 1.25,
        updatedAt: DateTime.now(),
      ),
      intervals: [],
    );
    await a.service.addFolder(
      a.shared.path,
      'Courses',
      sharedWith: {b.service.deviceId},
    );
    final offer = (await b.service.offeredFolders(b.service.devices.single))
        .single;
    await b.service.addFolder(
      b.shared.path,
      'Courses',
      id: offer['id'] as String,
      sharedWith: {a.service.deviceId},
    );
    await a.service.shareApplication(a.service.devices.single, true);
    await b.service.shareApplication(b.service.devices.single, true);
    await b.service.syncDevice(b.service.devices.single);
    expect(b.service.error, isNull, reason: b.service.reports.join('\n'));
    final receivedVideo = VideoRepository(b.repo),
        receivedLesson = (await VideoRepository(b.repo).lessons()).single;
    expect(
      p.normalize(receivedLesson.source),
      p.normalize(p.join(b.shared.path, 'lesson.mp4')),
    );
    expect((await receivedVideo.progress(receivedLesson))!.positionMs, 42500);
    expect((await receivedVideo.progress(receivedLesson))!.speed, 1.25);
    expect(
      await File(receivedLesson.source).readAsBytes(),
      await source.readAsBytes(),
    );
  });
}
