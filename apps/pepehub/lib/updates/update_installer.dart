import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'update_package.dart';

/// Command-line switch that turns the freshly unpacked `pepehub.exe` into the
/// installer of its own package: `pepehub.exe --apply-update <transaction.json>`.
const applyUpdateFlag = '--apply-update';
const updateReceiptName = '.pepehub-update-receipt.json';

/// Path of the transaction file when the process was started as an installer.
String? updateInstallerConfig(List<String> args) {
  final index = args.indexOf(applyUpdateFlag);
  return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
}

class UpdateInstallException implements Exception {
  final String message;

  /// The running application has not been closed yet, so it reports the
  /// failure itself and the installer only has to leave quietly.
  final bool beforeClose;
  const UpdateInstallException(this.message, {this.beforeClose = false});
  @override
  String toString() => message;
}

/// Replaces the installed Windows application with the staged package.
///
/// The old approach handed this work to a hidden PowerShell script. Here the
/// new version does it itself: the application unpacks the package, starts the
/// unpacked `pepehub.exe` with [applyUpdateFlag] and closes; that process copies
/// its own files over the installation and opens the installed application.
/// Nothing in the installation is in use by then, and every failure is shown
/// in a window instead of a log file nobody sees.
class WindowsUpdateInstaller {
  final File config;
  final Duration closeTimeout, pollInterval;
  final int copyAttempts;

  /// Whether the installed executable is no longer running. On Windows a
  /// running image cannot be opened for writing.
  final Future<bool> Function(File executable) replaceable;
  final Future<void> Function(File source, File destination) copy;
  final Future<void> Function(File executable) start;
  final void Function(String step)? onStep;

  late final String installDir, stageDir, transactionDir, expectedVersion;
  late final List<UpdatePackageFile> files;
  final _touched = <String>[];
  final _before = <String, bool>{};

  WindowsUpdateInstaller(
    this.config, {
    this.closeTimeout = const Duration(seconds: 90),
    this.pollInterval = const Duration(milliseconds: 200),
    this.copyAttempts = 20,
    Future<bool> Function(File executable)? replaceable,
    Future<void> Function(File source, File destination)? copy,
    Future<void> Function(File executable)? start,
    this.onStep,
  }) : replaceable = replaceable ?? _canWrite,
       copy = copy ?? _copy,
       start = start ?? _start;

  File _marker(String name) => File(p.join(transactionDir, name));
  File get installedExecutable => File(p.join(installDir, 'pepehub.exe'));
  String get _backupDir => p.join(transactionDir, 'backup');

  static Future<bool> _canWrite(File executable) async {
    try {
      await (await executable.open(mode: FileMode.append)).close();
      return true;
    } on FileSystemException {
      return false;
    }
  }

  static Future<void> _copy(File source, File destination) async {
    await source.copy(destination.path);
  }

  static Future<void> _start(File executable) async {
    await Process.start(
      executable.path,
      const [],
      workingDirectory: executable.parent.path,
      mode: ProcessStartMode.detached,
    );
  }

  void _step(String text) => onStep?.call(text);

  void _status(String state) {
    try {
      _marker('status.json').writeAsStringSync(
        jsonEncode({
          'state': state,
          'time': DateTime.now().toUtc().toIso8601String(),
        }),
      );
    } on FileSystemException {
      /* The status file is informational only. */
    }
  }

  File _target(String root, String relative) {
    if (relative != updateReceiptName && !safeUpdatePath(relative)) {
      throw const UpdateInstallException('Недопустимый путь в пакете.');
    }
    final file = File(p.joinAll([root, ...relative.split('/')]));
    if (!p.isWithin(root, file.path)) {
      throw const UpdateInstallException('Путь в пакете выходит за папку.');
    }
    return file;
  }

  /// Reads the transaction, checks the staged files and tells the running
  /// application (`started`, then `ready`) that it may close.
  Future<void> prepare({String? runningVersion}) async {
    try {
      final file = config.absolute;
      // Shows the application that the installer is alive before the slower
      // verification below.
      File(p.join(file.parent.path, 'started')).writeAsStringSync('started');
      final value = jsonDecode(await file.readAsString());
      if (value is! Map<String, dynamic>) throw const FormatException();
      transactionDir = p.normalize(value['transactionDir'] as String);
      installDir = p.normalize(value['installDir'] as String);
      stageDir = p.normalize(value['stageDir'] as String);
      expectedVersion = value['expectedVersion'] as String;
      files = [
        for (final item in value['files'] as List)
          UpdatePackageFile(
            (item as Map)['path'] as String,
            item['sha256'] as String,
            item['bytes'] as int,
          ),
      ];
      if (!p.equals(file.path, p.join(transactionDir, 'transaction.json')) ||
          !p.equals(stageDir, p.join(transactionDir, 'stage')) ||
          p.equals(installDir, p.rootPrefix(installDir)) ||
          p.equals(installDir, transactionDir) ||
          p.isWithin(installDir, transactionDir) ||
          p.isWithin(transactionDir, installDir)) {
        throw const UpdateInstallException('Неверные папки обновления.');
      }
      final names = <String>{};
      for (final item in files) {
        if (!safeUpdatePath(item.path) ||
            !names.add(item.path.toLowerCase()) ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(item.sha256) ||
            item.bytes < 0) {
          throw const UpdateInstallException('Неверный список файлов пакета.');
        }
      }
      if (files.length > 10000 ||
          !names.contains('pepehub.exe') ||
          !names.contains('flutter_windows.dll')) {
        throw const UpdateInstallException('Пакет приложения неполный.');
      }
      if (runningVersion != null && runningVersion != expectedVersion) {
        throw UpdateInstallException(
          'В пакете версия $runningVersion, а ожидалась $expectedVersion.',
        );
      }
      if (!await installedExecutable.exists()) {
        throw const UpdateInstallException(
          'Не найден установленный pepehub.exe.',
        );
      }
      _step('Проверяем файлы обновления…');
      for (final item in files) {
        final source = _target(stageDir, item.path);
        if (await FileSystemEntity.type(source.path, followLinks: false) !=
                FileSystemEntityType.file ||
            await source.length() != item.bytes ||
            await _digest(source) != item.sha256) {
          throw UpdateInstallException(
            'Распакованный файл повреждён: ${item.path}.',
          );
        }
      }
      // Fails here, while the application is still open, when the folder is
      // read-only (Program Files without administrator rights, for example).
      final probe = File(p.join(installDir, '.pepehub-write-test'));
      try {
        await probe.writeAsString('update');
        await probe.delete();
      } on FileSystemException {
        throw UpdateInstallException(
          'Нет права записи в папку приложения: $installDir. '
          'Перенесите PepeHub в обычную папку или обновите его вручную.',
        );
      }
      _marker('ready').writeAsStringSync('ready');
      _status('waiting');
    } catch (error) {
      final message = error is UpdateInstallException
          ? error.message
          : 'Не удалось прочитать задание обновления: $error';
      try {
        File(p.join(config.absolute.parent.path, 'failure.txt'))
            .writeAsStringSync(message);
      } on FileSystemException {
        /* The application then reports that the installer went silent. */
      }
      throw UpdateInstallException(message, beforeClose: true);
    }
  }

  /// Waits for the application to close, replaces its files and returns once
  /// the installation is complete. On failure the previous files are back in
  /// place before the exception leaves this method.
  Future<void> install() async {
    _step('Ждём закрытия PepeHub…');
    final watch = Stopwatch()..start();
    while (true) {
      if (await _marker('cancel').exists()) {
        throw const UpdateInstallException(
          'Обновление отменено приложением.',
          beforeClose: true,
        );
      }
      if (await replaceable(installedExecutable)) break;
      if (watch.elapsed >= closeTimeout) {
        throw const UpdateInstallException(
          'PepeHub не закрылся. Закройте все его окна и повторите.',
        );
      }
      await Future<void>.delayed(pollInterval);
    }
    try {
      await _apply();
    } catch (error) {
      var message = error is UpdateInstallException
          ? error.message
          : _describe(error);
      try {
        await _restore();
        _status('rolledBack');
        message += '\nПрежняя версия сохранена.';
      } catch (_) {
        message +=
            '\nНе все файлы прежней версии удалось вернуть. Их копия лежит '
            'в $_backupDir.';
      }
      try {
        _marker('failure.txt').writeAsStringSync(message);
      } on FileSystemException {
        /* The message is still shown in the window. */
      }
      throw UpdateInstallException(message);
    }
  }

  Future<void> launch() => start(installedExecutable);

  static String _describe(Object error) => error is FileSystemException
      ? '${error.message}: ${error.path ?? ''}'
            '${error.osError == null ? '' : ' (${error.osError!.message.trim()})'}'
      : '$error';

  Future<void> _apply() async {
    _touched.clear();
    _before.clear();
    final managed = [for (final item in files) item.path];
    final receipt = File(p.join(installDir, updateReceiptName));
    if (await receipt.exists()) {
      try {
        final previous = jsonDecode(await receipt.readAsString());
        for (final old in (previous as Map)['files'] as List) {
          // An unreadable entry is simply never cleaned up.
          if (old is String && safeUpdatePath(old) && !managed.contains(old)) {
            managed.add(old);
          }
        }
      } catch (_) {
        /* A damaged receipt only means obsolete files stay in place. */
      }
    }
    managed.add(updateReceiptName);
    _step('Сохраняем копию прежней версии…');
    await Directory(_backupDir).create(recursive: true);
    for (final relative in managed) {
      final original = _target(installDir, relative);
      final kind = await FileSystemEntity.type(
        original.path,
        followLinks: false,
      );
      if (kind == FileSystemEntityType.link) {
        throw UpdateInstallException(
          'В папке приложения ссылка вместо файла: $relative.',
        );
      }
      _before[relative] = kind == FileSystemEntityType.file;
      if (_before[relative]!) {
        final saved = _target(_backupDir, relative);
        await saved.parent.create(recursive: true);
        await _retry(() => copy(original, saved));
      }
    }
    await _marker('before.json').writeAsString(jsonEncode(_before));
    _status('applying');
    var done = 0;
    for (final item in files) {
      _step('Копируем файлы: ${++done} из ${files.length}');
      final destination = _target(installDir, item.path);
      await destination.parent.create(recursive: true);
      _touched.add(item.path);
      await _retry(() => copy(_target(stageDir, item.path), destination));
    }
    final current = {for (final item in files) item.path.toLowerCase()};
    for (final relative in managed) {
      if (relative == updateReceiptName ||
          current.contains(relative.toLowerCase())) {
        continue;
      }
      _touched.add(relative);
      final obsolete = _target(installDir, relative);
      if (await obsolete.exists()) await _retry(obsolete.delete);
    }
    _touched.add(updateReceiptName);
    await receipt.writeAsString(
      jsonEncode({
        'version': expectedVersion,
        'files': [for (final item in files) item.path],
      }),
    );
    _status('complete');
  }

  /// An antivirus or the search indexer may hold a fresh file for a moment.
  Future<void> _retry(Future<void> Function() action) async {
    for (var attempt = 1; ; attempt++) {
      try {
        return await action();
      } on FileSystemException {
        if (attempt >= copyAttempts) rethrow;
        await Future<void>.delayed(pollInterval);
      }
    }
  }

  static Future<String> _digest(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  Future<void> _restore() async {
    final failed = <String>[];
    for (final relative in _touched.reversed) {
      try {
        final destination = _target(installDir, relative);
        if (_before[relative] == true) {
          final saved = _target(_backupDir, relative);
          // A file whose replacement never started is already in place.
          if (await destination.exists() &&
              await _digest(destination) == await _digest(saved)) {
            continue;
          }
          await destination.parent.create(recursive: true);
          await _retry(() => copy(saved, destination));
        } else if (await destination.exists()) {
          await _retry(destination.delete);
        }
      } catch (_) {
        failed.add(relative);
      }
    }
    if (failed.isNotEmpty) throw StateError(failed.join(', '));
  }
}

class UpdatePackageFile {
  final String path, sha256;
  final int bytes;
  const UpdatePackageFile(this.path, this.sha256, this.bytes);
}
