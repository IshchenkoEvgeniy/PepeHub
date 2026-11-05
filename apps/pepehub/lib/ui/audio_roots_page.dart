import 'package:flutter/material.dart';

import '../audio/audio_roots.dart';
import '../audio/audio_folder.dart';
import '../media/asset_store.dart';
import '../media/library_folder_preference.dart';
import '../media/audio_player_scope.dart';
import 'audio_mini_player.dart';
import 'folder_scan_summary.dart';

class AudioRootsPage extends StatefulWidget {
  final AssetStore assets;
  const AudioRootsPage({super.key, required this.assets});
  @override
  State<AudioRootsPage> createState() => _AudioRootsPageState();
}

class _AudioRootsPageState extends State<AudioRootsPage> {
  late final manager = AudioRoots(widget.assets);
  List<AudioRoot> roots = [];
  String? pinnedRoot;
  late final preference = LibraryFolderPreference(
    widget.assets.repository,
    reading: false,
  );
  bool busy = false;
  String message = '';
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final items = await manager.list();
      final pinned = await preference.load();
      if (mounted) {
        setState(() {
          roots = items;
          pinnedRoot = pinned;
        });
      }
    } catch (e) {
      if (mounted) setState(() => message = '$e');
    }
  }

  Future<void> run(Future<String> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = '';
    });
    try {
      final result = await action();
      if (mounted) setState(() => message = result);
    } catch (e) {
      if (mounted) setState(() => message = '$e');
    } finally {
      await load();
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> rename(AudioRoot root) async {
    var title = root.title;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Название папки в PepeHub'),
        content: TextFormField(
          initialValue: title,
          onChanged: (value) => title = value,
          maxLength: 500,
          autofocus: true,
          decoration: const InputDecoration(
            helperText: 'Имя папки на диске не изменится',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, title),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (result != null && mounted) {
      await run(() async {
        await manager.rename(root, result);
        return 'Название сохранено';
      });
    }
  }

  Future<void> remove(AudioRoot root) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Отключить папку аудиокниг?'),
        content: Text(
          '${root.title}\nАудиокниги этой папки скроются из списка файлов. Исходные файлы, позиции и история останутся. Повторное подключение вернёт книги.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Отключить'),
          ),
        ],
      ),
    );
    if (yes == true && mounted) {
      await run(() async {
        await manager.remove(root);
        return 'Папка аудиокниг отключена';
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('Папки аудиокниг')),
      bottomNavigationBar: AudioMiniPlayer(
        controller: AudioPlayerScope.of(context),
      ),
      body: Column(
        children: [
          if (busy) const LinearProgressIndicator(),
          if (message.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(message),
                ),
              ),
            ),
          Expanded(
            child: roots.isEmpty
                ? const Center(child: Text('Подключённых корневых папок нет'))
                : ListView.builder(
                    itemCount: roots.length,
                    itemBuilder: (_, i) {
                      final root = roots[i];
                      return Card(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                root.title,
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              Text('${root.bookIds.length} книг'),
                              FolderScanSummary(
                                audio: true,
                                lastScan: DateTime.tryParse(
                                  '${root.data['lastScan']}',
                                ),
                                report: (root.data['lastReport'] as Map?)
                                    ?.cast<String, dynamic>(),
                                warnings:
                                    (root.data['warnings'] as List?)
                                        ?.cast<String>() ??
                                    const [],
                              ),
                              SelectableText(
                                root.path,
                                style: const TextStyle(fontSize: 12),
                              ),
                              Wrap(
                                spacing: 8,
                                children: [
                                  TextButton.icon(
                                    onPressed: busy
                                        ? null
                                        : () => run(() async {
                                            await preference.set(
                                              pinnedRoot == root.key
                                                  ? null
                                                  : root.key,
                                            );
                                            return pinnedRoot == root.key
                                                ? 'Закрепление снято'
                                                : 'Папка будет открываться по умолчанию';
                                          }),
                                    icon: Icon(
                                      pinnedRoot == root.key
                                          ? Icons.push_pin
                                          : Icons.push_pin_outlined,
                                    ),
                                    label: Text(
                                      pinnedRoot == root.key
                                          ? 'Открепить по умолчанию'
                                          : 'Открывать по умолчанию',
                                    ),
                                  ),
                                  TextButton.icon(
                                    onPressed: busy
                                        ? null
                                        : () => run(
                                            () async =>
                                                (await manager.refresh(root))
                                                    .message,
                                          ),
                                    icon: const Icon(Icons.refresh),
                                    label: const Text('Обновить'),
                                  ),
                                  TextButton.icon(
                                    onPressed: busy ? null : () => rename(root),
                                    icon: const Icon(Icons.edit),
                                    label: const Text('Переименовать'),
                                  ),
                                  TextButton.icon(
                                    onPressed: busy
                                        ? null
                                        : () => run(() async {
                                            final folder =
                                                await pickAudioFolder();
                                            if (folder == null) {
                                              return 'Замена отменена';
                                            }
                                            return (await manager.refresh(
                                              root,
                                              replacement: folder,
                                            )).message;
                                          }),
                                    icon: const Icon(
                                      Icons.drive_file_move_outline,
                                    ),
                                    label: const Text('Изменить путь'),
                                  ),
                                  TextButton.icon(
                                    onPressed: busy ? null : () => remove(root),
                                    icon: const Icon(Icons.link_off),
                                    label: const Text('Отключить папку'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
  );
}
