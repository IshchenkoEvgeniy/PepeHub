import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/audio/audio_folder.dart';
import 'package:pepehub/audio/audio_catalog.dart';
import 'package:pepehub/audio/audio_roots.dart';
import 'package:pepehub/audio/audio_library_repository.dart';
import 'package:pepehub/audio/models.dart';
import 'package:pepehub/audio/book_folder_operations.dart';
import 'package:pepehub/audio/audio_journal.dart';

void main() {
  test('rename and move folder preserve tracks, position, bookmark, history and root bindings', () async {
    final temp = await Directory.systemTemp.createTemp('pepehub-folder-ops-');
    final db = AppDatabase(NativeDatabase.memory());
    final repo = Repository(db);
    final assets = AssetStore(repo, Directory('${temp.path}/cache'));
    try {
      final source = await Directory('${temp.path}/source/Book')
          .create(recursive: true);
      await File('${source.path}/01.mp3').writeAsBytes(List.filled(64, 1));
      await File('${source.path}/cover.jpg').writeAsBytes([1, 2, 3]);
      final destination = await Directory('${temp.path}/destination').create();
      final folder = await scanAudioFolder(source.parent.path);
      await connectAudioCatalog(assets, folder, groupAudioCatalog(folder));
      await repo.setMeta(
        audioRootKey(destination.path),
        jsonEncode({
          'root': destination.path,
          'title': 'Destination',
          'mode': 'folders',
          'bookIds': [],
        }),
      );
      final roots = AudioRoots(assets);
      final root = (await roots.list()).firstWhere(
        (r) => r.path == folder.root,
      );
      final id = root.bookIds.single;
      final track = (await assets.audioTracks(id)).single;
      final library = AudioLibraryRepository(db);
      final initial = await library.progressForTrack(track.id);
      await library.saveDuration(track.id, const Duration(minutes: 10));
      await library.saveProgress(
        AudioProgress(
          AudioLocator(
            bookId: id,
            editionId: initial.locator.editionId,
            trackId: track.id,
            positionMs: 42000,
            manifestRevision: initial.locator.manifestRevision,
          ),
          1.5,
        ),
      );
      final journal = AudioJournal(repo);
      await journal.bookmark(id, track.id, 40000, 'Bookmark');
      final manager = BookFolderOperations(assets);
      await manager.relocate(id, await manager.locate(id), root, 'Renamed');
      expect(await source.exists(), false);
      expect(
        await File('${source.parent.path}/Renamed/cover.jpg').readAsBytes(),
        [1, 2, 3],
      );
      expect((await assets.audioTracks(id)).single.id, track.id);
      final target = (await roots.list()).firstWhere(
        (r) => r.path == destination.path,
      );
      await manager.relocate(id, await manager.locate(id), target, 'Renamed');
      expect(await File('${destination.path}/Renamed/01.mp3').length(), 64);
      expect(
        (await library.progressForTrack(track.id)).locator.positionMs,
        42000,
      );
      expect((await library.progressForTrack(track.id)).speed, 1.5);
      expect(
        (await journal.list('audio_bookmark')).single.payload!['trackId'],
        track.id,
      );
      expect(
        (await library.durations(
          initial.locator.editionId,
        ))[track.id]?.inMinutes,
        10,
      );
      expect(
        (await roots.list()).firstWhere((r) => r.path == root.path).bookIds,
        isEmpty,
      );
      expect(
        (await roots.list()).firstWhere((r) => r.path == target.path).bookIds,
        [id],
      );
      expect(await manager.hasPending(id), false);
      expect(Directory('${destination.path}/.pepehub/logs').existsSync(), true);
      await roots.refresh(
        (await roots.list()).firstWhere((r) => r.path == target.path),
      );
      expect((await repo.records('book')).length, 1);
      // An occupied target is never overwritten; recovery clears a non-executed intent.
      await Directory('${destination.path}/Occupied').create();
      await expectLater(
        manager.relocate(
          id,
          await manager.locate(id),
          (await roots.list()).firstWhere((r) => r.bookIds.contains(id)),
          'Occupied',
        ),
        throwsStateError,
      );
      expect(await manager.hasPending(id), true);
      expect(await manager.recover(id), contains('прежнем месте'));
      expect(await manager.hasPending(id), false);
      // Simulate interruption after the filesystem operation, before committing paths.
      final before = await manager.locate(id);
      await repo.setMeta(
        'book-folder-operation:$id',
        jsonEncode({
          'sourceRoot': before.root.path,
          'source': before.relative,
          'targetRoot': before.root.path,
          'target': 'Recovered',
        }),
      );
      await Directory('${before.root.path}/Renamed')
          .rename('${before.root.path}/Recovered');
      expect(await manager.recover(id), contains('сохранены'));
      expect((await assets.audioTracks(id)).single.path, contains('Recovered'));
      expect(
        (await library.progressForTrack(track.id)).locator.positionMs,
        42000,
      );
      expect(await manager.hasPending(id), false);
    } finally {
      await db.close();
      await temp.delete(recursive: true);
    }
  });
  test('folder name validation rejects traversal and support folders', () {
    for (final name in [
      '..',
      'a/../b',
      'a\\b',
      '.pepehub',
      'A/CON',
      'A/',
      'A:B',
    ]) {
      expect(() => validateRelativeFolder(name), throwsArgumentError);
    }
    expect(() => validateRelativeFolder('Автор/Книга 2'), returnsNormally);
  });
}
