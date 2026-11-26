import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../diagnostics/user_message.dart';
import '../ui/pepe_widgets.dart';
import 'video_discovery.dart';
import 'video_discovery_scan.dart';
import 'video_repository.dart';

String videoBytes(int bytes) {
  if (bytes <= 0) return '';
  const units = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = value >= 10 || unit == 0
      ? value.round().toString()
      : value.toStringAsFixed(1).replaceAll('.', ',');
  return '$text ${units[unit]}';
}

IconData videoGroupIcon(VideoGroupKind kind) => switch (kind) {
  VideoGroupKind.existing => Icons.playlist_add,
  VideoGroupKind.series => Icons.live_tv_outlined,
  VideoGroupKind.course => Icons.school_outlined,
  VideoGroupKind.movie => Icons.movie_outlined,
  VideoGroupKind.collection => Icons.video_library_outlined,
  VideoGroupKind.folder => Icons.folder_outlined,
  VideoGroupKind.camera => Icons.photo_camera_outlined,
  VideoGroupKind.messenger => Icons.forum_outlined,
  VideoGroupKind.screen => Icons.screenshot_monitor_outlined,
  VideoGroupKind.clips => Icons.timelapse,
  VideoGroupKind.duplicates => Icons.content_copy_outlined,
};

/// Finds videos in chosen folders (and on Android in the device's media
/// index), proposes groups and adds only what the user confirms.
class VideoDiscoveryPage extends StatefulWidget {
  final VideoRepository repository;
  final VideoDiscoveryScanner scanner;
  const VideoDiscoveryPage({
    super.key,
    required this.repository,
    this.scanner = const PlatformVideoDiscoveryScanner(),
  });
  @override
  State<VideoDiscoveryPage> createState() => _VideoDiscoveryPageState();
}

class _VideoDiscoveryPageState extends State<VideoDiscoveryPage> {
  VideoDiscoverySettings settings = const VideoDiscoverySettings();
  bool loading = true, scanning = false, grouping = false, adding = false;
  bool showHidden = false, changed = false;
  int found = 0, known = 0;
  String? error;
  List<String> scanErrors = [];
  List<VideoCandidate>? candidates;
  VideoGrouping mode = VideoGrouping.smart;
  List<VideoGroupProposal> groups = [];
  final selected = <String>{};
  final excluded = <String>{};

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    try {
      final value = await widget.repository.discoverySettings();
      if (mounted) {
        setState(() {
          settings = value;
          loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = describeError(e);
        });
      }
    }
  }

  Future<void> _saveSettings(VideoDiscoverySettings value) async {
    setState(() => settings = value);
    try {
      await widget.repository.saveDiscoverySettings(value);
    } catch (e) {
      if (mounted) setState(() => error = describeError(e));
    }
  }

  VideoDiscoverySettings _with({
    List<({String root, String title})>? roots,
    bool? device,
    Set<String>? ignored,
  }) => VideoDiscoverySettings(
    roots: roots ?? settings.roots,
    device: device ?? settings.device,
    ignored: ignored ?? settings.ignored,
  );

  Future<void> _addRoot() async {
    try {
      final root = await widget.scanner.pickRoot();
      if (root == null || !mounted) return;
      if (settings.roots.any((value) => value.root == root.root)) return;
      await _saveSettings(_with(roots: [...settings.roots, root]));
    } catch (e) {
      if (mounted) setState(() => error = describeError(e));
    }
  }

  Future<void> _scan() async {
    if (scanning) return;
    if (settings.roots.isEmpty && !settings.device) {
      setState(
        () => error = widget.scanner.supportsDevice
            ? 'Добавьте папку или включите поиск по всему устройству'
            : 'Добавьте папку для поиска',
      );
      return;
    }
    setState(() {
      scanning = true;
      found = 0;
      error = null;
      scanErrors = [];
    });
    try {
      final result = await widget.scanner.scan(
        roots: settings.roots,
        device: widget.scanner.supportsDevice && settings.device,
        onProgress: (count) {
          if (mounted) setState(() => found = count);
        },
      );
      if (!mounted) return;
      candidates = result.files;
      scanErrors = result.errors;
      found = result.files.length;
      await _regroup(resetSelection: true);
    } on VideoDiscoveryCancelled {
      // The previous results, if any, stay on screen.
    } catch (e) {
      if (mounted) setState(() => error = describeError(e));
    } finally {
      if (mounted) setState(() => scanning = false);
    }
  }

  Future<void> _regroup({bool resetSelection = false}) async {
    final files = candidates;
    if (files == null) return;
    setState(() => grouping = true);
    try {
      final library = await widget.repository.knownMedia();
      final items = await widget.repository.items();
      final request = VideoDiscoveryRequest(
        files,
        grouping: mode,
        knownSources: library.sources,
        knownFileKeys: library.fileKeys,
        existingKeys: {
          for (final item in items)
            if (item.discoveryKey != null) item.discoveryKey!: item.id,
        },
        existingTitles: {for (final item in items) item.id: item.title},
      );
      // Small results group at once; large ones off the UI thread.
      final result = files.length < 400
          ? groupVideoCandidates(request)
          : await compute(groupVideoCandidates, request);
      if (!mounted) return;
      setState(() {
        groups = result.groups;
        known = result.known;
        final keys = {for (final group in groups) group.key};
        if (resetSelection) {
          selected
            ..clear()
            ..addAll([
              for (final group in groups)
                if (group.kind.selectedByDefault &&
                    !settings.ignored.contains(group.key))
                  group.key,
            ]);
          excluded.clear();
        } else {
          selected.retainAll(keys);
          for (final group in groups) {
            if (group.kind.selectedByDefault &&
                !settings.ignored.contains(group.key)) {
              selected.add(group.key);
            }
          }
        }
      });
    } catch (e) {
      if (mounted) setState(() => error = describeError(e));
    } finally {
      if (mounted) setState(() => grouping = false);
    }
  }

  List<VideoDiscoveredFile> _files(VideoGroupProposal group) => [
    for (final file in group.files)
      if (!excluded.contains(file.candidate.source)) file,
  ];

  Iterable<VideoGroupProposal> get _visible => groups.where(
    (group) => showHidden || !settings.ignored.contains(group.key),
  );

  int get _selectedFiles => _visible
      .where((group) => selected.contains(group.key))
      .fold(0, (sum, group) => sum + _files(group).length);

  Future<void> _add() async {
    if (adding) return;
    final chosen = [
      for (final group in _visible)
        if (selected.contains(group.key) && _files(group).isNotEmpty) group,
    ];
    if (chosen.isEmpty) return;
    setState(() {
      adding = true;
      error = null;
    });
    final done = <String>{};
    try {
      for (final group in chosen) {
        final files = _files(group);
        await widget.repository.addSources(
          title: group.title,
          sources: [for (final file in files) file.toDraft()],
          itemId: group.targetItemId,
          folder: group.folder.isEmpty ? null : group.folder,
          discoveryKey: group.key,
          single: group.single && files.length == 1,
        );
        done.add(group.key);
        changed = true;
      }
    } catch (e) {
      if (mounted) setState(() => error = describeError(e));
    } finally {
      if (mounted) {
        setState(() {
          adding = false;
          groups = [
            for (final group in groups)
              if (!done.contains(group.key)) group,
          ];
          selected.removeAll(done);
        });
        if (done.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Добавлено в медиатеку: ${done.length}')),
          );
        }
      }
    }
  }

  void _replace(VideoGroupProposal group, VideoGroupProposal next) =>
      setState(() {
        groups = [for (final value in groups) value == group ? next : value];
      });

  Future<void> _rename(VideoGroupProposal group) async {
    final controller = TextEditingController(text: group.title);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Название'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 300,
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    controller.dispose();
    final clean = title?.trim() ?? '';
    if (clean.isEmpty || clean.length > 300 || !mounted) return;
    _replace(group, group.copyWith(title: clean));
  }

  Future<void> _merge(VideoGroupProposal source) async {
    final targets = [
      for (final group in _visible)
        if (group != source && group.kind != VideoGroupKind.duplicates) group,
    ];
    final target = await showDialog<VideoGroupProposal>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Объединить «${source.title}» с…'),
        children: [
          for (final group in targets)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, group),
              child: ListTile(
                leading: Icon(videoGroupIcon(group.kind)),
                title: Text(group.title),
                subtitle: Text('${group.kind.label} · ${group.files.length}'),
              ),
            ),
        ],
      ),
    );
    if (target == null || !mounted) return;
    setState(() {
      final merged = target.copyWith(
        files: [
          ...target.files,
          // The added files keep their group as a module of the target.
          for (final file in source.files)
            VideoDiscoveredFile(
              file.candidate,
              file.title,
              file.module.isEmpty ? source.title : file.module,
            ),
        ],
      );
      groups = [
        for (final group in groups)
          if (group == target) merged else if (group != source) group,
      ];
      selected.remove(source.key);
      selected.add(target.key);
    });
  }

  Future<void> _toggleHidden(VideoGroupProposal group) async {
    final ignored = {...settings.ignored};
    if (!ignored.remove(group.key)) {
      ignored.add(group.key);
      selected.remove(group.key);
    }
    await _saveSettings(_with(ignored: ignored));
  }

  Future<void> _showFiles(VideoGroupProposal group) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.75,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  group.title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (group.folder.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(group.folder),
                ),
              Expanded(
                child: ListView.builder(
                  itemCount: group.files.length,
                  itemBuilder: (_, i) {
                    final file = group.files[i];
                    final source = file.candidate.source;
                    return CheckboxListTile(
                      value: !excluded.contains(source),
                      onChanged: (value) {
                        setState(() {
                          if (value == true) {
                            excluded.remove(source);
                          } else {
                            excluded.add(source);
                          }
                        });
                        update(() {});
                      },
                      title: Text(file.title),
                      subtitle: Text(
                        [
                          if (file.module.isNotEmpty) file.module,
                          if (file.candidate.durationMs != null &&
                              file.candidate.durationMs! > 0)
                            pepeTime(file.candidate.durationMs!),
                          videoBytes(file.candidate.size),
                        ].where((part) => part.isNotEmpty).join(' · '),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _roots(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('Где искать', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      if (widget.scanner.supportsDevice)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Всё устройство'),
          subtitle: const Text(
            'Видео из медиатеки Android: загрузки, камера, мессенджеры. '
            'Попросит доступ к видео.',
          ),
          value: settings.device,
          onChanged: scanning
              ? null
              : (value) => _saveSettings(_with(device: value)),
        ),
      for (final root in settings.roots)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.folder_outlined),
          title: Text(root.title),
          trailing: IconButton(
            tooltip: 'Убрать папку из поиска',
            onPressed: scanning
                ? null
                : () => _saveSettings(
                    _with(
                      roots: [
                        for (final value in settings.roots)
                          if (value.root != root.root) value,
                      ],
                    ),
                  ),
            icon: const Icon(Icons.close),
          ),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: scanning ? null : _addRoot,
          icon: const Icon(Icons.create_new_folder_outlined),
          label: const Text('Добавить папку'),
        ),
      ),
      if (widget.scanner.supportsDevice)
        Text(
          'Папки находят и скрытые от медиатеки видео (с файлом .nomedia). '
          'Android не даёт выбрать корень памяти и «Загрузки» — для них '
          'включите «Всё устройство».',
          style: Theme.of(context).textTheme.bodySmall,
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final visible = _visible.toList();
    final hidden = groups.length - visible.length;
    final hiddenCount = groups
        .where((group) => settings.ignored.contains(group.key))
        .length;
    return PopScope(
      canPop: !adding,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && scanning) widget.scanner.cancel();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(
            onPressed: adding ? null : () => Navigator.pop(context, changed),
          ),
          title: const Text('Поиск видео'),
        ),
        bottomNavigationBar: candidates == null
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: FilledButton.icon(
                    onPressed: adding || scanning || _selectedFiles == 0
                        ? null
                        : _add,
                    icon: adding
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.library_add),
                    label: Text(
                      'Добавить выбранное · групп: ${visible.where((g) => selected.contains(g.key)).length}, файлов: $_selectedFiles',
                    ),
                  ),
                ),
              ),
        body: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              sliver: SliverList.list(
                children: [
                  if (loading) const LinearProgressIndicator(),
                  _roots(context),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: loading || scanning ? null : _scan,
                          icon: const Icon(Icons.manage_search),
                          label: Text(
                            candidates == null ? 'Найти видео' : 'Искать снова',
                          ),
                        ),
                      ),
                      if (scanning) ...[
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: widget.scanner.cancel,
                          child: const Text('Отменить'),
                        ),
                      ],
                    ],
                  ),
                  if (scanning) ...[
                    const SizedBox(height: 8),
                    const LinearProgressIndicator(),
                    Text('Найдено видео: $found'),
                  ],
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  for (final message in scanErrors)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('Не прочитано: $message'),
                    ),
                  if (candidates != null) ...[
                    const SizedBox(height: 16),
                    SegmentedButton<VideoGrouping>(
                      segments: const [
                        ButtonSegment(
                          value: VideoGrouping.smart,
                          icon: Icon(Icons.auto_awesome_outlined),
                          label: Text('Умная'),
                        ),
                        ButtonSegment(
                          value: VideoGrouping.folders,
                          icon: Icon(Icons.folder_outlined),
                          label: Text('По папкам'),
                        ),
                      ],
                      selected: {mode},
                      onSelectionChanged: grouping || adding
                          ? null
                          : (value) {
                              setState(() => mode = value.single);
                              _regroup();
                            },
                    ),
                    const SizedBox(height: 8),
                    Text(
                      [
                        'Найдено: ${candidates!.length}',
                        if (known > 0) 'уже в медиатеке: $known',
                        'групп: ${visible.length}',
                      ].join(' · '),
                    ),
                    if (grouping) const LinearProgressIndicator(),
                    if (hiddenCount > 0)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text('Показать скрытые группы ($hiddenCount)'),
                        value: showHidden,
                        onChanged: (value) =>
                            setState(() => showHidden = value),
                      ),
                    if (!grouping && visible.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Text(
                          hidden > 0
                              ? 'Все найденные группы скрыты.'
                              : 'Новых видео не найдено.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                  ],
                ],
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              sliver: SliverList.builder(
                itemCount: visible.length,
                itemBuilder: (context, index) {
                  final group = visible[index];
                  final files = _files(group);
                  final duration = group.totalDurationMs;
                  final isHidden = settings.ignored.contains(group.key);
                  return Card(
                    key: ValueKey('discovery-group:${group.key}'),
                    margin: const EdgeInsets.only(top: 8),
                    child: ListTile(
                      contentPadding: const EdgeInsets.only(left: 4, right: 4),
                      leading: Checkbox(
                        value: selected.contains(group.key) && files.isNotEmpty,
                        onChanged: adding || files.isEmpty
                            ? null
                            : (value) => setState(() {
                                if (value == true) {
                                  selected.add(group.key);
                                } else {
                                  selected.remove(group.key);
                                }
                              }),
                      ),
                      title: Row(
                        children: [
                          Icon(videoGroupIcon(group.kind), size: 18),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              group.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      subtitle: Text(
                        [
                          [
                            group.kind.label,
                            files.length == group.files.length
                                ? 'файлов: ${files.length}'
                                : 'файлов: ${files.length} из ${group.files.length}',
                            if (duration != null && duration > 0)
                              pepeTime(duration),
                            videoBytes(group.totalSize),
                            if (isHidden) 'скрыта',
                          ].where((part) => part.isNotEmpty).join(' · '),
                          if (group.folder.isNotEmpty) group.folder,
                        ].join('\n'),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => _showFiles(group),
                      trailing: PopupMenuButton<String>(
                        tooltip: 'Действия с группой',
                        enabled: !adding,
                        onSelected: (action) {
                          if (action == 'files') _showFiles(group);
                          if (action == 'rename') _rename(group);
                          if (action == 'merge') _merge(group);
                          if (action == 'hide') _toggleHidden(group);
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'files',
                            child: Text('Файлы…'),
                          ),
                          if (group.kind != VideoGroupKind.existing)
                            const PopupMenuItem(
                              value: 'rename',
                              child: Text('Переименовать'),
                            ),
                          const PopupMenuItem(
                            value: 'merge',
                            child: Text('Объединить с…'),
                          ),
                          PopupMenuItem(
                            value: 'hide',
                            child: Text(
                              isHidden
                                  ? 'Вернуть группу'
                                  : 'Скрыть и не предлагать',
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
