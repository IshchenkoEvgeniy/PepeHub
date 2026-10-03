import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../data/repository.dart';
import 'library_repository.dart';
import 'library_mapper.dart';
import 'models.dart';
import 'obsidian_sync_service.dart';

class LibraryService extends ChangeNotifier {
  final Repository local;
  final http.Client client;
  LibraryService(this.local, this.client);
  ObsidianConfig? config;
  LibraryRepository? get repository =>
      config == null ? null : LibraryRepository(local, config!.namespace);
  List<LibraryEntry> entries = [];
  Map<String, dynamic>? snapshot;
  bool syncing = false;
  String? error;
  Timer? _timer;
  bool _disposed = false;
  int _generation = 0;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> connect(ObsidianConfig? next) async {
    _generation++;
    _timer?.cancel();
    config = next;
    error = null;
    await reload();
    if (next != null && !_disposed) {
      _timer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => unawaited(sync()),
      );
      await sync();
    }
  }

  Future<void> reload() async {
    final generation = _generation, repo = repository;
    final values = await repo?.entries() ?? <String, LibraryEntry>{};
    final schema = await repo?.snapshot();
    if (generation != _generation || _disposed) return;
    entries = values.values.toList()
      ..sort(
        (a, b) =>
            a.item.title.toLowerCase().compareTo(b.item.title.toLowerCase()),
      );
    snapshot = schema;
    _notify();
  }

  Future<void> sync() async {
    final repo = repository, connection = config;
    if (syncing || repo == null || connection == null || _disposed) return;
    final generation = _generation;
    syncing = true;
    error = null;
    _notify();
    try {
      await ObsidianSyncService(repo, client, connection).run();
    } catch (e) {
      if (generation == _generation) error = '$e';
    } finally {
      syncing = false;
      await reload();
      if (generation != _generation && config != null && !_disposed) {
        unawaited(sync());
      }
    }
  }

  LibraryEntry? forBook(String id) =>
      entries.where((e) => e.sourceBookId == id).firstOrNull;
  ObsidianLibraryItem draft(LibraryRecord book, Map<String, dynamic> details) {
    if (snapshot == null) {
      throw StateError(
        'Сначала подключите Obsidian и дождитесь получения библиотеки.',
      );
    }
    return LibraryMapper.fromBook(
      book,
      snapshot!,
      details,
      uuid.v5(Namespace.url.value, 'pepehub:${config!.namespace}:${book.id}'),
    );
  }

  Future<void> add(ObsidianLibraryItem item, String sourceBookId) async {
    final repo = repository;
    if (repo == null) throw StateError('Подключите Obsidian.');
    await repo.mutate((data) async {
      if (data.values.any(
            (e) => e.sourceBookId == sourceBookId && e.state != 'removed',
          ) ||
          (data.containsKey(item.id) && data[item.id]!.state != 'removed')) {
        return;
      }
      data.removeWhere(
        (_, entry) =>
            entry.sourceBookId == sourceBookId && entry.state == 'removed',
      );
      data[item.id] = LibraryEntry(
        item,
        sourceBookId: sourceBookId,
        state: 'pending',
        operation: {
          'operationId': uuid.v4(),
          'itemId': item.id,
          'action': 'create',
          'collectionId': item.collectionId,
          'mediaType': item.mediaType,
          'base': <String, dynamic>{},
          'values': item.values,
        },
      );
    });
    await reload();
    await sync();
  }

  Future<void> link(String itemId, String sourceBookId) async {
    final repo = repository;
    if (repo == null) throw StateError('Подключите Obsidian.');
    await repo.mutate((data) async {
      final entry = data[itemId];
      if (entry == null || entry.state != 'synced') {
        throw StateError('Карточка ещё не синхронизирована.');
      }
      if (data.values.any(
        (e) => e.sourceBookId == sourceBookId && e.item.id != itemId,
      )) {
        throw StateError('Книга уже связана с другой карточкой.');
      }
      data[itemId] = LibraryEntry(entry.item, sourceBookId: sourceBookId);
    });
    await reload();
  }

  Future<void> save(
    String id,
    Map<String, dynamic> next, {
    required Map<String, dynamic> original,
  }) async {
    final repo = repository;
    if (repo == null) throw StateError('Подключите Obsidian.');
    await repo.mutate((data) async {
      final entry = data[id];
      if (entry == null || entry.state != 'synced') {
        throw StateError(
          'Дождитесь обмена или разрешите конфликт перед новой правкой.',
        );
      }
      final changed = {
        for (final key in next.keys)
          if (!sameMetadataValue(next[key], original[key])) key: next[key],
      };
      if (changed.isEmpty) return;
      data[id] = LibraryEntry(
        entry.item.withValues({...entry.item.values, ...changed}),
        state: 'pending',
        sourceBookId: entry.sourceBookId,
        operation: {
          'operationId': uuid.v4(),
          'itemId': id,
          'action': 'update',
          'collectionId': entry.item.collectionId,
          'mediaType': entry.item.mediaType,
          'base': {for (final key in changed.keys) key: original[key]},
          'values': changed,
        },
      );
    });
    await reload();
    await sync();
  }

  Future<void> useObsidian(String id) async {
    await repository?.mutate((data) async {
      final entry = data[id];
      if (entry?.remote != null) {
        data[id] = LibraryEntry(
          entry!.remote!,
          sourceBookId: entry.sourceBookId,
        );
      } else if (entry != null) {
        data[id] = LibraryEntry(
          entry.item,
          state: 'removed',
          sourceBookId: entry.sourceBookId,
        );
      }
    });
    await reload();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
