import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/repository.dart';
import '../library/library_service.dart';
import '../library/models.dart';
import '../library/reading_insights.dart';
import '../statistics/activity_streak.dart';
import '../statistics/annual_summary.dart'
    show annualCategories, AnnualCategory;
import '../statistics/year_progress.dart';
import 'app_theme.dart';
import 'library_card_link.dart';
import 'library_archive_page.dart' show ShelfBookCover;
import 'shelf_components.dart';

/// Section heading shared by every block of the statistics feed.
Widget statisticsHeading(BuildContext context, String title, {String? note}) {
  final palette = ShelfPalette.of(context);
  return Padding(
    padding: const EdgeInsets.only(top: 26, bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: AppFonts.book(
            palette.text,
            size: 22,
          ).copyWith(fontStyle: FontStyle.italic),
        ),
        if (note != null && note.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              note,
              style: TextStyle(fontSize: 12, color: palette.muted),
            ),
          ),
      ],
    ),
  );
}

/// «59 ч», «3 ч 20 мин», «45 мин».
String statisticsHours(int ms) {
  final minutes = ms ~/ 60000;
  if (minutes < 60) return '$minutes мин';
  final h = minutes ~/ 60, m = minutes % 60;
  return m == 0 || h >= 10 ? '$h ч' : '$h ч $m мин';
}

/// «1 завершение», «3 завершения», «12 завершений».
String statisticsCount(int n, String one, String few, String many) =>
    '$n ${ruPlural(n, one, few, many)}';

/// The whole statistics feed for one year: totals and goal, then the
/// sections the hub supplies (calendar, top books), then monthly charts,
/// ratings, categories and the lazily built list of the year's books.
class AnnualBookStatistics extends StatefulWidget {
  final Repository repository;
  final LibraryService? library;
  final List<LibraryEntry>? completedEntries;
  final int year;
  final int? firstYear;
  final String scope;
  final Map<String, int> readingDays, audioDays;
  final Map<String, int>? audioActivityDays;

  /// Every saved day of every year, for streaks and the comparison with the
  /// previous year. Without them those figures are not shown.
  final Map<String, int>? readingAllDays, audioAllDays, audioActivityAllDays;
  final int audioEstimateMs, audioUndatedMs;
  final ValueChanged<int> onYear;
  final ValueChanged<String> onScope;
  final bool loading;
  final String? error;
  final DateTime Function()? clock;

  /// Built after the totals and the goal (calendar, most time).
  final List<Widget Function()> overview;

  /// Built before the list of the year's books (links to detailed pages).
  final List<Widget Function()> links;

  const AnnualBookStatistics({
    super.key,
    required this.repository,
    this.library,
    this.completedEntries,
    required this.year,
    this.firstYear,
    required this.scope,
    required this.readingDays,
    required this.audioDays,
    this.audioActivityDays,
    this.readingAllDays,
    this.audioAllDays,
    this.audioActivityAllDays,
    this.audioEstimateMs = 0,
    this.audioUndatedMs = 0,
    required this.onYear,
    required this.onScope,
    this.loading = false,
    this.error,
    this.clock,
    this.overview = const [],
    this.links = const [],
  });
  @override
  State<AnnualBookStatistics> createState() => _AnnualBookStatisticsState();
}

class _AnnualBookStatisticsState extends State<AnnualBookStatistics> {
  int? goal;
  String get _goalKey => 'library-year-goal:personal:${widget.year}';
  DateTime get _now => widget.clock?.call() ?? DateTime.now();
  static const _streakHint =
      'Считаются дни, когда читали или слушали не меньше 5 минут';

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

  static Map<String, int> _merge(Iterable<Map<String, int>> sources) {
    final result = <String, int>{};
    for (final source in sources) {
      for (final e in source.entries) {
        result[e.key] = (result[e.key] ?? 0) + e.value;
      }
    }
    return result;
  }

  bool _inScope(YearBook b) =>
      widget.scope == 'all' ||
      b.entry.item.mediaType ==
          (widget.scope == 'audio' ? 'audiobook' : 'book');

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final now = _now, year = widget.year, scope = widget.scope;
    final entries =
        widget.completedEntries ?? widget.library?.visibleEntries ?? [];
    final allCompleted = booksCompletedInYear(entries, year);
    final completed = allCompleted.where(_inScope).toList();
    final goalProgress = allCompleted.fold<int>(
      0,
      (sum, b) => sum + b.completions,
    );
    final readings = completed
        .where((b) => b.entry.item.mediaType == 'book')
        .fold<int>(0, (sum, b) => sum + b.completions);
    final completedCount = completed.fold<int>(
      0,
      (sum, b) => sum + b.completions,
    );

    // Time and activity in the chosen scope.
    final readingYear = sumDaysInYear(widget.readingDays, year);
    final audioYear = sumDaysInYear(widget.audioDays, year);
    final days = _merge([
      if (scope != 'audio') widget.readingDays,
      if (scope != 'reading') widget.audioDays,
    ]);
    final activity = _merge([
      if (scope != 'audio') widget.readingDays,
      if (scope != 'reading') widget.audioActivityDays ?? widget.audioDays,
    ]);
    final months = List<int>.filled(12, 0),
        timeMonths = List<int>.filled(12, 0);
    for (final b in completed) {
      for (final date in b.dates) {
        months[date.month - 1]++;
      }
    }
    for (final e in days.entries) {
      final date = bookDate(e.key);
      if (date != null && date.year == year) {
        timeMonths[date.month - 1] += e.value;
      }
    }
    final totalTime = timeMonths.fold<int>(0, (a, b) => a + b);
    final activeDays = activity.entries
        .where((e) => e.value > 0 && bookDate(e.key)?.year == year)
        .length;
    final yearBest = activityStreak(activity, now, year: year).best;

    // Everything saved, for the streak and the comparison with last year.
    final hasAll = widget.readingAllDays != null && widget.audioAllDays != null;
    final allTime = hasAll
        ? _merge([
            if (scope != 'audio') widget.readingAllDays!,
            if (scope != 'reading') widget.audioAllDays!,
          ])
        : null;
    final allActivity = hasAll
        ? _merge([
            if (scope != 'audio') widget.readingAllDays!,
            if (scope != 'reading')
              widget.audioActivityAllDays ?? widget.audioAllDays!,
          ])
        : null;
    final currentStreak = allActivity == null
        ? null
        : activityStreak(allActivity, now).current;
    final cutoff = comparisonCutoff(year, now);
    final byDate = cutoff == null ? '' : ' на эту дату';
    final timeChange = allTime == null
        ? null
        : percentChange(
            sumDaysInYear(allTime, year, cutoff: cutoff),
            sumDaysInYear(allTime, year - 1, cutoff: cutoff),
          );
    final previousCompleted = booksCompletedInYear(entries, year - 1)
        .where(_inScope)
        .fold<int>(
          0,
          (sum, b) => sum + countDatesInYear(b.dates, year - 1, cutoff: cutoff),
        );
    final completedByDate = completed.fold<int>(
      0,
      (sum, b) => sum + countDatesInYear(b.dates, year, cutoff: cutoff),
    );
    final average = averagePerMonth(completedCount, year, now);

    // Ratings on a fixed scale (5 or 10), empty levels included.
    final ratings = completed.map((b) => b.rating).whereType<double>().toList();
    final averageRating = ratings.isEmpty
        ? '—'
        : (ratings.reduce((a, b) => a + b) / ratings.length).toStringAsFixed(1);
    final ratingMax = ratings.any((r) => r > 5) ? 10 : 5;
    final ratingLevels = List<int>.filled(ratingMax + 1, 0);
    for (final r in ratings) {
      ratingLevels[r.floor().clamp(1, ratingMax)]++;
    }
    final ratingTop = ratingLevels.fold<int>(1, math.max);

    final pageBooks = completed
        .where(
          (b) =>
              b.entry.item.value('unit') == 'pages' &&
              (num.tryParse('${b.entry.item.value('total')}') ?? 0) > 0,
        )
        .toList();
    num pagesOf(YearBook b) => num.parse('${b.entry.item.value('total')}');
    final pages = pageBooks.fold<num>(0, (sum, b) => sum + pagesOf(b));
    pageBooks.sort((a, b) => pagesOf(b).compareTo(pagesOf(a)));

    String completions(int n) =>
        statisticsCount(n, 'завершение', 'завершения', 'завершений');

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
            ShelfPill(
              key: ValueKey('statistics-scope:$key'),
              label: label,
              selected: scope == key,
              onTap: () => widget.onScope(key),
            ),
        ],
      ),
      () => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Летопись $year года',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: AppFonts.serif,
                  fontStyle: FontStyle.italic,
                  fontSize: 18,
                  color: palette.muted,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Предыдущий год',
              onPressed:
                  widget.loading ||
                      (widget.firstYear != null && year <= widget.firstYear!)
                  ? null
                  : () => widget.onYear(year - 1),
              icon: const Icon(Icons.chevron_left),
            ),
            IconButton(
              tooltip: 'Следующий год',
              onPressed: widget.loading || year >= now.year
                  ? null
                  : () => widget.onYear(year + 1),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
      ),
      if (widget.loading) () => const LinearProgressIndicator(),
      if (widget.error != null)
        () => Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            widget.error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      () => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: _strip(palette, [
          _figure(
            palette,
            '$completedCount',
            switch (scope) {
              'reading' => 'книг завершено',
              'audio' => 'аудиокниг завершено',
              _ =>
                'завершено · $readings кн., ${completedCount - readings} ауд.',
            },
            change: previousCompleted > 0 || completedByDate > 0
                ? '${countChange(completedByDate, previousCompleted)} к ${year - 1}$byDate'
                : null,
          ),
          _figure(
            palette,
            statisticsHours(totalTime),
            'всего за год',
            change: timeChange == null
                ? null
                : '$timeChange к ${year - 1}$byDate',
          ),
          _goalFigure(palette, goalProgress),
        ]),
      ),
      () => _strip(palette, top: false, [
        _figure(
          palette,
          '$activeDays',
          '${ruPlural(activeDays, 'день', 'дня', 'дней')} с книгой',
        ),
        KeyedSubtree(
          key: const ValueKey('statistics-streak'),
          child: currentStreak != null && year == now.year
              ? _figure(
                  palette,
                  '$currentStreak',
                  '${ruPlural(currentStreak, 'день', 'дня', 'дней')} подряд',
                  change: 'рекорд года $yearBest',
                  tooltip: _streakHint,
                )
              : _figure(
                  palette,
                  '$yearBest',
                  'рекорд дней подряд за $year',
                  tooltip: _streakHint,
                ),
        ),
        _figure(palette, average.toStringAsFixed(1), 'завершений в месяц'),
      ]),
      () => _goalPace(palette, goalProgress),
      if (scope != 'reading' && widget.audioEstimateMs > 0)
        () => _note(
          palette,
          'Включая ${statisticsHours(widget.audioEstimateMs)} по полю «Прослушано»: оценка при 1×, отнесена к дате в карточке.',
        ),
      if (scope != 'reading' && widget.audioUndatedMs > 0)
        () => _note(
          palette,
          'Ещё ${statisticsHours(widget.audioUndatedMs)} указано без даты и не отнесено к году. Укажите дату начала или завершения в карточке.',
        ),
      ...widget.overview,
      () => statisticsHeading(
        context,
        'Завершения по месяцам',
        note: completions(completedCount),
      ),
      () => _bars(palette, months, completions),
      () => statisticsHeading(
        context,
        'Время по месяцам',
        note: scope == 'all'
            ? 'чтение ${statisticsHours(readingYear)} · прослушивание ${statisticsHours(audioYear)}'
            : statisticsHours(totalTime),
      ),
      () => _bars(palette, timeMonths, statisticsHours, counts: false),
      () => statisticsHeading(
        context,
        'Оценки',
        note: ratings.isEmpty
            ? null
            : 'средняя $averageRating · ${statisticsCount(ratings.length, 'оценка', 'оценки', 'оценок')}',
      ),
      if (ratings.isEmpty)
        () => _note(palette, 'Оценки появятся после заполнения карточек.')
      else
        for (var level = ratingMax; level >= 1; level--)
          () => _barRow(
            palette,
            '★ $level',
            ratingLevels[level] / ratingTop,
            '${ratingLevels[level]}',
            labelWidth: 48,
          ),
      for (final (title, field) in const [
        ('Жанры', 'genre'),
        ('Авторы', 'author'),
        ('Серии', 'series'),
      ])
        () => _categories(palette, title, annualCategories(completed, field)),
      () => statisticsHeading(
        context,
        'Самые объёмные',
        note: pageBooks.isEmpty
            ? null
            : '${bookAmount(pages)} стр. в завершённых книгах, без повторного счёта перечитываний',
      ),
      if (pageBooks.isEmpty)
        () => _note(
          palette,
          'Укажите объём в страницах в карточках завершённых книг.',
        )
      else
        for (final book in pageBooks.take(5))
          () => _barRow(
            palette,
            book.entry.item.title,
            pagesOf(book) / pagesOf(pageBooks.first),
            '${bookAmount(pagesOf(book))} стр.',
            key: ValueKey('statistics-pages-book:${book.entry.item.id}'),
            onTap: libraryCardOpener(
              context,
              widget.library,
              book.entry.item.id,
            ),
          ),
      if (widget.links.isNotEmpty) ...[
        () => statisticsHeading(context, 'Подробнее'),
        ...widget.links,
      ],
      () => statisticsHeading(
        context,
        'Книги за год',
        note: completed.isEmpty
            ? null
            : statisticsCount(
                completed.length,
                'произведение',
                'произведения',
                'произведений',
              ),
      ),
      if (completed.isEmpty)
        () => _note(
          palette,
          'За этот год нет завершённых книг с указанной датой завершения.',
        ),
      for (var i = 0; i < completed.length; i++) ...[
        if (i == 0 || completed[i].date.month != completed[i - 1].date.month)
          () => Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 4),
            child: Text(
              bookMonths[completed[i].date.month - 1],
              style: AppFonts.book(palette.muted, size: 17),
            ),
          ),
        () => _book(completed[i]),
      ],
    ];
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 32),
      itemCount: rows.length,
      itemBuilder: (_, i) => rows[i](),
    );
  }

  Widget _strip(
    ShelfPalette palette,
    List<Widget> figures, {
    bool top = true,
  }) => Container(
    decoration: BoxDecoration(
      border: Border(
        top: top ? BorderSide(color: palette.accent) : BorderSide.none,
        bottom: BorderSide(color: palette.line),
      ),
    ),
    child: IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < figures.length; i++) ...[
            if (i > 0) VerticalDivider(color: palette.line, width: 1),
            Expanded(child: figures[i]),
          ],
        ],
      ),
    ),
  );

  Widget _figure(
    ShelfPalette palette,
    String value,
    String label, {
    String? change,
    String? tooltip,
    VoidCallback? onTap,
  }) {
    Widget child = Padding(
      padding: const EdgeInsets.fromLTRB(10, 12, 6, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: AppFonts.book(
                palette.text,
                size: 30,
              ).copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(fontSize: 12, color: palette.muted)),
          if (change != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                change,
                style: TextStyle(fontSize: 11, color: palette.accent),
              ),
            ),
        ],
      ),
    );
    if (onTap != null) child = InkWell(onTap: onTap, child: child);
    if (tooltip != null) child = Tooltip(message: tooltip, child: child);
    return child;
  }

  Widget _goalFigure(ShelfPalette palette, int progress) => KeyedSubtree(
    key: const ValueKey('statistics-goal'),
    child: _figure(
      palette,
      goal == null ? '—' : '$progress / $goal',
      goal == null ? 'цель на год' : 'цель · книги и аудио вместе',
      change: goal == null ? 'Задать цель' : 'Изменить',
      onTap: _setGoal,
    ),
  );

  Widget _goalPace(ShelfPalette palette, int progress) {
    final goal = this.goal;
    if (goal == null) return const SizedBox(height: 4);
    final now = _now;
    final pace = goalPace(
      done: progress,
      goal: goal,
      year: widget.year,
      now: now,
    );
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              key: const ValueKey('statistics-goal-progress'),
              minHeight: 5,
              value: (progress / goal).clamp(0, 1).toDouble(),
              color: palette.accent,
              backgroundColor: palette.line,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            goalPaceText(pace, goal, widget.year, now),
            style: TextStyle(fontSize: 13, color: palette.muted),
          ),
        ],
      ),
    );
  }

  Widget _note(ShelfPalette palette, String text) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(text, style: TextStyle(fontSize: 13, color: palette.muted)),
  );

  Widget _barRow(
    ShelfPalette palette,
    String label,
    double share,
    String value, {
    double? labelWidth,
    VoidCallback? onTap,
    Key? key,
  }) {
    final title = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppFonts.book(palette.text, size: 16),
    );
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          if (labelWidth != null)
            SizedBox(width: labelWidth, child: title)
          else
            Expanded(flex: 5, child: title),
          const SizedBox(width: 10),
          Expanded(
            flex: 4,
            child: Align(
              alignment: Alignment.centerLeft,
              child: share <= 0
                  ? const SizedBox(height: 5)
                  : FractionallySizedBox(
                      widthFactor: share.clamp(.03, 1.0),
                      child: Container(height: 5, color: palette.accent),
                    ),
            ),
          ),
          SizedBox(
            width: 70,
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 13, color: palette.muted),
            ),
          ),
          if (onTap != null)
            Icon(Icons.chevron_right, size: 18, color: palette.muted),
        ],
      ),
    );
    return onTap == null
        ? KeyedSubtree(key: key, child: row)
        : InkWell(key: key, onTap: onTap, child: row);
  }

  Widget _categories(
    ShelfPalette palette,
    String title,
    List<AnnualCategory> categories,
  ) {
    Widget row(AnnualCategory c) => _barRow(
      palette,
      c.label,
      c.books / categories.first.books,
      c.completions == c.books
          ? '${c.books}'
          : '${c.books} · ${c.completions}×',
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        statisticsHeading(context, title),
        if (categories.isEmpty)
          _note(palette, 'За этот год завершённых произведений нет.'),
        for (final c in categories.take(5)) row(c),
        if (categories.length > 5)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                useSafeArea: true,
                builder: (sheet) => SizedBox(
                  height: MediaQuery.sizeOf(sheet).height * .8,
                  child: Column(
                    children: [
                      ListTile(
                        title: Text('$title · ${categories.length}'),
                        trailing: IconButton(
                          tooltip: 'Закрыть',
                          onPressed: () => Navigator.pop(sheet),
                          icon: const Icon(Icons.close),
                        ),
                      ),
                      Expanded(
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          itemCount: categories.length,
                          itemBuilder: (_, i) => row(categories[i]),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              child: Text('Все ${categories.length}'),
            ),
          ),
      ],
    );
  }

  Widget _bars(
    ShelfPalette palette,
    List<int> values,
    String Function(int) label, {
    bool counts = true,
  }) {
    final max = values.fold<int>(1, (a, b) => a > b ? a : b);
    return SizedBox(
      height: 150,
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
                                style: TextStyle(
                                  fontSize: 10,
                                  color: palette.muted,
                                ),
                              ),
                            ),
                          ),
                        Container(
                          height: values[i] == 0
                              ? 2
                              : 4 + 100 * values[i] / max,
                          decoration: BoxDecoration(
                            color: values[i] == 0
                                ? palette.line
                                : palette.accent,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          bookMonths[i].substring(0, 1),
                          style: TextStyle(fontSize: 11, color: palette.muted),
                        ),
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
    final palette = ShelfPalette.of(context);
    final open = libraryCardOpener(context, widget.library, item.id);
    return InkWell(
      key: ValueKey('annual-book:${item.id}'),
      onTap: open,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: palette.line)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ShelfBookCover(
              title: item.title,
              mediaType: item.mediaType,
              cover: '${item.value('cover') ?? ''}',
              localPath: widget.library?.coverPath(item),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.book(palette.text, size: 17),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [
                      [
                        item.mediaType == 'audiobook' ? 'Аудиокнига' : 'Книга',
                        if (book.rating != null)
                          '★ ${bookAmount(book.rating!)}',
                      ].join(' · '),
                      '${bookDateLabel(item.value('startDate'))} — ${bookDateLabel(book.date)}',
                      if (book.completions > 1)
                        'Завершений за год: ${book.completions}',
                    ].join('\n'),
                    style: TextStyle(fontSize: 13, color: palette.muted),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
