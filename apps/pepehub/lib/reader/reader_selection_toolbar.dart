import 'package:flutter/material.dart';

Widget readerSelectionToolbar({
  required BuildContext context,
  required double width,
  required TextSelectionToolbarAnchors anchors,
  required List<ContextMenuButtonItem> buttonItems,
  VoidCallback? onMore,
  Widget? palette,
}) => _ReaderSelectionToolbar(
  width: width,
  anchors: anchors,
  items: buttonItems,
  onMore: onMore,
  palette: palette,
);

class _ReaderSelectionToolbar extends StatefulWidget {
  final double width;
  final TextSelectionToolbarAnchors anchors;
  final List<ContextMenuButtonItem> items;
  final VoidCallback? onMore;
  final Widget? palette;
  const _ReaderSelectionToolbar({
    required this.width,
    required this.anchors,
    required this.items,
    this.onMore,
    this.palette,
  });
  @override
  State<_ReaderSelectionToolbar> createState() =>
      _ReaderSelectionToolbarState();
}

class _ReaderSelectionToolbarState extends State<_ReaderSelectionToolbar> {
  bool colors = false;
  bool highlight(ContextMenuButtonItem item) => item.label == 'Выделить';
  bool note(ContextMenuButtonItem item) =>
      item.label == 'Заметка' || item.label == 'Цитата / заметка';
  bool copy(ContextMenuButtonItem item) =>
      item.type == ContextMenuButtonType.copy;
  String label(ContextMenuButtonItem item, BuildContext context) => copy(item)
      ? 'Копировать'
      : note(item)
      ? 'Заметка'
      : AdaptiveTextSelectionToolbar.getButtonLabel(context, item);
  IconData icon(ContextMenuButtonItem item) => highlight(item)
      ? Icons.highlight_outlined
      : note(item)
      ? Icons.mode_comment_outlined
      : copy(item)
      ? Icons.copy_outlined
      : Icons.more_horiz;

  @override
  Widget build(BuildContext context) {
    final primary = [
      ...widget.items.where(highlight),
      ...widget.items.where(note),
      ...widget.items.where(copy),
    ];
    final extras = widget.items
        .where((i) => !highlight(i) && !note(i) && !copy(i))
        .toList();
    return Padding(
      padding: const EdgeInsets.all(8),
      child: CustomSingleChildLayout(
        delegate: TextSelectionToolbarLayoutDelegate(
          anchorAbove: widget.anchors.primaryAnchor - const Offset(8, 16),
          anchorBelow:
              (widget.anchors.secondaryAnchor ?? widget.anchors.primaryAnchor) +
              const Offset(-8, 18),
        ),
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          elevation: 6,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            width: (widget.width - 24).clamp(200, 400),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      for (final item in primary)
                        Expanded(
                          child: TextButton(
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 3,
                                vertical: 10,
                              ),
                              minimumSize: const Size(44, 56),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            onPressed: highlight(item) && widget.palette != null
                                ? () => setState(() => colors = !colors)
                                : item.onPressed,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(icon(item), size: 19),
                                const SizedBox(height: 5),
                                Text(
                                  label(item, context),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (extras.isNotEmpty)
                        Expanded(
                          child: Tooltip(
                            message: 'Ещё',
                            child: TextButton(
                              child: const Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.more_horiz, size: 19),
                                  SizedBox(height: 5),
                                  Text('Ещё', style: TextStyle(fontSize: 12)),
                                ],
                              ),
                              onPressed: () async {
                                final navigator = Navigator.of(context);
                                widget.onMore?.call();
                                final chosen =
                                    await showModalBottomSheet<
                                      ContextMenuButtonItem
                                    >(
                                      context: navigator.context,
                                      useSafeArea: true,
                                      showDragHandle: true,
                                      constraints: const BoxConstraints(
                                        maxWidth: 640,
                                      ),
                                      builder: (context) => SafeArea(
                                        top: false,
                                        child: SingleChildScrollView(
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              const ListTile(
                                                title: Text(
                                                  'Действия с выделением',
                                                ),
                                              ),
                                              for (final item in extras)
                                                ListTile(
                                                  title: Text(
                                                    label(item, context),
                                                  ),
                                                  onTap: () => Navigator.pop(
                                                    context,
                                                    item,
                                                  ),
                                                ),
                                              const SizedBox(height: 16),
                                            ],
                                          ),
                                        ),
                                      ),
                                    );
                                chosen?.onPressed?.call();
                              },
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (colors && widget.palette != null) ...[
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: widget.palette!,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
