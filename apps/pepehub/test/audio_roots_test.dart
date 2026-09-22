import 'dart:io';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/audio/audio_roots.dart';
import 'package:pepehub/audio/audio_catalog.dart';
import 'package:pepehub/audio/audio_folder.dart';
import 'package:pepehub/audio/audio_library_repository.dart';
import 'package:pepehub/audio/models.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';

void main() {
  test('legacy separate-file grouping survives refresh', () async {
    final temp = await Directory.systemTemp.createTemp('legacy-roots-');
    final db = AppDatabase(NativeDatabase.memory());
    final repo = Repository(db);
    final assets = AssetStore(repo, Directory('${temp.path}/managed'));
    final roots = AudioRoots(assets);
    try {
      for (final name in ['One.m4b', 'Two.m4b']) {
        await File('${temp.path}/$name').writeAsBytes(List.filled(16, 1));
      }
      final folder = await scanAudioFolder(temp.path);
      await connectAudioCatalog(
        assets,
        folder,
        groupAudioCatalog(folder, mode: 'files'),
        mode: 'files',
      );
      final root = (await roots.list()).single;
      final legacy = {...root.data}..remove('mode');
      await repo.setMeta(root.key, jsonEncode(legacy));
      final result = await roots.refresh((await roots.list()).single);
      expect(result.added, 0);
      expect(result.updated, 2);
      expect(result.warnings, isEmpty);
      expect((await roots.list()).single.mode, 'files');
      expect(await repo.records('book'), hasLength(2));
    } finally {
      await db.close();
      await temp.delete(recursive: true);
    }
  });
  test(
    'rename, rescan, relocate and remove preserve original files and progress',
    () async {
      final temp = await Directory.systemTemp.createTemp('roots-test-');
      final source = await Directory('${temp.path}/source').create();
      final db = AppDatabase(NativeDatabase.memory());
      final repo = Repository(db);
      final assets = AssetStore(repo, Directory('${temp.path}/managed'));
      final roots = AudioRoots(assets);
      try {
        Future<File> book(String parent, String name) async {
          final file = File('$parent/$name/01.mp3');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(List.filled(16, 1));
          return file;
        }

        await book(source.path, 'Book A');
        final scan = await scanAudioFolder(source.path);
        await connectAudioCatalog(assets, scan, groupAudioCatalog(scan));
        var root = (await roots.list()).single;
        final id = root.bookIds.single;
        final track = (await assets.audioTracks(id)).single;
        final library = AudioLibraryRepository(db);
        final initial = await library.progressForTrack(track.id);
        await library.saveProgress(
          AudioProgress(
            AudioLocator(
              bookId: id,
              editionId: initial.locator.editionId,
              trackId: track.id,
              positionMs: 25000,
              manifestRevision: 1,
            ),
            1.5,
          ),
        );
        await roots.rename(root, 'My library');
        root = (await roots.list()).single;
        expect(root.title, 'My library');
        expect(await source.exists(), isTrue);
        await book(source.path, 'Book B');
        final refresh = await roots.refresh(root);
        expect(refresh.added, 1);
        expect(refresh.updated, 1);
        expect(refresh.warnings, isEmpty);
        root = (await roots.list()).single;
        expect(root.bookIds, hasLength(2));
        final original = File('${source.path}/Book A/01.mp3');
        await original.writeAsBytes(List.filled(32, 1));
        final changed = await roots.refresh(root);
        expect(changed.warnings, hasLength(1));
        expect((await assets.audioTracks(id)).single.bytes, 16);
        expect(
          (await library.progressForTrack(track.id)).locator.positionMs,
          25000,
        );
        await original.writeAsBytes(List.filled(16, 1));
        final moved = await source.rename('${temp.path}/moved');
        final replacement = await scanAudioFolder(moved.path);
        await roots.refresh(root, replacement: replacement);
        root = (await roots.list()).single;
        expect(root.path, replacement.root);
        expect(root.title, 'My library');
        expect((await assets.audioTracks(id)).single.id, track.id);
        expect(
          (await library.progressForTrack(track.id)).locator.positionMs,
          25000,
        );
        final bad = await Directory('${temp.path}/wrong').create();
        await expectLater(
          roots.refresh(root, replacement: await scanAudioFolder(bad.path)),
          throwsStateError,
        );
        expect((await roots.list()).single.path, replacement.root);
        await roots.remove(root);
        expect(await roots.list(), isEmpty);
        expect(await repo.meta('audio-library-hidden:$id'), '1');
        expect(await File('${moved.path}/Book A/01.mp3').exists(), isTrue);
        await connectAudioCatalog(
          assets,
          replacement,
          groupAudioCatalog(replacement),
        );
        expect(await repo.meta('audio-library-hidden:$id'), '0');
        expect(await repo.records('book'), hasLength(2));
        expect(
          (await library.progressForTrack(track.id)).locator.positionMs,
          25000,
        );
        expect(await assets.directory.exists(), isFalse);
      } finally {
        await db.close();
        await temp.delete(recursive: true);
      }
    },
  );
}
