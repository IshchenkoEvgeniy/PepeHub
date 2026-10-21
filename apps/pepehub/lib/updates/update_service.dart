import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/repository.dart';
import 'update_manifest.dart';
import 'update_package.dart';
import 'update_trust.dart';

class UpdateAppInfo {
  final String version, platform;
  final int versionCode;
  const UpdateAppInfo(this.version, this.versionCode, this.platform);
  factory UpdateAppInfo.fromJson(Map<Object?, Object?> value) => UpdateAppInfo(
    value['version'] as String,
    value['versionCode'] as int,
    value['platform'] as String,
  );
}

abstract class UpdatePlatform {
  Future<UpdateAppInfo> info();
  Future<String> installApk(
    File file,
    UpdateRelease release,
    UpdateArtifact artifact,
  );
  Future<bool> openInstallSettings();
  Future<void> openDownload(Uri url);
  Future<void> exitForUpdate();
}

class NativeUpdatePlatform implements UpdatePlatform {
  const NativeUpdatePlatform();
  static const channel = MethodChannel('pepehub/updates');
  @override
  Future<UpdateAppInfo> info() async => UpdateAppInfo.fromJson(
    (await channel.invokeMapMethod<Object?, Object?>('getInfo'))!,
  );
  @override
  Future<String> installApk(
    File file,
    UpdateRelease release,
    UpdateArtifact artifact,
  ) async => (await channel.invokeMethod<String>('installApk', {
    'path': file.path,
    'version': release.version,
    'versionCode': artifact.versionCode,
    'sha256': artifact.hash,
  }))!;
  @override
  Future<bool> openInstallSettings() async =>
      await channel.invokeMethod<bool>('openInstallSettings') ?? false;
  @override
  Future<void> openDownload(Uri url) => channel.invokeMethod('openDownload', {
    'url': updateUrl('$url').toString(),
  });
  @override
  Future<void> exitForUpdate() => channel.invokeMethod('exitForUpdate');
}

enum UpdatePhase {
  idle,
  checking,
  downloading,
  ready,
  preparing,
  installerOpened,
  permissionRequired,
}

class UpdateService extends ChangeNotifier with WidgetsBindingObserver {
  final Repository repository;
  final UpdatePlatform platform;
  final http.Client client;
  final http.Client Function() downloadClient;
  final Future<Directory> Function() directory;
  final String publicKey;
  final DateTime Function() now;
  final bool observeLifecycle;
  final Duration installTimeout;
  final Future<void> Function()? prepareRestart;
  final Future<void> Function(File config, File helper)? launchHelper;
  final String Function() executable;
  final bool _ownsClient;
  UpdateService(
    this.repository, {
    this.platform = const NativeUpdatePlatform(),
    http.Client? client,
    http.Client Function()? downloadClient,
    Future<Directory> Function()? directory,
    this.publicKey = updatePublicKey,
    DateTime Function()? now,
    this.observeLifecycle = true,
    this.installTimeout = const Duration(seconds: 45),
    this.prepareRestart,
    this.launchHelper,
    String Function()? executable,
  }) : client = client ?? http.Client(),
       _ownsClient = client == null,
       downloadClient = downloadClient ?? http.Client.new,
       directory =
           directory ??
           (() async => Directory(
             p.join((await getTemporaryDirectory()).path, 'pepehub-updates'),
           )),
       now = now ?? DateTime.now,
       executable = executable ?? (() => Platform.resolvedExecutable);

  UpdateAppInfo? app;
  UpdateRelease? release;
  UpdateArtifact? artifact;
  UpdatePhase phase = UpdatePhase.idle;
  String feed = const String.fromEnvironment(
    'PEPEHUB_UPDATE_FEED',
    defaultValue: defaultUpdateFeed,
  );
  String? error, lastChecked;
  bool automatic = true, loaded = false, _disposed = false, _cancelled = false;
  int received = 0, total = 0;
  File? package;
  String? installStep;
  bool _waitingForInstallSettings = false;
  http.Client? _downloader;
  Directory? _pendingTransaction;
  bool get busy => [
    UpdatePhase.checking,
    UpdatePhase.downloading,
    UpdatePhase.preparing,
  ].contains(phase);
  bool get available => release != null && artifact != null;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    try {
      app = await platform.info();
      parseVersion(app!.version);
      if (![
        'windows-x64',
        'android-arm64',
        'android-universal',
      ].contains(app!.platform)) {
        throw const UpdateException('Эта платформа пока не поддерживается');
      }
      feed = await repository.meta('update-feed') ?? feed;
      updateUrl(feed);
      automatic = await repository.meta('update-auto') != 'false';
      lastChecked = await repository.meta('update-last-check');
      if (observeLifecycle) WidgetsBinding.instance.addObserver(this);
    } catch (_) {
      error = 'Проверка обновлений недоступна в этой сборке';
    }
    loaded = true;
    _notify();
    if (app != null && automatic && observeLifecycle && !_disposed) {
      unawaited(check(quiet: true));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        automatic &&
        !busy &&
        !_waitingForInstallSettings) {
      unawaited(check(quiet: true));
    }
  }

  Future<void> configure({bool? automatic, String? feed}) async {
    if (busy) throw const UpdateException('Дождитесь завершения обновления');
    if (feed != null) {
      final next = updateUrl(feed.trim()).toString();
      await repository.setMeta('update-feed', next);
      this.feed = next;
      release = null;
      artifact = null;
      package = null;
      phase = UpdatePhase.idle;
    }
    if (automatic != null) {
      await repository.setMeta('update-auto', '$automatic');
      this.automatic = automatic;
    }
    error = null;
    _notify();
  }

  Future<http.StreamedResponse> _get(
    http.Client connection,
    Uri url, {
    Map<String, String> headers = const {},
  }) async {
    var target = url;
    for (var i = 0; i < 6; i++) {
      updateUrl(target.toString());
      final request = http.Request('GET', target)..followRedirects = false;
      request.headers.addAll({'User-Agent': 'PepeHub updater', ...headers});
      final response = await connection
          .send(request)
          .timeout(const Duration(seconds: 25));
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers['location'];
        await response.stream.listen((_) {}).cancel();
        if (location == null) {
          throw const UpdateException('Сервер не указал адрес файла');
        }
        target = updateUrl(target.resolve(location).toString());
        continue;
      }
      return response;
    }
    throw const UpdateException('Слишком много перенаправлений');
  }

  Future<void> check({bool quiet = false}) async {
    if (busy || app == null || _disposed) return;
    if (quiet) {
      final attempted = DateTime.tryParse(
        await repository.meta('update-last-attempt') ?? '',
      );
      if (attempted != null &&
          now().difference(attempted) < const Duration(hours: 12)) {
        return;
      }
    }
    final oldPhase = phase;
    phase = UpdatePhase.checking;
    error = null;
    _notify();
    try {
      await repository.setMeta(
        'update-last-attempt',
        now().toUtc().toIso8601String(),
      );
      final response = await _get(
        client,
        updateUrl(feed),
        headers: {'Cache-Control': 'no-cache'},
      );
      if (response.statusCode != 200) {
        await response.stream.listen((_) {}).cancel();
        throw UpdateException(
          response.statusCode == 404
              ? 'Первый выпуск с обновлениями ещё не опубликован'
              : 'Сервер обновлений вернул ${response.statusCode}',
        );
      }
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 25),
      )) {
        bytes.addAll(chunk);
        if (bytes.length > 65536) {
          throw const UpdateException('Слишком большой список обновлений');
        }
      }
      final latest = await UpdateRelease.verify(
        bytes,
        now: now(),
        publicKey: publicKey,
      );
      final candidate = latest.artifacts[app!.platform];
      final highest =
          int.tryParse(await repository.meta('update-highest-build') ?? '') ??
          0;
      if (latest.build < highest) {
        throw const UpdateException(
          'Сервер вернул устаревший список обновлений',
        );
      }
      await repository.setMeta('update-highest-build', '${latest.build}');
      if (candidate == null) {
        throw const UpdateException(
          'В выпуске нет пакета для этого устройства',
        );
      }
      if (candidate.versionCode > app!.versionCode &&
          compareVersions(latest.version, app!.version) >= 0) {
        final changed = artifact?.hash != candidate.hash;
        release = latest;
        artifact = candidate;
        if (changed) package = null;
        // Settings can recreate the Android process. Reuse a verified download
        // after a restart rather than asking the user to fetch the APK again.
        if (package == null) {
          final root = await _cache();
          final cached = File(
            p.join(root.path, _packageName(latest, candidate)),
          );
          if (await _verified(cached, candidate)) package = cached;
        }
        phase = package == null
            ? UpdatePhase.idle
            : !changed &&
                  [
                    UpdatePhase.permissionRequired,
                    UpdatePhase.installerOpened,
                  ].contains(oldPhase)
            ? oldPhase
            : UpdatePhase.ready;
      } else {
        release = null;
        artifact = null;
        package = null;
        phase = UpdatePhase.idle;
      }
      lastChecked = now().toUtc().toIso8601String();
      await repository.setMeta('update-last-check', lastChecked!);
    } catch (e) {
      error = e is UpdateException
          ? e.message
          : 'Не удалось проверить обновления. Проверьте подключение.';
      phase = oldPhase;
    } finally {
      _notify();
    }
  }

  Future<Directory> _cache() async {
    final root = await directory();
    await root.create(recursive: true);
    if (await FileSystemEntity.type(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const UpdateException('Неверный каталог загрузки');
    }
    return root;
  }

  Future<bool> _verified(File file, UpdateArtifact expected) async =>
      await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.file &&
      await file.length() == expected.bytes &&
      (await sha256.bind(file.openRead()).first).toString() == expected.hash;

  String _packageName(UpdateRelease value, UpdateArtifact asset) =>
      '${value.build}-${app!.platform}-${asset.hash}.${asset.format}';

  Future<void> download() async {
    if (!available || busy || _disposed) return;
    final selected = artifact!, selectedRelease = release!;
    phase = UpdatePhase.downloading;
    _cancelled = false;
    error = null;
    total = selected.bytes;
    received = 0;
    package = null;
    _notify();
    IOSink? output;
    final connection = downloadClient();
    _downloader = connection;
    try {
      final root = await _cache();
      final name = _packageName(selectedRelease, selected);
      final ready = File(p.join(root.path, name)),
          partial = File(p.join(root.path, '$name.part'));
      await for (final old in root.list(followLinks: false)) {
        final base = p.basename(old.path);
        if (old is File &&
            base != name &&
            base != '$name.part' &&
            RegExp(
              r'^\d+-(windows-x64|android-arm64|android-universal)-[a-f0-9]{64}\.(zip|apk)(\.part)?$',
            ).hasMatch(base)) {
          await old.delete();
        }
      }
      if (await _verified(ready, selected)) {
        package = ready;
        phase = UpdatePhase.ready;
        return;
      }
      if (await FileSystemEntity.type(partial.path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const UpdateException('Неверный файл загрузки');
      }
      var offset = await partial.exists() ? await partial.length() : 0;
      if (offset > selected.bytes) {
        await partial.delete();
        offset = 0;
      }
      if (offset < selected.bytes) {
        final response = await _get(
          connection,
          selected.url,
          headers: {
            if (offset > 0) 'Range': 'bytes=$offset-',
            'Accept-Encoding': 'identity',
          },
        );
        if (response.statusCode == 206) {
          final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$')
              .firstMatch(response.headers['content-range'] ?? '');
          if (range == null ||
              int.parse(range[1]!) != offset ||
              int.parse(range[2]!) != selected.bytes - 1 ||
              int.parse(range[3]!) != selected.bytes) {
            await response.stream.listen((_) {}).cancel();
            throw const UpdateException(
              'Сервер вернул неверный диапазон файла',
            );
          }
        } else if (response.statusCode == 200) {
          offset = 0;
        } else {
          await response.stream.listen((_) {}).cancel();
          throw UpdateException(
            'Не удалось скачать обновление: ${response.statusCode}',
          );
        }
        final length = response.contentLength;
        if (length != null && length != selected.bytes - offset) {
          await response.stream.listen((_) {}).cancel();
          throw const UpdateException(
            'Размер загрузки отличается от подписанного',
          );
        }
        output = partial.openWrite(
          mode: offset == 0 ? FileMode.write : FileMode.append,
        );
        received = offset;
        var lastNotice = 0;
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 30),
        )) {
          if (_cancelled || _disposed) {
            throw const UpdateException('Загрузка отменена');
          }
          received += chunk.length;
          if (received > selected.bytes) {
            throw const UpdateException('Сервер прислал лишние данные');
          }
          output.add(chunk);
          // Flush applies backpressure: a slow disk cannot accumulate the ZIP in RAM.
          await output.flush();
          if (now().millisecondsSinceEpoch - lastNotice > 100) {
            lastNotice = now().millisecondsSinceEpoch;
            _notify();
          }
        }
        await output.close();
        output = null;
      }
      if (_cancelled) throw const UpdateException('Загрузка отменена');
      if (!await _verified(partial, selected)) {
        if (await partial.exists()) await partial.delete();
        throw const UpdateException(
          'Контрольная сумма обновления не совпала. Скачайте его заново.',
        );
      }
      if (await ready.exists()) await ready.delete();
      package = await partial.rename(ready.path);
      received = selected.bytes;
      phase = UpdatePhase.ready;
    } catch (e) {
      phase = UpdatePhase.idle;
      error = _cancelled
          ? null
          : e is UpdateException
          ? e.message
          : 'Загрузка прервана. Её можно продолжить.';
    } finally {
      try {
        await output?.close();
      } catch (_) {
        phase = UpdatePhase.idle;
        error ??=
            'Не удалось сохранить скачанный файл. Проверьте свободное место.';
      }
      connection.close();
      _downloader = null;
      _notify();
    }
  }

  void cancelDownload() {
    _cancelled = true;
    _downloader?.close();
  }

  Future<void> install() async {
    if (package == null || !available || busy || _disposed) return;
    final selected = artifact!, selectedRelease = release!, file = package!;
    phase = UpdatePhase.preparing;
    installStep = 'Проверяем скачанный файл…';
    error = null;
    _notify();
    try {
      if (!await _verified(file, selected).timeout(
        installTimeout,
        onTimeout: () => throw const UpdateException(
          'Не удалось прочитать скачанный пакет. Повторите попытку или скачайте обновление заново.',
        ),
      )) {
        package = null;
        throw const UpdateException(
          'Скачанный пакет изменился. Скачайте его заново.',
        );
      }
      if (selected.format == 'apk') {
        if (_disposed) return;
        installStep = 'Проверяем APK и вызываем установщик Android…';
        _notify();
        final status = await platform
            .installApk(file, selectedRelease, selected)
            .timeout(
              installTimeout,
              onTimeout: () => throw const UpdateException(
                'Android не ответил на запрос установки. Повторите попытку или скачайте APK через браузер.',
              ),
            );
        phase = switch (status) {
          'permissionRequired' => UpdatePhase.permissionRequired,
          'installerOpened' => UpdatePhase.installerOpened,
          _ => throw const UpdateException(
            'Android не подтвердил запуск установщика',
          ),
        };
        if (phase == UpdatePhase.permissionRequired &&
            !_waitingForInstallSettings) {
          installStep = null;
          _notify();
          await allowInstall();
        }
      } else {
        if (_pendingTransaction case final old?) {
          await File(p.join(old.path, 'cancel')).writeAsString('cancel');
        }
        final cache = await _cache();
        final transaction = await cache.createTemp('windows-');
        _pendingTransaction = transaction;
        final stage = p.join(transaction.path, 'stage');
        final files = await stageUpdatePackage(file.path, stage);
        final helper = File(p.join(transaction.path, 'install.ps1'));
        await helper.writeAsString(
          await rootBundle.loadString('assets/updater/install-windows.ps1'),
        );
        final install = File(executable()).absolute.parent.path;
        final config = File(p.join(transaction.path, 'transaction.json'));
        await config.writeAsString(
          jsonEncode({
            'installDir': install,
            'stageDir': stage,
            'transactionDir': transaction.path,
            'parentPid': pid,
            'expectedVersion':
                '${selectedRelease.version}+${selectedRelease.build}',
            'files': files,
          }),
        );
        await (launchHelper ?? _launchHelper)(config, helper);
        final ready = File(p.join(transaction.path, 'ready'));
        for (var i = 0; i < 100 && !await ready.exists(); i++) {
          final failure = File(p.join(transaction.path, 'failure.txt'));
          if (await failure.exists()) {
            throw const UpdateException(
              'Не удалось подготовить установку. Проверьте права на папку приложения.',
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        if (!await ready.exists()) {
          throw const UpdateException('Помощник обновления не запустился');
        }
        await prepareRestart?.call();
        await platform.exitForUpdate();
        phase = UpdatePhase.installerOpened;
      }
    } catch (e) {
      if (selected.format == 'zip' && _pendingTransaction != null) {
        try {
          await File(p.join(_pendingTransaction!.path, 'cancel'))
              .writeAsString('cancel');
        } catch (_) {}
      }
      phase = package == null ? UpdatePhase.idle : UpdatePhase.ready;
      error = e is UpdateException
          ? e.message
          : e is PlatformException
          ? e.message ?? 'Не удалось открыть установщик'
          : 'Не удалось установить обновление. Текущая версия сохранена.';
    } finally {
      installStep = null;
      _notify();
    }
  }

  Future<void> allowInstall() async {
    if (_waitingForInstallSettings || busy || package == null || _disposed) {
      return;
    }
    _waitingForInstallSettings = true;
    error = null;
    try {
      final granted = await platform.openInstallSettings();
      if (_disposed) return;
      if (granted) {
        await install();
      } else {
        phase = UpdatePhase.permissionRequired;
        error = 'Разрешение установки не включено. Разрешите установку для PepeHub или скачайте APK через браузер.';
      }
    } catch (e) {
      error = e is PlatformException
          ? e.message ?? 'Не удалось открыть настройки установки Android'
          : 'Откройте разрешение установки для PepeHub в настройках Android';
    } finally {
      _waitingForInstallSettings = false;
      _notify();
    }
  }

  Future<void> openAndroidDownload() async {
    if (artifact == null ||
        app?.platform.startsWith('android') != true ||
        busy) {
      return;
    }
    try {
      await platform.openDownload(updateUrl('${artifact!.url}'));
      error = null;
    } catch (_) {
      error =
          'Не удалось открыть браузер. Ссылку на APK можно скопировать ниже.';
    }
    _notify();
  }

  static Future<void> _launchHelper(File config, File helper) async {
    final script =
        "& '${helper.path.replaceAll("'", "''")}' -ConfigPath '${config.path.replaceAll("'", "''")}'";
    final encoded = <int>[
      for (final unit in script.codeUnits) ...[unit & 255, unit >> 8],
    ];
    final system = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    await Process.start(
      p.join(system, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'),
      [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-EncodedCommand',
        base64Encode(encoded),
      ],
      mode: ProcessStartMode.detached,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _downloader?.close();
    if (observeLifecycle) WidgetsBinding.instance.removeObserver(this);
    if (_ownsClient) client.close();
    super.dispose();
  }
}

class UpdateScope extends InheritedWidget {
  final UpdateService service;
  const UpdateScope({super.key, required this.service, required super.child});
  static UpdateService? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UpdateScope>()?.service;
  @override
  bool updateShouldNotify(UpdateScope oldWidget) =>
      service != oldWidget.service;
}
