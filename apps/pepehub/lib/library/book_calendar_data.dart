import 'package:drift/drift.dart' show Variable;

import '../audio/audio_journal.dart';
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
        record.title,
        record.payload?['format'] == 'audio' ? 'audiobook' : 'book',
        entry,
        entry == null ? coverByBook[record.id] : library?.coverPath(entry.item),
      );
    }
    final summary =
        readingSummary ??
        await compute<Map<String, dynamic>, ReadingCalendarSummary>(
          summarizeReadingCalendar,
          <String, dynamic>{'sessions': reading, 'year': year},
        );
    for (final book in summary.bookDays.entries) {
      for (final e in book.value.entries) {
        if (e.key.startsWith('$year-')) {
          data.add(e.key, book.key, e.value);
        }
      }
    }
    final audio = await repository.db
        .customSelect(
          'SELECT day,book_id,wall_ms FROM audio_daily_totals_v1 WHERE day>=? AND day<? AND wall_ms>0',
          variables: [Variable('$year-01-01'), Variable('${year + 1}-01-01')],
        )
        .get();
    for (final row in audio) {
      data.add(
        row.read<String>('day'),
        row.read<String>('book_id'),
        row.read<int>('wall_ms'),
      );
    }
    final audioGroups = <String, List<Map<String, dynamic>>>{};
    for (final event in foreignAudio) {
      (audioGroups['${event['bookId']}'] ??= []).add(event);
    }
    for (final group in audioGroups.entries) {
      for (final day in AudioStats(group.value).days.entries) {
        if (day.key.startsWith('$year-')) {
          data.add(day.key, group.key, day.value);
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
        for (final slot in await library.history!.entries()) {
          final v = slot['value'] as Map;
          if (v['deleted'] == true || !standalone.containsKey(v['itemId'])) {
            continue;
          }
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
      for (final completed in booksCompletedInYear(
        library.visibleEntries,
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
            library.coverPath(entry.item),
          ),
        );
        for (final date in completed.dates) {
          final day =
              '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
          (data.days[day] ??= {}).putIfAbsent(id, () => 0);
          (data.completedDays[day] ??= {}).add(id);
        }
      }
    }
    return data;
  }
}
