import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../audio/book_folder_operations.dart';
import '../audio/audio_roots.dart';
import '../media/asset_store.dart';
import '../media/audio_controller.dart';

Future<void> showBookFolderDialog(
  BuildContext context,
  AssetStore assets,
  AudioController? audio,
  String bookId,
) async {
  final manager = BookFolderOperations(assets);
  try {
    if (await manager.hasPending(bookId)) {
      if (!context.mounted) return;
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Незавершённая операция'),
          content: const Text(
            'Проверить, где находится папка, и восстановить ссылки без повторного перемещения?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Позже'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Проверить незавершённую операцию'),
            ),
          ],
        ),
      );
      if (accepted != true) return;
      await audio?.prepareFolderChange();
      final message = await manager.recover(bookId);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
      return;
    }
    final location = await manager.locate(bookId);
    final roots = (await AudioRoots(
      assets,
    ).list()).where((r) => r.mode == 'folders').toList();
    var target = location.root.key;
    var name = p.posix.basename(location.relative);
    var parent = '';
    var rename = true;
    if (!context.mounted) return;
    final result = await showDialog<({String root, String relative})>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, refresh) => AlertDialog(
          title: const Text('Папка книги'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${location.root.title} / ${location.relative}'),
                  SwitchListTile(
                    title: const Text('Переименовать папку'),
                    subtitle: const Text('Выключите для перемещения'),
                    value: rename,
                    onChanged: (v) => refresh(() => rename = v),
                  ),
                  if (rename)
                    TextFormField(
                      initialValue: name,
                      maxLength: 200,
                      decoration: const InputDecoration(
                        labelText: 'Новое имя папки',
                      ),
                      onChanged: (v) => name = v,
                    ),
                  if (!rename) ...[
                    DropdownButton<String>(
                      isExpanded: true,
                      value: target,
                      items: [
                        for (final r in roots)
                          DropdownMenuItem(
                            value: r.key,
                            child: Text(
                              r.title,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) => refresh(() => target = v!),
                    ),
                    TextFormField(
                      decoration: const InputDecoration(
                        labelText: 'Папка назначения внутри корня',
                        helperText: 'Пусто — прямо в корень. Папка должна существовать.',
                      ),
                      onChanged: (v) => parent = v.trim(),
                    ),
                  ],
                  const SizedBox(height: 16),
                  const Text(
                    'Изменится папка на накопителе вместе со всем содержимым. Воспроизведение остановится. Перед операцией сохраняется резервный снимок.',
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () {
                final oldParent = p.posix.dirname(location.relative);
                Navigator.pop(context, (
                  root: rename ? location.root.key : target,
                  relative: rename
                      ? (oldParent == '.'
                            ? name.trim()
                            : '$oldParent/${name.trim()}')
                      : (parent.isEmpty
                            ? p.posix.basename(location.relative)
                            : '$parent/${p.posix.basename(location.relative)}'),
                ));
              },
              child: Text(rename ? 'Переименовать' : 'Переместить'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    await audio?.prepareFolderChange();
    final message = await manager.relocate(
      bookId,
      location,
      roots.firstWhere((r) => r.key == result.root),
      result.relative,
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  } catch (e) {
    if (context.mounted) {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Операция с папкой'),
          content: SingleChildScrollView(child: Text('$e')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Закрыть'),
            ),
          ],
        ),
      );
    }
  }
}
