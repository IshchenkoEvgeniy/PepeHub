import 'dart:async';

import 'package:flutter/material.dart';

import '../audio/audio_folder.dart';
import '../audio/audio_roots.dart';
import '../media/asset_store.dart';
import '../media/audio_player_scope.dart';
import '../media/folder_scan_progress.dart';
import '../media/library_folder_preference.dart';
import 'audio_catalog_dialog.dart';
import 'folder_scan_panel.dart';
import 'pepe_widgets.dart';
import 'reading_roots_page.dart' show readableFolderPath;
import 'shelf_book_details.dart';
import 'shelf_components.dart';

/// «1 аудиокнига», «3 аудиокниги», «12 аудиокниг».
String audiobookCount(int n) {
  final last = n % 10, lastTwo = n % 100;
  final word = last == 1 && lastTwo != 11
      ? 'аудиокнига'
      : last >= 2 && last <= 4 && (lastTwo < 12 || lastTwo > 14)
      ? 'аудиокниги'
      : 'аудиокниг';
  return '$n $word';
}

/// «12 аудиокниг · 340 файлов · проверено вчера».
String audioRootSummary(AudioRoot root, DateTime now) {
  final report = (root.data['lastReport'] as Map?)?.cast<String, dynamic>();
  final files = (report?['supported'] as num?)?.toInt();
  final scan = DateTime.tryParse('${root.data['lastScan']}');
  return [
    audiobookCount(root.bookIds.length),
    if (files != null && files > 0) '$files файлов',
    scan == null ? 'ещё не проверялась' : 'проверено ${shelfDay(scan, now)}',
  ].join(' · ');
}

/// Connected audiobook folders. Tapping a folder returns its key: the shelf
/// then shows only that folder.
class AudioRootsPage extends StatefulWidget {
  final AssetStore assets;
  const AudioRootsPage({super.key, required this.assets});
  @override
  State<AudioRootsPage> createState() => _AudioRootsPageState();
}

class _AudioRootsPageState extends State<AudioRootsPage> {
  late final manager = AudioRoots(widget.assets);
  List<AudioRoot> roots = [];
  String? pinnedRoot;
  late final preference = LibraryFolderPreference(
    widget.assets.repository,
    reading: false,
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
    activeFolderScan.addListener(_scanChanged);
    unawaited(load());
  }

  @override
  void dispose() {
    activeFolderScan.removeListener(_scanChanged);
    super.dispose();
  }

  void _scanChanged() {
    if (mounted) setState(() {});
  }

  bool get scanning => activeFolderScan.value != null;

  Future<void> load() async {
    try {
      final items = await manager.list();
      final pinned = await preference.load();
      if (!mounted) return;
      setState(() {
        roots = items..sort((a, b) => a.title.compareTo(b.title));
        pinnedRoot = pinned;
        loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = 'Не удалось загрузить папки: $e';
          retry = load;
        });
      }
    }
  }

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
      await load();
      if (mounted) setState(() => busy = false);
    }
  }

  /// Runs a scan with live progress. It keeps running if the user leaves.
  Future<void> _scan(
    String title,
    Future<RootRefreshResult?> Function(FolderScanProgress progress) work,
  ) async {
    if (scanning || busy) return;
    final progress = FolderScanProgress(title);
    activeFolderScan.value = progress;
    if (mounted) setState(() => error = '');
    FolderScanOutcome? outcome;
    try {
      final result = await work(progress);
      retry = null;
      outcome = FolderScanOutcome(
        result == null
            ? 'Папки обновлены'
            : 'Добавлено: ${result.added}, обновлено: ${result.updated}'
                  '${result.warnings.isEmpty ? '' : '. Есть замечания — см. карточку папки'}',
      );
    } on FolderScanCancelled {
      outcome = const FolderScanOutcome(
        'Обновление отменено. Библиотека не изменилась.',
      );
    } catch (e) {
      error = 'Не удалось обновить папку: $e';
      retry = () => _scan(title, work);
      outcome = FolderScanOutcome(error, failed: true);
    } finally {
      activeFolderScan.value = null;
      if (mounted) {
        if (outcome != null && !outcome.failed) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(outcome.message)));
        }
        await load();
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
      folder = await pickAudioFolder();
    } catch (e) {
      setState(() {
        error = 'Не удалось открыть папку: $e';
        retry = _connect;
      });
      return;
    }
    if (folder == null || !mounted) return;
    await AudioPlayerScope.of(context)?.stop();
    if (!mounted) return;
    final count = await showDialog<int>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          AudioCatalogDialog(folder: folder!, assets: widget.assets),
    );
    await load();
    if (count != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Подключено: ${audiobookCount(count)}. Файлы остаются на месте.',
          ),
        ),
      );
    }
  }

  Future<void> _refreshAll() => _scan('Обновление папок', (progress) async {
    final list = [...roots];
    var added = 0, updated = 0;
    final warnings = <String>[];
    for (final (index, root) in list.indexed) {
      progress.update(
        title: list.length == 1
            ? 'Обновление «${root.title}»'
            : 'Папка ${index + 1} из ${list.length}: ${root.title}',
      );
      final result = await manager.refresh(root, progress: progress);
      added += result.added;
      updated += result.updated;
      warnings.addAll(result.warnings);
    }
    return RootRefreshResult(added, updated, warnings);
  });

  Future<void> _select(AudioRoot root, String action) async {
    if (busy || scanning) return;
    switch (action) {
      case 'pin':
        await _run(
          () => preference.set(pinnedRoot == root.key ? null : root.key),
        );
      case 'refresh':
        await _scan(
          'Обновление «${root.title}»',
          (progress) => manager.refresh(root, progress: progress),
        );
      case 'rename':
        await _rename(root);
      case 'move':
        final AudioFolder? folder;
        try {
          folder = await pickAudioFolder();
        } catch (e) {
          setState(() => error = 'Не удалось открыть папку: $e');
          return;
        }
        if (folder == null || !mounted) return;
        await _scan(
          'Новый путь для «${root.title}»',
          (progress) =>
              manager.refresh(root, replacement: folder, progress: progress),
        );
      case 'disconnect':
        await _remove(root);
    }
  }

  Future<void> _rename(AudioRoot root) async {
    var title = root.title;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Название папки в PepeHub'),
        content: TextFormField(
          initialValue: title,
          onChanged: (value) => title = value,
          maxLength: 500,
          autofocus: true,
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
    if (result != null && mounted) {
      await _run(() => manager.rename(root, result));
    }
  }

  Future<void> _remove(AudioRoot root) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Отключить папку аудиокниг?'),
        content: Text(
          '${root.title} · ${audiobookCount(root.bookIds.length)}.\nАудиокниги этой папки скроются из списка. Файлы на диске не удаляются. Позиции, закладки и история сохранятся, если подключить папку снова.',
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
    if (yes == true && mounted) await _run(() => manager.remove(root));
  }

  Widget _errorPanel() {
    final scheme = Theme.of(context).colorScheme;
    return PepePanel(
      key: const ValueKey('audio-roots-error'),
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
    key: const ValueKey('audio-roots-empty'),
    child: Column(
      children: [
        const SizedBox(height: 8),
        Icon(Icons.library_music_outlined, size: 44, color: palette.muted),
        const SizedBox(height: 12),
        const Text(
          'Подключите папку с аудиокнигами',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          'Каждая вложенная папка станет отдельной аудиокнигой; перед подключением можно проверить группировку. Файлы остаются на месте.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, height: 1.4, color: palette.muted),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: busy || scanning ? null : _connect,
          icon: const Icon(Icons.create_new_folder_outlined),
          label: const Text('Подключить папку аудиокниг'),
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

  Widget _rootCard(AudioRoot root, ShelfPalette palette) {
    final scheme = Theme.of(context).colorScheme;
    final report = (root.data['lastReport'] as Map?)?.cast<String, dynamic>();
    final missing = (report?['missing'] as num? ?? 0).toInt();
    final unsupported = (report?['unsupported'] as num? ?? 0).toInt();
    // Missing books are already counted above; list only the other warnings.
    final warnings = ((root.data['warnings'] as List?)?.cast<String>() ?? [])
        .where((w) => !w.endsWith('не найдена; карточка и прогресс сохранены.'))
        .toList();
    final open = expanded.contains(root.key);
    return Material(
      key: ValueKey('audio-root:${root.key}'),
      color: palette.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
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
                          audioRootSummary(root, DateTime.now()),
                          key: ValueKey('audio-root-summary:${root.key}'),
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
                        value: 'move',
                        child: Text('Изменить путь'),
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
                    if (root.data['lastScan'] == null)
                      _plaque(
                        Icons.info_outline,
                        'Обновите папку, чтобы найти новые аудиокниги и проверить прежние.',
                        color: palette.accent,
                      ),
                    if (missing > 0)
                      _plaque(
                        Icons.help_outline,
                        'Не найдено прежних аудиокниг: $missing. Карточки и позиции сохранены; они вернутся, когда папки появятся.',
                        color: Colors.amber,
                      ),
                    if (warnings.isNotEmpty) ...[
                      _plaque(
                        Icons.warning_amber_rounded,
                        'Не удалось обработать: ${warnings.length}',
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
                            warnings.take(20).join('\n') +
                                (warnings.length > 20
                                    ? '\n… и ещё ${warnings.length - 20}'
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
    final scan = activeFolderScan.value;
    return PepeSubpage(
      title: 'Папки аудиокниг',
      back: 'Аудиокниги',
      section: PepeSection.audio,
      actions: [
        if (roots.isNotEmpty)
          IconButton(
            tooltip: 'Обновить все папки',
            onPressed: busy || scanning ? null : _refreshAll,
            icon: const Icon(Icons.refresh),
          ),
        IconButton(
          tooltip: 'Подключить папку аудиокниг',
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
                'Нажмите на папку, чтобы открыть её аудиокниги на полке.',
                style: TextStyle(fontSize: 12.5, color: palette.muted),
              ),
            ),
          for (final root in roots) ...[
            _rootCard(root, palette),
            const SizedBox(height: 12),
          ],
        ],
      ],
    );
  }
}
