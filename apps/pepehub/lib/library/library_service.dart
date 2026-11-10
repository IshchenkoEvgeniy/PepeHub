import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../data/repository.dart';
import '../audio/manual_audio_progress.dart';
import '../reader/reading_library.dart';
import '../recommendations/recommendation_store.dart';
import '../media/asset_store.dart';
import 'library_repository.dart';
import 'library_mapper.dart';
import 'library_exchange.dart';
import 'personal_library.dart';
import 'models.dart';
import 'activity_store.dart';
import 'cover_sync.dart';
import 'automatic_metadata.dart';
import 'note_store.dart';
import 'metadata_values.dart';
import 'library_features.dart';
import 'series_draft.dart';
import 'library_folder_storage.dart';
import 'purged_books.dart';
import '../diagnostics/user_message.dart';

class LibraryService extends ChangeNotifier {
  final Repository local;
  final http.Client client;
  final AssetStore? assets;
  LibraryService(this.local, this.client, {this.assets});
  late final folderStorage = LibraryFolderStorage(this);
  LibraryRepository get repository => LibraryRepository(
    local,
    personalLibraryNamespace,
    storageKey: personalLibraryKey,
  );
  ActivityStore? get history =>
      ActivityStore(local, personalLibraryNamespace, catalog: repository);
  NoteStore? get notes =>
      NoteStore(local, personalLibraryNamespace, catalog: repository);
  CoverSync? get covers => assets == null ? null : CoverSync.local(assets!);
  Future<String?> chooseCover() async {
    if (covers == null) throw StateError('Хранилище обложек недоступно.');
    return covers!.choose();
  }

  final Set<String> _knownNamespaces = {};
  bool _migrated = false;
  Future<void> _reloadTail = Future.value();
  Future<void>? _refresh;
  bool _refreshAgain = false;
  Future<void> get idle => _reloadTail;
  String? coverHash(LibraryItem item) {
    final cover = '${item.value('cover') ?? ''}';
    final reference = CoverSync.referenceHash(cover);
    if (reference != null) return reference;
    // The imported copy also belongs to an unchanged HTTP(S) reference and is
    // usable offline. A cover edit explicitly clears this value, including on
    // legacy items that still carry a top-level coverAsset.
    final stored = item.values.containsKey('pepehub_cover_asset')
        ? item.values['pepehub_cover_asset']
        : item.coverAsset;
    final hash = stored is Map ? stored['hash'] : null;
    return CoverSync.referenceHash('pepehub-cover:$hash');
  }

  String? coverPath(LibraryItem item) {
    final hash = coverHash(item);
    return hash == null ? null : coverReferencePath('pepehub-cover:$hash');
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
  List<LibraryEntry> _seriesEntries = [], _unreadSeriesEntries = [];
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
    final series = value.where((e) => isSeriesCatalogItem(e.item)).toList();
    _seriesEntries = List.unmodifiable(
      series.where((e) => !isLibraryDeleted(e.item)),
    );
    _unreadSeriesEntries = List.unmodifiable(
      _seriesEntries.where((e) => isUnreadSeriesItem(e.item)),
    );
    _trash = List.unmodifiable(series.where((e) => isLibraryDeleted(e.item)));
    _bySource.clear();
    for (final e in value) {
      if (e.sourceBookId != null) _bySource[e.sourceBookId!] = e;
    }
  }

  List<LibraryEntry> get completed => _completed;
  List<LibraryEntry> get inbox => _inbox;
  List<LibraryEntry> get trash => _trash;
  List<LibraryEntry> get visibleEntries => _visible;
  List<LibraryEntry> get seriesEntries => _seriesEntries;
  List<LibraryEntry> get unreadSeriesEntries => _unreadSeriesEntries;
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

  Future<void> restoreCard(String id) => restoreCards([id]);

  Future<void> restoreCards(Iterable<String> ids) async {
    final selected = ids.toSet();
    await repository.mutate((cards) async {
      for (final id in selected) {
        final card = cards[id];
        if (card == null || !isLibraryDeleted(card.item)) continue;
        cards[id] = LibraryEntry(
          card.item.withValues({
            ...card.item.values,
            'pepehub_deleted_at': null,
          }),
          sourceBookId: card.sourceBookId,
        );
      }
    });
    await loadCached();
  }

  Future<({int count, Set<String> covers})> _purgeCards(
    Iterable<String> ids, {
    bool includeVisible = false,
  }) async {
    final removed = <String>{};
    final coverHashes = <String>{};
    await repository.mutate((cards) async {
      for (final id in ids.toSet()) {
        final card = cards[id];
        if (card != null &&
            (isLibraryDeleted(card.item) ||
                includeVisible && isSeriesCatalogItem(card.item))) {
          cards.remove(id);
          removed.add(id);
          final hash = coverHash(card.item);
          if (hash != null) coverHashes.add(hash);
        }
      }
      if (removed.isEmpty) return;
      for (final store in [history!, notes!]) {
        await store.mutate((state) async {
          (state['slots'] as Map).removeWhere(
            (_, slot) => removed.contains((slot['value'] as Map)['itemId']),
          );
        });
      }
      await LibraryExchange.detachRemovedCards(local, removed);
      for (final id in removed) {
        await local.db.customStatement(
          'DELETE FROM metadata WHERE key IN (?,?)',
          [
            'obsidian-policy:$personalLibraryNamespace:$id',
            'obsidian-auto:$personalLibraryNamespace:$id',
          ],
        );
      }
    });
    return (count: removed.length, covers: coverHashes);
  }

  Future<void> _discardUnusedCovers(Set<String> hashes) async {
    final storage = covers;
    if (storage == null || hashes.isEmpty) return;
    await local.db.transaction(() async {
      final cards = await repository.entries();
      final referenced = cards.values.map((card) => coverHash(card.item));
      for (final hash in hashes.difference(referenced.nonNulls.toSet())) {
        await storage.discardCached(hash);
      }
    });
  }

  /// Removes archive data without changing the source files or native history.
  Future<int> purgeCards(
    Iterable<String> ids, {
    bool includeVisible = false,
  }) async {
    final removed = await _purgeCards(ids, includeVisible: includeVisible);
    await _discardUnusedCovers(removed.covers);
    await loadCached();
    return removed.count;
  }

  Iterable<String> _expiredCards(Iterable<LibraryEntry> entries, int days) {
    if (![7, 30, 90].contains(days)) return const [];
    final cutoff = DateTime.now().toUtc().subtract(Duration(days: days));
    return entries
        .where((entry) {
          final deleted = DateTime.tryParse(
            '${entry.item.values['pepehub_deleted_at']}',
          );
          return deleted != null && deleted.isBefore(cutoff);
        })
        .map((entry) => entry.item.id);
  }

  Future<void> setTrashRetention(int days) async {
    if (![0, 7, 30, 90].contains(days)) {
      throw ArgumentError('Срок хранения: 0, 7, 30 или 90 дней');
    }
    final removed = await local.db.transaction(() async {
      await local.setMeta('library-trash-retention-days', '$days');
      return _purgeCards(
        _expiredCards((await repository.entries()).values, days),
      );
    });
    await _discardUnusedCovers(removed.covers);
    await loadCached();
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

  /// Completing an item fills known progress. Explicit editor values win.
  void _completeItem(LibraryItem before, Map<String, dynamic> changes) {
    if (isFinishedLibraryItem(before) ||
        canonicalLibraryStatus(changes['status']) != 'finished') {
      return;
    }
    final total = num.tryParse('${changes['total'] ?? before.value('total')}');
    if (!changes.containsKey('progress') &&
        total != null &&
        total.isFinite &&
        total > 0) {
      changes['progress'] = total;
    }
    if (!changes.containsKey('endDate') &&
        (isUnreadSeriesItem(before) ||
            '${before.value('endDate') ?? ''}'.isEmpty)) {
      changes['endDate'] = DateTime.now().toIso8601String().substring(0, 10);
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
    if (status != null &&
        !libraryStatusesLocal.containsKey(status) &&
        status != 'unread') {
      throw ArgumentError('Неизвестный статус');
    }
    await local.db.transaction(() async {
      await repository.mutate((cards) async {
        for (final id in selected) {
          final card = cards[id];
          if (card == null || isLibraryDeleted(card.item)) continue;
          final patch = {...changes, if (reread) 'status': 'finished'};
          _completeItem(card.item, patch);
          final values = {...card.item.values, ...patch};
          if (card.item.mediaType == 'audiobook' &&
              patch.containsKey('progress')) {
            values.addAll(manualAudioProgressStamp(values));
          }
          final updated = card.item.withValues(values);
          if (libraryStatus(updated) == 'unread' &&
              !isUnreadSeriesItem(updated)) {
            throw ArgumentError('Непрочитанный том должен относиться к серии');
          }
          if (changes.containsKey('series') &&
              seriesTextKey(changes['series']) !=
                  seriesTextKey(card.item.value('series'))) {
            values['pepehub_series_id'] = null;
          }
          if (reread && !isUnreadSeriesItem(card.item)) {
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
                ['paused', 'abandoned', 'planned', 'unread'].contains(status)
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
    if (status == 'unread') status = 'planned';
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
  Map<String, List<String>> get suggestions =>
      metadataSuggestions(visibleEntries);
  Map<String, dynamic>? collectionFor(LibraryItem item) =>
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

  bool _disposed = false;
  bool loading = false;
  String? error;
  void _notify() {
    if (!_disposed) notifyListeners();
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
    loading = true;
    error = null;
    // Paint the working copy even while an external folder is reconnecting.
    await loadCached();
    try {
      await folderStorage.synchronize();
    } on LibraryFolderPending {
      // Shown on the «Данные» screen; the next check retries.
    } catch (e) {
      error = 'Не удалось обновить папку библиотеки: ${describeError(e)}';
    }
    // Show imported cards before inspecting any connected book files.
    await loadCached();
    try {
      if (!_migrated) {
        // Stores of the old connector remain intact as a migration source.
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
      error =
          'Не удалось обновить сведения о некоторых файлах: ${describeError(e)}';
    } finally {
      loading = false;
      if (!_disposed) await loadCached();
    }
  }

  /// Reading the catalog never waits for audio tags, artwork or source scans.
  Future<void> loadCached() async {
    if (_disposed) return;
    var values = await repository.entries();
    if (missingLibrarySeriesLinks(values.values).isNotEmpty) {
      await repository.mutate((cards) async {
        for (final link in missingLibrarySeriesLinks(cards.values).entries) {
          final entry = cards[link.key]!;
          cards[link.key] = LibraryEntry(
            entry.item.withValues({
              ...entry.item.values,
              'pepehub_series_id': link.value,
            }),
            sourceBookId: entry.sourceBookId,
            state: entry.state,
            message: entry.message,
            operation: entry.operation,
            remote: entry.remote,
          );
        }
      });
      values = await repository.entries();
    }
    final retention =
        int.tryParse(await local.meta('library-trash-retention-days') ?? '') ??
        0;
    final expired = _expiredCards(values.values, retention).toList();
    if (expired.isNotEmpty) {
      final removed = await _purgeCards(expired);
      await _discardUnusedCovers(removed.covers);
      values = await repository.entries();
    }
    // Older versions kept the service records of books the trash had already
    // deleted for good; drop them once, the trash does it from now on.
    if (await local.meta('library-purged-book-drafts-v1') != '1') {
      if (await discardPurgedBookDrafts(local) > 0) {
        values = await repository.entries();
      }
      await local.setMeta('library-purged-book-drafts-v1', '1');
    }
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

  LibraryEntry? sourceDraft(String id) => _bySource[id];
  LibraryEntry? forBook(String id) {
    final entry = _bySource[id];
    return entry != null && isLibraryArchiveItem(entry.item) ? entry : null;
  }

  LibraryItem draft(LibraryRecord book, Map<String, dynamic> details) =>
      LibraryMapper.fromBook(
        book,
        personalLibrarySchema,
        details,
        uuid.v5(Namespace.url.value, 'personal-library:${book.id}'),
      );
  LibraryItem emptyDraft({bool audio = false}) =>
      personalLibraryItem(uuid.v4(), audio ? 'audiobook' : 'book', {
        'title': '',
        'author': <String>[],
        'genre': <String>[],
        'status': 'finished',
        'format': audio ? 'Audiobook' : 'E-book',
        'unit': audio ? 'minutes' : 'pages',
        'notes': '',
        if (audio) 'narrator': <String>[],
        'language': '',
        'publisher': '',
        'tags': <String>[],
      });
  Future<LibraryItem> prepareDraft(LibraryRecord book) async {
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

  Future<void> _store(LibraryItem item, String? sourceBookId) =>
      repository.mutate((cards) async {
        if (cards.containsKey(item.id) ||
            sourceBookId != null &&
                cards.values.any((e) => e.sourceBookId == sourceBookId)) {
          return;
        }
        cards[item.id] = LibraryEntry(
          personalLibraryItem(item.id, item.mediaType, {
            ...item.values,
            if (item.mediaType == 'audiobook' &&
                item.values['pepehub_audio_progress_at'] == null)
              ...manualAudioProgressStamp(item.values),
            'pepehub_added_at':
                item.values['pepehub_added_at'] ??
                DateTime.now().toUtc().toIso8601String(),
          }),
          sourceBookId: sourceBookId,
        );
      });
  Future<void> add(
    LibraryItem item,
    String sourceBookId, {
    Map<String, dynamic>? original,
  }) async {
    if (!libraryItemStatuses(item)
        .containsKey(canonicalLibraryStatus(item.value('status')))) {
      throw ArgumentError(
        'Выберите статус произведения; непрочитанный том должен относиться к серии',
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

  /// Save the reviewed batch once. A failed validation or write leaves both the
  /// new series and existing cards untouched; missing dates stay unknown.
  Future<List<String>> addSeries(
    Iterable<LibraryItem> items, {
    Set<String> allowDuplicateIds = const {},
    String? existingSeriesKey,
  }) async {
    final drafts = items.toList();
    if (drafts.isEmpty || drafts.length > 1000) {
      throw ArgumentError('Выберите от 1 до 1000 томов.');
    }
    final ids = <String>{};
    final seriesIds = <String>{};
    final seriesNames = <String>{};
    for (final item in drafts) {
      validateSeriesDraft(item);
      if (!ids.add(item.id)) {
        throw ArgumentError('Карточка повторяется в списке.');
      }
      final seriesId = item.values['pepehub_series_id'];
      if (seriesId is! String || seriesId.isEmpty) {
        throw ArgumentError('Не задана серия.');
      }
      seriesIds.add(seriesId);
      seriesNames.add(seriesTextKey(item.value('series')));
    }
    if (seriesIds.length != 1 || seriesNames.length != 1) {
      throw ArgumentError(
        'Все выбранные тома должны относиться к одной серии.',
      );
    }
    await repository.mutate((cards) async {
      if (ids.any(cards.containsKey)) {
        throw StateError(
          'Карточки уже были сохранены. Откройте библиотеку заново.',
        );
      }
      if (cards.values.any(
        (e) =>
            librarySeriesKey(e.item) == 'series-id:${seriesIds.single}' &&
            librarySeriesKey(e.item) != existingSeriesKey,
      )) {
        throw StateError(
          'Эта серия уже существует. Откройте её и выберите «Добавить тома».',
        );
      }
      final target = existingSeriesKey == null
          ? <LibraryEntry>[]
          : cards.values
                .where(
                  (e) =>
                      isSeriesCatalogItem(e.item) &&
                      !isLibraryDeleted(e.item) &&
                      librarySeriesKey(e.item) == existingSeriesKey,
                )
                .toList();
      if (existingSeriesKey != null && target.isEmpty) {
        throw StateError(
          'Серия изменилась. Откройте её заново перед добавлением.',
        );
      }
      if (target.any(
            (e) => seriesTextKey(e.item.value('series')) != seriesNames.single,
          ) ||
          target.any(
            (e) =>
                e.item.values['pepehub_series_id'] != null &&
                e.item.values['pepehub_series_id'] != seriesIds.single,
          )) {
        throw StateError(
          'Серия изменилась. Откройте её заново перед добавлением.',
        );
      }
      final conflicts = seriesDraftConflicts(
        drafts,
        cards.values,
        existingSeriesKey: existingSeriesKey,
      );
      if (conflicts.keys.any((id) => !allowDuplicateIds.contains(id))) {
        throw StateError(
          'Обнаружены совпадения. Проверьте список томов ещё раз.',
        );
      }
      final addedAt = DateTime.now().toUtc().toIso8601String();
      for (final e in target) {
        cards[e.item.id] = LibraryEntry(
          e.item.withValues({
            ...e.item.values,
            'pepehub_series_id': seriesIds.single,
          }),
          sourceBookId: e.sourceBookId,
          state: e.state,
          message: e.message,
          operation: e.operation,
          remote: e.remote,
        );
      }
      for (final item in drafts) {
        cards[item.id] = LibraryEntry(
          personalLibraryItem(item.id, item.mediaType, {
            ...item.values,
            'series': '${drafts.first.value('series')}'.trim(),
            'status': libraryStatus(item),
            'pepehub_added_at': addedAt,
            'pepehub_auto_discovered': false,
            'pepehub_source_only': false,
            'pepehub_recommendation_only': false,
            'pepehub_deleted_at': null,
            if (item.mediaType == 'audiobook')
              ...manualAudioProgressStamp(item.values),
          }),
        );
      }
    });
    await loadCached();
    return ids.toList();
  }

  Future<LibraryItem> previewLink(
    LibraryRecord book,
    LibraryItem target,
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
      if (changed.containsKey('series') &&
          seriesTextKey(changed['series']) !=
              seriesTextKey(entry.item.value('series')) &&
          !changed.containsKey('pepehub_series_id')) {
        changed['pepehub_series_id'] = null;
      }
      if (changed.containsKey('cover') &&
          !changed.containsKey('pepehub_cover_asset')) {
        changed['pepehub_cover_asset'] = null;
      }
      _completeItem(entry.item, changed);
      final updated = entry.item.withValues({...entry.item.values, ...changed});
      if (libraryStatus(updated) == 'unread' && !isUnreadSeriesItem(updated)) {
        throw ArgumentError('Непрочитанный том должен относиться к серии');
      }
      if (changed.containsKey('status')) {
        final status = canonicalLibraryStatus(changed['status']);
        if (!libraryItemStatuses(updated).containsKey(status)) {
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
        policy['status'] =
            ['paused', 'abandoned', 'planned', 'unread'].contains(status)
            ? 'obsidian'
            : 'auto';
        await local.setMeta(key, jsonEncode(policy));
      }
      if (entry.item.mediaType == 'audiobook') {
        if (changed.containsKey('progress') || changed.containsKey('unit')) {
          changed.addAll(
            manualAudioProgressStamp({...entry.item.values, ...changed}),
          );
        } else if (entry.item.values['pepehub_audio_progress_at'] == null) {
          // Preserve a legacy card's cutoff before a title/status/date edit
          // changes modifiedAt. Its original manual edit time is unavailable.
          changed.addAll(
            manualAudioProgressStamp(
              entry.item.values,
              at: DateTime.fromMillisecondsSinceEpoch(
                entry.item.modifiedAt,
                isUtc: true,
              ),
            ),
          );
        }
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

  LibraryItem fromRecommendation(
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
    folderStorage.dispose();
    super.dispose();
  }
}
