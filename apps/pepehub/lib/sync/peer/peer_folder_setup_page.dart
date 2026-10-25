import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../data/repository.dart' show uuid;
import 'peer_files.dart';
import 'peer_models.dart';
import 'peer_service.dart';

class PeerFolderPreview {
  final int files, bytes;
  final List<String> examples;
  const PeerFolderPreview(this.files, this.bytes, this.examples);
}

/// Metadata-only preview: no hashes, staging files, sidecars or remote writes.
Future<PeerFolderPreview> previewPeerFolder(String root) async {
  if (root.startsWith('content://')) {
    final value = await peerFilesChannel.invokeMapMethod<String, dynamic>(
      'preview',
      {'root': root},
    );
    if (value == null) throw StateError('Не удалось прочитать папку');
    return PeerFolderPreview(
      value['files'] as int,
      value['bytes'] as int,
      List<String>.from(value['examples'] as List),
    );
  }
  if (await FileSystemEntity.type(root, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw StateError('Выберите существующую папку, а не ссылку на неё');
  }
  var files = 0, bytes = 0, visited = 0;
  final examples = <String>[];
  Future<void> visit(Directory directory, int depth) async {
    if (depth > 32) throw StateError('В папке больше 32 уровней вложенности');
    await for (final entry in directory.list(followLinks: false)) {
      if (peerIgnored(p.basename(entry.path))) continue;
      if (++visited > 50000) {
        throw StateError('Слишком много элементов в папке');
      }
      if (entry is Directory) {
        await visit(entry, depth + 1);
      } else if (entry is File) {
        if (++files > peerMaxFiles) {
          throw StateError('В общей папке допускается до $peerMaxFiles файлов');
        }
        final relative = peerPath(
          p.relative(entry.path, from: root).replaceAll('\\', '/'),
        );
        bytes += await entry.length();
        if (examples.length < 25) examples.add(relative);
      }
    }
  }

  await visit(Directory(root), 0);
  return PeerFolderPreview(files, bytes, examples);
}

class PeerFolderSetupPage extends StatefulWidget {
  final PeerSyncService service;
  final Future<String?> Function() pick;
  final PeerDevice? peer;
  final Map<String, dynamic>? offer;
  const PeerFolderSetupPage({
    super.key,
    required this.service,
    required this.pick,
    this.peer,
    this.offer,
  });
  @override
  State<PeerFolderSetupPage> createState() => _PeerFolderSetupPageState();
}

class _PeerFolderSetupPageState extends State<PeerFolderSetupPage> {
  final name = TextEditingController();
  int step = 0;
  String? root, error;
  String library = 'all', download = 'none';
  bool busy = false;
  PeerFolderPreview? preview;
  final shared = <String>{};
  static const libraries = {
    'none': 'Не подключать к библиотеке',
    'all': 'По содержимому',
    'books': 'Книги',
    'audio': 'Аудиокниги',
    'video': 'Медиа',
  };
  static const downloads = {
    'none': 'Только данные приложения',
    'selected': 'Выбранные файлы',
    'all': 'Все файлы папки',
  };
  @override
  void initState() {
    super.initState();
    name.text = widget.offer?['name'] as String? ?? '';
    if (widget.peer != null) shared.add(widget.peer!.id);
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final selected = await widget.pick();
      if (selected == null || !mounted) return;
      final result = await previewPeerFolder(selected);
      if (mounted) {
        setState(() {
          root = selected;
          preview = result;
          if (name.text.trim().isEmpty) {
            name.text = selected.startsWith('content:')
                ? 'Общая папка'
                : p.basename(selected);
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = 'Не удалось проверить папку: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _continue() async {
    if (step == 0 &&
        (root == null ||
            preview == null ||
            name.text.trim().isEmpty ||
            name.text.length > 200)) {
      setState(
        () => error = 'Выберите папку и укажите название до 200 знаков.',
      );
      return;
    }
    if (step < 2) {
      setState(() {
        step++;
        error = null;
      });
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final id = widget.offer?['id'] as String? ?? uuid.v4();
      await widget.service.addFolder(
        root!,
        name.text.trim(),
        id: id,
        sharedWith: shared,
        library: library,
        download: download,
      );
      if (mounted) {
        Navigator.pop(
          context,
          widget.service.folders.firstWhere((folder) => folder.id == id),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.offer == null ? 'Новая общая папка' : 'Принять общую папку',
      ),
    ),
    body: Stepper(
      currentStep: step,
      onStepCancel: busy || step == 0 ? null : () => setState(() => step--),
      onStepContinue: busy ? null : _continue,
      controlsBuilder: (context, details) => Padding(
        padding: const EdgeInsets.only(top: 20),
        child: Wrap(
          spacing: 12,
          children: [
            FilledButton(
              key: ValueKey('peer-folder-continue-${details.stepIndex}'),
              onPressed: busy || details.stepIndex != step
                  ? null
                  : details.onStepContinue,
              child: Text(
                details.stepIndex == 2 ? 'Подключить папку' : 'Продолжить',
              ),
            ),
            if (step > 0)
              TextButton(
                onPressed: busy ? null : details.onStepCancel,
                child: const Text('Назад'),
              ),
            if (busy)
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(),
              ),
          ],
        ),
      ),
      steps: [
        Step(
          title: const Text('Папка'),
          isActive: step >= 0,
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Выберите отдельную папку для обмена. Существующие файлы сохранятся.',
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : _pick,
                icon: const Icon(Icons.folder_open),
                label: const Text('Выбрать папку'),
              ),
              if (root != null) Text(root!),
              TextField(
                controller: name,
                maxLength: 200,
                decoration: const InputDecoration(
                  labelText: 'Название общей папки',
                ),
              ),
              if (error != null) Text(error!),
            ],
          ),
        ),
        Step(
          title: const Text('Что передавать'),
          isActive: step >= 1,
          content: Column(
            children: [
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: library,
                decoration: const InputDecoration(
                  labelText: 'Подключение к библиотеке',
                ),
                items: [
                  for (final entry in libraries.entries)
                    DropdownMenuItem(
                      value: entry.key,
                      child: Text(
                        entry.value,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: busy
                    ? null
                    : (value) => setState(() => library = value!),
              ),
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: download,
                decoration: const InputDecoration(
                  labelText: 'Загрузка на это устройство',
                ),
                items: [
                  for (final entry in downloads.entries)
                    DropdownMenuItem(
                      value: entry.key,
                      child: Text(
                        entry.value,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: busy
                    ? null
                    : (value) => setState(() => download = value!),
              ),
              for (final device in widget.service.devices)
                CheckboxListTile(
                  title: Text(device.name),
                  subtitle: const Text('Разрешить обмен этой папкой'),
                  value: shared.contains(device.id),
                  onChanged: busy
                      ? null
                      : (value) => setState(() {
                          if (value == true) {
                            shared.add(device.id);
                          } else {
                            shared.remove(device.id);
                          }
                        }),
                ),
              if (error != null) Text(error!),
            ],
          ),
        ),
        Step(
          title: const Text('Проверка перед подключением'),
          isActive: step >= 2,
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name.text),
              Text(
                'На этом устройстве: ${preview?.files ?? 0} файлов · ${((preview?.bytes ?? 0) / 1048576).toStringAsFixed(1)} МиБ',
              ),
              Text('Загрузка: ${downloads[download]}'),
              Text('Библиотека: ${libraries[library]}'),
              Text(
                'Устройства: ${widget.service.devices.where((device) => shared.contains(device.id)).map((device) => device.name).join(', ')}',
              ),
              const SizedBox(height: 12),
              Text(
                download == 'none'
                    ? 'Новые медиафайлы на это устройство скачиваться не будут.'
                    : download == 'selected'
                    ? 'После подключения выберите файлы для загрузки.'
                    : 'Файлы выбранных папок будут объединяться при обмене.',
              ),
              const Text(
                'Входящие удаления всегда требуют отдельного подтверждения. Перед обменом список файлов проверяется повторно.',
              ),
              if (preview?.examples.isNotEmpty == true) ...[
                const SizedBox(height: 12),
                const Text('Примеры локальных файлов:'),
                for (final file in preview!.examples)
                  Text(file, maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
              if (error != null) Text(error!),
            ],
          ),
        ),
      ],
    ),
  );
}
