enum VideoItemKind { video, course }

enum VideoActivityMode { visual, audio, study }

class VideoFileIdentity {
  final int size, modifiedMs;
  final String fingerprint, sample;
  const VideoFileIdentity(
    this.size,
    this.modifiedMs,
    this.fingerprint, {
    this.sample = 'head-tail-v1',
  });
  Map<String, dynamic> toJson() => {
    'size': size,
    'modifiedMs': modifiedMs,
    'fingerprint': fingerprint,
    'sample': sample,
  };
  factory VideoFileIdentity.fromJson(Map<String, dynamic> data) =>
      VideoFileIdentity(
        data['size'] as int,
        data['modifiedMs'] as int,
        data['fingerprint'] as String,
        sample: data['sample'] as String? ?? 'head-tail-v1',
      );
  bool sameSample(VideoFileIdentity other) =>
      sample == other.sample &&
      size == other.size &&
      fingerprint == other.fingerprint;
}

class VideoLessonEdit {
  final String id, title, module;
  const VideoLessonEdit(this.id, this.title, this.module);
}

class VideoFolderBinding {
  final String id, source;
  final String? relativeName;
  final VideoFileIdentity? identity;
  final bool available, newVersion;
  const VideoFolderBinding(
    this.id,
    this.source, {
    this.relativeName,
    this.identity,
    this.available = true,
    this.newVersion = false,
  });
}

class VideoItem {
  final String id, title;
  final VideoItemKind kind;
  final String? root;
  final bool favorite;
  final bool connected;
  const VideoItem({
    required this.id,
    required this.title,
    required this.kind,
    this.root,
    this.favorite = false,
    this.connected = true,
  });

  factory VideoItem.fromJson(String id, Map<String, dynamic> data) => VideoItem(
    id: id,
    title: data['title'] as String,
    kind: VideoItemKind.values.byName(data['kind'] as String),
    root: data['root'] as String?,
    favorite: data['favorite'] == true,
    connected: data['connected'] != false,
  );

  Map<String, dynamic> toJson() => {
    'version': 1,
    'title': title,
    'kind': kind.name,
    'root': root,
    'favorite': favorite,
    'connected': connected,
  };
}

class VideoLesson {
  final String id, itemId, title, module, source, mediaVersion;
  final int ordinal;
  final int? durationMs;
  final bool available;
  const VideoLesson({
    required this.id,
    required this.itemId,
    required this.title,
    required this.module,
    required this.source,
    required this.mediaVersion,
    required this.ordinal,
    this.durationMs,
    this.available = true,
  });

  bool get isRemote {
    final uri = Uri.tryParse(source);
    return uri?.scheme == 'http' || uri?.scheme == 'https';
  }

  factory VideoLesson.fromJson(String id, Map<String, dynamic> data) =>
      VideoLesson(
        id: id,
        itemId: data['itemId'] as String,
        title: data['title'] as String,
        module: data['module'] as String? ?? '',
        source: data['source'] as String,
        mediaVersion: data['mediaVersion'] as String,
        ordinal: data['ordinal'] as int,
        durationMs: data['durationMs'] as int?,
        available: data['available'] != false,
      );

  Map<String, dynamic> toJson() => {
    'version': 1,
    'itemId': itemId,
    'title': title,
    'module': module,
    'source': source,
    'mediaVersion': mediaVersion,
    'ordinal': ordinal,
    'durationMs': durationMs,
    'available': available,
  };
}

class VideoProgress {
  final String lessonId, mediaVersion;
  final int positionMs;
  final double speed;
  final DateTime updatedAt;
  const VideoProgress({
    required this.lessonId,
    required this.mediaVersion,
    required this.positionMs,
    required this.speed,
    required this.updatedAt,
  });

  factory VideoProgress.fromJson(Map<String, dynamic> data) => VideoProgress(
    lessonId: data['lessonId'] as String,
    mediaVersion: data['mediaVersion'] as String,
    positionMs: data['positionMs'] as int,
    speed: (data['speed'] as num).toDouble(),
    updatedAt: DateTime.parse(data['updatedAt'] as String),
  );

  Map<String, dynamic> toJson() => {
    'version': 1,
    'lessonId': lessonId,
    'mediaVersion': mediaVersion,
    'positionMs': positionMs,
    'speed': speed,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };
}

/// One continuous media range. The ID is retained while its checkpoint grows.
class VideoInterval {
  final String id, sessionId, lessonId, mediaVersion;
  final VideoActivityMode mode;
  final DateTime startedAt;
  final int offsetMinutes, startMs, endMs, wallMs;
  final double speed;
  const VideoInterval({
    required this.id,
    required this.sessionId,
    required this.lessonId,
    required this.mediaVersion,
    required this.mode,
    required this.startedAt,
    required this.offsetMinutes,
    required this.startMs,
    required this.endMs,
    required this.wallMs,
    required this.speed,
  });

  int get mediaMs => endMs - startMs;
  String get coverageKey => '$lessonId:$mediaVersion:${mode.name}';
  DateTime get endedAt => startedAt.add(Duration(milliseconds: wallMs));
  String get localDay =>
      videoDay(startedAt.toUtc().add(Duration(minutes: offsetMinutes)));

  factory VideoInterval.fromJson(String id, Map<String, dynamic> data) =>
      VideoInterval(
        id: id,
        sessionId: data['sessionId'] as String,
        lessonId: data['lessonId'] as String,
        mediaVersion: data['mediaVersion'] as String,
        mode: VideoActivityMode.values.byName(data['mode'] as String),
        startedAt: DateTime.parse(data['startedAt'] as String),
        offsetMinutes: data['offsetMinutes'] as int,
        startMs: data['startMs'] as int,
        endMs: data['endMs'] as int,
        wallMs: data['wallMs'] as int,
        speed: (data['speed'] as num).toDouble(),
      );

  Map<String, dynamic> toJson() => {
    'version': 1,
    'sessionId': sessionId,
    'lessonId': lessonId,
    'mediaVersion': mediaVersion,
    'mode': mode.name,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'startEpochMs': startedAt.millisecondsSinceEpoch,
    'endEpochMs': startedAt.millisecondsSinceEpoch + wallMs,
    'offsetMinutes': offsetMinutes,
    'startMs': startMs,
    'endMs': endMs,
    'wallMs': wallMs,
    'speed': speed,
  };
}

class VideoPreferences {
  final int dailyMinutes, weeklyMinutes, completionPercent;
  const VideoPreferences({
    this.dailyMinutes = 0,
    this.weeklyMinutes = 0,
    this.completionPercent = 95,
  });

  factory VideoPreferences.fromJson(
    Map<String, dynamic> data,
  ) => VideoPreferences(
    dailyMinutes: (data['dailyMinutes'] as num? ?? 0).toInt().clamp(0, 1440),
    weeklyMinutes: (data['weeklyMinutes'] as num? ?? 0).toInt().clamp(0, 10080),
    completionPercent: (data['completionPercent'] as num? ?? 95).toInt().clamp(
      1,
      100,
    ),
  );
  Map<String, dynamic> toJson() => {
    'version': 1,
    'dailyMinutes': dailyMinutes,
    'weeklyMinutes': weeklyMinutes,
    'completionPercent': completionPercent,
  };
}

/// Explicit user decisions and a historical coverage milestone. The current
/// automatic completion status is always derived from current coverage.
class VideoLearningState {
  final String lessonId, mediaVersion;
  final DateTime? manualCompletedAt, understoodAt, coverageCompletedAt;
  final int? coverageThreshold;
  const VideoLearningState({
    required this.lessonId,
    required this.mediaVersion,
    this.manualCompletedAt,
    this.understoodAt,
    this.coverageCompletedAt,
    this.coverageThreshold,
  });
  String get key => '$lessonId:$mediaVersion';

  factory VideoLearningState.fromJson(Map<String, dynamic> data) =>
      VideoLearningState(
        lessonId: data['lessonId'] as String,
        mediaVersion: data['mediaVersion'] as String,
        manualCompletedAt: DateTime.tryParse(
          data['manualCompletedAt'] as String? ?? '',
        ),
        understoodAt: DateTime.tryParse(data['understoodAt'] as String? ?? ''),
        coverageCompletedAt: DateTime.tryParse(
          data['coverageCompletedAt'] as String? ?? '',
        ),
        coverageThreshold: data['coverageThreshold'] as int?,
      );
  Map<String, dynamic> toJson() => {
    'version': 1,
    'lessonId': lessonId,
    'mediaVersion': mediaVersion,
    'manualCompletedAt': manualCompletedAt?.toUtc().toIso8601String(),
    'understoodAt': understoodAt?.toUtc().toIso8601String(),
    'coverageCompletedAt': coverageCompletedAt?.toUtc().toIso8601String(),
    'coverageThreshold': coverageThreshold,
  };
}

class VideoHistoryCursor {
  final int startEpochMs;
  final String id;
  const VideoHistoryCursor(this.startEpochMs, this.id);
}

class VideoHistoryPage {
  final List<VideoInterval> intervals;
  final VideoHistoryCursor? next;
  const VideoHistoryPage(this.intervals, this.next);
}

String videoDay(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
