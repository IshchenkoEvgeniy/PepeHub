import 'audio_journal.dart';

/// Derived from immutable intervals, so restoring logs reconstructs sessions.
class ListeningSession {
  final String bookId;
  final DateTime start;
  DateTime end;
  final String localDay;
  final int offsetMinutes;
  int wallMs = 0, mediaMs = 0, pauses = 0, seeks = 0;
  ListeningSession(
    this.bookId,
    this.start,
    this.end,
    this.localDay,
    this.offsetMinutes,
  );
  int get elapsedMs => end.difference(start).inMilliseconds;
}

class ListeningAnalytics {
  final AudioStats selected, lifetime;
  final List<ListeningSession> sessions;
  final int firstHeardMs, repeatedHistoryMs;
  final Map<String, AudioStats> byBook;
  ListeningAnalytics(
    this.selected,
    this.lifetime,
    this.sessions,
    this.firstHeardMs,
    this.repeatedHistoryMs,
    this.byBook,
  );

  int currentStreak(DateTime now) {
    var date = DateTime.utc(now.year, now.month, now.day);
    if (!lifetime.days.containsKey(dayKey(date))) {
      date = date.subtract(const Duration(days: 1));
    }
    var count = 0;
    while (lifetime.days.containsKey(dayKey(date))) {
      count++;
      date = date.subtract(const Duration(days: 1));
    }
    return count;
  }

  int timeBetween(DateTime start, DateTime end) => lifetime.days.entries
      .where(
        (e) =>
            e.key.compareTo(dayKey(start)) >= 0 &&
            e.key.compareTo(dayKey(end)) < 0,
      )
      .fold(0, (sum, e) => sum + e.value);
}

ListeningAnalytics analyzeListening(Map<String, dynamic> request) {
  final rangeStart = DateTime.tryParse(request['start'] as String? ?? '');
  final rangeEnd = DateTime.tryParse(request['end'] as String? ?? '');
  final events = <Map<String, dynamic>>[];
  for (final raw in List<Map<String, dynamic>>.from(
    request['events'] as List,
  )) {
    if (raw['kind'] != 'listen' || (rangeStart == null && rangeEnd == null)) {
      events.add(raw);
      continue;
    }
    final at = DateTime.parse(raw['at'] as String);
    final wall = (raw['wallMs'] as num).toInt();
    if (wall <= 0) {
      events.add(raw);
      continue;
    }
    final cuts = <int>{0, wall};
    for (final boundary in [rangeStart, rangeEnd]) {
      if (boundary == null) continue;
      final ms = boundary.difference(at).inMilliseconds;
      if (ms > 0 && ms < wall) cuts.add(ms);
    }
    final sorted = cuts.toList()..sort();
    final from = (raw['positionMs'] as num).toInt(),
        to = (raw['endMs'] as num).toInt();
    for (var i = 1; i < sorted.length; i++) {
      final start = at.add(Duration(milliseconds: sorted[i - 1]));
      final left = from + ((to - from) * sorted[i - 1] / wall).round();
      final right = from + ((to - from) * sorted[i] / wall).round();
      events.add({
        ...raw,
        'at': start.toUtc().toIso8601String(),
        'localDay': dayKey(
          start.toUtc().add(
            Duration(minutes: (raw['offsetMinutes'] as num?)?.toInt() ?? 0),
          ),
        ),
        'positionMs': left,
        'endMs': right,
        'mediaMs': right - left,
        'wallMs': sorted[i] - sorted[i - 1],
      });
    }
  }
  events.sort((a, b) => (a['at'] as String).compareTo(b['at'] as String));
  final book = request['book'] as String?;
  final cutoff = request['cutoff'] as String?;
  bool matches(Map<String, dynamic> e) =>
      (book == null || e['bookId'] == book) &&
      (cutoff == null || (e['localDay'] as String).compareTo(cutoff) >= 0) &&
      (rangeStart == null ||
          !DateTime.parse(e['at'] as String).isBefore(rangeStart)) &&
      (rangeEnd == null ||
          DateTime.parse(e['at'] as String).isBefore(rangeEnd));
  final filtered = events.where(matches).toList();
  final allBook = events
      .where((e) => book == null || e['bookId'] == book)
      .toList();
  final sessions = <ListeningSession>[];
  ListeningSession? active;
  final ranges = <String, List<(int, int)>>{};
  var firstHeard = 0, repeats = 0;
  for (final e in events) {
    if (!matches(e)) active = null;
    final at = DateTime.parse(e['at'] as String);
    if (active != null &&
        (e['bookId'] != active.bookId ||
            at.difference(active.end).inMilliseconds > 300000)) {
      active = null;
    }
    if (e['kind'] == 'listen') {
      final wall = (e['wallMs'] as num).toInt();
      final start = (e['positionMs'] as num).toInt();
      final end = (e['endMs'] as num).toInt();
      if (wall <= 0 || end <= start) continue;
      final until = at.add(Duration(milliseconds: wall));
      if (active == null && matches(e)) {
        active = ListeningSession(
          e['bookId'] as String,
          at,
          until,
          e['localDay'] as String,
          (e['offsetMinutes'] as num?)?.toInt() ?? 0,
        );
        sessions.add(active);
      }
      if (active != null) {
        if (until.isAfter(active.end)) active.end = until;
        active.wallMs += wall;
        active.mediaMs += end - start;
      }
      final key = '${e['bookId']}:${e['trackId']}';
      final previous = ranges.putIfAbsent(key, () => []);
      var overlap = 0;
      for (final r in previous) {
        final left = start > r.$1 ? start : r.$1;
        final right = end < r.$2 ? end : r.$2;
        if (right > left) overlap += right - left;
      }
      if (matches(e)) {
        firstHeard += end - start - overlap;
        repeats += overlap;
      }
      previous.add((start, end));
      previous.sort((a, b) => a.$1.compareTo(b.$1));
      final merged = <(int, int)>[];
      for (final r in previous) {
        if (merged.isEmpty || r.$1 > merged.last.$2) {
          merged.add(r);
        } else if (r.$2 > merged.last.$2) {
          merged[merged.length - 1] = (merged.last.$1, r.$2);
        }
      }
      ranges[key] = merged;
    } else if (active != null) {
      if (e['kind'] == 'pause') active.pauses++;
      if (e['kind'] == 'seek') active.seeks++;
      if (e['kind'] == 'stop' ||
          e['kind'] == 'completed' ||
          e['kind'] == 'sleep_fired') {
        active = null;
      }
    }
  }
  final grouped = <String, List<Map<String, dynamic>>>{};
  for (final e in filtered) {
    grouped.putIfAbsent(e['bookId'] as String, () => []).add(e);
  }
  return ListeningAnalytics(
    AudioStats(filtered),
    AudioStats(allBook),
    sessions
        .where(
          (s) =>
              (book == null || s.bookId == book) &&
              (cutoff == null || s.localDay.compareTo(cutoff) >= 0),
        )
        .toList()
        .reversed
        .toList(),
    firstHeard,
    repeats,
    {for (final e in grouped.entries) e.key: AudioStats(e.value)},
  );
}
