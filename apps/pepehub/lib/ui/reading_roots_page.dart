import 'package:flutter/material.dart';

import '../reader/reading_roots.dart';
import '../audio/audio_folder.dart';
import '../media/asset_store.dart';
import '../media/library_folder_preference.dart';
import '../media/audio_player_scope.dart';
import 'audio_mini_player.dart';
import 'import_folder_page.dart';
import 'folder_scan_summary.dart';

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

  Future<void> _select(ReadingRoot root, String action) async {
    if (busy) return;
    if (action == 'disconnect') {
      if (await _confirmDisconnect(root) && mounted) {
        await _run(() => store.disconnect(root));
      }
    } else if (action == 'rename') {
      final title = await _rename(root);
      if (title != null && mounted) await _run(() => store.rename(root, title));
    } else {
      await _run(() async {
        if (action == 'refresh') {
          await store.refresh(root);
        } else if (action == 'pin') {
          await preference.set(pinnedRoot == root.key ? null : root.key);
        }
      });
    }
  }

  Future<bool> _confirmDisconnect(ReadingRoot root) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: const Text('Отключить папку книг?'),
          content: Text(
            '${root.title} · ${root.bookIds.length} книг.\nКниги этой папки скроются из списка файлов. Независимо импортированные копии останутся. Файлы, карточки библиотеки, прогресс, цитаты и заметки сохранятся. Повторное подключение вернёт книги.',
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
      ) ??
      false;
  Future<String?> _rename(ReadingRoot root) async {
    var title = root.title;
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Название папки в PepeHub'),
        content: TextFormField(
          initialValue: title,
          maxLength: 500,
          onChanged: (v) => title = v,
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
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
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
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Папка добавленных книг'),
            subtitle: const Text('Куда копировать книги, выбранные по одному'),
            trailing: const Icon(Icons.chevron_right),
            onTap: busy
                ? null
                : () => Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ImportFolderPage(assets: widget.assets),
                    ),
                  ).then((_) => _run(() async {})),
          ),
          FilledButton.icon(
            onPressed: busy
                ? null
                : () => _run(() async {
                    final folder = await pickAudioFolder(books: true);
                    if (folder != null) {
                      await store.connect(folder, skipUnreadable: true);
                    }
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
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${root.bookIds.length} книг\n${root.path}'),
                    FolderScanSummary(
                      lastScan: root.lastScan,
                      report: root.report,
                      warnings: root.warnings,
                    ),
                  ],
                ),
                trailing: PopupMenuButton<String>(
                  enabled: !busy,
                  onSelected: (v) => _select(root, v),
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
                      value: 'rename',
                      child: Text('Переименовать'),
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
    ),
  );
}
