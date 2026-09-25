import '../audio/statistics_export.dart';
import 'audio_mini_player.dart';
import 'statistics_range.dart';
import '../audio/listening_analytics.dart';
import '../audio/audio_library_repository.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../audio/audio_journal.dart';
import '../media/audio_controller.dart';
import '../data/repository.dart';
import 'statistics_management_page.dart';

String statTime(int ms) {
  final minutes = ms ~/ 60000;
  return minutes >= 60
      ? '${minutes ~/ 60} ч ${minutes % 60} мин'
      : minutes > 0
      ? '$minutes мин'
      : '${ms ~/ 1000} с';
}

class AudioStatisticsPage extends StatefulWidget {
  final Repository repository;
  final AudioController? controller;
  final bool returnToPlayer;
  final String? initialBookId;
  const AudioStatisticsPage({
    super.key,
    required this.repository,
    this.controller,
    this.returnToPlayer = false,
    this.initialBookId,
  });
  @override
  State<AudioStatisticsPage> createState() => _AudioStatisticsPageState();
}

class _AudioStatisticsPageState extends State<AudioStatisticsPage> {
  ListeningGoals goals = const ListeningGoals();
  AudioStats? stats;
  AudioStats? goalStats;
  ListeningAnalytics? analytics;
  Map<String, ({int? total, int? position, double speed})> summaries = {};
  DateTime calendarMonth = DateTime(DateTime.now().year, DateTime.now().month);
  List<Map<String, dynamic>> events = [];
  Map<String, String> titles = {};
  int period = 30, legacyMs = 0;
  DateTimeRange? customRange;
  String? selectedBook, error;
  bool busy = false;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    selectedBook = widget.initialBookId;
    load();
    timer = Timer.periodic(const Duration(seconds: 15), (_) => load());
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> load() async {
    if (busy) return;
    busy = true;
    final requestedPeriod = period, requestedBook = selectedBook;
    final requestedRange = customRange;
    try {
      await AudioJournal(widget.repository).ensureIndexes();
      await widget.controller?.flushJournal();
      final books = (await widget.repository.records('book'))
          .where((b) => b.payload?['format'] == 'audio')
          .toList();
      final sessions = await widget.repository.records('session');
      final all = await widget.repository.records('audio_event');
      final now = DateTime.now();
      final cutoff = requestedPeriod <= 0
          ? null
          : dayKey(
              DateTime(now.year, now.month, now.day - requestedPeriod + 1),
            );
      final analysis = await compute(analyzeListening, <String, dynamic>{
        'events': all.map((r) => r.payload!).toList(),
        'book': requestedBook,
        'cutoff': cutoff,
        if (requestedPeriod == -1 && requestedRange != null) ...{
          'start': requestedRange.start.toUtc().toIso8601String(),
          'end': requestedRange.end.toUtc().toIso8601String(),
        },
      });
      final bookData = await AudioLibraryRepository(widget.repository.db)
          .bookSummaries();
      final result = analysis.selected;
      final savedGoals = await ListeningGoals.load(widget.repository);
      final global = await compute(
        AudioStats.new,
        all.map((r) => r.payload!).toList(),
      );

      if (mounted &&
          requestedPeriod == period &&
          requestedRange == customRange &&
          requestedBook == selectedBook) {
        setState(() {
          stats = result;
          goals = savedGoals;
          goalStats = global;
          analytics = analysis;
          summaries = bookData;
          events = result.recent;
          titles = {for (final b in books) b.id: b.title};
          legacyMs = sessions.fold(
            0,
            (sum, s) =>
                sum +
                (s.payload?['kind'] == 'listening' &&
                        (requestedBook == null ||
                            s.payload?['bookId'] == requestedBook)
                    ? ((s.payload?['activeSeconds'] as num?)?.toInt() ?? 0) *
                          1000
                    : 0),
          );
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      busy = false;
      if (mounted &&
          (requestedPeriod != period ||
              requestedBook != selectedBook ||
              requestedRange != customRange)) {
        unawaited(load());
      }
    }
  }

  Future<void> _goals() async {
    var daily = '${goals.dailyMinutes}', weekly = '${goals.weeklyMinutes}';
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Цели прослушивания'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Для всех книг. 0 — выключить цель.'),
            TextFormField(
              initialValue: daily,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Минут в день'),
              onChanged: (v) => daily = v,
            ),
            TextFormField(
              initialValue: weekly,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Минут в неделю'),
              onChanged: (v) => weekly = v,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    try {
      final value = ListeningGoals(
        dailyMinutes: int.parse(daily),
        weeklyMinutes: int.parse(weekly),
      );
      await value.save(widget.repository);
      if (mounted) setState(() => goals = value);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Проверьте минуты: $e')));
      }
    }
  }

  Future<void> _exportStats(String format) async {
    final data = analytics;
    if (data == null || busy || error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Дождитесь успешного расчёта статистики')),
      );
      return;
    }
    try {
      final text = format == 'csv'
          ? statisticsCsv(data, titles)
          : statisticsJson(
              data,
              titles,
              period: period,
              bookId: selectedBook,
              start: customRange?.start.toUtc().toIso8601String(),
              end: customRange?.end.toUtc().toIso8601String(),
            );
      final saved = await saveStatisticsFile(text, format);
      if (mounted && saved) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Статистика экспортирована')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Widget _goalCard() {
    final now = DateTime.now();
    final day = DateTime.utc(now.year, now.month, now.day);
    final monday = day.subtract(Duration(days: day.weekday - 1));
    final todayMs = goalStats?.days[dayKey(day)] ?? 0;
    final weekMs =
        goalStats?.days.entries
            .where(
              (e) =>
                  e.key.compareTo(dayKey(monday)) >= 0 &&
                  e.key.compareTo(dayKey(day)) <= 0,
            )
            .fold<int>(0, (sum, e) => sum + e.value) ??
        0;
    Widget line(String title, int ms, int target) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$title · ${statTime(ms)} / $target мин'),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: (ms / (target * 60000)).clamp(0, 1),
            minHeight: 7,
            borderRadius: BorderRadius.circular(7),
          ),
          if (ms >= target * 60000) const Text('Цель достигнута ✓'),
        ],
      ),
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Мои цели · все книги',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: 'Настроить цели',
                  onPressed: _goals,
                  icon: const Icon(Icons.tune),
                ),
              ],
            ),
            if (goals.dailyMinutes > 0)
              line('Сегодня', todayMs, goals.dailyMinutes),
            if (goals.weeklyMinutes > 0)
              line('Неделя с понедельника', weekMs, goals.weeklyMinutes),
            if (goals.dailyMinutes == 0 && goals.weeklyMinutes == 0)
              const Text('Цели выключены'),
          ],
        ),
      ),
    );
  }

  String _sessionTime(DateTime value, int offset) {
    final local = value.toUtc().add(Duration(minutes: offset));
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  Widget _calendar() {
    final activity = analytics!.lifetime.days;
    final first = DateTime.utc(calendarMonth.year, calendarMonth.month);
    final count = DateTime.utc(first.year, first.month + 1, 0).day;
    final offset = first.weekday - 1;
    final maxDay = activity.values.fold<int>(1, math.max);
    return Column(
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Предыдущий месяц',
              onPressed: () => setState(
                () => calendarMonth = DateTime(first.year, first.month - 1),
              ),
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Text(
                'Календарь · ${first.month.toString().padLeft(2, '0')}.${first.year}',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Следующий месяц',
              onPressed: () => setState(
                () => calendarMonth = DateTime(first.year, first.month + 1),
              ),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        const Text(
          'Вся история выбранных книг · нажмите день для деталей',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            for (final label in ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'])
              Expanded(child: Center(child: Text(label))),
          ],
        ),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 7,
            mainAxisSpacing: 5,
            crossAxisSpacing: 5,
          ),
          itemCount: ((offset + count + 6) ~/ 7) * 7,
          itemBuilder: (context, i) {
            final number = i - offset + 1;
            if (number < 1 || number > count) return const SizedBox();
            final key = dayKey(DateTime(first.year, first.month, number));
            final value = activity[key] ?? 0;
            return Material(
              color: value == 0
                  ? Theme.of(context).colorScheme.surfaceContainerHighest
                  : Color.lerp(
                      const Color(0xffc3e4c9),
                      const Color(0xff216b54),
                      value / maxDay,
                    ),
              borderRadius: BorderRadius.circular(9),
              child: InkWell(
                borderRadius: BorderRadius.circular(9),
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text(key),
                    content: Text('Активное прослушивание: ${statTime(value)}'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Закрыть'),
                      ),
                    ],
                  ),
                ),
                child: Center(
                  child: Text(
                    '$number',
                    style: TextStyle(
                      color: value / maxDay > .6
                          ? Colors.white
                          : value > 0
                          ? Colors.black87
                          : Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _comparisons() {
    final now = DateTime.now();
    final today = DateTime.utc(now.year, now.month, now.day);
    final week = today.subtract(Duration(days: today.weekday - 1));
    final month = DateTime.utc(now.year, now.month);
    final previousMonth = DateTime.utc(now.year, now.month - 1);
    final priorMonthEnd = DateTime.utc(
      previousMonth.year,
      previousMonth.month,
      math.min(now.day, DateTime.utc(now.year, now.month, 0).day) + 1,
    );
    Widget row(String title, int value, int previous) => ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(
        'Сейчас ${statTime(value)} · раньше ${statTime(previous)}',
      ),
      trailing: Text(
        previous == 0
            ? '—'
            : '${value >= previous ? '+' : ''}${((value / previous - 1) * 100).toStringAsFixed(0)}%',
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        const Text(
          'Сравнение периодов',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
        ),
        const Text(
          'По календарным дням до сегодня включительно; сегодняшний день ещё не завершён.',
          style: TextStyle(fontSize: 12),
        ),
        row(
          'Эта неделя / те же дни прошлой',
          analytics!.timeBetween(week, today.add(const Duration(days: 1))),
          analytics!.timeBetween(
            week.subtract(const Duration(days: 7)),
            today.subtract(const Duration(days: 6)),
          ),
        ),
        row(
          'Этот месяц / те же даты прошлого',
          analytics!.timeBetween(month, today.add(const Duration(days: 1))),
          analytics!.timeBetween(previousMonth, priorMonthEnd),
        ),
      ],
    );
  }

  Widget metric(String title, String value, IconData icon, {String? note}) =>
      Container(
        width: MediaQuery.sizeOf(context).width < 500
            ? (MediaQuery.sizeOf(context).width - 52) / 2
            : 220,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              value,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
            ),
            Text(title),
            if (note != null)
              Text(
                note,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      );
  @override
  Widget build(BuildContext context) {
    final s = stats;
    final top = s?.books.entries.toList() ?? [];
    top.sort((a, b) => b.value.compareTo(a.value));
    final chartEnd = period == -1 && customRange != null
        ? customRange!.end.subtract(const Duration(microseconds: 1))
        : DateTime.now();
    final chartStart = period == -1 && customRange != null
        ? customRange!.start
        : DateTime(
            chartEnd.year,
            chartEnd.month,
            chartEnd.day - (period == 0 ? 13 : period - 1),
          );
    final count =
        (DateTime.utc(chartEnd.year, chartEnd.month, chartEnd.day)
                    .difference(
                      DateTime.utc(
                        chartStart.year,
                        chartStart.month,
                        chartStart.day,
                      ),
                    )
                    .inDays +
                1)
            .clamp(1, 31);
    final days = List.generate(
      count,
      (i) => dayKey(
        DateTime(chartEnd.year, chartEnd.month, chartEnd.day - count + 1 + i),
      ),
    );
    final maximum = s == null
        ? 1
        : math.max(1, days.map((d) => s.days[d] ?? 0).reduce(math.max));
    return Scaffold(
      bottomNavigationBar: AudioMiniPlayer(
        controller: widget.controller,
        onOpen: widget.returnToPlayer ? () => Navigator.pop(context) : null,
      ),
      appBar: AppBar(
        title: const Text('Моё прослушивание'),
        actions: [
          IconButton(
            tooltip: 'Управление статистикой',
            onPressed: () async {
              await Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) => StatisticsManagementPage(
                    repository: widget.repository,
                    controller: widget.controller,
                    initialTab: 1,
                  ),
                ),
              );
              if (mounted) load();
            },
            icon: const Icon(Icons.edit_note),
          ),
          PopupMenuButton<String>(
            tooltip: 'Экспорт статистики',
            icon: const Icon(Icons.file_download_outlined),
            onSelected: _exportStats,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'csv', child: Text('Экспорт CSV')),
              PopupMenuItem(value: 'json', child: Text('Экспорт JSON')),
            ],
          ),
          IconButton(onPressed: load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1050),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xff174d3e), Color(0xff328b6a)],
                  ),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'ВРЕМЯ ДЛЯ ИСТОРИЙ',
                      style: TextStyle(
                        color: Colors.white70,
                        letterSpacing: 2,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      s == null ? 'Собираем историю…' : statTime(s.wallMs),
                      style: const TextStyle(
                        fontSize: 38,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const Text(
                      'Реальное время звучания · без пауз и перемоток',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              if (goalStats != null) _goalCard(),
              Wrap(
                spacing: 8,
                children: [
                  for (final p in [1, 7, 30, 0])
                    ChoiceChip(
                      label: Text(
                        p == 0
                            ? 'Всё время'
                            : p == 1
                            ? '1 день'
                            : '$p дней',
                      ),
                      selected: period == p,
                      onSelected: (_) {
                        setState(() => period = p);
                        load();
                      },
                    ),
                  ChoiceChip(
                    label: const Text('Произвольный'),
                    selected: period == -1,
                    onSelected: (_) async {
                      final picked = await pickStatisticsRange(
                        context,
                        customRange,
                      );
                      if (picked == null || !mounted) return;
                      setState(() {
                        customRange = picked;
                        period = -1;
                        calendarMonth = DateTime(
                          picked.start.year,
                          picked.start.month,
                        );
                      });
                      load();
                    },
                  ),
                ],
              ),
              if (period == -1 && customRange != null)
                Text(rangeLabel(customRange!)),
              DropdownButton<String?>(
                isExpanded: true,
                value: titles.containsKey(selectedBook) ? selectedBook : null,
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('Все книги'),
                  ),
                  for (final e in titles.entries)
                    DropdownMenuItem<String?>(
                      value: e.key,
                      child: Text(e.value, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) {
                  setState(() => selectedBook = v);
                  load();
                },
              ),
              if (error != null) Text(error!),
              if (s == null) const LinearProgressIndicator(),
              if (s != null) ...[
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    metric(
                      'Пройдено материала',
                      statTime(s.mediaMs),
                      Icons.headphones,
                    ),
                    metric(
                      'Уникальные участки',
                      statTime(s.uniqueMs),
                      Icons.auto_stories_outlined,
                    ),
                    metric(
                      'Повторное прослушивание',
                      statTime(analytics!.repeatedHistoryMs),
                      Icons.replay,
                    ),
                    metric(
                      'Впервые прослушано',
                      statTime(analytics!.firstHeardMs),
                      Icons.fiber_new,
                      note: 'С учётом всей сохранённой истории',
                    ),
                    metric(
                      'Текущая серия',
                      '${analytics!.currentStreak(DateTime.now())}',
                      Icons.local_fire_department,
                      note: 'За всю историю, включая вчера',
                    ),
                    metric(
                      'Сессий',
                      '${analytics!.sessions.length}',
                      Icons.timelapse,
                      note: 'Перерыв до 5 минут внутри одной книги',
                    ),
                    metric(
                      'Средняя сессия',
                      statTime(
                        analytics!.sessions.isEmpty
                            ? 0
                            : analytics!.sessions.fold<int>(
                                    0,
                                    (sum, x) => sum + x.wallMs,
                                  ) ~/
                                  analytics!.sessions.length,
                      ),
                      Icons.av_timer,
                    ),
                    metric(
                      'Самая длинная сессия',
                      statTime(
                        analytics!.sessions.fold<int>(
                          0,
                          (value, x) => math.max(value, x.wallMs),
                        ),
                      ),
                      Icons.timer_outlined,
                    ),
                    metric(
                      'Средняя скорость',
                      '${s.averageSpeed.toStringAsFixed(2)}×',
                      Icons.speed,
                      note: 'Материал / реальное время',
                    ),
                    metric(
                      'Активных дней',
                      '${s.days.length}',
                      Icons.calendar_month,
                    ),
                    metric(
                      'Книг в прослушивании',
                      '${s.books.length}',
                      Icons.library_books_outlined,
                    ),
                    metric('Перемоток', '${s.seeks}', Icons.swap_horiz),
                    metric(
                      'Лучшая серия дней',
                      '${analytics!.lifetime.longestStreak}',
                      Icons.local_fire_department_outlined,
                    ),
                    metric('Паузы', '${s.pauses}', Icons.pause_circle_outline),
                    metric(
                      'Буферизации / ошибки',
                      '${s.bufferings} / ${s.errors}',
                      Icons.network_check,
                    ),
                    metric(
                      'Переходы вперёд',
                      statTime(s.forwardMs),
                      Icons.fast_forward,
                      note: 'В пределах одного трека',
                    ),
                    metric(
                      'Переходы назад',
                      statTime(s.backwardMs),
                      Icons.fast_rewind,
                      note: 'В пределах одного трека',
                    ),
                    metric(
                      'Добавлено закладок',
                      '${s.bookmarks}',
                      Icons.bookmark_outline,
                    ),
                    metric(
                      'Срабатываний таймера',
                      '${s.timers}',
                      Icons.bedtime_outlined,
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                _calendar(),
                _comparisons(),
                const SizedBox(height: 24),
                Text(
                  period == -1
                      ? 'Активность · до 31 дня выбранного периода'
                      : period == 1
                      ? 'Сегодня'
                      : 'Последние $count дней',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: 155,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (final d in days)
                        Expanded(
                          child: Tooltip(
                            message: '$d · ${statTime(s.days[d] ?? 0)}',
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 3,
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  Container(
                                    height: math.max(
                                      3,
                                      (s.days[d] ?? 0) / maximum * 120,
                                    ),
                                    decoration: BoxDecoration(
                                      color: d == dayKey(DateTime.now())
                                          ? const Color(0xffe1ad58)
                                          : const Color(0xff438b70),
                                      borderRadius: BorderRadius.circular(5),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    d.substring(8),
                                    style: const TextStyle(fontSize: 9),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 28),
                const Text(
                  'Книги',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                ),
                for (final e in top)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.headphones),
                    title: Text(titles[e.key] ?? 'Книга из архива'),
                    onTap: () {
                      setState(() => selectedBook = e.key);
                      load();
                    },
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Уникально: ${statTime(analytics!.byBook[e.key]!.uniqueMs)} · материал: ${statTime(analytics!.byBook[e.key]!.mediaMs)}',
                        ),
                        if (summaries[e.key]?.total != null &&
                            summaries[e.key]?.position != null) ...[
                          const SizedBox(height: 6),
                          LinearProgressIndicator(
                            value:
                                (summaries[e.key]!.position! /
                                        summaries[e.key]!.total!)
                                    .clamp(0, 1),
                          ),
                          Text(
                            'По позиции: ${(summaries[e.key]!.position! / summaries[e.key]!.total! * 100).toStringAsFixed(1)}% · осталось ${statTime(((summaries[e.key]!.total! - summaries[e.key]!.position!).clamp(0, 1 << 60) / summaries[e.key]!.speed).round())}',
                          ),
                        ] else
                          const Text(
                            'Для общей длительности откройте книгу в плеере',
                          ),
                      ],
                    ),
                    trailing: Text(statTime(e.value)),
                  ),
                const SizedBox(height: 20),
                const Text(
                  'Скорость и время суток',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final e in s.speeds.entries)
                      Chip(label: Text('${e.key}× · ${statTime(e.value)}')),
                  ],
                ),
                Wrap(
                  spacing: 6,
                  children: [
                    for (var hour = 0; hour < 24; hour++)
                      if (s.hours.containsKey(hour))
                        Chip(
                          label: Text('$hour:00 · ${statTime(s.hours[hour]!)}'),
                        ),
                  ],
                ),
                const SizedBox(height: 24),
                const Text(
                  'Сессии прослушивания',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                ),
                const Text(
                  'Период — по дате начала. Короткие паузы не добавляют активного времени.',
                ),
                for (final session in analytics!.sessions.take(50))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.headphones),
                    title: Text(titles[session.bookId] ?? 'Книга из архива'),
                    subtitle: Text(
                      '${session.localDay} ${_sessionTime(session.start, session.offsetMinutes)}–${_sessionTime(session.end, session.offsetMinutes)} · ${statTime(session.wallMs)} звучания / ${statTime(session.elapsedMs)} от начала до конца\nМатериал ${statTime(session.mediaMs)} · пауз ${session.pauses} · перемоток ${session.seeks}',
                    ),
                    isThreeLine: true,
                  ),
                if (analytics!.sessions.length > 50)
                  const Text(
                    'Показаны последние 50 сессий; сводка учитывает все.',
                  ),
                const SizedBox(height: 24),
                Text(
                  'Старый журнал сессий: ${statTime(legacyMs)} за всё время. Он пересекается с новым журналом и не прибавляется к нему. Подробные интервалы собираются с версии 0.7.0.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 24),
                const Text(
                  'Подробный журнал · последние 100 событий',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                for (final e in events)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Icon(
                      e['kind'] == 'listen' ? Icons.headphones : Icons.history,
                    ),
                    title: Text(
                      '${eventLabel(e['kind'] as String)} · ${titles[e['bookId']] ?? 'Книга'}',
                    ),
                    subtitle: Text(
                      '${e['at']} · ${statTime((e['positionMs'] as num).toInt())}${e['kind'] == 'listen' ? ' → ${statTime((e['endMs'] as num).toInt())} · ${statTime((e['wallMs'] as num).toInt())} · ${e['speed']}×' : ''}',
                    ),
                  ),
                if (events.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Включите аудиокнигу — здесь появится история прослушивания.',
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

String eventLabel(String kind) =>
    const {
      'listen': 'Прослушивание',
      'chapter_completed': 'Завершена глава',
      'play': 'Воспроизведение',
      'pause': 'Пауза',
      'stop': 'Остановка',
      'seek': 'Перемотка',
      'speed': 'Скорость',
      'bookmark': 'Закладка',
      'sleep_set': 'Таймер установлен',
      'sleep_fired': 'Таймер сработал',
      'sleep_extended': 'Таймер продлён',
      'sleep_cancelled': 'Таймер отменён',
      'completed': 'Конец книги',
      'track_changed': 'Смена трека',
      'buffering': 'Буферизация',
      'error': 'Ошибка',
    }[kind] ??
    kind;
