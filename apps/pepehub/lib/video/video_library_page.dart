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
import '../vocabulary/vocabulary_page.dart';
import '../vocabulary/vocabulary_repository.dart';

class VideoLibraryPage extends StatefulWidget {
  final VideoRepository repository;
  final ShelfNavigation navigation;
  final AudioController? audio;
  final VideoFilePicker chooseFiles;
  const VideoLibraryPage({
    super.key,
    required this.repository,
    required this.navigation,
    this.audio,
    this.chooseFiles = pickVideoFiles,
  });
  @override
  State<VideoLibraryPage> createState() => _VideoLibraryPageState();
}

class _VideoLibraryPageState extends State<VideoLibraryPage> {
  List<VideoItem> items = [];
  List<VideoLesson> lessons = [];
  Map<String, VideoProgress> progress = {};
  bool loading = true, busy = false, favorites = false;
  String query = '';
  String? error;
  int _request = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final request = ++_request;
    try {
      final nextItems = await widget.repository.items();
      final nextLessons = await widget.repository.lessons();
      final nextProgress = await widget.repository.allProgress();
      if (!mounted || request != _request) return;
      setState(() {
        items = nextItems;
        lessons = nextLessons;
        progress = nextProgress;
        loading = false;
        error = null;
      });
    } catch (e) {
      if (mounted && request == _request) {
        setState(() {
          loading = false;
          error = 'Не удалось открыть видеобиблиотеку: $e';
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
            .showSnackBar(SnackBar(content: Text('$e')));
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
      throw StateError('В выбранной папке нет поддерживаемых видео');
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
    await _load();
  });

  Future<void> _addLink() => _run(() async {
    final draft = await showDialog<VideoSourceDraft>(
      context: context,
      builder: (_) => const _VideoLinkDialog(),
    );
    if (draft == null) return;
    await widget.repository.addSources(title: draft.title, sources: [draft]);
    await _load();
  });

  VideoProgress? _recent(VideoItem item) {
    VideoProgress? recent;
    for (final lesson in lessons.where((l) => l.itemId == item.id)) {
      final saved = progress[lesson.id];
      if (saved != null &&
          saved.mediaVersion == lesson.mediaVersion &&
          (recent == null || saved.updatedAt.isAfter(recent.updatedAt))) {
        recent = saved;
      }
    }
    return recent;
  }

  Future<void> _open(VideoItem item) => _run(() async {
    final own = lessons.where((l) => l.itemId == item.id).toList();
    if (own.isEmpty) return;
    if (item.kind == VideoItemKind.course) {
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
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => VideoPlayerPage(
            repository: widget.repository,
            item: item,
            lessons: own,
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
    final visible =
        items
            .where(
              (item) =>
                  (!favorites || item.favorite) &&
                  (query.isEmpty ||
                      item.title.toLowerCase().contains(query.toLowerCase()) ||
                      lessons.any(
                        (lesson) =>
                            lesson.itemId == item.id &&
                            lesson.title.toLowerCase().contains(
                              query.toLowerCase(),
                            ),
                      )),
            )
            .toList()
          ..sort((a, b) {
            final aTime = _recent(a)?.updatedAt, bTime = _recent(b)?.updatedAt;
            if (aTime != null && bTime != null) return bTime.compareTo(aTime);
            if (aTime != null) return -1;
            if (bTime != null) return 1;
            return a.title.compareTo(b.title);
          });
    return ShelfShell(
      title: 'Видео',
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
          tooltip: 'Статистика видео',
          onPressed: () => Navigator.push<void>(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  VideoStatisticsPage(repository: widget.repository),
            ),
          ),
          icon: const Icon(Icons.bar_chart),
        ),
      ],
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const ShelfIntro(
            title: 'Видео',
            subtitle: 'Свои видео и курсы. Позиция сохраняется, просмотренные участки учитываются отдельно от перемоток.',
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: busy ? null : () => _pick(false),
                icon: const Icon(Icons.video_file_outlined),
                label: const Text('Добавить файлы'),
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : () => _pick(true),
                icon: const Icon(Icons.folder_open),
                label: const Text('Подключить папку'),
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : _addLink,
                icon: const Icon(Icons.link),
                label: const Text('Добавить ссылку'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Поиск видео и уроков',
            ),
            onChanged: (value) => setState(() => query = value.trim()),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: [
              FilterChip(
                label: const Text('Избранное'),
                selected: favorites,
                onSelected: (value) => setState(() => favorites = value),
              ),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Text(
                  '${visible.length} в библиотеке',
                  style: TextStyle(color: palette.muted),
                ),
              ),
            ],
          ),
          if (loading) const LinearProgressIndicator(),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(error!),
                  TextButton(onPressed: _load, child: const Text('Повторить')),
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
                    Icon(Icons.ondemand_video, size: 48, color: palette.accent),
                    const SizedBox(height: 16),
                    Text(
                      'Начните с видео или курса',
                      style: Theme.of(context).textTheme.titleLarge,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Подключите папку с уроками или добавьте прямую ссылку. Локальные видео читаются из исходных файлов.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          if (!loading && items.isNotEmpty && visible.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('По выбранным условиям ничего не найдено.'),
            ),
          for (final item in visible) ...[
            const SizedBox(height: 10),
            ShelfPanel(
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                leading: Icon(
                  item.kind == VideoItemKind.course
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
                    item.kind == VideoItemKind.course
                        ? 'Курс · ${lessons.where((l) => l.itemId == item.id).length} уроков'
                        : 'Видео',
                    if (_recent(item) != null)
                      'Последняя позиция: ${pepeTime(_recent(item)!.positionMs)}',
                  ].join('\n'),
                ),
                trailing: IconButton(
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
                ),
                onTap: busy ? null : () => _open(item),
              ),
            ),
          ],
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
      final next = await widget.repository.lessons(itemId: widget.item.id);
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
          error = '$e';
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
    return result;
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
      if (mounted) setState(() => error = '$e');
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
            trailing: const Icon(Icons.play_circle_outline),
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
  @override
  void dispose() {
    title.dispose();
    url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Добавить ссылку на видео'),
    content: SizedBox(
      width: 480,
      child: Form(
        key: form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
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
                  hintText: 'https://…/lesson.mp4',
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
              VideoSourceDraft(validateVideoUrl(url.text), title.text.trim()),
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
    title: const Text('Проверить видео и порядок уроков'),
    content: SizedBox(
      width: 600,
      height: 400,
      child: Column(
        children: [
          TextField(
            controller: title,
            maxLength: 300,
            decoration: InputDecoration(
              labelText: sources.length > 1 || widget.selection.root != null
                  ? 'Название курса'
                  : 'Название видео',
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
