import 'package:flutter/material.dart';

String folderScanTime(DateTime? value, {DateTime? now}) {
  if (value == null) return 'Папка ещё не проверялась';
  final local = value.toLocal();
  final days = (now ?? DateTime.now()).difference(local).inDays;
  final date =
      '${local.day.toString().padLeft(2, '0')}.${local.month.toString().padLeft(2, '0')}.${local.year}';
  final age = days <= 0 ? 'сегодня' : '$days дн. назад';
  return 'Проверено $age · $date';
}

String folderScanReport(Map<String, dynamic> report, {bool audio = false}) =>
    'Найдено файлов: ${report['found']}, поддерживаемых: ${report['supported']}. '
    'Добавлено ${audio ? 'аудиокниг' : 'книг'}: ${report['added']}, обновлено: ${report['updated']}. '
    'Пропущено неподдерживаемых: ${report['unsupported']}, ошибок: ${report['errors']}'
    '${report['duplicates'] == null ? '' : ', дубликатов: ${report['duplicates']}'}.'
    '${(report['missing'] as num? ?? 0) == 0 ? '' : ' Не найдены прежние книги: ${report['missing']}.'}';

class FolderScanSummary extends StatelessWidget {
  final DateTime? lastScan;
  final Map<String, dynamic>? report;
  final List<String> warnings;
  final bool audio;
  const FolderScanSummary({
    super.key,
    this.lastScan,
    this.report,
    this.warnings = const [],
    this.audio = false,
  });
  @override
  Widget build(BuildContext context) {
    final attention =
        warnings.length +
        (audio ? 0 : (report?['missing'] as num? ?? 0).toInt());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(folderScanTime(lastScan)),
        if (lastScan == null ||
            DateTime.now().difference(lastScan!).inDays >= 7)
          const Text(
            'Обновите папку, чтобы найти новые файлы и проверить доступность прежних.',
          ),
        if (report != null) Text(folderScanReport(report!, audio: audio)),
        if (attention > 0) Text('Требуют внимания: $attention'),
        if (warnings.isNotEmpty) ...[
          for (final warning in warnings.take(20)) Text(warning),
          if (warnings.length > 20)
            const Text('Показаны первые 20 предупреждений.'),
        ],
      ],
    );
  }
}
