import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'peer_wire.dart';

const peerDiscoveryPort = 42590;
final peerDiscoveryGroup = InternetAddress('239.255.42.89');

List<int> peerAnnouncement({
  required String from,
  required String to,
  required String channel,
  required String key,
  required int port,
}) {
  final data = {
    'v': 1,
    'from': from,
    'to': to,
    'channel': channel,
    'port': port,
    'nonce': peerRandomKey(),
  };
  final body = base64UrlEncode(utf8.encode(jsonEncode(data)));
  final mac = Hmac(
    sha256,
    base64Url.decode(key),
  ).convert(utf8.encode(body)).toString();
  return utf8.encode(jsonEncode({'body': body, 'mac': mac}));
}

Map<String, dynamic>? readPeerAnnouncement(
  List<int> packet,
  String local,
  Map<String, String> keys,
) {
  if (packet.isEmpty || packet.length > 2048) return null;
  try {
    final envelope = jsonDecode(utf8.decode(packet)) as Map;
    final body = envelope['body'] as String,
        supplied = envelope['mac'] as String;
    final data =
        jsonDecode(utf8.decode(base64Url.decode(body))) as Map<String, dynamic>;
    final key = keys[data['channel']];
    if (key == null ||
        data['v'] != 1 ||
        data['to'] != local ||
        data['from'] == local ||
        data['port'] is! int ||
        (data['port'] as int) < 1 ||
        (data['port'] as int) > 65535 ||
        data['nonce'] is! String ||
        (data['nonce'] as String).length != 44 ||
        supplied.length != 64) {
      return null;
    }
    final expected = Hmac(
      sha256,
      base64Url.decode(key),
    ).convert(utf8.encode(body)).toString();
    var difference = 0;
    for (var i = 0; i < 64; i++) {
      difference |= expected.codeUnitAt(i) ^ supplied.codeUnitAt(i);
    }
    return difference == 0 ? data : null;
  } catch (_) {
    return null;
  }
}

class PeerDiscovery {
  final List<List<int>> Function() announcements;
  final Future<void> Function(List<int>, InternetAddress) onPacket;
  final void Function(List<String>)? onAddresses;
  final void Function(Object)? onError;
  final int listenPort;
  final bool multicast;
  RawDatagramSocket? _socket;
  Timer? _timer;
  bool _closed = false;
  final Map<String, NetworkInterface> _interfaces = {};
  final Map<String, DateTime> _recent = {};
  PeerDiscovery({
    required this.announcements,
    required this.onPacket,
    this.onAddresses,
    this.onError,
    this.listenPort = peerDiscoveryPort,
    this.multicast = true,
  });
  int get port => _socket?.port ?? 0;
  Future<void> start() async {
    _closed = false;
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      listenPort,
      reuseAddress: true,
      reusePort: !Platform.isWindows,
    );
    if (_closed) {
      socket.close();
      return;
    }
    _socket = socket;
    socket.broadcastEnabled = true;
    socket.writeEventsEnabled = false;
    socket.multicastHops = 1;
    socket.listen(
      (event) {
        if (event != RawSocketEvent.read) return;
        for (var i = 0; i < 32; i++) {
          final packet = socket.receive();
          if (packet == null) break;
          if (packet.data.length > 2048) continue;
          final digest =
              '${packet.address.address}:${sha256.convert(packet.data)}';
          final now = DateTime.now();
          _recent.removeWhere((_, time) => now.difference(time).inSeconds > 30);
          if (_recent.containsKey(digest) || _recent.length > 256) continue;
          _recent[digest] = now;
          unawaited(
            onPacket(packet.data, packet.address).catchError((Object e) {
              onError?.call(e);
            }),
          );
        }
      },
      onError: (Object e) {
        onError?.call(e);
      },
    );
    await announce();
    if (!_closed) {
      _timer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => unawaited(announce()),
      );
    }
  }

  Future<void> announce() async {
    final socket = _socket;
    if (socket == null || _closed) return;
    try {
      final networks = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      onAddresses?.call([
        for (final n in networks)
          for (final address in n.addresses) address.address,
      ]);
      final current = {
        for (final network in networks)
          '${network.index}:${network.addresses.map((a) => a.address).join(',')}':
              network,
      };
      for (final old
          in _interfaces.keys
              .where((key) => !current.containsKey(key))
              .toList()) {
        try {
          socket.leaveMulticast(peerDiscoveryGroup, _interfaces[old]);
        } catch (_) {}
        _interfaces.remove(old);
      }
      if (multicast) {
        for (final network in networks) {
          final key =
              '${network.index}:${network.addresses.map((a) => a.address).join(',')}';
          if (!_interfaces.containsKey(key)) {
            try {
              socket.joinMulticast(peerDiscoveryGroup, network);
              _interfaces[key] = network;
            } catch (_) {}
          }
        }
      }
      for (final packet in announcements()) {
        socket.send(packet, InternetAddress('255.255.255.255'), listenPort);
        if (multicast) {
          for (final network in networks) {
            try {
              socket.setRawOption(
                RawSocketOption(
                  RawSocketOption.levelIPv4,
                  RawSocketOption.IPv4MulticastInterface,
                  network.addresses.first.rawAddress,
                ),
              );
              socket.send(packet, peerDiscoveryGroup, listenPort);
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      onError?.call(e);
    }
  }

  void sendTo(List<int> packet, InternetAddress address, int port) {
    _socket?.send(packet, address, port);
  }

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    _socket?.close();
    _socket = null;
    _interfaces.clear();
    _recent.clear();
  }
}
