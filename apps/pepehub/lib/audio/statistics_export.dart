import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';

import '../data/repository.dart';
import 'audio_folder.dart';
import 'audio_journal.dart';
import 'listening_analytics.dart';

class ListeningGoals {
  final int dailyMinutes, weeklyMinutes;
  const ListeningGoals({this.dailyMinutes = 30, this.weeklyMinutes = 180});
  Map<String, int> get json => {
    'dailyMinutes': dailyMinutes,
    'weeklyMinutes': weeklyMinutes,
  };
  static Future<ListeningGoals> load(Repository repository) async {
    final value = await repository.meta('audio-listening-goals');
    if (value == null) return const ListeningGoals();
    final data = jsonDecode(value);
    return ListeningGoals(
      dailyMinutes: data['dailyMinutes'] as int,
      weeklyMinutes: data['weeklyMinutes'] as int,
    );
  }

  Future<void> save(Repository repository) {
    if (dailyMinutes < 0 ||
        dailyMinutes > 1440 ||
        weeklyMinutes < 0 ||
        weeklyMinutes > 10080) {
      throw ArgumentError('Цель: 0–1440 минут в день, 0–10080 в неделю');
    }
    return repository.setMeta('audio-listening-goals', jsonEncode(json));
  }
}

String csvCell(Object? value) {
  var text = '${value ?? ''}';
  // Prevent a book title or bookmark note from becoming a spreadsheet formula.
  if (RegExp(r'^\s*[=+@-]').hasMatch(text)) text = "'$text";
  return '"${text.replaceAll('"', '""')}"';
}

String statisticsCsv(ListeningAnalytics analysis, Map<String, String> titles) {
  final rows = <List<Object?>>[
    [
      'type',
      'book_id',
      'title',
      'date',
      'active_ms',
      'material_ms',
      'unique_ms',
      'start_utc',
      'end_utc',
      'pauses',
      'seeks',
    ],
    [
      'total',
      '',
      '',
      '',
      analysis.selected.wallMs,
      analysis.selected.mediaMs,
      analysis.selected.uniqueMs,
      '',
      '',
      analysis.selected.pauses,
      analysis.selected.seeks,
    ],
    for (final e in analysis.selected.days.entries)
      ['day', '', '', e.key, e.value, '', '', '', '', '', ''],
    for (final e in analysis.byBook.entries)
      [
        'book',
        e.key,
        titles[e.key] ?? '',
        '',
        e.value.wallMs,
        e.value.mediaMs,
        e.value.uniqueMs,
        '',
        '',
        e.value.pauses,
        e.value.seeks,
      ],
    for (final s in analysis.sessions)
      [
        'session',
        s.bookId,
        titles[s.bookId] ?? '',
        s.localDay,
        s.wallMs,
        s.mediaMs,
        '',
        s.start.toUtc().toIso8601String(),
        s.end.toUtc().toIso8601String(),
        s.pauses,
        s.seeks,
      ],
  ];
  rows.first.addAll([
    'first_heard_ms',
    'repeated_ms',
    'metric',
    'value',
    'unit',
  ]);
  rows[1].addAll([analysis.firstHeardMs, analysis.repeatedHistoryMs]);
  for (final entry in <String, Object>{
    'average_speed': analysis.selected.averageSpeed,
    'longest_streak_days': analysis.lifetime.longestStreak,
    'bookmarks_added': analysis.selected.bookmarks,
    'sleep_fired': analysis.selected.timers,
    'errors': analysis.selected.errors,
    'bufferings': analysis.selected.bufferings,
    'forward_ms': analysis.selected.forwardMs,
    'backward_ms': analysis.selected.backwardMs,
  }.entries) {
    rows.add([
      'metric',
      '',
      '',
      '',
      '',
      '',
      '',
      '',
      '',
      '',
      '',
      '',
      '',
      entry.key,
      entry.value,
      '',
    ]);
  }
  for (final e in analysis.selected.speeds.entries) {
    rows.add([
      'speed',
      '',
      '',
      '',
      '',
      '',
      '',
      '',
      '',
      '',
      '',
      '',
      '',
      e.key,
      e.value,
      'active_ms',
    ]);
  }
  for (final e in analysis.selected.hours.entries) {
    rows.add([
      'hour',
      '',
      '',
      '',
      '',
      '',
      '',
      '',
      '',
      '',
      '',
      '',
      '',
      e.key,
      e.value,
      'active_ms',
    ]);
  }
  for (final row in rows) {
    while (row.length < rows.first.length) {
      row.add('');
    }
  }
  return '\ufeff${rows.map((r) => r.map(csvCell).join(',')).join('\r\n')}\r\n';
}

String statisticsJson(
  ListeningAnalytics analysis,
  Map<String, String> titles, {
  required int period,
  String? bookId,
  String? start,
  String? end,
}) => const JsonEncoder.withIndent('  ').convert({
  'format': 'pepehub-statistics',
  'version': 1,
  'createdAt': DateTime.now().toUtc().toIso8601String(),
  'periodDays': period,
  if (period == -1) 'startInclusive': start,
  if (period == -1) 'endExclusive': end,
  'bookId': bookId,
  'unit': 'milliseconds',
  'activeMs': analysis.selected.wallMs,
  'materialMs': analysis.selected.mediaMs,
  'uniqueMs': analysis.selected.uniqueMs,
  'firstHeardMs': analysis.firstHeardMs,
  'repeatedMs': analysis.repeatedHistoryMs,
  'days': analysis.selected.days,
  'averageSpeed': analysis.selected.averageSpeed,
  'speedActiveMs': analysis.selected.speeds,
  'hourActiveMs': {
    for (final e in analysis.selected.hours.entries) '${e.key}': e.value,
  },
  'longestStreakDays': analysis.lifetime.longestStreak,
  'counts': {
    'pauses': analysis.selected.pauses,
    'seeks': analysis.selected.seeks,
    'bookmarksAdded': analysis.selected.bookmarks,
    'sleepFired': analysis.selected.timers,
    'errors': analysis.selected.errors,
    'bufferings': analysis.selected.bufferings,
  },
  'books': [
    for (final e in analysis.byBook.entries)
      {
        'id': e.key,
        'title': titles[e.key],
        'activeMs': e.value.wallMs,
        'materialMs': e.value.mediaMs,
        'uniqueMs': e.value.uniqueMs,
      },
  ],
  'sessions': [
    for (final s in analysis.sessions)
      {
        'bookId': s.bookId,
        'start': s.start.toUtc().toIso8601String(),
        'end': s.end.toUtc().toIso8601String(),
        'localDay': s.localDay,
        'activeMs': s.wallMs,
        'elapsedMs': s.elapsedMs,
        'materialMs': s.mediaMs,
        'pauses': s.pauses,
        'seeks': s.seeks,
      },
  ],
});
Future<bool> saveStatisticsFile(String text, String format) async {
  final name = 'PepeHub-statistics-${dayKey(DateTime.now())}.$format';
  if (Platform.isAndroid) {
    return await audioFolderChannel.invokeMethod<bool>('exportStatistics', {
          'name': name,
          'mime': format == 'csv' ? 'text/csv' : 'application/json',
          'text': text,
        }) ??
        false;
  }
  final target = await getSaveLocation(
    suggestedName: name,
    acceptedTypeGroups: [
      XTypeGroup(label: format.toUpperCase(), extensions: [format]),
    ],
  );
  if (target == null) return false;
  await File(target.path).writeAsString(text, flush: true);
  return true;
}
