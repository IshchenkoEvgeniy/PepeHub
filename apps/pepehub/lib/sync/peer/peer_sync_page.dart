import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ui/audio_mini_player.dart';
import '../../ui/settings_components.dart';

import 'peer_files.dart';
import 'peer_models.dart';
import 'peer_service.dart';
import 'peer_sync_schedule.dart';
import 'peer_diagnostics.dart';
import 'peer_sync_log_page.dart';
import 'peer_deletions_page.dart';
import 'app_sync_review_page.dart';
import 'peer_folder_files_page.dart';
import 'peer_history_page.dart';
import 'peer_qr.dart';
import 'peer_folder_setup_page.dart';

class PeerSyncPage extends StatefulWidget {
  final PeerSyncService service;
  final bool embedded;
  final String section;
  final ValueChanged<String>? onNavigate;
  final VoidCallback? onData;
  const PeerSyncPage({
    super.key,
    required this.service,
    this.embedded = false,
    this.section = 'overview',
    this.onNavigate,
    this.onData,
  });
  @override
  State<PeerSyncPage> createState() => _PeerSyncPageState();
}

class _PeerSyncPageState extends State<PeerSyncPage> {
  PeerSyncService get service => widget.service;
  bool working = false;
  @override
  void initState() {
    super.initState();
    service.initialize();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => working = true);
    try {
      await action();
    } catch (e) {
      service.recordFailure(e);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(peerFailureDescription(e))));
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<String?> _text(
    String title,
    String initial,
    String label, {
    int lines = 1,
    bool obscure = false,
  }) async {
    final controller = TextEditingController(text: initial);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 440,
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLines: lines,
            obscureText: obscure,
            decoration: InputDecoration(labelText: label),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Готово'),
          ),
        ],
      ),
    );
    // Dialog routes finish their closing animation after their result completes.
    Future<void>.delayed(const Duration(seconds: 1), controller.dispose);
    return result;
  }

  Future<bool> _confirm(String title, String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Продолжить'),
            ),
          ],
        ),
      ) ==
      true;
  Future<void> _invite() async {
    final host = await _text(
      'Адрес этого устройства',
      service.addresses.first,
      'IPv4 в общей сети',
    );
    if (host == null || !mounted) return;
    if (InternetAddress.tryParse(host.trim())?.type !=
        InternetAddressType.IPv4) {
      throw const FormatException('Введите IPv4-адрес');
    }
    final code = service.invitation(host.trim());
    try {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Подключить устройство'),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Код действует 5 минут и разрешает сопряжение одного устройства. Вставьте его в PepeHub на втором устройстве. Оба приложения должны быть открыты в одной сети.',
                  ),
                  const SizedBox(height: 16),
                  PeerInvitationQr(code: code),
                  SelectableText(code, style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Закрыть'),
            ),
            FilledButton.icon(
              onPressed: () => Clipboard.setData(ClipboardData(text: code)),
              icon: const Icon(Icons.copy),
              label: const Text('Копировать'),
            ),
          ],
        ),
      );
    } finally {
      service.cancelInvitation();
    }
  }

  Future<void> _address(PeerDevice peer) async {
    final host = await _text(
      'Адрес устройства',
      peer.host,
      'IP-адрес или имя компьютера',
    );
    if (host == null || !mounted) return;
    final port = await _text('Порт устройства', '${peer.port}', 'TCP-порт');
    if (port == null) return;
    await service.updateAddress(peer, host, int.tryParse(port.trim()) ?? 0);
  }

  Future<void> _relay() async {
    final url = await _text(
      'Ретранслятор для интернета',
      service.relayUrl,
      'wss://сервер/v1/relay; пусто — выключить',
    );
    if (url == null || !mounted) return;
    if (url.trim().isEmpty) {
      await service.configureRelay('', null);
      return;
    }
    final token = await _text(
      'Ключ доступа сервера',
      '',
      'Пусто — оставить сохранённый ключ',
      obscure: true,
    );
    if (token != null) await service.configureRelay(url, token);
  }

  Future<String?> _pick() async {
    if (Platform.isAndroid) {
      return (await peerFilesChannel.invokeMapMethod<String, dynamic>(
            'pick',
          ))?['root']
          as String?;
    }
    return getDirectoryPath(confirmButtonText: 'Выбрать общую папку');
  }

  Future<void> _add({PeerDevice? peer, Map<String, dynamic>? offer}) async {
    final folder = await Navigator.push<PeerFolder>(
      context,
      MaterialPageRoute(
        builder: (_) => PeerFolderSetupPage(
          service: service,
          pick: _pick,
          peer: peer,
          offer: offer,
        ),
      ),
    );
    if (folder != null && folder.download == 'selected' && mounted) {
      await _files(folder);
    }
  }

  Future<void> _files(PeerFolder folder) => Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (_) => PeerFolderFilesPage(service: service, folder: folder),
    ),
  );
  static const _libraryLabels = {
    'none': 'Не подключать к библиотеке',
    'all': 'По содержимому: книги, аудио и видео',
    'books': 'Книги',
    'audio': 'Аудиокниги',
    'video': 'Медиа',
  };
  Future<String?> _libraryMode(String initial) async {
    var selected = initial;
    return showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Автоподключение к библиотеке'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Подключать полученные файлы прямо из общей папки и обновлять список после обмена. Дополнительная копия медиа в приложении не создаётся.',
                  ),
                  for (final entry in _libraryLabels.entries)
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      leading: Icon(
                        selected == entry.key
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                      ),
                      title: Text(entry.value),
                      onTap: () => update(() => selected = entry.key),
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
              onPressed: () => Navigator.pop(context, selected),
              child: const Text('Готово'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _offers(PeerDevice peer) async {
    final offers = await service.offeredFolders(peer);
    if (!mounted) return;
    final offer = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Папки: ${peer.name}'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (offers.isEmpty)
                  const Text(
                    'На другом устройстве добавьте папку и разрешите доступ этому устройству.',
                  ),
                for (final folder in offers)
                  ListTile(
                    title: Text(folder['name'] as String),
                    subtitle: Text(
                      service.folders.any((f) => f.id == folder['id'])
                          ? 'Уже подключена'
                          : 'Выбрать локальную папку',
                    ),
                    onTap: service.folders.any((f) => f.id == folder['id'])
                        ? null
                        : () => Navigator.pop(context, folder),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
    if (offer != null) await _add(peer: peer, offer: offer);
  }

  Future<void> _access(PeerFolder folder) async {
    final selected = {...folder.devices};
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(folder.name),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Доступ к этой папке разрешён только выбранным устройствам.',
                  ),
                  if (service.devices.isEmpty)
                    const Text('Сначала подключите второе устройство.'),
                  for (final peer in service.devices)
                    CheckboxListTile(
                      title: Text(peer.name),
                      value: selected.contains(peer.id),
                      onChanged: (value) => update(() {
                        if (value == true) {
                          selected.add(peer.id);
                        } else {
                          selected.remove(peer.id);
                        }
                      }),
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
              onPressed: () => Navigator.pop(context, selected),
              child: const Text('Сохранить'),
            ),
          ],
        ),
      ),
    );
    if (result != null) await service.configureFolder(folder, devices: result);
  }

  List<Widget> _rules(bool disabled) => [
    SwitchListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      title: const Text('Автообмен в открытом приложении'),
      subtitle: const Text(
        'Только при изменениях и не чаще выбранного интервала. Входящий обмен с разрешённых устройств остаётся доступен. Фон Android включается отдельно. Для согласованного интервала обновите оба приложения.',
      ),
      value: service.autoSync,
      onChanged: disabled
          ? null
          : (value) => _run(() => service.setAutoSync(value)),
    ),
    Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Интервал автоматической синхронизации'),
          const SizedBox(height: 8),
          DropdownButton<int>(
            key: const ValueKey('peer-sync-interval'),
            isExpanded: true,
            value: service.schedule.minutes,
            items: [
              for (final minutes in PeerSyncSchedule.intervals)
                DropdownMenuItem(
                  value: minutes,
                  child: Text(
                    minutes < 60 ? '$minutes мин' : '${minutes ~/ 60} ч',
                  ),
                ),
            ],
            onChanged: disabled
                ? null
                : (value) {
                    if (value != null) {
                      _run(() => service.setSyncInterval(value));
                    }
                  },
          ),
          const SizedBox(height: 8),
          const Text(
            'Ручной обмен работает сразу. Интервал ограничивает автоматические проверки и фоновые задания.',
          ),
        ],
      ),
    ),
    if (Platform.isAndroid) ...[
      SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        title: const Text('Фоновый обмен данными приложения'),
        subtitle: const Text(
          'Android запускает задания с выбранным интервалом или позже. Медиафайлы в этих заданиях не скачиваются. После принудительной остановки откройте приложение.',
        ),
        value: service.backgroundSync,
        onChanged: disabled
            ? null
            : (value) => _run(() => service.configureBackground(value: value)),
      ),
      if (service.backgroundSync)
        SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
          title: const Text('Фон только в сети без тарификации'),
          value: service.backgroundWifiOnly,
          onChanged: disabled
              ? null
              : (value) =>
                    _run(() => service.configureBackground(wifiOnly: value)),
        ),
      OutlinedButton.icon(
        onPressed: disabled || !service.enabled || service.devices.isEmpty
            ? null
            : () => _run(service.transferInBackground),
        icon: const Icon(Icons.sync),
        label: const Text('Передать файлы с уведомлением'),
      ),
    ],
  ];

  static const _titles = {
    'overview': 'Синхронизация',
    'devices': 'Устройства',
    'folders': 'Общие папки',
    'rules': 'Расписание и сеть',
    'connection': 'Связь и дополнительно',
  };
  void _navigate(String part) {
    if (widget.onNavigate != null) {
      widget.onNavigate!(part);
      return;
    }
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => PeerSyncPage(
          service: service,
          section: part,
          onData: widget.onData,
        ),
      ),
    );
  }

  void _journal() => Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (_) => PeerSyncLogPage(journal: service.journal),
    ),
  );
  Widget _overview(bool disabled) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SettingsHeading(
        'Синхронизация',
        'Прямой обмен файлами и данными приложения между ПК и телефоном. Экспорт и резервные копии доступны в библиотеке.',
      ),
      SettingsGroup(
        children: [
          SwitchListTile.adaptive(
            title: const Text('Прямая синхронизация'),
            subtitle: Text(service.status),
            value: service.enabled,
            onChanged: disabled || !service.loaded
                ? null
                : (value) => _run(() => service.setEnabled(value)),
          ),
        ],
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.icon(
          onPressed: disabled || !service.enabled || service.devices.isEmpty
              ? null
              : () => _run(service.syncAll),
          icon: const Icon(Icons.sync),
          label: const Text('Синхронизировать устройства'),
        ),
      ),
      const SizedBox(height: 20),
      SettingsGroup(
        children: [
          SettingsLink(
            title: 'Устройства',
            subtitle: 'Подключение и разрешения',
            value: 'Сопряжено: ${service.devices.length}',
            icon: Icons.devices,
            onTap: () => _navigate('devices'),
          ),
          SettingsLink(
            title: 'Общие папки',
            subtitle: 'Что передавать и куда сохранять',
            value: 'Подключено: ${service.folders.length}',
            icon: Icons.folder_shared_outlined,
            onTap: () => _navigate('folders'),
          ),
          SettingsLink(
            title: 'Расписание и сеть',
            subtitle: service.autoSync
                ? 'Не чаще чем раз в ${service.schedule.minutes < 60 ? '${service.schedule.minutes} мин' : '${service.schedule.minutes ~/ 60} ч'}'
                : 'Автообмен в открытом приложении выключен',
            icon: Icons.schedule,
            onTap: () => _navigate('rules'),
          ),
          if (widget.onData != null)
            SettingsLink(
              title: 'Экспорт и резервные копии',
              subtitle: 'Каталог, журнал, обложки и заметки',
              icon: Icons.link,
              onTap: widget.onData,
            ),
        ],
      ),
      SettingsGroup(
        children: [
          SettingsLink(
            title: 'Спорные и ожидающие данные',
            subtitle: 'Сравнить версии, проверить ожидающие источники',
            icon: Icons.merge_type,
            onTap: disabled || !service.loaded
                ? null
                : () => Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => AppSyncReviewPage(service: service),
                    ),
                  ),
          ),
          if (service.pendingDeletions.isNotEmpty)
            SettingsLink(
              title:
                  'Подтвердить удаления (${service.pendingDeletions.length})',
              subtitle: 'Файлы сохраняются до вашего решения',
              icon: Icons.delete_outline,
              onTap: () => Navigator.push<void>(
                context,
                MaterialPageRoute(
                  builder: (_) => PeerDeletionsPage(service: service),
                ),
              ),
            ),
          SettingsLink(
            title: 'Журнал синхронизации',
            subtitle: 'Результаты, ошибки и объём данных',
            icon: Icons.receipt_long_outlined,
            onTap: _journal,
          ),
          SettingsLink(
            title: 'Связь и дополнительно',
            subtitle: 'Имя, адреса и необязательный сервер обмена',
            icon: Icons.settings_ethernet,
            onTap: () => _navigate('connection'),
          ),
        ],
      ),
      PeerSyncStatusPanel(journal: service.journal),
      if (service.reports.isNotEmpty)
        ExpansionTile(
          title: const Text('Подробности последнего обмена'),
          children: [
            for (final report in service.reports)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(report),
              ),
          ],
        ),
      const SettingsNotice(
        'Карточки и история могут передаваться без файлов книг. Файлы доступны на втором устройстве только после подключения общей папки и разрешения их загрузки.',
      ),
    ],
  );
  Widget _devices(bool disabled) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SettingsHeading(
        'Устройства',
        'Сопряжение сохраняется. Права на данные приложения и файлы выбираются отдельно для каждого устройства.',
      ),
      SettingsGroup(
        children: [
          SettingsLink(
            title: 'Создать код',
            subtitle: 'Показать QR-код для второго устройства',
            icon: Icons.qr_code,
            onTap: disabled || !service.enabled ? null : () => _run(_invite),
          ),
          SettingsLink(
            title: 'Вставить код',
            subtitle: 'Использовать код со второго устройства',
            icon: Icons.content_paste,
            onTap: disabled || !service.loaded
                ? null
                : () => _run(() async {
                    final code = await _text(
                      'Подключить устройство',
                      '',
                      'Вставьте код подключения',
                      lines: 4,
                    );
                    if (code != null) await service.pair(code);
                  }),
          ),
          if (Platform.isAndroid)
            SettingsLink(
              title: 'Сканировать QR',
              subtitle: 'Оба приложения должны быть открыты в одной сети',
              icon: Icons.qr_code_scanner,
              onTap: disabled || !service.loaded
                  ? null
                  : () => _run(() async {
                      final code = await Navigator.push<String>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const PeerQrScannerPage(),
                        ),
                      );
                      if (code != null) await service.pair(code);
                    }),
            ),
        ],
      ),
      if (service.devices.isEmpty)
        const SettingsNotice(
          'Подключённых устройств пока нет. Создайте код на одном устройстве и используйте его на другом.',
        ),
      for (final peer in service.devices)
        SettingsGroup(
          children: [
            ExpansionTile(
              key: ValueKey('peer-device:${peer.id}'),
              title: Text(peer.name),
              subtitle: Text(
                peer.applicationData
                    ? 'Сопряжение сохранено · данные приложения разрешены'
                    : 'Сопряжение сохранено · данные приложения выключены',
              ),
              children: [
                SwitchListTile.adaptive(
                  title: const Text('Данные приложения'),
                  subtitle: const Text(
                    'Прогресс, заметки, статистика, Anki, подборки и общие настройки. Включите на обоих устройствах. Пароли и локальные пути не передаются.',
                  ),
                  value: peer.applicationData,
                  onChanged: disabled
                      ? null
                      : (value) => _run(() async {
                          if (!value ||
                              await _confirm(
                                'Передавать данные приложения?',
                                'Разрешает этому устройству доступ к текстовым данным профиля, включая личные заметки и карточки Anki. Для переноса привязанных данных медиа нужно сопоставить источники. Доступ к файлам определяется общими папками отдельно.',
                              )) {
                            await service.shareApplication(peer, value);
                          }
                        }),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton(
                        onPressed: disabled || !service.enabled
                            ? null
                            : () => _run(() => service.syncDevice(peer)),
                        child: const Text('Синхронизировать'),
                      ),
                      OutlinedButton(
                        onPressed: disabled || !service.enabled
                            ? null
                            : () => _run(() => _offers(peer)),
                        child: const Text('Принять папку'),
                      ),
                    ],
                  ),
                ),
                ExpansionTile(
                  title: const Text('Адрес и управление доступом'),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: SelectableText('${peer.host}:${peer.port}'),
                    ),
                    if (service.relayUrl.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          service.relayReady(peer.id)
                              ? 'Через интернет: доступно'
                              : 'Через интернет: ожидание соединения',
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          TextButton(
                            onPressed: disabled || !service.enabled
                                ? null
                                : () => _run(() => _address(peer)),
                            child: const Text('Изменить адрес'),
                          ),
                          TextButton(
                            onPressed: disabled
                                ? null
                                : () => _run(() async {
                                    if (await _confirm(
                                      'Отключить устройство?',
                                      'Его доступ к общим папкам будет отозван. Локальные файлы сохранятся.',
                                    )) {
                                      await service.revoke(peer);
                                    }
                                  }),
                            child: const Text('Отключить'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
    ],
  );
  Widget _folder(PeerFolder folder, bool disabled) => SettingsGroup(
    children: [
      ExpansionTile(
        key: ValueKey('peer-folder:${folder.id}'),
        title: Text(folder.name),
        subtitle: Text(
          '${folder.paused ? 'На паузе' : 'Обмен разрешён'} · ${folder.devices.length} устройств\nБиблиотека: ${_libraryLabels[folder.library]}',
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: SelectableText(folder.root),
          ),
          SettingsLink(
            title: 'Выбрать файлы',
            subtitle: folder.download == 'all'
                ? 'Загружается вся папка'
                : folder.download == 'selected'
                ? 'Загружаются выбранные файлы'
                : 'Только данные приложения',
            icon: Icons.checklist,
            onTap: disabled ? null : () => _files(folder),
          ),
          SettingsLink(
            title: 'Автоподключение к библиотеке',
            subtitle: _libraryLabels[folder.library],
            icon: Icons.local_library_outlined,
            onTap: disabled
                ? null
                : () => _run(() async {
                    final mode = await _libraryMode(folder.library);
                    if (mode != null) {
                      await service.configureFolder(folder, library: mode);
                    }
                  }),
          ),
          SettingsLink(
            title: 'Выбрать устройства',
            subtitle: 'Кому разрешён обмен этой папкой',
            icon: Icons.devices,
            onTap: disabled ? null : () => _run(() => _access(folder)),
          ),
          SettingsLink(
            title: 'История и очистка',
            subtitle: folder.history.enabled
                ? '${folder.history.maxDays} дней · ${peerHistorySize(folder.history.maxBytes)}'
                : 'История версий выключена',
            icon: Icons.history,
            onTap: disabled
                ? null
                : () => Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          PeerHistoryPage(service: service, folder: folder),
                    ),
                  ),
          ),
          SwitchListTile.adaptive(
            title: const Text('Приостановить обмен папкой'),
            value: folder.paused,
            onChanged: disabled
                ? null
                : (value) => _run(
                    () => service.configureFolder(folder, paused: value),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: disabled
                      ? null
                      : () => _run(() => service.verifyFolder(folder)),
                  child: const Text('Проверить всё содержимое'),
                ),
                TextButton(
                  onPressed: disabled
                      ? null
                      : () => _run(() async {
                          if (await _confirm(
                            'Убрать общую папку?',
                            'Обмен этой папкой остановится. Все локальные файлы сохранятся.',
                          )) {
                            await service.disconnectFolder(folder);
                          }
                        }),
                  child: const Text('Убрать'),
                ),
              ],
            ),
          ),
        ],
      ),
    ],
  );
  Widget _folders(bool disabled) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SettingsHeading(
        'Общие папки',
        'Файлы передаются отдельно от карточек книг и прогресса. На ПК и телефоне могут быть разные пути одной общей папки.',
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.icon(
          onPressed: disabled || !service.loaded ? null : () => _run(_add),
          icon: const Icon(Icons.create_new_folder_outlined),
          label: const Text('Добавить папку'),
        ),
      ),
      const SizedBox(height: 18),
      if (service.folders.isEmpty)
        const SettingsNotice(
          'Общих папок пока нет. Создайте папку для обмена или примите её от подключённого устройства.',
        ),
      for (final folder in service.folders) _folder(folder, disabled),
      const SettingsNotice(
        'Неизменившиеся файлы повторно не перечитываются. Полная проверка содержимого запускается отдельно по вашей кнопке.',
      ),
    ],
  );
  Widget _connection(bool disabled) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SettingsHeading(
        'Связь и дополнительно',
        'Локальный адрес обновляется автоматически. Сервер обмена нужен только при работе через интернет.',
      ),
      SettingsGroup(
        children: [
          SettingsLink(
            title: service.name.isEmpty ? 'Это устройство' : service.name,
            subtitle: 'Изменить имя устройства',
            icon: Icons.edit_outlined,
            onTap: disabled
                ? null
                : () => _run(() async {
                    final name = await _text(
                      'Имя устройства',
                      service.name,
                      'Название',
                    );
                    if (name != null) await service.rename(name);
                  }),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              service.enabled
                  ? 'Локальные адреса: ${service.addresses.join(', ')}\nПорт: ${service.port}'
                  : 'Приём соединений выключен',
            ),
          ),
          SettingsLink(
            title: 'Обмен через интернет',
            subtitle: service.relayUrl.isEmpty
                ? 'Сервер обмена не настроен'
                : 'На обоих устройствах должны быть одинаковые параметры',
            icon: Icons.public,
            onTap: disabled ? null : () => _run(_relay),
          ),
        ],
      ),
      const SettingsNotice(
        'Обязательного аккаунта или облачного хранилища нет. При обмене через сервер оба устройства должны быть онлайн.',
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: service,
    builder: (context, _) {
      final disabled = working || service.busy;
      final section = widget.section;
      final child = switch (section) {
        'devices' => _devices(disabled),
        'folders' => _folders(disabled),
        'rules' => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SettingsHeading(
              'Расписание и сеть',
              'Автоматический обмен только при изменениях. Ручной обмен доступен сразу.',
            ),
            SettingsGroup(children: _rules(disabled)),
          ],
        ),
        'connection' => _connection(disabled),
        _ => _overview(disabled),
      };
      final body = ListView(
        key: ValueKey('peer-settings:$section'),
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
        children: [
          if (service.error != null) SettingsNotice(service.error!),
          child,
          if (service.busy || working)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(),
            ),
        ],
      );
      if (widget.embedded) return body;
      return Scaffold(
        appBar: AppBar(
          title: Text(_titles[section] ?? 'Синхронизация'),
          actions: [
            IconButton(
              tooltip: 'Журнал синхронизации',
              onPressed: _journal,
              icon: const Icon(Icons.receipt_long_outlined),
            ),
          ],
        ),
        bottomNavigationBar: const AudioPlayerFooter(),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: body,
          ),
        ),
      );
    },
  );
}
