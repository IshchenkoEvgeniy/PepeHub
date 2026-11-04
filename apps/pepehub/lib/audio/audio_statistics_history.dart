import '../data/repository.dart';
import '../library/activity_store.dart';
import '../library/library_features.dart';
import '../library/library_repository.dart';
import '../library/models.dart';
import '../library/personal_library.dart';
import '../library/reading_insights.dart';
import '../reader/reading_library.dart';
import 'audio_journal.dart';

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
      result.add(
        _event(
          'card:${v['itemId']}',
          '${v['day']}',
          (v['durationMs'] as num).toInt(),
          (v['mediaMs'] as num?)?.toInt() ?? 0,
          'activity:${v['id']}',
        ),
      );
    }
    final recordedMedia = <String, int>{};
    void account(String id, int wall, int media) {
      recordedMedia[id] = (recordedMedia[id] ?? 0) + (media > 0 ? media : wall);
    }

    final baselines = await ReadingLibrary(repository)
        .entries('obsidian-auto:$personalLibraryNamespace:');

    // Aggregate in SQLite without loading tracks or native event payloads.
    for (final row
        in await repository.db
            .customSelect(
              "SELECT json_extract(payload,'\$.bookId') AS book_id,"
              "SUM(json_extract(payload,'\$.wallMs')) AS wall,"
              "SUM(CASE WHEN json_extract(payload,'\$.kind')='listen' THEN "
              "json_extract(payload,'\$.endMs')-json_extract(payload,'\$.positionMs') "
              "ELSE COALESCE(NULLIF(json_extract(payload,'\$.mediaMs'),0),"
              "json_extract(payload,'\$.wallMs')) END) AS media "
              "FROM records WHERE type='audio_event' AND deleted=0 AND json_valid(payload) "
              "AND json_extract(payload,'\$.kind') IN ('listen','journal') "
              "AND json_extract(payload,'\$.wallMs')>0 GROUP BY 1",
            )
            .get()) {
      account(
        row.read<String>('book_id'),
        row.read<int>('wall'),
        row.read<int>('media'),
      );
    }
    for (final e in result) {
      account(
        e['bookId'] as String,
        (e['wallMs'] as num).toInt(),
        (e['mediaMs'] as num?)?.toInt() ?? 0,
      );
    }
    final titles = <String, String>{};
    for (final entry in cards) {
      final item = entry.item;
      if (item.mediaType != 'audiobook') continue;
      final id = entry.sourceBookId ?? 'card:${item.id}';
      titles[id] = item.title;
      final progress = num.tryParse(
        '${item.value('progress')}'.replaceAll(',', '.'),
      );
      final savedUnit = item.value('unit');
      final unit = savedUnit == null || savedUnit == '' ? 'minutes' : savedUnit;
      // Automatic position updates can include seeks. Only a manual value may
      // supply missing listening time; an unchanged automatic baseline cannot.
      if (entry.sourceBookId != null &&
          sameMetadataValue(
            baselines[item.id]?['progress'],
            item.value('progress'),
          )) {
        continue;
      }
      if (progress == null ||
          !progress.isFinite ||
          progress <= 0 ||
          !['minutes', 'hours'].contains(unit)) {
        continue;
      }
      final listened = (progress * (unit == 'hours' ? 3600000 : 60000)).round();
      // Progress describes media time. Subtract media already journaled so
      // playback at 2x and repeated visits never inflate the manual remainder.
      final missing = listened - (recordedMedia[id] ?? 0);
      if (missing <= 0) continue;
      final date =
          bookDate(item.value('endDate')) ?? bookDate(item.value('startDate'));
      if (date == null) continue;
      result.add(
        _event(id, dayKey(date), missing, missing, 'metadata:${item.id}'),
      );
    }
    return AudioStatisticsHistory(result, titles);
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
