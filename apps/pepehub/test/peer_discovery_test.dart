import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/sync/peer/peer_discovery.dart';
import 'package:pepehub/sync/peer/peer_wire.dart';

import 'app_sync_service_test.dart' show ServiceFixture;
import 'peer_sync_test.dart' show deviceA, deviceB;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  tearDownAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = false);
  test('discovery accepts only an authenticated pair announcement addressed to this device', () {
    final key = peerRandomKey(),
        channel = '33333333-3333-4333-8333-333333333333';
    final packet = peerAnnouncement(
      from: deviceA,
      to: deviceB,
      channel: channel,
      key: key,
      port: 42589,
    );
    expect(
      readPeerAnnouncement(packet, deviceB, {channel: key})?['from'],
      deviceA,
    );
    expect(utf8.decode(packet).contains(key), false);
    expect(readPeerAnnouncement(packet, deviceA, {channel: key}), isNull);
    expect(
      readPeerAnnouncement(packet, deviceB, {channel: peerRandomKey()}),
      isNull,
    );
    final forged = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(packet)) as Map,
    )..['mac'] = '0' * 64;
    expect(
      readPeerAnnouncement(utf8.encode(jsonEncode(forged)), deviceB, {
        channel: key,
      }),
      isNull,
    );
    expect(
      readPeerAnnouncement(List.filled(2049, 65), deviceB, {channel: key}),
      isNull,
    );
  });

  test(
    'real UDP transports a pair announcement without sending library contents',
    () async {
      final received = Completer<List<int>>();
      final a = PeerDiscovery(
        announcements: () => [],
        onPacket: (_, _) async {},
        listenPort: 0,
        multicast: false,
      );
      final b = PeerDiscovery(
        announcements: () => [],
        onPacket: (bytes, _) async {
          if (!received.isCompleted) received.complete(bytes);
        },
        listenPort: 0,
        multicast: false,
      );
      await a.start();
      await b.start();
      addTearDown(a.close);
      addTearDown(b.close);
      final packet = peerAnnouncement(
        from: deviceA,
        to: deviceB,
        channel: 'pair',
        key: peerRandomKey(),
        port: 42589,
      );
      a.sendTo(packet, InternetAddress.loopbackIPv4, b.port);
      expect(await received.future.timeout(const Duration(seconds: 5)), packet);
    },
  );

  Future<(ServiceFixture, ServiceFixture)> pair() async {
    final a = ServiceFixture(), b = ServiceFixture();
    await a.open();
    await b.open();
    addTearDown(a.close);
    addTearDown(b.close);
    await a.service.setEnabled(true);
    await b.service.pair(a.service.invitation('127.0.0.1'));
    await b.service.shareApplication(b.service.devices.single, true);
    return (a, b);
  }

  test('changed IP is verified over encrypted TCP then persisted without rotating keys or permissions', () async {
    final (a, b) = await pair();
    final peer = b.service.devices.single;
    final key = (await b.service.secrets.read(peer.channel))!;
    b.service.devices = [peer.withAddress('127.0.0.9', a.service.port)];
    await b.service.store.saveDevices(b.service.devices);
    final packet = peerAnnouncement(
      from: a.service.deviceId,
      to: b.service.deviceId,
      channel: peer.channel,
      key: key,
      port: a.service.port,
    );
    await b.service.acceptAnnouncement(packet, InternetAddress.loopbackIPv4);
    final updated = (await b.service.store.devices()).single;
    expect(updated.host, '127.0.0.1');
    expect(updated.port, a.service.port);
    expect(updated.channel, peer.channel);
    expect(updated.applicationData, true);
    expect(await b.service.secrets.read(peer.channel), key);
    expect(a.service.devices.single.host, '127.0.0.1');
  });

  test('manual address verification rejects a server with the wrong pair key and leaves the old address intact', () async {
    final (a, b) = await pair();
    final peer = b.service.devices.single;
    final wrong = PeerWireServer(
      keyFor: (_) async => peerRandomKey(),
      handle: (_, _, _) async => {'device': a.service.deviceId},
    );
    await wrong.start(address: InternetAddress.loopbackIPv4);
    addTearDown(wrong.close);
    await expectLater(
      b.service.updateAddress(peer, '127.0.0.1', wrong.port),
      throwsA(anything),
    );
    expect(b.service.devices.single.port, peer.port);
    expect((await b.service.store.devices()).single.port, peer.port);
  });

  test(
    'a revoked pair cannot reappear from an old signed announcement',
    () async {
      final (a, b) = await pair();
      final peer = b.service.devices.single;
      final packet = peerAnnouncement(
        from: a.service.deviceId,
        to: b.service.deviceId,
        channel: peer.channel,
        key: (await b.service.secrets.read(peer.channel))!,
        port: a.service.port,
      );
      await b.service.revoke(peer);
      await b.service.acceptAnnouncement(packet, InternetAddress.loopbackIPv4);
      expect(b.service.devices, isEmpty);
      expect(await b.service.store.devices(), isEmpty);
    },
  );
}
