import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../diagnostics/user_message.dart';
import '../ui/pepe_widgets.dart';
import 'models.dart';
import 'video_covers.dart';
import 'video_discovery_page.dart' show videoBytes;
import 'video_import.dart' show videoFilesChannel;
import 'video_repository.dart';
import 'video_session.dart';

/// Deletes media files from the device. Replaceable in tests.
abstract class VideoFileDeleter {
  /// [sources] are lesson sources. Links are never deleted.
  Future<({Set<String> deleted, Set<String> failed})> delete(
    List<String> sources,
  );
}

class PlatformVideoFileDeleter implements VideoFileDeleter {
  const PlatformVideoFileDeleter();

  @override
  Future<({Set<String> deleted, Set<String> failed})> delete(
    List<String> sources,
  ) async {
    final local = [
      for (final source in sources)
        if (!source.startsWith('http://') && !source.startsWith('https://'))
          source,
    ];
    final failed = {
      for (final source in sources)
        if (!local.contains(source)) source,
    };
    if (local.isEmpty) return (deleted: <String>{}, failed: failed);
    if (Platform.isAndroid) {
      // Android asks the user to confirm deleting files of other apps.
      final result = await videoFilesChannel.invokeMapMethod<String, dynamic>(
        'deleteFiles',
        {'uris': local},
      );
      return (
        deleted: {for (final s in result?['deleted'] as List? ?? []) '$s'},
        failed: {
          ...failed,
          for (final s in result?['failed'] as List? ?? local) '$s',
        },
      );
    }
    final deleted = <String>{};
    for (final source in local) {
      try {
        if (!p.isAbsolute(source)) {
          failed.add(source);
          continue;
        }
        final file = File(source);
        if (await file.exists()) await file.delete();
        deleted.add(source);
      } catch (_) {
        failed.add(source);
      }
    }
    return (deleted: deleted, failed: failed);
  }
}

/// A title for a video, course or file.
Future<String?> askMediaTitle(
  BuildContext context, {
  required String title,
  required String initial,
}) => showDialog<String>(
  context: context,
  builder: (_) => _TitleDialog(title: title, initial: initial),
);

class _TitleDialog extends StatefulWidget {
  final String title, initial;
  const _TitleDialog({required this.title, required this.initial});
  @override
  State<_TitleDialog> createState() => _TitleDialogState();
}

class _TitleDialogState extends State<_TitleDialog> {
  late final controller = TextEditingController(text: widget.initial)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initial.length,
    );
  String? error;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _save() {
    final value = controller.text.trim();
    if (value.isEmpty) {
      setState(() => error = 'Введите название');
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      key: const ValueKey('media-title-field'),
      controller: controller,
      autofocus: true,
      maxLength: 300,
      decoration: InputDecoration(labelText: 'Название', errorText: error),
      onSubmitted: (_) => _save(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(onPressed: _save, child: const Text('Сохранить')),
    ],
  );
}

/// Path, size, duration and progress of a video, course or file.
Future<void> showMediaDetails(
  BuildContext context,
  VideoRepository repository, {
  required String title,
  required List<VideoLesson> lessons,
  Map<String, VideoProgress> progress = const {},
}) async {
  var size = 0, sized = 0;
  String? location;
  // Facts of up to 500 files: enough for a course, light for a big one.
  for (final lesson in lessons.take(500)) {
    final details = await repository.lessonDetails(lesson.id);
    final bytes = details?['fileSize'] ?? details?['fileIdentity']?['size'];
    if (bytes is int && bytes > 0) {
      size += bytes;
      sized++;
    }
    location ??= details?['relativeName'] as String?;
  }
  if (!context.mounted) return;
  final duration = lessons.fold<int>(0, (sum, l) => sum + (l.durationMs ?? 0));
  final watched = lessons.where((lesson) {
    final saved = progress[lesson.id];
    return saved != null && saved.mediaVersion == lesson.mediaVersion;
  }).length;
  final single = lessons.length == 1 ? lessons.single : null;
  final rows = <(String, String)>[
    ('Файлов', '${lessons.length}'),
    if (duration > 0)
      (
        'Длительность',
        pepeTime(duration) +
            (lessons.any((l) => l.durationMs == null)
                ? ' (известна не для всех)'
                : ''),
      ),
    if (sized > 0)
      (
        'Размер',
        videoBytes(size) +
            (sized < lessons.length ? ' (известен не для всех)' : ''),
      ),
    if (single != null &&
        progress[single.id]?.mediaVersion == single.mediaVersion)
      ('Позиция', pepeTime(progress[single.id]!.positionMs))
    else if (lessons.length > 1)
      ('Начато', '$watched из ${lessons.length}'),
    if (location != null)
      (
        lessons.length == 1 ? 'Путь' : 'Папка',
        lessons.length == 1
            ? location
            : p.posix.dirname(location.replaceAll('\\', '/')),
      ),
    if (single != null) ('Источник', single.source),
  ];
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      scrollable: true,
      title: Text(title),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Theme.of(context).textTheme.labelMedium),
                  SelectableText(value),
                ],
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
      ],
    ),
  );
}

/// Marks files as watched or clears the mark. Returns how many changed.
Future<int> setLessonsWatched(
  VideoRepository repository,
  Iterable<VideoLesson> lessons,
  bool watched,
) async {
  var changed = 0;
  for (final lesson in lessons) {
    if (lesson.isAudio) continue;
    await repository.setLearningState(lesson, manualComplete: watched);
    changed++;
  }
  return changed;
}

/// Removes items and files from the media library and offers «Вернуть».
Future<bool> removeFromMediaLibrary(
  BuildContext context,
  VideoRepository repository, {
  List<VideoItem> items = const [],
  List<VideoLesson> lessons = const [],
  required String what,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      scrollable: true,
      title: Text('Убрать $what из медиатеки?'),
      content: const Text(
        'Файлы на устройстве останутся на месте — PepeHub просто перестанет '
        'их показывать. Прогресс и заметки сохранятся, если добавить файлы '
        'снова.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Убрать из медиатеки'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return false;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await _closeSession(context, {
      for (final item in items) item.id,
      for (final lesson in lessons) lesson.itemId,
    });
    final removedLessons = <String>[], removedItems = <String>[];
    for (final item in items) {
      removedLessons.addAll(await repository.removeItem(item.id));
      removedItems.add(item.id);
    }
    final removal = await repository.removeLessons([
      for (final lesson in lessons) lesson.id,
    ]);
    final all = VideoRemoval(
      [...removedLessons, ...removal.lessons],
      [...removedItems, ...removal.items],
    );
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          persist: false,
          content: Text('Убрано из медиатеки: $what'),
          action: SnackBarAction(
            label: 'Вернуть',
            onPressed: () => repository
                .restoreRemoval(all)
                .then((_) => repository.repository.notifyExternalChange()),
          ),
        ),
      );
    return true;
  } catch (e) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(describeError(e))));
    return false;
  }
}

/// Deletes the files from the device after a confirmation, then removes
/// them from the media library. Returns how many files were deleted.
Future<int> deleteMediaFiles(
  BuildContext context,
  VideoRepository repository,
  List<VideoLesson> lessons, {
  required String what,
  VideoFileDeleter deleter = const PlatformVideoFileDeleter(),
}) async {
  final local = [
    for (final lesson in lessons)
      if (!lesson.isRemote) lesson,
  ];
  final messenger = ScaffoldMessenger.of(context);
  if (local.isEmpty) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(content: Text('Ссылки нельзя удалить с устройства')),
      );
    return 0;
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      scrollable: true,
      icon: const Icon(Icons.delete_forever_outlined),
      title: Text('Удалить $what с устройства?'),
      content: Text(
        'Файлов: ${local.length}. Они будут удалены с устройства, '
        'вернуть их из PepeHub будет нельзя. '
        '${Platform.isAndroid ? 'Android может попросить подтверждение. ' : ''}'
        'Прогресс и заметки останутся в статистике.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Отмена'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Удалить файлы'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return 0;
  try {
    // The player must let go of a file before it can be deleted.
    await _closeSession(context, {for (final l in local) l.itemId});
    final result = await deleter.delete([for (final l in local) l.source]);
    final gone = [
      for (final lesson in local)
        if (result.deleted.contains(lesson.source)) lesson.id,
    ];
    if (gone.isNotEmpty) await repository.removeLessons(gone, trash: false);
    final failed = local.length - gone.length;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            [
              if (gone.isNotEmpty) 'Удалено файлов: ${gone.length}',
              if (failed > 0)
                'не удалось удалить: $failed${Platform.isAndroid ? ' (нет доступа или отменено)' : ''}',
            ].join(', '),
          ),
        ),
      );
    return gone.length;
  } catch (e) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(describeError(e))));
    return 0;
  }
}

Future<void> _closeSession(BuildContext context, Set<String> itemIds) async {
  final session = VideoSessionScope.read(context);
  if (session?.item != null && itemIds.contains(session!.item!.id)) {
    await session.close();
  }
}

/// «1 видео», «3 видео», «2 курса»… for confirmations and messages.
String mediaCount(int count, {required bool music, bool courses = false}) {
  if (count == 1) {
    return courses ? (music ? 'плейлист' : 'курс') : (music ? 'трек' : 'видео');
  }
  final ten = count % 100, one = count % 10;
  String form(String a, String b, String c) => ten >= 11 && ten <= 14
      ? c
      : one == 1
      ? a
      : one >= 2 && one <= 4
      ? b
      : c;
  if (courses) {
    return music
        ? '$count ${form('плейлист', 'плейлиста', 'плейлистов')}'
        : '$count ${form('курс', 'курса', 'курсов')}';
  }
  return music ? '$count ${form('трек', 'трека', 'треков')}' : '$count видео';
}

/// «м:сс» for the skip dialog.
String skipTimeText(int ms) {
  final seconds = ms ~/ 1000;
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// Parses «85», «1:25» or «1:25.5»; null for anything else.
int? parseSkipTime(String text) {
  final clean = text.trim().replaceAll(',', '.');
  if (clean.isEmpty) return 0;
  final parts = clean.split(':');
  if (parts.length > 2) return null;
  final seconds = double.tryParse(parts.last);
  final minutes = parts.length == 2 ? int.tryParse(parts.first) : 0;
  if (seconds == null || minutes == null || seconds < 0 || minutes < 0) {
    return null;
  }
  if (parts.length == 2 && seconds >= 60) return null;
  return ((minutes * 60 + seconds) * 1000).round();
}

/// Asks how much of the beginning and the end of every file to skip.
/// [positionMs] and [durationMs] offer «take the current moment».
Future<({int introMs, int outroMs})?> askSkipSettings(
  BuildContext context, {
  required int introMs,
  required int outroMs,
  int? positionMs,
  int? durationMs,
}) => showDialog<({int introMs, int outroMs})>(
  context: context,
  builder: (_) => _SkipDialog(
    introMs: introMs,
    outroMs: outroMs,
    positionMs: positionMs,
    durationMs: durationMs,
  ),
);

class _SkipDialog extends StatefulWidget {
  final int introMs, outroMs;
  final int? positionMs, durationMs;
  const _SkipDialog({
    required this.introMs,
    required this.outroMs,
    this.positionMs,
    this.durationMs,
  });

  @override
  State<_SkipDialog> createState() => _SkipDialogState();
}

class _SkipDialogState extends State<_SkipDialog> {
  late final intro = TextEditingController(
    text: widget.introMs == 0 ? '' : skipTimeText(widget.introMs),
  );
  late final outro = TextEditingController(
    text: widget.outroMs == 0 ? '' : skipTimeText(widget.outroMs),
  );
  String? error;

  @override
  void dispose() {
    intro.dispose();
    outro.dispose();
    super.dispose();
  }

  void _save() {
    final start = parseSkipTime(intro.text), end = parseSkipTime(outro.text);
    if (start == null || end == null) {
      setState(() => error = 'Введите время как 85 или 1:25');
      return;
    }
    if (start > 30 * 60000 || end > 30 * 60000) {
      setState(() => error = 'Не больше 30 минут');
      return;
    }
    Navigator.pop(context, (introMs: start, outroMs: end));
  }

  @override
  Widget build(BuildContext context) {
    final position = widget.positionMs, duration = widget.durationMs;
    Widget field(
      TextEditingController controller,
      String label,
      String key,
      String? nowLabel,
      int? nowValue,
    ) => Row(
      children: [
        Expanded(
          child: TextField(
            key: ValueKey(key),
            controller: controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: label, hintText: '0:00'),
            onSubmitted: (_) => _save(),
          ),
        ),
        if (nowLabel != null && nowValue != null) ...[
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => setState(() {
              controller.text = skipTimeText(nowValue);
              error = null;
            }),
            child: Text(nowLabel),
          ),
        ],
      ],
    );
    return AlertDialog(
      scrollable: true,
      title: const Text('Пропуск заставки'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Действует для всех видео курса. Начало пропускается, если '
              'видео открыто с начала; на титрах в конце видео отмечается '
              'просмотренным и начинается следующее.',
            ),
            const SizedBox(height: 12),
            field(
              intro,
              'Пропускать в начале',
              'skip-intro',
              'Сейчас',
              position != null && position > 0 ? position : null,
            ),
            field(
              outro,
              'Пропускать в конце',
              'skip-outro',
              'Отсюда',
              position != null && duration != null && duration > position
                  ? duration - position
                  : null,
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, (introMs: 0, outroMs: 0)),
          child: const Text('Не пропускать'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(onPressed: _save, child: const Text('Сохранить')),
      ],
    );
  }
}

/// Own cover of a video or course: a picture from files, or back to a
/// frame of the video. Returns true when the cover changed.
Future<bool> chooseMediaCover(
  BuildContext context,
  VideoRepository repository,
  VideoItem item, {
  VideoCovers? covers,
}) async {
  final store = covers ?? VideoCovers.instance;
  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.image_outlined),
            title: const Text('Выбрать картинку…'),
            onTap: () => Navigator.pop(sheet, 'pick'),
          ),
          if (item.cover != null)
            ListTile(
              leading: const Icon(Icons.hide_image_outlined),
              title: const Text('Вернуть кадр из видео'),
              onTap: () => Navigator.pop(sheet, 'reset'),
            ),
          const ListTile(
            enabled: false,
            leading: Icon(Icons.photo_camera_outlined),
            title: Text('Кадр из видео'),
            subtitle: Text(
              'Откройте видео на нужном моменте и выберите в инструментах '
              'плеера «Сделать обложкой».',
            ),
          ),
        ],
      ),
    ),
  );
  if (action == null || !context.mounted) return false;
  final messenger = ScaffoldMessenger.of(context);
  try {
    String? name;
    if (action == 'pick') {
      final bytes = await VideoCovers.choose();
      if (bytes == null) return false;
      name = await store.save(bytes);
    }
    final old = await repository.setCover(item.id, name);
    if (old != null && old != name) await store.discard(old);
    return true;
  } catch (e) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(describeError(e))));
    return false;
  }
}
