import 'dart:convert';
import 'dart:isolate';

import 'listening_analytics.dart';

/// Retains decoded history off the UI isolate. Playback checkpoints send only
/// the changed records; changing filters sends no history at all.
class ListeningWorker {
  Isolate? _isolate;
  Future<SendPort>? _ready;
  ReceivePort? _reply;
  bool _disposed = false;

  Future<SendPort> _start() async {
    final ready = ReceivePort();
    try {
      _isolate = await Isolate.spawn(_listen, ready.sendPort);
      final port = await ready.first as SendPort;
      if (_disposed) {
        _isolate?.kill(priority: Isolate.immediate);
        throw StateError('Listening worker disposed');
      }
      return port;
    } finally {
      ready.close();
    }
  }

  Future<ListeningAnalytics> analyze(Map<String, dynamic> request) async {
    if (_disposed) throw StateError('Listening worker disposed');
    final port = await (_ready ??= _start());
    if (_disposed) throw StateError('Listening worker disposed');
    final reply = _reply = ReceivePort();
    try {
      port.send([reply.sendPort, request]);
      final result = await reply.first;
      if (result is ListeningAnalytics) return result;
      throw StateError('Listening analysis: $result');
    } finally {
      reply.close();
      if (identical(_reply, reply)) _reply = null;
    }
  }

  void dispose() {
    _disposed = true;
    _reply?.close();
    _isolate?.kill(priority: Isolate.immediate);
  }
}

void _listen(SendPort ready) {
  final incoming = ReceivePort();
  ready.send(incoming.sendPort);
  final events = <String, Map<String, dynamic>>{};
  var foreign = <Map<String, dynamic>>[];
  incoming.listen((message) {
    final reply = message[0] as SendPort;
    final request = message[1] as Map<String, dynamic>;
    try {
      if (request['replace'] == true) events.clear();
      for (final entry
          in (request['updates'] as Map<String, String?>).entries) {
        if (entry.value == null) {
          events.remove(entry.key);
        } else {
          events[entry.key] = jsonDecode(entry.value!) as Map<String, dynamic>;
        }
      }
      if (request['foreign'] != null) {
        foreign = request['foreign'] as List<Map<String, dynamic>>;
      }
      reply.send(
        analyzeListening({
          ...request,
          'events': [...events.values, ...foreign],
        }),
      );
    } catch (error, stack) {
      reply.send('$error\n$stack');
    }
  });
}
