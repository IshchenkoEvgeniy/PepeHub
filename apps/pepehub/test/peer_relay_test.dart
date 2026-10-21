import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/sync/peer/peer_relay.dart';
import 'package:pepehub/sync/peer/peer_wire.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:pepehub/vocabulary/vocabulary_repository.dart';

import 'app_sync_service_test.dart' show ServiceFixture;

Future<void> until(bool Function() predicate) async {
  for (var n = 0; !predicate() && n < 200; n++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  expect(predicate(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  tearDownAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = false);
  test('sync service falls back to relay, keeps permissions and revocation closes the tunnel', () async {
    final reservation = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        ),
        port = reservation.port;
    await reservation.close();
    final token = peerRandomKey();
    final process = await Process.start(
      'node',
      ['services/relay/server.ts'],
      workingDirectory: Directory.current.parent.parent.path,
      environment: {'RELAY_TOKEN': token, 'PORT': '$port'},
    );
    process.stderr.drain<void>();
    await process.stdout
        .transform(utf8.decoder)
        .first
        .timeout(const Duration(seconds: 10));
    final a = ServiceFixture(), b = ServiceFixture();
    await a.open();
    await b.open();
    try {
      await a.service.setEnabled(true);
      await b.service.pair(a.service.invitation('127.0.0.1'));
      await a.service.shareApplication(a.service.devices.single, true);
      await b.service.shareApplication(b.service.devices.single, true);
      final url = 'ws://127.0.0.1:$port/v1/relay';
      await a.service.configureRelay(url, token);
      await b.service.configureRelay(url, token);
      await until(
        () =>
            a.service.relayReady(b.service.deviceId) &&
            b.service.relayReady(a.service.deviceId),
      );
      // Closed direct ports model two different NAT networks.
      a.service.devices = [
        a.service.devices.single.withAddress('127.0.0.1', 1),
      ];
      b.service.devices = [
        b.service.devices.single.withAddress('127.0.0.1', 1),
      ];
      await VocabularyRepository(a.repo)
          .save(front: 'relay works', back: 'работает');
      await b.service.syncAll(metadataOnly: true);
      expect(b.service.error, isNull, reason: b.service.journal.export());
      expect(
        (await VocabularyRepository(b.repo).list()).single.front,
        'relay works',
      );
      expect(
        b.service.journal.export(),
        contains('Обмен продолжен через шифрованный ретранслятор'),
      );
      await a.service.revoke(a.service.devices.single);
      await until(() => !b.service.relayReady(a.service.deviceId));
      expect(a.service.devices, isEmpty);
    } finally {
      await a.close();
      await b.close();
      process.kill();
      await process.exitCode;
    }
  }, timeout: const Timeout(Duration(seconds: 30)));
  test('real Node relay carries authenticated encrypted frames, bounds blocks and recovers after disconnect', () async {
    final reservation = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        ),
        port = reservation.port;
    await reservation.close();
    final key = peerRandomKey(),
        channel = peerRandomKey(),
        token = peerRandomKey();
    final process = await Process.start(
      'node',
      ['--disable-warning=ExperimentalWarning', 'services/relay/server.ts'],
      workingDirectory: Directory.current.parent.parent.path,
      environment: {'RELAY_TOKEN': token, 'PORT': '$port'},
    );
    final output = process.stdout.transform(utf8.decoder).asBroadcastStream();
    process.stderr.drain<void>();
    await output.first.timeout(const Duration(seconds: 10));
    var handled = 0;
    final payload = List.generate(100000, (i) => 'Value-$i').join('|');
    final waiting = Completer<void>(), release = Completer<void>();
    final a = PeerWireServer(
      keyFor: (_) async => key,
      handle: (_, request, _) async => {'answer': request['body']},
    );
    final b = PeerWireServer(
      keyFor: (_) async => key,
      handle: (_, request, _) async {
        handled++;
        if (request['wait'] == true) {
          waiting.complete();
          await release.future;
        }
        return {'answer': request['large'] == true ? payload : request['body']};
      },
    );
    await a.start(address: InternetAddress.loopbackIPv4);
    await b.start(address: InternetAddress.loopbackIPv4);
    final url = 'ws://127.0.0.1:$port/v1/relay';
    final first = PeerRelay(
      url: url,
      token: token,
      key: key,
      channel: channel,
      first: true,
      targetPort: a.port,
    );
    var second = PeerRelay(
      url: url,
      token: token,
      key: key,
      channel: channel,
      first: false,
      targetPort: b.port,
    );
    try {
      await first.start();
      await second.start();
      await until(() => first.ready && second.ready);
      final result = await peerRequest(
        host: '127.0.0.1',
        port: first.port,
        channel: channel,
        key: key,
        request: {'large': true},
      );
      expect(result['answer'], payload);
      expect(handled, 1);
      await expectLater(
        peerRequest(
          host: '127.0.0.1',
          port: first.port,
          channel: channel,
          key: peerRandomKey(),
          request: {'body': 'forged'},
        ),
        throwsA(anything),
      );
      expect(handled, 1);
      final cancellation = PeerRequestCancellation();
      final pending = peerRequest(
        host: '127.0.0.1',
        port: first.port,
        channel: channel,
        key: key,
        request: {'wait': true},
        cancellation: cancellation,
      );
      final expectation = expectLater(pending, throwsA(anything));
      await waiting.future;
      cancellation.cancel();
      await expectation;
      release.complete();
      await second.close();
      await until(() => !first.ready);
      second = PeerRelay(
        url: url,
        token: token,
        key: key,
        channel: channel,
        first: false,
        targetPort: b.port,
      );
      await second.start();
      await until(() => first.ready && second.ready);
      expect(
        (await peerRequest(
          host: '127.0.0.1',
          port: first.port,
          channel: channel,
          key: key,
          request: {'body': 'after reconnect'},
        ))['answer'],
        'after reconnect',
      );
      expect(handled, 3);
    } finally {
      if (!release.isCompleted) release.complete();
      await first.close();
      await second.close();
      await a.close();
      await b.close();
      process.kill();
      await process.exitCode;
    }
  }, timeout: const Timeout(Duration(seconds: 40)));

  test(
    'relay URL refuses cleartext remote servers and embedded credentials',
    () {
      expect(
        () => PeerRelay.validateUrl('ws://example.com/v1/relay'),
        throwsFormatException,
      );
      expect(
        () => PeerRelay.validateUrl('wss://secret@example.com/v1/relay'),
        throwsFormatException,
      );
      expect(
        () => PeerRelay.validateUrl('wss://example.com/v1/relay?key=secret'),
        throwsFormatException,
      );
      expect(PeerRelay.validateUrl('wss://example.com/v1/relay').scheme, 'wss');
    },
  );
}
