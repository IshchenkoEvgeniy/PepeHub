import 'library_features.dart';
import 'metadata_values.dart';
import 'models.dart';
import 'personal_library.dart';

typedef SeriesTitle = ({String title, num index});

List<SeriesTitle> parseSeriesTitles(String text, {num firstIndex = 1}) {
  final result = <SeriesTitle>[];
  var next = firstIndex;
  final numbered = RegExp(
    r'^(?:том\s+)?(\d+(?:[.,]\d+)?)[.)]\s+(.+)$',
    caseSensitive: false,
  );
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    final line = raw.trim().replaceFirst(RegExp(r'^[-*•]\s+'), '');
    if (line.isEmpty) continue;
    final match = numbered.firstMatch(line);
    final index = match == null
        ? next
        : num.parse(match[1]!.replaceAll(',', '.'));
    final title = (match?[2] ?? line).trim();
    result.add((title: title, index: index));
    next = index == index.round() ? index + 1 : index.ceil();
  }
  return result;
}

String seriesVolumeFingerprint(LibraryItem item) {
  final authors = metadataStrings(
    item.value('author'),
  ).map(seriesTextKey).toList()..sort();
  return '${item.mediaType}\u0000${seriesTextKey(item.title)}\u0000${authors.join('\u0000')}';
}

/// Warnings, not automatic merges. Choosing a warned row explicitly permits
/// creating a separate card, preserving all existing editions and history.
Map<String, String> seriesDraftConflicts(
  Iterable<LibraryItem> drafts,
  Iterable<LibraryEntry> existing, {
  String? existingSeriesKey,
}) {
  final known = <String, LibraryEntry>{
    for (final e in existing)
      if (isSeriesCatalogItem(e.item)) seriesVolumeFingerprint(e.item): e,
  };
  final seen = <String>{};
  final positions = <String>{};
  String? position(LibraryItem item) {
    final n = num.tryParse('${item.value('seriesIndex')}'.replaceAll(',', '.'));
    if (n == null || !n.isFinite) return null;
    return '${item.mediaType}:${n == n.round() ? n.round() : n}';
  }

  final occupied = <String>{
    if (existingSeriesKey != null)
      for (final e in existing)
        if (isSeriesCatalogItem(e.item) &&
            !isLibraryDeleted(e.item) &&
            librarySeriesKey(e.item) == existingSeriesKey &&
            position(e.item) != null)
          position(e.item)!,
  };
  final conflicts = <String, String>{};
  for (final item in drafts) {
    final fingerprint = seriesVolumeFingerprint(item);
    final found = known[fingerprint];
    final number = position(item);
    final repeatedTitle = !seen.add(fingerprint);
    final repeatedNumber = number != null && !positions.add(number);
    if (found != null) {
      conflicts[item.id] = isLibraryDeleted(found.item)
          ? 'Похожая карточка есть в корзине'
          : 'Похожая карточка уже есть в библиотеке';
    } else if (repeatedTitle) {
      conflicts[item.id] = 'Название повторяется в этом списке';
    } else if (number != null && occupied.contains(number)) {
      conflicts[item.id] = 'Том с таким номером и типом уже есть в серии';
    } else if (repeatedNumber) {
      conflicts[item.id] = 'Номер тома повторяется в этом списке';
    }
  }
  return conflicts;
}

void validateSeriesDraft(LibraryItem item) {
  if (!['book', 'audiobook'].contains(item.mediaType) ||
      !libraryItemStatuses(item).containsKey(libraryStatus(item))) {
    throw ArgumentError('Выберите статус каждого тома серии.');
  }
  if ('${item.value('title') ?? ''}'.trim().isEmpty ||
      '${item.value('series') ?? ''}'.trim().isEmpty) {
    throw ArgumentError('Укажите название серии и каждого тома.');
  }
  final index = num.tryParse(
    '${item.value('seriesIndex')}'.replaceAll(',', '.'),
  );
  if (index == null || !index.isFinite || index < 0) {
    throw ArgumentError('Укажите неотрицательный номер каждого тома.');
  }
  final start = DateTime.tryParse('${item.value('startDate')}');
  final end = DateTime.tryParse('${item.value('endDate')}');
  for (final field in ['startDate', 'endDate']) {
    final value = item.value(field);
    if (value != null && value != '' && DateTime.tryParse('$value') == null) {
      throw ArgumentError('Проверьте дату: ${item.title}');
    }
  }
  if (start != null && end != null && end.isBefore(start)) {
    throw ArgumentError('Дата завершения раньше даты начала: ${item.title}');
  }
  for (final field in ['total', 'progress', 'rating']) {
    final value = item.value(field);
    if (value == null || value == '') continue;
    final number = num.tryParse('$value');
    if (number == null ||
        !number.isFinite ||
        number < 0 ||
        field == 'rating' && number > 10) {
      throw ArgumentError('Проверьте объём, прогресс и оценку: ${item.title}');
    }
  }
  final total = num.tryParse('${item.value('total')}');
  final progress = num.tryParse('${item.value('progress')}');
  if (total != null && total > 0 && progress != null && progress > total) {
    throw ArgumentError('Прогресс больше общего объёма: ${item.title}');
  }
}
