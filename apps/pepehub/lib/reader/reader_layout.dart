import 'package:flutter/material.dart';

import 'epub.dart';

class ReaderPreferences {
  final double size, spacing, margin;
  final String font, palette, mode;
  final String leftTap, centerTap, rightTap;
  final double zoneWidth;
  const ReaderPreferences({
    this.size = 22,
    this.spacing = 1.35,
    this.margin = 24,
    this.font = 'serif',
    this.palette = 'sepia',
    this.mode = 'scroll',
    this.leftTap = 'previous',
    this.centerTap = 'controls',
    this.rightTap = 'next',
    this.zoneWidth = .25,
  });
  factory ReaderPreferences.fromJson(
    Map<String, dynamic> data,
  ) => ReaderPreferences(
    size: ((data['size'] as num?)?.toDouble() ?? 22).clamp(14, 36),
    spacing: ((data['spacing'] as num?)?.toDouble() ?? 1.35).clamp(1.2, 2.2),
    margin: ((data['margin'] as num?)?.toDouble() ?? 24).clamp(12, 48),
    font: data['font'] == 'sans' ? 'sans' : 'serif',
    palette:
        const ['light', 'dark', 'sepia', 'system'].contains(data['palette'])
        ? data['palette'] as String
        : 'sepia',
    mode: data['mode'] == 'pages' ? 'pages' : 'scroll',
    leftTap: _tap(data['leftTap'], 'previous'),
    centerTap: _tap(data['centerTap'], 'controls'),
    rightTap: _tap(data['rightTap'], 'next'),
    zoneWidth: ((data['zoneWidth'] as num?)?.toDouble() ?? .25).clamp(.15, .4),
  );
  ReaderPreferences copy({
    double? size,
    double? spacing,
    double? margin,
    String? font,
    String? palette,
    String? mode,
    String? leftTap,
    String? centerTap,
    String? rightTap,
    double? zoneWidth,
  }) => ReaderPreferences(
    size: size ?? this.size,
    spacing: spacing ?? this.spacing,
    margin: margin ?? this.margin,
    font: font ?? this.font,
    palette: palette ?? this.palette,
    mode: mode ?? this.mode,
    leftTap: leftTap ?? this.leftTap,
    centerTap: centerTap ?? this.centerTap,
    rightTap: rightTap ?? this.rightTap,
    zoneWidth: zoneWidth ?? this.zoneWidth,
  );
  Map<String, dynamic> toJson() => {
    'size': size,
    'spacing': spacing,
    'margin': margin,
    'font': font,
    'palette': palette,
    'mode': mode,
    'leftTap': leftTap,
    'centerTap': centerTap,
    'rightTap': rightTap,
    'zoneWidth': zoneWidth,
  };
  static String _tap(dynamic v, String fallback) =>
      const ['previous', 'next', 'controls', 'none'].contains(v)
      ? v as String
      : fallback;
  String tapAt(double fraction) => fraction < zoneWidth
      ? leftTap
      : fraction > 1 - zoneWidth
      ? rightTap
      : centerTap;
  TextStyle style(Color color) => TextStyle(
    inherit: false,
    fontSize: size,
    height: spacing,
    fontFamily: font == 'serif' ? 'ReaderLora' : null,
    color: color,
    letterSpacing: 0,
    wordSpacing: 0,
    fontWeight: FontWeight.w400,
    textBaseline: TextBaseline.alphabetic,
  );
}

class ReaderDocument {
  final EpubBook book;
  late final List<String> texts = book.chapters
      .map((c) => c.paragraphs.join('\n\n'))
      .toList();
  late final List<int> starts = _starts();
  late final int length = texts.fold(0, (sum, text) => sum + text.length);
  ReaderDocument(this.book);
  List<int> _starts() {
    var sum = 0;
    return [
      for (final text in texts)
        (() {
          final at = sum;
          sum += text.length;
          return at;
        })(),
    ];
  }

  int offset(int chapter, int paragraph, int within) {
    final paragraphs = book.chapters[chapter].paragraphs;
    paragraph = paragraph.clamp(0, paragraphs.length - 1);
    return paragraphs.take(paragraph).fold(0, (sum, p) => sum + p.length + 2) +
        within.clamp(0, paragraphs[paragraph].length);
  }

  ({int paragraph, int within}) paragraphAt(int chapter, int offset) {
    final paragraphs = book.chapters[chapter].paragraphs;
    var rest = offset.clamp(0, texts[chapter].length);
    for (var i = 0; i < paragraphs.length; i++) {
      if (rest <= paragraphs[i].length || i == paragraphs.length - 1) {
        return (paragraph: i, within: rest.clamp(0, paragraphs[i].length));
      }
      rest -= paragraphs[i].length + 2;
    }
    return (paragraph: 0, within: 0);
  }

  ({int chapter, int offset}) locate(double fraction) {
    final absolute = (fraction.clamp(0, 1) * length).round();
    for (var i = texts.length - 1; i >= 0; i--) {
      if (absolute >= starts[i]) {
        return (
          chapter: i,
          offset: (absolute - starts[i]).clamp(0, texts[i].length),
        );
      }
    }
    return (chapter: 0, offset: 0);
  }
}

class ReaderSlice {
  final int start, end;
  const ReaderSlice(this.start, this.end);
}

/// Page boundaries use original UTF-16 offsets, never page numbers as identity.
Future<List<ReaderSlice>> paginateReader(
  String text,
  TextStyle style,
  double width,
  double height,
  TextScaler scaler, {
  bool Function()? cancelled,
  TextSpan Function(int start, int end)? styledText,
}) async {
  final pages = <ReaderSlice>[];
  var start = 0;
  final painter = TextPainter(
    textDirection: TextDirection.ltr,
    textScaler: scaler,
  );
  try {
    while (start < text.length) {
      if (cancelled?.call() == true) return [];
      var end = (start + 6000).clamp(0, text.length);
      // Avoid splitting a surrogate pair at the measurement window boundary.
      if (end < text.length &&
          text.codeUnitAt(end) >= 0xDC00 &&
          text.codeUnitAt(end) <= 0xDFFF) {
        end--;
      }
      final chunk = text.substring(start, end);
      painter.text =
          styledText?.call(start, end) ?? TextSpan(text: chunk, style: style);
      painter.layout(maxWidth: width);
      if (painter.height > height) {
        final lines = painter
            .computeLineMetrics()
            .where((line) => line.baseline + line.descent <= height - 1)
            .toList();
        if (lines.isEmpty) {
          throw StateError('Увеличьте высоту окна или уменьшите шрифт.');
        }
        final last = lines.last;
        final position = painter.getPositionForOffset(
          Offset(last.left + last.width / 2, last.baseline - last.ascent / 2),
        );
        final boundary = painter.getLineBoundary(position);
        end = start + boundary.end;
        if (end < text.length && text.codeUnitAt(end) == 10) end++;
      } else if (end < text.length) {
        // Very wide windows: continue at a word boundary rather than inside it.
        final space = chunk.lastIndexOf(RegExp(r'\s'));
        if (space > chunk.length - 100) end = start + space + 1;
      }
      if (end <= start) {
        throw StateError('Не удалось разбить текст на страницы.');
      }
      // Line baselines omit some leading, especially with accessibility scaling
      // and fallback fonts. Verify the actual standalone page before committing.
      while (true) {
        painter.text =
            styledText?.call(
              start,
              start + text.substring(start, end).trimRight().length,
            ) ??
            TextSpan(
              text: text.substring(start, end).trimRight(),
              style: style,
            );
        painter.layout(maxWidth: width);
        if (painter.height <= height) break;
        final last = painter.computeLineMetrics().last;
        final position = painter.getPositionForOffset(
          Offset(last.left + last.width / 2, last.baseline - last.ascent / 2),
        );
        final shorter = start + painter.getLineBoundary(position).start;
        if (shorter <= start || shorter >= end) {
          throw StateError('Увеличьте высоту окна или уменьшите шрифт.');
        }
        end = shorter;
      }
      pages.add(ReaderSlice(start, end));
      start = end;
      if (pages.length % 8 == 0) await Future<void>.delayed(Duration.zero);
    }
    return pages.isEmpty ? [const ReaderSlice(0, 0)] : pages;
  } finally {
    painter.dispose();
  }
}

List<Map<String, dynamic>> searchReader(Map<String, dynamic> request) {
  final query = (request['query'] as String).trim();
  if (query.isEmpty) return [];
  final pattern = RegExp(
    RegExp.escape(query),
    caseSensitive: false,
    unicode: true,
  );
  final texts = (request['texts'] as List).cast<String>();
  final results = <Map<String, dynamic>>[];
  for (var c = 0; c < texts.length; c++) {
    for (final match in pattern.allMatches(texts[c])) {
      results.add({
        'chapter': c,
        'offset': match.start,
        'end': match.end,
        'excerpt': texts[c]
            .substring(
              (match.start - 45).clamp(0, texts[c].length),
              (match.end + 90).clamp(0, texts[c].length),
            )
            .replaceAll('\n', ' '),
      });
      if (results.length == 200) return results;
    }
  }
  return results;
}
