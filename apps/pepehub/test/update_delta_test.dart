import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/updates/update_delta.dart';
import 'package:pepehub/updates/update_manifest.dart';

void main() {
  late Directory root;
  late File base, patch, output;
  late UpdateDelta delta;
  late UpdateArtifact target;
  final original = utf8.encode('abcdef'), expected = utf8.encode('abXYZef');
  setUp(() async {
    root = await Directory.systemTemp.createTemp('pepehub-delta-');
    base = File('${root.path}/base');
    patch = File('${root.path}/patch');
    output = File('${root.path}/output');
    await base.writeAsBytes(original);
  });
  tearDown(() => root.delete(recursive: true));
  List<int> copy(int offset, int length) {
    final bytes = Uint8List(13);
    bytes[0] = 0;
    ByteData.sublistView(bytes).setUint64(1, offset, Endian.little);
    ByteData.sublistView(bytes).setUint32(9, length, Endian.little);
    return bytes;
  }

  Future<void> prepare(List<int> commands) async {
    final baseHash = sha256.convert(original).toString(),
        targetHash = sha256.convert(expected).toString();
    final header = utf8.encode(
      jsonEncode({
        'version': 1,
        'baseSha256': baseHash,
        'baseBytes': original.length,
        'targetSha256': targetHash,
        'targetBytes': expected.length,
      }),
    );
    final prefix = Uint8List(12)..setRange(0, 8, ascii.encode('PEPEDLT1'));
    ByteData.sublistView(prefix).setUint32(8, header.length, Endian.little);
    final bytes = [...prefix, ...header, ...gzip.encode(commands)];
    await patch.writeAsBytes(bytes);
    delta = UpdateDelta(
      Uri.https('example.test', '/patch'),
      sha256.convert(bytes).toString(),
      bytes.length,
      baseHash,
      original.length,
      1,
    );
    target = UpdateArtifact(
      Uri.https('example.test', '/package'),
      targetHash,
      'apk',
      expected.length,
      2,
    );
  }

  Future<void> apply({bool Function()? cancelled}) => applyUpdateDelta(
    base: base,
    patch: patch,
    output: output,
    delta: delta,
    target: target,
    cancelled: cancelled,
  );
  List<int> valid() => [
    ...copy(0, 2),
    1,
    3,
    0,
    0,
    0,
    ...utf8.encode('XYZ'),
    ...copy(4, 2),
    255,
  ];

  test(
    'copy and literal operations reconstruct the exact signed target bytes',
    () async {
      await prepare(valid());
      await apply();
      expect(await output.readAsBytes(), expected);
    },
  );
  test(
    'a modified installed base is rejected before creating output',
    () async {
      await prepare(valid());
      await base.writeAsString('abqdef');
      await expectLater(apply(), throwsA(isA<UpdateException>()));
      expect(await output.exists(), isFalse);
    },
  );
  test('a modified downloaded patch is rejected', () async {
    await prepare(valid());
    final bytes = await patch.readAsBytes();
    bytes[0] ^= 1;
    await patch.writeAsBytes(bytes);
    await expectLater(apply(), throwsA(isA<UpdateException>()));
  });
  test(
    'copying beyond base bounds and trailing commands are rejected',
    () async {
      await prepare([...copy(5, 7), 255]);
      await expectLater(apply(), throwsA(isA<UpdateException>()));
      await prepare([...valid(), 1]);
      await expectLater(apply(), throwsA(isA<UpdateException>()));
    },
  );
  test(
    'cancelled reconstruction never produces an installable target',
    () async {
      await prepare(valid());
      await expectLater(
        apply(cancelled: () => true),
        throwsA(isA<UpdateException>()),
      );
      expect(await output.exists(), isFalse);
    },
  );
}
