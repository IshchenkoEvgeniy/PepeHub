import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../audio/audio_folder.dart';
import '../media/asset_store.dart';
import 'reading_roots.dart';
import 'reading_book_visibility.dart';

class ReadingBookSource {
  final String path, hash, name;
  final String? root;
  ReadingBookSource(this.path, this.hash, this.name, [this.root]);
}

class ReadingBookWriteAccessRequired implements Exception {
  final String? root;
  final String message;
  const ReadingBookWriteAccessRequired(this.root, this.message);
  @override
  String toString() => message;
}

String readingBookActionMessage(Object error) {
  if (error is PlatformException) {
    return error.message ?? 'Не удалось выполнить действие с файлом книги';
  }
  if (error is StateError) return error.message;
  return error.toString();
}

/// Visibility is local to this device. Removing a file is a separate,
/// explicitly confirmed action and never erases reading history.
class ReadingBookActions {
  final AssetStore assets;
  ReadingBookActions(this.assets);
  Future<bool> requestWriteAccess(
    ReadingBookWriteAccessRequired failure,
  ) async {
    if (failure.root == null) throw failure;
    return await audioFolderChannel.invokeMethod<bool>(
          'requestBookWriteAccess',
          {'root': failure.root},
        ) ??
        false;
  }

  Future<void> hide(String id, {bool hidden = true}) async {
    await assets.repository.db.transaction(() async {
      await assets.repository.setMeta(
        'reading-user-hidden:$id',
        hidden ? '1' : '0',
      );
      await assets.repository.setMeta(
        'reading-library-hidden:$id',
        hidden ? '1' : '0',
      );
    });
    assets.repository.notifyExternalChange();
  }

  Future<List<ReadingBookSource>> sources(String id) async {
    final rows = await assets.repository.db
        .customSelect(
          'SELECT * FROM local_assets WHERE book_id=?',
          variables: [Variable(id)],
        )
        .get();
    final result = <String, ReadingBookSource>{};
    for (final row in rows) {
      final asset = LocalAsset.fromRow(row);
      result[asset.path] = ReadingBookSource(
        asset.path,
        asset.hash,
        asset.filename,
      );
      final managed = await assets.managedBookCopy(asset);
      if (managed != null) {
        result[managed.path] = ReadingBookSource(
          managed.path,
          managed.hash,
          managed.filename,
        );
      }
    }
    final raw = await assets.repository.meta('reading-source-path:$id');
    if (raw != null && rows.isNotEmpty) {
      final value = jsonDecode(raw) as Map;
      final root = value['root'] as String,
          relative = value['relativePath'] as String;
      if ((await ReadingRoots(
        assets,
      ).list()).any((r) => r.path == root && r.bookIds.contains(id))) {
        final current = rows.map(LocalAsset.fromRow).first;
        if (root.startsWith('content:')) {
          final folder = await rescanAudioFolder(root, books: true);
          final source = folder.files
              .where((f) => f.name == relative)
              .firstOrNull;
          if (source != null) {
            result[source.path] = ReadingBookSource(
              source.path,
              current.hash,
              source.name,
              root,
            );
          }
        } else {
          if (p.posix.isAbsolute(relative) ||
              relative
                  .split('/')
                  .any((v) => v == '..' || v.isEmpty || v.contains('\\'))) {
            throw StateError('Недопустимый путь книги');
          }
          final path = p.normalize(p.joinAll([root, ...relative.split('/')]));
          if (!p.isWithin(root, path)) {
            throw StateError('Файл за пределами папки книг');
          }
          result[path] = ReadingBookSource(path, current.hash, relative, root);
        }
      }
    }
    return result.values.toList();
  }

  Future<void> _delete(
    ReadingBookSource source, {
    required bool checkOnly,
  }) async {
    if (source.path.startsWith('content:')) {
      try {
        await audioFolderChannel.invokeMethod<void>('deleteBookFile', {
          'uri': source.path,
          'hash': source.hash,
          'checkOnly': checkOnly,
        });
      } on PlatformException catch (error) {
        if (error.code != 'book_write_permission') rethrow;
        final details = error.details;
        throw ReadingBookWriteAccessRequired(
          details is Map ? details['root'] as String? : null,
          error.message ?? 'Нужен доступ на запись к папке книги',
        );
      }
      return;
    }
    final file = File(source.path);
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.file ||
        !p.equals(
          await file.resolveSymbolicLinks(),
          p.normalize(file.absolute.path),
        )) {
      throw StateError('Путь книги заменён ссылкой или папкой');
    }
    if ((await sha256.bind(file.openRead()).first).toString() != source.hash) {
      throw StateError('Файл изменился. Обновите папку книг перед удалением.');
    }
    if (!checkOnly) await file.delete();
  }

  Future<void> deleteForever(String id) async {
    final selected = await sources(id);
    for (final source in selected) {
      await _delete(source, checkOnly: true);
    }
    for (final source in selected) {
      await _delete(source, checkOnly: false);
    }
    // Only generated files under the application's own cache directories.
    for (final hash in selected.map((s) => s.hash).toSet()) {
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) continue;
      final cache = Directory(p.join(assets.directory.path, 'reading-cache'));
      if (await FileSystemEntity.type(cache.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        continue;
      }
      await for (final file in cache.list(followLinks: false)) {
        if (file is File && p.basename(file.path).startsWith('$hash.')) {
          await file.delete();
        }
      }
    }
    await assets.repository.db.transaction(
      () => ReadingBookVisibility(assets.repository).deleted(id, byUser: true),
    );
    assets.repository.notifyExternalChange();
  }

  Future<void> reveal(String id) async {
    final selected = await sources(id);
    if (selected.isEmpty) throw StateError('У книги нет локального файла');
    final source =
        selected.where((s) => s.root != null).firstOrNull ?? selected.first;
    if (source.path.startsWith('content:') || Platform.isAndroid) {
      await audioFolderChannel.invokeMethod<void>('revealBookFile', {
        'uri': source.path,
        'root': source.root,
      });
    } else if (Platform.isWindows) {
      final exists = await File(source.path).exists();
      final target = exists ? source.path : p.dirname(source.path);
      final result = await Process.run('explorer.exe', [
        if (exists) '/select,',
        p.windows.normalize(target),
      ]);
      // Explorer commonly returns 1 when it delegates to an existing window.
      if (result.exitCode != 0 && result.exitCode != 1) {
        throw StateError('Не удалось открыть Проводник');
      }
    } else {
      await Process.start(Platform.isMacOS ? 'open' : 'xdg-open', [
        if (Platform.isMacOS) '-R',
        Platform.isMacOS ? source.path : p.dirname(source.path),
      ]);
    }
  }
}
