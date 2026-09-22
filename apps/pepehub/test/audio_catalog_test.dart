import 'dart:io';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/audio/audio_catalog.dart';
import 'package:pepehub/audio/audio_folder.dart';
import 'package:pepehub/audio/audio_sidecar.dart';
import 'package:pepehub/audio/audio_library_repository.dart';
import 'package:pepehub/audio/models.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';

void main() {
  test(
    'mixed root files and subfolders can replace an old aggregate',
    () async {
      final root = await Directory.systemTemp.createTemp('mixed-catalog-');
      final db = AppDatabase(NativeDatabase.memory());
      final repo = Repository(db);
      final assets = AssetStore(repo, Directory('${root.path}/managed'));
      try {
        await File('${root.path}/root.mp3').writeAsBytes(List.filled(16, 1));
        await Directory('${root.path}/Book').create();
        await File('${root.path}/Book/01.mp3').writeAsBytes(List.filled(16, 2));
        final folder = await scanAudioFolder(root.path);
        final old = await assets.connectAudioFolder(
          folder.files,
          root: folder.root!,
          title: 'Aggregate',
        );
        expect(
          await connectAudioCatalog(assets, folder, groupAudioCatalog(folder)),
          2,
        );
        expect(await repo.meta('audio-library-superseded:${old.bookId}'), '1');
        expect(await assets.directory.exists(), isFalse);
      } finally {
        await db.close();
        await root.delete(recursive: true);
      }
    },
  );
  test('separates books, joins discs, ignores service folders, supports loose books', () {
    final folder = AudioFolder('Library', [
      for (final name in [
        'Author/Book A/Disc 2/2.mp3',
        'Author/Book A/Disc 1/1.mp3',
        'Author/Book B/01.mp3',
        'Novel/01.mp3',
        '!Smart AudioBook Player Statistics/1.mp3',
        '.pepehub/test.mp3',
      ])
        FolderAudioFile('/$name', name),
    ], root: '/Library');
    final books = groupAudioCatalog(folder);
    expect(books.map((b) => b.title), ['Book A', 'Book B', 'Novel']);
    expect(books.first.files.map((f) => f.name), [
      'Disc 1/1.mp3',
      'Disc 2/2.mp3',
    ]);
    expect(groupAudioCatalog(folder, mode: 'single'), hasLength(1));
    expect(groupAudioCatalog(folder, mode: 'files'), hasLength(4));
  });

  test('catalog is atomic, deduplicated, and replaces aggregate preserving position', () async {
    final root = await Directory.systemTemp.createTemp('catalog-test-');
    final db = AppDatabase(NativeDatabase.memory());
    final repo = Repository(db);
    final assets = AssetStore(repo, Directory('${root.path}/managed'));
    try {
      for (final name in [
        'Book A/01.mp3',
        'Book B/01.mp3',
        '.pepehub/ignored.mp3',
      ]) {
        final file = File('${root.path}/$name');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(List.filled(16, 1));
      }
      final folder = await scanAudioFolder(root.path);
      expect(folder.files, hasLength(2));
      final old = await assets.connectAudioFolder(
        folder.files,
        root: folder.root!,
        title: 'Wrong aggregate',
      );
      final library = AudioLibraryRepository(db);
      final oldTracks = await assets.audioTracks(old.bookId);
      final initial = await library.progressForTrack(old.id);
      await library.saveProgress(
        AudioProgress(
          AudioLocator(
            bookId: old.bookId,
            editionId: initial.locator.editionId,
            trackId: oldTracks.last.id,
            positionMs: 60000,
            manifestRevision: 1,
          ),
          1.5,
        ),
      );
      final drafts = groupAudioCatalog(folder);
      expect(await connectAudioCatalog(assets, folder, drafts), 2);
      expect(await repo.meta('audio-library-superseded:${old.bookId}'), '1');
      final books = (await repo.records('book'))
          .where((b) => b.id != old.bookId)
          .toList();
      final bookB = books.firstWhere((b) => b.title == 'Book B');
      final tracks = await assets.audioTracks(bookB.id);
      final progress = await library.progressForTrack(tracks.first.id);
      expect(progress.locator.positionMs, 60000);
      expect(progress.speed, 1.5);
      await connectAudioCatalog(assets, folder, groupAudioCatalog(folder));
      expect(
        await repo.records('book'),
        hasLength(3),
      ); // aggregate kept for history
      expect(await assets.directory.exists(), isFalse);
      await repo.addSession(bookB, 5);
      await saveAudioSidecar(assets, folder);
      await saveAudioSidecar(assets, folder);
      final snapshots = await Directory('${root.path}/.pepehub')
          .list()
          .where((f) => f.path.endsWith('.json'))
          .toList();
      expect(snapshots, hasLength(2));
      final data = jsonDecode(await File(snapshots.first.path).readAsString());
      expect(data['format'], 'pepehub-library-snapshot');
      expect(data['books'], hasLength(2));
      expect(data['sessions'], hasLength(1));
      expect(await scanAudioFolder(root.path).then((f) => f.files.length), 2);
      final invalid = groupAudioCatalog(folder);
      invalid.last.title = '';
      await expectLater(
        connectAudioCatalog(assets, folder, invalid),
        throwsArgumentError,
      );
      expect(await repo.records('book'), hasLength(3));
    } finally {
      await db.close();
      await root.delete(recursive: true);
    }
  });
}
