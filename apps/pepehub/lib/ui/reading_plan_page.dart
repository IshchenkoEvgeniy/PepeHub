import 'package:flutter/material.dart';

import '../data/repository.dart';
import '../reader/reading_plan.dart';

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
        ScaffoldMessenger.of(context).showSnackBar(
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
  @override
  Widget build(BuildContext context) {
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('План чтения'),
        actions: [
          IconButton(
            tooltip: 'Обновить прогноз',
            onPressed: busy ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : AbsorbPointer(
              absorbing: busy,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  if (source != null)
                    Text(
                      source.title,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  const SizedBox(height: 16),
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
                  if (source != null) ...[
                    if (source.saved == null)
                      const Text('Создайте личный план для этой книги.'),
                    if (dirty)
                      const Text(
                        'Изменения ещё не сохранены. Прогноз ниже — для выбранных настроек.',
                      ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: minutes,
                      keyboardType: TextInputType.number,
                      maxLength: 4,
                      decoration: const InputDecoration(
                        labelText: 'Минут в день',
                        helperText: 'Активное чтение этой книги · 1–1440',
                      ),
                      onChanged: (_) => setState(() => dirty = true),
                    ),
                    Text('Цель: прочитать первые $target% книги'),
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
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.event_outlined),
                      title: const Text('Срок завершения'),
                      subtitle: Text(
                        deadline == null ? 'Без срока' : date(deadline!),
                      ),
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
                    FilledButton.icon(
                      onPressed: _save,
                      icon: const Icon(Icons.check),
                      label: const Text('Сохранить план'),
                    ),
                    const SizedBox(height: 20),
                    if (forecast != null)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Сегодня',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              Text(
                                '${(forecast.todayMs / 60000).floor()} / ${plan!.dailyMinutes} мин',
                              ),
                              const SizedBox(height: 8),
                              LinearProgressIndicator(
                                value:
                                    (forecast.todayMs /
                                            (plan.dailyMinutes * 60000))
                                        .clamp(0, 1),
                              ),
                              const SizedBox(height: 20),
                              if (forecast.targetChars != null) ...[
                                Text(
                                  'Учтено ${(forecast.coveredChars / source.length * 100).toStringAsFixed(1)}% книги · цель $target%',
                                ),
                                const SizedBox(height: 8),
                                LinearProgressIndicator(
                                  value:
                                      (forecast.coveredChars /
                                              forecast.targetChars!)
                                          .clamp(0, 1),
                                ),
                                const SizedBox(height: 16),
                              ],
                              if (forecast.complete)
                                Text(
                                  'Цель по объёму достигнута',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium,
                                )
                              else if (forecast.targetChars == null)
                                const Text(
                                  'Для прогноза нужен текстовый объём книги. Обновите сведения из файла. Для PDF пока доступна цель по времени.',
                                )
                              else if (forecast.remainingMinutes == null)
                                const Text(
                                  'Пока мало данных для прогноза. Нужно не менее минуты измеренного чтения, 300 знаков и двух обычных переходов. Старые сессии без замера скорости в прогноз не входят.',
                                )
                              else ...[
                                Text(
                                  'Осталось примерно ${duration(forecast.remainingMinutes!)}',
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                                Text(
                                  'Скорость: ${forecast.charsPerMinute!.round()} знаков/мин',
                                ),
                                if (forecast.expectedDate != null)
                                  Text(
                                    'При вашей дневной цели: ${date(forecast.expectedDate!)}',
                                  ),
                                if (forecast.minutesPerDay != null)
                                  Text(
                                    'Дополнительно до срока: около ${forecast.minutesPerDay} мин в день',
                                  ),
                                if (!forecast.overdue &&
                                    deadline != null &&
                                    forecast.expectedDate!.isAfter(deadline!))
                                  const Text(
                                    'При текущей дневной цели срок не достигается. Увеличьте время или перенесите дату.',
                                  ),
                              ],
                              if (forecast.overdue)
                                Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: Text(
                                    'Срок прошёл. Выберите новую дату.',
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .error,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                    const Text(
                      'Прогноз приблизительный: он основан на активном чтении этой версии книги. Паузы, бездействие и переходы по поиску, оглавлению или ползунку исключаются из замера скорости. Пропущенный текст остаётся в плане; повторное чтение засчитывается в минуты за день, но не уменьшает непрочитанный объём.',
                    ),
                    if (source.saved != null)
                      TextButton.icon(
                        onPressed: _remove,
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Удалить план'),
                      ),
                    if (busy) const LinearProgressIndicator(),
                  ],
                ],
              ),
            ),
    );
  }
}
