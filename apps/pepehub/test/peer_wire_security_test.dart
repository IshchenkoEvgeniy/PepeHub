import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/sync/peer/peer_wire.dart';

class Frames {
  final StreamIterator<Uint8List> stream;
  List<int> pending = [];
  Frames(Socket socket)
    : stream = StreamIterator(socket.timeout(const Duration(seconds: 3)));
  Future<List<int>> take(int count) async {
    while (pending.length < count) {
      if (!await stream.moveNext()) throw const SocketException('closed');
      pending.addAll(stream.current);
    }
    final result = pending.sublist(0, count);
    pending = pending.sublist(count);
    return result;
  }

  Future<List<int>> frame() async {
    final bytes = Uint8List.fromList(await take(4));
    return take(ByteData.sublistView(bytes).getUint32(0));
  }
}

void send(Socket socket, List<int> bytes) {
  socket.add((ByteData(4)..setUint32(0, bytes.length)).buffer.asUint8List());
  socket.add(bytes);
}

void main() {
  test(
    'captured encrypted request cannot be replayed on a different connection',
    () async {
      final key = peerRandomKey();
      var calls = 0;
      final server = PeerWireServer(
        keyFor: (_) async => key,
        handle: (_, message, address) async {
          calls++;
          return {'ok': true};
        },
      );
      await server.start(address: InternetAddress.loopbackIPv4);
      addTearDown(server.close);
      final first = await Socket.connect('127.0.0.1', server.port);
      final firstFrames = Frames(first);
      final hello = jsonDecode(utf8.decode(await firstFrames.frame())) as Map;
      final box = await AesGcm.with256bits().encrypt(
        utf8.encode(jsonEncode({'requestId': 'one', 'op': 'list'})),
        secretKey: SecretKey(base64Url.decode(key)),
        aad: utf8.encode('${hello['challenge']}|test|request'),
      );
      final envelope = utf8.encode(
        jsonEncode({
          'channel': 'test',
          'box': base64Encode(box.concatenation()),
        }),
      );
      send(first, envelope);
      await first.flush();
      await firstFrames.frame();
      await firstFrames.stream.cancel();
      first.destroy();
      expect(calls, 1);
      final second = await Socket.connect('127.0.0.1', server.port);
      final secondFrames = Frames(second);
      final nextHello =
          jsonDecode(utf8.decode(await secondFrames.frame())) as Map;
      expect(nextHello['challenge'], isNot(hello['challenge']));
      send(second, envelope);
      await second.flush();
      await expectLater(secondFrames.frame(), throwsA(isA<SocketException>()));
      await secondFrames.stream.cancel();
      second.destroy();
      expect(calls, 1);
    },
  );
  test(
    'ciphertext tampering and oversized unauthenticated frames are rejected',
    () async {
      final key = peerRandomKey();
      var calls = 0;
      final server = PeerWireServer(
        keyFor: (_) async => key,
        handle: (_, message, address) async {
          calls++;
          return {};
        },
      );
      await server.start(address: InternetAddress.loopbackIPv4);
      addTearDown(server.close);
      for (final oversized in [false, true]) {
        final socket = await Socket.connect('127.0.0.1', server.port);
        final frames = Frames(socket);
        final hello = jsonDecode(utf8.decode(await frames.frame())) as Map;
        if (oversized) {
          socket.add(
            (ByteData(4)..setUint32(0, 1024 * 1024 * 100)).buffer.asUint8List(),
          );
        } else {
          final box = await AesGcm.with256bits().encrypt(
            utf8.encode('{"requestId":"one"}'),
            secretKey: SecretKey(base64Url.decode(key)),
            aad: utf8.encode('${hello['challenge']}|test|request'),
          );
          final bytes = box.concatenation();
          bytes[15] ^= 1;
          send(
            socket,
            utf8.encode(
              jsonEncode({'channel': 'test', 'box': base64Encode(bytes)}),
            ),
          );
        }
        await socket.flush();
        await expectLater(frames.frame(), throwsA(isA<SocketException>()));
        await frames.stream.cancel();
        socket.destroy();
      }
      expect(calls, 0);
    },
  );
}
