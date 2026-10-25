import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../data/repository.dart';
import '../../media/asset_store.dart';
import '../../video/models.dart';
import '../../video/media_formats.dart';
import '../../video/video_import.dart';
import '../../video/video_repository.dart';
import 'app_sync_models.dart';
import 'app_sync_store.dart';
import 'peer_files.dart';
import 'peer_models.dart';

String sharedMediaId(String key) =>
    uuid.v5(Namespace.url.value, 'pepehub:app-sync:$key');
const _idFields = {
  'collections',
  'id',
  'bookId',
  'editionId',
  'trackId',
  'lessonId',
  'itemId',
  'mediaId',
};

class AppSyncMedia {
  final AppSyncStore store;
  final List<PeerFolder> Function() folders;
  final bool verifyNewFiles;
  final Map<String, String> outgoing = {}, incoming = {}, resources = {};
  final Map<String, String> currentHashes = {};
  final Map<String, String> currentAudioManifests = {};
  final Set<String> ambiguous = {};
  final Map<String, Map<String, dynamic>> aliases = {}, documents = {};
  final List<String> warnings = [];
  AppSyncMedia(this.store, this.folders, {this.verifyNewFiles = true});
  Repository get repository => store.peer.repository;
  String? local(String shared) => incoming[shared];
  Future<void> _bind(
    String kind,
    String id,
    String common,
    Map<String, dynamic> data,
  ) async {
    final previous = aliases['$kind:$id'];
    common = previous?['shared'] as String? ?? common;
    if (previous == null ||
        appSyncJson(previous['data']) != appSyncJson(data)) {
      await store.alias(kind, id, common, data);
    }
    aliases['$kind:$id'] = {
      'kind': kind,
      'local': id,
      'shared': common,
      'data': data,
    };
    outgoing[id] = common;
    incoming.putIfAbsent(common, () => id);
    if (data['descriptor'] case final Map descriptor) {
      documents['media:$kind:$common'] = Map<String, dynamic>.from(descriptor);
    }
  }

  ({PeerFolder folder, String path})? location(String source) {
    for (final folder in folders()) {
      if (folder.paused) continue;
      if (source.startsWith('content://') &&
          folder.root.startsWith('content://')) {
        final document = Uri.parse(source), tree = Uri.parse(folder.root);
        if (document.authority != tree.authority) continue;
        final parts = tree.pathSegments;
        final index = parts.indexOf('tree');
        if (index < 0 ||
            index + 1 >= parts.length ||
            !document.pathSegments.contains('document')) {
          continue;
        }
        final root = parts[index + 1], value = document.pathSegments.last;
        if (value.startsWith('$root/')) {
          return (
            folder: folder,
            path: peerPath(value.substring(root.length + 1)),
          );
        }
      } else if (!source.startsWith('content:') &&
          !folder.root.startsWith('content:') &&
          p.isWithin(folder.root, source)) {
        return (
          folder: folder,
          path: peerPath(
            p.relative(source, from: folder.root).replaceAll('\\', '/'),
          ),
        );
      }
    }
    return null;
  }

  Future<Map<String, dynamic>?> _source(
    String path,
    String name,
    int bytes, {
    String? knownHash,
  }) async {
    final place = location(path);
    final entry = place == null
        ? null
        : await store.peer.entry(place.folder.id, place.path);
    if (entry?.deleted == true) return null;
    final hash =
        entry?.hash ??
        (knownHash != null && appSyncHash.hasMatch(knownHash)
            ? knownHash
            : null);
    if (hash == null ||
        entry != null &&
            knownHash != null &&
            appSyncHash.hasMatch(knownHash) &&
            hash != knownHash) {
      return null;
    }
    return {
      'hash': hash,
      'bytes': entry?.bytes ?? bytes,
      'name': name,
      if (place != null) 'folder': place.folder.id,
      if (place != null) 'path': place.path,
    };
  }

  Future<void> prepare() async {
    outgoing.clear();
    incoming.clear();
    resources.clear();
    currentHashes.clear();
    currentAudioManifests.clear();
    ambiguous.clear();
    documents.clear();
    aliases.clear();
    warnings.clear();
    for (final alias in await store.aliases()) {
      aliases['${alias['kind']}:${alias['local']}'] = alias;
      outgoing[alias['local'] as String] = alias['shared'] as String;
      incoming.putIfAbsent(
        alias['shared'] as String,
        () => alias['local'] as String,
      );
      final data = Map<String, dynamic>.from(alias['data'] as Map);
      if (data['descriptor'] case final Map descriptor) {
        documents['media:${alias['kind']}:${alias['shared']}'] =
            Map<String, dynamic>.from(descriptor);
      }
      if (data['resource'] is String && data['hash'] is String) {
        resources[data['resource'] as String] = data['hash'] as String;
      }
    }
    final assets = await AssetStore(repository, pDirectoryPlaceholder).list();
    final byBook = <String, List<LocalAsset>>{};
    for (final asset in assets) {
      (byBook[asset.bookId] ??= []).add(asset);
    }
    for (final book in await repository.records('book')) {
      final own = byBook[book.id] ?? [];
      if (own.isEmpty) continue;
      final audio = book.payload?['format'] == 'audio';
      final ordered = audio
          ? await repository.db
                .customSelect(
                  'SELECT t.id,t.edition_id,t.ordinal,t.title,t.duration_ms,r.path,r.sha256,r.bytes,e.manifest_revision FROM audio_tracks t JOIN audio_editions e ON e.id=t.edition_id JOIN audio_resources r ON r.sha256=t.asset_hash WHERE e.book_id=? ORDER BY t.ordinal',
                  variables: [Variable(book.id)],
                )
                .get()
          : <QueryRow>[];
      final sources = <Map<String, dynamic>>[];
      if (audio) {
        for (final track in ordered) {
          final source = await _source(
            track.read<String>('path'),
            track.read<String>('title'),
            track.read<int>('bytes'),
            knownHash: track.read<String>('sha256'),
          );
          if (source == null) {
            sources.clear();
            break;
          }
          sources.add({...source});
        }
      } else {
        final source = await _source(
          own.first.path,
          own.first.filename,
          own.first.bytes,
          knownHash: own.first.hash,
        );
        if (source != null) sources.add(source);
      }
      if (sources.isEmpty) {
        warnings.add(
          '${book.title}: для связи источника подключите его общую папку',
        );
        continue;
      }
      final manifest = appSyncDigest(sources.map((s) => s['hash']).toList());
      final common =
          outgoing[book.id] ??
          sharedMediaId('${audio ? 'audio' : 'book'}:$manifest');
      if (audio) {
        final edition = ordered.first.read<String>('edition_id');
        currentAudioManifests[edition] = manifest;
        final revision = ordered.first.read<int>('manifest_revision');
        final previous = aliases['edition:$edition']?['data'] as Map?;
        if (previous != null &&
            previous['manifest'] != manifest &&
            previous['revision'] == revision) {
          warnings.add(
            '${book.title}: состав или содержимое изменилось; обновите издание аудиокниги',
          );
          continue;
        }
        await _bind('edition', edition, sharedMediaId('edition:$common'), {
          'book': common,
          'manifest': manifest,
          'revision': revision,
        });
        for (var i = 0; i < ordered.length; i++) {
          final track = ordered[i];
          final sharedTrack =
              outgoing[track.read<String>('id')] ??
              sharedMediaId('track:$common:$i:${sources[i]['hash']}');
          sources[i]['id'] = sharedTrack;
          final resource = track.read<String>('sha256');
          resources[resource] = sources[i]['hash'] as String;
          await _bind('track', track.read<String>('id'), sharedTrack, {
            'book': common,
            'resource': resource,
            'hash': sources[i]['hash'],
          });
        }
      }
      await _bind('book', book.id, common, {
        'descriptor': {
          'kind': audio ? 'audio' : 'book',
          'format': book.payload?['format'],
          'manifest': manifest,
          'sources': sources,
        },
      });
    }
    final video = VideoRepository(repository);
    final allLessons = await video.lessons();
    for (final item in await video.items()) {
      final lessons = allLessons.where((l) => l.itemId == item.id).toList();
      final located = <String, Map<String, dynamic>>{};
      for (final lesson in lessons) {
        final source = await _source(lesson.source, lesson.title, 0);
        if (source != null) located[lesson.id] = source;
      }
      if (located.isEmpty) continue;
      final first = located.values.first;
      String? rootToken;
      if (item.root != null) {
        for (final folder in folders()) {
          if (item.root!.startsWith('content://') &&
              folder.root.startsWith('content://')) {
            final root = Uri.parse(item.root!), shared = Uri.parse(folder.root);
            final rootId = root.pathSegments.last,
                sharedId = shared.pathSegments.last;
            if (root.authority == shared.authority &&
                (rootId == sharedId || rootId.startsWith('$sharedId/'))) {
              rootToken =
                  '${folder.id}:${rootId == sharedId ? '.' : rootId.substring(sharedId.length + 1)}';
              break;
            }
          } else if (p.equals(item.root!, folder.root) ||
              p.isWithin(folder.root, item.root!)) {
            rootToken =
                '${folder.id}:${p.relative(item.root!, from: folder.root).replaceAll('\\', '/')}';
            break;
          }
        }
      }
      final token = rootToken ?? '${first['folder']}:${first['path']}';
      final common = outgoing[item.id] ?? sharedMediaId('course:$token');
      await _bind('item', item.id, common, {
        'descriptor': {
          'kind': item.kind.name,
          'title': item.title,
          'favorite': item.favorite,
        },
      });
      for (final lesson in lessons) {
        final source = located[lesson.id];
        if (source == null) continue;
        currentHashes[lesson.id] = source['hash'] as String;
        final old = aliases['lesson:${lesson.id}'];
        final versions = Map<String, dynamic>.from(
          (old?['data'] as Map?)?['versions'] as Map? ?? {},
        );
        if (versions[lesson.mediaVersion] != null &&
            versions[lesson.mediaVersion] != source['hash']) {
          warnings.add(
            '${lesson.title}: содержимое изменилось; обновите папку курса перед переносом позиции',
          );
          continue;
        }
        if (!versions.containsKey(lesson.mediaVersion)) {
          final record = await repository.record(lesson.id);
          if (record?.payload?['fileIdentity'] case final Map identity) {
            try {
              await verifyVideoSources([
                VideoSourceDraft(
                  lesson.source,
                  lesson.title,
                  identity: VideoFileIdentity.fromJson(
                    Map<String, dynamic>.from(identity),
                  ),
                ),
              ]);
            } catch (_) {
              warnings.add(
                '${lesson.title}: обновите изменённый источник курса',
              );
              continue;
            }
          }
          versions[lesson.mediaVersion] = source['hash'];
        }
        final sharedLesson =
            outgoing[lesson.id] ??
            sharedMediaId('lesson:$common:${lesson.module}/${source['path']}');
        await _bind('lesson', lesson.id, sharedLesson, {
          'versions': versions,
          'descriptor': {
            'itemId': common,
            'title': lesson.title,
            'module': lesson.module,
            'ordinal': lesson.ordinal,
            if (lesson.isAudio) 'audio': true,
            if (lesson.music != null)
              'music': {
                'artist': lesson.music!.artist,
                'album': lesson.music!.album,
                if (lesson.music!.trackNumber != null)
                  'trackNumber': lesson.music!.trackNumber,
              },
            'mediaVersion': versions[lesson.mediaVersion],
            'source': source,
          },
        });
      }
    }
  }

  void checkAmbiguousBindings() {
    final grouped = <String, Set<String>>{};
    for (final value in aliases.values.where(
      (a) => {'book', 'item', 'lesson'}.contains(a['kind']),
    )) {
      (grouped[value['shared'] as String] ??= {}).add(value['local'] as String);
    }
    ambiguous.addAll(
      grouped.entries.where((e) => e.value.length > 1).map((e) => e.key),
    );
    if (ambiguous.isEmpty) return;
    for (final value in aliases.values) {
      if (ambiguous.contains(value['shared']) ||
          ambiguous.contains((value['data'] as Map)['book'])) {
        outgoing.remove(value['local']);
        incoming.remove(value['shared']);
        documents.remove('media:${value['kind']}:${value['shared']}');
      }
    }
    warnings.add(
      'Есть несколько локальных копий одного медиа. Их позиции не объединяются автоматически; требуется выбрать соответствие.',
    );
  }

  Future<void> prepareNames() async {
    final shelf = await repository.meta('recommendations-shelf-v1');
    if (shelf != null) {
      final data = jsonDecode(shelf) as Map;
      for (final raw in data['categories'] as List) {
        final category = raw as Map;
        await _bind(
          'category',
          category['id'] as String,
          sharedMediaId(
            'category:${(category['name'] as String).trim().toLowerCase()}',
          ),
          {},
        );
      }
      for (final raw in data['books'] as List) {
        final book = raw as Map, catalog = book['catalog'] as Map;
        final id = book['id'] as String;
        final common = catalog['source'] == 'manual'
            ? id
            : sharedMediaId(
                'recommendation:${catalog['source']}:${catalog['sourceId']}',
              );
        await _bind('recommendation', id, common, {});
      }
    }
    final rows = await repository.db
        .customSelect(
          "SELECT key,value FROM metadata WHERE key LIKE 'reading-collection:%' OR key LIKE 'audio-collection:%'",
        )
        .get();
    for (final row in rows) {
      final key = row.read<String>('key'),
          data = jsonDecode(row.read<String>('value')) as Map;
      final split = key.indexOf(':'),
          kind = key.substring(0, split),
          id = key.substring(split + 1);
      await _bind(
        kind,
        id,
        sharedMediaId('$kind:${(data['name'] as String).trim().toLowerCase()}'),
        {},
      );
    }
  }

  // The store is only used for its database-backed list, never for filesystem access.
  static final pDirectoryPlaceholder = Directory('unused-app-sync-assets');

  Map<String, dynamic> translate(
    Map<String, dynamic> value, {
    required bool encode,
  }) {
    final ids = encode ? outgoing : incoming;
    Object? visit(Object? raw, [String? field]) {
      if (raw is List) return raw.map((e) => visit(e, field)).toList();
      if (raw is! Map) {
        if (raw is String && _idFields.contains(field)) return ids[raw] ?? raw;
        return raw;
      }
      final map = Map<String, dynamic>.from(raw);
      final result = {
        for (final entry in map.entries)
          entry.key: visit(entry.value, entry.key),
      };
      final lesson =
          (map['lessonId'] ?? (map['kind'] == 'video' ? map['mediaId'] : null))
              as String?;
      final version = map['mediaVersion'];
      if (lesson != null && version is String) {
        final localLesson = encode ? lesson : incoming[lesson];
        final versions =
            (aliases['lesson:$localLesson']?['data'] as Map?)?['versions']
                as Map? ??
            {};
        result['mediaVersion'] = encode
            ? versions[version] ?? version
            : versions.entries
                      .where((e) => e.value == version)
                      .firstOrNull
                      ?.key ??
                  version;
      } else if (version is String && map['kind'] == 'audio') {
        result['mediaVersion'] = encode
            ? resources[version] ?? version
            : resources.entries
                      .where((e) => e.value == version)
                      .firstOrNull
                      ?.key ??
                  version;
      }
      return result;
    }

    return Map<String, dynamic>.from(visit(value) as Map);
  }

  Future<String?> _resolve(Map<String, dynamic> source) async {
    final hash = source['hash'];
    if (hash is! String || !appSyncHash.hasMatch(hash)) {
      throw const FormatException('Неверная версия источника');
    }
    final folder = folders()
        .where((f) => f.id == source['folder'] && !f.paused)
        .firstOrNull;
    if (folder == null || source['path'] is! String) return null;
    final path = peerPath(source['path'] as String);
    final entry = await store.peer.entry(folder.id, path);
    if (entry?.hash != hash) return null;
    final files = peerFileSystem(folder.root);
    if (!verifyNewFiles || await files.hash(path) != hash) return null;
    return files.source(path);
  }

  Future<bool> apply(String key, Map<String, dynamic> data) async {
    final parts = key.split(':'), kind = parts[1], common = parts[2];
    if (ambiguous.contains(common)) return false;
    if (!appSyncUuid.hasMatch(common)) {
      throw const FormatException('Неверный ID медиа');
    }
    if (kind == 'item') {
      final id = incoming[common] ?? common;
      final old = await repository.record(id);
      await _record('video_item', id, {
        ...?old?.payload,
        'version': 1,
        'title': data['title'],
        'kind': data['kind'],
        'favorite': data['favorite'],
        'root': old?.payload?['root'],
        'connected': true,
      });
      await _bind('item', id, common, {'descriptor': data});
      return true;
    }
    if (kind == 'lesson') {
      final item = incoming[data['itemId']];
      if (item == null) return false;
      final id = incoming[common] ?? common,
          old = await repository.record(incoming[common] ?? common);
      final source = Map<String, dynamic>.from(data['source'] as Map);
      if (source['hash'] != data['mediaVersion']) {
        throw const FormatException('Источник относится к другой версии урока');
      }
      final path = await _resolve(source);
      final versions = Map<String, dynamic>.from(
        (aliases['lesson:$id']?['data'] as Map?)?['versions'] as Map? ?? {},
      );
      final version =
          versions.entries
              .where((e) => e.value == data['mediaVersion'])
              .firstOrNull
              ?.key ??
          uuid.v4();
      // Existing content versions are never rebound to different bytes.
      if (old != null &&
          old.payload?['mediaVersion'] != version &&
          path == null) {
        return false;
      }
      versions[version] = data['mediaVersion'];
      if (path != null) currentHashes[id] = source['hash'] as String;
      await _record('video_lesson', id, {
        ...?old?.payload,
        'version': 1,
        'itemId': item,
        'title': data['title'],
        'module': data['module'],
        'ordinal': data['ordinal'],
        'mediaVersion': version,
        'durationMs': old?.payload?['durationMs'],
        'audio':
            data['audio'] == true ||
            isMusicSource(
              source['path'] as String? ??
                  path ??
                  source['name'] as String? ??
                  '',
            ),
        if (data['music'] is Map)
          'music': {
            ...Map<String, dynamic>.from(data['music'] as Map),
            if (old?.payload?['mediaVersion'] == version &&
                old?.payload?['music'] is Map &&
                old!.payload!['music']['coverPath'] != null)
              'coverPath': old.payload!['music']['coverPath'],
          },
        if (old?.payload?['mediaVersion'] != version) 'fileIdentity': null,
        'source':
            path ?? old?.payload?['source'] ?? 'pepehub-unavailable:$common',
        'available': path != null,
      });
      await _bind('lesson', id, common, {
        'versions': versions,
        'descriptor': data,
      });
      return true;
    }
    if (kind != 'book') throw const FormatException('Неизвестный вид медиа');
    final id = incoming[common] ?? common;
    final sources = (data['sources'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    if (sources.isEmpty || sources.length > 1000) {
      throw const FormatException('Неверный состав книги');
    }
    if (data['kind'] == 'audio') {
      final existing = await repository.db
          .customSelect(
            'SELECT id,manifest_revision FROM audio_editions WHERE book_id=? ORDER BY id',
            variables: [Variable(id)],
          )
          .get();
      final edition =
          existing.firstOrNull?.read<String>('id') ??
          sharedMediaId('edition:$common');
      if (currentAudioManifests[edition] != null &&
          currentAudioManifests[edition] != data['manifest']) {
        return false;
      }
      final planned =
          <
            ({
              String id,
              String shared,
              QueryRow? old,
              String? path,
              Map<String, dynamic> source,
            })
          >[];
      for (var i = 0; i < sources.length; i++) {
        final source = sources[i],
            shared = source['id'] as String,
            track = incoming[source['id']] ?? source['id'] as String;
        final old = await repository.db
            .customSelect(
              'SELECT * FROM audio_tracks WHERE id=?',
              variables: [Variable(track)],
            )
            .getSingleOrNull();
        final path = old == null ? await _resolve(source) : null;
        if (old != null &&
                (old.read<int>('ordinal') != i ||
                    old.read<String>('edition_id') != edition) ||
            old == null && path == null) {
          return false;
        }
        planned.add((
          id: track,
          shared: shared,
          old: old,
          path: path,
          source: source,
        ));
      }
      await repository.db.customStatement(
        'INSERT OR IGNORE INTO audio_editions VALUES(?,?,1)',
        [edition, id],
      );
      await _bind('edition', edition, sharedMediaId('edition:$common'), {
        'book': common,
        'manifest': data['manifest'],
        'revision': existing.firstOrNull?.read<int>('manifest_revision') ?? 1,
      });
      currentAudioManifests[edition] = data['manifest'] as String;
      for (var i = 0; i < sources.length; i++) {
        final source = planned[i].source,
            sharedTrack = planned[i].shared,
            trackId = planned[i].id;
        final old = planned[i].old, path = planned[i].path;
        if (old != null) {
          // Reordering an active edition needs a separate manifest transaction.
          if (old.read<int>('ordinal') != i) return false;
        } else if (path != null) {
          await repository.db.customStatement(
            'INSERT OR IGNORE INTO audio_resources VALUES(?,?,?)',
            [source['hash'], path, source['bytes']],
          );
          await repository.db.customStatement(
            'INSERT INTO audio_tracks VALUES(?,?,?,?,?,?)',
            [
              trackId,
              edition,
              source['hash'],
              i,
              source['name'],
              source['durationMs'],
            ],
          );
        } else {
          return false;
        }
        final resource =
            old?.read<String>('asset_hash') ?? source['hash'] as String;
        resources[resource] = source['hash'] as String;
        await _bind('track', trackId, sharedTrack, {
          'book': common,
          'resource': resource,
          'hash': source['hash'],
        });
      }
    } else if (await repository.db
            .customSelect(
              'SELECT 1 FROM local_assets WHERE book_id=?',
              variables: [Variable(id)],
            )
            .getSingleOrNull() ==
        null) {
      final source = sources.single, path = await _resolve(sources.single);
      if (path != null) {
        await repository.db.customStatement(
          'INSERT OR IGNORE INTO local_assets VALUES(?,?,?,?,?,?)',
          [
            sharedMediaId('asset:$common'),
            id,
            source['name'],
            path,
            source['hash'],
            source['bytes'],
          ],
        );
      }
    }
    await _bind('book', id, common, {'descriptor': data});
    return true;
  }

  Future<void> _record(
    String type,
    String id,
    Map<String, dynamic> value,
  ) async {
    final old = await repository.record(id);
    if (old != null && old.type != type) {
      throw StateError('ID занят другим видом записи');
    }
    if (old?.deleted == true) return;
    if (old != null && appSyncJson(old.payload) == appSyncJson(value)) return;
    await repository.db.customStatement(
      'INSERT INTO records VALUES(?,?,1,0,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,revision=records.revision+1',
      [id, type, jsonEncode(value)],
    );
  }
}
