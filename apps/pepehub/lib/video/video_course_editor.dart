import 'package:flutter/material.dart';

import 'models.dart';
import 'video_repository.dart';
import 'video_session.dart';

class VideoCourseEditor extends StatefulWidget {
  final VideoRepository repository;
  final VideoItem item;
  final List<VideoLesson> lessons;
  const VideoCourseEditor({
    super.key,
    required this.repository,
    required this.item,
    required this.lessons,
  });
  @override
  State<VideoCourseEditor> createState() => _VideoCourseEditorState();
}

class _VideoCourseEditorState extends State<VideoCourseEditor> {
  late final title = TextEditingController(text: widget.item.title);
  late final token = VideoRepository.structureToken(
    widget.item,
    widget.lessons,
  );
  late final ordered = [
    for (final lesson in widget.lessons)
      VideoLessonEdit(lesson.id, lesson.title, lesson.module),
  ];
  bool saving = false;
  String? error;
  @override
  void dispose() {
    title.dispose();
    super.dispose();
  }

  Future<void> editLesson(int index) async {
    final value = ordered[index];
    var name = value.title, module = value.module;
    final form = GlobalKey<FormState>();
    final edited = await showDialog<VideoLessonEdit>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Редактировать урок'),
        content: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  key: const ValueKey('video-edit-lesson-title'),
                  initialValue: name,
                  onChanged: (text) => name = text,
                  maxLength: 300,
                  decoration: const InputDecoration(
                    labelText: 'Название урока',
                  ),
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ? 'Введите название' : null,
                ),
                TextFormField(
                  key: const ValueKey('video-edit-lesson-module'),
                  initialValue: module,
                  onChanged: (text) => module = text,
                  maxLength: 300,
                  decoration: const InputDecoration(
                    labelText: 'Модуль (необязательно)',
                  ),
                ),
              ],
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
                  VideoLessonEdit(value.id, name.trim(), module.trim()),
                );
              }
            },
            child: const Text('Готово'),
          ),
        ],
      ),
    );
    if (edited != null && mounted) setState(() => ordered[index] = edited);
  }

  Future<void> save() async {
    if (saving) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final session = VideoSessionScope.read(context);
      if (session?.item?.id == widget.item.id) await session!.close();
      await widget.repository.saveCourseStructure(
        widget.item,
        title: title.text,
        token: token,
        ordered: ordered,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          saving = false;
          error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Структура курса'),
        actions: [
          TextButton(
            onPressed: saving ? null : save,
            child: const Text('Сохранить'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              key: const ValueKey('video-edit-course-title'),
              controller: title,
              enabled: !saving,
              maxLength: 300,
              decoration: const InputDecoration(labelText: 'Название курса'),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Перетаскивайте уроки за ручку. Нажмите на урок, чтобы изменить название или модуль. Позиции и история сохранятся.',
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (saving) const LinearProgressIndicator(),
          Expanded(
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              itemCount: ordered.length,
              onReorderItem: (oldIndex, newIndex) {
                if (saving) return;
                setState(() {
                  ordered.insert(newIndex, ordered.removeAt(oldIndex));
                });
              },
              itemBuilder: (context, index) => ListTile(
                key: ValueKey(ordered[index].id),
                leading: Text('${index + 1}'),
                title: Text(ordered[index].title),
                subtitle: ordered[index].module.isEmpty
                    ? null
                    : Text(ordered[index].module),
                onTap: saving ? null : () => editLesson(index),
                trailing: saving
                    ? null
                    : ReorderableDragStartListener(
                        index: index,
                        child: const Padding(
                          padding: EdgeInsets.all(12),
                          child: Icon(Icons.drag_handle),
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
