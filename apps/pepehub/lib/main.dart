import 'ui/app_theme.dart';

import 'package:flutter/material.dart';

import 'data/database.dart';
import 'data/repository.dart';
import 'media/asset_store.dart';
import 'media/audio_controller.dart';
import 'ui/library_page.dart';
import 'reader/reader_routes.dart';

Future<void> main() => startPepeHub();

Future<void> startPepeHub({
  Future<AppDatabase> Function()? openDatabase,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final db = await (openDatabase ?? AppDatabase.open)();
    await db.customSelect('SELECT 1').get();
    final repository = Repository(db);
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
  late final theme = AppTheme(widget.repository);
  @override
  void initState() {
    super.initState();
    theme.load();
  }

  @override
  void dispose() {
    theme.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: theme,
    builder: (context, _) => ThemeScope(
      controller: theme,
      child: MaterialApp(
        title: 'PepeHub',
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
            child: child!,
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
