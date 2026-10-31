import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'update_trust.dart';

class UpdateException implements Exception {
  final String message;
  const UpdateException(this.message);
  @override
  String toString() => message;
}

Uri updateUrl(String value) {
  final url = Uri.tryParse(value);
  if (url == null ||
      url.scheme != 'https' ||
      url.host.isEmpty ||
      url.userInfo.isNotEmpty ||
      url.hasFragment) {
    throw const UpdateException('Для обновления нужен HTTPS-адрес');
  }
  return url;
}

List<int> parseVersion(String version) {
  if (!RegExp(r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$')
      .hasMatch(version)) {
    throw const UpdateException('Некорректная версия обновления');
  }
  final parts = version.split('.').map(int.parse).toList();
  if (parts.any((p) => p > 999999)) {
    throw const UpdateException('Некорректная версия');
  }
  return parts;
}

int compareVersions(String a, String b) {
  final first = parseVersion(a), second = parseVersion(b);
  for (var i = 0; i < 3; i++) {
    if (first[i] != second[i]) return first[i].compareTo(second[i]);
  }
  return 0;
}

class UpdateDelta {
  final Uri url;
  final String hash, baseHash;
  final int bytes, baseBytes, fromBuild;
  const UpdateDelta(
    this.url,
    this.hash,
    this.bytes,
    this.baseHash,
    this.baseBytes,
    this.fromBuild,
  );
  factory UpdateDelta.fromJson(Map<String, dynamic> value) {
    final result = UpdateDelta(
      updateUrl(value['url'] as String),
      value['sha256'] as String,
      value['bytes'] as int,
      value['baseSha256'] as String,
      value['baseBytes'] as int,
      value['fromBuild'] as int,
    );
    if (value['format'] != 'pepe-delta-v1' ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(result.hash) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(result.baseHash) ||
        result.bytes < 1 ||
        result.bytes > 2147483648 ||
        result.baseBytes < 1 ||
        result.baseBytes > 2147483648 ||
        result.fromBuild < 1 ||
        result.fromBuild > 999999) {
      throw const UpdateException('Некорректный дельта-пакет');
    }
    return result;
  }
}

class UpdateArtifact {
  final Uri url;
  final String hash, format;
  final int bytes, versionCode;
  final List<UpdateDelta> deltas;
  const UpdateArtifact(
    this.url,
    this.hash,
    this.format,
    this.bytes,
    this.versionCode, {
    this.deltas = const [],
  });
  factory UpdateArtifact.fromJson(Map<String, dynamic> value) {
    final result = UpdateArtifact(
      updateUrl(value['url'] as String),
      value['sha256'] as String,
      value['format'] as String,
      value['bytes'] as int,
      value['versionCode'] as int,
      deltas: [
        for (final delta in value['deltas'] as List? ?? [])
          UpdateDelta.fromJson(Map<String, dynamic>.from(delta as Map)),
      ],
    );
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(result.hash) ||
        !['zip', 'apk'].contains(result.format) ||
        result.bytes < 1 ||
        result.bytes > 2147483648 ||
        result.versionCode < 1 ||
        result.versionCode > 2100000000 ||
        result.deltas.length > 3 ||
        result.deltas.any((d) => d.bytes >= result.bytes) ||
        result.deltas.map((d) => d.fromBuild).toSet().length !=
            result.deltas.length) {
      throw const UpdateException('Некорректные параметры файла обновления');
    }
    return result;
  }
}

class UpdateRelease {
  final String version, notes;
  final int build;
  final DateTime publishedAt, expiresAt;
  final Map<String, UpdateArtifact> artifacts;
  const UpdateRelease(
    this.version,
    this.build,
    this.notes,
    this.publishedAt,
    this.expiresAt,
    this.artifacts,
  );

  static Future<UpdateRelease> verify(
    List<int> envelope, {
    DateTime? now,
    String publicKey = updatePublicKey,
  }) async {
    try {
      if (envelope.length > 65536) {
        throw const UpdateException('Слишком большой список обновлений');
      }
      final outer = jsonDecode(utf8.decode(envelope)) as Map<String, dynamic>;
      final payload = base64Decode(outer['payload'] as String),
          signature = base64Decode(outer['signature'] as String);
      final key = base64Decode(publicKey);
      if (payload.length > 32768 ||
          key.length != 32 ||
          signature.length != 64 ||
          !await Ed25519().verify(
            payload,
            signature: Signature(
              signature,
              publicKey: SimplePublicKey(key, type: KeyPairType.ed25519),
            ),
          )) {
        throw const UpdateException('Подпись обновления не прошла проверку');
      }
      final value = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
      if (value['schema'] != 1 ||
          value['appId'] != 'app.pepehub.pepehub' ||
          value['channel'] != 'stable') {
        throw const UpdateException(
          'Обновление предназначено для другого приложения',
        );
      }
      final version = value['version'] as String,
          notes = value['notes'] as String;
      parseVersion(version);
      final build = value['build'] as int;
      final published = DateTime.parse(value['publishedAt'] as String),
          expires = DateTime.parse(value['expiresAt'] as String);
      final clock = (now ?? DateTime.now()).toUtc();
      if (build < 1 ||
          build > 999999 ||
          notes.length > 8000 ||
          !expires.isAfter(published) ||
          !expires.isAfter(clock) ||
          published.isAfter(clock.add(const Duration(days: 1)))) {
        throw const UpdateException(
          'Список обновлений устарел или имеет неверную дату',
        );
      }
      final raw = value['artifacts'] as Map<String, dynamic>;
      if (raw.isEmpty ||
          raw.length > 3 ||
          raw.keys.any(
            (k) => ![
              'windows-x64',
              'android-arm64',
              'android-universal',
            ].contains(k),
          )) {
        throw const UpdateException('Неизвестная платформа обновления');
      }
      final artifacts = {
        for (final item in raw.entries)
          item.key: UpdateArtifact.fromJson(item.value as Map<String, dynamic>),
      };
      for (final item in artifacts.entries) {
        if (item.value.format != (item.key == 'windows-x64' ? 'zip' : 'apk') ||
            item.value.deltas.any((d) => d.fromBuild >= build) ||
            item.value.versionCode !=
                build + (item.key == 'android-arm64' ? 2000 : 0)) {
          throw const UpdateException('Неверная версия пакета обновления');
        }
      }
      return UpdateRelease(
        version,
        build,
        notes,
        published,
        expires,
        artifacts,
      );
    } on UpdateException {
      rethrow;
    } catch (_) {
      throw const UpdateException('Не удалось проверить список обновлений');
    }
  }
}
