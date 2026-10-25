import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:pdfrx/pdfrx.dart';

import 'epub.dart';
import 'reader_layout.dart';

Future<void> validatePdf(String path) async {
  final document = await openLocalPdf(path);
  await document.dispose();
}

/// A bounded thumbnail, regardless of the source page's physical dimensions.
Future<Uint8List> pdfCover(PdfDocument document) async {
  final page = document.pages.first;
  final longest = page.width > page.height ? page.width : page.height;
  if (!longest.isFinite || longest <= 0) {
    throw const FormatException('Некорректный размер страницы PDF');
  }
  final rendered = await page.render(
    fullWidth: (page.width * 600 / longest).clamp(1, 600),
    fullHeight: (page.height * 600 / longest).clamp(1, 600),
  );
  if (rendered == null) throw StateError('Не удалось получить обложку PDF');
  try {
    final image = await rendered.createImage();
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) throw StateError('Не удалось сохранить обложку PDF');
      return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
    } finally {
      image.dispose();
    }
  } finally {
    rendered.dispose();
  }
}

/// Use exactly the viewer's structured UTF-16 text, so selection anchors also
/// work in the shared reflow reader. Do not retain glyph rectangles for a book.
Future<ReaderDocument> pdfReadingDocument(
  PdfDocument document,
  String title, {
  bool Function()? cancelled,
  void Function(int)? onProgress,
  int maxCharacters = 2000000,
}) async {
  if (document.permissions?.allowsCopying == false) {
    throw const FormatException('Автор PDF запретил извлечение текста');
  }
  final chapters = <EpubChapter>[];
  var length = 0;
  for (final page in document.pages) {
    if (cancelled?.call() == true) throw StateError('Просмотрщик закрыт');
    final text = (await page.loadStructuredText()).fullText;
    length += text.length;
    if (length > maxCharacters) {
      throw const FormatException(
        'Для текстового режима слишком много текста. Продолжайте читать оригинал PDF — поиск и заметки доступны там.',
      );
    }
    chapters.add(
      EpubChapter('pdf:${page.pageNumber}', 'Страница ${page.pageNumber}', [
        text,
      ]),
    );
    onProgress?.call(page.pageNumber);
    // Allow UI input/cancellation while indexing a large document.
    await Future<void>.delayed(Duration.zero);
  }
  return ReaderDocument(EpubBook(title, const [], chapters));
}

Map<String, dynamic> pdfTextIndex(ReaderDocument document) => {
  'chapters': [for (final c in document.book.chapters) c.title],
  'starts': document.starts,
  'lengths': [for (final t in document.texts) t.length],
  'paragraphStarts': [
    for (final _ in document.texts) [0],
  ],
  'length': document.length,
  'pdfPages': document.texts.length,
};

/// Compact statistics index: retain integer offsets, never the entire text.
Future<Map<String, dynamic>?> pdfStatisticsIndex(
  PdfDocument document, {
  required bool Function() cancelled,
  Map<String, dynamic>? partial,
  Future<void> Function(Map<String, dynamic>)? onProgress,
}) async {
  if (document.permissions?.allowsCopying == false) return null;
  final starts = <int>[], lengths = <int>[];
  var total = 0;
  final savedLengths = partial?['lengths'];
  if (partial?['pdfPages'] == document.pages.length &&
      partial?['pdfTextIndexVersion'] == 1 &&
      savedLengths is List &&
      savedLengths.length <= document.pages.length &&
      savedLengths.every((length) => length is int && length >= 0)) {
    for (final length in savedLengths.cast<int>()) {
      starts.add(total);
      lengths.add(length);
      total += length;
    }
  }
  Map<String, dynamic> snapshot() => {
    'pdfPages': document.pages.length,
    'length': total,
    'starts': starts.toList(),
    'lengths': lengths.toList(),
    'pdfTextIndexVersion': 1,
  };
  var checkpointPages = lengths.length;
  Future<void> checkpoint() async {
    if (lengths.length == checkpointPages) return;
    await onProgress?.call(snapshot());
    checkpointPages = lengths.length;
  }

  for (final page in document.pages.skip(lengths.length)) {
    if (cancelled()) {
      await checkpoint();
      return null;
    }
    final length = (await page.loadStructuredText()).fullText.length;
    starts.add(total);
    lengths.add(length);
    total += length;
    if (lengths.length - checkpointPages >= 32) await checkpoint();
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  if (cancelled()) {
    await checkpoint();
    return null;
  }
  return snapshot();
}

Future<PdfDocument> openLocalPdf(String path) async {
  await pdfrxFlutterInitialize();
  final document = await PdfDocument.openFile(
    path,
    passwordProvider: () async => null,
  );
  try {
    if (document.pages.isEmpty || document.pages.length > 20000) {
      throw const FormatException('Недопустимое число страниц PDF');
    }
    return document;
  } catch (_) {
    await document.dispose();
    rethrow;
  }
}
