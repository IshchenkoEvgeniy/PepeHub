import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../data/database.dart';
import 'models.dart';

class AudioLibraryRepository {
  final AppDatabase db;
  AudioLibraryRepository(this.db);

  /// Pairs (part, whole): every audio file of `part` is also in `whole`,
  /// which has more files, and `part` was never started. Such a part is a
  /// leftover of the same files connected another way (an overlapping folder,
  /// another grouping mode, a card from another device) and only duplicates
  /// `whole` on the shelf. Files are compared by identity, never by name:
  /// imported copies by content hash; linked files by path, and an Android
  /// document by its document id, which is the same under any picked folder
  /// (`content://…/tree/<folder>/document/<file>`).
  Future<List<(String, String)>> containedBooks() async {
    final rows = await db.customSelect('''
      WITH h AS (
        SELECT DISTINCT e.book_id AS book,
          CASE WHEN t.asset_hash NOT LIKE 'external:%' THEN t.asset_hash
            WHEN r.path LIKE 'content:%' AND instr(r.path,'/document/')>0
              THEN 'doc:'||substr(r.path,instr(r.path,'/document/')+10)
            ELSE 'path:'||r.path END AS hash
        FROM audio_tracks t JOIN audio_editions e ON e.id=t.edition_id
        JOIN audio_resources r ON r.sha256=t.asset_hash
      ),
      n AS (SELECT book,COUNT(*) AS c FROM h GROUP BY book),
      started AS (
        SELECT DISTINCT e.book_id AS book FROM audio_progress p
        JOIN audio_editions e ON e.id=p.edition_id
        JOIN audio_tracks t ON t.id=p.track_id
        WHERE p.position_ms>0 OR t.ordinal>0
      )
      SELECT a.book AS part,b.book AS whole
      FROM h a JOIN h b ON b.hash=a.hash AND b.book<>a.book
      JOIN n na ON na.book=a.book JOIN n nb ON nb.book=b.book
      WHERE nb.c>na.c AND a.book NOT IN (SELECT book FROM started)
      GROUP BY a.book,b.book
      HAVING COUNT(*)=MAX(na.c)
    ''').get();
    return [
      for (final row in rows)
        (row.read<String>('part'), row.read<String>('whole')),
    ];
  }

  Future<Map<String, ({int? total, int? position, double speed})>>
  bookSummaries({String? bookId}) async {
    final rows = await db
        .customSelect(
          '''
      WITH choices AS (
        SELECT e.id,e.book_id,p.track_id,p.position_ms,p.speed,
          ROW_NUMBER() OVER(PARTITION BY e.book_id ORDER BY p.updated_at DESC,e.id) AS priority
        FROM audio_editions e LEFT JOIN audio_progress p ON p.edition_id=e.id
        ${bookId == null ? '' : 'WHERE e.book_id=?'}
      )
      SELECT c.book_id,c.speed,
        CASE WHEN COUNT(*)=COUNT(CASE WHEN t.duration_ms>0 THEN 1 END)
          THEN SUM(t.duration_ms) END AS total_ms,
        CASE WHEN c.track_id IS NOT NULL AND current.id IS NULL THEN NULL
          WHEN SUM(CASE WHEN t.ordinal<COALESCE(current.ordinal,0)
            AND (t.duration_ms IS NULL OR t.duration_ms<=0) THEN 1 ELSE 0 END)>0 THEN NULL
          ELSE SUM(CASE WHEN t.ordinal<COALESCE(current.ordinal,0) THEN t.duration_ms ELSE 0 END)
            + MIN(MAX(COALESCE(c.position_ms,0),0),COALESCE(current.duration_ms,c.position_ms,0))
          END AS position_ms
      FROM choices c JOIN audio_tracks t ON t.edition_id=c.id
      LEFT JOIN audio_tracks current ON current.id=c.track_id AND current.edition_id=c.id
      WHERE c.priority=1 GROUP BY c.id,c.book_id
    ''',
          variables: [if (bookId != null) Variable(bookId)],
        )
        .get();
    return {
      for (final row in rows)
        row.read<String>('book_id'): (
          total: row.readNullable<int>('total_ms'),
          position: row.readNullable<int>('position_ms'),
          speed: row.readNullable<double>('speed') ?? 1.0,
        ),
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
    return AudioProgress(
      locator,
      row?.read<double>('speed') ?? await _defaultSpeed(),
    );
  }

  /// The player's default speed, applied to books without saved progress.
  Future<double> _defaultSpeed() async {
    try {
      final raw = await db
          .customSelect(
            "SELECT value FROM metadata WHERE key='audio-sleep-settings'",
          )
          .getSingleOrNull();
      final value = raw == null
          ? null
          : (jsonDecode(raw.read<String>('value')) as Map)['defaultSpeed'];
      return value is num && audioDefaultSpeeds.contains(value)
          ? value.toDouble()
          : 1;
    } catch (_) {
      return 1;
    }
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
