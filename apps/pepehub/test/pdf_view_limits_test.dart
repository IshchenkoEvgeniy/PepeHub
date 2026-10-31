import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:pepehub/reader/pdf_view_limits.dart';

void main() {
  test('zoomed out annotated pages retain all visible glyphs and trim after leaving view', () {
    final cache = {for (var n = 1; n <= 16; n++) n: 'glyphs-$n'};
    trimPdfGlyphCache(cache, {for (var n = 1; n <= 12; n++) n});
    expect(cache.keys.toSet(), {for (var n = 1; n <= 12; n++) n});
    trimPdfGlyphCache(cache, {1, 2});
    expect(cache.length, 8);
    expect(cache.keys, containsAll([1, 2]));
  });
  test('large page raster allocation is bounded by area and longest edge', () {
    for (final size in [
      const Size(10000, 20000),
      const Size(50000, 100),
      const Size(600, 800),
    ]) {
      final scale = pdfRenderScale(size.width, size.height, 10);
      expect(
        size.width * size.height * scale * scale,
        lessThanOrEqualTo(4000001),
      );
      expect(size.longestSide * scale, lessThanOrEqualTo(3072));
    }
    expect(pdfRenderScale(600, 800, .5), .5);
  });
  test(
    'horizontal lock preserves X and zoom while vertical position changes',
    () {
      const viewport = Size(400, 600), document = Size(1000, 10000);
      final dragged = Matrix4.identity()
        ..setEntry(0, 0, 3)
        ..setEntry(1, 1, 3)
        ..setEntry(0, 3, -900)
        ..setEntry(1, 3, -2100);
      final locked = lockedPdfMatrix(
        dragged,
        viewport,
        document,
        x: 350,
        zoom: 2,
      );
      expect(locked.zoom, 2);
      expect(locked.calcPosition(viewport).dx, 350);
      expect(
        locked.calcPosition(viewport).dy,
        dragged.calcPosition(viewport).dy,
      );
      final small = lockedPdfMatrix(
        dragged,
        viewport,
        const Size(100, 100),
        x: 900,
        zoom: 1,
      );
      expect(small.calcPosition(viewport), const Offset(50, 50));
    },
  );
}
