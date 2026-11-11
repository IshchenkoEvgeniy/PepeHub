import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'book_image_export.dart';
import 'epub.dart';
import 'image_size.dart';

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

/// Full-screen illustration: pinch or double-tap to zoom, swipe to the
/// neighbouring illustrations of the book, tap to show or hide the tools
/// (save, rotate, background, inverted colours, details).
Future<void> showBookIllustration(
  BuildContext context,
  BookIllustration illustration, {
  List<BookIllustration> gallery = const [],
  String? bookTitle,
}) {
  final list = gallery.isEmpty ? [illustration] : gallery;
  var start = list.indexWhere((e) => identical(e, illustration));
  if (start < 0) {
    start = list.indexWhere((e) => identical(e.bytes, illustration.bytes));
  }
  final images = start < 0 ? [illustration] : list;
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierDismissible: true,
      barrierLabel: 'Закрыть иллюстрацию',
      barrierColor: Colors.black,
      transitionDuration: const Duration(milliseconds: 160),
      reverseTransitionDuration: const Duration(milliseconds: 120),
      pageBuilder: (context, animation, _) => FadeTransition(
        opacity: animation,
        child: _IllustrationViewer(
          images,
          start < 0 ? 0 : start,
          bookTitle: bookTitle,
        ),
      ),
    ),
  );
}

class _IllustrationViewer extends StatefulWidget {
  final List<BookIllustration> images;
  final int initial;
  final String? bookTitle;
  const _IllustrationViewer(this.images, this.initial, {this.bookTitle});
  @override
  State<_IllustrationViewer> createState() => _IllustrationViewerState();
}

class _IllustrationViewerState extends State<_IllustrationViewer> {
  final transform = TransformationController();
  late final pages = PageController(initialPage: widget.initial);
  late int index = widget.initial;
  TapDownDetails? doubleTap;
  bool zoomed = false, tools = true, saving = false, invert = false;
  int turns = 0;

  /// 0 — black, 1 — white, 2 — grey: transparent drawings need a light page.
  int backdrop = 0;
  static const backdrops = [Colors.black, Colors.white, Color(0xff808080)];

  BookIllustration get image => widget.images[index];

  @override
  void initState() {
    super.initState();
    transform.addListener(_zoomChanged);
  }

  @override
  void dispose() {
    transform.removeListener(_zoomChanged);
    transform.dispose();
    pages.dispose();
    super.dispose();
  }

  void _zoomChanged() {
    final value = transform.value.getMaxScaleOnAxis() > 1.01;
    if (value != zoomed) setState(() => zoomed = value);
  }

  void _toggleZoom() {
    final at = doubleTap?.localPosition ?? Offset.zero;
    transform.value = zoomed
        ? Matrix4.identity()
        : (Matrix4.identity()
            ..translateByDouble(-at.dx * 1.5, -at.dy * 1.5, 0, 1)
            ..scaleByDouble(2.5, 2.5, 1, 1));
  }

  void _zoomBy(double factor) {
    final size = MediaQuery.sizeOf(context);
    final scale = (transform.value.getMaxScaleOnAxis() * factor).clamp(1.0, 6.0);
    if (scale <= 1.001) {
      transform.value = Matrix4.identity();
      return;
    }
    final c = size.center(Offset.zero);
    transform.value = Matrix4.identity()
      ..translateByDouble(c.dx * (1 - scale), c.dy * (1 - scale), 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  void _show(int next) {
    if (next < 0 || next >= widget.images.length) return;
    pages.animateToPage(
      next,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => saving = true);
    try {
      final label = image.label.trim();
      final name = bookImageFileName(
        image.bytes,
        book: widget.bookTitle,
        label: label.isEmpty || label.length > 60
            ? 'иллюстрация ${index + 1}'
            : label,
      );
      final saved = await saveBookImage(image.bytes, name);
      if (saved != null) {
        messenger?.showSnackBar(
          SnackBar(content: Text('Изображение сохранено: $name')),
        );
      }
    } catch (e) {
      messenger?.showSnackBar(
        SnackBar(content: Text('Не удалось сохранить изображение: $e')),
      );
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _details() {
    final type = bookImageType(image.bytes);
    final size = imageHeaderSize(image.bytes);
    final kb = image.bytes.length / 1024;
    final label = image.label.trim();
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (context) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Сведения об изображении',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              if (label.isNotEmpty) SelectableText('Подпись: $label'),
              Text('Формат: ${type.label}'),
              if (size != null)
                Text(
                  'Размер: ${size.width.round()} × ${size.height.round()} пикс.',
                ),
              Text(
                'Объём: ${kb >= 1024 ? '${(kb / 1024).toStringAsFixed(1)} МБ' : '${kb.round()} КБ'}',
              ),
              if (widget.images.length > 1)
                Text(
                  'Иллюстрация ${index + 1} из ${widget.images.length} в книге',
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _picture(BookIllustration item) {
    final label = item.label.trim();
    Widget picture = Image.memory(
      item.bytes,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      semanticLabel: label.isEmpty ? null : label,
      errorBuilder: (_, e, s) => const Text(
        'Формат изображения не поддерживается',
        style: TextStyle(color: Colors.white70),
      ),
    );
    if (invert) {
      picture = ColorFiltered(
        colorFilter: const ColorFilter.matrix([
          -1, 0, 0, 0, 255, //
          0, -1, 0, 0, 255, //
          0, 0, -1, 0, 255, //
          0, 0, 0, 1, 0, //
        ]),
        child: picture,
      );
    }
    return RotatedBox(quarterTurns: turns, child: picture);
  }

  @override
  Widget build(BuildContext context) {
    final label = image.label.trim();
    final background = backdrops[backdrop];
    final many = widget.images.length > 1;
    final bar = Colors.black.withValues(alpha: .55);
    Widget action(
      String tooltip,
      IconData icon,
      VoidCallback? onTap, {
      bool on = false,
      Key? key,
    }) => IconButton(
      key: key,
      tooltip: tooltip,
      color: on ? Colors.amberAccent : Colors.white,
      disabledColor: Colors.white38,
      onPressed: onTap,
      icon: Icon(icon),
    );
    return Material(
      color: background,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
              _show(index + 1),
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
              _show(index - 1),
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.maybePop(context),
        },
        child: Focus(
          autofocus: true,
          child: Stack(
            fit: StackFit.expand,
            children: [
              PageView.builder(
                controller: pages,
                // A zoomed picture pans; swiping turns only at normal size.
                physics: zoomed
                    ? const NeverScrollableScrollPhysics()
                    : const PageScrollPhysics(),
                itemCount: widget.images.length,
                onPageChanged: (value) => setState(() {
                  index = value;
                  turns = 0;
                  transform.value = Matrix4.identity();
                }),
                itemBuilder: (context, i) => GestureDetector(
                  onTap: () => setState(() => tools = !tools),
                  onDoubleTapDown: (details) => doubleTap = details,
                  onDoubleTap: _toggleZoom,
                  child: i == index
                      ? InteractiveViewer(
                          transformationController: transform,
                          minScale: 1,
                          maxScale: 6,
                          child: Center(child: _picture(widget.images[i])),
                        )
                      : Center(child: _picture(widget.images[i])),
                ),
              ),
              if (many && !zoomed && tools) ...[
                if (index > 0)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: action(
                      'Предыдущая иллюстрация',
                      Icons.chevron_left,
                      () => _show(index - 1),
                    ),
                  ),
                if (index < widget.images.length - 1)
                  Align(
                    alignment: Alignment.centerRight,
                    child: action(
                      'Следующая иллюстрация',
                      Icons.chevron_right,
                      () => _show(index + 1),
                    ),
                  ),
              ],
              AnimatedOpacity(
                opacity: tools ? 1 : 0,
                duration: const Duration(milliseconds: 150),
                child: IgnorePointer(
                  ignoring: !tools,
                  child: Column(
                    children: [
                      Material(
                        color: bar,
                        child: SafeArea(
                          bottom: false,
                          child: Row(
                            children: [
                              action(
                                'Закрыть иллюстрацию',
                                Icons.close,
                                () => Navigator.pop(context),
                              ),
                              Expanded(
                                child: Text(
                                  many
                                      ? '${index + 1} из ${widget.images.length}'
                                      : (widget.bookTitle ?? ''),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ),
                              action(
                                'Сведения об изображении',
                                Icons.info_outline,
                                _details,
                              ),
                            ],
                          ),
                        ),
                      ),
                      const Spacer(),
                      Material(
                        color: bar,
                        child: SafeArea(
                          top: false,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (label.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    20,
                                    10,
                                    20,
                                    0,
                                  ),
                                  child: Text(
                                    label,
                                    textAlign: TextAlign.center,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                    ),
                                  ),
                                ),
                              SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    action(
                                      'Сохранить изображение',
                                      Icons.download_outlined,
                                      saving ? null : _save,
                                      key: const ValueKey(
                                        'illustration-save',
                                      ),
                                    ),
                                    action(
                                      'Повернуть',
                                      Icons.rotate_right,
                                      () => setState(
                                        () => turns = (turns + 1) % 4,
                                      ),
                                    ),
                                    action(
                                      'Уменьшить',
                                      Icons.zoom_out,
                                      zoomed ? () => _zoomBy(1 / 1.5) : null,
                                    ),
                                    action(
                                      'Увеличить',
                                      Icons.zoom_in,
                                      () => _zoomBy(1.5),
                                    ),
                                    action(
                                      'Фон: чёрный / белый / серый',
                                      Icons.contrast,
                                      () => setState(
                                        () => backdrop = (backdrop + 1) % 3,
                                      ),
                                      on: backdrop != 0,
                                    ),
                                    action(
                                      'Инвертировать цвета',
                                      Icons.invert_colors,
                                      () => setState(() => invert = !invert),
                                      on: invert,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
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
