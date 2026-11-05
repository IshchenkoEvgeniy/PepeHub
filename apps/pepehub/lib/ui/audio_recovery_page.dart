import 'package:file_selector/file_selector.dart';

import '../audio/audio_sidecar.dart';

import 'package:flutter/material.dart';

import '../audio/audio_roots.dart';
import '../audio/audio_folder.dart';
import '../media/asset_store.dart';

class AudioRecoveryPage extends StatefulWidget {
  final AssetStore assets;
  const AudioRecoveryPage({super.key, required this.assets});
  @override
  State<AudioRecoveryPage> createState() => _AudioRecoveryPageState();
}

class _AudioRecoveryPageState extends State<AudioRecoveryPage> {
  late final manager = AudioRoots(widget.assets);
  List<AudioRoot> roots = [];
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
      if (mounted) {
        setState(() {
          roots = items;
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
      widget.assets.repository.notifyExternalChange();
      if (mounted) setState(() => message = result);
    } catch (e) {
      if (mounted) setState(() => message = '$e');
    } finally {
      await load();
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> restoreLogs(AudioRoot root) async => run(() async {
    final files = await openFiles(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Журнал',
          extensions: ['json', 'bak'],
          mimeTypes: ['application/json', 'application/octet-stream'],
        ),
      ],
    );
    if (files.isEmpty) return 'Отменено';
    if (files.length > 100) {
      throw StateError('Выберите до 100 пакетов за один раз');
    }
    final snapshots = <Map<String, dynamic>>[];
    var size = 0, count = 0;
    for (final file in files) {
      size += await file.length();
      if (size > 64 * 1024 * 1024) {
        throw StateError('За один раз можно восстановить до 64 МиБ журнала');
      }
      final snapshot = parseAudioSnapshot(await file.readAsString());
      if (snapshot['kind'] != 'audio-journal') {
        throw StateError('Выберите файлы events-*.json');
      }
      snapshots.add(snapshot);
      count += (snapshot['events'] as List).length;
    }
    if (!mounted) return 'Отменено';
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Восстановить подробный журнал?'),
        content: Text(
          'Пакетов: ${files.length}, событий: $count. Существующие события не будут продублированы.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Восстановить'),
          ),
        ],
      ),
    );
    if (ok != true) return 'Отменено';
    await saveAudioSidecar(
      widget.assets,
      AudioFolder(root.title, [], root: root.path),
    );
    await widget.assets.repository.db.transaction(() async {
      for (final snapshot in snapshots) {
        await restoreAudioSnapshot(
          widget.assets,
          root,
          snapshot,
          backup: false,
        );
      }
    });
    return 'Восстановлено событий: $count';
  });

  Future<void> restore(AudioRoot root) async {
    await run(() async {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'Снимок PepeHub',
            extensions: ['json'],
            mimeTypes: ['application/json'],
          ),
        ],
      );
      if (file == null) return 'Восстановление отменено';
      if (await file.length() > 16 * 1024 * 1024) {
        throw StateError('Снимок больше 16 МиБ');
      }
      final snapshot = parseAudioSnapshot(await file.readAsString());
      if (!mounted) return 'Отменено';
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Восстановить снимок?'),
          content: Text(
            'Дата: ${snapshot['createdAt']}\nКниг: ${(snapshot['books'] as List).length}, сессий: ${(snapshot['sessions'] as List).length}.\nПозиции, обложки и закладки будут заменены, сессии объединены по ID. Перед заменой сохраним текущий снимок. Аудиофайлы не изменятся.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Восстановить'),
            ),
          ],
        ),
      );
      if (accepted != true) return 'Восстановление отменено';
      final count = await restoreAudioSnapshot(widget.assets, root, snapshot);
      return 'Восстановлено книг: $count';
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('Восстановление аудиоданных')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Выберите исходную папку аудиокниг. Снимок содержит позиции, закладки и настройки; подробный журнал — события прослушивания.',
            ),
          ),
          if (busy) const LinearProgressIndicator(),
          if (message.isNotEmpty)
            Padding(padding: const EdgeInsets.all(16), child: Text(message)),
          Expanded(
            child: roots.isEmpty
                ? const Center(
                    child: Text(
                      'Сначала подключите папку в «Папки аудиокниг».',
                    ),
                  )
                : ListView.builder(
                    itemCount: roots.length,
                    itemBuilder: (context, index) {
                      final root = roots[index];
                      return Card(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                root.title,
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              Text(root.path),
                              Wrap(
                                spacing: 8,
                                children: [
                                  TextButton.icon(
                                    onPressed: busy
                                        ? null
                                        : () => run(() async {
                                            await saveAudioSidecar(
                                              widget.assets,
                                              AudioFolder(
                                                root.title,
                                                [],
                                                root: root.path,
                                              ),
                                            );
                                            return 'Снимок сохранён в .pepehub';
                                          }),
                                    icon: const Icon(Icons.save_outlined),
                                    label: const Text('Сохранить снимок'),
                                  ),
                                  TextButton.icon(
                                    onPressed: busy
                                        ? null
                                        : () => restore(root),
                                    icon: const Icon(Icons.restore),
                                    label: const Text('Восстановить снимок'),
                                  ),
                                  TextButton.icon(
                                    onPressed: busy
                                        ? null
                                        : () => restoreLogs(root),
                                    icon: const Icon(Icons.history),
                                    label: const Text(
                                      'Восстановить подробный журнал',
                                    ),
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
