/// Calendar days ending today, including today's unfinished day. Weekly goals
/// remain calendar weeks; the statistics preset "7 days" is always rolling.
const statisticsDayPeriods = <(int, String)>[
  (1, '1 день'),
  (7, '7 дней'),
  (30, '30 дней'),
  (365, '365 дней'),
  (0, 'Всё время'),
];

DateTime statisticsPeriodStart(DateTime now, int days) {
  final local = now.toLocal();
  return DateTime(local.year, local.month, local.day - days + 1);
}

({List<DateTime> days, bool limited}) statisticsChartWindow(
  DateTime now, {
  required int period,
  DateTime? start,
  DateTime? end,
}) {
  final last = period < 0 && end != null
      ? end.subtract(const Duration(microseconds: 1)).toLocal()
      : now.toLocal();
  final first = start?.toLocal();
  final count = period < 0 && first != null
      ? DateTime.utc(last.year, last.month, last.day)
                .difference(DateTime.utc(first.year, first.month, first.day))
                .inDays +
            1
      : period == 0
      ? 30
      : period;
  final shown = count.clamp(1, 60);
  return (
    days: [
      for (var i = shown - 1; i >= 0; i--)
        DateTime(last.year, last.month, last.day - i),
    ],
    limited: period == 0 || count > shown,
  );
}
