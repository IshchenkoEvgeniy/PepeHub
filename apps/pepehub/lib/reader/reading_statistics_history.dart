import '../data/repository.dart';
import '../library/activity_store.dart';
import '../library/library_features.dart';
import '../library/library_repository.dart';
import '../library/personal_library.dart';
import 'reading_library.dart';

/// One read-only source for the overview, calendar and reading statistics.
/// Missing files never erase recorded time or create new library cards.
class ReadingStatisticsHistory {
  final List<Map<String, dynamic>> sessions;
  final Map<String, String> titles;
  ReadingStatisticsHistory(this.sessions, this.titles);

  static Future<ReadingStatisticsHistory> load(Repository repository) async {
    final library = ReadingLibrary(repository);
    final sessions = <Map<String, dynamic>>[
      ...(await library.statisticsSessions()).values,
      ...await ActivityStore.foreignReading(repository),
      for (final s in await repository.records('session'))
        if (s.payload?['kind'] == 'reading')
          {
            'id': s.id,
            'bookId': s.payload!['bookId'],
            'startedAt': s.payload!['startedAt'],
            'source': 'manual',
            'closed': true,
            'spans': ActivityStore.manualSpans(s.payload!),
          },
    ];
    final cards =
        (await LibraryRepository(
              repository,
              personalLibraryNamespace,
              storageKey: personalLibraryKey,
            ).entries()).values
            .where(
              (e) =>
                  e.item.mediaType == 'book' &&
                  isLibraryArchiveItem(e.item) &&
                  !isLibraryDeleted(e.item),
            )
            .toList();
    final titles = <String, String>{
      // Project only the effective title. Index navigation, book text and audio
      // tracks never need to cross the database boundary for statistics labels.
      for (final row
          in await repository.db
              .customSelect(
                "SELECT b.id,COALESCE(json_extract(CASE WHEN json_valid(p.value) THEN p.value ELSE '{}' END,'\$.overrides.title'),"
                "json_extract(i.value,'\$.title'),json_extract(b.payload,'\$.title'),'Книга') AS title "
                'FROM records b LEFT JOIN local_assets a ON a.book_id=b.id '
                "LEFT JOIN reading_shelf_v1 i ON i.key='reading-index:'||a.sha256 "
                "LEFT JOIN metadata p ON p.key='reading-book:'||b.id "
                "WHERE b.type='book' AND json_valid(b.payload) AND json_type(b.payload)='object' "
                "AND IFNULL(json_extract(b.payload,'\$.format'),'')!='audio'",
              )
              .get())
        row.read<String>('id'): row.read<String>('title'),
      for (final e in cards)
        e.sourceBookId ?? 'card:${e.item.id}': e.item.title,
    };
    final standalone = {
      for (final e in cards)
        if (e.sourceBookId == null) e.item.id,
    };
    if (standalone.isNotEmpty) {
      for (final slot in await ActivityStore(
        repository,
        personalLibraryNamespace,
      ).entries()) {
        final value = Map<String, dynamic>.from(slot['value'] as Map);
        if (value['deleted'] == true ||
            value['mediaType'] != 'book' ||
            !standalone.contains(value['itemId'])) {
          continue;
        }
        final start = value['startedAt'] ?? '${value['day']}T12:00:00.000Z';
        final end =
            value['endedAt'] ??
            DateTime.parse(start as String)
                .add(Duration(milliseconds: value['durationMs'] as int))
                .toIso8601String();
        sessions.add({
          'id': value['id'],
          'bookId': 'card:${value['itemId']}',
          'source': 'library',
          'closed': true,
          'timeKnown': value['startedAt'] != null,
          'day': value['day'],
          'startedAt': start,
          'spans': [
            {
              'start': start,
              'end': end,
              'activeMs': value['durationMs'],
              'newChars': value['unit'] == 'characters' ? value['progress'] : 0,
              'localDay': value['day'],
              'offsetMinutes': value['offsetMinutes'],
            },
          ],
        });
      }
    }
    for (final session in sessions) {
      final id = session['bookId'] as String;
      titles.putIfAbsent(id, () => 'Книга без файла');
    }
    return ReadingStatisticsHistory(sessions, titles);
  }
}
