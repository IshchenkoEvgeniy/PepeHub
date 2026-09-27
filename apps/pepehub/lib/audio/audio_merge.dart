import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:crypto/crypto.dart';

import '../data/repository.dart';
import '../media/asset_store.dart';
import 'audio_library_repository.dart';
import 'audio_journal.dart';
import 'audio_roots.dart';
import 'models.dart';

/// Creates one ordered edition while keeping the original cards recoverable.
/// No source audio file is moved or copied.
class AudioMerge {
  final AssetStore assets;
  AudioMerge(this.assets);
  Repository get repository => assets.repository;

  /// Replaces previously split cards after the user reconnects the same folder
  /// as a single numbered-part book.
  Future<void> absorb(String targetId, List<String> oldIds) async {
    if (oldIds.isEmpty) return;
    final target = await assets.audioTracks(targetId);
    final byPath = {for (final track in target) track.path: track};
    final trackIds = <String, String>{};
    final order = {for (var i = 0; i < target.length; i++) target[i].id: i};
    for (final id in oldIds) {
      final original = await assets.audioTracks(id);
      if (original.isEmpty ||
          original.any((track) => !byPath.containsKey(track.path))) {
        throw StateError('Не все треки прежней книги найдены в объединённой');
      }
      for (final track in original) {
        trackIds[track.id] = byPath[track.path]!.id;
      }
    }
    AudioProgress? furthest;
    final library = AudioLibraryRepository(repository.db);
    for (final id in oldIds) {
      final row = await repository.db
          .customSelect(
            'SELECT p.track_id,p.position_ms,p.speed FROM audio_progress p JOIN audio_editions e ON e.id=p.edition_id WHERE e.book_id=? ORDER BY p.updated_at DESC LIMIT 1',
            variables: [Variable(id)],
          )
          .getSingleOrNull();
      if (row == null) continue;
      final mapped = trackIds[row.read<String>('track_id')];
      if (mapped == null) continue;
      final parent = await library.edition(
        (await library.track(mapped))!.editionId,
      );
      final candidate = AudioProgress(
        AudioLocator(
          bookId: targetId,
          editionId: parent.id,
          trackId: mapped,
          positionMs: row.read<int>('position_ms'),
          manifestRevision: parent.manifestRevision,
        ),
        row.read<double>('speed'),
      );
      if (furthest == null ||
          order[mapped]! > order[furthest.locator.trackId]! ||
          order[mapped] == order[furthest.locator.trackId] &&
              candidate.locator.positionMs > furthest.locator.positionMs) {
        furthest = candidate;
      }
    }
    await _moveRecords(oldIds.toSet(), targetId, trackIds);
    if (furthest != null) await library.saveProgress(furthest);
    for (final id in oldIds) {
      await repository.setMeta('audio-library-hidden:$id', '1');
    }
  }

  Future<String> merge(List<String> bookIds, String title) async {
    if (bookIds.length < 2 || bookIds.toSet().length != bookIds.length) {
      throw ArgumentError('Выберите хотя бы две разные аудиокниги');
    }
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty || cleanTitle.length > 500) {
      throw ArgumentError('Укажите название объединённой книги');
    }
    final books = <LibraryRecord>[];
    final tracks = <String, List<LocalAsset>>{};
    for (final id in bookIds) {
      final book = await repository.record(id);
      if (book == null || book.deleted || book.payload?['format'] != 'audio') {
        throw StateError('Одна из выбранных книг недоступна');
      }
      books.add(book);
      tracks[id] = await assets.audioTracks(id);
      if (tracks[id]!.isEmpty) throw StateError('У книги нет аудиотреков');
    }
    final roots = await AudioRoots(assets).list();
    final relatedRoots = roots
        .where((root) => bookIds.any(root.bookIds.contains))
        .toList();
    if (relatedRoots.length > 1 ||
        relatedRoots.isNotEmpty &&
            !bookIds.every(relatedRoots.single.bookIds.contains)) {
      throw StateError('Объединяйте книги из одной подключённой папки');
    }
    final root = relatedRoots.firstOrNull;
    final paths = <String, String>{};
    for (final id in bookIds) {
      final raw = await repository.meta('audio-source-path:$id');
      if (raw != null) {
        paths[id] = (jsonDecode(raw) as Map)['relativePath'] as String? ?? '';
      }
    }
    if (root != null) {
      final numbered = RegExp(r'^\d{1,3}$');
      if (paths.length != bookIds.length ||
          paths.values.any(
            (path) => !numbered.hasMatch(path.split('/').last),
          )) {
        throw StateError(
          'В подключённой папке можно объединить соседние папки частей 01, 02 и так далее',
        );
      }
      final parentNames = paths.values
          .map((path) => path.split('/')..removeLast())
          .map((parts) => parts.join('/'))
          .toSet();
      if (parentNames.length != 1) {
        throw StateError('Выберите части из одной родительской папки');
      }
      for (final otherId in root.bookIds) {
        if (bookIds.contains(otherId)) continue;
        final raw = await repository.meta('audio-source-path:$otherId');
        if (raw == null) continue;
        final path = (jsonDecode(raw) as Map)['relativePath'] as String? ?? '';
        final parts = path.split('/');
        final name = parts.removeLast();
        if (numbered.hasMatch(name) && parts.join('/') == parentNames.single) {
          throw StateError('Выберите все пронумерованные части этой книги');
        }
      }
    }
    final parent = root != null && paths.length == bookIds.length
        ? _commonParent(paths.values.toList())
        : '';
    final newId = uuid.v4(), editionId = uuid.v4();
    final oldToNew = <String, String>{};
    final newOrder = <String, int>{};
    await repository.db.transaction(() async {
      await repository.put('book', newId, {
        ...books.first.payload!,
        'title': cleanTitle,
      });
      await repository.db.customStatement(
        'INSERT INTO audio_editions VALUES(?,?,1)',
        [editionId, newId],
      );
      var ordinal = 0;
      for (final id in bookIds) {
        final sourcePath = paths[id];
        final prefix = sourcePath == null
            ? books.first.id == id
                  ? books.first.title
                  : (await repository.record(id))!.title
            : parent.isEmpty
            ? sourcePath
            : sourcePath.startsWith('$parent/')
            ? sourcePath.substring(parent.length + 1)
            : sourcePath;
        for (final asset in tracks[id]!) {
          final oldTrack = await AudioLibraryRepository(repository.db)
              .track(asset.id);
          final trackId = uuid.v4();
          oldToNew[asset.id] = trackId;
          newOrder[trackId] = ordinal;
          final label = prefix == '.' || prefix.isEmpty
              ? asset.filename
              : '$prefix/${asset.filename}';
          await repository.db.customStatement(
            'INSERT INTO audio_tracks VALUES(?,?,?,?,?,?)',
            [
              trackId,
              editionId,
              oldTrack!.assetHash,
              ordinal++,
              label,
              oldTrack.durationMs,
            ],
          );
        }
      }
      AudioProgress? furthest;
      for (final id in bookIds) {
        final row = await repository.db
            .customSelect(
              'SELECT p.track_id,p.position_ms,p.speed FROM audio_progress p JOIN audio_editions e ON e.id=p.edition_id WHERE e.book_id=? ORDER BY p.updated_at DESC LIMIT 1',
              variables: [Variable(id)],
            )
            .getSingleOrNull();
        if (row == null) continue;
        final mapped = oldToNew[row.read<String>('track_id')];
        if (mapped == null) continue;
        final candidate = AudioProgress(
          AudioLocator(
            bookId: newId,
            editionId: editionId,
            trackId: mapped,
            positionMs: row.read<int>('position_ms'),
            manifestRevision: 1,
          ),
          row.read<double>('speed'),
        );
        if (furthest == null ||
            newOrder[mapped]! > newOrder[furthest.locator.trackId]! ||
            newOrder[mapped] == newOrder[furthest.locator.trackId] &&
                candidate.locator.positionMs > furthest.locator.positionMs) {
          furthest = candidate;
        }
      }
      if (furthest != null) {
        await AudioLibraryRepository(repository.db).saveProgress(furthest);
      }
      await _moveRecords(bookIds.toSet(), newId, oldToNew);
      for (final id in bookIds) {
        await repository.setMeta('audio-library-hidden:$id', '1');
      }
      if (root != null) {
        final source = parent.isEmpty
            ? root.path
            : '${root.path}#pepehub-book=${Uri.encodeComponent(parent)}';
        final key = 'audio-folder:${sha256.convert(utf8.encode(source))}';
        await repository.setMeta(key, newId);
        await repository.setMeta('audio-folder-book:$newId', key);
        await repository.setMeta(
          'audio-source-path:$newId',
          jsonEncode({'relativePath': parent}),
        );
        await repository.setMeta(
          root.key,
          jsonEncode({
            ...root.data,
            'mode': 'parts',
            'bookIds': [
              for (final id in root.bookIds)
                if (!bookIds.contains(id)) id,
              newId,
            ],
          }),
        );
      }
    });
    return newId;
  }

  Future<void> _moveRecords(
    Set<String> oldIds,
    String newId,
    Map<String, String> trackIds,
  ) async {
    for (final type in [
      'audio_event',
      'audio_note',
      'audio_bookmark',
      'session',
    ]) {
      for (final record in await repository.records(type)) {
        final data = record.payload;
        if (data == null || !oldIds.contains(data['bookId'])) continue;
        final oldTrack = data['trackId'];
        final fromTrack = data['fromTrackId'];
        final updated = <String, dynamic>{
          ...data,
          'bookId': newId,
          if (oldTrack is String && trackIds.containsKey(oldTrack))
            'trackId': trackIds[oldTrack],
          if (fromTrack is String && trackIds.containsKey(fromTrack))
            'fromTrackId': trackIds[fromTrack],
        };
        if (type == 'session') {
          await repository.put(type, record.id, updated);
        } else {
          await AudioJournal(repository).put(type, record.id, updated);
        }
      }
    }
  }

  String _commonParent(List<String> paths) {
    final parts = paths.map((path) => path.split('/')).toList();
    final common = <String>[];
    for (var i = 0; i < parts.first.length; i++) {
      final value = parts.first[i];
      if (parts.every((path) => i < path.length && path[i] == value)) {
        common.add(value);
      } else {
        break;
      }
    }
    return common.join('/');
  }
}
