import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Small rotating file with uncaught and explicitly reported failures.
///
/// Diagnostics never throw: a broken log must not break reading or playback.
class ErrorLog {
  ErrorLog._();

  static const _limitBytes = 512 * 1024;
  static const _stackLines = 40;
  static const _maxPending = 200;

  static File? _file;
  static final List<String> _pending = [];
  static Future<void> _tail = Future.value();
  static final Map<String, DateTime> _recentKeys = {};

  /// Absolute path of the active log, once [attach] has been called.
  static String? get path => _file?.path;

  /// Starts writing to `errors.log` in [directory]; earlier entries are kept
  /// in memory until then.
  static void attach(Directory directory, {String name = 'errors.log'}) {
    _file = File('${directory.path}${Platform.pathSeparator}$name');
    _flush();
  }

  /// Routes Flutter framework errors and uncaught asynchronous errors here.
  static void install() {
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      (previous ?? FlutterError.presentError)(details);
      record(
        details.exception,
        details.stack,
        context: details.library == null
            ? 'flutter'
            : 'flutter: ${details.library}',
      );
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      record(error, stack, context: 'uncaught');
      return true;
    };
  }

  /// Appends [error]. Identical [once] keys are written at most once a minute,
  /// so failures repeating on a timer do not flood the file.
  static void record(
    Object error,
    StackTrace? stack, {
    String context = 'error',
    String? once,
  }) {
    try {
      final now = DateTime.now();
      if (once != null) {
        final last = _recentKeys[once];
        if (last != null && now.difference(last).inSeconds < 60) return;
        if (_recentKeys.length > 256) _recentKeys.clear();
        _recentKeys[once] = now;
      }
      final entry = StringBuffer()
        ..writeln('[${now.toIso8601String()}] $context: $error');
      if (stack != null) {
        final lines = stack.toString().trimRight().split('\n');
        entry.writeln(lines.take(_stackLines).join('\n'));
        if (lines.length > _stackLines) {
          entry.writeln('... ещё ${lines.length - _stackLines} строк');
        }
      }
      if (kDebugMode) debugPrint(entry.toString().trimRight());
      if (_pending.length >= _maxPending) _pending.removeAt(0);
      _pending.add(entry.toString());
      _flush();
    } catch (_) {
      // Diagnostics are best effort by design.
    }
  }

  static void _flush() {
    final file = _file;
    if (file == null || _pending.isEmpty) return;
    final text = _pending.join();
    _pending.clear();
    _tail = _tail.then((_) async {
      try {
        await file.parent.create(recursive: true);
        if (await file.exists() && await file.length() > _limitBytes) {
          final old = File('${file.path}.1');
          if (await old.exists()) await old.delete();
          await file.rename(old.path);
        }
        await file.writeAsString(text, mode: FileMode.append, flush: true);
      } catch (_) {
        // Diagnostics are best effort by design.
      }
    });
  }

  /// Waits for queued writes.
  static Future<void> flush() => _tail;

  /// All logs of this app (foreground and background worker), each with its
  /// previous rotation first.
  static Future<String> read() async {
    await flush();
    final out = StringBuffer();
    for (final file in await _files()) {
      try {
        final text = await file.readAsString();
        if (text.isEmpty) continue;
        out
          ..writeln('===== ${file.uri.pathSegments.last} =====')
          ..write(text);
      } catch (_) {
        // Unreadable file is skipped.
      }
    }
    return out.toString();
  }

  static Future<List<File>> _files() async {
    final file = _file;
    if (file == null) return const [];
    try {
      final names = <String>[];
      await for (final entity in file.parent.list()) {
        final name = entity.uri.pathSegments.last;
        if (entity is File && name.contains('.log')) names.add(name);
      }
      names.sort((a, b) {
        final base = a.replaceAll('.1', '').compareTo(b.replaceAll('.1', ''));
        return base != 0 ? base : b.compareTo(a);
      });
      return [
        for (final name in names)
          File('${file.parent.path}${Platform.pathSeparator}$name'),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Total size of all log files in bytes. Does not wait for queued writes:
  /// the figure is informational.
  static Future<int> size() async {
    var total = 0;
    for (final file in await _files()) {
      try {
        total += await file.length();
      } catch (_) {
        // Missing file counts as empty.
      }
    }
    return total;
  }

  static Future<void> clear() async {
    await flush();
    for (final file in await _files()) {
      try {
        await file.delete();
      } catch (_) {
        // Nothing else to do.
      }
    }
  }
}
