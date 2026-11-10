import 'goal_settings_page.dart';
import 'reading_plan_page.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../library/library_service.dart';
import 'library_card_link.dart';

import '../data/repository.dart';
import '../reader/reading_activity.dart';
import '../reader/reading_statistics_data.dart';
import '../reader/reading_statistics_history.dart';
import '../statistics/statistics_period.dart';
import '../reader/reading_library.dart';
import '../reader/reading_log.dart';
import '../reader/reading_plan.dart';

import 'dart:io';

import 'audio_statistics_page.dart' show statTime;
import 'pepe_widgets.dart';
import 'shelf_components.dart';
import 'statistics_range.dart';
import 'statistics_management_page.dart';
import '../diagnostics/user_message.dart';

class ReadingStatisticsPage extends StatefulWidget {
  final Repository repository;
  final String? bookId;

  /// Lets a book's page open its library card.
  final LibraryService? library;
  const ReadingStatisticsPage({
    super.key,
    required this.repository,
    this.bookId,
    this.library,
  });
  @override
  State<ReadingStatisticsPage> createState() => _ReadingStatisticsPageState();
}

class _ReadingStatisticsPageState extends State<ReadingStatisticsPage> {
  List<LibraryRecord> books = [];
  final _worker = ReadingStatisticsWorker();
  ReadingStatisticsData _stats = ReadingStatisticsData.empty();
  int _calculation = 0;
  final titles = <String, String>{};
  int period = 30, goal = 30, sessionLimit = 20;
  DateTimeRange? range;
  late DateTime calendar = DateTime(DateTime.now().year, DateTime.now().month);
  String? error;
  bool loading = true;
  bool savingJournal = false;
  List<String> journalFolders = [];
  String? lastJournalSave;
  Future<void>? _loadingWork;
  bool _loadAgain = false;
  Map<String, String> covers = {};

  /// Per-book page only: progress, remaining time and expected finish.
  ReadingForecast? forecast;
  ReadingPlan bookPlan = const ReadingPlan();
  int bookLength = 0;
  @override
  void initState() {
    super.initState();
    widget.repository.externalChanges.addListener(_externalChanged);
    _load();
  }

  @override
  void dispose() {
    widget.repository.externalChanges.removeListener(_externalChanged);
    _worker.dispose();
    super.dispose();
  }

  void _externalChanged() {
    if (mounted) unawaited(_load());
  }

  Future<void> _calculate({List<Map<String, dynamic>>? rows}) async {
    final request = ++_calculation;
    final now = DateTime.now();
    if (mounted) setState(() => loading = true);
    try {
      final result = await _worker.analyze({
        'sessions': ?rows,
        'book': widget.bookId,
        'now': now,
        'start': period < 0 ? range?.start : null,
        'end': period < 0 ? range?.end : null,
        'startDay': period > 0
            ? readingDay(DateTime(now.year, now.month, now.day - period + 1))
            : null,
        'endDay': period > 0
            ? readingDay(DateTime(now.year, now.month, now.day + 1))
            : null,
      });
      if (mounted && request == _calculation) {
        setState(() {
          _stats = result;
          loading = false;
        });
      }
    } catch (e) {
      if (mounted && request == _calculation) {
        setState(() {
          error = describeError(e);
          loading = false;
        });
      }
    }
  }

  Future<void> _load() async {
    if (_loadingWork != null) {
      _loadAgain = true;
      return _loadingWork;
    }
    final work = _drainLoads();
    _loadingWork = work;
    try {
      await work;
    } finally {
      _loadingWork = null;
    }
  }

  Future<void> _drainLoads() async {
    do {
      _loadAgain = false;
      await _loadOnce();
    } while (_loadAgain && mounted);
  }

  Future<void> _loadOnce() async {
    try {
      final library = ReadingLibrary(widget.repository);
      final history = await ReadingStatisticsHistory.load(widget.repository);
      final b = (await widget.repository.bookHeaders())
          .where((b) => b.payload?['format'] != 'audio')
          .toList();
      final names = history.titles;
      final g =
          int.tryParse(
            await widget.repository.meta('reading-daily-goal') ?? '',
          ) ??
          30;
      final logWarnings = <String>[];
      final configuredRoots = await library.entries('reading-library-root:');
      final folders = configuredRoots.values
          .where(
            (root) =>
                widget.bookId == null ||
                (root['bookIds'] as List? ?? []).contains(widget.bookId),
          )
          .map((root) => '${root['path']}/.pepehub/reading/logs')
          .toList();
      final lastSave = widget.bookId == null
          ? null
          : await widget.repository.meta('reading-log-saved:${widget.bookId}');
      final warnings = await widget.repository.metadataPrefixes([
        'reading-log-error:',
      ]);
      var coverPaths = <String, String>{};
      try {
        coverPaths = await library.coverPaths();
      } catch (_) {
        /* Covers are decoration; spines remain. */
      }
      ReadingForecast? bookForecast;
      var plan = const ReadingPlan();
      var length = 0;
      if (widget.bookId != null) {
        try {
          final data = await ReadingPlans(widget.repository)
              .load(widget.bookId!);
          bookForecast = (await analyzeReadingPlan(
            data,
            widget.bookId!,
            DateTime.now(),
          )).forecast;
          plan = data.saved ?? const ReadingPlan();
          length = data.length;
        } catch (_) {
          /* A card without a file has no text to forecast. */
        }
      }
      for (final book in b.where(
        (b) => widget.bookId == null || b.id == widget.bookId,
      )) {
        final warning = warnings['reading-log-error:${book.id}'];
        if (warning != null && warning.isNotEmpty) {
          logWarnings.add('${names[book.id]}: $warning');
        }
      }
      if (mounted) {
        setState(() {
          books = b;

          titles
            ..clear()
            ..addAll(names);
          goal = g.clamp(0, 1440);
          covers = coverPaths;
          forecast = bookForecast;
          bookPlan = plan;
          bookLength = length;
          journalFolders = folders;
          lastJournalSave = lastSave;
          error = logWarnings.isEmpty
              ? null
              : 'Данные в приложении сохранены, но журнал в папке не обновлён:\n${logWarnings.join('\n')}';
        });
        await _calculate(rows: history.sessions);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = describeError(e);
          loading = false;
        });
      }
    }
  }

  Future<void> _saveJournal() async {
    if (savingJournal) return;
    setState(() => savingJournal = true);
    try {
      final count = await ReadingLog(widget.repository)
          .exportAll(bookId: widget.bookId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Журнал обновлён: $count дней чтения.')),
        );
        await _load();
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => error = 'Не удалось записать журнал: ${describeError(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => savingJournal = false);
    }
  }

  Future<void> _goal() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => GoalSettingsPage(repository: widget.repository),
      ),
    );
    try {
      final saved = await widget.repository.meta('reading-daily-goal');
      if (mounted) {
        setState(() => goal = (int.tryParse(saved ?? '') ?? 30).clamp(0, 1440));
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = 'Не удалось обновить цель: ${describeError(e)}');
      }
    }
  }

  String get _periodLabel => switch (period) {
    1 => 'за сегодня',
    7 => 'за 7 дней',
    30 => 'за 30 дней',
    365 => 'за 365 дней',
    0 => 'за всё время',
    _ => range == null ? 'за период' : rangeLabel(range!),
  };

  Future<void> _manage() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => StatisticsManagementPage(
          repository: widget.repository,
          initialTab: 0,
        ),
      ),
    );
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final now = DateTime.now(), today = DateTime(now.year, now.month, now.day);
    final start = period < 0
            ? range?.start
            : period == 0
            ? null
            : DateTime(now.year, now.month, now.day - period + 1),
        end = period < 0 ? range?.end : null;
    final total = _stats.total, all = _stats.all, global = _stats.global;
    final streak = _stats.streak;
    final todayMs = global.days[readingDay(today)] ?? 0;
    final shown = _stats.shown;
    final activeDays = total.days.values.where((v) => v > 0).length;
    final average = total.sessions == 0
        ? 0
        : total.milliseconds ~/ total.sessions;

    final chart = statisticsChartWindow(
      now,
      period: period,
      start: range?.start,
      end: range?.end,
    );
    final barDays = chart.days;
    final streakDays = [
      for (var i = 29; i >= 0; i--)
        all.days[readingDay(DateTime(now.year, now.month, now.day - i))] ?? 0,
    ];

    final hero = _hero(
      palette,
      total.milliseconds,
      total.sessions,
      activeDays,
      average,
    );
    final goalPanel = PepePanel(
      title: 'Цель на сегодня · вся библиотека',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Настроить цели',
            onPressed: _goal,
            icon: const Icon(Icons.tune, size: 20),
          ),
        ],
      ),
      child: Row(
        children: [
          PepeRing(
            value: goal == 0 ? 0 : todayMs / (goal * 60000),
            center: '${todayMs ~/ 60000}',
            below: goal == 0 ? 'мин' : 'из $goal мин',
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  goal == 0
                      ? 'Цель не задана'
                      : todayMs >= goal * 60000
                      ? 'Цель выполнена'
                      : 'Осталось ${statTime(goal * 60000 - todayMs)}',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Считается всё чтение за сегодня, по всем книгам.',
                  style: TextStyle(fontSize: 12, color: palette.muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    final streakPanel = PepePanel(
      title: 'Дней подряд / рекорд',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '${streak.current}',
                  style: AppFonts.title(palette.text, size: 44),
                ),
                TextSpan(
                  text: '  рекорд ${streak.best}',
                  style: TextStyle(fontSize: 14, color: palette.muted),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          PepeStreak(values: streakDays, goalMinutes: goal),
          const SizedBox(height: 6),
          Text(
            'последние 30 дней · день серии: от 5 минут',
            style: TextStyle(fontSize: 11, color: palette.muted),
          ),
        ],
      ),
    );
    final barsPanel = PepePanel(
      title: chart.limited
          ? 'По дням · последние ${barDays.length} дней периода'
          : 'По дням',
      trailing: goal > 0
          ? Text(
              '- - цель $goal мин',
              style: TextStyle(fontSize: 12, color: palette.muted),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (chart.limited)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('Итоги выше рассчитаны за весь выбранный период.'),
            ),
          PepeBars(
            values: [for (final d in barDays) total.days[readingDay(d)] ?? 0],
            tooltips: [
              for (final d in barDays)
                '${pepeDate(d)} · ${statTime(total.days[readingDay(d)] ?? 0)}',
            ],
            goalMinutes: goal,
            startLabel: pepeDate(barDays.first),
            endLabel: barDays.last == today
                ? 'сегодня'
                : pepeDate(barDays.last),
          ),
        ],
      ),
    );
    final chars = total.newChars + total.repeatChars;
    final splitPanel = PepePanel(
      title: 'Новое и перечитанное',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 14,
              child: Row(
                children: [
                  if (chars == 0)
                    Expanded(child: ColoredBox(color: palette.raised))
                  else ...[
                    Expanded(
                      flex: (total.newChars * 1000 ~/ chars).clamp(1, 1000),
                      child: ColoredBox(color: palette.accent),
                    ),
                    Expanded(
                      flex: (total.repeatChars * 1000 ~/ chars).clamp(1, 1000),
                      child: ColoredBox(color: palette.muted),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: PepeFigure(
                  pepePages(total.newChars),
                  'Новое продвижение',
                  size: 24,
                  color: palette.accent,
                ),
              ),
              Expanded(
                child: PepeFigure(
                  pepePages(total.repeatChars),
                  'Повторное чтение',
                  size: 24,
                ),
              ),
            ],
          ),
        ],
      ),
    );
    final calendarPanel = PepePanel(
      child: PepeMonthCalendar(
        month: calendar,
        title:
            'Календарь · ${pepeMonthNames[calendar.month - 1]} ${calendar.year}',
        dayValue: (d) => all.days[readingDay(d)] ?? 0,
        goalMinutes: goal,
        describe: statTime,
        onPrevious: () => setState(
          () => calendar = DateTime(calendar.year, calendar.month - 1),
        ),
        onNext: () => setState(
          () => calendar = DateTime(calendar.year, calendar.month + 1),
        ),
        onDay: (date) {
          setState(() {
            period = -1;
            range = DateTimeRange(
              start: date,
              end: DateTime(date.year, date.month, date.day + 1),
            );
          });
          unawaited(_calculate());
        },
      ),
    );
    final perBook = total.books.keys.toList()
      ..sort((a, b) => total.books[b]!.compareTo(total.books[a]!));
    final booksPanel = PepePanel(
      title: 'По книгам',
      child: perBook.isEmpty
          ? Text(
              'За этот период книг нет.',
              style: TextStyle(color: palette.muted),
            )
          : SizedBox(
              height: (perBook.length * 84.0).clamp(84, 420),
              child: ListView.builder(
                key: const ValueKey('reading-statistics-books'),
                primary: false,
                itemCount: perBook.length,
                itemBuilder: (context, index) {
                  final id = perBook[index],
                      title = titles[id] ?? 'Книга без файла';
                  return PepeShareRow(
                    key: ValueKey('reading-statistics-book:$id'),
                    leading: _cover(id, title),
                    title: title,
                    value: statTime(total.books[id]!),
                    note:
                        '${(total.books[id]! * 100 / total.milliseconds.clamp(1, 1 << 62)).round()}%',
                    share:
                        total.books[id]! / total.milliseconds.clamp(1, 1 << 62),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ReadingStatisticsPage(
                          repository: widget.repository,
                          bookId: id,
                          library: widget.library,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
    );
    final sessionsPanel = PepePanel(
      title: 'Сессии',
      trailing: Text(
        '${shown.length}',
        style: TextStyle(fontSize: 13, color: palette.muted),
      ),
      child: _sessions(palette, shown, start, end),
    );
    final bookPanel = widget.bookId == null ? null : _bookPanel(palette);

    return PepeSubpage(
      title: widget.bookId == null
          ? 'Чтение'
          : titles[widget.bookId] ?? 'Статистика книги',
      back: widget.bookId == null ? 'Статистика' : 'Чтение',
      section: PepeSection.statistics,
      onRefresh: _load,
      actions: [
        ?libraryCardAction(context, widget.library, widget.bookId),
        IconButton(
          tooltip: 'О статистике и экспорт журнала',
          onPressed: _info,
          icon: const Icon(Icons.info_outline),
        ),
        IconButton(
          tooltip: 'Управление статистикой',
          onPressed: _manage,
          icon: const Icon(Icons.edit_note),
        ),
        IconButton(
          tooltip: 'Обновить статистику',
          onPressed: _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
      children: [
        if (loading)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: LinearProgressIndicator(
              key: ValueKey('reading-statistics-loading'),
            ),
          ),
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
        PepeChoices<int>(
          options: const [...statisticsDayPeriods, (-1, 'Произвольный')],
          selected: period,
          onSelect: (p) async {
            if (p != -1) {
              setState(() => period = p);
              await _calculate();
              return;
            }
            final v = await pickStatisticsRange(context, range);
            if (v != null && mounted) {
              setState(() {
                range = v;
                period = -1;
              });
              await _calculate();
            }
          },
        ),
        if (period == -1 && range != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              rangeLabel(range!),
              style: TextStyle(fontSize: 12, color: palette.muted),
            ),
          ),
        const SizedBox(height: 18),
        // Everyday figures first: today's goal and the streak, then totals.
        if (MediaQuery.sizeOf(context).width < 1100) ...[
          if (bookPanel != null) ...[bookPanel, const SizedBox(height: 16)],
          goalPanel,
          const SizedBox(height: 16),
          streakPanel,
          const SizedBox(height: 16),
          hero,
          const SizedBox(height: 16),
          barsPanel,
          const SizedBox(height: 16),
          widget.bookId == null ? booksPanel : sessionsPanel,
          const SizedBox(height: 16),
          calendarPanel,
          const SizedBox(height: 16),
          _comparison(),
          const SizedBox(height: 16),
          splitPanel,
          if (widget.bookId == null) ...[
            const SizedBox(height: 16),
            sessionsPanel,
          ],
        ] else ...[
          if (bookPanel != null) ...[bookPanel, const SizedBox(height: 16)],
          PepeRow(
            breakpoint: 0,
            children: [(4, goalPanel), (4, streakPanel), (6, hero)],
          ),
          const SizedBox(height: 16),
          PepeRow(children: [(7, barsPanel), (4, calendarPanel)]),
          const SizedBox(height: 16),
          PepeRow(
            children: [
              (7, widget.bookId == null ? booksPanel : sessionsPanel),
              (4, _comparison()),
            ],
          ),
          const SizedBox(height: 16),
          if (widget.bookId == null)
            PepeRow(children: [(7, sessionsPanel), (4, splitPanel)])
          else
            splitPanel,
        ],
      ],
    );
  }

  Widget _comparison() {
    final previous = _stats.previousPeriod, current = _stats.total;
    Widget row(
      String label,
      int value,
      int before,
      String Function(int) format,
    ) => ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label),
      subtitle: Text('${format(value)} · раньше ${format(before)}'),
      trailing: Text(
        before == 0
            ? (value == 0 ? '0%' : '—')
            : '${value >= before ? '+' : ''}${((value - before) * 100 / before).toStringAsFixed(0)}%',
      ),
    );
    return PepePanel(
      title: 'Сравнение периодов',
      child: previous == null
          ? const Text(
              'Выберите 1, 7, 30, 365 дней или произвольный период для сравнения с предыдущим периодом такой же длины.',
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'С предыдущим периодом такой же длины.',
                  style: TextStyle(
                    fontSize: 12,
                    color: ShelfPalette.of(context).muted,
                  ),
                ),
                row(
                  'Время чтения',
                  current.milliseconds,
                  previous.milliseconds,
                  statTime,
                ),
                row('Сессии', current.sessions, previous.sessions, (v) => '$v'),
                row(
                  'Дни с чтением',
                  current.days.values.where((v) => v > 0).length,
                  previous.days.values.where((v) => v > 0).length,
                  (v) => '$v',
                ),
                row(
                  'Новое продвижение',
                  current.newChars,
                  previous.newChars,
                  pepePages,
                ),
              ],
            ),
    );
  }

  Widget _hero(ShelfPalette palette, int ms, int count, int days, int average) {
    final ink = palette.onAccent;
    final soft = ink.withValues(alpha: .72);
    Widget figure(String value, String label) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: AppFonts.title(ink, size: 20)),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(fontSize: 12, color: soft)),
      ],
    );
    return Material(
      color: palette.accent,
      borderRadius: BorderRadius.circular(22),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _periodLabel.toUpperCase(),
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
              child: Text(statTime(ms), style: AppFonts.title(ink, size: 34)),
            ),
            Text(
              'Активное чтение · аудио не учитывается',
              style: TextStyle(fontSize: 13, color: soft),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 24,
              runSpacing: 12,
              children: [
                figure('$count', 'Сессий за период'),
                figure('$days', 'Активных дней'),
                figure(count == 0 ? '—' : statTime(average), 'Средняя сессия'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _sessions(
    ShelfPalette palette,
    List<Map<String, dynamic>> shown,
    DateTime? start,
    DateTime? end,
  ) {
    if (shown.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          'За этот период чтения пока нет.',
          style: TextStyle(color: palette.muted),
        ),
      );
    }
    final rows = <Widget>[];
    String? lastDay;
    for (final session in shown.take(sessionLimit)) {
      final known = session['timeKnown'] != false;
      final at = known
          ? DateTime.parse(session['startedAt'] as String).toLocal()
          : DateTime.tryParse('${session['day']}') ??
                DateTime.parse(session['startedAt'] as String).toLocal();
      final day = readingDay(at);
      if (day != lastDay) {
        lastDay = day;
        rows.add(
          Padding(
            padding: EdgeInsets.only(top: rows.isEmpty ? 0 : 14, bottom: 4),
            child: Text(
              '${pepeDate(at)} · ${pepeWeekdays[at.weekday - 1]}',
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
      // Tracked sessions need no label; only other sources are marked.
      final kind = session['source'] == 'obsidian'
          ? 'Библиотека'
          : session['source'] == 'manual'
          ? 'Вручную'
          : null;
      rows.add(
        Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: palette.line)),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 48,
                child: Text(
                  known ? pepeClock(at) : '—',
                  style: TextStyle(fontSize: 13, color: palette.muted),
                ),
              ),
              Expanded(
                child: Text(
                  titles[session['bookId']] ?? 'Книга',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.book(palette.text, size: 16),
                ),
              ),
              if (kind != null) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: palette.strongLine),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    kind,
                    style: TextStyle(fontSize: 11, color: palette.muted),
                  ),
                ),
              ],
              const SizedBox(width: 10),
              SizedBox(
                width: 76,
                child: Text(
                  statTime(session['_milliseconds'] as int),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...rows,
        if (shown.length > sessionLimit)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() => sessionLimit += 20),
              child: const Text('Показать ещё'),
            ),
          ),
      ],
    );
  }

  Widget _journal(ShelfPalette palette, StateSetter? setSheet) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        'Экспорт в папку · Markdown / JSON',
        style: Theme.of(context).textTheme.titleSmall,
      ),
      const SizedBox(height: 6),
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            journalFolders.isEmpty
                ? 'Сессии хранятся в приложении. Подключите папку книг, чтобы рядом с книгами появился каталог .pepehub/reading/logs.'
                : 'При открытии книги и затем примерно каждые 30 секунд данные записываются в .pepehub/reading/logs. Также сохраняются при закрытии и переходах.',
            style: TextStyle(fontSize: 12.5, height: 1.4, color: palette.muted),
          ),
          for (final folder in journalFolders)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: palette.raised,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Icon(Icons.folder_outlined, size: 16, color: palette.muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SelectableText(
                      folder,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          if (lastJournalSave != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Последнее сохранение: ${_savedAt(lastJournalSave!)}',
                style: TextStyle(fontSize: 12, color: palette.muted),
              ),
            ),
          if (journalFolders.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  onPressed: savingJournal
                      ? null
                      : () async {
                          await _saveJournal();
                          setSheet?.call(() {});
                        },
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: const Text('Записать журнал сейчас'),
                ),
              ),
            ),
        ],
      ),
    ],
  );

  /// Service details kept off the main page: how time is counted and the
  /// journal export.
  Future<void> _info() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setSheet) {
        final palette = ShelfPalette.of(sheetContext);
        final muted = TextStyle(
          fontSize: 13,
          height: 1.4,
          color: palette.muted,
        );
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'О статистике',
                  style: Theme.of(sheetContext).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Text(
                  'Учёт приостанавливается в фоне, в поиске и настройках, а также после 2 минут без действий. Аудиокниги здесь не учитываются.',
                  style: muted,
                ),
                const SizedBox(height: 8),
                Text(
                  'Продвижение — оценка по обычному перелистыванию и прокрутке. Поиск и быстрые переходы не засчитываются, ручные сессии добавляют только время. Страница — около $pepeCharsPerPage знаков.',
                  style: muted,
                ),
                const SizedBox(height: 8),
                Text(
                  'Сравнение идёт с предыдущим периодом такой же длины. Сегодняшний день ещё не завершён; при нулевой базе процент не рассчитывается.',
                  style: muted,
                ),
                const Divider(height: 32),
                _journal(palette, setSheet),
              ],
            ),
          ),
        );
      },
    ),
  );

  Widget _cover(String id, String title) {
    final path = covers[id];
    final spine = PepeSpine(title);
    if (path == null) return spine;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Image.file(
        File(path),
        width: 32,
        height: 48,
        fit: BoxFit.cover,
        cacheWidth: 96,
        errorBuilder: (_, _, _) => spine,
      ),
    );
  }

  /// Progress, remaining time and expected finish of the opened book.
  Widget _bookPanel(ShelfPalette palette) {
    final f = forecast;
    final title = titles[widget.bookId] ?? 'Книга';
    final target = f?.targetChars;
    final covered = f?.coveredChars ?? 0;
    final progress = bookLength <= 0
        ? null
        : (covered / bookLength).clamp(0.0, 1.0);
    final lines = <String>[];
    String headline;
    if (f == null || target == null) {
      headline = 'Нет текста для прогноза';
      lines.add(
        'Откройте книгу на этом устройстве, чтобы появились прогресс и прогноз.',
      );
    } else if (f.remainingChars == 0) {
      headline = bookPlan.targetPercent < 100
          ? 'Цель ${bookPlan.targetPercent}% достигнута'
          : 'Книга прочитана';
    } else {
      final remainingPages = pepePages(f.remainingChars!);
      if (f.remainingMinutes == null) {
        headline = 'Осталось $remainingPages';
        lines.add(
          'Время появится, когда наберётся минута обычного чтения этой книги.',
        );
      } else {
        headline = 'Осталось ≈ ${statTime(f.remainingMinutes! * 60000)}';
        lines.add(
          '$remainingPages · ${(f.charsPerMinute! * 60 / pepeCharsPerPage).round()} стр. в час',
        );
      }
      if (f.expectedDate != null) {
        final d = f.expectedDate!;
        lines.add(
          'Закончите ≈ ${d.day} ${pepeMonthGenitive[d.month - 1]}${d.year == DateTime.now().year ? '' : ' ${d.year}'} при ${bookPlan.dailyMinutes} мин в день',
        );
      }
      if (f.overdue) lines.add('Срок плана уже прошёл.');
    }
    return PepePanel(
      title: title,
      trailing: IconButton(
        tooltip: 'План чтения',
        icon: const Icon(Icons.event_note, size: 20),
        onPressed: () => Navigator.push<void>(
          context,
          MaterialPageRoute(
            builder: (_) => ReadingPlanPage(
              repository: widget.repository,
              bookId: widget.bookId!,
            ),
          ),
        ).then((_) => _load()),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 48, height: 72, child: _cover(widget.bookId!, title)),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (progress != null)
                  Text(
                    '${(progress * 100).round()}% прочитано',
                    style: AppFonts.title(palette.text, size: 22),
                  ),
                const SizedBox(height: 2),
                Text(
                  headline,
                  key: const ValueKey('reading-book-forecast'),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                for (final line in lines)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      line,
                      style: TextStyle(fontSize: 12.5, color: palette.muted),
                    ),
                  ),
                if (progress != null) ...[
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 4,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _savedAt(String value) {
    final at = DateTime.tryParse(value)?.toLocal();
    return at == null ? value : '${pepeDate(at)}, ${pepeClock(at)}';
  }
}
