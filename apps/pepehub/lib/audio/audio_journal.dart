import 'dart:convert';

import 'package:drift/drift.dart';

import '../data/repository.dart';

/// Local records intentionally bypass the deferred remote outbox.
class AudioJournal {
  final Repository repository;
  AudioJournal(this.repository);
  static const noteKinds = ['thought', 'quote', 'character'];
  static void validateNote(Map<String, dynamic> data) {
    if (!noteKinds.contains(data['kind']) ||
        data['text'] is! String ||
        (data['text'] as String).trim().isEmpty ||
        (data['text'] as String).length > 10000 ||
        data['title'] is! String ||
        (data['title'] as String).length > 200 ||
        data['positionMs'] is! int ||
        (data['positionMs'] as int) < 0) {
      throw ArgumentError(
        'Заметка: текст 1–10000 символов, заголовок до 200 и корректная позиция',
      );
    }
  }

  Future<String> saveNote({
    String? id,
    required String bookId,
    required String trackId,
    required int positionMs,
    required String kind,
    required String title,
    required String text,
  }) async {
    final previous = id == null ? null : await repository.record(id);
    if (id != null &&
        (previous == null ||
            previous.type != 'audio_note' ||
            previous.deleted ||
            previous.payload?['bookId'] != bookId)) {
      throw StateError('Заметка не найдена');
    }
    final data = <String, dynamic>{
      'bookId': bookId,
      'trackId': previous?.payload?['trackId'] ?? trackId,
      'positionMs': previous?.payload?['positionMs'] ?? positionMs,
      'kind': kind,
      'title': title.trim(),
      'text': text.trim(),
      'at':
          previous?.payload?['at'] ?? DateTime.now().toUtc().toIso8601String(),
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    };
    validateNote(data);
    final track = await repository.db
        .customSelect(
          'SELECT t.id FROM audio_tracks t JOIN audio_editions e ON e.id=t.edition_id WHERE t.id=? AND e.book_id=?',
          variables: [Variable(data['trackId'] as String), Variable(bookId)],
        )
        .getSingleOrNull();
    if (track == null) throw StateError('Глава заметки не принадлежит книге');
    final noteId = id ?? uuid.v4();
    await put('audio_note', noteId, data);
    return noteId;
  }

  Future<void> deleteNote(String id, {bool restore = false}) =>
      repository.db.customStatement(
        "UPDATE records SET deleted=?,revision=revision+1 WHERE id=? AND type='audio_note'",
        [restore ? 0 : 1, id],
      );
  String? _listenId;
  Map<String, dynamic>? _listenData;
  void endInterval() {
    _listenId = null;
    _listenData = null;
  }

  Future<void> appendListening(ListeningSegment segment) async {
    var data = segment.data;
    final previous = _listenData;
    final previousAt = previous == null
        ? null
        : DateTime.parse(previous['at'] as String);
    final at = segment.at.toUtc();
    final continuous =
        previous != null &&
        previous['bookId'] == data['bookId'] &&
        previous['trackId'] == data['trackId'] &&
        previous['endMs'] == data['positionMs'] &&
        previous['speed'] == data['speed'] &&
        previous['localDay'] == data['localDay'] &&
        previousAt!.hour == at.hour &&
        at
                .difference(
                  previousAt.add(
                    Duration(milliseconds: previous['wallMs'] as int),
                  ),
                )
                .inMilliseconds
                .abs() <=
            50;
    final id = continuous ? _listenId! : uuid.v4();
    if (continuous) {
      data = {
        ...previous,
        'endMs': segment.endMs,
        'mediaMs': segment.endMs - (previous['positionMs'] as int),
        'wallMs': (previous['wallMs'] as int) + segment.wallMs,
      };
    }
    await put('audio_event', id, data);
    _listenId = id;
    _listenData = data;
  }

  Future<void> ensureIndexes() => repository.db.customStatement(
    "CREATE INDEX IF NOT EXISTS records_audio_day ON records(type,json_extract(payload,'\$.localDay'),json_extract(payload,'\$.bookId'))",
  );
  Future<void> put(String type, String id, Map<String, dynamic> data) =>
      repository.db.customStatement(
        'INSERT INTO records(id,type,revision,deleted,payload) VALUES(?,?,1,0,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,deleted=0,revision=records.revision+1',
        [id, type, jsonEncode(data)],
      );

  Future<void> deleteEvent(String id) async {
    final record = await repository.record(id);
    if (record == null || record.type != 'audio_event' || record.deleted) {
      throw StateError('Событие прослушивания не найдено');
    }
    await repository.db.customStatement(
      "UPDATE records SET deleted=1,revision=revision+1 WHERE id=? AND type='audio_event' AND deleted=0",
      [id],
    );
  }

  Future<void> event(
    String kind,
    String bookId,
    String trackId,
    int positionMs, {
    Map<String, dynamic> extra = const {},
  }) async {
    endInterval();
    final now = DateTime.now();
    await put('audio_event', uuid.v4(), {
      'version': 1,
      'kind': kind,
      'bookId': bookId,
      'trackId': trackId,
      'positionMs': positionMs,
      'at': now.toUtc().toIso8601String(),
      'offsetMinutes': now.timeZoneOffset.inMinutes,
      'localDay': dayKey(now),
      'timezone': now.timeZoneName,
      ...extra,
    });
  }

  Future<List<LibraryRecord>> list(
    String type, {
    String? bookId,
    String? kind,
    int limit = 200,
  }) async =>
      (await repository.db
              .customSelect(
                "SELECT * FROM records WHERE type=? AND deleted=0 ${bookId == null ? '' : "AND json_extract(payload,'\$.bookId')=?"} ${kind == null ? '' : "AND json_extract(payload,'\$.kind')=?"} ORDER BY json_extract(payload,'\$.at') DESC,id DESC LIMIT ?",
                variables: [
                  Variable(type),
                  if (bookId != null) Variable(bookId),
                  if (kind != null) Variable(kind),
                  Variable(limit),
                ],
              )
              .get())
          .map(LibraryRecord.fromRow)
          .toList();
  Future<void> bookmark(
    String bookId,
    String trackId,
    int positionMs,
    String title,
  ) async {
    if (title.trim().isEmpty || title.length > 500) {
      throw ArgumentError('Название закладки: 1–500 символов');
    }
    await put('audio_bookmark', uuid.v4(), {
      'bookId': bookId,
      'trackId': trackId,
      'positionMs': positionMs,
      'title': title.trim(),
      'at': DateTime.now().toUtc().toIso8601String(),
    });
    await event('bookmark', bookId, trackId, positionMs);
  }

  Future<void> editBookmark(String id, String title) async {
    final clean = title.trim();
    if (clean.isEmpty || clean.length > 500) {
      throw ArgumentError('Название: 1–500 символов');
    }
    final row = await repository.record(id);
    if (row == null || row.type != 'audio_bookmark' || row.deleted) {
      throw StateError('Закладка не найдена');
    }
    await put('audio_bookmark', id, {...row.payload!, 'title': clean});
  }

  Future<void> restoreBookmark(String id) => repository.db.customStatement(
    "UPDATE records SET deleted=0,revision=revision+1 WHERE id=? AND type='audio_bookmark'",
    [id],
  );

  Future<void> deleteBookmark(String id) => repository.db.customStatement(
    "UPDATE records SET deleted=1,revision=revision+1 WHERE id=? AND type='audio_bookmark'",
    [id],
  );
}

String dayKey(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

/// A contiguous audible range. Discontinuities/seeks never become listened time.
class ListeningSegment {
  final String bookId, trackId;
  final int startMs, endMs, wallMs;
  final double speed;
  final DateTime at;
  ListeningSegment(
    this.bookId,
    this.trackId,
    this.startMs,
    this.endMs,
    this.wallMs,
    this.speed,
    this.at,
  );
  Map<String, dynamic> get data => {
    'version': 1,
    'kind': 'listen',
    'bookId': bookId,
    'trackId': trackId,
    'positionMs': startMs,
    'endMs': endMs,
    'wallMs': wallMs,
    'mediaMs': endMs - startMs,
    'speed': speed,
    'at': at.toUtc().toIso8601String(),
    'offsetMinutes': at.timeZoneOffset.inMinutes,
    'localDay': dayKey(at),
    'timezone': at.timeZoneName,
  };
}

class ListeningSampler {
  final List<ListeningSegment> pending = [];
  String? _book, _track;
  int _position = 0, _mono = 0;
  double _speed = 1;
  bool _audible = false;
  DateTime? _at;
  void sample({
    required String bookId,
    required String trackId,
    required int positionMs,
    required int monotonicMs,
    required double speed,
    required bool audible,
    required DateTime at,
  }) {
    final elapsed = monotonicMs - _mono, moved = positionMs - _position;
    if (_audible &&
        _book == bookId &&
        _track == trackId &&
        elapsed > 0 &&
        elapsed <= 15000 &&
        moved > 0 &&
        (moved - elapsed * _speed).abs() <= 1500) {
      final segment = ListeningSegment(
        bookId,
        trackId,
        _position,
        positionMs,
        elapsed,
        _speed,
        _at!,
      );
      if (pending.isNotEmpty) {
        final previous = pending.last;
        if (previous.trackId == trackId &&
            previous.endMs == segment.startMs &&
            previous.speed == segment.speed &&
            dayKey(previous.at) == dayKey(segment.at) &&
            segment.at
                    .difference(
                      previous.at.add(Duration(milliseconds: previous.wallMs)),
                    )
                    .inMilliseconds
                    .abs() <=
                5 &&
            previous.wallMs < 10000) {
          pending[pending.length - 1] = ListeningSegment(
            bookId,
            trackId,
            previous.startMs,
            segment.endMs,
            previous.wallMs + elapsed,
            _speed,
            previous.at,
          );
        } else {
          pending.add(segment);
        }
      } else {
        pending.add(segment);
      }
    }
    _book = bookId;
    _track = trackId;
    _position = positionMs;
    _mono = monotonicMs;
    _speed = speed;
    _audible = audible;
    _at = at;
  }
}

class AudioStats {
  int wallMs = 0,
      mediaMs = 0,
      uniqueMs = 0,
      seeks = 0,
      bookmarks = 0,
      timers = 0,
      pauses = 0,
      errors = 0,
      bufferings = 0,
      completions = 0,
      forwardMs = 0,
      backwardMs = 0;
  final Map<String, int> days = {}, books = {}, speeds = {};
  final Map<int, int> hours = {};
  final List<Map<String, dynamic>> recent = [];
  AudioStats(Iterable<Map<String, dynamic>> events) {
    final ranges = <String, List<(int, int)>>{};
    for (final e in events) {
      final kind = e['kind'];
      if (kind == 'listen') {
        final wall = (e['wallMs'] as num).toInt(),
            start = (e['positionMs'] as num).toInt(),
            end = (e['endMs'] as num).toInt();
        if (wall <= 0 || end <= start) continue;
        wallMs += wall;
        mediaMs += end - start;
        final day = e['localDay'] as String, book = e['bookId'] as String;
        days[day] = (days[day] ?? 0) + wall;
        books[book] = (books[book] ?? 0) + wall;
        final speed = '${e['speed']}';
        speeds[speed] = (speeds[speed] ?? 0) + wall;
        final local = DateTime.parse(e['at'] as String)
            .toUtc()
            .add(Duration(minutes: (e['offsetMinutes'] as num?)?.toInt() ?? 0));
        hours[local.hour] = (hours[local.hour] ?? 0) + wall;
        ranges.putIfAbsent('$book:${e['trackId']}', () => []).add((start, end));
      } else if (kind == 'seek') {
        seeks++;
        if (e['trackId'] == e['fromTrackId'] && e['fromMs'] is num) {
          final delta =
              (e['positionMs'] as num).toInt() - (e['fromMs'] as num).toInt();
          if (delta > 0) {
            forwardMs += delta;
          } else {
            backwardMs -= delta;
          }
        }
      } else if (kind == 'pause') {
        pauses++;
      } else if (kind == 'error') {
        errors++;
      } else if (kind == 'buffering') {
        bufferings++;
      } else if (kind == 'completed') {
        completions++;
      } else if (kind == 'bookmark') {
        bookmarks++;
      } else if (kind == 'sleep_fired') {
        timers++;
      }
    }
    final sorted = events.toList()
      ..sort(
        (a, b) =>
            (b['at'] as String? ?? '').compareTo(a['at'] as String? ?? ''),
      );
    recent.addAll(sorted.where((e) => e['kind'] != 'listen').take(100));
    for (final list in ranges.values) {
      list.sort((a, b) => a.$1.compareTo(b.$1));
      int? start;
      var end = 0;
      for (final range in list) {
        if (start == null) {
          start = range.$1;
          end = range.$2;
        } else if (range.$1 <= end) {
          if (range.$2 > end) end = range.$2;
        } else {
          uniqueMs += end - start;
          start = range.$1;
          end = range.$2;
        }
      }
      if (start != null) uniqueMs += end - start;
    }
  }
  int get longestStreak {
    final sorted = days.keys.toList()..sort();
    var best = 0, current = 0;
    DateTime? previous;
    for (final key in sorted) {
      final date = DateTime.parse('${key}T00:00:00Z');
      current = previous != null && date.difference(previous).inDays == 1
          ? current + 1
          : 1;
      if (current > best) best = current;
      previous = date;
    }
    return best;
  }

  int get repeatedMs => mediaMs - uniqueMs;
  double get averageSpeed => wallMs == 0 ? 0 : mediaMs / wallMs;
}
