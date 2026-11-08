import '../library/library_dates.dart';

/// Russian plural word for [n]: «1 день», «3 дня», «11 дней».
String ruPlural(int n, String one, String few, String many) {
  final last = n.abs() % 10, lastTwo = n.abs() % 100;
  if (last == 1 && lastTwo != 11) return one;
  if (last >= 2 && last <= 4 && (lastTwo < 12 || lastTwo > 14)) return few;
  return many;
}

int _daysInYear(int year) =>
    DateTime.utc(year + 1).difference(DateTime.utc(year)).inDays;

/// Days of [year] that have passed by [now], counting today. A past year is
/// complete, a future one has not started.
int elapsedDaysOfYear(int year, DateTime now) {
  final local = now.toLocal();
  if (year < local.year) return _daysInYear(year);
  if (year > local.year) return 0;
  return DateTime.utc(
        local.year,
        local.month,
        local.day,
      ).difference(DateTime.utc(year)).inDays +
      1;
}

/// The same calendar moment one year earlier, for "this year so far" versus
/// "last year by this date". Null for a past year: compare whole years.
DateTime? comparisonCutoff(int year, DateTime now) {
  final local = now.toLocal();
  if (year != local.year) return null;
  return DateTime(local.year, local.month, local.day);
}

bool _onOrBefore(DateTime date, DateTime? cutoff) =>
    cutoff == null ||
    date.month < cutoff.month ||
    (date.month == cutoff.month && date.day <= cutoff.day);

/// Sum of saved local days in [year]; with [cutoff] only up to its month/day.
int sumDaysInYear(Map<String, int> days, int year, {DateTime? cutoff}) {
  var total = 0;
  for (final e in days.entries) {
    final date = libraryDate(e.key);
    if (date == null || date.year != year || !_onOrBefore(date, cutoff)) {
      continue;
    }
    total += e.value;
  }
  return total;
}

/// Completion dates in [year]; with [cutoff] only up to its month/day.
int countDatesInYear(Iterable<DateTime> dates, int year, {DateTime? cutoff}) =>
    dates.where((d) => d.year == year && _onOrBefore(d, cutoff)).length;

/// «+18%», «−5%», «как в 2025»; null when there is nothing to compare with.
String? percentChange(int current, int previous) {
  if (previous <= 0) return null;
  final change = ((current / previous - 1) * 100).round();
  if (change == 0) return '±0%';
  return change > 0 ? '+$change%' : '−${-change}%';
}

/// «+2», «−1», «±0» for whole counts.
String countChange(int current, int previous) {
  final change = current - previous;
  if (change == 0) return '±0';
  return change > 0 ? '+$change' : '−${-change}';
}

/// Completions per month, using the elapsed share of the current year rather
/// than counting an unfinished month as whole. At least one month is assumed
/// so that a book on 2 January does not become «30 в месяц».
double averagePerMonth(int count, int year, DateTime now) {
  final elapsed = elapsedDaysOfYear(year, now);
  if (elapsed <= 0) return 0;
  final months = elapsed * 12 / _daysInYear(year);
  return count / (months < 1 ? 1 : months);
}

class GoalPace {
  /// Completions expected by 31 December at the current pace; null before
  /// the year or after it.
  final int? projected;

  /// Completions still needed; 0 when the goal is reached.
  final int remaining;

  /// Days left in the year, including today; 0 for a past year.
  final int daysLeft;

  const GoalPace({
    required this.projected,
    required this.remaining,
    required this.daysLeft,
  });

  bool get reached => remaining <= 0;

  /// Days per completion needed to reach the goal; null when reached or when
  /// the year is over.
  double? get daysPerCompletion =>
      reached || daysLeft <= 0 ? null : daysLeft / remaining;
}

GoalPace goalPace({
  required int done,
  required int goal,
  required int year,
  required DateTime now,
}) {
  final total = _daysInYear(year), elapsed = elapsedDaysOfYear(year, now);
  final thisYear = now.toLocal().year, current = year == thisYear;
  return GoalPace(
    projected: current && elapsed > 0 ? (done * total / elapsed).round() : null,
    remaining: goal - done > 0 ? goal - done : 0,
    daysLeft: current ? total - elapsed + 1 : (year > thisYear ? total : 0),
  );
}

/// One line about the goal: forecast and the pace still needed.
String goalPaceText(GoalPace pace, int goal, int year, DateTime now) {
  final local = now.toLocal();
  if (pace.reached) return 'Цель выполнена.';
  if (year < local.year) {
    return 'Не хватило ${pace.remaining} ${ruPlural(pace.remaining, 'произведения', 'произведений', 'произведений')}.';
  }
  if (year > local.year) return 'Год ещё не начался.';
  final parts = <String>[
    if (pace.projected != null)
      'В этом темпе к 31 декабря выйдет около ${pace.projected} из $goal.',
  ];
  final every = pace.daysPerCompletion;
  if (every != null) {
    if (every < 1) {
      final perDay = (1 / every).ceil();
      parts.add(
        'Чтобы успеть, нужно $perDay ${ruPlural(perDay, 'произведение', 'произведения', 'произведений')} в день.',
      );
    } else {
      final days = every.floor();
      parts.add(
        days == 1
            ? 'Чтобы успеть, нужно одно произведение в день.'
            : 'Чтобы успеть — одно произведение каждые $days ${ruPlural(days, 'день', 'дня', 'дней')}.',
      );
    }
  }
  return parts.join(' ');
}
