import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:drift/drift.dart' show Variable;

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
  final Map<String, int> _discoveredRevisions = {};
  String? coverPath(ObsidianLibraryItem item) =>
      coverReferencePath('${item.value('cover') ?? ''}');
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

  List<LibraryEntry> entries = [];
  List<LibraryEntry> get completed => entries
      .where(
        (e) =>
            isFinishedLibraryItem(e.item) &&
            e.item.values['pepehub_recommendation_only'] != true,
      )
      .toList();
  List<LibraryEntry> get inbox => entries
      .where(
        (e) =>
            !isFinishedLibraryItem(e.item) &&
            e.item.values['pepehub_recommendation_only'] != true,
      )
      .toList();
  Map<String, dynamic>? snapshot = personalLibrarySchema;
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
    final task = _reloadTail.then((_) => _reload());
    _reloadTail = task.catchError((Object _) {});
    return task;
  }

  Future<void> _reload() async {
    final generation = _generation;
    if (!_migrated) {
      // Old connector stores and outboxes remain intact as a migration source.
      final cached = await ReadingLibrary(local).entries('obsidian-library:');
      for (final ns in cached.keys.where(
        (key) => RegExp(r'^[a-f0-9]{64}$').hasMatch(key),
      )) {
        _knownNamespaces.add(ns);
        await LibraryExchange(local, repository, ns).importCached();
        await LibraryExchange(local, repository, ns).journals();
      }
      _migrated = true;
    }
    if (config != null) {
      _knownNamespaces.add(config!.namespace);
      await exchange!.importCached();
      await exchange!.journals();
    }
    await _captureCompleted();
    if (assets != null) {
      await AutomaticMetadata(assets!)
          .refresh(repository, personalLibrarySchema, localOnly: true);
    }
    final values = await repository.entries();
    final loadedPolicies = <String, Map<String, String>>{};
    for (final entry in values.values) {
      final raw = await local.meta(
        'obsidian-policy:$personalLibraryNamespace:${entry.item.id}',
      );
      if (raw != null) {
        loadedPolicies[entry.item.id] = Map<String, String>.from(
          jsonDecode(raw) as Map,
        );
      }
    }
    if (generation != _generation || _disposed) return;
    entries = values.values.toList()
      ..sort(
        (a, b) =>
            a.item.title.toLowerCase().compareTo(b.item.title.toLowerCase()),
      );
    policies
      ..clear()
      ..addAll(loadedPolicies);
    _notify();
  }

  Future<void> _captureCompleted() async {
    final cards = await repository.entries();
    final reading = ReadingLibrary(local);
    final rows = await local.db
        .customSelect(
          "SELECT b.id,coalesce(s.revision,0) AS revision FROM records b LEFT JOIN library_source_revisions_v1 s ON s.book_id=b.id WHERE b.type='book' AND b.deleted=0 AND json_valid(b.payload)",
        )
        .get();
    final linked = cards.values.map((e) => e.sourceBookId).toSet();
    for (final row in rows) {
      final id = row.read<String>('id'), revision = row.read<int>('revision');
      if (linked.contains(id) || _discoveredRevisions[id] == revision) {
        continue;
      }
      final book = await local.record(id);
      if (book == null || book.deleted) continue;
      final audio = book.payload?['format'] == 'audio';
      final prefs = await reading.value(
        '${audio ? 'audio' : 'reading'}-book:${book.id}',
      );
      final status = audio
          ? (await local.meta('audio-status-override:${book.id}') ??
                book.payload?['status'])
          : ((prefs['overrides'] as Map?)?['status'] ??
                book.payload?['status']);
      final overrides = prefs['overrides'] as Map? ?? {};
      final ended =
          overrides['finishedAt'] ??
          prefs['finishedAt'] ??
          book.payload?['finishedAt'];
      final audioCompleted =
          audio &&
          !['planned', 'paused'].contains(
            canonicalLibraryStatus(
              await local.meta('audio-status-override:${book.id}'),
            ),
          ) &&
          (await local.db
                  .customSelect(
                    r"SELECT 1 FROM records r WHERE r.type='audio_event' AND r.deleted=0 AND json_valid(r.payload) AND json_extract(r.payload,'$.bookId')=? AND json_extract(r.payload,'$.kind')='completed' AND EXISTS(SELECT 1 FROM audio_tracks t JOIN audio_editions e ON e.id=t.edition_id WHERE t.id=json_extract(r.payload,'$.trackId') AND e.book_id=? AND NOT EXISTS(SELECT 1 FROM audio_tracks later WHERE later.edition_id=t.edition_id AND later.ordinal>t.ordinal)) LIMIT 1",
                    variables: [Variable(book.id), Variable(book.id)],
                  )
                  .getSingleOrNull()) !=
              null;
      if (canonicalLibraryStatus(status) != 'finished' &&
          ended == null &&
          !audioCompleted) {
        _discoveredRevisions[id] = revision;
        continue;
      }
      final draft = await prepareDraft(book);
      if (isFinishedLibraryItem(draft)) {
        await _store(draft, book.id);
      }
      _discoveredRevisions[id] = revision;
    }
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

  LibraryEntry? forBook(String id) =>
      entries.where((e) => e.sourceBookId == id).firstOrNull;
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
          personalLibraryItem(item.id, item.mediaType, item.values),
          sourceBookId: sourceBookId,
        );
      });
  Future<void> add(
    ObsidianLibraryItem item,
    String sourceBookId, {
    Map<String, dynamic>? original,
  }) async {
    if (original != null) await _protectCleared(item.id, item.values, original);
    await _store(item, sourceBookId.isEmpty ? null : sourceBookId);
    await reload();
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
      data[id] = LibraryEntry(
        personalLibraryItem(id, entry.item.mediaType, {
          ...entry.item.values,
          ...changed,
        }),
        sourceBookId: entry.sourceBookId,
      );
    });
    await reload();
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
      return item;
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
