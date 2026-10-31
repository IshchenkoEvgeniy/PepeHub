import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../audio/audio_folder.dart';
import '../library/library_backup.dart';
import '../library/library_service.dart';

Future<bool> saveLibraryFile(Uint8List bytes, String name, String mime) async {
  if (Platform.isAndroid) {
    final root = await getTemporaryDirectory();
    final file = File(
      p.join(
        root.path,
        'library-export-${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await file.writeAsBytes(bytes, flush: true);
    try {
      return await audioFolderChannel.invokeMethod<bool>('exportStatistics', {
            'path': file.path,
            'name': name,
            'mime': mime,
          }) ??
          false;
    } finally {
      if (await file.exists()) await file.delete();
    }
  }
  final location = await getSaveLocation(suggestedName: name);
  if (location == null) return false;
  await File(location.path).writeAsBytes(bytes, flush: true);
  return true;
}

class LibraryDataPage extends StatefulWidget {
  final LibraryService library;
  const LibraryDataPage({super.key, required this.library});
  @override
  State<LibraryDataPage> createState() => _LibraryDataPageState();
}

class _LibraryDataPageState extends State<LibraryDataPage> {
  bool busy = false;
  String? message;
  List<File> backups = [];
  LibraryBackup get storage => LibraryBackup(widget.library);
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final folder = await storage.directory();
      final files = await folder
          .list(followLinks: false)
          .where((e) => e is File && e.path.endsWith('.zip'))
          .cast<File>()
          .toList();
      files.sort((a, b) => b.path.compareTo(a.path));
      if (mounted) setState(() => backups = files);
    } catch (e) {
      if (mounted) {
        setState(() => message = 'Не удалось открыть локальные копии: $e');
      }
    }
  }

  Future<void> _run(Future<String?> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final text = await action();
      await _load();
      if (mounted) setState(() => message = text);
    } catch (e) {
      if (mounted) setState(() => message = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<String?> _restore(File file) async {
    if (await file.length() > 134217728) {
      throw StateError('Архив больше 128 МиБ');
    }
    final preview = storage.inspect(await file.readAsBytes());
    final existing = (await widget.library.repository.entries()).keys.toSet();
    final changed = preview.cards.keys.where(existing.contains).length;
    if (!mounted) return null;
    final mode = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Восстановить библиотеку?'),
        content: SingleChildScrollView(
          child: Text(
            'Копия: ${preview.createdAt}\nКарточек: ${preview.cards.length}\nНовых: ${preview.cards.length - changed}\nСовпадающих по ID: $changed\nОбложек: ${preview.covers.length}\n\nПри объединении совпадающие карточки заменятся данными из копии. Перед восстановлением автоматически сохранится текущая библиотека. Файлы книг и остальные разделы приложения не меняются.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Заменить библиотеку'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Объединить'),
          ),
        ],
      ),
    );
    if (mode == null) return null;
    await storage.restore(preview, replace: mode);
    return 'Восстановлено карточек: ${preview.cards.length}';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Экспорт и резервные копии')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Резервная копия библиотеки',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 10),
        const Text(
          'ZIP содержит карточки, коллекции, цитаты, историю и сохранённые обложки, включая корзину. Оригинальные файлы книг и аудио в копию не входят.',
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: busy
              ? null
              : () => _run(() async {
                  final file = await storage.saveLocal();
                  final saved = await saveLibraryFile(
                    await file.readAsBytes(),
                    p.basename(file.path),
                    'application/zip',
                  );
                  return saved
                      ? 'Копия сохранена на устройстве и экспортирована.'
                      : 'Локальная копия создана. Экспорт отменён.';
                }),
          icon: const Icon(Icons.backup_outlined),
          label: const Text('Создать резервную копию'),
        ),
        OutlinedButton.icon(
          onPressed: busy
              ? null
              : () => _run(() async {
                  final file = await openFile(
                    acceptedTypeGroups: [
                      const XTypeGroup(
                        label: 'Копия библиотеки',
                        extensions: ['zip'],
                        mimeTypes: ['application/zip'],
                      ),
                    ],
                  );
                  if (file == null) return null;
                  // Native pickers can provide a staged path; XFile keeps that contract.
                  return _restore(File(file.path));
                }),
          icon: const Icon(Icons.restore),
          label: const Text('Восстановить из файла…'),
        ),
        const SizedBox(height: 24),
        const Text(
          'Экспорт данных',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        const Text(
          'Карточки без корзины: JSON для обработки, CSV для таблиц, Markdown для чтения. Для переноса с цитатами и обложками используйте ZIP.',
        ),
        Wrap(
          spacing: 8,
          children: [
            for (final format in ['json', 'csv', 'md'])
              OutlinedButton(
                onPressed: busy
                    ? null
                    : () => _run(() async {
                        final saved = await saveLibraryFile(
                          Uint8List.fromList(
                            utf8.encode(storage.exportText(format)),
                          ),
                          'PepeHub-library.$format',
                          format == 'json'
                              ? 'application/json'
                              : format == 'csv'
                              ? 'text/csv'
                              : 'text/markdown',
                        );
                        return saved ? 'Экспорт сохранён.' : null;
                      }),
                child: Text(format.toUpperCase()),
              ),
          ],
        ),
        if (busy) const LinearProgressIndicator(),
        if (message != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: SelectableText(message!),
          ),
        const SizedBox(height: 24),
        const Text(
          'Локальные копии',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
        ),
        for (final file in backups)
          ListTile(
            leading: const Icon(Icons.folder_zip_outlined),
            title: Text(p.basename(file.path)),
            trailing: PopupMenuButton<String>(
              enabled: !busy,
              onSelected: (action) => _run(() async {
                if (action == 'restore') return _restore(file);
                final saved = await saveLibraryFile(
                  await file.readAsBytes(),
                  p.basename(file.path),
                  'application/zip',
                );
                return saved ? 'Копия экспортирована.' : null;
              }),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'restore', child: Text('Восстановить…')),
                PopupMenuItem(
                  value: 'export',
                  child: Text('Сохранить в файл…'),
                ),
              ],
            ),
          ),
        if (backups.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Копий пока нет'),
          ),
      ],
    ),
  );
}
