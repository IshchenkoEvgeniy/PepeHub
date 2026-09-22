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
