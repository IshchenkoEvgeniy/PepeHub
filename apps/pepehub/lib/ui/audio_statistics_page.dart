import '../audio/statistics_export.dart';
import 'audio_mini_player.dart';
import 'statistics_range.dart';
import '../audio/listening_analytics.dart';
import '../audio/audio_library_repository.dart';

import 'dart:async';

import '../library/activity_store.dart';

import 'package:flutter/foundation.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../audio/audio_journal.dart';
import '../media/audio_controller.dart';
import '../data/repository.dart';
import 'pepe_widgets.dart';
import 'shelf_components.dart';
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
      await widget.controller?.flushJournal();
      final books = (await widget.repository.records('book'))
          .where((b) => b.payload?['format'] == 'audio')
          .toList();
      final sessions = await widget.repository.records('session');
      final all = await widget.repository.records('audio_event');
      final allEvents = [
        ...all.map((r) => r.payload!),
        ...await ActivityStore.foreignAudio(widget.repository),
      ];
      final now = DateTime.now();
      final cutoff = requestedPeriod <= 0
          ? null
          : dayKey(
              DateTime(now.year, now.month, now.day - requestedPeriod + 1),
            );
      final analysis = await compute(analyzeListening, <String, dynamic>{
        'events': allEvents,
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
      final global = await compute(AudioStats.new, allEvents);

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

  String _sessionTime(DateTime value, int offset) {
    final local = value.toUtc().add(Duration(minutes: offset));
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _manage() async {
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
  }

  String get _periodLabel => switch (period) {
    1 => 'за сегодня',
    7 => 'за 7 дней',
    30 => 'за 30 дней',
    0 => 'за всё время',
    _ => customRange == null ? 'за период' : rangeLabel(customRange!),
  };

  Widget _hero(ShelfPalette palette, AudioStats? s) {
    final ink = palette.onAccent;
    final soft = ink.withValues(alpha: .72);
    Widget figure(String value, String label) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: AppFonts.title(ink, size: 24)),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(fontSize: 12, color: soft)),
      ],
    );
    final data = analytics;
    return Material(
      color: palette.accent,
      borderRadius: BorderRadius.circular(22),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ВРЕМЯ ДЛЯ ИСТОРИЙ · ${_periodLabel.toUpperCase()}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: .8,
                color: soft,
              ),
            ),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                s == null ? 'Собираем историю…' : statTime(s.wallMs),
                style: AppFonts.title(ink, size: s == null ? 34 : 58),
              ),
            ),
            Text(
              'Реальное время звучания · без пауз и перемоток',
              style: TextStyle(fontSize: 13, color: soft),
            ),
            if (s != null && data != null) ...[
              const SizedBox(height: 18),
              Wrap(
                spacing: 28,
                runSpacing: 12,
                children: [
                  figure('${data.sessions.length}', 'Сессий'),
                  figure('${s.days.length}', 'Активных дней'),
                  figure(
                    '${s.averageSpeed.toStringAsFixed(2)}×',
                    'Средняя скорость',
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _goalPanel(ShelfPalette palette) {
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
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '${pepeTime(ms)} / $target мин',
                style: TextStyle(fontSize: 13, color: palette.muted),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: (ms / (target * 60000)).clamp(0, 1),
              minHeight: 10,
              color: palette.accent,
              backgroundColor: palette.raised,
            ),
          ),
          if (ms >= target * 60000)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Цель достигнута ✓',
                style: TextStyle(fontSize: 12, color: palette.accent),
              ),
            ),
        ],
      ),
    );
    return PepePanel(
      title: 'Мои цели · все книги',
      trailing: IconButton(
        tooltip: 'Настроить цели',
        onPressed: _goals,
        icon: const Icon(Icons.tune, size: 20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (goals.dailyMinutes > 0)
            line('Сегодня', todayMs, goals.dailyMinutes),
          if (goals.weeklyMinutes > 0)
            line('Неделя с понедельника', weekMs, goals.weeklyMinutes),
          if (goals.dailyMinutes == 0 && goals.weeklyMinutes == 0)
            Text('Цели выключены', style: TextStyle(color: palette.muted)),
        ],
      ),
    );
  }

  Widget _streakPanel(ShelfPalette palette) {
    final data = analytics!;
    final now = DateTime.now();
    final cells = [
      for (var i = 29; i >= 0; i--)
        data.lifetime.days[dayKey(
              DateTime(now.year, now.month, now.day - i),
            )] ??
            0,
    ];
    return PepePanel(
      title: 'Текущая серия',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '${data.currentStreak(now)}',
                  style: AppFonts.title(palette.text, size: 44),
                ),
                TextSpan(
                  text: '  лучшая серия дней: ${data.lifetime.longestStreak}',
                  style: TextStyle(fontSize: 13, color: palette.muted),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          PepeStreak(values: cells, goalMinutes: goals.dailyMinutes),
          const SizedBox(height: 6),
          Text(
            'последние 30 дней · за всю историю, включая вчера',
            style: TextStyle(fontSize: 11, color: palette.muted),
          ),
        ],
      ),
    );
  }

  Widget _calendarPanel() {
    final activity = analytics!.lifetime.days;
    return PepePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PepeMonthCalendar(
            month: calendarMonth,
            title:
                'Календарь · ${pepeMonthNames[calendarMonth.month - 1]} ${calendarMonth.year}',
            dayValue: (d) => activity[dayKey(d)] ?? 0,
            goalMinutes: goals.dailyMinutes,
            describe: statTime,
            onPrevious: () => setState(
              () => calendarMonth = DateTime(
                calendarMonth.year,
                calendarMonth.month - 1,
              ),
            ),
            onNext: () => setState(
              () => calendarMonth = DateTime(
                calendarMonth.year,
                calendarMonth.month + 1,
              ),
            ),
            onDay: (date) {
              final value = activity[dayKey(date)] ?? 0;
              showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text('${pepeDate(date)} ${date.year}'),
                  content: Text('Активное прослушивание: ${statTime(value)}'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Закрыть'),
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 10),
          Text(
            'Вся история выбранных книг · нажмите день для деталей',
            style: TextStyle(
              fontSize: 11.5,
              color: ShelfPalette.of(context).muted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _comparisons(ShelfPalette palette) {
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
    Widget row(String title, int value, int previous) {
      final change = previous == 0
          ? '—'
          : '${value >= previous ? '+' : ''}${((value / previous - 1) * 100).toStringAsFixed(0)}%';
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: palette.line)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 13.5)),
                  const SizedBox(height: 3),
                  Text(
                    'Сейчас ${pepeTime(value)} · раньше ${pepeTime(previous)}',
                    style: TextStyle(fontSize: 12, color: palette.muted),
                  ),
                ],
              ),
            ),
            Text(
              change,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: previous != 0 && value >= previous
                    ? palette.accent
                    : palette.text,
              ),
            ),
          ],
        ),
      );
    }

    return PepePanel(
      title: 'Сравнение периодов',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'По календарным дням до сегодня включительно; сегодняшний день ещё не завершён.',
            style: TextStyle(fontSize: 11.5, color: palette.muted),
          ),
          const SizedBox(height: 8),
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
      ),
    );
  }

  Widget _rhythm(ShelfPalette palette, AudioStats s) {
    final speedTotal = s.speeds.values.fold<int>(0, (a, b) => a + b);
    final speeds = s.speeds.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final hourMax = math.max(1, s.hours.values.fold<int>(0, math.max));
    return PepePanel(
      title: 'Скорость и время суток',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (speeds.isEmpty)
            Text('Пока нет данных.', style: TextStyle(color: palette.muted)),
          for (final e in speeds.take(5))
            PepeShareRow(
              title: '${e.key}×',
              value: pepeTime(e.value),
              share: e.value / math.max(1, speedTotal),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              for (var hour = 0; hour < 24; hour++)
                Expanded(
                  child: Tooltip(
                    message: '$hour:00 · ${pepeTime(s.hours[hour] ?? 0)}',
                    child: Container(
                      height: 30,
                      margin: const EdgeInsets.only(right: 2),
                      decoration: BoxDecoration(
                        color: (s.hours[hour] ?? 0) == 0
                            ? palette.raised
                            : Color.lerp(
                                palette.muted,
                                palette.accent,
                                (s.hours[hour]! / hourMax).clamp(0.0, 1.0),
                              ),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              for (final label in ['0', '6', '12', '18', '23'])
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(fontSize: 10.5, color: palette.muted),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _booksPanel(ShelfPalette palette, AudioStats s) {
    final top = s.books.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final sum = math.max(1, top.fold<int>(0, (a, e) => a + e.value));
    return PepePanel(
      title: 'Книги',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (top.isEmpty)
            Text(
              'За этот период книг нет.',
              style: TextStyle(color: palette.muted),
            ),
          for (final e in top) _bookRow(palette, e.key, e.value, sum),
        ],
      ),
    );
  }

  Widget _bookRow(ShelfPalette palette, String id, int ms, int sum) {
    final title = titles[id] ?? 'Книга из архива';
    final data = analytics!.byBook[id];
    final summary = summaries[id];
    final known = summary?.total != null && summary?.position != null;
    final progress = known
        ? (summary!.position! / summary.total!).clamp(0.0, 1.0)
        : null;
    return InkWell(
      onTap: () {
        setState(() => selectedBook = id);
        load();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: palette.line)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PepeSpine(title, width: 36, height: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.book(palette.text, size: 17),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    data == null
                        ? '${(ms * 100 / sum).round()}% времени'
                        : 'Уникально: ${pepeTime(data.uniqueMs)} · материал: ${pepeTime(data.mediaMs)}',
                    style: TextStyle(fontSize: 12, color: palette.muted),
                  ),
                  const SizedBox(height: 7),
                  if (progress != null) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 5,
                        color: palette.accent,
                        backgroundColor: palette.raised,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'По позиции: ${(progress * 100).toStringAsFixed(1)}% · осталось ${pepeTime(((summary!.total! - summary.position!).clamp(0, 1 << 60) / summary.speed).round())}',
                      style: TextStyle(fontSize: 11.5, color: palette.muted),
                    ),
                  ] else
                    Text(
                      'Для общей длительности откройте книгу в плеере',
                      style: TextStyle(fontSize: 11.5, color: palette.muted),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              pepeTime(ms),
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sessionsPanel(ShelfPalette palette) {
    final list = analytics!.sessions;
    final rows = <Widget>[];
    String? lastDay;
    for (final session in list.take(50)) {
      if (session.localDay != lastDay) {
        lastDay = session.localDay;
        final date = DateTime.tryParse(session.localDay);
        rows.add(
          Padding(
            padding: EdgeInsets.only(top: rows.isEmpty ? 0 : 14, bottom: 4),
            child: Text(
              date == null
                  ? session.localDay
                  : '${pepeDate(date)} · ${pepeWeekdays[date.weekday - 1]}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: .4,
                color: palette.muted,
              ),
            ),
          ),
        );
      }
      rows.add(
        Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: palette.line)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 92,
                child: Text(
                  session.timeKnown
                      ? '${_sessionTime(session.start, session.offsetMinutes)}–${_sessionTime(session.end, session.offsetMinutes)}'
                      : 'Obsidian',
                  style: TextStyle(fontSize: 12.5, color: palette.muted),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      titles[session.bookId] ?? 'Книга из архива',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.book(palette.text, size: 16),
                    ),
                    if (session.timeKnown)
                      Text(
                        'от начала до конца ${pepeTime(session.elapsedMs)} · материал ${pepeTime(session.mediaMs)} · пауз ${session.pauses} · перемоток ${session.seeks}',
                        style: TextStyle(fontSize: 11.5, color: palette.muted),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(
                pepeTime(session.wallMs),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return PepePanel(
      title: 'Сессии прослушивания',
      trailing: Text(
        '${list.length}',
        style: TextStyle(fontSize: 13, color: palette.muted),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Период — по дате начала. Короткие паузы не добавляют активного времени.',
            style: TextStyle(fontSize: 11.5, color: palette.muted),
          ),
          const SizedBox(height: 10),
          if (list.isEmpty)
            Text(
              'Сессий за период нет.',
              style: TextStyle(color: palette.muted),
            ),
          ...rows,
          if (list.length > 50)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Показаны последние 50 сессий; сводка учитывает все.',
                style: TextStyle(fontSize: 12, color: palette.muted),
              ),
            ),
        ],
      ),
    );
  }

  Widget _playerPanel(ShelfPalette palette, AudioStats s) {
    Widget line(String label, String value, [String? note]) => Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: palette.line)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 13.5)),
                if (note != null)
                  Text(
                    note,
                    style: TextStyle(fontSize: 11, color: palette.muted),
                  ),
              ],
            ),
          ),
          Text(
            value,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
    return PepePanel(
      title: 'В плеере',
      child: Column(
        children: [
          line('Перемоток', '${s.seeks}'),
          line('Паузы', '${s.pauses}'),
          line('Буферизации / ошибки', '${s.bufferings} / ${s.errors}'),
          line(
            'Переходы вперёд',
            pepeTime(s.forwardMs),
            'В пределах одного трека',
          ),
          line(
            'Переходы назад',
            pepeTime(s.backwardMs),
            'В пределах одного трека',
          ),
          line('Добавлено закладок', '${s.bookmarks}'),
          line('Срабатываний таймера', '${s.timers}'),
        ],
      ),
    );
  }

  Widget _eventsPanel(ShelfPalette palette) => PepePanel(
    padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
    child: Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        title: const Text(
          'Подробный журнал · последние 100 событий',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [
          if (events.isEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'Включите аудиокнигу — здесь появится история прослушивания.',
                style: TextStyle(color: palette.muted),
              ),
            ),
          for (final e in events)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(
                e['kind'] == 'listen' ? Icons.headphones : Icons.history,
                size: 18,
                color: palette.muted,
              ),
              title: Text(
                '${eventLabel(e['kind'] as String)} · ${titles[e['bookId']] ?? 'Книга'}',
              ),
              subtitle: Text(
                '${e['at']} · ${pepeTime((e['positionMs'] as num).toInt())}${e['kind'] == 'listen' ? ' → ${pepeTime((e['endMs'] as num).toInt())} · ${pepeTime((e['wallMs'] as num).toInt())} · ${e['speed']}×' : ''}',
              ),
            ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final s = stats;
    final data = analytics;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final barEnd = period == -1 && customRange != null
        ? DateTime(
            customRange!.end.year,
            customRange!.end.month,
            customRange!.end.day - 1,
          )
        : today;
    final barCount = period == -1 && customRange != null
        ? customRange!.duration.inDays.clamp(7, 60)
        : period == 30 || period == 0
        ? 30
        : 14;
    final barDays = [
      for (var i = barCount - 1; i >= 0; i--)
        DateTime(barEnd.year, barEnd.month, barEnd.day - i),
    ];
    final lifetime = data?.lifetime.days ?? const <String, int>{};

    final picker = Wrap(
      spacing: 10,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        PepeChoices<int>(
          options: const [
            (1, '1 день'),
            (7, '7 дней'),
            (30, '30 дней'),
            (0, 'Всё время'),
            (-1, 'Произвольный'),
          ],
          selected: period,
          onSelect: (p) async {
            if (p != -1) {
              setState(() => period = p);
              load();
              return;
            }
            final picked = await pickStatisticsRange(context, customRange);
            if (picked == null || !mounted) return;
            setState(() {
              customRange = picked;
              period = -1;
              calendarMonth = DateTime(picked.start.year, picked.start.month);
            });
            load();
          },
        ),
        Container(
          constraints: const BoxConstraints(maxWidth: 320),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            border: Border.all(color: palette.strongLine),
            borderRadius: BorderRadius.circular(30),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String?>(
              isExpanded: true,
              isDense: true,
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
          ),
        ),
      ],
    );

    final stacked = MediaQuery.sizeOf(context).width < 1100;
    final Widget figures = s == null || data == null
        ? const SizedBox()
        : PepeFigureStrip([
            (statTime(s.mediaMs), 'Пройдено материала'),
            (pepeTime(s.uniqueMs), 'Уникальные участки'),
            (pepeTime(data.repeatedHistoryMs), 'Повторное прослушивание'),
            (pepeTime(data.firstHeardMs), 'Впервые прослушано'),
            (
              pepeTime(
                data.sessions.isEmpty
                    ? 0
                    : data.sessions.fold<int>(0, (sum, x) => sum + x.wallMs) ~/
                          data.sessions.length,
              ),
              'Средняя сессия',
            ),
            (
              pepeTime(
                data.sessions.fold<int>(
                  0,
                  (value, x) => math.max(value, x.wallMs),
                ),
              ),
              'Самая длинная сессия',
            ),
            ('${s.books.length}', 'Книг в прослушивании'),
            ('${data.lifetime.longestStreak}', 'Лучшая серия дней'),
          ]);
    return PepeSubpage(
      title: 'Прослушивание',
      back: 'Статистика',
      section: PepeSection.statistics,
      onRefresh: load,
      bottomNavigationBar: AudioMiniPlayer(
        controller: widget.controller,
        onOpen: widget.returnToPlayer ? () => Navigator.pop(context) : null,
      ),
      actions: [
        IconButton(
          tooltip: 'Управление статистикой',
          onPressed: _manage,
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
        IconButton(
          tooltip: 'Обновить статистику',
          onPressed: load,
          icon: const Icon(Icons.refresh),
        ),
      ],
      children: [
        picker,
        if (period == -1 && customRange != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              rangeLabel(customRange!),
              style: TextStyle(fontSize: 12, color: palette.muted),
            ),
          ),
        const SizedBox(height: 18),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: PepePanel(
              outlined: true,
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ),
        if (s == null || data == null) ...[
          _hero(palette, null),
          const SizedBox(height: 12),
          const LinearProgressIndicator(),
        ] else ...[
          if (stacked) ...[
            _hero(palette, s),
            const SizedBox(height: 18),
            figures,
            const SizedBox(height: 18),
            if (goalStats != null) ...[
              _goalPanel(palette),
              const SizedBox(height: 16),
            ],
            _streakPanel(palette),
          ] else ...[
            PepeRow(
              breakpoint: 0,
              children: [
                (6, _hero(palette, s)),
                (4, goalStats == null ? const SizedBox() : _goalPanel(palette)),
                (4, _streakPanel(palette)),
              ],
            ),
            const SizedBox(height: 18),
            figures,
          ],
          const SizedBox(height: 18),
          PepeRow(
            children: [
              (
                7,
                PepePanel(
                  title: 'По дням',
                  trailing: goals.dailyMinutes > 0
                      ? Text(
                          '- - цель ${goals.dailyMinutes} мин',
                          style: TextStyle(fontSize: 12, color: palette.muted),
                        )
                      : null,
                  child: PepeBars(
                    values: [for (final d in barDays) lifetime[dayKey(d)] ?? 0],
                    tooltips: [
                      for (final d in barDays)
                        '${pepeDate(d)} · ${pepeTime(lifetime[dayKey(d)] ?? 0)}',
                    ],
                    goalMinutes: goals.dailyMinutes,
                    startLabel: pepeDate(barDays.first),
                    endLabel: barDays.last == today
                        ? 'сегодня'
                        : pepeDate(barDays.last),
                  ),
                ),
              ),
              (4, _rhythm(palette, s)),
            ],
          ),
          const SizedBox(height: 16),
          PepeRow(
            children: [(4, _calendarPanel()), (7, _booksPanel(palette, s))],
          ),
          const SizedBox(height: 16),
          PepeRow(
            children: [
              (7, _sessionsPanel(palette)),
              (
                4,
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _comparisons(palette),
                    const SizedBox(height: 16),
                    _playerPanel(palette, s),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _eventsPanel(palette),
          const SizedBox(height: 14),
          Text(
            'Старый журнал сессий: ${pepeTime(legacyMs)} за всё время. Он пересекается с новым журналом и не прибавляется к нему. Подробные интервалы собираются с версии 0.7.0.',
            style: TextStyle(color: palette.muted, fontSize: 12),
          ),
        ],
      ],
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
