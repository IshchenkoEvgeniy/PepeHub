import 'package:flutter/material.dart';

import '../audio/audio_catalog.dart';
import '../audio/audio_folder.dart';
import '../audio/audio_sidecar.dart';
import '../media/asset_store.dart';

class AudioCatalogDialog extends StatefulWidget {
  final AudioFolder folder;
  final AssetStore assets;
  const AudioCatalogDialog({
    super.key,
    required this.folder,
    required this.assets,
  });
  @override
  State<AudioCatalogDialog> createState() => _AudioCatalogDialogState();
}

class _AudioCatalogDialogState extends State<AudioCatalogDialog> {
  late List<AudioBookDraft> drafts = groupAudioCatalog(widget.folder);
  String mode = 'folders', error = '';
  bool busy = false;
  bool sidecar = true;
  @override
  void initState() {
    super.initState();
    final parts = numberedAudioParts(widget.folder);
    if (parts.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final merge = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Это части одной аудиокниги?'),
          content: Text(
            'Найдены папки ${parts.join(', ')}. Объединить их в одну книгу с последовательным воспроизведением?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Оставить отдельно'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Объединить'),
            ),
          ],
        ),
      );
      if (merge == true && mounted) {
        setState(() {
          mode = 'parts';
          drafts = groupAudioCatalog(widget.folder, mode: mode);
        });
      }
    });
  }

  Future<void> save() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      final count = await connectAudioCatalog(
        widget.assets,
        widget.folder,
        drafts,
        mode: mode,
      );
      if (sidecar) {
        try {
          await saveAudioSidecar(widget.assets, widget.folder);
        } catch (e) {
          if (mounted) {
            setState(() {
              busy = false;
              error =
                  'Книги подключены. Не удалось сохранить снимок в .pepehub: $e. Можно закрыть это окно.';
            });
          }
          return;
        }
      }
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.pop(context, count);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: const Text('Книги в папке'),
      content: SizedBox(
        width: 560,
        height: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Файлы остаются на месте. Проверьте разделение на книги.',
            ),
            DropdownButton<String>(
              isExpanded: true,
              value: mode,
              items: const [
                DropdownMenuItem(
                  value: 'folders',
                  child: Text('Отдельная книга в каждой подпапке'),
                ),
                DropdownMenuItem(
                  value: 'parts',
                  child: Text('Нумерованные папки — части одной книги'),
                ),
                DropdownMenuItem(
                  value: 'files',
                  child: Text('Каждый файл — отдельная книга'),
                ),
                DropdownMenuItem(
                  value: 'single',
                  child: Text('Вся папка — одна книга'),
                ),
              ],
              onChanged: busy
                  ? null
                  : (v) => setState(() {
                      mode = v!;
                      drafts = groupAudioCatalog(widget.folder, mode: mode);
                    }),
            ),
            Text('Найдено книг: ${drafts.length}'),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: sidecar,
              onChanged: busy ? null : (v) => setState(() => sidecar = v!),
              title: const Text('Сохранить снимок данных в .pepehub'),
              subtitle: const Text(
                'Список книг, позиции и статистика на момент подключения',
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: drafts.length,
                itemBuilder: (_, i) {
                  final draft = drafts[i];
                  return Row(
                    key: ValueKey('$mode/${draft.relativeFolder}'),
                    children: [
                      Checkbox(
                        value: draft.selected,
                        onChanged: busy
                            ? null
                            : (v) => setState(() => draft.selected = v!),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              TextFormField(
                                initialValue: draft.title,
                                enabled: !busy,
                                maxLength: 500,
                                decoration: const InputDecoration(
                                  labelText: 'Название',
                                  counterText: '',
                                ),
                                onChanged: (v) => draft.title = v,
                              ),
                              Text(
                                '${draft.files.length} треков · ${draft.relativeFolder.isEmpty ? 'Файлы в корне' : draft.relativeFolder}',
                              ),
                              Text(
                                draft.files.first.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            if (busy) const LinearProgressIndicator(),
            if (error.isNotEmpty)
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: busy ? null : save,
          child: const Text('Подключить книги'),
        ),
      ],
    ),
  );
}
