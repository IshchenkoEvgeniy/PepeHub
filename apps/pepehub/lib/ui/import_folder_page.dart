import 'package:flutter/material.dart';

import '../media/asset_store.dart';
import '../media/import_folder.dart';
import '../media/audio_player_scope.dart';
import 'audio_mini_player.dart';
import '../diagnostics/user_message.dart';

class ImportFolderPage extends StatefulWidget {
  final AssetStore assets;
  final Future<String?> Function()? pick;
  const ImportFolderPage({super.key, required this.assets, this.pick});
  @override
  State<ImportFolderPage> createState() => _ImportFolderPageState();
}

class _ImportFolderPageState extends State<ImportFolderPage> {
  late final store = ImportFolder(widget.assets);
  String? root;
  bool busy = true;
  int count = 0, done = 0, total = 0;
  String? message, error;
  @override
  void initState() {
    super.initState();
    _run(() async {});
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
      final path = await store.load();
      final items = await store.candidates();
      if (mounted) {
        setState(() {
          root = path;
          count = items.length;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = describeError(e));
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          total = 0;
        });
      }
    }
  }

  Future<void> _choose() => _run(() async {
    final path = await (widget.pick ?? pickImportFolder)();
    if (path == null) return;
    await store.configure(path);
    message = 'Новые текстовые книги будут сохраняться в выбранную папку.';
  });

  Future<void> _copy() => _run(() async {
    final copied = await store.copyExisting(
      onProgress: (value, limit) {
        if (mounted) {
          setState(() {
            done = value;
            total = limit;
          });
        }
      },
    );
    message = 'Скопировано книг: $copied. Прогресс и история сохранены.';
  });

  Future<void> _clear() => _run(() async {
    await store.clear();
    message = 'Новые книги будут открываться из исходного расположения.';
  });

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('Папка добавленных книг')),
      bottomNavigationBar: AudioMiniPlayer(
        controller: AudioPlayerScope.of(context),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Без папки импорта PepeHub открывает добавленные файлы на их месте. Выберите папку, если хотите собирать книги и журналы чтения в одном месте для Syncthing.',
          ),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Папка импорта',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    root ?? 'Не выбрана. Приложение открывает оригиналы.',
                  ),
                  if (root != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: busy ? null : _clear,
                        child: const Text('Отключить папку импорта'),
                      ),
                    ),
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      key: const ValueKey('choose-import-folder'),
                      onPressed: busy ? null : _choose,
                      icon: const Icon(Icons.folder_open_outlined),
                      label: Text(
                        root == null ? 'Выбрать папку' : 'Изменить папку',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('Ранее добавленные книги: $count'),
          const SizedBox(height: 8),
          const Text(
            'Их можно скопировать в выбранную папку вместе с журналами чтения. Исходные файлы останутся на месте. Подключённые папки не переносятся.',
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey('copy-existing-imports'),
              onPressed: busy || root == null || count == 0 ? null : _copy,
              icon: const Icon(Icons.drive_file_move_outlined),
              label: const Text('Скопировать ранее добавленные'),
            ),
          ),
          if (busy) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(value: total == 0 ? null : done / total),
            if (total > 0) Text('Скопировано: $done из $total'),
          ],
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(message!),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    ),
  );
}
