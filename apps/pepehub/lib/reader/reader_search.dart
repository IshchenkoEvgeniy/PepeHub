import 'dart:async';
import 'dart:isolate';

import 'reader_layout.dart';

class ReaderSearchSession {
  String query = '';
  bool inCurrentChapter = false, complete = false, hasMore = false;
  int? scannedChapter;
  List<Map<String, dynamic>> hits = [];
}

class ReaderSearchBatch {
  final List<Map<String, dynamic>> hits;
  final bool hasMore;
  const ReaderSearchBatch(this.hits, this.hasMore);
}

void _scan(Map<String, dynamic> message) {
  final port = message.remove('port') as SendPort;
  final hits = searchReader({...message, 'limit': 201});
  port.send({'hits': hits.take(200).toList(), 'hasMore': hits.length > 200});
}

/// One active scan. Superseded work is killed, including a spawn that finishes
/// after cancellation; it cannot retain an old document or publish stale hits.
class ReaderSearchWorker {
  Isolate? _isolate;
  ReceivePort? _port;
  Completer<ReaderSearchBatch?>? _pending;
  int _generation = 0;

  void cancel() {
    _generation++;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _port?.close();
    _port = null;
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) pending.complete(null);
  }

  Future<ReaderSearchBatch?> search({
    required List<String> texts,
    required String query,
    int? chapter,
    Map<String, dynamic>? after,
  }) {
    cancel();
    final generation = _generation;
    final pending = _pending = Completer<ReaderSearchBatch?>();
    final port = _port = ReceivePort();
    void finish([Object? error]) {
      if (generation != _generation) return;
      _isolate?.kill(priority: Isolate.immediate);
      _isolate = null;
      port.close();
      _port = null;
      _pending = null;
      if (error != null && !pending.isCompleted) pending.completeError(error);
    }

    port.listen((message) {
      if (generation != _generation || pending.isCompleted) return;
      if (message is Map) {
        pending.complete(
          ReaderSearchBatch(
            (message['hits'] as List).cast<Map<String, dynamic>>(),
            message['hasMore'] as bool,
          ),
        );
        finish();
      } else {
        finish(StateError(message == null ? 'Поиск прерван' : '$message'));
      }
    });
    Isolate.spawn(
      _scan,
      <String, dynamic>{
        'port': port.sendPort,
        'texts': texts,
        'query': query,
        'scopeChapter': ?chapter,
        if (after != null) ...{
          'afterChapter': after['chapter'],
          'afterOffset': after['end'],
        },
      },
      onError: port.sendPort,
      onExit: port.sendPort,
    ).then((isolate) {
      if (generation != _generation || !identical(_pending, pending)) {
        isolate.kill(priority: Isolate.immediate);
      } else {
        _isolate = isolate;
      }
    }, onError: (Object error, StackTrace stack) => finish(error));
    return pending.future;
  }
}
