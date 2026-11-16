import 'dart:io';
import 'dart:convert';

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
import 'package:pepehub/reader/reading_roots.dart';
import 'package:pepehub/reader/reading_library.dart';
import 'package:pepehub/reader/reading_log.dart';

void main() {
  _crossDeviceTests();
  test(
    'reinstall restores audio and reconnect keeps newer local position',
    () async {
      final dir = await Directory.systemTemp.createTemp('recovery-audio-');
      final first = AppDatabase(NativeDatabase.memory());
      final second = AppDatabase(NativeDatabase.memory());
      try {
        await Directory('${dir.path}/Book').create();
        await File('${dir.path}/Book/01.mp3').writeAsBytes(List.filled(16, 1));
        final folder = await scanAudioFolder(dir.path);
        final old = AssetStore(
          Repository(first),
          Directory('${dir.path}/cache'),
        );
        await connectAudioCatalog(old, folder, groupAudioCatalog(folder));
        final book = (await AudioRoots(old).list()).single.bookIds.single;
        final track = (await old.audioTracks(book)).single;
        final library = AudioLibraryRepository(first);
        final progress = await library.progressForTrack(track.id);
        await library.saveProgress(
          AudioProgress(
            AudioLocator(
              bookId: book,
              editionId: progress.locator.editionId,
              trackId: track.id,
              manifestRevision: progress.locator.manifestRevision,
              positionMs: 123000,
            ),
            1.5,
          ),
        );
        await old.repository.put('session', 'portable-session', {
          'bookId': book,
          'activeSeconds': 120,
          'kind': 'listening',
        });
        await saveAudioSidecar(old, folder);
        final snapshotFile = Directory('${dir.path}/.pepehub')
            .listSync()
            .whereType<File>()
            .singleWhere((f) => f.path.endsWith('.json'));
        final empty = jsonDecode(
          await snapshotFile.readAsString(),
        ) as Map<String, dynamic>;
        empty['sessions'] = [];
        for (final book in empty['books'] as List) {
          for (final progress in book['progress'] as List) {
            progress['position_ms'] = 0;
          }
        }
        await File('${dir.path}/.pepehub/library-9999999999999-empty.json')
            .writeAsString(jsonEncode(empty));
        final fresh = AssetStore(
          Repository(second),
          Directory('${dir.path}/fresh'),
        );
        await connectAudioCatalog(fresh, folder, groupAudioCatalog(folder));
        final restored = (await fresh.audioTracks(
          (await AudioRoots(fresh).list()).single.bookIds.single,
        )).single;
        final newLibrary = AudioLibraryRepository(second);
        final state = await newLibrary.progressForTrack(restored.id);
        expect(state.locator.positionMs, 123000);
        expect(
          (await fresh.repository.records('session')).single.payload!['bookId'],
          restored.bookId,
        );
        await newLibrary.saveProgress(
          AudioProgress(
            AudioLocator(
              bookId: restored.bookId,
              editionId: state.locator.editionId,
              trackId: restored.id,
              manifestRevision: state.locator.manifestRevision,
              positionMs: 456000,
            ),
            1,
          ),
        );
        await connectAudioCatalog(fresh, folder, groupAudioCatalog(folder));
        expect(
          (await newLibrary.progressForTrack(restored.id)).locator.positionMs,
          456000,
        );
        expect(await fresh.repository.records('session'), hasLength(1));
      } finally {
        await first.close();
        await second.close();
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'reading reconnect restores sessions by content hash and portable position',
    () async {
      final dir = await Directory.systemTemp.createTemp('recovery-reading-');
      final first = AppDatabase(NativeDatabase.memory());
      final second = AppDatabase(NativeDatabase.memory());
      try {
        await File('${dir.path}/Book.txt')
            .writeAsString('A book with enough text.');
        final folder = await scanAudioFolder(dir.path, books: true);
        final old = AssetStore(
          Repository(first),
          Directory('${dir.path}/cache'),
        );
        final root = await ReadingRoots(old).connect(folder);
        final asset = (await old.list()).single;
        final library = ReadingLibrary(old.repository);
        await library.update('reader:${asset.hash}', {
          'chapter': 0,
          'textOffset': 12,
        });
        final session = <String, dynamic>{
          'id': 's1',
          'bookId': root.bookIds.single,
          'hash': asset.hash,
          'startedAt': '2026-09-20T10:00:00Z',
          'endedAt': '2026-09-20T10:10:00Z',
          'position': 12,
          'spans': [],
          'events': [],
          'closed': true,
        };
        await library.update('reading-session:s1', session);
        await ReadingLog(old.repository).export(session);
        final fresh = AssetStore(
          Repository(second),
          Directory('${dir.path}/fresh'),
        );
        final connected = await ReadingRoots(fresh).connect(folder);
        final recovered = ReadingLibrary(fresh.repository);
        expect(
          (await recovered.value('reading-session:s1'))['bookId'],
          connected.bookIds.single,
        );
        expect(
          (await recovered.value('reader:${asset.hash}'))['textOffset'],
          12,
        );
        await recovered.update('reader:${asset.hash}', {'textOffset': 20});
        await ReadingRoots(fresh).connect(folder);
        expect(
          (await recovered.value('reader:${asset.hash}'))['textOffset'],
          20,
        );
        expect(await recovered.entries('reading-session:'), hasLength(1));
      } finally {
        await first.close();
        await second.close();
        await dir.delete(recursive: true);
      }
    },
  );
}

void _crossDeviceTests() {
  test('a books folder carries bookmarks, notes, PDF view and settings to a new device', () async {
    final dir = await Directory.systemTemp.createTemp('recovery-state-');
    final first = AppDatabase(NativeDatabase.memory());
    final second = AppDatabase(NativeDatabase.memory());
    try {
      await File('${dir.path}/Book.txt')
          .writeAsString('A book with enough text.');
      final folder = await scanAudioFolder(dir.path, books: true);
      final old = AssetStore(Repository(first), Directory('${dir.path}/cache'));
      final root = await ReadingRoots(old).connect(folder);
      final oldId = root.bookIds.single;
      final hash = (await old.list()).single.hash;
      final repo = old.repository;
      await ReadingLibrary(repo)
          .update('reader:$hash', {'chapter': 0, 'textOffset': 5});
      await repo.setMeta('pdf:$hash', '7');
      await repo.setMeta('pdf-view:$hash', jsonEncode({'zoom': 1.5}));
      await repo.setMeta(
        'reading-book:$oldId',
        jsonEncode({
          'favorite': true,
          'collections': ['local-only'],
          'overrides': {'title': 'Своё название'},
        }),
      );
      final bookmark = {
        'layoutVersion': 2,
        'id': 'b1',
        'title': 'Глава',
        'chapter': 0,
        'offset': 3,
        'createdAt': '2026-11-01T10:00:00Z',
      };
      await repo.setMeta('reader-bookmark:$hash:b1', jsonEncode(bookmark));
      for (final id in ['kept', 'deleted']) {
        await repo.setMeta(
          'reading-note:$id',
          jsonEncode({
            'id': id,
            'bookId': oldId,
            'hash': hash,
            'quote': 'Цитата $id',
          }),
        );
      }
      final session = <String, dynamic>{
        'id': 's1',
        'bookId': oldId,
        'hash': hash,
        'startedAt': '2026-11-01T10:00:00Z',
        'endedAt': '2026-11-01T10:10:00Z',
        'position': 5,
        'spans': [],
        'events': [],
        'closed': true,
      };
      await ReadingLibrary(repo).update('reading-session:s1', session);
      await ReadingLog(repo).export(session);

      // The old device deletes a note after the log was written: a later
      // folder check there must not bring it back.
      await repo.db.customStatement('DELETE FROM metadata WHERE key=?', [
        'reading-note:deleted',
      ]);
      await ReadingRoots(old).connect(folder);
      expect(await repo.meta('reading-note:deleted'), isNull);

      final fresh = AssetStore(
        Repository(second),
        Directory('${dir.path}/fresh'),
      );
      final connected = await ReadingRoots(fresh).connect(folder);
      final newId = connected.bookIds.single;
      final restored = fresh.repository;
      expect(
        jsonDecode((await restored.meta('reader:$hash'))!)['textOffset'],
        5,
      );
      expect(await restored.meta('pdf:$hash'), '7');
      expect(jsonDecode((await restored.meta('pdf-view:$hash'))!), {
        'zoom': 1.5,
      });
      expect(
        jsonDecode((await restored.meta('reader-bookmark:$hash:b1'))!),
        bookmark,
      );
      final prefs = jsonDecode((await restored.meta('reading-book:$newId'))!);
      expect(prefs['favorite'], true);
      expect(prefs['overrides'], {'title': 'Своё название'});
      expect(prefs.containsKey('collections'), isFalse);
      final note = jsonDecode((await restored.meta('reading-note:kept'))!);
      expect(note['bookId'], newId);
      expect(note['quote'], 'Цитата kept');
      // The new device saw the packet written before the deletion.
      expect(await restored.meta('reading-note:deleted'), isNotNull);
    } finally {
      await first.close();
      await second.close();
      await dir.delete(recursive: true);
    }
  });
}
