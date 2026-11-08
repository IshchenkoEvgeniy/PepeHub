import 'package:flutter/material.dart';

import '../audio/audio_resume.dart';
import '../audio/models.dart';
import '../media/audio_controller.dart';
import '../media/audio_player_scope.dart';
import 'audio_rewind_options.dart';
import 'settings_components.dart';

String _speedLabel(double speed) =>
    '${(speed == speed.roundToDouble() ? speed.toStringAsFixed(1) : '$speed').replaceAll('.', ',')}×';

/// Shared audiobook player options, embedded in settings.
class PlaybackSettings extends StatelessWidget {
  const PlaybackSettings({super.key});

  Widget _choice<T>(
    String title,
    String? subtitle,
    T value,
    List<T> items,
    String Function(T) label,
    ValueChanged<T> changed, {
    Key? key,
  }) => SettingsDropdownTile<T>(
    key: key,
    title: title,
    subtitle: subtitle,
    value: value,
    items: items,
    label: label,
    onChanged: changed,
  );

  Future<void> _reset(AudioController player) => player.updateSleepOptions(
    fade: true,
    rewind: true,
    rewindSeconds: 10,
    seekStepSeconds: 10,
    seekForwardSeconds: 10,
    defaultSpeed: 1,
    resume: const AudioRewindSettings(),
    resumeAfterInterruption: false,
  );

  @override
  Widget build(BuildContext context) {
    final player = AudioPlayerScope.of(context);
    if (player == null) {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsHeading('Плеер аудиокниг', ''),
          SettingsNotice(
            'Аудиоплеер недоступен. Перезапустите приложение, чтобы повторить запуск.',
          ),
        ],
      );
    }
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SettingsHeading(
            'Плеер аудиокниг',
            'Общие настройки для всех аудиокниг. Скорость открытой книги и таймер сна меняются в самом плеере.',
          ),
          if (player.error.isNotEmpty) SettingsNotice(player.error),
          const SettingsSubheading('Воспроизведение'),
          SettingsGroup(
            children: [
              _choice<double>(
                'Скорость для новых книг',
                'Книги с сохранённым прогрессом помнят свою скорость',
                audioDefaultSpeeds.contains(player.defaultSpeed)
                    ? player.defaultSpeed
                    : 1,
                audioDefaultSpeeds,
                _speedLabel,
                (v) => player.updateSleepOptions(defaultSpeed: v),
                key: const ValueKey('playback-default-speed'),
              ),
              _choice<int>(
                'Шаг назад',
                null,
                player.seekStepSeconds,
                audioSeekSteps,
                (v) => '$v с',
                (v) => player.updateSleepOptions(seekStepSeconds: v),
                key: const ValueKey('playback-seek-back'),
              ),
              _choice<int>(
                'Шаг вперёд',
                null,
                player.seekForwardSeconds,
                audioSeekSteps,
                (v) => '$v с',
                (v) => player.updateSleepOptions(seekForwardSeconds: v),
                key: const ValueKey('playback-seek-forward'),
              ),
            ],
          ),
          const SettingsSubheading('Пауза, сон и звонки'),
          SettingsGroup(
            children: [
              SwitchListTile(
                title: const Text('Плавно затихать перед сном'),
                value: player.sleepFade,
                onChanged: (v) => player.updateSleepOptions(fade: v),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: AudioRewindOptions(
                  sleepEnabled: player.sleepRewind,
                  sleepSeconds: player.sleepRewindSeconds,
                  settings: player.rewindSettings,
                  onSleepEnabled: (v) => player.updateSleepOptions(rewind: v),
                  onSleepSeconds: (v) =>
                      player.updateSleepOptions(rewindSeconds: v),
                  onSettings: (v) => player.updateSleepOptions(resume: v),
                  resumeAfterInterruption: player.resumeAfterInterruption,
                  onResumeAfterInterruption: (v) =>
                      player.updateSleepOptions(resumeAfterInterruption: v),
                ),
              ),
            ],
          ),
          SettingsResetButton(
            what: 'настройки плеера',
            onReset: () => _reset(player),
          ),
        ],
      ),
    );
  }
}

/// Standalone route for callers outside settings.
class PlaybackSettingsPage extends StatelessWidget {
  const PlaybackSettingsPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Плеер аудиокниг')),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
      children: const [PlaybackSettings()],
    ),
  );
}
