import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/media/embedded_artwork.dart';

List<int> atom(String name, List<int> body) {
  final bytes = Uint8List(8 + body.length);
  ByteData.sublistView(bytes).setUint32(0, bytes.length);
  bytes.setRange(4, 8, name.codeUnits);
  bytes.setRange(8, bytes.length, body);
  return bytes;
}

void main() {
  test(
    'extracts ID3 APIC and nested M4B cover; rejects truncated metadata',
    () async {
      final root = await Directory.systemTemp.createTemp('pepehub-tags-');
      try {
        final file = File('${root.path}/book.mp3');
        final picture = [137, 80, 78, 71, 1, 2, 3];
        final body = [0, ...'image/png'.codeUnits, 0, 3, 0, ...picture];
        final frame = [
          ...'APIC'.codeUnits,
          0,
          0,
          0,
          body.length,
          0,
          0,
          ...body,
        ];
        await file.writeAsBytes([
          ...'ID3'.codeUnits,
          3,
          0,
          0,
          0,
          0,
          0,
          frame.length,
          ...frame,
        ]);
        expect(await embeddedArtwork(file.path), picture);
        await file.writeAsBytes(
          atom(
            'moov',
            atom(
              'udta',
              atom('meta', [
                0,
                0,
                0,
                0,
                ...atom(
                  'ilst',
                  atom(
                    'covr',
                    atom('data', [0, 0, 0, 13, 0, 0, 0, 0, ...picture]),
                  ),
                ),
              ]),
            ),
          ),
        );
        expect(await embeddedArtwork(file.path), picture);
        await file.writeAsBytes([0, 0, 255, 255, ...'moov'.codeUnits, 0, 0]);
        expect(await embeddedArtwork(file.path), isNull);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
