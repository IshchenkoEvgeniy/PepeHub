import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;

import '../../audio/audio_folder.dart';
import '../../audio/audio_roots.dart';
import '../../media/asset_store.dart';
import '../../reader/book_formats.dart';
import '../../reader/reading_roots.dart';
import '../../video/video_folder_sync.dart';
import '../../video/video_import.dart';
import '../../video/video_repository.dart';
import 'peer_files.dart';
import 'peer_models.dart';

/// Register source references from the selected folder. This never invokes
/// book/audio import or copies media into AssetStore.directory.
class PeerLibraryConnector {
  final AssetStore assets;
  PeerLibraryConnector(this.assets);

  Future<List<String>> refresh(
    PeerFolder folder,
    Map<String, PeerFileEntry> entries, {
    void Function()? ensureAllowed,
  }) async {
    final reports = <String>[];
    final repo = assets.repository, files = peerFileSystem(folder.root);
    for (final kind in ['books', 'audio', 'video']) {
      if (folder.library != 'all' && folder.library != kind) continue;
      ensureAllowed?.call();
      final extensions = kind == 'books'
          ? bookExtensions
          : kind == 'audio'
          ? audioExtensions
          // Keep automatic audiobook routing stable. Music is included when
          // the user explicitly chooses the Media destination for this folder.
          : folder.library == 'video'
          ? mediaExtensions
          : videoExtensions;
      final selected =
          entries.values
              .where(
                (e) =>
                    !e.deleted &&
                    extensions.contains(
                      p.posix
                          .extension(e.path)
                          .toLowerCase()
                          .replaceFirst('.', ''),
                    ),
              )
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      final signature = peerDigest(
        utf8.encode(
          jsonEncode([
            folder.root,
            kind,
            for (final entry in selected) [entry.path, entry.hash],
          ]),
        ),
      );
      final key = 'peer-library-index:${folder.id}:$kind';
      final readingRoots = kind == 'books'
          ? await ReadingRoots(assets).list()
          : null;
      final audioRoots = kind == 'audio'
          ? await AudioRoots(assets).list()
          : null;
      final videos = VideoRepository(repo);
      final videoItems = kind == 'video' ? await videos.items() : null;
      final exists = kind == 'books'
          ? readingRoots!.any((r) => r.path == folder.root)
          : kind == 'audio'
          ? audioRoots!.any((r) => r.path == folder.root)
          : videoItems!.any((r) => r.root == folder.root);
      if (await repo.meta(key) == signature && exists) continue;
      if (selected.isEmpty && !exists) continue;
      final sourceFiles = <XFile>[];
      final videoSources = <VideoSourceDraft>[];
      for (final entry in selected) {
        ensureAllowed?.call();
        final source = await files.source(entry.path);
        if (source == null) {
          throw StateError(
            'Файл исчез до подключения к библиотеке: ${entry.path}',
          );
        }
        if (kind == 'video') {
          videoSources.add(videoDraft(source, entry.path));
        } else {
          sourceFiles.add(
            source.startsWith('content://')
                ? SafAudioFile(source, entry.path, entry.bytes)
                : FolderAudioFile(source, entry.path),
          );
        }
      }
      ensureAllowed?.call();
      if (kind == 'books') {
        await ReadingRoots(assets).connect(
          AudioFolder(folder.name, sourceFiles, root: folder.root),
          verified: {
            for (final entry in selected)
              entry.path: (hash: entry.hash!, bytes: entry.bytes),
          },
        );
        reports.add(
          'Папка подключена к «Книгам»: ${selected.length} файлов, без копирования в приложение.',
        );
      } else if (kind == 'audio') {
        final existing = audioRoots!
            .where((r) => r.path == folder.root)
            .firstOrNull;
        final result = await AudioRoots(assets).refresh(
          existing ??
              AudioRoot(audioRootKey(folder.root), {
                'root': folder.root,
                'title': folder.name,
                'mode': 'folders',
                'bookIds': <String>[],
              }),
          replacement: AudioFolder(folder.name, sourceFiles, root: folder.root),
        );
        reports.add('Папка подключена к «Аудиокнигам»: ${result.message}');
        // Retry incomplete groups on the next exchange, keeping working sources.
        if (result.warnings.isNotEmpty) {
          repo.notifyExternalChange();
          continue;
        }
      } else {
        final scanned = selected.isEmpty
            ? null
            : await scanVideoFolder(folder.root);
        final identities = {
          for (final source in scanned?.sources ?? <VideoSourceDraft>[])
            source.source: source,
        };
        final verified = <VideoSourceDraft>[];
        for (final source in videoSources) {
          final found = identities[source.source];
          if (found == null) {
            throw StateError(
              'Видео исчезло при подключении: ${source.relativeName}',
            );
          }
          verified.add(found);
        }
        final matching = videoItems!
            .where((r) => r.root == folder.root)
            .toList();
        if (matching.length > 1) {
          throw StateError(
            'Несколько курсов связаны с этой папкой. Выберите привязку вручную.',
          );
        }
        if (matching.isEmpty) {
          await videos.addSources(
            title: folder.name,
            sources: verified,
            root: folder.root,
          );
        } else {
          final preview = await previewVideoFolder(
            videos,
            matching.single,
            VideoImportSelection(folder.name, verified, root: folder.root),
          );
          // Automatic refresh only matches existing paths. Renames still need
          // explicit confirmation in the course editor.
          await preview.apply({});
        }
        reports.add('Папка подключена к «Медиа»: ${selected.length} файлов.');
      }
      ensureAllowed?.call();
      await repo.setMeta(key, signature);
      repo.notifyExternalChange();
    }
    return reports;
  }
}
