import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/user_message.dart';
import '../ui/pepe_widgets.dart';
import '../ui/shelf_components.dart';
import 'models.dart';
import 'video_discovery_page.dart' show videoBytes;
import 'video_import.dart' show videoFilesChannel;
import 'video_media_actions.dart';
import 'video_media_status.dart';
import 'video_repository.dart';

/// Sizes of local files that were added without one. Replaceable in tests.
abstract class VideoFileSizer {
  /// Source → size in bytes; unreadable files are left out.
  Future<Map<String, int>> sizes(List<String> sources);
}

class PlatformVideoFileSizer implements VideoFileSizer {
  const PlatformVideoFileSizer();

  @override
  Future<Map<String, int>> sizes(List<String> sources) async {
    final local = [
      for (final source in sources)
        if (!source.startsWith('http://') && !source.startsWith('https://'))
          source,
    ];
    if (local.isEmpty || Platform.environment.containsKey('FLUTTER_TEST')) {
      return {};
    }
    if (Platform.isAndroid) {
      Map<String, dynamic>? result;
      try {
        result = await videoFilesChannel.invokeMapMethod<String, dynamic>(
          'fileSizes',
          {'uris': local},
        );
      } on Exception {
        // Sizes stay unknown; the page still lists the files.
        return {};
      }
      return {
        for (final entry in (result ?? const {}).entries)
          if (entry.value is int && (entry.value as int) > 0)
            entry.key: entry.value as int,
      };
    }
    final sizes = <String, int>{};
    for (final source in local) {
      try {
        if (!p.isAbsolute(source)) continue;
        final file = File(source);
        if (await file.exists()) sizes[source] = await file.length();
      } on FileSystemException {
        // An unreadable file has no known size.
      }
    }
    return sizes;
  }
}

/// Short name of a file for lists: the file name of a path or a link.
String videoSourceName(String source) => videoFileName(source);

String _ago(DateTime at, DateTime now) {
  final days = now.difference(at).inDays;
  if (days <= 0) return 'сегодня';
  if (days == 1) return 'вчера';
  return '$days дн. назад';
}

/// «Корзина медиатеки»: what was removed in the last 30 days.
class VideoTrashPage extends StatefulWidget {
  final VideoRepository repository;
  const VideoTrashPage({super.key, required this.repository});

  @override
  State<VideoTrashPage> createState() => _VideoTrashPageState();
}

class _VideoTrashPageState extends State<VideoTrashPage> {
  List<VideoTrashEntry> entries = [];
  bool loading = true, busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final next = await widget.repository.trash();
      if (!mounted) return;
      setState(() {
        entries = next;
        loading = false;
        error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = describeError(e);
        });
      }
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
      widget.repository.repository.notifyExternalChange();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(describeError(e))));
      }
    } finally {
      if (mounted) setState(() => busy = false);
      await _load();
    }
  }

  Future<void> _empty() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Очистить корзину?'),
        content: const Text(
          'Записи нельзя будет вернуть из корзины. Файлы на устройстве '
          'останутся, автопоиск не будет добавлять их снова — только ручной '
          'поиск.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Очистить'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _run(() => widget.repository.forgetTrash(entries));
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final now = DateTime.now();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Корзина медиатеки'),
        actions: [
          if (entries.isNotEmpty)
            TextButton(
              key: const ValueKey('trash-empty'),
              onPressed: busy ? null : _empty,
              child: const Text('Очистить'),
            ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            sliver: SliverList.list(
              children: [
                if (loading || busy) const LinearProgressIndicator(),
                Text(
                  'Убранное из медиатеки хранится здесь 30 дней. Файлы на '
                  'устройстве не трогаются; прогресс и заметки вернутся вместе '
                  'с записью.',
                  style: TextStyle(color: palette.muted),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(error!),
                  ),
                if (!loading && entries.isEmpty && error == null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Center(child: Text('Корзина пуста')),
                  ),
              ],
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            sliver: SliverList.builder(
              itemCount: entries.length,
              itemBuilder: (context, i) {
                final entry = entries[i];
                final left = 30 - now.difference(entry.removedAt).inDays;
                return Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: ShelfPanel(
                    child: ListTile(
                      key: ValueKey('trash-entry:${entry.id}'),
                      leading: Icon(
                        entry.audio
                            ? Icons.music_note_outlined
                            : entry.course
                            ? Icons.school_outlined
                            : Icons.ondemand_video,
                        color: palette.accent,
                      ),
                      title: Text(
                        entry.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        [
                          if (entry.parentTitle != null)
                            'из «${entry.parentTitle}»'
                          else if (entry.course)
                            'Курс · файлов: ${entry.lessonIds.length}',
                          'убрано ${_ago(entry.removedAt, now)}',
                          'останется ${left.clamp(1, 30)} дн.',
                        ].join(' · '),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            key: ValueKey('trash-restore:${entry.id}'),
                            onPressed: busy
                                ? null
                                : () => _run(
                                    () => widget.repository.restoreTrash(entry),
                                  ),
                            child: const Text('Вернуть'),
                          ),
                          IconButton(
                            tooltip: 'Убрать из корзины',
                            onPressed: busy
                                ? null
                                : () => _run(
                                    () =>
                                        widget.repository.forgetTrash([entry]),
                                  ),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Files of the same content in several places of the media library.
class VideoDuplicatesPage extends StatefulWidget {
  final VideoRepository repository;
  final VideoFileDeleter deleter;
  final bool music;
  const VideoDuplicatesPage({
    super.key,
    required this.repository,
    this.deleter = const PlatformVideoFileDeleter(),
    this.music = false,
  });

  @override
  State<VideoDuplicatesPage> createState() => _VideoDuplicatesPageState();
}

class _VideoDuplicatesPageState extends State<VideoDuplicatesPage> {
  List<List<VideoFileFact>> groups = [];
  Map<String, VideoItem> items = {};
  Map<String, VideoProgress> progress = {};
  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final facts = await widget.repository.fileFacts(audio: widget.music);
      final nextItems = {
        for (final item in await widget.repository.items()) item.id: item,
      };
      final nextProgress = await widget.repository.allProgress();
      if (!mounted) return;
      setState(() {
        groups = videoDuplicateGroups(facts);
        items = nextItems;
        progress = nextProgress;
        loading = false;
        error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = describeError(e);
        });
      }
    }
  }

  /// The copy to keep: the most watched, then the first added.
  VideoFileFact _keeper(List<VideoFileFact> group) {
    var best = group.first;
    var bestPosition = videoOwnProgress(best.lesson, progress)?.positionMs ?? 0;
    for (final fact in group.skip(1)) {
      final position = videoOwnProgress(fact.lesson, progress)?.positionMs ?? 0;
      if (position > bestPosition) {
        best = fact;
        bestPosition = position;
      }
    }
    return best;
  }

  Future<void> _deleteExtra(List<VideoFileFact> group) async {
    final keep = _keeper(group);
    final extra = [
      for (final fact in group)
        if (!identical(fact, keep) && !videoMaybeSameFile(fact, keep))
          fact.lesson,
    ];
    if (extra.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text(
              'Похоже, это один и тот же файл, открытый разными способами. '
              'Удалите лишнюю запись вручную через меню копии',
            ),
          ),
        );
      return;
    }
    await deleteMediaFiles(
      context,
      widget.repository,
      extra,
      what: extra.length == 1
          ? 'лишнюю копию'
          : 'лишние копии (${extra.length})',
      deleter: widget.deleter,
    );
    if (mounted) await _load();
  }

  Future<void> _copyAction(String action, VideoFileFact fact) async {
    final what = '«${fact.lesson.title}»';
    if (action == 'delete') {
      await deleteMediaFiles(
        context,
        widget.repository,
        [fact.lesson],
        what: what,
        deleter: widget.deleter,
      );
    } else if (action == 'remove') {
      await removeFromMediaLibrary(
        context,
        widget.repository,
        lessons: [fact.lesson],
        what: what,
      );
    }
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final wasted = groups.fold<int>(
      0,
      (sum, group) => sum + (group.first.size ?? 0) * (group.length - 1),
    );
    final rows = <Object>[
      for (final group in groups) ...[group, ...group],
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Повторяющиеся файлы')),
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            sliver: SliverList.list(
              children: [
                if (loading) const LinearProgressIndicator(),
                if (error != null) Text(error!),
                if (!loading && error == null)
                  Text(
                    groups.isEmpty
                        ? 'Повторяющихся файлов нет.'
                        : 'Групп: ${groups.length}'
                              '${wasted > 0 ? ' · лишние копии занимают ${videoBytes(wasted)}' : ''}',
                    key: const ValueKey('duplicates-summary'),
                  ),
                const SizedBox(height: 4),
                Text(
                  'Копией считается файл того же размера и содержания или с '
                  'тем же именем и размером.',
                  style: TextStyle(color: palette.muted, fontSize: 12),
                ),
              ],
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            sliver: SliverList.builder(
              itemCount: rows.length,
              itemBuilder: (context, i) {
                final row = rows[i];
                if (row is List<VideoFileFact>) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 20, bottom: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${videoSourceName(row.first.lesson.source)} · '
                            'копий: ${row.length}'
                            '${row.first.size == null ? '' : ' · ${videoBytes(row.first.size!)}'}',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        TextButton(
                          key: ValueKey(
                            'duplicates-keep:${row.first.lesson.id}',
                          ),
                          onPressed: () => _deleteExtra(row),
                          child: const Text('Оставить одну'),
                        ),
                      ],
                    ),
                  );
                }
                final fact = row as VideoFileFact;
                final saved = videoOwnProgress(fact.lesson, progress);
                final item = items[fact.lesson.itemId];
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: ShelfPanel(
                    child: ListTile(
                      key: ValueKey('duplicate:${fact.lesson.id}'),
                      title: Text(
                        fact.lesson.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        [
                          if (item != null) item.title,
                          if (saved != null)
                            'позиция ${pepeTime(saved.positionMs)}',
                          fact.lesson.source,
                        ].join(' · '),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: PopupMenuButton<String>(
                        key: ValueKey('duplicate-menu:${fact.lesson.id}'),
                        onSelected: (action) => _copyAction(action, fact),
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'remove',
                            child: Text('Убрать из медиатеки…'),
                          ),
                          PopupMenuItem(
                            value: 'delete',
                            child: Text('Удалить с устройства…'),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// How much space videos and courses take, the largest first.
class VideoStoragePage extends StatefulWidget {
  final VideoRepository repository;
  final VideoFileDeleter deleter;
  final VideoFileSizer sizer;
  final bool music;
  const VideoStoragePage({
    super.key,
    required this.repository,
    this.deleter = const PlatformVideoFileDeleter(),
    this.sizer = const PlatformVideoFileSizer(),
    this.music = false,
  });

  @override
  State<VideoStoragePage> createState() => _VideoStoragePageState();
}

class _StorageRow {
  final VideoItem item;
  final List<VideoLesson> lessons;
  final int bytes, unknown;
  final bool done;
  const _StorageRow(
    this.item,
    this.lessons,
    this.bytes,
    this.unknown,
    this.done,
  );
}

class _VideoStoragePageState extends State<VideoStoragePage> {
  List<_StorageRow> rows = [];
  bool loading = true, onlyDone = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      var facts = await widget.repository.fileFacts(audio: widget.music);
      final unknown = [
        for (final fact in facts)
          if (fact.size == null && !fact.lesson.isRemote) fact,
      ];
      if (unknown.isNotEmpty) {
        final measured = await widget.sizer.sizes([
          for (final fact in unknown) fact.lesson.source,
        ]);
        if (measured.isNotEmpty) {
          await widget.repository.saveFileSizes({
            for (final fact in unknown)
              if (measured[fact.lesson.source] case final int size)
                fact.lesson.id: size,
          });
          facts = await widget.repository.fileFacts(audio: widget.music);
        }
      }
      final items = await widget.repository.items();
      final progress = await widget.repository.allProgress();
      final learning = await widget.repository.allLearningStates();
      final byItem = <String, List<VideoFileFact>>{};
      for (final fact in facts) {
        (byItem[fact.lesson.itemId] ??= []).add(fact);
      }
      final next = <_StorageRow>[];
      for (final item in items) {
        final own = byItem[item.id];
        if (own == null || own.isEmpty) continue;
        final lessons = [for (final fact in own) fact.lesson];
        next.add(
          _StorageRow(
            item,
            lessons,
            own.fold(0, (sum, fact) => sum + (fact.size ?? 0)),
            own.where((fact) => fact.size == null).length,
            videoItemState(lessons, progress, learning) == VideoWatchState.done,
          ),
        );
      }
      next.sort((a, b) => b.bytes.compareTo(a.bytes));
      if (!mounted) return;
      setState(() {
        rows = next;
        loading = false;
        error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = describeError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final total = rows.fold<int>(0, (sum, row) => sum + row.bytes);
    final done = rows
        .where((row) => row.done)
        .fold<int>(0, (sum, row) => sum + row.bytes);
    final shown = onlyDone ? rows.where((row) => row.done).toList() : rows;
    return Scaffold(
      appBar: AppBar(title: const Text('Место на устройстве')),
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            sliver: SliverList.list(
              children: [
                if (loading) const LinearProgressIndicator(),
                if (error != null) Text(error!),
                if (!loading && error == null) ...[
                  Text(
                    total == 0
                        ? 'Размер файлов неизвестен'
                        : '${widget.music ? 'Музыка занимает' : 'Видео занимают'} ${videoBytes(total)}',
                    key: const ValueKey('storage-total'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (done > 0)
                    Text(
                      'Из них досмотрено: ${videoBytes(done)} — эти файлы '
                      'можно удалить, прогресс останется в статистике.',
                      style: TextStyle(color: palette.muted),
                    ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilterChip(
                      key: const ValueKey('storage-only-done'),
                      label: const Text('Только досмотренные'),
                      selected: onlyDone,
                      onSelected: (value) => setState(() => onlyDone = value),
                    ),
                  ),
                ],
              ],
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            sliver: SliverList.builder(
              itemCount: shown.length,
              itemBuilder: (context, i) {
                final row = shown[i];
                final course = row.item.kind == VideoItemKind.course;
                return Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: ShelfPanel(
                    child: ListTile(
                      key: ValueKey('storage-item:${row.item.id}'),
                      leading: Icon(
                        widget.music
                            ? Icons.music_note_outlined
                            : course
                            ? Icons.school_outlined
                            : Icons.ondemand_video,
                        color: palette.accent,
                      ),
                      title: Text(
                        row.item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        [
                          row.bytes > 0
                              ? videoBytes(row.bytes)
                              : 'размер неизвестен',
                          if (course) 'файлов: ${row.lessons.length}',
                          if (row.unknown > 0 && row.bytes > 0)
                            'без размера: ${row.unknown}',
                          if (row.done) 'Досмотрено',
                        ].join(' · '),
                      ),
                      trailing: IconButton(
                        key: ValueKey('storage-delete:${row.item.id}'),
                        tooltip: 'Удалить с устройства',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          await deleteMediaFiles(
                            context,
                            widget.repository,
                            row.lessons,
                            what: '«${row.item.title}»',
                            deleter: widget.deleter,
                          );
                          if (mounted) await _load();
                        },
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
