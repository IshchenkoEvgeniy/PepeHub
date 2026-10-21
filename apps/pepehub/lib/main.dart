import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'sync/peer/peer_service.dart';
import 'sync/peer/peer_store.dart';
import 'sync/peer/peer_background.dart';
import 'ui/app_theme.dart';
import 'updates/update_service.dart';
import 'updates/update_page.dart';

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

Future<void> main() => startPepeHub();

@pragma('vm:entry-point')
Future<void> peerBackgroundMain() => runPeerBackground();

Future<void> startPepeHub({
  Future<AppDatabase> Function()? openDatabase,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await claimPeerForeground();
    final db = await (openDatabase ?? AppDatabase.open)();
    await db.customSelect('SELECT 1').get();
    final repository = Repository(db);
    await repository.initializeTransports();
    final assets = await AssetStore.open(repository);
    AudioController? audio;
    String? audioError;
    try {
      audio = await AudioController.create(assets);
    } catch (e) {
      audioError = 'Аудиоплеер не запустился: $e';
    }
    runApp(
      PepeHubApp(
        repository: repository,
        assets: assets,
        audio: audio,
        audioError: audioError,
      ),
    );
  } catch (error) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                'Не удалось открыть библиотеку. Данные не сброшены.\n$error',
              ),
            ),
          ),
        ),
      ),
    );
  }
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
      await peers.close();
    },
  );
  final messenger = GlobalKey<ScaffoldMessengerState>();
  String? _notifiedUpdate;
  late final theme = AppTheme(widget.repository);
  final navigator = GlobalKey<NavigatorState>();
  late final peers = PeerSyncService(
    PeerStore(widget.repository),
    assets: widget.assets,
    workDirectory: widget.assets == null
        ? null
        : Directory(p.join(widget.assets!.directory.path, 'peer-sync')),
    protectsTarget: (target) =>
        target.startsWith('p:audio:') &&
            widget.audio?.canPlay == true &&
            target == 'p:audio:${widget.audio?.progressEditionId}' ||
        target.startsWith('p:video:') &&
            videos.controller?.current != null &&
            target == 'p:video:${videos.controller!.current!.id}',
  );
  late final videos = VideoPlaybackSession(
    VideoRepository(widget.repository),
    audio: widget.audio,
  );
  @override
  void initState() {
    super.initState();
    theme.load();
    updates.addListener(_updateNotice);
    unawaited(updates.initialize());
    attachPeerBackground(peers);
    unawaited(peers.initialize());
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
    theme.dispose();
    updates.removeListener(_updateNotice);
    updates.dispose();
    videos.dispose();
    peers.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: theme,
    builder: (context, _) => ThemeScope(
      controller: theme,
      child: MaterialApp(
        title: 'PepeHub',
        navigatorKey: navigator,
        scaffoldMessengerKey: messenger,
        navigatorObservers: [readerRoutes],
        debugShowCheckedModeBanner: false,
        theme: AppTheme.data(
          Brightness.dark,
          style: theme.style,
          compact: theme.compact,
        ),
        themeMode: ThemeMode.dark,
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
              child: PeerSyncScope(
                service: peers,
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
