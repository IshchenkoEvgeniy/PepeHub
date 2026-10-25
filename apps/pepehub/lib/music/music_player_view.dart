import 'dart:io';

import 'package:flutter/material.dart';

import '../video/video_controller.dart';
import '../video/video_repository.dart';
import '../video/models.dart';
import 'music_metadata.dart';
import 'music_statistics_page.dart';

/// Music has its own presentation; playback and media-button ownership stay
/// with the shared session so opening a queue never creates another decoder.
class MusicPlayerView extends StatelessWidget {
  final VideoPlaybackController player;
  final VideoRepository repository;
  final VideoItem item;
  final VoidCallback onBack, onMini, onNotes;
  final Future<void> Function(Future<void> Function()) run;
  const MusicPlayerView({
    super.key,
    required this.player,
    required this.repository,
    required this.item,
    required this.onBack,
    required this.onMini,
    required this.onNotes,
    required this.run,
  });

  Future<void> _statistics(BuildContext context) => run(() async {
    await player.flush();
    if (!context.mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => MusicStatisticsPage(repository: repository, item: item),
      ),
    );
  });

  Future<void> _edit(BuildContext context) async {
    final song = player.current!;
    final title = TextEditingController(text: song.title);
    final artist = TextEditingController(text: song.music?.artist ?? '');
    final album = TextEditingController(text: song.music?.album ?? '');
    final track = TextEditingController(
      text: song.music?.trackNumber?.toString() ?? '',
    );
    try {
      final result = await showDialog<(String, MusicMetadata)>(
        context: context,
        builder: (context) {
          String? error;
          return StatefulBuilder(
            builder: (context, update) => AlertDialog(
              title: const Text('Сведения о треке'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final field in [
                      (title, 'Название'),
                      (artist, 'Исполнитель'),
                      (album, 'Альбом'),
                      (track, 'Номер трека'),
                    ])
                      TextField(
                        controller: field.$1,
                        decoration: InputDecoration(labelText: field.$2),
                      ),
                    if (error != null) Text(error!),
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
                    final number = int.tryParse(track.text.trim());
                    if (title.text.trim().isEmpty ||
                        title.text.runes.length > 300 ||
                        artist.text.runes.length > 500 ||
                        album.text.runes.length > 500 ||
                        track.text.trim().isNotEmpty &&
                            (number == null || number < 1 || number > 100000)) {
                      update(
                        () => error =
                            'Проверьте название и номер трека (1–100000).',
                      );
                      return;
                    }
                    Navigator.pop(context, (
                      title.text.trim(),
                      MusicMetadata(
                        artist: artist.text.trim(),
                        album: album.text.trim(),
                        trackNumber: number,
                        coverPath: song.music?.coverPath,
                      ),
                    ));
                  },
                  child: const Text('Сохранить'),
                ),
              ],
            ),
          );
        },
      );
      if (result != null && player.current?.id == song.id) {
        await run(
          () => player.updateMusicDetails(
            result.$1,
            result.$2,
            lessonId: song.id,
            mediaVersion: song.mediaVersion,
          ),
        );
      }
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      for (final input in [title, artist, album, track]) {
        input.dispose();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final song = player.current!;
    final order = player.playbackOrder;
    final duration = player.state.durationMs;
    final cover = song.music?.coverPath;
    String time(int ms) =>
        '${ms ~/ 60000}:${(ms ~/ 1000 % 60).toString().padLeft(2, '0')}';
    return Scaffold(
      key: const ValueKey('music-player'),
      appBar: AppBar(
        leading: IconButton(
          tooltip: 'Закрыть плеер',
          onPressed: onBack,
          icon: const Icon(Icons.arrow_back),
        ),
        title: Text(item.title),
        actions: [
          IconButton(
            tooltip: 'Плейлист и заметки',
            onPressed: onNotes,
            icon: const Icon(Icons.notes_outlined),
          ),
          PopupMenuButton<String>(
            tooltip: 'Инструменты плеера',
            onSelected: (value) {
              if (value == 'edit') {
                _edit(context);
              }
              if (value == 'notes') {
                onNotes();
              }
              if (value == 'statistics') {
                _statistics(context);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('Сведения о треке')),
              PopupMenuItem(value: 'notes', child: Text('Плейлист и заметки')),
              PopupMenuItem(
                value: 'statistics',
                child: Text('Статистика музыки'),
              ),
            ],
          ),
          IconButton(
            tooltip: 'Мини-плеер',
            onPressed: onMini,
            icon: const Icon(Icons.minimize),
          ),
        ],
      ),
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 700),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        if (player.loading) const LinearProgressIndicator(),
                        if (player.error != null) Text(player.error!),
                        SizedBox(
                          width: 220,
                          height: 220,
                          child: cover == null
                              ? const Icon(Icons.album_outlined, size: 160)
                              : ClipRRect(
                                  borderRadius: BorderRadius.circular(20),
                                  child: Image.file(
                                    File(cover),
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, error, stack) =>
                                        const Icon(
                                          Icons.album_outlined,
                                          size: 160,
                                        ),
                                  ),
                                ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          song.title,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        Text(
                          song.music?.subtitle.isNotEmpty == true
                              ? song.music!.subtitle
                              : 'Исполнитель и альбом не указаны',
                        ),
                        if (song.music?.trackNumber != null)
                          Text('Трек ${song.music!.trackNumber}'),
                        MusicSeekBar(
                          key: ValueKey(song.id),
                          position: player.positionMs,
                          duration: duration,
                          onSeek: (value) => run(() => player.seek(value)),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(time(player.positionMs)),
                            Text(time(duration)),
                          ],
                        ),
                        Wrap(
                          alignment: WrapAlignment.center,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 12,
                          children: [
                            IconButton(
                              key: const ValueKey('music-shuffle'),
                              tooltip: player.shuffleEnabled
                                  ? 'Выключить перемешивание'
                                  : 'Перемешать',
                              isSelected: player.shuffleEnabled,
                              onPressed: player.canShuffle
                                  ? () => run(
                                      () => player.setShuffle(
                                        !player.shuffleEnabled,
                                      ),
                                    )
                                  : null,
                              icon: const Icon(Icons.shuffle),
                              selectedIcon: const Icon(Icons.shuffle_on),
                            ),
                            IconButton(
                              tooltip: 'Предыдущий трек',
                              onPressed: player.canGoPrevious
                                  ? () => run(player.previous)
                                  : null,
                              icon: const Icon(Icons.skip_previous),
                            ),
                            IconButton.filled(
                              iconSize: 48,
                              tooltip: player.state.playing
                                  ? 'Пауза'
                                  : 'Воспроизвести',
                              onPressed: player.loading
                                  ? null
                                  : () => run(player.toggle),
                              icon: Icon(
                                player.state.playing
                                    ? Icons.pause
                                    : Icons.play_arrow,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Следующий трек',
                              onPressed: player.canGoNext
                                  ? () => run(player.next)
                                  : null,
                              icon: const Icon(Icons.skip_next),
                            ),
                            IconButton(
                              key: const ValueKey('music-repeat'),
                              tooltip: switch (player.repeatMode) {
                                MusicRepeat.off => 'Повтор выключен',
                                MusicRepeat.one => 'Повтор трека',
                                MusicRepeat.all => 'Повтор плейлиста',
                              },
                              isSelected: player.repeatMode != MusicRepeat.off,
                              onPressed: () => run(
                                () => player.setRepeat(
                                  MusicRepeat.values[(player.repeatMode.index +
                                          1) %
                                      3],
                                ),
                              ),
                              icon: Icon(
                                player.repeatMode == MusicRepeat.one
                                    ? Icons.repeat_one
                                    : Icons.repeat,
                              ),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            const Icon(Icons.volume_up_outlined),
                            Expanded(
                              child: Slider(
                                value: player.state.volume.clamp(0, 100),
                                max: 100,
                                onChanged: (value) =>
                                    run(() => player.setVolume(value)),
                              ),
                            ),
                          ],
                        ),
                        Wrap(
                          spacing: 12,
                          children: [
                            PopupMenuButton<int>(
                              tooltip: 'Таймер сна',
                              onSelected: (minutes) => run(
                                () => player.setSleepTimer(
                                  minutes > 0
                                      ? Duration(minutes: minutes)
                                      : null,
                                  untilLessonEnd: minutes == -1,
                                ),
                              ),
                              itemBuilder: (_) => [
                                for (final minutes in [0, 15, 30, 60, -1])
                                  PopupMenuItem(
                                    value: minutes,
                                    child: Text(
                                      minutes == 0
                                          ? 'Выключить таймер'
                                          : minutes == -1
                                          ? 'До конца трека'
                                          : '$minutes минут',
                                    ),
                                  ),
                              ],
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Text(
                                  player.sleepAtLessonEnd
                                      ? 'Сон: конец трека'
                                      : player.sleepRemainingMs == null
                                      ? 'Таймер сна'
                                      : 'Сон: ${time(player.sleepRemainingMs!)}',
                                ),
                              ),
                            ),
                            TextButton.icon(
                              onPressed: () async {
                                final choices = [
                                  for (
                                    var i = 0;
                                    i < player.lessons.length;
                                    i++
                                  )
                                    if (player.lessons[i].isAudio &&
                                        player.lessons[i].available &&
                                        i != player.index)
                                      i,
                                ];
                                final selected = await showDialog<int>(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    title: const Text('Играть следующим'),
                                    content: SizedBox(
                                      width: 420,
                                      height: 380,
                                      child: choices.isEmpty
                                          ? const Center(
                                              child: Text('Нет других треков'),
                                            )
                                          : ListView.builder(
                                              itemCount: choices.length,
                                              itemBuilder: (context, row) {
                                                final i = choices[row],
                                                    track = player.lessons[i];
                                                return ListTile(
                                                  title: Text(track.title),
                                                  subtitle: Text(
                                                    track.music?.subtitle ?? '',
                                                  ),
                                                  onTap: () =>
                                                      Navigator.pop(context, i),
                                                );
                                              },
                                            ),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(context),
                                        child: const Text('Отмена'),
                                      ),
                                    ],
                                  ),
                                );
                                if (selected != null) {
                                  await run(() => player.playNext(selected));
                                }
                              },
                              icon: const Icon(Icons.queue_music),
                              label: const Text('Добавить в очередь'),
                            ),
                          ],
                        ),
                        Text(
                          'Очередь · ${order.length} треков',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            SliverReorderableList(
              itemCount: order.length,
              onReorderItem: (from, to) =>
                  run(() => player.reorderQueue(from, to)),
              itemBuilder: (context, row) {
                final i = order[row], track = player.lessons[i];
                return ListTile(
                  key: ValueKey('music-queue-${track.id}'),
                  selected: i == player.index,
                  leading: ReorderableDragStartListener(
                    index: row,
                    child: const Padding(
                      padding: EdgeInsets.all(12),
                      child: Icon(Icons.drag_handle),
                    ),
                  ),
                  title: Text(track.title),
                  subtitle: Text(track.music?.subtitle ?? ''),
                  onTap: () => run(() => player.load(i)),
                  trailing: PopupMenuButton<String>(
                    onSelected: (value) => run(
                      () => value == 'next'
                          ? player.playNext(i)
                          : player.removeFromQueue(i),
                    ),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'next',
                        enabled: i != player.index,
                        child: const Text('Играть следующим'),
                      ),
                      PopupMenuItem(
                        value: 'remove',
                        enabled: i != player.index,
                        child: const Text('Убрать из очереди'),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Keep scrubbing local; one seek on release avoids serializing dozens of
/// decoder operations while the user drags the thumb.
class MusicSeekBar extends StatefulWidget {
  final int position, duration;
  final Future<void> Function(int) onSeek;
  const MusicSeekBar({
    super.key,
    required this.position,
    required this.duration,
    required this.onSeek,
  });
  @override
  State<MusicSeekBar> createState() => _MusicSeekBarState();
}

class _MusicSeekBarState extends State<MusicSeekBar> {
  double? drag;
  @override
  Widget build(BuildContext context) => Slider(
    key: const ValueKey('music-seek'),
    value: (drag ?? widget.position.toDouble()).clamp(
      0,
      widget.duration > 0 ? widget.duration.toDouble() : 1,
    ),
    max: widget.duration > 0 ? widget.duration.toDouble() : 1,
    onChanged: widget.duration > 0
        ? (value) => setState(() => drag = value)
        : null,
    onChangeEnd: (value) {
      setState(() => drag = null);
      widget.onSeek(value.round());
    },
  );
}
