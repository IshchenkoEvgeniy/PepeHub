import 'package:flutter/material.dart';

import '../audio/audio_resume.dart';

String audioSeekReasonLabel(Object? reason) => switch (reason) {
  'sleep_rewind' => 'Возврат после таймера',
  'resume_rewind' => 'Возврат после паузы',
  'sleep_boundary' => 'Остановка в конце главы',
  'rewind' => 'Назад',
  'forward' => 'Вперёд',
  'book_timeline' => 'Переход по книге',
  'chapter' => 'Переход к главе',
  'bookmark' => 'Переход к закладке',
  'history' => 'Возврат из истории',
  _ => 'Перемотка',
};

class AudioRewindOptions extends StatelessWidget {
  final bool sleepEnabled;
  final int sleepSeconds;
  final AudioRewindSettings settings;
  final ValueChanged<bool> onSleepEnabled;
  final ValueChanged<int> onSleepSeconds;
  final ValueChanged<AudioRewindSettings> onSettings;
  final bool resumeAfterInterruption;
  final ValueChanged<bool>? onResumeAfterInterruption;
  const AudioRewindOptions({
    super.key,
    required this.sleepEnabled,
    required this.sleepSeconds,
    required this.settings,
    required this.onSleepEnabled,
    required this.onSleepSeconds,
    required this.onSettings,
    this.resumeAfterInterruption = false,
    this.onResumeAfterInterruption,
  });
  Widget seconds(
    String title,
    int value,
    ValueChanged<int> changed, {
    bool zero = true,
  }) {
    final choices = {
      if (zero) 0,
      3,
      5,
      10,
      15,
      30,
      45,
      60,
      120,
      300,
      value,
    }.toList()..sort();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      trailing: DropdownButton<int>(
        value: value,
        items: choices
            .map(
              (n) => DropdownMenuItem(
                value: n,
                child: Text(n == 0 ? 'Нет' : '$n с'),
              ),
            )
            .toList(),
        onChanged: (n) {
          if (n != null) changed(n);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Возврат после таймера'),
        subtitle: const Text(
          'Один раз перед следующим запуском, в том числе после закрытия приложения',
        ),
        value: sleepEnabled,
        onChanged: onSleepEnabled,
      ),
      if (sleepEnabled)
        seconds('После таймера', sleepSeconds, onSleepSeconds, zero: false),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Умный возврат после паузы'),
        subtitle: const Text(
          'Пауза до 5 секунд — без возврата. Ручная перемотка отменяет автовозврат.',
        ),
        value: settings.enabled,
        onChanged: (v) => onSettings(settings.copyWith(enabled: v)),
      ),
      if (settings.enabled) ...[
        seconds(
          'Пауза 5 с – 1 мин',
          settings.shortSeconds,
          (v) => onSettings(settings.copyWith(shortSeconds: v)),
        ),
        seconds(
          'Пауза 1 мин – 1 ч',
          settings.mediumSeconds,
          (v) => onSettings(settings.copyWith(mediumSeconds: v)),
        ),
        seconds(
          'Пауза от 1 часа',
          settings.longSeconds,
          (v) => onSettings(settings.copyWith(longSeconds: v)),
        ),
      ],
      if (onResumeAfterInterruption != null)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Продолжать после звонка'),
          subtitle: const Text(
            'Только если книга звучала до прерывания. Ручная пауза, наушники и таймер отменяют продолжение.',
          ),
          value: resumeAfterInterruption,
          onChanged: onResumeAfterInterruption,
        ),
    ],
  );
}
