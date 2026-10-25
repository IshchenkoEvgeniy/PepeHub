import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/reader/pdf_image_regions.dart';
import 'package:pepehub/reader/pdf_support.dart';
import 'package:pepehub/reader/reading_library.dart';

/// Page 1: a 1x1 image scaled to the top-right quarter of a 200x100 page.
/// Page 2: the same image inside a form XObject placed at (20, 10).
Uint8List _imagePdf() {
  String stream(String dictionary, String data) =>
      '<< $dictionary /Length ${latin1.encode(data).length} >>\n'
      'stream\n$data\nendstream';
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R 6 0 R] /Count 2 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] '
        '/Resources << /XObject << /Im1 4 0 R >> >> /Contents 5 0 R >>',
    stream(
      '/Type /XObject /Subtype /Image /Width 1 /Height 1 '
          '/ColorSpace /DeviceRGB /BitsPerComponent 8',
      '\u00ff\u0000\u0000',
    ),
    stream('', 'q 100 0 0 50 100 50 cm /Im1 Do Q'),
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] '
        '/Resources << /XObject << /Fm1 7 0 R >> >> /Contents 8 0 R >>',
    stream(
      '/Type /XObject /Subtype /Form /BBox [0 0 200 100] '
          '/Resources << /XObject << /Im1 4 0 R >> >>',
      'q 50 0 0 40 0 0 cm /Im1 Do Q',
    ),
    stream('', 'q 1 0 0 1 20 10 cm /Fm1 Do Q'),
  ];
  final out = StringBuffer('%PDF-1.4\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(latin1.encode(out.toString()).length);
    out.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = latin1.encode(out.toString()).length;
  out.write('xref\n0 ${objects.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets) {
    out.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  out.write(
    'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
    'startxref\n$xref\n%%EOF\n',
  );
  return latin1.encode(out.toString());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final pdfium = Platform.environment['PEPEHUB_PDFIUM'];
  setUpAll(() {
    if (pdfium != null) {
      Pdfrx.pdfiumModulePath = pdfium;
      Pdfrx.cacheDirectoryPath = Directory.systemTemp.path;
    }
  });

  test('a plain value under "reader:" does not hide the library', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = Repository(db);
    final library = ReadingLibrary(repo);
    await repo.setMeta('reader:${'a' * 64}', jsonEncode({'chapter': 2}));
    // Written by 0.23.0 and synced/left on devices.
    await repo.setMeta('reader:pdf-mode', 'scroll');
    await repo.setMeta('reader:broken', '{');
    final positions = await library.entries('reader:');
    expect(positions.keys, ['a' * 64]);
    await migrateLegacyPdfMode(repo);
    expect(await repo.meta('reader:pdf-mode'), isNull);
    expect(await repo.meta('pdf-reader-mode'), 'scroll');
    await migrateLegacyPdfMode(repo);
    expect(await repo.meta('pdf-reader-mode'), 'scroll');
  });

  test('image areas are found on the page and inside form XObjects', () async {
    final directory = await Directory.systemTemp.createTemp('pdf-images-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/images.pdf');
    await file.writeAsBytes(_imagePdf());
    final document = await openLocalPdf(file.path);
    final regions = PdfImageRegions(file.path);
    try {
      Future<List<Rect>> read(int page) async {
        final loaded = Completer<void>();
        final first = regions.regions(page, loaded.complete);
        if (first != null) return first;
        await loaded.future.timeout(const Duration(seconds: 10));
        return regions.regions(page, () {})!;
      }

      void near(Rect actual, Rect expected) {
        for (final (a, b) in [
          (actual.left, expected.left),
          (actual.top, expected.top),
          (actual.right, expected.right),
          (actual.bottom, expected.bottom),
        ]) {
          expect(a, closeTo(b, .01));
        }
      }

      near((await read(1)).single, const Rect.fromLTRB(.5, 0, 1, .5));
      near((await read(2)).single, const Rect.fromLTRB(.1, .5, .35, .9));
    } finally {
      await regions.close();
      await document.dispose();
    }
  }, skip: pdfium == null);
}
