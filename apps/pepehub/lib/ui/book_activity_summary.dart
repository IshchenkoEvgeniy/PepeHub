import 'package:flutter/material.dart';

import '../library/reading_insights.dart';

class BookActivityDayTile extends StatelessWidget {
  final BookActivityDay day;
  final String? title;
  final VoidCallback? onTap;
  const BookActivityDayTile({
    super.key,
    required this.day,
    this.title,
    this.onTap,
  });
  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.symmetric(vertical: 4),
    child: ListTile(
      onTap: onTap,
      title: Text(
        title ?? bookDateLabel(day.day),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          if (title != null) bookDateLabel(day.day),
          bookActivityTime(day.durationMs),
          if (day.progressLabel.isNotEmpty) '+ ${day.progressLabel}',
          '${day.slots.length} записей',
          if (day.slots.any((s) => s['conflict'] != null)) 'Есть конфликт',
        ].join(' · '),
      ),
      trailing: onTap == null ? null : const Icon(Icons.chevron_right),
    ),
  );
}
