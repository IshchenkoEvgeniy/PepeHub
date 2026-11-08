import 'dart:async';

import 'package:flutter/material.dart';

import '../audio/audio_folder.dart';
import '../media/asset_store.dart';
import '../media/library_folder_preference.dart';
import '../reader/book_formats.dart';
import '../library/book_trash.dart';
import '../reader/reading_roots.dart';
import 'folder_scan_panel.dart';
import 'import_folder_page.dart';
import 'pepe_widgets.dart';
import 'shelf_book_details.dart';
import 'shelf_components.dart';

/// «1 книга», «3 книги», «12 книг».
String bookCount(int n) {
  final last = n % 10, lastTwo = n % 100;
  final word = last == 1 && lastTwo != 11
      ? 'книга'
      : last >= 2 && last <= 4 && (lastTwo < 12 || lastTwo > 14)
      ? 'книги'
      : 'книг';
  return '$n $word';
}

/// Android folder URIs as people know them: «Память телефона / Download».
String readableFolderPath(String path) {
  if (!path.startsWith('content://')) return path;
  final tree = path.lastIndexOf('/tree/');
  if (tree < 0) return path;
  final String document;
  try {
    document = Uri.decodeComponent(path.substring(tree + 6));
  } on Object {
    // Malformed percent or UTF-8 sequences: show the URI unchanged.
    return path;
  }
  final colon = document.indexOf(':');
  if (colon < 0) return document;
  final volume = document.substring(0, colon);
  final rest = document.substring(colon + 1).replaceAll('/', ' / ');
  final place = volume == 'primary' ? 'Память телефона' : 'Карта $volume';
  return rest.isEmpty ? place : '$place / $rest';
}

/// One line for a folder card: «124 книги · EPUB 80, PDF 30 · проверено вчера».
String readingRootSummary(
  ReadingRoot root,
  Map<String, int> formats,
  DateTime now, {
  int trashed = 0,
}) {
  final parts = <String>[bookCount(root.availableIds.length - trashed)];
  final byCount = formats.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  if (byCount.isNotEmpty) {
    parts.add(
      byCount.take(4).map((e) => '${formatLabel(e.key)} ${e.value}').join(', '),
    );
  }
  final scan = root.lastScan;
  parts.add(
    scan == null ? 'ещё не проверялась' : 'проверено ${shelfDay(scan, now)}',
  );
  return parts.join(' · ');
}

/// Connected book folders. Tapping a folder returns its key: the shelf then
/// shows only that folder.
class ReadingRootsPage extends StatefulWidget {
  final AssetStore assets;
  const ReadingRootsPage({super.key, required this.assets});
  @override
  State<ReadingRootsPage> createState() => _ReadingRootsPageState();
}

class _ReadingRootsPageState extends State<ReadingRootsPage> {
  late final store = ReadingRoots(widget.assets);
  List<ReadingRoot> roots = [];
  Map<String, Map<String, int>> formats = {};
  String? pinnedRoot;

  /// Books of each folder that are in the trash.
  Map<String, List<String>> trashed = {};
  late final preference = LibraryFolderPreference(
    widget.assets.repository,
    reading: true,
  );

  /// A quick action (rename, pin, disconnect) is running.
  bool busy = false;
  bool loading = true;
  String error = '';
  Future<void> Function()? retry;
  final expanded = <String>{};

  @override
  void initState() {
    super.initState();
    activeReadingScan.addListener(_scanChanged);
    unawaited(_reload());
  }

  @override
  void dispose() {
    activeReadingScan.removeListener(_scanChanged);
    super.dispose();
  }

  void _scanChanged() {
    if (mounted) setState(() {});
  }

  bool get scanning => activeReadingScan.value != null;

  Future<void> _reload() async {
    try {
      final values = await store.list();
      final pinned = await preference.load();
      final rows = await widget.assets.repository.db
          .customSelect('SELECT book_id,filename FROM local_assets')
          .get();
      final formatOf = <String, String>{
        for (final row in rows)
          row.read<String>('book_id'): bookFormat(row.read<String>('filename')),
      };
      final inTrash = {
        for (final book in await BookTrash(widget.assets.repository).list())
          book.id,
      };
      final counts = <String, Map<String, int>>{};
      final trashedByRoot = <String, List<String>>{};
      for (final root in values) {
        trashedByRoot[root.key] = [
          for (final id in root.availableIds)
            if (inTrash.contains(id)) id,
        ];
        final byFormat = counts[root.key] = <String, int>{};
        for (final id in root.availableIds) {
          if (inTrash.contains(id)) continue;
          final format = formatOf[id];
          if (format != null) byFormat[format] = (byFormat[format] ?? 0) + 1;
        }
      }
      if (!mounted) return;
      setState(() {
        roots = values..sort((a, b) => a.title.compareTo(b.title));
        pinnedRoot = pinned;
        formats = counts;
        trashed = trashedByRoot;
        loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = 'Не удалось загрузить папки: $e';
          retry = _reload;
        });
      }
    }
  }

  /// Runs a quick action; a failure is shown with «Повторить».
  Future<void> _run(Future<void> Function() action) async {
    if (busy || scanning) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await action();
      retry = null;
    } catch (e) {
      error = '$e';
      retry = () => _run(action);
    } finally {
      await _reload();
      if (mounted) setState(() => busy = false);
    }
  }

  /// Runs a scan with live progress. It keeps running if the user leaves.
  Future<void> _scan(
    String title,
    Future<Object?> Function(ReadingScanProgress progress) work,
  ) async {
    if (scanning || busy) return;
    final progress = ReadingScanProgress(title);
    activeReadingScan.value = progress;
    if (mounted) setState(() => error = '');
    FolderScanOutcome? outcome;
    try {
      final result = await work(progress);
      retry = null;
      outcome = FolderScanOutcome(
        result is ReadingRoot
            ? '«${result.title}»: ${bookCount(result.availableIds.length)}'
                  '${(result.report?['added'] as num? ?? 0) > 0 ? ', новых: ${result.report!['added']}' : ''}'
            : 'Папки обновлены',
      );
    } on ReadingScanCancelled {
      outcome = const FolderScanOutcome(
        'Проверка отменена. Библиотека не изменилась.',
      );
    } catch (e) {
      error = 'Не удалось проверить папку: $e';
      retry = () => _scan(title, work);
      outcome = FolderScanOutcome(error, failed: true);
    } finally {
      activeReadingScan.value = null;
      if (mounted) {
        if (outcome != null && !outcome.failed) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(outcome.message)));
        }
        await _reload();
      } else if (outcome != null) {
        // The user went back to the shelf: show the result there.
        folderScanOutcome.value = outcome;
      }
    }
  }

  Future<void> _connect() async {
    if (scanning || busy) return;
    final AudioFolder? folder;
    try {
      folder = await pickAudioFolder(books: true);
    } catch (e) {
      setState(() {
        error = 'Не удалось открыть папку: $e';
        retry = _connect;
      });
      return;
    }
    if (folder == null || !mounted) return;
    await _scan(
      'Подключение «${folder.title}»',
      (progress) => store.connect(
        folder!,
        skipUnreadable: true,
        progress: progress,
        restoreRemoved: true,
      ),
    );
  }

  Future<void> _refreshAll() => _scan('Обновление папок', (progress) async {
    final list = [...roots];
    for (final (index, root) in list.indexed) {
      progress.update(
        title: list.length == 1
            ? 'Обновление «${root.title}»'
            : 'Папка ${index + 1} из ${list.length}: ${root.title}',
      );
      await store.refresh(root, progress: progress);
    }
    return null;
  });

  Future<void> _select(ReadingRoot root, String action) async {
    if (busy || scanning) return;
    if (action == 'disconnect') {
      if (await _confirmDisconnect(root) && mounted) {
        await _run(() => store.disconnect(root));
      }
    } else if (action == 'rename') {
      final title = await _rename(root);
      if (title != null && mounted) await _run(() => store.rename(root, title));
    } else if (action == 'refresh') {
      await _scan(
        'Обновление «${root.title}»',
        (progress) => store.refresh(root, progress: progress),
      );
    } else if (action == 'pin') {
      await _run(
        () => preference.set(pinnedRoot == root.key ? null : root.key),
      );
    }
  }

  Future<bool> _confirmDisconnect(ReadingRoot root) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: const Text('Отключить папку книг?'),
          content: Text(
            '${root.title} · ${bookCount(root.bookIds.length)}.\nКниги этой папки скроются из списка файлов. Независимо добавленные книги останутся. Файлы на диске не удаляются. Прогресс, заметки и статистика сохранятся, если подключить папку снова.',
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

  Widget _errorPanel() {
    final scheme = Theme.of(context).colorScheme;
    return PepePanel(
      key: const ValueKey('reading-roots-error'),
      outlined: true,
      child: Row(
        children: [
          Icon(Icons.error_outline, color: scheme.error),
          const SizedBox(width: 12),
          Expanded(
            child: Text(error, style: TextStyle(color: scheme.error)),
          ),
          if (retry != null)
            TextButton(
              onPressed: busy || scanning ? null : retry,
              child: const Text('Повторить'),
            ),
        ],
      ),
    );
  }

  Widget _empty(ShelfPalette palette) => PepePanel(
    key: const ValueKey('reading-roots-empty'),
    child: Column(
      children: [
        const SizedBox(height: 8),
        Icon(Icons.folder_copy_outlined, size: 44, color: palette.muted),
        const SizedBox(height: 12),
        const Text(
          'Подключите папку с книгами',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          'PepeHub найдёт в ней EPUB, FB2, TXT, PDF и другие текстовые форматы, включая вложенные папки. Файлы остаются на месте; новые книги появятся после обновления папки.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, height: 1.4, color: palette.muted),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: busy || scanning ? null : _connect,
          icon: const Icon(Icons.create_new_folder_outlined),
          label: const Text('Подключить папку книг'),
        ),
        const SizedBox(height: 4),
      ],
    ),
  );

  Widget _plaque(
    IconData icon,
    String text, {
    required Color color,
    Widget? action,
  }) => Container(
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

  Widget _rootCard(ReadingRoot root, ShelfPalette palette) {
    final scheme = Theme.of(context).colorScheme;
    final report = root.report;
    final missing = (report?['missing'] as num? ?? 0).toInt();
    final unsupported = (report?['unsupported'] as num? ?? 0).toInt();
    final open = expanded.contains(root.key);
    return Material(
      key: ValueKey('reading-root:${root.key}'),
      color: palette.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        // Opens the shelf filtered by this folder.
        onTap: busy ? null : () => Navigator.pop(context, root.key),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 4, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    root.key == pinnedRoot
                        ? Icons.push_pin
                        : Icons.folder_outlined,
                    color: palette.accent,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          root.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          readingRootSummary(
                            root,
                            formats[root.key] ?? const {},
                            DateTime.now(),
                            trashed: trashed[root.key]?.length ?? 0,
                          ),
                          key: ValueKey('reading-root-summary:${root.key}'),
                          style: const TextStyle(fontSize: 13),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          readableFolderPath(root.path),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: palette.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    enabled: !busy && !scanning,
                    tooltip: 'Действия с папкой',
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
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (root.lastScan == null)
                      _plaque(
                        Icons.info_outline,
                        'Обновите папку, чтобы найти книги и проверить прежние.',
                        color: palette.accent,
                      ),
                    if (trashed[root.key]?.isNotEmpty ?? false)
                      _plaque(
                        Icons.delete_outline,
                        'В корзине книг этой папки: ${trashed[root.key]!.length}. На полке их нет.',
                        color: palette.accent,
                        action: TextButton(
                          key: ValueKey('restore-trashed:${root.key}'),
                          onPressed: busy || scanning
                              ? null
                              : () => _run(
                                  () =>
                                      BookTrash(widget.assets.repository)
                                          .restore(trashed[root.key]!),
                                ),
                          child: const Text('Вернуть'),
                        ),
                      ),
                    if (missing > 0)
                      _plaque(
                        Icons.help_outline,
                        'Не найдено прежних книг: $missing. Они в разделе «Файл не найден» и вернутся, когда файлы появятся.',
                        color: Colors.amber,
                      ),
                    if (root.warnings.isNotEmpty) ...[
                      _plaque(
                        Icons.warning_amber_rounded,
                        'Не удалось прочитать файлов: ${root.warnings.length}',
                        color: scheme.error,
                        action: TextButton(
                          onPressed: () => setState(
                            () => open
                                ? expanded.remove(root.key)
                                : expanded.add(root.key),
                          ),
                          child: Text(open ? 'Скрыть' : 'Подробнее'),
                        ),
                      ),
                      if (open)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 6, 0, 0),
                          child: Text(
                            root.warnings.take(20).join('\n') +
                                (root.warnings.length > 20
                                    ? '\n… и ещё ${root.warnings.length - 20}'
                                    : ''),
                            style: TextStyle(
                              fontSize: 12,
                              color: palette.muted,
                            ),
                          ),
                        ),
                    ],
                    if (unsupported > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'Пропущено файлов других форматов: $unsupported',
                          style: TextStyle(fontSize: 12, color: palette.muted),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final scan = activeReadingScan.value;
    return PepeSubpage(
      title: 'Папки книг',
      back: 'Книги',
      section: PepeSection.books,
      actions: [
        if (roots.isNotEmpty)
          IconButton(
            tooltip: 'Обновить все папки',
            onPressed: busy || scanning ? null : _refreshAll,
            icon: const Icon(Icons.refresh),
          ),
        IconButton(
          tooltip: 'Подключить папку книг',
          onPressed: busy || scanning ? null : _connect,
          icon: const Icon(Icons.create_new_folder_outlined),
        ),
      ],
      children: [
        if (busy || loading)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: LinearProgressIndicator(),
          ),
        if (scan != null) ...[
          FolderScanPanel(progress: scan),
          const SizedBox(height: 16),
        ],
        if (error.isNotEmpty) ...[_errorPanel(), const SizedBox(height: 16)],
        if (!loading && roots.isEmpty)
          _empty(palette)
        else ...[
          if (roots.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Text(
                'Нажмите на папку, чтобы открыть её книги на полке.',
                style: TextStyle(fontSize: 12.5, color: palette.muted),
              ),
            ),
          for (final root in roots) ...[
            _rootCard(root, palette),
            const SizedBox(height: 12),
          ],
        ],
        const SizedBox(height: 12),
        PepePanel(
          title: 'Импорт',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.download_outlined),
            title: const Text('Папка добавленных книг'),
            subtitle: const Text(
              'Куда копировать книги, открытые по одной через «Открыть файл…»',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: busy
                ? null
                : () => Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ImportFolderPage(assets: widget.assets),
                    ),
                  ).then((_) => _reload()),
          ),
        ),
      ],
    );
  }
}
