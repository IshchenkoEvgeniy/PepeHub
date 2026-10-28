import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'reader_appearance.dart';

/// Small original-colour raster detects margins for text and scanned pages.
/// Fractions use top-left coordinates; the PDF itself is never modified.
Rect? pdfInkBounds(Uint8List bgra, int width, int height) {
  if (width <= 0 || height <= 0 || bgra.length < width * height * 4) {
    return null;
  }
  var left = width, top = height, right = -1, bottom = -1;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 4;
      if (bgra[i + 3] > 32 &&
          (bgra[i] < 240 || bgra[i + 1] < 240 || bgra[i + 2] < 240)) {
        left = math.min(left, x);
        right = math.max(right, x);
        top = math.min(top, y);
        bottom = math.max(bottom, y);
      }
    }
  }
  if (right < left || bottom < top) return null;
  return Rect.fromLTRB(
    (left / width - .02).clamp(0, 1),
    (top / height - .02).clamp(0, 1),
    ((right + 1) / width + .02).clamp(0, 1),
    ((bottom + 1) / height + .02).clamp(0, 1),
  );
}

class PdfContentBounds {
  final _cache = <int, Future<Rect?>>{};
  Future<Rect?> forPage(PdfPage page) =>
      _cache.putIfAbsent(page.pageNumber, () async {
        try {
          final scale = 384 / math.max(page.width, page.height);
          final width = math.max(1, (page.width * scale).round());
          final height = math.max(1, (page.height * scale).round());
          final image = await page.render(
            width: width,
            height: height,
            fullWidth: width.toDouble(),
            fullHeight: height.toDouble(),
            backgroundColor: 0xffffffff,
          );
          if (image == null) return null;
          try {
            return pdfInkBounds(image.pixels, image.width, image.height);
          } finally {
            image.dispose();
          }
        } catch (_) {
          _cache.remove(page.pageNumber);
          rethrow;
        }
      });
}

class PdfPageTools extends StatefulWidget {
  final PdfViewerController controller;
  final bool locked, initialCrop;
  final int page;
  final Future<void> Function(bool) onCrop;
  const PdfPageTools({
    super.key,
    required this.controller,
    required this.locked,
    required this.page,
    required this.initialCrop,
    required this.onCrop,
  });
  @override
  State<PdfPageTools> createState() => _PdfPageToolsState();
}

class _PdfPageToolsState extends State<PdfPageTools> {
  late bool cropped = widget.initialCrop;
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(changed);
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(changed);
    super.dispose();
  }

  Future<void> crop(bool next) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.onCrop(next);
      if (mounted) setState(() => cropped = next);
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Не удалось определить поля страницы');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final enabled = controller.isReady && !widget.locked && !busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ReaderValueStepper(
          label: 'Масштаб',
          value: controller.isReady
              ? '${(controller.currentZoom * 100).round()}%'
              : '—',
          decreaseLabel: 'Уменьшить масштаб PDF',
          increaseLabel: 'Увеличить масштаб PDF',
          onDecrease: enabled ? () => controller.zoomDown() : null,
          onIncrease: enabled ? () => controller.zoomUp() : null,
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.fit_screen),
              label: const Text('По ширине'),
              onPressed: enabled
                  ? () => controller.goTo(
                      controller.calcMatrixFitWidthForPage(
                        pageNumber: widget.page,
                      ),
                    )
                  : null,
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.crop_portrait),
              label: const Text('Вся страница'),
              onPressed: enabled
                  ? () => controller.goTo(
                      controller.calcMatrixForFit(pageNumber: widget.page),
                    )
                  : null,
            ),
          ],
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('Обрезать белые поля'),
          subtitle: busy ? const Text('Определение границ…') : null,
          value: cropped,
          onChanged: enabled ? crop : null,
        ),
        if (widget.locked)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              'Для изменения масштаба отключите фиксацию ширины в меню PDF.',
            ),
          ),
        if (error != null)
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        const SizedBox(height: 12),
      ],
    );
  }
}
