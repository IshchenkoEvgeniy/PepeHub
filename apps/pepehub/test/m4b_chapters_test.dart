import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/audio/m4b_chapters.dart';

List<int> u32(int v) {
  final b = ByteData(4)..setUint32(0, v);
  return b.buffer.asUint8List();
}

List<int> u64(int v) {
  final b = ByteData(8)..setUint64(0, v);
  return b.buffer.asUint8List();
}

List<int> box(String type, List<int> data) => [
  ...u32(8 + data.length),
  ...type.codeUnits,
  ...data,
];
void main() {
  test('Nero chapter timestamps use 100ns units', () async {
    final name = utf8.encode('Вступление');
    final movie = Uint8List.fromList(
      box(
        'udta',
        box('chpl', [
          1,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          2,
          ...u64(0),
          name.length,
          ...name,
          ...u64(125000000),
          1,
          66,
        ]),
      ),
    );
    final chapters = await parseChapterMovie(
      movie,
      (_, _) async => Uint8List(0),
    );
    expect(chapters.map((c) => c.startMs), [0, 12500]);
    expect(chapters.first.title, 'Вступление');
  });
  test(
    'QuickTime referenced chapter track reads text samples after moov scan',
    () async {
      final root = await Directory.systemTemp.createTemp('pepehub-chapters-');
      try {
        final one = utf8.encode('Глава 1'), two = utf8.encode('Глава 2');
        final a = [0, one.length, ...one], b = [0, two.length, ...two];
        final tkhd = [...List.filled(12, 0), ...u32(2), ...List.filled(8, 0)];
        final mdhd = [
          ...List.filled(12, 0),
          ...u32(1000),
          ...List.filled(8, 0),
        ];
        final table = [
          ...box('stsz', [
            ...u32(0),
            ...u32(0),
            ...u32(2),
            ...u32(a.length),
            ...u32(b.length),
          ]),
          ...box('stts', [...u32(0), ...u32(1), ...u32(2), ...u32(1500)]),
          ...box('stsc', [
            ...u32(0),
            ...u32(1),
            ...u32(1),
            ...u32(2),
            ...u32(1),
          ]),
          ...box('stco', [...u32(0), ...u32(1), ...u32(8)]),
        ];
        final movie = [
          ...box('trak', box('tref', box('chap', u32(2)))),
          ...box('trak', [
            ...box('tkhd', tkhd),
            ...box('mdia', [
              ...box('mdhd', mdhd),
              ...box('minf', box('stbl', table)),
            ]),
          ]),
        ];
        final file = File('${root.path}/book.m4b');
        await file.writeAsBytes([
          ...box('mdat', [...a, ...b]),
          ...box('moov', movie),
        ]);
        final chapters = await readM4bChapters(file.path);
        expect(chapters.map((c) => c.title), ['Глава 1', 'Глава 2']);
        expect(chapters.map((c) => c.startMs), [0, 1500]);
        await file.rename('${root.path}/closed.m4b');
        final invalid = Uint8List.fromList(
          box('udta', box('chpl', [1, 0, 0, 0, 0, 0, 0, 0, 2, ...u64(0), 250])),
        );
        await expectLater(
          parseChapterMovie(invalid, (_, _) async => Uint8List(0)),
          throwsFormatException,
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
