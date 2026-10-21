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
  final String? remoteDevice;
  final void Function()? ensureAllowed;
  final void Function(String path, int checked)? onScan;
  final void Function(String path, int bytes, int total)? onTransfer;
  final void Function(String path, String phase)? onPhase;
  PeerReplica({
    required this.store,
    required this.folder,
    required this.device,
    required this.files,
    required this.work,
    this.remoteDevice,
    this.ensureAllowed,
    this.onScan,
    this.onTransfer,
    this.onPhase,
  });

  Future<Map<String, PeerFileEntry>> scan({
    bool forceHash = false,
    Set<String> invalidated = const {},
  }) async {
    // Collect the entire scan before recording missing paths as deletions.
    final disk = await files.scan(
          onProgress: onScan,
          cached: await store.scanCache(folder),
          invalidated: invalidated,
          forceHash: forceHash,
        ),
        old = await store.entries(folder.id);
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
      await store.saveScanCache(folder, disk);
    });
    final entries = await store.entries(folder.id);
    for (final request in await store.pendingDeletions(folder: folder.id)) {
      final current = entries[request.path];
      if (current == null ||
          current.hash != request.local.hash ||
          comparePeerClocks(current.clock, request.local.clock) != 0) {
        await store.clearDeletion(folder.id, request.path);
      }
    }
    return entries;
  }

  Future<File?> _legacyStage(PeerFileEntry entry) async {
    final directory = Directory(p.join(work.path, folder.id));
    if (await FileSystemEntity.type(work.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        await FileSystemEntity.type(directory.path, followLinks: false) !=
            FileSystemEntityType.directory) {
      return null;
    }
    final file = File(p.join(directory.path, '${peerStageKey(entry)}.part'));
    return await FileSystemEntity.type(file.path, followLinks: false) ==
            FileSystemEntityType.file
        ? file
        : null;
  }

  /// Reclaim only old private transfer copies whose contents already exist in
  /// the fully scanned destination. Missing files/unknown caches are retained.
  Future<int> cleanupLegacyStages(Map<String, PeerFileEntry> entries) async {
    if (await FileSystemEntity.type(
          p.join(work.path, folder.id),
          followLinks: false,
        ) !=
        FileSystemEntityType.directory) {
      return 0;
    }
    var removed = 0;
    for (final entry in entries.values.where((e) => !e.deleted)) {
      ensureAllowed?.call();
      final legacy = await _legacyStage(entry);
      if (legacy != null) {
        removed += await legacy.length();
        await legacy.delete();
      }
    }
    return removed;
  }

  Future<PeerStagingFile> _stage(
    PeerFileEntry entry,
    PeerChunkReader read, {
    String? sourcePath,
  }) async {
    final file = await files.stage(entry);
    var offset = await file.prepare();
    if (offset > entry.bytes) {
      await file.reset();
      offset = 0;
    }
    final legacy = await _legacyStage(
      sourcePath == null
          ? entry
          : PeerFileEntry(
              path: sourcePath,
              hash: entry.hash,
              bytes: entry.bytes,
              clock: entry.clock,
            ),
    );
    if (legacy != null) {
      final length = await legacy.length();
      if (length > offset && length <= entry.bytes) {
        onPhase?.call(entry.path, 'Перенос прежней докачки в общую папку');
        await for (final chunk in legacy.openRead(offset, length)) {
          ensureAllowed?.call();
          for (var n = 0; n < chunk.length; n += peerChunkSize) {
            final bytes = chunk.sublist(
              n,
              (n + peerChunkSize).clamp(0, chunk.length),
            );
            await file.append(offset, bytes);
            offset += bytes.length;
          }
        }
        await legacy.delete();
      }
    }
    onPhase?.call(
      entry.path,
      offset > 0 ? 'Возобновление загрузки' : 'Получение файла',
    );
    onTransfer?.call(entry.path, offset, entry.bytes);
    while (offset < entry.bytes) {
      ensureAllowed?.call();
      final count = (entry.bytes - offset).clamp(1, peerChunkSize);
      final bytes = await read(
        sourcePath ?? entry.path,
        entry.hash!,
        offset,
        count,
      );
      if (bytes.isEmpty || bytes.length > count) {
        throw StateError('Источник вернул неполный или неверный блок');
      }
      await file.append(offset, bytes);
      offset += bytes.length;
      onTransfer?.call(entry.path, offset, entry.bytes);
    }
    onPhase?.call(entry.path, 'Проверка контрольной суммы');
    if (await file.hash() != entry.hash) {
      await file.discard();
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
      onPhase?.call(entry.path, 'Перенос удаления в историю версий');
      ensureAllowed?.call();
      await files.remove(entry.path, previous?.hash);
    } else {
      final stage = await _stage(entry, read, sourcePath: sourcePath);
      ensureAllowed?.call();
      onPhase?.call(entry.path, 'Сохранение проверенного файла');
      await stage.publish(previous?.hash);
      final legacy = await _legacyStage(entry);
      if (legacy != null) await legacy.delete();
    }
    await store.put(folder.id, entry);
    onPhase?.call(
      entry.path,
      entry.deleted
          ? 'Удаление применено; прежняя версия сохранена'
          : 'Файл сохранён',
    );
  }

  /// Returns a conflict description when both independent versions were retained.
  Future<String?> apply(PeerFileEntry remote, PeerChunkReader read) async {
    ensureAllowed?.call();
    final local = await store.entry(folder.id, remote.path);
    final pending = await store.pendingDeletion(folder.id, remote.path);
    if (pending != null &&
        !remote.deleted &&
        comparePeerClocks(remote.clock, pending.remote.clock) != -1) {
      await store.clearDeletion(folder.id, remote.path);
    }
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
      if (remote.deleted && local != null && !local.deleted) {
        await store.requestDeletion(
          PeerPendingDeletion(
            folder: folder.id,
            device: remoteDevice ?? remote.clock.keys.first,
            local: local,
            remote: remote,
            time:
                pending != null &&
                    comparePeerClocks(pending.remote.clock, remote.clock) == 0
                ? pending.time
                : DateTime.now(),
          ),
        );
        return '${remote.path}: удаление ожидает подтверждения на этом устройстве';
      }
      await _install(remote, local, read);
      await store.clearDeletion(folder.id, remote.path);
      return null;
    }
    final clock = mergePeerClocks(local!.clock, remote.clock);
    if (local.hash == remote.hash && local.bytes == remote.bytes) {
      await store.put(folder.id, local.withClock(clock));
      return null;
    }
    if (local.deleted || remote.deleted) {
      await store.clearDeletion(folder.id, remote.path);
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

  Future<void> resolveDeletion(
    PeerPendingDeletion request, {
    required bool delete,
  }) async {
    ensureAllowed?.call();
    final currentRequest = await store.pendingDeletion(folder.id, request.path);
    if (currentRequest == null ||
        comparePeerClocks(currentRequest.remote.clock, request.remote.clock) !=
            0) {
      throw StateError('Запрос удаления изменился. Обновите список.');
    }
    final entries = await scan(), local = entries[request.path];
    if (local == null ||
        local.hash != request.local.hash ||
        comparePeerClocks(local.clock, request.local.clock) != 0) {
      await store.clearDeletion(folder.id, request.path);
      throw StateError(
        'Файл изменился после запроса удаления. Изменённая версия сохранена; повторите синхронизацию.',
      );
    }
    ensureAllowed?.call();
    if (await files.hash(request.path) != local.hash) {
      throw StateError('Файл изменился во время подтверждения');
    }
    if (delete) {
      await _install(
        request.remote,
        local,
        (_, _, _, _) async => throw StateError('Удаление не загружает файлы'),
      );
    } else {
      final clock = mergePeerClocks(local.clock, request.remote.clock);
      clock[device] = await store.nextCounter();
      await store.put(folder.id, local.withClock(clock));
    }
    await store.clearDeletion(folder.id, request.path);
  }
}
