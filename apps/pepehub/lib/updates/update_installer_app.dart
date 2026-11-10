import 'dart:io';

import 'package:flutter/material.dart';

import '../ui/app_theme.dart';
import 'update_installer.dart';
import 'update_service.dart';

/// Entry point of `pepehub.exe --apply-update <transaction.json>`.
///
/// Opens neither the library nor the database: this process only replaces the
/// installed files and starts the installed application.
Future<void> runUpdateInstaller(String configPath) async {
  WidgetsFlutterBinding.ensureInitialized();
  final step = ValueNotifier('Готовим обновление…');
  final installer = WindowsUpdateInstaller(
    File(configPath),
    onStep: (text) => step.value = text,
  );
  runApp(UpdateInstallerApp(installer: installer, step: step, start: false));
  String? running;
  try {
    final info = await const NativeUpdatePlatform().info();
    running = '${info.version}+${info.versionCode}';
  } catch (_) {
    /* The staged files are still verified by their hashes. */
  }
  try {
    await installer.prepare(runningVersion: running);
  } on UpdateInstallException {
    // The application is still open and shows the reason from failure.txt.
    exit(1);
  }
  runApp(UpdateInstallerApp(installer: installer, step: step));
}

class UpdateInstallerApp extends StatefulWidget {
  final WindowsUpdateInstaller installer;
  final ValueNotifier<String> step;
  final bool start;
  final void Function(int code) quit;
  const UpdateInstallerApp({
    super.key,
    required this.installer,
    required this.step,
    this.start = true,
    this.quit = exit,
  });

  @override
  State<UpdateInstallerApp> createState() => _UpdateInstallerAppState();
}

class _UpdateInstallerAppState extends State<UpdateInstallerApp> {
  String? error;
  bool installed = false, busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.start) _install();
  }

  @override
  void didUpdateWidget(UpdateInstallerApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.start && !oldWidget.start) _install();
  }

  Future<void> _install() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (!installed) await widget.installer.install();
      installed = true;
      widget.step.value = 'Открываем PepeHub…';
      try {
        await widget.installer.launch();
      } catch (failure) {
        throw UpdateInstallException(
          'Обновление установлено, но PepeHub не открылся сам: $failure\n'
          'Откройте его как обычно.',
        );
      }
      widget.quit(0);
    } on UpdateInstallException catch (failure) {
      // Cancelled by the application, which is still running.
      if (failure.beforeClose) return widget.quit(1);
      if (mounted) setState(() => error = failure.message);
    } catch (failure) {
      if (mounted) setState(() => error = '$failure');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _openInstalled() async {
    try {
      await widget.installer.launch();
      widget.quit(0);
    } catch (failure) {
      if (mounted) setState(() => error = 'PepeHub не открылся: $failure');
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Обновление PepeHub',
    theme: AppTheme.data(Brightness.dark),
    home: Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: error == null
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 24),
                      const Text(
                        'Обновляем PepeHub',
                        style: TextStyle(fontSize: 22),
                      ),
                      const SizedBox(height: 8),
                      ValueListenableBuilder(
                        valueListenable: widget.step,
                        builder: (_, text, _) =>
                            Text(text, textAlign: TextAlign.center),
                      ),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        installed
                            ? 'Обновление установлено'
                            : 'Обновление не установлено',
                        style: const TextStyle(fontSize: 22),
                      ),
                      const SizedBox(height: 12),
                      SelectableText(error!, textAlign: TextAlign.center),
                      const SizedBox(height: 24),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        alignment: WrapAlignment.center,
                        children: [
                          if (!installed)
                            FilledButton(
                              onPressed: _install,
                              child: const Text('Повторить'),
                            ),
                          OutlinedButton(
                            onPressed: _openInstalled,
                            child: Text(
                              installed
                                  ? 'Открыть PepeHub'
                                  : 'Открыть прежнюю версию',
                            ),
                          ),
                          TextButton(
                            onPressed: () => widget.quit(0),
                            child: const Text('Закрыть'),
                          ),
                        ],
                      ),
                    ],
                  ),
          ),
        ),
      ),
    ),
  );
}
