import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pepehub/updates/update_service.dart';

import 'update_test.dart' show UpdateFixture, FakeUpdatePlatform, updateNow;

class _InstalledApk extends FakeUpdatePlatform implements UpdateBaseProvider {
  final File file;
  _InstalledApk(this.file)
    : super(const UpdateAppInfo('0.21.0', 2076, 'android-arm64'));
  @override
  Future<File?> installedPackage() async => file;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final valid in [true, false]) {
    test(
      valid
          ? 'Android updater downloads only the signed delta and reconstructs the full APK'
          : 'unusable installed APK never starts a full download without an explicit choice',
      () async {
        final f = UpdateFixture();
        await f.open();
        final base = List<int>.filled(1024 * 1024, 65);
        f.bytes = [...base]..[base.length - 1] = 66;
        final installed = File('${f.cache.path}/base.apk');
        await installed.writeAsBytes(
          valid ? base : List<int>.filled(base.length, 67),
        );
        final header = utf8.encode(
          jsonEncode({
            'version': 1,
            'baseSha256': sha256.convert(base).toString(),
            'baseBytes': base.length,
            'targetSha256': f.hash,
            'targetBytes': f.bytes.length,
          }),
        );
        final prefix = Uint8List(12)..setRange(0, 8, ascii.encode('PEPEDLT1'));
        ByteData.sublistView(prefix).setUint32(8, header.length, Endian.little);
        final copy = Uint8List(13);
        ByteData.sublistView(copy).setUint64(1, 0, Endian.little);
        ByteData.sublistView(copy).setUint32(9, base.length - 1, Endian.little);
        final patch = [
          ...prefix,
          ...header,
          ...gzip.encode([...copy, 1, 1, 0, 0, 0, 66, 255]),
        ];
        final payload = f.payload(platform: 'android-arm64', build: 77);
        ((payload['artifacts'] as Map)['android-arm64'] as Map)['deltas'] = [
          {
            'url': 'https://releases.example/change.pdelta',
            'sha256': sha256.convert(patch).toString(),
            'bytes': patch.length,
            'format': 'pepe-delta-v1',
            'baseSha256': sha256.convert(base).toString(),
            'baseBytes': base.length,
            'fromBuild': 76,
          },
        ];
        final envelope = await f.sign(payload);
        final requested = <String>[];
        final service = UpdateService(
          f.repo,
          platform: _InstalledApk(installed),
          publicKey: f.publicKey,
          now: () => updateNow,
          observeLifecycle: false,
          directory: () async => f.cache,
          client: MockClient((_) async => http.Response.bytes(envelope, 200)),
          downloadClient: () => MockClient((r) async {
            requested.add(r.url.path);
            return http.Response.bytes(
              r.url.path.endsWith('.pdelta') ? patch : f.bytes,
              200,
            );
          }),
        );
        try {
          await service.initialize();
          await service.check();
          expect(service.delta?.fromBuild, 76);
          await service.download();
          if (valid) {
            expect(service.error, isNull);
            expect(service.phase, UpdatePhase.ready);
            expect(service.usingDelta, isTrue);
            expect(service.total, patch.length);
            expect(requested, ['/change.pdelta']);
            expect(await service.package!.readAsBytes(), f.bytes);
          } else {
            expect(requested, isEmpty);
            expect(service.package, isNull);
            expect(service.fullPackageRequired, isTrue);
            expect(service.error, contains('автоматически не скачивался'));
            await service.download(fullPackage: true);
            expect(service.error, isNull);
            expect(requested, ['/update.apk']);
            expect(await service.package!.readAsBytes(), f.bytes);
          }
        } finally {
          service.dispose();
          await f.close();
        }
      },
    );
  }
}
