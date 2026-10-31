import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../audio/audio_journal.dart';
import '../audio/listening_analytics.dart';
import '../audio/audio_daily_totals.dart';
import '../data/repository.dart';
import '../library/activity_store.dart';
import '../library/library_service.dart';
import '../library/book_calendar_data.dart';
import '../media/audio_controller.dart';
import '../reader/reading_activity.dart';
import '../reader/reading_library.dart';
import '../reader/reading_statistics_data.dart';
import 'app_theme.dart';
import 'audio_statistics_page.dart';
import 'reading_statistics_page.dart';
import 'shelf_components.dart';
import 'book_calendar.dart';
import 'annual_book_statistics.dart';

/// Reading and listening for one calendar year, with links to the detailed
/// statistics pages.
class StatisticsHubPage extends StatefulWidget {
  final Repository repository;
  final AudioController? audio;
  final ShelfNavigation navigation;
  final VoidCallback? onJournal;
  final LibraryService? library;
  const StatisticsHubPage({
    super.key,
    required this.repository,
    required this.navigation,
    this.audio,
    this.onJournal,
    this.library,
  });
  @override
  State<StatisticsHubPage> createState() => _StatisticsHubPageState();
}

class _StatisticsHubPageState extends State<StatisticsHubPage> {
  String scope = 'all';
  int year = DateTime.now().year;
  bool annual = false;
  BookCalendarData calendar = BookCalendarData();
  Map<String, int> readingDays = {}, audioDays = {};
  Map<String, int> readingAllDays = {}, audioAllDays = {};
  Map<String, String> titles = {};
  bool loading = true;
  String? error;
  int _request = 0;
  Future<void>? _loadingWork;
  bool _loadAgain = false;

  @override
  void initState() {
    super.initState();
    widget.repository.externalChanges.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.repository.externalChanges.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
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
      final library = ReadingLibrary(repository);
      final automatic = (await library.statisticsSessions()).values;
      final manual = (await repository.records('session'))
          .where((s) => s.payload?['kind'] == 'reading');
      final rows = <Map<String, dynamic>>[
        ...automatic,
        ...await ActivityStore.foreignReading(repository),
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
      final reading = await compute(summarizeReadingCalendar, <String, dynamic>{
        'sessions': rows,
        'year': selectedYear,
      });

      await widget.audio?.flushJournal();
      final totals = AudioDailyStore(repository);
      final native = await totals.period(
        DateTime(selectedYear),
        DateTime(selectedYear + 1),
      );
      final nativeAll = await totals.lifetime();
      final events = await ActivityStore.foreignAudio(repository);
      final listening = await compute(analyzeListening, <String, dynamic>{
        'events': events,
        'book': null,
        'cutoff': null,
        'start': DateTime(selectedYear).toUtc().toIso8601String(),
        'end': DateTime(selectedYear + 1).toUtc().toIso8601String(),
      });
      final lifetime = await compute(AudioStats.new, events);
      await widget.library?.loadCached();
      final calendarData = await BookCalendarData.load(
        repository: repository,
        year: selectedYear,
        reading: rows,
        foreignAudio: events,
        library: widget.library,
        bookRecords: records,
        readingSummary: reading,
      );
      if (!mounted || request != _request) return;
      setState(() {
        titles = {
          for (final b in records) b.id: b.title,
          for (final b in calendarData.books.values) b.id: b.title,
        };
        calendar = calendarData;
        readingDays = _merge(reading.days, calendarData.archiveReading);
        readingAllDays = _merge(
          reading.allDays,
          calendarData.archiveReadingAll,
        );
        audioDays = _merge(
          _merge(native.days, listening.selected.days),
          calendarData.archiveAudio,
        );
        audioAllDays = _merge(
          _merge(nativeAll.days, lifetime.days),
          calendarData.archiveAudioAll,
        );
        error = null;
        loading = false;
      });
    } catch (e) {
      if (mounted && request == _request) {
        setState(() {
          error = 'Не удалось посчитать статистику: $e';
          loading = false;
        });
      }
    }
  }

  Map<String, int> _merge(Map<String, int> a, Map<String, int> b) => {
    ...a,
    for (final e in b.entries) e.key: (a[e.key] ?? 0) + e.value,
  };

  Map<String, int> get _days => switch (scope) {
    'reading' => readingDays,
    'audio' => audioDays,
    _ => _merge(readingDays, audioDays),
  };
  Map<String, int> get _allDays => switch (scope) {
    'reading' => readingAllDays,
    'audio' => audioAllDays,
    _ => _merge(readingAllDays, audioAllDays),
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

  static String hours(int ms) {
    final minutes = ms ~/ 60000;
    if (minutes < 60) return '$minutes мин';
    final h = minutes ~/ 60, m = minutes % 60;
    return m == 0 || h >= 10 ? '$h ч' : '$h ч $m мин';
  }

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final days = _days;
    final total = days.values.fold(0, (sum, ms) => sum + ms);
    final activeDays = days.values.where((ms) => ms > 0).length;
    final streak = readingStreak(_allDays, DateTime.now());
    final top = _books.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final topMax = top.isEmpty ? 1 : top.first.value;
    return ShelfShell(
      title: 'Статистика',
      navigation: widget.navigation,
      bottomNavigationBar: null,
      actions: [
        IconButton(
          tooltip: 'Обновить статистику',
          onPressed: loading ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Обзор'),
                  selected: !annual,
                  onSelected: (_) => setState(() => annual = false),
                ),
                ChoiceChip(
                  label: const Text('Годовая статистика'),
                  selected: annual,
                  onSelected: (_) => setState(() => annual = true),
                ),
              ],
            ),
          ),
          if (annual && loading) const LinearProgressIndicator(),
          if (annual && error != null) Text(error!),
          Expanded(
            child: annual
                ? AnnualBookStatistics(
                    repository: widget.repository,
                    library: widget.library,
                    year: year,
                    scope: scope,
                    readingDays: readingDays,
                    audioDays: audioDays,
                    onScope: (value) => setState(() => scope = value),
                    onYear: (value) {
                      if (loading) return;
                      setState(() => year = value);
                      _load();
                    },
                  )
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(20, 6, 20, 32),
                      children: [
                        Wrap(
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
                                onTap: () => setState(() => scope = key),
                              ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
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
                              onPressed: loading
                                  ? null
                                  : () {
                                      setState(() => year--);
                                      _load();
                                    },
                              icon: const Icon(Icons.chevron_left),
                            ),
                            IconButton(
                              tooltip: 'Следующий год',
                              onPressed: loading || year >= DateTime.now().year
                                  ? null
                                  : () {
                                      setState(() => year++);
                                      _load();
                                    },
                              icon: const Icon(Icons.chevron_right),
                            ),
                          ],
                        ),
                        if (loading) const LinearProgressIndicator(),
                        if (error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        const SizedBox(height: 12),
                        Container(
                          decoration: BoxDecoration(
                            border: Border(
                              top: BorderSide(color: palette.accent),
                              bottom: BorderSide(color: palette.line),
                            ),
                          ),
                          child: IntrinsicHeight(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _figure(palette, hours(total), 'всего за год'),
                                VerticalDivider(color: palette.line, width: 1),
                                _figure(
                                  palette,
                                  '$activeDays',
                                  'дней с книгой',
                                ),
                                VerticalDivider(color: palette.line, width: 1),
                                _figure(
                                  palette,
                                  '${streak.current}',
                                  'дней подряд, рекорд ${streak.best}',
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        _heading('Книжный календарь', null, palette),
                        const SizedBox(height: 10),
                        BookCalendar(
                          year: year,
                          scope: scope,
                          data: calendar,
                          library: widget.library,
                        ),
                        const SizedBox(height: 26),
                        _heading('Больше всего времени', null, palette),
                        const SizedBox(height: 8),
                        if (top.isEmpty)
                          Text(
                            'В этом году пока нет записей.',
                            style: TextStyle(color: palette.muted),
                          ),
                        for (final entry in top.take(5))
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Row(
                              children: [
                                Expanded(
                                  flex: 5,
                                  child: Text(
                                    titles[entry.key]?.isNotEmpty == true
                                        ? titles[entry.key]!
                                        : 'Книга удалена',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppFonts.book(
                                      palette.text,
                                      size: 16,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  flex: 4,
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: FractionallySizedBox(
                                      widthFactor: (entry.value / topMax).clamp(
                                        .03,
                                        1.0,
                                      ),
                                      child: Container(
                                        height: 5,
                                        color: palette.accent,
                                      ),
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  width: 70,
                                  child: Text(
                                    hours(entry.value),
                                    textAlign: TextAlign.right,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: palette.muted,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 24),
                        _heading('Подробнее', null, palette),
                        const SizedBox(height: 4),
                        if (scope != 'audio')
                          _link(
                            palette,
                            Icons.menu_book_outlined,
                            'Статистика чтения',
                            () => Navigator.push<void>(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ReadingStatisticsPage(
                                  repository: widget.repository,
                                ),
                              ),
                            ),
                          ),
                        if (scope != 'reading')
                          _link(
                            palette,
                            Icons.headphones_outlined,
                            'Статистика прослушивания',
                            () => Navigator.push<void>(
                              context,
                              MaterialPageRoute(
                                builder: (_) => AudioStatisticsPage(
                                  repository: widget.repository,
                                  controller: widget.audio,
                                ),
                              ),
                            ),
                          ),
                        if (widget.onJournal != null)
                          _link(
                            palette,
                            Icons.history,
                            'Журнал занятий',
                            widget.onJournal!,
                          ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _figure(ShelfPalette palette, String value, String label) => Expanded(
    child: Padding(
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
        ],
      ),
    ),
  );

  Widget _heading(String title, String? note, ShelfPalette palette) => Row(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: [
      Expanded(
        child: Text(
          title,
          style: AppFonts.book(
            palette.text,
            size: 22,
          ).copyWith(fontStyle: FontStyle.italic),
        ),
      ),
      if (note != null)
        Text(note, style: TextStyle(fontSize: 12, color: palette.muted)),
    ],
  );

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
