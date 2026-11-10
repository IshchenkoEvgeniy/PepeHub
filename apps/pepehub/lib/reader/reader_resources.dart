import 'package:flutter/material.dart';

import 'epub.dart';

Future<void> showBookFootnote(BuildContext context, BookFootnote note) =>
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .65,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  'Примечание ${note.label.replaceAll(RegExp(r'[\[\]]'), '')}',
                ),
                trailing: IconButton(
                  tooltip: 'Закрыть сноску',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  child: SelectableText(
                    note.text,
                    style: Theme.of(context).textTheme.bodyLarge
                        ?.copyWith(height: 1.6),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

/// Full-screen illustration on a dark backdrop: pinch or double-tap to zoom,
/// tap the backdrop or the close button to return to the text.
Future<void> showBookIllustration(
  BuildContext context,
  BookIllustration illustration,
) => Navigator.of(context).push(
  PageRouteBuilder<void>(
    opaque: false,
    barrierDismissible: true,
    barrierLabel: 'Закрыть иллюстрацию',
    barrierColor: Colors.black,
    transitionDuration: const Duration(milliseconds: 160),
    reverseTransitionDuration: const Duration(milliseconds: 120),
    pageBuilder: (context, animation, _) => FadeTransition(
      opacity: animation,
      child: _IllustrationViewer(illustration),
    ),
  ),
);

class _IllustrationViewer extends StatefulWidget {
  final BookIllustration illustration;
  const _IllustrationViewer(this.illustration);
  @override
  State<_IllustrationViewer> createState() => _IllustrationViewerState();
}

class _IllustrationViewerState extends State<_IllustrationViewer> {
  final transform = TransformationController();
  TapDownDetails? doubleTap;

  @override
  void dispose() {
    transform.dispose();
    super.dispose();
  }

  void _toggleZoom() {
    final at = doubleTap?.localPosition ?? Offset.zero;
    transform.value = transform.value.getMaxScaleOnAxis() > 1.01
        ? Matrix4.identity()
        : (Matrix4.identity()
            ..translateByDouble(-at.dx * 1.5, -at.dy * 1.5, 0, 1)
            ..scaleByDouble(2.5, 2.5, 1, 1));
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.illustration.label.trim();
    return Material(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            onDoubleTapDown: (details) => doubleTap = details,
            onDoubleTap: _toggleZoom,
            child: InteractiveViewer(
              transformationController: transform,
              minScale: 1,
              maxScale: 6,
              child: Center(
                child: Image.memory(
                  widget.illustration.bytes,
                  fit: BoxFit.contain,
                  semanticLabel: label.isEmpty ? null : label,
                  errorBuilder: (_, e, s) => const Text(
                    'Формат изображения не поддерживается',
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: IconButton(
                tooltip: 'Закрыть иллюстрацию',
                color: Colors.white,
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ),
          ),
          if (label.isNotEmpty)
            SafeArea(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

Future<void> showChapterResources(
  BuildContext context,
  EpubChapter chapter,
) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .8,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Сноски и иллюстрации',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          Text(chapter.title),
          const SizedBox(height: 16),
          if (chapter.footnotes.isEmpty && chapter.illustrations.isEmpty)
            const Text(
              'В этой главе нет доступных встроенных сносок или иллюстраций.',
            ),
          for (final note in chapter.footnotes)
            ListTile(
              leading: const Icon(Icons.notes),
              title: Text('Сноска ${note.label}'),
              subtitle: Text(
                note.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => showBookFootnote(context, note),
            ),
          for (final illustration in chapter.illustrations)
            Card(
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => showBookIllustration(context, illustration),
                child: Column(
                  children: [
                    Image.memory(
                      illustration.bytes,
                      height: 220,
                      cacheWidth: 700,
                      fit: BoxFit.contain,
                      errorBuilder: (_, e, s) => const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('Не удалось показать изображение'),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text('${illustration.label} · увеличить'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  ),
);
