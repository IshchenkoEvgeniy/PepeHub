import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../audio/audio_statistics_history.dart';
import '../audio/listening_analytics.dart';
import '../audio/audio_daily_totals.dart';
import '../data/repository.dart';
import '../library/library_service.dart';
import '../library/reading_insights.dart' show bookDate;
import '../library/book_calendar_data.dart';
import '../media/audio_controller.dart';
import '../reader/reading_statistics_data.dart';
import '../reader/reading_statistics_history.dart';
import 'app_theme.dart';
import 'audio_statistics_page.dart';
import 'reading_statistics_page.dart';
import 'shelf_components.dart';
import 'book_calendar.dart';
import 'annual_book_statistics.dart';
import '../statistics/annual_summary.dart';
import 'year_review_page.dart';
import 'library_card_link.dart';
import 'statistics_exchange_page.dart';
import '../statistics/portable_history.dart';
import '../library/models.dart';
import '../diagnostics/user_message.dart';

/// Reading and listening for one calendar year, with links to the detailed
/// statistics pages.
class StatisticsHubPage extends StatefulWidget {
  final Repository repository;
  final AudioController? audio;
  final ShelfNavigation navigation;
  final VoidCallback? onJournal;
  final LibraryService? library;
  final DateTime Function()? clock;
  const StatisticsHubPage({
    super.key,
    required this.repository,
    required this.navigation,
    this.audio,
    this.onJournal,
    this.library,
    this.clock,
  });
  @override
  State<StatisticsHubPage> createState() => _StatisticsHubPageState();
}

class _StatisticsHubPageState extends State<StatisticsHubPage> {
  String scope = 'all';
  late int year;
  DateTime get _now => widget.clock?.call() ?? DateTime.now();
  BookCalendarData calendar = BookCalendarData();
  Map<String, int> readingDays = {}, audioDays = {};
  Map<String, int> readingAllDays = {}, audioAllDays = {};
  Map<String, int> audioActivityDays = {}, audioActivityAllDays = {};
  int audioEstimateMs = 0, audioUndatedMs = 0;
  Map<String, String> titles = {};
  bool loading = true;
  String? error;
  int _request = 0;
  Future<void>? _loadingWork;
  bool _loadAgain = false;
  bool _historyDirty = true;
  List<LibraryEntry> _completedEntries = [];
  Map<String, String> _readingTitles = {};
  ReadingCalendarSummary? _readingSummary;
  AudioStatisticsHistory? _audioHistory;
  ListeningAnalytics? _listening;
  AudioDailyTotals? _nativeAudio;
  late int firstYear;

  @override
  void initState() {
    super.initState();
    year = firstYear = _now.year;
    widget.repository.externalChanges.addListener(_load);
    widget.library?.addListener(_libraryChanged);
    _load();
  }

  void _libraryChanged() {
    // loadCached also notifies while this page is reading its catalog.
    if (!loading) _load();
  }

  @override
  void didUpdateWidget(StatisticsHubPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.library != widget.library) {
      oldWidget.library?.removeListener(_libraryChanged);
      widget.library?.addListener(_libraryChanged);
      _load();
    }
  }

  @override
  void dispose() {
    widget.repository.externalChanges.removeListener(_load);
    widget.library?.removeListener(_libraryChanged);
    super.dispose();
  }

  Future<void> _load({bool refreshHistory = true}) async {
    if (!mounted) return;
    _historyDirty |= refreshHistory;
    if (_loadingWork != null) {
      _loadAgain = true;
      _request++;
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
    final request = ++_request, selectedYear = year;
    if (!loading) setState(() => loading = true);
    try {
      final repository = widget.repository;
      final records = await repository.bookHeaders();
      if (_historyDirty || _readingSummary == null) {
        _historyDirty = false;
        await widget.audio?.flushJournal();
        await widget.library?.loadCached();
        _completedEntries = await statisticsEntries(
          repository,
          widget.library?.visibleEntries ?? [],
        );
        final readingHistory = await ReadingStatisticsHistory.load(repository);
        _readingTitles = readingHistory.titles;
        _readingSummary = await compute(
          summarizeReadingCalendar,
          <String, dynamic>{
            'sessions': readingHistory.sessions,
            'year': selectedYear,
          },
        );
        _nativeAudio = await AudioDailyStore(repository).lifetime();
        final audioHistory = await AudioStatisticsHistory.load(repository);
        final listening = await compute(analyzeListening, <String, dynamic>{
          'events': audioHistory.events,
          'book': null,
          'cutoff': null,
        });
        // Keep numeric summaries and labels, not another copy of every raw
        // session/event in the UI isolate while browsing years.
        _audioHistory = AudioStatisticsHistory(const [], audioHistory.titles);
        _listening = ListeningAnalytics(
          listening.selected,
          listening.lifetime,
          const [],
          0,
          0,
          listening.byBook,
        );
      }
      final reading = _readingSummary!.forYear(selectedYear);
      final nativeAll = _nativeAudio!, native = nativeAll.forYear(selectedYear);
      final history = _audioHistory!, listening = _listening!;
      Map<String, int> inYear(Map<String, int> days) => {
        for (final e in days.entries)
          if (e.key.startsWith('$selectedYear-')) e.key: e.value,
      };
      final calendarData = await BookCalendarData.load(
        repository: repository,
        year: selectedYear,
        reading: const [],
        foreignAudio: history.events,
        audioHistory: history,
        library: widget.library,
        bookRecords: records,
        readingSummary: reading,
        nativeAudio: native,
        audioSummary: listening,
        readingTitles: _readingTitles,
        completedEntries: _completedEntries,
      );
      if (!mounted || request != _request) return;
      setState(() {
        titles = {
          for (final b in records) b.id: b.title,
          ...history.titles,
          for (final b in calendarData.books.values) b.id: b.title,
        };
        calendar = calendarData;
        readingDays = _merge(reading.days, calendarData.archiveReading);
        readingAllDays = _merge(
          reading.allDays,
          calendarData.archiveReadingAll,
        );
        audioDays = _merge(native.days, inYear(listening.lifetime.days));
        audioAllDays = _merge(nativeAll.days, listening.lifetime.days);
        audioActivityDays = _merge(
          native.days,
          inYear(listening.lifetime.activityDays),
        );
        audioActivityAllDays = _merge(
          nativeAll.days,
          listening.lifetime.activityDays,
        );
        audioEstimateMs = inYear(listening.lifetime.estimatedDays).values
            .fold(0, (a, b) => a + b);
        audioUndatedMs = listening.lifetime.undatedMs;
        final years = <int>[
          _now.year,
          for (final day in {...readingAllDays.keys, ...audioAllDays.keys})
            if (int.tryParse(day.split('-').first) case final int year) year,
          for (final book in calendarData.completedDays.keys)
            if (int.tryParse(book.split('-').first) case final int year) year,
          for (final e in _completedEntries) ...[
            if (bookDate(e.item.value('endDate')) case final DateTime date)
              date.year,
            for (final c in e.item.values['pepehub_completions'] as List? ?? [])
              if (c is Map)
                if (bookDate(c['date']) case final DateTime date) date.year,
          ],
        ];
        firstYear = years.reduce((a, b) => a < b ? a : b);
        error = null;
        loading = false;
      });
    } catch (e) {
      _historyDirty = true;
      if (mounted && request == _request) {
        setState(() {
          error = 'Не удалось посчитать статистику: ${describeError(e)}';
          loading = false;
        });
      }
    }
  }

  Map<String, int> _merge(Map<String, int> a, Map<String, int> b) => {
    ...a,
    for (final e in b.entries) e.key: (a[e.key] ?? 0) + e.value,
  };

  Map<String, int> get _books {
    final result = <String, int>{};
    for (final day in calendar.days.values) {
      for (final e in day.entries) {
        if (scope != 'all' &&
            calendar.books[e.key]?.mediaType !=
                (scope == 'audio' ? 'audiobook' : 'book')) {
          continue;
        }
        result[e.key] = (result[e.key] ?? 0) + e.value;
      }
    }
    return result;
  }

  static String hours(int ms) => statisticsHours(ms);

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final top = _books.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final topMax = top.isEmpty ? 1 : top.first.value;
    return ShelfShell(
      title: 'Статистика',
      navigation: widget.navigation,
      bottomNavigationBar: null,
      actions: [
        IconButton(
          tooltip: 'Итоги года',
          onPressed: loading
              ? null
              : () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => YearReviewPage(
                      library: widget.library,
                      summary: AnnualSummary(
                        year: year,
                        scope: scope,
                        entries: _completedEntries,
                        readingDays: readingDays,
                        audioDays: audioDays,
                        audioActivityDays: audioActivityDays,
                        bookTimes: _books,
                        titles: titles,
                      ),
                    ),
                  ),
                ),
          icon: const Icon(Icons.auto_awesome_outlined),
        ),
        IconButton(
          tooltip: 'Экспорт и импорт всей статистики',
          icon: const Icon(Icons.import_export),
          onPressed: () async {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    StatisticsExchangePage(repository: widget.repository),
              ),
            );
            if (mounted) await _load();
          },
        ),
        IconButton(
          tooltip: 'Обновить статистику',
          onPressed: loading ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
      body: RefreshIndicator(
        onRefresh: _load,
        child: AnnualBookStatistics(
          completedEntries: _completedEntries,
          repository: widget.repository,
          library: widget.library,
          year: year,
          scope: scope,
          readingDays: readingDays,
          audioDays: audioDays,
          audioActivityDays: audioActivityDays,
          readingAllDays: readingAllDays,
          audioAllDays: audioAllDays,
          audioActivityAllDays: audioActivityAllDays,
          audioEstimateMs: audioEstimateMs,
          audioUndatedMs: audioUndatedMs,
          loading: loading,
          error: error,
          clock: () => _now,
          firstYear: firstYear,
          onScope: (value) => setState(() => scope = value),
          onYear: (value) {
            if (loading) return;
            setState(() => year = value);
            _load(refreshHistory: false);
          },
          overview: [
            () => statisticsHeading(context, 'Книжный календарь'),
            () => BookCalendar(
              year: year,
              scope: scope,
              data: calendar,
              library: widget.library,
            ),
            () => statisticsHeading(context, 'Больше всего времени'),
            if (top.isEmpty)
              () => Text(
                'В этом году пока нет записей.',
                style: TextStyle(color: palette.muted),
              ),
            for (final entry in top.take(5))
              () => _topBook(
                entry.key,
                Row(
                  children: [
                    Expanded(
                      flex: 5,
                      child: Text(
                        titles[entry.key]?.isNotEmpty == true
                            ? titles[entry.key]!
                            : 'Книга удалена',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppFonts.book(palette.text, size: 16),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 4,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: (entry.value / topMax).clamp(.03, 1.0),
                          child: Container(height: 5, color: palette.accent),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 70,
                      child: Text(
                        hours(entry.value),
                        textAlign: TextAlign.right,
                        style: TextStyle(fontSize: 13, color: palette.muted),
                      ),
                    ),
                    if (_topBookOpener(entry.key) != null)
                      Icon(Icons.chevron_right, size: 18, color: palette.muted),
                  ],
                ),
              ),
          ],
          links: [
            if (scope != 'audio')
              () => _link(
                palette,
                Icons.menu_book_outlined,
                'Статистика чтения',
                () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ReadingStatisticsPage(
                      repository: widget.repository,
                      library: widget.library,
                    ),
                  ),
                ),
              ),
            if (scope != 'reading')
              () => _link(
                palette,
                Icons.headphones_outlined,
                'Статистика прослушивания',
                () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AudioStatisticsPage(
                      repository: widget.repository,
                      controller: widget.audio,
                      library: widget.library,
                    ),
                  ),
                ),
              ),
            if (widget.onJournal != null)
              () => _link(
                palette,
                Icons.history,
                'Журнал занятий',
                widget.onJournal!,
              ),
          ],
        ),
      ),
    );
  }

  /// Calendar ids are local file ids or `card:<id>`; both lead to a card.
  VoidCallback? _topBookOpener(String key) => libraryCardOpener(
    context,
    widget.library,
    calendar.books[key]?.entry?.item.id ??
        libraryItemIdForBook(widget.library, key),
  );

  Widget _topBook(String key, Widget row) {
    final open = _topBookOpener(key);
    final padded = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: row,
    );
    return open == null
        ? KeyedSubtree(key: ValueKey('statistics-top-book:$key'), child: padded)
        : InkWell(
            key: ValueKey('statistics-top-book:$key'),
            onTap: open,
            child: padded,
          );
  }

  Widget _link(
    ShelfPalette palette,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon, color: palette.accent),
    title: Text(label),
    trailing: Icon(Icons.chevron_right, color: palette.muted),
    onTap: onTap,
  );
}
