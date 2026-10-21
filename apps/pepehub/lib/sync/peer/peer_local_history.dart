import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'peer_history.dart';

class PeerLocalHistory implements PeerHistoryStorage {
  final Future<String> Function() checkedBase;
  final PeerHistorySettings settings;
  final DateTime Function() now;
  PeerLocalHistory(this.checkedBase, this.settings, {DateTime Function()? now})
    : now = now ?? DateTime.now;

  Future<Directory?> directory({bool create = false}) async {
    var current = await checkedBase();
    for (final name in ['.pepehub', 'p2p', 'versions']) {
      current = p.join(current, name);
      final kind = await FileSystemEntity.type(current, followLinks: false);
      if (kind == FileSystemEntityType.notFound) {
        if (!create) return null;
        await Directory(current).create();
      } else if (kind != FileSystemEntityType.directory) {
        throw StateError('История заменена ссылкой или файлом');
      }
    }
    return Directory(current);
  }

  String name(String original, {DateTime? at}) =>
      'v1-${(at ?? now()).millisecondsSinceEpoch}-${const Uuid().v4().replaceAll('-', '')}-${p.basename(original).substring(0, p.basename(original).length.clamp(0, 140))}';

  Future<void> _checkFile(File file) async {
    final base = await checkedBase();
    if (!p.isWithin(base, file.path)) {
      throw StateError('История вне общей папки');
    }
    final parts = p.split(p.relative(file.path, from: base));
    var current = base;
    for (var i = 0; i < parts.length; i++) {
      current = p.join(current, parts[i]);
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type !=
          (i == parts.length - 1
              ? FileSystemEntityType.file
              : FileSystemEntityType.directory)) {
        throw StateError('Файл истории изменился или заменён ссылкой');
      }
    }
  }

  @override
  Future<PeerHistorySummary> maintainHistory({
    bool migrate = false,
    bool prune = false,
    bool clear = false,
  }) async {
    settings.validate();
    final base = await checkedBase();
    final warnings = <String>[];
    var moved = 0, removed = 0, reclaimed = 0, unknown = 0;
    final records = <({File file, DateTime at, int bytes, bool legacy})>[];
    final archive = await directory();
    if (archive != null) {
      await for (final entity in archive.list(followLinks: false)) {
        final at = peerHistoryTime(p.basename(entity.path));
        if (entity is File &&
            at != null &&
            await FileSystemEntity.type(entity.path, followLinks: false) ==
                FileSystemEntityType.file) {
          records.add((
            file: entity,
            at: at,
            bytes: await entity.length(),
            legacy: false,
          ));
        } else {
          unknown++;
        }
      }
    }
    if (migrate || clear) {
      var visited = 0;
      Future<void> visit(Directory parent, int depth) async {
        if (depth > 32) throw StateError('Слишком глубокая папка истории');
        await for (final entity in parent.list(followLinks: false)) {
          if (++visited > 50000) {
            throw StateError('Больше 50000 элементов папки');
          }
          final leaf = p.basename(entity.path);
          final legacy = RegExp(r'^\.pepehub-version-\d{13}-[a-f0-9]{8}-(.+)$')
              .firstMatch(leaf);
          if (entity is File &&
              legacy != null &&
              await FileSystemEntity.type(entity.path, followLinks: false) ==
                  FileSystemEntityType.file) {
            final at = peerHistoryTime(leaf)!;
            var file = entity, outside = true;
            if (migrate && !clear) {
              try {
                await _checkFile(file);
                final target = p.join(
                  (await directory(create: true))!.path,
                  name(legacy[1]!, at: at),
                );
                if (await FileSystemEntity.type(target, followLinks: false) !=
                    FileSystemEntityType.notFound) {
                  throw StateError('Имя истории уже занято');
                }
                file = await file.rename(target);
                outside = false;
                moved++;
              } catch (e) {
                warnings.add('Не перенесена копия $leaf: $e');
              }
            }
            records.add((
              file: file,
              at: at,
              bytes: await file.length(),
              legacy: outside,
            ));
          } else if (entity is Directory &&
              !leaf.toLowerCase().startsWith('.pepehub') &&
              !leaf.toLowerCase().startsWith('.syncthing') &&
              await FileSystemEntity.type(entity.path, followLinks: false) ==
                  FileSystemEntityType.directory) {
            await visit(entity, depth + 1);
          }
        }
      }

      await visit(Directory(base), 0);
    }
    records.sort((a, b) {
      final order = a.at.compareTo(b.at);
      return order == 0 ? a.file.path.compareTo(b.file.path) : order;
    });
    var total = records
        .where((r) => !r.legacy)
        .fold(0, (sum, r) => sum + r.bytes);
    final remaining = <({File file, DateTime at, int bytes, bool legacy})>[];
    final cutoff = now().subtract(Duration(days: settings.maxDays));
    for (final entry in records) {
      final remove =
          clear ||
          prune &&
              settings.enabled &&
              !entry.legacy &&
              (entry.at.isBefore(cutoff) || total > settings.maxBytes);
      if (remove) {
        try {
          await _checkFile(entry.file);
          await entry.file.delete();
          if (!entry.legacy) total -= entry.bytes;
          removed++;
          reclaimed += entry.bytes;
          continue;
        } catch (e) {
          warnings.add('Не удалена копия ${p.basename(entry.file.path)}: $e');
        }
      }
      remaining.add(entry);
    }
    return PeerHistorySummary(
      files: remaining.length,
      bytes: remaining.fold(0, (sum, r) => sum + r.bytes),
      legacy: remaining.where((r) => r.legacy).length,
      unknown: unknown,
      moved: moved,
      removed: removed,
      reclaimed: reclaimed,
      warnings: warnings.take(20).toList(),
    );
  }
}
