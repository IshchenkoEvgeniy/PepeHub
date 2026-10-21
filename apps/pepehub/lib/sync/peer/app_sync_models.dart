import 'dart:convert';

import 'peer_models.dart';

const appSyncMaxBytes = 16 * 1024 * 1024;
final appSyncUuid = RegExp(
  r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
);
final appSyncHash = RegExp(r'^[a-f0-9]{64}$');

Object? _canonical(Object? value, [int depth = 0]) {
  if (depth > 24) throw const FormatException('Слишком глубокая запись');
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key], depth + 1)};
  }
  if (value is List) return value.map((v) => _canonical(v, depth + 1)).toList();
  return value;
}

String appSyncJson(Object? value) => jsonEncode(_canonical(value));
String appSyncDigest(Object? value) =>
    peerDigest(utf8.encode(appSyncJson(value)));

class AppSyncLocalProblem {
  final String key, target, description;
  const AppSyncLocalProblem(this.key, this.target, this.description);
  String get reference {
    final parts = key.split(':'), id = parts.last;
    final suffix = appSyncUuid.hasMatch(id) || appSyncHash.hasMatch(id)
        ? id
        : peerStorageKey(key).substring(0, 12);
    return '${parts.take(2).join(':')}:$suffix';
  }

  String get warning =>
      'Запись $reference временно не передаётся: $description. Исходная запись сохранена на этом устройстве.';
}

/// A verified payload with invalid application fields. Transfer/authentication
/// failures and bad checksums remain fatal to the exchange.
class AppSyncRejectedRecord extends FormatException {
  final String key;
  AppSyncRejectedRecord(this.key, String description) : super(description);
}

class AppSyncVersion {
  final String key;
  final Map<String, dynamic>? value;
  final Map<String, int> clock;
  bool get deleted => value == null;
  AppSyncVersion(this.key, this.value, Map<String, int> clock)
    : clock = Map.unmodifiable(clock) {
    if (key.isEmpty ||
        key.length > 512 ||
        key.contains(RegExp(r'[\x00-\x1f]')) ||
        clock.isEmpty ||
        clock.length > 64 ||
        clock.entries.any(
          (e) =>
              !appSyncUuid.hasMatch(e.key) ||
              e.value < 1 ||
              e.value > 9007199254740991,
        )) {
      throw const FormatException('Некорректная версия данных приложения');
    }
    if (bytes.length > appSyncMaxBytes) {
      throw const FormatException('Запись приложения больше 16 МиБ');
    }
  }
  Map<String, dynamic> toJson() => {'key': key, 'value': value, 'clock': clock};
  List<int> get bytes => utf8.encode(appSyncJson(toJson()));
  String get id => peerDigest(bytes);
  String get content => appSyncDigest(value);
  Map<String, dynamic> get header => {
    'id': id,
    'key': key,
    'bytes': bytes.length,
  };
  factory AppSyncVersion.fromJson(Map<String, dynamic> data) => AppSyncVersion(
    data['key'] as String,
    data['value'] == null
        ? null
        : Map<String, dynamic>.from(data['value'] as Map),
    Map<String, int>.from(data['clock'] as Map),
  );
}

class AppSyncLocal {
  final String key, target;
  final Map<String, dynamic>? value;
  const AppSyncLocal(this.key, this.target, this.value);
  String get digest => appSyncDigest(value);
}

class AppSyncProjection {
  final String key, target, digest;
  final Map<String, int> clock;
  final bool materialized;
  const AppSyncProjection(
    this.key,
    this.target,
    this.digest,
    this.clock,
    this.materialized,
  );
}
