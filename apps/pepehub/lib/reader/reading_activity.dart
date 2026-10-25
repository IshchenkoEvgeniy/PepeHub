import 'dart:async';
import 'dart:convert';

import '../data/repository.dart';
import 'reading_library.dart';

/// Counts interaction-based reading, never claims eye tracking.
class ReadingActivity {
  final Repository repository;
  final String bookId, hash;
  final int length;
  final DateTime Function() clock;
  final void Function(Object)? onError;
  final Future<void> Function(Map<String, dynamic>)? export;
  final String id = uuid.v4();
  final List<Map<String, dynamic>> spans = [], events = [];
  List<List<int>> coverage = [];
  Map<String, dynamic>? span;
  late DateTime started, lastTouch, accounted, positionAt;
  DateTime? lastCheckpoint;
  DateTime? lastExport;
  int position = 0, fresh = 0, repeated = 0;
  int sampleActiveMs = 0, speedActiveMs = 0, speedChars = 0, speedMoves = 0;
  bool sampleEligible = true;
  bool reachedEnd = false;
  bool suspended = false, idle = false, closed = false;
  Timer? timer;
  Timer? jumpCheckpoint;
  Future<void> writes = Future.value();
  static const idleLimit = Duration(minutes: 2);
  ReadingActivity(
    this.repository, {
    required this.bookId,
    required this.hash,
    required this.length,
    DateTime Function()? clock,
    this.onError,
    this.export,
  }) : clock = clock ?? DateTime.now;

  Future<void> start(int offset, {bool runTimer = true}) async {
    final stored = await ReadingLibrary(repository)
        .value('reading-coverage:$hash');
    coverage = [
      for (final r in stored['ranges'] as List? ?? [])
        [(r[0] as num).toInt(), (r[1] as num).toInt()],
    ];
    started = lastTouch = accounted = positionAt = clock();
    position = offset;
    _event('start', started);
    _begin(started);
    await checkpoint();
    if (runTimer) {
      timer = Timer.periodic(const Duration(seconds: 5), (_) {
        tick();
        if (!suspended &&
            !idle &&
            (lastCheckpoint == null ||
                clock().difference(lastCheckpoint!).inSeconds >= 30)) {
          checkpoint();
        }
      });
    }
  }

  void _begin(DateTime at) {
    span = {
      'start': at.toUtc().toIso8601String(),
      'end': at.toUtc().toIso8601String(),
      'newChars': 0,
      'repeatChars': 0,
      'localDay': readingDay(at),
      'offsetMinutes': at.timeZoneOffset.inMinutes,
    };
    spans.add(span!);
    accounted = at;
  }

  void _event(
    String kind,
    DateTime at, [
    Map<String, dynamic> data = const {},
  ]) {
    events.add({
      'kind': kind,
      'at': at.toUtc().toIso8601String(),
      'position': position,
      ...data,
    });
  }

  void tick() {
    if (closed || suspended || idle) return;
    final now = clock();
    final deadline = lastTouch.add(idleLimit);
    final until = now.isAfter(deadline) ? deadline : now;
    if (until.isAfter(accounted)) {
      if (sampleEligible) {
        sampleActiveMs += until.difference(accounted).inMilliseconds;
      }
      // Split at local midnight so daily totals stay exact across DST.
      while (!DateTime(
        accounted.year,
        accounted.month,
        accounted.day + 1,
      ).isAfter(until)) {
        final midnight = DateTime(
          accounted.year,
          accounted.month,
          accounted.day + 1,
        );
        span!['end'] = midnight.toUtc().toIso8601String();
        _begin(midnight);
      }
      span!['end'] = until.toUtc().toIso8601String();
      accounted = until;
    }
    if (!now.isBefore(deadline)) {
      sampleEligible = false;
      sampleActiveMs = 0;
      idle = true;
      span = null;
      _event('idle', deadline);
      checkpoint(significant: true);
    }
  }

  void touch() {
    if (closed || suspended) return;
    tick();
    final now = clock();
    if (idle) {
      idle = false;
      positionAt = now;
      _begin(now);
      _event('resume', now);
    }
    lastTouch = now;
  }

  void move(
    int to, {
    bool jump = false,
    bool chapterEnded = false,
    bool deferCheckpoint = false,
  }) {
    if (closed) return;
    tick();
    to = to.clamp(0, length);
    final now = clock(),
        seconds = clock().difference(positionAt).inMilliseconds / 1000;
    final delta = to - position;
    // Fast page flipping and deliberate jumps do not imply reading skipped text.
    if (!jump &&
        !suspended &&
        !idle &&
        seconds >= 2 &&
        delta > 0 &&
        delta <= (seconds * 100).clamp(3000, 20000)) {
      var overlap = 0;
      for (final r in coverage) {
        overlap += (r[1].clamp(position, to) - r[0].clamp(position, to));
      }
      fresh += delta - overlap;
      repeated += overlap;
      // Pair text only with its own uninterrupted active interval. Never use
      // time spent before a jump, in panels, or in a partial page after resume.
      if (sampleEligible && sampleActiveMs >= 2000) {
        speedChars += delta;
        speedActiveMs += sampleActiveMs;
        speedMoves++;
      }
      span?['newChars'] = (span?['newChars'] as int? ?? 0) + delta - overlap;
      span?['repeatChars'] = (span?['repeatChars'] as int? ?? 0) + overlap;
      coverage = mergeReadingRanges([
        ...coverage,
        [position, to],
      ]);
      if (to == length) reachedEnd = true;
      if (chapterEnded) _event('chapter_end', now);
    }
    if (jump) _event('jump', now, {'to': to});
    position = to;
    positionAt = now;
    sampleActiveMs = 0;
    sampleEligible = !suspended;
    touch();
    if (jump || chapterEnded) {
      if (deferCheckpoint) {
        jumpCheckpoint?.cancel();
        jumpCheckpoint = Timer(
          const Duration(milliseconds: 350),
          () => checkpoint(significant: true),
        );
      } else {
        checkpoint(significant: true);
      }
    }
  }

  Future<void> pause(String reason) async {
    if (closed || suspended) return;
    tick();
    suspended = true;
    sampleEligible = false;
    sampleActiveMs = 0;
    span = null;
    _event('pause', clock(), {'reason': reason});
    await checkpoint(significant: true);
  }

  void resume() {
    if (closed || !suspended) return;
    suspended = false;
    idle = false;
    sampleEligible = false;
    sampleActiveMs = 0;
    lastTouch = accounted = positionAt = clock();
    _begin(accounted);
    _event('resume', accounted);
  }

  Future<void> close() async {
    if (closed) return writes;
    tick();
    closed = true;
    timer?.cancel();
    span = null;
    _event('end', clock());
    await checkpoint(significant: true);
  }

  Map<String, dynamic> snapshot() => {
    'id': id,
    'bookId': bookId,
    'hash': hash,
    'startedAt': started.toUtc().toIso8601String(),
    'endedAt': accounted.toUtc().toIso8601String(),
    'closed': closed,
    'position': position,
    'length': length,
    'newChars': fresh,
    'repeatChars': repeated,
    'speedVersion': 1,
    'speedActiveMs': speedActiveMs,
    'speedChars': speedChars,
    'speedMoves': speedMoves,
    'spans': spans,
    'events': events,
  };
  Future<void> checkpoint({bool significant = false}) {
    jumpCheckpoint?.cancel();
    jumpCheckpoint = null;
    lastCheckpoint = clock();
    final json = jsonEncode(snapshot()),
        ranges = jsonEncode({'ranges': coverage});
    final activityStart = spans
        .where(
          (s) =>
              DateTime.parse(s['end'] as String)
                  .isAfter(DateTime.parse(s['start'] as String)),
        )
        .firstOrNull?['start'];
    final finished = reachedEnd;
    final finishedAt = accounted.toUtc().toIso8601String();
    final next = writes.then((_) async {
      await repository.db.transaction(() async {
        await repository.setMeta('reading-session:$id', json);
        await repository.setMeta('reading-coverage:$hash', ranges);
        final library = ReadingLibrary(repository);
        final dates = await library.value('reading-dates:$bookId');
        await library.update('reading-dates:$bookId', {
          if (activityStart != null && dates['startedAt'] == null)
            'startedAt': activityStart,
          if (finished && dates['finishedAt'] == null) 'finishedAt': finishedAt,
        });
      });
      if (export != null &&
          (significant ||
              lastExport == null ||
              clock().difference(lastExport!) >= const Duration(seconds: 30))) {
        await export!(jsonDecode(json) as Map<String, dynamic>);
        lastExport = clock();
      }
    });
    writes = next.catchError((Object e) {
      onError?.call(e);
    });
    return writes;
  }
}

/// Coalesces rapid position reports (scroll updates, page animations) into
/// one move once the text has been still for [delay]. Without this, every
/// 250 ms update inside a gesture resets [ReadingActivity.move]'s two-second
/// reading window and most of the scrolled text is never counted.
class SettledReadingMoves {
  final void Function(int position) onMove;
  final Duration delay;
  Timer? _timer;
  int? _pending;
  SettledReadingMoves(
    this.onMove, {
    this.delay = const Duration(milliseconds: 400),
  });

  void add(int position) {
    _pending = position;
    _timer?.cancel();
    _timer = Timer(delay, flush);
  }

  /// Reports a pending position now, e.g. before a jump, a panel or closing.
  void flush() {
    _timer?.cancel();
    _timer = null;
    final pending = _pending;
    _pending = null;
    if (pending != null) onMove(pending);
  }
}

List<List<int>> mergeReadingRanges(List<List<int>> ranges) {
  final sorted = [
    for (final r in ranges) [...r],
  ]..sort((a, b) => a[0].compareTo(b[0]));
  final result = <List<int>>[];
  for (final r in sorted) {
    if (r[1] <= r[0]) continue;
    if (result.isEmpty || result.last[1] < r[0]) {
      result.add(r);
    } else if (r[1] > result.last[1]) {
      result.last[1] = r[1];
    }
  }
  return result;
}

String readingDay(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

class ReadingTotals {
  int milliseconds = 0, newChars = 0, repeatChars = 0, sessions = 0;
  final Map<String, int> days = {}, books = {};
  void add(String id, DateTime from, DateTime to, int ms) {
    if (!to.isAfter(from) || ms <= 0) return;
    milliseconds += ms;
    books[id] = (books[id] ?? 0) + ms;
    var at = from.toLocal();
    final end = to.toLocal();
    while (at.isBefore(end)) {
      final midnight = DateTime(at.year, at.month, at.day + 1);
      final until = midnight.isBefore(end) ? midnight : end;
      final part =
          (ms *
                  until.difference(at).inMicroseconds /
                  to.difference(from).inMicroseconds)
              .round();
      final key = readingDay(at);
      days[key] = (days[key] ?? 0) + part;
      at = until;
    }
  }
}

ReadingTotals readingTotals(
  List<Map<String, dynamic>> sessions, {
  DateTime? start,
  DateTime? end,
  String? bookId,
}) {
  final totals = ReadingTotals();
  for (final session in sessions) {
    final id = session['bookId'] as String;
    if (bookId != null && id != bookId) continue;
    var included = false;
    for (final s in session['spans'] as List? ?? []) {
      if (s['pepehubDeleted'] == true) continue;
      final a = DateTime.parse(s['start'] as String),
          b = DateTime.parse(s['end'] as String);
      final from = start != null && start.isAfter(a) ? start : a;
      final to = end != null && end.isBefore(b) ? end : b;
      if (!to.isAfter(from) || !b.isAfter(a)) continue;
      final fraction =
          to.difference(from).inMicroseconds / b.difference(a).inMicroseconds;
      final ms = s['activeMs'] as int? ?? b.difference(a).inMilliseconds;
      if (s['localDay'] is String) {
        final part = (ms * fraction).round();
        totals.milliseconds += part;
        totals.books[id] = (totals.books[id] ?? 0) + part;
        final key = s['localDay'] as String;
        totals.days[key] = (totals.days[key] ?? 0) + part;
      } else {
        totals.add(id, from, to, (ms * fraction).round());
      }
      totals.newChars += ((s['newChars'] as num? ?? 0) * fraction).round();
      totals.repeatChars += ((s['repeatChars'] as num? ?? 0) * fraction)
          .round();
      included = true;
    }
    if (included) totals.sessions++;
  }
  return totals;
}

({int current, int best}) readingStreak(Map<String, int> days, DateTime now) {
  final dates =
      days.entries
          .where((e) => e.value > 0)
          .map((e) => DateTime.parse(e.key))
          .toList()
        ..sort();
  int best = 0, run = 0;
  DateTime? prior;
  for (final date in dates) {
    run =
        prior != null &&
            date == DateTime(prior.year, prior.month, prior.day + 1)
        ? run + 1
        : 1;
    if (run > best) best = run;
    prior = date;
  }
  var at = DateTime(now.year, now.month, now.day), current = 0;
  if ((days[readingDay(at)] ?? 0) == 0) {
    at = DateTime(at.year, at.month, at.day - 1);
  }
  while ((days[readingDay(at)] ?? 0) > 0) {
    current++;
    at = DateTime(at.year, at.month, at.day - 1);
  }
  return (current: current, best: best);
}
