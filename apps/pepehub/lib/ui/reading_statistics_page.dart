import 'package:flutter/material.dart';

import '../data/repository.dart';
import '../reader/reading_activity.dart';
import '../reader/reading_library.dart';
import 'statistics_range.dart';
import 'audio_statistics_page.dart' show statTime;
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
        for (final s in manual)
          {
            'id': s.id,
            'bookId': s.payload!['bookId'],
            'startedAt': s.payload!['startedAt'],
            'source': 'manual',
            'closed': true,
            'spans': [
              {
                'start': s.payload!['startedAt'],
                'end': s.payload!['endedAt'],
                'activeMs':
                    ((s.payload!['activeSeconds'] as num?)?.toInt() ?? 0) *
                    1000,
              },
            ],
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
          goal = g.clamp(1, 1440);
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

  Widget _metric(String title, String value, IconData icon) => SizedBox(
    width: 155,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20),
            const SizedBox(height: 8),
            Text(value, style: Theme.of(context).textTheme.titleLarge),
            Text(title, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final now = DateTime.now(),
        today = DateTime(
          DateTime.now().year,
          DateTime.now().month,
          DateTime.now().day,
        );
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
    final offset = calendar.weekday - 1,
        count = DateTime(calendar.year, calendar.month + 1, 0).day;
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
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.bookId == null
              ? 'Статистика чтения'
              : titles[widget.bookId] ?? 'Статистика книги',
        ),
        actions: [
          IconButton(
            tooltip: 'Управление статистикой',
            onPressed: () async {
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
            },
            icon: const Icon(Icons.edit_note),
          ),
          IconButton(
            tooltip: 'Обновить статистику',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (loading) const LinearProgressIndicator(),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          Text(
            statTime(total.milliseconds),
            style: Theme.of(context).textTheme.displaySmall,
          ),
          const Text('Активное чтение · аудио не учитывается'),
          const Text(
            'Учёт приостанавливается в фоне, в поиске/настройках и после 2 минут без действий.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 12),
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
                  onSelected: (_) => setState(() => period = p),
                ),
              ChoiceChip(
                label: const Text('Произвольный'),
                selected: period == -1,
                onSelected: (_) async {
                  final v = await pickStatisticsRange(context, range);
                  if (v != null && mounted) {
                    setState(() {
                      range = v;
                      period = -1;
                    });
                  }
                },
              ),
            ],
          ),
          if (period == -1 && range != null) Text(rangeLabel(range!)),
          const SizedBox(height: 12),
          Wrap(
            children: [
              _metric('Сессий за период', '${total.sessions}', Icons.menu_book),
              _metric(
                'Новое продвижение',
                '${total.newChars} зн.',
                Icons.trending_up,
              ),
              _metric(
                'Повторное чтение',
                '${total.repeatChars} зн.',
                Icons.replay,
              ),
              _metric(
                'Дней подряд / рекорд',
                '${streak.current} / ${streak.best}',
                Icons.local_fire_department_outlined,
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Text(
              'Продвижение — оценка по обычному перелистыванию и прокрутке. Поиск и быстрые переходы не засчитываются. Ручные сессии добавляют только время. При обрезке периода продвижение распределяется внутри активного интервала пропорционально времени.',
              style: TextStyle(fontSize: 12),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text('Цель на сегодня · вся библиотека'),
                      ),
                      IconButton(
                        tooltip: 'Изменить цель чтения',
                        onPressed: _goal,
                        icon: const Icon(Icons.edit_outlined),
                      ),
                    ],
                  ),
                  Text('${statTime(todayMs)} / $goal мин'),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: (todayMs / (goal * 60000)).clamp(0, 1),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Последние 7 дней: ${statTime(week)} · предыдущие: ${statTime(previous)}',
            ),
          ),
          Row(
            children: [
              IconButton(
                tooltip: 'Предыдущий месяц',
                onPressed: () => setState(
                  () => calendar = DateTime(calendar.year, calendar.month - 1),
                ),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Text(
                  'Календарь · ${calendar.month.toString().padLeft(2, '0')}.${calendar.year}',
                  textAlign: TextAlign.center,
                ),
              ),
              IconButton(
                tooltip: 'Следующий месяц',
                onPressed: () => setState(
                  () => calendar = DateTime(calendar.year, calendar.month + 1),
                ),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          Row(
            children: [
              for (final d in ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'])
                Expanded(child: Text(d, textAlign: TextAlign.center)),
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
            itemCount: offset + count,
            itemBuilder: (context, i) {
              if (i < offset) return const SizedBox();
              final date = DateTime(
                    calendar.year,
                    calendar.month,
                    i - offset + 1,
                  ),
                  ms =
                      all.days[readingDay(
                        DateTime(calendar.year, calendar.month, i - offset + 1),
                      )] ??
                      0;
              return Tooltip(
                message: statTime(ms),
                child: InkWell(
                  onTap: () => setState(() {
                    period = -1;
                    range = DateTimeRange(
                      start: date,
                      end: DateTime(date.year, date.month, date.day + 1),
                    );
                  }),
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: ms > 0
                          ? Theme.of(context).colorScheme.primaryContainer
                          : Theme.of(context).colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${date.day}',
                      style: TextStyle(
                        fontWeight: ms > 0
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 20),
          if (widget.bookId == null) ...[
            Text('По книгам', style: Theme.of(context).textTheme.titleLarge),
            for (final book in books.where(
              (b) => total.books.containsKey(b.id),
            ))
              ListTile(
                leading: const Icon(Icons.menu_book),
                title: Text(titles[book.id] ?? book.title),
                trailing: Text(statTime(total.books[book.id]!)),
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
          const SizedBox(height: 12),
          Text('Сессии', style: Theme.of(context).textTheme.titleLarge),
          if (shown.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('За этот период чтения пока нет.'),
            ),
          for (final session in shown.take(sessionLimit))
            ListTile(
              title: Text(titles[session['bookId']] ?? 'Книга'),
              subtitle: Text(
                '${DateTime.parse(session['startedAt'] as String).toLocal().toString().substring(0, 16)} · ${session['source'] == 'manual'
                    ? 'Вручную'
                    : session['closed'] == true
                    ? 'Завершена'
                    : 'Сохранённый интервал'}',
              ),
              trailing: Text(
                statTime(
                  readingTotals([session], start: start, end: end).milliseconds,
                ),
              ),
            ),
          if (shown.length > sessionLimit)
            TextButton(
              onPressed: () => setState(() => sessionLimit += 20),
              child: const Text('Показать ещё'),
            ),
        ],
      ),
    );
  }
}
