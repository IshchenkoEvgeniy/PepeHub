import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../media/asset_store.dart';
import 'audio_roots.dart';
import 'audio_folder.dart';
import 'audio_catalog.dart';
import 'audio_sidecar.dart';

String binding(String root, String relative) =>
    'audio-folder:${sha256.convert(utf8.encode('$root#pepehub-book=${Uri.encodeComponent(relative)}'))}';
void validateFolderPart(String name) {
  if (name.isEmpty ||
      name.length > 200 ||
      name == '.' ||
      name == '..' ||
      RegExp(r'[<>:"/\\|?*\x00-\x1f]').hasMatch(name) ||
      name.endsWith('.') ||
      name.endsWith(' ') ||
      isAudioSupportFolder(name) ||
      RegExp(
        r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
        caseSensitive: false,
      ).hasMatch(name)) {
    throw ArgumentError('Недопустимое имя папки');
  }
}

void validateRelativeFolder(String relative, {bool allowEmpty = false}) {
  if (relative.isEmpty && allowEmpty) return;
  for (final part in relative.split('/')) {
    validateFolderPart(part);
  }
}

class BookFolderLocation {
  final AudioRoot root;
  final String relative;
  BookFolderLocation(this.root, this.relative);
}

class BookFolderOperations {
  final AssetStore assets;
  BookFolderOperations(this.assets);
  String _pending(String id) => 'book-folder-operation:$id';
  Future<bool> hasPending(String id) async =>
      await assets.repository.meta(_pending(id)) != null;
  Future<BookFolderLocation> locate(String id) async {
    final key = await assets.repository.meta('audio-folder-book:$id');
    final matches = <BookFolderLocation>[];
    for (final root in await AudioRoots(assets).list()) {
      if (!root.bookIds.contains(id) || root.mode != 'folders') continue;
      final drafts = groupAudioCatalog(await rescanAudioFolder(root.path));
      for (final draft in drafts) {
        if (draft.relativeFolder.isNotEmpty &&
            binding(root.path, draft.relativeFolder) == key) {
          if (drafts.any(
            (d) => d.relativeFolder.startsWith('${draft.relativeFolder}/'),
          )) {
            throw StateError(
              'Внутри папки есть другие книги. Перемещайте отдельные папки.',
            );
          }
          matches.add(BookFolderLocation(root, draft.relativeFolder));
        }
      }
    }
    if (matches.length != 1) {
      throw StateError(
        'Нужна отдельная папка книги внутри подключённого корня. Сначала обновите библиотеку.',
      );
    }
    return matches.single;
  }

  Future<String> relocate(
    String bookId,
    BookFolderLocation source,
    AudioRoot targetRoot,
    String targetRelative,
  ) async {
    validateRelativeFolder(source.relative);
    validateRelativeFolder(targetRelative);
    if (RegExp(
      r'^(?:(?:cd|disc|disk|диск|часть|part|том)\s*[-_. ]*\d+|audio|аудио|tracks|chapters)$',
      caseSensitive: false,
    ).hasMatch(p.posix.basename(targetRelative))) {
      throw ArgumentError(
        'Это имя используется для частей книги. Выберите другое имя папки книги.',
      );
    }
    final fresh = groupAudioCatalog(await rescanAudioFolder(source.root.path))
        .where((d) => d.relativeFolder == source.relative)
        .firstOrNull;
    final existingTracks = await assets.audioTracks(bookId);
    if (fresh == null || fresh.files.length != existingTracks.length) {
      throw StateError(
        'Состав книги изменился. Обновите библиотеку перед перемещением.',
      );
    }
    for (final track in existingTracks) {
      final file = fresh.files
          .where((f) => f.name == track.filename)
          .firstOrNull;
      if (file == null ||
          (track.bytes > 0 && await file.length() != track.bytes)) {
        throw StateError('Файлы книги изменились. Перемещение не начато.');
      }
    }

    if (await hasPending(bookId)) {
      throw StateError('Сначала завершите предыдущую операцию');
    }
    if (targetRoot.mode != 'folders') {
      throw StateError('Целевой корень должен разделять книги по папкам');
    }
    if (source.root.path == targetRoot.path &&
        source.relative == targetRelative) {
      throw StateError('Папка уже находится здесь');
    }
    final rename =
        source.root.path == targetRoot.path &&
        p.posix.dirname(source.relative) == p.posix.dirname(targetRelative);
    if (!rename &&
        p.posix.basename(source.relative) != p.posix.basename(targetRelative)) {
      throw StateError('Переименование и перенос выполняются отдельно');
    }
    if (source.root.path == targetRoot.path &&
        targetRelative.startsWith('${source.relative}/')) {
      throw StateError('Нельзя переместить папку внутрь себя');
    }
    await saveAudioSidecar(
      assets,
      AudioFolder(source.root.title, [], root: source.root.path),
    );
    final operation = {
      'bookId': bookId,
      'sourceRoot': source.root.path,
      'source': source.relative,
      'targetRoot': targetRoot.path,
      'target': targetRelative,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    };
    await assets.repository.setMeta(_pending(bookId), jsonEncode(operation));
    try {
      if (source.root.path.startsWith('content://')) {
        if (!targetRoot.path.startsWith('content://')) {
          throw StateError('Разные типы хранилищ');
        }
        await audioFolderChannel.invokeMethod<void>('relocate', operation);
      } else {
        final from = await checkedDirectory(source.root.path, source.relative);
        final parentRelative = p.posix.dirname(targetRelative);
        final parent = await checkedDirectory(
          targetRoot.path,
          parentRelative == '.' ? '' : parentRelative,
        );
        final target = p.join(parent, p.posix.basename(targetRelative));
        if (p.equals(from, target) || p.isWithin(from, target)) {
          throw StateError('Недопустимое назначение');
        }
        if (await FileSystemEntity.type(target, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw StateError('Папка назначения уже существует');
        }
        // Rename performs a filesystem move; never fall back to copying gigabytes.
        await Directory(from).rename(target);
      }
      return await recover(bookId);
    } catch (e) {
      throw StateError(
        '$e. Операция записана: откройте меню папки и нажмите «Проверить незавершённую операцию».',
      );
    }
  }

  Future<String> recover(String bookId) async {
    final raw = await assets.repository.meta(_pending(bookId));
    if (raw == null) return 'Нет незавершённых операций';
    final op = jsonDecode(raw) as Map<String, dynamic>;
    final roots = await AudioRoots(assets).list();
    final source = roots.where((r) => r.path == op['sourceRoot']).firstOrNull;
    final target = roots.where((r) => r.path == op['targetRoot']).firstOrNull;
    if (source == null || target == null) {
      throw StateError('Подключите исходный и целевой корни');
    }
    final targetDrafts = groupAudioCatalog(
      await rescanAudioFolder(target.path),
    );
    final draft = targetDrafts
        .where((d) => d.relativeFolder == op['target'])
        .firstOrNull;
    final sourceDrafts = source.path == target.path
        ? targetDrafts
        : groupAudioCatalog(await rescanAudioFolder(source.path));
    final original = sourceDrafts
        .where((d) => d.relativeFolder == op['source'])
        .firstOrNull;
    if (original != null) {
      await assets.repository.db.customStatement(
        'DELETE FROM metadata WHERE key=?',
        [_pending(bookId)],
      );
      return 'Папка осталась на прежнем месте. Можно повторить операцию.';
    }
    if (draft == null || original != null) {
      throw StateError(
        'Нельзя однозначно определить перемещённую папку; данные сохранены, укажите путь заново',
      );
    }
    await assets.repository.db.transaction(() async {
      await assets.connectAudioFolder(
        draft.files,
        root:
            '${target.path}#pepehub-book=${Uri.encodeComponent(draft.relativeFolder)}',
        title: draft.title,
        replaceBookId: bookId,
      );
      if (source.key != target.key) {
        await assets.repository.setMeta(
          source.key,
          jsonEncode({
            ...source.data,
            'bookIds': source.bookIds.where((id) => id != bookId).toList(),
          }),
        );
      }
      await assets.repository.setMeta(
        target.key,
        jsonEncode({
          ...target.data,
          'bookIds': {...target.bookIds, bookId}.toList(),
        }),
      );
      // Re-export history into the destination root; immutable packet IDs deduplicate retries.
      await assets.repository.setMeta(
        'audio-journal-export:${target.key}',
        '0',
      );
      await assets.repository.db.customStatement(
        'DELETE FROM metadata WHERE key=?',
        [_pending(bookId)],
      );
    });
    try {
      await saveAudioSidecar(
        assets,
        AudioFolder(target.title, [], root: target.path),
      );
    } catch (e) {
      return 'Папка перемещена, база обновлена. Не удалось записать новый снимок: $e';
    }
    return 'Папка перемещена. Главы, прогресс и закладки сохранены.';
  }
}

Future<String> checkedDirectory(String root, String relative) async {
  validateRelativeFolder(relative, allowEmpty: true);
  final base = await Directory(root).resolveSymbolicLinks();
  var candidate = base;
  for (final part in relative.isEmpty ? <String>[] : relative.split('/')) {
    candidate = p.join(candidate, part);
    if (await FileSystemEntity.type(candidate, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw StateError('Папка отсутствует или является ссылкой');
    }
  }
  final resolved = await Directory(candidate).resolveSymbolicLinks();
  if (!p.equals(base, resolved) && !p.isWithin(base, resolved)) {
    throw StateError('Путь выходит за пределы корня');
  }
  return resolved;
}
