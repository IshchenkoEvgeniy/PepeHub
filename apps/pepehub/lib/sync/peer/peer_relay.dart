import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'peer_wire.dart';

/// Opaque TCP tunnel. The existing challenge/AES-GCM protocol runs inside it;
/// the relay never receives the pairing key or decrypted requests.
class PeerRelay {
  final String url, token, key, channel;
  final bool first;
  final int targetPort;
  final void Function(bool ready)? onState;
  final void Function(String message)? onFailure;
  String? _lastFailure;
  ServerSocket? _proxy;
  WebSocket? _websocket;
  Timer? _retry;
  bool _closed = false, ready = false;
  int _attempt = 0;
  final Map<String, _RelayStream> _streams = {};
  int get port => _proxy?.port ?? 0;
  PeerRelay({
    required this.url,
    required this.token,
    required this.key,
    required this.channel,
    required this.first,
    required this.targetPort,
    this.onState,
    this.onFailure,
  });

  static Uri validateUrl(String value) {
    final uri = Uri.parse(value.trim());
    if (uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.host.isEmpty ||
        uri.scheme != 'wss' &&
            !(uri.scheme == 'ws' &&
                ['127.0.0.1', 'localhost', '::1'].contains(uri.host))) {
      throw const FormatException(
        'Укажите wss://адрес/v1/relay. ws:// разрешён только на localhost.',
      );
    }
    return uri;
  }

  Future<void> start() async {
    validateUrl(url);
    _proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _proxy!.listen((socket) {
      if (!ready || _streams.length >= 8) {
        socket.destroy();
        return;
      }
      final id = peerRandomKey();
      final stream = _RelayStream(this, id, socket);
      _streams[id] = stream;
      _send({'op': 'open', 'id': id});
      stream.start();
    });
    unawaited(_connect());
  }

  Future<void> _connect() async {
    try {
      final socket = await WebSocket.connect(
        url,
        headers: token.isEmpty ? null : {'Authorization': 'Bearer $token'},
        compression: CompressionOptions.compressionOff,
      ).timeout(const Duration(seconds: 10));
      if (_closed) {
        await socket.close();
        return;
      }
      _websocket = socket;
      socket.pingInterval = const Duration(seconds: 25);
      final room = base64UrlEncode(
        Hmac(
          sha256,
          base64Url.decode(key),
        ).convert(utf8.encode('pepehub-relay-v1:$channel')).bytes,
      );
      socket.add(jsonEncode({'room': room, 'side': first ? 'a' : 'b'}));
      socket.listen(
        _message,
        onError: (Object _) => _lost(socket),
        onDone: () => _lost(socket),
      );
    } catch (failure) {
      final message = failure.toString().contains('401')
          ? 'Ретранслятор отклонил ключ доступа сервера.'
          : 'Ретранслятор недоступен. Проверьте адрес сервера и соединение с интернетом.';
      if (!_closed && _lastFailure != message) {
        _lastFailure = message;
        onFailure?.call(message);
      }
      if (!_closed) _reconnect();
    }
  }

  void _state(bool value) {
    if (ready != value) {
      ready = value;
      if (value) _lastFailure = null;
      onState?.call(value);
    }
  }

  void _lost(WebSocket socket) {
    if (!identical(_websocket, socket)) return;
    _websocket = null;
    _state(false);
    for (final stream in _streams.values.toList()) {
      stream.close(send: false);
    }
    _reconnect();
  }

  void _reconnect() {
    if (_closed || _retry?.isActive == true) return;
    final seconds = (5 * (1 << (_attempt++).clamp(0, 4))).clamp(5, 60);
    _retry = Timer(Duration(seconds: seconds), () => unawaited(_connect()));
  }

  void _send(Map<String, dynamic> message) {
    final socket = _websocket;
    if (socket == null || socket.readyState != WebSocket.open) {
      throw const SocketException('Ретранслятор недоступен');
    }
    socket.add(jsonEncode(message));
  }

  void _message(dynamic raw) {
    try {
      if (raw is! String || raw.length > 200000) throw const FormatException();
      final message = jsonDecode(raw) as Map<String, dynamic>;
      if (message['op'] == 'state') {
        _state(message['ready'] == true);
        if (ready) {
          _attempt = 0;
        } else {
          for (final s in _streams.values.toList()) {
            s.close(send: false);
          }
        }
        return;
      }
      final id = message['id'];
      if (id is! String || id.length > 100) throw const FormatException();
      switch (message['op']) {
        case 'open':
          if (_streams.containsKey(id) || _streams.length >= 8) {
            _send({'op': 'close', 'id': id});
            return;
          }
          final stream = _RelayStream(this, id, null);
          _streams[id] = stream;
          unawaited(stream.accept(targetPort));
        case 'data':
          final bytes = base64Decode(message['bytes'] as String);
          if (bytes.isEmpty || bytes.length > 65536) {
            throw const FormatException();
          }
          _streams[id]?.receive(bytes, message['seq']);
        case 'ack':
          _streams[id]?.ack(message['seq']);
        case 'close':
          _streams[id]?.close(send: false);
        default:
          throw const FormatException();
      }
    } catch (_) {
      unawaited(_websocket?.close(WebSocketStatus.protocolError));
    }
  }

  Future<void> close() async {
    _closed = true;
    _retry?.cancel();
    _state(false);
    for (final stream in _streams.values.toList()) {
      stream.close(send: false);
    }
    await _proxy?.close();
    await _websocket?.close();
    _websocket = null;
  }
}

class _RelayStream {
  final PeerRelay owner;
  final String id;
  Socket? socket;
  bool closed = false, receiving = false;
  int sent = 0, received = 0;
  Completer<void>? pending;
  _RelayStream(this.owner, this.id, this.socket);
  Future<void> accept(int port) async {
    try {
      final connected = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 5),
      );
      if (closed) {
        connected.destroy();
        return;
      }
      socket = connected;
      start();
    } catch (_) {
      close();
    }
  }

  void start() {
    late final StreamSubscription<List<int>> subscription;
    subscription = socket!.listen(
      (bytes) async {
        subscription.pause();
        try {
          for (var offset = 0; offset < bytes.length; offset += 65536) {
            if (closed) return;
            final end = (offset + 65536).clamp(0, bytes.length);
            pending = Completer<void>();
            owner._send({
              'op': 'data',
              'id': id,
              'seq': ++sent,
              'bytes': base64Encode(bytes.sublist(offset, end)),
            });
            await pending!.future.timeout(const Duration(seconds: 40));
          }
        } catch (_) {
          close();
        } finally {
          if (!closed) subscription.resume();
        }
      },
      onDone: close,
      onError: (Object _) => close(),
    );
  }

  void ack(dynamic seq) {
    if (seq == sent && pending?.isCompleted == false) pending!.complete();
  }

  void receive(List<int> bytes, dynamic seq) {
    if (closed) return;
    if (receiving || socket == null || seq != received + 1) {
      close();
      return;
    }
    receiving = true;
    socket!.add(bytes);
    unawaited(
      socket!
          .flush()
          .then((_) {
            if (!closed) {
              received++;
              receiving = false;
              owner._send({'op': 'ack', 'id': id, 'seq': received});
            }
          })
          .catchError((Object _) {
            close();
          }),
    );
  }

  void close({bool send = true}) {
    if (closed) return;
    closed = true;
    // A local socket's final data must reach the other side before EOF.
    final waiting = pending;
    if (send && waiting?.isCompleted == false) {
      unawaited(
        waiting!.future
            .timeout(const Duration(seconds: 2))
            .then((_) => _finish(true), onError: (Object _) => _finish(true)),
      );
    } else {
      _finish(send);
    }
  }

  void _finish(bool send) {
    if (pending?.isCompleted == false) pending!.complete();
    owner._streams.remove(id);
    socket?.destroy();
    if (send) {
      try {
        owner._send({'op': 'close', 'id': id});
      } catch (_) {}
    }
  }
}
