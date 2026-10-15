import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../data/repository.dart';
import 'peer_files.dart';
import 'peer_models.dart';
import 'peer_replica.dart';
import 'peer_store.dart';
import 'peer_wire.dart';

final _uuidPattern = RegExp(
  r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
);

class _Invitation {
  final String id, key;
  final DateTime expires;
  Map<String, dynamic>? receipt;
  Future<void>? saving;
  String? usedBy;
  _Invitation(this.id, this.key)
    : expires = DateTime.now().add(const Duration(minutes: 5));
}

class PeerSyncService extends ChangeNotifier with WidgetsBindingObserver {
  final PeerStore store;
  final PeerSecrets secrets;
  final Directory? workDirectory;
  final int configuredPort;
  final InternetAddress? bindAddress;
  final bool observeLifecycle;
  late final PeerWireServer wire = PeerWireServer(
    keyFor: _keyFor,
    handle: _handle,
  );
  final Map<String, String> _keys = {};
  final Map<String, Map<String, dynamic>> _jobs = {};
  final Set<String> _active = {};
  List<PeerFolder> folders = [];
  List<PeerDevice> devices = [];
  List<String> addresses = [];
  List<String> reports = [];
  String deviceId = '', name = '', status = 'Прямая синхронизация выключена';
  String? error;
  DateTime? lastExchange;
  bool loaded = false,
      enabled = false,
      _disposed = false,
      _syncing = false,
      _foreground = true;
  int _generation = 0;
  Timer? _timer;
  _Invitation? _invitation;
  Future<void>? _initializing;
  bool get busy => _syncing || _active.isNotEmpty;
  int get port => wire.port;
  PeerSyncService(
    this.store, {
    this.secrets = const SecurePeerSecrets(),
    this.workDirectory,
    this.configuredPort = peerPort,
    this.bindAddress,
    this.observeLifecycle = true,
  });

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    try {
      await store.initialize();
      deviceId = await store.deviceId();
      name =
          await store.repository.meta('peer-sync-name') ??
          (Platform.isAndroid ? 'Мой телефон' : 'Мой компьютер');
      folders = await store.folders();
      devices = await store.devices();
      for (final device in devices) {
        final key = await secrets.read(device.channel);
        if (key != null) _keys[device.channel] = key;
      }
      loaded = true;
      if (_disposed) return;
      if (observeLifecycle) WidgetsBinding.instance.addObserver(this);
      if (await store.repository.meta('peer-sync-enabled') == '1') {
        await setEnabled(true);
      }
    } catch (_) {
      loaded = true;
      error = 'Не удалось открыть настройки прямой синхронизации. Данные не сброшены.';
    }
    _changed();
  }

  Future<void> setEnabled(bool value) async {
    if (!loaded) await initialize();
    if (_disposed) return;
    if (!value) {
      enabled = false;
      _generation++;
      _invitation = null;
      _timer?.cancel();
      await wire.close();
      await store.repository.setMeta('peer-sync-enabled', '0');
      status = 'Прямая синхронизация выключена';
      _changed();
      return;
    }
    try {
      await wire.start(address: bindAddress, port: configuredPort);
      if (_disposed) {
        await wire.close();
        return;
      }
      enabled = true;
      error = null;
      await store.repository.setMeta('peer-sync-enabled', '1');
      addresses = [
        for (final network in await NetworkInterface.list(
          type: InternetAddressType.IPv4,
        ))
          for (final address in network.addresses) address.address,
      ];
      if (addresses.isEmpty) addresses = ['127.0.0.1'];
      status = 'Готово к прямому соединению';
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 60), (_) {
        if (_foreground && enabled && !busy && devices.isNotEmpty) {
          unawaited(syncAll());
        }
      });
    } catch (_) {
      enabled = false;
      await wire.close();
      error =
          'Не удалось открыть порт прямой синхронизации. Проверьте сеть и доступность порта $configuredPort.';
    }
    _changed();
  }

  Future<void> rename(String value) async {
    final next = value.trim();
    if (next.isEmpty || next.length > 100) {
      throw ArgumentError('Имя: от 1 до 100 знаков');
    }
    await store.repository.setMeta('peer-sync-name', next);
    name = next;
    _changed();
  }

  String invitation(String host) {
    if (!enabled || port == 0) {
      throw StateError('Сначала включите прямую синхронизацию');
    }
    final invite = _Invitation(uuid.v4(), peerRandomKey());
    _invitation = invite;
    return Uri(
      scheme: 'pepehub-peer',
      host: 'pair',
      queryParameters: {
        'v': '1',
        'device': deviceId,
        'host': host,
        'port': '$port',
        'invite': invite.id,
        'key': invite.key,
      },
    ).toString();
  }

  void cancelInvitation() {
    _invitation = null;
  }

  Future<void> pair(String code) async {
    await initialize();
    final uri = Uri.tryParse(code.trim()),
        args = Uri.tryParse(code.trim())?.queryParameters;
    if (uri?.scheme != 'pepehub-peer' ||
        uri?.host != 'pair' ||
        args?['v'] != '1') {
      throw const FormatException('Неверный код подключения');
    }
    final host = args!['host'] ?? '',
        other = args['device'] ?? '',
        invite = args['invite'] ?? '',
        key = args['key'] ?? '';
    final remotePort = int.tryParse(args['port'] ?? '') ?? 0;
    if (!_uuidPattern.hasMatch(other) ||
        !_uuidPattern.hasMatch(invite) ||
        other == deviceId ||
        host.isEmpty ||
        host.length > 255 ||
        remotePort < 1 ||
        remotePort > 65535 ||
        base64Url.decode(key).length != 32) {
      throw const FormatException('Неверный код подключения');
    }
    if (!enabled) await setEnabled(true);
    if (!enabled) throw StateError('Не удалось включить прямое соединение');
    final result = await peerRequest(
      host: host,
      port: remotePort,
      channel: 'invite:$invite',
      key: key,
      request: {
        'op': 'pair',
        'from': deviceId,
        'to': other,
        'name': name,
        'port': port,
      },
    );
    if (result['device'] != other ||
        !_uuidPattern.hasMatch(result['channel'] as String) ||
        base64Url.decode(result['key'] as String).length != 32) {
      throw const FormatException('Ответ другого устройства');
    }
    await _remember(
      PeerDevice(
        id: other,
        name: result['name'] as String,
        host: host,
        port: remotePort,
        channel: result['channel'] as String,
      ),
      result['key'] as String,
    );
    status = 'Устройства сопряжены. Выберите общие папки.';
    _changed();
  }

  Future<void> _remember(PeerDevice peer, String key) async {
    if (!devices.any((p) => p.id == peer.id) && devices.length >= 32) {
      throw StateError('Допускается до 32 устройств');
    }
    final old = devices.where((p) => p.id == peer.id).firstOrNull;
    await secrets.write(peer.channel, key);
    final next = [...devices.where((p) => p.id != peer.id), peer];
    await store.saveDevices(next);
    devices = next;
    _keys[peer.channel] = key;
    if (old != null && old.channel != peer.channel) {
      _keys.remove(old.channel);
      await secrets.delete(old.channel);
    }
    _changed();
  }

  Future<void> revoke(PeerDevice peer) async {
    _generation++;
    _keys.remove(peer.channel);
    await secrets.delete(peer.channel);
    devices = devices.where((d) => d.id != peer.id).toList();
    folders = [
      for (final folder in folders)
        folder.copyWith(devices: {...folder.devices}..remove(peer.id)),
    ];
    await store.saveDevices(devices);
    await store.saveFolders(folders);
    _changed();
  }

  Future<Directory> _work() async =>
      workDirectory ??
      Directory(
        p.join((await getApplicationSupportDirectory()).path, 'peer-sync'),
      );
  Future<PeerReplica> _replica(PeerFolder folder) async => PeerReplica(
    store: store,
    folder: folder,
    device: deviceId,
    files: peerFileSystem(folder.root),
    work: await _work(),
  );

  Future<void> addFolder(
    String root,
    String label, {
    String? id,
    Set<String> sharedWith = const {},
  }) async {
    if (label.trim().isEmpty || label.length > 200) {
      throw ArgumentError('Название: от 1 до 200 знаков');
    }
    final folderId = id ?? uuid.v4();
    if (!_uuidPattern.hasMatch(folderId) ||
        folders.any((f) => f.id == folderId)) {
      throw StateError('Общая папка уже подключена');
    }
    if (folders.length >= 100) {
      throw StateError('Допускается до 100 общих папок');
    }
    if (root.startsWith('content://')) {
      if (folders.any((f) => f.root == root)) {
        throw StateError('Эта локальная папка уже подключена');
      }
      for (final existing in folders.where(
        (f) => f.root.startsWith('content://'),
      )) {
        if (await peerFilesChannel.invokeMethod<bool>('overlaps', {
              'root': root,
              'other': existing.root,
            }) ==
            true) {
          throw StateError('Общие папки не должны перекрываться');
        }
      }
    } else {
      final directory = Directory(root);
      if (!await directory.exists()) {
        throw StateError('Выберите существующую папку');
      }
      root = await directory.resolveSymbolicLinks();
      for (final existing in folders.where(
        (f) => !f.root.startsWith('content://'),
      )) {
        final path = p.normalize(existing.root);
        if (p.equals(root, path) ||
            p.isWithin(root, path) ||
            p.isWithin(path, root)) {
          throw StateError('Общие папки не должны перекрываться');
        }
      }
      final working = p.normalize((await _work()).absolute.path);
      if (p.equals(root, working) ||
          p.isWithin(root, working) ||
          p.isWithin(working, root)) {
        throw StateError('Папка данных приложения не может быть общей');
      }
    }
    final folder = PeerFolder(
      id: folderId,
      name: label.trim(),
      root: root,
      devices: sharedWith,
    );
    await store.forgetFolder(folderId);
    await (await _replica(folder)).scan();
    folders = [...folders, folder];
    await store.saveFolders(folders);
    _changed();
  }

  Future<void> configureFolder(
    PeerFolder folder, {
    Set<String>? devices,
    bool? paused,
  }) async {
    folders = [
      for (final item in folders)
        item.id == folder.id
            ? item.copyWith(devices: devices, paused: paused)
            : item,
    ];
    await store.saveFolders(folders);
    _changed();
  }

  Future<void> disconnectFolder(PeerFolder folder) async {
    if (_active.contains(folder.id)) {
      throw StateError('Дождитесь завершения обмена или выключите соединение');
    }
    folders = folders.where((f) => f.id != folder.id).toList();
    await store.saveFolders(folders);
    await store.forgetFolder(folder.id);
    _changed();
  }

  Future<String?> _keyFor(String channel) async {
    if (!enabled) return null;
    final invite = _invitation;
    if (channel.startsWith('invite:')) {
      return invite != null &&
              channel == 'invite:${invite.id}' &&
              DateTime.now().isBefore(invite.expires)
          ? invite.key
          : null;
    }
    return _keys[channel];
  }

  PeerFolder _allowed(String id, String device) => folders.firstWhere(
    (f) => f.id == id && !f.paused && f.devices.contains(device),
    orElse: () => throw StateError('Нет доступа к общей папке'),
  );

  Future<Map<String, dynamic>> _handle(
    String channel,
    Map<String, dynamic> request,
    String address,
  ) async {
    if (!enabled ||
        request['to'] != deviceId ||
        !_uuidPattern.hasMatch(request['from'] as String)) {
      throw StateError('Другое устройство');
    }
    if (channel.startsWith('invite:')) {
      final invite = _invitation;
      if (invite == null ||
          channel != 'invite:${invite.id}' ||
          !DateTime.now().isBefore(invite.expires)) {
        throw StateError('Код недействителен');
      }
      if (request['op'] != 'pair' ||
          invite.usedBy != null && invite.usedBy != request['from'] ||
          request['from'] == deviceId ||
          (request['name'] as String).isEmpty ||
          (request['name'] as String).length > 100 ||
          request['port'] is! int ||
          (request['port'] as int) < 1 ||
          (request['port'] as int) > 65535) {
        throw StateError('Неверное сопряжение');
      }
      if (invite.saving != null) {
        await invite.saving;
        return {...invite.receipt!};
      }
      final key = peerRandomKey(), pairChannel = uuid.v4();
      invite.usedBy = request['from'] as String;
      invite.saving = _remember(
        PeerDevice(
          id: request['from'] as String,
          name: request['name'] as String,
          host: address,
          port: request['port'] as int,
          channel: pairChannel,
        ),
        key,
      );
      await invite.saving;
      invite.receipt = {
        'device': deviceId,
        'name': name,
        'channel': pairChannel,
        'key': key,
      };
      return {...invite.receipt!};
    }
    final device = devices.firstWhere(
      (p) => p.channel == channel && p.id == request['from'],
    );
    switch (request['op']) {
      case 'folders':
        return {
          'folders': [
            for (final f in folders.where(
              (f) => !f.paused && f.devices.contains(device.id),
            ))
              {'id': f.id, 'name': f.name},
          ],
        };
      case 'status':
        final job = _jobs[request['job']];
        return {
          'job': job?['peer'] == device.id ? job : {'state': 'unknown'},
        };
      case 'manifest':
        final folder = _allowed(request['folder'] as String, device.id);
        if (_active.contains(folder.id)) {
          return {
            'entries': (await store.entries(folder.id)).values
                .map((e) => e.toJson())
                .toList(),
          };
        }
        _active.add(folder.id);
        late Map<String, PeerFileEntry> entries;
        try {
          entries = await (await _replica(folder)).scan();
        } finally {
          _active.remove(folder.id);
        }
        return {'entries': entries.values.map((e) => e.toJson()).toList()};
      case 'read':
        final folder = _allowed(request['folder'] as String, device.id);
        final path = peerPath(request['path'] as String),
            offset = request['offset'] as int,
            count = request['count'] as int;
        final entry = await store.entry(folder.id, path);
        if (entry == null ||
            entry.deleted ||
            entry.hash != request['hash'] ||
            offset < 0 ||
            offset > entry.bytes ||
            count < 1 ||
            count > peerChunkSize) {
          throw StateError('Файл или диапазон изменился');
        }
        return {
          'bytes': base64Encode(
            await peerFileSystem(folder.root).read(path, offset, count),
          ),
        };
      case 'pull':
        final folder = _allowed(request['folder'] as String, device.id);
        if (_active.contains(folder.id)) return {'busy': true};
        final job = uuid.v4();
        if (_jobs.length > 32) _jobs.remove(_jobs.keys.first);
        _jobs[job] = {'state': 'running', 'peer': device.id};
        unawaited(
          _pull(device, folder)
              .then((warnings) {
                _jobs[job] = {
                  'state': 'done',
                  'peer': device.id,
                  'warnings': warnings,
                };
              })
              .catchError((Object _) {
                _jobs[job] = {'state': 'failed', 'peer': device.id};
              }),
        );
        return {'job': job};
      default:
        throw StateError('Неподдерживаемая команда');
    }
  }

  Future<Map<String, dynamic>> _request(
    PeerDevice peer,
    Map<String, dynamic> request,
  ) async {
    final key = _keys[peer.channel];
    if (!enabled ||
        _disposed ||
        key == null ||
        !devices.any((d) => d.id == peer.id && d.channel == peer.channel)) {
      throw StateError('Соединение отключено');
    }
    return peerRequest(
      host: peer.host,
      port: peer.port,
      channel: peer.channel,
      key: key,
      request: {...request, 'from': deviceId, 'to': peer.id},
    );
  }

  Future<List<Map<String, dynamic>>> offeredFolders(PeerDevice peer) async {
    final result = await _request(peer, {'op': 'folders'});
    final list = (result['folders'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    if (list.length > 100 ||
        list.any(
          (e) =>
              !_uuidPattern.hasMatch(e['id'] as String) ||
              (e['name'] as String).length > 200,
        )) {
      throw const FormatException('Неверный список папок');
    }
    return list;
  }

  Future<List<String>> _pull(PeerDevice peer, PeerFolder folder) async {
    if (_active.contains(folder.id)) return ['Обмен папкой уже выполняется'];
    _active.add(folder.id);
    final generation = _generation;
    _changed();
    final warnings = <String>[];
    try {
      _allowed(folder.id, peer.id);
      final replica = PeerReplica(
        store: store,
        folder: folder,
        device: deviceId,
        files: peerFileSystem(folder.root),
        work: await _work(),
        ensureAllowed: () {
          if (generation != _generation || !enabled || _disposed) {
            throw StateError('Передача остановлена');
          }
          _allowed(folder.id, peer.id);
        },
      );
      final local = await replica.scan();
      final manifest = await _request(peer, {
        'op': 'manifest',
        'folder': folder.id,
      });
      final raw = manifest['entries'] as List;
      if (raw.length > peerMaxFiles * 2) {
        throw StateError('Слишком большой индекс общей папки');
      }
      final entries = raw
          .map(
            (e) => PeerFileEntry.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .toList();
      final folded = <String>{};
      for (final entry in entries) {
        if (!folded.add(entry.path.toLowerCase())) {
          throw StateError('Конфликт регистра имён в общей папке');
        }
        if (local.keys.any(
          (path) =>
              path != entry.path &&
              path.toLowerCase() == entry.path.toLowerCase(),
        )) {
          throw StateError(
            'Имена на устройствах различаются только регистром: ${entry.path}',
          );
        }
      }
      for (final entry in entries) {
        if (generation != _generation) throw StateError('Передача остановлена');
        _allowed(folder.id, peer.id);
        status = '${folder.name}: ${entry.path}';
        _changed();
        final warning = await replica.apply(entry, (
          path,
          hash,
          offset,
          count,
        ) async {
          if (generation != _generation) {
            throw StateError('Передача остановлена');
          }
          _allowed(folder.id, peer.id);
          final result = await _request(peer, {
            'op': 'read',
            'folder': folder.id,
            'path': path,
            'hash': hash,
            'offset': offset,
            'count': count,
          });
          return base64Decode(result['bytes'] as String);
        });
        if (warning != null) warnings.add(warning);
      }
      return warnings;
    } finally {
      _active.remove(folder.id);
      _changed();
    }
  }

  Future<void> syncDevice(PeerDevice peer) async {
    if (busy || !enabled) return;
    _syncing = true;
    error = null;
    reports = [];
    final generation = _generation;
    _changed();
    try {
      final offers = await offeredFolders(peer),
          ids = offers.map((f) => f['id']).toSet();
      if (!folders.any(
        (f) => !f.paused && f.devices.contains(peer.id) && ids.contains(f.id),
      )) {
        status =
            'Устройства соединены. Свяжите общую папку на обоих устройствах.';
        return;
      }
      for (final folder
          in folders
              .where(
                (f) =>
                    !f.paused &&
                    f.devices.contains(peer.id) &&
                    ids.contains(f.id),
              )
              .toList()) {
        reports.addAll(await _pull(peer, folder));
        final reply = await _request(peer, {'op': 'pull', 'folder': folder.id});
        if (reply['busy'] == true) {
          reports.add(
            '${folder.name}: второе устройство занято; обмен повторится',
          );
          continue;
        }
        final job = reply['job'] as String;
        final deadline = DateTime.now().add(const Duration(hours: 1));
        while (true) {
          if (DateTime.now().isAfter(deadline)) {
            throw StateError('Превышено время ожидания обмена');
          }
          if (generation != _generation) {
            throw StateError('Соединение отключено');
          }
          await Future<void>.delayed(const Duration(milliseconds: 250));
          final state =
              (await _request(peer, {'op': 'status', 'job': job}))['job']
                  as Map;
          if (state['state'] == 'done') {
            reports.addAll((state['warnings'] as List).cast<String>());
            break;
          }
          if (state['state'] != 'running') {
            throw StateError('Второе устройство не завершило передачу');
          }
        }
      }
      lastExchange = DateTime.now();
      status = 'Прямой обмен завершён';
    } catch (_) {
      if (generation != _generation || !enabled || _disposed) {
        error = null;
        status = enabled
            ? 'Передача остановлена'
            : 'Прямая синхронизация выключена';
      } else {
        error = 'Обмен не завершён. Проверьте доступность устройства, доступ к папке и свободное место. Частичная загрузка сохранена.';
        status = 'Ожидание повторного соединения';
      }
    } finally {
      _syncing = false;
      _changed();
    }
  }

  Future<void> syncAll() async {
    for (final peer in devices.toList()) {
      if (!enabled || _disposed) return;
      await syncDevice(peer);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground && enabled && !busy) unawaited(syncAll());
  }

  @override
  void dispose() {
    _disposed = true;
    enabled = false;
    _generation++;
    _timer?.cancel();
    _invitation = null;
    if (observeLifecycle) WidgetsBinding.instance.removeObserver(this);
    unawaited(wire.close());
    super.dispose();
  }
}

class PeerSyncScope extends InheritedNotifier<PeerSyncService> {
  const PeerSyncScope({
    super.key,
    required PeerSyncService service,
    required super.child,
  }) : super(notifier: service);
  static PeerSyncService? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PeerSyncScope>()?.notifier;
}
