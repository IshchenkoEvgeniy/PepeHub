// Explicit opt-in network acceptance. Never installs/starts an application or
// opens the user's library; all files and metadata belong to this test.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/updates/update_package.dart';
import 'package:pepehub/updates/update_service.dart';

import 'update_test.dart' show FakeUpdatePlatform;

void main() {
  final feed = Platform.environment['PEPEHUB_VERIFY_UPDATE_FEED'];
  final expectedBuild = int.tryParse(
    Platform.environment['PEPEHUB_VERIFY_UPDATE_BUILD'] ?? '',
  );
  test(
    'anonymous public feed verifies embedded key, resumes GitHub download and stages real Windows bundle',
    () async {
      final db = AppDatabase(NativeDatabase.memory()), repo = Repository(db);
      final cache = await Directory.systemTemp.createTemp(
        'pepehub-public-update-',
      );
      final service = UpdateService(
        repo,
        platform: FakeUpdatePlatform(
          const UpdateAppInfo('0.21.0', 52, 'windows-x64'),
        ),
        observeLifecycle: false,
        directory: () async => cache,
      );
      try {
        await service.initialize();
        await service.configure(feed: feed!);
        await service.check();
        expect(service.error, null);
        expect(service.available, true);
        final asset = service.artifact!, release = service.release!;
        if (expectedBuild != null) {
          expect(release.build, expectedBuild);
        }
        expect(asset.versionCode, greaterThan(52));
        // The Android ABI code is distinct from the shared build number.
        final phone = UpdateService(
          repo,
          platform: FakeUpdatePlatform(
            const UpdateAppInfo('0.21.0', 2052, 'android-arm64'),
          ),
          observeLifecycle: false,
          directory: () async => cache,
        );
        try {
          await phone.initialize();
          await phone.configure(feed: feed);
          await phone.check();
          expect(phone.error, null);
          expect(phone.available, true);
          expect(phone.artifact!.versionCode, release.build + 2000);
          expect(phone.release!.build, release.build);
        } finally {
          phone.dispose();
        }
        final connection = http.Client();
        var resumed = false;
        try {
          final response = await connection.send(
            http.Request('GET', asset.url)..headers['Range'] = 'bytes=0-63',
          );
          if (response.statusCode == 206) {
            final prefix = await response.stream.toBytes();
            expect(prefix.length, 64);
            final partial = File(
              p.join(
                cache.path,
                '${release.build}-windows-x64-${asset.hash}.zip.part',
              ),
            );
            await partial.writeAsBytes(prefix);
            resumed = true;
          } else {
            await response.stream.listen((_) {}).cancel();
          }
        } finally {
          connection.close();
        }
        await service.download();
        expect(service.error, null);
        expect(service.phase, UpdatePhase.ready);
        expect(await service.package!.length(), asset.bytes);
        final files = await stageUpdatePackage(
          service.package!.path,
          p.join(cache.path, 'staged'),
        );
        expect(
          files.any(
            (f) =>
                f['path'] ==
                'data/flutter_assets/assets/updater/install-windows.ps1',
          ),
          true,
        );
        expect(await repo.pendingCount(), 0);
        // ignore: avoid_print
        print(
          'Public update verified: build ${release.build}, ${asset.bytes} bytes, ${files.length} files, Range resume=$resumed. No install performed.',
        );
      } finally {
        service.dispose();
        await db.close();
        final actual = await cache.resolveSymbolicLinks(),
            temp = await Directory.systemTemp.resolveSymbolicLinks();
        if (!p.isWithin(temp, actual)) {
          throw StateError('Unexpected acceptance cleanup path');
        }
        await cache.delete(recursive: true);
      }
    },
    skip: feed == null,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
