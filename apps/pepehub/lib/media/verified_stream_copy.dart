import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class CopiedDigest {
  final int bytes;
  final String hash;
  final List<int> header;
  CopiedDigest(this.bytes, this.hash, this.header);
}

/// Platform streams stay on their owning isolate. Bounded transferable batches
/// are written and hashed by a worker, with acknowledgements for backpressure.
Future<CopiedDigest> copyVerifiedStream(
  Stream<List<int>> source,
  File target, {
  required int expectedBytes,
  void Function()? check,
  void Function(int)? onProgress,
}) async {
  final responses = ReceivePort();
  // One response stream also supplies the worker's command port.
  final incoming = StreamIterator<dynamic>(responses);
  Isolate? worker;
  SendPort? commands;
  var completed = false;
  Future<dynamic> response() async {
    if (!await incoming.moveNext()) throw StateError('Копирование прервано');
    final value = incoming.current;
    if (value is Map && value['error'] != null) {
      throw StateError('${value['error']}');
    }
    return value;
  }

  try {
    worker = await Isolate.spawn(_copyWorker, [
      responses.sendPort,
      target.path,
    ]);
    commands = await response() as SendPort;
    final buffer = BytesBuilder(copy: false);
    var received = 0;
    final elapsed = Stopwatch()..start();
    var notified = -100;
    Future<void> send() async {
      if (buffer.isEmpty) return;
      commands!.send([
        'chunk',
        TransferableTypedData.fromList([buffer.takeBytes()]),
      ]);
      await response();
    }

    await for (final chunk in source) {
      check?.call();
      if (received + chunk.length > expectedBytes) {
        throw StateError('Размер файла изменился');
      }
      var offset = 0;
      while (offset < chunk.length) {
        check?.call();
        final end = (offset + 1024 * 1024 - buffer.length).clamp(
          offset,
          chunk.length,
        );
        buffer.add(
          chunk is Uint8List
              ? Uint8List.sublistView(chunk, offset, end)
              : chunk.sublist(offset, end),
        );
        received += end - offset;
        offset = end;
        if (buffer.length == 1024 * 1024) await send();
        if (elapsed.elapsedMilliseconds - notified >= 100 ||
            received == expectedBytes) {
          notified = elapsed.elapsedMilliseconds;
          onProgress?.call(received);
        }
      }
    }
    check?.call();
    if (received != expectedBytes) {
      throw StateError('Файл прочитан не полностью');
    }
    await send();
    commands.send(['finish']);
    final result = await response() as Map;
    completed = true;
    return CopiedDigest(
      result['bytes'] as int,
      result['hash'] as String,
      List<int>.from(result['header'] as List),
    );
  } finally {
    if (!completed && commands != null) {
      commands.send(['abort']);
      try {
        await response();
      } catch (_) {
        /* Original error wins. */
      }
    }
    await incoming.cancel();
    responses.close();
    worker?.kill(priority: Isolate.immediate);
  }
}

class _HashSink implements Sink<Digest> {
  Digest? digest;
  @override
  void add(Digest value) {
    digest = value;
  }

  @override
  void close() {}
}

void _copyWorker(List<dynamic> arguments) async {
  final output = arguments[0] as SendPort, input = ReceivePort();
  RandomAccessFile? file;
  final digest = _HashSink(), header = <int>[];
  final hash = sha256.startChunkedConversion(digest);
  var size = 0;
  try {
    file = await File(arguments[1] as String).open(mode: FileMode.write);
    output.send(input.sendPort);
    await for (final message in input) {
      if (message[0] == 'chunk') {
        final data = (message[1] as TransferableTypedData)
            .materialize()
            .asUint8List();
        if (header.length < 12) header.addAll(data.take(12 - header.length));
        hash.add(data);
        await file!.writeFrom(data);
        size += data.length;
        output.send(true);
      } else {
        hash.close();
        if (message[0] == 'finish') await file!.flush();
        await file!.close();
        file = null;
        output.send(
          message[0] == 'finish'
              ? {
                  'bytes': size,
                  'hash': digest.digest.toString(),
                  'header': header,
                }
              : true,
        );
        break;
      }
    }
  } catch (error) {
    // Keep accepting an abort after an I/O error so the caller can await close.
    if (file != null) {
      try {
        await file.close();
      } catch (_) {}
      file = null;
    }
    output.send({'error': '$error'});
    output.send(true);
  } finally {
    if (file != null) {
      await file.close();
    }
    input.close();
  }
}
