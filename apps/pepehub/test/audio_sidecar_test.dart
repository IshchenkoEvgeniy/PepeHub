import 'package:pepehub/audio/audio_journal.dart';

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/audio/audio_catalog.dart';
import 'package:pepehub/audio/audio_folder.dart';
import 'package:pepehub/audio/audio_roots.dart';
import 'package:pepehub/audio/audio_sidecar.dart';
import 'package:pepehub/audio/audio_library_repository.dart';
import 'package:pepehub/audio/models.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';

void main() {
  test('snapshots rotate, restore position/statistics, reject changed tracks atomically', () async {
    final dir = await Directory.systemTemp.createTemp('pepehub-snapshots-');
    final db = AppDatabase(NativeDatabase.memory());
    final repo = Repository(db);
    final assets = AssetStore(repo, Directory('${dir.path}/cache'));
    try {
      await Directory('${dir.path}/Book').create();
      await File('${dir.path}/Book/01.mp3').writeAsBytes(List.filled(16, 1));
      final folder = await scanAudioFolder(dir.path);
      await connectAudioCatalog(assets, folder, groupAudioCatalog(folder));
      final root = (await AudioRoots(assets).list()).single;
      final track = (await assets.audioTracks(root.bookIds.single)).single;
      final library = AudioLibraryRepository(db);
      final initial = await library.progressForTrack(track.id);
      Future<void> position(int ms) => library.saveProgress(
        AudioProgress(
          AudioLocator(
            bookId: track.bookId,
            editionId: initial.locator.editionId,
            trackId: track.id,
            manifestRevision: initial.locator.manifestRevision,
            positionMs: ms,
          ),
          1.5,
        ),
      );
      await position(25000);
      final notesJournal = AudioJournal(repo);
      final noteId = await notesJournal.saveNote(
        bookId: track.bookId,
        trackId: track.id,
        positionMs: 12000,
        kind: 'quote',
        title: 'Цитата',
        text: 'Текст цитаты',
      );
      await repo.put('session', 'session-test', {
        'bookId': track.bookId,
        'activeSeconds': 20,
        'kind': 'listening',
      });
      await saveAudioSidecar(assets, folder);
      final support = Directory('${dir.path}/.pepehub');
      final snapshot = parseAudioSnapshot(
        await support
            .listSync()
            .whereType<File>()
            .singleWhere((f) => f.path.endsWith('.json'))
            .readAsString(),
      );
      await position(90000);
      await notesJournal.saveNote(
        id: noteId,
        bookId: track.bookId,
        trackId: track.id,
        positionMs: 90000,
        kind: 'character',
        title: 'Имя',
        text: 'Изменено',
      );
      expect((await repo.record(noteId))!.payload!['positionMs'], 12000);
      await notesJournal.deleteNote(noteId);
      expect((await notesJournal.list('audio_note')).isEmpty, isTrue);
      await notesJournal.deleteNote(noteId, restore: true);
      expect((await notesJournal.list('audio_note')).single.id, noteId);
      expect(await restoreAudioSnapshot(assets, root, snapshot), 1);
      expect((await repo.record(noteId))!.payload!['text'], 'Текст цитаты');
      expect((await repo.record(noteId))!.payload!['positionMs'], 12000);
      expect(
        (await library.progressForTrack(track.id)).locator.positionMs,
        25000,
      );
      expect((await repo.records('session')).length, 1);
      // Simulate a reconnected library whose snapshot IDs came from an older DB.
      final remapped = jsonDecode(jsonEncode(snapshot)) as Map<String, dynamic>;
      remapped['books'][0]['id'] = 'previous-book';
      remapped['books'][0]['tracks'][0]['id'] = 'previous-track';
      remapped['books'][0]['progress'][0]['track_id'] = 'previous-track';
      remapped['sessions'][0]['data']['bookId'] = 'previous-book';
      remapped['books'][0]['notes'][0]['data']['bookId'] = 'previous-book';
      remapped['books'][0]['notes'][0]['data']['trackId'] = 'previous-track';
      expect(await restoreAudioSnapshot(assets, root, remapped), 1);
      expect((await repo.records('session')).length, 1);
      expect((await repo.record(noteId))!.payload!['trackId'], track.id);
      final withoutNotes =
          jsonDecode(jsonEncode(snapshot)) as Map<String, dynamic>;
      withoutNotes['books'][0].remove('notes');
      await restoreAudioSnapshot(assets, root, withoutNotes);
      expect((await notesJournal.list('audio_note')).length, 1);
      final invalid = jsonDecode(jsonEncode(snapshot)) as Map<String, dynamic>;
      invalid['books'][0]['tracks'][0]['bytes'] = 999;
      await expectLater(
        restoreAudioSnapshot(assets, root, invalid),
        throwsStateError,
      );
      expect(
        (await library.progressForTrack(track.id)).locator.positionMs,
        25000,
      );
      final invalidProgress =
          jsonDecode(jsonEncode(snapshot)) as Map<String, dynamic>;
      invalidProgress['books'][0]['progress'][0]['position_ms'] = -1;
      await expectLater(
        restoreAudioSnapshot(assets, root, invalidProgress),
        throwsArgumentError,
      );
      expect(
        (await library.progressForTrack(track.id)).locator.positionMs,
        25000,
      );
      final unrelated = File('${support.path}/notes.json');
      await unrelated.writeAsString('keep');
      for (var i = 0; i < 12; i++) {
        await saveAudioSidecar(assets, folder);
      }
      expect(
        support.listSync().where((f) => f.path.endsWith('.json')).length,
        11,
      );
      expect(await unrelated.readAsString(), 'keep');
      final writer = AudioSidecarWriter(assets);
      final snapshots = [
        for (var i = 0; i < 30; i++)
          writer.update(track.bookId, force: i == 29),
      ];
      expect(
        snapshots.every((snapshot) => identical(snapshot, snapshots.first)),
        true,
        reason: 'Pending saves of one book share a single forced snapshot',
      );
      await Future.wait(snapshots);
      final before = support.listSync().map((f) => f.path).toSet();
      await writer.update(track.bookId);
      expect(support.listSync().map((f) => f.path).toSet(), before);
      expect(() => parseAudioSnapshot('{"version":99}'), throwsStateError);
      final journal = AudioJournal(repo);
      await journal.bookmark(track.bookId, track.id, 10000, 'Важный момент');
      await journal.event(
        'seek',
        track.bookId,
        track.id,
        5000,
        extra: {'fromTrackId': track.id, 'fromMs': 2000, 'reason': 'test'},
      );
      await writer.update(track.bookId, force: true);
      final logs = Directory('${support.path}/logs')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList();
      expect(logs.length, 1);
      final packet = parseAudioSnapshot(await logs.single.readAsString());
      expect(packet['kind'], 'audio-journal');
      expect((packet['events'] as List).length, 2);
      await restoreAudioSnapshot(assets, root, packet);
      expect((await journal.list('audio_event')).length, 2);
      await exportAudioJournal(assets, root);
      expect(
        Directory('${support.path}/logs')
            .listSync(recursive: true)
            .whereType<File>()
            .length,
        1,
        reason:
            'Replaying the same event revisions must not rotate the journal',
      );
      final backups =
          support
              .listSync()
              .whereType<File>()
              .where(
                (f) => f.path
                    .split(Platform.pathSeparator)
                    .last
                    .startsWith('library-'),
              )
              .toList()
            ..sort((a, b) => b.path.compareTo(a.path));
      final latest = parseAudioSnapshot(await backups.first.readAsString());
      expect((latest['books'][0]['bookmarks'] as List).length, 1);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });
}
