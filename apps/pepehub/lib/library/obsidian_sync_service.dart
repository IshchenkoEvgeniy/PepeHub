import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'library_repository.dart';
import 'activity_store.dart';
import 'cover_sync.dart';
import 'automatic_metadata.dart';
import 'note_store.dart';

class _ResetLibraryIndex implements Exception {}

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
      if (path.startsWith('/changes?') &&
          (response.statusCode == 409 || response.statusCode == 404)) {
        throw _ResetLibraryIndex();
      }
      throw StateError(
        response.statusCode == 404
            ? 'На сервере Companion ещё не установлен мост библиотеки PepeHub.'
            : 'Ошибка обмена с Obsidian: HTTP ${response.statusCode}',
      );
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final index = response.headers['x-pepehub-index'],
        cursor = int.tryParse(response.headers['x-pepehub-cursor'] ?? '');
    if (index != null && cursor != null && cursor >= 0) {
      json['_indexId'] = index;
      json['_cursor'] = cursor;
    }
    return json;
  }

  Future<({Map<String, dynamic> value, bool changed})>
  _librarySnapshot() async {
    final stored = await repository.snapshot();
    final index = stored?['_indexId'], initial = stored?['_cursor'];
    if (index is String &&
        initial is int &&
        RegExp(r'^[a-f0-9-]{36}$').hasMatch(index)) {
      var cursor = initial, changed = false;
      try {
        while (true) {
          final page = await _request('/changes?index=$index&after=$cursor');
          final next = page['cursor'];
          if (page['version'] != 1 ||
              page['indexId'] != index ||
              next is! int ||
              next < cursor ||
              page['changes'] is! List ||
              page['hasMore'] == true && next == cursor) {
            throw const FormatException(
              'Некорректный курсор библиотеки Obsidian',
            );
          }
          final schema = page['schema'] as Map?;
          final schemaChanged =
              schema == null ||
              jsonEncode([schema['fields'], schema['collections']]) !=
                  jsonEncode([stored?['fields'], stored?['collections']]);
          if ((page['changes'] as List).isNotEmpty ||
              next != cursor ||
              schemaChanged) {
            await repository.receiveChanges(page);
            changed = true;
          }
          cursor = next;
          if (page['hasMore'] != true) {
            return (
              value: changed ? (await repository.snapshot())! : stored!,
              changed: changed,
            );
          }
        }
      } on _ResetLibraryIndex {
        /* An explicit reset requires one full snapshot. */
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
    final changed = jsonEncode(snapshot) != jsonEncode(stored);
    if (changed) await repository.receive(snapshot);
    return (value: snapshot, changed: changed);
  }

  Future<void> _sendMetadata() async {
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
  }

  Future<bool> run() async {
    await _sendMetadata();
    final pulled = await _librarySnapshot(), snapshot = pulled.value;
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
    if (await repository.repository.meta('obsidian-sync-notes') != 'false') {
      final notes = NoteStore(repository.repository, config.namespace);
      await notes.capture();
      final allowed = (snapshot['items'] as List)
          .map((item) => item['id'])
          .toSet();
      final operations = (await notes.pending())
          .where((op) => allowed.contains(op['entry']['itemId']))
          .toList();
      for (var offset = 0; offset < operations.length; offset += 2) {
        final response = await _request('/notes', {
          'operations': operations.skip(offset).take(2).toList(),
        });
        await notes.receipts(response['receipts'] as List);
      }
      var cursor = (await notes.state())['cursor'] as int;
      while (true) {
        final page = await _request('/notes?after=$cursor'),
            next = page['cursor'] as int;
        if (page['version'] != 1 ||
            next < cursor ||
            (page['hasMore'] == true && next == cursor)) {
          throw const FormatException('Некорректный курсор заметок.');
        }
        await notes.receive(page['records'] as List, next);
        cursor = next;
        if (page['hasMore'] != true) break;
      }
    }
    if (covers != null) {
      await AutomaticMetadata(covers!.assets).refresh(repository, snapshot);
      // Autofill creates durable operations too. Send them now, even when the
      // periodic timer is disabled, rather than waiting for another sync.
      await _sendMetadata();
    }
    return covers != null &&
            await repository.repository.meta('obsidian-sync-covers') != 'false'
        ? await covers!.run()
        : false;
  }
}
