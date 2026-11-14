import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/reader/book_image_export.dart';
import 'package:pepehub/reader/reader_layout.dart';
import 'package:pepehub/reader/reader_status_line.dart';
import 'package:pepehub/ui/pepe_widgets.dart';

void main() {
  screenTests();
  test('reader pages use the same page size as the statistics', () {
    const length = 52 * pepeCharsPerPage - 100;
    expect(readerBookPages(length, 0), (page: 1, count: 52));
    expect(readerBookPages(length, 14 * pepeCharsPerPage + 5).page, 15);
    expect(readerBookPages(length, length).page, 52);
    // The statistics describe the same book as "≈ 52 pages".
    expect(pepePages(length), '≈ 52 стр.');
    expect(readerBookPages(0, 0), (page: 1, count: 1));
  });

  test('measured screens replace the statistics page in the reader', () {
    // 600 characters fit on a screen: 100 000 characters are 167 screens and
    // each page turn moves the number by one.
    expect(readerBookPages(100000, 0, charsPerScreen: 600), (
      page: 1,
      count: 167,
    ));
    expect(readerBookPages(100000, 600, charsPerScreen: 600).page, 2);
    expect(readerBookPages(100000, 1199, charsPerScreen: 600).page, 2);
    expect(readerBookPages(100000, 100000, charsPerScreen: 600).page, 167);
    // An unmeasured or broken layout falls back to the statistics page.
    expect(
      readerBookPages(100000, 0, charsPerScreen: 0),
      readerBookPages(100000, 0),
    );
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

void screenTests() {
  test('laid-out screens are counted exactly, one per page turn', () {
    // Two chapters of 2 000 characters, ~600 a screen. Chapter 0 is laid out
    // in screens of different length, with a short chapter end.
    final laid = <ReaderScreen>[
      (chapter: 0, start: 0, end: 700),
      (chapter: 0, start: 700, end: 1200),
      (chapter: 0, start: 1200, end: 1900),
      (chapter: 0, start: 1900, end: 2000),
    ];
    final screens = ReaderScreens(
      const [2000, 2000],
      laid,
      complete: false,
      size: 600,
    );
    // Chapter 0: 4 real screens; chapter 1 is not laid out: ceil(2000/600).
    expect(screens.count, 4 + 4);
    expect([for (final s in laid) screens.page(0, s.start)], [1, 2, 3, 4]);
    // Inside a screen the number stays.
    expect(screens.page(0, 1199), 2);
    // The next chapter starts on its own page.
    expect(screens.page(1, 0), 5);
    expect(screens.page(1, 1999), 8);
  });

  test('a window in the middle of a chapter keeps page numbers in order', () {
    final screens = ReaderScreens(
      const [6000],
      const [
        (chapter: 0, start: 3000, end: 3500),
        (chapter: 0, start: 3500, end: 4100),
      ],
      complete: false,
      size: 600,
    );
    // 5 estimated screens before the window, 2 laid out, 4 estimated after.
    expect(screens.count, 5 + 2 + 4);
    expect(screens.page(0, 0), 1);
    expect(screens.page(0, 2999), 5);
    expect(screens.page(0, 3000), 6);
    expect(screens.page(0, 3500), 7);
    expect(screens.page(0, 4100), 8);
    expect(screens.page(0, 6000), 11);
  });

  test('a complete layout gives the real number of screens', () {
    final screens = ReaderScreens(
      const [1000, 300],
      const [
        (chapter: 0, start: 0, end: 450),
        (chapter: 0, start: 450, end: 1000),
        (chapter: 1, start: 0, end: 300),
      ],
      complete: true,
      size: 600,
    );
    expect(screens.count, 3);
    expect(screens.page(1, 299), 3);
  });
}
