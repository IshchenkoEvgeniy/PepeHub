import '../library/models.dart';
import '../library/metadata_values.dart';
import '../library/reading_insights.dart';
import 'activity_streak.dart';

class AnnualCategory {
  final String label;
  final int books, completions;
  const AnnualCategory(this.label, this.books, this.completions);
}

/// Each work contributes once to every named category; page totals and rating
/// votes are never multiplied by rereads or by the number of its genres.
List<AnnualCategory> annualCategories(List<YearBook> books, String field) {
  final counts = <String, (String, int, int)>{};
  for (final book in books) {
    final labels = metadataStrings(book.entry.item.value(field));
    final unique = <String, String>{};
    for (final label in labels) {
      final text = label.trim();
      if (text.isNotEmpty) unique.putIfAbsent(text.toLowerCase(), () => text);
    }
    if (unique.isEmpty) {
      unique[''] = field == 'series' ? 'Без серии' : 'Не указано';
    }
    for (final e in unique.entries) {
      final prior = counts[e.key];
      counts[e.key] = (
        prior?.$1 ?? e.value,
        (prior?.$2 ?? 0) + 1,
        (prior?.$3 ?? 0) + book.completions,
      );
    }
  }
  return [
    for (final value in counts.values)
      AnnualCategory(value.$1, value.$2, value.$3),
  ]..sort((a, b) {
    final count = b.books.compareTo(a.books);
    return count != 0 ? count : a.label.compareTo(b.label);
  });
}

class AnnualSummary {
  final int year;
  final String scope;
  final List<YearBook> books;
  final Map<String, int> days, activityDays, bookTimes;
  final Map<String, String> titles;
  AnnualSummary({
    required this.year,
    required this.scope,
    required Iterable<LibraryEntry> entries,
    required Map<String, int> readingDays,
    required Map<String, int> audioDays,
    required Map<String, int> audioActivityDays,
    this.bookTimes = const {},
    this.titles = const {},
  }) : books = booksCompletedInYear(entries, year, scope: scope),
       days = _merge(year, scope, readingDays, audioDays),
       activityDays = _merge(year, scope, readingDays, audioActivityDays);
  static Map<String, int> _merge(
    int year,
    String scope,
    Map<String, int> reading,
    Map<String, int> audio,
  ) {
    final result = <String, int>{};
    for (final source in [
      if (scope != 'audio') reading,
      if (scope != 'reading') audio,
    ]) {
      for (final e in source.entries) {
        if (e.key.startsWith('$year-')) {
          result[e.key] = (result[e.key] ?? 0) + e.value;
        }
      }
    }
    return Map.unmodifiable(result);
  }

  int get completions => books.fold(0, (sum, b) => sum + b.completions);
  int get milliseconds => days.values.fold(0, (a, b) => a + b);
  int get activeDays => activityDays.values.where((v) => v > 0).length;
  MapEntry<String, int>? get longestDay {
    final values = activityDays.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) {
        final time = b.value.compareTo(a.value);
        return time == 0 ? a.key.compareTo(b.key) : time;
      });
    return values.firstOrNull;
  }

  int bestStreak(DateTime now) =>
      activityStreak(activityDays, now, year: year).best;
  List<YearBook> get bestBooks =>
      books.where((b) => b.rating != null).toList()..sort((a, b) {
        final score = b.rating!.compareTo(a.rating!);
        return score == 0
            ? a.entry.item.title.compareTo(b.entry.item.title)
            : score;
      });
  AnnualCategory? get favoriteGenre => annualCategories(
    books,
    'genre',
  ).where((c) => c.label != 'Не указано').firstOrNull;
}
