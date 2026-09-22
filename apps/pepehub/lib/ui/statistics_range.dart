import 'package:flutter/material.dart';

String rangeLabel(DateTimeRange range) {
  String date(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  return '${date(range.start)} — ${date(range.end)}';
}

Future<DateTimeRange?> pickStatisticsRange(
  BuildContext context,
  DateTimeRange? initial,
) {
  final now = DateTime.now();
  var start = initial?.start ?? DateTime(now.year, now.month, now.day);
  var end = initial?.end ?? now;
  return showDialog<DateTimeRange>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        Future<void> change(bool first, bool clock) async {
          final current = first ? start : end;
          DateTime? result;
          if (clock) {
            final picked = await showTimePicker(
              context: context,
              initialTime: TimeOfDay.fromDateTime(current),
            );
            if (picked != null) {
              result = DateTime(
                current.year,
                current.month,
                current.day,
                picked.hour,
                picked.minute,
              );
            }
          } else {
            final picked = await showDatePicker(
              context: context,
              initialDate: current,
              firstDate: DateTime(2000),
              lastDate: DateTime(now.year + 1, 12, 31),
            );
            if (picked != null) {
              result = DateTime(
                picked.year,
                picked.month,
                picked.day,
                current.hour,
                current.minute,
              );
            }
          }
          if (result != null && context.mounted) {
            setState(() {
              if (first) {
                start = result!;
              } else {
                end = result!;
              }
            });
          }
        }

        return AlertDialog(
          title: const Text('Произвольный период'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final first in [true, false]) ...[
                Text(
                  first ? 'Начало' : 'Конец (не включая)',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Wrap(
                  children: [
                    TextButton(
                      onPressed: () => change(first, false),
                      child: Text(
                        MaterialLocalizations.of(context)
                            .formatMediumDate(first ? start : end),
                      ),
                    ),
                    TextButton(
                      onPressed: () => change(first, true),
                      child: Text(
                        TimeOfDay.fromDateTime(first ? start : end)
                            .format(context),
                      ),
                    ),
                  ],
                ),
              ],
              if (!end.isAfter(start))
                const Text('Конец должен быть позже начала'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: end.isAfter(start)
                  ? () => Navigator.pop(
                      context,
                      DateTimeRange(start: start, end: end),
                    )
                  : null,
              child: const Text('Применить'),
            ),
          ],
        );
      },
    ),
  );
}
