import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle, FontLoader;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/reader/reader_fonts.dart';
import 'package:pepehub/reader/reader_layout.dart';

// Inspect the actual font cmap: a fallback font rendering the same letter
// would hide missing Ukrainian glyphs in a screenshot-only test.
bool hasGlyph(Uint8List bytes, int code) {
  final data = ByteData.sublistView(bytes);
  int u16(int at) => data.getUint16(at);
  int u32(int at) => data.getUint32(at);
  var cmap = 0;
  for (var i = 0; i < u16(4); i++) {
    final at = 12 + i * 16;
    if (ascii.decode(bytes.sublist(at, at + 4)) == 'cmap') {
      cmap = u32(at + 8);
      break;
    }
  }
  if (cmap == 0) return false;
  for (var i = 0; i < u16(cmap + 2); i++) {
    final table = cmap + u32(cmap + 4 + i * 8 + 4);
    final format = u16(table);
    if (format == 12) {
      for (var j = 0; j < u32(table + 12); j++) {
        final group = table + 16 + j * 12;
        if (u32(group) <= code && code <= u32(group + 4)) {
          if (u32(group + 8) + code - u32(group) != 0) return true;
        }
      }
    } else if (format == 4 && code <= 0xffff) {
      final count = u16(table + 6) ~/ 2;
      final ends = table + 14;
      final starts = ends + count * 2 + 2;
      final deltas = starts + count * 2;
      final ranges = deltas + count * 2;
      for (var j = 0; j < count; j++) {
        if (u16(starts + j * 2) <= code && code <= u16(ends + j * 2)) {
          final range = u16(ranges + j * 2);
          final glyph = range == 0
              ? code
              : u16(ranges + j * 2 + range + (code - u16(starts + j * 2)) * 2);
          if ((range == 0 || glyph != 0) &&
              ((glyph + u16(deltas + j * 2)) & 0xffff) != 0) {
            return true;
          }
        }
      }
    }
  }
  return false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('multilingual font proof with actual offline faces', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() => rootBundle.evict('FontManifest.json'));
    final key = GlobalKey();
    final manifest =
        jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    await tester.runAsync(() async {
      for (final font in readerFonts) {
        final entry = manifest.cast<Map>().singleWhere(
          (entry) => entry['family'] == font.family,
        );
        final loader = FontLoader(font.family);
        for (final face in entry['fonts'] as List) {
          loader.addFont(
            File(face['asset'] as String)
                .readAsBytes()
                .then(ByteData.sublistView),
          );
        }
        await loader.load();
      }
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepaintBoundary(
            key: key,
            child: GridView.count(
              padding: const EdgeInsets.all(16),
              crossAxisCount: 2,
              childAspectRatio: 2,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              children: [
                for (final font in readerFonts)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            font.name,
                            style: const TextStyle(
                              fontFamily: 'Onest',
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 12),
                          for (final sample in [
                            'Ґанок, Єва, Іван і Їжак.',
                            'Съешь ещё этих мягких булок.',
                            'The quick brown fox.',
                          ])
                            Text(
                              sample,
                              style: TextStyle(
                                fontFamily: font.family,
                                fontSize: 20,
                              ),
                            ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Text(
                                'Курсив · Italic',
                                style: TextStyle(
                                  fontFamily: font.family,
                                  fontSize: 18,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                              const SizedBox(width: 20),
                              Text(
                                'Жирний · Bold',
                                style: TextStyle(
                                  fontFamily: font.family,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final image =
          await (key.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      await File('build/reader-fonts-proof.png')
          .writeAsBytes(png!.buffer.asUint8List());
    });
  });

  test('all reading faces persist and preserve legacy Lora/Onest IDs', () {
    expect(readerFonts, hasLength(10));
    expect(readerFonts.map((f) => f.id).toSet(), hasLength(readerFonts.length));
    expect(readerFont('serif').family, 'ReaderLora');
    expect(readerFont('sans').family, 'Onest');
    expect(ReaderPreferences.fromJson({'font': 42}).font, 'serif');
    expect(ReaderPreferences.fromJson({'font': 'missing'}).font, 'serif');
    for (final font in readerFonts) {
      final saved = ReaderPreferences.fromJson(
        ReaderPreferences(font: font.id).toJson(),
      );
      expect(saved.font, font.id);
      expect(saved.style(Colors.black).fontFamily, font.family);
    }
  });

  test(
    'bundled normal, bold and italic fonts cover UA, RU, EN without fallback',
    () async {
      final manifest =
          jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
      const alphabet =
          'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
          'АБВГҐДЕЄЁЖЗИІЇЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ'
          'абвгґдеєёжзиіїйклмнопрстуфхцчшщъыьэюя’“”—…';
      for (final font in readerFonts) {
        final entry = manifest.cast<Map>().singleWhere(
          (entry) => entry['family'] == font.family,
        );
        for (final face in entry['fonts'] as List) {
          final asset = face['asset'] as String;
          final bytes = await File(asset).readAsBytes();
          for (final code in alphabet.runes.toSet()) {
            expect(
              hasGlyph(bytes, code),
              isTrue,
              reason: '$asset lacks ${String.fromCharCode(code)}',
            );
          }
        }
      }
    },
  );

  test(
    'new font binaries match their pinned upstream hashes and bundle licenses',
    () async {
      final manifest = jsonDecode(
        await File('assets/fonts/reader-fonts.json').readAsString(),
      ) as Map;
      for (final entry in manifest['files'] as List) {
        final bytes = await File('assets/fonts/${entry['file']}').readAsBytes();
        expect(sha256.convert(bytes).toString(), entry['sha256']);
        final name = (entry['file'] as String).split(RegExp('[-.]')).first;
        final license = await rootBundle.loadString(
          'assets/fonts/$name-OFL.txt',
        );
        expect(license, contains('SIL OPEN FONT LICENSE'));
      }
      expect(
        await rootBundle.loadString('assets/fonts/Merriweather-FONTLOG.txt'),
        contains('FONTLOG'),
      );
    },
  );
}
