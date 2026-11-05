import 'package:drift/drift.dart' show Variable, QueryRow;

import '../audio/audio_journal.dart';
import '../audio/audio_daily_totals.dart';
import '../audio/listening_analytics.dart';
import '../audio/audio_statistics_history.dart';
import '../data/repository.dart';
import '../reader/reading_statistics_data.dart';

import 'package:flutter/foundation.dart' show compute;

import 'library_service.dart';
import 'models.dart';
import 'reading_insights.dart';

class CalendarBook {
  final String id, title, mediaType;
  final LibraryEntry? entry;
  final String? localCover;
  const CalendarBook(
    this.id,
    this.title,
    this.mediaType,
    this.entry,
    this.localCover,
  );
}

class BookCalendarData {
  final Map<String, CalendarBook> books = {};
  final Map<String, Map<String, int>> days = {};
  final Map<String, int> archiveReading = {}, archiveAudio = {};
  final Map<String, int> archiveReadingAll = {}, archiveAudioAll = {};
  final Map<String, Set<String>> completedDays = {};
  void add(String day, String id, int ms) {
    if (ms <= 0) return;
    final values = days.putIfAbsent(day, () => {});
    values[id] = (values[id] ?? 0) + ms;
  }

  static Future<BookCalendarData> load({
    required Repository repository,
    required int year,
    required List<Map<String, dynamic>> reading,
    required List<Map<String, dynamic>> foreignAudio,
    LibraryService? library,
    List<LibraryRecord>? bookRecords,
    ReadingCalendarSummary? readingSummary,
    AudioStatisticsHistory? audioHistory,
    AudioDailyTotals? nativeAudio,
    ListeningAnalytics? audioSummary,
    Map<String, String> readingTitles = const {},
    Iterable<LibraryEntry>? completedEntries,
  }) async {
    final data = BookCalendarData();
    final links = {
      for (final e in library?.visibleEntries ?? <LibraryEntry>[])
        if (e.sourceBookId != null) e.sourceBookId!: e,
    };
    // SQL projects only cover paths; paragraph and chapter indexes stay in SQLite.
    final covers = await repository.db
        .customSelect(
          "SELECT a.book_id,json_extract(m.value,'\$.cover') AS cover FROM local_assets a "
          "JOIN reading_shelf_v1 m ON m.key='reading-index:'||a.sha256",
        )
        .get();
    final coverByBook = {
      for (final row in covers)
        row.read<String>('book_id'): row.readNullable<String>('cover'),
    };
    for (final record in bookRecords ?? await repository.bookHeaders()) {
      final entry = links[record.id];
      data.books[record.id] = CalendarBook(
        record.id,
        readingTitles[record.id] ?? entry?.item.title ?? record.title,
        record.payload?['format'] == 'audio' ? 'audiobook' : 'book',
        entry,
        entry == null ? coverByBook[record.id] : library?.coverPath(entry.item),
      );
    }
    for (final e in readingTitles.entries) {
      data.books.putIfAbsent(
        e.key,
        () => CalendarBook(e.key, e.value, 'book', null, null),
      );
    }
    final summary =
        readingSummary ??
        await compute<Map<String, dynamic>, ReadingCalendarSummary>(
          summarizeReadingCalendar,
          <String, dynamic>{'sessions': reading, 'year': year},
        );
    for (final book in summary.bookDays.entries) {
      data.books.putIfAbsent(
        book.key,
        () => CalendarBook(
          book.key,
          readingTitles[book.key] ?? 'Книга без файла',
          'book',
          null,
          null,
        ),
      );
      for (final e in book.value.entries) {
        if (e.key.startsWith('$year-')) {
          data.add(e.key, book.key, e.value);
        }
      }
    }
    final audio = nativeAudio == null
        ? await repository.db
              .customSelect(
                'SELECT day,book_id,wall_ms FROM audio_daily_totals_v1 WHERE day>=? AND day<? AND wall_ms>0',
                variables: [
                  Variable('$year-01-01'),
                  Variable('${year + 1}-01-01'),
                ],
              )
              .get()
        : <QueryRow>[];
    for (final row in audio) {
      final id = row.read<String>('book_id');
      data.books.putIfAbsent(
        id,
        () => CalendarBook(id, 'Аудиокнига без файла', 'audiobook', null, null),
      );
      data.add(
        row.read<String>('day'),
        row.read<String>('book_id'),
        row.read<int>('wall_ms'),
      );
    }
    if (nativeAudio != null) {
      for (final book in nativeAudio.bookDays.entries) {
        data.books.putIfAbsent(
          book.key,
          () => CalendarBook(
            book.key,
            'Аудиокнига без файла',
            'audiobook',
            null,
            null,
          ),
        );
        for (final e in book.value.entries) {
          if (e.key.startsWith('$year-')) data.add(e.key, book.key, e.value);
        }
      }
    }
    final supplemental =
        audioHistory ??
        await AudioStatisticsHistory.load(
          repository,
          entries: library?.visibleEntries,
          foreign: foreignAudio,
        );
    final audioGroups = <String, List<Map<String, dynamic>>>{};
    for (final title in supplemental.titles.entries) {
      data.books.putIfAbsent(
        title.key,
        () => CalendarBook(title.key, title.value, 'audiobook', null, null),
      );
    }
    if (audioSummary == null) {
      for (final event in supplemental.events) {
        (audioGroups['${event['bookId']}'] ??= []).add(event);
      }
    }
    final audioBooks =
        audioSummary?.byBook ??
        {
          for (final group in audioGroups.entries)
            group.key: AudioStats(group.value),
        };
    for (final group in audioBooks.entries) {
      data.books.putIfAbsent(
        group.key,
        () => CalendarBook(
          group.key,
          'Аудиокнига без файла',
          'audiobook',
          null,
          null,
        ),
      );
      for (final day in group.value.days.entries) {
        data.archiveAudioAll[day.key] =
            (data.archiveAudioAll[day.key] ?? 0) + day.value;
        if (day.key.startsWith('$year-')) {
          data.add(day.key, group.key, day.value);
          data.archiveAudio[day.key] =
              (data.archiveAudio[day.key] ?? 0) + day.value;
        }
      }
    }
    // Cards without a linked local file still have their own reading journal.
    if (library != null) {
      final standalone = {
        for (final e in library.visibleEntries)
          if (e.sourceBookId == null) e.item.id: e,
      };
      if (standalone.isNotEmpty) {
        for (final e in standalone.values) {
          data.books['card:${e.item.id}'] = CalendarBook(
            'card:${e.item.id}',
            e.item.title,
            e.item.mediaType,
            e,
            library.coverPath(e.item),
          );
        }
        final missing = standalone.keys
            .where((id) => !summary.bookDays.containsKey('card:$id'))
            .toSet();
        for (final slot
            in missing.isEmpty
                ? <Map<String, dynamic>>[]
                : await library.history!.entries()) {
          final v = slot['value'] as Map;
          if (v['deleted'] == true || !standalone.containsKey(v['itemId'])) {
            continue;
          }
          if (v['mediaType'] == 'audiobook') continue;
          // The shared reading source already includes these card sessions.
          // Keep the fallback for callers supplying only native reading rows.
          if (!missing.contains(v['itemId'])) continue;
          final day = '${v['day']}';
          final ms = (v['durationMs'] as num).toInt();
          final all = v['mediaType'] == 'book'
              ? data.archiveReadingAll
              : data.archiveAudioAll;
          all[day] = (all[day] ?? 0) + ms;
          if (!day.startsWith('$year-')) continue;
          data.add(day, 'card:${v['itemId']}', ms);
          final totals = v['mediaType'] == 'book'
              ? data.archiveReading
              : data.archiveAudio;
          totals[day] = (totals[day] ?? 0) + ms;
        }
      }
    }
    for (final completed in booksCompletedInYear(
      completedEntries ?? library?.visibleEntries ?? [],
      year,
    )) {
      final entry = completed.entry;
      final id = entry.sourceBookId ?? 'card:${entry.item.id}';
      data.books.putIfAbsent(
        id,
        () => CalendarBook(
          id,
          entry.item.title,
          entry.item.mediaType,
          entry,
          library?.coverPath(entry.item),
        ),
      );
      for (final date in completed.dates) {
        final day =
            '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
        (data.days[day] ??= {}).putIfAbsent(id, () => 0);
        (data.completedDays[day] ??= {}).add(id);
      }
    }
    return data;
  }
}
