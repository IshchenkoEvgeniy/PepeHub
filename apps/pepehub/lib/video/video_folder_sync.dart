import 'package:path/path.dart' as p;

import 'models.dart';
import 'video_import.dart';
import 'video_repository.dart';

class VideoRenameCandidate {
  final VideoLesson lesson;
  final VideoSourceDraft source;
  final bool sampled;
  const VideoRenameCandidate(this.lesson, this.source, this.sampled);
}

class VideoFolderPreview {
  final VideoRepository repository;
  final VideoItem item;
  final VideoImportSelection selection;
  final String token;
  final List<VideoLesson> lessons;
  final Map<String, Map<String, dynamic>> payloads;
  final Map<String, VideoSourceDraft> direct;
  final List<VideoRenameCandidate> renames;
  final Set<String> changed;
  final int baselines;
  VideoFolderPreview(
    this.repository,
    this.item,
    this.selection,
    this.token,
    this.lessons,
    this.payloads,
    this.direct,
    this.renames,
    this.changed,
    this.baselines,
  );
  int get missingCount => lessons.length - direct.length;
  int get newCount => selection.sources.length - direct.length;
  Future<void> apply(Set<String> confirmed) async {
    await verifyVideoSources(selection.sources);
    final chosen = {
      for (final rename in renames)
        if (confirmed.contains(rename.lesson.id))
          rename.lesson.id: rename.source,
    };
    final used = <String>{};
    final bindings = <VideoFolderBinding>[];
    for (final lesson in lessons) {
      final source = direct[lesson.id] ?? chosen[lesson.id];
      if (source == null) {
        bindings.add(
          VideoFolderBinding(lesson.id, lesson.source, available: false),
        );
      } else {
        if (!used.add(source.source)) {
          throw StateError('Один файл нельзя связать с двумя уроками');
        }
        bindings.add(
          VideoFolderBinding(
            lesson.id,
            source.source,
            relativeName: source.relativeName,
            identity: source.identity,
            newVersion:
                changed.contains(lesson.id) && !chosen.containsKey(lesson.id),
          ),
        );
      }
    }
    await repository.applyFolderRefresh(
      item,
      token: token,
      root: selection.root!,
      bindings: bindings,
      additions: selection.sources
          .where((source) => !used.contains(source.source))
          .toList(),
    );
  }
}

String _relative(
  VideoItem item,
  VideoLesson lesson,
  Map<String, dynamic> payload,
) {
  final saved = payload['relativeName'] as String?;
  if (saved != null) return saved;
  if (lesson.source.startsWith('content:')) {
    final root = Uri.parse(item.root!).pathSegments.last,
        document = Uri.parse(lesson.source).pathSegments.last;
    return document.startsWith('$root/')
        ? document.substring(root.length + 1)
        : p.posix.basename(document);
  }
  return p.relative(lesson.source, from: item.root!).replaceAll('\\', '/');
}

Future<VideoFolderPreview> previewVideoFolder(
  VideoRepository repository,
  VideoItem item,
  VideoImportSelection selection,
) async {
  if (selection.root == null || item.root == null) {
    throw ArgumentError('Выберите папку курса');
  }
  final token = await repository.folderToken(item.id);
  final lessons = await repository.lessons(itemId: item.id);
  final rows = await repository.repository.records('video_lesson');
  final payloads = {
    for (final row in rows)
      if (row.payload?['itemId'] == item.id) row.id: row.payload!,
  };
  final available = {
    for (final source in selection.sources) source.source: source,
  };
  if (available.length != selection.sources.length) {
    throw StateError('В сканировании повторяются источники');
  }
  final byRelative = <String, List<VideoSourceDraft>>{};
  for (final source in selection.sources) {
    if (source.relativeName != null) {
      (byRelative[source.relativeName!] ??= []).add(source);
    }
  }
  final direct = <String, VideoSourceDraft>{}, changed = <String>{};
  final unmatched = <VideoLesson>[];
  var baselines = 0;
  for (final lesson in lessons) {
    final payload = payloads[lesson.id]!;
    final old = payload['fileIdentity'] == null
        ? null
        : VideoFileIdentity.fromJson(
            Map<String, dynamic>.from(payload['fileIdentity'] as Map),
          );
    final source = available[lesson.source];
    if (source == null) {
      unmatched.add(lesson);
      continue;
    }
    direct[lesson.id] = source;
    if (old == null && source.identity != null) baselines++;
    if (old != null &&
        source.identity != null &&
        (!old.sameSample(source.identity!) ||
            old.modifiedMs != source.identity!.modifiedMs)) {
      changed.add(lesson.id);
    }
  }
  final used = direct.values.map((source) => source.source).toSet();
  final hashGroups = <String, List<VideoSourceDraft>>{};
  for (final source in selection.sources) {
    final identity = source.identity;
    if (identity != null && !used.contains(source.source)) {
      (hashGroups['${identity.sample}:${identity.size}:${identity.fingerprint}'] ??=
              [])
          .add(source);
    }
  }
  final renames = <VideoRenameCandidate>[];
  final oldHashes = <String, int>{};
  for (final lesson in unmatched) {
    final value = payloads[lesson.id]!['fileIdentity'];
    if (value != null) {
      final old = VideoFileIdentity.fromJson(
        Map<String, dynamic>.from(value as Map),
      );
      final key = '${old.sample}:${old.size}:${old.fingerprint}';
      oldHashes[key] = (oldHashes[key] ?? 0) + 1;
    }
  }
  for (final lesson in lessons.where((lesson) => changed.contains(lesson.id))) {
    final old = VideoFileIdentity.fromJson(
      Map<String, dynamic>.from(payloads[lesson.id]!['fileIdentity'] as Map),
    );
    final source = direct[lesson.id]!;
    if (source.identity != null && old.sameSample(source.identity!)) {
      renames.add(VideoRenameCandidate(lesson, source, true));
    }
  }
  for (final lesson in unmatched) {
    final payload = payloads[lesson.id]!;
    final old = payload['fileIdentity'] == null
        ? null
        : VideoFileIdentity.fromJson(
            Map<String, dynamic>.from(payload['fileIdentity'] as Map),
          );
    VideoSourceDraft? candidate;
    var sampled = false;
    final relativeMatches = byRelative[_relative(item, lesson, payload)] ?? [];
    final relative = relativeMatches.length == 1
        ? relativeMatches.single
        : null;
    if (selection.root != item.root &&
        relative != null &&
        !used.contains(relative.source)) {
      if (old != null &&
          relative.identity != null &&
          !old.sameSample(relative.identity!)) {
        direct[lesson.id] = relative;
        changed.add(lesson.id);
        used.add(relative.source);
        continue;
      }
      candidate = relative;
      sampled = old != null && relative.identity != null;
    } else if (old != null) {
      final matches =
          hashGroups['${old.sample}:${old.size}:${old.fingerprint}'] ?? [];
      final remaining = matches
          .where((source) => !used.contains(source.source))
          .toList();
      if (remaining.length == 1 &&
          oldHashes['${old.sample}:${old.size}:${old.fingerprint}'] == 1) {
        candidate = remaining.single;
        sampled = true;
      }
    }
    if (candidate != null) {
      renames.add(VideoRenameCandidate(lesson, candidate, sampled));
      used.add(candidate.source);
    }
  }
  // Never claim that partial samples prove complete content equality. Only an
  // explicit checkbox can preserve a media version through a source rename.
  if (await repository.folderToken(item.id) != token) {
    throw StateError('Курс изменился. Повторите сканирование');
  }
  return VideoFolderPreview(
    repository,
    item,
    selection,
    token,
    lessons,
    payloads,
    direct,
    renames,
    changed,
    baselines,
  );
}
