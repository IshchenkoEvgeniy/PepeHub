import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pepehub/sync/peer/peer_wire.dart';
import 'package:pepehub/vocabulary/vocabulary_repository.dart';

import 'app_sync_service_test.dart' show ServiceFixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  tearDownAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = false);
  test('headless mode exchanges Anki without transferring or scanning media and rejects incoming file jobs', () async {
    final a = ServiceFixture(), b = ServiceFixture();
    await a.open();
    await b.open(background: true);
    try {
      await a.service.setEnabled(true);
      await b.service.pair(a.service.invitation('127.0.0.1'));
      await File(p.join(a.shared.path, 'lesson.mp4')).writeAsBytes([1, 2, 3]);
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
      );
      // After initial setup, a short background exchange must not discover this file.
      await File(p.join(b.shared.path, 'new-unscanned.mp4'))
          .writeAsBytes([4, 5, 6]);
      await a.service.shareApplication(a.service.devices.single, true);
      await b.service.shareApplication(b.service.devices.single, true);
      await VocabularyRepository(a.repo).save(front: 'background', back: 'фон');
      await b.service.syncAll(metadataOnly: true);
      expect(b.service.error, isNull, reason: b.service.journal.export());
      expect(
        (await VocabularyRepository(b.repo).list()).single.front,
        'background',
      );
      expect(await File(p.join(b.shared.path, 'lesson.mp4')).exists(), false);
      expect(
        await b.service.store.entry(
          b.service.folders.single.id,
          'new-unscanned.mp4',
        ),
        isNull,
      );
      final peer = a.service.devices.single,
          key = (await a.service.secrets.read(peer.channel))!;
      Future<Map<String, dynamic>> request(String operation) => peerRequest(
        host: peer.host,
        port: peer.port,
        channel: peer.channel,
        key: key,
        request: {
          'op': operation,
          'from': a.service.deviceId,
          'to': b.service.deviceId,
          'folder': b.service.folders.single.id,
        },
      );
      expect((await request('pull'))['busy'], true);
      await expectLater(request('manifest'), throwsStateError);
      await b.service.configureBackground(value: true, wifiOnly: false);
      expect(await b.repo.meta('peer-background-enabled'), '1');
      expect(await b.repo.meta('peer-background-wifi'), '0');
    } finally {
      await a.close();
      await b.close();
    }
  });
}
