/// Shared precision for navigation, notes and repeat ranges.
String videoTimestamp(int milliseconds, {bool precise = false}) {
  final ms = milliseconds.clamp(0, 1 << 53);
  final seconds = ms ~/ 1000, minutes = seconds ~/ 60, hours = minutes ~/ 60;
  final base = hours > 0
      ? '$hours:${(minutes % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}'
      : '$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
  return precise ? '$base.${(ms % 1000).toString().padLeft(3, '0')}' : base;
}

/// Seconds, mm:ss or hh:mm:ss, with optional millisecond precision.
int? parseVideoTimestamp(String text) {
  final parts = text.trim().replaceAll(',', '.').split(':');
  if (parts.isEmpty || parts.length > 3) return null;
  if (!RegExp(r'^\d{1,9}(\.\d{1,3})?$').hasMatch(parts.last)) return null;
  if (parts
      .take(parts.length - 1)
      .any((p) => !RegExp(r'^\d{1,9}$').hasMatch(p))) {
    return null;
  }
  final seconds = double.parse(parts.last);
  if (parts.length > 1 && seconds >= 60) return null;
  final whole = parts.take(parts.length - 1).map(int.parse).toList();
  if (parts.length == 3 && whole[1] >= 60) return null;
  final total =
      seconds +
      (whole.isEmpty ? 0 : whole.last * 60) +
      (parts.length == 3 ? whole.first * 3600 : 0);
  final ms = (total * 1000).round();
  return ms <= 1 << 53 ? ms : null;
}

class VideoLoopSettings {
  final int startMs, endMs, pauseMs;

  /// Total passes, including the first. Null means continue until stopped.
  final int? totalPasses;
  const VideoLoopSettings({
    required this.startMs,
    required this.endMs,
    this.totalPasses,
    this.pauseMs = 0,
  });

  void validate({int? durationMs}) {
    if (startMs < 0 ||
        endMs - startMs < 500 ||
        (durationMs != null && durationMs > 0 && endMs > durationMs) ||
        (totalPasses != null && (totalPasses! < 1 || totalPasses! > 100)) ||
        pauseMs < 0 ||
        pauseMs > 30000) {
      throw ArgumentError(
        'Фрагмент от 0,5 секунды в пределах видео; 1–100 проходов или без ограничения; пауза до 30 секунд',
      );
    }
  }
}

class VideoSeekEntry {
  final int fromMs, toMs;
  const VideoSeekEntry(this.fromMs, this.toMs);
}
