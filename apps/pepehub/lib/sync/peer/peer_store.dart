import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../data/repository.dart';
import 'peer_models.dart';
import 'peer_files.dart';

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
  Future<void> initialize() async {
    await repository.db.customStatement(
      'CREATE TABLE IF NOT EXISTS peer_sync_files(folder_id TEXT NOT NULL,path TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(folder_id,path))',
    );
    await repository.db.customStatement(
      'CREATE TABLE IF NOT EXISTS peer_sync_deletions(folder_id TEXT NOT NULL,path TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(folder_id,path))',
    );
    await repository.db.customStatement(
      'CREATE TABLE IF NOT EXISTS peer_sync_scan_cache(folder_id TEXT NOT NULL,path TEXT NOT NULL,root TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(folder_id,path))',
    );
    await repository.db.customStatement(
      'CREATE TABLE IF NOT EXISTS peer_sync_remote_index(device TEXT NOT NULL,folder TEXT NOT NULL,revision TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(device,folder))',
    );
  }

  Future<Map<String, PeerDiskFile>> scanCache(PeerFolder folder) async => {
    for (final row
        in await repository.db
            .customSelect(
              'SELECT path,payload FROM peer_sync_scan_cache WHERE folder_id=? AND root=?',
              variables: [Variable(folder.id), Variable(folder.root)],
            )
            .get())
      row.read<String>('path'): PeerDiskFile.fromJson(
        jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
      ),
  };
  Future<void> saveScanCache(
    PeerFolder folder,
    List<PeerDiskFile> files,
  ) async {
    final old = await scanCache(folder);
    final present = files.map((f) => f.path).toSet();
    await repository.db.customStatement(
      'DELETE FROM peer_sync_scan_cache WHERE folder_id=? AND root<>?',
      [folder.id, folder.root],
    );
    for (final path in old.keys.where((p) => !present.contains(p))) {
      await repository.db.customStatement(
        'DELETE FROM peer_sync_scan_cache WHERE folder_id=? AND path=?',
        [folder.id, path],
      );
    }
    for (final file in files) {
      final before = old[file.path];
      if (before?.stamp == file.stamp &&
          before?.hash == file.hash &&
          before?.bytes == file.bytes) {
        continue;
      }
      await repository.db.customStatement(
        'INSERT INTO peer_sync_scan_cache(folder_id,path,root,payload) VALUES(?,?,?,?) ON CONFLICT(folder_id,path) DO UPDATE SET root=excluded.root,payload=excluded.payload',
        [folder.id, file.path, folder.root, jsonEncode(file.toJson())],
      );
    }
  }

  Future<({String revision, List<PeerFileEntry> entries})?> remoteIndex(
    String device,
    String folder,
  ) async {
    final row = await repository.db
        .customSelect(
          'SELECT revision,payload FROM peer_sync_remote_index WHERE device=? AND folder=?',
          variables: [Variable(device), Variable(folder)],
        )
        .getSingleOrNull();
    if (row == null) return null;
    return (
      revision: row.read<String>('revision'),
      entries: [
        for (final value in jsonDecode(row.read<String>('payload')) as List)
          PeerFileEntry.fromJson(Map<String, dynamic>.from(value as Map)),
      ],
    );
  }

  Future<void> saveRemoteIndex(
    String device,
    String folder,
    String revision,
    List<PeerFileEntry> entries,
  ) => repository.db.customStatement(
    'INSERT INTO peer_sync_remote_index(device,folder,revision,payload) VALUES(?,?,?,?) ON CONFLICT(device,folder) DO UPDATE SET revision=excluded.revision,payload=excluded.payload',
    [
      device,
      folder,
      revision,
      jsonEncode(entries.map((e) => e.toJson()).toList()),
    ],
  );

  Future<List<PeerPendingDeletion>> pendingDeletions({
    String? folder,
  }) async => [
    for (final row
        in await repository.db
            .customSelect(
              'SELECT payload FROM peer_sync_deletions ${folder == null ? '' : 'WHERE folder_id=?'} ORDER BY folder_id,path',
              variables: [if (folder != null) Variable(folder)],
            )
            .get())
      PeerPendingDeletion.fromJson(
        jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
      ),
  ];
  Future<void> requestDeletion(PeerPendingDeletion request) =>
      repository.db.customStatement(
        'INSERT INTO peer_sync_deletions(folder_id,path,payload) VALUES(?,?,?) ON CONFLICT(folder_id,path) DO UPDATE SET payload=excluded.payload',
        [request.folder, request.path, jsonEncode(request.toJson())],
      );
  Future<void> clearDeletion(String folder, String path) =>
      repository.db.customStatement(
        'DELETE FROM peer_sync_deletions WHERE folder_id=? AND path=?',
        [folder, path],
      );

  Future<PeerPendingDeletion?> pendingDeletion(
    String folder,
    String path,
  ) async {
    final row = await repository.db
        .customSelect(
          'SELECT payload FROM peer_sync_deletions WHERE folder_id=? AND path=?',
          variables: [Variable(folder), Variable(path)],
        )
        .getSingleOrNull();
    return row == null
        ? null
        : PeerPendingDeletion.fromJson(
            jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
          );
  }

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
  Future<void> forgetFolder(String folder) async {
    await repository.db.customStatement(
      'DELETE FROM peer_sync_scan_cache WHERE folder_id=?',
      [folder],
    );
    await repository.db.customStatement(
      'DELETE FROM peer_sync_remote_index WHERE folder=?',
      [folder],
    );
    await repository.db.customStatement(
      'DELETE FROM peer_sync_files WHERE folder_id=?',
      [folder],
    );
    await repository.db.customStatement(
      'DELETE FROM peer_sync_deletions WHERE folder_id=?',
      [folder],
    );
  }

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
