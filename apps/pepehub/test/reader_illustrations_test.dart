import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/reader/epub.dart';
import 'package:pepehub/reader/image_size.dart';
import 'package:pepehub/reader/reader_layout.dart';
import 'package:pepehub/reader/reader_viewport.dart';

Future<Uint8List> _png(WidgetTester tester, int width, int height) async =>
    (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint()..color = const Color(0xffffffff),
      );
      final image = await recorder.endRecording().toImage(width, height);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data!.buffer.asUint8List();
    }))!;

const _before = 'Перед рисунком идёт обычный абзац текста. ';
const _after = 'После рисунка стоит подпись и продолжение главы. ';

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('image sizes come from the file header without decoding', (
    tester,
  ) async {
    expect(imageHeaderSize(await _png(tester, 600, 90)), const Size(600, 90));
    final jpeg = Uint8List.fromList([
      0xff, 0xd8, // start of image
      0xff, 0xe0, 0x00, 0x04, 0x00, 0x00, // APP0 segment, 2 bytes of data
      0xff, 0xc0, 0x00, 0x11, 0x08, // baseline frame, 8-bit samples
      0x01, 0x2c, // height 300
      0x02, 0x58, // width 600
      0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    ]);
    expect(imageHeaderSize(jpeg), const Size(600, 300));
    final gif = Uint8List.fromList([
      ...'GIF89a'.codeUnits,
      0x20, 0x00, // width 32
      0x10, 0x00, // height 16
      0x00, 0x00, 0x00,
    ]);
    expect(imageHeaderSize(gif), const Size(32, 16));
    expect(imageHeaderSize(Uint8List.fromList('<svg/>'.codeUnits)), isNull);
    expect(imageHeaderSize(Uint8List.fromList([0x89, 0x50])), isNull);
  });

  for (final paged in [true, false]) {
    testWidgets(
      'a wide figure keeps its proportions (paged=$paged) and opens on tap',
      (tester) async {
        tester.view.physicalSize = const Size(390, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final strip = await _png(tester, 600, 90);
        final text = '${_before * 4}\n\n${_after * 4}';
        final opened = <BookIllustration>[];
        final controller = ReaderViewportController();
        await tester.pumpWidget(
          MaterialApp(
            home: Material(
              child: ReaderViewport(
                controller: controller,
                text: text,
                style: const TextStyle(fontSize: 18, height: 1.4),
                scaler: TextScaler.noScaling,
                width: 390,
                height: 800,
                margin: 20,
                anchor: 0,
                scrolling: !paged,
                compactFlow: !paged,
                firstChapter: true,
                lastChapter: true,
                preferences: const ReaderPreferences(),
                illustrations: [
                  BookIllustration(
                    'Рис. 1',
                    strip,
                    offset: text.indexOf('\n\n') + 2,
                  ),
                ],
                onImage: opened.add,
                onPosition: (_) {},
                onChapter: (_) {},
              ),
            ),
          ),
        );
        await _settle(tester);
        final image = find.byType(Image);
        expect(image, findsOneWidget);
        // 600×90 in a 350 px column: full width, 1/6.67 of it in height —
        // no box of empty space around a narrow strip.
        final size = tester.getSize(image);
        expect(size.width, closeTo(350, .5));
        expect(size.height, closeTo(350 * 90 / 600, .5));
        if (paged) {
          // The figure shares its screen with the text before and after it.
          expect(controller.pageInfo.value?.count, 1);
        }
        await tester.tapAt(tester.getCenter(image));
        await tester.pump();
        expect(opened.single.label, 'Рис. 1');
        // A side tap over the picture still turns pages instead of opening.
        final rect = tester.getRect(image);
        await tester.tapAt(Offset(rect.left + 4, rect.center.dy));
        await tester.pump();
        expect(opened, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('a small picture is never enlarged past its own size', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final icon = await _png(tester, 40, 40);
    final tall = await _png(tester, 300, 3000);
    const text = 'Значок и схема.\n\nТекст после.';
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: ReaderViewport(
            text: text,
            style: const TextStyle(fontSize: 18, height: 1.4),
            scaler: TextScaler.noScaling,
            width: 390,
            height: 800,
            margin: 20,
            anchor: 0,
            scrolling: true,
            compactFlow: true,
            firstChapter: true,
            lastChapter: true,
            preferences: const ReaderPreferences(),
            illustrations: [
              BookIllustration('Значок', icon, offset: 0),
              BookIllustration('Схема', tall, offset: 17),
            ],
            onPosition: (_) {},
            onChapter: (_) {},
          ),
        ),
      ),
    );
    await _settle(tester);
    final images = find.byType(Image);
    expect(tester.getSize(images.first), const Size(40, 40));
    // A very tall figure fits the screen height instead of running past it.
    expect(tester.getSize(images.last).height, lessThan(800));
    expect(tester.takeException(), isNull);
  });
}
