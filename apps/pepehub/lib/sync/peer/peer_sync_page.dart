import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ui/audio_mini_player.dart';

import 'peer_files.dart';
import 'peer_models.dart';
import 'peer_service.dart';
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
  const PeerSyncPage({super.key, required this.service});
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
                      contentPadding: EdgeInsets.zero,
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

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: service,
    builder: (context, _) {
      final disabled = working || service.busy;
      return Scaffold(
        bottomNavigationBar: const AudioPlayerFooter(),
        appBar: AppBar(
          title: const Text('Устройства и общие папки'),
          actions: [
            IconButton(
              tooltip: 'Журнал синхронизации',
              icon: const Icon(Icons.receipt_long_outlined),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => PeerSyncLogPage(journal: service.journal),
                ),
              ),
            ),
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Прямой обмен между ПК и телефоном',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Без обязательного аккаунта и облака. Файлы выбранных папок передаются по локальной сети, пока оба приложения открыты. Обмен прогрессом, заметками, статистикой и Anki включается отдельно для каждого устройства.',
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Прямая синхронизация'),
                  subtitle: Text(service.status),
                  value: service.enabled,
                  onChanged: working || !service.loaded
                      ? null
                      : (value) => _run(() => service.setEnabled(value)),
                ),
                if (service.enabled)
                  Text(
                    'Адреса: ${service.addresses.join(', ')} · порт ${service.port}',
                  ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Автоматически начинать обмен'),
                  subtitle: const Text(
                    'Только при изменениях. В ручном режиме входящий обмен с разрешённых устройств остаётся доступен.',
                  ),
                  value: service.autoSync,
                  onChanged: disabled
                      ? null
                      : (value) => _run(() => service.setAutoSync(value)),
                ),
                if (Platform.isAndroid) ...[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Фоновый обмен данными приложения'),
                    subtitle: const Text(
                      'Android назначает задания примерно от 15 минут. Медиафайлы в этих заданиях не скачиваются. После принудительной остановки откройте приложение.',
                    ),
                    value: service.backgroundSync,
                    onChanged: disabled
                        ? null
                        : (value) => _run(
                            () => service.configureBackground(value: value),
                          ),
                  ),
                  if (service.backgroundSync)
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Фон только в сети без тарификации'),
                      value: service.backgroundWifiOnly,
                      onChanged: disabled
                          ? null
                          : (value) => _run(
                              () =>
                                  service.configureBackground(wifiOnly: value),
                            ),
                    ),
                  OutlinedButton.icon(
                    onPressed:
                        disabled || !service.enabled || service.devices.isEmpty
                        ? null
                        : () => _run(service.transferInBackground),
                    icon: const Icon(Icons.sync),
                    label: const Text('Передать файлы с уведомлением'),
                  ),
                ],
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    service.name.isEmpty ? 'Это устройство' : service.name,
                  ),
                  subtitle: const Text('Имя устройства'),
                  trailing: const Icon(Icons.edit_outlined),
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
                if (service.error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      service.error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                PeerSyncStatusPanel(journal: service.journal),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.public),
                  title: const Text('Обмен через интернет'),
                  subtitle: Text(
                    service.relayUrl.isEmpty
                        ? 'Ретранслятор выключен. Можно подключить свой сервер; оба устройства должны быть онлайн.'
                        : 'Ретранслятор настроен. Укажите тот же сервер и ключ на втором устройстве.',
                  ),
                  trailing: const Icon(Icons.settings_outlined),
                  onTap: disabled ? null : () => _run(_relay),
                ),
                if (service.pendingDeletions.isNotEmpty)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.delete_outline),
                    title: Text(
                      'Подтвердить удаления (${service.pendingDeletions.length})',
                    ),
                    subtitle: const Text('Файлы сохраняются до вашего решения'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => PeerDeletionsPage(service: service),
                      ),
                    ),
                  ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: disabled || !service.enabled
                          ? null
                          : () => _run(_invite),
                      icon: const Icon(Icons.link),
                      label: const Text('Создать код'),
                    ),
                    OutlinedButton.icon(
                      onPressed: disabled || !service.loaded
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
                      icon: const Icon(Icons.devices),
                      label: const Text('Вставить код'),
                    ),
                    if (Platform.isAndroid)
                      OutlinedButton.icon(
                        onPressed: disabled || !service.loaded
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
                        icon: const Icon(Icons.qr_code_scanner),
                        label: const Text('Сканировать QR'),
                      ),
                  ],
                ),
                const SizedBox(height: 24),
                const Text(
                  'Устройства',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                if (service.devices.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('Подключите ПК или телефон с помощью кода.'),
                  ),
                for (final peer in service.devices)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            peer.name,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          Text('${peer.host}:${peer.port}'),
                          if (service.relayUrl.isNotEmpty)
                            Text(
                              service.relayReady(peer.id)
                                  ? 'Через интернет: доступно'
                                  : 'Через интернет: ожидание соединения',
                            ),
                          const Text(
                            'Адрес обновляется автоматически в локальной сети; сопряжение сохраняется.',
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Данные приложения'),
                            subtitle: const Text(
                              'Прогресс связанных медиа, заметки, статистика, Anki, подборки и общие настройки. Включите на обоих устройствах. Пароли и локальные пути не передаются.',
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
                                      await service.shareApplication(
                                        peer,
                                        value,
                                      );
                                    }
                                  }),
                          ),
                          Wrap(
                            spacing: 8,
                            children: [
                              TextButton(
                                onPressed: disabled || !service.enabled
                                    ? null
                                    : () =>
                                          _run(() => service.syncDevice(peer)),
                                child: const Text('Синхронизировать'),
                              ),
                              TextButton(
                                onPressed: disabled || !service.enabled
                                    ? null
                                    : () => _run(() => _offers(peer)),
                                child: const Text('Принять папку'),
                              ),
                              TextButton(
                                onPressed: disabled || !service.enabled
                                    ? null
                                    : () => _run(() => _address(peer)),
                                child: const Text('Изменить адрес'),
                              ),
                              TextButton(
                                onPressed: working
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
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
                const Text(
                  'Общие папки',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                TextButton.icon(
                  onPressed: disabled || !service.loaded
                      ? null
                      : () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => AppSyncReviewPage(service: service),
                          ),
                        ),
                  icon: const Icon(Icons.merge_type),
                  label: const Text('Спорные и ожидающие данные'),
                ),
                const Text(
                  'Windows отслеживает изменения папок; контрольная проверка — раз в час. Android SAF и папки без наблюдения проверяются раз в 5 минут. Неизменившиеся файлы не перечитываются. На устройствах могут быть разные пути к одной общей папке.',
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: disabled || !service.loaded
                        ? null
                        : () => _run(() => _add()),
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('Добавить папку'),
                  ),
                ),
                for (final folder in service.folders)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            folder.name,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          Text(
                            folder.root,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            folder.paused
                                ? 'На паузе'
                                : 'Доступ: ${folder.devices.length} устройств',
                          ),
                          Text(
                            'Автоподключение: ${_libraryLabels[folder.library]}',
                          ),
                          Text(
                            folder.history.enabled
                                ? 'История: ${folder.history.maxDays} дней · ${peerHistorySize(folder.history.maxBytes)}'
                                : 'История версий: выключена',
                          ),
                          Text(
                            'Загрузка: ${folder.download == 'all'
                                ? 'вся папка'
                                : folder.download == 'selected'
                                ? 'выбранные файлы'
                                : 'только данные приложения'}',
                          ),
                          Wrap(
                            spacing: 8,
                            children: [
                              TextButton(
                                onPressed: disabled
                                    ? null
                                    : () => _files(folder),
                                child: const Text('Выбрать файлы'),
                              ),
                              TextButton(
                                onPressed: disabled
                                    ? null
                                    : () => Navigator.push<void>(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) => PeerHistoryPage(
                                            service: service,
                                            folder: folder,
                                          ),
                                        ),
                                      ),
                                child: const Text('История и очистка'),
                              ),
                              TextButton(
                                onPressed: disabled
                                    ? null
                                    : () => _run(() async {
                                        final library = await _libraryMode(
                                          folder.library,
                                        );
                                        if (library != null) {
                                          await service.configureFolder(
                                            folder,
                                            library: library,
                                          );
                                        }
                                      }),
                                child: const Text('Автоподключение'),
                              ),
                              TextButton(
                                onPressed: disabled
                                    ? null
                                    : () => _run(
                                        () => service.verifyFolder(folder),
                                      ),
                                child: const Text('Проверить всё содержимое'),
                              ),
                              TextButton(
                                onPressed: disabled
                                    ? null
                                    : () => _run(() => _access(folder)),
                                child: const Text('Выбрать устройства'),
                              ),
                              TextButton(
                                onPressed: disabled
                                    ? null
                                    : () => _run(
                                        () => service.configureFolder(
                                          folder,
                                          paused: !folder.paused,
                                        ),
                                      ),
                                child: Text(
                                  folder.paused ? 'Возобновить' : 'Пауза',
                                ),
                              ),
                              TextButton(
                                onPressed: disabled
                                    ? null
                                    : () => _run(() async {
                                        if (await _confirm(
                                          'Убрать общую папку?',
                                          'Обмен этой папкой остановится. Все локальные файлы сохранятся.',
                                        )) {
                                          await service.disconnectFolder(
                                            folder,
                                          );
                                        }
                                      }),
                                child: const Text('Убрать'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                if (service.busy || working) const LinearProgressIndicator(),
                for (final report in service.reports)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(report),
                  ),
                const SizedBox(height: 24),
                const Text(
                  'Облако — дополнительный режим',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const Text(
                  'Облачное хранение и аккаунты пока не подключены. Они будут отдельной настройкой; прямой обмен папками работает самостоятельно.',
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      );
    },
  );
}
