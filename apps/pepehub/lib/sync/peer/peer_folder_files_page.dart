import 'package:flutter/material.dart';

import '../../ui/audio_mini_player.dart';
import 'peer_models.dart';
import 'peer_service.dart';
import 'peer_diagnostics.dart';

class PeerFolderFilesPage extends StatefulWidget {
  final PeerSyncService service;
  final PeerFolder folder;
  const PeerFolderFilesPage({
    super.key,
    required this.service,
    required this.folder,
  });
  @override
  State<PeerFolderFilesPage> createState() => _PeerFolderFilesPageState();
}

class _PeerFolderFilesPageState extends State<PeerFolderFilesPage> {
  late String mode = widget.folder.download;
  late final Set<String> selected = {...widget.folder.selectedPaths};
  List<PeerFileEntry> files = [];
  String query = '', error = '';
  bool loading = true, saving = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final next = await widget.service.filesForSelection(widget.folder);
      if (mounted) setState(() => files = next);
    } catch (e) {
      if (mounted) setState(() => error = peerFailureDescription(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  String size(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МиБ';
  @override
  Widget build(BuildContext context) {
    final visible = files
        .where((f) => f.path.toLowerCase().contains(query.toLowerCase()))
        .toList();
    bool picked(String path) =>
        selected.any((p) => p == path || path.startsWith('$p/'));
    final chosen = files
        .where((f) => mode == 'all' || mode == 'selected' && picked(f.path))
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Файлы на этом устройстве')),
      bottomNavigationBar: const AudioPlayerFooter(),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.folder.name,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: mode,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Что скачивать',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'none',
                        child: Text('Только данные приложения'),
                      ),
                      DropdownMenuItem(
                        value: 'selected',
                        child: Text('Выбранные файлы'),
                      ),
                      DropdownMenuItem(value: 'all', child: Text('Всю папку')),
                    ],
                    onChanged: saving ? null : (v) => setState(() => mode = v!),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Настройка действует только на этом устройстве. Существующие файлы сохраняются. Прогресс и заметки передаются отдельно при включённых «Данных приложения».',
                  ),
                  Text(
                    'Выбрано: ${chosen.length} · ${size(chosen.fold<int>(0, (n, f) => n + f.bytes))}',
                  ),
                  if (error.isNotEmpty) Text(error),
                  if (mode == 'selected')
                    TextField(
                      decoration: const InputDecoration(
                        labelText: 'Поиск урока или файла',
                      ),
                      onChanged: (v) => setState(() => query = v),
                    ),
                  if (mode == 'selected')
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: () => setState(
                            () => selected.addAll(visible.map((f) => f.path)),
                          ),
                          child: const Text('Выбрать найденные'),
                        ),
                        TextButton(
                          onPressed: () => setState(selected.clear),
                          child: const Text('Снять выбор'),
                        ),
                      ],
                    ),
                  FilledButton(
                    onPressed: saving
                        ? null
                        : () async {
                            setState(() => saving = true);
                            try {
                              await widget.service.configureFolder(
                                widget.folder,
                                download: mode,
                                selectedPaths: selected,
                              );
                              if (context.mounted) Navigator.pop(context);
                            } catch (e) {
                              if (mounted) {
                                setState(
                                  () => error = peerFailureDescription(e),
                                );
                              }
                            } finally {
                              if (mounted) setState(() => saving = false);
                            }
                          },
                    child: const Text('Сохранить'),
                  ),
                  if (loading || saving) const LinearProgressIndicator(),
                ],
              ),
            ),
          ),
          if (mode == 'selected')
            SliverList.builder(
              itemCount: visible.length,
              itemBuilder: (context, index) {
                final file = visible[index];
                return CheckboxListTile(
                  title: Text(file.path),
                  subtitle: Text(size(file.bytes)),
                  value: picked(file.path),
                  onChanged: saving
                      ? null
                      : (v) => setState(() {
                          if (v == true) {
                            selected.add(file.path);
                          } else {
                            // Expand any selected parent before removing this one child.
                            final parents = selected
                                .where((p) => file.path.startsWith('$p/'))
                                .toList();
                            for (final parent in parents) {
                              selected.remove(parent);
                              selected.addAll(
                                files
                                    .where(
                                      (f) =>
                                          f.path.startsWith('$parent/') &&
                                          f.path != file.path,
                                    )
                                    .map((f) => f.path),
                              );
                            }
                            selected.remove(file.path);
                          }
                        }),
                );
              },
            ),
        ],
      ),
    );
  }
}
