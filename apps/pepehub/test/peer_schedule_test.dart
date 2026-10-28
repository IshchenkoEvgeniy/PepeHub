import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/reader/reading_shelf_sources.dart';
import 'package:pepehub/sync/peer/app_sync_engine.dart';
import 'package:pepehub/sync/peer/app_sync_media.dart';
import 'package:pepehub/sync/peer/app_sync_models.dart';
import 'package:pepehub/sync/peer/app_sync_store.dart';
import 'package:pepehub/sync/peer/peer_sync_schedule.dart';
import 'package:pepehub/sync/peer/peer_store.dart';
import 'package:pepehub/sync/peer/peer_wire.dart';
import 'package:pepehub/vocabulary/vocabulary_repository.dart';

import 'app_sync_service_test.dart' show ServiceFixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  tearDownAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = false);

  test('application manifest pages preserve all headers and UTF-8 byte lengths', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final peer = PeerStore(Repository(db));
    final store = AppSyncStore(peer);
    const device = '00000000-0000-0000-0000-000000000001';
    final app = AppSyncEngine(peer, device, AppSyncMedia(store, () => []));
    final expected = <String, Map<String, dynamic>>{};
    await db.transaction(() async {
      for (var i = 0; i < 300; i++) {
        final version = AppSyncVersion(
          'record:book:00000000-0000-0000-0000-${(i + 2).toString().padLeft(12, '0')}',
          {
            'title': 'Книга № $i 📖',
            'authors': [],
            'format': 'epub',
            'status': 'planned',
          },
          {device: i + 1},
        );
        expected[version.id] = version.header;
        await store.merge(version);
      }
    });
    final revision = await store.manifestRevision();
    final received = <String, Map<String, dynamic>>{};
    var after = '';
    for (final count in [128, 128, 44]) {
      final page = await app.manifest(after: after);
      expect(page, hasLength(count));
      for (final header in page) {
        final id = header['id'] as String;
        expect(id.compareTo(after), greaterThan(0));
        received[id] = header;
        after = id;
      }
    }
    expect(received, expected);
    expect(await app.manifest(after: after), isEmpty);
    expect(await store.manifestRevision(), revision);
    await store.merge(
      AppSyncVersion(
        'record:book:00000000-0000-0000-0000-000000000400',
        {
          'title': 'Новая',
          'authors': [],
          'format': 'epub',
          'status': 'planned',
        },
        {device: 301},
      ),
    );
    expect(await store.manifestRevision(), isNot(revision));
  });

  test('hourly limits survive restart, include incoming probes, recover from clock correction', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = Repository(db);
    var now = DateTime.utc(2026, 10, 25);
    final schedule = PeerSyncSchedule(repo, now: () => now);
    await schedule.load();
    expect(schedule.minutes, 60);
    expect(schedule.checkDue('phone'), true);
    await schedule.checked('phone');
    await schedule.probed('phone');
    await schedule.exchanged('phone');
    final restarted = PeerSyncSchedule(repo, now: () => now);
    await restarted.load();
    expect(restarted.checkDue('phone'), false);
    expect(restarted.probeDue('phone'), false);
    expect(restarted.exchangeDue('phone'), false);
    expect(restarted.checkDue('another-device'), true);
    now = now.add(const Duration(minutes: 59));
    expect(restarted.checkDue('phone'), false);
    now = now.add(const Duration(minutes: 1));
    expect(restarted.checkDue('phone'), true);
    await restarted.setMinutes(180);
    expect(restarted.checkDue('phone'), false);
    now = now.subtract(const Duration(hours: 2));
    expect(restarted.checkDue('phone'), true);
  });

  test('manual exchange bypasses interval; unchanged application index is conditional', () async {
    final a = ServiceFixture(), b = ServiceFixture();
    await a.open();
    await b.open(background: true);
    addTearDown(a.close);
    addTearDown(b.close);
    await a.service.setEnabled(true);
    await b.service.pair(a.service.invitation('127.0.0.1'));
    await a.service.shareApplication(a.service.devices.single, true);
    await b.service.shareApplication(b.service.devices.single, true);
    await VocabularyRepository(a.repo).save(front: 'first', back: 'первый');
    await b.service.syncAll(metadataOnly: true);
    expect(b.service.error, isNull);
    final last = b.service.lastExchange;
    await VocabularyRepository(a.repo).save(front: 'second', back: 'второй');
    await b.service.syncAll(metadataOnly: true);
    expect(b.service.lastExchange, last);
    expect(await VocabularyRepository(b.repo).list(), hasLength(1));
    await b.service.syncDevice(b.service.devices.single);
    expect(b.service.error, isNull, reason: b.service.journal.export());
    expect(await VocabularyRepository(b.repo).list(), hasLength(2));
    await b.service.syncDevice(b.service.devices.single);
    expect(b.service.journal.export(), contains('Индекс не изменился'));

    final peer = b.service.devices.single;
    final key = (await b.service.secrets.read(peer.channel))!;
    Future<Map<String, dynamic>> request(Map<String, dynamic> fields) =>
        peerRequest(
          host: peer.host,
          port: peer.port,
          channel: peer.channel,
          key: key,
          request: {'from': b.service.deviceId, 'to': peer.id, ...fields},
        );
    expect((await request({'op': 'probe'}))['busy'], true);
    expect((await request({'op': 'folders', 'automatic': true}))['busy'], true);
    expect(
      (await request({'op': 'folders', 'automatic': false}))['busy'],
      isNot(true),
    );
  });

  test('large shelf separates remote-only cards without hiding manual plans or losing records', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = Repository(db);
    final sources = ReadingShelfSources([]);
    await sources.load(repo); // Empty peer tables on a fresh installation.
    await db.transaction(() async {
      for (var i = 0; i < 2000; i++) {
        final id = 'remote-$i';
        await repo.put('book', id, {
          'title': id,
          'authors': [],
          'format': 'epub',
          'status': 'planned',
        });
        await db.customStatement('INSERT INTO peer_app_alias VALUES(?,?,?,?)', [
          'book',
          id,
          id,
          jsonEncode({
            'descriptor': {'kind': 'book', 'sources': []},
          }),
        ]);
      }
    });
    await repo.addBook('Manual plan', '', 'epub');
    await repo.addBook('Audio excluded', '', 'audio');
    await sources.load(repo);
    final shelf = await repo.shelfBooks(audio: false);
    expect(shelf, hasLength(2001));
    expect(shelf.where((b) => sources.remoteOnly(b.id)), hasLength(2000));
    expect(
      shelf.where((b) => !sources.remoteOnly(b.id)).single.title,
      'Manual plan',
    );
    expect(await repo.records('book'), hasLength(2002));
    expect(sources.first('absent'), isNull);
  });
}
