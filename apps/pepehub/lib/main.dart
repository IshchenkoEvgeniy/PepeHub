import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'ui/app_theme.dart';
import 'ui/goal_reminders.dart';
import 'ui/goal_settings_page.dart';
import 'updates/update_installer.dart';
import 'updates/update_installer_app.dart';
import 'updates/update_service.dart';
import 'updates/update_page.dart';

import 'diagnostics/error_log.dart';
import 'diagnostics/user_message.dart';
import 'data/database.dart';
import 'data/repository.dart';
import 'media/asset_store.dart';
import 'media/audio_controller.dart';
import 'media/audio_player_scope.dart';
import 'ui/library_page.dart';
import 'reader/reader_routes.dart';
import 'video/video_repository.dart';
import 'video/video_session.dart';
import 'video/video_player_page.dart';
import 'video/video_mini_player.dart';

Future<void> main([List<String> args = const []]) {
  // The unpacked new version installs itself over the old one; see
  // WindowsUpdateInstaller.
  final update = Platform.isWindows ? updateInstallerConfig(args) : null;
  return update == null ? startPepeHub() : runUpdateInstaller(update);
}

const _russian = Locale('ru');
const _localizations = <LocalizationsDelegate<Object>>[
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];

Future<void> startPepeHub({
  Future<AppDatabase> Function()? openDatabase,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  ErrorLog.install();
  unawaited(_attachErrorLog());
  // Paint immediately; the library opens behind a lightweight screen.
  runApp(const _StartupScreen());
  try {
    final db = await (openDatabase ?? AppDatabase.open)();
    await db.customSelect('SELECT 1').get();
    final repository = Repository(db);
    final assets = await AssetStore.open(repository);
    final (audio, audioError) = await _startAudio(assets);
    runApp(
      PepeHubApp(
        repository: repository,
        assets: assets,
        audio: audio,
        audioError: audioError,
      ),
    );
  } catch (error, stack) {
    ErrorLog.record(error, stack, context: 'startup');
    runApp(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        locale: _russian,
        supportedLocales: const [_russian],
        localizationsDelegates: _localizations,
        theme: AppTheme.data(Brightness.dark),
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: SelectableText(
                'Не удалось открыть библиотеку. Данные не сброшены.\n'
                '${describeError(error)}',
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _attachErrorLog({String name = 'errors.log'}) async {
  try {
    final support = await getApplicationSupportDirectory();
    ErrorLog.attach(Directory(p.join(support.path, 'logs')), name: name);
  } catch (_) {
    // Without a support folder errors stay in memory and debug output.
  }
}

Future<(AudioController?, String?)> _startAudio(AssetStore assets) async {
  try {
    return (await AudioController.create(assets), null);
  } catch (error, stack) {
    ErrorLog.record(error, stack, context: 'audio startup');
    return (null, 'Аудиоплеер не запустился: ${describeError(error)}');
  }
}

class _StartupScreen extends StatelessWidget {
  const _StartupScreen();
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.data(Brightness.dark),
    home: const Scaffold(
      body: Center(
        child: SizedBox.square(
          dimension: 28,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      ),
    ),
  );
}

class PepeHubApp extends StatefulWidget {
  final Repository repository;
  final AssetStore? assets;
  final AudioController? audio;
  final String? audioError;
  const PepeHubApp({
    super.key,
    required this.repository,
    this.assets,
    this.audio,
    this.audioError,
  });
  @override
  State<PepeHubApp> createState() => _PepeHubAppState();
}

class _PepeHubAppState extends State<PepeHubApp> {
  late final updates = UpdateService(
    widget.repository,
    prepareRestart: () async {
      navigator.currentState?.popUntil((route) => route.isFirst);
      await WidgetsBinding.instance.endOfFrame;
      await videos.close();
      await widget.audio?.pause();
      await widget.audio?.flushJournal();
    },
  );
  final messenger = GlobalKey<ScaffoldMessengerState>();
  String? _notifiedUpdate;
  late final theme = AppTheme(widget.repository);
  final navigator = GlobalKey<NavigatorState>();
  late final reminders = GoalReminderService(
    widget.repository,
    foreground: () =>
        mounted &&
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
    show: () {
      final host = messenger.currentState;
      if (host == null) return false;
      host.showSnackBar(
        SnackBar(
          // Flutter keeps snack bars with an action until dismissed.
          persist: false,
          content: const Text(
            'Время для чтения или аудиокниги. Проверьте свои цели на сегодня.',
          ),
          duration: const Duration(seconds: 15),
          action: SnackBarAction(
            label: 'Цели',
            onPressed: () => navigator.currentState?.push(
              MaterialPageRoute<void>(
                builder: (_) => GoalSettingsPage(repository: widget.repository),
              ),
            ),
          ),
        ),
      );
      return true;
    },
  );
  late final videos = VideoPlaybackSession(
    VideoRepository(widget.repository),
    audio: widget.audio,
  );
  @override
  void initState() {
    super.initState();
    theme.load();
    reminders.start();
    WidgetsBinding.instance.addPostFrameCallback((_) => reminders.check());
    updates.addListener(_updateNotice);
    unawaited(updates.initialize());
    widget.repository.externalChanges.addListener(_externalChange);
  }

  void _externalChange() {
    if (mounted) unawaited(theme.load());
  }

  void _updateNotice() {
    final release = updates.release;
    if (release == null ||
        !updates.available ||
        _notifiedUpdate == '${release.version}+${release.build}') {
      return;
    }
    final host = messenger.currentState;
    if (host == null) return;
    _notifiedUpdate = '${release.version}+${release.build}';
    host.showSnackBar(
      SnackBar(
        // Flutter keeps snack bars with an action until dismissed.
        persist: false,
        content: Text('Доступно обновление PepeHub ${release.version}'),
        duration: const Duration(seconds: 10),
        action: SnackBarAction(
          label: 'Открыть',
          onPressed: () {
            navigator.currentState?.push(
              MaterialPageRoute<void>(
                builder: (_) => UpdatePage(service: updates),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  void dispose() {
    widget.repository.externalChanges.removeListener(_externalChange);
    reminders.dispose();
    theme.dispose();
    updates.removeListener(_updateNotice);
    updates.dispose();
    videos.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: theme,
    builder: (context, _) => ThemeScope(
      controller: theme,
      child: MaterialApp(
        title: 'PepeHub',
        locale: _russian,
        supportedLocales: const [_russian],
        localizationsDelegates: _localizations,
        navigatorKey: navigator,
        scaffoldMessengerKey: messenger,
        navigatorObservers: [readerRoutes],
        debugShowCheckedModeBanner: false,
        theme: theme.lightTheme,
        darkTheme: theme.darkTheme,
        themeMode: theme.themeMode,
        builder: (context, child) {
          final media = MediaQuery.of(context);
          return MediaQuery(
            data: media.copyWith(
              textScaler: TextScaler.linear(
                media.textScaler.scale(1) * theme.textScale,
              ),
              disableAnimations: media.disableAnimations || theme.reduceMotion,
            ),
            child: UpdateScope(
              service: updates,
              child: AudioPlayerScope(
                controller: widget.audio,
                child: VideoSessionScope(
                  session: videos,
                  child: Overlay.wrap(
                    child: Stack(
                      children: [
                        child!,
                        VideoMiniPlayer(
                          session: videos,
                          onOpen: () {
                            final item = videos.item,
                                player = videos.controller;
                            if (item == null ||
                                player == null ||
                                videos.pageAttached) {
                              return;
                            }
                            navigator.currentState?.push(
                              MaterialPageRoute<void>(
                                builder: (_) => VideoPlayerPage(
                                  repository: videos.repository,
                                  item: item,
                                  lessons: player.lessons,
                                  initialIndex: player.index,
                                  session: videos,
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
        home: LibraryPage(
          repository: widget.repository,
          assets: widget.assets,
          audio: widget.audio,
          audioError: widget.audioError,
        ),
      ),
    ),
  );
}
