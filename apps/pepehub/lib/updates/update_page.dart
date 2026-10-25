import 'package:flutter/material.dart';

import '../ui/audio_mini_player.dart';
import '../ui/settings_components.dart';
import 'update_service.dart';

class UpdatePage extends StatelessWidget {
  final UpdateService service;
  final bool embedded, details;
  final VoidCallback? onDetails;
  const UpdatePage({
    super.key,
    required this.service,
    this.embedded = false,
    this.details = false,
    this.onDetails,
  });
  String _size(int bytes) => '${(bytes / 1048576).toStringAsFixed(1)} МБ';
  String _checked(BuildContext context) {
    final time = DateTime.tryParse(service.lastChecked ?? '')?.toLocal();
    if (time == null) return 'Проверка ещё не выполнялась';
    final locale = MaterialLocalizations.of(context);
    return 'Последняя проверка: ${locale.formatMediumDate(time)}, ${locale.formatTimeOfDay(TimeOfDay.fromDateTime(time))}';
  }

  void _showDetails(BuildContext context) {
    if (onDetails != null) {
      onDetails!();
      return;
    }
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => UpdatePage(service: service, details: true),
      ),
    );
  }

  Widget _stages(BuildContext context) {
    final stage =
        service.package != null ||
            service.phase == UpdatePhase.preparing ||
            service.phase == UpdatePhase.permissionRequired
        ? 2
        : service.phase == UpdatePhase.downloading
        ? 1
        : 0;
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < 3; i++)
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: i == 2 ? 0 : 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 3,
                      color: i <= stage
                          ? colors.primary
                          : colors.outlineVariant,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      ['Проверка', 'Загрузка', 'Установка'][i],
                      style: TextStyle(
                        color: i == stage
                            ? colors.primary
                            : colors.onSurfaceVariant,
                        fontWeight: i == stage
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _details(BuildContext context, bool android) => [
    const SettingsHeading(
      'Источник обновлений',
      'Служебные сведения и альтернативная загрузка.',
    ),
    SettingsGroup(
      children: [
        ListTile(
          title: const Text('Установленная версия'),
          subtitle: Text(
            '${service.app?.version ?? 'Не определена'} · сборка ${service.app?.versionCode ?? '—'}',
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Источник обновлений'),
              const SizedBox(height: 8),
              SelectableText(service.feed),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Проверяются подпись выпуска и контрольная сумма скачанного файла.',
          ),
        ),
        if (service.artifact case final asset?)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Пакет: ${_size(asset.bytes)} · сборка ${asset.versionCode}',
                ),
                const SizedBox(height: 8),
                SelectableText('${asset.url}'),
              ],
            ),
          ),
      ],
    ),
    if (android && service.artifact != null)
      OutlinedButton.icon(
        onPressed: service.busy ? null : service.openAndroidDownload,
        icon: const Icon(Icons.open_in_browser),
        label: const Text('Скачать APK через браузер'),
      ),
    const SizedBox(height: 12),
    OutlinedButton.icon(
      onPressed: service.busy || service.app == null
          ? null
          : () => service.check(),
      icon: const Icon(Icons.refresh),
      label: const Text('Проверить обновления'),
    ),
    if (service.error case final message?)
      Padding(
        padding: const EdgeInsets.only(top: 16),
        child: SelectableText(
          message,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ),
  ];
  List<Widget> _main(BuildContext context, bool android) {
    final app = service.app,
        release = service.release,
        asset = service.artifact,
        phase = service.phase;
    return [
      const SettingsHeading(
        'Обновление приложения',
        'Обновление устанавливается поверх текущей версии. Книги и настройки сохраняются.',
      ),
      _stages(context),
      SettingsGroup(
        children: [
          ListTile(
            leading: const Icon(Icons.verified_outlined),
            title: Text(app == null ? 'PepeHub' : 'PepeHub ${app.version}'),
            subtitle: Text(_checked(context)),
          ),
        ],
      ),
      if (phase == UpdatePhase.checking || phase == UpdatePhase.preparing)
        const Padding(
          padding: EdgeInsets.only(bottom: 16),
          child: LinearProgressIndicator(),
        ),
      if (service.error case final message?)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Semantics(
            liveRegion: true,
            child: SelectableText(
              message,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ),
      if (!service.available &&
          service.lastChecked != null &&
          service.error == null &&
          !service.busy)
        const SettingsNotice('Установлена актуальная версия'),
      if (release != null && asset != null) ...[
        SettingsGroup(
          children: [
            ListTile(
              title: Text(
                'Доступна версия ${release.version}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(_size(asset.bytes)),
            ),
            if (release.notes.isNotEmpty)
              ExpansionTile(
                title: const Text('Что нового'),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Text(release.notes),
                  ),
                ],
              ),
          ],
        ),
        if (service.installStep case final step?)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Semantics(liveRegion: true, child: Text(step)),
          ),
        if (phase == UpdatePhase.downloading) ...[
          LinearProgressIndicator(
            value: service.total == 0 ? null : service.received / service.total,
          ),
          const SizedBox(height: 8),
          Text('${_size(service.received)} / ${_size(service.total)}'),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: service.cancelDownload,
              child: const Text('Остановить загрузку'),
            ),
          ),
        ] else if (phase == UpdatePhase.permissionRequired) ...[
          const SettingsNotice(
            'Разрешите PepeHub устанавливать обновления в настройках Android и вернитесь сюда. Установка продолжится автоматически.',
          ),
          FilledButton.icon(
            onPressed: service.allowInstall,
            icon: const Icon(Icons.security),
            label: const Text('Разрешить установку'),
          ),
        ] else if (service.package != null) ...[
          SettingsNotice(
            android
                ? phase == UpdatePhase.installerOpened
                      ? 'Запрос передан Android. Если окно не появилось, повторите установку или скачайте APK через браузер.'
                      : 'APK скачан. Подтвердите установку в системном окне Android.'
                : 'Приложение закроется, обновится и откроется снова.',
          ),
          FilledButton.icon(
            onPressed: service.busy ? null : service.install,
            icon: const Icon(Icons.system_update_alt),
            label: Text(
              android ? 'Установить обновление' : 'Обновить и перезапустить',
            ),
          ),
        ] else
          FilledButton.icon(
            onPressed: service.busy ? null : service.download,
            icon: const Icon(Icons.download_outlined),
            label: Text(
              service.received > 0
                  ? 'Продолжить загрузку'
                  : 'Скачать обновление',
            ),
          ),
        if (android &&
            (service.error != null || phase == UpdatePhase.installerOpened))
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TextButton.icon(
              onPressed: service.busy ? null : service.openAndroidDownload,
              icon: const Icon(Icons.open_in_browser),
              label: const Text('Скачать APK через браузер'),
            ),
          ),
      ] else
        FilledButton.icon(
          onPressed: service.busy || app == null ? null : () => service.check(),
          icon: const Icon(Icons.refresh),
          label: Text(
            phase == UpdatePhase.checking
                ? 'Проверяем…'
                : 'Проверить обновления',
          ),
        ),
      const SizedBox(height: 22),
      SettingsGroup(
        children: [
          SwitchListTile.adaptive(
            title: const Text('Проверять обновления автоматически'),
            subtitle: const Text(
              'При открытии приложения, не чаще раза в 12 часов. Скачивание начинается по вашей кнопке.',
            ),
            value: service.automatic,
            onChanged: service.busy
                ? null
                : (value) => service.configure(automatic: value),
          ),
          SettingsLink(
            title: 'Источник обновлений',
            subtitle: 'Подпись, сборка и ссылка на пакет',
            icon: Icons.shield_outlined,
            onTap: () => _showDetails(context),
          ),
        ],
      ),
      const Text('Удалять приложение перед установкой обновления не нужно.'),
    ];
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: service,
    builder: (context, _) {
      final android = service.app?.platform.startsWith('android') == true;
      final body = !service.loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              key: ValueKey('update-page:$details'),
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: details
                      ? _details(context, android)
                      : _main(context, android),
                ),
              ],
            );
      if (embedded) return body;
      return Scaffold(
        appBar: AppBar(
          title: Text(
            details ? 'Источник обновлений' : 'Обновление приложения',
          ),
        ),
        bottomNavigationBar: const AudioPlayerFooter(),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: body,
          ),
        ),
      );
    },
  );
}
