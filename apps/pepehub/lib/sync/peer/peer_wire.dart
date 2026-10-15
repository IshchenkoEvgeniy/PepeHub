import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

const _maxFrame = 8 * 1024 * 1024;
final _cipher = AesGcm.with256bits();
final _random = Random.secure();
String peerRandomKey() =>
    base64UrlEncode(List.generate(32, (_) => _random.nextInt(256)));

class _Frames {
  final StreamIterator<Uint8List> input;
  Uint8List _pending = Uint8List(0);
  int _offset = 0;
  _Frames(Socket socket)
    : input = StreamIterator(socket.timeout(const Duration(seconds: 40)));
  Future<Uint8List> bytes(int count) async {
    final out = Uint8List(count);
    var written = 0;
    while (written < count) {
      if (_offset == _pending.length) {
        if (!await input.moveNext()) {
          throw const SocketException('Соединение закрыто');
        }
        _pending = input.current;
        _offset = 0;
      }
      final amount = min(count - written, _pending.length - _offset);
      out.setRange(written, written + amount, _pending, _offset);
      written += amount;
      _offset += amount;
    }
    return out;
  }

  Future<Uint8List> frame({int maximum = _maxFrame}) async {
    final length = ByteData.sublistView(await bytes(4)).getUint32(0);
    if (length < 1 || length > maximum) {
      throw const FormatException('Превышен размер пакета');
    }
    return bytes(length);
  }

  Future<void> close() => input.cancel();
}

Future<void> _send(Socket socket, List<int> data) async {
  if (data.isEmpty || data.length > _maxFrame) {
    throw const FormatException('Превышен размер пакета');
  }
  socket.add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List());
  socket.add(data);
  await socket.flush();
}

Future<List<int>> _seal(
  Map<String, dynamic> message,
  String key,
  String aad,
) async => (await _cipher.encrypt(
  utf8.encode(jsonEncode(message)),
  secretKey: SecretKey(base64Url.decode(key)),
  aad: utf8.encode(aad),
)).concatenation();

Future<Map<String, dynamic>> _open(
  List<int> bytes,
  String key,
  String aad,
) async => jsonDecode(
  utf8.decode(
    await _cipher.decrypt(
      SecretBox.fromConcatenation(bytes, nonceLength: 12, macLength: 16),
      secretKey: SecretKey(base64Url.decode(key)),
      aad: utf8.encode(aad),
    ),
  ),
) as Map<String, dynamic>;

typedef PeerWireHandler = Future<Map<String, dynamic>> Function(
  String channel,
  Map<String, dynamic> request,
  String address,
);

class PeerWireServer {
  final Future<String?> Function(String channel) keyFor;
  final PeerWireHandler handle;
  ServerSocket? _server;
  final Set<Socket> _sockets = {};
  int get port => _server?.port ?? 0;
  PeerWireServer({required this.keyFor, required this.handle});
  Future<void> start({InternetAddress? address, int port = 0}) async {
    if (_server != null) return;
    _server = await ServerSocket.bind(address ?? InternetAddress.anyIPv4, port);
    _server!.listen((socket) {
      if (_sockets.length >= 8) {
        socket.destroy();
        return;
      }
      _sockets.add(socket);
      unawaited(_serve(socket));
    });
  }

  Future<void> _serve(Socket socket) async {
    final frames = _Frames(socket);
    try {
      // A new challenge per connection prevents replay, including after restart.
      final challenge = peerRandomKey();
      await _send(
        socket,
        utf8.encode(
          jsonEncode({'protocol': 'pepehub-peer-1', 'challenge': challenge}),
        ),
      );
      final envelope = jsonDecode(
        utf8.decode(await frames.frame(maximum: 8192)),
      ) as Map<String, dynamic>;
      final channel = envelope['channel'] as String;
      if (channel.length > 100) throw const FormatException('Канал недоступен');
      final key = await keyFor(channel);
      if (key == null) throw const FormatException('Устройство не сопряжено');
      final request = await _open(
        base64Decode(envelope['box'] as String),
        key,
        '$challenge|$channel|request',
      );
      Map<String, dynamic> reply;
      try {
        reply = await handle(channel, request, socket.remoteAddress.address);
      } catch (_) {
        reply = {
          'error': 'Операция недоступна или состояние папки изменилось. Обновите соединение.',
        };
      }
      reply['requestId'] = request['requestId'];
      await _send(
        socket,
        await _seal(reply, key, '$challenge|$channel|response'),
      );
    } catch (_) {
      // Authentication failures reveal neither folder names nor key material.
    } finally {
      await frames.close();
      _sockets.remove(socket);
      socket.destroy();
    }
  }

  Future<void> close() async {
    final server = _server;
    _server = null;
    await server?.close();
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
    _sockets.clear();
  }
}

Future<Map<String, dynamic>> peerRequest({
  required String host,
  required int port,
  required String channel,
  required String key,
  required Map<String, dynamic> request,
}) async {
  final socket = await Socket.connect(
    host,
    port,
    timeout: const Duration(seconds: 8),
  );
  final frames = _Frames(socket);
  try {
    final hello = jsonDecode(
      utf8.decode(await frames.frame(maximum: 512)),
    ) as Map<String, dynamic>;
    if (hello['protocol'] != 'pepehub-peer-1' ||
        (hello['challenge'] as String).length != 44) {
      throw const FormatException('Неподдерживаемый протокол устройства');
    }
    final challenge = hello['challenge'] as String, requestId = peerRandomKey();
    final box = await _seal(
      {...request, 'requestId': requestId},
      key,
      '$challenge|$channel|request',
    );
    await _send(
      socket,
      utf8.encode(jsonEncode({'channel': channel, 'box': base64Encode(box)})),
    );
    final reply = await _open(
      await frames.frame(),
      key,
      '$challenge|$channel|response',
    );
    if (reply['requestId'] != requestId) {
      throw const FormatException('Ответ относится к другому запросу');
    }
    if (reply['error'] != null) throw StateError(reply['error'] as String);
    return reply;
  } finally {
    await frames.close();
    socket.destroy();
  }
}
