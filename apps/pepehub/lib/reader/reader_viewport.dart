import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

import 'reader_layout.dart';
import 'reading_library.dart';
import 'reading_notes_page.dart';
import 'epub.dart';

class ReaderViewport extends StatefulWidget {
  final String text;
  final TextStyle style;
  final TextScaler scaler;
  final double width, height, margin, pageHeightFactor;
  final int anchor;
  final int? highlightStart, highlightEnd;
  final bool scrolling, compactFlow, firstChapter, lastChapter;
  final ValueChanged<int> onPosition, onChapter;
  final List<ReadingNote> notes;
  final void Function(int start, int end, bool comment)? onAnnotate;
  final VoidCallback? onLoading, onReady;
  final ReaderPreferences? preferences;
  final VoidCallback? onToggleControls;
  final void Function(int offset, bool end)? onBoundary;
  final bool selectingRange, hideControls;
  final List<BookFootnote> footnotes;
  final ValueChanged<BookFootnote>? onFootnote;
  final List<BookMarkup> markup;
  final List<BookIllustration> illustrations;
  final List<int> chapterBreaks;
  final bool showScrollbar;
  final ValueChanged<String>? onLink;
  const ReaderViewport({
    super.key,
    required this.text,
    required this.style,
    required this.scaler,
    required this.width,
    required this.height,
    required this.margin,
    this.pageHeightFactor = 1,
    required this.anchor,
    this.highlightStart,
    this.highlightEnd,
    required this.scrolling,
    this.compactFlow = false,
    required this.firstChapter,
    required this.lastChapter,
    required this.onPosition,
    required this.onChapter,
    this.notes = const [],
    this.onAnnotate,
    this.onLoading,
    this.onReady,
    this.preferences,
    this.onToggleControls,
    this.onBoundary,
    this.selectingRange = false,
    this.hideControls = false,
    this.footnotes = const [],
    this.onFootnote,
    this.markup = const [],
    this.illustrations = const [],
    this.chapterBreaks = const [],
    this.showScrollbar = false,
    this.onLink,
  });
  @override
  State<ReaderViewport> createState() => _ReaderViewportState();
}

class _ReaderViewportState extends State<ReaderViewport> {
  List<ReaderSlice>? pages;
  PageController? pager;
  ScrollController? scroll;
  int index = 0;
  String? error;
  bool interacted = false;
  Offset? down;
  DateTime? downAt;
  bool hasSelection = false;
  final recognizers = <BookFootnote, TapGestureRecognizer>{};
  final linkRecognizers = <String, TapGestureRecognizer>{};
  final images = <ReaderSlice, BookIllustration>{};
  bool crossingChapter = false;
  double? draggingPage;
  DateTime lastPositionUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? positionUpdateTimer;
  final starts = <double>[], heights = <double>[];
  final chapterSeparators = <bool>[];
  late List<BookMarkup> markupByStart;
  late List<int> markupPrefixMaxEnd;
  double contentHeight = 0;
  bool layoutComplete = false;
  Completer<void>? morePagesRequested;
  bool get progressiveLayout => widget.text.length > 40000;
  String _text(ReaderSlice page) {
    final text = widget.text.substring(page.start, page.end);
    return text.trimRight();
  }

  // The scroll viewport and a reading page can have different heights.
  double get viewportExtent =>
      widget.height -
      (widget.scrolling && !widget.compactFlow ||
              !widget.scrolling && !widget.hideControls
          ? 48
          : 0);
  double get extent => widget.scrolling && !widget.compactFlow
      ? viewportExtent * widget.pageHeightFactor
      : viewportExtent;
  double get textHeight =>
      viewportExtent * (widget.scrolling ? widget.pageHeightFactor : 1) - 32;
  double get textWidth => widget.width - widget.margin * 2;
  double _measuredTextWidth(int at) {
    final block = _blockAt(at)?.block;
    final borderAndMargin = block == 'pre'
        ? 8.0
        : const {'aside', 'blockquote'}.contains(block)
        ? 9.0
        : 0.0;
    return (textWidth - _indent(at) - borderAndMargin)
        .clamp(1.0, double.infinity)
        .toDouble();
  }

  double get illustrationHeight => (extent * .85).clamp(
    0,
    (extent - widget.margin * 2 - (widget.scrolling ? 14 : 24)).clamp(
      0,
      double.infinity,
    ),
  );
  BookMarkup? _blockAt(int at) {
    final ranges = _markupOverlapping(at, at + 1);
    return ranges.where((r) => r.heading > 0).firstOrNull ??
        ranges.where((r) => r.block != null).firstOrNull;
  }

  double _indent(int at) {
    if (!widget.scrolling) return 0;
    final block = _blockAt(at);
    if (block?.block == 'li') return 28.0 * (block!.depth.clamp(1, 3));
    if (const {'blockquote', 'dd', 'aside'}.contains(block?.block)) return 18;
    return 0;
  }

  TextAlign _alignment(int at) {
    if (!widget.scrolling) return TextAlign.left;
    final align = _markupOverlapping(at, at + 1)
        .where((r) => r.start <= at && r.end > at && r.align != null)
        .firstOrNull
        ?.align;
    if (align != null) {
      return switch (align) {
        'center' => TextAlign.center,
        'right' => TextAlign.right,
        // Full justification creates distracting gaps on narrow phone screens.
        'justify' => TextAlign.left,
        _ => TextAlign.left,
      };
    }
    return (_blockAt(at)?.heading ?? 0) > 0
        ? TextAlign.center
        : _blockAt(at)?.code == true
        ? TextAlign.left
        : TextAlign.left;
  }

  @override
  void initState() {
    super.initState();
    _indexMarkup();
    widget.onLoading?.call();
    _layout();
  }

  @override
  void didUpdateWidget(covariant ReaderViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.markup, widget.markup)) _indexMarkup();
  }

  void _indexMarkup() {
    final ordered = widget.markup.asMap().entries.toList()
      ..sort((a, b) {
        final byStart = a.value.start.compareTo(b.value.start);
        return byStart != 0 ? byStart : a.key.compareTo(b.key);
      });
    markupByStart = [for (final entry in ordered) entry.value];
    var maxEnd = -1;
    final prefixMaxEnd = <int>[];
    for (final item in markupByStart) {
      if (item.end > maxEnd) maxEnd = item.end;
      prefixMaxEnd.add(maxEnd);
    }
    markupPrefixMaxEnd = prefixMaxEnd;
  }

  Iterable<BookMarkup> _markupOverlapping(int start, int end) sync* {
    var low = 0, high = markupPrefixMaxEnd.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (markupPrefixMaxEnd[middle] > start) {
        high = middle;
      } else {
        low = middle + 1;
      }
    }
    for (var i = low; i < markupByStart.length; i++) {
      final range = markupByStart[i];
      if (range.start >= end) break;
      if (range.end > start) yield range;
    }
  }

  @override
  void dispose() {
    for (final r in recognizers.values) {
      r.dispose();
    }
    for (final r in linkRecognizers.values) {
      r.dispose();
    }
    pager?.dispose();
    scroll?.dispose();
    positionUpdateTimer?.cancel();
    final pending = morePagesRequested;
    morePagesRequested = null;
    if (pending != null && !pending.isCompleted) pending.complete();
    super.dispose();
  }

  TextStyle _styleAt(int offset, [Iterable<BookMarkup>? matching]) {
    var style = widget.style;
    for (final range in matching ?? _markupOverlapping(offset, offset + 1)) {
      if (range.start > offset || range.end <= offset) continue;
      if (range.heading > 0) {
        style = style.copyWith(
          fontSize:
              (widget.style.fontSize ?? 22) * (range.heading == 1 ? 1.4 : 1.2),
          fontWeight: FontWeight.w700,
          height: 1.25,
        );
      }
      if (range.bold) style = style.copyWith(fontWeight: FontWeight.w700);
      if (range.italic) style = style.copyWith(fontStyle: FontStyle.italic);
      if (range.code) {
        style = style.copyWith(
          fontFamily: 'monospace',
          fontSize: (widget.style.fontSize ?? 22) * .88,
        );
      }
      if (range.href != null) {
        style = style.copyWith(
          color: (widget.style.color?.computeLuminance() ?? 0) > .5
              ? const Color(0xff8acbea)
              : const Color(0xff17658a),
          decoration: TextDecoration.underline,
        );
      }
    }
    return style;
  }

  BookFootnote? _footnoteAt(int offset) => widget.footnotes
      .where((note) => note.start <= offset && note.end > offset)
      .firstOrNull;

  String _noteMarker(String text) => text.replaceAllMapped(
    RegExp(r'[0-9]'),
    (match) => '⁰¹²³⁴⁵⁶⁷⁸⁹'[int.parse(match.group(0)!)],
  );

  TextStyle _noteMarkerStyle(TextStyle base) => base.copyWith(
    fontSize: (base.fontSize ?? widget.style.fontSize ?? 22) * .68,
    height: 1,
  );

  TextSpan _richText(int start, int end) {
    final matching = _markupOverlapping(start, end).toList();
    final points = <int>{
      start,
      end,
      for (final r in matching) ...[
        r.start.clamp(start, end),
        r.end.clamp(start, end),
      ],
      for (final note in widget.footnotes) ...[
        note.start.clamp(start, end),
        note.end.clamp(start, end),
      ],
    }.toList()..sort();
    return TextSpan(
      style: widget.style,
      children: [
        for (var i = 0; i < points.length - 1; i++)
          TextSpan(
            text: _footnoteAt(points[i]) == null
                ? widget.text.substring(points[i], points[i + 1])
                : _noteMarker(widget.text.substring(points[i], points[i + 1])),
            style: _footnoteAt(points[i]) == null
                ? _styleAt(points[i], matching)
                : _noteMarkerStyle(_styleAt(points[i], matching)),
          ),
      ],
    );
  }

  TextPainter _painter(String text, {int start = 0}) => TextPainter(
    text: _richText(start, start + text.length),
    textDirection: TextDirection.ltr,
    textScaler: widget.scaler,
    textAlign: _alignment(start),
    strutStyle: StrutStyle.fromTextStyle(widget.style),
  )..layout(maxWidth: _measuredTextWidth(start));

  double _segmentExtent(ReaderSlice segment) {
    if (images.containsKey(segment)) {
      return illustrationHeight + widget.margin * 2;
    }
    final block = _blockAt(segment.start)?.block;
    final blockMargin = const {'aside', 'blockquote', 'pre'}.contains(block)
        ? 8.0
        : 0.0;
    return (segment.height ?? 0) + (widget.scrolling ? 10 : 24) + blockMargin;
  }

  void _requestMorePages() {
    final pending = morePagesRequested;
    morePagesRequested = null;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  void _publishLayout(List<ReaderSlice> result) {
    if (!mounted || result.isEmpty) return;
    final chapterEnds = widget.chapterBreaks
        .where((at) => at >= 2)
        .map((at) => at - 2)
        .toSet();
    for (var i = starts.length; i < result.length; i++) {
      starts.add(contentHeight);
      final divider = chapterEnds.contains(result[i].end);
      chapterSeparators.add(divider);
      final height = widget.scrolling
          ? widget.compactFlow
                ? _segmentExtent(result[i]) + 4 + (divider ? 1 : 0)
                : extent
          : extent;
      heights.add(height);
      contentHeight += height;
    }
    if (pages != null) {
      setState(() => pages = List.unmodifiable(result));
      return;
    }
    final imageAtAnchor = result.indexWhere(
      (page) => images.containsKey(page) && page.start == widget.anchor,
    );
    index =
        (imageAtAnchor >= 0
                ? imageAtAnchor
                : result.lastIndexWhere((p) => p.start <= widget.anchor))
            .clamp(0, result.length - 1);
    if (widget.anchor == 0) index = 0;
    pager = PageController(initialPage: index);
    var pixels = starts[index];
    if (widget.scrolling) {
      final page = result[index];
      var withinPage = 0.0;
      for (final segment in page.segments ?? [page]) {
        if (images.containsKey(segment)) {
          if (widget.anchor <= segment.start) break;
          withinPage += _segmentExtent(segment);
          continue;
        }
        final text = _text(segment);
        if (widget.anchor <= segment.end) {
          final painter = _painter(text, start: segment.start);
          withinPage +=
              5 +
              painter
                  .getOffsetForCaret(
                    TextPosition(
                      offset: (widget.anchor - segment.start).clamp(
                        0,
                        text.length,
                      ),
                    ),
                    Rect.zero,
                  )
                  .dy;
          painter.dispose();
          break;
        }
        withinPage += _segmentExtent(segment);
      }
      pixels += withinPage;
    }
    scroll = ScrollController(
      initialScrollOffset: pixels.clamp(
        0,
        (contentHeight - viewportExtent).clamp(0, double.infinity),
      ),
    );
    setState(() => pages = List.unmodifiable(result));
    widget.onReady?.call();
  }

  Future<void> _layout() async {
    try {
      final result = <ReaderSlice>[];
      final orderedImages = [...widget.illustrations]
        ..sort((a, b) => a.offset.compareTo(b.offset));
      final currentPage = <ReaderSlice>[];
      var usedPageHeight = 0.0;
      void finishPage() {
        if (currentPage.isEmpty) return;
        result.add(
          ReaderSlice(
            currentPage.first.start,
            currentPage.last.end,
            height: extent,
            segments: List.unmodifiable(currentPage),
          ),
        );
        currentPage.clear();
        usedPageHeight = 0;
      }

      void addSegment(ReaderSlice segment) {
        if (!widget.scrolling || widget.compactFlow) {
          result.add(segment);
          return;
        }
        final segmentHeight = _segmentExtent(segment);
        final pageCapacity = extent - 16;
        if (currentPage.isNotEmpty &&
            usedPageHeight + segmentHeight > pageCapacity) {
          finishPage();
        }
        currentPage.add(segment);
        usedPageHeight += segmentHeight;
        if (usedPageHeight >= pageCapacity) finishPage();
      }

      var from = 0;
      var laidOutSlices = 0;
      Future<void> appendText(int end) async {
        if (end <= from) return;
        Future<void> paginateRange(int base, int limit) async {
          if (limit <= base) return;
          final paragraphBoundaries = <int>{
            base,
            if (widget.scrolling)
              ...RegExp(r'\n\n')
                  .allMatches(widget.text.substring(base, limit))
                  .map((match) => base + match.end),
            limit,
          }.toList()..sort();
          for (
            var paragraph = 0;
            paragraph < paragraphBoundaries.length - 1;
            paragraph++
          ) {
            final paragraphStart = paragraphBoundaries[paragraph];
            final paragraphEnd = paragraphBoundaries[paragraph + 1];
            if (paragraphStart == paragraphEnd) continue;
            if (widget.text
                .substring(paragraphStart, paragraphEnd)
                .trim()
                .isEmpty) {
              continue;
            }
            final block = _blockAt(paragraphStart)?.block;
            final blockMargin =
                const {'aside', 'blockquote', 'pre'}.contains(block)
                ? 8.0
                : 0.0;
            final firstHeight =
                widget.scrolling &&
                    !widget.compactFlow &&
                    currentPage.isNotEmpty
                ? (extent - 16 - usedPageHeight - 10 - blockMargin)
                      .clamp(0.0, textHeight)
                      .toDouble()
                : null;
            final slices = await paginateReader(
              widget.text.substring(paragraphStart, paragraphEnd),
              widget.style,
              _measuredTextWidth(paragraphStart),
              textHeight,
              widget.scaler,
              cancelled: () => !mounted,
              firstPageHeight: firstHeight,
              widthAt: (start) => _measuredTextWidth(paragraphStart + start),
              styledText: (a, b) =>
                  _richText(paragraphStart + a, paragraphStart + b),
            );
            for (final slice in slices) {
              addSegment(
                ReaderSlice(
                  paragraphStart + slice.start,
                  paragraphStart + slice.end,
                  height: slice.height,
                ),
              );
              if (progressiveLayout && result.isNotEmpty) {
                if (pages == null && result.last.end >= widget.anchor) {
                  final anchorPage = result.lastIndexWhere(
                    (page) => page.start <= widget.anchor,
                  );
                  if (result.length - anchorPage >= 4) {
                    _publishLayout(result);
                  }
                } else if (pages != null &&
                    result.length - starts.length >= 4) {
                  _publishLayout(result);
                }
                if (pages != null && result.length - index >= 16) {
                  _publishLayout(result);
                  morePagesRequested ??= Completer<void>();
                  await morePagesRequested!.future;
                  if (!mounted) return;
                }
              }
              if (++laidOutSlices % 24 == 0) {
                await Future<void>.delayed(Duration.zero);
                if (!mounted) return;
              }
            }
          }
        }

        var cursor = from;
        final chapterStarts =
            widget.chapterBreaks.where((at) => at > from && at <= end).toList()
              ..sort();
        for (var part = 0; part < chapterStarts.length; part++) {
          final chapterStart = chapterStarts[part];
          // Whole-book flow inserts two newlines before a chapter. Keep them
          // out of text layout; fixed-page mode still starts that chapter on
          // a fresh screen, while compact mode keeps the flow tight.
          final chapterEnd = (chapterStart - 2).clamp(cursor, end);
          await paginateRange(cursor, chapterEnd);
          if (widget.scrolling && !widget.compactFlow) finishPage();
          cursor = chapterStart;
          if (part % 32 == 31) {
            await Future<void>.delayed(Duration.zero);
            if (!mounted) return;
          }
        }
        await paginateRange(cursor, end);
        from = end;
      }

      for (final image in orderedImages) {
        final at = image.offset.clamp(from, widget.text.length);
        await appendText(at);
        if (widget.scrolling && !widget.compactFlow) finishPage();
        final slice = ReaderSlice(at, at, height: extent);
        images[slice] = image;
        result.add(slice);
      }
      await appendText(widget.text.length);
      if (widget.scrolling && !widget.compactFlow) finishPage();
      if (result.isEmpty) {
        result.add(
          widget.scrolling
              ? ReaderSlice(
                  0,
                  0,
                  height: extent,
                  segments: const [ReaderSlice(0, 0, height: 0)],
                )
              : const ReaderSlice(0, 0),
        );
      }
      if (!mounted) return;
      layoutComplete = true;
      _publishLayout(result);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  void _scrolled() {
    if (!interacted || pages == null || !scroll!.hasClients) return;
    final elapsed = DateTime.now().difference(lastPositionUpdate);
    const interval = Duration(milliseconds: 250);
    if (elapsed < interval) {
      positionUpdateTimer ??= Timer(interval - elapsed, () {
        positionUpdateTimer = null;
        _updateScrolledPosition();
      });
      return;
    }
    _updateScrolledPosition();
  }

  void _updateScrolledPosition() {
    if (!interacted || pages == null || !scroll!.hasClients) return;
    positionUpdateTimer?.cancel();
    positionUpdateTimer = null;
    lastPositionUpdate = DateTime.now();
    final pixels = scroll!.offset.clamp(0, scroll!.position.maxScrollExtent);
    final next = starts
        .lastIndexWhere((s) => s <= pixels)
        .clamp(0, pages!.length - 1);
    if (!layoutComplete && pages!.length - next <= 8) _requestMorePages();
    final page = pages![next];
    var withinPage = (pixels - starts[next]).clamp(0, heights[next]).toDouble();
    var position = page.start;
    for (final segment in page.segments ?? [page]) {
      if (images.containsKey(segment)) {
        position = segment.start;
        final itemExtent = _segmentExtent(segment);
        if (withinPage <= itemExtent) break;
        withinPage -= itemExtent;
        position = segment.end;
        continue;
      }
      final text = _text(segment);
      final painter = _painter(text, start: segment.start);
      final itemExtent = _segmentExtent(segment);
      if (withinPage <= itemExtent) {
        final within = painter
            .getPositionForOffset(
              Offset(0, (withinPage - 5).clamp(0, segment.height ?? 0)),
            )
            .offset;
        position = (segment.start + within).clamp(segment.start, segment.end);
        painter.dispose();
        break;
      }
      painter.dispose();
      withinPage -= itemExtent;
      position = segment.end;
    }
    if (index != next) setState(() => index = next);
    widget.onPosition(position.clamp(page.start, page.end));
  }

  void _step(int delta) {
    hasSelection = false;
    final list = pages;
    if (list == null) return;
    if (widget.scrolling && scroll!.hasClients) {
      final at = scroll!.offset, max = scroll!.position.maxScrollExtent;
      if (delta > 0 && at >= max - 1) {
        if (!layoutComplete) {
          _requestMorePages();
          return;
        }
        if (!widget.lastChapter) {
          widget.onChapter(1);
        } else {
          widget.onPosition(widget.text.length);
        }
        return;
      }
      if (delta < 0 && at <= 1) {
        if (!widget.firstChapter) widget.onChapter(-1);
        return;
      }
      interacted = true;
      scroll!.animateTo(
        (at + delta * extent).clamp(0, max),
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
      return;
    }
    final next = index + delta;
    if (next < 0) {
      if (!widget.firstChapter) widget.onChapter(-1);
      return;
    }
    if (next >= list.length) {
      if (!layoutComplete) {
        _requestMorePages();
        return;
      }
      if (!widget.lastChapter) {
        widget.onChapter(1);
      } else {
        widget.onPosition(widget.text.length);
      }
      return;
    }
    interacted = true;
    if (!layoutComplete && list.length - next <= 8) _requestMorePages();
    if (widget.scrolling) {
      scroll!.animateTo(
        next * extent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    } else {
      pager!.animateToPage(
        next,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    }
  }

  void _tapAt(double fraction) {
    if (hasSelection) return;
    final action = widget.preferences?.tapAt(fraction);
    if (action == 'previous') _step(-1);
    if (action == 'next') _step(1);
    if (action == 'controls') widget.onToggleControls?.call();
  }

  Widget _scrollingList(
    List<ReaderSlice> list,
    Widget Function(int index) item,
  ) => ListView.builder(
    physics: const AlwaysScrollableScrollPhysics(
      parent: ClampingScrollPhysics(),
    ),
    controller: scroll,
    itemExtentBuilder: (i, _) => heights[i],
    padding: EdgeInsets.zero,
    itemCount: list.length,
    itemBuilder: (_, i) => item(i),
  );

  Widget _pageSlider(int pageCount) {
    final lastPage = pageCount - 1;
    final value = (draggingPage ?? index.toDouble())
        .clamp(0, lastPage)
        .toDouble();
    final shownPage = value.round() + 1;
    final countLabel = layoutComplete ? '$pageCount' : '$pageCount+';
    return SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            const Icon(Icons.menu_book_outlined, size: 18),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  IgnorePointer(
                    child: CustomPaint(
                      painter: ReaderChapterTicksPainter(
                        _chapterPositions(pageCount),
                        Theme.of(context).colorScheme.onSurface
                            .withValues(alpha: .3),
                      ),
                    ),
                  ),
                  Slider(
                    value: value,
                    min: 0,
                    max: lastPage > 0 ? lastPage.toDouble() : 1,
                    label: '$shownPage из $countLabel',
                    semanticFormatterCallback: (v) =>
                        'Страница ${v.round() + 1} из $countLabel',
                    onChanged: pageCount > 1
                        ? (v) => setState(() => draggingPage = v)
                        : null,
                    onChangeEnd: pageCount > 1
                        ? (v) {
                            final target = v.round().clamp(0, lastPage);
                            setState(() => draggingPage = null);
                            interacted = true;
                            scroll?.animateTo(
                              starts[target],
                              duration: const Duration(milliseconds: 180),
                              curve: Curves.easeOut,
                            );
                          }
                        : null,
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 72,
              child: Text(
                '$shownPage из $countLabel',
                textAlign: TextAlign.end,
                maxLines: 1,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<double> _chapterPositions(int itemCount) {
    if (itemCount <= 1) return const [0];
    final lastItem = itemCount - 1;
    return {
      0.0,
      for (final start in widget.chapterBreaks)
        (() {
          final page = pages!.indexWhere((item) => item.start >= start);
          if (page < 0) return 1.0;
          return page / lastItem;
        })(),
    }.toList()..sort();
  }

  @override
  Widget build(BuildContext context) {
    final list = pages;
    if (list == null) {
      return Center(
        child: error == null
            ? const CircularProgressIndicator()
            : Padding(padding: const EdgeInsets.all(24), child: Text(error!)),
      );
    }
    InlineSpan span(ReaderSlice segment) {
      final raw = _text(segment);
      final base = segment.start;
      final markupRanges = _markupOverlapping(base, base + raw.length).toList();
      final ranges = <({int start, int end, Color color})>[
        for (final note in widget.notes)
          (
            start: note.start,
            end: note.end,
            color: noteColors[note.color] ?? noteColors['yellow']!,
          ),
        if (widget.highlightStart != null && widget.highlightEnd != null)
          (
            start: widget.highlightStart!,
            end: widget.highlightEnd!,
            color: noteColors['yellow']!,
          ),
      ].where((r) => r.start < base + raw.length && r.end > base).toList();
      final points = <int>{
        0,
        raw.length,
        for (final r in ranges) ...[
          (r.start - base).clamp(0, raw.length),
          (r.end - base).clamp(0, raw.length),
        ],
        for (final note in widget.footnotes) ...[
          (note.start - base).clamp(0, raw.length),
          (note.end - base).clamp(0, raw.length),
        ],
        for (final r in markupRanges) ...[
          (r.start - base).clamp(0, raw.length),
          (r.end - base).clamp(0, raw.length),
        ],
      }.toList()..sort();
      final spans = <InlineSpan>[];
      for (var j = 0; j < points.length - 1; j++) {
        final link = markupRanges
            .where(
              (r) =>
                  r.href != null &&
                  r.start <= base + points[j] &&
                  r.end > base + points[j],
            )
            .firstOrNull
            ?.href;
        final footnote = widget.footnotes
            .where(
              (n) => n.start <= base + points[j] && n.end > base + points[j],
            )
            .firstOrNull;
        final range = ranges
            .where(
              (r) => r.start <= base + points[j] && r.end > base + points[j],
            )
            .lastOrNull;
        spans.add(
          TextSpan(
            text: footnote == null
                ? raw.substring(points[j], points[j + 1])
                : _noteMarker(raw.substring(points[j], points[j + 1])),
            recognizer: footnote == null
                ? (link == null
                      ? null
                      : linkRecognizers.putIfAbsent(
                          link,
                          () =>
                              TapGestureRecognizer()
                                ..onTap = () => widget.onLink?.call(link),
                        ))
                : recognizers.putIfAbsent(
                    footnote,
                    () =>
                        TapGestureRecognizer()
                          ..onTap = () => widget.onFootnote?.call(footnote),
                  ),
            style:
                (footnote == null
                        ? _styleAt(base + points[j], markupRanges)
                        : _noteMarkerStyle(
                            _styleAt(base + points[j], markupRanges),
                          ))
                    .merge(
                      range == null
                          ? (footnote == null
                                ? null
                                : const TextStyle(
                                    decoration: TextDecoration.underline,
                                  ))
                          : TextStyle(
                              backgroundColor: range.color,
                              color: const Color(0xff262626),
                            ),
                    ),
          ),
        );
      }
      return TextSpan(children: spans);
    }

    Widget pageContent(ReaderSlice segment) {
      if (images.containsKey(segment)) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (e) => _tapAt(e.localPosition.dx / widget.width),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              widget.margin,
              widget.margin,
              widget.margin,
              widget.margin,
            ),
            child: SizedBox(
              height: illustrationHeight,
              child: Image.memory(
                images[segment]!.bytes,
                fit: BoxFit.contain,
                cacheWidth: 1024,
                semanticLabel: images[segment]!.label,
                errorBuilder: (_, _, _) =>
                    Center(child: Text(images[segment]!.label)),
              ),
            ),
          ),
        );
      }
      final text = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (e) => _tapAt(e.localPosition.dx / widget.width),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            widget.margin + _indent(segment.start),
            widget.scrolling ? 5 : 12,
            widget.margin,
            widget.scrolling ? 5 : 12,
          ),
          child: SizedBox(
            width: textWidth - _indent(segment.start),
            child: Listener(
              onPointerDown: (e) {
                down = e.localPosition;
                downAt = DateTime.now();
              },
              child: SelectableText.rich(
                span(segment) as TextSpan,
                key: ValueKey((segment.start, segment.end)),
                style: widget.style,
                textScaler: widget.scaler,
                // The chapter flow owns scrolling. SelectableText must
                // never create a nested scrollable viewport of its own.
                scrollPhysics: const NeverScrollableScrollPhysics(),
                textAlign: _alignment(segment.start),
                onSelectionChanged: (s, cause) => hasSelection = !s.isCollapsed,
                onTap: () {
                  if (hasSelection ||
                      down == null ||
                      downAt == null ||
                      DateTime.now().difference(downAt!).inMilliseconds > 350) {
                    return;
                  }
                  _tapAt((down!.dx + widget.margin) / widget.width);
                },
                contextMenuBuilder: (context, state) {
                  final savedSelection = state.textEditingValue.selection;
                  return readerSelectionToolbar(
                    onMore: state.hideToolbar,
                    context: context,
                    width: widget.width,
                    anchors: state.contextMenuAnchors,
                    buttonItems: [
                      if (widget.onBoundary != null &&
                          !state.textEditingValue.selection.isCollapsed)
                        ContextMenuButtonItem(
                          label: widget.selectingRange
                              ? 'Закончить здесь'
                              : 'Начать длинную цитату',
                          onPressed: () {
                            final selection = savedSelection;
                            state.hideToolbar();
                            widget.onBoundary!(
                              segment.start +
                                  (widget.selectingRange
                                      ? selection.end
                                      : selection.start),
                              widget.selectingRange,
                            );
                          },
                        ),
                      if (widget.onAnnotate != null &&
                          !state.textEditingValue.selection.isCollapsed)
                        for (final comment in [false, true])
                          ContextMenuButtonItem(
                            label: comment ? 'Заметка' : 'Выделить',
                            onPressed: () {
                              final selection = savedSelection;
                              state.hideToolbar();
                              widget.onAnnotate!(
                                segment.start + selection.start,
                                segment.start + selection.end,
                                comment,
                              );
                            },
                          ),
                      ...state.contextMenuButtonItems,
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
      final block = _blockAt(segment.start);
      Widget styledText = text;
      if (const {'aside', 'blockquote', 'pre'}.contains(block?.block)) {
        final foreground =
            widget.style.color ?? Theme.of(context).colorScheme.onSurface;
        final isCode = block?.block == 'pre';
        styledText = Container(
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 3),
          decoration: BoxDecoration(
            color: foreground.withValues(alpha: isCode ? .08 : .045),
            border: isCode
                ? Border.all(color: foreground.withValues(alpha: .22))
                : Border(
                    left: BorderSide(
                      color: foreground.withValues(alpha: .55),
                      width: 3,
                    ),
                  ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: text,
        );
      }
      final marker = block?.marker;
      if (marker == null || block?.start != segment.start) return styledText;
      return Stack(
        clipBehavior: Clip.none,
        children: [
          styledText,
          Positioned(
            left: widget.margin + _indent(segment.start) - 28,
            top: 5,
            child: Text(marker, style: widget.style, textScaler: widget.scaler),
          ),
        ],
      );
    }

    Widget page(int i) {
      final current = list[i];
      final segments = current.segments;
      if (segments == null) return pageContent(current);
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [for (final segment in segments) pageContent(segment)],
      );
    }

    Widget decoratedPage(int i) {
      if (widget.scrolling) {
        if (widget.compactFlow) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              page(i),
              if (i < chapterSeparators.length && chapterSeparators[i])
                Divider(
                  height: 1,
                  thickness: 1,
                  color: widget.style.color?.withValues(alpha: .36),
                ),
            ],
          );
        }
        return SizedBox(
          height: extent,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (event) =>
                      _tapAt(event.localPosition.dx / widget.width),
                ),
              ),
              Positioned.fill(
                child: ClipRect(
                  child: Align(
                    alignment: images.containsKey(list[i])
                        ? Alignment.center
                        : Alignment.topCenter,
                    child: page(i),
                  ),
                ),
              ),
              if (i < list.length - 1)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Divider(
                    height: 1,
                    thickness: 1,
                    color: widget.style.color?.withValues(alpha: .36),
                  ),
                ),
            ],
          ),
        );
      }
      return Stack(fit: StackFit.expand, children: [page(i)]);
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _step(1),
        const SingleActivator(LogicalKeyboardKey.pageDown): () => _step(1),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _step(-1),
        const SingleActivator(LogicalKeyboardKey.pageUp): () => _step(-1),
      },
      child: Listener(
        onPointerSignal: (event) {
          if (event is PointerScrollEvent &&
              widget.scrolling &&
              scroll?.hasClients == true) {
            final position = scroll!.position;
            if (event.scrollDelta.dy > 0 &&
                    position.pixels >= position.maxScrollExtent - 1 ||
                event.scrollDelta.dy < 0 && position.pixels <= 1) {
              _cross(event.scrollDelta.dy);
            }
          }
        },
        child: Focus(
          autofocus: ModalRoute.of(context)?.isCurrent ?? true,
          child: Column(
            children: [
              Expanded(
                child: widget.scrolling
                    ? NotificationListener<ScrollNotification>(
                        onNotification: (n) {
                          if (n.depth != 0) return false;
                          if (n is ScrollStartNotification &&
                                  n.dragDetails != null ||
                              n is UserScrollNotification &&
                                  n.direction != ScrollDirection.idle) {
                            interacted = true;
                          }
                          if (n is ScrollUpdateNotification) _scrolled();
                          if (n is ScrollEndNotification) {
                            _updateScrolledPosition();
                          }
                          if (n is OverscrollNotification) _cross(n.overscroll);
                          return false;
                        },
                        child: ScrollConfiguration(
                          behavior: ScrollConfiguration.of(context)
                              .copyWith(scrollbars: false),
                          child: widget.showScrollbar
                              ? Scrollbar(
                                  controller: scroll,
                                  thumbVisibility: true,
                                  child: _scrollingList(list, decoratedPage),
                                )
                              : _scrollingList(list, decoratedPage),
                        ),
                      )
                    : NotificationListener<ScrollNotification>(
                        onNotification: (n) {
                          if (n.depth != 0) return false;
                          if (n is ScrollStartNotification &&
                              n.dragDetails != null) {
                            interacted = true;
                          }
                          if (n is OverscrollNotification) _cross(n.overscroll);
                          return false;
                        },
                        child: PageView.builder(
                          physics: const AlwaysScrollableScrollPhysics(
                            parent: ClampingScrollPhysics(),
                          ),
                          controller: pager,
                          itemCount: list.length,
                          onPageChanged: (i) {
                            setState(() => index = i);
                            if (!layoutComplete && list.length - i <= 8) {
                              _requestMorePages();
                            }
                            if (interacted) widget.onPosition(list[i].start);
                          },
                          itemBuilder: (_, i) => decoratedPage(i),
                        ),
                      ),
              ),
              if (widget.scrolling && !widget.compactFlow)
                _pageSlider(list.length)
              else if (!widget.scrolling && !widget.hideControls)
                SizedBox(
                  height: 48,
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: 'Предыдущая страница',
                        onPressed: index == 0 && widget.firstChapter
                            ? null
                            : () => _step(-1),
                        icon: const Icon(Icons.chevron_left),
                      ),
                      Expanded(
                        child: Text(
                          '${widget.scrolling ? 'Прокрутка' : 'Страница'} · ${index + 1}/${list.length}${layoutComplete ? '' : '+'}',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
                      IconButton(
                        tooltip: index == list.length - 1 && widget.lastChapter
                            ? 'Конец книги'
                            : 'Следующая страница',
                        onPressed: () => _step(1),
                        icon: const Icon(Icons.chevron_right),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _cross(double overscroll) {
    if (crossingChapter || hasSelection || overscroll.abs() < 2) return;
    final delta = overscroll > 0 ? 1 : -1;
    if (delta > 0 && !layoutComplete) {
      _requestMorePages();
      return;
    }
    if (delta > 0 && widget.lastChapter || delta < 0 && widget.firstChapter) {
      return;
    }
    crossingChapter = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onChapter(delta);
    });
  }
}

class ReaderChapterTicksPainter extends CustomPainter {
  final List<double> positions;
  final Color color;
  const ReaderChapterTicksPainter(this.positions, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final start = 12.0;
    final end = (size.width - 12).clamp(start, size.width).toDouble();
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (final position in positions) {
      final x = start + (end - start) * position.clamp(0, 1);
      canvas.drawLine(
        Offset(x, size.height / 2 - 4),
        Offset(x, size.height / 2 + 4),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant ReaderChapterTicksPainter oldDelegate) =>
      positions != oldDelegate.positions || color != oldDelegate.color;
}

Widget readerSelectionToolbar({
  required BuildContext context,
  required double width,
  required TextSelectionToolbarAnchors anchors,
  required List<ContextMenuButtonItem> buttonItems,
  VoidCallback? onMore,
}) => Padding(
  padding: const EdgeInsets.all(8),
  child: CustomSingleChildLayout(
    delegate: TextSelectionToolbarLayoutDelegate(
      anchorAbove: anchors.primaryAnchor - const Offset(8, 16),
      anchorBelow:
          (anchors.secondaryAnchor ?? anchors.primaryAnchor) +
          const Offset(-8, 16),
    ),
    child: Material(
      elevation: 5,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: (width - 32).clamp(200, 400),
        child: Wrap(
          children: [
            for (final item in buttonItems.where(_primarySelectionAction))
              TextButton(
                onPressed: item.onPressed,
                child: Text(
                  AdaptiveTextSelectionToolbar.getButtonLabel(context, item),
                ),
              ),
            if (buttonItems.any((item) => !_primarySelectionAction(item)))
              TextButton(
                onPressed: () async {
                  final navigator = Navigator.of(context);
                  onMore?.call();
                  final chosen =
                      await showModalBottomSheet<ContextMenuButtonItem>(
                        context: navigator.context,
                        showDragHandle: true,
                        builder: (context) => SafeArea(
                          child: ListView(
                            shrinkWrap: true,
                            children: [
                              for (final item in buttonItems.where(
                                (item) => !_primarySelectionAction(item),
                              ))
                                ListTile(
                                  title: Text(
                                    AdaptiveTextSelectionToolbar.getButtonLabel(
                                      context,
                                      item,
                                    ),
                                  ),
                                  onTap: () => Navigator.pop(context, item),
                                ),
                            ],
                          ),
                        ),
                      );
                  chosen?.onPressed?.call();
                },
                child: const Text('Ещё'),
              ),
          ],
        ),
      ),
    ),
  ),
);

bool _primarySelectionAction(ContextMenuButtonItem item) =>
    item.type == ContextMenuButtonType.copy ||
    item.label == 'Выделить' ||
    item.label == 'Заметка' ||
    item.label == 'Цитата / заметка';
