import 'package:flutter/material.dart';

import '../reader/reading_roots.dart';
import '../audio/audio_folder.dart';
import '../media/asset_store.dart';

class ReadingRootsPage extends StatefulWidget {
  final AssetStore assets;
  const ReadingRootsPage({super.key, required this.assets});
  @override
  State<ReadingRootsPage> createState() => _ReadingRootsPageState();
}

class _ReadingRootsPageState extends State<ReadingRootsPage> {
  late final store = ReadingRoots(widget.assets);
  List<ReadingRoot> roots = [];
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
      if (mounted) setState(() => roots = values);
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
              title: Text(root.title),
              subtitle: Text('${root.bookIds.length} книг\n${root.path}'),
              trailing: PopupMenuButton<String>(
                enabled: !busy,
                onSelected: (v) => _run(() async {
                  if (v == 'refresh') {
                    await store.connect(
                      await rescanAudioFolder(root.path, books: true),
                    );
                  } else {
                    await store.disconnect(root);
                  }
                }),
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'refresh',
                    child: Text('Обновить папку'),
                  ),
                  PopupMenuItem(
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
