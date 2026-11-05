import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../media/asset_store.dart';
import '../media/library_folder_preference.dart';
import '../media/library_recovery.dart';
import 'audio_catalog.dart';
import 'audio_folder.dart';

String audioRootKey(String root) =>
    'audio-library-root:${sha256.convert(utf8.encode(root))}';
String _sourceKey(String source) =>
    'audio-folder:${sha256.convert(utf8.encode(source))}';

class AudioRoot {
  final String key;
  final Map<String, dynamic> data;
  AudioRoot(this.key, this.data);
  String get path => data['root'] as String;
  String get title => data['title'] as String;
  String get mode => data['mode'] as String? ?? 'folders';
  List<String> get bookIds => (data['bookIds'] as List).cast<String>();
}

class RootRefreshResult {
  final int added, updated;
  final List<String> warnings;
  final int found, supported, unsupported, errors;
  RootRefreshResult(
    this.added,
    this.updated,
    this.warnings, {
    this.found = 0,
    this.supported = 0,
    this.unsupported = 0,
    this.errors = 0,
  });
  String get message =>
      'Найдено файлов: $found, аудиофайлов: $supported. Добавлено книг: $added, обновлено книг: $updated. Пропущено неподдерживаемых: $unsupported, ошибок: $errors.${warnings.isEmpty ? '' : '\n${warnings.join('\n')}'}';
}

class AudioRoots {
  final AssetStore assets;
  AudioRoots(this.assets);
  Future<List<AudioRoot>> list() async => [
    for (final row
        in await assets.repository.db
            .customSelect(
              "SELECT key,value FROM metadata WHERE key>='audio-library-root:' AND key<'audio-library-root;' ORDER BY key",
            )
            .get())
      AudioRoot(
        row.read<String>('key'),
        jsonDecode(row.read<String>('value')) as Map<String, dynamic>,
      ),
  ];

  Future<void> rename(AudioRoot root, String title) async {
    final clean = title.trim();
    if (clean.isEmpty || clean.length > 500) {
      throw ArgumentError('Название: от 1 до 500 символов');
    }
    await assets.repository.setMeta(
      root.key,
      jsonEncode({...root.data, 'title': clean, 'displayTitle': clean}),
    );
    assets.repository.notifyExternalChange();
  }

  Future<void> remove(AudioRoot root) async {
    await assets.repository.db.transaction(() async {
      await LibraryFolderPreference(
        assets.repository,
        reading: false,
      ).replace(root.key, null);
      final others = (await list())
          .where((r) => r.key != root.key)
          .expand((r) => r.bookIds)
          .toSet();
      for (final id in root.bookIds) {
        if (!others.contains(id)) {
          await assets.repository.setMeta('audio-library-hidden:$id', '1');
        }
      }
      await assets.repository.db.customStatement(
        'DELETE FROM metadata WHERE key=?',
        [root.key],
      );
    });
    assets.repository.notifyExternalChange();
  }

  Future<RootRefreshResult> refresh(
    AudioRoot root, {
    AudioFolder? replacement,
  }) async {
    final scan = replacement ?? await rescanAudioFolder(root.path);
    final newKey = audioRootKey(scan.root!);
    if (newKey != root.key && (await list()).any((r) => r.key == newKey)) {
      throw StateError('Эта папка уже подключена');
    }
    var mode = root.mode;
    if (!root.data.containsKey('mode')) {
      final bindings = await assets.repository.db
          .customSelect(
            "SELECT key,value FROM metadata WHERE key>='audio-folder:' AND key<'audio-folder;'",
          )
          .get();
      final known = {
        for (final row in bindings)
          if (root.bookIds.contains(row.read<String>('value')))
            row.read<String>('key'),
      };
      var best = 0;
      for (final candidateMode in ['folders', 'files', 'single']) {
        final candidates = groupAudioCatalog(scan, mode: candidateMode);
        final score = candidates
            .where(
              (d) => known.contains(
                _sourceKey(
                  d.relativeFolder.isEmpty && candidates.length == 1
                      ? root.path
                      : '${root.path}#pepehub-book=${Uri.encodeComponent(d.relativeFolder)}',
                ),
              ),
            )
            .length;
        if (score > best) {
          best = score;
          mode = candidateMode;
        }
      }
    }
    final drafts = groupAudioCatalog(scan, mode: mode);
    var added = 0, updated = 0, errors = 0;
    final ids = {...root.bookIds}, seen = <String>{}, warnings = <String>[];
    final repo = assets.repository;
    await repo.db.transaction(() async {
      for (final draft in drafts) {
        String source(String base) =>
            draft.relativeFolder.isEmpty && drafts.length == 1
            ? base
            : '$base#pepehub-book=${Uri.encodeComponent(draft.relativeFolder)}';
        // Legacy 0.5.3 roots have no per-group index; their source bindings are
        // sufficient for a moved root whose internal book structure is intact.
        var oldId = await repo.meta(_sourceKey(source(root.path)));
        if (oldId != null && !root.bookIds.contains(oldId)) oldId = null;
        if (oldId == null && draft.relativeFolder.isEmpty) {
          for (final alternative in [root.path, '${root.path}#pepehub-book=']) {
            final candidate = await repo.meta(_sourceKey(alternative));
            if (candidate != null && root.bookIds.contains(candidate)) {
              oldId = candidate;
              break;
            }
          }
        }
        try {
          final asset = await assets.connectAudioFolder(
            draft.files,
            root: source(scan.root!),
            title: draft.title,
            replaceBookId: oldId,
          );
          ids.add(asset.bookId);
          seen.add(asset.bookId);
          await repo.setMeta('audio-source-missing:${asset.bookId}', '0');
          await repo.setMeta(
            'audio-source-path:${asset.bookId}',
            jsonEncode({'relativePath': draft.relativeFolder}),
          );
          await repo.setMeta(
            'audio-library-hidden:${asset.bookId}',
            await repo.meta('audio-user-hidden:${asset.bookId}') == '1'
                ? '1'
                : '0',
          );
          if (oldId == null) {
            added++;
          } else {
            updated++;
          }
        } catch (e) {
          errors++;
          if (oldId != null) seen.add(oldId);
          warnings.add('${draft.title}: $e');
        }
      }
      for (final id in root.bookIds.where((id) => !seen.contains(id))) {
        await repo.setMeta('audio-source-missing:$id', '1');
        final book = await repo.record(id);
        warnings.add(
          '${book?.title ?? id}: не найдена; карточка и прогресс сохранены.',
        );
      }
      // Keep the old root intact if relocation would strand known books.
      if (newKey != root.key && warnings.isNotEmpty) {
        throw StateError('Замена пути отменена: ${warnings.join('\n')}');
      }
      await repo.setMeta(
        newKey,
        jsonEncode({
          ...root.data,
          'root': scan.root,
          'mode': mode,
          'bookIds': ids.toList(),
          'lastScan': DateTime.now().toUtc().toIso8601String(),
          'warnings': warnings,
          'lastReport': {
            'found': scan.foundFiles,
            'supported': scan.files.length,
            'added': added,
            'updated': updated,
            'unsupported': scan.unsupportedFiles,
            'errors': errors,
            'missing': root.bookIds.where((id) => !seen.contains(id)).length,
          },
        }),
      );
      if (newKey != root.key) {
        await LibraryFolderPreference(
          repo,
          reading: false,
        ).replace(root.key, newKey);
        await repo.db.customStatement('DELETE FROM metadata WHERE key=?', [
          root.key,
        ]);
      }
    });
    try {
      await recoverAudioRoot(
        assets,
        AudioRoot(
          newKey,
          jsonDecode((await repo.meta(newKey))!) as Map<String, dynamic>,
        ),
      );
    } finally {
      repo.notifyExternalChange();
    }
    return RootRefreshResult(
      added,
      updated,
      warnings,
      found: scan.foundFiles,
      supported: scan.files.length,
      unsupported: scan.unsupportedFiles,
      errors: errors,
    );
  }
}
