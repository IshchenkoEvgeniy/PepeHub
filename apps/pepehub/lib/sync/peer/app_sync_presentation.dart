import 'app_sync_models.dart';

const _fieldNames = {
  'title': 'Название',
  'name': 'Название',
  'front': 'Лицевая сторона',
  'back': 'Обратная сторона',
  'body': 'Текст',
  'text': 'Текст',
  'comment': 'Комментарий',
  'quote': 'Цитата',
  'notes': 'Заметка',
  'authors': 'Авторы',
  'tags': 'Теги',
  'characters': 'Персонажи',
  'color': 'Цвет',
  'status': 'Статус',
  'chapter': 'Глава',
  'textOffset': 'Положение в главе',
  'positionMs': 'Позиция',
  'speed': 'Скорость',
  'artist': 'Исполнитель',
  'album': 'Альбом',
  'trackNumber': 'Номер трека',
  'deck': 'Колода Anki',
  'updatedAt': 'Время изменения',
  'updated': 'Время изменения',
  'createdAt': 'Время создания',
  'deadline': 'Срок',
  'dailyMinutes': 'Минут в день',
  'bodyFormat': 'Формат текста',
  'description': 'Описание',
  'module': 'Раздел',
  'ordinal': 'Порядок',
  'favorite': 'Избранное',
};

Map<String, String> appSyncDisplayFields(
  Map<String, dynamic>? value, {
  bool complete = false,
}) {
  if (value == null) return {'Состояние': 'Удалено'};
  final result = <String, String>{'Состояние': 'Сохранено'};
  void visit(Map values, String prefix, int depth) {
    for (final entry in values.entries) {
      final key = '${entry.key}';
      if ([
        'version',
        'schemaVersion',
        'id',
        'bookId',
        'lessonId',
        'mediaVersion',
        'hash',
        'manifest',
        'trackId',
      ].contains(key)) {
        continue;
      }
      final label = [
        if (prefix.isNotEmpty) prefix,
        _fieldNames[key] ?? key,
      ].join(' / ');
      final data = entry.value;
      if (data is Map && depth < 3) {
        visit(data, label, depth + 1);
        continue;
      }
      String text;
      if (data == null) {
        text = 'Не указано';
      } else if (data is bool) {
        text = data ? 'Да' : 'Нет';
      } else if (data is List || data is Map) {
        text = appSyncJson(data);
      } else if (key == 'positionMs' && data is num) {
        final seconds = data.toInt() ~/ 1000;
        text =
            '${seconds ~/ 3600}:${(seconds ~/ 60 % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
      } else if (key == 'chapter' && data is int) {
        text = '${data + 1}';
      } else if (key == 'speed') {
        text = '$data×';
      } else {
        text = '$data';
      }
      result[label] = !complete && text.length > 2000
          ? '${text.substring(0, 2000)}…'
          : text;
    }
  }

  visit(value, '', 0);
  return result;
}

List<String> appSyncChangedFields(List<AppSyncVersion> versions) {
  final all = versions
      .map((version) => appSyncDisplayFields(version.value, complete: true))
      .toList();
  final keys = {for (final fields in all) ...fields.keys};
  return keys
      .where(
        (key) =>
            all.map((fields) => fields[key] ?? 'Нет значения').toSet().length >
            1,
      )
      .toList();
}

String readerPositionDescription(
  Map<String, dynamic> value,
  Map<String, dynamic> index,
) {
  final chapter = (value['chapter'] as num?)?.toInt() ?? 0;
  final chapters = index['chapters'] is List
      ? index['chapters'] as List
      : const [];
  final lengths = index['lengths'] is List
      ? index['lengths'] as List
      : const [];
  final title = chapter >= 0 && chapter < chapters.length
      ? '${chapters[chapter]}'
      : index['pdfPages'] == null
      ? 'Глава ${chapter + 1}'
      : 'Страница ${chapter + 1}';
  final length =
      chapter >= 0 && chapter < lengths.length && lengths[chapter] is num
      ? (lengths[chapter] as num).toInt()
      : 0;
  final offset = (value['textOffset'] as num?)?.toInt() ?? 0;
  return [
    title,
    if (length > 0)
      '${(offset * 100 / length).clamp(0, 100).toStringAsFixed(0)}% главы',
  ].join(' · ');
}

String readerPositionContext(String text, int offset) {
  final at = offset.clamp(0, text.length);
  var from = (at - 120).clamp(0, text.length),
      to = (at + 180).clamp(0, text.length);
  bool low(int unit) => unit >= 0xdc00 && unit <= 0xdfff;
  if (from < text.length && low(text.codeUnitAt(from))) from++;
  if (to < text.length && low(text.codeUnitAt(to))) to--;
  return '${from > 0 ? '…' : ''}${text.substring(from, to).trim()}${to < text.length ? '…' : ''}';
}
