import 'package:flutter/foundation.dart' show compute;

import '../audio/audio_daily_totals.dart';
import '../reader/reading_statistics_history.dart';
import '../reader/reading_statistics_data.dart';
import 'activity_store.dart';
import 'library_service.dart';

/// Local activity stays visible before a work is explicitly added to the
/// archive. These disposable day rows are never stored or synchronized as cards.
class JournalDays {
  final List<Map<String, dynamic>> slots;
  final Map<String, String> titles;
  JournalDays(this.slots, this.titles);

  static Future<JournalDays> outsideArchive(LibraryService library) async {
    final repository = library.local;
    final linked = {for (final e in library.visibleEntries) e.sourceBookId};
    final history = await ReadingStatisticsHistory.load(repository);
    final reading = await compute(summarizeReadingCalendar, <String, dynamic>{
      'sessions': history.sessions,
      'year': DateTime.now().year,
    });
    final audio = await AudioDailyStore(repository).lifetime();
    final foreign = await ActivityStore.foreignAudio(repository);
    final audioBooks = <String, Map<String, int>>{
      for (final e in audio.bookDays.entries) e.key: {...e.value},
    };
    // Foreign rows have already been deduplicated against native intervals.
    for (final value in foreign) {
      final id = value['bookId'] as String, day = value['localDay'] as String;
      final days = audioBooks.putIfAbsent(id, () => {});
      days[day] = (days[day] ?? 0) + (value['wallMs'] as num).toInt();
    }
    final titles = {
      for (final b in await repository.bookHeaders()) b.id: b.title,
      ...history.titles,
    };
    final slots = <Map<String, dynamic>>[];
    for (final (type, books) in [
      ('book', reading.bookDays),
      ('audiobook', audioBooks),
    ]) {
      for (final book in books.entries) {
        if (linked.contains(book.key) || book.key.startsWith('card:')) continue;
        for (final day in book.value.entries) {
          if (day.value <= 0) continue;
          slots.add({
            'nativeBookId': book.key,
            'value': {
              'id': 'native:$type:${book.key}:${day.key}',
              'itemId': 'source:${book.key}',
              'mediaType': type,
              'day': day.key,
              'durationMs': day.value,
              'progress': 0,
              'unit': 'unknown',
              'mediaMs': 0,
              'note':
                  'Дневной итог · отдельные сессии доступны в правке журнала',
              'origin': 'app-native',
              'deleted': false,
            },
          });
        }
      }
    }
    // Keep this view based on actual intervals; manual progress estimates are
    // for statistics only and never become journal sessions.
    return JournalDays(slots, {
      for (final e in titles.entries) 'source:${e.key}': e.value,
    });
  }
}
