import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ui/audio_mini_player.dart';

import 'peer_files.dart';
import 'peer_models.dart';
import 'peer_service.dart';

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
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
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
    if (!await _confirm(
      'Общая папка',
      'Выберите отдельную папку для обмена. При связывании её содержимое объединится с папкой второго устройства. Изменения и удаления также передаются; предыдущие версии файлов сохраняются.',
    )) {
      return;
    }
    final root = await _pick();
    if (root == null || !mounted) return;
    final label =
        offer?['name'] as String? ??
        await _text('Название папки', '', 'Например: Английский');
    if (label == null) return;
    await service.addFolder(
      root,
      label,
      id: offer?['id'] as String?,
      sharedWith: peer == null ? {} : {peer.id},
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
        appBar: AppBar(title: const Text('Устройства и общие папки')),
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
                  'Без обязательного аккаунта и облака. В этой версии передаются файлы выбранных папок по локальной сети, пока оба приложения открыты. Прогресс, статистика и карточки приложения пока не переносятся.',
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
                const Text(
                  'Автоматическая проверка раз в минуту. На устройствах могут быть разные пути к одной общей папке.',
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
                          Wrap(
                            spacing: 8,
                            children: [
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
