import '../library/metadata_values.dart';
import '../library/reading_insights.dart';

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
