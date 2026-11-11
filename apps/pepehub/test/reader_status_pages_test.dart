import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/reader/book_image_export.dart';
import 'package:pepehub/reader/reader_layout.dart';
import 'package:pepehub/reader/reader_status_line.dart';
import 'package:pepehub/ui/pepe_widgets.dart';

void main() {
  test('reader pages use the same page size as the statistics', () {
    const length = 52 * pepeCharsPerPage - 100;
    expect(readerBookPages(length, 0), (page: 1, count: 52));
    expect(readerBookPages(length, 14 * pepeCharsPerPage + 5).page, 15);
    expect(readerBookPages(length, length).page, 52);
    // The statistics describe the same book as "≈ 52 pages".
    expect(pepePages(length), '≈ 52 стр.');
    expect(readerBookPages(0, 0), (page: 1, count: 1));
  });

  test('the font can be made smaller than 12', () {
    expect(ReaderPreferences.fromJson({'size': 8}).size, 8);
    expect(
      ReaderPreferences.fromJson({'size': 2}).size,
      ReaderPreferences.minSize,
    );
  });

  test('the navigation bar setting is kept', () {
    final value = const ReaderPreferences().copy(systemNavigation: true);
    expect(ReaderPreferences.fromJson(value.toJson()).systemNavigation, true);
    expect(const ReaderPreferences().systemNavigation, false);
  });

  test('saved illustrations get the right file type', () {
    final png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0, 0, 0, 0]);
    final jpeg = Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0]);
    expect(bookImageType(png).mime, 'image/png');
    expect(bookImageType(jpeg).extension, 'jpg');
    expect(
      bookImageFileName(jpeg, book: 'Хоббит', label: 'Карта: Глушь?'),
      'Хоббит — Карта Глушь.jpg',
    );
  });
}
