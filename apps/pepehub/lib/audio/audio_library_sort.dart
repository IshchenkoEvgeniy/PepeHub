import '../data/repository.dart';
import 'audio_import.dart';

typedef AudioBookSummary = ({int? total, int? position, double speed});

/// Unknown durations/progress are always last, independent of direction.
int compareAudioBooks(
  LibraryRecord a,
  LibraryRecord b, {
  required String order,
  required Map<String, AudioBookSummary> summaries,
  required Map<String, DateTime> recent,
}) {
  double? fraction(LibraryRecord book) {
    final summary = summaries[book.id];
    if (summary?.total == null || summary!.total! <= 0) return null;
    return ((summary.position ?? 0) / summary.total!).clamp(0.0, 1.0);
  }

  int nullable(num? x, num? y, {bool descending = false}) {
    if (x == null) return y == null ? 0 : 1;
    if (y == null) return -1;
    return descending ? y.compareTo(x) : x.compareTo(y);
  }

  String author(LibraryRecord book) =>
      (book.payload?['authors'] as List? ?? []).join(', ').toLowerCase();
  final result = switch (order) {
    'added' => nullable(a.localOrder, b.localOrder, descending: true),
    'author' => author(a).compareTo(author(b)),
    'progress' => nullable(fraction(a), fraction(b), descending: true),
    'duration' || 'duration-desc' => nullable(
      summaries[a.id]?.total,
      summaries[b.id]?.total,
      descending: order == 'duration-desc',
    ),
    'recent' => nullable(
      recent[a.id]?.millisecondsSinceEpoch,
      recent[b.id]?.millisecondsSinceEpoch,
      descending: true,
    ),
    _ => naturalAudioOrder(a.title, b.title),
  };
  if (result != 0) return result;
  final title = naturalAudioOrder(a.title, b.title);
  return title != 0 ? title : a.id.compareTo(b.id);
}

String? audioRemainingLabel(AudioBookSummary? summary) {
  final total = summary?.total;
  if (summary == null ||
      total == null ||
      total <= 0 ||
      summary.position == null) {
    return null;
  }
  final remaining = total - (summary.position ?? 0).clamp(0, total);
  if (remaining == 0) return 'Прослушано полностью';
  final speed = summary.speed.isFinite && summary.speed > 0 ? summary.speed : 1;
  final minutes = (remaining / speed / 60000).ceil();
  final time = minutes >= 60
      ? '${minutes ~/ 60} ч${minutes % 60 == 0 ? '' : ' ${minutes % 60} мин'}'
      : '$minutes мин';
  return 'Осталось $time${speed == 1 ? '' : ' на $speed×'}';
}
