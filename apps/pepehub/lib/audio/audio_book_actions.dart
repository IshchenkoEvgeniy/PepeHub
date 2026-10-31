import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Variable;

import '../reader/reading_book_actions.dart';

/// File operations are scoped to one selected book, never its parent folder.
/// Track IDs, durations, locators, artwork and journal records stay intact.
class AudioBookActions extends ReadingBookActions {
  AudioBookActions(super.assets);

  @override
  Future<void> hideMany(Iterable<String> ids, {bool hidden = true}) async {
    await assets.repository.db.transaction(() async {
      for (final id in ids.toSet()) {
        await assets.repository.setMeta(
          'audio-user-hidden:$id',
          hidden ? '1' : '0',
        );
        await assets.repository.setMeta(
          'audio-library-hidden:$id',
          hidden ? '1' : '0',
        );
      }
    });
    assets.repository.notifyExternalChange();
  }

  @override
  Future<void> deleteForever(String id) async {
    final tracks = await assets.audioTracks(id);
    final selected = <String, ReadingBookSource>{};
    for (final track in tracks) {
      // A shared physical file must not disappear from another book/edition.
      final shared = await assets.repository.db
          .customSelect(
            'SELECT 1 FROM audio_tracks t JOIN audio_editions e ON e.id=t.edition_id '
            'JOIN audio_resources r ON r.sha256=t.asset_hash '
            'WHERE r.path=? AND e.book_id<>? LIMIT 1',
            variables: [Variable(track.path), Variable(id)],
          )
          .getSingleOrNull();
      if (shared != null) {
        throw StateError(
          'Файл используется другой аудиокнигой. Уберите книгу из списка.',
        );
      }
      if (selected.containsKey(track.path)) continue;
      var hash = track.hash;
      // Folder links have opaque external: IDs. Hash only on explicit deletion,
      // streaming one file at a time; never read audio bytes for a shelf screen.
      if (hash.startsWith('external:')) {
        if (track.path.startsWith('content:')) {
          if (track.bytes <= 0) {
            throw StateError(
              'Не удалось проверить размер аудиофайла. Обновите папку аудиокниг или уберите книгу из списка.',
            );
          }
          // Android checks the registered size and exact document URI instead.
          hash = 'external:${track.bytes}';
        } else {
          final file = File(track.path);
          final type = await FileSystemEntity.type(
            track.path,
            followLinks: false,
          );
          if (type == FileSystemEntityType.notFound) continue;
          if (type != FileSystemEntityType.file ||
              (track.bytes > 0 && await file.length() != track.bytes)) {
            throw StateError('Файл изменился. Обновите папку аудиокниг.');
          }
          hash = (await sha256.bind(file.openRead()).first).toString();
        }
      }
      selected[track.path] = ReadingBookSource(
        track.path,
        hash,
        track.filename,
      );
    }
    await deleteFiles(selected.values.toList());
    await hide(id);
  }
}
