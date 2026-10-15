import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../data/repository.dart';
import 'peer_models.dart';

abstract class PeerSecrets {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecurePeerSecrets implements PeerSecrets {
  final FlutterSecureStorage storage;
  const SecurePeerSecrets([this.storage = const FlutterSecureStorage()]);
  @override
  Future<String?> read(String key) => storage.read(key: 'pepehub-p2p:$key');
  @override
  Future<void> write(String key, String value) =>
      storage.write(key: 'pepehub-p2p:$key', value: value);
  @override
  Future<void> delete(String key) => storage.delete(key: 'pepehub-p2p:$key');
}

class PeerStore {
  final Repository repository;
  PeerStore(this.repository);
  Future<void> initialize() => repository.db.customStatement(
    'CREATE TABLE IF NOT EXISTS peer_sync_files(folder_id TEXT NOT NULL,path TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(folder_id,path))',
  );

  Future<String> deviceId() async {
    final old = await repository.meta('peer-sync-device');
    if (old != null) return old;
    final id = uuid.v4();
    await repository.setMeta('peer-sync-device', id);
    return id;
  }

  Future<int> nextCounter() => repository.db.transaction(() async {
    final n =
        (int.tryParse(await repository.meta('peer-sync-counter') ?? '') ?? 0) +
        1;
    await repository.setMeta('peer-sync-counter', '$n');
    return n;
  });
  Future<List<PeerFolder>> folders() async => [
    for (final entry in jsonDecode(
      await repository.meta('peer-sync-folders') ?? '[]',
    ) as List)
      PeerFolder.fromJson(Map<String, dynamic>.from(entry as Map)),
  ];
  Future<void> saveFolders(List<PeerFolder> folders) => repository.setMeta(
    'peer-sync-folders',
    jsonEncode(folders.map((f) => f.toJson()).toList()),
  );
  Future<List<PeerDevice>> devices() async => [
    for (final entry in jsonDecode(
      await repository.meta('peer-sync-devices') ?? '[]',
    ) as List)
      PeerDevice.fromJson(Map<String, dynamic>.from(entry as Map)),
  ];
  Future<void> saveDevices(List<PeerDevice> devices) => repository.setMeta(
    'peer-sync-devices',
    jsonEncode(devices.map((d) => d.toJson()).toList()),
  );
  Future<Map<String, PeerFileEntry>> entries(String folder) async => {
    for (final row
        in await repository.db
            .customSelect(
              'SELECT path,payload FROM peer_sync_files WHERE folder_id=? ORDER BY path',
              variables: [Variable(folder)],
            )
            .get())
      row.read<String>('path'): PeerFileEntry.fromJson(
        jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
      ),
  };
  Future<void> put(String folder, PeerFileEntry file) =>
      repository.db.customStatement(
        'INSERT INTO peer_sync_files(folder_id,path,payload) VALUES(?,?,?) ON CONFLICT(folder_id,path) DO UPDATE SET payload=excluded.payload',
        [folder, file.path, jsonEncode(file.toJson())],
      );
  Future<void> forgetFolder(String folder) => repository.db.customStatement(
    'DELETE FROM peer_sync_files WHERE folder_id=?',
    [folder],
  );
  Future<PeerFileEntry?> entry(String folder, String path) async {
    final row = await repository.db
        .customSelect(
          'SELECT payload FROM peer_sync_files WHERE folder_id=? AND path=?',
          variables: [Variable(folder), Variable(path)],
        )
        .getSingleOrNull();
    return row == null
        ? null
        : PeerFileEntry.fromJson(
            jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
          );
  }
}
