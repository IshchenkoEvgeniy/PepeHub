import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../audio/audio_folder.dart';
import '../diagnostics/user_message.dart';
import '../library/library_backup.dart';
import '../library/library_folder_storage.dart';
import '../library/library_service.dart';
import '../sync/peer/peer_files.dart';
import 'pepe_widgets.dart';
import 'reading_roots_page.dart' show readableFolderPath;
import 'settings_components.dart';
import 'shelf_book_details.dart' show shelfDay;
import 'shelf_components.dart';
import 'storage_settings_page.dart' show storageBytes;

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

/// «3 карточки», «12 сессий»: Russian plural for [n].
String libraryCount(int n, String one, String few, String many) {
  final last = n % 10, lastTwo = n % 100;
  final word = last == 1 && lastTwo != 11
      ? one
      : last >= 2 && last <= 4 && (lastTwo < 12 || lastTwo > 14)
      ? few
      : many;
  return '$n $word';
}

/// «только что», «5 мин назад», «сегодня в 14:05», «вчера в 09:12».
String libraryMoment(DateTime value, DateTime now) {
  final passed = now.difference(value);
  if (passed.inSeconds < 60) return 'только что';
  if (passed.inMinutes < 60) return '${passed.inMinutes} мин назад';
  return '${shelfDay(value, now)} в ${pepeClock(value.toLocal())}';
}

/// One line about the folder: «60 карточек · 3 в корзине · 12 сессий …».
String libraryFolderSummary(LibraryFolderStats stats) => [
  libraryCount(stats.cards - stats.deleted, 'карточка', 'карточки', 'карточек'),
  if (stats.deleted > 0) '${stats.deleted} в корзине',
  if (stats.history > 0)
    libraryCount(stats.history, 'сессия', 'сессии', 'сессий'),
  if (stats.notes > 0)
    libraryCount(stats.notes, 'заметка', 'заметки', 'заметок'),
  if (stats.covers > 0)
    libraryCount(stats.covers, 'обложка', 'обложки', 'обложек'),
].join(' · ');

/// Creation time of a local copy from its name
/// (`PepeHub-library-2026-11-08T13-04-05-123456Z.zip`).
DateTime? libraryBackupTime(String name) {
  final match = RegExp(r'(\d{4}-\d\d-\d\d)T(\d\d)-(\d\d)-(\d\d)(?:-(\d+))?Z')
      .firstMatch(name);
  if (match == null) return null;
  return DateTime.tryParse(
    '${match[1]}T${match[2]}:${match[3]}:${match[4]}'
    '${match[5] == null ? '' : '.${match[5]}'}Z',
  );
}

class LibraryDataPage extends StatefulWidget {
  final LibraryService library;
  final bool embedded;
  const LibraryDataPage({
    super.key,
    required this.library,
    this.embedded = false,
  });
  @override
  State<LibraryDataPage> createState() => _LibraryDataPageState();
}

class _LibraryDataPageState extends State<LibraryDataPage> {
  bool busy = false;
  String? message;
  bool messageIsError = false;
  List<File> backups = [];
  bool allBackups = false;
  LibraryFolderReport? report;
  LibraryBackup get storage => LibraryBackup(widget.library);
  LibraryFolderStorage get folder => widget.library.folderStorage;

  @override
  void initState() {
    super.initState();
    folder.addListener(_folderChanged);
    folder
        .initialize()
        .then((_) {
          _folderChanged();
          return _inspect();
        })
        .catchError((Object e) {
          if (mounted) {
            _show(
              'Не удалось загрузить настройки папки: ${describeError(e)}',
              error: true,
            );
          }
        });
    _load();
  }

  void _folderChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    folder.removeListener(_folderChanged);
    super.dispose();
  }

  void _show(String? text, {bool error = false}) => setState(() {
    message = text;
    messageIsError = error;
  });

  Future<void> _inspect() async {
    try {
      final next = folder.enabled ? await folder.inspect() : null;
      if (mounted) setState(() => report = next);
    } catch (e) {
      // Details are optional; the folder itself keeps working.
      if (mounted) setState(() => report = null);
    }
  }

  Future<String?> _folderAction({String? selected}) async {
    Future<void> apply({LibraryFolderPreference? preference}) async {
      if (selected == null) {
        await folder.synchronize(force: true, preference: preference);
        await widget.library.loadCached();
      } else {
        await folder.connect(selected, preference: preference);
      }
    }

    try {
      await apply();
    } on LibraryFolderConflict catch (conflict) {
      if (!mounted) return null;
      final choice = await showDialog<LibraryFolderPreference>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: const Text('Выбрать версию изменений'),
          content: Text(
            'Здесь и в папке по-разному изменены ${libraryCount(conflict.documents.length, 'запись', 'записи', 'записей')}. '
            'Остальные изменения, а также сессии и заметки обоих устройств объединятся сами. '
            'Если удаление произведения совпало с новой заметкой или историей, выбирается версия произведения целиком. '
            'Перед заменой автоматически сохранится резервная копия текущей библиотеки.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: () =>
                  Navigator.pop(context, LibraryFolderPreference.local),
              child: const Text('Версия с этого устройства'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(context, LibraryFolderPreference.folder),
              child: const Text('Версия из папки'),
            ),
          ],
        ),
      );
      if (choice == null) return null;
      await storage.saveLocal();
      await apply(preference: choice);
    } on LibraryFolderPending catch (e) {
      return 'Другое устройство ещё передаёт файлы: ${e.message}';
    }
    return selected == null
        ? 'Библиотека и папка совпадают.'
              '${folder.warning == null ? '' : '\n${folder.warning}'}'
        : 'Папка подключена. Изменения будут сохраняться в неё автоматически.'
              '${folder.warning == null ? '' : '\n${folder.warning}'}';
  }

  Future<String?> _chooseFolder() async {
    final String? selected;
    if (Platform.isAndroid) {
      selected =
          (await peerFilesChannel.invokeMapMethod<String, dynamic>(
                'pick',
              ))?['root']
              as String?;
    } else {
      selected = await getDirectoryPath(
        confirmButtonText: 'Выбрать папку библиотеки',
      );
    }
    if (selected == null) return null;
    return _folderAction(selected: selected);
  }

  Future<String?> _disconnectFolder() async {
    if (!mounted) return null;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Отключить папку библиотеки?'),
        content: const Text(
          'Текущие карточки, цитаты, история и обложки останутся на устройстве. '
          'Файлы в папке сохранятся. Новые изменения будут храниться только на этом устройстве.',
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
    );
    if (confirmed != true) return null;
    final saved = await folder.disconnect();
    return saved
        ? 'Папка отключена. Последние изменения сохранены в папке и на устройстве.'
        : 'Папка отключена. Последние изменения остались на устройстве: '
              'записать их в папку не удалось.';
  }

  Future<String?> _removeConflictCopies(List<String> paths) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Удалить копии конфликтов?'),
        content: Text(
          'Syncthing сохраняет такие копии, когда файл менялся на двух устройствах сразу. '
          'PepeHub объединяет изменения обоих устройств сам, поэтому копии не нужны.\n\n'
          '${paths.take(8).join('\n')}${paths.length > 8 ? '\n… и ещё ${paths.length - 8}' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return null;
    final removed = await folder.removeConflictCopies(paths);
    return 'Удалено копий: $removed';
  }

  Future<void> _load() async {
    try {
      final dir = await storage.directory();
      final files = await dir
          .list(followLinks: false)
          .where((e) => e is File && e.path.endsWith('.zip'))
          .cast<File>()
          .toList();
      files.sort((a, b) => b.path.compareTo(a.path));
      if (mounted) setState(() => backups = files);
    } catch (e) {
      if (mounted) {
        _show(
          'Не удалось открыть локальные копии: ${describeError(e)}',
          error: true,
        );
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
      if (mounted) _show(text);
    } catch (e) {
      if (mounted) _show(describeError(e), error: true);
    } finally {
      if (mounted) setState(() => busy = false);
      await _inspect();
    }
  }

  Future<String?> _restore(File file) async {
    if (await file.length() > 134217728) {
      throw StateError('Архив больше 128 МиБ');
    }
    final preview = storage.inspect(await file.readAsBytes());
    final existing = (await widget.library.repository.entries()).keys.toSet();
    final changed = preview.cards.keys.where(existing.contains).length;
    final created = DateTime.tryParse(preview.createdAt);
    if (!mounted) return null;
    final mode = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Восстановить библиотеку?'),
        content: Text(
          'Копия: ${created == null ? preview.createdAt : libraryMoment(created, DateTime.now())}\n'
          'Карточек: ${preview.cards.length}, из них новых: ${preview.cards.length - changed}\n'
          'Обложек: ${preview.covers.length}\n\n'
          '«Объединить» добавит новые карточки и заменит совпадающие данными из копии. '
          '«Заменить» сделает библиотеку такой же, как в копии. '
          'Перед восстановлением автоматически сохранится текущая библиотека. '
          'Файлы книг и остальные разделы приложения не меняются.',
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

  Future<String?> _deleteBackup(File file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить локальную копию?'),
        content: Text(p.basename(file.path)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return null;
    await file.delete();
    return 'Копия удалена.';
  }

  Widget _plaque(
    IconData icon,
    String text, {
    required Color color,
    Widget? action,
    Key? key,
  }) => Container(
    key: key,
    margin: const EdgeInsets.only(top: 10),
    padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        ?action,
      ],
    ),
  );

  String _status(DateTime now) {
    if (folder.working) return 'Сохраняется…';
    final saved = folder.savedAt, checked = folder.checkedAt;
    final parts = [
      if (saved != null) 'сохранено ${libraryMoment(saved, now)}',
      if (checked != null && (saved == null || checked.isAfter(saved)))
        'проверено ${libraryMoment(checked, now)}',
    ];
    if (parts.isEmpty) return 'Изменения сохраняются автоматически';
    final text = parts.join(' · ');
    return text[0].toUpperCase() + text.substring(1);
  }

  Widget _emptyFolder(ShelfPalette palette) => PepePanel(
    key: const ValueKey('library-folder-empty'),
    child: Column(
      children: [
        const SizedBox(height: 8),
        Icon(Icons.folder_shared_outlined, size: 44, color: palette.muted),
        const SizedBox(height: 12),
        const Text(
          'Папка библиотеки',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          'Сейчас библиотека хранится только на этом устройстве. Выберите папку, '
          'которую синхронизирует Syncthing или облачный диск, — и карточки, серии, цитаты, '
          'история и обложки будут одинаковыми на телефоне и ПК. Можно выбрать готовую '
          'PepeHub-library или папку, в которой её создать.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, height: 1.4, color: palette.muted),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: busy ? null : () => _run(_chooseFolder),
          icon: const Icon(Icons.create_new_folder_outlined),
          label: const Text('Выбрать папку…'),
        ),
        const SizedBox(height: 4),
      ],
    ),
  );

  Widget _folderCard(ShelfPalette palette) {
    final scheme = Theme.of(context).colorScheme;
    final now = DateTime.now();
    final path = folder.displayPath!;
    final stats = folder.stats;
    final info = report;
    final unused = info == null ? 0 : info.unusedObjects + info.unusedCovers;
    return Material(
      key: const ValueKey('library-folder-card'),
      color: palette.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    folder.error != null
                        ? Icons.sync_problem
                        : Icons.folder_shared_outlined,
                    color: folder.error != null ? scheme.error : palette.accent,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Папка библиотеки',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (stats != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          libraryFolderSummary(stats),
                          key: const ValueKey('library-folder-summary'),
                          style: const TextStyle(fontSize: 13),
                        ),
                      ],
                      const SizedBox(height: 2),
                      Text(
                        _status(now),
                        style: TextStyle(fontSize: 12.5, color: palette.muted),
                      ),
                      const SizedBox(height: 2),
                      SelectableText(
                        readableFolderPath(path),
                        maxLines: 2,
                        style: TextStyle(fontSize: 11.5, color: palette.muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (folder.error != null)
              _plaque(
                Icons.error_outline,
                'Не удалось обновить папку. Изменения сохранены на устройстве. ${folder.error}',
                color: scheme.error,
                action: TextButton(
                  onPressed: busy ? null : () => _run(() => _folderAction()),
                  child: const Text('Повторить'),
                ),
              ),
            if (folder.pending != null)
              _plaque(
                Icons.hourglass_top_rounded,
                'Другое устройство ещё передаёт файлы. PepeHub проверит папку снова через несколько секунд.',
                color: Colors.amber,
              ),
            if (folder.warning != null)
              _plaque(
                Icons.info_outline,
                folder.warning!,
                color: palette.accent,
              ),
            if (info != null && info.conflictCopies.isNotEmpty)
              _plaque(
                Icons.call_split,
                'Копий конфликтов Syncthing: ${info.conflictCopies.length}. PepeHub объединяет изменения сам, копии не нужны.',
                color: Colors.amber,
                key: const ValueKey('library-folder-conflicts'),
                action: TextButton(
                  onPressed: busy
                      ? null
                      : () => _run(
                          () => _removeConflictCopies(info.conflictCopies),
                        ),
                  child: const Text('Удалить'),
                ),
              ),
            if (info?.syncthingRoot case final root?
                when !info!.ignoresTemporary)
              _plaque(
                Icons.sync,
                'Папка синхронизируется Syncthing. Добавьте .pepehub в исключения: там временные файлы записи, передавать их не нужно.',
                color: palette.accent,
                key: const ValueKey('library-folder-stignore'),
                action: TextButton(
                  onPressed: busy
                      ? null
                      : () => _run(() async {
                          await folder.ignoreTemporaryFiles(root);
                          return 'Строка .pepehub добавлена в .stignore. На телефоне добавьте её '
                              'в игнорируемые шаблоны этой папки в Syncthing.';
                        }),
                  child: const Text('Добавить'),
                ),
              ),
            if (unused > 0)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  'Прежние версии данных: ${libraryCount(unused, 'файл', 'файла', 'файлов')}, '
                  '${storageBytes(info!.unusedBytes)}. Удаляются сами через 30 дней.',
                  style: TextStyle(fontSize: 12, color: palette.muted),
                ),
              ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                OutlinedButton.icon(
                  onPressed: busy ? null : () => _run(() => _folderAction()),
                  icon: const Icon(Icons.sync),
                  label: const Text('Обновить из папки'),
                ),
                TextButton(
                  onPressed: busy ? null : () => _run(_chooseFolder),
                  child: const Text('Другая папка…'),
                ),
                TextButton(
                  onPressed: busy ? null : () => _run(_disconnectFolder),
                  child: const Text('Отключить папку'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _syncHelp(ShelfPalette palette) {
    final muted = TextStyle(fontSize: 13, height: 1.45, color: palette.muted);
    return PepePanel(
      padding: const EdgeInsets.fromLTRB(20, 4, 12, 4),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.fromLTRB(0, 0, 8, 14),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          title: const Text(
            'Как синхронизировать с ПК через Syncthing',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          children: [
            Text(
              '1. В Syncthing добавьте одну и ту же папку на телефоне и ПК — PepeHub-library или папку, в которой она лежит.\n'
              '2. На каждом устройстве выберите эту папку здесь, в «Папке библиотеки».\n'
              '3. В игнорируемых шаблонах папки в Syncthing добавьте строку .pepehub — '
              'там временные файлы записи.\n\n'
              'PepeHub сохраняет изменения в папку сам и проверяет её каждые несколько секунд. '
              'Сессии чтения записываются не чаще раза в 2 минуты и сразу, когда приложение сворачивается. '
              'Если устройства изменили библиотеку одновременно, правки объединяются: '
              'сессии и заметки обоих устройств сохраняются, а выбирать версию нужно, только если одна карточка '
              'изменена по-разному.\n\n'
              'Внутри: «Книги» и «Корзина» — читаемые JSON-файлы по сериям; library.json, objects/ и covers/ — '
              'служебный каталог, версии данных и обложки. Файлы книг и аудио в папку не входят.',
              style: muted,
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(const ClipboardData(text: '.pepehub'));
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Строка .pepehub скопирована'),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Скопировать шаблон .pepehub'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _backupPanel(ShelfPalette palette) {
    final now = DateTime.now();
    final shown = allBackups ? backups : backups.take(5).toList();
    return PepePanel(
      title: 'Резервные копии',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'ZIP с карточками, сериями, коллекциями, цитатами, историей, корзиной и обложками. '
            'Файлы книг и аудио в копию не входят. Копия создаётся и сама — перед восстановлением '
            'и перед выбором версии при конфликте.',
            style: TextStyle(fontSize: 13, height: 1.4, color: palette.muted),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
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
            ],
          ),
          const SizedBox(height: 16),
          Text(
            backups.isEmpty
                ? 'Локальных копий пока нет'
                : 'На этом устройстве: ${libraryCount(backups.length, 'копия', 'копии', 'копий')}',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          for (final file in shown)
            ListTile(
              key: ValueKey('library-backup:${p.basename(file.path)}'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.folder_zip_outlined),
              title: Text(switch (libraryBackupTime(p.basename(file.path))) {
                final time? => libraryMoment(time, now),
                null => p.basename(file.path),
              }),
              subtitle: Text(
                _size(file),
                style: TextStyle(fontSize: 12, color: palette.muted),
              ),
              trailing: PopupMenuButton<String>(
                enabled: !busy,
                tooltip: 'Действия с копией',
                onSelected: (action) => _run(() async {
                  if (action == 'restore') return _restore(file);
                  if (action == 'delete') return _deleteBackup(file);
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
                  PopupMenuItem(value: 'delete', child: Text('Удалить')),
                ],
              ),
            ),
          if (backups.length > shown.length)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() => allBackups = true),
                child: Text('Показать все (${backups.length})'),
              ),
            ),
        ],
      ),
    );
  }

  String _size(File file) {
    try {
      return storageBytes(file.lengthSync());
    } on FileSystemException {
      return 'недоступна';
    }
  }

  Widget _exportPanel(ShelfPalette palette) => PepePanel(
    title: 'Экспорт',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Карточки без корзины: JSON — для обработки, CSV — для таблиц, Markdown — для чтения. '
          'Для переноса с цитатами и обложками используйте резервную копию.',
          style: TextStyle(fontSize: 13, height: 1.4, color: palette.muted),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (format, label) in [
              ('json', 'JSON'),
              ('csv', 'CSV'),
              ('md', 'Markdown'),
            ])
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
                child: Text(label),
              ),
          ],
        ),
      ],
    ),
  );

  List<Widget> _children(ShelfPalette palette) {
    final scheme = Theme.of(context).colorScheme;
    return [
      if (busy || folder.working)
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: LinearProgressIndicator(),
        ),
      if (message != null) ...[
        PepePanel(
          key: const ValueKey('library-data-message'),
          outlined: true,
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            children: [
              Icon(
                messageIsError
                    ? Icons.error_outline
                    : Icons.check_circle_outline,
                color: messageIsError ? scheme.error : palette.accent,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SelectableText(
                  message!,
                  style: messageIsError ? TextStyle(color: scheme.error) : null,
                ),
              ),
              IconButton(
                tooltip: 'Скрыть',
                onPressed: () => _show(null),
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
      ],
      if (folder.enabled) _folderCard(palette) else _emptyFolder(palette),
      const SizedBox(height: 12),
      _syncHelp(palette),
      const SizedBox(height: 16),
      PepeRow(
        breakpoint: 900,
        children: [(3, _backupPanel(palette)), (2, _exportPanel(palette))],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    if (widget.embedded) {
      return Scaffold(
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
          children: [
            const SettingsHeading(
              'Резервные копии и экспорт',
              'Папка для синхронизации библиотеки между устройствами, резервные копии и экспорт.',
            ),
            ..._children(palette),
          ],
        ),
      );
    }
    return PepeSubpage(
      title: 'Данные библиотеки',
      back: 'Библиотека',
      section: PepeSection.library,
      subtitle: 'Папка для синхронизации между устройствами, резервные копии и экспорт.',
      children: _children(palette),
    );
  }
}
