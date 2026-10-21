import 'package:flutter/material.dart';

import '../ui/audio_mini_player.dart';
import 'update_service.dart';

class UpdatePage extends StatelessWidget {
  final UpdateService service;
  const UpdatePage({super.key, required this.service});
  String _size(int bytes) => '${(bytes / 1048576).toStringAsFixed(1)} МБ';
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: service,
    builder: (context, _) {
      final app = service.app,
          release = service.release,
          asset = service.artifact;
      final phase = service.phase;
      final android = app?.platform.startsWith('android') == true;
      return Scaffold(
        appBar: AppBar(title: const Text('Обновление приложения')),
        bottomNavigationBar: const AudioPlayerFooter(),
        body: !service.loaded
            ? const Center(child: CircularProgressIndicator())
            : Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      Text(
                        app == null ? 'PepeHub' : 'PepeHub ${app.version}',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      if (app != null)
                        Text('Установленная сборка: ${app.versionCode}'),
                      const SizedBox(height: 16),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Проверять обновления автоматически'),
                        subtitle: const Text(
                          'При открытии приложения, не чаще раза в 12 часов. Скачивание начинается по вашей кнопке.',
                        ),
                        value: service.automatic,
                        onChanged: service.busy
                            ? null
                            : (value) => service.configure(automatic: value),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: service.busy || app == null
                            ? null
                            : () => service.check(),
                        icon: const Icon(Icons.refresh),
                        label: Text(
                          phase == UpdatePhase.checking
                              ? 'Проверяем…'
                              : 'Проверить обновления',
                        ),
                      ),
                      if (phase == UpdatePhase.checking ||
                          phase == UpdatePhase.preparing)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: LinearProgressIndicator(),
                        ),
                      if (!service.available && service.error != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Semantics(
                            liveRegion: true,
                            child: SelectableText(
                              service.error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        ),
                      if (!service.available &&
                          service.lastChecked != null &&
                          service.error == null &&
                          !service.busy)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Text('Установлена актуальная версия'),
                        ),
                      if (release != null && asset != null) ...[
                        const SizedBox(height: 20),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  'Доступна версия ${release.version}',
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                                Text(
                                  'Сборка ${asset.versionCode} · ${_size(asset.bytes)}',
                                ),
                                if (release.notes.isNotEmpty) ...[
                                  const SizedBox(height: 12),
                                  Text(release.notes),
                                ],
                                const SizedBox(height: 16),
                                if (service.installStep case final step?)
                                  Semantics(
                                    liveRegion: true,
                                    child: Text(step),
                                  ),
                                if (service.error case final message?)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: Semantics(
                                      liveRegion: true,
                                      child: SelectableText(
                                        message,
                                        style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .error,
                                        ),
                                      ),
                                    ),
                                  ),
                                if (phase == UpdatePhase.downloading) ...[
                                  LinearProgressIndicator(
                                    value: service.total == 0
                                        ? null
                                        : service.received / service.total,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    '${_size(service.received)} / ${_size(service.total)}',
                                  ),
                                  TextButton(
                                    onPressed: service.cancelDownload,
                                    child: const Text('Остановить загрузку'),
                                  ),
                                ] else if (phase ==
                                    UpdatePhase.permissionRequired) ...[
                                  const Text(
                                    'Разрешите PepeHub устанавливать обновления в настройках Android и вернитесь сюда. Установка продолжится автоматически.',
                                  ),
                                  const SizedBox(height: 8),
                                  FilledButton(
                                    onPressed: service.allowInstall,
                                    child: const Text('Разрешить установку'),
                                  ),
                                  OutlinedButton(
                                    onPressed: service.install,
                                    child: const Text('Установить обновление'),
                                  ),
                                ] else if (service.package != null) ...[
                                  Text(
                                    android
                                        ? 'APK скачан. Нажмите «Установить обновление» и подтвердите установку в окне Android. Книги и настройки сохранятся.'
                                        : 'Приложение закроется, обновится и откроется снова. Книги и настройки сохранятся.',
                                  ),
                                  const SizedBox(height: 8),
                                  FilledButton.icon(
                                    onPressed: service.busy
                                        ? null
                                        : service.install,
                                    icon: const Icon(Icons.system_update_alt),
                                    label: Text(
                                      android
                                          ? 'Установить обновление'
                                          : 'Обновить и перезапустить',
                                    ),
                                  ),
                                  if (phase == UpdatePhase.installerOpened &&
                                      android)
                                    const Padding(
                                      padding: EdgeInsets.only(top: 8),
                                      child: Text(
                                        'Запрос передан Android. Если окно не появилось, скачайте APK через браузер и откройте его в загрузках. Можно также повторить установку.',
                                      ),
                                    ),
                                ] else
                                  FilledButton.icon(
                                    onPressed: service.busy
                                        ? null
                                        : service.download,
                                    icon: const Icon(Icons.download_outlined),
                                    label: Text(
                                      service.received > 0
                                          ? 'Продолжить загрузку'
                                          : 'Скачать обновление',
                                    ),
                                  ),
                                if (android) ...[
                                  const SizedBox(height: 8),
                                  TextButton.icon(
                                    onPressed: service.busy
                                        ? null
                                        : service.openAndroidDownload,
                                    icon: const Icon(Icons.open_in_browser),
                                    label: const Text(
                                      'Скачать APK через браузер',
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      const Text(
                        'Обновление устанавливается поверх текущей версии. Удалять приложение перед установкой не нужно.',
                      ),
                      const SizedBox(height: 12),
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: const Text('Источник обновлений'),
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: SelectableText(service.feed),
                          ),
                          const Text(
                            'Проверяются подпись выпуска и контрольная сумма скачанного файла.',
                          ),
                          if (android && asset != null) ...[
                            const SizedBox(height: 12),
                            const Text('Прямая ссылка на APK:'),
                            SelectableText('${asset.url}'),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
      );
    },
  );
}
