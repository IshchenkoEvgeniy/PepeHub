import 'package:flutter/material.dart';

import '../data/repository.dart';
import '../reader/reading_plan.dart';
import 'pepe_widgets.dart';
import 'shelf_components.dart';

class ReadingPlanPage extends StatefulWidget {
  final Repository repository;
  final String bookId;
  const ReadingPlanPage({
    super.key,
    required this.repository,
    required this.bookId,
  });
  @override
  State<ReadingPlanPage> createState() => _ReadingPlanPageState();
}

class _ReadingPlanPageState extends State<ReadingPlanPage> {
  late final plans = ReadingPlans(widget.repository);
  final minutes = TextEditingController(text: '20');
  ReadingPlanData? data;
  int target = 100;
  DateTime? deadline;
  String? error;
  bool loading = true, busy = false, dirty = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    minutes.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final result = await plans.load(widget.bookId);
      if (!mounted) return;
      setState(() {
        data = result;
        loading = false;
        error = null;
        if (!dirty) {
          final plan = result.saved ?? const ReadingPlan();
          minutes.text = '${plan.dailyMinutes}';
          target = plan.targetPercent;
          deadline = plan.deadline;
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = '$e';
        });
      }
    }
  }

  ReadingPlan? get draft {
    final value = int.tryParse(minutes.text);
    return value == null || value < 1 || value > 1440
        ? null
        : ReadingPlan(
            dailyMinutes: value,
            targetPercent: target,
            deadline: deadline,
          );
  }

  Future<void> _save() async {
    final plan = draft;
    if (plan == null) {
      setState(() => error = 'Укажите от 1 до 1440 минут в день.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await plans.save(widget.bookId, plan);
      if (!mounted) return;
      setState(() => dirty = false);
      await _load();
      if (mounted && error == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('План чтения сохранён')));
      }
    } catch (e) {
      if (mounted) setState(() => error = 'План не сохранён: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _remove() async {
    final previous = data?.saved;
    if (previous == null) return;
    setState(() => busy = true);
    try {
      await plans.remove(widget.bookId);
      if (!mounted) return;
      setState(() => dirty = false);
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
          SnackBar(
            content: const Text('План удалён. Статистика сохранена.'),
            action: SnackBarAction(
              label: 'Отменить',
              onPressed: () async {
                try {
                  await plans.save(widget.bookId, previous);
                  await _load();
                } catch (e) {
                  if (mounted) {
                    setState(() => error = 'Не удалось вернуть план: $e');
                  }
                }
              },
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = 'Не удалось удалить план: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _pickDate() async {
    final today = DateTime.now();
    final value = await showDatePicker(
      context: context,
      initialDate:
          deadline ?? DateTime(today.year, today.month, today.day + 14),
      firstDate: DateTime(1900),
      lastDate: DateTime(2100),
      helpText: 'Завершить до конца выбранного дня',
    );
    if (value != null && mounted) {
      setState(() {
        deadline = value;
        dirty = true;
      });
    }
  }

  String date(DateTime value) =>
      '${value.day.toString().padLeft(2, '0')}.${value.month.toString().padLeft(2, '0')}.${value.year}';
  String duration(int value) =>
      value < 60 ? '$value мин' : '${value ~/ 60} ч ${value % 60} мин';
  void _step(int delta) {
    final value = (int.tryParse(minutes.text) ?? 20) + delta;
    setState(() {
      minutes.text = '${value.clamp(1, 1440)}';
      dirty = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final source = data, plan = draft;
    final forecast = source == null || plan == null
        ? null
        : forecastReading(
            plan: plan,
            bookId: widget.bookId,
            hash: source.hash,
            length: source.length,
            coverage: source.coverage,
            sessions: source.sessions,
            now: DateTime.now(),
          );
    final settings = PepePanel(
      title: 'Настройки плана',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (source?.saved == null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                'Создайте личный план для этой книги.',
                style: TextStyle(color: palette.muted),
              ),
            ),
          if (dirty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                'Изменения ещё не сохранены. Прогноз — для выбранных настроек.',
                style: TextStyle(fontSize: 12.5, color: palette.accent),
              ),
            ),
          TextField(
            controller: minutes,
            keyboardType: TextInputType.number,
            maxLength: 4,
            decoration: InputDecoration(
              labelText: 'Минут в день',
              helperText: 'Активное чтение этой книги · 1–1440',
              prefixIcon: IconButton(
                tooltip: 'Меньше',
                onPressed: () => _step(-5),
                icon: const Icon(Icons.remove),
              ),
              suffixIcon: IconButton(
                tooltip: 'Больше',
                onPressed: () => _step(5),
                icon: const Icon(Icons.add),
              ),
            ),
            textAlign: TextAlign.center,
            onChanged: (_) => setState(() => dirty = true),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Expanded(child: Text('Цель по объёму')),
              Text(
                'первые $target%',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          Slider(
            value: target.toDouble(),
            min: 1,
            max: 100,
            divisions: 99,
            label: '$target%',
            onChanged: (v) => setState(() {
              target = v.round();
              dirty = true;
            }),
          ),
          Material(
            color: palette.raised,
            borderRadius: BorderRadius.circular(14),
            child: ListTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              leading: const Icon(Icons.event_outlined),
              title: const Text('Срок завершения'),
              subtitle: Text(deadline == null ? 'Без срока' : date(deadline!)),
              onTap: _pickDate,
              trailing: deadline == null
                  ? const Icon(Icons.edit_calendar)
                  : IconButton(
                      tooltip: 'Убрать срок',
                      onPressed: () => setState(() {
                        deadline = null;
                        dirty = true;
                      }),
                      icon: const Icon(Icons.close),
                    ),
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            children: [
              FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.check),
                label: const Text('Сохранить план'),
              ),
              if (source?.saved != null)
                TextButton.icon(
                  onPressed: _remove,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Удалить план'),
                ),
            ],
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: LinearProgressIndicator(),
            ),
        ],
      ),
    );
    final projection = forecast == null || plan == null || source == null
        ? null
        : _projection(palette, forecast, plan, source);
    return PepeSubpage(
      title: 'План чтения',
      back: 'Книга',
      section: PepeSection.books,
      subtitle: source?.title,
      maxWidth: 1180,
      actions: [
        IconButton(
          tooltip: 'Обновить прогноз',
          onPressed: busy ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
      children: loading
          ? const [
              Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator()),
              ),
            ]
          : [
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (source != null)
                AbsorbPointer(
                  absorbing: busy,
                  child: PepeRow(
                    breakpoint: 760,
                    children: [
                      (5, settings),
                      if (projection != null) (6, projection),
                    ],
                  ),
                ),
              if (source != null) ...[
                const SizedBox(height: 16),
                Text(
                  'Прогноз приблизительный: он основан на активном чтении этой версии книги. Паузы, бездействие и переходы по поиску, оглавлению или ползунку исключаются из замера скорости. Пропущенный текст остаётся в плане; повторное чтение засчитывается в минуты за день, но не уменьшает непрочитанный объём.',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    color: palette.muted,
                  ),
                ),
              ],
            ],
    );
  }

  Widget _projection(
    ShelfPalette palette,
    ReadingForecast forecast,
    ReadingPlan plan,
    ReadingPlanData source,
  ) {
    final covered = source.length == 0
        ? 0.0
        : forecast.coveredChars / source.length;
    final String headline;
    final List<String> lines = [];
    if (forecast.complete) {
      headline = 'Цель по объёму достигнута';
    } else if (forecast.targetChars == null) {
      headline = 'Нет прогноза';
      lines.add(
        'Для прогноза нужен текстовый объём книги. Обновите сведения из файла. Для PDF пока доступна цель по времени.',
      );
    } else if (forecast.remainingMinutes == null) {
      headline = 'Мало данных';
      lines.add(
        'Пока мало данных для прогноза. Нужно не менее минуты измеренного чтения, 300 знаков и двух обычных переходов. Старые сессии без замера скорости в прогноз не входят.',
      );
    } else {
      headline = 'Осталось примерно ${duration(forecast.remainingMinutes!)}';
      lines.add('Скорость: ${forecast.charsPerMinute!.round()} знаков/мин');
      if (forecast.minutesPerDay != null) {
        lines.add(
          'Дополнительно до срока: около ${forecast.minutesPerDay} мин в день',
        );
      }
      if (!forecast.overdue &&
          deadline != null &&
          forecast.expectedDate!.isAfter(deadline!)) {
        lines.add(
          'При текущей дневной цели срок не достигается. Увеличьте время или перенесите дату.',
        );
      }
    }
    return PepePanel(
      title: 'Прогноз',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              PepeRing(
                value: forecast.todayMs / (plan.dailyMinutes * 60000),
                center: '${(forecast.todayMs / 60000).floor()}',
                below: 'из ${plan.dailyMinutes} мин',
                size: 112,
              ),
              const SizedBox(width: 20),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Сегодня',
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      headline,
                      style: AppFonts.title(palette.text, size: 22),
                    ),
                    if (forecast.expectedDate != null &&
                        forecast.remainingMinutes != null &&
                        !forecast.complete) ...[
                      const SizedBox(height: 6),
                      Text(
                        'При вашей дневной цели: ${date(forecast.expectedDate!)}',
                        style: TextStyle(fontSize: 13, color: palette.accent),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          if (forecast.targetChars != null) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Учтено ${(covered * 100).toStringAsFixed(1)}% книги',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                Text(
                  'цель $target%',
                  style: TextStyle(fontSize: 13, color: palette.muted),
                ),
              ],
            ),
            const SizedBox(height: 8),
            LayoutBuilder(
              builder: (context, constraints) => Stack(
                clipBehavior: Clip.none,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: covered.clamp(0.0, 1.0),
                      minHeight: 12,
                      color: palette.accent,
                      backgroundColor: palette.raised,
                    ),
                  ),
                  Positioned(
                    left: constraints.maxWidth * target / 100 - 1,
                    top: -3,
                    child: Container(width: 2, height: 18, color: palette.text),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
          ],
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                line,
                style: TextStyle(fontSize: 13, color: palette.muted),
              ),
            ),
          if (forecast.overdue)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'Срок прошёл. Выберите новую дату.',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }
}
