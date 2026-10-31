import 'audio_journal.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../media/asset_store.dart';
import '../data/database_schema.dart';
import '../data/repository.dart';
import 'audio_folder.dart';
import 'audio_roots.dart';
import 'audio_library_repository.dart';
import 'models.dart';
import '../media/audio_artwork.dart';

/// User-requested, versioned local snapshot; never a second copy of audio.
Future<void> saveAudioSidecar(AssetStore assets, AudioFolder root) async {
  final repository = assets.repository;
  if ((await repository.meta('recovery-error:${audioRootKey(root.root!)}') ??
          '')
      .isNotEmpty) {
    throw StateError(
      'Сначала завершите восстановление истории: обновите папку.',
    );
  }
  final catalog = jsonDecode(
    (await repository.meta(
      'audio-library-root:${sha256.convert(utf8.encode(root.root!))}',
    ))!,
  );
  final ids = (catalog['bookIds'] as List).cast<String>().toSet();
  final books = <Map<String, dynamic>>[];
  for (final id in ids) {
    final record = await repository.record(id);
    final tracks = await assets.audioTracks(id);
    final progress = await repository.db
        .customSelect(
          'SELECT p.* FROM audio_progress p JOIN audio_editions e ON e.id=p.edition_id WHERE e.book_id=?',
          variables: [Variable(id)],
        )
        .get();
    final cover = await repository.meta('audio-cover:$id');
    final coverFile = cover == null ? null : File(cover);
    books.add({
      if (coverFile != null &&
          await coverFile.exists() &&
          await coverFile.length() <= 2 * 1024 * 1024)
        'cover': base64Encode(await coverFile.readAsBytes()),
      'bookmarks': [
        for (final b in await AudioJournal(
          repository,
        ).list('audio_bookmark', bookId: id, limit: 100000))
          {'id': b.id, 'data': b.payload},
      ],
      'notes': [
        for (final n in await AudioJournal(
          repository,
        ).list('audio_note', bookId: id, limit: 100000))
          {'id': n.id, 'data': n.payload},
      ],
      'id': id,
      'card': record?.payload,
      'tracks': [
        for (final t in tracks)
          {'id': t.id, 'name': t.filename, 'bytes': t.bytes},
      ],
      'progress': progress.map((r) => r.data).toList(),
    });
  }
  final sessions = (await repository.records('session'))
      .where((s) => ids.contains(s.payload?['bookId']));
  final json = jsonEncode({
    'format': 'pepehub-library-snapshot',
    'version': 1,
    'createdAt': DateTime.now().toUtc().toIso8601String(),
    'library': root.title,
    'books': books,
    'sessions': [
      for (final s in sessions) {'id': s.id, 'data': s.payload},
    ],
  });
  if (utf8.encode(json).length > 16 * 1024 * 1024) {
    throw StateError('Снимок превышает 16 МиБ; данные остаются в приложении');
  }
  if (root.root!.startsWith('content://')) {
    await audioFolderChannel.invokeMethod<void>('snapshot', {
      'root': root.root,
      'json': json,
    });
  } else {
    final directory = Directory(p.join(root.root!, '.pepehub'));
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw StateError('.pepehub не является обычной папкой');
    }
    await directory.create();
    final file = File(
      p.join(
        directory.path,
        'library-${DateTime.now().millisecondsSinceEpoch}-${uuid.v4()}.json',
      ),
    );
    final pending = File('${file.path}.partial');
    await pending.create(exclusive: true);
    try {
      await pending.writeAsString(json, flush: true);
      await pending.rename(file.path);
    } catch (_) {
      if (await pending.exists()) await pending.delete();
      rethrow;
    }
    final previous = <File>[];
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is File &&
          RegExp(r'^library-[0-9]+-[a-f0-9-]+\.json$')
              .hasMatch(p.basename(entry.path))) {
        previous.add(entry);
      }
    }
    previous.sort((a, b) => b.path.compareTo(a.path));
    for (final old in previous.skip(10)) {
      await old.delete();
    }
  }
  await exportAudioJournal(
    assets,
    AudioRoot(
      audioRootKey(root.root!),
      Map<String, dynamic>.from(catalog as Map),
    ),
  );
}

/// Serialized and throttled; a failed sidecar never rolls back the local database.
class AudioSidecarWriter {
  final AssetStore assets;
  final Map<String, DateTime> _last = {};
  AudioSidecarWriter(this.assets);
  final Map<String, _SidecarRequest> _pending = {};
  bool _running = false;
  Future<void> update(String bookId, {bool force = false}) {
    final existing = _pending[bookId];
    if (existing != null) {
      existing.force = existing.force || force;
      return existing.done.future;
    }
    final request = _SidecarRequest(force);
    _pending[bookId] = request;
    if (!_running) {
      _running = true;
      unawaited(Future<void>(_drain));
    }
    return request.done.future;
  }

  Future<void> _drain() async {
    try {
      while (_pending.isNotEmpty) {
        final id = _pending.keys.first;
        final request = _pending.remove(id)!;
        try {
          await _update(id, force: request.force);
          request.done.complete();
        } catch (error, stack) {
          request.done.completeError(error, stack);
        }
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _update(String bookId, {bool force = false}) async {
    for (final root in await AudioRoots(assets).list()) {
      if (!root.bookIds.contains(bookId)) continue;
      if (!force &&
          _last[root.key] != null &&
          DateTime.now().difference(_last[root.key]!).inSeconds < 60) {
        continue;
      }
      await saveAudioSidecar(
        assets,
        AudioFolder(root.title, [], root: root.path),
      );
      if (force) await exportLibraryTable(assets, root, force: true);
      _last[root.key] = DateTime.now();
    }
  }
}

class _SidecarRequest {
  bool force;
  final done = Completer<void>();
  _SidecarRequest(this.force);
}

Map<String, dynamic> parseAudioSnapshot(String text) {
  if (utf8.encode(text).length > 16 * 1024 * 1024) {
    throw StateError('Снимок больше 16 МиБ');
  }
  final data = jsonDecode(text);
  if (data is! Map<String, dynamic> ||
      data['format'] != 'pepehub-library-snapshot' ||
      !(data['version'] == 1 ||
          data['version'] == 2 && data['kind'] == 'audio-journal') ||
      data['books'] is! List ||
      data['sessions'] is! List) {
    throw StateError('Неподдерживаемый снимок');
  }
  if (data['version'] == 2 &&
      (data['events'] is! List ||
          (data['events'] as List).any(
            (event) =>
                event is! Map ||
                event['id'] is! String ||
                (event['id'] as String).isEmpty ||
                event['revision'] is! int ||
                (event['revision'] as int) < 1 ||
                event['deleted'] is! bool ||
                event['data'] is! Map,
          ))) {
    throw StateError('Некорректная версия события журнала');
  }
  return data;
}

Future<int> restoreAudioSnapshot(
  AssetStore assets,
  AudioRoot root,
  Map<String, dynamic> snapshot, {
  bool backup = true,
  bool merge = false,
  Set<String>? preserveProgressBookIds,
  Set<String>? preserveEventIds,
}) async {
  // Revalidate even when called without the UI preview.
  parseAudioSnapshot(jsonEncode(snapshot));
  final library = AudioLibraryRepository(assets.repository.db);
  final matches = <String, String>{};
  final trackMaps = <String, Map<String, String>>{};
  for (final raw in snapshot['books'] as List) {
    final book = raw as Map;
    final oldTracks = (book['tracks'] as List).cast<Map>();
    if (oldTracks.isEmpty) continue;
    final candidates = <String>[];
    for (final id in root.bookIds) {
      final tracks = await assets.audioTracks(id);
      if (tracks.length == oldTracks.length &&
          oldTracks.every(
            (old) =>
                tracks
                    .where(
                      (t) =>
                          t.filename == old['name'] && t.bytes == old['bytes'],
                    )
                    .length ==
                1,
          )) {
        candidates.add(id);
      }
    }
    final oldId = book['id'] as String;
    final id = candidates.contains(oldId)
        ? oldId
        : candidates.length == 1
        ? candidates.single
        : null;
    if (id == null || matches.containsValue(id)) {
      if (merge) continue;
      throw StateError(
        'Книга не найдена однозначно: ${book['card']?['title'] ?? oldId}. Сначала подключите исходные папки.',
      );
    }
    matches[oldId] = id;
    final tracks = await assets.audioTracks(id);
    trackMaps[oldId] = {
      for (final old in oldTracks)
        old['id'] as String: tracks
            .singleWhere(
              (t) => t.filename == old['name'] && t.bytes == old['bytes'],
            )
            .id,
    };
  }
  if (matches.isEmpty) {
    if (merge) return 0;
    throw StateError('В снимке нет подходящих книг');
  }
  // Backup failure aborts restore, preserving the only current copy.
  if (backup) {
    await saveAudioSidecar(
      assets,
      AudioFolder(root.title, [], root: root.path),
    );
  }
  await assets.repository.db.transaction(() async {
    for (final raw in snapshot['books'] as List) {
      final book = raw as Map;
      final id = matches[book['id']];
      if (id == null) continue;
      for (final progress in book['progress'] as List) {
        final trackId = trackMaps[book['id']]![progress['track_id']];
        if (trackId == null) throw StateError('Трек позиции отсутствует');
        final track = (await library.track(trackId))!;
        final edition = await library.edition(track.editionId);
        if (merge) {
          final current = await assets.repository.db
              .customSelect(
                'SELECT position_ms FROM audio_progress WHERE edition_id=?',
                variables: [Variable(edition.id)],
              )
              .get();
          if (current.isNotEmpty &&
              ((preserveProgressBookIds?.contains(id) ?? true) ||
                  current.any((r) => r.read<int>('position_ms') > 0))) {
            continue;
          }
        }
        await library.saveProgress(
          AudioProgress(
            AudioLocator(
              bookId: id,
              editionId: edition.id,
              trackId: trackId,
              manifestRevision: edition.manifestRevision,
              positionMs: progress['position_ms'] as int,
            ),
            (progress['speed'] as num).toDouble(),
          ),
        );
      }
      if (!merge && book.containsKey('bookmarks')) {
        await assets.repository.db.customStatement(
          "UPDATE records SET deleted=1 WHERE type='audio_bookmark' AND json_extract(payload,'\$.bookId')=?",
          [id],
        );
      }
      for (final rawBookmark in (book['bookmarks'] as List? ?? [])) {
        final data = Map<String, dynamic>.from(rawBookmark['data'] as Map);
        data['bookId'] = id;
        data['trackId'] =
            trackMaps[book['id']]![data['trackId']] ??
            (throw StateError('Трек закладки отсутствует'));
        if (data['positionMs'] is! int ||
            data['positionMs'] < 0 ||
            data['title'] is! String) {
          throw StateError('Некорректная закладка');
        }
        final existing = await assets.repository.record(
          rawBookmark['id'] as String,
        );
        if (merge && existing != null) continue;
        if (existing != null && existing.type != 'audio_bookmark') {
          throw StateError('Конфликт закладки');
        }
        await AudioJournal(assets.repository)
            .put('audio_bookmark', rawBookmark['id'] as String, data);
      }
      if (!merge && book.containsKey('notes')) {
        await assets.repository.db.customStatement(
          "UPDATE records SET deleted=1 WHERE type='audio_note' AND json_extract(payload,'\$.bookId')=?",
          [id],
        );
      }
      for (final rawNote in (book['notes'] as List? ?? [])) {
        final data = Map<String, dynamic>.from(rawNote['data'] as Map);
        data['bookId'] = id;
        data['trackId'] =
            trackMaps[book['id']]![data['trackId']] ??
            (throw StateError('Трек заметки отсутствует'));
        AudioJournal.validateNote(data);
        final existing = await assets.repository.record(
          rawNote['id'] as String,
        );
        if (merge && existing != null) continue;
        if (existing != null &&
            (existing.type != 'audio_note' ||
                existing.payload?['bookId'] != id)) {
          throw StateError('Конфликт заметки');
        }
        await AudioJournal(assets.repository)
            .put('audio_note', rawNote['id'] as String, data);
      }
      final cover = book['cover'];
      if (!merge && cover is String) {
        await ArtworkStore(assets).save(id, base64Decode(cover));
      }
    }
    for (final rawEvent in (snapshot['events'] as List? ?? [])) {
      final event = rawEvent as Map;
      final data = Map<String, dynamic>.from(event['data'] as Map);
      final oldBook = data['bookId'];
      final id = matches[oldBook];
      if (merge && id == null) continue;
      if (id == null) throw StateError('Книга события не найдена');
      data['bookId'] = id;
      for (final field in ['trackId', 'fromTrackId']) {
        if (data[field] != null) {
          data[field] =
              trackMaps[oldBook]![data[field]] ??
              (throw StateError('Трек события не найден'));
        }
      }
      if (data['positionMs'] is! int ||
          data['positionMs'] < 0 ||
          data['at'] is! String ||
          DateTime.tryParse(data['at']) == null) {
        throw StateError('Некорректное событие');
      }
      if (data['localDay'] is! String ||
          DateTime.tryParse(data['localDay']) == null ||
          data['offsetMinutes'] is! num ||
          (data['offsetMinutes'] as num).abs() > 1440) {
        throw StateError('Некорректная дата события');
      }
      if (data['kind'] == 'listen' &&
          (data['wallMs'] is! int ||
              data['wallMs'] <= 0 ||
              data['endMs'] is! int ||
              data['endMs'] < data['positionMs'] ||
              data['speed'] is! num)) {
        throw StateError('Некорректный интервал');
      }
      final existing = await assets.repository.record(event['id'] as String);
      if (existing != null &&
          (existing.type != 'audio_event' ||
              existing.payload?['bookId'] != id)) {
        throw StateError('Конфликт события');
      }
      // Automatic reconnect never replaces events that existed before recovery,
      // including edits that reduced time and local deletion tombstones.
      if (merge &&
          existing != null &&
          (preserveEventIds?.contains(existing.id) ?? true)) {
        continue;
      }
      final versionKey = 'audio-event-portable-version:${event['id']}';
      if (snapshot['version'] == 2) {
        final revision = event['revision'] as int;
        final knownVersion = await assets.repository.meta(versionKey);
        if (existing != null &&
            existing.revision >= revision &&
            (!merge || knownVersion != null)) {
          await assets.repository.setMeta(versionKey, '${existing.revision}');
          continue;
        }
        await assets.repository.setMeta(versionKey, '$revision');
        // Keep the portable revision so an older backup cannot win simply
        // because it contains a longer listening interval.
        await assets.repository.db.customStatement(
          "INSERT INTO records(id,type,revision,deleted,payload) VALUES(?,'audio_event',?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,deleted=excluded.deleted,payload=excluded.payload",
          [
            event['id'],
            revision,
            event['deleted'] == true ? 1 : 0,
            jsonEncode(data),
          ],
        );
        continue;
      }
      if (existing != null &&
          (existing.deleted ||
              await assets.repository.meta(versionKey) != null)) {
        continue;
      }
      // A daily journal backup may contain an earlier checkpoint of the same
      // growing interval. Restoring it must not shorten already recorded time.
      if (data['kind'] == 'listen' &&
          existing?.payload?['kind'] == 'listen' &&
          (existing!.payload!['wallMs'] as num) >= (data['wallMs'] as num)) {
        continue;
      }
      await AudioJournal(assets.repository)
          .put('audio_event', event['id'] as String, data);
    }
    for (final raw in snapshot['sessions'] as List) {
      final session = raw as Map;
      final data = Map<String, dynamic>.from(session['data'] as Map);
      final id = matches[data['bookId']];
      if (merge && id == null) continue;
      if (id == null) throw StateError('Сессия относится к неизвестной книге');
      data['bookId'] = id;
      final existing = await assets.repository.record(session['id'] as String);
      if (merge && existing != null) continue;
      if (existing != null &&
          (existing.type != 'session' || existing.payload?['bookId'] != id)) {
        throw StateError('Конфликт идентификатора сессии');
      }
      await assets.repository.put(
        'session',
        session['id'] as String,
        data,
        coalesce: true,
      );
    }
  });
  return matches.length;
}

/// One replaceable daily journal; record IDs still make restore idempotent.
Future<void> exportAudioJournal(AssetStore assets, AudioRoot root) async {
  final repo = assets.repository;
  if ((await repo.meta('recovery-error:${root.key}') ?? '').isNotEmpty) {
    throw StateError('Журнал защищён до завершения восстановления истории.');
  }
  final ids = root.bookIds;
  if (ids.isEmpty) return;
  final placeholders = List.filled(ids.length, '?').join(',');
  final days = await repo.db
      .customSelect(
        "SELECT ${SchemaSql.audioEventDay} AS day,COUNT(*) AS n,SUM(revision) AS rev FROM records "
        "WHERE ${SchemaSql.audioEventRows} AND ${SchemaSql.audioEventBook} IN ($placeholders) GROUP BY day",
        variables: [for (final id in ids) Variable(id)],
      )
      .get();
  for (final row in days) {
    final day = row.read<String>('day');
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(day)) {
      throw StateError('Некорректная дата');
    }
    final key = 'audio-journal-daily:${root.key}:$day';
    final fingerprint =
        'v2:${row.read<int>('n')}:${row.read<int>('rev')}:${ids.join(',')}';
    if (await repo.meta(key) == fingerprint) continue;
    final events =
        (await repo.db
                .customSelect(
                  "SELECT * FROM records WHERE ${SchemaSql.audioEventRows} "
                  "AND ${SchemaSql.audioEventDay}=? AND ${SchemaSql.audioEventBook} IN ($placeholders) "
                  "ORDER BY json_extract(payload,'\$.at'),id",
                  variables: [
                    Variable(day),
                    for (final id in ids) Variable(id),
                  ],
                )
                .get())
            .map(LibraryRecord.fromRow)
            .toList();
    final books = <Map<String, dynamic>>[];
    for (final id
        in events.map((e) => e.payload!['bookId'] as String).toSet()) {
      books.add({
        'id': id,
        'card': (await repo.record(id))?.payload,
        'tracks': [
          for (final t in await assets.audioTracks(id))
            {'id': t.id, 'name': t.filename, 'bytes': t.bytes},
        ],
        'progress': [],
      });
    }
    final packet = jsonEncode({
      'format': 'pepehub-library-snapshot',
      'version': 2,
      'kind': 'audio-journal',
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'library': root.title,
      'books': books,
      'sessions': [],
      'events': [
        for (final e in events)
          {
            'id': e.id,
            'revision': e.revision,
            'deleted': e.deleted,
            'data': e.payload,
          },
      ],
    });
    await writeAudioSupport(root, 'events-$day.json', packet, day: day);
    if (!root.path.startsWith('content:')) {
      final covered = {for (final e in events) e.id: e.payload!};
      final directory = Directory(p.join(root.path, '.pepehub', 'logs', day));
      await for (final entry in directory.list(followLinks: false)) {
        if (entry is! File ||
            !RegExp(r'^events-[a-f0-9]{64}\.json$')
                .hasMatch(p.basename(entry.path))) {
          continue;
        }
        try {
          if (await entry.length() > 16 * 1024 * 1024) continue;
          final old = parseAudioSnapshot(await entry.readAsString());
          final oldEvents = old['events'] as List? ?? [];
          if (old['kind'] == 'audio-journal' &&
              oldEvents.isNotEmpty &&
              oldEvents.every(
                (e) =>
                    covered.containsKey(e['id']) &&
                    jsonEncode(covered[e['id']]) == jsonEncode(e['data']),
              )) {
            await entry.delete();
          }
        } catch (_) {
          /* Unknown or unreadable files are retained. */
        }
      }
    }
    await repo.setMeta(key, fingerprint);
  }
  // Report refreshes at the first snapshot of the day and after an hour of use.
  // Explicit pause/stop updates are requested by AudioSidecarWriter below.
  await exportLibraryTable(assets, root);
}

Future<void> writeAudioSupport(
  AudioRoot root,
  String name,
  String text, {
  String? day,
}) async {
  if (utf8.encode(text).length > 16 * 1024 * 1024) {
    throw StateError('Журнал превышает 16 МиБ');
  }
  if (root.path.startsWith('content:')) {
    await audioFolderChannel.invokeMethod<void>(
      day == null ? 'report' : 'journal',
      {
        'root': root.path,
        'name': name,
        'json': text,
        'day': day,
        'replace': true,
      },
    );
    return;
  }
  var directory = Directory(root.path);
  for (final part in [
    '.pepehub',
    if (day != null) ...['logs', day],
  ]) {
    directory = Directory(p.join(directory.path, part));
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw StateError('Каталог данных недоступен');
    }
    await directory.create();
  }
  final target = File(p.join(directory.path, name));
  final backup = File('${target.path}.bak');
  final temp = File('${target.path}.${uuid.v4()}.partial');
  try {
    await temp.writeAsString(text, flush: true);
    if (await target.exists()) {
      if (await backup.exists()) await backup.delete();
      await target.rename(backup.path);
    }
    await temp.rename(target.path);
  } catch (_) {
    if (await temp.exists()) await temp.delete();
    rethrow;
  }
}

Future<void> exportLibraryTable(
  AssetStore assets,
  AudioRoot root, {
  bool force = false,
}) async {
  final repo = assets.repository;
  final key = 'audio-library-table:${root.key}';
  final now = DateTime.now();
  final previous = DateTime.tryParse(await repo.meta(key) ?? '');
  if (!force &&
      previous != null &&
      dayKey(previous.toLocal()) == dayKey(now) &&
      now.difference(previous).inMinutes < 60) {
    return;
  }
  final rows = <List<Object?>>[
    [
      'ID',
      'Книга',
      'Статус',
      'Глав',
      'Глав прослушано ≥99%',
      'Длительность, с',
      'Позиция, с',
      'Прогресс, %',
      'Активное время, с',
      'Уникально прослушано, с',
      'Повторно, с',
      'Первое прослушивание UTC',
      'Последнее прослушивание UTC',
      'Завершение отмечено UTC',
      'Скорость',
      'Обновлено UTC',
    ],
  ];
  for (final id in root.bookIds) {
    final card = await repo.record(id);
    final tracks = await assets.audioTracks(id);
    if (tracks.isEmpty) continue;
    final events =
        (await AudioJournal(repo).list(
            'audio_event',
            bookId: id,
            limit: -1,
          )).map((record) => record.payload!).toList()
          ..sort((a, b) => (a['at'] as String).compareTo(b['at'] as String));
    final stats = AudioStats(events);
    final progress = await AudioLibraryRepository(repo.db)
        .progressForTrack(tracks.first.id);
    int? total = 0, position = 0;
    var reached = false, finishedChapters = 0;
    for (final track in tracks) {
      final info = await AudioLibraryRepository(repo.db).track(track.id);
      final duration = info?.durationMs;
      if (duration == null) {
        total = null;
      } else if (total != null) {
        total += duration;
      }
      if (track.id == progress.locator.trackId) {
        if (position != null) position += progress.locator.positionMs;
        reached = true;
      } else if (!reached) {
        if (duration == null) {
          position = null;
        } else if (position != null) {
          position += duration;
        }
      }
      if (duration != null &&
          duration > 0 &&
          AudioStats(events.where((e) => e['trackId'] == track.id)).uniqueMs >=
              duration * .99) {
        finishedChapters++;
      }
    }
    final listened = events.where((e) => e['kind'] == 'listen').toList();
    final completed = events.where((e) => e['kind'] == 'completed').toList();
    final status =
        await repo.meta('audio-status-override:$id') ??
        card?.payload?['status'] ??
        'planned';
    rows.add([
      id,
      card?.title ?? '',
      status,
      tracks.length,
      finishedChapters,
      total == null ? '' : total / 1000,
      position == null ? '' : position / 1000,
      total == null || total == 0 || position == null
          ? ''
          : (100 * position / total).toStringAsFixed(2),
      stats.wallMs / 1000,
      stats.uniqueMs / 1000,
      stats.repeatedMs / 1000,
      listened.isEmpty ? '' : listened.first['at'],
      listened.isEmpty
          ? ''
          : DateTime.parse(listened.last['at'] as String)
                .add(Duration(milliseconds: listened.last['wallMs'] as int))
                .toIso8601String(),
      completed.isEmpty ? '' : completed.last['at'],
      progress.speed,
      now.toUtc().toIso8601String(),
    ]);
  }
  String cell(Object? value) {
    var text = '${value ?? ''}';
    if (RegExp(r'^\s*[=+@-]').hasMatch(text)) text = "'$text";
    return '"${text.replaceAll('"', '""')}"';
  }

  await writeAudioSupport(
    root,
    'library.csv',
    '\uFEFF${rows.map((row) => row.map(cell).join(';')).join('\r\n')}\r\n',
  );
  await repo.setMeta(key, now.toUtc().toIso8601String());
}
