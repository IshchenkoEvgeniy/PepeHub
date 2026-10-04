import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../audio/audio_import.dart';
import '../media/asset_store.dart';

class AudioImportDialog extends StatefulWidget {
  final List<XFile> files;
  final AssetStore assets;
  final String? initialTitle;
  final String? sourceRoot;
  const AudioImportDialog({
    super.key,
    required this.files,
    required this.assets,
    this.initialTitle,
    this.sourceRoot,
  });
  @override
  State<AudioImportDialog> createState() => _AudioImportDialogState();
}

class _AudioImportDialogState extends State<AudioImportDialog> {
  late final files = [...widget.files]
    ..sort((a, b) => naturalAudioOrder(a.name, b.name));
  late final title = TextEditingController(
    text: widget.initialTitle ?? p.basenameWithoutExtension(files.first.name),
  );
  AudioImportControl? control;
  bool busy = false;
  double progress = 0;
  String error = '';
  @override
  void dispose() {
    title.dispose();
    super.dispose();
  }

  Future<void> import() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = '';
      progress = 0;
    });
    control = AudioImportControl();
    var lastUpdate = DateTime.now();
    try {
      final asset = widget.sourceRoot != null
          ? await widget.assets.connectAudioFolder(
              files,
              root: widget.sourceRoot!,
              title: title.text,
            )
          : await widget.assets.importAudioBook(
              files,
              title: title.text,
              control: control,
              onProgress: (done, total) {
                final now = DateTime.now();
                if (mounted &&
                    (done == total ||
                        now.difference(lastUpdate).inMilliseconds >= 100)) {
                  lastUpdate = now;
                  setState(() => progress = done / total);
                }
              },
            );
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.pop(context, asset);
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
      title: Text(
        widget.sourceRoot == null
            ? 'Копирование аудиокниги'
            : 'Подключение папки',
      ),
      content: SizedBox(
        width: 560,
        height: 400,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: title,
              enabled: !busy,
              maxLength: 500,
              decoration: const InputDecoration(labelText: 'Название книги'),
            ),
            Text('${files.length} файлов · порядок прослушивания'),
            if (widget.sourceRoot != null)
              const Text(
                'Воспроизведение из исходной папки. Файлы не копируются.',
              ),
            const Text(
              'Файлы отсортированы по имени. Порядок можно изменить.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ReorderableListView.builder(
                buildDefaultDragHandles: !busy,
                itemCount: files.length,
                onReorderItem: (oldIndex, newIndex) {
                  if (busy) return;
                  setState(() {
                    files.insert(newIndex, files.removeAt(oldIndex));
                  });
                },
                itemBuilder: (_, i) => ListTile(
                  key: ObjectKey(files[i]),
                  leading: Text('${i + 1}'),
                  title: Text(
                    files[i].name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: busy
                      ? null
                      : Row(
                          children: [
                            IconButton(
                              tooltip: 'Переместить выше',
                              visualDensity: VisualDensity.compact,
                              onPressed: i == 0
                                  ? null
                                  : () => setState(
                                      () => files.insert(
                                        i - 1,
                                        files.removeAt(i),
                                      ),
                                    ),
                              icon: const Icon(Icons.arrow_upward, size: 18),
                            ),
                            IconButton(
                              tooltip: 'Переместить ниже',
                              visualDensity: VisualDensity.compact,
                              onPressed: i == files.length - 1
                                  ? null
                                  : () => setState(
                                      () => files.insert(
                                        i + 1,
                                        files.removeAt(i),
                                      ),
                                    ),
                              icon: const Icon(Icons.arrow_downward, size: 18),
                            ),
                          ],
                        ),
                ),
              ),
            ),
            if (busy) ...[
              LinearProgressIndicator(
                value: widget.sourceRoot == null ? progress : null,
              ),
              Text(
                widget.sourceRoot != null
                    ? 'Сохранение ссылок на треки…'
                    : progress < 1
                    ? 'Копирование: ${(progress * 100).round()}%'
                    : 'Проверка и сохранение книги…',
              ),
            ],
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
          onPressed: () {
            if (busy && widget.sourceRoot != null) {
              return;
            } else if (busy) {
              control?.cancelled = true;
            } else {
              Navigator.pop(context);
            }
          },
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: busy ? null : import,
          child: Text(widget.sourceRoot == null ? 'Копировать' : 'Подключить'),
        ),
      ],
    ),
  );
}
