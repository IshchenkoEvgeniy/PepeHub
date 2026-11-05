import 'package:flutter/material.dart';

import '../media/audio_player_scope.dart';
import 'audio_rewind_options.dart';
import 'settings_components.dart';

class PlaybackSettingsPage extends StatelessWidget {
  const PlaybackSettingsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final player = AudioPlayerScope.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки плеера аудиокниг')),
      body: player == null
          ? const Padding(
              padding: EdgeInsets.all(20),
              child: SettingsNotice(
                'Аудиоплеер недоступен. Перезапустите приложение, чтобы повторить запуск.',
              ),
            )
          : ListenableBuilder(
              listenable: player,
              builder: (context, _) => ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  const SettingsNotice(
                    'Общие настройки для всех аудиокниг. Скорость и таймер сна доступны в открытом плеере.',
                  ),
                  if (player.error.isNotEmpty) SettingsNotice(player.error),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Плавно затихать перед сном'),
                    value: player.sleepFade,
                    onChanged: (v) => player.updateSleepOptions(fade: v),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Шаг перемотки'),
                    trailing: DropdownButton<int>(
                      value: player.seekStepSeconds,
                      items: [5, 10, 15, 30, 60]
                          .map(
                            (v) =>
                                DropdownMenuItem(value: v, child: Text('$v с')),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v != null) {
                          player.updateSleepOptions(seekStepSeconds: v);
                        }
                      },
                    ),
                  ),
                  AudioRewindOptions(
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
                ],
              ),
            ),
    );
  }
}
