import '../data/repository.dart';

String _cell(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('|', '&#124;')
    .replaceAll(RegExp(r'[\r\n]'), ' ')
    .replaceAllMapped(RegExp(r'([\\`*_\[\]])'), (m) => '\\${m[1]}');
String exportMarkdown(List<LibraryRecord> books, List<LibraryRecord> sessions) {
  final lines = [
    '# Библиотека PepeHub',
    '',
    'Экспорт карточек и вручную введённых сессий. Время указано в UTC.',
    '',
  ];
  for (final book in books) {
    final data = book.payload!;
    lines.addAll([
      '<!-- pepehub:${book.id}:start -->',
      '## ${_cell(book.title)}',
      '',
      'Авторы: ${(data['authors'] as List).map((a) => _cell(a as String)).join(', ')}',
      'Формат: ${data['format']}',
      'Статус: ${data['status']}',
      '',
      '| Начало (UTC) | Минуты | ID сессии |',
      '| --- | ---: | --- |',
    ]);
    final history =
        sessions.where((s) => s.payload!['bookId'] == book.id).toList()..sort(
          (a, b) => (a.payload!['startedAt'] as String).compareTo(
            b.payload!['startedAt'] as String,
          ),
        );
    for (final session in history) {
      final s = session.payload!;
      lines.add(
        '| ${s['startedAt']} | ${((s['activeSeconds'] as num) / 60).toStringAsFixed(1)} | ${session.id} |',
      );
    }
    lines.addAll(['<!-- pepehub:${book.id}:end -->', '']);
  }
  return '${lines.join('\n')}\n';
}
