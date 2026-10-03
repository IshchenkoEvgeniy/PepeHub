import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'library_repository.dart';
import 'activity_store.dart';
import 'cover_sync.dart';

class ObsidianConfig {
  final String url, token;
  ObsidianConfig(String url, this.token)
    : url = url.trim().replaceFirst(RegExp(r'/+$'), '') {
    final uri = Uri.tryParse(this.url);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        (uri.scheme != 'https' &&
            !(uri.scheme == 'http' &&
                ['localhost', '127.0.0.1', '::1'].contains(uri.host)))) {
      throw const FormatException(
        'Укажите HTTPS-адрес Companion (HTTP разрешён только для localhost).',
      );
    }
    if (token.trim().isEmpty) {
      throw const FormatException('Введите API-токен Companion.');
    }
  }
  String get namespace =>
      sha256.convert(utf8.encode('$url\n$token')).toString();
  Map<String, dynamic> toJson() => {'url': url, 'token': token};
  factory ObsidianConfig.fromJson(Map<String, dynamic> json) =>
      ObsidianConfig(json['url'] as String, json['token'] as String);
}

class ObsidianSyncService {
  final LibraryRepository repository;
  final http.Client client;
  final ObsidianConfig config;
  final CoverSync? covers;
  ObsidianSyncService(this.repository, this.client, this.config, {this.covers});
  Future<Map<String, dynamic>> _request(
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final uri = Uri.parse('${config.url}/api/pepehub/library$path');
    final request = http.Request(body == null ? 'GET' : 'POST', uri)
      ..followRedirects = false
      ..headers.addAll({
        'Authorization': 'Bearer ${config.token}',
        'Content-Type': 'application/json',
      });
    if (body != null) request.body = jsonEncode(body);
    final response = await http.Response.fromStream(
      await client.send(request).timeout(const Duration(seconds: 20)),
    ).timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        response.statusCode == 404
            ? 'На сервере Companion ещё не установлен мост библиотеки PepeHub.'
            : 'Ошибка обмена с Obsidian: HTTP ${response.statusCode}',
      );
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return json;
  }

  Future<bool> run() async {
    // The only outbound data are durable operations queued by explicit user actions.
    for (final entry in (await repository.entries()).values.where(
      (e) => e.pending,
    )) {
      final receipt = await _request('/operations', entry.operation!);
      if (receipt['status'] == 'pending') {
        await repository.receipt(
          entry.item.id,
          await _request('/operations/${entry.operation!['operationId']}'),
        );
      } else {
        await repository.receipt(entry.item.id, receipt);
      }
    }
    final snapshot = await _request('');
    if (snapshot['version'] != 1) {
      throw const FormatException('Неподдерживаемая версия моста Obsidian.');
    }
    if (snapshot['ready'] != true) {
      throw StateError(
        'Ожидается первый снимок библиотеки. Откройте Obsidian с обновлённым плагином.',
      );
    }
    await repository.receive(snapshot);
    if (await repository.repository.meta('obsidian-sync-history') != 'false') {
      final history = ActivityStore(repository.repository, config.namespace);
      await history.capture();
      final allowed = (snapshot['items'] as List)
          .map((item) => item['id'] as String)
          .toSet();
      final operations = (await history.pending())
          .where((op) => allowed.contains(op['entry']['itemId']))
          .toList();
      for (var offset = 0; offset < operations.length; offset += 20) {
        final response = await _request('/activity', {
          'operations': operations.skip(offset).take(20).toList(),
        });
        await history.receipts(response['receipts'] as List);
      }
      var cursor = (await history.state())['cursor'] as int;
      while (true) {
        final page = await _request('/activity?after=$cursor');
        final next = page['cursor'] as int, records = page['records'] as List;
        if (next < cursor || (page['hasMore'] == true && next == cursor)) {
          throw const FormatException('Некорректный курсор журнала.');
        }
        await history.receive(records, next);
        cursor = next;
        if (page['hasMore'] != true) break;
      }
    }
    return covers != null &&
            await repository.repository.meta('obsidian-sync-covers') != 'false'
        ? await covers!.run()
        : false;
  }
}
