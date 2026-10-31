import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../data/repository.dart';
import '../reader/reading_library.dart';
import '../recommendations/recommendation_store.dart';
import '../media/asset_store.dart';
import 'library_repository.dart';
import 'library_mapper.dart';
import 'library_exchange.dart';
import 'personal_library.dart';
import 'models.dart';
import 'obsidian_sync_service.dart';
import 'activity_store.dart';
import 'cover_sync.dart';
import 'automatic_metadata.dart';
import 'note_store.dart';
import 'metadata_values.dart';
import 'library_features.dart';

class LibraryService extends ChangeNotifier {
  final Repository local;
  final http.Client client;
  final AssetStore? assets;
  LibraryService(this.local, this.client, {this.assets});
  ObsidianConfig? config;
  LibraryRepository get repository => LibraryRepository(
    local,
    personalLibraryNamespace,
    storageKey: personalLibraryKey,
  );
  ActivityStore? get history =>
      ActivityStore(local, personalLibraryNamespace, catalog: repository);
  NoteStore? get notes =>
      NoteStore(local, personalLibraryNamespace, catalog: repository);
  CoverSync? get covers =>
      assets == null ? null : CoverSync.local(assets!, client);
  LibraryExchange? get exchange => config == null
      ? null
      : LibraryExchange(local, repository, config!.namespace);
  Future<String?> chooseCover() async {
    if (covers == null) throw StateError('Хранилище обложек недоступно.');
    return covers!.choose();
  }

  final Set<String> _knownNamespaces = {};
  final Set<String> _uploadedCovers = {};
  bool _migrated = false;
  Future<void> _reloadTail = Future.value();
  Future<void>? _refresh;
  bool _refreshAgain = false;
  Future<void> get idle => _reloadTail;
  String? coverPath(ObsidianLibraryItem item) {
    final cover = '${item.value('cover') ?? ''}';
    final stored = item.values['pepehub_cover_asset'];
    final hash =
        item.coverAsset?['hash'] ?? (stored is Map ? stored['hash'] : null);
    return coverReferencePath(cover) ??
        coverReferencePath('pepehub-cover:$hash');
  }

  String? coverReferencePath(String value) {
    final hash = CoverSync.referenceHash(value);
    if (hash == null || covers == null) return null;
    final path = covers!.path(hash);
    if (File(path).existsSync()) return path;
    for (final ns in _knownNamespaces) {
      final legacy = File(path).parent.parent.uri
          .resolve('$ns/$hash.png')
          .toFilePath();
      if (File(legacy).existsSync()) return legacy;
    }
    return null;
  }

  List<LibraryEntry> _entries = [];
  List<LibraryEntry> _visible = [], _completed = [], _inbox = [], _trash = [];
  final Map<String, LibraryEntry> _bySource = {};
  List<LibraryEntry> get entries => _entries;
  set entries(List<LibraryEntry> value) {
    _entries = List.unmodifiable(value);
    final archive = value.where((e) => isLibraryArchiveItem(e.item)).toList();
    _visible = List.unmodifiable(
      archive.where((e) => !isLibraryDeleted(e.item)),
    );
    _completed = List.unmodifiable(
      _visible.where((e) => isFinishedLibraryItem(e.item)),
    );
    _inbox = List.unmodifiable(
      _visible.where((e) => !isFinishedLibraryItem(e.item)),
    );
    _trash = List.unmodifiable(archive.where((e) => isLibraryDeleted(e.item)));
    _bySource.clear();
    for (final e in value) {
      if (e.sourceBookId != null) _bySource[e.sourceBookId!] = e;
    }
  }

  List<LibraryEntry> get completed => _completed;
  List<LibraryEntry> get inbox => _inbox;
  List<LibraryEntry> get trash => _trash;
  List<LibraryEntry> get visibleEntries => _visible;
  Future<void> deleteCards(Iterable<String> ids) async {
    final selected = ids.toSet();
    await repository.mutate((cards) async {
      for (final id in selected) {
        final card = cards[id];
        if (card == null || isLibraryDeleted(card.item)) continue;
        cards[id] = LibraryEntry(
          personalLibraryItem(id, card.item.mediaType, {
            ...card.item.values,
            'pepehub_deleted_at': DateTime.now().toUtc().toIso8601String(),
          }),
          sourceBookId: card.sourceBookId,
        );
      }
    });
    await loadCached();
  }

  Future<void> restoreCard(String id) async {
    final card = (await repository.entries())[id];
    if (card != null) {
      await save(id, {
        ...card.item.values,
        'pepehub_deleted_at': null,
      }, original: card.item.values);
    }
  }

  Future<void> favorite(String id) async {
    final card = (await repository.entries())[id];
    if (card != null) {
      await save(id, {
        ...card.item.values,
        'pepehub_favorite': card.item.values['pepehub_favorite'] != true,
      }, original: card.item.values);
    }
  }

  /// A single transaction for the current selection; unrelated card fields stay intact.
  Future<void> editCards(
    Iterable<String> ids,
    Map<String, dynamic> changes, {
    String? addCollection,
    bool reread = false,
  }) async {
    final selected = ids.toSet();
    if (changes.keys.any(
      (key) => ![
        'author',
        'series',
        'status',
        'rereadCount',
        'endDate',
        'notes',
        'pepehub_favorite',
        'pepehub_hidden',
      ].contains(key),
    )) {
      throw ArgumentError('Неизвестное поле массового изменения');
    }
    final status = changes['status'];
    final rereads = changes['rereadCount'];
    if (rereads != null &&
        (rereads is! num ||
            !rereads.isFinite ||
            rereads < 0 ||
            rereads > 99999 ||
            rereads != rereads.round())) {
      throw ArgumentError('Введите целое число перечитываний от 0 до 99999');
    }
    if (status != null && !libraryStatusesLocal.containsKey(status)) {
      throw ArgumentError('Неизвестный статус');
    }
    await local.db.transaction(() async {
      await repository.mutate((cards) async {
        for (final id in selected) {
          final card = cards[id];
          if (card == null || isLibraryDeleted(card.item)) continue;
          final values = {...card.item.values, ...changes};
          if (status == 'finished' &&
              libraryStatus(card.item) != 'finished' &&
              '${values['endDate'] ?? ''}'.isEmpty) {
            values['endDate'] = DateTime.now().toIso8601String().substring(
              0,
              10,
            );
          }
          if (reread) {
            if (libraryRereads(card.item) >= 99999) {
              throw StateError('Достигнут предел счётчика перечитываний');
            }
            values['rereadCount'] = libraryRereads(card.item) + 1;
            values['status'] = 'finished';
            values['endDate'] = DateTime.now().toIso8601String().substring(
              0,
              10,
            );
            final old = card.item.values['pepehub_completions'];
            values['pepehub_completions'] = [
              if (old is List) ...old,
              if ((old is! List || old.isEmpty) &&
                  card.item.value('endDate') != null)
                {
                  'date': card.item.value('endDate'),
                  'rating': card.item.value('rating'),
                },
              {'date': values['endDate'], 'rating': values['rating']},
            ];
          }
          if (addCollection?.trim().isNotEmpty == true) {
            values['pepehub_collections'] = metadataStrings([
              ...libraryCollections(card.item),
              addCollection!.trim(),
            ]);
          }
          if (status != null || reread) {
            final key = 'obsidian-policy:$personalLibraryNamespace:$id';
            final policy = await ReadingLibrary(local).value(key);
            policy['status'] =
                ['paused', 'abandoned', 'planned'].contains(status)
                ? 'obsidian'
                : 'auto';
            await local.setMeta(key, jsonEncode(policy));
          }
          cards[id] = LibraryEntry(
            personalLibraryItem(id, card.item.mediaType, values),
            sourceBookId: card.sourceBookId,
          );
          if (status != null || reread) {
            await _sourceStatus(card, values['status'] as String);
          }
        }
      });
    });
    await loadCached();
  }

  Map<String, dynamic>? snapshot = personalLibrarySchema;
  Future<void> _sourceStatus(LibraryEntry card, String status) async {
    final source = card.sourceBookId == null
        ? null
        : await local.record(card.sourceBookId!);
    if (source == null || source.deleted) return;
    final finished = status == 'finished'
        ? DateTime.now().toUtc().toIso8601String()
        : null;
    await local.put('book', source.id, {
      ...?source.payload,
      'status': status,
      'finishedAt': finished,
    });
    if (card.item.mediaType == 'audiobook') {
      await local.setMeta('audio-status-override:${source.id}', status);
    } else {
      final reading = ReadingLibrary(local), key = 'reading-book:${source.id}';
      final prefs = await reading.value(key);
      await reading.update(key, {
        'overrides': {
          ...Map<String, dynamic>.from(prefs['overrides'] as Map? ?? {}),
          'status': status,
          'finishedAt': finished,
        },
      });
    }
  }

  final Map<String, Map<String, String>> policies = {};
  Map<String, List<String>> get suggestions => metadataSuggestions(entries);
  Map<String, dynamic>? collectionFor(ObsidianLibraryItem item) =>
      (personalLibrarySchema['collections'] as List)
          .cast<Map<String, dynamic>>()
          .where((c) => c['id'] == item.mediaType)
          .firstOrNull;
  Future<void> savePolicy(String id, Map<String, String> policy) async {
    await local.setMeta(
      'obsidian-policy:$personalLibraryNamespace:$id',
      jsonEncode(policy),
    );
    policies[id] = Map.of(policy);
  }

  bool syncing = false, _syncAgain = false, _disposed = false;
  bool loading = false;
  String? error;
  Timer? _timer;
  int _generation = 0;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> connect(ObsidianConfig? next) async {
    _generation++;
    _timer?.cancel();
    config = next;
    await local.setMeta('obsidian-library-enabled', '${next != null}');
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

  Future<void> reload() {
    _refreshAgain = true;
    if (_refresh != null) return _refresh!;
    final task = _reloadTail.then((_) async {
      try {
        do {
          _refreshAgain = false;
          await _reload();
        } while (_refreshAgain && !_disposed);
      } finally {
        _refresh = null;
      }
    });
    _refresh = task;
    _reloadTail = task.catchError((Object _) {});
    return task;
  }

  Future<void> _reload() async {
    if (_disposed) return;
    final generation = _generation;
    loading = true;
    error = null;
    // Show the durable catalog before inspecting any connected files.
    await loadCached();
    try {
      if (!_migrated) {
        // Old connector stores and outboxes remain intact as a migration source.
        final cached = await ReadingLibrary(local).entries('obsidian-library:');
        final migrated = await local.meta('library-legacy-migration-v1') == '1';
        for (final ns in cached.keys.where(
          (key) => RegExp(r'^[a-f0-9]{64}$').hasMatch(key),
        )) {
          _knownNamespaces.add(ns);
          if (!migrated) {
            await LibraryExchange(local, repository, ns).importCached();
            await loadCached();
            await LibraryExchange(local, repository, ns).journals();
          }
        }
        await local.setMeta('library-legacy-migration-v1', '1');
        _migrated = true;
      }
      if (config != null) {
        _knownNamespaces.add(config!.namespace);
        await exchange!.importCached();
        await exchange!.journals();
      }
      if (_disposed) return;
      if (assets != null) {
        await AutomaticMetadata(assets!).refresh(
          repository,
          personalLibrarySchema,
          localOnly: true,
          cancelled: () => _disposed,
          onProgress: loadCached,
          onError: (_) => error = 'Не удалось прочитать сведения о некоторых файлах. Сохранённые карточки доступны.',
        );
      }
    } catch (e) {
      error = 'Не удалось обновить сведения о некоторых файлах: $e';
    } finally {
      loading = false;
      if (generation == _generation && !_disposed) await loadCached();
    }
  }

  /// Reading the catalog never waits for audio tags, artwork or source scans.
  Future<void> loadCached() async {
    if (_disposed) return;
    var values = await repository.entries();
    if (await local.meta('library-manual-archive-v1') != '1') {
      if (values.values.any(
        (e) => e.item.values['pepehub_auto_discovered'] == true,
      )) {
        await repository.mutate((cards) async {
          for (final e in cards.entries.toList()) {
            if (e.value.item.values['pepehub_auto_discovered'] == true) {
              cards[e.key] = LibraryEntry(
                e.value.item.withValues({
                  ...e.value.item.values,
                  'pepehub_source_only': true,
                }),
                sourceBookId: e.value.sourceBookId,
              );
            }
          }
        });
        values = await repository.entries();
      }
      await local.setMeta('library-manual-archive-v1', '1');
    }
    final loadedPolicies = await ReadingLibrary(local)
        .entries('obsidian-policy:$personalLibraryNamespace:');
    if (_disposed) return;
    entries = values.values.toList()
      ..sort(
        (a, b) =>
            a.item.title.toLowerCase().compareTo(b.item.title.toLowerCase()),
      );
    policies
      ..clear()
      ..addAll(
        loadedPolicies.map(
          (id, value) => MapEntry(id, Map<String, String>.from(value)),
        ),
      );
    _notify();
  }

  Future<void> sync() async {
    final adapter = exchange, connection = config;
    if (syncing) {
      _syncAgain = true;
      return;
    }
    if (adapter == null || connection == null || _disposed) return;
    final generation = _generation;
    syncing = true;
    error = null;
    _notify();
    try {
      do {
        _syncAgain = false;
        await adapter.importCached();
        final includeCover =
            await local.meta('obsidian-sync-covers') != 'false';
        for (final id in (await adapter.bindings()).keys) {
          if (includeCover) await _publishCover(id);
          await adapter.queue(id, includeCover: includeCover);
        }
        await adapter.journals(send: true);
        if (await ObsidianSyncService(
          adapter.remote,
          client,
          connection,
          covers: assets == null
              ? null
              : CoverSync(assets!, client, connection),
        ).run()) {
          _syncAgain = true;
        }
        await adapter.importCached();
        await adapter.journals();
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

  LibraryEntry? sourceDraft(String id) => _bySource[id];
  LibraryEntry? forBook(String id) {
    final entry = _bySource[id];
    return entry != null && isLibraryArchiveItem(entry.item) ? entry : null;
  }

  ObsidianLibraryItem draft(LibraryRecord book, Map<String, dynamic> details) =>
      LibraryMapper.fromBook(
        book,
        personalLibrarySchema,
        details,
        uuid.v5(Namespace.url.value, 'personal-library:${book.id}'),
      );
  ObsidianLibraryItem emptyDraft({bool audio = false}) =>
      personalLibraryItem(uuid.v4(), audio ? 'audiobook' : 'book', {
        'title': '',
        'author': <String>[],
        'genre': <String>[],
        'status': 'finished',
        'format': audio ? 'Audiobook' : 'E-book',
        'unit': audio ? 'minutes' : 'pages',
        'notes': '',
        'narrator': '',
        'language': '',
        'publisher': '',
        'tags': <String>[],
      });
  Future<ObsidianLibraryItem> prepareDraft(LibraryRecord book) async {
    final details = assets == null
        ? {...?book.payload}
        : await AutomaticMetadata(assets!).withCover(book, covers);
    final item = draft(book, details);
    await local.setMeta(
      'obsidian-auto:$personalLibraryNamespace:${item.id}',
      jsonEncode(item.values),
    );
    return item;
  }

  Future<void> _store(ObsidianLibraryItem item, String? sourceBookId) =>
      repository.mutate((cards) async {
        if (cards.containsKey(item.id) ||
            sourceBookId != null &&
                cards.values.any((e) => e.sourceBookId == sourceBookId)) {
          return;
        }
        cards[item.id] = LibraryEntry(
          personalLibraryItem(item.id, item.mediaType, {
            ...item.values,
            'pepehub_added_at':
                item.values['pepehub_added_at'] ??
                DateTime.now().toUtc().toIso8601String(),
          }),
          sourceBookId: sourceBookId,
        );
      });
  Future<void> add(
    ObsidianLibraryItem item,
    String sourceBookId, {
    Map<String, dynamic>? original,
  }) async {
    if (!libraryStatusesLocal.containsKey(
      canonicalLibraryStatus(item.value('status')),
    )) {
      throw ArgumentError(
        'В библиотеке доступны только завершённые, отложенные и брошенные произведения',
      );
    }
    final existing = (await repository.entries()).values
        .where(
          (e) =>
              e.item.id == item.id ||
              sourceBookId.isNotEmpty && e.sourceBookId == sourceBookId,
        )
        .firstOrNull;
    final values = {
      ...?existing?.item.values,
      ...item.values,
      'pepehub_auto_discovered': false,
      'pepehub_source_only': false,
      'pepehub_deleted_at': null,
      'pepehub_recommendation_only': false,
      if (isFinishedLibraryItem(item) &&
          '${item.value('endDate') ?? ''}'.isEmpty)
        'endDate': DateTime.now().toIso8601String().substring(0, 10),
    };
    if (existing != null) {
      await save(
        existing.item.id,
        values,
        original: isLibraryArchiveItem(existing.item)
            ? original ?? existing.item.values
            : existing.item.values,
      );
    } else {
      if (original != null) await _protectCleared(item.id, values, original);
      await _store(
        item.withValues(values),
        sourceBookId.isEmpty ? null : sourceBookId,
      );
      if (sourceBookId.isNotEmpty) {
        await _sourceStatus(
          LibraryEntry(item, sourceBookId: sourceBookId),
          canonicalLibraryStatus(values['status']),
        );
        final excluded = metadataStrings(
          jsonDecode(await local.meta('library-auto-excluded') ?? '[]'),
        );
        if (excluded.remove(sourceBookId)) {
          await local.setMeta('library-auto-excluded', jsonEncode(excluded));
        }
      }
      await loadCached();
    }
  }

  Future<ObsidianLibraryItem> previewLink(
    LibraryRecord book,
    ObsidianLibraryItem target,
  ) async => draft(
    book,
    matchLibraryProgress(
      assets == null
          ? {...?book.payload}
          : await AutomaticMetadata(assets!).details(book),
      target,
    ),
  );
  Future<void> link(
    String itemId,
    String sourceBookId, {
    Map<String, String>? policy,
  }) async {
    await repository.mutate((data) async {
      final entry = data[itemId];
      if (entry == null) {
        throw StateError('Карточка не найдена.');
      }
      if (data.values.any(
        (e) => e.sourceBookId == sourceBookId && e.item.id != itemId,
      )) {
        throw StateError('Книга уже связана с другой карточкой.');
      }
      data[itemId] = LibraryEntry(entry.item, sourceBookId: sourceBookId);
    });
    if (policy != null) await savePolicy(itemId, policy);
    await reload();
  }

  Future<void> save(
    String id,
    Map<String, dynamic> next, {
    required Map<String, dynamic> original,
  }) async {
    await _protectCleared(id, next, original);
    await repository.mutate((data) async {
      final entry = data[id];
      if (entry == null) throw StateError('Карточка не найдена.');
      final changed = {
        for (final key in next.keys)
          if (!sameMetadataValue(next[key], original[key])) key: next[key],
      };
      if (changed.isEmpty) return;
      for (final field in changed.entries) {
        if (!sameMetadataValue(
              entry.item.values[field.key],
              original[field.key],
            ) &&
            !sameMetadataValue(entry.item.values[field.key], field.value)) {
          throw StateError(
            'Карточка изменилась во время редактирования. Откройте её заново перед сохранением.',
          );
        }
      }
      if (changed.containsKey('status')) {
        final status = canonicalLibraryStatus(changed['status']);
        if (!libraryStatusesLocal.containsKey(status)) {
          throw ArgumentError('Неизвестный статус');
        }
        changed['status'] = status;
        if (status == 'finished' && '${next['endDate'] ?? ''}'.isEmpty) {
          changed['endDate'] = DateTime.now().toIso8601String().substring(
            0,
            10,
          );
        }
        final key = 'obsidian-policy:$personalLibraryNamespace:$id';
        final policy = await ReadingLibrary(local).value(key);
        policy['status'] = ['paused', 'abandoned', 'planned'].contains(status)
            ? 'obsidian'
            : 'auto';
        await local.setMeta(key, jsonEncode(policy));
      }
      data[id] = LibraryEntry(
        personalLibraryItem(id, entry.item.mediaType, {
          ...entry.item.values,
          ...changed,
        }),
        sourceBookId: entry.sourceBookId,
      );
      if (changed.containsKey('status')) {
        await _sourceStatus(entry, changed['status'] as String);
      }
    });
    await loadCached();
  }

  Future<void> _protectCleared(
    String id,
    Map<String, dynamic> next,
    Map<String, dynamic> original,
  ) async {
    final policy = await ReadingLibrary(local)
        .value('obsidian-policy:$personalLibraryNamespace:$id');
    for (final field in next.entries) {
      if (!sameMetadataValue(field.value, original[field.key]) &&
          (field.value == null ||
              field.value == '' ||
              field.value is List && (field.value as List).isEmpty)) {
        policy[field.key] = 'obsidian';
      }
    }
    await local.setMeta(
      'obsidian-policy:$personalLibraryNamespace:$id',
      jsonEncode(policy),
    );
  }

  Future<void> exportToObsidian(String id) async {
    if (exchange == null) {
      throw StateError('Подключите Obsidian в разделе обмена данными.');
    }
    final includeCover = await local.meta('obsidian-sync-covers') != 'false';
    if (includeCover) await _publishCover(id);
    await exchange!.queue(id, explicit: true, includeCover: includeCover);
    await sync();
  }

  Future<void> _publishCover(String id) async {
    final connection = config;
    if (connection == null || assets == null) return;
    final card = (await repository.entries())[id];
    final reference = card?.item.value('cover');
    final hash = CoverSync.referenceHash(reference);
    if (hash == null ||
        _uploadedCovers.contains('${connection.namespace}:$hash')) {
      return;
    }
    final path = coverReferencePath('$reference');
    if (path == null) return;
    await CoverSync(assets!, client, connection).publishCached(hash, path);
    _uploadedCovers.add('${connection.namespace}:$hash');
  }

  Future<void> useObsidian(String id) async {
    await exchange?.resolve(id, useRemote: true);
    await reload();
  }

  Future<void> keepLocal(String id) async {
    await exchange?.resolve(id, useRemote: false);
    await sync();
  }

  Future<void> toRecommendations(String id) async {
    final entry = (await repository.entries())[id];
    if (entry == null) return;
    final item = entry.item, store = RecommendationStore(local);
    final shelf = await store.load();
    final recommendationId = uuid.v5(
      Namespace.url.value,
      'library-recommendation:$id',
    );
    if (!shelf.books.any((b) => b.id == recommendationId)) {
      await store.saveBook(
        RecommendedBook(
          id: recommendationId,
          catalog: CatalogBook(
            source: 'manual',
            sourceId: recommendationId,
            sourceUrl: '',
            data: {
              ...item.values,
              'title': item.title,
              'authors': metadataStrings(item.value('author')),
              'genres': metadataStrings(item.value('genre')),
              'coverUrl': item.value('cover'),
              'libraryId': id,
            },
          ),
          notes: '${item.values['notes'] ?? ''}',
          categories: {
            if (shelf.categories
                    .where((c) => c.name == 'Хочу прочитать')
                    .firstOrNull
                case final category?)
              category.id: null,
          },
          createdAt: DateTime.now().toUtc().toIso8601String(),
        ),
      );
    }
    await save(id, {
      ...item.values,
      'pepehub_recommendation_only': true,
    }, original: item.values);
  }

  ObsidianLibraryItem fromRecommendation(
    RecommendedBook book, {
    bool audio = false,
  }) {
    final existing = entries
        .where(
          (e) =>
              e.item.values['pepehub_recommendation_id'] == book.id ||
              e.item.id == book.catalog.data['libraryId'],
        )
        .firstOrNull;
    final item = existing?.item ?? emptyDraft(audio: audio);
    if (existing != null &&
        isFinishedLibraryItem(item) &&
        item.values['pepehub_recommendation_only'] != true) {
      return item.withValues({...item.values, 'pepehub_deleted_at': null});
    }
    return personalLibraryItem(item.id, item.mediaType, {
      ...item.values,
      for (final field in [
        'description',
        'language',
        'publisher',
        'isbn',
        'year',
        'tags',
        'series',
      ])
        if (book.catalog.data.containsKey(field))
          field: book.catalog.data[field],
      if (book.catalog.data['seriesIndex'] != null ||
          book.catalog.data['seriesNumber'] != null)
        'seriesIndex':
            book.catalog.data['seriesIndex'] ??
            book.catalog.data['seriesNumber'],
      'title': book.catalog.title,
      'author': book.catalog.authors,
      'genre': metadataStrings(book.catalog.data['genres']),
      'cover': book.catalog.coverUrl ?? item.value('cover'),
      'notes': book.notes,
      'status': 'finished',
      'pepehub_recommendation_id': book.id,
      'pepehub_recommendation_data': book.catalog.toJson(),
      'pepehub_recommendation_only': false,
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
