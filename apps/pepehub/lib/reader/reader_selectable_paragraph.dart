import 'package:flutter/material.dart';

/// Reports offsets in this paragraph directly; repeated text needs no search.
/// Selected paragraphs stay registered while the user scrolls a long quote.
class ReaderSelectableParagraph extends StatefulWidget {
  final TextSpan span;
  final TextStyle style;
  final TextScaler scaler;
  final TextAlign alignment;
  final ValueChanged<TextSelection?> onSelection;
  const ReaderSelectableParagraph({
    super.key,
    required this.span,
    required this.style,
    required this.scaler,
    required this.alignment,
    required this.onSelection,
  });

  @override
  State<ReaderSelectableParagraph> createState() => _ParagraphState();
}

class _ParagraphState extends State<ReaderSelectableParagraph>
    with AutomaticKeepAliveClientMixin {
  final selection = SelectionListenerNotifier();
  bool selected = false;
  @override
  bool get wantKeepAlive => selected;

  @override
  void initState() {
    super.initState();
    selection.addListener(_changed);
  }

  void _changed() {
    final range = selection.registered ? selection.selection.range : null;
    final value = range == null
        ? null
        : TextSelection(
            baseOffset: range.startOffset,
            extentOffset: range.endOffset,
          );
    final active = value != null && !value.isCollapsed;
    if (selected != active) {
      selected = active;
      updateKeepAlive();
    }
    widget.onSelection(value);
  }

  @override
  void dispose() {
    selection.removeListener(_changed);
    selection.dispose();
    widget.onSelection(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SelectionListener(
      selectionNotifier: selection,
      child: Text.rich(
        widget.span,
        // Match the measurement painter; Material's letter spacing must not
        // change line wrapping after fixed item extents have been calculated.
        style: widget.style.copyWith(inherit: false),
        strutStyle: StrutStyle.fromTextStyle(widget.style),
        textHeightBehavior: const TextHeightBehavior(),
        textDirection: TextDirection.ltr,
        textScaler: widget.scaler,
        textAlign: widget.alignment,
      ),
    );
  }
}
