import 'package:flutter/material.dart';

import '../diagnostics/user_message.dart';
import '../media/audio_controller.dart';
import '../ui/audio_mini_player.dart';
import '../ui/pepe_widgets.dart';
import 'models.dart';
import 'video_player_page.dart';
import 'video_repository.dart';

String videoSectionOf(Iterable<VideoLesson> lessons) =>
    lessons.isNotEmpty && lessons.every((lesson) => lesson.isAudio)
    ? 'music'
    : 'video';

/// Asks which playlist receives [lessons] (or creates one) and adds them.
/// Returns the playlist title, or null when the user cancelled.
Future<String?> addLessonsToPlaylist(
  BuildContext context,
  VideoRepository repository,
  List<VideoLesson> lessons,
) async {
  if (lessons.isEmpty) return null;
  final section = videoSectionOf(lessons);
  final own = lessons
      .where((lesson) => lesson.isAudio == (section == 'music'))
      .toList();
  final playlists = (await repository.playlists())
      .where((playlist) => playlist.section == section)
      .toList();
  if (!context.mounted) return null;
  final choice = await showDialog<({String? id, String title})>(
    context: context,
    builder: (_) => _PlaylistChoiceDialog(playlists: playlists),
  );
  if (choice == null || !context.mounted) return null;
  final messenger = ScaffoldMessenger.of(context);
  try {
    var id = choice.id;
    var added = own.length;
    if (id == null) {
      id = (await repository.createPlaylist(
        choice.title,
        section: section,
        entries: [for (final lesson in own) lesson.id],
      )).id;
    } else {
      added = await repository.addToPlaylist(id, own.map((l) => l.id));
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          added == 0
              ? 'Уже в плейлисте «${choice.title}»'
              : 'Добавлено в «${choice.title}»: $added',
        ),
      ),
    );
    return choice.title;
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(describeError(e))));
    return null;
  }
}

/// Asks for a playlist title. Returns null when cancelled.
Future<String?> askPlaylistTitle(
  BuildContext context, {
  String initial = '',
  String title = 'Новый плейлист',
}) => showDialog<String>(
  context: context,
  builder: (_) => _PlaylistTitleDialog(initial: initial, title: title),
);

class _PlaylistTitleDialog extends StatefulWidget {
  final String initial, title;
  const _PlaylistTitleDialog({required this.initial, required this.title});
  @override
  State<_PlaylistTitleDialog> createState() => _PlaylistTitleDialogState();
}

class _PlaylistTitleDialogState extends State<_PlaylistTitleDialog> {
  late final controller = TextEditingController(text: widget.initial);
  String? error;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = controller.text.trim();
    if (value.isEmpty || value.length > 300) {
      setState(() => error = 'Название: от 1 до 300 символов');
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: controller,
      autofocus: true,
      maxLength: 300,
      decoration: InputDecoration(labelText: 'Название', errorText: error),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Сохранить')),
    ],
  );
}

class _PlaylistChoiceDialog extends StatelessWidget {
  final List<VideoPlaylist> playlists;
  const _PlaylistChoiceDialog({required this.playlists});
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Добавить в плейлист'),
    content: SizedBox(
      width: 420,
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('Новый плейлист…'),
            onTap: () async {
              final title = await askPlaylistTitle(context);
              if (title != null && context.mounted) {
                Navigator.pop(context, (id: null, title: title));
              }
            },
          ),
          for (final playlist in playlists)
            ListTile(
              leading: const Icon(Icons.playlist_play),
              title: Text(playlist.title),
              subtitle: Text('Файлов: ${playlist.entries.length}'),
              onTap: () => Navigator.pop(context, (
                id: playlist.id,
                title: playlist.title,
              )),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
    ],
  );
}

class VideoPlaylistPage extends StatefulWidget {
  final VideoRepository repository;
  final VideoPlaylist playlist;
  final AudioController? audio;
  const VideoPlaylistPage({
    super.key,
    required this.repository,
    required this.playlist,
    this.audio,
  });
  @override
  State<VideoPlaylistPage> createState() => _VideoPlaylistPageState();
}

class _VideoPlaylistPageState extends State<VideoPlaylistPage> {
  late VideoPlaylist playlist = widget.playlist;
  List<VideoLesson> entries = [];
  Map<String, VideoItem> items = {};
  bool loading = true, busy = false;
  String? error;
  int missing = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final current = (await widget.repository.playlists())
          .where((value) => value.id == playlist.id)
          .firstOrNull;
      if (current == null) {
        if (mounted) Navigator.pop(context);
        return;
      }
      final all = await widget.repository.lessons();
      final byId = {for (final lesson in all) lesson.id: lesson};
      final nextItems = {
        for (final item in await widget.repository.items()) item.id: item,
      };
      final resolved = <VideoLesson>[];
      var gone = 0;
      for (final id in current.entries) {
        final lesson = byId[id];
        if (lesson == null ||
            !nextItems.containsKey(lesson.itemId) ||
            lesson.isAudio != (current.section == 'music')) {
          gone++;
        } else {
          resolved.add(lesson);
        }
      }
      if (!mounted) return;
      setState(() {
        playlist = current;
        entries = resolved;
        items = nextItems;
        missing = gone;
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

  bool _playable(VideoLesson lesson) =>
      lesson.available && items[lesson.itemId]?.connected != false;

  Future<void> _save(List<VideoLesson> next) async {
    final shown = entries.map((lesson) => lesson.id).toSet();
    setState(() => entries = next);
    try {
      playlist = await widget.repository.savePlaylistEntries(playlist.id, [
        for (final lesson in next) lesson.id,
      ], shown: shown);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(describeError(e))));
        await _load();
      }
    }
  }

  Future<void> _play(int index) async {
    if (busy) return;
    final playable = entries.where(_playable).toList();
    final start = playable.indexOf(entries[index]);
    if (start < 0) return;
    setState(() => busy = true);
    try {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => VideoPlayerPage(
            repository: widget.repository,
            // The playlist plays like a course; lessons keep their own
            // progress, notes and statistics in their items.
            item: VideoItem(
              id: playlist.id,
              title: playlist.title,
              kind: VideoItemKind.course,
            ),
            lessons: playable,
            initialIndex: start,
            beforePlaying: widget.audio?.pause,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _rename() async {
    final title = await askPlaylistTitle(
      context,
      initial: playlist.title,
      title: 'Переименовать плейлист',
    );
    if (title == null) return;
    try {
      final next = await widget.repository.renamePlaylist(playlist.id, title);
      if (mounted) setState(() => playlist = next);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(describeError(e))));
      }
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Удалить плейлист «${playlist.title}»?'),
        content: const Text(
          'Видео и курсы останутся в медиатеке, удалится только список.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить плейлист'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.repository.deletePlaylist(playlist.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final duration = entries.every((lesson) => lesson.durationMs != null)
        ? entries.fold<int>(0, (sum, lesson) => sum + lesson.durationMs!)
        : null;
    return Scaffold(
      bottomNavigationBar: const AudioPlayerFooter(),
      appBar: AppBar(
        title: Text(playlist.title),
        actions: [
          IconButton(
            tooltip: 'Воспроизвести плейлист',
            onPressed: busy || !entries.any(_playable)
                ? null
                : () => _play(entries.indexWhere(_playable)),
            icon: const Icon(Icons.play_arrow),
          ),
          PopupMenuButton<String>(
            tooltip: 'Действия с плейлистом',
            onSelected: (action) {
              if (action == 'rename') _rename();
              if (action == 'delete') _delete();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('Переименовать')),
              PopupMenuItem(value: 'delete', child: Text('Удалить плейлист…')),
            ],
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (loading) const LinearProgressIndicator(),
          if (error != null)
            Padding(padding: const EdgeInsets.all(16), child: Text(error!)),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              [
                'Файлов: ${entries.length}',
                if (duration != null && duration > 0) pepeTime(duration),
                if (missing > 0) 'удалено из медиатеки: $missing',
              ].join(' · '),
            ),
          ),
          if (!loading && entries.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Плейлист пуст. Добавляйте видео через меню «⋮» у видео или '
                'курса либо кнопкой рядом с уроком.',
                textAlign: TextAlign.center,
              ),
            ),
          Expanded(
            child: ReorderableListView.builder(
              padding: const EdgeInsets.only(bottom: 16),
              // Own handles: the default one covers the remove button on
              // desktop. A long press drags on phones.
              buildDefaultDragHandles: false,
              itemCount: entries.length,
              onReorderItem: (oldIndex, newIndex) {
                final next = [...entries];
                next.insert(newIndex, next.removeAt(oldIndex));
                _save(next);
              },
              itemBuilder: (_, i) {
                final lesson = entries[i];
                final item = items[lesson.itemId];
                return ReorderableDelayedDragStartListener(
                  key: ValueKey(lesson.id),
                  index: i,
                  child: ListTile(
                    leading: ReorderableDragStartListener(
                      index: i,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.drag_indicator),
                          const SizedBox(width: 4),
                          Text('${i + 1}'),
                        ],
                      ),
                    ),
                    title: Text(
                      lesson.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      [
                        if (item != null && item.title != lesson.title)
                          item.title,
                        if (lesson.durationMs != null)
                          pepeTime(lesson.durationMs!),
                        if (!_playable(lesson)) 'Файл недоступен',
                      ].join(' · '),
                    ),
                    trailing: IconButton(
                      tooltip: 'Убрать из плейлиста',
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () => _save([...entries]..removeAt(i)),
                    ),
                    onTap: busy || !_playable(lesson) ? null : () => _play(i),
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
