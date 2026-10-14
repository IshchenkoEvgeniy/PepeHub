import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ui/pepe_widgets.dart';
import '../ui/shelf_components.dart';
import 'models.dart';

class VideoActivityCalendar extends StatefulWidget {
  final Map<String, int> days;
  const VideoActivityCalendar({super.key, required this.days});
  @override
  State<VideoActivityCalendar> createState() => _VideoActivityCalendarState();
}

class _VideoActivityCalendarState extends State<VideoActivityCalendar> {
  late DateTime month = DateTime(DateTime.now().year, DateTime.now().month);
  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final count = DateTime(month.year, month.month + 1, 0).day;
    final leading = month.weekday - 1;
    final cells = ((leading + count) / 7).ceil() * 7;
    final maximum = widget.days.values.fold(1, math.max);
    return ShelfPanel(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Предыдущий месяц видео',
                onPressed: () => setState(
                  () => month = DateTime(month.year, month.month - 1),
                ),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Text(
                  '${pepeMonthNames[month.month - 1]} ${month.year}',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: 'Следующий месяц видео',
                onPressed: () => setState(
                  () => month = DateTime(month.year, month.month + 1),
                ),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              for (final day in ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'])
                Expanded(
                  child: Text(
                    day,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 11, color: palette.muted),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: cells,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              crossAxisSpacing: 4,
              mainAxisSpacing: 4,
            ),
            itemBuilder: (_, cell) {
              final day = cell - leading + 1;
              if (day < 1 || day > count) return const SizedBox.shrink();
              final date = DateTime(month.year, month.month, day);
              final key = videoDay(date),
                  amount = widget.days[videoDay(date)] ?? 0;
              final intensity = amount == 0
                  ? 0.0
                  : .25 + .75 * math.sqrt(amount / maximum);
              final label = '$key · ${pepeTime(amount)}';
              return Semantics(
                button: true,
                label: label,
                child: Tooltip(
                  message: label,
                  child: Material(
                    color: Color.lerp(
                      palette.raised,
                      palette.accent,
                      intensity,
                    ),
                    borderRadius: BorderRadius.circular(6),
                    child: InkWell(
                      key: ValueKey('video-calendar:$key'),
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => showDialog<void>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: Text(key),
                          content: Text(
                            'Время воспроизведения: ${pepeTime(amount)}',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Закрыть'),
                            ),
                          ],
                        ),
                      ),
                      child: Center(
                        child: Text(
                          '$day',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: amount > 0
                                ? FontWeight.w700
                                : FontWeight.w400,
                            color: intensity > .6
                                ? palette.onAccent
                                : palette.text,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          Text(
            'Вся история выбранных уроков; даты сохранены в момент просмотра.',
            style: TextStyle(fontSize: 11, color: palette.muted),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
