import 'package:path/path.dart' as p;

import '../audio/audio_import.dart' show naturalAudioOrder;
import 'video_repository.dart';

/// One video found by automatic search. Only cheap facts: no file contents
/// are read while searching, so thousands of files stay fast.
class VideoCandidate {
  final String source;

  /// Display path with `/`, starting at the searched folder's name, for
  /// example `Movies/Курсы/Flutter/01 Введение.mp4`.
  final String path;
  final int size, modifiedMs;
  final int? durationMs;
  const VideoCandidate({
    required this.source,
    required this.path,
    this.size = 0,
    this.modifiedMs = 0,
    this.durationMs,
  });

  String get name => p.posix.basename(path);
  String get folder {
    final dir = p.posix.dirname(path);
    return dir == '.' ? '' : dir;
  }

  factory VideoCandidate.fromJson(Map<String, dynamic> data) => VideoCandidate(
    source: data['uri'] as String,
    path: (data['path'] as String).replaceAll('\\', '/'),
    size: (data['size'] as num?)?.toInt() ?? 0,
    modifiedMs: (data['modifiedMs'] as num?)?.toInt() ?? 0,
    durationMs: (data['durationMs'] as num?)?.toInt(),
  );
}

enum VideoGroupKind {
  existing,
  series,
  course,
  movie,
  collection,
  folder,
  camera,
  messenger,
  screen,
  clips,
  duplicates,
}

extension VideoGroupKindLabel on VideoGroupKind {
  String get label => switch (this) {
    VideoGroupKind.existing => 'Новое в медиатеке',
    VideoGroupKind.series => 'Сериал',
    VideoGroupKind.course => 'Курс',
    VideoGroupKind.movie => 'Фильм',
    VideoGroupKind.collection => 'Подборка',
    VideoGroupKind.folder => 'Папка',
    VideoGroupKind.camera => 'Камера',
    VideoGroupKind.messenger => 'Мессенджер',
    VideoGroupKind.screen => 'Записи экрана',
    VideoGroupKind.clips => 'Короткие ролики',
    VideoGroupKind.duplicates => 'Возможные дубликаты',
  };

  /// Personal recordings, clips and duplicates are offered unticked.
  bool get selectedByDefault => switch (this) {
    VideoGroupKind.camera ||
    VideoGroupKind.messenger ||
    VideoGroupKind.screen ||
    VideoGroupKind.clips ||
    VideoGroupKind.duplicates => false,
    _ => true,
  };
}

class VideoDiscoveredFile {
  final VideoCandidate candidate;
  final String title, module;
  const VideoDiscoveredFile(this.candidate, this.title, this.module);

  VideoSourceDraft toDraft() => VideoSourceDraft(
    candidate.source,
    title,
    module: module,
    relativeName: candidate.path,
    size: candidate.size > 0 ? candidate.size : null,
    durationMs: candidate.durationMs,
  );
}

class VideoGroupProposal {
  /// Stable between searches: hiding a group or adding new files to an
  /// already added item relies on it.
  final String key;
  final String title;
  final VideoGroupKind kind;

  /// Common folder of the files (display path), or empty.
  final String folder;
  final List<VideoDiscoveredFile> files;

  /// For [VideoGroupKind.existing]: the media item that receives the files.
  final String? targetItemId;
  const VideoGroupProposal({
    required this.key,
    required this.title,
    required this.kind,
    required this.folder,
    required this.files,
    this.targetItemId,
  });

  int get totalSize => files.fold(0, (sum, file) => sum + file.candidate.size);
  int? get totalDurationMs {
    var total = 0;
    for (final file in files) {
      final duration = file.candidate.durationMs;
      if (duration == null || duration <= 0) return null;
      total += duration;
    }
    return total;
  }

  /// A movie or one file becomes a single video, everything else a course.
  bool get single => files.length == 1 && kind != VideoGroupKind.existing;

  VideoGroupProposal copyWith({
    String? title,
    List<VideoDiscoveredFile>? files,
  }) => VideoGroupProposal(
    key: key,
    title: title ?? this.title,
    kind: kind,
    folder: folder,
    files: files ?? this.files,
    targetItemId: targetItemId,
  );
}

enum VideoGrouping { smart, folders }

class VideoDiscoveryRequest {
  final List<VideoCandidate> candidates;
  final VideoGrouping grouping;
  final Set<String> knownSources, knownFileKeys;

  /// `discoveryKey` → item ID of media added by an earlier search.
  final Map<String, String> existingKeys;
  final Map<String, String> existingTitles;
  const VideoDiscoveryRequest(
    this.candidates, {
    this.grouping = VideoGrouping.smart,
    this.knownSources = const {},
    this.knownFileKeys = const {},
    this.existingKeys = const {},
    this.existingTitles = const {},
  });
}

class VideoDiscoveryResult {
  final List<VideoGroupProposal> groups;

  /// Files skipped because they are already in the media library.
  final int known;
  const VideoDiscoveryResult(this.groups, this.known);
}

// Thresholds. Size stands in for duration where Android gives none (folders).
const _clipMs = 30 * 1000;
const _movieMs = 60 * 60 * 1000;
const _movieBytes = 600 * 1024 * 1024;

final _seasonEpisode = [
  RegExp(r'(?<!\p{L})[Ss](\d{1,2})[ ._-]?[EeЕе](\d{1,3})(?!\d)', unicode: true),
  RegExp(r'(?<!\d)(\d{1,2})[xXхХ](\d{2,3})(?!\d)'),
];
// Markers must start a word: «Step 05» is not episode 5.
final _episodeOnly = RegExp(
  r'(?<!\p{L})(?:сери[яи]|эпизод|episode|ep|выпуск)[ ._#№-]*(\d{1,4})(?!\d)',
  caseSensitive: false,
  unicode: true,
);
final _seasonWord = RegExp(
  r'(?<!\p{L})(?:сезон|season|s)[ ._-]*(\d{1,2})(?!\d)|(\d{1,2})[ ._-]*(?:сезон|season)',
  caseSensitive: false,
  unicode: true,
);
final _seasonFolder = RegExp(
  r'^(?:сезон|season|s)[ ._-]*\d{1,2}$|^\d{1,2}[ ._-]*(?:сезон|season)$',
  caseSensitive: false,
);
final _lessonWord = RegExp(
  r'(?:урок|lesson|lecture|лекция|занятие|part|часть|глава|chapter|видео|video)[ ._#№-]*\d{1,3}',
  caseSensitive: false,
);
final _leadingNumber = RegExp(r'^\s*[\[(]?\d{1,3}(?:[.)\]_ -]|$)');
final _moduleFolder = RegExp(
  r'^\s*\d{1,3}(?:[.)_ -]|$)|модуль|module|раздел|section|часть|part|неделя|week|глава|chapter|урок|lesson|блок|block|день|day',
  caseSensitive: false,
);
final _noise = RegExp(
  r'\b(?:2160p|1080p|720p|480p|360p|4k|uhd|hdr|web[ .-]?dl|web[ .-]?rip|webrip|bdrip|brrip|blu[ .-]?ray|hdtv|dvdrip|hdrip|x26[45]|h\.?26[45]|hevc|avc|aac\d?(?:\.\d)?|ac3|dts|10bit|8bit|rus|eng|sub|subs|dub|proper|repack|extended)\b',
  caseSensitive: false,
);
final _brackets = RegExp(r'\[[^\]]*\]|\{[^}]*\}');
final _year = RegExp(r'[(\[]?\b(19|20)\d{2}\b[)\]]?');

String _stem(String name) => p.posix.basenameWithoutExtension(name);

/// Removes release tags, separators and brackets: «Show.Name.S01E02.1080p»
/// before the episode marker becomes «Show Name».
String cleanVideoTitle(String raw) {
  var text = raw.replaceAll(_brackets, ' ');
  text = text.replaceAll(RegExp(r'[._]+'), ' ');
  text = text.replaceAll(_noise, ' ');
  text = text.replaceAll(RegExp(r'\(\s*\)'), ' ');
  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  text = text.replaceAll(RegExp(r'^[\s\-–—:,]+|[\s\-–—:,]+$'), '');
  return text.trim();
}

String _normalizedKey(String title) => title
    .toLowerCase()
    .replaceAll('ё', 'е')
    .replaceAll(_year, ' ')
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();

class _Episode {
  final String title;
  final int? season;
  final int episode;
  const _Episode(this.title, this.season, this.episode);
}

_Episode? _parseEpisode(VideoCandidate file) {
  final stem = _stem(file.name);
  for (final pattern in _seasonEpisode) {
    final match = pattern.firstMatch(stem);
    if (match != null) {
      return _Episode(
        cleanVideoTitle(stem.substring(0, match.start)),
        int.parse(match.group(1)!),
        int.parse(match.group(2)!),
      );
    }
  }
  final match = _episodeOnly.firstMatch(stem);
  if (match == null) return null;
  int? season;
  final seasonMatch = _seasonWord.firstMatch(stem.substring(0, match.start));
  var titleEnd = match.start;
  if (seasonMatch != null) {
    season = int.parse(seasonMatch.group(1) ?? seasonMatch.group(2)!);
    titleEnd = seasonMatch.start;
  } else {
    final folder = p.posix.basename(file.folder);
    if (_seasonFolder.hasMatch(folder)) {
      final folderSeason = _seasonWord.firstMatch(folder);
      if (folderSeason != null) {
        season = int.parse(folderSeason.group(1) ?? folderSeason.group(2)!);
      }
    }
  }
  return _Episode(
    cleanVideoTitle(stem.substring(0, titleEnd)),
    season,
    int.parse(match.group(1)!),
  );
}

/// Where personal recordings live on Android phones.
VideoGroupKind? _personalKind(String path) {
  final lower = '/${path.toLowerCase()}';
  if (lower.contains('/dcim/') || lower.contains('/camera/')) {
    return VideoGroupKind.camera;
  }
  if (RegExp(
    r'/(?:screenrecorder|screen ?recordings?|screenrecord|screencasts?|записи экрана)/',
  ).hasMatch(lower)) {
    return VideoGroupKind.screen;
  }
  if (RegExp(r'/(?:telegram|whatsapp|viber|vk|signal|messenger)[^/]*/')
      .hasMatch(lower)) {
    return VideoGroupKind.messenger;
  }
  return null;
}

String _messengerName(String path) {
  final lower = path.toLowerCase();
  for (final (needle, name) in const [
    ('telegram', 'Telegram'),
    ('whatsapp', 'WhatsApp'),
    ('viber', 'Viber'),
    ('signal', 'Signal'),
    ('vk', 'ВКонтакте'),
  ]) {
    if (lower.contains(needle)) return name;
  }
  return 'Мессенджеры';
}

const _months = [
  'январь',
  'февраль',
  'март',
  'апрель',
  'май',
  'июнь',
  'июль',
  'август',
  'сентябрь',
  'октябрь',
  'ноябрь',
  'декабрь',
];

String _commonFolder(Iterable<VideoCandidate> files) {
  List<String>? common;
  for (final file in files) {
    final parts = file.folder.isEmpty ? <String>[] : file.folder.split('/');
    if (common == null) {
      common = parts;
      continue;
    }
    var i = 0;
    while (i < common.length && i < parts.length && common[i] == parts[i]) {
      i++;
    }
    common = common.sublist(0, i);
  }
  return (common ?? const []).join('/');
}

String _folderTitle(String folder) {
  if (folder.isEmpty) return 'Без папки';
  final name = p.posix.basename(folder);
  if (_seasonFolder.hasMatch(name)) {
    final parent = p.posix.dirname(folder);
    if (parent != '.' && parent.isNotEmpty) {
      return '${p.posix.basename(parent)} · $name';
    }
  }
  return name;
}

String _relativeModule(String root, String folder) {
  if (folder == root) return '';
  if (root.isEmpty) return folder;
  return folder.startsWith('$root/') ? folder.substring(root.length + 1) : '';
}

int _byPath(VideoDiscoveredFile a, VideoDiscoveredFile b) =>
    naturalAudioOrder(a.candidate.path, b.candidate.path);

/// Groups found videos into proposals. Pure and synchronous: run it with
/// `compute` so a catalogue of thousands of files does not block the UI.
VideoDiscoveryResult groupVideoCandidates(VideoDiscoveryRequest request) {
  var known = 0;
  final seen = <String>{};
  final fresh = <VideoCandidate>[];
  for (final file in request.candidates) {
    if (!seen.add(file.source)) continue;
    if (request.knownSources.contains(file.source) ||
        (file.size > 0 &&
            request.knownFileKeys.contains(
              VideoKnownMedia.fileKey(file.name, file.size),
            ))) {
      known++;
      continue;
    }
    fresh.add(file);
  }

  // The same name and size found twice (a copy in Download and in a course
  // folder, or the same file through a folder and Android's index).
  final duplicates = <VideoCandidate>[];
  final unique = <VideoCandidate>[];
  final bySignature = <String>{};
  for (final file in fresh..sort((a, b) => naturalAudioOrder(a.path, b.path))) {
    if (file.size > 0 &&
        !bySignature.add(VideoKnownMedia.fileKey(file.name, file.size))) {
      duplicates.add(file);
    } else {
      unique.add(file);
    }
  }

  final groups = request.grouping == VideoGrouping.folders
      ? _groupByFolders(unique)
      : _groupSmart(unique, request.existingKeys.keys.toSet());
  if (duplicates.isNotEmpty) {
    groups.add(
      VideoGroupProposal(
        key: 'duplicates',
        title: 'Возможные дубликаты',
        kind: VideoGroupKind.duplicates,
        folder: '',
        files: [
          for (final file in duplicates)
            VideoDiscoveredFile(file, _stem(file.name), ''),
        ],
      ),
    );
  }

  // Files for media added by an earlier search are offered as additions.
  final result = <VideoGroupProposal>[];
  for (final group in groups) {
    final itemId = request.existingKeys[group.key];
    if (itemId == null || group.kind == VideoGroupKind.duplicates) {
      result.add(group);
      continue;
    }
    result.add(
      VideoGroupProposal(
        key: group.key,
        title: request.existingTitles[itemId] ?? group.title,
        kind: VideoGroupKind.existing,
        folder: group.folder,
        files: group.files,
        targetItemId: itemId,
      ),
    );
  }
  int rank(VideoGroupKind kind) => switch (kind) {
    VideoGroupKind.existing => 0,
    _ when kind.selectedByDefault => 1,
    VideoGroupKind.duplicates => 3,
    _ => 2,
  };
  result.sort((a, b) {
    final order = rank(a.kind).compareTo(rank(b.kind));
    return order != 0 ? order : naturalAudioOrder(a.title, b.title);
  });
  return VideoDiscoveryResult(result, known);
}

List<VideoGroupProposal> _groupByFolders(List<VideoCandidate> files) {
  final byFolder = <String, List<VideoCandidate>>{};
  for (final file in files) {
    (byFolder[file.folder] ??= []).add(file);
  }
  return [
    for (final entry in byFolder.entries)
      VideoGroupProposal(
        key: 'folder:${entry.key.toLowerCase()}',
        title: _folderTitle(entry.key),
        kind: VideoGroupKind.folder,
        folder: entry.key,
        files: [
          for (final file in entry.value)
            VideoDiscoveredFile(file, _stem(file.name), ''),
        ]..sort(_byPath),
      ),
  ];
}

List<VideoGroupProposal> _groupSmart(
  List<VideoCandidate> files,
  Set<String> existingKeys,
) {
  final groups = <VideoGroupProposal>[];
  final rest = <VideoCandidate>[];

  // 1. Personal recordings by where phones keep them.
  final personal = <String, List<VideoCandidate>>{};
  final personalKind = <String, VideoGroupKind>{};
  final personalTitle = <String, String>{};
  for (final file in files) {
    final kind = _personalKind(file.path);
    if (kind == null) {
      rest.add(file);
      continue;
    }
    late final String key, title;
    switch (kind) {
      case VideoGroupKind.camera:
        final date = DateTime.fromMillisecondsSinceEpoch(file.modifiedMs);
        final month = date.month.toString().padLeft(2, '0');
        // Without a date the group must not depend on the time zone.
        key = file.modifiedMs <= 0 ? 'camera' : 'camera:${date.year}-$month';
        title = file.modifiedMs <= 0
            ? 'Камера'
            : 'Камера · ${_months[date.month - 1]} ${date.year}';
      case VideoGroupKind.messenger:
        final name = _messengerName(file.path);
        key = 'messenger:${name.toLowerCase()}';
        title = name;
      default:
        key = 'screen';
        title = 'Записи экрана';
    }
    (personal[key] ??= []).add(file);
    personalKind[key] = kind;
    personalTitle[key] = title;
  }
  for (final entry in personal.entries) {
    groups.add(
      VideoGroupProposal(
        key: entry.key,
        title: personalTitle[entry.key]!,
        kind: personalKind[entry.key]!,
        folder: _commonFolder(entry.value),
        files: [
          for (final file in entry.value)
            VideoDiscoveredFile(file, _stem(file.name), ''),
        ]..sort(_byPath),
      ),
    );
  }

  // 2. Short clips.
  final media = <VideoCandidate>[];
  final clips = <VideoCandidate>[];
  for (final file in rest) {
    final duration = file.durationMs;
    (duration != null && duration > 0 && duration < _clipMs ? clips : media)
        .add(file);
  }
  if (clips.isNotEmpty) {
    groups.add(
      VideoGroupProposal(
        key: 'clips',
        title: 'Короткие ролики',
        kind: VideoGroupKind.clips,
        folder: _commonFolder(clips),
        files: [
          for (final file in clips)
            VideoDiscoveredFile(file, _stem(file.name), ''),
        ]..sort(_byPath),
      ),
    );
  }

  // 3. Series by episode markers in names, across folders.
  final series = <String, List<(VideoCandidate, _Episode)>>{};
  final seriesTitle = <String, String>{};
  final other = <VideoCandidate>[];
  for (final file in media) {
    final episode = _parseEpisode(file);
    if (episode == null) {
      other.add(file);
      continue;
    }
    var title = episode.title;
    if (_normalizedKey(title).isEmpty) {
      // «S01E02.mkv» in «Show/Season 1»: the show is named by its folder.
      var folder = file.folder;
      if (_seasonFolder.hasMatch(p.posix.basename(folder))) {
        folder = p.posix.dirname(folder);
      }
      title = cleanVideoTitle(p.posix.basename(folder));
    }
    final key = _normalizedKey(title);
    if (key.isEmpty) {
      other.add(file);
      continue;
    }
    (series[key] ??= []).add((file, episode));
    seriesTitle.putIfAbsent(key, () => title);
  }
  for (final entry in series.entries) {
    // One new episode is enough for a series already in the library.
    if (entry.value.length < 2 &&
        !existingKeys.contains('series:${entry.key}')) {
      other.add(entry.value.single.$1);
      continue;
    }
    final seasons = {for (final (_, e) in entry.value) e.season ?? 1};
    final sorted = [...entry.value]
      ..sort((a, b) {
        var order = (a.$2.season ?? 1).compareTo(b.$2.season ?? 1);
        if (order != 0) return order;
        order = a.$2.episode.compareTo(b.$2.episode);
        return order != 0 ? order : naturalAudioOrder(a.$1.path, b.$1.path);
      });
    groups.add(
      VideoGroupProposal(
        key: 'series:${entry.key}',
        title: seriesTitle[entry.key]!,
        kind: VideoGroupKind.series,
        folder: _commonFolder(sorted.map((e) => e.$1)),
        files: [
          for (final (file, episode) in sorted)
            VideoDiscoveredFile(
              file,
              _stem(file.name),
              seasons.length > 1 ||
                      (existingKeys.contains('series:${entry.key}') &&
                          (episode.season ?? 1) > 1)
                  ? 'Сезон ${episode.season ?? 1}'
                  : '',
            ),
        ],
      ),
    );
  }

  // 4. Courses and collections by folder; numbered module folders join
  // their parent («Курс/01 Основы/…», «Курс/02 Практика/…»).
  final byFolder = <String, List<VideoCandidate>>{};
  for (final file in other) {
    (byFolder[file.folder] ??= []).add(file);
  }
  final moduleParents = <String, int>{};
  for (final folder in byFolder.keys) {
    final parent = p.posix.dirname(folder);
    if (folder.isNotEmpty &&
        parent != '.' &&
        _moduleFolder.hasMatch(p.posix.basename(folder))) {
      moduleParents[parent] = (moduleParents[parent] ?? 0) + 1;
    }
  }
  final courses = <String, List<VideoCandidate>>{};
  for (final entry in byFolder.entries) {
    final parent = p.posix.dirname(entry.key);
    final root =
        (moduleParents[parent] ?? 0) >= 2 &&
            _moduleFolder.hasMatch(p.posix.basename(entry.key))
        ? parent
        : entry.key;
    (courses[root] ??= []).addAll(entry.value);
  }
  for (final entry in courses.entries) {
    final folder = entry.key;
    final all = entry.value;
    final hasModules = all.any((file) => file.folder != folder);
    bool movieSized(VideoCandidate file) {
      final duration = file.durationMs;
      return duration != null && duration > 0
          ? duration >= _movieMs
          : file.size >= _movieBytes;
    }

    bool numbered(VideoCandidate file) {
      final stem = _stem(file.name);
      return _leadingNumber.hasMatch(stem) || _lessonWord.hasMatch(stem);
    }

    final numberedCount = all.where(numbered).length;
    final isCourse =
        hasModules || (all.length >= 2 && numberedCount * 2 >= all.length);
    if (!isCourse) {
      // Unnumbered large files are separate movies; the rest of the folder
      // stays together as a collection.
      final movies = all.where(movieSized).toList();
      final small = all.where((file) => !movieSized(file)).toList();
      for (final file in movies) {
        groups.add(
          VideoGroupProposal(
            key: 'movie:${file.path.toLowerCase()}',
            title: cleanVideoTitle(_stem(file.name)).isEmpty
                ? _stem(file.name)
                : cleanVideoTitle(_stem(file.name)),
            kind: VideoGroupKind.movie,
            folder: file.folder,
            files: [VideoDiscoveredFile(file, _stem(file.name), '')],
          ),
        );
      }
      if (small.isEmpty) continue;
      groups.add(
        VideoGroupProposal(
          key: 'folder:${folder.toLowerCase()}',
          title: small.length == 1
              ? _stem(small.single.name)
              : _folderTitle(folder),
          kind: small.length == 1
              ? VideoGroupKind.movie
              : VideoGroupKind.collection,
          folder: folder,
          files: [
            for (final file in small)
              VideoDiscoveredFile(file, _stem(file.name), ''),
          ]..sort(_byPath),
        ),
      );
      continue;
    }
    groups.add(
      VideoGroupProposal(
        key: 'folder:${folder.toLowerCase()}',
        title: _folderTitle(folder),
        kind: VideoGroupKind.course,
        folder: folder,
        files: [
          for (final file in all)
            VideoDiscoveredFile(
              file,
              _stem(file.name),
              _relativeModule(folder, file.folder),
            ),
        ]..sort(_byPath),
      ),
    );
  }
  return groups;
}

/// Section title for the media list grouped by folders: the folder that
/// holds a video, or the parent of a course folder, so courses that live
/// side by side share one section.
String videoFolderSection(
  String? folder, {
  required bool course,
  String? root,
  String? firstSource,
}) {
  var path = folder ?? _pathFromUri(root);
  if (path == null || path.isEmpty) {
    final fromSource = _pathFromUri(firstSource);
    if (fromSource != null) {
      final dir = p.posix.dirname(fromSource);
      path = dir == '.' ? '' : dir;
      course = false;
    }
  }
  if (path == null || path.isEmpty) {
    final uri = Uri.tryParse(firstSource ?? '');
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      return 'Ссылки';
    }
    return 'Другие';
  }
  if (course) {
    final parent = p.posix.dirname(path);
    if (parent != '.' && parent.isNotEmpty && parent != '/') return parent;
  }
  return path;
}

/// Readable path from a local path or an Android storage document URI
/// (`…/tree/primary%3AMovies%2FКурсы` → `Movies/Курсы`). Media index URIs
/// carry no path and give null.
String? _pathFromUri(String? value) {
  if (value == null || value.isEmpty) return null;
  final uri = Uri.tryParse(value);
  if (uri == null || uri.scheme != 'content') {
    if (uri != null && (uri.scheme == 'http' || uri.scheme == 'https')) {
      return null;
    }
    final normal = value.replaceAll('\\', '/');
    return normal.endsWith('/')
        ? normal.substring(0, normal.length - 1)
        : normal;
  }
  final segments = uri.pathSegments;
  String? id;
  final document = segments.indexOf('document');
  final tree = segments.indexOf('tree');
  if (document >= 0 && document + 1 < segments.length) {
    id = segments[document + 1];
  } else if (tree >= 0 && tree + 1 < segments.length) {
    id = segments[tree + 1];
  }
  if (id == null || !id.contains(':')) return null;
  final colon = id.indexOf(':');
  final volume = id.substring(0, colon), path = id.substring(colon + 1);
  final clean = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  if (volume == 'primary' || volume == 'home') return clean;
  return clean.isEmpty ? 'Карта памяти' : 'Карта памяти/$clean';
}
