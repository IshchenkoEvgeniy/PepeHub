import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../data/repository.dart';
import '../../media/asset_store.dart';
import 'peer_files.dart';
import 'peer_history.dart';
import 'peer_models.dart';
import 'peer_replica.dart';
import 'peer_store.dart';
import 'peer_sync_schedule.dart';
import 'peer_wire.dart';
import 'peer_diagnostics.dart';
import 'peer_library.dart';
import 'app_sync_engine.dart';
import 'app_sync_media.dart';
import 'app_sync_store.dart';
import 'app_sync_models.dart';
import 'peer_scan_monitor.dart';
import 'peer_discovery.dart';
import 'peer_relay.dart';

import 'package:flutter/services.dart';

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
  final AssetStore? assets;
  final PeerSecrets secrets;
  final Directory? workDirectory;
  final int configuredPort;
  final InternetAddress? bindAddress;
  final bool observeLifecycle;
  final bool? discoverAddresses;
  final bool backgroundWorker;
  final bool Function(String target)? protectsTarget;
  late final schedule = PeerSyncSchedule(store.repository, now: clock);
  final DateTime Function()? clock;
  late final journal = PeerSyncJournal(store.repository);
  AppSyncEngine? application;
  final Map<String, bool> remoteAppSharing = {};
  bool _appActive = false;
  late final PeerWireServer wire = PeerWireServer(
    keyFor: _keyFor,
    handle: _handle,
    onError: (failure, channel, operation) {
      journal.add(
        'Входящий запрос «${_operationLabel(operation)}»: ${peerFailureDescription(failure)}',
        level: PeerLogLevel.error,
        peer: devices.where((d) => d.channel == channel).firstOrNull?.name,
      );
    },
  );
  final Map<String, String> _keys = {};
  final Map<String, Map<String, dynamic>> _jobs = {};
  final Set<String> _active = {};
  List<PeerFolder> folders = [];
  List<PeerDevice> devices = [];
  List<PeerPendingDeletion> pendingDeletions = [];
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
  PeerRequestCancellation _requests = PeerRequestCancellation();
  Timer? _timer;
  Timer? _changeDelay;
  bool autoSync = true, _checking = false;
  bool backgroundSync = false, backgroundWifiOnly = true;
  bool _exchangeCancelled = false;
  static const _backgroundChannel = MethodChannel(
    'app.pepehub/peer_background',
  );
  final Map<String, PeerScanMonitor> _monitors = {};
  final Map<String, Future<Map<String, PeerFileEntry>>> _scans = {};
  final Map<String, DateTime> _historyChecked = {};
  final Map<String, Future<void>> _historyWork = {};
  final Map<String, String> _autoObserved = {};
  final Map<String, DateTime> _retryAfter = {};
  final Map<String, int> _failures = {};
  DateTime? _appChecked;
  PeerDiscovery? _discovery;
  final Map<String, DateTime> _addressAttempts = {};
  final Set<String> _checkingAddresses = {};
  String relayUrl = '';
  String _relayToken = '';
  final Map<String, PeerRelay> _relays = {};
  final Map<String, DateTime> _directRetry = {};
  bool relayReady(String device) => _relays[device]?.ready == true;
  static const _networkChannel = MethodChannel('app.pepehub/peer_network');
  _Invitation? _invitation;
  Future<void>? _initializing;
  bool get busy => _syncing || _active.isNotEmpty || _appActive;
  int get port => wire.port;
  PeerSyncService(
    this.store, {
    this.clock,
    this.secrets = const SecurePeerSecrets(),
    this.assets,
    this.workDirectory,
    this.configuredPort = peerPort,
    this.bindAddress,
    this.observeLifecycle = true,
    this.discoverAddresses,
    this.backgroundWorker = false,
    this.protectsTarget,
  });

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    try {
      await store.initialize();
      await schedule.load();
      await journal.initialize();
      if (Platform.isAndroid && observeLifecycle) {
        final report = await _backgroundChannel
            .invokeMapMethod<String, dynamic>('backgroundReport');
        final time = report?['time'] as String?,
            message = report?['result'] as String?;
        if (time != null &&
            message != null &&
            await store.repository.meta('peer-background-last-report') !=
                time) {
          journal.add('Android: $message');
          await store.repository.setMeta('peer-background-last-report', time);
        }
      }
      deviceId = await store.deviceId();
      final appStore = AppSyncStore(store);
      application = AppSyncEngine(
        store,
        deviceId,
        AppSyncMedia(
          appStore,
          () => folders,
          verifyNewFiles: !backgroundWorker,
        ),
        isProtected: protectsTarget,
      );
      name =
          await store.repository.meta('peer-sync-name') ??
          (Platform.isAndroid ? 'Мой телефон' : 'Мой компьютер');
      folders = await store.folders();
      pendingDeletions = await store.pendingDeletions();
      devices = await store.devices();
      autoSync = await store.repository.meta('peer-sync-auto') != '0';
      backgroundSync =
          await store.repository.meta('peer-background-enabled') == '1';
      backgroundWifiOnly =
          await store.repository.meta('peer-background-wifi') != '0';
      relayUrl = await store.repository.meta('peer-relay-url') ?? '';
      _relayToken = await secrets.read('relay-access') ?? '';
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
    } catch (failure) {
      loaded = true;
      error = 'Не удалось открыть настройки прямой синхронизации. Данные не сброшены.';
      journal.add(
        '$error ${peerFailureDescription(failure)}',
        level: PeerLogLevel.error,
      );
    }
    _changed();
  }

  Future<void> setEnabled(bool value) async {
    if (!loaded) await initialize();
    if (_disposed) return;
    if (!value) {
      enabled = false;
      cancelExchange();
      _generation++;
      _invitation = null;
      _timer?.cancel();
      _changeDelay?.cancel();
      await _stopDiscovery();
      await _stopRelays();
      for (final monitor in _monitors.values) {
        await monitor.close();
      }
      _monitors.clear();
      await wire.close();
      await store.repository.setMeta('peer-sync-enabled', '0');
      status = 'Прямая синхронизация выключена';
      if (Platform.isAndroid && observeLifecycle) await configureBackground();
      journal.add(
        'Прямая синхронизация выключена. Активные соединения закрыты.',
      );
      await journal.flush();
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
      if (Platform.isAndroid && observeLifecycle) await configureBackground();
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
      journal.add(
        'Приём соединений включён: ${addresses.join(', ')}:$port. Автообмен по изменениям; контроль папок с наблюдением раз в час, остальных — раз в 5 минут.',
      );
      _timer?.cancel();
      if (!backgroundWorker) _monitorFolders();
      await _startDiscovery();
      await _startRelays();
      if (!backgroundWorker) {
        _timer = Timer.periodic(
          const Duration(seconds: 30),
          (_) => unawaited(checkForChanges()),
        );
      }
    } catch (failure) {
      enabled = false;
      await wire.close();
      error =
          'Не удалось открыть порт $configuredPort: ${peerFailureDescription(failure)}';
      journal.add(error!, level: PeerLogLevel.error);
    }
    await journal.flush();
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

  Future<void> configureRelay(String url, String? value) async {
    final next = url.trim();
    final token = value == null || value.isEmpty ? _relayToken : value;
    if (next.isNotEmpty) PeerRelay.validateUrl(next);
    if (token.length > 512 || next.isNotEmpty && token.length < 24) {
      throw const FormatException('Ключ сервера: от 24 до 512 знаков');
    }
    await secrets.write('relay-access', token);
    await store.repository.setMeta('peer-relay-url', next);
    relayUrl = next;
    _relayToken = token;
    await _stopRelays();
    if (enabled) await _startRelays();
    _changed();
  }

  Future<void> _startRelays() async {
    if (relayUrl.isEmpty || !enabled) return;
    for (final peer in devices.toList()) {
      final key = _keys[peer.channel];
      if (key == null || _relays.containsKey(peer.id)) continue;
      final relay = PeerRelay(
        url: relayUrl,
        token: _relayToken,
        key: key,
        channel: peer.channel,
        first: deviceId.compareTo(peer.id) < 0,
        targetPort: port,
        onFailure: (message) {
          if (!_disposed && enabled) {
            journal.add(message, level: PeerLogLevel.warning, peer: peer.name);
          }
        },
        onState: (ready) {
          if (_disposed || !enabled) return;
          journal.add(
            ready
                ? 'Ретранслятор: второе устройство доступно; прямое соединение остаётся первым выбором.'
                : 'Ретранслятор: ожидание второго устройства.',
            peer: peer.name,
          );
          if (ready) _scheduleChanges();
          _changed();
        },
      );
      _relays[peer.id] = relay;
      try {
        await relay.start();
      } catch (_) {
        await relay.close();
        _relays.remove(peer.id);
        journal.add(
          'Не удалось запустить подключение ретранслятора.',
          level: PeerLogLevel.warning,
          peer: peer.name,
        );
      }
    }
  }

  Future<void> _stopRelays() async {
    final old = _relays.values.toList();
    _relays.clear();
    _directRetry.clear();
    for (final relay in old) {
      await relay.close();
    }
  }

  Future<void> _startDiscovery() async {
    if (!(discoverAddresses ?? observeLifecycle) || _discovery != null) return;
    try {
      if (Platform.isAndroid) {
        await _networkChannel.invokeMethod<void>('multicast', {
          'enabled': true,
        });
      }
      final discovery = PeerDiscovery(
        announcements: () => [
          for (final peer in devices)
            if (_keys[peer.channel] != null)
              peerAnnouncement(
                from: deviceId,
                to: peer.id,
                channel: peer.channel,
                key: _keys[peer.channel]!,
                port: port,
              ),
        ],
        onPacket: acceptAnnouncement,
        onAddresses: (value) {
          if (value.isNotEmpty && value.join(',') != addresses.join(',')) {
            addresses = value;
            _changed();
          }
        },
      );
      _discovery = discovery;
      await discovery.start();
      journal.add(
        'Поиск сопряжённых устройств в локальной сети включён (UDP $peerDiscoveryPort).',
      );
    } catch (failure) {
      await _stopDiscovery();
      journal.add(
        'Автопоиск адресов недоступен. Можно указать адрес вручную. ${peerFailureDescription(failure)}',
        level: PeerLogLevel.warning,
      );
    }
  }

  Future<void> _stopDiscovery() async {
    final current = _discovery;
    _discovery = null;
    await current?.close();
    if (Platform.isAndroid) {
      try {
        await _networkChannel.invokeMethod<void>('multicast', {
          'enabled': false,
        });
      } catch (_) {}
    }
  }

  Future<void> acceptAnnouncement(
    List<int> packet,
    InternetAddress source,
  ) async {
    if (!enabled || _disposed) return;
    final data = readPeerAnnouncement(packet, deviceId, _keys);
    if (data == null) return;
    final peer = devices
        .where((p) => p.id == data['from'] && p.channel == data['channel'])
        .firstOrNull;
    if (peer == null ||
        peer.host == source.address && peer.port == data['port']) {
      return;
    }
    final candidate = '${peer.id}:${source.address}:${data['port']}';
    final now = DateTime.now();
    _addressAttempts.removeWhere((_, at) => now.difference(at).inMinutes > 5);
    if (_checkingAddresses.contains(peer.id) ||
        _addressAttempts[candidate]?.isAfter(
              now.subtract(const Duration(seconds: 30)),
            ) ==
            true) {
      return;
    }
    _addressAttempts[candidate] = now;
    _checkingAddresses.add(peer.id);
    try {
      await updateAddress(peer, source.address, data['port'] as int);
    } catch (_) {
      // UDP is only a hint. Failed endpoint verification must not replace the
      // last known address, revoke pairing or flood the sync journal.
    } finally {
      _checkingAddresses.remove(peer.id);
    }
  }

  Future<void> updateAddress(PeerDevice peer, String host, int nextPort) async {
    host = host.trim();
    final key = _keys[peer.channel], generation = _generation;
    if (!enabled ||
        key == null ||
        host.isEmpty ||
        host.length > 255 ||
        nextPort < 1 ||
        nextPort > 65535) {
      throw const FormatException('Проверьте адрес и порт');
    }
    final nonce = peerRandomKey();
    final reply = await peerRequest(
      host: host,
      port: nextPort,
      channel: peer.channel,
      key: key,
      request: {
        'op': 'identity',
        'from': deviceId,
        'to': peer.id,
        'nonce': nonce,
        'listenPort': port,
      },
    );
    if (reply['device'] != peer.id ||
        reply['nonce'] != nonce ||
        reply['port'] != nextPort) {
      throw const FormatException(
        'Адрес не подтверждён сопряжённым устройством',
      );
    }
    if (_disposed ||
        !enabled ||
        _generation != generation ||
        _keys[peer.channel] != key ||
        !devices.any((p) => p.id == peer.id && p.channel == peer.channel)) {
      throw StateError('Сопряжение изменилось во время проверки адреса');
    }
    await _saveAddress(peer, host, nextPort);
  }

  Future<void> _saveAddress(PeerDevice peer, String host, int nextPort) async {
    final current = devices
        .where((p) => p.id == peer.id && p.channel == peer.channel)
        .firstOrNull;
    if (current == null || current.host == host && current.port == nextPort) {
      return;
    }
    devices = [
      for (final p in devices)
        p.id == peer.id ? p.withAddress(host, nextPort) : p,
    ];
    await store.saveDevices(devices);
    _retryAfter.remove(peer.id);
    _failures.remove(peer.id);
    _autoObserved.remove(peer.id);
    journal.add(
      'Адрес подтверждён существующим сопряжением: $host:$nextPort. Ключ и разрешения сохранены.',
      peer: peer.name,
    );
    _changed();
    _scheduleChanges();
  }

  void _monitorFolders() {
    final active = {for (final f in folders.where((f) => !f.paused)) f.id: f};
    for (final id in _monitors.keys.toList()) {
      if (active[id]?.root != _monitors[id]!.root) {
        unawaited(_monitors.remove(id)!.close());
      }
    }
    if (!enabled) return;
    for (final f in active.values) {
      _monitors.putIfAbsent(
        f.id,
        () => PeerScanMonitor(f.root, _scheduleChanges)..start(),
      );
    }
  }

  void _scheduleChanges() {
    if (!enabled || !autoSync || _disposed) return;
    _changeDelay?.cancel();
    _changeDelay = Timer(
      const Duration(seconds: 10),
      () => unawaited(checkForChanges()),
    );
  }

  void localFilesChanged() {
    for (final monitor in _monitors.values) {
      monitor.dirty();
    }
    _appChecked = null;
    _scheduleChanges();
  }

  Future<void> setSyncInterval(int minutes) async {
    await schedule.setMinutes(minutes);
    await configureBackground();
    _scheduleChanges();
    _changed();
  }

  Future<void> setAutoSync(bool value) async {
    autoSync = value;
    await store.repository.setMeta('peer-sync-auto', value ? '1' : '0');
    journal.add(
      value ? 'Автоматическое начало обмена по изменениям включено.' : 'Автоматическое начало обмена выключено. Ручной обмен и входящие запросы доступны.',
    );
    if (value) _scheduleChanges();
    _changed();
  }

  /// Small authenticated state probe. No full index or file body is sent.
  Future<String> _stateFor(PeerDevice peer, {bool prepare = true}) async {
    final parts = <Object?>[];
    for (final folder in folders.where(
      (f) => !f.paused && f.devices.contains(peer.id),
    )) {
      if (prepare && !_active.contains(folder.id)) {
        _active.add(folder.id);
        try {
          await _scanFolder(folder);
        } finally {
          _active.remove(folder.id);
        }
      }
      final entries = (await store.entries(folder.id)).values.toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      parts.add([
        folder.id,
        folder.download,
        folder.selectedPaths.toList()..sort(),
        for (final e in entries) e.toJson(),
      ]);
    }
    parts.add(peer.applicationData);
    if (_appAllowed(peer.id)) {
      if (prepare &&
          !_appActive &&
          (_appChecked == null ||
              DateTime.now().difference(_appChecked!).inSeconds >= 25)) {
        _appActive = true;
        try {
          await application!.refresh();
          _appChecked = DateTime.now();
        } finally {
          _appActive = false;
        }
      }
      parts.add(await application!.store.manifestRevision());
      parts.add(application!.validationWarnings);
    }
    return peerDigest(utf8.encode(jsonEncode(parts)));
  }

  Future<void> checkForChanges() async {
    if (!loaded ||
        !enabled ||
        !autoSync ||
        !_foreground ||
        busy ||
        _checking ||
        _disposed) {
      return;
    }
    _checking = true;
    try {
      for (final peer in devices.toList()) {
        if (!enabled || !autoSync || busy || _disposed) return;
        if (!schedule.checkDue(peer.id)) continue;
        if (_retryAfter[peer.id]?.isAfter(DateTime.now()) == true) continue;
        await schedule.checked(peer.id);
        try {
          final remote = await _request(peer, {'op': 'probe'}, quiet: true);
          if (remote['busy'] == true) continue;
          _failures.remove(peer.id);
          _retryAfter.remove(peer.id);
          // One automatic initiator when both sides have automatic mode on.
          if (remote['automatic'] == true && deviceId.compareTo(peer.id) > 0) {
            continue;
          }
          final local = await _stateFor(peer);
          final state = '$local:${remote['revision']}';
          if (_autoObserved[peer.id] == state) continue;
          _autoObserved[peer.id] = state;
          journal.add(
            'Обнаружено изменение индекса или первый обмен. Запуск синхронизации.',
            peer: peer.name,
          );
          final previousExchange = lastExchange;
          await syncDevice(peer, automatic: true);
          if (lastExchange == previousExchange) {
            _autoObserved.remove(peer.id);
          }
          if (error != null) {
            _autoObserved.remove(peer.id);
            throw StateError('Автообмен не завершён');
          }
          _failures.remove(peer.id);
          _retryAfter.remove(peer.id);
        } catch (failure) {
          final count = (_failures[peer.id] ?? 0) + 1;
          _failures[peer.id] = count;
          final delay = (30 * (1 << count.clamp(0, 4))).clamp(30, 600);
          _retryAfter[peer.id] = DateTime.now().add(Duration(seconds: delay));
          if (count == 1) {
            journal.add(
              'Автопроверка: ${peerFailureDescription(failure)} Повторы будут реже до восстановления соединения.',
              level: PeerLogLevel.warning,
              peer: peer.name,
            );
          }
        }
      }
    } finally {
      _checking = false;
    }
  }

  Future<void> verifyFolder(PeerFolder folder) async {
    if (busy) throw StateError('Дождитесь завершения обмена');
    _active.add(folder.id);
    try {
      await _scanFolder(folder, rescan: true, forceHash: true);
      await _refreshLibrary(folder);
    } finally {
      _active.remove(folder.id);
      _changed();
    }
  }

  Future<List<PeerFileEntry>> filesForSelection(PeerFolder folder) async {
    final result = await store.entries(folder.id);
    for (final peer in devices.where((p) => folder.devices.contains(p.id))) {
      final cached = await store.remoteIndex(peer.id, folder.id);
      List<PeerFileEntry> entries = cached?.entries ?? [];
      if (enabled && !busy) {
        try {
          final reply = await _request(peer, {
            'op': 'manifest',
            'folder': folder.id,
            if (cached != null) 'knownRevision': cached.revision,
          });
          if (reply['entries'] case final List raw) {
            if (raw.length > peerMaxFiles * 2) {
              throw const FormatException('Слишком большой индекс');
            }
            entries = [
              for (final item in raw)
                PeerFileEntry.fromJson(Map<String, dynamic>.from(item as Map)),
            ];
            if (reply['revision'] case final String revision) {
              await store.saveRemoteIndex(
                peer.id,
                folder.id,
                revision,
                entries,
              );
            }
          }
        } catch (_) {}
      }
      for (final entry in entries.where((e) => !e.deleted)) {
        if (result[entry.path]?.deleted != false ||
            (result[entry.path]?.bytes ?? 0) < entry.bytes) {
          result[entry.path] = entry;
        }
      }
    }
    return result.values.where((e) => !e.deleted).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
  }

  String invitation(String host) {
    if (!enabled || port == 0) {
      throw StateError('Сначала включите прямую синхронизацию');
    }
    final invite = _Invitation(uuid.v4(), peerRandomKey());
    _invitation = invite;
    journal.add('Создан код сопряжения на 5 минут. Адрес: $host:$port.');
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
    journal.add('Подключение для сопряжения: $host:$remotePort.');
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
    journal.add(
      'Сопряжение завершено. Выберите общие папки и разрешения.',
      peer: result['name'] as String,
    );
    await journal.flush();
    _changed();
  }

  Future<void> _remember(PeerDevice peer, String key) async {
    if (!devices.any((p) => p.id == peer.id) && devices.length >= 32) {
      throw StateError('Допускается до 32 устройств');
    }
    final old = devices.where((p) => p.id == peer.id).firstOrNull;
    if (old != null) peer = peer.withApplicationData(old.applicationData);
    await secrets.write(peer.channel, key);
    final next = [...devices.where((p) => p.id != peer.id), peer];
    await store.saveDevices(next);
    devices = next;
    _keys[peer.channel] = key;
    await _relays.remove(peer.id)?.close();
    if (old != null && old.channel != peer.channel) {
      _keys.remove(old.channel);
      await secrets.delete(old.channel);
    }
    await _startRelays();
    _changed();
  }

  Future<void> revoke(PeerDevice peer) async {
    _generation++;
    await _relays.remove(peer.id)?.close();
    _keys.remove(peer.channel);
    await secrets.delete(peer.channel);
    devices = devices.where((d) => d.id != peer.id).toList();
    folders = [
      for (final folder in folders)
        folder.copyWith(devices: {...folder.devices}..remove(peer.id)),
    ];
    await store.saveDevices(devices);
    await store.saveFolders(folders);
    for (final request in await store.pendingDeletions()) {
      if (request.device == peer.id) {
        await store.clearDeletion(request.folder, request.path);
      }
    }
    pendingDeletions = await store.pendingDeletions();
    journal.add(
      'Устройство отключено; дальнейший обмен запрещён.',
      peer: peer.name,
    );
    await journal.flush();
    _changed();
  }

  Future<void> shareApplication(PeerDevice peer, bool value) async {
    if (!value) _generation++;
    devices = [
      for (final item in devices)
        item.id == peer.id ? item.withApplicationData(value) : item,
    ];
    await store.saveDevices(devices);
    journal.add(
      value
          ? 'Разрешён обмен данными приложения. Разрешение требуется на обеих сторонах.'
          : 'Обмен данными приложения запрещён.',
      peer: peer.name,
    );
    await journal.flush();
    _changed();
  }

  bool _appAllowed(String device) =>
      enabled && devices.any((d) => d.id == device && d.applicationData);

  Future<Directory> _work() async =>
      workDirectory ??
      Directory(
        p.join((await getApplicationSupportDirectory()).path, 'peer-sync'),
      );
  void _historyReport(PeerFolder folder, PeerHistorySummary report) {
    if (report.moved > 0 || report.removed > 0) {
      journal.add(
        'История: перенесено ${report.moved}, удалено ${report.removed}, освобождено ${report.reclaimed} байт. Осталось ${report.files} копий (${report.bytes} байт).',
        subject: folder.name,
      );
    }
    for (final warning in report.warnings) {
      journal.add(warning, level: PeerLogLevel.warning, subject: folder.name);
    }
  }

  PeerFileSystem _historyFiles(PeerFolder folder) => peerFileSystem(
    folder.root,
    history: folder.history,
    onHistoryWarning: (warning) =>
        journal.add(warning, level: PeerLogLevel.warning, subject: folder.name),
  );

  Future<PeerFileSystem> _folderFiles(PeerFolder folder) async {
    final files = _historyFiles(folder);
    final checked = _historyChecked[folder.id];
    if (checked != null &&
        DateTime.now().difference(checked) < const Duration(days: 1)) {
      return files;
    }
    final running = _historyWork[folder.id];
    if (running != null) {
      await running;
      return files;
    }
    final work = () async {
      _historyChecked[folder.id] = DateTime.now();
      final key = 'peer-history-v1:${peerStorageKey(folder.root)}';
      try {
        final migrated = await store.repository.meta('$key:migrated') == '1';
        final last =
            int.tryParse(await store.repository.meta('$key:checked') ?? '') ??
            0;
        if ((!folder.history.enabled && migrated) ||
            DateTime.now().millisecondsSinceEpoch - last <
                const Duration(days: 1).inMilliseconds) {
          return;
        }
        final report = await (files as PeerHistoryStorage).maintainHistory(
          migrate: !migrated,
          prune: folder.history.enabled,
        );
        _historyReport(folder, report);
        if (report.legacy == 0) {
          await store.repository.setMeta('$key:migrated', '1');
        }
        await store.repository.setMeta(
          '$key:checked',
          '${DateTime.now().millisecondsSinceEpoch}',
        );
      } catch (failure) {
        journal.add(
          'Не удалось обслужить историю: ${peerFailureDescription(failure)}',
          level: PeerLogLevel.warning,
          subject: folder.name,
        );
        await store.repository.setMeta(
          '$key:checked',
          '${DateTime.now().millisecondsSinceEpoch}',
        );
      }
    }();
    _historyWork[folder.id] = work;
    try {
      await work;
    } finally {
      _historyWork.remove(folder.id);
    }
    return files;
  }

  Future<PeerHistorySummary> manageHistory(
    PeerFolder folder, {
    bool clear = false,
    bool prune = false,
  }) async {
    if (busy || _scans.isNotEmpty || _historyWork.isNotEmpty) {
      throw StateError('Дождитесь завершения обмена и повторите действие');
    }
    final current = folders.firstWhere((f) => f.id == folder.id);
    _active.add(folder.id);
    _changed();
    try {
      final report = await (_historyFiles(current) as PeerHistoryStorage)
          .maintainHistory(migrate: !clear, prune: prune, clear: clear);
      _historyReport(current, report);
      final key = 'peer-history-v1:${peerStorageKey(current.root)}';
      if (report.legacy == 0) {
        await store.repository.setMeta('$key:migrated', '1');
      }
      if (clear || prune || !current.history.enabled) {
        await store.repository.setMeta(
          '$key:checked',
          '${DateTime.now().millisecondsSinceEpoch}',
        );
        _historyChecked[folder.id] = DateTime.now();
      }
      await journal.flush();
      return report;
    } finally {
      _active.remove(folder.id);
      _changed();
    }
  }

  Future<PeerReplica> _replica(
    PeerFolder folder, {
    int? activity,
    void Function()? ensureAllowed,
  }) async => PeerReplica(
    store: store,
    folder: folder,
    device: deviceId,
    files: await _folderFiles(folder),
    work: await _work(),
    ensureAllowed: ensureAllowed,
    onScan: activity == null
        ? null
        : (path, checked) => journal.update(
            activity,
            subject: '${folder.name} / $path',
            completed: checked,
          ),
  );

  Future<Map<String, PeerFileEntry>> _scanFolder(
    PeerFolder folder, {
    String? peer,
    String? job,
    bool rescan = false,
    bool forceHash = false,
  }) async {
    final running = _scans[folder.id];
    if (running != null) {
      if (!forceHash && !rescan) return running;
      await running;
    }
    final monitor = _monitors[folder.id];
    if (!rescan &&
        !forceHash &&
        monitor != null &&
        !monitor.due(DateTime.now())) {
      await peerFileSystem(folder.root).checkRoot();
      return store.entries(folder.id);
    }
    final future = _scanFolderNow(
      folder,
      peer: peer,
      job: job,
      forceHash: forceHash,
    );
    _scans[folder.id] = future;
    try {
      return await future;
    } finally {
      _scans.remove(folder.id);
    }
  }

  Future<Map<String, PeerFileEntry>> _scanFolderNow(
    PeerFolder folder, {
    String? peer,
    String? job,
    bool forceHash = false,
  }) async {
    final monitor = _monitors[folder.id];
    final scannedGeneration = monitor?.generation ?? 0;
    final activity = journal.start(
      forceHash
          ? 'Полная проверка содержимого файлов'
          : 'Проверка изменений папки',
      peer: peer,
      subject: folder.name,
    );
    if (job != null) _jobs[job]?['activity'] = activity;
    try {
      final replica = await _replica(folder, activity: activity);
      final entries = await replica.scan(
        forceHash: forceHash,
        invalidated:
            monitor?.paths((await store.entries(folder.id)).keys) ?? const {},
      );
      monitor?.completed(scannedGeneration, DateTime.now());
      pendingDeletions = await store.pendingDeletions();
      final reclaimed = await replica.cleanupLegacyStages(entries);
      if (reclaimed > 0) {
        journal.add(
          'Освобождено $reclaimed байт прежних временных копий приложения; проверенные файлы остаются в общей папке.',
          subject: folder.name,
        );
      }
      journal.add(
        'Индекс готов: файлов ${entries.values.where((e) => !e.deleted).length}, удалений ${entries.values.where((e) => e.deleted).length}.',
        peer: peer,
        subject: folder.name,
      );
      return entries;
    } catch (failure) {
      journal.add(
        'Проверка папки: ${peerFailureDescription(failure)}',
        level: PeerLogLevel.error,
        peer: peer,
        subject: folder.name,
      );
      rethrow;
    } finally {
      journal.finish(activity);
    }
  }

  Future<void> addFolder(
    String root,
    String label, {
    String? id,
    Set<String> sharedWith = const {},
    String library = 'none',
    String download = 'all',
  }) async {
    if (!const ['all', 'none', 'selected'].contains(download)) {
      throw ArgumentError('Неизвестный режим загрузки');
    }
    if (!const ['none', 'all', 'books', 'audio', 'video'].contains(library)) {
      throw ArgumentError('Неизвестный раздел библиотеки');
    }
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
      library: library,
      download: download,
    );
    await store.forgetFolder(folderId);
    await _scanFolder(folder);
    folders = [...folders, folder];
    await store.saveFolders(folders);
    _monitorFolders();
    await _refreshLibrary(folder);
    journal.add(
      id == null
          ? 'Общая папка добавлена. Разрешите доступ через «Выбрать устройства».'
          : 'Общая папка связана со вторым устройством.',
      subject: folder.name,
    );
    await journal.flush();
    _changed();
  }

  Future<void> configureFolder(
    PeerFolder folder, {
    Set<String>? devices,
    bool? paused,
    String? library,
    String? download,
    Set<String>? selectedPaths,
    PeerHistorySettings? history,
  }) async {
    history?.validate();
    if (history != null &&
        (busy || _scans.isNotEmpty || _historyWork.isNotEmpty)) {
      throw StateError('Дождитесь завершения обмена перед изменением истории');
    }
    if (download != null &&
        !const ['all', 'none', 'selected'].contains(download)) {
      throw ArgumentError('Неизвестный режим загрузки');
    }
    if (library != null &&
        !const ['none', 'all', 'books', 'audio', 'video'].contains(library)) {
      throw ArgumentError('Неизвестный раздел библиотеки');
    }
    folders = [
      for (final item in folders)
        item.id == folder.id
            ? item.copyWith(
                devices: devices,
                paused: paused,
                library: library,
                download: download,
                selectedPaths: selectedPaths,
                history: history,
              )
            : item,
    ];
    await store.saveFolders(folders);
    if (history != null) _historyChecked.remove(folder.id);
    _monitorFolders();
    _monitors[folder.id]?.dirty();
    if (library != null && library != 'none') {
      await _scanFolder(folders.firstWhere((f) => f.id == folder.id));
      await _refreshLibrary(folders.firstWhere((f) => f.id == folder.id));
    }
    journal.add(
      'Доступ: ${folders.firstWhere((f) => f.id == folder.id).devices.length} устройств. ${paused == true
          ? 'Папка на паузе.'
          : paused == false
          ? 'Обмен возобновлён.'
          : download != null
          ? 'Режим загрузки обновлён.'
          : history != null
          ? 'История версий ${history.enabled ? 'включена' : 'выключена'}. Старые копии сохраняются до явной очистки или применения лимитов.'
          : 'Разрешения обновлены.'}',
      subject: folder.name,
    );
    await journal.flush();
    _changed();
    if (download != null || selectedPaths != null) _scheduleChanges();
  }

  Future<void> disconnectFolder(PeerFolder folder) async {
    if (_active.contains(folder.id)) {
      throw StateError('Дождитесь завершения обмена или выключите соединение');
    }
    folders = folders.where((f) => f.id != folder.id).toList();
    await store.saveFolders(folders);
    await store.forgetFolder(folder.id);
    _monitorFolders();
    pendingDeletions = await store.pendingDeletions();
    journal.add(
      'Папка отключена от обмена. Локальные файлы сохранены.',
      subject: folder.name,
    );
    await journal.flush();
    _changed();
  }

  Future<List<String>> _refreshLibrary(
    PeerFolder folder, {
    void Function()? ensureAllowed,
  }) async {
    if (folder.library == 'none') return [];
    final activity = journal.start(
      'Подключение общей папки к библиотеке',
      subject: folder.name,
    );
    try {
      if (assets == null) {
        throw StateError(
          'Хранилище библиотеки ещё не открыто. Повторите обновление папки.',
        );
      }
      final result = await PeerLibraryConnector(assets!).refresh(
        folder,
        await store.entries(folder.id),
        ensureAllowed: ensureAllowed,
      );
      for (final report in result) {
        journal.add(report, subject: folder.name);
      }
      return result;
    } catch (failure) {
      final report =
          'Автоподключение к библиотеке: ${peerFailureDescription(failure)}';
      journal.add(report, level: PeerLogLevel.warning, subject: folder.name);
      return [report];
    } finally {
      journal.finish(activity);
    }
  }

  Future<void> resolveDeletion(
    PeerPendingDeletion request, {
    required bool delete,
  }) async {
    if (busy) throw StateError('Дождитесь завершения обмена');
    final folder = _allowed(request.folder, request.device),
        generation = _generation;
    _syncing = true;
    _active.add(folder.id);
    final activity = journal.start(
      delete
          ? 'Применение подтверждённого удаления'
          : 'Сохранение файла вместо удаления',
      subject: '${folder.name} / ${request.path}',
    );
    _changed();
    void allowed() {
      if (_disposed || generation != _generation) {
        throw StateError('Операция остановлена');
      }
      _allowed(request.folder, request.device);
    }

    try {
      final replica = await _replica(
        folder,
        activity: activity,
        ensureAllowed: allowed,
      );
      await replica.resolveDeletion(request, delete: delete);
      journal.add(
        delete
            ? 'Удаление подтверждено. Предыдущая версия сохранена в общей папке.'
            : 'Удаление отклонено. Файл сохранён; при следующем обмене он восстановится на других устройствах.',
        subject: '${folder.name} / ${request.path}',
      );
      await _refreshLibrary(folder, ensureAllowed: allowed);
    } catch (failure) {
      recordFailure(failure);
      rethrow;
    } finally {
      pendingDeletions = await store.pendingDeletions();
      journal.finish(activity);
      _active.remove(folder.id);
      _syncing = false;
      _changed();
      await journal.flush();
    }
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
      journal.add(
        'Устройство сопряжено. Доступ к папкам и данным задаётся отдельно.',
        peer: request['name'] as String,
      );
      return {...invite.receipt!};
    }
    final device = devices.firstWhere(
      (p) => p.channel == channel && p.id == request['from'],
    );
    switch (request['op']) {
      case 'identity':
        final nonce = request['nonce'], nextPort = request['listenPort'];
        if (nonce is! String ||
            nonce.length != 44 ||
            nextPort is! int ||
            nextPort < 1 ||
            nextPort > 65535) {
          throw const FormatException('Неверный запрос адреса');
        }
        // The request is authenticated by this pair's key. The socket source
        // provides the address; a field inside an announcement never does.
        await _saveAddress(device, address, nextPort);
        return {'device': deviceId, 'nonce': nonce, 'port': port};
      case 'probe':
        if (busy || !schedule.probeDue(device.id)) return {'busy': true};
        await schedule.probed(device.id);
        return {
          'revision': await _stateFor(device, prepare: !backgroundWorker),
          'automatic': autoSync && _foreground,
        };
      case 'folders':
        if (request['automatic'] == true && !schedule.exchangeDue(device.id)) {
          return {
            'busy': true,
            'folders': <Object>[],
            'applicationData': false,
          };
        }
        if (request.containsKey('automatic')) {
          await schedule.exchanged(device.id);
        }
        journal.add(
          'Устройство проверяет доступные папки и разрешения.',
          peer: device.name,
        );
        return {
          'deleteApproval': 1,
          'applicationData': device.applicationData,
          'folders': [
            for (final f in folders.where(
              (f) => !f.paused && f.devices.contains(device.id),
            ))
              {'id': f.id, 'name': f.name},
          ],
        };
      case 'status':
        final job = _jobs[request['job']];
        final activity = journal.activities
            .where((a) => a.id == job?['activity'])
            .firstOrNull;
        return {
          'job': job?['peer'] == device.id
              ? {
                  ...job!,
                  if (activity != null)
                    'progress': {
                      'stage': activity.stage,
                      'subject': activity.subject,
                      'completed': activity.completed,
                      'total': activity.total,
                      'bytes': activity.bytes,
                      'totalBytes': activity.totalBytes,
                    },
                }
              : {'state': 'unknown'},
        };
      case 'app_manifest':
        if (!_appAllowed(device.id)) {
          throw StateError('Обмен данными приложения не разрешён');
        }
        final app = application!;
        await app.initialize();
        if (!_appActive && (request['after'] as String? ?? '').isEmpty) {
          _appActive = true;
          final activity = journal.start(
            'Подготовка индекса данных приложения для второго устройства',
            peer: device.name,
          );
          try {
            await app.refresh();
          } finally {
            journal.finish(activity);
            _appActive = false;
            _changed();
          }
        }
        return app.store.db.transaction(() async {
          final revision = await app.store.manifestRevision();
          if ((request['after'] as String? ?? '').isEmpty &&
              request['knownRevision'] == revision) {
            return {
              'unchanged': true,
              'revision': revision,
              'warnings': app.validationWarnings,
            };
          }
          return {
            'versions': await app.manifest(
              after: request['after'] as String? ?? '',
            ),
            'revision': revision,
            if ((request['after'] as String? ?? '').isEmpty)
              'warnings': app.validationWarnings,
          };
        });
      case 'app_read':
        if (!_appAllowed(device.id)) {
          throw StateError('Обмен данными приложения не разрешён');
        }
        return {
          'bytes': base64Encode(
            await application!.read(
              request['id'] as String,
              request['offset'] as int,
              request['count'] as int,
            ),
          ),
        };
      case 'app_pull':
        if (!_appAllowed(device.id)) {
          throw StateError('Обмен данными приложения не разрешён');
        }
        if (_appActive) return {'busy': true};
        final job = uuid.v4();
        if (_jobs.length > 32) _jobs.remove(_jobs.keys.first);
        _jobs[job] = {'state': 'running', 'peer': device.id};
        unawaited(
          _pullApplication(device, job: job)
              .then((warnings) {
                _jobs[job] = {
                  'state': 'done',
                  'peer': device.id,
                  'warnings': warnings,
                };
              })
              .catchError((Object failure) {
                _jobs[job] = {
                  'state': 'failed',
                  'peer': device.id,
                  'error': peerFailureDescription(failure),
                };
              }),
        );
        return {'job': job};
      case 'manifest':
        if (backgroundWorker) {
          throw StateError(
            'Фоновое задание обменивается только данными приложения',
          );
        }
        final folder = _allowed(request['folder'] as String, device.id);
        if (_active.contains(folder.id)) {
          return {
            'entries': (await store.entries(folder.id)).values
                .where((e) => !e.deleted || request['deleteApproval'] == 1)
                .map((e) => e.toJson())
                .toList(),
          };
        }
        _active.add(folder.id);
        late Map<String, PeerFileEntry> entries;
        try {
          entries = await _scanFolder(
            folder,
            peer: device.name,
            rescan: request['rescan'] == true,
          );
        } finally {
          _active.remove(folder.id);
        }
        final visible =
            entries.values
                .where((e) => !e.deleted || request['deleteApproval'] == 1)
                .toList()
              ..sort((a, b) => a.path.compareTo(b.path));
        final revision = peerDigest(
          utf8.encode(jsonEncode(visible.map((e) => e.toJson()).toList())),
        );
        return {
          'revision': revision,
          if (request['knownRevision'] == revision)
            'unchanged': true
          else
            'entries': visible.map((e) => e.toJson()).toList(),
        };
      case 'read':
        if (backgroundWorker) {
          throw StateError('Откройте приложение для передачи файлов');
        }
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
        if (backgroundWorker) return {'busy': true};
        final folder = _allowed(request['folder'] as String, device.id);
        if (_active.contains(folder.id)) return {'busy': true};
        final job = uuid.v4();
        if (_jobs.length > 32) _jobs.remove(_jobs.keys.first);
        _jobs[job] = {'state': 'running', 'peer': device.id};
        unawaited(
          _pull(device, folder, job: job)
              .then((warnings) {
                _jobs[job] = {
                  'state': 'done',
                  'peer': device.id,
                  'warnings': warnings,
                };
              })
              .catchError((Object failure) {
                _jobs[job] = {
                  'state': 'failed',
                  'peer': device.id,
                  'error': peerFailureDescription(failure),
                };
              }),
        );
        return {'job': job};
      default:
        throw StateError('Неподдерживаемая команда');
    }
  }

  Future<Map<String, dynamic>> _request(
    PeerDevice peer,
    Map<String, dynamic> request, {
    bool quiet = false,
  }) async {
    final key = _keys[peer.channel];
    final cancellation = _requests;
    if (!enabled ||
        _disposed ||
        key == null ||
        !devices.any((d) => d.id == peer.id && d.channel == peer.channel)) {
      throw StateError('Соединение отключено');
    }
    try {
      final relay = _relays[peer.id];
      final useRelay =
          relay?.ready == true &&
          _directRetry[peer.id]?.isAfter(DateTime.now()) == true;
      Future<Map<String, dynamic>> send(bool throughRelay) => peerRequest(
        host: throughRelay ? '127.0.0.1' : peer.host,
        port: throughRelay ? relay!.port : peer.port,
        channel: peer.channel,
        key: key,
        request: {
          ...request,
          'from': deviceId,
          'to': peer.id,
          'deleteApproval': 1,
        },
        cancellation: cancellation,
      );
      if (useRelay) return await send(true);
      try {
        return await send(false);
      } catch (failure) {
        if (failure is! SocketException && failure is! TimeoutException ||
            relay?.ready != true ||
            cancellation.cancelled ||
            !enabled ||
            _disposed) {
          rethrow;
        }
        _directRetry[peer.id] = DateTime.now().add(const Duration(minutes: 1));
        journal.add(
          'Прямой адрес недоступен. Обмен продолжен через шифрованный ретранслятор.',
          peer: peer.name,
        );
        return await send(true);
      }
    } catch (failure) {
      if (!quiet) {
        journal.add(
          '${_operationLabel(request['op'] as String)} (${peer.host}:${peer.port}): ${peerFailureDescription(failure)}',
          level: PeerLogLevel.error,
          peer: peer.name,
        );
      }
      rethrow;
    }
  }

  static String _operationLabel(String operation) => switch (operation) {
    'probe' => 'Проверка изменений индекса',
    'folders' => 'Запрос папок и разрешений',
    'manifest' => 'Запрос индекса файлов',
    'read' => 'Получение блока файла',
    'pull' => 'Запуск передачи на второе устройство',
    'status' => 'Ожидание второго устройства',
    'app_manifest' => 'Запрос индекса данных приложения',
    'app_read' => 'Получение данных приложения',
    'app_pull' => 'Запуск передачи данных приложения на второе устройство',
    'pair' => 'Сопряжение',
    _ => 'Запрос синхронизации',
  };

  void recordFailure(Object failure) {
    journal.add(peerFailureDescription(failure), level: PeerLogLevel.error);
  }

  Future<List<Map<String, dynamic>>> offeredFolders(
    PeerDevice peer, {
    bool? automatic,
  }) async {
    final result = await _request(peer, {
      'op': 'folders',
      'automatic': ?automatic,
    });
    if (result['busy'] == true) {
      throw StateError(
        'Второе устройство ожидает следующего интервала автообмена. Ручной обмен доступен.',
      );
    }
    remoteAppSharing[peer.id] = result['applicationData'] == true;
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

  Future<List<String>> _pull(
    PeerDevice peer,
    PeerFolder folder, {
    String? job,
  }) async {
    if (_active.contains(folder.id)) return ['Обмен папкой уже выполняется'];
    _active.add(folder.id);
    final generation = _generation;
    _changed();
    final warnings = <String>[];
    final activity = journal.start(
      'Подготовка получения файлов',
      peer: peer.name,
      subject: folder.name,
    );
    var checked = 0, total = 0, transferred = 0;
    try {
      _allowed(folder.id, peer.id);
      final replica = PeerReplica(
        store: store,
        folder: folder,
        device: deviceId,
        files: await _folderFiles(folder),
        work: await _work(),
        remoteDevice: peer.id,
        onTransfer: (path, bytes, size) => journal.update(
          activity,
          stage: 'Получение файла',
          subject: '${folder.name} / $path',
          completed: checked,
          total: total,
          bytes: bytes,
          totalBytes: size,
        ),
        onPhase: (path, phase) {
          journal.update(
            activity,
            stage: phase,
            subject: '${folder.name} / $path',
            completed: checked,
            total: total,
          );
          journal.add(
            phase,
            peer: peer.name,
            subject: '${folder.name} / $path',
          );
        },
        ensureAllowed: () {
          if (generation != _generation || !enabled || _disposed) {
            throw StateError('Передача остановлена');
          }
          _allowed(folder.id, peer.id);
        },
      );
      final local = await _scanFolder(folder, peer: peer.name, job: job);
      if (job != null) _jobs[job]?['activity'] = activity;
      journal.update(
        activity,
        stage: 'Ожидание индекса файлов на втором устройстве',
      );
      journal.add(
        'Запрошен индекс второго устройства. Проверка больших файлов может занять время.',
        peer: peer.name,
        subject: folder.name,
      );
      final cached = await store.remoteIndex(peer.id, folder.id);
      final manifest = await _request(peer, {
        'op': 'manifest',
        'folder': folder.id,
        if (cached != null) 'knownRevision': cached.revision,
        if (_manualRescan) 'rescan': true,
      });
      if (manifest['unchanged'] == true &&
          (cached == null || manifest['revision'] != cached.revision)) {
        throw const FormatException(
          'Неизменившийся индекс не соответствует сохранённой версии',
        );
      }
      final raw = manifest['unchanged'] == true && cached != null
          ? cached.entries.map((e) => e.toJson()).toList()
          : manifest['entries'] as List;
      if (raw.length > peerMaxFiles * 2) {
        throw StateError('Слишком большой индекс общей папки');
      }
      final entries = raw
          .map(
            (e) => PeerFileEntry.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .toList();
      if (manifest['revision'] case final String revision) {
        await store.saveRemoteIndex(peer.id, folder.id, revision, entries);
      }
      final selectedEntries = entries
          .where((e) => folder.receives(e.path))
          .toList();
      total = selectedEntries.length;
      if (folder.download != 'all') {
        journal.add(
          'На этом устройстве выбрано $total из ${entries.length} записей папки. Существующие файлы вне выбора сохраняются.',
          peer: peer.name,
          subject: folder.name,
        );
      }
      journal.add(
        manifest['unchanged'] == true
            ? 'Индекс второго устройства не изменился; используется сохранённая версия ($total записей).'
            : 'Получен индекс: $total записей. Сравнение версий.',
        peer: peer.name,
        subject: folder.name,
      );
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
      for (final entry in selectedEntries) {
        if (generation != _generation) throw StateError('Передача остановлена');
        _allowed(folder.id, peer.id);
        status = '${folder.name}: ${entry.path}';
        journal.update(
          activity,
          stage: 'Сравнение версий файлов',
          subject: '${folder.name} / ${entry.path}',
          completed: checked,
          total: total,
        );
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
          final bytes = base64Decode(result['bytes'] as String);
          transferred += bytes.length;
          return bytes;
        });
        checked++;
        if (warning != null) {
          warnings.add(warning);
          journal.add(
            warning,
            level: PeerLogLevel.warning,
            peer: peer.name,
            subject: folder.name,
          );
        }
      }
      journal.add(
        'Папка проверена: $checked записей, получено $transferred байт по сети, предупреждений ${warnings.length}.',
        peer: peer.name,
        subject: folder.name,
      );
      warnings.addAll(
        await _refreshLibrary(
          folder,
          ensureAllowed: () {
            if (generation != _generation || !enabled || _disposed) {
              throw StateError('Передача остановлена');
            }
            _allowed(folder.id, peer.id);
          },
        ),
      );
      return warnings;
    } catch (failure) {
      final current = journal.activities
          .where((a) => a.id == activity)
          .firstOrNull;
      journal.add(
        '${current?.stage ?? 'Обмен файлами'}: ${peerFailureDescription(failure)}',
        level: PeerLogLevel.error,
        peer: peer.name,
        subject: current?.subject ?? folder.name,
      );
      rethrow;
    } finally {
      journal.finish(activity);
      _active.remove(folder.id);
      pendingDeletions = await store.pendingDeletions();
      _changed();
      await journal.flush();
    }
  }

  bool _manualRescan = false;
  Future<void> syncDevice(
    PeerDevice peer, {
    bool automatic = false,
    bool metadataOnly = false,
  }) async {
    if (busy || !enabled) return;
    if (automatic && !schedule.exchangeDue(peer.id)) return;
    _syncing = true;
    _manualRescan = !automatic;
    error = null;
    reports = [];
    final generation = _generation;
    final started = DateTime.now();
    var filesStarted = false, filesFinished = false;
    final activity = journal.start(
      'Соединение с ${peer.host}:${peer.port}',
      peer: peer.name,
    );
    _changed();
    try {
      await schedule.exchanged(peer.id);
      final offers = await offeredFolders(peer, automatic: automatic),
          ids = offers.map((f) => f['id']).toSet();
      final includeApp =
          _appAllowed(peer.id) && remoteAppSharing[peer.id] == true;
      journal.add(
        'Соединение установлено. Доступно папок: ${offers.length}. Данные приложения: локально ${_appAllowed(peer.id) ? 'разрешены' : 'выключены'}, на втором устройстве ${remoteAppSharing[peer.id] == true ? 'разрешены' : 'выключены'}.',
        peer: peer.name,
      );
      if (!folders.any(
            (f) =>
                !f.paused && f.devices.contains(peer.id) && ids.contains(f.id),
          ) &&
          !includeApp) {
        status =
            'Устройства соединены. Свяжите общую папку на обоих устройствах.';
        if (_appAllowed(peer.id) && !includeApp) {
          status = 'На втором устройстве включите «Данные приложения» либо свяжите общую папку.';
        }
        journal.add(
          '$status Обмен данными не выполнялся.',
          level: PeerLogLevel.warning,
          peer: peer.name,
        );
        return;
      }
      if (_appAllowed(peer.id) && !includeApp) {
        reports.add(
          'На втором устройстве пока не разрешён обмен данными приложения.',
        );
        journal.add(reports.last, level: PeerLogLevel.warning, peer: peer.name);
      }
      for (final folder
          in folders
              .where(
                (f) =>
                    !metadataOnly &&
                    !f.paused &&
                    f.devices.contains(peer.id) &&
                    ids.contains(f.id),
              )
              .toList()) {
        filesStarted = true;
        if (!automatic) await _scanFolder(folder, rescan: true);
        journal.update(
          activity,
          stage: 'Получение изменений папки',
          subject: folder.name,
        );
        reports.addAll(await _pull(peer, folder));
        journal.update(
          activity,
          stage: 'Передача изменений на второе устройство',
          subject: folder.name,
        );
        journal.add(
          'Запущена передача изменений на второе устройство.',
          peer: peer.name,
          subject: folder.name,
        );
        final reply = await _request(peer, {'op': 'pull', 'folder': folder.id});
        if (reply['busy'] == true) {
          reports.add(
            '${folder.name}: второе устройство занято; обмен повторится',
          );
          journal.add(
            reports.last,
            level: PeerLogLevel.warning,
            peer: peer.name,
          );
          continue;
        }
        await _waitForJob(
          peer,
          reply['job'] as String,
          generation,
          activity: activity,
        );
      }
      filesFinished = true;
      if (includeApp) {
        journal.update(
          activity,
          stage: 'Получение данных приложения',
          subject: 'Прогресс, заметки и статистика',
        );
        reports.addAll(await _pullApplication(peer));
        journal.update(
          activity,
          stage: 'Передача данных приложения на второе устройство',
          subject: 'Прогресс, заметки и статистика',
        );
        final reply = await _request(peer, {'op': 'app_pull'});
        if (reply['busy'] == true) {
          reports.add('Второе устройство уже обменивается данными приложения.');
          journal.add(
            reports.last,
            level: PeerLogLevel.warning,
            peer: peer.name,
          );
        } else {
          await _waitForJob(
            peer,
            reply['job'] as String,
            generation,
            activity: activity,
          );
        }
      }
      lastExchange = DateTime.now();
      await schedule.exchanged(peer.id);
      status = 'Прямой обмен завершён';
      if (pendingDeletions.isNotEmpty) {
        status +=
            '. Ожидают подтверждения удаления: ${pendingDeletions.length}';
      }
      journal.add(
        'Обмен завершён за ${DateTime.now().difference(started).inSeconds} с. ${reports.isEmpty ? 'Замечаний нет.' : 'Подробности и ожидающие записи перечислены в журнале.'}',
        peer: peer.name,
      );
    } catch (failure) {
      if (generation != _generation || !enabled || _disposed) {
        error = null;
        status = enabled
            ? 'Передача остановлена'
            : 'Прямая синхронизация выключена';
        journal.add(status, level: PeerLogLevel.warning, peer: peer.name);
      } else {
        final outcome = filesStarted
            ? filesFinished
                  ? 'Файловый этап завершён. Ошибка возникла при обмене данными приложения.'
                  : 'Уже полученные файлы сохранены; незавершённая докачка продолжится при повторе.'
            : 'Передача файлов не выполнялась.';
        error =
            'Обмен не завершён: ${peerFailureDescription(failure)} $outcome Подробности — в журнале синхронизации.';
        journal.add(
          'Обмен прерван: ${peerFailureDescription(failure)} $outcome',
          level: PeerLogLevel.error,
          peer: peer.name,
        );
        status = filesStarted && filesFinished
            ? 'Файлы синхронизированы; данные приложения требуют повтора'
            : 'Ожидание повторного соединения';
      }
    } finally {
      _manualRescan = false;
      journal.finish(activity);
      _syncing = false;
      _changed();
      await journal.flush();
    }
  }

  Future<void> syncAll({bool metadataOnly = false}) async {
    _exchangeCancelled = false;
    for (final peer in devices.toList()) {
      if (!enabled || _disposed || _exchangeCancelled) return;
      await syncDevice(
        peer,
        automatic: metadataOnly,
        metadataOnly: metadataOnly,
      );
    }
  }

  Future<void> _waitForJob(
    PeerDevice peer,
    String job,
    int generation, {
    int? activity,
  }) async {
    final deadline = DateTime.now().add(const Duration(hours: 1));
    String? lastStage;
    while (true) {
      if (generation != _generation || DateTime.now().isAfter(deadline)) {
        throw StateError('Обмен остановлен');
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final state =
          (await _request(peer, {'op': 'status', 'job': job}))['job'] as Map;
      if (state['state'] == 'done') {
        reports.addAll((state['warnings'] as List).cast<String>());
        for (final report in (state['warnings'] as List).cast<String>()) {
          journal.add('На втором устройстве: $report', peer: peer.name);
        }
        journal.add(
          'Второе устройство завершило применение изменений.',
          peer: peer.name,
        );
        return;
      }
      if (state['state'] != 'running') {
        throw StateError(
          'На втором устройстве: ${state['error'] is String ? peerSafeDiagnostic(state['error'] as String) : 'задача обмена не завершена; откройте журнал на втором устройстве.'}',
        );
      }
      final progress = state['progress'];
      if (progress is Map && progress['stage'] is String) {
        final stage = peerSafeDiagnostic(progress['stage'] as String),
            subject = progress['subject'] is String
                ? peerSafeDiagnostic(progress['subject'] as String)
                : null;
        if (activity != null) {
          int? number(String key) =>
              progress[key] is int && (progress[key] as int) >= 0
              ? progress[key] as int
              : null;
          journal.update(
            activity,
            stage: 'На втором устройстве: $stage',
            subject: subject,
            completed: number('completed'),
            total: number('total'),
            bytes: number('bytes'),
            totalBytes: number('totalBytes'),
          );
        }
        if ('$stage|$subject' != lastStage) {
          lastStage = '$stage|$subject';
          journal.add(
            'На втором устройстве: $stage',
            peer: peer.name,
            subject: subject,
          );
        }
      }
    }
  }

  Future<List<String>> _pullApplication(PeerDevice peer, {String? job}) async {
    if (_appActive) return ['Обмен данными приложения уже выполняется'];
    _appActive = true;
    final generation = _generation;
    final activity = journal.start(
      'Подготовка локальных данных приложения',
      peer: peer.name,
    );
    if (job != null) _jobs[job]?['activity'] = activity;
    _changed();
    void allowed() {
      if (generation != _generation || !_appAllowed(peer.id) || _disposed) {
        throw StateError('Обмен данными приложения отключён');
      }
    }

    try {
      allowed();
      final app = application!;
      await app.refresh();
      final diagnostics = <String>{};
      void recordDiagnostics(Iterable<String> messages, {bool remote = false}) {
        for (final message in messages) {
          final text = '${remote ? 'На втором устройстве: ' : ''}$message';
          if (diagnostics.add(text)) {
            journal.add(text, level: PeerLogLevel.warning, peer: peer.name);
          }
        }
      }

      recordDiagnostics(app.validationWarnings);
      journal.add(
        'Локальные изменения подготовлены. Запрашивается индекс данных приложения.',
        peer: peer.name,
      );
      journal.update(
        activity,
        stage: 'Ожидание индекса данных приложения на втором устройстве',
      );
      var after = '';
      final revisionKey = 'peer-app-remote-revision:${peer.id}';
      final knownRevision = await store.repository.meta(revisionKey);
      String? indexRevision;
      var stableIndex = true, unchanged = false;
      var indexBytes = 0;
      var received = 0;
      var downloaded = 0, checked = 0;
      while (true) {
        allowed();
        final response = await _request(peer, {
          'op': 'app_manifest',
          'after': after,
          if (after.isEmpty && knownRevision != null)
            'knownRevision': knownRevision,
        });
        indexBytes += utf8.encode(jsonEncode(response)).length;
        final revision = response['revision'] as String?;
        if (after.isEmpty) indexRevision = revision;
        if (revision == null || revision != indexRevision) stableIndex = false;
        if (response['warnings'] case final List warnings) {
          recordDiagnostics(
            warnings.whereType<String>().take(100),
            remote: true,
          );
        }
        if (response['unchanged'] == true) {
          if (knownRevision == null ||
              revision != knownRevision ||
              after.isNotEmpty) {
            throw const FormatException(
              'Invalid conditional application index',
            );
          }
          unchanged = true;
          break;
        }
        final versions = response['versions'] as List;
        if (versions.length > 128 || (received += versions.length) > 100000) {
          throw StateError('Слишком большой индекс данных');
        }
        journal.add(
          'Получена страница индекса: ${versions.length} записей, всего найдено $received.',
          peer: peer.name,
        );
        for (final value in versions) {
          allowed();
          final header = Map<String, dynamic>.from(value as Map);
          final id = header['id'] as String;
          journal.update(
            activity,
            stage: 'Сравнение и получение данных приложения',
            completed: checked,
            total: received,
          );
          if (id.compareTo(after) <= 0) {
            throw StateError('Неверная последовательность индекса');
          }
          try {
            final beforeDownload = downloaded;
            await app.receive(header, (offset, count) async {
              allowed();
              final result = await _request(peer, {
                'op': 'app_read',
                'id': id,
                'offset': offset,
                'count': count,
              });
              final bytes = base64Decode(result['bytes'] as String);
              downloaded += bytes.length;
              journal.update(
                activity,
                stage: 'Получение записи данных приложения',
                completed: checked,
                total: received,
                bytes: offset + bytes.length,
                totalBytes: header['bytes'] is int
                    ? header['bytes'] as int
                    : null,
              );
              return bytes;
            });
            final entity = header['key'] as String;
            if (downloaded > beforeDownload &&
                entity.startsWith('media:book:')) {
              await store.repository.setMeta(
                'peer-book-origin:${entity.substring('media:book:'.length)}',
                jsonEncode({
                  'device': peer.id,
                  'name': peer.name,
                  'receivedAt': DateTime.now().toUtc().toIso8601String(),
                }),
              );
            }
          } on AppSyncRejectedRecord catch (failure) {
            stableIndex = false;
            recordDiagnostics([
              'Запись ${AppSyncLocalProblem(failure.key, '', '').reference} не принята: ${failure.message}. Остальные данные продолжают синхронизироваться.',
            ], remote: true);
          }
          checked++;
          after = id;
        }
        if (versions.length < 128) break;
      }
      allowed();
      if (stableIndex && indexRevision != null) {
        await store.repository.setMeta(revisionKey, indexRevision);
      }
      journal.add(
        '${unchanged ? 'Индекс не изменился' : 'Индекс обработан: $checked записей'}. Ответы индекса: $indexBytes байт JSON; содержимое записей: $downloaded байт. Шифрование и сетевые заголовки сюда не входят. Применение прогресса, заметок и статистики.',
        peer: peer.name,
      );
      journal.update(activity, stage: 'Применение данных приложения');
      final applied = await app.applyPending(ensureAllowed: allowed);
      recordDiagnostics(app.validationWarnings);
      final issues = await app.issues();
      journal.add(
        'Данные приложения: применено $applied, ожидает решения или источника ${issues.length}.',
        peer: peer.name,
      );
      if (issues.isNotEmpty) {
        journal.add(
          'Откройте «Спорные и ожидающие данные»: ${issues.length} записей требуют решения, файла или закрытия активного плеера.',
          level: PeerLogLevel.warning,
          peer: peer.name,
        );
      }
      for (final warning in app.codec.media.warnings) {
        journal.add(warning, level: PeerLogLevel.warning, peer: peer.name);
      }
      return [
        'Данные приложения: применено $applied, ожидает решения или источника ${issues.length}.',
        ...app.codec.media.warnings,
        ...diagnostics,
      ];
    } catch (failure) {
      journal.add(
        'Данные приложения: ${peerFailureDescription(failure)}',
        level: PeerLogLevel.error,
        peer: peer.name,
      );
      rethrow;
    } finally {
      journal.finish(activity);
      _appActive = false;
      _changed();
      await journal.flush();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground && enabled && !busy) _scheduleChanges();
  }

  /// Stops at a safe block boundary; staging files remain resumable.
  void cancelExchange() {
    _exchangeCancelled = true;
    _generation++;
    _requests.cancel();
    _requests = PeerRequestCancellation();
  }

  Future<void> configureBackground({bool? value, bool? wifiOnly}) async {
    final next = value ?? backgroundSync, wifi = wifiOnly ?? backgroundWifiOnly;
    if (Platform.isAndroid) {
      await _backgroundChannel.invokeMethod<void>('configure', {
        'enabled': next && enabled,
        'wifiOnly': wifi,
        'intervalMinutes': schedule.minutes,
      });
    }
    await store.repository.setMeta('peer-background-enabled', next ? '1' : '0');
    await store.repository.setMeta('peer-background-wifi', wifi ? '1' : '0');
    backgroundSync = next;
    backgroundWifiOnly = wifi;
    _changed();
  }

  Future<void> transferInBackground() async {
    if (busy || !enabled) return;
    if (Platform.isAndroid) {
      await _backgroundChannel.invokeMethod<void>('startTransfer');
    }
    try {
      await syncAll();
    } finally {
      if (Platform.isAndroid) {
        await _backgroundChannel.invokeMethod<void>('stopTransfer');
      }
    }
  }

  Future<void> close() async {
    enabled = false;
    cancelExchange();
    _timer?.cancel();
    _changeDelay?.cancel();
    await _stopDiscovery();
    await _stopRelays();
    await wire.close();
    while (busy || _checking || _scans.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    await journal.flush();
  }

  @override
  void dispose() {
    _disposed = true;
    enabled = false;
    _generation++;
    _timer?.cancel();
    _changeDelay?.cancel();
    unawaited(_stopDiscovery());
    unawaited(_stopRelays());
    for (final monitor in _monitors.values) {
      unawaited(monitor.close());
    }
    _monitors.clear();
    _invitation = null;
    journal.dispose();
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
