import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';

import '../data/repository.dart';
import 'reading_activity.dart';
import 'reading_library.dart';

class ReadingPlan {
  final int dailyMinutes, targetPercent;
  final DateTime? deadline;
  const ReadingPlan({
    this.dailyMinutes = 20,
    this.targetPercent = 100,
    this.deadline,
  });
  factory ReadingPlan.fromJson(Map<String, dynamic> json) => ReadingPlan(
    dailyMinutes: ((json['dailyMinutes'] as num?)?.toInt() ?? 20).clamp(
      1,
      1440,
    ),
    targetPercent: ((json['targetPercent'] as num?)?.toInt() ?? 100).clamp(
      1,
      100,
    ),
    deadline: DateTime.tryParse(json['deadline'] as String? ?? ''),
  );
  Map<String, dynamic> toJson() => {
    'version': 1,
    'dailyMinutes': dailyMinutes,
    'targetPercent': targetPercent,
    'deadline': deadline == null ? null : readingDay(deadline!),
  };
}

class ReadingForecast {
  final int? targetChars, remainingChars;
  final int coveredChars, todayMs, sampleMs, sampleChars, sampleMoves;
  final double? charsPerMinute;
  final int? remainingMinutes, minutesPerDay;
  final DateTime? expectedDate;
  final bool overdue;
  const ReadingForecast({
    required this.targetChars,
    required this.remainingChars,
    required this.coveredChars,
    required this.todayMs,
    required this.sampleMs,
    required this.sampleChars,
    required this.sampleMoves,
    required this.charsPerMinute,
    required this.remainingMinutes,
    required this.minutesPerDay,
    required this.expectedDate,
    required this.overdue,
  });
  bool get complete => remainingChars == 0;
}

/// Coverage, not the current slider position: skipped sections remain unread.
ReadingForecast forecastReading({
  required ReadingPlan plan,
  required String bookId,
  required String? hash,
  required int length,
  required List<List<int>> coverage,
  required Iterable<Map<String, dynamic>> sessions,
  required DateTime now,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final rows = sessions
      .where(
        (s) =>
            s['bookId'] == bookId &&
            s['source'] != 'manual' &&
            (hash == null || s['hash'] == hash),
      )
      .toList();
  final todayMs = readingTotals(
    rows,
    start: today,
    end: now,
    bookId: bookId,
  ).milliseconds;
  int sampleMs = 0, sampleChars = 0, sampleMoves = 0;
  if (hash != null) {
    for (final s in rows.where((s) => s['speedVersion'] == 1)) {
      final ms = (s['speedActiveMs'] as num?)?.toInt() ?? 0;
      final chars = (s['speedChars'] as num?)?.toInt() ?? 0;
      final moves = (s['speedMoves'] as num?)?.toInt() ?? 0;
      if (ms <= 0 || chars <= 0 || moves <= 0) continue;
      sampleMs += ms;
      sampleChars += chars;
      sampleMoves += moves;
    }
  }
  final double? rate =
      sampleMs >= 60000 && sampleChars >= 300 && sampleMoves >= 2
      ? sampleChars * 60000 / sampleMs
      : null;
  final target = length > 0 ? (length * plan.targetPercent / 100).ceil() : null;
  final covered = target == null
      ? 0
      : mergeReadingRanges([
          for (final r in coverage)
            if (r.length == 2) [r[0].clamp(0, target), r[1].clamp(0, target)],
        ]).fold<int>(0, (sum, r) => sum + r[1] - r[0]);
  final remaining = target == null ? null : target - covered;
  final minutes = remaining == 0
      ? 0
      : remaining != null && rate != null
      ? (remaining / rate).ceil()
      : null;
  final deadline = plan.deadline;
  final overdue =
      deadline != null &&
      DateTime(deadline.year, deadline.month, deadline.day).isBefore(today) &&
      remaining != 0;
  final days = deadline == null
      ? null
      : math.max(
          1,
          DateTime.utc(deadline.year, deadline.month, deadline.day)
                  .difference(DateTime.utc(today.year, today.month, today.day))
                  .inDays +
              1,
        );
  // Today's completed effort consumes today's budget. Rereading still counts
  // toward the daily time goal, but does not reduce uncovered target text.
  final untilMidnight =
      DateTime(
        today.year,
        today.month,
        today.day + 1,
      ).difference(now).inMilliseconds /
      60000;
  final todayBudget = math.min(
    untilMidnight,
    math.max(0.0, plan.dailyMinutes - todayMs / 60000),
  );
  final extraDays = minutes == null
      ? null
      : math.max(0, ((minutes - todayBudget) / plan.dailyMinutes).ceil());
  return ReadingForecast(
    targetChars: target,
    remainingChars: remaining,
    coveredChars: covered,
    todayMs: todayMs,
    sampleMs: sampleMs,
    sampleChars: sampleChars,
    sampleMoves: sampleMoves,
    charsPerMinute: rate,
    remainingMinutes: minutes,
    minutesPerDay: days != null && minutes != null && !overdue
        ? (minutes / days).ceil()
        : null,
    expectedDate: extraDays == null
        ? null
        : DateTime(today.year, today.month, today.day + extraDays),
    overdue: overdue,
  );
}

class ReadingPlanData {
  final String title;
  final String? hash;
  final int length;
  final ReadingPlan? saved;
  final List<List<int>> coverage;
  final List<Map<String, dynamic>> sessions;
  const ReadingPlanData({
    required this.title,
    required this.hash,
    required this.length,
    required this.saved,
    required this.coverage,
    required this.sessions,
  });
}

class ReadingPlans {
  final Repository repository;
  ReadingPlans(this.repository);
  Future<ReadingPlanData> load(String bookId) async {
    final library = ReadingLibrary(repository);
    final book = await repository.record(bookId);
    if (book == null || book.payload?['format'] == 'audio') {
      throw StateError('Текстовая книга не найдена');
    }
    final asset = await repository.db
        .customSelect(
          'SELECT sha256 FROM local_assets WHERE book_id=? LIMIT 1',
          variables: [Variable(bookId)],
        )
        .getSingleOrNull();
    final hash = asset?.read<String>('sha256');
    final index = hash == null
        ? <String, dynamic>{}
        : await library.value('reading-index:$hash');
    final info = await library.bookInfo(book, hash);
    final raw = await repository.meta('reading-plan:$bookId');
    final ranges = hash == null
        ? <String, dynamic>{}
        : await library.value('reading-coverage:$hash');
    return ReadingPlanData(
      title: info['title'] as String? ?? book.title,
      hash: hash,
      length: (index['length'] as num?)?.toInt() ?? 0,
      saved: raw == null
          ? null
          : ReadingPlan.fromJson(jsonDecode(raw) as Map<String, dynamic>),
      coverage: [
        for (final r in ranges['ranges'] as List? ?? [])
          [(r[0] as num).toInt(), (r[1] as num).toInt()],
      ],
      sessions: (await library.entries('reading-session:')).values
          .where((s) => s['bookId'] == bookId)
          .toList(),
    );
  }

  Future<void> save(String bookId, ReadingPlan plan) async {
    if (plan.dailyMinutes < 1 ||
        plan.dailyMinutes > 1440 ||
        plan.targetPercent < 1 ||
        plan.targetPercent > 100) {
      throw ArgumentError('Укажите 1–1440 минут в день и цель от 1 до 100%.');
    }
    final book = await repository.record(bookId);
    if (book == null || book.payload?['format'] == 'audio') {
      throw StateError('Текстовая книга не найдена');
    }
    await repository.setMeta('reading-plan:$bookId', jsonEncode(plan.toJson()));
  }

  Future<void> remove(String bookId) => repository.db.customStatement(
    'DELETE FROM metadata WHERE key=?',
    ['reading-plan:$bookId'],
  );
}
