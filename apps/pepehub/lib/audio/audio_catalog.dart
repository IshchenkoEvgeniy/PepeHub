import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;

import '../media/asset_store.dart';
import '../media/library_recovery.dart';
import 'audio_roots.dart';
import 'audio_folder.dart';
import 'audio_import.dart';
import 'audio_library_repository.dart';
import 'models.dart';

class CatalogFile extends FolderAudioFile {
  final XFile original;
  CatalogFile(this.original, String label) : super(original.path, label);
  @override
  Future<int> length() => original.length();
  @override
  Stream<Uint8List> openRead([int? start, int? end]) =>
      original.openRead(start, end);
}

class AudioBookDraft {
  final String relativeFolder;
  String title;
  final List<XFile> files;
  bool selected = true;
  AudioBookDraft(this.relativeFolder, this.title, this.files);
}

/// Heuristics are always shown before saving. Disc folders belong to their
/// parent; unrelated book folders never collapse into a single root book.
List<AudioBookDraft> groupAudioCatalog(
  AudioFolder folder, {
  String mode = 'folders',
}) {
  final groups = <String, List<XFile>>{};
  final disc = RegExp(
    r'^(?:(?:cd|disc|disk|диск|часть|part|том)\s*[-_. ]*\d+|audio|аудио|tracks|chapters)$',
    caseSensitive: false,
  );
  for (final file in folder.files) {
    final relative = file.name.replaceAll('\\', '/');
    if (relative.split('/').any(isAudioSupportFolder)) continue;
    var parent = p.posix.dirname(relative);
    if (parent == '.') parent = '';
    while (parent.isNotEmpty && disc.hasMatch(p.posix.basename(parent))) {
      parent = p.posix.dirname(parent);
      if (parent == '.') parent = '';
    }
    final key = mode == 'single'
        ? ''
        : mode == 'files'
        ? relative
        : parent;
    final label = mode == 'folders' && key.isNotEmpty
        ? relative.substring(key.length + 1)
        : relative;
    groups.putIfAbsent(key, () => []).add(CatalogFile(file, label));
  }
  final result = [
    for (final entry in groups.entries)
      AudioBookDraft(
        entry.key,
        entry.key.isEmpty
            ? folder.title
            : mode == 'files'
            ? p.posix.basenameWithoutExtension(entry.key)
            : p.posix.basename(entry.key),
        entry.value..sort((a, b) => naturalAudioOrder(a.name, b.name)),
      ),
  ];
  result.sort((a, b) => naturalAudioOrder(a.relativeFolder, b.relativeFolder));
  return result;
}

Future<int> connectAudioCatalog(
  AssetStore assets,
  AudioFolder root,
  List<AudioBookDraft> drafts, {
  String mode = 'folders',
}) async {
  final selected = drafts.where((d) => d.selected).toList();
  if (selected.isEmpty) throw StateError('Выберите хотя бы одну книгу');
  final repository = assets.repository;
  final count = await repository.db.transaction(() async {
    final oldId = await repository.meta(
      'audio-folder:${sha256.convert(utf8.encode(root.root!))}',
    );
    final oldTracks = oldId == null
        ? <LocalAsset>[]
        : await assets.audioTracks(oldId);
    final createdTracks = <LocalAsset>[];
    final ids = <String>[];
    for (final draft in selected) {
      final source = draft.relativeFolder.isEmpty && drafts.length == 1
          ? root.root!
          : '${root.root!}#pepehub-book=${Uri.encodeComponent(draft.relativeFolder)}';
      final asset = await assets.connectAudioFolder(
        draft.files,
        root: source,
        title: draft.title,
      );
      ids.add(asset.bookId);
      await repository.setMeta('audio-library-hidden:${asset.bookId}', '0');
      createdTracks.addAll(await assets.audioTracks(asset.bookId));
    }
    // Replace the old accidental aggregate only when every original source is
    // represented. Keep its sessions and records, and preserve its locator.
    final byPath = {for (final track in createdTracks) track.path: track};
    if (oldId != null &&
        !ids.contains(oldId) &&
        oldTracks.isNotEmpty &&
        oldTracks.every((t) => byPath.containsKey(t.path))) {
      final library = AudioLibraryRepository(repository.db);
      final oldProgress = await library.progressForTrack(oldTracks.first.id);
      final oldPath = oldTracks
          .firstWhere((t) => t.id == oldProgress.locator.trackId)
          .path;
      final target = byPath[oldPath]!;
      final targetProgress = await library.progressForTrack(target.id);
      final hasProgress = await repository.db
          .customSelect(
            'SELECT 1 FROM audio_progress WHERE edition_id=?',
            variables: [Variable(targetProgress.locator.editionId)],
          )
          .get();
      if (hasProgress.isEmpty) {
        await library.saveProgress(
          AudioProgress(
            AudioLocator(
              bookId: target.bookId,
              editionId: targetProgress.locator.editionId,
              trackId: target.id,
              positionMs: oldProgress.locator.positionMs,
              manifestRevision: targetProgress.locator.manifestRevision,
            ),
            oldProgress.speed,
          ),
        );
      }
      await repository.setMeta('audio-library-superseded:$oldId', '1');
    }
    final key = 'audio-library-root:${sha256.convert(utf8.encode(root.root!))}';
    final previous = await repository.meta(key);
    final prior = previous == null
        ? <String, dynamic>{}
        : jsonDecode(previous) as Map<String, dynamic>;
    await repository.setMeta(
      key,
      jsonEncode({
        ...prior,
        'root': root.root,
        'title': prior['displayTitle'] ?? root.title,
        'mode': mode,
        'bookIds': {...(prior['bookIds'] as List? ?? []), ...ids}.toList(),
      }),
    );
    return ids.length;
  });
  final key = audioRootKey(root.root!);
  await recoverAudioRoot(
    assets,
    AudioRoot(
      key,
      jsonDecode((await repository.meta(key))!) as Map<String, dynamic>,
    ),
  );
  return count;
}
