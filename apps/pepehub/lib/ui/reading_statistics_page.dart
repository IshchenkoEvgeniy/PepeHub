import 'package:flutter/material.dart';

import '../data/repository.dart';
import '../library/activity_store.dart';
import '../reader/reading_activity.dart';
import '../reader/reading_library.dart';
import '../reader/reading_log.dart';
import 'audio_statistics_page.dart' show statTime;
import 'pepe_widgets.dart';
import 'shelf_components.dart';
import 'statistics_range.dart';
import 'reading_plan_page.dart';
import 'statistics_management_page.dart';

class ReadingStatisticsPage extends StatefulWidget {
  final Repository repository;
  final String? bookId;
  const ReadingStatisticsPage({
    super.key,
    required this.repository,
    this.bookId,
  });
  @override
  State<ReadingStatisticsPage> createState() => _ReadingStatisticsPageState();
}

class _ReadingStatisticsPageState extends State<ReadingStatisticsPage> {
  List<LibraryRecord> books = [];
  List<Map<String, dynamic>> sessions = [];
  final titles = <String, String>{};
  int period = 30, goal = 30, sessionLimit = 20;
  DateTimeRange? range;
  late DateTime calendar = DateTime(DateTime.now().year, DateTime.now().month);
  String? error;
  bool loading = true;
  bool savingJournal = false;
  List<String> journalFolders = [];
  String? lastJournalSave;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final library = ReadingLibrary(widget.repository);
      final b = (await widget.repository.records('book'))
          .where((b) => b.payload?['format'] != 'audio')
          .toList();
      final automatic = (await library.entries('reading-session:')).values
          .toList();
      final manual = (await widget.repository.records('session'))
          .where((s) => s.payload?['kind'] == 'reading');
      final rows = [
        ...automatic,
        ...await ActivityStore.foreignReading(widget.repository),
        for (final s in manual)
          {
            'id': s.id,
            'bookId': s.payload!['bookId'],
            'startedAt': s.payload!['startedAt'],
            'source': 'manual',
            'closed': true,
            'spans': ActivityStore.manualSpans(s.payload!),
          },
      ];
      final prefs = await library.entries('reading-book:'),
          index = await library.entries('reading-index:');
      final assets = await widget.repository.db
          .customSelect('SELECT book_id,sha256 FROM local_assets')
          .get();
      final hashes = {
        for (final a in assets)
          a.read<String>('book_id'): a.read<String>('sha256'),
      };
      final names = {
        for (final book in b)
          book.id:
              ReadingLibrary.effective({
                    ...book.payload!,
                    ...?(index[hashes[book.id]]),
                  }, prefs[book.id] ?? {})['title']
                  as String,
      };
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
      for (final book in b.where(
        (b) => widget.bookId == null || b.id == widget.bookId,
      )) {
        final warning = await widget.repository.meta(
          'reading-log-error:${book.id}',
        );
        if (warning != null && warning.isNotEmpty) {
          logWarnings.add('${names[book.id]}: $warning');
        }
      }
      if (mounted) {
        setState(() {
          books = b;
          sessions = rows.where((s) => names.containsKey(s['bookId'])).toList();
          titles
            ..clear()
            ..addAll(names);
          goal = g.clamp(0, 1440);
          journalFolders = folders;
          lastJournalSave = lastSave;
          error = logWarnings.isEmpty
              ? null
              : 'Данные в приложении сохранены, но журнал в папке не обновлён:\n${logWarnings.join('\n')}';
          loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
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
      if (mounted) setState(() => error = 'Не удалось записать журнал: $e');
    } finally {
      if (mounted) setState(() => savingJournal = false);
    }
  }

  Future<void> _goal() async {
    final input = TextEditingController(text: '$goal');
    final result = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ежедневная цель чтения'),
        content: TextField(
          controller: input,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Минут в день (1–1440)'),
        ),
        actions: [
          if (widget.bookId != null)
            IconButton(
              tooltip: 'План чтения',
              icon: const Icon(Icons.event_note),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ReadingPlanPage(
                    repository: widget.repository,
                    bookId: widget.bookId!,
                  ),
                ),
              ),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              final v = int.tryParse(input.text);
              if (v != null && v >= 1 && v <= 1440) Navigator.pop(context, v);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(seconds: 1), input.dispose);
    if (result == null) return;
    try {
      await widget.repository.setMeta('reading-daily-goal', '$result');
      if (mounted) setState(() => goal = result);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  String get _periodLabel => switch (period) {
    1 => 'за сегодня',
    7 => 'за 7 дней',
    30 => 'за 30 дней',
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
    final now = DateTime.now(),
        today = DateTime(now.year, now.month, now.day);
    final start = period < 0
            ? range?.start
            : period == 0
            ? null
            : DateTime(now.year, now.month, now.day - period + 1),
        end = period < 0 ? range?.end : null;
    final total = readingTotals(
      sessions,
      start: start,
      end: end,
      bookId: widget.bookId,
    );
    final all = readingTotals(sessions, bookId: widget.bookId);
    final global = readingTotals(sessions);
    final streak = readingStreak(all.days, now);
    final todayMs = global.days[readingDay(today)] ?? 0;
    final shown =
        sessions
            .where((s) => widget.bookId == null || s['bookId'] == widget.bookId)
            .where(
              (s) => readingTotals([s], start: start, end: end).sessions > 0,
            )
            .toList()
          ..sort(
            (a, b) =>
                (b['startedAt'] as String).compareTo(a['startedAt'] as String),
          );
    final week = readingTotals(
      sessions,
      start: DateTime(now.year, now.month, now.day - 6),
      bookId: widget.bookId,
    ).milliseconds;
    final previous = readingTotals(
      sessions,
      start: DateTime(now.year, now.month, now.day - 13),
      end: DateTime(now.year, now.month, now.day - 6),
      bookId: widget.bookId,
    ).milliseconds;
    final activeDays = total.days.values.where((v) => v > 0).length;
    final average = total.sessions == 0
        ? 0
        : total.milliseconds ~/ total.sessions;

    // Days shown as bars: the chosen period, at least two weeks.
    final barEnd = period < 0 && range != null
        ? DateTime(range!.end.year, range!.end.month, range!.end.day - 1)
        : today;
    final barCount = period < 0 && range != null
        ? range!.duration.inDays.clamp(7, 60)
        : period == 30 || period == 0
        ? 30
        : 14;
    final barDays = [
      for (var i = barCount - 1; i >= 0; i--)
        DateTime(barEnd.year, barEnd.month, barEnd.day - i),
    ];
    final streakDays = [
      for (var i = 29; i >= 0; i--)
        all.days[readingDay(DateTime(now.year, now.month, now.day - i))] ?? 0,
    ];

    final hero = _hero(palette, total.milliseconds, total.sessions, activeDays,
        average, week, previous);
    final goalPanel = PepePanel(
      title: 'Цель на сегодня · вся библиотека',
      trailing: IconButton(
        tooltip: 'Изменить цель чтения',
        onPressed: _goal,
        icon: const Icon(Icons.edit_outlined, size: 20),
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
            'последние 30 дней',
            style: TextStyle(fontSize: 11, color: palette.muted),
          ),
        ],
      ),
    );
    final barsPanel = PepePanel(
      title: 'По дням',
      trailing: goal > 0
          ? Text(
              '- - цель $goal мин',
              style: TextStyle(fontSize: 12, color: palette.muted),
            )
          : null,
      child: PepeBars(
        values: [for (final d in barDays) all.days[readingDay(d)] ?? 0],
        tooltips: [
          for (final d in barDays)
            '${pepeDate(d)} · ${statTime(all.days[readingDay(d)] ?? 0)}',
        ],
        goalMinutes: goal,
        startLabel: pepeDate(barDays.first),
        endLabel: barDays.last == today ? 'сегодня' : pepeDate(barDays.last),
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
                  pepeChars(total.newChars),
                  'Новое продвижение',
                  size: 24,
                  color: palette.accent,
                ),
              ),
              Expanded(
                child: PepeFigure(
                  pepeChars(total.repeatChars),
                  'Повторное чтение',
                  size: 24,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'Продвижение — оценка по обычному перелистыванию и прокрутке. Поиск и быстрые переходы не засчитываются. Ручные сессии добавляют только время.',
            style: TextStyle(fontSize: 11.5, height: 1.4, color: palette.muted),
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
        onDay: (date) => setState(() {
          period = -1;
          range = DateTimeRange(
            start: date,
            end: DateTime(date.year, date.month, date.day + 1),
          );
        }),
      ),
    );
    final perBook = books.where((b) => total.books.containsKey(b.id)).toList()
      ..sort((a, b) => total.books[b.id]!.compareTo(total.books[a.id]!));
    final booksPanel = PepePanel(
      title: 'По книгам',
      child: perBook.isEmpty
          ? Text(
              'За этот период книг нет.',
              style: TextStyle(color: palette.muted),
            )
          : Column(
              children: [
                for (final book in perBook)
                  PepeShareRow(
                    leading: PepeSpine(titles[book.id] ?? book.title),
                    title: titles[book.id] ?? book.title,
                    value: statTime(total.books[book.id]!),
                    note:
                        '${(total.books[book.id]! * 100 / total.milliseconds.clamp(1, 1 << 62)).round()}%',
                    share: total.books[book.id]! / total.milliseconds.clamp(1, 1 << 62),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ReadingStatisticsPage(
                          repository: widget.repository,
                          bookId: book.id,
                        ),
                      ),
                    ),
                  ),
              ],
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
    final journalPanel = _journal(palette);

    return PepeSubpage(
      title: widget.bookId == null
          ? 'Чтение'
          : titles[widget.bookId] ?? 'Статистика книги',
      back: widget.bookId == null ? 'Статистика' : 'Чтение',
      section: PepeSection.statistics,
      subtitle:
          'Учёт приостанавливается в фоне, в поиске/настройках и после 2 минут без действий.',
      onRefresh: _load,
      actions: [
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
            child: LinearProgressIndicator(),
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
              return;
            }
            final v = await pickStatisticsRange(context, range);
            if (v != null && mounted) {
              setState(() {
                range = v;
                period = -1;
              });
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
        if (MediaQuery.sizeOf(context).width < 1100) ...[
          hero,
          const SizedBox(height: 16),
          splitPanel,
          const SizedBox(height: 16),
          goalPanel,
          const SizedBox(height: 16),
          streakPanel,
          const SizedBox(height: 16),
          barsPanel,
        ] else ...[
          PepeRow(
            breakpoint: 0,
            children: [(6, hero), (4, goalPanel), (4, streakPanel)],
          ),
          const SizedBox(height: 16),
          PepeRow(children: [(7, barsPanel), (4, splitPanel)]),
        ],
        const SizedBox(height: 16),
        PepeRow(
          children: [
            (4, calendarPanel),
            if (widget.bookId == null) (7, booksPanel) else (7, sessionsPanel),
          ],
        ),
        const SizedBox(height: 16),
        if (widget.bookId == null)
          PepeRow(children: [(7, sessionsPanel), (4, journalPanel)])
        else
          journalPanel,
      ],
    );
  }

  Widget _hero(
    ShelfPalette palette,
    int ms,
    int count,
    int days,
    int average,
    int week,
    int previous,
  ) {
    final ink = palette.onAccent;
    final soft = ink.withValues(alpha: .72);
    final diff = week - previous;
    Widget figure(String value, String label) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: AppFonts.title(ink, size: 24)),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(fontSize: 12, color: soft)),
      ],
    );
    return Material(
      color: palette.accent,
      borderRadius: BorderRadius.circular(22),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
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
              child: Text(
                statTime(ms),
                style: AppFonts.title(ink, size: 58),
              ),
            ),
            Text(
              'Активное чтение · аудио не учитывается',
              style: TextStyle(fontSize: 13, color: soft),
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 28,
              runSpacing: 12,
              children: [
                figure('$count', 'Сессий за период'),
                figure('$days', 'Активных дней'),
                figure(count == 0 ? '—' : statTime(average), 'Средняя сессия'),
              ],
            ),
            const SizedBox(height: 16),
            Container(height: 1, color: ink.withValues(alpha: .25)),
            const SizedBox(height: 12),
            Row(
              children: [
                Icon(
                  diff >= 0 ? Icons.north_east : Icons.south_east,
                  size: 16,
                  color: ink,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Последние 7 дней: ${statTime(week)} · предыдущие: ${statTime(previous)}',
                    style: TextStyle(fontSize: 12.5, color: ink),
                  ),
                ),
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
      final kind = session['source'] == 'obsidian'
          ? 'Obsidian'
          : session['source'] == 'manual'
          ? 'Вручную'
          : session['closed'] == true
          ? 'Завершена'
          : 'Сохранённый интервал';
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
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  border: Border.all(color: palette.strongLine),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  kind,
                  style: TextStyle(fontSize: 11, color: palette.muted),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 76,
                child: Text(
                  statTime(
                    readingTotals([session], start: start, end: end)
                        .milliseconds,
                  ),
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

  Widget _journal(ShelfPalette palette) => PepePanel(
    title: 'Журнал чтения',
    child: Column(
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
                onPressed: savingJournal ? null : _saveJournal,
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('Записать журнал сейчас'),
              ),
            ),
          ),
      ],
    ),
  );

  String _savedAt(String value) {
    final at = DateTime.tryParse(value)?.toLocal();
    return at == null ? value : '${pepeDate(at)}, ${pepeClock(at)}';
  }
}
