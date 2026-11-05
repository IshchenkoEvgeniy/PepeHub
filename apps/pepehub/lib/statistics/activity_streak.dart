import '../library/library_dates.dart';

const activityStreakMinimumMs = 5 * 60 * 1000;

/// Saved local calendar days, not UTC instants. Calendar arithmetic is done
/// in UTC solely to avoid 23/25-hour DST days breaking adjacency.
/// Today may still be in progress; yesterday preserves the current streak.
({int current, int best}) activityStreak(
  Map<String, int> days,
  DateTime now, {
  int minimumMs = activityStreakMinimumMs,
  int? year,
}) {
  final local = now.toLocal();
  final today = DateTime.utc(local.year, local.month, local.day);
  final qualified = <DateTime>{};
  for (final e in days.entries) {
    if (e.value < minimumMs || e.value <= 0) continue;
    final date = libraryDate(e.key);
    if (date == null || (year != null && date.year != year)) continue;
    final day = DateTime.utc(date.year, date.month, date.day);
    if (!day.isAfter(today)) qualified.add(day);
  }
  final sorted = qualified.toList()..sort();
  var best = 0, run = 0;
  DateTime? previous;
  for (final date in sorted) {
    run = previous != null && date.difference(previous).inDays == 1
        ? run + 1
        : 1;
    if (run > best) best = run;
    previous = date;
  }
  if (year != null && year != local.year) return (current: 0, best: best);
  var at = qualified.contains(today)
      ? today
      : today.subtract(const Duration(days: 1));
  var current = 0;
  while (qualified.contains(at)) {
    current++;
    at = at.subtract(const Duration(days: 1));
  }
  return (current: current, best: best);
}
