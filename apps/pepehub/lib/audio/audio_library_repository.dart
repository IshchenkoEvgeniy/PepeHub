import 'book_timeline.dart';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../data/database.dart';
import 'models.dart';

class AudioLibraryRepository {
  final AppDatabase db;
  AudioLibraryRepository(this.db);

  Future<Map<String, ({int? total, int? position, double speed})>>
  bookSummaries() async {
    final rows = await db.customSelect(
      '''SELECT e.book_id,t.id,t.duration_ms,
      p.track_id,p.position_ms,p.speed FROM audio_editions e
      JOIN audio_tracks t ON t.edition_id=e.id
      LEFT JOIN audio_progress p ON p.edition_id=e.id ORDER BY e.id,t.ordinal''',
    ).get();
    final grouped = <String, List<QueryRow>>{};
    for (final row in rows) {
      grouped.putIfAbsent(row.read<String>('book_id'), () => []).add(row);
    }
    return {
      for (final entry in grouped.entries)
        entry.key: (() {
          final tracks = entry.value;
          final timeline = BookTimeline([
            for (final t in tracks) t.readNullable<int>('duration_ms'),
          ]);
          final selected = tracks.first.readNullable<String>('track_id');
          final index = selected == null
              ? 0
              : tracks.indexWhere((r) => r.read<String>('id') == selected);
          return (
            total: timeline.totalMs,
            position: timeline.positionMs(
              index,
              tracks.first.readNullable<int>('position_ms') ?? 0,
            ),
            speed: tracks.first.readNullable<double>('speed') ?? 1.0,
          );
        })(),
    };
  }

  Future<Map<String, DateTime>> lastPlayed() async => {
    for (final row
        in await db
            .customSelect(
              'SELECT e.book_id,MAX(p.updated_at) AS updated_at FROM audio_editions e '
              'JOIN audio_progress p ON p.edition_id=e.id GROUP BY e.book_id',
            )
            .get())
      if (DateTime.tryParse(row.read<String>('updated_at'))
          case final DateTime time)
        row.read<String>('book_id'): time,
  };

  Future<Map<String, Duration>> durations(String editionId) async => {
    for (final row
        in await db
            .customSelect(
              'SELECT id,duration_ms FROM audio_tracks WHERE edition_id=? AND duration_ms IS NOT NULL',
              variables: [Variable(editionId)],
            )
            .get())
      row.read<String>('id'): Duration(
        milliseconds: row.read<int>('duration_ms'),
      ),
  };

  Future<void> saveDuration(String trackId, Duration value) =>
      db.customStatement('UPDATE audio_tracks SET duration_ms=? WHERE id=?', [
        value.inMilliseconds,
        trackId,
      ]);

  /// Bridge for the existing single-file importer. Resources are independent
  /// of editions: sharing bytes never means sharing playback progress.
  Future<void> registerSingleTrack({
    required String bookId,
    required String assetId,
    required String hash,
    required String path,
    required String filename,
    required int bytes,
  }) => db.transaction(() async {
    final editionId = const Uuid().v5(
      Namespace.url.value,
      'pepehub:edition:$bookId',
    );
    await db.customStatement(
      'INSERT OR IGNORE INTO audio_editions VALUES(?,?,1)',
      [editionId, bookId],
    );
    await db.customStatement(
      'INSERT INTO audio_resources VALUES(?,?,?) ON CONFLICT(sha256) DO UPDATE SET path=excluded.path,bytes=excluded.bytes',
      [hash, path, bytes],
    );
    final existing = await track(assetId);
    if (existing != null) {
      if (existing.editionId != editionId || existing.assetHash != hash) {
        throw StateError('Содержимое трека изменилось');
      }
      return;
    }
    await db.customStatement(
      'INSERT INTO audio_tracks VALUES(?,?,?,?,?,NULL)',
      [assetId, editionId, hash, 0, filename],
    );
  });

  Future<AudioTrack?> track(String id) async {
    final row = await db
        .customSelect(
          'SELECT * FROM audio_tracks WHERE id=?',
          variables: [Variable(id)],
        )
        .getSingleOrNull();
    return row == null
        ? null
        : AudioTrack(
            id: row.read<String>('id'),
            editionId: row.read<String>('edition_id'),
            assetHash: row.read<String>('asset_hash'),
            title: row.read<String>('title'),
            ordinal: row.read<int>('ordinal'),
            durationMs: row.readNullable<int>('duration_ms'),
          );
  }

  Future<AudioEdition> edition(String id) async {
    final row = await db
        .customSelect(
          'SELECT * FROM audio_editions WHERE id=?',
          variables: [Variable(id)],
        )
        .getSingle();
    return AudioEdition(
      id: id,
      bookId: row.read<String>('book_id'),
      manifestRevision: row.read<int>('manifest_revision'),
    );
  }

  Future<AudioProgress> progressForTrack(String trackId) async {
    final selected = await track(trackId);
    if (selected == null) throw StateError('Трек отсутствует в библиотеке');
    final parent = await edition(selected.editionId);
    final row = await db
        .customSelect(
          'SELECT * FROM audio_progress WHERE edition_id=?',
          variables: [Variable(parent.id)],
        )
        .getSingleOrNull();
    final first = row == null
        ? await db
              .customSelect(
                'SELECT id FROM audio_tracks WHERE edition_id=? ORDER BY ordinal LIMIT 1',
                variables: [Variable(parent.id)],
              )
              .getSingle()
        : null;
    final locator = AudioLocator(
      bookId: parent.bookId,
      editionId: parent.id,
      trackId: row?.read<String>('track_id') ?? first!.read<String>('id'),
      positionMs: row?.read<int>('position_ms') ?? 0,
      manifestRevision:
          row?.read<int>('manifest_revision') ?? parent.manifestRevision,
    );
    return AudioProgress(locator, row?.read<double>('speed') ?? 1);
  }

  Future<void> saveProgress(AudioProgress progress) => db.transaction(() async {
    final locator = progress.locator;
    final selected = await track(locator.trackId);
    if (selected == null || selected.editionId != locator.editionId) {
      throw ArgumentError('Трек не принадлежит изданию');
    }
    final parent = await edition(locator.editionId);
    if (parent.bookId != locator.bookId ||
        parent.manifestRevision != locator.manifestRevision) {
      throw StateError('Изменилось издание аудиокниги');
    }
    if (selected.durationMs != null &&
        locator.positionMs > selected.durationMs!) {
      throw ArgumentError('Позиция за пределами трека');
    }
    await db.customStatement(
      'INSERT INTO audio_progress(edition_id,track_id,position_ms,manifest_revision,speed,updated_at) VALUES(?,?,?,?,?,?) ON CONFLICT(edition_id) DO UPDATE SET track_id=excluded.track_id,position_ms=excluded.position_ms,manifest_revision=excluded.manifest_revision,speed=excluded.speed,updated_at=excluded.updated_at',
      [
        locator.editionId,
        locator.trackId,
        locator.positionMs,
        locator.manifestRevision,
        progress.speed,
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
  });
}
