import 'package:flutter/material.dart';

import '../data/repository.dart';
import '../library/library_service.dart';
import '../library/reading_insights.dart';
import 'library_work_page.dart';
import 'obsidian_library_dashboard.dart' show ShelfBookCover;

class AnnualBookStatistics extends StatefulWidget {
  final Repository repository;
  final LibraryService? library;
  final int year;
  final String scope;
  final Map<String, int> readingDays, audioDays;
  final ValueChanged<int> onYear;
  final ValueChanged<String> onScope;
  const AnnualBookStatistics({
    super.key,
    required this.repository,
    this.library,
    required this.year,
    required this.scope,
    required this.readingDays,
    required this.audioDays,
    required this.onYear,
    required this.onScope,
  });
  @override
  State<AnnualBookStatistics> createState() => _AnnualBookStatisticsState();
}

class _AnnualBookStatisticsState extends State<AnnualBookStatistics> {
  int? goal;
  String get _goalKey => 'library-year-goal:personal:${widget.year}';
  @override
  void initState() {
    super.initState();
    _loadGoal();
  }

  @override
  void didUpdateWidget(AnnualBookStatistics old) {
    super.didUpdateWidget(old);
    if (old.year != widget.year) {
      goal = null;
      _loadGoal();
    }
  }

  Future<void> _loadGoal() async {
    final key = _goalKey;
    final value = int.tryParse(await widget.repository.meta(key) ?? '');
    if (mounted && key == _goalKey) {
      setState(() => goal = value != null && value > 0 ? value : null);
    }
  }

  Future<void> _setGoal() async {
    var value = '${goal ?? 12}';
    final key = _goalKey;
    final result = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text('Цель на ${widget.year} год'),
          content: TextFormField(
            initialValue: value,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Книг и аудиокниг',
              helperText: 'От 1 до 10000',
            ),
            onChanged: (v) => update(() => value = v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed:
                  (int.tryParse(value) ?? 0) > 0 &&
                      (int.tryParse(value) ?? 0) <= 10000
                  ? () => Navigator.pop(context, int.parse(value))
                  : null,
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    await widget.repository.setMeta(key, '$result');
    if (mounted && key == _goalKey) setState(() => goal = result);
  }

  @override
  Widget build(BuildContext context) {
    final library = widget.library;
    final completed = booksCompletedInYear(
      library?.visibleEntries ?? [],
      widget.year,
      scope: widget.scope,
    );
    final allCompleted = booksCompletedInYear(
      library?.visibleEntries ?? [],
      widget.year,
    );
    final readings = completed
        .where((b) => b.entry.item.mediaType == 'book')
        .length;
    final ratings = completed.map((b) => b.rating).whereType<double>().toList();
    final average = ratings.isEmpty
        ? '—'
        : (ratings.reduce((a, b) => a + b) / ratings.length).toStringAsFixed(1);
    final months = List<int>.filled(12, 0),
        timeMonths = List<int>.filled(12, 0);
    final days = <String, int>{};
    for (final source in [
      if (widget.scope != 'audio') widget.readingDays,
      if (widget.scope != 'reading') widget.audioDays,
    ]) {
      for (final e in source.entries) {
        days[e.key] = (days[e.key] ?? 0) + e.value;
      }
    }
    for (final b in completed) {
      months[b.date.month - 1]++;
    }
    for (final e in days.entries) {
      final date = bookDate(e.key);
      if (date != null && date.year == widget.year) {
        timeMonths[date.month - 1] += e.value;
      }
    }
    final totalTime = timeMonths.fold<int>(0, (a, b) => a + b);
    final pageBooks = completed
        .where(
          (b) =>
              b.entry.item.value('unit') == 'pages' &&
              (num.tryParse('${b.entry.item.value('total')}') ?? 0) > 0,
        )
        .toList();
    final pages = pageBooks.fold<num>(
      0,
      (sum, b) => sum + num.parse('${b.entry.item.value('total')}'),
    );
    pageBooks.sort(
      (a, b) =>
          num.parse('${b.entry.item.value('total')}')
              .compareTo(num.parse('${a.entry.item.value('total')}')),
    );
    final ratingLevels = ratings.toSet().toList()
      ..sort((a, b) => b.compareTo(a));
    final denominator = widget.year == DateTime.now().year
        ? DateTime.now().month
        : 12;
    final rows = <Widget Function()>[
      () => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final (key, label) in const [
            ('all', 'Всё'),
            ('reading', 'Книги'),
            ('audio', 'Аудио'),
          ])
            ChoiceChip(
              label: Text(label),
              selected: widget.scope == key,
              onSelected: (_) => widget.onScope(key),
            ),
        ],
      ),
      () => Row(
        children: [
          Expanded(
            child: Text(
              '${widget.year}',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ),
          IconButton(
            tooltip: 'Предыдущий год',
            onPressed: () => widget.onYear(widget.year - 1),
            icon: const Icon(Icons.chevron_left),
          ),
          IconButton(
            tooltip: 'Следующий год',
            onPressed: widget.year >= DateTime.now().year
                ? null
                : () => widget.onYear(widget.year + 1),
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
      () => _panel(
        'Завершённые книги по месяцам',
        _bars(months, (v) => '$v книг'),
      ),
      () => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.flag_outlined),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      goal == null
                          ? 'Поставьте цель на год'
                          : '${allCompleted.length} из $goal книг',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  const Expanded(child: Text('Книги и аудиокниги вместе')),
                  TextButton(
                    onPressed: _setGoal,
                    child: Text(goal == null ? 'Задать' : 'Изменить'),
                  ),
                ],
              ),
              if (goal != null)
                LinearProgressIndicator(
                  value: (allCompleted.length / goal!).clamp(0, 1).toDouble(),
                ),
            ],
          ),
        ),
      ),
      () => Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _figure('${completed.length}', 'Завершено'),
          _figure(
            '$readings / ${completed.length - readings}',
            'Книги / аудио',
          ),
          _figure(
            (completed.length / denominator).toStringAsFixed(1),
            'В среднем за месяц',
          ),
          _figure(bookActivityTime(totalTime), 'Чтение и прослушивание'),
          _figure(
            '${days.values.where((ms) => ms > 0).length}',
            'Активных дней',
          ),
          _figure(bookAmount(pages), 'Страниц в завершённых книгах'),
        ],
      ),
      () => _panel(
        'Средняя оценка · $average / 10',
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Оценено книг: ${ratings.length}'),
            if (ratings.isEmpty)
              const Text('Оценки появятся после заполнения карточек.'),
            for (final rating in ratingLevels)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    SizedBox(width: 40, child: Text(bookAmount(rating))),
                    Expanded(
                      child: LinearProgressIndicator(
                        value:
                            ratings.where((v) => v == rating).length /
                            ratings.length,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text('${ratings.where((v) => v == rating).length}'),
                  ],
                ),
              ),
          ],
        ),
      ),
      () => _panel(
        'Время по месяцам · ${bookActivityTime(totalTime)}',
        _bars(timeMonths, bookActivityTime, counts: false),
      ),
      () => _panel(
        'Время чтения и прослушивания',
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (widget.scope != 'audio')
              _figure(
                bookActivityTime(
                  widget.readingDays.values.fold<int>(0, (a, b) => a + b),
                ),
                'Чтение',
              ),
            if (widget.scope != 'reading')
              _figure(
                bookActivityTime(
                  widget.audioDays.values.fold<int>(0, (a, b) => a + b),
                ),
                'Прослушивание',
              ),
          ],
        ),
      ),
      () => _panel(
        'Страницы по книгам',
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (pageBooks.isEmpty)
              const Text(
                'Укажите объём в страницах в карточках завершённых книг.',
              ),
            for (final book in pageBooks.take(5))
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${book.entry.item.title} · ${bookAmount(num.parse('${book.entry.item.value('total')}'))} стр.',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value:
                          num.parse('${book.entry.item.value('total')}') /
                          num.parse(
                            '${pageBooks.first.entry.item.value('total')}',
                          ),
                    ),
                  ],
                ),
              ),
            if (pageBooks.isNotEmpty)
              Text(
                'Объём завершённых книг с известным числом страниц; без повторного счёта перечитываний.',
              ),
          ],
        ),
      ),
      () => Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          'Книги за год',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
      ),
      if (completed.isEmpty)
        () => const Text(
          'За этот год нет завершённых книг с указанной датой завершения.',
        ),
      for (var i = 0; i < completed.length; i++) ...[
        if (i == 0 || completed[i].date.month != completed[i - 1].date.month)
          () => Padding(
            padding: const EdgeInsets.only(top: 20, bottom: 8),
            child: Text(
              bookMonths[completed[i].date.month - 1],
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
        () => _book(completed[i]),
      ],
    ];
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      itemCount: rows.length,
      itemBuilder: (_, i) => rows[i](),
    );
  }

  Widget _figure(String value, String label) => SizedBox(
    width: 155,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value, style: Theme.of(context).textTheme.titleLarge),
            ),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    ),
  );
  Widget _panel(String title, Widget child) => Card(
    margin: const EdgeInsets.symmetric(vertical: 8),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 16),
          child,
        ],
      ),
    ),
  );
  Widget _bars(
    List<int> values,
    String Function(int) label, {
    bool counts = true,
  }) {
    final max = values.fold<int>(1, (a, b) => a > b ? a : b);
    return SizedBox(
      height: 154,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < 12; i++)
            Expanded(
              child: Tooltip(
                message: '${bookMonths[i]}: ${label(values[i])}',
                child: Semantics(
                  label: '${bookMonths[i]}: ${label(values[i])}',
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (values[i] > 0 && counts)
                          SizedBox(
                            height: 16,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                '${values[i]}',
                                style: const TextStyle(fontSize: 10),
                              ),
                            ),
                          ),
                        Container(
                          height: 4 + 100 * values[i] / max,
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text('${i + 1}', style: const TextStyle(fontSize: 11)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _book(YearBook book) {
    final item = book.entry.item;
    return Card(
      key: ValueKey('annual-book:${item.id}'),
      child: ListTile(
        contentPadding: const EdgeInsets.all(12),
        leading: ShelfBookCover(
          title: item.title,
          mediaType: item.mediaType,
          cover: '${item.value('cover') ?? ''}',
          localPath: widget.library?.coverPath(item),
        ),
        title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          [
            item.mediaType == 'audiobook' ? 'Аудиокнига' : 'Книга',
            if (book.rating != null) '★ ${book.rating} / 10',
            '${bookDateLabel(item.value('startDate'))} — ${bookDateLabel(book.date)}',
            if (book.completions > 1) 'Завершений за год: ${book.completions}',
          ].join('\n'),
        ),
        onTap: widget.library == null
            ? null
            : () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => LibraryWorkPage(
                    library: widget.library!,
                    itemId: item.id,
                  ),
                ),
              ),
      ),
    );
  }
}
