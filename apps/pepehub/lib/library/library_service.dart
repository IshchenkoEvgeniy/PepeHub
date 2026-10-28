import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../data/repository.dart';
import 'library_repository.dart';
import 'library_mapper.dart';
import 'models.dart';
import 'obsidian_sync_service.dart';
import 'activity_store.dart';
import 'cover_sync.dart';
import 'automatic_metadata.dart';
import 'note_store.dart';
import 'metadata_values.dart';
import '../media/asset_store.dart';

class LibraryService extends ChangeNotifier {
  final Repository local;
  final http.Client client;
  final AssetStore? assets;
  LibraryService(this.local, this.client, {this.assets});
  ObsidianConfig? config;
  LibraryRepository? get repository =>
      config == null ? null : LibraryRepository(local, config!.namespace);
  ActivityStore? get history =>
      config == null ? null : ActivityStore(local, config!.namespace);
  NoteStore? get notes =>
      config == null ? null : NoteStore(local, config!.namespace);
  CoverSync? get covers => config == null || assets == null
      ? null
      : CoverSync(assets!, client, config!);
  Future<String?> chooseCover() async {
    if (covers == null) {
      throw StateError('Подключите Obsidian перед выбором обложки.');
    }
    return covers!.choose();
  }

  String? coverPath(ObsidianLibraryItem item) {
    final hash =
        CoverSync.referenceHash(item.value('cover')) ??
        item.coverAsset?['hash'] as String?;
    return hash == null ? null : covers?.path(hash);
  }

  String? coverReferencePath(String value) {
    final hash = CoverSync.referenceHash(value);
    return hash == null ? null : covers?.path(hash);
  }

  List<LibraryEntry> entries = [];
  Map<String, dynamic>? snapshot;
  final Map<String, Map<String, String>> policies = {};
  Map<String, List<String>> get suggestions => metadataSuggestions(entries);
  Map<String, dynamic>? collectionFor(ObsidianLibraryItem item) =>
      (snapshot?['collections'] as List? ?? [])
          .whereType<Map>()
          .where((c) => c['id'] == item.collectionId)
          .map((c) => Map<String, dynamic>.from(c))
          .firstOrNull;
  Future<void> savePolicy(String id, Map<String, String> policy) async {
    final repo = repository;
    if (repo == null) throw StateError('Подключите Obsidian.');
    await local.setMeta(
      'obsidian-policy:${repo.namespace}:$id',
      jsonEncode(policy),
    );
    policies[id] = Map.of(policy);
  }

  bool syncing = false;
  bool _syncAgain = false;
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
    await local.setMeta('obsidian-active-namespace', next?.namespace ?? '');
    error = null;
    await reload();
    if (next != null && !_disposed) {
      await configureTimer();
      await sync();
    }
  }

  Future<void> configureTimer() async {
    final generation = _generation;
    final seconds =
        int.tryParse(await local.meta('obsidian-sync-seconds') ?? '') ?? 30;
    if (_disposed || generation != _generation) return;
    _timer?.cancel();
    _timer = null;
    if (config != null && seconds > 0) {
      _timer = Timer.periodic(
        Duration(seconds: seconds.clamp(30, 3600)),
        (_) => unawaited(sync()),
      );
    }
  }

  Future<void> reload() async {
    final generation = _generation, repo = repository;
    final values = await repo?.entries() ?? <String, LibraryEntry>{};
    final schema = await repo?.snapshot();
    final warning = repo == null
        ? null
        : await local.meta('obsidian-cover-errors:${repo.namespace}');
    final loadedPolicies = <String, Map<String, String>>{};
    if (repo != null) {
      for (final entry in values.values) {
        final raw = await local.meta(
          'obsidian-policy:${repo.namespace}:${entry.item.id}',
        );
        if (raw != null) {
          loadedPolicies[entry.item.id] = Map<String, String>.from(
            jsonDecode(raw) as Map,
          );
        }
      }
    }
    if (generation != _generation || _disposed) return;
    entries = values.values.toList()
      ..sort(
        (a, b) =>
            a.item.title.toLowerCase().compareTo(b.item.title.toLowerCase()),
      );
    snapshot = schema;
    policies
      ..clear()
      ..addAll(loadedPolicies);
    if (error == null && warning != null && warning.isNotEmpty) error = warning;
    _notify();
  }

  Future<void> sync() async {
    final repo = repository, connection = config;
    if (syncing) {
      _syncAgain = true;
      return;
    }
    if (repo == null || connection == null || _disposed) return;
    final generation = _generation;
    syncing = true;
    error = null;
    _notify();
    try {
      do {
        _syncAgain = false;
        if (await ObsidianSyncService(
          repo,
          client,
          connection,
          covers: assets == null
              ? null
              : CoverSync(assets!, client, connection),
        ).run()) {
          _syncAgain = true;
        }
      } while (_syncAgain && generation == _generation && !_disposed);
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

  Future<ObsidianLibraryItem> prepareDraft(LibraryRecord book) async {
    final connection = config, schema = snapshot, generation = _generation;
    if (connection == null || schema == null) {
      throw StateError('Сначала подключите Obsidian.');
    }
    final details = assets == null
        ? {...?book.payload}
        : await AutomaticMetadata(assets!).withCover(
            book,
            await local.meta('obsidian-sync-covers') == 'false'
                ? null
                : CoverSync(assets!, client, connection),
          );
    if (generation != _generation) {
      throw StateError('Соединение изменилось. Повторите добавление книги.');
    }
    final item = LibraryMapper.fromBook(
      book,
      schema,
      details,
      uuid.v5(
        Namespace.url.value,
        'pepehub:${connection.namespace}:${book.id}',
      ),
    );
    await local.setMeta(
      'obsidian-auto:${connection.namespace}:${item.id}',
      jsonEncode(item.values),
    );
    return item;
  }

  Future<void> add(
    ObsidianLibraryItem item,
    String sourceBookId, {
    Map<String, dynamic>? original,
  }) async {
    final repo = repository;
    if (repo == null) throw StateError('Подключите Obsidian.');
    final chosen = item.value('libraryType');
    if (chosen != null && chosen != item.collectionId) {
      final collection = (snapshot?['collections'] as List? ?? [])
          .whereType<Map>()
          .where((c) => c['id'] == chosen)
          .firstOrNull;
      if (collection == null ||
          collection['mediaType'] != item.mediaType &&
              collection['id'] != 'book') {
        throw StateError('Выберите подходящую коллекцию библиотеки.');
      }
      item = ObsidianLibraryItem(
        id: item.id,
        path: item.path,
        collectionId: '$chosen',
        mediaType: item.mediaType,
        fields: item.fields,
        values: item.values,
      );
    }
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
          if (original != null)
            'clearFields': [
              for (final entry in original.entries)
                if (entry.value != null &&
                    entry.value != '' &&
                    !(entry.value is List && (entry.value as List).isEmpty) &&
                    (item.values[entry.key] == null ||
                        item.values[entry.key] == '' ||
                        item.values[entry.key] is List &&
                            (item.values[entry.key] as List).isEmpty))
                  entry.key,
            ],
        },
      );
    });
    await reload();
    await sync();
  }

  Future<ObsidianLibraryItem> previewLink(
    LibraryRecord book,
    ObsidianLibraryItem target,
  ) async {
    final schema = snapshot;
    if (schema == null) throw StateError('Дождитесь библиотеки Obsidian.');
    return LibraryMapper.fromBook(
      book,
      {
        ...schema,
        'fields': target.fields.map((f) => f.toJson()).toList(),
        'collections': [
          collectionFor(target) ??
              {'id': target.collectionId, 'mediaType': target.mediaType},
        ],
      },
      matchLibraryProgress(
        assets == null
            ? {...?book.payload}
            : await AutomaticMetadata(assets!).details(book),
        target,
      ),
      target.id,
    );
  }

  Future<void> link(
    String itemId,
    String sourceBookId, {
    Map<String, String>? policy,
  }) async {
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
      if (policy != null) {
        await local.setMeta(
          'obsidian-policy:${repo.namespace}:$itemId',
          jsonEncode(policy),
        );
      }
    });
    await reload();
    await sync();
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
