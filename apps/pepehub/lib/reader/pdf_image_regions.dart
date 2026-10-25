import 'dart:ffi';
import 'dart:math' as math;
import 'dart:ui';

import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart' as pdfium;
import 'package:pdfrx/pdfrx.dart';

/// Raster image areas of PDF pages as fractions of the page (top-left origin).
///
/// The dark PDF theme inverts whole pages, which turns photos into negatives.
/// Painting these areas once more with a difference blend restores them.
/// PDFium is not thread-safe, so the page objects are read inside pdfrx's own
/// PDFium worker through [PdfrxEntryFunctions.compute].
class PdfImageRegions {
  final String path;
  final _pages = <int, List<Rect>>{};
  final _loading = <int>{};
  bool _disabled = false, _used = false, _closed = false;

  PdfImageRegions(this.path);

  /// Regions of [pageNumber] (1-based), or null while they are still read.
  /// [onLoaded] runs once the regions become available.
  List<Rect>? regions(int pageNumber, VoidCallback onLoaded) {
    if (_disabled || _closed) return const [];
    final known = _pages[pageNumber];
    if (known != null) return known;
    if (_loading.add(pageNumber)) {
      _used = true;
      PdfrxEntryFunctions.instance
          .compute(_imageRegions, <String, Object?>{
            'path': path,
            'page': pageNumber - 1,
            'module': Pdfrx.pdfiumModulePath,
          })
          .then(
            (value) {
              if (_closed) return;
              if (_pages.length >= 64) _pages.remove(_pages.keys.first);
              _pages[pageNumber] = [
                for (final r in value) Rect.fromLTRB(r[0], r[1], r[2], r[3]),
              ];
              onLoaded();
            },
            onError: (Object _) {
              // Images stay inverted, exactly as before; nothing else breaks.
              _disabled = true;
            },
          )
          .whenComplete(() => _loading.remove(pageNumber));
    }
    return null;
  }

  /// Paints [regions] of a page drawn in [pageRect] so that a later inversion
  /// of the whole viewer restores their original colours.
  static void restore(Canvas canvas, Rect pageRect, List<Rect> regions) {
    if (regions.isEmpty) return;
    final paint = Paint()
      ..color = const Color(0xffffffff)
      ..blendMode = BlendMode.difference;
    for (final r in regions) {
      canvas.drawRect(
        Rect.fromLTRB(
          pageRect.left + r.left * pageRect.width,
          pageRect.top + r.top * pageRect.height,
          pageRect.left + r.right * pageRect.width,
          pageRect.top + r.bottom * pageRect.height,
        ),
        paint,
      );
    }
  }

  /// Releases the worker's copy of the document.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_used) return;
    try {
      await PdfrxEntryFunctions.instance.compute(_closeDocument, path);
    } catch (_) {
      /* The worker may already be stopped with the app. */
    }
  }
}

// Worker isolate state. These statics live inside pdfrx's PDFium worker.
pdfium.PDFium? _library;
final _documents = <String, pdfium.FPDF_DOCUMENT>{};

pdfium.PDFium _pdfium(String? module) =>
    _library ??= pdfium.getPdfium(modulePath: module);

bool _closeDocument(String path) {
  final document = _documents.remove(path);
  if (document != null) _library?.FPDF_CloseDocument(document);
  return true;
}

List<List<double>> _imageRegions(Map<String, Object?> message) {
  final lib = _pdfium(message['module'] as String?);
  final path = message['path'] as String;
  final document = _documents[path] ??= using((arena) {
    final opened = lib.FPDF_LoadDocument(
      path.toNativeUtf8(allocator: arena).cast<Char>(),
      nullptr,
    );
    if (opened == nullptr) throw StateError('PDFium не открыл $path');
    return opened;
  });
  final page = lib.FPDF_LoadPage(document, message['page'] as int);
  if (page == nullptr) return const [];
  try {
    return using((arena) {
      final left = arena<Float>(), bottom = arena<Float>();
      final right = arena<Float>(), top = arena<Float>();
      final matrix = arena<pdfium.FS_MATRIX>();
      final dx = arena<Int>(), dy = arena<Int>();
      // Page-to-device with a large virtual canvas gives page fractions that
      // already include the crop box origin and the page's own rotation.
      const size = 1 << 20;
      final result = <List<double>>[];

      void image(pdfium.FPDF_PAGEOBJECT object, List<List<double>> forms) {
        if (lib.FPDFPageObj_GetBounds(object, left, bottom, right, top) == 0) {
          return;
        }
        var minX = double.infinity, minY = double.infinity;
        var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
        for (final (x0, y0) in [
          (left.value, bottom.value),
          (left.value, top.value),
          (right.value, bottom.value),
          (right.value, top.value),
        ]) {
          // Objects inside form XObjects are in form space; apply the form
          // matrices from the innermost outward.
          var x = x0, y = y0;
          for (final m in forms.reversed) {
            final nx = m[0] * x + m[2] * y + m[4];
            final ny = m[1] * x + m[3] * y + m[5];
            x = nx;
            y = ny;
          }
          if (lib.FPDF_PageToDevice(page, 0, 0, size, size, 0, x, y, dx, dy) ==
              0) {
            return;
          }
          final px = dx.value / size, py = dy.value / size;
          minX = math.min(minX, px);
          maxX = math.max(maxX, px);
          minY = math.min(minY, py);
          maxY = math.max(maxY, py);
        }
        minX = minX.clamp(0.0, 1.0);
        maxX = maxX.clamp(0.0, 1.0);
        minY = minY.clamp(0.0, 1.0);
        maxY = maxY.clamp(0.0, 1.0);
        // Hairlines and specks are not worth a separate layer operation.
        if ((maxX - minX) * (maxY - minY) < .0004) return;
        result.add([minX, minY, maxX, maxY]);
      }

      void visit(
        pdfium.FPDF_PAGEOBJECT object,
        List<List<double>> forms,
        int depth,
      ) {
        if (result.length >= 256) return;
        final type = lib.FPDFPageObj_GetType(object);
        if (type == pdfium.FPDF_PAGEOBJ_IMAGE) {
          image(object, forms);
        } else if (type == pdfium.FPDF_PAGEOBJ_FORM && depth < 8) {
          if (lib.FPDFPageObj_GetMatrix(object, matrix) == 0) return;
          final m = matrix.ref;
          final chain = [
            ...forms,
            [m.a, m.b, m.c, m.d, m.e, m.f],
          ];
          final count = lib.FPDFFormObj_CountObjects(object);
          for (var i = 0; i < count && result.length < 256; i++) {
            final child = lib.FPDFFormObj_GetObject(object, i);
            if (child != nullptr) visit(child, chain, depth + 1);
          }
        }
      }

      final count = lib.FPDFPage_CountObjects(page);
      for (var i = 0; i < count && result.length < 256; i++) {
        final object = lib.FPDFPage_GetObject(page, i);
        if (object != nullptr) visit(object, const [], 0);
      }
      return _merge(result);
    });
  } finally {
    lib.FPDF_ClosePage(page);
  }
}

/// A difference blend applied twice cancels out, so overlapping image areas
/// (tiled scans, a photo over its own background) are merged first.
List<List<double>> _merge(List<List<double>> input) {
  final boxes = [
    for (final r in input) [...r],
  ];
  var merged = true;
  while (merged) {
    merged = false;
    for (var i = 0; i < boxes.length && !merged; i++) {
      for (var j = i + 1; j < boxes.length; j++) {
        final a = boxes[i], b = boxes[j];
        if (a[0] < b[2] && b[0] < a[2] && a[1] < b[3] && b[1] < a[3]) {
          boxes[i] = [
            math.min(a[0], b[0]),
            math.min(a[1], b[1]),
            math.max(a[2], b[2]),
            math.max(a[3], b[3]),
          ];
          boxes.removeAt(j);
          merged = true;
          break;
        }
      }
    }
  }
  return boxes;
}
