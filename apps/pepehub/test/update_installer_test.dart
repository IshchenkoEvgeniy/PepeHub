import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pepehub/updates/update_installer.dart';
import 'package:pepehub/updates/update_installer_app.dart';

class InstallFixture {
  Directory? _root;
  Directory get root => _root!;
  late final String install, transaction, stage;
  late final File config;
  final started = <String>[];

  Future<void> open({Map<String, Object?> override = const {}}) async {
    // A space, an apostrophe and Cyrillic: real user folders contain them.
    _root = await Directory.systemTemp.createTemp("pepehub install ' тест ");
    install = p.join(root.path, 'install');
    transaction = p.join(root.path, 'transaction');
    stage = p.join(transaction, 'stage');
    write(install, 'pepehub.exe', 'old exe');
    write(install, 'flutter_windows.dll', 'old engine');
    write(install, 'data/app.so', 'old code');
    write(install, 'data/obsolete.txt', 'old managed asset');
    write(install, 'library.sqlite', 'USER DATABASE');
    write(install, 'data/note.txt', 'USER FILE NEXT TO DATA');
    write(
      install,
      updateReceiptName,
      jsonEncode({
        'version': '0.21.0+51',
        'files': [
          'pepehub.exe',
          'flutter_windows.dll',
          'data/app.so',
          'data/obsolete.txt',
          '../library.sqlite',
        ],
      }),
    );
    write(stage, 'pepehub.exe', 'new exe');
    write(stage, 'flutter_windows.dll', 'new engine');
    write(stage, 'data/app.so', 'new code');
    write(stage, 'data/fonts/new.ttf', 'new font');
    config = File(p.join(transaction, 'transaction.json'));
    save(override);
  }

  void save([Map<String, Object?> override = const {}]) {
    config.writeAsStringSync(
      jsonEncode({
        'installDir': install,
        'stageDir': stage,
        'transactionDir': transaction,
        'expectedVersion': '0.21.0+52',
        'files': [
          for (final name in [
            'data/app.so',
            'data/fonts/new.ttf',
            'flutter_windows.dll',
            'pepehub.exe',
          ])
            {
              'path': name,
              'sha256': sha256
                  .convert(File(p.join(stage, name)).readAsBytesSync())
                  .toString(),
              'bytes': File(p.join(stage, name)).lengthSync(),
            },
        ],
        ...override,
      }),
    );
  }

  void write(String folder, String name, String text) =>
      File(p.joinAll([folder, ...name.split('/')]))
        ..createSync(recursive: true)
        ..writeAsStringSync(text);
  String read(String name) =>
      File(p.joinAll([install, ...name.split('/')])).readAsStringSync();
  bool exists(String name) =>
      File(p.joinAll([install, ...name.split('/')])).existsSync();
  bool marker(String name) => File(p.join(transaction, name)).existsSync();
  String state() =>
      (jsonDecode(File(p.join(transaction, 'status.json')).readAsStringSync())
              as Map)['state']
          as String;

  WindowsUpdateInstaller installer({
    Future<bool> Function(File)? replaceable,
    Future<void> Function(File, File)? copy,
    Duration closeTimeout = const Duration(seconds: 5),
  }) => WindowsUpdateInstaller(
    config,
    closeTimeout: closeTimeout,
    pollInterval: const Duration(milliseconds: 5),
    copyAttempts: 3,
    replaceable: replaceable ?? (_) async => true,
    copy: copy,
    start: (executable) async => started.add(executable.path),
  );

  void expectOldInstallation() {
    expect(read('pepehub.exe'), 'old exe');
    expect(read('flutter_windows.dll'), 'old engine');
    expect(read('data/app.so'), 'old code');
    expect(read('data/obsolete.txt'), 'old managed asset');
    expect(exists('data/fonts/new.ttf'), false);
    expect(
      (jsonDecode(read(updateReceiptName)) as Map)['version'],
      '0.21.0+51',
    );
  }

  Future<void> close() async => _root?.delete(recursive: true);
}

void main() {
  late InstallFixture f;
  setUp(() => f = InstallFixture());
  tearDown(() => f.close());

  test('installer mode is selected only by its command-line switch', () {
    expect(updateInstallerConfig(const []), null);
    expect(updateInstallerConfig(const ['--apply-update']), null);
    expect(
      updateInstallerConfig(const ['--apply-update', r'C:\t\transaction.json']),
      r'C:\t\transaction.json',
    );
  });

  test(
    'replaces managed files, removes obsolete ones and keeps user files',
    () async {
      await f.open();
      final steps = <String>[];
      final installer = WindowsUpdateInstaller(
        f.config,
        replaceable: (_) async => true,
        start: (executable) async => f.started.add(executable.path),
        onStep: steps.add,
      );
      await installer.prepare(runningVersion: '0.21.0+52');
      expect(f.marker('started'), true);
      expect(f.marker('ready'), true);
      f.expectOldInstallation();
      await installer.install();
      expect(f.read('pepehub.exe'), 'new exe');
      expect(f.read('flutter_windows.dll'), 'new engine');
      expect(f.read('data/app.so'), 'new code');
      expect(f.read('data/fonts/new.ttf'), 'new font');
      expect(f.exists('data/obsolete.txt'), false);
      // Neither unknown files nor an unsafe receipt entry are touched.
      expect(f.read('library.sqlite'), 'USER DATABASE');
      expect(f.read('data/note.txt'), 'USER FILE NEXT TO DATA');
      final receipt = jsonDecode(f.read(updateReceiptName)) as Map;
      expect(receipt['version'], '0.21.0+52');
      expect(receipt['files'], hasLength(4));
      expect(f.state(), 'complete');
      expect(steps.last, 'Копируем файлы: 4 из 4');
      await installer.launch();
      expect(f.started, [p.join(f.install, 'pepehub.exe')]);
    },
  );

  test('waits until the application has closed', () async {
    await f.open();
    var polls = 0;
    final installer = f.installer(
      replaceable: (executable) async {
        expect(executable.path, p.join(f.install, 'pepehub.exe'));
        // Nothing may change while the old version is still running.
        f.expectOldInstallation();
        return ++polls > 3;
      },
    );
    await installer.prepare();
    await installer.install();
    expect(polls, 4);
    expect(f.read('pepehub.exe'), 'new exe');
  });

  test('gives up when the application stays open and can retry', () async {
    await f.open();
    var closed = false;
    final installer = f.installer(
      replaceable: (_) async => closed,
      closeTimeout: const Duration(milliseconds: 40),
    );
    await installer.prepare();
    await expectLater(
      installer.install(),
      throwsA(
        isA<UpdateInstallException>()
            .having((e) => e.beforeClose, 'beforeClose', false)
            .having((e) => e.message, 'message', contains('не закрылся')),
      ),
    );
    f.expectOldInstallation();
    closed = true;
    await installer.install();
    expect(f.read('pepehub.exe'), 'new exe');
  });

  test('stops quietly when the application cancels the update', () async {
    await f.open();
    final installer = f.installer(replaceable: (_) async => false);
    await installer.prepare();
    File(p.join(f.transaction, 'cancel')).writeAsStringSync('cancel');
    await expectLater(
      installer.install(),
      throwsA(
        isA<UpdateInstallException>().having(
          (e) => e.beforeClose,
          'beforeClose',
          true,
        ),
      ),
    );
    f.expectOldInstallation();
  });

  test('a failed copy restores the previous version; a retry works', () async {
    await f.open();
    var broken = true, attempts = 0;
    final installer = f.installer(
      copy: (source, destination) async {
        if (broken &&
            destination.path == p.join(f.install, 'flutter_windows.dll')) {
          attempts++;
          throw FileSystemException('Нет доступа', destination.path);
        }
        await source.copy(destination.path);
      },
    );
    await installer.prepare();
    await expectLater(
      installer.install(),
      throwsA(
        isA<UpdateInstallException>()
            .having((e) => e.beforeClose, 'beforeClose', false)
            .having(
              (e) => e.message,
              'message',
              allOf(
                contains('flutter_windows.dll'),
                contains('Прежняя версия сохранена'),
              ),
            ),
      ),
    );
    expect(attempts, 3);
    f.expectOldInstallation();
    expect(f.read('library.sqlite'), 'USER DATABASE');
    expect(f.state(), 'rolledBack');
    expect(f.marker('failure.txt'), true);
    broken = false;
    await installer.install();
    expect(f.read('flutter_windows.dll'), 'new engine');
    expect(f.exists('data/obsolete.txt'), false);
    expect(f.state(), 'complete');
  });

  test('a briefly locked file is retried', () async {
    await f.open();
    var failures = 2;
    final installer = f.installer(
      copy: (source, destination) async {
        if (destination.path == p.join(f.install, 'pepehub.exe') &&
            failures-- > 0) {
          throw FileSystemException('Файл занят', destination.path);
        }
        await source.copy(destination.path);
      },
    );
    await installer.prepare();
    await installer.install();
    expect(f.read('pepehub.exe'), 'new exe');
  });

  test('refuses damaged, unsafe and mismatched packages before the '
      'application closes', () async {
    await f.open();
    Future<void> rejected(Matcher message, {String? runningVersion}) async {
      final failure = File(p.join(f.transaction, 'failure.txt'));
      if (failure.existsSync()) failure.deleteSync();
      final ready = File(p.join(f.transaction, 'ready'));
      await expectLater(
        f.installer().prepare(runningVersion: runningVersion),
        throwsA(
          isA<UpdateInstallException>()
              .having((e) => e.beforeClose, 'beforeClose', true)
              .having((e) => e.message, 'message', message),
        ),
      );
      expect(failure.readAsStringSync(), message);
      expect(ready.existsSync(), false);
      f.expectOldInstallation();
    }

    await rejected(contains('0.21.0+53'), runningVersion: '0.21.0+53');
    f.save({
      'files': [
        {'path': '../escape.dll', 'sha256': 'a' * 64, 'bytes': 1},
      ],
    });
    await rejected(contains('список файлов'));
    f.save({'stageDir': f.install});
    await rejected(contains('папки'));
    f.save({'installDir': p.join(f.transaction, 'stage', 'data')});
    await rejected(contains('папки'));
    f.config.writeAsStringSync('not json');
    await rejected(contains('задание'));
    f.save();
    f.write(f.stage, 'data/app.so', 'tampered');
    await rejected(contains('data/app.so'));
    expect(File(p.join(f.root.path, 'escape.dll')).existsSync(), false);
  });

  testWidgets('the window reports a failure and offers a retry', (
    tester,
  ) async {
    await tester.runAsync(() => f.open());
    // File operations need the real event loop, timers the test clock.
    Future<void> settle(bool Function() done) async {
      for (var i = 0; i < 200 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 10));
      }
    }

    var closed = false;
    final codes = <int>[];
    final installer = f.installer(
      replaceable: (_) async => closed,
      closeTimeout: const Duration(milliseconds: 30),
    );
    await tester.runAsync(() => installer.prepare());
    final step = ValueNotifier('Готовим обновление…');
    await tester.pumpWidget(
      UpdateInstallerApp(installer: installer, step: step, quit: codes.add),
    );
    await settle(() => find.text('Повторить').evaluate().isNotEmpty);
    expect(find.text('Обновление не установлено'), findsOneWidget);
    expect(find.textContaining('не закрылся'), findsOneWidget);
    expect(find.text('Открыть прежнюю версию'), findsOneWidget);
    expect(codes, isEmpty);
    closed = true;
    await tester.tap(find.text('Повторить'));
    await settle(() => codes.isNotEmpty);
    expect(codes, [0]);
    expect(f.started, [p.join(f.install, 'pepehub.exe')]);
    expect(f.read('pepehub.exe'), 'new exe');
  });
}
