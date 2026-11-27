import 'package:flutter/material.dart';

import '../media/audio_controller.dart';
import '../ui/pepe_widgets.dart';
import '../ui/shelf_components.dart';
import 'models.dart';
import 'video_import.dart';
import 'video_player_page.dart';
import 'video_repository.dart';
import 'video_statistics_page.dart';
import 'video_folder_sync.dart';
import 'video_folder_dialog.dart';
import 'video_session.dart';
import 'video_discovery.dart' show videoFolderSection;
import 'video_discovery_page.dart';
import 'video_discovery_scan.dart';
import 'video_playlists.dart';
import 'video_thumbnails.dart';
import 'video_auto_discovery.dart';
import 'video_course_page.dart';
import 'video_media_actions.dart';
import 'video_media_views.dart';
import '../audio/audio_import.dart' show naturalAudioOrder;
import '../vocabulary/vocabulary_page.dart';
import '../vocabulary/vocabulary_repository.dart';
import '../music/music_statistics_page.dart';
import '../diagnostics/user_message.dart';

class VideoLibraryPage extends StatefulWidget {
  final VideoRepository repository;
  final ShelfNavigation navigation;
  final AudioController? audio;
  final VideoFilePicker chooseFiles;
  final VideoDiscoveryScanner discoveryScanner;
  final VideoSourceChecker sourceChecker;
  final VideoThumbnails? thumbnails;
  final VideoFileDeleter deleter;
  const VideoLibraryPage({
    super.key,
    required this.repository,
    required this.navigation,
    this.audio,
    this.chooseFiles = pickVideoFiles,
    this.discoveryScanner = const PlatformVideoDiscoveryScanner(),
    this.sourceChecker = const PlatformVideoSourceChecker(),
    this.thumbnails,
    this.deleter = const PlatformVideoFileDeleter(),
  });
  @override
  State<VideoLibraryPage> createState() => _VideoLibraryPageState();
}

/// Orders of the media list, saved between launches.
const videoSortLabels = {
  'recent': 'Недавно смотрели',
  'added': 'Недавно добавленные',
  'added-old': 'Давно добавленные',
  'title': 'По названию А–Я',
  'title-desc': 'По названию Я–А',
  'duration': 'Сначала длинные',
};

class _VideoLibraryPageState extends State<VideoLibraryPage> {
  List<VideoItem> items = [];
  List<VideoLesson> lessons = [];
  Map<String, VideoProgress> progress = {};
  List<VideoPlaylist> playlists = [];
  bool loading = true, busy = false, favorites = false;
  String query = '', mediaFilter = 'video';

  /// `list`, `folders` or `playlists`.
  String groupBy = 'list';

  /// A key of [videoSortLabels].
  String sortBy = 'recent';

  /// A key of [videoViewLabels].
  String view = 'list';

  /// Selected items; selection mode while not empty.
  final selected = <String>{};
  Map<String, VideoLearningState> learning = {};
  bool get selecting => selected.isNotEmpty;
  Map<String, List<VideoLesson>> _byItem = {};
  bool _filterLoaded = false;
  String? error;
  int _request = 0;
  bool _background = false;
  late final AppLifecycleListener _lifecycle;
  @override
  void initState() {
    super.initState();
    widget.repository.repository.externalChanges.addListener(_load);
    _lifecycle = AppLifecycleListener(onResume: _upkeep);
    _load().then((_) => _upkeep());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    widget.repository.repository.externalChanges.removeListener(_load);
    super.dispose();
  }

  /// Hides deleted files and, when turned on, adds new videos by itself.
  /// Runs on opening and on returning to the app; errors stay quiet.
  Future<void> _upkeep() async {
    if (_background || !mounted) return;
    _background = true;
    try {
      try {
        final changed = await VideoAutoDiscovery.checkSources(
          widget.repository,
          widget.sourceChecker,
        );
        if (changed > 0 && mounted) await _load();
      } catch (_) {
        /* The next opening checks again. */
      }
      if (!mounted) return;
      final found = await VideoAutoDiscovery.search(
        widget.repository,
        widget.discoveryScanner,
      );
      if (found == null || found.files == 0 || !mounted) return;
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              'Автопоиск добавил видео: ${found.files} '
              '(${found.groups == 1 ? 'в одну группу' : 'групп: ${found.groups}'})',
            ),
          ),
        );
    } catch (_) {
      /* Background search reports nothing; the search page shows errors. */
    } finally {
      _background = false;
    }
  }

  Future<void> _load() async {
    final request = ++_request;
    try {
      if (!_filterLoaded) {
        mediaFilter =
            await widget.repository.repository.meta('media-section') == 'music'
            ? 'music'
            : 'video';
        final savedGroup = await widget.repository.repository.meta(
          'media-grouping',
        );
        if (const ['folders', 'playlists'].contains(savedGroup)) {
          groupBy = savedGroup!;
        }
        final savedSort = await widget.repository.repository.meta('media-sort');
        if (videoSortLabels.containsKey(savedSort)) sortBy = savedSort!;
        final savedView = await widget.repository.repository.meta('media-view');
        if (videoViewLabels.containsKey(savedView)) view = savedView!;
        _filterLoaded = true;
      }
      final nextItems = await widget.repository.items();
      // Deleted files are not listed; an item without files disappears.
      final nextLessons = await widget.repository.lessons(hideMissing: true);
      final nextProgress = await widget.repository.allProgress();
      final nextPlaylists = await widget.repository.playlists();
      final nextLearning = await widget.repository.allLearningStates();
      if (!mounted || request != _request) return;
      final byItem = <String, List<VideoLesson>>{};
      for (final lesson in nextLessons) {
        (byItem[lesson.itemId] ??= []).add(lesson);
      }
      setState(() {
        items = nextItems;
        lessons = nextLessons;
        _byItem = byItem;
        playlists = nextPlaylists;
        progress = nextProgress;
        learning = nextLearning;
        selected.retainAll({for (final item in nextItems) item.id});
        loading = false;
        error = null;
      });
    } catch (e) {
      if (mounted && request == _request) {
        setState(() {
          loading = false;
          error = 'Не удалось открыть медиатеку: ${describeError(e)}';
        });
      }
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(describeError(e))));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _pick(bool folder) => _run(() async {
    final selection = await widget.chooseFiles(folder: folder);
    if (selection == null || !mounted) return;
    final existing = selection.root == null
        ? null
        : (await widget.repository.items())
              .where((item) => item.root == selection.root)
              .firstOrNull;
    if (!mounted) return;
    if (existing != null) {
      if (!mounted) return;
      final session = VideoSessionScope.read(context);
      if (session?.item?.id == existing.id) await session!.close();
      final preview = await previewVideoFolder(
        widget.repository,
        existing,
        selection,
      );
      if (!mounted) return;
      await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => VideoFolderRefreshDialog(preview: preview),
      );
      if (mounted) await _load();
      return;
    }
    if (selection.sources.isEmpty) {
      throw StateError('В выбранной папке нет поддерживаемых видео или аудио');
    }
    final confirmed = await showDialog<VideoImportSelection>(
      context: context,
      builder: (_) => _VideoImportDialog(selection: selection),
    );
    if (confirmed == null) return;
    await widget.repository.addSources(
      title: confirmed.title,
      sources: confirmed.sources,
      root: confirmed.root,
    );
    mediaFilter = confirmed.sources.every((source) => source.isAudio)
        ? 'music'
        : 'video';
    await widget.repository.repository.setMeta('media-section', mediaFilter);
    await _load();
  });

  Future<void> _addLink() => _run(() async {
    final draft = await showDialog<VideoSourceDraft>(
      context: context,
      builder: (_) => const _VideoLinkDialog(),
    );
    if (draft == null) return;
    await widget.repository.addSources(title: draft.title, sources: [draft]);
    mediaFilter = draft.isAudio ? 'music' : 'video';
    await widget.repository.repository.setMeta('media-section', mediaFilter);
    await _load();
  });

  VideoProgress? _recent(VideoItem item) {
    VideoProgress? recent;
    for (final lesson in _sectionLessons(item)) {
      final saved = progress[lesson.id];
      if (saved != null &&
          saved.mediaVersion == lesson.mediaVersion &&
          (recent == null || saved.updatedAt.isAfter(recent.updatedAt))) {
        recent = saved;
      }
    }
    return recent;
  }

  // Lessons are indexed by item once per load: the list stays linear in
  // size with thousands of videos.
  Iterable<VideoLesson> _sectionLessons(VideoItem item) =>
      (_byItem[item.id] ?? const <VideoLesson>[]).where(
        (lesson) => lesson.isAudio == (mediaFilter == 'music'),
      );

  Future<void> _discover() async {
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => VideoDiscoveryPage(
          repository: widget.repository,
          scanner: widget.discoveryScanner,
        ),
      ),
    );
    if (!mounted) return;
    if (mediaFilter != 'video') {
      mediaFilter = 'video';
      await widget.repository.repository.setMeta('media-section', 'video');
    }
    await _load();
  }

  Future<void> _setGroupBy(String value) async {
    setState(() => groupBy = value);
    await widget.repository.repository.setMeta('media-grouping', value);
  }

  Future<void> _setSortBy(String value) async {
    setState(() => sortBy = value);
    await widget.repository.repository.setMeta('media-sort', value);
  }

  /// The order of [items] is the order they were added.
  int Function(VideoItem, VideoItem) _comparator() {
    int byTitle(VideoItem a, VideoItem b) =>
        naturalAudioOrder(a.title.toLowerCase(), b.title.toLowerCase());
    switch (sortBy) {
      case 'added' || 'added-old':
        final added = {for (var i = 0; i < items.length; i++) items[i].id: i};
        final sign = sortBy == 'added' ? -1 : 1;
        return (a, b) => sign * added[a.id]!.compareTo(added[b.id]!);
      case 'title':
        return byTitle;
      case 'title-desc':
        return (a, b) => byTitle(b, a);
      case 'duration':
        final total = <String, int>{};
        int length(VideoItem item) => total.putIfAbsent(
          item.id,
          () =>
              _sectionLessons(item)
                  .fold(0, (sum, lesson) => sum + (lesson.durationMs ?? 0)),
        );
        return (a, b) {
          final order = length(b).compareTo(length(a));
          return order != 0 ? order : byTitle(a, b);
        };
      default:
        final recent = <String, DateTime?>{};
        return (a, b) {
          final aTime = recent.putIfAbsent(a.id, () => _recent(a)?.updatedAt),
              bTime = recent.putIfAbsent(b.id, () => _recent(b)?.updatedAt);
          if (aTime != null && bTime != null) return bTime.compareTo(aTime);
          if (aTime != null) return -1;
          if (bTime != null) return 1;
          return byTitle(a, b);
        };
    }
  }

  /// The lesson whose frame stands for an item in the list.
  VideoLesson? _cover(VideoItem item) {
    VideoLesson? first;
    for (final lesson in _sectionLessons(item)) {
      if (lesson.available && VideoThumbnails.supports(lesson)) return lesson;
      first ??= lesson;
    }
    return first;
  }

  Future<void> _createPlaylist() => _run(() async {
    final title = await askPlaylistTitle(context);
    if (title == null) return;
    final playlist = await widget.repository.createPlaylist(
      title,
      section: mediaFilter,
    );
    await _load();
    if (mounted) await _openPlaylist(playlist);
  });

  Future<void> _openPlaylist(VideoPlaylist playlist) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => VideoPlaylistPage(
          repository: widget.repository,
          playlist: playlist,
          audio: widget.audio,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _setView(String value) async {
    setState(() => view = value);
    await widget.repository.repository.setMeta('media-view', value);
  }

  /// Rows of the media list: items, playlists and section headers.
  List<Object> _rows(
    List<VideoItem> visible,
    List<VideoPlaylist> sectionPlaylists,
  ) {
    if (groupBy == 'folders') {
      final sections = <String, List<VideoItem>>{};
      for (final item in visible) {
        (sections[_folderOf(item)] ??= []).add(item);
      }
      int rank(String name) => name == 'Ссылки' || name == 'Другие' ? 1 : 0;
      int byName(String a, String b) =>
          naturalAudioOrder(a.toLowerCase(), b.toLowerCase());
      // Folders follow the chosen order too: by name, by total length, or
      // by their first item in that order (the newest, the latest watched).
      final itemOrder = _comparator();
      final total = <String, int>{};
      int length(String name) => total.putIfAbsent(
        name,
        () => sections[name]!.fold(
          0,
          (sum, item) =>
              sum +
              _sectionLessons(item)
                  .fold(0, (sum, lesson) => sum + (lesson.durationMs ?? 0)),
        ),
      );
      final names = sections.keys.toList()
        ..sort((a, b) {
          final order = rank(a).compareTo(rank(b));
          if (order != 0) return order;
          final chosen = switch (sortBy) {
            'title' => byName(a, b),
            'title-desc' => byName(b, a),
            'duration' => length(b).compareTo(length(a)),
            _ => itemOrder(sections[a]!.first, sections[b]!.first),
          };
          return chosen != 0 ? chosen : byName(a, b);
        });
      return [
        for (final name in names) ...[
          _SectionHeader(name, sections[name]!.length, Icons.folder_outlined),
          ...sections[name]!,
        ],
      ];
    }
    if (groupBy == 'playlists') {
      final listed = <String>{
        for (final playlist in playlists)
          if (playlist.section == mediaFilter) ...playlist.entries,
      };
      final rest = [
        for (final item in visible)
          if (!_sectionLessons(item).any((l) => listed.contains(l.id))) item,
      ];
      return [
        _SectionHeader(
          'Плейлисты',
          sectionPlaylists.length,
          Icons.playlist_play,
          action: _createPlaylist,
        ),
        ...sectionPlaylists,
        if (rest.isNotEmpty)
          _SectionHeader('Вне плейлистов', rest.length, Icons.inbox_outlined),
        ...rest,
      ];
    }
    return visible;
  }

  String _folderOf(VideoItem item) => videoFolderSection(
    item.folder,
    course: item.kind == VideoItemKind.course,
    root: item.root,
    firstSource: _byItem[item.id]?.firstOrNull?.source,
  );

  void _toggle(VideoItem item) => setState(() {
    if (!selected.remove(item.id)) selected.add(item.id);
  });

  List<VideoItem> _chosen(List<VideoItem> visible) => [
    for (final item in visible)
      if (selected.contains(item.id)) item,
  ];

  bool _watched(VideoItem item) {
    final own = _sectionLessons(item).toList();
    return own.isNotEmpty &&
        own.every(
          (lesson) =>
              learning['${lesson.id}:${lesson.mediaVersion}']
                  ?.manualCompletedAt !=
              null,
        );
  }

  String _what(List<VideoItem> chosen) {
    final music = mediaFilter == 'music';
    if (chosen.length == 1) return '«${chosen.single.title}»';
    final courses = chosen.where((i) => i.kind == VideoItemKind.course).length;
    if (courses == chosen.length) {
      return mediaCount(chosen.length, music: music, courses: true);
    }
    return courses == 0
        ? mediaCount(chosen.length, music: music)
        : '${chosen.length} медиа';
  }

  /// One action for one item (its menu) or for the selection.
  Future<void> _itemAction(String action, List<VideoItem> chosen) async {
    if (chosen.isEmpty) return;
    final files = [for (final item in chosen) ..._sectionLessons(item)];
    final what = _what(chosen);
    switch (action) {
      case 'rename':
        final item = chosen.single;
        final title = await askMediaTitle(
          context,
          title: 'Переименовать',
          initial: item.title,
        );
        if (title == null || !mounted) return;
        await _run(() async {
          await widget.repository.renameItem(item.id, title);
          // A single video's file carries the same name in the player.
          final own = _sectionLessons(item).toList();
          if (item.kind == VideoItemKind.video && own.length == 1) {
            await widget.repository.renameLesson(own.single.id, title);
          }
          await _load();
        });
      case 'details':
        await showMediaDetails(
          context,
          widget.repository,
          title: chosen.length == 1 ? chosen.single.title : what,
          lessons: files,
          progress: progress,
        );
      case 'playlist':
        await addLessonsToPlaylist(context, widget.repository, files);
        if (mounted) setState(selected.clear);
        if (mounted) await _load();
      case 'favorite' || 'unfavorite':
        await _run(() async {
          for (final item in chosen) {
            await widget.repository.setFavorite(item, action == 'favorite');
          }
          selected.clear();
          await _load();
        });
      case 'watched' || 'unwatched':
        await _run(() async {
          final changed = await setLessonsWatched(
            widget.repository,
            files,
            action == 'watched',
          );
          selected.clear();
          await _load();
          if (mounted && changed > 0) {
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                SnackBar(
                  content: Text(
                    action == 'watched'
                        ? 'Отмечено просмотренным: $what'
                        : 'Отметка снята: $what',
                  ),
                ),
              );
          }
        });
      case 'merge':
        final title = await askMediaTitle(
          context,
          title: 'Объединить в курс',
          initial: chosen.first.title,
        );
        if (title == null || !mounted) return;
        await _run(() async {
          await widget.repository.mergeIntoCourse(
            title: title,
            itemIds: [for (final item in chosen) item.id],
          );
          selected.clear();
          await _load();
          if (mounted) {
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                SnackBar(
                  content: Text('Курс «$title»: файлов ${files.length}'),
                ),
              );
          }
        });
      case 'select':
        setState(() => selected.add(chosen.single.id));
      case 'remove':
        if (await removeFromMediaLibrary(
          context,
          widget.repository,
          items: chosen,
          what: what,
        )) {
          selected.clear();
          if (mounted) await _load();
        }
      case 'delete':
        await deleteMediaFiles(
          context,
          widget.repository,
          files,
          what: what,
          deleter: widget.deleter,
        );
        selected.clear();
        if (mounted) await _load();
    }
  }

  List<PopupMenuEntry<String>> _itemMenu(List<VideoItem> chosen) {
    final single = chosen.length == 1;
    final music = mediaFilter == 'music';
    final favorite = chosen.every((item) => item.favorite);
    final watched = chosen.every(_watched);
    return [
      if (single)
        const PopupMenuItem(value: 'rename', child: Text('Переименовать…')),
      const PopupMenuItem(value: 'details', child: Text('Сведения')),
      const PopupMenuItem(value: 'playlist', child: Text('В плейлист…')),
      if (!single)
        PopupMenuItem(
          value: favorite ? 'unfavorite' : 'favorite',
          child: Text(favorite ? 'Убрать из избранного' : 'В избранное'),
        ),
      if (!music)
        PopupMenuItem(
          value: watched ? 'unwatched' : 'watched',
          child: Text(
            watched ? 'Снять отметку «Просмотрено»' : 'Отметить просмотренным',
          ),
        ),
      if (!single && !music)
        const PopupMenuItem(value: 'merge', child: Text('Объединить в курс…')),
      if (single && !selecting)
        const PopupMenuItem(value: 'select', child: Text('Выбрать')),
      const PopupMenuDivider(),
      const PopupMenuItem(value: 'remove', child: Text('Убрать из медиатеки…')),
      const PopupMenuItem(
        value: 'delete',
        child: Text('Удалить с устройства…'),
      ),
    ];
  }

  Widget _itemTile(BuildContext context, VideoItem item) {
    final palette = ShelfPalette.of(context);
    final music = mediaFilter == 'music';
    final own = _sectionLessons(item).toList();
    final cover = _cover(item);
    final recent = _recent(item);
    final course = item.kind == VideoItemKind.course;
    final kind = music
        ? (course ? 'Плейлист · треков: ${own.length}' : 'Музыка')
        : course
        ? 'Курс · ${own.length} уроков'
        : 'Видео';
    final subtitle = [
      kind,
      if (_watched(item)) 'Просмотрено',
      if (recent != null)
        view == 'list'
            ? '\nПоследняя позиция: ${pepeTime(recent.positionMs)}'
            : 'позиция ${pepeTime(recent.positionMs)}',
    ].join(' · ').replaceAll(' · \n', '\n');
    return VideoMediaTile(
      key: ValueKey('media-item:${item.id}'),
      view: view,
      title: item.title,
      subtitle: subtitle,
      cover: cover,
      frame: !music,
      thumbnails: widget.thumbnails,
      icon: music
          ? Icons.music_note_outlined
          : course
          ? Icons.school_outlined
          : Icons.ondemand_video,
      badge: course
          ? '${own.length} ▶'
          : cover?.durationMs == null
          ? null
          : pepeTime(cover!.durationMs!),
      selected: selecting ? selected.contains(item.id) : null,
      onTap: busy
          ? null
          : selecting
          ? () => _toggle(item)
          : () => _open(item),
      onLongPress: busy ? null : () => _toggle(item),
      trailing: selecting
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (view == 'list' || view == 'cards')
                  IconButton(
                    tooltip: item.favorite
                        ? 'Убрать из избранного'
                        : 'В избранное',
                    onPressed: busy
                        ? null
                        : () => _run(() async {
                            await widget.repository.setFavorite(
                              item,
                              !item.favorite,
                            );
                            await _load();
                          }),
                    icon: Icon(item.favorite ? Icons.star : Icons.star_border),
                  )
                else if (item.favorite)
                  Icon(Icons.star, size: 16, color: palette.accent),
                PopupMenuButton<String>(
                  key: ValueKey('media-item-menu:${item.id}'),
                  tooltip: 'Действия',
                  enabled: !busy,
                  padding: EdgeInsets.zero,
                  iconColor: palette.muted,
                  onSelected: (action) => _itemAction(action, [item]),
                  itemBuilder: (_) => _itemMenu([item]),
                ),
              ],
            ),
    );
  }

  Future<void> _open(VideoItem item) => _run(() async {
    final own = _sectionLessons(item).toList();
    if (own.isEmpty) return;
    if (item.kind == VideoItemKind.course &&
        !own.every((lesson) => lesson.isAudio)) {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => VideoCoursePage(
            repository: widget.repository,
            item: item,
            audio: widget.audio,
            thumbnails: widget.thumbnails,
            deleter: widget.deleter,
          ),
        ),
      );
    } else {
      final savedQueue = own.every((lesson) => lesson.isAudio)
          ? await widget.repository.musicQueue(item.id)
          : null;
      final remembered = own.indexWhere(
        (lesson) => lesson.available && lesson.id == savedQueue?['current'],
      );
      final recent = own.indexWhere(
        (lesson) => lesson.available && lesson.id == _recent(item)?.lessonId,
      );
      final first = own.indexWhere((lesson) => lesson.available);
      if (first < 0) {
        throw StateError(
          'Нет доступных источников. Обновите или переподключите папку.',
        );
      }
      if (!mounted) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => VideoPlayerPage(
            repository: widget.repository,
            item: item,
            lessons: own,
            initialIndex: remembered >= 0
                ? remembered
                : recent >= 0
                ? recent
                : first,
            beforePlaying: widget.audio?.pause,
          ),
        ),
      );
    }
    if (mounted) await _load();
  });

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final needle = query.toLowerCase();
    final visible = items.where((item) {
      if (favorites && !item.favorite) return false;
      final own = _sectionLessons(item);
      if (own.isEmpty) return false;
      return query.isEmpty ||
          item.title.toLowerCase().contains(needle) ||
          own.any(
            (lesson) =>
                '${lesson.title} ${lesson.music?.artist ?? ''} ${lesson.music?.album ?? ''}'
                    .toLowerCase()
                    .contains(needle),
          );
    }).toList()..sort(_comparator());
    final sectionPlaylists = [
      for (final playlist in playlists)
        if (playlist.section == mediaFilter &&
            !favorites &&
            (query.isEmpty || playlist.title.toLowerCase().contains(needle)))
          playlist,
    ];
    final rows = _rows(visible, sectionPlaylists);
    final chosen = _chosen(visible);
    return PopScope(
      canPop: !selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && selecting) setState(selected.clear);
      },
      child: ShelfShell(
        title: 'Медиа',
        navigation: widget.navigation,
        actions: [
          IconButton(
            tooltip: 'Словарь Anki',
            icon: const Icon(Icons.style_outlined),
            onPressed: () => Navigator.push<void>(
              context,
              MaterialPageRoute(
                builder: (_) => VocabularyPage(
                  repository: VocabularyRepository(
                    widget.repository.repository,
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: mediaFilter == 'music'
                ? 'Статистика музыки'
                : 'Статистика видео и курсов',
            onPressed: () => Navigator.push<void>(
              context,
              MaterialPageRoute(
                builder: (_) => mediaFilter == 'music'
                    ? MusicStatisticsPage(repository: widget.repository)
                    : VideoStatisticsPage(repository: widget.repository),
              ),
            ),
            icon: const Icon(Icons.bar_chart),
          ),
        ],
        body: Column(
          children: [
            if (selecting)
              VideoSelectionBar(
                count: chosen.length,
                total: visible.length,
                onClose: () => setState(selected.clear),
                onSelectAll: () => setState(() {
                  if (chosen.length == visible.length) {
                    selected.clear();
                  } else {
                    selected.addAll(visible.map((item) => item.id));
                  }
                }),
                actions: [
                  IconButton(
                    tooltip: 'В плейлист',
                    onPressed: busy
                        ? null
                        : () => _itemAction('playlist', chosen),
                    icon: const Icon(Icons.playlist_add),
                  ),
                  PopupMenuButton<String>(
                    key: const ValueKey('selection-menu'),
                    tooltip: 'Ещё',
                    enabled: !busy && chosen.isNotEmpty,
                    onSelected: (action) => _itemAction(action, chosen),
                    itemBuilder: (_) => _itemMenu(chosen),
                  ),
                ],
              ),
            Expanded(
              child: CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    sliver: SliverList.list(
                      children: [
                        TextField(
                          decoration: InputDecoration(
                            prefixIcon: const Icon(Icons.search),
                            hintText: 'Поиск в медиа',
                            suffixIcon: PopupMenuButton<String>(
                              tooltip: 'Добавить медиа',
                              enabled: !busy,
                              icon: const Icon(Icons.add_circle_outline),
                              onSelected: (action) {
                                if (action == 'discover') _discover();
                                if (action == 'files') _pick(false);
                                if (action == 'folder') _pick(true);
                                if (action == 'link') _addLink();
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: 'discover',
                                  child: ListTile(
                                    leading: Icon(Icons.manage_search),
                                    title: Text('Найти видео автоматически'),
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'files',
                                  child: ListTile(
                                    leading: Icon(Icons.library_music_outlined),
                                    title: Text('Добавить файлы'),
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'folder',
                                  child: ListTile(
                                    leading: Icon(Icons.folder_open),
                                    title: Text('Подключить папку'),
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'link',
                                  child: ListTile(
                                    leading: Icon(Icons.link),
                                    title: Text('Добавить ссылку'),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          onChanged: (value) =>
                              setState(() => query = value.trim()),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  children: [
                                    for (final entry in const {
                                      'video': 'Видео и курсы',
                                      'music': 'Музыка',
                                    }.entries)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          right: 8,
                                        ),
                                        child: ChoiceChip(
                                          label: Text(entry.value),
                                          selected: mediaFilter == entry.key,
                                          onSelected: busy
                                              ? null
                                              : (_) => _run(() async {
                                                  await widget
                                                      .repository
                                                      .repository
                                                      .setMeta(
                                                        'media-section',
                                                        entry.key,
                                                      );
                                                  if (mounted) {
                                                    setState(
                                                      () => mediaFilter =
                                                          entry.key,
                                                    );
                                                  }
                                                }),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                            PopupMenuButton<String>(
                              key: const ValueKey('media-sort'),
                              tooltip: 'Сортировка: ${videoSortLabels[sortBy]}',
                              icon: const Icon(Icons.sort),
                              initialValue: sortBy,
                              onSelected: _setSortBy,
                              itemBuilder: (_) => [
                                for (final entry in videoSortLabels.entries)
                                  CheckedPopupMenuItem(
                                    value: entry.key,
                                    checked: entry.key == sortBy,
                                    child: Text(entry.value),
                                  ),
                              ],
                            ),
                            VideoViewButton(view: view, onSelected: _setView),
                            IconButton(
                              tooltip: favorites
                                  ? 'Показать все медиа'
                                  : 'Избранное',
                              isSelected: favorites,
                              selectedIcon: const Icon(Icons.star),
                              icon: const Icon(Icons.star_border),
                              onPressed: () =>
                                  setState(() => favorites = !favorites),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        SegmentedButton<String>(
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(
                              value: 'list',
                              icon: Icon(Icons.view_list_outlined),
                              label: Text('Список'),
                            ),
                            ButtonSegment(
                              value: 'folders',
                              icon: Icon(Icons.folder_outlined),
                              label: Text('Папки'),
                            ),
                            ButtonSegment(
                              value: 'playlists',
                              icon: Icon(Icons.playlist_play),
                              label: Text('Плейлисты'),
                            ),
                          ],
                          selected: {groupBy},
                          onSelectionChanged: (value) =>
                              _setGroupBy(value.single),
                        ),
                        const SizedBox(height: 6),
                        ValueListenableBuilder<bool>(
                          valueListenable: VideoAutoDiscovery.searching,
                          builder: (_, searching, _) => Text(
                            [
                              '${visible.length} в библиотеке',
                              videoSortLabels[sortBy]!.toLowerCase(),
                              if (searching) 'ищу новые видео…',
                            ].join(' · '),
                            style: TextStyle(
                              color: palette.muted,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        if (loading) const LinearProgressIndicator(),
                        if (error != null)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(error!),
                                TextButton(
                                  onPressed: _load,
                                  child: const Text('Повторить'),
                                ),
                              ],
                            ),
                          ),
                        if (!loading && items.isEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 36),
                            child: ShelfPanel(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                children: [
                                  Icon(
                                    Icons.perm_media,
                                    size: 48,
                                    color: palette.accent,
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    'Добавьте видео или музыку',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge,
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 8),
                                  const Text(
                                    'Добавьте файлы, подключите папку с уроками или музыкой либо укажите прямую ссылку. Медиа читаются из исходных файлов.',
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 16),
                                  FilledButton.icon(
                                    onPressed: busy ? null : _discover,
                                    icon: const Icon(Icons.manage_search),
                                    label: const Text(
                                      'Найти видео автоматически',
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (!loading && items.isNotEmpty && rows.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              'По выбранным условиям ничего не найдено.',
                            ),
                          ),
                      ],
                    ),
                  ),
                  ...videoMediaSlivers(
                    rows: rows,
                    view: view,
                    isTile: (row) => row is VideoItem,
                    build: (context, row) {
                      return switch (row) {
                        _SectionHeader() => _header(context, row),
                        VideoPlaylist() => _playlistTile(context, row),
                        _ => _itemTile(context, row as VideoItem),
                      };
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, _SectionHeader row) {
    final palette = ShelfPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 2),
      child: Row(
        children: [
          Icon(row.icon, size: 18, color: palette.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              row.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          Text('${row.count}', style: TextStyle(color: palette.muted)),
          if (row.action != null)
            IconButton(
              tooltip: 'Создать плейлист',
              onPressed: busy ? null : row.action,
              icon: const Icon(Icons.playlist_add),
            ),
        ],
      ),
    );
  }

  Widget _playlistTile(BuildContext context, VideoPlaylist row) {
    final palette = ShelfPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: ShelfPanel(
        child: ListTile(
          key: ValueKey('media-playlist:${row.id}'),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 6,
          ),
          leading: Icon(Icons.playlist_play, color: palette.accent),
          title: Text(row.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text('Плейлист · файлов: ${row.entries.length}'),
          trailing: const Icon(Icons.chevron_right),
          onTap: busy || selecting ? null : () => _openPlaylist(row),
        ),
      ),
    );
  }
}

class _VideoLinkDialog extends StatefulWidget {
  const _VideoLinkDialog();
  @override
  State<_VideoLinkDialog> createState() => _VideoLinkDialogState();
}

class _VideoLinkDialogState extends State<_VideoLinkDialog> {
  final form = GlobalKey<FormState>();
  final title = TextEditingController(), url = TextEditingController();
  bool audio = false;
  @override
  void dispose() {
    title.dispose();
    url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Добавить ссылку на медиа'),
    content: SizedBox(
      width: 480,
      child: Form(
        key: form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Музыка / аудио'),
                subtitle: const Text(
                  'Включите для аудиоссылок без расширения файла',
                ),
                value: audio,
                onChanged: (value) => setState(() => audio = value),
              ),
              TextFormField(
                controller: title,
                autofocus: true,
                maxLength: 300,
                decoration: const InputDecoration(labelText: 'Название'),
                validator: (value) =>
                    value?.trim().isEmpty != false ? 'Введите название' : null,
              ),
              TextFormField(
                controller: url,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Прямая HTTP(S)-ссылка',
                  hintText: 'https://…/track.mp3 или lesson.mp4',
                ),
                validator: (value) {
                  try {
                    validateVideoUrl(value ?? '');
                    return null;
                  } catch (_) {
                    return 'Нужна прямая HTTP(S)-ссылка';
                  }
                },
              ),
            ],
          ),
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
          if (form.currentState!.validate()) {
            Navigator.pop(
              context,
              VideoSourceDraft(
                validateVideoUrl(url.text),
                title.text.trim(),
                audio: audio,
              ),
            );
          }
        },
        child: const Text('Добавить'),
      ),
    ],
  );
}

class _VideoImportDialog extends StatefulWidget {
  final VideoImportSelection selection;
  const _VideoImportDialog({required this.selection});
  @override
  State<_VideoImportDialog> createState() => _VideoImportDialogState();
}

class _VideoImportDialogState extends State<_VideoImportDialog> {
  late final title = TextEditingController(text: widget.selection.title);
  late final sources = [...widget.selection.sources];
  String? error;
  @override
  void dispose() {
    title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      sources.every((source) => source.isAudio)
          ? 'Проверить музыку и порядок треков'
          : 'Проверить медиа и порядок файлов',
    ),
    content: SizedBox(
      width: 600,
      height: 400,
      child: Column(
        children: [
          TextField(
            controller: title,
            maxLength: 300,
            decoration: InputDecoration(
              labelText: sources.every((source) => source.isAudio)
                  ? (sources.length > 1 || widget.selection.root != null
                        ? 'Название плейлиста'
                        : 'Название трека')
                  : (sources.length > 1 || widget.selection.root != null
                        ? 'Название курса / подборки'
                        : 'Название видео'),
              errorText: error,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ReorderableListView.builder(
              itemCount: sources.length,
              onReorderItem: (oldIndex, newIndex) => setState(() {
                sources.insert(newIndex, sources.removeAt(oldIndex));
              }),
              itemBuilder: (_, i) => ListTile(
                key: ValueKey(sources[i].source),
                leading: Text('${i + 1}'),
                title: Text(sources[i].title),
                subtitle: sources[i].module.isEmpty
                    ? null
                    : Text(sources[i].module),
              ),
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () {
          if (title.text.trim().isEmpty) {
            setState(() => error = 'Введите название');
            return;
          }
          Navigator.pop(
            context,
            VideoImportSelection(
              title.text.trim(),
              sources,
              root: widget.selection.root,
            ),
          );
        },
        child: const Text('Подключить'),
      ),
    ],
  );
}

class _SectionHeader {
  final String title;
  final int count;
  final IconData icon;
  final VoidCallback? action;
  const _SectionHeader(this.title, this.count, this.icon, {this.action});
}
