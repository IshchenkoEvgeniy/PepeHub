import 'dart:io';

import 'package:path/path.dart' as p;

import 'peer_files.dart';
import 'peer_models.dart';
import 'peer_store.dart';

typedef PeerChunkReader = Future<List<int>> Function(
  String path,
  String hash,
  int offset,
  int count,
);

class PeerReplica {
  final PeerStore store;
  final PeerFolder folder;
  final String device;
  final PeerFileSystem files;
  final Directory work;
  final void Function()? ensureAllowed;
  PeerReplica({
    required this.store,
    required this.folder,
    required this.device,
    required this.files,
    required this.work,
    this.ensureAllowed,
  });

  Future<Map<String, PeerFileEntry>> scan() async {
    // Collect the entire scan before recording missing paths as deletions.
    final disk = await files.scan(), old = await store.entries(folder.id);
    final next = <PeerFileEntry>[], seen = <String>{};
    for (final file in disk) {
      seen.add(file.path);
      final previous = old[file.path];
      if (previous?.hash == file.hash && previous?.bytes == file.bytes) {
        continue;
      }
      next.add(
        PeerFileEntry(
          path: file.path,
          hash: file.hash,
          bytes: file.bytes,
          clock: {...?previous?.clock, device: await store.nextCounter()},
        ),
      );
    }
    for (final previous in old.values) {
      if (!previous.deleted && !seen.contains(previous.path)) {
        next.add(
          PeerFileEntry(
            path: previous.path,
            hash: null,
            bytes: 0,
            clock: {...previous.clock, device: await store.nextCounter()},
          ),
        );
      }
    }
    await store.repository.db.transaction(() async {
      for (final file in next) {
        await store.put(folder.id, file);
      }
    });
    return store.entries(folder.id);
  }

  Future<File> _stage(PeerFileEntry entry, PeerChunkReader read) async {
    final directory = Directory(p.join(work.path, folder.id));
    await directory.create(recursive: true);
    final file = File(
      p.join(
        directory.path,
        '${peerStorageKey(entry.path)}-${entry.hash}.part',
      ),
    );
    var offset = await file.exists() ? await file.length() : 0;
    if (offset > entry.bytes) {
      await file.writeAsBytes([]);
      offset = 0;
    }
    final out = await file.open(mode: FileMode.append);
    try {
      while (offset < entry.bytes) {
        final count = (entry.bytes - offset).clamp(1, peerChunkSize);
        final bytes = await read(entry.path, entry.hash!, offset, count);
        if (bytes.isEmpty || bytes.length > count) {
          throw StateError('Источник вернул неполный или неверный блок');
        }
        await out.writeFrom(bytes);
        offset += bytes.length;
      }
      await out.flush();
    } finally {
      await out.close();
    }
    if (await hashPeerFile(file) != entry.hash) {
      await file.delete(); // Only a hash-addressed staging file in app storage.
      throw StateError(
        'Контрольная сумма не совпала: ${entry.path}. Предыдущий файл сохранён.',
      );
    }
    return file;
  }

  Future<void> _install(
    PeerFileEntry entry,
    PeerFileEntry? previous,
    PeerChunkReader read, {
    String? sourcePath,
  }) async {
    if (entry.deleted) {
      ensureAllowed?.call();
      await files.remove(entry.path, previous?.hash);
    } else {
      final stage = await _stage(
        sourcePath == null
            ? entry
            : PeerFileEntry(
                path: sourcePath,
                hash: entry.hash,
                bytes: entry.bytes,
                clock: entry.clock,
              ),
        read,
      );
      ensureAllowed?.call();
      await files.publish(entry.path, stage, previous?.hash);
    }
    await store.put(folder.id, entry);
  }

  /// Returns a conflict description when both independent versions were retained.
  Future<String?> apply(PeerFileEntry remote, PeerChunkReader read) async {
    ensureAllowed?.call();
    final local = await store.entry(folder.id, remote.path);
    final relation = local == null
        ? -1
        : comparePeerClocks(local.clock, remote.clock);
    if (relation == 1) return null;
    if (relation == 0) {
      if (local!.hash != remote.hash || local.bytes != remote.bytes) {
        throw StateError('Одинаковая версия описывает разное содержимое');
      }
      return null;
    }
    if (relation == -1) {
      await _install(remote, local, read);
      return null;
    }
    final clock = mergePeerClocks(local!.clock, remote.clock);
    if (local.hash == remote.hash && local.bytes == remote.bytes) {
      await store.put(folder.id, local.withClock(clock));
      return null;
    }
    if (local.deleted || remote.deleted) {
      final changed = local.deleted ? remote : local;
      if (local.deleted) {
        await _install(changed.withClock(clock), local, read);
      } else {
        await store.put(folder.id, changed.withClock(clock));
      }
      return '${remote.path}: конкурентное удаление и изменение; изменённый файл сохранён';
    }
    // Content hashes provide a clock-independent, deterministic winner.
    final remoteWins = remote.hash!.compareTo(local.hash!) > 0;
    final loser = remoteWins ? local : remote;
    final conflict = loser.withClock(clock, path: peerConflictPath(loser));
    final copyHash = await files.hash(conflict.path);
    if (copyHash != null && copyHash != conflict.hash) {
      throw StateError('Имя конфликтной копии занято: ${conflict.path}');
    }
    if (copyHash == null) {
      await _install(
        conflict,
        null,
        remoteWins
            ? (path, hash, offset, count) =>
                  files.read(loser.path, offset, count)
            : read,
        sourcePath: loser.path,
      );
    } else {
      await store.put(folder.id, conflict);
    }
    if (remoteWins) {
      await _install(remote.withClock(clock), local, read);
    } else {
      await store.put(folder.id, local.withClock(clock));
    }
    return '${remote.path}: сохранены обе версии (${conflict.path})';
  }
}
