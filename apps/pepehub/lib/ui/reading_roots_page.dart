import 'package:flutter/material.dart';

import '../reader/reading_roots.dart';
import '../audio/audio_folder.dart';
import '../media/asset_store.dart';
import '../media/library_folder_preference.dart';
import '../media/audio_player_scope.dart';
import 'audio_mini_player.dart';

class ReadingRootsPage extends StatefulWidget {
  final AssetStore assets;
  const ReadingRootsPage({super.key, required this.assets});
  @override
  State<ReadingRootsPage> createState() => _ReadingRootsPageState();
}

class _ReadingRootsPageState extends State<ReadingRootsPage> {
  late final store = ReadingRoots(widget.assets);
  List<ReadingRoot> roots = [];
  String? pinnedRoot;
  late final preference = LibraryFolderPreference(
    widget.assets.repository,
    reading: true,
  );
  bool busy = false;
  String error = '';
  @override
  void initState() {
    super.initState();
    _run(() async {});
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
      final values = await store.list();
      final pinned = await preference.load();
      if (mounted) {
        setState(() {
          roots = values;
          pinnedRoot = pinned;
        });
      }
      error = '';
    } catch (e) {
      error = '$e';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Папки книг')),
    bottomNavigationBar: AudioMiniPlayer(
      controller: AudioPlayerScope.of(context),
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Отдельные папки для EPUB, FB2, TXT, PDF и других текстовых форматов. На Android открываемая книга кэшируется локально для чтения.',
        ),
        FilledButton.icon(
          onPressed: busy
              ? null
              : () => _run(() async {
                  final folder = await pickAudioFolder(books: true);
                  if (folder != null) await store.connect(folder);
                }),
          icon: const Icon(Icons.create_new_folder_outlined),
          label: const Text('Подключить папку книг'),
        ),
        if (busy) const LinearProgressIndicator(),
        if (error.isNotEmpty) Text(error),
        for (final root in roots)
          Card(
            child: ListTile(
              leading: root.key == pinnedRoot
                  ? const Icon(Icons.push_pin)
                  : null,
              title: Text(root.title),
              subtitle: Text('${root.bookIds.length} книг\n${root.path}'),
              trailing: PopupMenuButton<String>(
                enabled: !busy,
                onSelected: (v) => _run(() async {
                  if (v == 'refresh') {
                    await store.connect(
                      await rescanAudioFolder(root.path, books: true),
                    );
                  } else if (v == 'pin') {
                    await preference.set(
                      pinnedRoot == root.key ? null : root.key,
                    );
                  } else {
                    await store.disconnect(root);
                  }
                }),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'pin',
                    child: Text(
                      pinnedRoot == root.key
                          ? 'Открепить по умолчанию'
                          : 'Открывать по умолчанию',
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'refresh',
                    child: Text('Обновить папку'),
                  ),
                  const PopupMenuItem(
                    value: 'disconnect',
                    child: Text('Отключить папку'),
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}
