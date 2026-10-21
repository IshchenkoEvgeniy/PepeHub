import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/updates/update_manifest.dart';
import 'package:pepehub/updates/update_package.dart';
import 'package:pepehub/updates/update_service.dart';

final updateNow = DateTime.utc(2026, 10, 17);

class FakeUpdatePlatform implements UpdatePlatform {
  UpdateAppInfo current;
  int installs = 0, exits = 0, settings = 0;
  bool permissionGranted = false;
  Completer<bool>? permissionResult;
  Completer<String>? installResult;
  Object? installError;
  Uri? openedDownload;
  String status = 'installerOpened';
  FakeUpdatePlatform([
    this.current = const UpdateAppInfo('0.21.0', 51, 'windows-x64'),
  ]);
  @override
  Future<UpdateAppInfo> info() async => current;
  @override
  Future<String> installApk(
    File file,
    UpdateRelease release,
    UpdateArtifact artifact,
  ) async {
    installs++;
    if (installError case final failure?) throw failure;
    return installResult == null ? status : await installResult!.future;
  }

  @override
  Future<bool> openInstallSettings() async {
    settings++;
    return permissionResult == null
        ? permissionGranted
        : await permissionResult!.future;
  }

  @override
  Future<void> openDownload(Uri url) async {
    openedDownload = url;
  }

  @override
  Future<void> exitForUpdate() async {
    exits++;
  }
}

class UpdateFixture {
  final db = AppDatabase(NativeDatabase.memory());
  late final repo = Repository(db);
  final native = FakeUpdatePlatform();
  late final Directory cache;
  late final SimpleKeyPair key;
  late final String publicKey;
  List<int> bytes = utf8.encode('A complete update package for tests');
  String get hash => sha256.convert(bytes).toString();
  Future<void> open() async {
    cache = await Directory.systemTemp.createTemp('pepehub-update-test-');
    key = await Ed25519().newKeyPairFromSeed(List.generate(32, (i) => i + 1));
    publicKey = base64Encode((await key.extractPublicKey()).bytes);
  }

  Map<String, dynamic> payload({
    String platform = 'windows-x64',
    int build = 52,
  }) => {
    'schema': 1,
    'appId': 'app.pepehub.pepehub',
    'channel': 'stable',
    'version': '0.21.0',
    'build': build,
    'notes': 'Улучшения приложения',
    'publishedAt': updateNow.toIso8601String(),
    'expiresAt': updateNow.add(const Duration(days: 30)).toIso8601String(),
    'artifacts': {
      platform: {
        'url':
            'https://releases.example/update.${platform == 'windows-x64' ? 'zip' : 'apk'}',
        'sha256': hash,
        'bytes': bytes.length,
        'versionCode': build + (platform == 'android-arm64' ? 2000 : 0),
        'format': platform == 'windows-x64' ? 'zip' : 'apk',
      },
    },
  };
  Future<List<int>> sign(Map<String, dynamic> value) async {
    final data = utf8.encode(jsonEncode(value)),
        signature = await Ed25519().sign(
          utf8.encode(jsonEncode(value)),
          keyPair: key,
        );
    return utf8.encode(
      jsonEncode({
        'payload': base64Encode(data),
        'signature': base64Encode(signature.bytes),
      }),
    );
  }

  Future<UpdateService> service({
    MockClient? downloads,
    Map<String, dynamic>? value,
    MockClient? client,
    Duration installTimeout = const Duration(seconds: 45),
  }) async {
    final envelope = await sign(
      value ?? payload(platform: native.current.platform),
    );
    final service = UpdateService(
      repo,
      platform: native,
      publicKey: publicKey,
      now: () => updateNow,
      observeLifecycle: false,
      installTimeout: installTimeout,
      directory: () async => cache,
      client:
          client ?? MockClient((_) async => http.Response.bytes(envelope, 200)),
      downloadClient: () =>
          downloads ?? MockClient((_) async => http.Response.bytes(bytes, 200)),
    );
    await service.initialize();
    return service;
  }

  Future<void> close() async {
    await db.close();
    await cache.delete(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late UpdateFixture f;
  setUp(() async {
    f = UpdateFixture();
    await f.open();
  });
  tearDown(() => f.close());

  test('signed manifest validates app, platform, expiry, version and rejects changed bytes/signature', () async {
    final valid = await f.sign(f.payload());
    expect(
      (await UpdateRelease.verify(
        valid,
        now: updateNow,
        publicKey: f.publicKey,
      )).build,
      52,
    );
    final outer = jsonDecode(utf8.decode(valid)) as Map<String, dynamic>;
    outer['payload'] = base64Encode(
      utf8.encode(jsonEncode({...f.payload(), 'build': 99})),
    );
    await expectLater(
      UpdateRelease.verify(
        utf8.encode(jsonEncode(outer)),
        now: updateNow,
        publicKey: f.publicKey,
      ),
      throwsA(isA<UpdateException>()),
    );
    for (final value in [
      {...f.payload(), 'appId': 'different.app'},
      {...f.payload(), 'version': '0.21.0+52'},
      {
        ...f.payload(),
        'expiresAt': updateNow
            .subtract(const Duration(days: 1))
            .toIso8601String(),
      },
      {
        ...f.payload(),
        'publishedAt': updateNow.add(const Duration(days: 2)).toIso8601String(),
      },
    ]) {
      await expectLater(
        UpdateRelease.verify(
          await f.sign(value),
          now: updateNow,
          publicKey: f.publicKey,
        ),
        throwsA(isA<UpdateException>()),
      );
    }
    expect(compareVersions('0.21.0', '0.20.9'), greaterThan(0));
    expect(compareVersions('0.9.0', '0.21.0'), lessThan(0));
    for (final url in [
      'http://example.com',
      'https://name:secret@example.com/a',
      'https://example.com/#x',
    ]) {
      expect(() => updateUrl(url), throwsA(isA<UpdateException>()));
    }
  });

  test('same version with higher build is offered, periodic checking is bounded and signed rollback is rejected', () async {
    var calls = 0, selected = f.payload();
    final service = await f.service(
      client: MockClient((_) async {
        calls++;
        return http.Response.bytes(await f.sign(selected), 200);
      }),
    );
    await service.check(quiet: true);
    expect(calls, 1);
    expect(service.available, true);
    await service.check(quiet: true);
    expect(calls, 1);
    await service.check();
    expect(calls, 2);
    selected = f.payload(build: 51);
    await service.check();
    expect(service.error, contains('устаревший'));
    expect(service.release!.build, 52);
    expect(await f.repo.pendingCount(), 0);
    service.dispose();
  });

  test('already installed build is current and automatic checks can be switched off', () async {
    f.native.current = const UpdateAppInfo('0.21.0', 52, 'windows-x64');
    final service = await f.service();
    await service.check();
    expect(service.available, false);
    expect(service.lastChecked, isNotNull);
    await service.configure(automatic: false);
    expect(await f.repo.meta('update-auto'), 'false');
    service.dispose();
  });

  test('HTTPS redirects are bounded and downgrade redirects never download a manifest', () async {
    var calls = 0;
    final service = await f.service(
      client: MockClient((request) async {
        calls++;
        expect(request.followRedirects, false);
        return http.Response(
          '',
          302,
          headers: {'location': 'http://unsafe.example/update.json'},
        );
      }),
    );
    await service.check();
    expect(calls, 1);
    expect(service.available, false);
    expect(service.error, contains('HTTPS'));
    service.dispose();
  });

  test('interrupted download resumes with Range and verifies the entire resulting file', () async {
    var attempts = 0;
    final service = await f.service(
      downloads: MockClient.streaming((request, body) async {
        await body.drain();
        attempts++;
        if (attempts == 1) {
          Stream<List<int>> interrupted() async* {
            yield f.bytes.sublist(0, 10);
            throw http.ClientException('Disconnected');
          }

          return http.StreamedResponse(
            interrupted(),
            200,
            contentLength: f.bytes.length,
          );
        }
        expect(request.headers['Range'], 'bytes=10-');
        return http.StreamedResponse(
          Stream.value(f.bytes.sublist(10)),
          206,
          contentLength: f.bytes.length - 10,
          headers: {
            'content-range': 'bytes 10-${f.bytes.length - 1}/${f.bytes.length}',
          },
        );
      }),
    );
    await service.check();
    await service.download();
    expect(service.package, null);
    expect(service.error, contains('прервана'));
    await service.download();
    expect(service.phase, UpdatePhase.ready);
    expect(await service.package!.readAsBytes(), f.bytes);
    expect(attempts, 2);
    service.dispose();
  });

  test('server ignoring Range restarts safely, corrupt payload is rejected and install cannot use altered cache', () async {
    final partial = File(
      p.join(f.cache.path, '52-windows-x64-${f.hash}.zip.part'),
    );
    await partial.writeAsBytes(f.bytes.sublist(0, 4));
    final service = await f.service();
    await service.check();
    await service.download();
    expect(await service.package!.readAsBytes(), f.bytes);
    await service.package!.writeAsString('Changed after verification');
    await service.install();
    expect(f.native.exits, 0);
    expect(service.error, contains('изменился'));
    service.dispose();
    await partial.writeAsBytes(List.filled(f.bytes.length, 0));
    final corrupt = await f.service();
    await corrupt.check();
    await corrupt.download();
    expect(corrupt.error, contains('Контрольная сумма'));
    expect(corrupt.package, isNull);
    corrupt.dispose();
  });

  test('Android permission flow keeps verified APK and retries installer without downloading again', () async {
    f.native.current = const UpdateAppInfo('0.21.0', 2051, 'android-arm64');
    f.native.status = 'permissionRequired';
    final service = await f.service();
    await service.check();
    await service.download();
    f.native.permissionResult = Completer<bool>();
    final request = service.install();
    for (var i = 0; i < 100 && f.native.settings == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(f.native.settings, 1);
    expect(service.phase, UpdatePhase.permissionRequired);
    expect(f.native.installs, 1);
    f.native.status = 'installerOpened';
    f.native.permissionResult!.complete(true);
    await request;
    expect(service.phase, UpdatePhase.installerOpened);
    expect(f.native.installs, 2);
    expect(f.native.settings, 1);
    expect(f.native.exits, 0);
    service.dispose();
  });

  test('permission denial does not launch an installer and returning from settings does not clear the APK', () async {
    f.native.current = const UpdateAppInfo('0.21.0', 2051, 'android-arm64');
    f.native.status = 'permissionRequired';
    final service = await f.service();
    await service.check();
    await service.download();
    await service.install();
    final file = service.package;
    f.native.permissionResult = Completer<bool>();
    final request = service.allowInstall();
    service.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await service.allowInstall(); // Double taps cannot open duplicate settings.
    expect(f.native.settings, 2);
    f.native.permissionResult!.complete(false);
    await request;
    expect(f.native.installs, 1);
    expect(service.phase, UpdatePhase.permissionRequired);
    expect(service.package, file);
    expect(service.error, contains('не включено'));
    await service.openAndroidDownload();
    expect(f.native.openedDownload, service.artifact!.url);
    service.dispose();
  });

  test('cached APK is restored after process recreation, but altered cache is rejected', () async {
    f.native.current = const UpdateAppInfo('0.21.0', 2051, 'android-arm64');
    final first = await f.service();
    await first.check();
    await first.download();
    final path = first.package!.path;
    first.dispose();
    final restored = await f.service();
    await restored.check();
    expect(restored.phase, UpdatePhase.ready);
    expect(restored.package!.path, path);
    await restored.package!.writeAsString('untrusted');
    restored.dispose();
    final changed = await f.service();
    await changed.check();
    expect(changed.package, isNull);
    expect(changed.phase, UpdatePhase.idle);
    changed.dispose();
  });

  test('native timeout, failure and unknown response restore the install button without redownloading', () async {
    f.native.current = const UpdateAppInfo('0.21.0', 2051, 'android-arm64');
    final service = await f.service(
      installTimeout: const Duration(milliseconds: 30),
    );
    await service.check();
    await service.download();
    final file = service.package;
    f.native.installResult = Completer<String>();
    await service.install();
    expect(service.phase, UpdatePhase.ready);
    expect(service.error, contains('не ответил'));
    expect(service.installStep, null);
    // A late answer cannot replace the reported timeout with success.
    f.native.installResult!.complete('installerOpened');
    await Future<void>.delayed(Duration.zero);
    expect(service.phase, UpdatePhase.ready);
    f.native.installResult = null;
    f.native.installError = PlatformException(
      code: 'install',
      message: 'Установка запрещена устройством',
    );
    await service.install();
    expect(service.error, 'Установка запрещена устройством');
    expect(service.phase, UpdatePhase.ready);
    f.native.installError = null;
    f.native.status = 'unexpected';
    await service.install();
    expect(service.error, contains('не подтвердил'));
    expect(service.phase, UpdatePhase.ready);
    expect(service.package, file);
    service.dispose();
  });

  test('Windows service stages a full bundle, waits for helper readiness and cancels it if saving fails', () async {
    final archive = Archive()
      ..addFile(ArchiveFile.string('pepehub.exe', 'exe'))
      ..addFile(ArchiveFile.string('flutter_windows.dll', 'dll'))
      ..addFile(ArchiveFile.string('data/app.so', 'app'));
    f.bytes = ZipEncoder().encode(archive);
    final envelope = await f.sign(f.payload());
    final transactions = <Directory>[];
    var saves = 0, failSave = false;
    final service = UpdateService(
      f.repo,
      platform: f.native,
      publicKey: f.publicKey,
      now: () => updateNow,
      observeLifecycle: false,
      directory: () async => f.cache,
      client: MockClient((_) async => http.Response.bytes(envelope, 200)),
      downloadClient: () =>
          MockClient((_) async => http.Response.bytes(f.bytes, 200)),
      executable: () =>
          p.join(f.cache.parent.path, 'installed-pepehub', 'pepehub.exe'),
      prepareRestart: () async {
        saves++;
        if (failSave) throw StateError('Save failed');
      },
      launchHelper: (config, helper) async {
        final value =
            jsonDecode(await config.readAsString()) as Map<String, dynamic>;
        expect(value['expectedVersion'], '0.21.0+52');
        expect(value['files'], hasLength(3));
        expect(await helper.exists(), true);
        transactions.add(config.parent);
        await File(p.join(config.parent.path, 'ready')).writeAsString('ready');
      },
    );
    await service.initialize();
    await service.check();
    await service.download();
    await service.install();
    expect(service.error, null);
    expect(f.native.exits, 1);
    expect(saves, 1);
    expect(service.phase, UpdatePhase.installerOpened);
    failSave = true;
    await service.install();
    expect(f.native.exits, 1);
    expect(saves, 2);
    expect(service.phase, UpdatePhase.ready);
    expect(
      await File(p.join(transactions.first.path, 'cancel')).exists(),
      true,
    );
    expect(await File(p.join(transactions.last.path, 'cancel')).exists(), true);
    service.dispose();
  });

  test('Windows extraction accepts complete bundles and blocks traversal, links and personal database files', () async {
    List<int> zip(String? extra, {bool link = false}) {
      final archive = Archive()
        ..addFile(ArchiveFile.string('pepehub.exe', 'exe'))
        ..addFile(ArchiveFile.string('flutter_windows.dll', 'dll'))
        ..addFile(ArchiveFile.string('data/app.so', 'app'));
      if (extra != null) {
        archive.addFile(
          link
              ? (ArchiveFile.string(extra, '../../outside')..mode = 0xa1ff)
              : ArchiveFile.string(extra, 'bad'),
        );
      }
      return ZipEncoder().encode(archive);
    }

    final source = File(p.join(f.cache.path, 'fixture.zip'));
    await source.writeAsBytes(zip(null));
    final files = await extractUpdatePackage(
      source.path,
      p.join(f.cache.path, 'good'),
    );
    expect(files, hasLength(3));
    expect(
      files.every(
        (f) => RegExp(r'^[a-f0-9]{64}$').hasMatch(f['sha256'] as String),
      ),
      true,
    );
    var index = 0;
    for (final invalid in [
      '../escape.dll',
      'data/../../escape.dll',
      'data/CON.txt',
      'data/a:stream',
      'library.sqlite',
      'data/space. ',
    ]) {
      await source.writeAsBytes(zip(invalid));
      await expectLater(
        extractUpdatePackage(
          source.path,
          p.join(f.cache.path, 'bad${index++}'),
        ),
        throwsA(isA<UpdateException>()),
      );
    }
    expect(safeUpdatePath(r'data\bad'), false);
    await source.writeAsBytes(zip('data/link', link: true));
    await expectLater(
      extractUpdatePackage(source.path, p.join(f.cache.path, 'link')),
      throwsA(isA<UpdateException>()),
    );
  });
}
