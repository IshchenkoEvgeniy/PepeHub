import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'reader_window.dart';

/// [selectedText] is the book text under the selection. When it is given,
/// the system actions that act on the live selection (share, look up, search,
/// select all) are replaced with ones that use this text, so they act on
/// exactly the book text. [onDismiss] closes the toolbar after an action
/// picked from the expanded «Ещё» list.
Widget readerSelectionToolbar({
  required BuildContext context,
  required double width,
  required TextSelectionToolbarAnchors anchors,
  required List<ContextMenuButtonItem> buttonItems,
  VoidCallback? onDismiss,
  Widget? palette,
  String? selectedText,
}) {
  final text = selectedText?.trim() ?? '';
  final messenger = ScaffoldMessenger.maybeOf(context);
  Future<void> open(Uri uri) async {
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw StateError('no handler');
      }
    } catch (_) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('Не удалось открыть браузер')),
      );
    }
  }

  final items = text.isEmpty
      ? buttonItems
      : [
          for (final item in buttonItems)
            if (!const {
              ContextMenuButtonType.selectAll,
              ContextMenuButtonType.share,
              ContextMenuButtonType.lookUp,
              ContextMenuButtonType.searchWeb,
              ContextMenuButtonType.liveTextInput,
            }.contains(item.type))
              item,
          if (ReaderWindow.supported)
            ContextMenuButtonItem(
              label: 'Поделиться',
              onPressed: () async {
                if (!await ReaderWindow.shareText(text)) {
                  await Clipboard.setData(ClipboardData(text: text));
                  messenger?.showSnackBar(
                    const SnackBar(content: Text('Текст скопирован')),
                  );
                }
              },
            ),
          ContextMenuButtonItem(
            label: 'Перевести',
            onPressed: () => open(
              Uri.https('translate.google.com', '/', {
                'sl': 'auto',
                'tl': 'ru',
                'op': 'translate',
                'text': text.length > 4000 ? text.substring(0, 4000) : text,
              }),
            ),
          ),
          ContextMenuButtonItem(
            label: 'Искать в интернете',
            onPressed: () => open(
              Uri.https('www.google.com', '/search', {
                'q': text.length > 400 ? text.substring(0, 400) : text,
              }),
            ),
          ),
          ContextMenuButtonItem(
            label: 'Викисловарь',
            onPressed: () => open(
              Uri.https(
                'ru.wiktionary.org',
                '/wiki/${text.split(RegExp(r'\s+')).first.replaceAll(RegExp(r'[^\p{L}\p{N}-]', unicode: true), '').toLowerCase()}',
              ),
            ),
          ),
        ];
  return _ReaderSelectionToolbar(
    width: width,
    anchors: anchors,
    items: items,
    onDismiss: onDismiss,
    palette: palette,
  );
}

class _ReaderSelectionToolbar extends StatefulWidget {
  final double width;
  final TextSelectionToolbarAnchors anchors;
  final List<ContextMenuButtonItem> items;
  final VoidCallback? onDismiss;
  final Widget? palette;
  const _ReaderSelectionToolbar({
    required this.width,
    required this.anchors,
    required this.items,
    this.onDismiss,
    this.palette,
  });
  @override
  State<_ReaderSelectionToolbar> createState() =>
      _ReaderSelectionToolbarState();
}

class _ReaderSelectionToolbarState extends State<_ReaderSelectionToolbar> {
  bool colors = false, more = false;
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
                                ? () => setState(() {
                                    colors = !colors;
                                    if (colors) more = false;
                                  })
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
                              key: const ValueKey('reader-selection-more'),
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
                              // The actions open inside the toolbar: a sheet
                              // pushed after the toolbar is gone lost the
                              // selection and its route on real devices.
                              onPressed: () => setState(() {
                                more = !more;
                                if (more) colors = false;
                              }),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    more ? Icons.expand_less : Icons.more_horiz,
                                    size: 19,
                                  ),
                                  const SizedBox(height: 5),
                                  const Text(
                                    'Ещё',
                                    style: TextStyle(fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (more && extras.isNotEmpty) ...[
                    const Divider(height: 1),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 280),
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final item in extras)
                              TextButton(
                                style: TextButton.styleFrom(
                                  alignment: Alignment.centerLeft,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 12,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                                onPressed: () {
                                  // Run the action while the selection is
                                  // still live, then close the toolbar.
                                  item.onPressed?.call();
                                  widget.onDismiss?.call();
                                },
                                child: Text(label(item, context)),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
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
