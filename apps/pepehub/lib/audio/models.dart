/// Stable content addresses: never serialize device paths into a locator.
class AudioLocator {
  final String bookId, editionId, trackId;
  final int positionMs, manifestRevision;

  AudioLocator({
    required this.bookId,
    required this.editionId,
    required this.trackId,
    required this.positionMs,
    required this.manifestRevision,
  }) {
    if ([bookId, editionId, trackId].any((id) => id.trim().isEmpty) ||
        positionMs < 0 ||
        manifestRevision < 1) {
      throw ArgumentError('Некорректный адрес аудиопозиции');
    }
  }

  Map<String, Object> toJson() => {
    'bookId': bookId,
    'editionId': editionId,
    'trackId': trackId,
    'positionMs': positionMs,
    'manifestRevision': manifestRevision,
  };
}

class AudioEdition {
  final String id, bookId;
  final int manifestRevision;
  AudioEdition({
    required this.id,
    required this.bookId,
    required this.manifestRevision,
  }) {
    if (id.isEmpty || bookId.isEmpty || manifestRevision < 1) {
      throw ArgumentError('Некорректное аудиоиздание');
    }
  }
}

class AudioTrack {
  final String id, editionId, assetHash, title;
  final int ordinal;
  final int? durationMs;
  AudioTrack({
    required this.id,
    required this.editionId,
    required this.assetHash,
    required this.title,
    required this.ordinal,
    this.durationMs,
  }) {
    if ([id, editionId, assetHash].any((id) => id.isEmpty) ||
        ordinal < 0 ||
        (durationMs != null && durationMs! < 0)) {
      throw ArgumentError('Некорректный аудиотрек');
    }
  }
}

class AudioChapter {
  final String id, trackId, title;
  final int startMs, endMs;
  AudioChapter({
    required this.id,
    required this.trackId,
    required this.title,
    required this.startMs,
    required this.endMs,
  }) {
    if (id.isEmpty || trackId.isEmpty || startMs < 0 || endMs <= startMs) {
      throw ArgumentError('Некорректные границы главы');
    }
  }
}

class AudioProgress {
  final AudioLocator locator;
  final double speed;
  AudioProgress(this.locator, this.speed) {
    if (!speed.isFinite || speed < 0.5 || speed > 3) {
      throw ArgumentError('Скорость от 0.5 до 3');
    }
  }
}
