import 'package:flutter/material.dart';

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
