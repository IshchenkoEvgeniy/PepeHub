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
  final double width, height, margin;
  final int anchor;
  final int? highlightStart, highlightEnd;
  final bool scrolling, firstChapter, lastChapter;
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
    required this.anchor,
    this.highlightStart,
    this.highlightEnd,
    required this.scrolling,
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
  final pageSeparators = <bool>[];
  late List<BookMarkup> markupByStart;
  late List<int> markupPrefixMaxEnd;
  double contentHeight = 0;
  String _text(ReaderSlice page) {
    final text = widget.text.substring(page.start, page.end);
    return text.trimRight();
  }

  // Reserve navigation controls separately from the measured text area.
  double get extent =>
      widget.height - (widget.scrolling || !widget.hideControls ? 48 : 0);
  double get textHeight => extent - 24;
  double get textWidth => widget.width - widget.margin * 2;
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
        'justify' => TextAlign.justify,
        _ => TextAlign.left,
      };
    }
    return (_blockAt(at)?.heading ?? 0) > 0
        ? TextAlign.center
        : _blockAt(at)?.code == true
        ? TextAlign.left
        : TextAlign.justify;
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
    super.dispose();
  }

  TextStyle _styleAt(int offset, [Iterable<BookMarkup>? matching]) {
    var style = widget.style;
    for (final range in matching ?? _markupOverlapping(offset, offset + 1)) {
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

  TextSpan _richText(int start, int end) {
    final matching = _markupOverlapping(start, end).toList();
    final points = <int>{
      start,
      end,
      for (final r in matching) ...[
        r.start.clamp(start, end),
        r.end.clamp(start, end),
      ],
    }.toList()..sort();
    return TextSpan(
      style: widget.style,
      children: [
        for (var i = 0; i < points.length - 1; i++)
          TextSpan(
            text: widget.text.substring(points[i], points[i + 1]),
            style: _styleAt(points[i], matching),
          ),
      ],
    );
  }

  TextPainter _painter(String text, {int start = 0}) => TextPainter(
    text: _richText(start, start + text.length),
    textDirection: TextDirection.ltr,
    textScaler: widget.scaler,
    textAlign: _alignment(start),
  )..layout(maxWidth: textWidth - _indent(start));

  double _segmentExtent(ReaderSlice segment) => images.containsKey(segment)
      ? illustrationHeight + widget.margin * 2
      : (segment.height ?? 0) + (widget.scrolling ? 10 : 24);

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
        if (!widget.scrolling) {
          result.add(segment);
          return;
        }
        const verticalPadding = 10.0;
        final segmentHeight = (segment.height ?? 0) + verticalPadding;
        final pageCapacity = extent - 1;
        if (currentPage.isNotEmpty &&
            usedPageHeight + segmentHeight > pageCapacity) {
          finishPage();
        }
        currentPage.add(segment);
        usedPageHeight += segmentHeight;
        if (usedPageHeight >= pageCapacity) finishPage();
      }

      var from = 0;
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
            final slices = await paginateReader(
              widget.text.substring(paragraphStart, paragraphEnd),
              widget.style,
              textWidth - _indent(paragraphStart),
              textHeight,
              widget.scaler,
              cancelled: () => !mounted,
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
            }
          }
        }

        var cursor = from;
        final chapterStarts =
            widget.chapterBreaks.where((at) => at > from && at <= end).toList()
              ..sort();
        for (var part = 0; part < chapterStarts.length; part++) {
          final chapterStart = chapterStarts[part];
          // Whole-book flow inserts exactly two separator newlines before a
          // chapter. Keep them out of pagination so they cannot create a
          // spurious blank page; the chapter still starts on a fresh page.
          final chapterEnd = (chapterStart - 2).clamp(cursor, end);
          await paginateRange(cursor, chapterEnd);
          if (widget.scrolling) finishPage();
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
        if (widget.scrolling) finishPage();
        final slice = ReaderSlice(at, at, height: extent);
        images[slice] = image;
        result.add(slice);
      }
      await appendText(widget.text.length);
      if (widget.scrolling) finishPage();
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
      if (widget.scrolling) {
        for (var i = 0; i < result.length; i++) {
          starts.add(contentHeight);
          pageSeparators.add(i < result.length - 1);
          heights.add(extent);
          contentHeight += heights.last;
        }
      } else {
        for (var i = 0; i < result.length; i++) {
          starts.add(contentHeight);
          heights.add(extent);
          contentHeight += extent;
        }
      }
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
          (contentHeight - extent).clamp(0, double.infinity),
        ),
      );
      setState(() => pages = result);
      widget.onReady?.call();
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
      final itemExtent = text.isEmpty
          ? 10.0
          : (segment.height ?? painter.height) + 10;
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
      if (!widget.lastChapter) {
        widget.onChapter(1);
      } else {
        widget.onPosition(widget.text.length);
      }
      return;
    }
    interacted = true;
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
                      painter: _PageTicksPainter(
                        pageCount,
                        Theme.of(context).colorScheme.onSurface
                            .withValues(alpha: .3),
                      ),
                    ),
                  ),
                  Slider(
                    value: value,
                    min: 0,
                    max: lastPage > 0 ? lastPage.toDouble() : 1,
                    label: '$shownPage из $pageCount',
                    semanticFormatterCallback: (v) =>
                        'Страница ${v.round() + 1} из $pageCount',
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
                '$shownPage из $pageCount',
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
            text: raw.substring(points[j], points[j + 1]),
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
            style: _styleAt(base + points[j], markupRanges).merge(
              range == null
                  ? (footnote == null
                        ? null
                        : const TextStyle(decoration: TextDecoration.underline))
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
      final marker = block?.marker;
      if (marker == null || block?.start != segment.start) return text;
      return Stack(
        clipBehavior: Clip.none,
        children: [
          text,
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
              Align(
                alignment: images.containsKey(list[i])
                    ? Alignment.center
                    : Alignment.topCenter,
                child: page(i),
              ),
              if (i < pageSeparators.length && pageSeparators[i])
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
          autofocus: true,
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
                            if (interacted) widget.onPosition(list[i].start);
                          },
                          itemBuilder: (_, i) => decoratedPage(i),
                        ),
                      ),
              ),
              if (widget.scrolling)
                _pageSlider(list.length)
              else if (!widget.hideControls)
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
                          '${widget.scrolling ? 'Прокрутка' : 'Страница'} · ${index + 1}/${list.length}',
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
    if (delta > 0 && widget.lastChapter || delta < 0 && widget.firstChapter) {
      return;
    }
    crossingChapter = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onChapter(delta);
    });
  }
}

class _PageTicksPainter extends CustomPainter {
  final int pageCount;
  final Color color;
  const _PageTicksPainter(this.pageCount, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final count = pageCount.clamp(1, 120).toInt();
    final start = 12.0;
    final end = (size.width - 12).clamp(start, size.width).toDouble();
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (var i = 0; i < count; i++) {
      final x = count == 1 ? start : start + (end - start) * i / (count - 1);
      canvas.drawLine(
        Offset(x, size.height / 2 - 4),
        Offset(x, size.height / 2 + 4),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PageTicksPainter oldDelegate) =>
      pageCount != oldDelegate.pageCount || color != oldDelegate.color;
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
