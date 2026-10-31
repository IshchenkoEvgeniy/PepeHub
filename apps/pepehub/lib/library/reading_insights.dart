import 'models.dart';
import 'library_features.dart';
import 'personal_library.dart';

const bookMonths = [
  'Январь',
  'Февраль',
  'Март',
  'Апрель',
  'Май',
  'Июнь',
  'Июль',
  'Август',
  'Сентябрь',
  'Октябрь',
  'Ноябрь',
  'Декабрь',
];

DateTime? bookDate(dynamic value) {
  final text = '${value ?? ''}'.trim();
  if (text.isEmpty) return null;
  final iso = DateTime.tryParse(text);
  if (iso != null) return text.contains('T') ? iso.toLocal() : iso;
  final parts = text.split('.').map(int.tryParse).toList();
  if (parts.length != 3 || parts.any((p) => p == null)) return null;
  final date = DateTime(parts[2]!, parts[1]!, parts[0]!);
  return date.year == parts[2] && date.month == parts[1] && date.day == parts[0]
      ? date
      : null;
}

String bookDateLabel(dynamic value) {
  final date = bookDate(value);
  if (date == null) return 'Не указана';
  return '${date.day.toString().padLeft(2, '0')}.'
      '${date.month.toString().padLeft(2, '0')}.${date.year}';
}

String bookActivityTime(num ms) {
  if (ms <= 0) return '0 мин';
  if (ms < 60000) return '< 1 мин';
  final minutes = ms ~/ 60000;
  return minutes < 60
      ? '$minutes мин'
      : '${minutes ~/ 60} ч ${minutes % 60} мин';
}

String bookAmount(num value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toStringAsFixed(1);

/// A view only: original intervals remain editable and keep their sync IDs.
class BookActivityDay {
  final String day, itemId;
  final List<Map<String, dynamic>> slots = [];
  final Map<String, num> progress = {};
  int durationMs = 0;
  BookActivityDay(this.day, this.itemId);
  String get progressLabel => progress.entries
      .where((e) => e.value > 0 && e.key != 'unknown')
      .map(
        (e) => e.key == 'minutes'
            ? '${bookActivityTime(e.value * 60000)} аудио'
            : '${bookAmount(e.value)} ${e.key == 'pages' ? 'стр.' : 'симв.'}',
      )
      .join(' · ');
}

List<BookActivityDay> groupBookActivity(Iterable<Map<String, dynamic>> slots) {
  final groups = <(String, String), BookActivityDay>{};
  for (final slot in slots) {
    final value = slot['value'] as Map;
    if (value['deleted'] == true && slot['conflict'] == null) continue;
    final duration = (value['durationMs'] as num? ?? 0).toInt();
    final progress = value['progress'] as num? ?? 0;
    if (duration <= 0 &&
        progress <= 0 &&
        slot['conflict'] == null &&
        '${value['note'] ?? ''}'.trim().isEmpty) {
      continue;
    }
    final day = '${value['day']}', id = '${value['itemId']}';
    final group = groups.putIfAbsent((day, id), () => BookActivityDay(day, id));
    group.slots.add(slot);
    if (value['deleted'] == true) continue;
    group.durationMs += duration;
    final unit = '${value['unit'] ?? 'unknown'}';
    group.progress[unit] = (group.progress[unit] ?? 0) + progress;
  }
  return groups.values.toList()..sort((a, b) {
    final date = b.day.compareTo(a.day);
    return date != 0 ? date : a.itemId.compareTo(b.itemId);
  });
}

class YearBook {
  final LibraryEntry entry;
  final DateTime date;
  final List<DateTime> dates;
  int get completions => dates.length;
  const YearBook(this.entry, this.date, this.dates);
  double? get rating {
    final n = double.tryParse('${entry.item.value('rating') ?? ''}');
    return n != null && n.isFinite && n >= 0 && n <= 10 ? n : null;
  }
}

/// One card per year; repeated completions are counted separately, without
/// multiplying page totals or rating votes. Unknown dates never mean "today".
List<YearBook> booksCompletedInYear(
  Iterable<LibraryEntry> entries,
  int year, {
  String scope = 'all',
}) {
  final result = <YearBook>[];
  for (final entry in entries) {
    final item = entry.item;
    if (!isLibraryArchiveItem(item) ||
        isLibraryDeleted(item) ||
        (scope == 'reading' && item.mediaType != 'book') ||
        (scope == 'audio' && item.mediaType != 'audiobook')) {
      continue;
    }
    final dates = <DateTime>[];
    void add(dynamic raw, {bool mirror = false}) {
      final date = bookDate(raw);
      if (date == null || date.year != year) return;
      if (mirror &&
          dates.any(
            (d) =>
                d.year == date.year &&
                d.month == date.month &&
                d.day == date.day,
          )) {
        return;
      }
      dates.add(date);
    }

    for (final completion
        in (item.values['pepehub_completions'] as List? ?? [])) {
      if (completion is Map) add(completion['date']);
    }
    if (libraryStatus(item) == 'finished') {
      add(item.value('endDate'), mirror: true);
    }
    if (dates.isEmpty) continue;
    dates.sort();
    result.add(YearBook(entry, dates.last, List.unmodifiable(dates)));
  }
  return result..sort((a, b) => b.date.compareTo(a.date));
}
