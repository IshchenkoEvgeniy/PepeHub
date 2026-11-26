import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../media/audio_controller.dart';
import '../ui/pepe_widgets.dart';
import '../ui/audio_mini_player.dart';
import '../ui/shelf_components.dart';
import 'models.dart';
import 'video_import.dart';
import 'video_player_page.dart';
import 'video_repository.dart';
import 'video_statistics_page.dart';
import 'video_activity.dart';
import 'video_progress_widgets.dart';
import 'video_course_editor.dart';
import 'video_folder_sync.dart';
import 'video_folder_dialog.dart';
import 'video_session.dart';
import 'video_discovery.dart' show videoFolderSection;
import 'video_discovery_page.dart';
import 'video_discovery_scan.dart';
import 'video_playlists.dart';
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
  const VideoLibraryPage({
    super.key,
    required this.repository,
    required this.navigation,
    this.audio,
    this.chooseFiles = pickVideoFiles,
    this.discoveryScanner = const PlatformVideoDiscoveryScanner(),
  });
  @override
  State<VideoLibraryPage> createState() => _VideoLibraryPageState();
}

class _VideoLibraryPageState extends State<VideoLibraryPage> {
  List<VideoItem> items = [];
  List<VideoLesson> lessons = [];
  Map<String, VideoProgress> progress = {};
  List<VideoPlaylist> playlists = [];
  bool loading = true, busy = false, favorites = false;
  String query = '', mediaFilter = 'video';

  /// `list`, `folders` or `playlists`.
  String groupBy = 'list';
  Map<String, List<VideoLesson>> _byItem = {};
  bool _filterLoaded = false;
  String? error;
  int _request = 0;
  @override
  void initState() {
    super.initState();
    widget.repository.repository.externalChanges.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.repository.repository.externalChanges.removeListener(_load);
    super.dispose();
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
        _filterLoaded = true;
      }
      final nextItems = await widget.repository.items();
      final nextLessons = await widget.repository.lessons();
      final nextProgress = await widget.repository.allProgress();
      final nextPlaylists = await widget.repository.playlists();
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

  Future<void> _addToPlaylist(VideoItem item) async {
    await addLessonsToPlaylist(
      context,
      widget.repository,
      _sectionLessons(item).toList(),
    );
    if (mounted) await _load();
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
      final names = sections.keys.toList()
        ..sort((a, b) {
          final order = rank(a).compareTo(rank(b));
          return order != 0
              ? order
              : a.toLowerCase().compareTo(b.toLowerCase());
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

  Future<void> _remove(VideoItem item) async {
    final what = item.kind == VideoItemKind.course
        ? (mediaFilter == 'music' ? 'плейлист' : 'курс')
        : (mediaFilter == 'music' ? 'трек' : 'видео');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text('Удалить «${item.title}» из медиатеки?'),
        content: Text(
          'Файлы на диске останутся на месте — PepeHub просто перестанет '
          'показывать этот $what. Чтобы вернуть его позже, добавьте файлы '
          'или папку снова.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить из медиатеки'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    List<String>? lessonIds;
    await _run(() async {
      lessonIds = await widget.repository.removeItem(item.id);
      await _load();
    });
    final removed = lessonIds;
    if (removed == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        // Flutter keeps snack bars with an action until dismissed.
        persist: false,
        content: Text('«${item.title}» удалён из медиатеки'),
        action: SnackBarAction(
          label: 'Вернуть',
          onPressed: () => _run(() async {
            await widget.repository.restoreItem(item.id, removed);
            await _load();
          }),
        ),
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
          builder: (_) => _VideoCoursePage(
            repository: widget.repository,
            item: item,
            audio: widget.audio,
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
    final recent = <String, DateTime?>{};
    final visible =
        items.where((item) {
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
        }).toList()..sort((a, b) {
          final aTime = recent.putIfAbsent(a.id, () => _recent(a)?.updatedAt),
              bTime = recent.putIfAbsent(b.id, () => _recent(b)?.updatedAt);
          if (aTime != null && bTime != null) return bTime.compareTo(aTime);
          if (aTime != null) return -1;
          if (bTime != null) return 1;
          return a.title.compareTo(b.title);
        });
    final sectionPlaylists = [
      for (final playlist in playlists)
        if (playlist.section == mediaFilter &&
            !favorites &&
            (query.isEmpty || playlist.title.toLowerCase().contains(needle)))
          playlist,
    ];
    final rows = _rows(visible, sectionPlaylists);
    return ShelfShell(
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
                repository: VocabularyRepository(widget.repository.repository),
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
      body: CustomScrollView(
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
                  onChanged: (value) => setState(() => query = value.trim()),
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
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  label: Text(entry.value),
                                  selected: mediaFilter == entry.key,
                                  onSelected: busy
                                      ? null
                                      : (_) => _run(() async {
                                          await widget.repository.repository
                                              .setMeta(
                                                'media-section',
                                                entry.key,
                                              );
                                          if (mounted) {
                                            setState(
                                              () => mediaFilter = entry.key,
                                            );
                                          }
                                        }),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: favorites ? 'Показать все медиа' : 'Избранное',
                      isSelected: favorites,
                      selectedIcon: const Icon(Icons.star),
                      icon: const Icon(Icons.star_border),
                      onPressed: () => setState(() => favorites = !favorites),
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
                  onSelectionChanged: (value) => _setGroupBy(value.single),
                ),
                const SizedBox(height: 6),
                Text(
                  '${visible.length} в библиотеке',
                  style: TextStyle(color: palette.muted, fontSize: 12),
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
                            style: Theme.of(context).textTheme.titleLarge,
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
                            label: const Text('Найти видео автоматически'),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (!loading && items.isNotEmpty && rows.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('По выбранным условиям ничего не найдено.'),
                  ),
              ],
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            sliver: SliverList.builder(
              itemCount: rows.length,
              itemBuilder: (_, index) {
                final row = rows[index];
                if (row is _SectionHeader) {
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
                        Text(
                          '${row.count}',
                          style: TextStyle(color: palette.muted),
                        ),
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
                if (row is VideoPlaylist) {
                  final own = row.entries.length;
                  return Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: ShelfPanel(
                      child: ListTile(
                        key: ValueKey('media-playlist:${row.id}'),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 6,
                        ),
                        leading: Icon(
                          Icons.playlist_play,
                          color: palette.accent,
                        ),
                        title: Text(
                          row.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text('Плейлист · файлов: $own'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: busy ? null : () => _openPlaylist(row),
                      ),
                    ),
                  );
                }
                final item = row as VideoItem;
                return Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: ShelfPanel(
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      leading: Icon(
                        mediaFilter == 'music'
                            ? Icons.music_note_outlined
                            : item.kind == VideoItemKind.course
                            ? Icons.school_outlined
                            : Icons.ondemand_video,
                        color: palette.accent,
                      ),
                      title: Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        [
                          mediaFilter == 'music'
                              ? (item.kind == VideoItemKind.course
                                    ? 'Плейлист · треков: ${_sectionLessons(item).length}'
                                    : 'Музыка')
                              : item.kind == VideoItemKind.course
                              ? 'Курс · ${_sectionLessons(item).length} уроков'
                              : 'Видео',
                          if (_recent(item) != null)
                            'Последняя позиция: ${pepeTime(_recent(item)!.positionMs)}',
                        ].join('\n'),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
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
                            icon: Icon(
                              item.favorite ? Icons.star : Icons.star_border,
                            ),
                          ),
                          PopupMenuButton<String>(
                            key: ValueKey('media-item-menu:${item.id}'),
                            tooltip: 'Действия',
                            enabled: !busy,
                            onSelected: (action) {
                              if (action == 'playlist') _addToPlaylist(item);
                              if (action == 'remove') _remove(item);
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                value: 'playlist',
                                child: Text('Добавить в плейлист…'),
                              ),
                              PopupMenuItem(
                                value: 'remove',
                                child: Text('Удалить из медиатеки…'),
                              ),
                            ],
                          ),
                        ],
                      ),
                      onTap: busy ? null : () => _open(item),
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

class _VideoCoursePage extends StatefulWidget {
  final VideoRepository repository;
  final VideoItem item;
  final AudioController? audio;
  const _VideoCoursePage({
    required this.repository,
    required this.item,
    this.audio,
  });
  @override
  State<_VideoCoursePage> createState() => _VideoCoursePageState();
}

class _VideoCoursePageState extends State<_VideoCoursePage> {
  late VideoItem currentItem = widget.item;
  List<VideoLesson> lessons = [];
  Map<String, VideoProgress> progress = {};
  String? error;
  bool loading = true;
  bool opening = false;
  VideoStats? stats;
  VideoPreferences preferences = const VideoPreferences();
  Map<String, VideoLearningState> learning = {};
  int _request = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final request = ++_request;
    try {
      currentItem = (await widget.repository.items()).firstWhere(
        (item) => item.id == widget.item.id,
      );
      final next = (await widget.repository.lessons(itemId: widget.item.id))
          .where((lesson) => !lesson.isAudio)
          .toList();
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
          progress = positions;
          stats = coverage;
          preferences = settings;
          learning = states;
          loading = false;
          error = null;
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
    if (state?.manualCompletedAt != null) return 'Завершён вручную';
    if (stats != null &&
        lesson.durationMs != null &&
        lesson.durationMs! > 0 &&
        stats!.lessonCoverage(lesson) * 100 >=
            lesson.durationMs! * preferences.completionPercent) {
      return 'Покрытие ≥ ${preferences.completionPercent}%';
    }
    return null;
  }

  Future<void> _play(int index) async {
    if (opening || !currentItem.connected || !lessons[index].available) return;
    setState(() => opening = true);
    try {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => VideoPlayerPage(
            repository: widget.repository,
            item: currentItem,
            lessons: lessons,
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
    final state = learning['${lesson.id}:${lesson.mediaVersion}'];
    if (state?.manualCompletedAt != null) return true;
    final saved = progress[lesson.id];
    final duration = lesson.durationMs;
    return saved != null &&
        saved.mediaVersion == lesson.mediaVersion &&
        duration != null &&
        duration > 20000 &&
        saved.positionMs >= duration - 10000;
  }

  Future<void> _folderAction(String action) async {
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

  @override
  Widget build(BuildContext context) => Scaffold(
    bottomNavigationBar: const AudioPlayerFooter(),
    appBar: AppBar(
      title: Text(currentItem.title),
      actions: [
        if (currentItem.root != null)
          PopupMenuButton<String>(
            tooltip: 'Папка курса',
            enabled: !loading && !opening,
            onSelected: _folderAction,
            itemBuilder: (_) => [
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
          ),
        IconButton(
          tooltip: 'Редактировать структуру курса',
          onPressed: loading || opening
              ? null
              : () async {
                  await Navigator.push<bool>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => VideoCourseEditor(
                        repository: widget.repository,
                        item: currentItem,
                        lessons: lessons,
                      ),
                    ),
                  );
                  if (mounted) await _load();
                },
          icon: const Icon(Icons.edit_note),
        ),
        IconButton(
          tooltip: 'Статистика курса',
          onPressed: _statistics,
          icon: const Icon(Icons.bar_chart),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
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
                      !currentItem.connected ||
                      !lessons[_recentIndex].available
                  ? null
                  : () => _play(_recentIndex),
              icon: const Icon(Icons.play_arrow),
              label: const Text('Продолжить курс'),
            ),
          ),
        const SizedBox(height: 16),
        for (var i = 0; i < lessons.length; i++) ...[
          if (lessons[i].module.isNotEmpty &&
              (i == 0 || lessons[i].module != lessons[i - 1].module))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                lessons[i].module,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ListTile(
            leading: Text('${i + 1}'),
            title: Text(lessons[i].title),
            subtitle: Text(
              [
                if (lessons[i].durationMs != null)
                  pepeTime(lessons[i].durationMs!),
                if (stats != null &&
                    lessons[i].durationMs != null &&
                    lessons[i].durationMs! > 0)
                  'Просмотрено: ${(stats!.lessonCoverage(lessons[i]) * 100 / lessons[i].durationMs!).toStringAsFixed(1)}%',
                if (_completionLabel(lessons[i]) != null)
                  _completionLabel(lessons[i])!,
                if (learning['${lessons[i].id}:${lessons[i].mediaVersion}']
                        ?.understoodAt !=
                    null)
                  'Разобрался',
                if (progress[lessons[i].id]?.mediaVersion ==
                    lessons[i].mediaVersion)
                  'Позиция: ${pepeTime(progress[lessons[i].id]!.positionMs)}',
                lessons[i].isRemote ? 'По ссылке' : 'Локальный файл',
                if (!lessons[i].available) 'Файл недоступен',
              ].join(' · '),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Добавить урок в плейлист',
                  onPressed: () => addLessonsToPlaylist(
                    context,
                    widget.repository,
                    [lessons[i]],
                  ),
                  icon: const Icon(Icons.playlist_add),
                ),
                const Icon(Icons.play_circle_outline),
              ],
            ),
            onTap: opening || !currentItem.connected || !lessons[i].available
                ? null
                : () => _play(i),
          ),
        ],
      ],
    ),
  );
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
