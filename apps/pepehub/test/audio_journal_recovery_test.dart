import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/audio/audio_catalog.dart';
import 'package:pepehub/audio/audio_folder.dart';
import 'package:pepehub/audio/audio_journal.dart';
import 'package:pepehub/audio/audio_roots.dart';
import 'package:pepehub/audio/audio_sidecar.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/media/library_recovery.dart';

void main() {
  late Directory directory;
  late AppDatabase first, second;
  late AssetStore assets;
  late AudioRoot root;
  late LocalAsset track;
  late AudioJournal journal;
  late File daily;

  Future<AssetStore> connect(AppDatabase db, String cache) async {
    final store = AssetStore(
      Repository(db),
      Directory('${directory.path}/$cache'),
    );
    final folder = await scanAudioFolder(directory.path);
    await connectAudioCatalog(store, folder, groupAudioCatalog(folder));
    return store;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'audio-journal-recovery-',
    );
    first = AppDatabase(NativeDatabase.memory());
    second = AppDatabase(NativeDatabase.memory());
    await Directory('${directory.path}/Book').create();
    await File('${directory.path}/Book/01.mp3')
        .writeAsBytes(List.filled(16, 1));
    assets = await connect(first, 'cache');
    root = (await AudioRoots(assets).list()).single;
    track = (await assets.audioTracks(root.bookIds.single)).single;
    journal = AudioJournal(assets.repository);
    await journal.appendListening(
      ListeningSegment(
        track.bookId,
        track.id,
        0,
        600000,
        600000,
        1,
        DateTime.utc(2026, 9, 17, 10),
      ),
    );
    await exportAudioJournal(assets, root);
    daily = File(
      '${directory.path}/.pepehub/logs/2026-09-17/events-2026-09-17.json',
    );
  });

  tearDown(() async {
    await first.close();
    await second.close();
    await directory.delete(recursive: true);
  });

  test('reconnect and reinstall preserve a reduced interval against older backups', () async {
    final old = parseAudioSnapshot(await daily.readAsString());
    final event = (await assets.repository.records('audio_event')).single;
    await journal.put('audio_event', event.id, {
      ...event.payload!,
      'wallMs': 300000,
      'mediaMs': 300000,
      'endMs': 300000,
      'note': 'Corrected',
    });
    await exportAudioJournal(assets, root);
    // Existing v1 packets remain supported, including multiple checkpoints that
    // would otherwise inflate the temporary database revision during recovery.
    for (final pair in [('a', 600000), ('b', 500000)]) {
      final legacy = jsonDecode(jsonEncode(old)) as Map<String, dynamic>;
      legacy['version'] = 1;
      for (final row in legacy['events'] as List) {
        row.remove('revision');
        row.remove('deleted');
        row['data']['wallMs'] = pair.$2;
      }
      await File('${daily.parent.path}/events-${pair.$1 * 64}.json')
          .writeAsString(jsonEncode(legacy));
    }
    await recoverAudioRoot(assets, root);
    expect(
      (await assets.repository.record(event.id))!.payload!['wallMs'],
      300000,
    );
    final fresh = await connect(second, 'fresh');
    final recovered = (await fresh.repository.records('audio_event')).single;
    expect(recovered.id, event.id);
    expect(recovered.revision, 2);
    expect(recovered.payload!['wallMs'], 300000);
    expect(recovered.payload!['note'], 'Corrected');
    final freshTrack = (await fresh.audioTracks(
      (await AudioRoots(fresh).list()).single.bookIds.single,
    )).single;
    expect(recovered.payload!['trackId'], freshTrack.id);
  });

  test('deleting the last event exports a tombstone and older packets cannot resurrect it', () async {
    final old = parseAudioSnapshot(await daily.readAsString());
    final event = (await assets.repository.records('audio_event')).single;
    await journal.deleteEvent(event.id);
    await exportAudioJournal(assets, root);
    final current = parseAudioSnapshot(await daily.readAsString());
    expect(current['version'], 2);
    expect((current['events'] as List).single['deleted'], true);
    final legacy = jsonDecode(jsonEncode(old)) as Map<String, dynamic>;
    legacy['version'] = 1;
    for (final row in legacy['events'] as List) {
      row.remove('revision');
      row.remove('deleted');
    }
    await File('${daily.parent.path}/events-${'c' * 64}.json')
        .writeAsString(jsonEncode(legacy));
    await recoverAudioRoot(assets, root);
    expect((await assets.repository.record(event.id))!.deleted, true);
    final fresh = await connect(second, 'fresh');
    expect(await fresh.repository.records('audio_event'), isEmpty);
    expect((await fresh.repository.record(event.id))!.deleted, true);
    expect((await fresh.repository.record(event.id))!.revision, 2);
  });

  test(
    'legacy recovery does not replace a local correction or deletion',
    () async {
      final legacy = parseAudioSnapshot(await daily.readAsString());
      legacy['version'] = 1;
      for (final row in legacy['events'] as List) {
        row.remove('revision');
        row.remove('deleted');
      }
      final event = (await assets.repository.records('audio_event')).single;
      await journal.put('audio_event', event.id, {
        ...event.payload!,
        'wallMs': 100000,
      });
      await restoreAudioSnapshot(
        assets,
        root,
        legacy,
        backup: false,
        merge: true,
      );
      expect(
        (await assets.repository.record(event.id))!.payload!['wallMs'],
        100000,
      );
      await journal.deleteEvent(event.id);
      await restoreAudioSnapshot(
        assets,
        root,
        legacy,
        backup: false,
        merge: true,
      );
      expect((await assets.repository.record(event.id))!.deleted, true);
    },
  );

  test(
    'invalid journal revisions are rejected before restoring any data',
    () async {
      final snapshot = parseAudioSnapshot(await daily.readAsString());
      snapshot['events'][0]['revision'] = 0;
      await expectLater(
        restoreAudioSnapshot(assets, root, snapshot, backup: false),
        throwsStateError,
      );
      expect(
        (await assets.repository.records('audio_event'))
            .single
            .payload!['wallMs'],
        600000,
      );
    },
  );
}
