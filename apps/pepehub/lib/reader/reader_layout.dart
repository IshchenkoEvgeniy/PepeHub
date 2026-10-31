import 'package:flutter/material.dart';

import 'epub.dart';
import 'reader_fonts.dart';

class ReaderPreferences {
  final double size, spacing, margin, pageHeightFactor, columnWidth;
  final String font, palette, mode;
  final bool showScrollbar, showHighlights;
  final String highlightColor;
  static const highlightColors = ['yellow', 'green', 'blue', 'pink'];
  final String leftTap, centerTap, rightTap;
  final double zoneWidth;
  const ReaderPreferences({
    this.size = 22,
    this.spacing = 1.35,
    this.margin = 24,
    this.pageHeightFactor = 1,
    this.columnWidth = 900,
    this.font = 'serif',
    this.palette = 'system',
    this.mode = 'seamless',
    this.showScrollbar = false,
    this.showHighlights = true,
    this.highlightColor = 'yellow',
    this.leftTap = 'previous',
    this.centerTap = 'controls',
    this.rightTap = 'next',
    this.zoneWidth = .25,
  });
  factory ReaderPreferences.fromJson(
    Map<String, dynamic> data,
  ) => ReaderPreferences(
    size: ((data['size'] as num?)?.toDouble() ?? 22).clamp(12, 56),
    spacing: ((data['spacing'] as num?)?.toDouble() ?? 1.35).clamp(1.2, 2.2),
    margin: ((data['margin'] as num?)?.toDouble() ?? 24).clamp(12, 48),
    pageHeightFactor: ((data['pageHeightFactor'] as num?)?.toDouble() ?? 1)
        .clamp(.65, 1.5),
    columnWidth: ((data['columnWidth'] as num?)?.toDouble() ?? 900).clamp(
      360,
      1200,
    ),
    font: readerFont(data['font']).id,
    palette:
        const ['light', 'dark', 'sepia', 'system'].contains(data['palette'])
        ? data['palette'] as String
        : 'system',
    mode:
        const ['pages', 'scroll', 'seamless', 'compact'].contains(data['mode'])
        ? data['mode'] as String
        : 'seamless',
    showScrollbar: data['showScrollbar'] == true,
    showHighlights: data['showHighlights'] != false,
    highlightColor: highlightColors.contains(data['highlightColor'])
        ? data['highlightColor'] as String
        : 'yellow',
    leftTap: _tap(data['leftTap'], 'previous'),
    centerTap: _tap(data['centerTap'], 'controls'),
    rightTap: _tap(data['rightTap'], 'next'),
    zoneWidth: ((data['zoneWidth'] as num?)?.toDouble() ?? .25).clamp(.15, .4),
  );
  ReaderPreferences copy({
    double? size,
    double? spacing,
    double? margin,
    double? pageHeightFactor,
    double? columnWidth,
    String? font,
    String? palette,
    String? mode,
    bool? showScrollbar,
    bool? showHighlights,
    String? highlightColor,
    String? leftTap,
    String? centerTap,
    String? rightTap,
    double? zoneWidth,
  }) => ReaderPreferences(
    size: size ?? this.size,
    spacing: spacing ?? this.spacing,
    margin: margin ?? this.margin,
    pageHeightFactor: pageHeightFactor ?? this.pageHeightFactor,
    columnWidth: columnWidth ?? this.columnWidth,
    font: font ?? this.font,
    palette: palette ?? this.palette,
    mode: mode ?? this.mode,
    showScrollbar: showScrollbar ?? this.showScrollbar,
    showHighlights: showHighlights ?? this.showHighlights,
    highlightColor: highlightColor ?? this.highlightColor,
    leftTap: leftTap ?? this.leftTap,
    centerTap: centerTap ?? this.centerTap,
    rightTap: rightTap ?? this.rightTap,
    zoneWidth: zoneWidth ?? this.zoneWidth,
  );
  Map<String, dynamic> toJson() => {
    'size': size,
    'spacing': spacing,
    'margin': margin,
    'pageHeightFactor': pageHeightFactor,
    'columnWidth': columnWidth,
    'font': font,
    'palette': palette,
    'mode': mode,
    'showScrollbar': showScrollbar,
    'showHighlights': showHighlights,
    'highlightColor': highlightColor,
    'leftTap': leftTap,
    'centerTap': centerTap,
    'rightTap': rightTap,
    'zoneWidth': zoneWidth,
  };
  static String _tap(dynamic v, String fallback) =>
      const ['previous', 'next', 'controls', 'none'].contains(v)
      ? v as String
      : fallback;
  bool isDark(Brightness systemBrightness) =>
      palette == 'dark' ||
      palette == 'system' && systemBrightness == Brightness.dark;
  String tapAt(double fraction) => fraction < zoneWidth
      ? leftTap
      : fraction > 1 - zoneWidth
      ? rightTap
      : centerTap;
  TextStyle style(Color color) => TextStyle(
    inherit: false,
    fontSize: size,
    height: spacing,
    fontFamily: readerFont(font).family,
    color: color,
    letterSpacing: 0,
    wordSpacing: 0,
    fontWeight: FontWeight.w400,
    textBaseline: TextBaseline.alphabetic,
  );
}

class ReaderDocument {
  final EpubBook book;
  late final List<String> texts = book.chapters.map((c) => c.text).toList();
  late final List<int> starts = _starts();
  late final int length = texts.fold(0, (sum, text) => sum + text.length);
  late final _paragraphIndexes = List<List<int>?>.filled(
    book.chapters.length,
    null,
  );
  ReaderDocument(this.book);
  List<int> _paragraphStarts(int chapter) =>
      _paragraphIndexes[chapter] ??= (() {
        var start = 0;
        return [
          for (final paragraph in book.chapters[chapter].paragraphs)
            (() {
              final value = start;
              start +=
                  paragraph.length +
                  book.chapters[chapter].paragraphSeparator.length;
              return value;
            })(),
        ];
      })();
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
    if (paragraphs.isEmpty) return 0;
    paragraph = paragraph.clamp(0, paragraphs.length - 1);
    return _paragraphStarts(chapter)[paragraph] +
        within.clamp(0, paragraphs[paragraph].length);
  }

  ({int paragraph, int within}) paragraphAt(int chapter, int offset) {
    final paragraphs = book.chapters[chapter].paragraphs;
    if (paragraphs.isEmpty) return (paragraph: 0, within: 0);
    final at = offset.clamp(0, texts[chapter].length);
    final starts = _paragraphStarts(chapter);
    var low = 0, high = paragraphs.length - 1;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (starts[middle] + paragraphs[middle].length < at) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return (
      paragraph: low,
      within: (at - starts[low]).clamp(0, paragraphs[low].length),
    );
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
  final double? height;
  final List<ReaderSlice>? segments;
  const ReaderSlice(this.start, this.end, {this.height, this.segments});
}

/// A bounded lead-in restores the original UTF-16 anchor without laying out
/// every preceding chapter. The viewport can request an earlier window later.
int readerWindowStart(String text, int anchor) {
  if (anchor < 24000) return 0;
  final target = (anchor - 12000).clamp(0, text.length);
  final paragraph = text.lastIndexOf('\n\n', target);
  if (paragraph >= target - 6000) return paragraph < 0 ? 0 : paragraph + 2;
  final line = text.lastIndexOf('\n', target);
  if (line >= target - 6000) return line < 0 ? 0 : line + 1;
  final word = text.lastIndexOf(' ', target);
  // Preserve a word (and its Unicode sequence) rather than slicing a glyph.
  return word >= target - 256 ? word + 1 : 0;
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
  double? firstPageHeight,
  double Function(int start)? widthAt,
}) async {
  final pages = <ReaderSlice>[];
  var start = 0;
  final painter = TextPainter(
    textDirection: TextDirection.ltr,
    textScaler: scaler,
    strutStyle: StrutStyle.fromTextStyle(style),
  );
  try {
    while (start < text.length) {
      if (cancelled?.call() == true) return [];
      var availableHeight = pages.isEmpty
          ? (firstPageHeight ?? height)
          : height;
      final availableWidth = widthAt?.call(start) ?? width;
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
      painter.layout(maxWidth: availableWidth);
      if (painter.height > availableHeight) {
        var lines = painter
            .computeLineMetrics()
            .where(
              (line) => line.baseline + line.descent <= availableHeight - 1,
            )
            .toList();
        if (lines.isEmpty && availableHeight < height) {
          // A heading or a tall glyph cannot fit in the remaining space.
          // Move it intact to the next screen.
          availableHeight = height;
          lines = painter
              .computeLineMetrics()
              .where((line) => line.baseline + line.descent <= height - 1)
              .toList();
        }
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
        painter.layout(maxWidth: availableWidth);
        if (painter.height <= availableHeight) break;
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
      pages.add(ReaderSlice(start, end, height: painter.height));
      start = end;
      if (pages.length % 8 == 0) await Future<void>.delayed(Duration.zero);
    }
    return pages.isEmpty ? [const ReaderSlice(0, 0)] : pages;
  } finally {
    painter.dispose();
  }
}

/// Search the original source so match offsets remain valid for highlights,
/// notes and PDF glyphs, even when query whitespace differs from the book.
RegExp readerSearchPattern(String query) => RegExp(
  query
      .trim()
      .split(RegExp(r'\s+'))
      .map((word) => RegExp.escape(word).replaceAll(RegExp('[еёЕЁ]'), '[её]'))
      .join(r'\s+'),
  caseSensitive: false,
  unicode: true,
);

String readerExcerpt(
  String text,
  int start,
  int end, {
  int before = 45,
  int after = 90,
}) {
  var left = (start - before).clamp(0, text.length);
  var right = (end + after).clamp(0, text.length);
  bool lowSurrogate(int at) =>
      at < text.length &&
      text.codeUnitAt(at) >= 0xDC00 &&
      text.codeUnitAt(at) <= 0xDFFF;
  if (left > 0 && lowSurrogate(left)) left--;
  if (right > 0 && lowSurrogate(right)) right++;
  return text.substring(left, right).replaceAll(RegExp(r'\s+'), ' ');
}

List<Map<String, dynamic>> searchReader(Map<String, dynamic> request) {
  final query = (request['query'] as String).trim();
  if (query.isEmpty) return [];
  final pattern = readerSearchPattern(query);
  final texts = (request['texts'] as List).cast<String>();
  final scope = request['scopeChapter'] as int?;
  final afterChapter = request['afterChapter'] as int? ?? -1;
  final afterOffset = request['afterOffset'] as int? ?? 0;
  final limit = ((request['limit'] as int?) ?? 200).clamp(1, 2001);
  final results = <Map<String, dynamic>>[];
  for (var c = 0; c < texts.length; c++) {
    if (scope != null && c != scope || c < afterChapter) continue;
    final start = c == afterChapter ? afterOffset.clamp(0, texts[c].length) : 0;
    for (final match in pattern.allMatches(texts[c], start)) {
      results.add({
        'chapter': c,
        'offset': match.start,
        'end': match.end,
        'excerpt': readerExcerpt(texts[c], match.start, match.end),
      });
      if (results.length == limit) return results;
    }
  }
  return results;
}
