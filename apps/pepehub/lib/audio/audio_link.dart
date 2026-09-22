import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;

import '../data/repository.dart';
import 'audio_folder.dart';

/// Device-local source references. No audio bytes are opened, hashed or copied.
/// `external:` resource keys are opaque IDs, never content hashes.
class AudioLinkService {
  final Repository repository;
  AudioLinkService(this.repository);

  Future<String> connect(
    List<XFile> files, {
    required String root,
    required String title,
    String? replaceBookId,
  }) async {
    if (files.isEmpty || files.length > 1000 || root.isEmpty) {
      throw ArgumentError('Выберите папку с 1–1000 аудиофайлов');
    }
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty || cleanTitle.length > 500) {
      throw ArgumentError('Укажите название книги');
    }
    final names = [
      for (final file in files)
        file is FolderAudioFile ? file.name : p.basename(file.path),
    ];
    if (names.toSet().length != files.length) {
      throw ArgumentError('Повторяющиеся пути треков');
    }
    final sizes = [for (final file in files) await file.length()];
    final key = 'audio-folder:${sha256.convert(utf8.encode(root))}';
    return repository.db.transaction(() async {
      final linked = await repository.meta(key);
      final existingId = replaceBookId ?? linked;
      if (existingId != null) {
        final book = await repository.record(existingId);
        if (book == null || book.deleted) {
          throw StateError(
            'Книга удалена. Подключение не восстановит её автоматически.',
          );
        }
        if (replaceBookId != null && linked != null && linked != existingId) {
          throw StateError('Эта папка уже подключена к другой книге');
        }
        final tracks = await repository.db
            .customSelect(
              'SELECT t.id,t.title,r.bytes FROM audio_tracks t JOIN audio_editions e ON e.id=t.edition_id JOIN audio_resources r ON r.sha256=t.asset_hash WHERE e.book_id=? ORDER BY t.ordinal',
              variables: [Variable(existingId)],
            )
            .get();
        final byName = {for (var i = 0; i < files.length; i++) names[i]: i};
        if (tracks.length != files.length ||
            tracks.any((t) {
              final i = byName[t.read<String>('title')];
              return i == null ||
                  (sizes[i] >= 0 &&
                      t.read<int>('bytes') > 0 &&
                      sizes[i] != t.read<int>('bytes'));
            })) {
          throw StateError(
            'Состав или размеры файлов отличаются. Выберите прежнюю книгу; позиция сохранена.',
          );
        }
        for (final track in tracks) {
          final i = byName[track.read<String>('title')]!;
          final resource = 'external:${track.read<String>('id')}';
          await repository.db.customStatement(
            'INSERT INTO audio_resources VALUES(?,?,?) ON CONFLICT(sha256) DO UPDATE SET path=excluded.path,bytes=excluded.bytes',
            [resource, files[i].path, sizes[i] < 0 ? 0 : sizes[i]],
          );
          await repository.db.customStatement(
            'UPDATE audio_tracks SET asset_hash=? WHERE id=?',
            [resource, track.read<String>('id')],
          );
        }
        final oldKey = await repository.meta('audio-folder-book:$existingId');
        if (oldKey != null && oldKey != key) {
          await repository.db.customStatement(
            'DELETE FROM metadata WHERE key=? AND value=?',
            [oldKey, existingId],
          );
        }
        await repository.setMeta(key, existingId);
        await repository.setMeta('audio-folder-book:$existingId', key);
        return existingId;
      }
      final bookId = uuid.v4(), editionId = uuid.v4();
      await repository.put('book', bookId, {
        'title': cleanTitle,
        'authors': <String>[],
        'format': 'audio',
        'status': 'planned',
      });
      await repository.db.customStatement(
        'INSERT INTO audio_editions VALUES(?,?,1)',
        [editionId, bookId],
      );
      for (var i = 0; i < files.length; i++) {
        final trackId = uuid.v4();
        final resource = 'external:$trackId';
        await repository.db.customStatement(
          'INSERT INTO audio_resources VALUES(?,?,?)',
          [resource, files[i].path, sizes[i] < 0 ? 0 : sizes[i]],
        );
        await repository.db.customStatement(
          'INSERT INTO audio_tracks VALUES(?,?,?,?,?,NULL)',
          [trackId, editionId, resource, i, names[i]],
        );
      }
      await repository.setMeta(key, bookId);
      await repository.setMeta('audio-folder-book:$bookId', key);
      return bookId;
    });
  }
}
