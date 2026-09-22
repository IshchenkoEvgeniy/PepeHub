import 'audio_statistics_page.dart';
import 'audio_notes_page.dart';

import 'dart:io';

import 'package:flutter/material.dart';

import '../media/audio_controller.dart';

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

  Widget _skip(int seconds) => Expanded(
    child: TextButton(
      onPressed: controller.canPlay
          ? () => controller.skipSeconds(seconds)
          : null,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            seconds < 0
                ? Icons.fast_rewind_rounded
                : Icons.fast_forward_rounded,
            size: seconds.abs() == 60 ? 36 : 30,
          ),
          Text(
            '${seconds < 0 ? '−' : '+'}${seconds.abs() == 60 ? '1 мин' : '10 с'}',
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      final maxTrack = controller.duration.inMilliseconds
          .toDouble()
          .clamp(1.0, double.infinity)
          .toDouble();
      return Scaffold(
        appBar: AppBar(
          title: const Text('Аудиокнига'),
          actions: [
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
          ],
        ),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        IconButton(
                          tooltip: 'Таймер сна',
                          onPressed: _showTools,
                          icon: Icon(
                            controller.sleepMode == 'off'
                                ? Icons.bedtime_outlined
                                : Icons.bedtime,
                          ),
                        ),
                        TextButton(
                          onPressed: _showTools,
                          child: Text('${controller.speed}×'),
                        ),
                        IconButton(
                          tooltip: 'Добавить закладку',
                          onPressed: controller.canPlay ? _addBookmark : null,
                          icon: const Icon(Icons.bookmark_add_outlined),
                        ),
                        IconButton(
                          tooltip: 'Мои закладки',
                          onPressed: _showBookmarks,
                          icon: const Icon(Icons.bookmarks_outlined),
                        ),
                        IconButton(
                          tooltip: 'Перемотки',
                          onPressed: _showHistory,
                          icon: const Icon(Icons.history),
                        ),
                      ],
                    ),
                    Text(
                      controller.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    if (controller.bookFraction != null) ...[
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 5,
                          ),
                        ),
                        child: Slider(
                          semanticFormatterCallback: (v) =>
                              'Позиция в книге ${v.round()} процентов',
                          value:
                              bookDragPosition ??
                              controller.bookFraction! * 100,
                          max: 100,
                          onChanged: controller.canPlay
                              ? (v) => setState(() => bookDragPosition = v)
                              : null,
                          onChangeEnd: (v) async {
                            await controller.seekBook(
                              Duration(
                                milliseconds:
                                    (controller.bookDuration!.inMilliseconds *
                                            v /
                                            100)
                                        .round(),
                              ),
                            );
                            if (mounted) {
                              setState(() => bookDragPosition = null);
                            }
                          },
                        ),
                      ),
                      Text(
                        '${audioTime(controller.bookPosition!)} из ${audioTime(controller.bookDuration!)} · ${(controller.bookFraction! * 100).toStringAsFixed(1)}%',
                        textAlign: TextAlign.center,
                      ),
                      Text(
                        'Осталось ${audioTime(controller.remainingAtSpeed!)} на ${controller.speed}×',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: colors.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ] else ...[
                      Text(
                        'Длительности: ${controller.knownDurations} из ${controller.tracks.length}',
                        textAlign: TextAlign.center,
                      ),
                      if (controller.scanningDurations)
                        const LinearProgressIndicator()
                      else
                        TextButton(
                          onPressed: controller.scanDurations,
                          child: const Text('Определить длительности'),
                        ),
                      if (controller.durationError.isNotEmpty)
                        Text(controller.durationError),
                    ],
                    const SizedBox(height: 12),
                    SizedBox(
                      height: (constraints.maxHeight * .43).clamp(180.0, 440.0),
                      child: Center(
                        child: AspectRatio(
                          aspectRatio: .72,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: ColoredBox(
                                  color: colors.surfaceContainerHighest,
                                  child: controller.artwork != null
                                      ? Image.file(
                                          File.fromUri(controller.artwork!),
                                          fit: BoxFit.contain,
                                          errorBuilder: (_, error, stack) =>
                                              Icon(
                                                Icons.headphones,
                                                size: 90,
                                                color: colors.primary,
                                              ),
                                        )
                                      : Icon(
                                          Icons.headphones_rounded,
                                          size: 90,
                                          color: colors.primary,
                                        ),
                                ),
                              ),
                              Center(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: colors.surface.withValues(alpha: .9),
                                    shape: BoxShape.circle,
                                    boxShadow: const [
                                      BoxShadow(
                                        blurRadius: 18,
                                        color: Colors.black26,
                                      ),
                                    ],
                                  ),
                                  child: IconButton(
                                    key: const ValueKey('cover-play'),
                                    padding: const EdgeInsets.all(12),
                                    iconSize: 48,
                                    tooltip: controller.playing
                                        ? 'Пауза'
                                        : 'Воспроизвести',
                                    onPressed: !controller.canPlay
                                        ? null
                                        : controller.playing
                                        ? controller.pause
                                        : controller.play,
                                    icon: Icon(
                                      controller.playing
                                          ? Icons.pause_rounded
                                          : Icons.play_arrow_rounded,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        IconButton(
                          tooltip: 'Предыдущая глава',
                          onPressed:
                              controller.canPlay && controller.trackIndex > 0
                              ? controller.skipToPrevious
                              : null,
                          icon: const Icon(Icons.skip_previous_rounded),
                        ),
                        Expanded(
                          child: TextButton(
                            onPressed: controller.canPlay ? _showTracks : null,
                            child: Text(
                              'Глава ${controller.trackIndex + 1} из ${controller.tracks.length}\n${controller.current?.filename ?? ''}',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Следующая глава',
                          onPressed:
                              controller.canPlay &&
                                  controller.trackIndex <
                                      controller.tracks.length - 1
                              ? controller.skipToNext
                              : null,
                          icon: const Icon(Icons.skip_next_rounded),
                        ),
                      ],
                    ),
                    if (controller.loading) const LinearProgressIndicator(),
                    Slider(
                      value:
                          (dragPosition ??
                                  controller.position.inMilliseconds.toDouble())
                              .clamp(0, maxTrack),
                      max: maxTrack,
                      onChanged:
                          controller.canPlay &&
                              controller.duration > Duration.zero
                          ? (v) => setState(() => dragPosition = v)
                          : null,
                      onChangeEnd: (v) async {
                        await controller.seek(
                          Duration(milliseconds: v.round()),
                        );
                        if (mounted) setState(() => dragPosition = null);
                      },
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(audioTime(controller.position)),
                        Text(
                          '−${audioTime(Duration(milliseconds: (controller.duration - controller.position).inMilliseconds.clamp(0, 1 << 53)))}',
                        ),
                      ],
                    ),
                    Row(
                      children: [_skip(-60), _skip(-10), _skip(10), _skip(60)],
                    ),
                    TextButton.icon(
                      onPressed: _showChapters,
                      icon: const Icon(Icons.list_alt),
                      label: Text('Главы (${controller.tracks.length})'),
                    ),
                    if (controller.sleepMode != 'off')
                      TextButton.icon(
                        onPressed: _showTools,
                        icon: const Icon(Icons.bedtime_outlined),
                        label: Text(
                          controller.sleepUntil == null
                              ? 'Сон: до конца ${controller.sleepMode == 'chapter' ? 'главы' : 'трека'}'
                              : 'Сон в ${TimeOfDay.fromDateTime(controller.sleepUntil!).format(context)}',
                        ),
                      ),
                    if (controller.sidecarError.isNotEmpty)
                      Text(controller.sidecarError),
                    if (controller.error.isNotEmpty)
                      Text(
                        controller.error,
                        style: TextStyle(color: colors.error),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
