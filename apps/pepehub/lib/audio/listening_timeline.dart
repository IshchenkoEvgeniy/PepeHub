/// The player's «История»: what was actually heard and where the listener
/// jumped, built from the journal's `listen` and `seek` events.
///
/// Rewind/forward taps in quick succession collapse into one entry with
/// their net effect, and the journal's hourly listening records merge back
/// into continuous spans, so the list reads as a short diary rather than a
/// log of every button press.
library;

sealed class TimelineEntry {
  /// Local time the entry began.
  DateTime get at;
}

/// Continuous listening of one track.
class ListenSpan extends TimelineEntry {
  final String trackId;
  final int startMs;
  int endMs;
  @override
  final DateTime at;
  DateTime end;

  /// The sleep timer stopped playback at the end of this span.
  bool sleep = false;
  ListenSpan(this.trackId, this.startMs, this.endMs, this.at, this.end);

  Duration get wall => end.difference(at);
}

/// A deliberate move: chapter, bookmark, timeline, or a run of skips.
class JumpEntry extends TimelineEntry {
  final String fromTrack;
  final int fromMs;
  String toTrack;
  int toMs;
  final String reason;
  @override
  final DateTime at;
  DateTime last;

  /// Skips merged into this entry; 1 for a single move.
  int count = 1;
  JumpEntry(
    this.fromTrack,
    this.fromMs,
    this.toTrack,
    this.toMs,
    this.reason,
    this.at,
  ) : last = at;

  /// ±N seconds buttons: worth showing, not worth a line each.
  bool get skip => skipReasons.contains(reason);

  /// Net movement within one track, or null across tracks.
  int? get deltaMs => fromTrack == toTrack ? toMs - fromMs : null;

  static const skipReasons = {'rewind', 'forward'};
}

class TimelineDay {
  final DateTime day;
  final List<TimelineEntry> entries;
  const TimelineDay(this.day, this.entries);
}

/// Skips this close together are one gesture.
const _skipGap = Duration(seconds: 90);

/// Listening records this close in time and position are one span.
const _listenGap = Duration(minutes: 5);
const _listenSlackMs = 3000;

/// A few seconds heard between two skips belong to the skipping.
const _probeMs = 20000;

/// [events] are journal payloads in any order; days and entries come out
/// newest first.
List<TimelineDay> buildListeningTimeline(
  Iterable<Map<String, dynamic>> events,
) {
  final parsed = <({DateTime at, Map<String, dynamic> e})>[];
  for (final e in events) {
    final at = DateTime.tryParse('${e['at'] ?? ''}');
    if (at != null) parsed.add((at: at.toLocal(), e: e));
  }
  parsed.sort((a, b) => a.at.compareTo(b.at));
  final out = <TimelineEntry>[];
  for (final (:at, :e) in parsed) {
    switch (e['kind']) {
      case 'listen':
        final track = e['trackId'], start = e['positionMs'], end = e['endMs'];
        if (track is! String || start is! num || end is! num) continue;
        final wall = (e['wallMs'] as num?)?.toInt() ?? end - start;
        final stop = at.add(Duration(milliseconds: wall.toInt()));
        final last = out.lastOrNull;
        if (last is ListenSpan &&
            last.trackId == track &&
            (start - last.endMs).abs() <= _listenSlackMs &&
            !at.isAfter(last.end.add(_listenGap))) {
          last
            ..endMs = end.toInt()
            ..end = stop;
        } else {
          out.add(ListenSpan(track, start.toInt(), end.toInt(), at, stop));
        }
      case 'seek':
        final from = e['fromTrackId'], fromMs = e['fromMs'];
        final to = e['trackId'], toMs = e['positionMs'];
        if (from is! String || fromMs is! num) continue;
        if (to is! String || toMs is! num) continue;
        final reason = '${e['reason'] ?? 'seek'}';
        final skip = JumpEntry.skipReasons.contains(reason);
        if (skip) {
          // A short probe between skips is part of the same search.
          var previous = out.lastOrNull;
          if (previous is ListenSpan &&
              previous.endMs - previous.startMs < _probeMs &&
              out.length >= 2) {
            final before = out[out.length - 2];
            if (before is JumpEntry &&
                before.skip &&
                !at.isAfter(before.last.add(_skipGap))) {
              out.removeLast();
              previous = before;
            }
          }
          if (previous is JumpEntry &&
              previous.skip &&
              previous.toTrack == from &&
              !at.isAfter(previous.last.add(_skipGap))) {
            previous
              ..toTrack = to
              ..toMs = toMs.toInt()
              ..last = at
              ..count += 1;
            continue;
          }
        }
        out.add(JumpEntry(from, fromMs.toInt(), to, toMs.toInt(), reason, at));
      case 'sleep_fired':
        final last = out.lastOrNull;
        if (last is ListenSpan &&
            !at.isAfter(last.end.add(const Duration(minutes: 2)))) {
          last.sleep = true;
        }
    }
  }
  final days = <DateTime, List<TimelineEntry>>{};
  for (final entry in out.reversed) {
    final day = DateTime(entry.at.year, entry.at.month, entry.at.day);
    (days[day] ??= []).add(entry);
  }
  return [
    for (final MapEntry(:key, :value) in days.entries) TimelineDay(key, value),
  ];
}
