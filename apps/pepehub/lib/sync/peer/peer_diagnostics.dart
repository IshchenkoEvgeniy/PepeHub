import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../data/repository.dart';

enum PeerLogLevel { info, warning, error }

// Only operational descriptions belong in this journal, never request bodies,
// pairing URIs, keys, note contents, or database exception parameters.
String peerSafeDiagnostic(String text) {
  final safe = text
      .replaceAll(RegExp(r'pepehub-peer:[^\s]+'), '[код подключения скрыт]')
      .replaceAll(RegExp(r'content://[^\s]+'), '[путь Android]')
      .replaceAll(
        RegExp(
          r'(?:key|token|password|secret)\s*[:=]\s*[^\s,;]+',
          caseSensitive: false,
        ),
        '[секрет скрыт]',
      )
      .replaceAll(RegExp(r'[A-Za-z0-9_+/=-]{43,}'), '[идентификатор скрыт]')
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ');
  return safe.length > 1200 ? '${safe.substring(0, 1200)}…' : safe;
}

String peerFailureDescription(Object failure) {
  String message;
  if (failure is TimeoutException) {
    message = 'Истекло время ожидания ответа. Убедитесь, что второе приложение открыто и устройства находятся в одной сети.';
  } else if (failure is SocketException) {
    final code = failure.osError?.errorCode;
    message = switch (code) {
      10061 || 1225 || 111 || 61 => 'Устройство отклонило соединение. Включите прямую синхронизацию на втором устройстве и проверьте порт и брандмауэр.',
      10060 || 110 || 60 => 'Устройство не ответило. Проверьте его IP-адрес, сеть и разрешение PepeHub в брандмауэре.',
      10065 || 113 || 101 => 'Нет сетевого маршрута до устройства. Проверьте подключение к общей сети.',
      _ => 'Сетевое соединение прервано: ${failure.message}',
    };
    if (code != null) message += ' Код ОС: $code.';
  } else if (failure is FileSystemException) {
    final code = failure.osError?.errorCode;
    message = switch (code) {
      28 || 112 => 'Недостаточно свободного места для передачи файла.',
      5 || 13 => 'Нет доступа к файлу или папке. Проверьте разрешения.',
      2 ||
      3 => 'Файл или папка больше не доступны. Проверьте подключение папки.',
      _ => 'Ошибка файловой системы: ${failure.message}',
    };
    if (code != null) message += ' Код ОС: $code.';
  } else if (failure is PlatformException) {
    message =
        'Ошибка доступа Android (${failure.code}): ${failure.message ?? 'Проверьте разрешение на выбранную папку.'}';
  } else if (failure is StateError) {
    message = failure.message;
  } else if (failure is FormatException) {
    message = 'Неверные данные: ${failure.message}';
  } else if (failure is ArgumentError) {
    message =
        'Неверный параметр: ${failure.message ?? failure.name ?? 'проверьте настройки'}';
  } else {
    message =
        'Внутренняя ошибка (${failure.runtimeType}). Скопируйте журнал для диагностики.';
  }
  return peerSafeDiagnostic(message);
}

class PeerLogEntry {
  final DateTime time;
  final PeerLogLevel level;
  final String message;
  final String? peer, subject;
  const PeerLogEntry({
    required this.time,
    required this.level,
    required this.message,
    this.peer,
    this.subject,
  });

  Map<String, dynamic> toJson() => {
    'time': time.toUtc().toIso8601String(),
    'level': level.name,
    'message': message,
    'peer': peer,
    'subject': subject,
  };
  factory PeerLogEntry.fromJson(Map<String, dynamic> value) => PeerLogEntry(
    time: DateTime.parse(value['time'] as String),
    level: PeerLogLevel.values.byName(value['level'] as String),
    message: peerSafeDiagnostic(value['message'] as String),
    peer: value['peer'] is String
        ? peerSafeDiagnostic(value['peer'] as String)
        : null,
    subject: value['subject'] is String
        ? peerSafeDiagnostic(value['subject'] as String)
        : null,
  );
  String get label => switch (level) {
    PeerLogLevel.info => 'Информация',
    PeerLogLevel.warning => 'Внимание',
    PeerLogLevel.error => 'Ошибка',
  };
  String get text =>
      '${time.toLocal().toIso8601String()} [$label] '
      '${peer == null ? '' : '$peer · '}${subject == null ? '' : '$subject · '}$message';
}

class PeerSyncActivity {
  final int id;
  final String stage;
  final String? peer, subject;
  final DateTime started;
  final int? completed, total, bytes, totalBytes;
  const PeerSyncActivity({
    required this.id,
    required this.stage,
    required this.started,
    this.peer,
    this.subject,
    this.completed,
    this.total,
    this.bytes,
    this.totalBytes,
  });
}

/// Bounded, local history; progress updates never generate a log per chunk.
class PeerSyncJournal extends ChangeNotifier {
  static const limit = 400;
  final Repository repository;
  final List<PeerLogEntry> _entries = [];
  final Map<int, PeerSyncActivity> _activities = {};
  final Map<int, DateTime> _notified = {};
  bool _dirty = false, _disposed = false;
  int _sequence = 0;
  Future<void>? _saving;
  String? storageError;
  PeerSyncJournal(this.repository);
  List<PeerLogEntry> get entries => List.unmodifiable(_entries);
  List<PeerSyncActivity> get activities =>
      List.unmodifiable(_activities.values);

  Future<void> initialize() async {
    try {
      final value = await repository.meta('peer-sync-journal');
      if (value == null) return;
      final list = jsonDecode(value) as List;
      for (final raw in list.skip(
        (list.length - limit).clamp(0, list.length),
      )) {
        try {
          _entries.add(
            PeerLogEntry.fromJson(Map<String, dynamic>.from(raw as Map)),
          );
        } catch (_) {
          // A damaged diagnostic entry must not block device synchronization.
        }
      }
    } catch (_) {
      storageError = 'Не удалось прочитать прошлый журнал. Новые события доступны на этом экране.';
    }
    _changed();
  }

  void add(
    String message, {
    PeerLogLevel level = PeerLogLevel.info,
    String? peer,
    String? subject,
  }) {
    if (_disposed) return;
    _entries.add(
      PeerLogEntry(
        time: DateTime.now(),
        level: level,
        message: peerSafeDiagnostic(message),
        peer: peer == null ? null : peerSafeDiagnostic(peer),
        subject: subject == null ? null : peerSafeDiagnostic(subject),
      ),
    );
    if (_entries.length > limit) {
      _entries.removeRange(0, _entries.length - limit);
    }
    _dirty = true;
    _changed();
    unawaited(flush());
  }

  int start(String stage, {String? peer, String? subject}) {
    final id = ++_sequence;
    _activities[id] = PeerSyncActivity(
      id: id,
      stage: stage,
      peer: peer,
      subject: subject,
      started: DateTime.now(),
    );
    add(stage, peer: peer, subject: subject);
    return id;
  }

  void update(
    int id, {
    String? stage,
    String? subject,
    int? completed,
    int? total,
    int? bytes,
    int? totalBytes,
  }) {
    final previous = _activities[id];
    if (previous == null || _disposed) return;
    _activities[id] = PeerSyncActivity(
      id: id,
      stage: stage ?? previous.stage,
      peer: previous.peer,
      subject: subject ?? previous.subject,
      started: previous.started,
      completed: completed,
      total: total,
      bytes: bytes,
      totalBytes: totalBytes,
    );
    final now = DateTime.now();
    if (_notified[id] == null ||
        now.difference(_notified[id]!).inMilliseconds >= 200) {
      _notified[id] = now;
      _changed();
    }
  }

  void finish(int id) {
    _activities.remove(id);
    _notified.remove(id);
    _changed();
  }

  Future<void> clear() async {
    _entries.clear();
    _dirty = true;
    _changed();
    await flush();
  }

  Future<void> flush() {
    if (_saving != null) return _saving!;
    final completer = Completer<void>();
    _saving = completer.future;
    () async {
      try {
        while (_dirty) {
          _dirty = false;
          await repository.setMeta(
            'peer-sync-journal',
            jsonEncode(_entries.map((e) => e.toJson()).toList()),
          );
        }
        storageError = null;
      } catch (_) {
        storageError = 'Не удалось сохранить журнал. Скопируйте его перед закрытием приложения.';
      } finally {
        _saving = null;
        completer.complete();
        _changed();
      }
    }();
    return completer.future;
  }

  String export() =>
      'PepeHub — журнал прямой синхронизации\n'
      'Событий: ${_entries.length} (последние $limit)\n\n'
      '${_entries.map((e) => e.text).join('\n')}';
  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
