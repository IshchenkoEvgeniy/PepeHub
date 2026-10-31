import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

/// Limits a full-page raster to 4 megapixels / 3072 pixels on either side.
double pdfRenderScale(double width, double height, double requested) {
  if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
    return 1;
  }
  return math.min(
    requested,
    math.min(
      3072 / math.max(width, height),
      math.sqrt(4000000 / (width * height)),
    ),
  );
}

/// Fixed document X and zoom, free vertical reading, with safe edge clamping.
Matrix4 lockedPdfMatrix(
  Matrix4 proposed,
  Size viewport,
  Size document, {
  required double x,
  required double zoom,
}) {
  final y = proposed.calcPosition(viewport).dy;
  double clamp(double value, double view, double size) => size <= view / zoom
      ? size / 2
      : value.clamp(view / zoom / 2, size - view / zoom / 2);
  return Matrix4.identity()
    ..setEntry(0, 0, zoom)
    ..setEntry(1, 1, zoom)
    ..setEntry(2, 2, zoom)
    ..setEntry(
      0,
      3,
      viewport.width / 2 - clamp(x, viewport.width, document.width) * zoom,
    )
    ..setEntry(
      1,
      3,
      viewport.height / 2 - clamp(y, viewport.height, document.height) * zoom,
    );
}

/// A small inactive cache plus every visible annotated page. Visible glyphs
/// must not evict each other while the viewer is zoomed out.
void trimPdfGlyphCache<T>(
  Map<int, T> cache,
  Set<int> visible, {
  int maxPages = 8,
}) {
  for (final page in cache.keys.toList()) {
    if (cache.length <= maxPages) break;
    if (!visible.contains(page)) cache.remove(page);
  }
}
