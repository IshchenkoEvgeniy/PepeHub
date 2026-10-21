import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'peer_history.dart';

const peerChunkSize = 256 * 1024;
const peerPort = 42589;
const peerMaxFiles = 10000;

String peerPath(String value) {
  final parts = value.split('/');
  if (value.isEmpty ||
      value.length > 1024 ||
      parts.length > 32 ||
      parts.any(
        (part) =>
            part.isEmpty ||
            part == '.' ||
            part == '..' ||
            part.length > 240 ||
            part.endsWith('.') ||
            part.endsWith(' ') ||
            part.toLowerCase() == '.pepehub' ||
            part.toLowerCase().startsWith('.pepehub-') ||
            RegExp(r'[<>:"\\|?*\x00-\x1f\x7f]').hasMatch(part) ||
            RegExp(
              r'^(con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³])( *\.| *$)',
              caseSensitive: false,
            ).hasMatch(part),
      )) {
    throw const FormatException('Недопустимый относительный путь');
  }
  return value;
}

bool peerIgnored(String name) =>
    name.toLowerCase() == '.pepehub' ||
    name.toLowerCase().startsWith('.pepehub-') ||
    name.toLowerCase().startsWith('.syncthing.') ||
    name.toLowerCase().startsWith('~syncthing~') ||
    {'desktop.ini', 'thumbs.db', '.ds_store'}.contains(name.toLowerCase());

String peerDigest(List<int> bytes) => sha256.convert(bytes).toString();

Map<String, int> mergePeerClocks(Map<String, int> a, Map<String, int> b) => {
  for (final key in {...a.keys, ...b.keys})
    key: (a[key] ?? 0) > (b[key] ?? 0) ? a[key]! : b[key]!,
};

/// -1: a precedes b, 1: a succeeds b, 0: equal, 2: concurrent.
int comparePeerClocks(Map<String, int> a, Map<String, int> b) {
  var less = false, more = false;
  for (final key in {...a.keys, ...b.keys}) {
    less |= (a[key] ?? 0) < (b[key] ?? 0);
    more |= (a[key] ?? 0) > (b[key] ?? 0);
  }
  return less && more
      ? 2
      : less
      ? -1
      : more
      ? 1
      : 0;
}

class PeerFileEntry {
  final String path;
  final String? hash;
  final int bytes;
  final Map<String, int> clock;
  bool get deleted => hash == null;
  PeerFileEntry({
    required String path,
    required this.hash,
    required this.bytes,
    required Map<String, int> clock,
  }) : path = peerPath(path),
       clock = Map.unmodifiable(clock) {
    if (bytes < 0 ||
        bytes > 1 << 50 ||
        hash != null && !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash!) ||
        hash == null && bytes != 0 ||
        clock.isEmpty ||
        clock.length > 64 ||
        clock.entries.any(
          (e) =>
              !RegExp(r'^[a-f0-9-]{36}$').hasMatch(e.key) ||
              e.value < 1 ||
              e.value > 9007199254740991,
        )) {
      throw const FormatException('Некорректная версия файла');
    }
  }
  PeerFileEntry withClock(Map<String, int> value, {String? path}) =>
      PeerFileEntry(
        path: path ?? this.path,
        hash: hash,
        bytes: bytes,
        clock: value,
      );
  Map<String, dynamic> toJson() => {
    'path': path,
    'hash': hash,
    'bytes': bytes,
    'clock': clock,
  };
  factory PeerFileEntry.fromJson(Map<String, dynamic> json) => PeerFileEntry(
    path: json['path'] as String,
    hash: json['hash'] as String?,
    bytes: json['bytes'] as int,
    clock: Map<String, int>.from(json['clock'] as Map),
  );
}

class PeerFolder {
  final String id, name, root;
  final Set<String> devices;
  final bool paused;
  final String library;
  final String download;
  final Set<String> selectedPaths;
  final PeerHistorySettings history;
  PeerFolder({
    required this.id,
    required this.name,
    required this.root,
    Set<String> devices = const {},
    this.paused = false,
    this.library = 'none',
    this.download = 'all',
    Set<String> selectedPaths = const {},
    this.history = const PeerHistorySettings(),
  }) : devices = Set.unmodifiable(devices),
       selectedPaths = Set.unmodifiable(selectedPaths.map(peerPath));
  bool receives(String path) =>
      download == 'all' ||
      download == 'selected' &&
          selectedPaths.any((p) => path == p || path.startsWith('$p/'));
  PeerFolder copyWith({
    Set<String>? devices,
    bool? paused,
    String? library,
    String? download,
    Set<String>? selectedPaths,
    PeerHistorySettings? history,
  }) => PeerFolder(
    id: id,
    name: name,
    root: root,
    devices: devices ?? this.devices,
    paused: paused ?? this.paused,
    library: library ?? this.library,
    download: download ?? this.download,
    selectedPaths: selectedPaths ?? this.selectedPaths,
    history: history ?? this.history,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'root': root,
    'devices': devices.toList(),
    'paused': paused,
    'library': library,
    'download': download,
    'selectedPaths': selectedPaths.toList()..sort(),
    'history': history.toJson(),
  };
  factory PeerFolder.fromJson(Map<String, dynamic> json) => PeerFolder(
    id: json['id'] as String,
    name: json['name'] as String,
    root: json['root'] as String,
    devices: (json['devices'] as List).cast<String>().toSet(),
    paused: json['paused'] == true,
    library: const ['all', 'books', 'audio', 'video'].contains(json['library'])
        ? json['library'] as String
        : 'none',
    download: const ['all', 'none', 'selected'].contains(json['download'])
        ? json['download'] as String
        : 'all',
    selectedPaths: (json['selectedPaths'] as List? ?? const [])
        .cast<String>()
        .toSet(),
    history: PeerHistorySettings.fromJson(json['history']),
  );
}

class PeerPendingDeletion {
  final String folder, device;
  final PeerFileEntry local, remote;
  final DateTime time;
  PeerPendingDeletion({
    required this.folder,
    required this.device,
    required this.local,
    required this.remote,
    required this.time,
  });
  String get path => remote.path;
  Map<String, dynamic> toJson() => {
    'folder': folder,
    'device': device,
    'local': local.toJson(),
    'remote': remote.toJson(),
    'time': time.toUtc().toIso8601String(),
  };
  factory PeerPendingDeletion.fromJson(Map<String, dynamic> value) =>
      PeerPendingDeletion(
        folder: value['folder'] as String,
        device: value['device'] as String,
        local: PeerFileEntry.fromJson(
          Map<String, dynamic>.from(value['local'] as Map),
        ),
        remote: PeerFileEntry.fromJson(
          Map<String, dynamic>.from(value['remote'] as Map),
        ),
        time: DateTime.parse(value['time'] as String),
      );
}

class PeerDevice {
  final String id, name, host, channel;
  final int port;
  final bool applicationData;
  const PeerDevice({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.channel,
    this.applicationData = false,
  });
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'channel': channel,
    'applicationData': applicationData,
  };
  factory PeerDevice.fromJson(Map<String, dynamic> json) => PeerDevice(
    id: json['id'] as String,
    name: json['name'] as String,
    host: json['host'] as String,
    port: json['port'] as int,
    channel: json['channel'] as String,
    applicationData: json['applicationData'] == true,
  );
  PeerDevice withApplicationData(bool value) => PeerDevice(
    id: id,
    name: name,
    host: host,
    port: port,
    channel: channel,
    applicationData: value,
  );
  PeerDevice withAddress(String address, int nextPort) => PeerDevice(
    id: id,
    name: name,
    host: address,
    port: nextPort,
    channel: channel,
    applicationData: applicationData,
  );
}

String peerConflictPath(PeerFileEntry file) {
  final parts = file.path.split('/'), name = parts.removeLast();
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final extension = dot > 0
      ? name.substring(dot).substring(0, (name.length - dot).clamp(0, 24))
      : '';
  parts.add(
    '${stem.substring(0, stem.length.clamp(0, 160))}.conflict-${file.hash!.substring(0, 16)}$extension',
  );
  return peerPath(parts.join('/'));
}

String peerStorageKey(String value) => peerDigest(utf8.encode(value));
