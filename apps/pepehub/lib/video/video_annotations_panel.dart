import 'package:flutter/material.dart';

import 'models.dart';
import 'video_annotations.dart';
import 'video_repository.dart';
import 'video_tools.dart';

class VideoAnnotationsPanel extends StatefulWidget {
  final VideoRepository repository;
  final VideoLesson lesson;
  final int refresh;
  final Future<void> Function(VideoAnnotation) onEdit, onSeek, onRepeat;
  const VideoAnnotationsPanel({
    super.key,
    required this.repository,
    required this.lesson,
    required this.onEdit,
    required this.onSeek,
    required this.onRepeat,
    this.refresh = 0,
  });
  @override
  State<VideoAnnotationsPanel> createState() => _VideoAnnotationsPanelState();
}

class _VideoAnnotationsPanelState extends State<VideoAnnotationsPanel> {
  List<VideoAnnotation> annotations = [];
  String query = '';
  String? error;
  bool loading = true;
  final Set<String> busy = {};
  int _request = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(VideoAnnotationsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lesson.id != widget.lesson.id ||
        oldWidget.lesson.mediaVersion != widget.lesson.mediaVersion ||
        oldWidget.refresh != widget.refresh) {
      if (oldWidget.lesson.id != widget.lesson.id ||
          oldWidget.lesson.mediaVersion != widget.lesson.mediaVersion) {
        annotations = [];
        loading = true;
        error = null;
      }
      _load();
    }
  }

  Future<void> _load() async {
    final request = ++_request;
    try {
      final entries = await widget.repository.annotations(widget.lesson);
      if (mounted && request == _request) {
        setState(() {
          annotations = entries;
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

  Future<void> _delete(VideoAnnotation annotation) async {
    if (busy.contains(annotation.id)) return;
    final lesson = widget.lesson;
    setState(() => busy.add(annotation.id));
    try {
      final deletion = await widget.repository.deleteAnnotation(
        lesson,
        annotation,
      );
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Заметка удалена'),
          action: SnackBarAction(
            label: 'Отменить',
            onPressed: () async {
              try {
                await widget.repository.restoreAnnotation(lesson, deletion);
                await _load();
              } catch (e) {
                if (mounted) setState(() => error = '$e');
              }
            },
          ),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy.remove(annotation.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = annotations.where(
      (a) =>
          '${a.title}\n${a.body}'.toLowerCase().contains(query.toLowerCase()),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Закладки и заметки',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 8),
        if (annotations.isNotEmpty)
          TextField(
            key: const ValueKey('video-annotation-search'),
            decoration: const InputDecoration(
              labelText: 'Поиск по заметкам',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (value) => setState(() => query = value),
          ),
        if (loading) const LinearProgressIndicator(),
        if (error != null)
          Row(
            children: [
              Expanded(
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
              TextButton(onPressed: _load, child: const Text('Обновить')),
            ],
          ),
        if (!loading && annotations.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Сохраните время или диапазон кнопкой закладки. Здесь можно хранить объяснения, вопросы и трудные фразы.',
            ),
          ),
        if (!loading && annotations.isNotEmpty && filtered.isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Ничего не найдено'),
          ),
        for (final annotation in filtered)
          ListTile(
            key: ValueKey('video-annotation:${annotation.id}'),
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              annotation.body.isEmpty ? Icons.bookmark_outline : Icons.notes,
            ),
            title: Text(annotation.title),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${videoTimestamp(annotation.startMs, precise: true)}${annotation.endMs == null ? '' : ' — ${videoTimestamp(annotation.endMs!, precise: true)}'}',
                ),
                if (annotation.body.isNotEmpty)
                  Text(
                    annotation.body,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
            onTap: () => widget.onSeek(annotation),
            trailing: PopupMenuButton<String>(
              tooltip: 'Действия с заметкой',
              enabled: !busy.contains(annotation.id),
              onSelected: (action) async {
                switch (action) {
                  case 'edit':
                    await widget.onEdit(annotation);
                  case 'repeat':
                    await widget.onRepeat(annotation);
                  case 'delete':
                    await _delete(annotation);
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'edit', child: Text('Изменить')),
                if (annotation.endMs != null &&
                    annotation.endMs! - annotation.startMs >= 500)
                  const PopupMenuItem(
                    value: 'repeat',
                    child: Text('Повторить фрагмент'),
                  ),
                const PopupMenuItem(value: 'delete', child: Text('Удалить')),
              ],
            ),
          ),
      ],
    );
  }
}
