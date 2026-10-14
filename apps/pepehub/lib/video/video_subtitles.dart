import 'dart:convert';

import 'package:enough_convert/enough_convert.dart';
import 'package:html/parser.dart' as html;

const maxVideoSubtitleBytes = 8 * 1024 * 1024;
const maxVideoSubtitleCues = 50000;

enum VideoSubtitleFormat { srt, vtt, ass }

enum VideoSubtitleEncoding {
  automatic,
  utf8,
  utf16le,
  utf16be,
  windows1251,
  windows1252,
}

String decodeVideoSubtitles(
  List<int> bytes, {
  VideoSubtitleEncoding encoding = VideoSubtitleEncoding.automatic,
}) {
  if (bytes.length > maxVideoSubtitleBytes) {
    throw const FormatException('Субтитры больше 8 МиБ');
  }
  final bom16 =
      bytes.length >= 2 &&
      ((bytes[0] == 255 && bytes[1] == 254) ||
          (bytes[0] == 254 && bytes[1] == 255));
  if (encoding == VideoSubtitleEncoding.automatic) {
    encoding = bom16
        ? (bytes[0] == 255
              ? VideoSubtitleEncoding.utf16le
              : VideoSubtitleEncoding.utf16be)
        : VideoSubtitleEncoding.utf8;
  }
  if (encoding == VideoSubtitleEncoding.windows1251) {
    return const Windows1251Codec().decode(bytes);
  }
  if (encoding == VideoSubtitleEncoding.windows1252) {
    return const Windows1252Codec().decode(bytes);
  }
  if (encoding == VideoSubtitleEncoding.utf8) {
    try {
      return utf8.decode(bytes).replaceFirst(RegExp(r'^\uFEFF'), '');
    } catch (_) {
      throw const FormatException(
        'Не удалось прочитать UTF-8. Выберите кодировку Windows-1251 / Windows-1252',
      );
    }
  }
  final begin = bom16 ? 2 : 0;
  if ((bytes.length - begin).isOdd) {
    throw const FormatException('Неполная строка UTF-16');
  }
  final units = <int>[];
  for (var i = begin; i < bytes.length; i += 2) {
    units.add(
      encoding == VideoSubtitleEncoding.utf16le
          ? bytes[i] | (bytes[i + 1] << 8)
          : (bytes[i] << 8) | bytes[i + 1],
    );
  }
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i >= units.length || units[i] < 0xdc00 || units[i] > 0xdfff) {
        throw const FormatException('Некорректный UTF-16');
      }
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      throw const FormatException('Некорректный UTF-16');
    }
  }
  return String.fromCharCodes(units);
}

class VideoSubtitleCue {
  final String id, text;
  final int startMs, endMs;
  const VideoSubtitleCue(this.id, this.startMs, this.endMs, this.text);
}

class VideoSubtitleDocument {
  final VideoSubtitleFormat format;
  final List<VideoSubtitleCue> cues;
  late final List<int> _maxEnd = List.filled(cues.length * 4 + 4, 0)..[0] = 0;
  VideoSubtitleDocument(this.format, List<VideoSubtitleCue> cues)
    : cues = List.unmodifiable(cues) {
    if (cues.isNotEmpty) _build(1, 0, cues.length - 1);
  }
  void _build(int node, int left, int right) {
    if (left == right) {
      _maxEnd[node] = cues[left].endMs;
      return;
    }
    final middle = (left + right) ~/ 2;
    _build(node * 2, left, middle);
    _build(node * 2 + 1, middle + 1, right);
    final a = _maxEnd[node * 2], b = _maxEnd[node * 2 + 1];
    _maxEnd[node] = a > b ? a : b;
  }

  /// Interval tree avoids scanning a whole transcript for an overlapping long cue.
  List<VideoSubtitleCue> activeAt(int positionMs, {int limit = 16}) {
    final result = <VideoSubtitleCue>[];
    if (cues.isEmpty || limit <= 0) return result;
    void visit(int node, int left, int right) {
      if (result.length >= limit ||
          cues[left].startMs > positionMs ||
          _maxEnd[node] <= positionMs) {
        return;
      }
      if (left == right) {
        result.add(cues[left]);
        return;
      }
      final middle = (left + right) ~/ 2;
      visit(node * 2, left, middle);
      visit(node * 2 + 1, middle + 1, right);
    }

    visit(1, 0, cues.length - 1);
    return result;
  }

  int nextIndex(int positionMs) {
    var low = 0, high = cues.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (cues[mid].startMs <= positionMs) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }
}

class VideoSubtitleParseRequest {
  final String text;
  final VideoSubtitleFormat format;
  const VideoSubtitleParseRequest(this.text, this.format);
}

VideoSubtitleDocument parseVideoSubtitles(VideoSubtitleParseRequest request) {
  final text = request.text
      .replaceFirst(RegExp(r'^\uFEFF'), '')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');
  if (utf8.encode(text).length > maxVideoSubtitleBytes) {
    throw const FormatException('Субтитры больше 8 МиБ');
  }
  if (text.contains('\u0000')) {
    throw const FormatException('Некорректный текст субтитров');
  }
  if (request.format == VideoSubtitleFormat.ass) {
    if (!RegExp(
      r'^\[Events\]',
      multiLine: true,
      caseSensitive: false,
    ).hasMatch(text)) {
      throw const FormatException('В ASS отсутствует раздел Events');
    }
    return VideoSubtitleDocument(request.format, []);
  }
  if (request.format == VideoSubtitleFormat.vtt &&
      !RegExp(r'^WEBVTT(?:[ \t].*)?\n').hasMatch(text)) {
    throw const FormatException('В WebVTT отсутствует заголовок WEBVTT');
  }
  final cues = <VideoSubtitleCue>[];
  final timing = RegExp(
    r'^((?:\d{2,8}:)?\d{2}:\d{2}[.,]\d{3})[ \t]+-->[ \t]+((?:\d{2,8}:)?\d{2}:\d{2}[.,]\d{3})(?:[ \t].*)?$',
  );
  int clock(String value) {
    final parts = value.replaceAll(',', '.').split(':');
    final seconds = double.parse(parts.last),
        minutes = int.parse(parts[parts.length - 2]);
    if (seconds >= 60 || minutes >= 60) {
      throw const FormatException('Некорректное время субтитров');
    }
    return ((seconds +
                minutes * 60 +
                (parts.length == 3 ? int.parse(parts.first) * 3600 : 0)) *
            1000)
        .round();
  }

  var ordinal = 0;
  for (final block in text.split(RegExp(r'\n[ \t]*\n'))) {
    final lines = block.trim().split('\n');
    if (lines.first.isEmpty) continue;
    if (request.format == VideoSubtitleFormat.vtt &&
        RegExp(r'^(WEBVTT(?:\s|$)|NOTE(?:\s|$)|STYLE$|REGION$)')
            .hasMatch(lines.first)) {
      continue;
    }
    final index = lines.indexWhere((line) => line.contains('-->'));
    if (index < 0) {
      throw const FormatException('Блок субтитров без временного диапазона');
    }
    final match = timing.firstMatch(lines[index].trim());
    if (match == null) {
      throw FormatException('Некорректное время в блоке ${ordinal + 1}');
    }
    final start = clock(match[1]!), end = clock(match[2]!);
    if (end <= start) {
      throw const FormatException('Конец реплики должен быть позже начала');
    }
    final payload = lines.skip(index + 1).join('\n');
    if (payload.length > 20000) {
      throw const FormatException('Реплика больше 20000 знаков');
    }
    final fragment = html.parseFragment(
      payload.replaceAll(RegExp(r'<\d{2}:[^>]+>'), ''),
    );
    for (final element in fragment.querySelectorAll('script,style')) {
      element.remove();
    }
    final clean = (fragment.text ?? '').trim();
    if (clean.isNotEmpty) {
      cues.add(
        VideoSubtitleCue(
          'cue:${(ordinal++).toString().padLeft(5, '0')}',
          start,
          end,
          clean,
        ),
      );
    }
    if (cues.length > maxVideoSubtitleCues) {
      throw const FormatException('Больше 50000 реплик в одном файле');
    }
  }
  if (cues.isEmpty) throw const FormatException('В файле нет текстовых реплик');
  cues.sort((a, b) {
    final comparison = a.startMs.compareTo(b.startMs);
    return comparison != 0 ? comparison : a.id.compareTo(b.id);
  });
  return VideoSubtitleDocument(request.format, cues);
}

class VideoSubtitleRecord {
  final String id, lessonId, mediaVersion, name, text;
  final VideoSubtitleFormat format;
  final int revision;
  const VideoSubtitleRecord({
    required this.id,
    required this.lessonId,
    required this.mediaVersion,
    required this.name,
    required this.text,
    required this.format,
    required this.revision,
  });
  factory VideoSubtitleRecord.fromJson(
    String id,
    int revision,
    Map<String, dynamic> data,
  ) => VideoSubtitleRecord(
    id: id,
    revision: revision,
    lessonId: data['lessonId'] as String,
    mediaVersion: data['mediaVersion'] as String,
    name: data['name'] as String,
    text: data['text'] as String,
    format: VideoSubtitleFormat.values.byName(data['format'] as String),
  );
}

class VideoPlaybackSettings {
  final String audio, subtitle;
  final String? translation;
  final int subtitleDelayMs, translationDelayMs, audioDelayMs, fontSize;
  final bool translationVisible, subtitleBackground;
  const VideoPlaybackSettings({
    this.audio = 'auto',
    this.subtitle = 'auto',
    this.translation,
    this.subtitleDelayMs = 0,
    this.translationDelayMs = 0,
    this.audioDelayMs = 0,
    this.fontSize = 22,
    this.translationVisible = true,
    this.subtitleBackground = true,
  });
  factory VideoPlaybackSettings.fromJson(Map<String, dynamic> data) =>
      VideoPlaybackSettings(
        audio: data['audio'] as String? ?? 'auto',
        subtitle: data['subtitle'] as String? ?? 'auto',
        translation: data['translation'] as String?,
        subtitleDelayMs: (data['subtitleDelayMs'] as int? ?? 0).clamp(
          -60000,
          60000,
        ),
        translationDelayMs: (data['translationDelayMs'] as int? ?? 0).clamp(
          -60000,
          60000,
        ),
        audioDelayMs: (data['audioDelayMs'] as int? ?? 0).clamp(-10000, 10000),
        fontSize: (data['fontSize'] as int? ?? 22).clamp(14, 40),
        translationVisible: data['translationVisible'] != false,
        subtitleBackground: data['subtitleBackground'] != false,
      );
  Map<String, dynamic> toJson() => {
    'version': 1,
    'audio': audio,
    'subtitle': subtitle,
    'translation': translation,
    'subtitleDelayMs': subtitleDelayMs,
    'translationDelayMs': translationDelayMs,
    'audioDelayMs': audioDelayMs,
    'fontSize': fontSize,
    'translationVisible': translationVisible,
    'subtitleBackground': subtitleBackground,
  };
}
