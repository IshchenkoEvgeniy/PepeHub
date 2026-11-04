import 'dart:convert';

import 'package:drift/drift.dart' show Variable;

import '../data/repository.dart';
import '../data/database_schema.dart';
import '../library/activity_store.dart';
import '../library/library_features.dart';
import '../library/library_repository.dart';
import '../library/models.dart';
import '../library/personal_library.dart';
import '../library/reading_insights.dart';
import '../reader/reading_library.dart';
import 'audio_journal.dart';
import 'manual_audio_progress.dart';

/// Supplemental statistics are views of saved data, never new journal writes.
class AudioStatisticsHistory {
  final List<Map<String, dynamic>> events;
  final Map<String, String> titles;
  AudioStatisticsHistory(this.events, this.titles);

  static Future<AudioStatisticsHistory> load(
    Repository repository, {
    Iterable<LibraryEntry>? entries,
    List<Map<String, dynamic>>? foreign,
  }) async {
    final cards =
        (entries ??
                (await LibraryRepository(
                  repository,
                  personalLibraryNamespace,
                  storageKey: personalLibraryKey,
                ).entries()).values)
            .where(
              (e) => isLibraryArchiveItem(e.item) && !isLibraryDeleted(e.item),
            )
            .toList();
    final result = <Map<String, dynamic>>[
      ...foreign ?? await ActivityStore.foreignAudio(repository),
    ];
    final standalone = {
      for (final e in cards)
        if (e.sourceBookId == null) e.item.id: e,
    };
    for (final slot in await ActivityStore(
      repository,
      personalLibraryNamespace,
    ).entries()) {
      final v = slot['value'] as Map;
      if (v['deleted'] == true ||
          v['mediaType'] != 'audiobook' ||
          !standalone.containsKey(v['itemId'])) {
        continue;
      }
      result.add({
        ..._event(
          'card:${v['itemId']}',
          '${v['day']}',
          (v['durationMs'] as num).toInt(),
          (v['mediaMs'] as num?)?.toInt() ?? 0,
          'activity:${v['id']}',
        ),
        'at': v['startedAt'] ?? '${v['day']}T12:00:00.000Z',
        'timeKnown': v['startedAt'] != null,
        'offsetMinutes': v['offsetMinutes'] ?? 0,
      });
    }
    final baselines = await ReadingLibrary(repository)
        .entries('obsidian-auto:$personalLibraryNamespace:');
    final candidates =
        <({LibraryEntry entry, String id, int media, DateTime cutoff})>[];
    final titles = <String, String>{};
    for (final entry in cards) {
      final item = entry.item;
      if (item.mediaType != 'audiobook') continue;
      final id = entry.sourceBookId ?? 'card:${item.id}';
      titles[id] = item.title;
      final values = {
        'progress': item.value('progress'),
        'unit': item.value('unit'),
      };
      final listened = audioProgressMs(values);
      // Automatic position updates can include seeks. Only a manual value may
      // supply missing listening time; an unchanged automatic baseline cannot.
      if (entry.sourceBookId != null &&
          listened != null &&
          listened == audioProgressMs(baselines[item.id] ?? {})) {
        continue;
      }
      if (listened == null || listened <= 0) continue;
      final stamped = item.values['pepehub_audio_progress_ms'] == listened
          ? DateTime.tryParse('${item.values['pepehub_audio_progress_at']}')
          : null;
      candidates.add((
        entry: entry,
        id: id,
        media: listened,
        cutoff:
            stamped ??
            DateTime.fromMillisecondsSinceEpoch(item.modifiedAt, isUtc: true),
      ));
    }
    final recorded = await _recordedBefore(repository, candidates);
    final journalsByBook = <String, List<Map<String, dynamic>>>{};
    for (final e in result) {
      (journalsByBook[e['bookId'] as String] ??= []).add(e);
    }
    for (final candidate in candidates) {
      final item = candidate.entry.item;
      var covered = recorded[candidate.id] ?? 0;
      // Journal entries have no track ranges, so their material is the best
      // available overlap estimate. Entries recorded later cannot erase history.
      for (final event
          in journalsByBook[candidate.id] ?? <Map<String, dynamic>>[]) {
        final at = DateTime.tryParse('${event['at']}');
        if (at == null) continue;
        final before = event['timeKnown'] == false
            ? '${event['localDay']}'.compareTo(
                    dayKey(candidate.cutoff.toLocal()),
                  ) <=
                  0
            : at.isBefore(candidate.cutoff);
        if (!before) continue;
        final wall = (event['wallMs'] as num).toInt();
        final media = (event['mediaMs'] as num?)?.toInt() ?? 0;
        if (event['timeKnown'] == false || wall <= 0) {
          covered += media > 0 ? media : wall;
        } else {
          final clipped = candidate.cutoff
              .difference(at)
              .inMilliseconds
              .clamp(0, wall);
          covered += ((media > 0 ? media : wall) * clipped / wall).round();
        }
      }
      final missing = candidate.media - covered;
      if (missing <= 0) continue;
      final date =
          bookDate(item.value('endDate')) ?? bookDate(item.value('startDate'));
      result.add({
        ..._event(
          candidate.id,
          dayKey(date ?? candidate.cutoff.toLocal()),
          missing,
          missing,
          'metadata:${item.id}',
        ),
        'estimated': true,
        'dateKnown': date != null,
      });
    }
    return AudioStatisticsHistory(result, titles);
  }

  /// Union overlapping ranges inside SQLite. Replays count as real listening,
  /// but must not consume the manual progress twice. Return one row per book.
  static Future<Map<String, int>> _recordedBefore(
    Repository repository,
    List<({LibraryEntry entry, String id, int media, DateTime cutoff})>
    candidates,
  ) async {
    final linked = [
      for (final c in candidates)
        if (c.entry.sourceBookId != null)
          {'book': c.id, 'cutoff': c.cutoff.millisecondsSinceEpoch},
    ];
    if (linked.isEmpty) return {};
    final rows = await repository.db
        .customSelect(
          '''
      WITH requested AS (
        SELECT json_extract(value,'\$.book') AS book,
          json_extract(value,'\$.cutoff') AS cutoff FROM json_each(?)
      ), source AS (
        SELECT book,cutoff,${SchemaSql.audioEventAt} AS at,
          json_extract(payload,'\$.kind') AS kind,
          json_extract(payload,'\$.trackId') AS track,
          CAST(json_extract(payload,'\$.wallMs') AS INTEGER) AS wall,
          CAST(json_extract(payload,'\$.positionMs') AS INTEGER) AS lo,
          CAST(json_extract(payload,'\$.endMs') AS INTEGER) AS hi,
          COALESCE(NULLIF(CAST(json_extract(payload,'\$.mediaMs') AS INTEGER),0),
            CAST(json_extract(payload,'\$.wallMs') AS INTEGER)) AS media
        FROM requested JOIN records ON ${SchemaSql.audioEventBook}=book
        WHERE ${SchemaSql.audioEventRows} AND deleted=0
          AND json_extract(payload,'\$.kind') IN ('listen','journal')
      ), clipped AS (
        SELECT *, MIN(wall,cutoff-at) AS elapsed FROM source
        WHERE wall>0 AND at<cutoff
      ), ranges AS (
        SELECT book,track,lo,lo+CAST(ROUND(1.0*(hi-lo)*elapsed/wall) AS INTEGER) AS hi
        FROM clipped WHERE kind='listen' AND hi>lo
      ), ordered AS (
        SELECT *,MAX(hi) OVER (PARTITION BY book,track ORDER BY lo,hi
          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS previous_hi FROM ranges
      ), totals AS (
        SELECT book,SUM(MAX(0,hi-MAX(lo,COALESCE(previous_hi,lo)))) AS media FROM ordered GROUP BY book
        UNION ALL SELECT book,SUM(CAST(ROUND(1.0*media*elapsed/wall) AS INTEGER))
          FROM clipped WHERE kind='journal' GROUP BY book
      ) SELECT book,SUM(media) AS media FROM totals GROUP BY book
    ''',
          variables: [Variable(jsonEncode(linked))],
        )
        .get();
    return {
      for (final row in rows) row.read<String>('book'): row.read<int>('media'),
    };
  }

  static Map<String, dynamic> _event(
    String book,
    String day,
    int wall,
    int media,
    String id,
  ) => {
    'kind': 'journal',
    'bookId': book,
    'trackId': id,
    'at': '${day}T12:00:00.000Z',
    'timeKnown': false,
    'localDay': day,
    'offsetMinutes': 0,
    'wallMs': wall,
    'mediaMs': media,
    'positionMs': 0,
    'endMs': media,
    'speed': 1,
  };
}
