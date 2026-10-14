import 'package:flutter/material.dart';

import 'models.dart';
import 'video_annotations.dart';
import 'video_repository.dart';
import 'video_tools.dart';

Future<int?> showVideoSeekDialog(
  BuildContext context,
  int positionMs,
  int durationMs,
) => showDialog<int>(
  context: context,
  builder: (_) => _SeekDialog(positionMs, durationMs),
);

Future<VideoLoopSettings?> showVideoLoopDialog(
  BuildContext context, {
  required int positionMs,
  required int durationMs,
  VideoLoopSettings? settings,
  int? startMs,
  int? endMs,
}) => showDialog<VideoLoopSettings>(
  context: context,
  builder: (_) => _LoopDialog(
    positionMs: positionMs,
    durationMs: durationMs,
    settings: settings,
    startMs: startMs,
    endMs: endMs,
  ),
);

Future<VideoAnnotation?> showVideoAnnotationDialog(
  BuildContext context, {
  required VideoRepository repository,
  required VideoLesson lesson,
  required int positionMs,
  required int durationMs,
  int? endMs,
  VideoAnnotation? existing,
  String? initialTitle,
  String? initialBody,
}) => showDialog<VideoAnnotation>(
  context: context,
  builder: (_) => _AnnotationDialog(
    repository: repository,
    lesson: lesson,
    positionMs: positionMs,
    durationMs: durationMs,
    endMs: endMs,
    existing: existing,
    initialTitle: initialTitle,
    initialBody: initialBody,
  ),
);

String? _timeError(String? text, int durationMs) {
  final value = parseVideoTimestamp(text ?? '');
  if (value == null) return 'Введите секунды, мм:сс или ч:мм:сс';
  if (durationMs > 0 && value > durationMs) {
    return 'Время больше длительности видео';
  }
  return null;
}

class _SeekDialog extends StatefulWidget {
  final int positionMs, durationMs;
  const _SeekDialog(this.positionMs, this.durationMs);
  @override
  State<_SeekDialog> createState() => _SeekDialogState();
}

class _SeekDialogState extends State<_SeekDialog> {
  final form = GlobalKey<FormState>();
  late final input = TextEditingController(
    text: videoTimestamp(widget.positionMs, precise: true),
  );
  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  void submit() {
    if (form.currentState!.validate()) {
      Navigator.pop(context, parseVideoTimestamp(input.text));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Перейти ко времени'),
    content: Form(
      key: form,
      child: TextFormField(
        key: const ValueKey('video-seek-time'),
        controller: input,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Время',
          helperText: 'Секунды, мм:сс или ч:мм:сс. Миллисекунды: .123',
        ),
        validator: (value) => _timeError(value, widget.durationMs),
        onFieldSubmitted: (_) => submit(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(onPressed: submit, child: const Text('Перейти')),
    ],
  );
}

class _LoopDialog extends StatefulWidget {
  final int positionMs, durationMs;
  final VideoLoopSettings? settings;
  final int? startMs, endMs;
  const _LoopDialog({
    required this.positionMs,
    required this.durationMs,
    this.settings,
    this.startMs,
    this.endMs,
  });
  @override
  State<_LoopDialog> createState() => _LoopDialogState();
}

class _LoopDialogState extends State<_LoopDialog> {
  final form = GlobalKey<FormState>();
  late final start = TextEditingController(
    text: videoTimestamp(
      widget.startMs ??
          widget.settings?.startMs ??
          (widget.durationMs > 0
              ? widget.positionMs.clamp(
                  0,
                  (widget.durationMs - 1000).clamp(0, 1 << 53),
                )
              : widget.positionMs),
      precise: true,
    ),
  );
  late final end = TextEditingController(
    text: videoTimestamp(
      widget.endMs ??
          widget.settings?.endMs ??
          (widget.durationMs > 0
              ? (parseVideoTimestamp(start.text)! + 10000).clamp(
                  0,
                  widget.durationMs,
                )
              : parseVideoTimestamp(start.text)! + 10000),
      precise: true,
    ),
  );
  late final pause = TextEditingController(
    text: '${(widget.settings?.pauseMs ?? 0) / 1000}',
  );
  late int passes = widget.settings?.totalPasses ?? 0;
  String? error;
  @override
  void dispose() {
    start.dispose();
    end.dispose();
    pause.dispose();
    super.dispose();
  }

  void submit() {
    if (!form.currentState!.validate()) return;
    final settings = VideoLoopSettings(
      startMs: parseVideoTimestamp(start.text)!,
      endMs: parseVideoTimestamp(end.text)!,
      totalPasses: passes == 0 ? null : passes,
      pauseMs: (double.parse(pause.text.replaceAll(',', '.')) * 1000).round(),
    );
    try {
      settings.validate(durationMs: widget.durationMs);
      Navigator.pop(context, settings);
    } catch (e) {
      setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Повтор фрагмента A–B'),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Каждый проход начинается в A. После последнего прохода видео остановится в B.',
              ),
              const SizedBox(height: 16),
              TextFormField(
                key: const ValueKey('video-loop-start'),
                controller: start,
                decoration: const InputDecoration(labelText: 'A — начало'),
                validator: (value) => _timeError(value, widget.durationMs),
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('video-loop-end'),
                controller: end,
                decoration: const InputDecoration(labelText: 'B — конец'),
                validator: (value) => _timeError(value, widget.durationMs),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                isExpanded: true,
                initialValue: passes,
                decoration: const InputDecoration(labelText: 'Всего проходов'),
                items: [
                  for (final count in ({
                    0,
                    1,
                    2,
                    3,
                    5,
                    10,
                    20,
                    50,
                    100,
                    passes,
                  }.toList()..sort()))
                    DropdownMenuItem(
                      value: count,
                      child: Text(count == 0 ? 'Без ограничения' : '$count'),
                    ),
                ],
                onChanged: (value) => passes = value!,
              ),
              const SizedBox(height: 12),
              TextFormField(
                key: const ValueKey('video-loop-pause'),
                controller: pause,
                decoration: const InputDecoration(
                  labelText: 'Пауза между проходами, секунд',
                  helperText: 'От 0 до 30 секунд; для повторения вслух',
                ),
                validator: (value) {
                  final seconds = double.tryParse(
                    (value ?? '').replaceAll(',', '.'),
                  );
                  return seconds == null ||
                          !seconds.isFinite ||
                          seconds < 0 ||
                          seconds > 30
                      ? 'От 0 до 30 секунд'
                      : null;
                },
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
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
      FilledButton(onPressed: submit, child: const Text('Начать повтор')),
    ],
  );
}

class _AnnotationDialog extends StatefulWidget {
  final VideoRepository repository;
  final VideoLesson lesson;
  final int positionMs, durationMs;
  final int? endMs;
  final VideoAnnotation? existing;
  final String? initialTitle, initialBody;
  const _AnnotationDialog({
    required this.repository,
    required this.lesson,
    required this.positionMs,
    required this.durationMs,
    this.endMs,
    this.existing,
    this.initialTitle,
    this.initialBody,
  });
  @override
  State<_AnnotationDialog> createState() => _AnnotationDialogState();
}

class _AnnotationDialogState extends State<_AnnotationDialog> {
  final form = GlobalKey<FormState>();
  late final title = TextEditingController(
    text:
        widget.existing?.title ??
        widget.initialTitle ??
        'Фрагмент ${videoTimestamp(widget.positionMs)}',
  );
  late final body = TextEditingController(
    text: widget.existing?.body ?? widget.initialBody ?? '',
  );
  late final start = TextEditingController(
    text: videoTimestamp(
      widget.existing?.startMs ?? widget.positionMs,
      precise: true,
    ),
  );
  late final end = TextEditingController(
    text: (widget.existing?.endMs ?? widget.endMs) == null
        ? ''
        : videoTimestamp(
            (widget.existing?.endMs ?? widget.endMs)!,
            precise: true,
          ),
  );
  bool saving = false;
  String? error;
  @override
  void dispose() {
    title.dispose();
    body.dispose();
    start.dispose();
    end.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (saving || !form.currentState!.validate()) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final saved = await widget.repository.saveAnnotation(
        widget.lesson,
        existing: widget.existing,
        title: title.text,
        body: body.text,
        startMs: parseVideoTimestamp(start.text)!,
        endMs: end.text.trim().isEmpty ? null : parseVideoTimestamp(end.text),
        durationMs: widget.durationMs,
      );
      if (mounted) Navigator.pop(context, saved);
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
    child: AlertDialog(
      title: Text(
        widget.existing == null ? 'Закладка / заметка' : 'Изменить заметку',
      ),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  key: const ValueKey('video-annotation-title'),
                  controller: title,
                  autofocus: true,
                  enabled: !saving,
                  decoration: const InputDecoration(labelText: 'Название'),
                  validator: (value) =>
                      value == null ||
                          value.trim().isEmpty ||
                          value.trim().runes.length > 140
                      ? 'От 1 до 140 знаков'
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const ValueKey('video-annotation-start'),
                  controller: start,
                  enabled: !saving,
                  decoration: const InputDecoration(labelText: 'Начало'),
                  validator: (value) => _timeError(value, widget.durationMs),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const ValueKey('video-annotation-end'),
                  controller: end,
                  enabled: !saving,
                  decoration: const InputDecoration(
                    labelText: 'Конец фрагмента — необязательно',
                  ),
                  validator: (value) {
                    if ((value ?? '').trim().isEmpty) return null;
                    final problem = _timeError(value, widget.durationMs);
                    if (problem != null) return problem;
                    final from = parseVideoTimestamp(start.text),
                        to = parseVideoTimestamp(value!);
                    return from != null && to! <= from
                        ? 'Конец должен быть позже начала'
                        : null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const ValueKey('video-annotation-body'),
                  controller: body,
                  enabled: !saving,
                  minLines: 3,
                  maxLines: 7,
                  decoration: const InputDecoration(
                    labelText: 'Заметка — необязательно',
                    helperText: 'Без текста сохранится закладка',
                  ),
                  validator: (value) => (value?.runes.length ?? 0) > 20000
                      ? 'До 20000 знаков'
                      : null,
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: saving ? null : submit,
          child: Text(saving ? 'Сохранение…' : 'Сохранить'),
        ),
      ],
    ),
  );
}
