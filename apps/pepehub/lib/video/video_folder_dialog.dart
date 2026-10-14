import 'package:flutter/material.dart';

import 'video_folder_sync.dart';

class VideoFolderRefreshDialog extends StatefulWidget {
  final VideoFolderPreview preview;
  const VideoFolderRefreshDialog({super.key, required this.preview});
  @override
  State<VideoFolderRefreshDialog> createState() =>
      _VideoFolderRefreshDialogState();
}

class _VideoFolderRefreshDialogState extends State<VideoFolderRefreshDialog> {
  final confirmed = <String>{};
  bool saving = false;
  String? error;
  Future<void> apply() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.preview.apply(confirmed);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          saving = false;
          error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = widget.preview;
    return PopScope(
      canPop: !saving,
      child: AlertDialog(
        title: const Text('Обновить папку курса'),
        content: SizedBox(
          width: 680,
          height: MediaQuery.sizeOf(context).height * .6,
          child: ListView(
            children: [
              Text(
                preview.selection.root!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 12),
              Text(
                'Новых файлов / кандидатов: ${preview.newCount}\nИзменённых: ${preview.changed.length}\nНедоступных / переименованных: ${preview.missingCount}',
              ),
              const SizedBox(height: 12),
              const Text(
                'Изменённое содержимое получает отдельную версию и прогресс. Недоступные уроки сохранят историю и заметки. Ручные названия и порядок остаются.',
              ),
              if (preview.baselines > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'Для ${preview.baselines} прежних файлов создаётся первый отпечаток. Изменения до этого сканирования определить нельзя.',
                  ),
                ),
              if (preview.renames.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Text(
                    'Подтвердите только те файлы, которые действительно остались тем же уроком. Частичный отпечаток — подсказка, а не проверка всего файла.',
                  ),
                ),
                for (final rename in preview.renames)
                  CheckboxListTile(
                    key: ValueKey('video-rename-${rename.lesson.id}'),
                    contentPadding: EdgeInsets.zero,
                    value: confirmed.contains(rename.lesson.id),
                    onChanged: saving
                        ? null
                        : (value) => setState(() {
                            if (value == true) {
                              confirmed.add(rename.lesson.id);
                            } else {
                              confirmed.remove(rename.lesson.id);
                            }
                          }),
                    title: Text(rename.lesson.title),
                    subtitle: Text(
                      '${rename.source.relativeName ?? rename.source.title}\n${rename.sampled ? 'Образцы содержимого совпали' : 'Старого отпечатка нет: совпал относительный путь'} · сохранить прежнюю версию и историю',
                    ),
                  ),
              ],
              if (saving) const LinearProgressIndicator(),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: saving ? null : () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: saving ? null : apply,
            child: const Text('Применить'),
          ),
        ],
      ),
    );
  }
}
