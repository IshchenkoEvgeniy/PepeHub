import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/audio/audio_journal.dart';
import 'package:pepehub/audio/audio_catalog.dart';
import 'package:pepehub/audio/audio_folder.dart';
import 'package:pepehub/audio/audio_roots.dart';
import 'package:pepehub/audio/audio_sidecar.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';

void main() {
  test('three hours of checkpoints stay compact and preserve exact listening totals', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final repo = Repository(db), journal = AudioJournal(Repository(db));
    try {
      final at = DateTime.utc(2026, 9, 17, 10);
      for (var i = 0; i < 1080; i++) {
        await journal.appendListening(
          ListeningSegment(
            'book',
            'track',
            i * 10000,
            (i + 1) * 10000,
            10000,
            1,
            at.add(Duration(seconds: i * 10)),
          ),
        );
      }
      final records = await repo.records('audio_event');
      expect(records.length, 3);
      final stats = AudioStats(records.map((r) => r.payload!));
      expect(stats.wallMs, 10800000);
      expect(stats.uniqueMs, 10800000);
      expect(stats.repeatedMs, 0);
      expect(stats.recent, isEmpty);
      journal.endInterval();
      await journal.appendListening(
        ListeningSegment(
          'book',
          'track',
          0,
          10000,
          10000,
          1,
          at.add(const Duration(hours: 3, minutes: 1)),
        ),
      );
      final repeated = AudioStats(
        (await repo.records('audio_event')).map((r) => r.payload!),
      );
      expect(repeated.repeatedMs, 10000);
      expect(repeated.wallMs, 10810000);
    } finally {
      await db.close();
    }
  });

  test('daily journal rotates, safely consolidates legacy packets, exports table and restores newest interval', () async {
    final dir = await Directory.systemTemp.createTemp('pepehub-compact-');
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
      final journal = AudioJournal(repo);
      final at = DateTime.utc(2026, 9, 17, 10);
      await journal.appendListening(
        ListeningSegment(track.bookId, track.id, 0, 10000, 10000, 1, at),
      );
      await exportAudioJournal(assets, root);
      final daily = File(
        '${dir.path}/.pepehub/logs/2026-09-17/events-2026-09-17.json',
      );
      final old = parseAudioSnapshot(await daily.readAsString());
      await journal.appendListening(
        ListeningSegment(
          track.bookId,
          track.id,
          10000,
          20000,
          10000,
          1,
          at.add(const Duration(seconds: 10)),
        ),
      );
      await exportAudioJournal(assets, root);
      final legacy = File('${daily.parent.path}/events-${'a' * 64}.json');
      await legacy.writeAsString(await daily.readAsString());
      final unknown = File('${daily.parent.path}/events-${'b' * 64}.json');
      await unknown.writeAsString('unknown data');
      await journal.event(
        'pause',
        track.bookId,
        track.id,
        10000,
        extra: {'localDay': '2026-09-17'},
      );
      await exportAudioJournal(assets, root);
      expect(await legacy.exists(), isFalse);
      expect(await unknown.readAsString(), 'unknown data');
      expect(await File('${daily.path}.bak').exists(), isTrue);
      await journal.appendListening(
        ListeningSegment(
          track.bookId,
          track.id,
          20000,
          30000,
          10000,
          1,
          at.add(const Duration(seconds: 20)),
        ),
      );
      await exportAudioJournal(assets, root);
      final current = parseAudioSnapshot(await daily.readAsString());
      expect(
        (current['events'] as List)
            .where((e) => e['data']['kind'] == 'listen')
            .fold<int>(0, (sum, e) => sum + (e['data']['wallMs'] as int)),
        30000,
      );
      await restoreAudioSnapshot(assets, root, old);
      final stats = AudioStats(
        (await repo.records('audio_event')).map((r) => r.payload!),
      );
      expect(
        stats.wallMs,
        30000,
        reason: 'Old checkpoint must not overwrite longer interval',
      );
      final table = await File('${dir.path}/.pepehub/library.csv')
          .readAsString();
      expect(table, contains('Книга'));
      expect(table, contains('Book'));
      expect(table, contains('Глав прослушано'));
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });
}
