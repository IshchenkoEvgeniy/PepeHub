import 'dart:convert';

import '../../data/repository.dart';

/// Persisted on this device, shared by the UI and Android background worker.
class PeerSyncSchedule {
  static const intervals = [15, 30, 60, 180, 360, 1440];
  final Repository repository;
  final DateTime Function() now;
  int minutes = 60;
  final Map<String, DateTime> _checks = {}, _incoming = {}, _exchanges = {};
  PeerSyncSchedule(this.repository, {DateTime Function()? now})
    : now = now ?? DateTime.now;

  Future<void> load() async {
    final saved = int.tryParse(
      await repository.meta('peer-sync-interval') ?? '',
    );
    minutes = intervals.contains(saved) ? saved! : 60;
    for (final entry in {
      'check': _checks,
      'probe': _incoming,
      'exchange': _exchanges,
    }.entries) {
      final raw = await repository.meta('peer-sync-schedule:${entry.key}');
      if (raw == null) continue;
      final values = jsonDecode(raw) as Map;
      for (final value in values.entries) {
        final date = DateTime.tryParse('${value.value}');
        if (date != null) entry.value[value.key as String] = date;
      }
    }
  }

  bool _due(DateTime? date) =>
      date == null ||
      // Recover from a clock corrected backwards; never lock sync indefinitely.
      date.isAfter(now()) ||
      now().difference(date) >= Duration(minutes: minutes);
  bool exchangeDue(String peer) => _due(_exchanges[peer]);
  bool checkDue(String peer) => _due(_checks[peer]) && exchangeDue(peer);
  bool probeDue(String peer) => _due(_incoming[peer]) && exchangeDue(peer);
  Future<void> _mark(
    String key,
    Map<String, DateTime> values,
    String peer,
  ) async {
    values[peer] = now();
    await repository.setMeta(
      'peer-sync-schedule:$key',
      jsonEncode({
        for (final entry in values.entries)
          entry.key: entry.value.toUtc().toIso8601String(),
      }),
    );
  }

  Future<void> checked(String peer) => _mark('check', _checks, peer);
  Future<void> probed(String peer) => _mark('probe', _incoming, peer);
  Future<void> exchanged(String peer) => _mark('exchange', _exchanges, peer);
  Future<void> setMinutes(int value) async {
    if (!intervals.contains(value)) throw ArgumentError.value(value);
    await repository.setMeta('peer-sync-interval', '$value');
    minutes = value;
  }
}
