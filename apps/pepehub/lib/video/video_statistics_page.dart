import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../ui/pepe_widgets.dart';
import '../ui/shelf_components.dart';
import '../ui/statistics_range.dart';
import 'models.dart';
import 'video_activity.dart';
import 'video_repository.dart';
import 'video_progress_widgets.dart';
import 'video_activity_calendar.dart';

class VideoStatisticsPage extends StatefulWidget {
  final VideoRepository repository;
  final VideoItem? item;
  final DateTime Function() now;
  const VideoStatisticsPage({
    super.key,
    required this.repository,
    this.item,
    this.now = DateTime.now,
  });
  @override
  State<VideoStatisticsPage> createState() => _VideoStatisticsPageState();
}

class _VideoStatisticsPageState extends State<VideoStatisticsPage> {
  int days = 0;
  VideoStats? stats;
  VideoDashboard? dashboard;
  VideoPreferences preferences = const VideoPreferences();
  Map<String, VideoLearningState> learning = {};
  final Set<String> saving = {};
  DateTimeRange? customRange;
  DateTime? _historyStart, _historyEnd;
  Set<String>? _historyLessons;
  List<VideoInterval> history = [];
  VideoHistoryCursor? historyNext;
  bool historyLoading = false;
  int visibleSessions = 20;
  List<VideoLesson> lessons = [];
  String? error;
  int _request = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    final request = ++_request;
    historyLoading = false;
    try {
      final nextLessons = await widget.repository.lessons(
        itemId: widget.item?.id,
      );
      final now = widget.now();
      final ids = widget.item == null
          ? null
          : nextLessons.map((l) => l.id).toSet();
      final start =
          customRange?.start ??
          (days == 0
              ? null
              : DateTime(now.year, now.month, now.day - days + 1));
      final end = customRange?.end ?? (days == 0 ? null : now);
      final nextPreferences = await widget.repository.preferences();
      final nextLearning = await widget.repository.allLearningStates();
      final next = await compute(
        analyzeVideoDashboard,
        VideoDashboardRequest(
          VideoAnalysisRequest(
            await widget.repository.intervals(),
            lessonIds: ids,
            start: start,
            end: end,
            lessons: nextLessons,
          ),
          now,
        ),
      );
      final firstPage = await widget.repository.history(
        lessonIds: ids,
        start: start,
        end: end,
      );
      if (!mounted || request != _request) return;
      setState(() {
        dashboard = next;
        stats = next.selected;
        preferences = nextPreferences;
        learning = nextLearning;
        history = firstPage.intervals;
        historyNext = firstPage.next;
        _historyStart = start;
        _historyEnd = end;
        _historyLessons = ids;
        visibleSessions = 20;
        lessons = nextLessons;
        error = null;
      });
    } catch (e) {
      if (mounted && request == _request) {
        setState(() => error = 'Не удалось загрузить статистику: $e');
      }
    }
  }

  Future<void> _moreHistory() async {
    final cursor = historyNext, request = _request;
    if (cursor == null || historyLoading) return;
    setState(() => historyLoading = true);
    try {
      final next = await widget.repository.history(
        lessonIds: _historyLessons,
        start: _historyStart,
        end: _historyEnd,
        before: cursor,
      );
      if (!mounted || request != _request) return;
      setState(() {
        history.addAll(next.intervals);
        historyNext = next.next;
      });
    } catch (e) {
      if (mounted && request == _request) {
        setState(() => error = 'Не удалось загрузить историю: $e');
      }
    } finally {
      if (mounted && request == _request) {
        setState(() => historyLoading = false);
      }
    }
  }

  Future<void> _customPeriod() async {
    final picked = await pickStatisticsRange(context, customRange);
    if (!mounted || picked == null) return;
    setState(() {
      customRange = picked;
      stats = null;
    });
    await _load();
  }

  Future<void> _settings() async {
    final picked = await showDialog<VideoPreferences>(
      context: context,
      builder: (_) => _VideoPreferencesDialog(value: preferences),
    );
    if (picked == null) return;
    try {
      await widget.repository.savePreferences(picked);
      await _load();
    } catch (e) {
      if (mounted) setState(() => error = 'Не удалось сохранить цели: $e');
    }
  }

  Future<void> _setLearning(
    VideoLesson lesson, {
    bool? manualComplete,
    bool? understood,
  }) async {
    if (!saving.add(lesson.id)) return;
    setState(() {});
    try {
      await widget.repository.setLearningState(
        lesson,
        manualComplete: manualComplete,
        understood: understood,
      );
      await _load();
    } catch (e) {
      if (mounted) setState(() => error = 'Не удалось сохранить отметку: $e');
    } finally {
      saving.remove(lesson.id);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context), result = stats;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.item?.title ?? 'Статистика видео'),
        actions: [
          IconButton(
            tooltip: 'Цели и порог просмотра',
            onPressed: _settings,
            icon: const Icon(Icons.tune),
          ),
          IconButton(
            tooltip: 'Обновить',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Wrap(
            spacing: 8,
            children: [
              for (final period in [0, 1, 7, 30])
                ChoiceChip(
                  label: Text(
                    period == 0
                        ? 'Всё время'
                        : period == 1
                        ? 'Сегодня'
                        : '$period дней',
                  ),
                  selected: customRange == null && days == period,
                  onSelected: (_) {
                    setState(() {
                      days = period;
                      customRange = null;
                      stats = null;
                    });
                    _load();
                  },
                ),
              ChoiceChip(
                label: const Text('Произвольный'),
                selected: customRange != null,
                onSelected: (_) => _customPeriod(),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (customRange != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(rangeLabel(customRange!)),
            ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (result == null && error == null)
            const Center(child: CircularProgressIndicator()),
          if (result != null) ...[
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _metric('Время воспроизведения', pepeTime(result.wallMs)),
                _metric(
                  'Просмотр видео',
                  pepeTime(result.modeTime[VideoActivityMode.visual] ?? 0),
                ),
                if ((result.modeTime[VideoActivityMode.audio] ?? 0) > 0)
                  _metric(
                    'Прослушивание видео',
                    pepeTime(result.modeTime[VideoActivityMode.audio]!),
                  ),
                _metric('Воспроизведено материала', pepeTime(result.mediaMs)),
                _metric('Впервые', pepeTime(result.firstMs)),
                _metric('Повторы', pepeTime(result.repeatedMs)),
                _metric('Уникально за период', pepeTime(result.uniqueMs)),
                _metric('Сессии', '${result.sessions.length}'),
                _metric(
                  'Средняя сессия',
                  pepeTime(
                    result.sessions.isEmpty
                        ? 0
                        : result.wallMs ~/ result.sessions.length,
                  ),
                ),
                if (dashboard != null)
                  _metric('Текущая серия', '${dashboard!.streak.current} дн.'),
                if (dashboard != null)
                  _metric('Лучшая серия', '${dashboard!.streak.best} дн.'),
              ],
            ),
            if ((result.modeTime[VideoActivityMode.audio] ?? 0) > 0)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  'Просмотр и прослушивание учитываются раздельно. Покрытие и завершение курса относятся к просмотру. «Впервые» и «Повторы» рассчитываются внутри каждого режима.',
                ),
              ),
            const SizedBox(height: 20),
            if (dashboard != null) ...[
              _goals(dashboard!),
              const SizedBox(height: 12),
              ShelfPanel(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Эта неделя и предыдущая',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${pepeTime(dashboard!.comparison.currentMs)} · ранее ${pepeTime(dashboard!.comparison.previousMs)}',
                    ),
                    Text(
                      dashboard!.comparison.percentChange == null
                          ? 'В предыдущем периоде нет просмотров.'
                          : '${dashboard!.comparison.percentChange! >= 0 ? '+' : ''}${dashboard!.comparison.percentChange!.toStringAsFixed(1)}%',
                    ),
                    Text(
                      'С понедельника до текущего дня и времени; такой же отрезок прошлой недели.',
                      style: TextStyle(color: palette.muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],
            if (widget.item?.kind == VideoItemKind.course) ...[
              VideoCourseProgressPanel(
                coverage: videoCourseCoverage(
                  lessons,
                  result,
                  preferences.completionPercent,
                  learning,
                ),
              ),
              const SizedBox(height: 20),
            ],
            if (result.firstViewedAt != null)
              Text(
                'Первый просмотр: ${videoMomentLabel(result.firstViewedAt!)}',
              ),
            if (result.lastViewedAt != null)
              Text(
                'Последний просмотр: ${videoMomentLabel(result.lastViewedAt!)}',
              ),
            const SizedBox(height: 12),
            Text(
              'Покрытие уроков за всё время',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'Учитываются воспроизведённые участки. Перемотки не добавляют просмотр; достижение конца не означает изучение всего урока.',
              style: TextStyle(color: palette.muted),
            ),
            const SizedBox(height: 12),
            for (final lesson in lessons) ...[
              VideoLessonProgressPanel(
                lesson: lesson,
                stats: result,
                threshold: preferences.completionPercent,
                learning: learning['${lesson.id}:${lesson.mediaVersion}'],
                saving: saving.contains(lesson.id),
                onLearningChanged: ({bool? manualComplete, bool? understood}) =>
                    _setLearning(
                      lesson,
                      manualComplete: manualComplete,
                      understood: understood,
                    ),
              ),
              const SizedBox(height: 8),
            ],
            if (lessons.isEmpty)
              const Text('Добавьте видео, чтобы появилась история занятий.'),
            const SizedBox(height: 20),
            Text('По дням', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            VideoActivityCalendar(days: result.lifetimeDays),
            const SizedBox(height: 12),
            for (final day
                in result.days.entries.toList()
                  ..sort((a, b) => b.key.compareTo(a.key)))
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(day.key),
                trailing: Text(pepeTime(day.value)),
              ),
            if (result.days.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text('Просмотров за этот период пока нет.'),
              ),
            const SizedBox(height: 20),
            Text(
              'Сессии занятий',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text(
              'Перерывы более пяти минут разделяют занятия. Время в выбранном периоде обрезается по его границам.',
              style: TextStyle(color: palette.muted, fontSize: 12),
            ),
            for (final session in result.sessionDetails.take(visibleSessions))
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(videoMomentLabel(session.start)),
                subtitle: Text(
                  '${pepeTime(session.wallMs)} активности · ${session.lessonIds.length} уроков',
                ),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        'Длительность занятия: ${pepeTime(session.elapsedMs)}\n'
                        'Перерывы: ${pepeTime(session.breakMs)}\n'
                        'Материал: ${pepeTime(session.mediaMs)} · впервые ${pepeTime(session.firstMs)} · повтор ${pepeTime(session.repeatedMs)}',
                      ),
                    ),
                  ),
                ],
              ),
            if (result.sessionDetails.length > visibleSessions)
              TextButton(
                onPressed: () => setState(() => visibleSessions += 20),
                child: const Text('Ещё сессии'),
              ),
            const SizedBox(height: 20),
            Text(
              'История просмотра',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            for (final interval in history) _historyTile(interval),
            if (history.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text('Интервалов просмотра за этот период нет.'),
              ),
            if (historyNext != null)
              TextButton(
                onPressed: historyLoading ? null : _moreHistory,
                child: Text(historyLoading ? 'Загрузка…' : 'Ещё история'),
              ),
          ],
        ],
      ),
    );
  }

  Widget _goals(VideoDashboard value) => ShelfPanel(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Цели всей видеобиблиотеки',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        if (preferences.dailyMinutes > 0) ...[
          Text(
            'Сегодня: ${pepeTime(value.todayMs)} из ${preferences.dailyMinutes} мин',
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: (value.todayMs / (preferences.dailyMinutes * 60000)).clamp(
              0,
              1,
            ),
          ),
        ] else
          const Text('Ежедневная цель не задана.'),
        const SizedBox(height: 10),
        if (preferences.weeklyMinutes > 0) ...[
          Text(
            'За неделю: ${pepeTime(value.globalWeekMs)} из ${preferences.weeklyMinutes} мин',
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: (value.globalWeekMs / (preferences.weeklyMinutes * 60000))
                .clamp(0, 1),
          ),
        ] else
          const Text('Недельная цель не задана.'),
        TextButton(onPressed: _settings, child: const Text('Настроить цели')),
      ],
    ),
  );

  Widget _historyTile(VideoInterval interval) {
    final from = _historyStart == null
        ? 0
        : _historyStart!
              .difference(interval.startedAt)
              .inMilliseconds
              .clamp(0, interval.wallMs);
    final to = _historyEnd == null
        ? interval.wallMs
        : _historyEnd!
              .difference(interval.startedAt)
              .inMilliseconds
              .clamp(0, interval.wallMs);
    if (to <= from) return const SizedBox.shrink();
    final start =
        interval.startMs + (interval.mediaMs * from / interval.wallMs).round();
    final end =
        interval.startMs + (interval.mediaMs * to / interval.wallMs).round();
    final title =
        lessons.where((l) => l.id == interval.lessonId).firstOrNull?.title ??
        'Удалённый или недоступный урок';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(
        '${videoMomentLabel(interval.startedAt.add(Duration(milliseconds: from)))}\n'
        '${videoPositionLabel(start)} — ${videoPositionLabel(end)} · ${pepeTime(to - from)} активности · ${interval.speed}×',
      ),
    );
  }

  Widget _metric(String title, String value) => SizedBox(
    key: ValueKey('video-metric:$title'),
    width: MediaQuery.sizeOf(context).width < 520
        ? (MediaQuery.sizeOf(context).width - 52) / 2
        : 220,
    child: ShelfPanel(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 11)),
          const SizedBox(height: 8),
          Text(value, style: Theme.of(context).textTheme.headlineSmall),
        ],
      ),
    ),
  );
}

class _VideoPreferencesDialog extends StatefulWidget {
  final VideoPreferences value;
  const _VideoPreferencesDialog({required this.value});
  @override
  State<_VideoPreferencesDialog> createState() =>
      _VideoPreferencesDialogState();
}

class _VideoPreferencesDialogState extends State<_VideoPreferencesDialog> {
  final form = GlobalKey<FormState>();
  late final daily = TextEditingController(
    text: '${widget.value.dailyMinutes}',
  );
  late final weekly = TextEditingController(
    text: '${widget.value.weeklyMinutes}',
  );
  late final threshold = TextEditingController(
    text: '${widget.value.completionPercent}',
  );
  @override
  void dispose() {
    daily.dispose();
    weekly.dispose();
    threshold.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Цели и порог просмотра'),
    content: SizedBox(
      width: 420,
      child: Form(
        key: form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _field(daily, 'Минут в день · 0 выключает цель', 0, 1440),
              _field(weekly, 'Минут в неделю · 0 выключает цель', 0, 10080),
              _field(threshold, 'Порог завершения по покрытию, %', 1, 100),
              const SizedBox(height: 12),
              const Text(
                'Цели общие для всех видео. Порог использует уникально просмотренный объём; ручное завершение и понимание отмечаются отдельно.',
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () {
          if (form.currentState!.validate()) {
            Navigator.pop(
              context,
              VideoPreferences(
                dailyMinutes: int.parse(daily.text),
                weeklyMinutes: int.parse(weekly.text),
                completionPercent: int.parse(threshold.text),
              ),
            );
          }
        },
        child: const Text('Сохранить'),
      ),
    ],
  );
  Widget _field(
    TextEditingController controller,
    String label,
    int minimum,
    int maximum,
  ) => TextFormField(
    controller: controller,
    keyboardType: TextInputType.number,
    decoration: InputDecoration(labelText: label),
    validator: (text) {
      final value = int.tryParse(text?.trim() ?? '');
      return value == null || value < minimum || value > maximum
          ? 'Введите число от $minimum до $maximum'
          : null;
    },
  );
}
