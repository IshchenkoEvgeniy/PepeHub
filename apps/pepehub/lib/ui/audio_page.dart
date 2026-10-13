import 'audio_statistics_page.dart';
import 'audio_notes_page.dart';

import 'dart:io';

import 'package:flutter/material.dart';

import '../data/repository.dart';
import '../media/audio_controller.dart';
import 'pepe_widgets.dart';
import 'shelf_components.dart';

String audioTime(Duration duration) {
  final seconds = duration.inSeconds;
  final h = seconds ~/ 3600, m = (seconds % 3600) ~/ 60, s = seconds % 60;
  return h > 0
      ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
      : '$m:${s.toString().padLeft(2, '0')}';
}

class AudioPage extends StatefulWidget {
  final AudioController controller;
  const AudioPage({super.key, required this.controller});
  @override
  State<AudioPage> createState() => _AudioPageState();
}

class _AudioPageState extends State<AudioPage> {
  double? dragPosition, bookDragPosition;
  AudioController get controller => widget.controller;
  Future<void> _showTracks() async {
    final tracks = controller.tracks;
    final selected = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Треки · ${tracks.length}'),
        content: SizedBox(
          width: 560,
          height: 400,
          child: ListView.builder(
            itemCount: tracks.length,
            itemBuilder: (_, i) => ListTile(
              onTap: () => Navigator.pop(context, i),
              selected: i == controller.trackIndex,
              leading: Text('${i + 1}'),
              title: Text(tracks[i].filename),
            ),
          ),
        ),
      ),
    );
    if (selected != null) await controller.skipToQueueItem(selected);
  }

  Future<void> _addBookmark() async {
    var label = audioTime(controller.position);
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Новая закладка'),
        content: TextFormField(
          initialValue: label,
          maxLength: 500,
          onChanged: (v) => label = v,
          decoration: const InputDecoration(labelText: 'Название / заметка'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, label),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (title == null || title.trim().isEmpty) return;
    try {
      await controller.addBookmark(title);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Закладка сохранена')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _editBookmark(String id, String oldTitle) async {
    var title = oldTitle;
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Редактировать закладку'),
        content: TextFormField(
          initialValue: oldTitle,
          maxLength: 500,
          onChanged: (v) => title = v,
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
    if (value == null) return;
    try {
      await controller.journal.editBookmark(id, value);
      await controller.sidecar.update(controller.current!.bookId, force: true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _showBookmarks() async {
    final book = controller.current?.bookId;
    if (book == null) return;
    final rows = await controller.journal.list('audio_bookmark', bookId: book);
    String? deletedId;
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, refresh) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .7,
            child: Column(
              children: [
                const ListTile(title: Text('Закладки')),
                if (deletedId != null)
                  ListTile(
                    title: const Text('Закладка удалена'),
                    trailing: TextButton(
                      onPressed: () async {
                        final id = deletedId!;
                        try {
                          await controller.journal.restoreBookmark(id);
                          final updated = await controller.journal.list(
                            'audio_bookmark',
                            bookId: book,
                          );
                          rows
                            ..clear()
                            ..addAll(updated);
                          deletedId = null;
                          if (context.mounted) refresh(() {});
                          await controller.sidecar.update(book, force: true);
                        } catch (e) {
                          if (mounted) {
                            ScaffoldMessenger.of(this.context)
                                .showSnackBar(SnackBar(content: Text('$e')));
                          }
                        }
                      },
                      child: const Text('Отменить удаление'),
                    ),
                  ),
                Expanded(
                  child: ListView(
                    children: [
                      for (final row in rows)
                        ListTile(
                          title: Text(row.payload!['title'] as String),
                          subtitle: Text(
                            audioTime(
                              Duration(
                                milliseconds: row.payload!['positionMs'] as int,
                              ),
                            ),
                          ),
                          onTap: () {
                            Navigator.pop(context);
                            controller.goToLocation(
                              row.payload!['trackId'] as String,
                              row.payload!['positionMs'] as int,
                            );
                          },
                          onLongPress: () async {
                            await _editBookmark(
                              row.id,
                              row.payload!['title'] as String,
                            );
                            final updated = await controller.journal.list(
                              'audio_bookmark',
                              bookId: book,
                            );
                            rows
                              ..clear()
                              ..addAll(updated);
                            if (context.mounted) refresh(() {});
                          },
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Редактировать закладку',
                                icon: const Icon(Icons.edit_outlined),
                                onPressed: () async {
                                  await _editBookmark(
                                    row.id,
                                    row.payload!['title'] as String,
                                  );
                                  final updated = await controller.journal.list(
                                    'audio_bookmark',
                                    bookId: book,
                                  );
                                  rows
                                    ..clear()
                                    ..addAll(updated);
                                  if (context.mounted) refresh(() {});
                                },
                              ),
                              IconButton(
                                tooltip: 'Удалить закладку',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () async {
                                  await controller.journal.deleteBookmark(
                                    row.id,
                                  );
                                  rows.remove(row);
                                  deletedId = row.id;
                                  if (mounted) {
                                    ScaffoldMessenger.of(
                                      this.context,
                                    ).showSnackBar(
                                      SnackBar(
                                        content: const Text('Закладка удалена'),
                                        duration: const Duration(seconds: 10),
                                        action: SnackBarAction(
                                          label: 'Отменить',
                                          onPressed: () async {
                                            try {
                                              await controller.journal
                                                  .restoreBookmark(row.id);
                                              final updated = await controller
                                                  .journal
                                                  .list(
                                                    'audio_bookmark',
                                                    bookId: book,
                                                  );
                                              rows
                                                ..clear()
                                                ..addAll(updated);
                                              if (context.mounted) {
                                                refresh(() {});
                                              }
                                              await controller.sidecar.update(
                                                book,
                                                force: true,
                                              );
                                            } catch (e) {
                                              if (mounted) {
                                                ScaffoldMessenger.of(
                                                  this.context,
                                                ).showSnackBar(
                                                  SnackBar(content: Text('$e')),
                                                );
                                              }
                                            }
                                          },
                                        ),
                                      ),
                                    );
                                  }

                                  if (context.mounted) refresh(() {});
                                  try {
                                    await controller.sidecar.update(
                                      book,
                                      force: true,
                                    );
                                  } catch (e) {
                                    if (mounted) {
                                      ScaffoldMessenger.of(
                                        this.context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            'Закладка удалена локально, снимок не обновлён: $e',
                                          ),
                                        ),
                                      );
                                    }
                                  }
                                },
                              ),
                            ],
                          ),
                        ),
                      if (rows.isEmpty)
                        const ListTile(title: Text('Закладок пока нет')),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showHistory() async {
    final book = controller.current?.bookId;
    if (book == null) return;
    await controller.flushJournal();
    final rows = (await controller.journal.list(
      'audio_event',
      bookId: book,
      kind: 'seek',
      limit: 100,
    )).where((r) => r.payload?['kind'] == 'seek').take(100).toList();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .7,
          child: Column(
            children: [
              const ListTile(
                title: Text('История перемоток'),
                subtitle: Text('Нажмите, чтобы вернуться к исходной позиции'),
              ),
              Expanded(
                child: ListView(
                  children: [
                    for (final row in rows)
                      ListTile(
                        leading: const Icon(Icons.undo),
                        title: Text(
                          '${audioTime(Duration(milliseconds: row.payload!['fromMs'] as int))} → ${audioTime(Duration(milliseconds: row.payload!['positionMs'] as int))}',
                        ),
                        subtitle: Text(
                          '${row.payload!['at']} · ${row.payload!['reason']}',
                        ),
                        onTap: () {
                          Navigator.pop(context);
                          controller.goToLocation(
                            row.payload!['fromTrackId'] as String,
                            row.payload!['fromMs'] as int,
                            reason: 'history',
                          );
                        },
                      ),
                    if (rows.isEmpty)
                      const ListTile(title: Text('Перемоток пока нет')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showChapters() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .7,
          child: Column(
            children: [
              const ListTile(
                title: Text('Главы книги'),
                subtitle: Text('Каждый аудиофайл — отдельная глава'),
              ),
              Expanded(
                child: ListView(
                  children: [
                    for (var i = 0; i < controller.tracks.length; i++)
                      ListTile(
                        leading: Text('${i + 1}'),
                        selected: i == controller.trackIndex,
                        title: Text(controller.tracks[i].filename),
                        subtitle: Text(
                          controller.trackDuration(controller.tracks[i].id) ==
                                  null
                              ? 'Длительность пока неизвестна'
                              : audioTime(
                                  controller.trackDuration(
                                    controller.tracks[i].id,
                                  )!,
                                ),
                        ),
                        onTap: () {
                          Navigator.pop(context);
                          controller.skipToQueueItem(i);
                        },
                      ),
                    if (controller.chapters.isNotEmpty)
                      const ListTile(
                        title: Text('Встроенные главы текущего файла'),
                      ),
                    for (final chapter in controller.chapters)
                      ListTile(
                        title: Text(chapter.title),
                        subtitle: Text(
                          audioTime(Duration(milliseconds: chapter.startMs)),
                        ),
                        onTap: () {
                          Navigator.pop(context);
                          controller.goToChapter(chapter);
                        },
                      ),
                    if (controller.chapterError.isNotEmpty)
                      ListTile(
                        title: Text(
                          controller.chapterError.isEmpty
                              ? 'Встроенные главы не найдены'
                              : controller.chapterError,
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

  void _showTools() => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => ListenableBuilder(
      listenable: controller,
      builder: (context, _) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton.icon(
                onPressed: controller.chooseArtwork,
                icon: const Icon(Icons.image_outlined),
                label: const Text('Выбрать обложку'),
              ),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 24,
                runSpacing: 16,
                children: [
                  DropdownButton<double>(
                    value: controller.speed,
                    items: [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]
                        .map(
                          (speed) => DropdownMenuItem(
                            value: speed,
                            child: Text('$speed×'),
                          ),
                        )
                        .toList(),
                    onChanged: (speed) {
                      if (speed != null) controller.setSpeed(speed);
                    },
                  ),
                  PopupMenuButton<int>(
                    tooltip: 'Таймер сна',
                    onSelected: (minutes) => controller.setSleepTimer(
                      minutes <= 0 ? null : minutes,
                      mode: minutes == -1
                          ? 'chapter'
                          : minutes == -2
                          ? 'track'
                          : 'duration',
                    ),
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: -1,
                        child: Text('До конца главы'),
                      ),
                      const PopupMenuItem(
                        value: -2,
                        child: Text('До конца трека'),
                      ),
                      for (final minutes in [0, 15, 30, 60])
                        PopupMenuItem(
                          value: minutes,
                          child: Text(
                            minutes == 0
                                ? 'Выключить таймер'
                                : '$minutes минут',
                          ),
                        ),
                    ],
                    child: Chip(
                      avatar: const Icon(Icons.bedtime_outlined),
                      label: Text(
                        controller.sleepUntil == null
                            ? (controller.sleepMode == 'off'
                                  ? 'Таймер сна'
                                  : controller.sleepMode == 'chapter'
                                  ? 'До конца главы'
                                  : 'До конца трека')
                            : 'До ${TimeOfDay.fromDateTime(controller.sleepUntil!).format(context)}',
                      ),
                    ),
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  TextButton.icon(
                    onPressed: _showChapters,
                    icon: const Icon(Icons.list_alt),
                    label: Text('Главы (${controller.tracks.length})'),
                  ),
                  TextButton.icon(
                    onPressed: controller.canPlay ? _addBookmark : null,
                    icon: const Icon(Icons.bookmark_add_outlined),
                    label: const Text('Закладка'),
                  ),
                  TextButton(
                    onPressed: _showBookmarks,
                    child: const Text('Мои закладки'),
                  ),
                  TextButton.icon(
                    onPressed: _showHistory,
                    icon: const Icon(Icons.history),
                    label: const Text('Перемотки'),
                  ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Плавно затихать перед сном'),
                value: controller.sleepFade,
                onChanged: (v) => controller.updateSleepOptions(fade: v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Вернуться на 10 секунд после таймера'),
                value: controller.sleepRewind,
                onChanged: (v) => controller.updateSleepOptions(rewind: v),
              ),
              if (controller.sleepMode != 'off')
                TextButton.icon(
                  onPressed: controller.extendSleep,
                  icon: const Icon(Icons.more_time),
                  label: const Text('Ещё 15 минут'),
                ),
            ],
          ),
        ),
      ),
    ),
  );

  String? panelBook;
  int panelVersion = 0;
  Future<List<LibraryRecord>>? bookmarkRows, seekRows;

  void _panelData() {
    final book = controller.current?.bookId;
    final key = '$book:$panelVersion';
    if (key == panelBook) return;
    panelBook = key;
    if (book == null) {
      bookmarkRows = seekRows = null;
      return;
    }
    bookmarkRows = controller.journal.list('audio_bookmark', bookId: book);
    seekRows = () async {
      await controller.flushJournal();
      return (await controller.journal.list(
        'audio_event',
        bookId: book,
        kind: 'seek',
        limit: 100,
      )).where((r) => r.payload?['kind'] == 'seek').take(100).toList();
    }();
  }

  void _refreshPanel() {
    if (mounted) setState(() => panelVersion++);
  }

  Widget _skip(int seconds, {bool compact = false}) => IconButton(
    tooltip: '${seconds < 0 ? 'Назад' : 'Вперёд'} на ${seconds.abs() == 60 ? '1 минуту' : '10 секунд'}',
    onPressed: controller.canPlay
        ? () => controller.skipSeconds(seconds)
        : null,
    icon: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          seconds < 0 ? Icons.fast_rewind_rounded : Icons.fast_forward_rounded,
          size: compact ? 26 : 30,
        ),
        Text(
          '${seconds < 0 ? '−' : '+'}${seconds.abs() == 60 ? '1 мин' : '10 с'}',
          style: const TextStyle(fontSize: 11),
        ),
      ],
    ),
  );

  Widget _playButton(ShelfPalette palette, double size) => SizedBox.square(
    dimension: size,
    child: IconButton.filled(
      key: const ValueKey('cover-play'),
      tooltip: controller.playing ? 'Пауза' : 'Воспроизвести',
      style: IconButton.styleFrom(
        backgroundColor: palette.accent,
        foregroundColor: palette.onAccent,
      ),
      iconSize: size * .5,
      onPressed: !controller.canPlay
          ? null
          : controller.playing
          ? controller.pause
          : controller.play,
      icon: Icon(
        controller.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
      ),
    ),
  );

  Widget _cover(ShelfPalette palette, double height) => SizedBox(
    height: height,
    child: Center(
      child: AspectRatio(
        aspectRatio: .72,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: ColoredBox(
            color: palette.raised,
            child: controller.artwork != null
                ? Image.file(
                    File.fromUri(controller.artwork!),
                    fit: BoxFit.cover,
                    errorBuilder: (_, error, stack) => Icon(
                      Icons.headphones,
                      size: 90,
                      color: palette.accent,
                    ),
                  )
                : Icon(
                    Icons.headphones_rounded,
                    size: 90,
                    color: palette.accent,
                  ),
          ),
        ),
      ),
    ),
  );

  String get _sleepLabel => controller.sleepUntil == null
      ? (controller.sleepMode == 'off'
            ? 'Таймер сна'
            : controller.sleepMode == 'chapter'
            ? 'До конца главы'
            : 'До конца трека')
      : 'Сон в ${TimeOfDay.fromDateTime(controller.sleepUntil!).format(context)}';

  Widget _chips(ShelfPalette palette) => Wrap(
    spacing: 8,
    runSpacing: 8,
    alignment: WrapAlignment.center,
    children: [
      PopupMenuButton<double>(
        tooltip: 'Скорость',
        initialValue: controller.speed,
        onSelected: controller.setSpeed,
        itemBuilder: (_) => [
          for (final speed in [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0])
            PopupMenuItem(value: speed, child: Text('$speed×')),
        ],
        child: IgnorePointer(
          child: ShelfPill(
            label: '${controller.speed}×',
            selected: controller.speed != 1,
            onTap: () {},
          ),
        ),
      ),
      PopupMenuButton<int>(
        tooltip: 'Таймер сна',
        onSelected: (minutes) => controller.setSleepTimer(
          minutes <= 0 ? null : minutes,
          mode: minutes == -1
              ? 'chapter'
              : minutes == -2
              ? 'track'
              : 'duration',
        ),
        itemBuilder: (_) => [
          const PopupMenuItem(value: -1, child: Text('До конца главы')),
          const PopupMenuItem(value: -2, child: Text('До конца трека')),
          for (final minutes in [0, 15, 30, 60])
            PopupMenuItem(
              value: minutes,
              child: Text(minutes == 0 ? 'Выключить таймер' : '$minutes минут'),
            ),
        ],
        child: IgnorePointer(
          child: ShelfPill(
            label: _sleepLabel,
            selected: controller.sleepMode != 'off',
            onTap: () {},
          ),
        ),
      ),
      IconButton(
        tooltip: 'Добавить закладку',
        onPressed: controller.canPlay
            ? () async {
                await _addBookmark();
                _refreshPanel();
              }
            : null,
        icon: const Icon(Icons.bookmark_add_outlined),
      ),
      IconButton(
        tooltip: 'Мои закладки',
        onPressed: () async {
          await _showBookmarks();
          _refreshPanel();
        },
        icon: const Icon(Icons.bookmarks_outlined),
      ),
      IconButton(
        tooltip: 'Перемотки',
        onPressed: _showHistory,
        icon: const Icon(Icons.history),
      ),
    ],
  );

  Widget _progress(ShelfPalette palette, double maxTrack) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (controller.loading) const LinearProgressIndicator(),
      Slider(
        value: (dragPosition ?? controller.position.inMilliseconds.toDouble())
            .clamp(0, maxTrack),
        max: maxTrack,
        onChanged: controller.canPlay && controller.duration > Duration.zero
            ? (v) => setState(() => dragPosition = v)
            : null,
        onChangeEnd: (v) async {
          await controller.seek(Duration(milliseconds: v.round()));
          if (mounted) setState(() => dragPosition = null);
        },
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              audioTime(controller.position),
              style: TextStyle(fontSize: 12.5, color: palette.muted),
            ),
            Text(
              '−${audioTime(Duration(milliseconds: (controller.duration - controller.position).inMilliseconds.clamp(0, 1 << 53)))}',
              style: TextStyle(fontSize: 12.5, color: palette.muted),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _controls(ShelfPalette palette, {required bool wide}) => FittedBox(
    fit: BoxFit.scaleDown,
    child: Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        tooltip: 'Предыдущая глава',
        onPressed: controller.canPlay && controller.trackIndex > 0
            ? controller.skipToPrevious
            : null,
        icon: const Icon(Icons.skip_previous_rounded),
      ),
      _skip(-60, compact: !wide),
      _skip(-10, compact: !wide),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: _playButton(palette, wide ? 84 : 68),
      ),
      _skip(10, compact: !wide),
      _skip(60, compact: !wide),
      IconButton(
        tooltip: 'Следующая глава',
        onPressed:
            controller.canPlay &&
                controller.trackIndex < controller.tracks.length - 1
            ? controller.skipToNext
            : null,
        icon: const Icon(Icons.skip_next_rounded),
      ),
    ],
    ),
  );

  Widget _bookProgress(ShelfPalette palette) {
    if (controller.bookFraction == null) {
      return Column(
        children: [
          Text(
            'Длительности: ${controller.knownDurations} из ${controller.tracks.length}',
            textAlign: TextAlign.center,
            style: TextStyle(color: palette.muted),
          ),
          if (controller.scanningDurations)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: LinearProgressIndicator(),
            )
          else
            TextButton(
              onPressed: controller.scanDurations,
              child: const Text('Определить длительности'),
            ),
          if (controller.durationError.isNotEmpty)
            Text(controller.durationError),
        ],
      );
    }
    return PepePanel(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Вся книга · ${(controller.bookFraction! * 100).toStringAsFixed(1)}%',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                'Осталось ${audioTime(controller.remainingAtSpeed!)} на ${controller.speed}×',
                style: TextStyle(fontSize: 12, color: palette.muted),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
            ),
            child: Slider(
              semanticFormatterCallback: (v) =>
                  'Позиция в книге ${v.round()} процентов',
              value: bookDragPosition ?? controller.bookFraction! * 100,
              max: 100,
              onChanged: controller.canPlay
                  ? (v) => setState(() => bookDragPosition = v)
                  : null,
              onChangeEnd: (v) async {
                await controller.seekBook(
                  Duration(
                    milliseconds:
                        (controller.bookDuration!.inMilliseconds * v / 100)
                            .round(),
                  ),
                );
                if (mounted) setState(() => bookDragPosition = null);
              },
            ),
          ),
          Text(
            '${audioTime(controller.bookPosition!)} из ${audioTime(controller.bookDuration!)}',
            style: TextStyle(fontSize: 12, color: palette.muted),
          ),
        ],
      ),
    );
  }

  Widget _heading(ShelfPalette palette, {required bool wide}) => Column(
    crossAxisAlignment: wide
        ? CrossAxisAlignment.start
        : CrossAxisAlignment.center,
    children: [
      Text(
        controller.title,
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        textAlign: wide ? TextAlign.start : TextAlign.center,
        style: AppFonts.book(palette.text, size: wide ? 30 : 22),
      ),
      const SizedBox(height: 6),
      InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: controller.canPlay ? _showTracks : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Text(
            'Глава ${controller.trackIndex + 1} из ${controller.tracks.length} · ${controller.current?.filename ?? ''}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: wide ? TextAlign.start : TextAlign.center,
            style: TextStyle(fontSize: 13, color: palette.muted),
          ),
        ),
      ),
    ],
  );

  List<Widget> _notices(ShelfPalette palette) => [
    if (controller.sidecarError.isNotEmpty)
      Text(
        controller.sidecarError,
        style: TextStyle(fontSize: 12, color: palette.muted),
      ),
    if (controller.error.isNotEmpty)
      Text(
        controller.error,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
  ];

  Widget _chapterList(ShelfPalette palette) => ListView(
    padding: const EdgeInsets.symmetric(vertical: 8),
    children: [
      for (var i = 0; i < controller.tracks.length; i++)
        ListTile(
          dense: true,
          selected: i == controller.trackIndex,
          selectedTileColor: palette.selected,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          leading: Text(
            '${i + 1}',
            style: AppFonts.title(
              i == controller.trackIndex ? palette.accent : palette.muted,
              size: 18,
            ),
          ),
          title: Text(
            controller.tracks[i].filename,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Text(
            controller.trackDuration(controller.tracks[i].id) == null
                ? ''
                : audioTime(controller.trackDuration(controller.tracks[i].id)!),
            style: TextStyle(fontSize: 12, color: palette.muted),
          ),
          onTap: () => controller.skipToQueueItem(i),
        ),
      if (controller.chapters.isNotEmpty) ...[
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: PepeCaption('Главы текущего файла'),
        ),
        for (final chapter in controller.chapters)
          ListTile(
            dense: true,
            title: Text(chapter.title),
            trailing: Text(audioTime(Duration(milliseconds: chapter.startMs))),
            onTap: () => controller.goToChapter(chapter),
          ),
      ],
    ],
  );

  Widget _rows(
    ShelfPalette palette,
    Future<List<LibraryRecord>>? future,
    String empty,
    Widget Function(LibraryRecord row) build,
  ) => FutureBuilder<List<LibraryRecord>>(
    future: future,
    builder: (context, snapshot) {
      final rows = snapshot.data;
      if (rows == null) {
        return snapshot.hasError
            ? Center(child: Text('${snapshot.error}'))
            : const Center(child: CircularProgressIndicator());
      }
      if (rows.isEmpty) {
        return Center(
          child: Text(empty, style: TextStyle(color: palette.muted)),
        );
      }
      return ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [for (final row in rows) build(row)],
      );
    },
  );

  Widget _panel(ShelfPalette palette) {
    _panelData();
    return DefaultTabController(
      length: 3,
      child: Material(
        color: palette.panel,
        borderRadius: BorderRadius.circular(22),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            TabBar(
              tabs: [
                Tab(text: 'Главы · ${controller.tracks.length}'),
                const Tab(text: 'Закладки'),
                const Tab(text: 'Перемотки'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _chapterList(palette),
                  Column(
                    children: [
                      Expanded(
                        child: _rows(
                          palette,
                          bookmarkRows,
                          'Закладок пока нет',
                          (row) => ListTile(
                            dense: true,
                            leading: Icon(
                              Icons.bookmark_outline,
                              color: palette.accent,
                            ),
                            title: Text(row.payload!['title'] as String),
                            trailing: Text(
                              audioTime(
                                Duration(
                                  milliseconds:
                                      row.payload!['positionMs'] as int,
                                ),
                              ),
                            ),
                            onTap: () => controller.goToLocation(
                              row.payload!['trackId'] as String,
                              row.payload!['positionMs'] as int,
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: TextButton.icon(
                          onPressed: () async {
                            await _showBookmarks();
                            _refreshPanel();
                          },
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          label: const Text('Изменить закладки'),
                        ),
                      ),
                    ],
                  ),
                  Column(
                    children: [
                      Expanded(
                        child: _rows(
                          palette,
                          seekRows,
                          'Перемоток пока нет',
                          (row) => ListTile(
                            dense: true,
                            leading: const Icon(Icons.undo),
                            title: Text(
                              '${audioTime(Duration(milliseconds: row.payload!['fromMs'] as int))} → ${audioTime(Duration(milliseconds: row.payload!['positionMs'] as int))}',
                            ),
                            subtitle: Text('${row.payload!['reason']}'),
                            onTap: () => controller.goToLocation(
                              row.payload!['fromTrackId'] as String,
                              row.payload!['fromMs'] as int,
                              reason: 'history',
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: TextButton.icon(
                          onPressed: _refreshPanel,
                          icon: const Icon(Icons.refresh, size: 18),
                          label: const Text('Обновить'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final palette = ShelfPalette.of(context);
      final maxTrack = controller.duration.inMilliseconds
          .toDouble()
          .clamp(1.0, double.infinity)
          .toDouble();
      final actions = [
        IconButton(
          tooltip: 'Заметки к книге',
          icon: const Icon(Icons.edit_note),
          onPressed: controller.current == null
              ? null
              : () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AudioNotesPage(
                      controller: controller,
                      bookId: controller.current!.bookId,
                    ),
                  ),
                ),
        ),
        IconButton(
          tooltip: 'Статистика',
          icon: const Icon(Icons.bar_chart),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => AudioStatisticsPage(
                repository: controller.assets.repository,
                controller: controller,
                initialBookId: controller.current?.bookId,
                returnToPlayer: true,
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Настройки плеера',
          onPressed: _showTools,
          icon: const Icon(Icons.more_vert),
        ),
      ];
      return PepeSubpage(
        title: 'Сейчас играет',
        back: 'Аудиокниги',
        section: PepeSection.audio,
        actions: actions,
        maxWidth: 1400,
        body: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 860;
            if (!wide) {
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  _cover(
                    palette,
                    (constraints.maxHeight * .42).clamp(180.0, 420.0),
                  ),
                  const SizedBox(height: 16),
                  _heading(palette, wide: false),
                  const SizedBox(height: 4),
                  _progress(palette, maxTrack),
                  _controls(palette, wide: false),
                  const SizedBox(height: 10),
                  _chips(palette),
                  const SizedBox(height: 12),
                  _bookProgress(palette),
                  const SizedBox(height: 6),
                  Center(
                    child: TextButton.icon(
                      onPressed: _showChapters,
                      icon: const Icon(Icons.list_alt),
                      label: Text('Главы (${controller.tracks.length})'),
                    ),
                  ),
                  ..._notices(palette),
                ],
              );
            }
            return Padding(
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 24),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 6,
                    child: ListView(
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _cover(
                              palette,
                              (constraints.maxHeight * .55).clamp(240.0, 420.0),
                            ),
                            const SizedBox(width: 28),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const SizedBox(height: 8),
                                  _heading(palette, wide: true),
                                  const SizedBox(height: 18),
                                  _bookProgress(palette),
                                  const SizedBox(height: 14),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: _chips(palette),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 18),
                        _progress(palette, maxTrack),
                        _controls(palette, wide: true),
                        const SizedBox(height: 10),
                        ..._notices(palette),
                      ],
                    ),
                  ),
                  const SizedBox(width: 24),
                  SizedBox(width: 380, child: _panel(palette)),
                ],
              ),
            );
          },
        ),
      );
    },
  );
}
