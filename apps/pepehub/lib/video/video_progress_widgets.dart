import 'package:flutter/material.dart';

import '../ui/pepe_widgets.dart';
import '../ui/shelf_components.dart';
import 'models.dart';
import 'video_activity.dart';

typedef VideoLearningAction = Future<void> Function({
  bool? manualComplete,
  bool? understood,
});

class VideoCourseProgressPanel extends StatelessWidget {
  final VideoCourseCoverage coverage;
  const VideoCourseProgressPanel({super.key, required this.coverage});
  @override
  Widget build(BuildContext context) => ShelfPanel(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Прогресс курса', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 10),
        if (coverage.fraction != null) ...[
          LinearProgressIndicator(value: coverage.fraction!.clamp(0, 1)),
          const SizedBox(height: 8),
          Text(
            '${(coverage.fraction! * 100).toStringAsFixed(1)}% · ${pepeTime(coverage.watchedMs)} из ${pepeTime(coverage.totalMs)}',
          ),
        ] else ...[
          Text(
            'Общий процент пока неизвестен: нет длительности ${coverage.unknownLessons} уроков.',
          ),
          if (coverage.totalMs > 0)
            Text(
              'Из известного объёма просмотрено ${pepeTime(coverage.watchedMs)} из ${pepeTime(coverage.totalMs)}.',
            ),
        ],
        const SizedBox(height: 8),
        Text(
          'Завершено уроков: ${coverage.completedLessons} из ${coverage.totalLessons}',
        ),
        if (coverage.remainingMs > 0)
          Text(
            'Осталось ${pepeTime(coverage.remainingMs)} известного материала.',
          ),
        const SizedBox(height: 6),
        Text(
          'Доля курса учитывает длительность уроков. Ручные отметки не увеличивают просмотренный объём.',
          style: TextStyle(color: ShelfPalette.of(context).muted, fontSize: 12),
        ),
      ],
    ),
  );
}

class VideoLessonProgressPanel extends StatelessWidget {
  final VideoLesson lesson;
  final VideoStats stats;
  final int threshold;
  final VideoLearningState? learning;
  final VideoLearningAction? onLearningChanged;
  final bool saving;
  const VideoLessonProgressPanel({
    super.key,
    required this.lesson,
    required this.stats,
    required this.threshold,
    this.learning,
    this.onLearningChanged,
    this.saving = false,
  });
  @override
  Widget build(BuildContext context) {
    final watched = stats.lessonCoverage(lesson), duration = lesson.durationMs;
    final automatic =
        duration != null &&
        duration > 0 &&
        watched * 100 >= duration * threshold;
    final state =
        learning ??
        VideoLearningState(
          lessonId: lesson.id,
          mediaVersion: lesson.mediaVersion,
        );
    return ShelfPanel(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            lesson.title,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          if (duration != null && duration > 0) ...[
            Text(
              '${(watched * 100 / duration).clamp(0, 100).toStringAsFixed(1)}% · ${pepeTime(watched)} из ${pepeTime(duration)}',
            ),
            const SizedBox(height: 10),
            VideoCoverageBar(
              durationMs: duration,
              runs: stats.coverageMaps[lesson.id] ?? const [],
            ),
          ] else
            Text(
              '${pepeTime(watched)} просмотрено · длительность ещё неизвестна',
            ),
          if (automatic ||
              state.manualCompletedAt != null ||
              state.understoodAt != null) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (automatic)
                  Chip(
                    label: Text('Покрытие ≥ $threshold%'),
                    avatar: const Icon(Icons.check_circle_outline, size: 18),
                  ),
                if (state.manualCompletedAt != null)
                  const Chip(label: Text('Завершён вручную')),
                if (state.understoodAt != null)
                  const Chip(
                    label: Text('Разобрался'),
                    avatar: Icon(Icons.school_outlined, size: 18),
                  ),
              ],
            ),
          ],
          if (state.coverageCompletedAt != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Порог ${state.coverageThreshold}% впервые достигнут ${videoMomentLabel(state.coverageCompletedAt!)}',
                style: TextStyle(
                  color: ShelfPalette.of(context).muted,
                  fontSize: 12,
                ),
              ),
            ),
          if (onLearningChanged != null) ...[
            const Divider(height: 24),
            CheckboxListTile(
              key: ValueKey('video-manual-${lesson.id}'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Завершён вручную'),
              dense: true,
              value: state.manualCompletedAt != null,
              onChanged: saving
                  ? null
                  : (value) => onLearningChanged!(manualComplete: value),
            ),
            CheckboxListTile(
              key: ValueKey('video-understood-${lesson.id}'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Разобрался в материале'),
              dense: true,
              value: state.understoodAt != null,
              onChanged: saving
                  ? null
                  : (value) => onLearningChanged!(understood: value),
            ),
          ],
        ],
      ),
    );
  }
}

class VideoCoverageBar extends StatelessWidget {
  final int durationMs;
  final List<VideoCoverageRun> runs;
  const VideoCoverageBar({
    super.key,
    required this.durationMs,
    required this.runs,
  });
  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final empty = palette.muted.withValues(alpha: .25),
        repeat = Colors.orange.shade400;
    final actual = runs.isEmpty ? [VideoCoverageRun(0, durationMs, 0)] : runs;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          button: true,
          label: 'Карта просмотра: показать диапазоны и повторы',
          child: InkWell(
            onTap: () => _details(context, actual),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: SizedBox(
                height: 16,
                width: double.infinity,
                child: CustomPaint(
                  painter: _CoveragePainter(
                    durationMs,
                    actual,
                    empty,
                    palette.accent,
                    repeat,
                  ),
                ),
              ),
            ),
          ),
        ),
        Wrap(
          spacing: 12,
          runSpacing: 6,
          children: [
            _legend(empty, 'Пропуски'),
            _legend(palette.accent, 'Просмотрено'),
            _legend(repeat, 'Повторы'),
          ],
        ),
      ],
    );
  }

  Widget _legend(Color color, String text) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 4),
      Text(text, style: const TextStyle(fontSize: 11)),
    ],
  );
  void _details(
    BuildContext context,
    List<VideoCoverageRun> actual,
  ) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Участки видео'),
      content: SizedBox(
        width: 480,
        height: 320,
        child: ListView.builder(
          itemCount: actual.length,
          itemBuilder: (_, i) => ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              '${videoPositionLabel(actual[i].startMs)} — ${videoPositionLabel(actual[i].endMs)}',
            ),
            subtitle: Text(
              actual[i].passes == 0
                  ? 'Не просмотрено'
                  : actual[i].passes == 1
                  ? 'Просмотрено один раз'
                  : 'Проходов: ${actual[i].passes}',
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
      ],
    ),
  );
}

class _CoveragePainter extends CustomPainter {
  final int duration;
  final List<VideoCoverageRun> runs;
  final Color empty, watched, repeated;
  const _CoveragePainter(
    this.duration,
    this.runs,
    this.empty,
    this.watched,
    this.repeated,
  );
  @override
  void paint(Canvas canvas, Size size) {
    if (duration <= 0) return;
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(5)),
    );
    final paint = Paint();
    for (final run in runs) {
      paint.color = run.passes == 0
          ? empty
          : run.passes == 1
          ? watched
          : repeated;
      canvas.drawRect(
        Rect.fromLTRB(
          run.startMs * size.width / duration,
          0,
          run.endMs * size.width / duration,
          size.height,
        ),
        paint,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CoveragePainter old) =>
      old.runs != runs ||
      old.duration != duration ||
      old.empty != empty ||
      old.watched != watched ||
      old.repeated != repeated;
}

String videoPositionLabel(int milliseconds) {
  final seconds = milliseconds ~/ 1000, minutes = milliseconds ~/ 60000;
  return '${minutes.toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
}

String videoMomentLabel(DateTime stamp) {
  final date = stamp.toLocal();
  return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year} ${pepeClock(date)}';
}
