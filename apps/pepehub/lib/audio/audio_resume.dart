import 'dart:convert';

import '../data/repository.dart';
import 'models.dart';

/// Explicit, configurable policy; these thresholds are PepeHub's defaults,
/// not a claimed copy of a closed-source player's internal formula.
class AudioRewindSettings {
  final bool enabled;
  final int shortSeconds, mediumSeconds, longSeconds;
  const AudioRewindSettings({
    this.enabled = true,
    this.shortSeconds = 3,
    this.mediumSeconds = 10,
    this.longSeconds = 30,
  });
  int secondsAfter(Duration pause) {
    if (!enabled || pause < const Duration(seconds: 5)) return 0;
    if (pause < const Duration(minutes: 1)) return shortSeconds;
    if (pause < const Duration(hours: 1)) return mediumSeconds;
    return longSeconds;
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'short': shortSeconds,
    'medium': mediumSeconds,
    'long': longSeconds,
  };
  factory AudioRewindSettings.fromJson(dynamic value) {
    final v = value is Map ? value : const {};
    int seconds(String key, int fallback) =>
        v[key] is int && v[key] >= 0 && v[key] <= 300
        ? v[key] as int
        : fallback;
    return AudioRewindSettings(
      enabled: v['enabled'] != false,
      shortSeconds: seconds('short', 3),
      mediumSeconds: seconds('medium', 10),
      longSeconds: seconds('long', 30),
    );
  }
  AudioRewindSettings copyWith({
    bool? enabled,
    int? shortSeconds,
    int? mediumSeconds,
    int? longSeconds,
  }) => AudioRewindSettings(
    enabled: enabled ?? this.enabled,
    shortSeconds: shortSeconds ?? this.shortSeconds,
    mediumSeconds: mediumSeconds ?? this.mediumSeconds,
    longSeconds: longSeconds ?? this.longSeconds,
  );
}

bool sameAudioPosition(AudioLocator a, AudioLocator b) =>
    a.bookId == b.bookId &&
    a.editionId == b.editionId &&
    a.trackId == b.trackId &&
    a.manifestRevision == b.manifestRevision &&
    a.positionMs == b.positionMs;

class AudioPauseCheckpoint {
  final String id, reason;
  final AudioLocator locator;
  final DateTime pausedAt;
  const AudioPauseCheckpoint(this.id, this.locator, this.pausedAt, this.reason);
  Map<String, dynamic> toJson() => {
    'version': 1,
    'id': id,
    'locator': locator.toJson(),
    'pausedAt': pausedAt.toUtc().toIso8601String(),
    'reason': reason,
  };
  factory AudioPauseCheckpoint.fromJson(Map<String, dynamic> v) {
    if (v['version'] != 1 ||
        v['id'] is! String ||
        !['pause', 'sleep'].contains(v['reason'])) {
      throw const FormatException('Некорректная точка продолжения');
    }
    final l = v['locator'] as Map;
    return AudioPauseCheckpoint(
      v['id'] as String,
      AudioLocator(
        bookId: l['bookId'] as String,
        editionId: l['editionId'] as String,
        trackId: l['trackId'] as String,
        positionMs: l['positionMs'] as int,
        manifestRevision: l['manifestRevision'] as int,
      ),
      DateTime.parse(v['pausedAt'] as String),
      v['reason'] as String,
    );
  }
}

/// Device-local intent; it must never rewind a different synced checkpoint.
class AudioResumeStore {
  final Repository repository;
  AudioResumeStore(this.repository);
  String key(String edition) => 'audio-resume:$edition';
  Future<AudioPauseCheckpoint?> load(String edition) async {
    final raw = await repository.meta(key(edition));
    if (raw == null) return null;
    try {
      return AudioPauseCheckpoint.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> save(AudioPauseCheckpoint checkpoint) async {
    final previous = await load(checkpoint.locator.editionId);
    // Repeated Pause/Stop/shutdown must not reset time away or turn Sleep into Pause.
    if (previous != null &&
        sameAudioPosition(previous.locator, checkpoint.locator) &&
        !(checkpoint.reason == 'sleep' && previous.reason != 'sleep')) {
      return;
    }
    await repository.setMeta(
      key(checkpoint.locator.editionId),
      jsonEncode(checkpoint.toJson()),
    );
  }

  Future<void> clear(String edition) => repository.db.customStatement(
    'DELETE FROM metadata WHERE key=?',
    [key(edition)],
  );
  Future<bool> consume(AudioPauseCheckpoint checkpoint) async {
    final current = await load(checkpoint.locator.editionId);
    if (current?.id != checkpoint.id) return false;
    await clear(checkpoint.locator.editionId);
    return true;
  }
}
