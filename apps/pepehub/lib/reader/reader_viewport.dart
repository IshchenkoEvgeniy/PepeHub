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
  final starts = <double>[], heights = <double>[];
  double contentHeight = 0;
  String _text(ReaderSlice page) {
    final text = widget.text.substring(page.start, page.end);
    return text.trimRight();
  }

  // Reserve navigation controls separately from the measured text area.
  double get extent =>
      widget.height - (widget.hideControls || widget.scrolling ? 0 : 48);
  double get textHeight => extent - 24;
  double get textWidth => widget.width - widget.margin * 2;
  BookMarkup? _blockAt(int at) {
    final ranges = widget.markup.where((r) => r.start <= at && r.end > at);
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
    final align = widget.markup
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
    widget.onLoading?.call();
    _layout();
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
    super.dispose();
  }

  TextStyle _styleAt(int offset) {
    var style = widget.style;
    for (final range in widget.markup.where(
      (r) => r.start <= offset && r.end > offset,
    )) {
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
    final points = <int>{
      start,
      end,
      for (final r in widget.markup.where(
        (r) => r.start < end && r.end > start,
      )) ...[r.start.clamp(start, end), r.end.clamp(start, end)],
    }.toList()..sort();
    return TextSpan(
      style: widget.style,
      children: [
        for (var i = 0; i < points.length - 1; i++)
          TextSpan(
            text: widget.text.substring(points[i], points[i + 1]),
            style: _styleAt(points[i]),
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
  Future<void> _layout() async {
    try {
      final result = <ReaderSlice>[];
      final orderedImages = [...widget.illustrations]
        ..sort((a, b) => a.offset.compareTo(b.offset));
      var from = 0;
      Future<void> appendText(int end) async {
        if (end <= from) return;
        final boundaries = [
          from,
          if (widget.scrolling)
            ...RegExp(r'\n\n')
                .allMatches(widget.text.substring(from, end))
                .map((m) => from + m.end),
          end,
        ];
        for (var part = 0; part < boundaries.length - 1; part++) {
          final base = boundaries[part], limit = boundaries[part + 1];
          if (base == limit) continue;
          final slices = await paginateReader(
            widget.text.substring(base, limit),
            widget.style,
            textWidth - _indent(base),
            textHeight,
            widget.scaler,
            cancelled: () => !mounted,
            styledText: (a, b) => _richText(base + a, base + b),
          );
          result.addAll(
            slices.map((s) => ReaderSlice(base + s.start, base + s.end)),
          );
          if (part % 32 == 31) {
            await Future<void>.delayed(Duration.zero);
            if (!mounted) return;
          }
        }
        from = end;
      }

      for (final image in orderedImages) {
        final at = image.offset.clamp(from, widget.text.length);
        await appendText(at);
        final slice = ReaderSlice(at, at);
        images[slice] = image;
        result.add(slice);
      }
      await appendText(widget.text.length);
      if (result.isEmpty) result.add(const ReaderSlice(0, 0));
      if (!mounted) return;
      index = result
          .lastIndexWhere((p) => p.start <= widget.anchor)
          .clamp(0, result.length - 1);
      if (widget.anchor == 0) index = 0;
      pager = PageController(initialPage: index);
      for (final page in result) {
        starts.add(contentHeight);
        if (widget.scrolling) {
          final painter = _painter(_text(page), start: page.start);
          final height = images.containsKey(page)
              ? extent * .85
              : painter.height + 10;
          final measured =
              height + (widget.chapterBreaks.contains(page.start) ? 32 : 0);
          heights.add(measured);
          contentHeight += measured;
          painter.dispose();
          if (heights.length % 8 == 0) {
            await Future<void>.delayed(Duration.zero);
            if (!mounted) return;
          }
        } else {
          heights.add(extent);
          contentHeight += extent;
        }
      }
      var pixels = starts[index];
      if (widget.scrolling) {
        final page = result[index];
        final painter = _painter(
          widget.text.substring(page.start, page.end),
          start: page.start,
        );
        pixels += painter
            .getOffsetForCaret(
              TextPosition(
                offset: (widget.anchor - page.start).clamp(
                  0,
                  page.end - page.start,
                ),
              ),
              Rect.zero,
            )
            .dy;
        painter.dispose();
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
    final pixels = scroll!.offset.clamp(0, scroll!.position.maxScrollExtent);
    final next = starts
        .lastIndexWhere((s) => s <= pixels)
        .clamp(0, pages!.length - 1);
    final page = pages![next];
    final painter = _painter(
      widget.text.substring(page.start, page.end),
      start: page.start,
    );
    final within = painter
        .getPositionForOffset(
          Offset(0, (pixels - starts[next] - 5).clamp(0, heights[next])),
        )
        .offset;
    painter.dispose();
    if (index != next) setState(() => index = next);
    widget.onPosition((page.start + within).clamp(page.start, page.end));
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
    InlineSpan span(int i) {
      final raw = _text(list[i]);
      final base = list[i].start;
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
        for (final r in widget.markup.where(
          (r) => r.start < base + raw.length && r.end > base,
        )) ...[
          (r.start - base).clamp(0, raw.length),
          (r.end - base).clamp(0, raw.length),
        ],
      }.toList()..sort();
      final spans = <InlineSpan>[];
      for (var j = 0; j < points.length - 1; j++) {
        final link = widget.markup
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
            style: _styleAt(base + points[j]).merge(
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

    Widget page(int i) => images.containsKey(list[i])
        ? Padding(
            padding: EdgeInsets.fromLTRB(
              widget.margin,
              widget.chapterBreaks.contains(list[i].start)
                  ? widget.margin + 32
                  : widget.margin,
              widget.margin,
              widget.margin,
            ),
            child: Image.memory(
              images[list[i]]!.bytes,
              fit: BoxFit.contain,
              cacheWidth: 1024,
              semanticLabel: images[list[i]]!.label,
              errorBuilder: (_, _, _) =>
                  Center(child: Text(images[list[i]]!.label)),
            ),
          )
        : GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (e) => _tapAt(e.localPosition.dx / widget.width),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                widget.margin + _indent(list[i].start),
                widget.scrolling
                    ? (widget.chapterBreaks.contains(list[i].start) ? 37 : 5)
                    : 12,
                widget.margin,
                widget.scrolling ? 5 : 12,
              ),
              child: SizedBox(
                width: textWidth - _indent(list[i].start),
                child: Listener(
                  onPointerDown: (e) {
                    down = e.localPosition;
                    downAt = DateTime.now();
                  },
                  child: SelectableText.rich(
                    span(i) as TextSpan,
                    style: widget.style,
                    textScaler: widget.scaler,
                    // The chapter flow owns scrolling. SelectableText must
                    // never create a nested scrollable viewport of its own.
                    scrollPhysics: const NeverScrollableScrollPhysics(),
                    textAlign: _alignment(list[i].start),
                    onSelectionChanged: (s, cause) =>
                        hasSelection = !s.isCollapsed,
                    onTap: () {
                      if (hasSelection ||
                          down == null ||
                          downAt == null ||
                          DateTime.now().difference(downAt!).inMilliseconds >
                              350) {
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
                                  list[i].start +
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
                                    list[i].start + selection.start,
                                    list[i].start + selection.end,
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
    Widget decoratedPage(int i) {
      final block = _blockAt(list[i].start);
      return Stack(
        fit: StackFit.expand,
        children: [
          page(i),
          if (widget.scrolling && widget.chapterBreaks.contains(list[i].start))
            Positioned(
              left: widget.margin,
              right: widget.margin,
              top: 14,
              child: Divider(
                height: 1,
                thickness: 1,
                color: widget.style.color?.withValues(alpha: .55),
              ),
            ),
          if (widget.scrolling &&
              block?.marker != null &&
              block!.start == list[i].start)
            Positioned(
              left: widget.margin + _indent(list[i].start) - 28,
              top: 5,
              child: Text(
                block.marker!,
                style: widget.style,
                textScaler: widget.scaler,
              ),
            ),
        ],
      );
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
              if (!widget.hideControls && !widget.scrolling)
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
