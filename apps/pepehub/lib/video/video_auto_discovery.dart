import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'video_discovery.dart';
import 'video_discovery_scan.dart';
import 'video_import.dart' show videoFilesChannel;
import 'video_repository.dart';

/// Tells which media files still exist. Replaceable in tests.
abstract class VideoSourceChecker {
  /// Certain answers only: a source that cannot be checked is in neither
  /// set. Null when checking is not possible at all.
  Future<({Set<String> missing, Set<String> present})?> check(
    List<String> sources,
  );
}

class PlatformVideoSourceChecker implements VideoSourceChecker {
  const PlatformVideoSourceChecker();

  @override
  Future<({Set<String> missing, Set<String> present})?> check(
    List<String> sources,
  ) async {
    // Widget tests use made-up paths that never exist.
    if (Platform.environment.containsKey('FLUTTER_TEST')) return null;
    final missing = <String>{}, present = <String>{};
    if (Platform.isAndroid) {
      for (var start = 0; start < sources.length; start += 5000) {
        final result = await videoFilesChannel.invokeMapMethod<String, dynamic>(
          'checkSources',
          {
            'uris': sources.sublist(
              start,
              (start + 5000).clamp(0, sources.length),
            ),
          },
        );
        if (result == null) return null;
        missing.addAll([for (final s in result['missing'] as List) '$s']);
        present.addAll([for (final s in result['present'] as List) '$s']);
      }
      return (missing: missing, present: present);
    }
    for (final source in sources) {
      if (!p.isAbsolute(source)) continue;
      try {
        (await File(source).exists() ? present : missing).add(source);
      } catch (_) {
        /* Unknown, not missing. */
      }
    }
    return (missing: missing, present: present);
  }
}

class VideoAutoDiscoveryResult {
  final int groups, files;
  const VideoAutoDiscoveryResult(this.groups, this.files);
}

/// Background upkeep of the media library: hides lessons whose files were
/// deleted and, when the user turned it on, adds new videos found in the
/// places of automatic search.
abstract final class VideoAutoDiscovery {
  static Future<VideoAutoDiscoveryResult?>? _running;
  static DateTime? _lastSearch, _lastCheck;
  static int _manual = 0;

  /// True while a background search runs, for a quiet hint in the list.
  static final searching = ValueNotifier<bool>(false);

  /// The search page is open: background search waits for the next time.
  static void manualStarted() => _manual++;
  static void manualEnded() => _manual = _manual > 0 ? _manual - 1 : 0;

  /// Resolves when no background search is running.
  static Future<void> idle() async {
    final running = _running;
    if (running == null) return;
    try {
      await running;
    } catch (_) {
      /* The manual search reports its own errors. */
    }
  }

  @visibleForTesting
  static void reset() {
    _running = null;
    _lastSearch = null;
    _lastCheck = null;
    _manual = 0;
    searching.value = false;
  }

  /// Marks deleted files and brings back returned ones. Returns how many
  /// lessons changed. At most once a minute unless [force].
  static Future<int> checkSources(
    VideoRepository repository,
    VideoSourceChecker checker, {
    bool force = false,
  }) async {
    final now = DateTime.now();
    if (!force &&
        _lastCheck != null &&
        now.difference(_lastCheck!) < const Duration(minutes: 1)) {
      return 0;
    }
    _lastCheck = now;
    final locals = await repository.localSources();
    if (locals.isEmpty) return 0;
    final result = await checker.check([
      for (final local in locals) local.source,
    ]);
    if (result == null) return 0;
    return repository.applySourceCheck(
      missing: result.missing,
      present: result.present,
    );
  }

  /// Searches the saved places and adds what a manual search would tick:
  /// new episodes of added media, series, courses, films and collections.
  /// Camera, messengers, screen recordings, clips, duplicates and hidden
  /// groups are left for the search page. At most every five minutes
  /// unless [force].
  static Future<VideoAutoDiscoveryResult?> search(
    VideoRepository repository,
    VideoDiscoveryScanner scanner, {
    bool force = false,
  }) {
    final running = _running;
    if (running != null) return running;
    if (_manual > 0) return Future.value();
    final now = DateTime.now();
    if (!force &&
        _lastSearch != null &&
        now.difference(_lastSearch!) < const Duration(minutes: 5)) {
      return Future.value();
    }
    final future = _search(repository, scanner);
    _running = future;
    return future.whenComplete(() {
      _running = null;
      searching.value = false;
    });
  }

  static Future<VideoAutoDiscoveryResult?> _search(
    VideoRepository repository,
    VideoDiscoveryScanner scanner,
  ) async {
    final settings = await repository.discoverySettings();
    final device = scanner.supportsDevice && settings.device;
    if (!settings.auto || (settings.roots.isEmpty && !device)) return null;
    _lastSearch = DateTime.now();
    searching.value = true;
    final scan = await scanner.scan(
      roots: settings.roots,
      device: device,
      quiet: true,
    );
    if (scan.files.isEmpty) return const VideoAutoDiscoveryResult(0, 0);
    // What the user removed stays removed; a manual search offers it.
    final library = await repository.knownMedia(includeRemoved: true);
    final items = await repository.items();
    final request = VideoDiscoveryRequest(
      scan.files,
      knownSources: library.sources,
      knownFileKeys: library.fileKeys,
      existingKeys: {
        for (final item in items)
          if (item.discoveryKey != null) item.discoveryKey!: item.id,
      },
      existingTitles: {for (final item in items) item.id: item.title},
    );
    final result = scan.files.length < 400
        ? groupVideoCandidates(request)
        : await compute(groupVideoCandidates, request);
    var groups = 0, files = 0;
    for (final group in result.groups) {
      if (settings.ignored.contains(group.key) ||
          group.files.isEmpty ||
          !(group.kind == VideoGroupKind.existing ||
              group.kind.selectedByDefault)) {
        continue;
      }
      // The search page may have opened meanwhile: it takes over.
      if (_manual > 0) break;
      try {
        await repository.addSources(
          title: group.title,
          sources: [for (final file in group.files) file.toDraft()],
          itemId: group.targetItemId,
          folder: group.folder.isEmpty ? null : group.folder,
          discoveryKey: group.key,
          single: group.single,
          markNew: true,
        );
        groups++;
        files += group.files.length;
      } catch (_) {
        // A media item removed meanwhile; the next search offers it anew.
      }
    }
    return VideoAutoDiscoveryResult(groups, files);
  }
}
