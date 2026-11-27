import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../audio/audio_import.dart' show naturalAudioOrder;
import '../diagnostics/user_message.dart';
import '../media/audio_controller.dart';
import '../ui/audio_mini_player.dart';
import '../ui/pepe_widgets.dart';
import '../ui/shelf_components.dart';
import 'models.dart';
import 'video_activity.dart';
import 'video_course_editor.dart';
import 'video_covers.dart';
import 'video_folder_dialog.dart';
import 'video_folder_sync.dart';
import 'video_import.dart';
import 'video_media_actions.dart';
import 'video_media_views.dart';
import 'video_player_page.dart';
import 'video_playlists.dart';
import 'video_progress_widgets.dart';
import 'video_repository.dart';
import 'video_session.dart';
import 'video_statistics_page.dart';
import 'video_thumbnails.dart';

/// Orders of the files inside a course, saved between launches.
const courseSortLabels = {
  'course': 'Порядок курса',
  'title': 'По названию А–Я',
  'title-desc': 'По названию Я–А',
  'duration': 'Сначала длинные',
  'duration-short': 'Сначала короткие',
  'recent': 'Недавно смотрели',
  'unwatched': 'Сначала непросмотренные',
};

class VideoCoursePage extends StatefulWidget {
  final VideoRepository repository;
  final VideoItem item;
  final AudioController? audio;
  final VideoThumbnails? thumbnails;
  final VideoFileDeleter deleter;
  final VideoCovers? covers;
  const VideoCoursePage({
    super.key,
    required this.repository,
    required this.item,
    this.audio,
    this.thumbnails,
    this.deleter = const PlatformVideoFileDeleter(),
    this.covers,
  });
  @override
  State<VideoCoursePage> createState() => _VideoCoursePageState();
}

class _ModuleHeader {
  final String title;
  const _ModuleHeader(this.title);
}

class _VideoCoursePageState extends State<VideoCoursePage> {
  /// Marks as they were when the course was opened; the library clears
  /// them after the course is closed.
  late final Set<String> _newLessons = widget.item.newLessons.toSet();
  late VideoItem currentItem = widget.item;

  /// Lessons with files on the device in course order; [allLessons] adds
  /// deleted ones, which the structure editor must keep.
  List<VideoLesson> lessons = [], allLessons = [];
  Map<String, VideoProgress> progress = {};
  String? error;
  bool loading = true;
  bool opening = false;
  VideoStats? stats;
  VideoPreferences preferences = const VideoPreferences();
  Map<String, VideoLearningState> learning = {};
  String sortBy = 'course', view = 'list';
  final selected = <String>{};

  /// Lesson ID → its number in course order, for any sort.
  Map<String, int> _numbers = {};
  bool _settingsLoaded = false;
  int _request = 0;

  bool get selecting => selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final request = ++_request;
    try {
      if (!_settingsLoaded) {
        final meta = widget.repository.repository;
        final savedSort = await meta.meta('course-sort');
        if (courseSortLabels.containsKey(savedSort)) sortBy = savedSort!;
        final savedView = await meta.meta('media-view');
        if (videoViewLabels.containsKey(savedView)) view = savedView!;
        _settingsLoaded = true;
      }
      final found = (await widget.repository.items())
          .where((item) => item.id == widget.item.id)
          .firstOrNull;
      if (found == null) {
        // Removed or merged into another course.
        if (mounted) Navigator.pop(context);
        return;
      }
      currentItem = found;
      final all = (await widget.repository.lessons(itemId: widget.item.id))
          .where((lesson) => !lesson.isAudio)
          .toList();
      final next = [
        for (final lesson in all)
          if (!lesson.missing) lesson,
      ];
      final positions = await widget.repository.allProgress();
      final settings = await widget.repository.preferences();
      final states = await widget.repository.allLearningStates();
      final ids = next.map((l) => l.id).toSet();
      final coverage = await compute(
        analyzeVideo,
        VideoAnalysisRequest(
          await widget.repository.intervals(lessonIds: ids),
          lessonIds: ids,
          lessons: next,
        ),
      );
      if (mounted && request == _request) {
        setState(() {
          lessons = next;
          allLessons = all;
          _numbers = {for (var i = 0; i < next.length; i++) next[i].id: i + 1};
          progress = positions;
          stats = coverage;
          preferences = settings;
          learning = states;
          loading = false;
          error = null;
          selected.retainAll(ids);
        });
      }
    } catch (e) {
      if (mounted && request == _request) {
        setState(() {
          error = describeError(e);
          loading = false;
        });
      }
    }
  }

  Future<void> _setSort(String value) async {
    setState(() => sortBy = value);
    await widget.repository.repository.setMeta('course-sort', value);
  }

  Future<void> _setView(String value) async {
    setState(() => view = value);
    await widget.repository.repository.setMeta('media-view', value);
  }

  Future<void> _statistics() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => VideoStatisticsPage(
          repository: widget.repository,
          item: currentItem,
        ),
      ),
    );
    if (mounted) await _load();
  }

  String? _completionLabel(VideoLesson lesson) {
    final state = learning['${lesson.id}:${lesson.mediaVersion}'];
    if (state?.manualCompletedAt != null) return 'Просмотрено';
    if (stats != null &&
        lesson.durationMs != null &&
        lesson.durationMs! > 0 &&
        stats!.lessonCoverage(lesson) * 100 >=
            lesson.durationMs! * preferences.completionPercent) {
      return 'Покрытие ≥ ${preferences.completionPercent}%';
    }
    return null;
  }

  bool _manuallyWatched(VideoLesson lesson) =>
      learning['${lesson.id}:${lesson.mediaVersion}']?.manualCompletedAt !=
      null;

  Future<void> _play(List<VideoLesson> queue, int index) async {
    if (opening || !currentItem.connected || !queue[index].available) return;
    setState(() => opening = true);
    try {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => VideoPlayerPage(
            repository: widget.repository,
            item: currentItem,
            lessons: queue,
            initialIndex: index,
            beforePlaying: widget.audio?.pause,
          ),
        ),
      );
      if (mounted) await _load();
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  int get _recentIndex {
    var result = 0;
    DateTime? recent;
    for (var i = 0; i < lessons.length; i++) {
      final saved = progress[lessons[i].id];
      if (saved != null &&
          saved.mediaVersion == lessons[i].mediaVersion &&
          (recent == null || saved.updatedAt.isAfter(recent))) {
        recent = saved.updatedAt;
        result = i;
      }
    }
    // A finished lesson sends «Continue» on to the next available one.
    if (recent != null && _finished(lessons[result])) {
      for (var i = result + 1; i < lessons.length; i++) {
        if (lessons[i].available) return i;
      }
    }
    return result;
  }

  bool _finished(VideoLesson lesson) {
    if (_manuallyWatched(lesson)) return true;
    final saved = progress[lesson.id];
    final duration = lesson.durationMs;
    return saved != null &&
        saved.mediaVersion == lesson.mediaVersion &&
        duration != null &&
        duration > 20000 &&
        saved.positionMs >= duration - 10000;
  }

  /// Lessons in the chosen order.
  List<VideoLesson> get _sorted {
    if (sortBy == 'course') return lessons;
    int byTitle(VideoLesson a, VideoLesson b) =>
        naturalAudioOrder(a.title.toLowerCase(), b.title.toLowerCase());
    DateTime? watchedAt(VideoLesson lesson) {
      final saved = progress[lesson.id];
      return saved?.mediaVersion == lesson.mediaVersion
          ? saved!.updatedAt
          : null;
    }

    final list = [...lessons];
    switch (sortBy) {
      case 'title':
        list.sort(byTitle);
      case 'title-desc':
        list.sort((a, b) => byTitle(b, a));
      case 'duration' || 'duration-short':
        final sign = sortBy == 'duration' ? -1 : 1;
        list.sort((a, b) {
          final order = sign * (a.durationMs ?? 0).compareTo(b.durationMs ?? 0);
          return order != 0 ? order : a.ordinal.compareTo(b.ordinal);
        });
      case 'recent':
        list.sort((a, b) {
          final x = watchedAt(a), y = watchedAt(b);
          if (x != null && y != null) return y.compareTo(x);
          if (x != null) return -1;
          if (y != null) return 1;
          return a.ordinal.compareTo(b.ordinal);
        });
      case 'unwatched':
        int rank(VideoLesson lesson) => _finished(lesson)
            ? 2
            : watchedAt(lesson) != null
            ? 1
            : 0;
        list.sort((a, b) {
          final order = rank(a).compareTo(rank(b));
          return order != 0 ? order : a.ordinal.compareTo(b.ordinal);
        });
    }
    return list;
  }

  List<Object> _rows(List<VideoLesson> sorted) {
    if (sortBy != 'course') return sorted;
    return [
      for (var i = 0; i < sorted.length; i++) ...[
        if (sorted[i].module.isNotEmpty &&
            (i == 0 || sorted[i].module != sorted[i - 1].module))
          _ModuleHeader(sorted[i].module),
        sorted[i],
      ],
    ];
  }

  Future<void> _folderAction(String action) async {
    if (action == 'cover') {
      if (await chooseMediaCover(
            context,
            widget.repository,
            currentItem,
            covers: widget.covers,
          ) &&
          mounted) {
        await _load();
      }
      return;
    }
    if (action == 'skip') {
      final current = await widget.repository.skipSettings(currentItem.id);
      if (!mounted) return;
      final value = await askSkipSettings(
        context,
        introMs: current.introMs,
        outroMs: current.outroMs,
      );
      if (value == null || !mounted) return;
      await _guard(
        () => widget.repository.saveSkipSettings(
          currentItem.id,
          introMs: value.introMs,
          outroMs: value.outroMs,
        ),
      );
      return;
    }
    if (action == 'rename') {
      final title = await askMediaTitle(
        context,
        title: 'Переименовать курс',
        initial: currentItem.title,
      );
      if (title == null || !mounted) return;
      await _guard(() => widget.repository.renameItem(currentItem.id, title));
      return;
    }
    if (opening || currentItem.root == null) return;
    setState(() {
      opening = true;
      error = null;
    });
    try {
      final session = VideoSessionScope.read(context);
      if (session?.item?.id == currentItem.id) await session!.close();
      if (action == 'disconnect') {
        await widget.repository.setRootConnection(currentItem, false);
      } else {
        final selection = action == 'reconnect'
            ? await pickVideoFiles(folder: true)
            : await scanVideoFolder(currentItem.root!);
        if (selection == null || !mounted) return;
        final preview = await previewVideoFolder(
          widget.repository,
          currentItem,
          selection,
        );
        if (!mounted) return;
        await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => VideoFolderRefreshDialog(preview: preview),
        );
      }
      if (mounted) await _load();
    } catch (e) {
      if (mounted) setState(() => error = describeError(e));
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  /// Runs an action, reports its error and reloads.
  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(describeError(e))));
      }
    }
    if (mounted) await _load();
  }

  void _toggle(VideoLesson lesson) => setState(() {
    if (!selected.remove(lesson.id)) selected.add(lesson.id);
  });

  List<VideoLesson> get _selectedLessons => [
    for (final lesson in lessons)
      if (selected.contains(lesson.id)) lesson,
  ];

  Future<void> _lessonAction(String action, List<VideoLesson> chosen) async {
    if (chosen.isEmpty) return;
    final what = chosen.length == 1
        ? '«${chosen.single.title}»'
        : mediaCount(chosen.length, music: false);
    switch (action) {
      case 'rename':
        final lesson = chosen.single;
        final title = await askMediaTitle(
          context,
          title: 'Переименовать',
          initial: lesson.title,
        );
        if (title == null || !mounted) return;
        await _guard(() => widget.repository.renameLesson(lesson.id, title));
      case 'details':
        await showMediaDetails(
          context,
          widget.repository,
          title: chosen.length == 1 ? chosen.single.title : what,
          lessons: chosen,
          progress: progress,
        );
      case 'playlist':
        await addLessonsToPlaylist(context, widget.repository, chosen);
        if (mounted) setState(selected.clear);
      case 'watched' || 'unwatched':
        await _guard(() async {
          await setLessonsWatched(
            widget.repository,
            chosen,
            action == 'watched',
          );
          selected.clear();
        });
      case 'select':
        setState(() => selected.add(chosen.single.id));
      case 'remove':
        if (await removeFromMediaLibrary(
          context,
          widget.repository,
          lessons: chosen,
          what: what,
        )) {
          selected.clear();
          if (mounted) await _load();
        }
      case 'delete':
        await deleteMediaFiles(
          context,
          widget.repository,
          chosen,
          what: what,
          deleter: widget.deleter,
        );
        selected.clear();
        if (mounted) await _load();
    }
  }

  List<PopupMenuEntry<String>> _lessonMenu(List<VideoLesson> chosen) {
    final single = chosen.length == 1;
    final watched = chosen.every(_manuallyWatched);
    return [
      if (single)
        const PopupMenuItem(value: 'rename', child: Text('Переименовать…')),
      const PopupMenuItem(value: 'details', child: Text('Сведения')),
      const PopupMenuItem(value: 'playlist', child: Text('В плейлист…')),
      PopupMenuItem(
        value: watched ? 'unwatched' : 'watched',
        child: Text(
          watched ? 'Снять отметку «Просмотрено»' : 'Отметить просмотренным',
        ),
      ),
      if (single && !selecting)
        const PopupMenuItem(value: 'select', child: Text('Выбрать')),
      const PopupMenuDivider(),
      const PopupMenuItem(value: 'remove', child: Text('Убрать из курса…')),
      const PopupMenuItem(
        value: 'delete',
        child: Text('Удалить с устройства…'),
      ),
    ];
  }

  Widget _tile(BuildContext context, Object row, List<VideoLesson> queue) {
    final palette = ShelfPalette.of(context);
    if (row is _ModuleHeader) {
      return Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 2),
        child: Text(row.title, style: Theme.of(context).textTheme.titleMedium),
      );
    }
    final lesson = row as VideoLesson;
    final number = _numbers[lesson.id] ?? 0;
    final saved = progress[lesson.id];
    final duration = lesson.durationMs;
    final details = [
      if (view == 'list' && duration != null) pepeTime(duration),
      if (stats != null && duration != null && duration > 0)
        'Просмотрено: ${(stats!.lessonCoverage(lesson) * 100 / duration).toStringAsFixed(view == 'list' ? 1 : 0)}%',
      ?_completionLabel(lesson),
      if (view == 'list' &&
          learning['${lesson.id}:${lesson.mediaVersion}']?.understoodAt != null)
        'Разобрался',
      if (view == 'list' && saved?.mediaVersion == lesson.mediaVersion)
        'Позиция: ${pepeTime(saved!.positionMs)}',
      if (view == 'list') lesson.isRemote ? 'По ссылке' : 'Локальный файл',
      if (!lesson.available) 'Файл недоступен',
    ];
    final playable = currentItem.connected && lesson.available;
    return VideoMediaTile(
      key: ValueKey('course-lesson:${lesson.id}'),
      view: view,
      title: view == 'list' || sortBy != 'course'
          ? lesson.title
          : '$number. ${lesson.title}',
      subtitle: details.join(' · '),
      cover: lesson,
      icon: Icons.play_circle_outline,
      thumbnails: widget.thumbnails,
      // Files added by automatic search since the course was last opened.
      tag: _newLessons.contains(lesson.id) ? 'Новое' : null,
      badge: sortBy == 'course' && view == 'list'
          ? '$number'
          : duration == null
          ? null
          : pepeTime(duration),
      selected: selecting ? selected.contains(lesson.id) : null,
      dimmed: !playable,
      onTap: selecting
          ? () => _toggle(lesson)
          : opening || !playable
          ? null
          : () => _play(queue, queue.indexOf(lesson)),
      onLongPress: () => _toggle(lesson),
      trailing: selecting
          ? null
          : PopupMenuButton<String>(
              key: ValueKey('lesson-menu:${lesson.id}'),
              tooltip: 'Действия',
              iconColor: palette.muted,
              onSelected: (action) => _lessonAction(action, [lesson]),
              itemBuilder: (_) => _lessonMenu([lesson]),
            ),
    );
  }

  PreferredSizeWidget _appBar() {
    if (selecting) {
      final chosen = _selectedLessons;
      return PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: VideoSelectionBar(
          count: selected.length,
          total: lessons.length,
          onClose: () => setState(selected.clear),
          onSelectAll: () => setState(() {
            if (selected.length == lessons.length) {
              selected.clear();
            } else {
              selected.addAll(lessons.map((l) => l.id));
            }
          }),
          actions: [
            IconButton(
              tooltip: 'В плейлист',
              onPressed: () => _lessonAction('playlist', chosen),
              icon: const Icon(Icons.playlist_add),
            ),
            PopupMenuButton<String>(
              key: const ValueKey('selection-menu'),
              tooltip: 'Ещё',
              onSelected: (action) => _lessonAction(action, chosen),
              itemBuilder: (_) => _lessonMenu(chosen),
            ),
          ],
        ),
      );
    }
    return AppBar(
      title: Text(currentItem.title),
      actions: [
        PopupMenuButton<String>(
          key: const ValueKey('course-sort'),
          tooltip: 'Сортировка: ${courseSortLabels[sortBy]}',
          icon: const Icon(Icons.sort),
          onSelected: _setSort,
          itemBuilder: (_) => [
            for (final entry in courseSortLabels.entries)
              CheckedPopupMenuItem(
                value: entry.key,
                checked: entry.key == sortBy,
                child: Text(entry.value),
              ),
          ],
        ),
        VideoViewButton(view: view, onSelected: _setView),
        IconButton(
          tooltip: 'Статистика курса',
          onPressed: _statistics,
          icon: const Icon(Icons.bar_chart),
        ),
        PopupMenuButton<String>(
          key: const ValueKey('course-menu'),
          tooltip: 'Курс',
          enabled: !loading && !opening,
          onSelected: (action) async {
            if (action == 'edit') {
              await Navigator.push<bool>(
                context,
                MaterialPageRoute(
                  builder: (_) => VideoCourseEditor(
                    repository: widget.repository,
                    item: currentItem,
                    lessons: allLessons,
                  ),
                ),
              );
              if (mounted) await _load();
            } else {
              await _folderAction(action);
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(
              value: 'rename',
              child: Text('Переименовать курс…'),
            ),
            const PopupMenuItem(value: 'edit', child: Text('Структура курса…')),
            const PopupMenuItem(value: 'cover', child: Text('Обложка…')),
            const PopupMenuItem(
              value: 'skip',
              child: Text('Пропуск заставки…'),
            ),
            if (currentItem.root != null) ...[
              const PopupMenuDivider(),
              if (currentItem.connected)
                const PopupMenuItem(
                  value: 'refresh',
                  child: Text('Обновить папку'),
                ),
              const PopupMenuItem(
                value: 'reconnect',
                child: Text('Переподключить папку'),
              ),
              if (currentItem.connected)
                const PopupMenuItem(
                  value: 'disconnect',
                  child: Text('Отключить папку'),
                ),
            ],
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final sorted = _sorted;
    final rows = _rows(sorted);
    return PopScope(
      canPop: !selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && selecting) setState(selected.clear);
      },
      child: Scaffold(
        bottomNavigationBar: const AudioPlayerFooter(),
        appBar: _appBar(),
        body: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              sliver: SliverList.list(
                children: [
                  if (loading) const LinearProgressIndicator(),
                  if (opening) const LinearProgressIndicator(),
                  if (!currentItem.connected)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        'Папка отключена. Переподключите её через меню, чтобы продолжить курс.',
                      ),
                    ),
                  if (error != null) Text(error!),
                  if (stats != null) ...[
                    VideoCourseProgressPanel(
                      coverage: videoCourseCoverage(
                        lessons,
                        stats!,
                        preferences.completionPercent,
                        learning,
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  if (lessons.isNotEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        onPressed:
                            opening ||
                                selecting ||
                                !currentItem.connected ||
                                !lessons[_recentIndex].available
                            ? null
                            : () => _play(lessons, _recentIndex),
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Продолжить курс'),
                      ),
                    ),
                  if (!loading && lessons.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Text('В курсе нет файлов на устройстве.'),
                    ),
                  const SizedBox(height: 4),
                ],
              ),
            ),
            ...videoMediaSlivers(
              rows: rows,
              view: view,
              isTile: (row) => row is VideoLesson,
              build: (context, row) => _tile(context, row, sorted),
            ),
          ],
        ),
      ),
    );
  }
}
