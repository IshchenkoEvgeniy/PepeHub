import 'models.dart';

const libraryStatusLabels = {
  'planned': 'В планах',
  'active': 'Чтение',
  'paused': 'На паузе',
  'abandoned': 'Брошена',
  'finished': 'Прочитано',
};

String canonicalLibraryStatus(Object? value) {
  final text = '$value'.trim().toLowerCase();
  return switch (text) {
    'finished' ||
    'completed' ||
    'done' ||
    'прочитано' ||
    'прослушано' ||
    'завершена' ||
    'завершено' => 'finished',
    'active' ||
    'reading' ||
    'listening' ||
    'чтение' ||
    'читаю' ||
    'слушаю' ||
    'прослушивание' => 'active',
    'paused' || 'pause' || 'на паузе' => 'paused',
    'отложена' || 'отложено' || 'on hold' => 'paused',
    'abandoned' || 'dropped' || 'dnf' || 'брошена' || 'брошено' => 'abandoned',
    'planned' || 'new' || 'в планах' || 'запланировано' => 'planned',
    _ => text,
  };
}

Map<String, String> libraryStatuses(Map? collection) => {
  for (final entry in libraryStatusLabels.entries)
    entry.key:
        '${(collection?['statuses'] as Map?)?[entry.key] ?? entry.value}',
};

String exportLibraryStatus(Object? value, Map? collection) {
  final canonical = canonicalLibraryStatus(value);
  final configured = collection?['statuses'] as Map?;
  return '${configured?[canonical] ?? value ?? ''}';
}

Map<String, dynamic> matchLibraryProgress(
  Map<String, dynamic> details,
  ObsidianLibraryItem target,
) {
  final result = Map<String, dynamic>.from(details);
  if (details['unit'] == 'minutes' && target.value('unit') == 'hours') {
    for (final field in ['durationMinutes', 'listenedMinutes']) {
      if (details[field] is num) result[field] = (details[field] as num) / 60;
    }
    result['unit'] = 'hours';
  }
  final total = num.tryParse('${target.value('total')}');
  if (details['unit'] == 'characters' &&
      target.value('unit') == 'pages' &&
      total != null &&
      total > 0 &&
      (details['total'] as num? ?? 0) > 0) {
    result['progress'] =
        (total * (details['progress'] as num? ?? 0) / (details['total'] as num))
            .round();
    result['total'] = total;
    result['unit'] = 'pages';
  }
  if (details['unit'] == 'pages' &&
      target.value('unit') == 'percent' &&
      (details['total'] as num? ?? 0) > 0) {
    result['progress'] =
        ((details['progress'] as num? ?? 0) * 10000 / (details['total'] as num))
            .round() /
        100;
    result['total'] = 100;
    result['unit'] = 'percent';
  }
  return result;
}

List<String> metadataStrings(Object? value) {
  final values = value is List ? value : ['$value'];
  final seen = <String>{};
  return [
    for (final raw in values)
      if (raw != null && '$raw' != 'null')
        for (final part
            in value is List ? ['$raw'] : '$raw'.split(RegExp(r'[,;\n]')))
          if (part.trim().isNotEmpty && seen.add(part.trim().toLowerCase()))
            part.trim(),
  ];
}

Map<String, List<String>> metadataSuggestions(Iterable<LibraryEntry> entries) {
  final values = <String, List<String>>{};
  for (final entry in entries.where((e) => e.state != 'removed')) {
    for (final field in [
      'author',
      'genre',
      'series',
      'status',
      'format',
      'unit',
    ]) {
      (values[field] ??= []).addAll(metadataStrings(entry.item.value(field)));
    }
    for (final field in ['language', 'publisher', 'narrator', 'tags']) {
      (values[field] ??= []).addAll(metadataStrings(entry.item.values[field]));
    }
  }
  return {
    for (final entry in values.entries)
      entry.key: metadataStrings(entry.value)
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase())),
  };
}

/// A filename is a suggestion, never an authoritative replacement for tags.
Map<String, dynamic>? suggestAudioTitle(String name) {
  final match = RegExp(r'^(.+?)\s+[-–—]\s+(.+?)(?:\s+\[([^\]]+)\])?$')
      .firstMatch(name.trim());
  if (match == null) return null;
  var title = match[2]!.trim();
  final part = RegExp(r'\s+(\d{1,3}|I|II|III|IV|V|VI|VII|VIII|IX|X)$')
      .firstMatch(title);
  const roman = {
    'I': 1,
    'II': 2,
    'III': 3,
    'IV': 4,
    'V': 5,
    'VI': 6,
    'VII': 7,
    'VIII': 8,
    'IX': 9,
    'X': 10,
  };
  final number = part == null
      ? null
      : int.tryParse(part[1]!) ?? roman[part[1]!];
  if (part != null) title = title.substring(0, part.start).trim();
  return {
    'title': title,
    'author': [match[1]!.trim()],
    'seriesIndex': ?number,
    if (match[3] != null) 'narrator': match[3]!.trim(),
  };
}
