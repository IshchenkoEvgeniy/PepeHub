import 'dart:convert';

import 'package:http/http.dart' as http;

import '../data/repository.dart';

class SyncConfig {
  final String endpoint, deviceId, token;
  const SyncConfig(this.endpoint, this.deviceId, this.token);
  Map<String, dynamic> toJson() => {
    'endpoint': endpoint,
    'deviceId': deviceId,
    'token': token,
  };
  factory SyncConfig.fromJson(Map<String, dynamic> json) => SyncConfig(
    json['endpoint'] as String,
    json['deviceId'] as String,
    json['token'] as String,
  );
  void validate() {
    final uri = Uri.tryParse(endpoint);
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        (uri.scheme != 'https' &&
            !(uri.scheme == 'http' &&
                ['127.0.0.1', 'localhost', '10.0.2.2'].contains(uri.host)))) {
      throw ArgumentError(
        'Укажите HTTPS-адрес сервера или локальный адрес разработки',
      );
    }
    if (!RegExp(
          r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
        ).hasMatch(deviceId) ||
        token.length < 32) {
      throw ArgumentError('Проверьте ID устройства и ключ');
    }
  }
}

class SyncClient {
  final Repository repository;
  final http.Client client;
  bool _running = false;
  SyncClient(this.repository, this.client);
  Future<void> run(SyncConfig config) async {
    if (_running) return;
    config.validate();
    _running = true;
    final endpoint = config.endpoint.replaceFirst(RegExp(r'/$'), '');
    try {
      Future<Map<String, dynamic>> request(
        String path, [
        Map<String, dynamic>? payload,
      ]) async {
        final headers = {
          'Authorization': 'Bearer ${config.token}',
          'Content-Type': 'application/json',
        };
        final uri = Uri.parse('$endpoint$path');
        final response =
            await (payload == null
                    ? client.get(uri, headers: headers)
                    : client.post(
                        uri,
                        headers: headers,
                        body: jsonEncode(payload),
                      ))
                .timeout(const Duration(seconds: 20));
        if (response.statusCode != 200) {
          throw StateError(
            response.statusCode == 401
                ? 'Ключ устройства не принят'
                : 'Сервер вернул ${response.statusCode}. Очередь сохранена.',
          );
        }
        return jsonDecode(response.body) as Map<String, dynamic>;
      }

      final identity = await request('/v1/me');
      if (identity['deviceId'] != config.deviceId) {
        throw StateError('Ключ принадлежит другому ID устройства');
      }
      await repository.configureIdentity(config.deviceId, endpoint);
      await repository.prepareCloudChanges();
      // Refresh after each receipt: a conflict must block later operations for that entity.
      final attempted = <String>{};
      while (true) {
        final pending = (await repository.pending())
            .where((r) => !attempted.contains(r.read<String>('operation_id')))
            .toList();
        if (pending.isEmpty) break;
        final operation = await repository.freezeOperation(
          pending.first.read<String>('operation_id'),
        );
        attempted.add(operation['operationId'] as String);
        await repository.applyReceipt(
          await request('/v1/operations', operation),
        );
      }
      while (true) {
        final cursor = await repository.meta('cursor') ?? '0';
        final page = await request('/v1/changes?after=$cursor&limit=100');
        await repository.applyPage(page);
        await request('/v1/ack', {'cursor': page['cursor']});
        if (page['hasMore'] != true) break;
      }
      await repository.setMeta(
        'last_sync',
        DateTime.now().toUtc().toIso8601String(),
      );
    } finally {
      _running = false;
    }
  }
}
