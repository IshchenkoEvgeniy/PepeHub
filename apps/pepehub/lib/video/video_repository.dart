import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../data/database_schema.dart';
import '../data/repository.dart';
import 'models.dart';
import 'media_formats.dart';
import 'video_activity.dart' show firstVideoCoverageCompletion;
import 'video_annotations.dart';
import 'video_subtitles.dart';
import '../music/music_metadata.dart';

class VideoSourceDraft {
  final String source, title, module;
  final String? relativeName;
  final VideoFileIdentity? identity;
  final bool audio;

  /// Cheap facts from automatic search. They let a later search recognise the
  /// same file found through another source (a folder or Android's media
  /// index) without reading file contents.
  final int? size, durationMs;
  const VideoSourceDraft(
    this.source,
    this.title, {
    this.module = '',
    this.relativeName,
    this.identity,
    this.audio = false,
    this.size,
    this.durationMs,
  });
  bool get isAudio => audio || isMusicSource(relativeName ?? source);
}

/// Sources and file keys already in the media library, for automatic search.
class VideoKnownMedia {
  final Set<String> sources, fileKeys;
  const VideoKnownMedia(this.sources, this.fileKeys);
  static String fileKey(String name, int size) {
    final base = name.replaceAll('\\', '/').split('/').last.toLowerCase();
    return '$base|$size';
  }

  bool contains(String source, String name, int? size) =>
      sources.contains(source) ||
      (size != null && size > 0 && fileKeys.contains(fileKey(name, size)));
}

/// Where automatic search looks. Roots are folder URIs (Android) or paths.
class VideoDiscoverySettings {
  final List<({String root, String title})> roots;
  final bool device;
  final Set<String> ignored;

  /// Search these places by itself when «Медиа» opens and add new videos.
  final bool auto;
  const VideoDiscoverySettings({
    this.roots = const [],
    this.device = false,
    this.ignored = const {},
    this.auto = false,
  });

  bool get hasPlaces => roots.isNotEmpty || device;
}

/// What one removal took out of the media library, for «Вернуть».
class VideoRemoval {
  final List<String> lessons, items;
  const VideoRemoval(this.lessons, this.items);
  bool get isEmpty => lessons.isEmpty && items.isEmpty;
}

/// A local lesson source for the check that hides deleted files.
class VideoLocalSource {
  final String lessonId, source;
  final bool missing;
  const VideoLocalSource(this.lessonId, this.source, this.missing);
}

/// Local-only video records.
class VideoRepository {
  final Repository repository;
  VideoRepository(this.repository);
  // Must match the video_interval_history index in the schema.
  static const _intervalStart = SchemaSql.videoIntervalStart;

  Future<void> _put(
    String type,
    String id,
    Map<String, dynamic> payload,
  ) async {
    await repository.db.customStatement(
      'INSERT INTO records(id,type,revision,deleted,payload) VALUES(?,?,1,0,?) '
      'ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,revision=records.revision+1 '
      'WHERE records.deleted=0 AND records.type=excluded.type',
      [id, type, jsonEncode(payload)],
    );
  }

  /// Media items in the order they were added (an update keeps the rowid).
  Future<List<VideoItem>> items() async {
    final rows = await repository.db
        .customSelect(
          "SELECT id,payload FROM records WHERE type='video_item' "
          'AND deleted=0 AND json_valid(payload) ORDER BY rowid',
        )
        .get();
    return [
      for (final row in rows)
        VideoItem.fromJson(
          row.read<String>('id'),
          jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
        ),
    ];
  }

  /// [hideMissing] leaves out lessons whose files were deleted from the
  /// device: lists and players use it, folder refresh and statistics do not.
  Future<List<VideoLesson>> lessons({
    String? itemId,
    bool hideMissing = false,
  }) async {
    final rows = await repository.db
        .customSelect(
          'SELECT * FROM records WHERE ${SchemaSql.videoLessonRows} '
          "${itemId == null ? '' : "AND json_extract(payload,'\$.itemId')=? "}"
          "${hideMissing ? "AND json_extract(payload,'\$.missing') IS NOT 1 " : ''}"
          "ORDER BY json_extract(payload,'\$.ordinal'),id",
          variables: [if (itemId != null) Variable(itemId)],
        )
        .get();
    return [
      for (final row in rows)
        VideoLesson.fromJson(
          row.read<String>('id'),
          jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
        ),
    ];
  }

  Future<VideoItem> addSources({
    required String title,
    required List<VideoSourceDraft> sources,
    String? root,
    String? itemId,
    String? folder,
    String? discoveryKey,
    bool single = false,
  }) async {
    final clean = title.trim();
    if (clean.isEmpty || clean.length > 300) {
      throw ArgumentError('Название: от 1 до 300 символов');
    }
    if (sources.isEmpty || sources.length > 10000) {
      throw ArgumentError('Выберите от 1 до 10000 медиафайлов');
    }
    for (final source in sources) {
      if (source.source.trim().isEmpty || source.title.trim().isEmpty) {
        throw ArgumentError('Источник и название урока обязательны');
      }
    }
    return repository.db.transaction(() async {
      final existingItems = await items();
      VideoItem? existing;
      if (itemId != null) {
        existing = existingItems.where((item) => item.id == itemId).firstOrNull;
        if (existing == null) {
          throw StateError('Медиа удалено. Повторите поиск');
        }
      } else if (root != null) {
        for (final item in existingItems) {
          if (item.root == root) {
            existing = item;
            break;
          }
        }
      } else if (sources.length == 1) {
        // Only the lessons with this source, not the whole media library:
        // automatic search adds hundreds of groups in a row.
        final owners = await repository.db
            .customSelect(
              "SELECT json_extract(payload,'\$.itemId') AS item FROM records "
              "WHERE ${SchemaSql.videoLessonRows} "
              "AND json_extract(payload,'\$.source')=?",
              variables: [Variable(sources.single.source)],
            )
            .get();
        for (final owner in owners) {
          final id = owner.readNullable<String>('item');
          for (final item in existingItems) {
            if (item.id == id) return item;
          }
        }
      }
      final item =
          existing ??
          VideoItem(
            id: uuid.v4(),
            title: clean,
            kind: !single && (root != null || sources.length > 1)
                ? VideoItemKind.course
                : VideoItemKind.video,
            root: root,
            folder: folder,
            discoveryKey: discoveryKey,
          );
      if (existing == null) await _put('video_item', item.id, item.toJson());
      final own = existing == null
          ? const <VideoLesson>[]
          : await lessons(itemId: existing.id);
      final known = own.map((l) => l.source).toSet();
      var ordinal = own.isEmpty
          ? 0
          : own.map((l) => l.ordinal).reduce((a, b) => a > b ? a : b) + 1;
      var added = 0;
      for (final source in sources) {
        if (!known.add(source.source)) continue;
        added++;
        final lesson = VideoLesson(
          id: uuid.v4(),
          itemId: item.id,
          title: source.title.trim(),
          module: source.module,
          source: source.source,
          mediaVersion: uuid.v4(),
          ordinal: ordinal++,
          durationMs: source.durationMs != null && source.durationMs! > 0
              ? source.durationMs
              : null,
          audio: source.isAudio,
        );
        await _put('video_lesson', lesson.id, {
          ...lesson.toJson(),
          if (source.identity != null)
            'fileIdentity': source.identity!.toJson(),
          if (source.relativeName != null) 'relativeName': source.relativeName,
          if (source.size != null && source.size! > 0) 'fileSize': source.size,
        });
      }
      if (existing != null &&
          existing.kind == VideoItemKind.video &&
          own.length + added > 1) {
        // New episodes turn a single found video into a course.
        final row = (await repository.record(existing.id))!;
        await _put('video_item', existing.id, {
          ...row.payload!,
          'kind': VideoItemKind.course.name,
        });
        return VideoItem.fromJson(existing.id, {
          ...row.payload!,
          'kind': VideoItemKind.course.name,
        });
      }
      return item;
    });
  }

  /// Removes a video, course or playlist from the media library. Files are
  /// never touched. Returns the lessons removed with it, for [restoreItem].
  Future<List<String>> removeItem(String itemId) =>
      repository.db.transaction(() async {
        final ids = [
          for (final lesson in await lessons(itemId: itemId)) lesson.id,
        ];
        await repository.db.customStatement(
          "UPDATE records SET deleted=1,revision=revision+1 "
          "WHERE id=? AND type='video_item' AND deleted=0",
          [itemId],
        );
        for (final id in ids) {
          await repository.db.customStatement(
            "UPDATE records SET deleted=1,revision=revision+1 "
            "WHERE id=? AND type='video_lesson' AND deleted=0",
            [id],
          );
        }
        return ids;
      });

  /// Lesson sources plus `name|size` keys, read with one light query. Files
  /// deleted from the device do not count: a copy put back is offered again.
  Future<VideoKnownMedia> knownMedia() async {
    final rows = await repository.db
        .customSelect(
          "SELECT json_extract(payload,'\$.source') AS source,"
          "json_extract(payload,'\$.relativeName') AS name,"
          "json_extract(payload,'\$.title') AS title,"
          "coalesce(json_extract(payload,'\$.fileSize'),"
          "json_extract(payload,'\$.fileIdentity.size')) AS size "
          'FROM records WHERE ${SchemaSql.videoLessonRows} '
          "AND json_extract(payload,'\$.missing') IS NOT 1",
        )
        .get();
    final sources = <String>{}, keys = <String>{};
    for (final row in rows) {
      final source = row.readNullable<String>('source');
      if (source != null) sources.add(source);
      final size = row.data['size'];
      final name = row.readNullable<String>('name');
      if (size is int && size > 0 && name != null) {
        keys.add(VideoKnownMedia.fileKey(name, size));
      }
    }
    return VideoKnownMedia(sources, keys);
  }

  /// Whether a finished video lesson counts down into the next one.
  Future<bool> autoNext() async =>
      await repository.meta('video-auto-next') != 'off';

  Future<void> setAutoNext(bool enabled) =>
      repository.setMeta('video-auto-next', enabled ? 'on' : 'off');

  /// Speed of the most recently watched lesson among [lessonIds].
  Future<double?> recentSpeed(Iterable<String> lessonIds) async {
    final ids = lessonIds.toSet();
    VideoProgress? recent;
    for (final progress in (await allProgress()).values) {
      if (ids.contains(progress.lessonId) &&
          (recent == null || progress.updatedAt.isAfter(recent.updatedAt))) {
        recent = progress;
      }
    }
    return recent?.speed;
  }

  static const _discoveryKey = 'video-discovery';

  Future<VideoDiscoverySettings> discoverySettings() async {
    final raw = await repository.meta(_discoveryKey);
    if (raw == null) return const VideoDiscoverySettings();
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      return VideoDiscoverySettings(
        roots: [
          for (final root in data['roots'] as List? ?? const [])
            if (root is Map &&
                root['root'] is String &&
                root['title'] is String)
              (root: root['root'] as String, title: root['title'] as String),
        ],
        device: data['device'] == true,
        ignored: {
          for (final key in data['ignored'] as List? ?? const [])
            if (key is String) key,
        },
        auto: data['auto'] == true,
      );
    } catch (_) {
      return const VideoDiscoverySettings();
    }
  }

  Future<void> saveDiscoverySettings(VideoDiscoverySettings value) {
    if (value.roots.length > 100) {
      throw ArgumentError('Не больше 100 папок для поиска');
    }
    // Oldest hidden groups drop out first; the set keeps insertion order.
    final ignored = value.ignored.toList();
    return repository.setMeta(
      _discoveryKey,
      jsonEncode({
        'version': 1,
        'roots': [
          for (final root in value.roots)
            {'root': root.root, 'title': root.title},
        ],
        'device': value.device,
        'ignored': ignored.length > 5000
            ? ignored.sublist(ignored.length - 5000)
            : ignored,
        'auto': value.auto,
      }),
    );
  }

  /// Sources of local files, without links, read with one light query.
  Future<List<VideoLocalSource>> localSources() async {
    final rows = await repository.db
        .customSelect(
          "SELECT id,json_extract(payload,'\$.source') AS source,"
          "json_extract(payload,'\$.missing') AS missing "
          'FROM records WHERE ${SchemaSql.videoLessonRows}',
        )
        .get();
    return [
      for (final row in rows)
        if (row.readNullable<String>('source') case final source?
            when !source.startsWith('http://') &&
                !source.startsWith('https://'))
          VideoLocalSource(
            row.read<String>('id'),
            source,
            row.data['missing'] == 1,
          ),
    ];
  }

  /// Marks lessons whose files are gone and brings back those whose files
  /// returned. Progress, notes and playlists keep the lesson either way.
  /// Returns how many lessons changed.
  Future<int> applySourceCheck({
    required Set<String> missing,
    required Set<String> present,
  }) async {
    if (missing.isEmpty && present.isEmpty) return 0;
    var changed = 0;
    await repository.db.transaction(() async {
      for (final local in await localSources()) {
        final String? update;
        if (!local.missing && missing.contains(local.source)) {
          update = "json_set(payload,'\$.missing',json('true'))";
        } else if (local.missing && present.contains(local.source)) {
          update = "json_remove(payload,'\$.missing')";
        } else {
          continue;
        }
        await repository.db.customStatement(
          'UPDATE records SET payload=$update,revision=revision+1 '
          "WHERE id=? AND type='video_lesson' AND deleted=0",
          [local.lessonId],
        );
        changed++;
      }
    });
    return changed;
  }

  Future<List<VideoPlaylist>> playlists() async => [
    for (final row in await repository.records('video_playlist'))
      VideoPlaylist.fromJson(row.id, row.payload!),
  ]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

  static String _playlistTitle(String title) {
    final clean = title.trim();
    if (clean.isEmpty || clean.length > 300) {
      throw ArgumentError('Название плейлиста: от 1 до 300 символов');
    }
    return clean;
  }

  Future<VideoPlaylist> createPlaylist(
    String title, {
    required String section,
    List<String> entries = const [],
  }) async {
    final playlist = VideoPlaylist(
      id: uuid.v4(),
      title: _playlistTitle(title),
      section: section == 'music' ? 'music' : 'video',
      entries: entries.toSet().toList(),
    );
    if (playlist.entries.length > 10000) {
      throw ArgumentError('В плейлисте не больше 10000 файлов');
    }
    await _put('video_playlist', playlist.id, playlist.toJson());
    return playlist;
  }

  Future<VideoPlaylist> _changePlaylist(
    String id,
    VideoPlaylist Function(VideoPlaylist current) change,
  ) => repository.db.transaction(() async {
    final row = await repository.record(id);
    if (row == null || row.deleted || row.type != 'video_playlist') {
      throw StateError('Плейлист удалён');
    }
    final next = change(VideoPlaylist.fromJson(id, row.payload!));
    if (next.entries.length > 10000) {
      throw ArgumentError('В плейлисте не больше 10000 файлов');
    }
    await _put('video_playlist', id, {...row.payload!, ...next.toJson()});
    return next;
  });

  Future<VideoPlaylist> renamePlaylist(String id, String title) {
    final clean = _playlistTitle(title);
    return _changePlaylist(
      id,
      (current) => VideoPlaylist(
        id: id,
        title: clean,
        section: current.section,
        entries: current.entries,
      ),
    );
  }

  /// Appends lessons that are not in the playlist yet. Returns how many.
  Future<int> addToPlaylist(String id, Iterable<String> lessonIds) async {
    var added = 0;
    await _changePlaylist(id, (current) {
      final entries = [...current.entries];
      final known = entries.toSet();
      for (final lesson in lessonIds) {
        if (known.add(lesson)) {
          entries.add(lesson);
          added++;
        }
      }
      return VideoPlaylist(
        id: id,
        title: current.title,
        section: current.section,
        entries: entries,
      );
    });
    return added;
  }

  /// Saves the order and removals made on the playlist screen. Entries that
  /// the screen did not show (removed media that can still be restored)
  /// stay at the end.
  Future<VideoPlaylist> savePlaylistEntries(
    String id,
    List<String> visible, {
    required Set<String> shown,
  }) => _changePlaylist(id, (current) {
    final kept = visible.toSet();
    return VideoPlaylist(
      id: id,
      title: current.title,
      section: current.section,
      entries: [
        ...kept,
        for (final entry in current.entries)
          if (!shown.contains(entry) && !kept.contains(entry)) entry,
      ],
    );
  });

  Future<void> deletePlaylist(String id) => repository.db.customStatement(
    "UPDATE records SET deleted=1,revision=revision+1 "
    "WHERE id=? AND type='video_playlist' AND deleted=0",
    [id],
  );

  /// Undoes [removeItem]; progress and notes were kept all along.
  Future<void> restoreItem(String itemId, List<String> lessonIds) =>
      repository.db.transaction(() async {
        for (final (id, type) in [
          (itemId, 'video_item'),
          for (final lesson in lessonIds) (lesson, 'video_lesson'),
        ]) {
          await repository.db.customStatement(
            "UPDATE records SET deleted=0,revision=revision+1 "
            "WHERE id=? AND type=? AND deleted=1",
            [id, type],
          );
        }
      });

  Future<void> renameItem(String itemId, String title) {
    final clean = _checkedTitle(title);
    return repository.db.transaction(() async {
      final row = await repository.record(itemId);
      if (row == null || row.deleted || row.type != 'video_item') {
        throw StateError('Медиа удалено');
      }
      await _put('video_item', itemId, {...row.payload!, 'title': clean});
    });
  }

  Future<void> renameLesson(String lessonId, String title) {
    final clean = _checkedTitle(title);
    return repository.db.transaction(() async {
      final row = await repository.record(lessonId);
      if (row == null || row.deleted || row.type != 'video_lesson') {
        throw StateError('Файл удалён из медиатеки');
      }
      await _put('video_lesson', lessonId, {
        ...row.payload!,
        'title': clean,
        // A folder refresh keeps the name chosen by the user.
        'manualStructure': true,
      });
    });
  }

  static String _checkedTitle(String title) {
    final clean = title.trim();
    if (clean.isEmpty || clean.runes.length > 300) {
      throw ArgumentError('Название: от 1 до 300 символов');
    }
    return clean;
  }

  /// Removes single files from their videos and courses; an item left
  /// without files is removed too. Files on the device are not touched.
  Future<VideoRemoval> removeLessons(Iterable<String> lessonIds) {
    final ids = lessonIds.toSet();
    return repository.db.transaction(() async {
      final removed = <String>[], owners = <String>{};
      for (final id in ids) {
        final row = await repository.record(id);
        if (row == null || row.deleted || row.type != 'video_lesson') continue;
        await repository.db.customStatement(
          "UPDATE records SET deleted=1,revision=revision+1 "
          "WHERE id=? AND type='video_lesson' AND deleted=0",
          [id],
        );
        removed.add(id);
        if (row.payload?['itemId'] case final String owner) owners.add(owner);
      }
      final emptied = <String>[];
      for (final owner in owners) {
        if ((await lessons(itemId: owner)).isNotEmpty) continue;
        await repository.db.customStatement(
          "UPDATE records SET deleted=1,revision=revision+1 "
          "WHERE id=? AND type='video_item' AND deleted=0",
          [owner],
        );
        emptied.add(owner);
      }
      return VideoRemoval(removed, emptied);
    });
  }

  /// Undoes [removeLessons] and [removeItem]s collected in one removal.
  Future<void> restoreRemoval(VideoRemoval removal) =>
      repository.db.transaction(() async {
        for (final (id, type) in [
          for (final item in removal.items) (item, 'video_item'),
          for (final lesson in removal.lessons) (lesson, 'video_lesson'),
        ]) {
          await repository.db.customStatement(
            "UPDATE records SET deleted=0,revision=revision+1 "
            "WHERE id=? AND type=? AND deleted=1",
            [id, type],
          );
        }
      });

  /// Joins videos and courses into one new course in the given order. The
  /// files keep their progress, notes and playlist places; a course that
  /// joins keeps its name as the module of its lessons.
  Future<VideoItem> mergeIntoCourse({
    required String title,
    required List<String> itemIds,
  }) {
    final clean = _checkedTitle(title);
    final ids = [
      ...{...itemIds},
    ];
    if (ids.length < 2) throw ArgumentError('Выберите хотя бы два медиа');
    return repository.db.transaction(() async {
      final sources = <VideoItem>[];
      for (final id in ids) {
        final row = await repository.record(id);
        if (row == null || row.deleted || row.type != 'video_item') {
          throw StateError('Медиа удалено. Обновите список');
        }
        sources.add(VideoItem.fromJson(id, row.payload!));
      }
      final folders = {for (final item in sources) item.folder};
      final course = VideoItem(
        id: uuid.v4(),
        title: clean,
        kind: VideoItemKind.course,
        folder: folders.length == 1 ? folders.single : null,
      );
      await _put('video_item', course.id, course.toJson());
      var ordinal = 0;
      for (final item in sources) {
        for (final lesson in await lessons(itemId: item.id)) {
          final row = (await repository.record(lesson.id))!;
          await _put('video_lesson', lesson.id, {
            ...row.payload!,
            'itemId': course.id,
            'ordinal': ordinal++,
            'module': lesson.module.isNotEmpty
                ? lesson.module
                : item.kind == VideoItemKind.course
                ? item.title
                : '',
          });
        }
        await repository.db.customStatement(
          "UPDATE records SET deleted=1,revision=revision+1 "
          "WHERE id=? AND type='video_item' AND deleted=0",
          [item.id],
        );
      }
      return course;
    });
  }

  /// File facts for «Сведения»: path, size and identity as stored.
  Future<Map<String, dynamic>?> lessonDetails(String lessonId) async {
    final row = await repository.record(lessonId);
    if (row == null || row.deleted || row.type != 'video_lesson') return null;
    return row.payload;
  }

  Future<void> setFavorite(VideoItem item, bool favorite) =>
      repository.db.transaction(() async {
        final row = await repository.record(item.id);
        if (row == null || row.deleted || row.type != 'video_item') {
          throw StateError('Медиафайл удалён');
        }
        await _put('video_item', item.id, {
          ...row.payload!,
          'favorite': favorite,
        });
      });

  Future<VideoLesson> saveMusicDetails(
    VideoLesson lesson,
    String title,
    MusicMetadata metadata,
  ) => repository.db.transaction(() async {
    final current = await _checkLesson(lesson);
    if (!current.isAudio ||
        title.trim().isEmpty ||
        title.runes.length > 300 ||
        metadata.artist.runes.length > 500 ||
        metadata.album.runes.length > 500 ||
        (metadata.trackNumber != null &&
            (metadata.trackNumber! < 1 || metadata.trackNumber! > 100000))) {
      throw ArgumentError(
        'Проверьте название, исполнителя, альбом и номер трека',
      );
    }
    final row = (await repository.record(lesson.id))!;
    final data = {
      ...row.payload!,
      'title': title.trim(),
      'audio': true,
      'music': metadata.toJson(),
    };
    if (jsonEncode(data) != jsonEncode(row.payload)) {
      await _put('video_lesson', lesson.id, data);
    }
    return VideoLesson.fromJson(lesson.id, data);
  });

  Future<Map<String, dynamic>?> musicQueue(String itemId) async {
    final value = await repository.meta('music-queue:$itemId');
    if (value == null) return null;
    try {
      final decoded = jsonDecode(value);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  Future<void> saveMusicQueue(String itemId, Map<String, dynamic> value) =>
      repository.setMeta('music-queue:$itemId', jsonEncode(value));

  static String structureToken(VideoItem item, List<VideoLesson> lessons) =>
      sha256
          .convert(
            utf8.encode(
              jsonEncode([
                item.id,
                item.title,
                item.root,
                [
                  for (final lesson in lessons)
                    [
                      lesson.id,
                      lesson.title,
                      lesson.module,
                      lesson.ordinal,
                      lesson.source,
                      lesson.mediaVersion,
                    ],
                ],
              ]),
            ),
          )
          .toString();

  Future<void> saveCourseStructure(
    VideoItem item, {
    required String title,
    required String token,
    required List<VideoLessonEdit> ordered,
  }) => repository.db.transaction(() async {
    final row = await repository.record(item.id);
    if (row == null || row.deleted || row.type != 'video_item') {
      throw StateError('Курс удалён');
    }
    final currentItem = VideoItem.fromJson(item.id, row.payload!);
    final current = await lessons(itemId: item.id);
    if (structureToken(currentItem, current) != token) {
      throw StateError('Структура курса изменилась. Откройте редактор заново');
    }
    final ids = ordered.map((lesson) => lesson.id).toSet();
    if (ordered.length != current.length ||
        ids.length != ordered.length ||
        !ids.containsAll(current.map((lesson) => lesson.id))) {
      throw ArgumentError('Редактор должен сохранить все существующие уроки');
    }
    if (title.trim().isEmpty || title.trim().runes.length > 300) {
      throw ArgumentError('Название курса: 1–300 знаков');
    }
    for (var i = 0; i < ordered.length; i++) {
      final edit = ordered[i];
      if (edit.title.trim().isEmpty ||
          edit.title.trim().runes.length > 300 ||
          edit.module.trim().runes.length > 300) {
        throw ArgumentError('Название урока и модуля: до 300 знаков');
      }
      final lessonRow = (await repository.record(edit.id))!;
      await _put('video_lesson', edit.id, {
        ...lessonRow.payload!,
        'title': edit.title.trim(),
        'module': edit.module.trim(),
        'ordinal': i,
        'manualStructure': true,
      });
    }
    await _put('video_item', item.id, {...row.payload!, 'title': title.trim()});
  });

  Future<String> folderToken(String itemId) async {
    final item = await repository.record(itemId);
    final rows =
        (await repository.records('video_lesson'))
            .where((row) => row.payload?['itemId'] == itemId)
            .toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    return sha256
        .convert(
          utf8.encode(
            jsonEncode([
              item?.revision,
              [
                for (final row in rows) [row.id, row.revision],
              ],
            ]),
          ),
        )
        .toString();
  }

  Future<void> setRootConnection(VideoItem item, bool connected) =>
      repository.db.transaction(() async {
        final row = await repository.record(item.id);
        if (row == null ||
            row.deleted ||
            row.type != 'video_item' ||
            row.payload?['root'] == null) {
          throw StateError('Подключённая папка отсутствует');
        }
        await _put('video_item', item.id, {
          ...row.payload!,
          'connected': connected,
        });
      });

  Future<void> applyFolderRefresh(
    VideoItem item, {
    required String token,
    required String root,
    required List<VideoFolderBinding> bindings,
    required List<VideoSourceDraft> additions,
  }) => repository.db.transaction(() async {
    final row = await repository.record(item.id);
    if (row == null ||
        row.deleted ||
        row.type != 'video_item' ||
        await folderToken(item.id) != token) {
      throw StateError(
        'Курс изменился во время сканирования. Повторите обновление',
      );
    }
    final own = await lessons(itemId: item.id);
    final ids = own.map((lesson) => lesson.id).toSet();
    if (bindings.length != own.length ||
        bindings.map((binding) => binding.id).toSet().length != own.length ||
        !ids.containsAll(bindings.map((binding) => binding.id))) {
      throw ArgumentError('Все существующие уроки должны остаться в каталоге');
    }
    if (root.trim().isEmpty || bindings.length + additions.length > 10000) {
      throw ArgumentError('Некорректная папка или слишком много уроков');
    }
    final sources = <String>{};
    for (final binding in bindings.where((entry) => entry.available)) {
      if (binding.source.trim().isEmpty || !sources.add(binding.source)) {
        throw ArgumentError('Доступные источники уроков должны быть уникальны');
      }
    }
    for (final addition in additions) {
      if (!sources.add(addition.source)) {
        throw ArgumentError('Повторяющийся источник нового урока');
      }
    }
    for (final binding in bindings) {
      final old = (await repository.record(binding.id))!;
      await _put('video_lesson', binding.id, {
        // A file found by the refresh is no longer deleted.
        for (final entry in old.payload!.entries)
          if (!(binding.available && entry.key == 'missing'))
            entry.key: entry.value,
        'source': binding.source,
        'available': binding.available,
        if (binding.identity != null)
          'fileIdentity': binding.identity!.toJson(),
        if (binding.relativeName != null) 'relativeName': binding.relativeName,
        if (binding.newVersion) ...{
          'mediaVersion': uuid.v4(),
          'durationMs': null,
        },
      });
    }
    var ordinal = own.isEmpty
        ? 0
        : own.map((lesson) => lesson.ordinal).reduce((a, b) => a > b ? a : b) +
              1;
    for (final addition in additions) {
      if (addition.source.trim().isEmpty || addition.title.trim().isEmpty) {
        throw ArgumentError('Некорректный новый урок');
      }
      final lesson = VideoLesson(
        id: uuid.v4(),
        itemId: item.id,
        title: addition.title,
        module: addition.module,
        source: addition.source,
        mediaVersion: uuid.v4(),
        ordinal: ordinal++,
        audio: addition.isAudio,
      );
      await _put('video_lesson', lesson.id, {
        ...lesson.toJson(),
        if (addition.identity != null)
          'fileIdentity': addition.identity!.toJson(),
        if (addition.relativeName != null)
          'relativeName': addition.relativeName,
      });
    }
    await _put('video_item', item.id, {
      ...row.payload!,
      'root': root,
      'connected': true,
    });
  });

  Future<List<VideoSubtitleRecord>> subtitles(VideoLesson lesson) async {
    final rows = await repository.db
        .customSelect(
          'SELECT id,revision,payload FROM records WHERE ${SchemaSql.videoSubtitleRows} '
          r"AND json_extract(payload,'$.lessonId')=? AND json_extract(payload,'$.mediaVersion')=? ORDER BY id",
          variables: [Variable(lesson.id), Variable(lesson.mediaVersion)],
        )
        .get();
    return [
      for (final row in rows)
        VideoSubtitleRecord.fromJson(
          row.read<String>('id'),
          row.read<int>('revision'),
          jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
        ),
    ];
  }

  Future<VideoSubtitleRecord> importSubtitles(
    VideoLesson lesson, {
    required String name,
    required String text,
    required VideoSubtitleFormat format,
  }) async {
    final clean = name.trim();
    if (clean.isEmpty || clean.runes.length > 200) {
      throw ArgumentError('Название: 1–200 знаков');
    }
    if (utf8.encode(text).length > maxVideoSubtitleBytes) {
      throw ArgumentError('Субтитры больше 8 МиБ');
    }
    await compute(parseVideoSubtitles, VideoSubtitleParseRequest(text, format));
    final digest = sha256
        .convert(utf8.encode('${format.name}\n$text'))
        .toString();
    return repository.db.transaction(() async {
      await _checkLesson(lesson);
      final duplicate = await repository.db
          .customSelect(
            'SELECT id,revision,payload FROM records WHERE ${SchemaSql.videoSubtitleRows} '
            r"AND json_extract(payload,'$.lessonId')=? AND json_extract(payload,'$.mediaVersion')=? AND json_extract(payload,'$.digest')=? LIMIT 1",
            variables: [
              Variable(lesson.id),
              Variable(lesson.mediaVersion),
              Variable(digest),
            ],
          )
          .getSingleOrNull();
      if (duplicate != null) {
        return VideoSubtitleRecord.fromJson(
          duplicate.read<String>('id'),
          duplicate.read<int>('revision'),
          jsonDecode(duplicate.read<String>('payload')) as Map<String, dynamic>,
        );
      }
      final id = uuid.v4();
      final data = {
        'version': 1,
        'lessonId': lesson.id,
        'mediaVersion': lesson.mediaVersion,
        'name': clean,
        'text': text,
        'format': format.name,
        'digest': digest,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
      };
      await _put('video_subtitle', id, data);
      return VideoSubtitleRecord.fromJson(id, 1, data);
    });
  }

  Future<VideoPlaybackSettings> playbackSettings(VideoLesson lesson) async {
    final row = await repository.record(
      'video-settings:${lesson.id}:${lesson.mediaVersion}',
    );
    return row != null && !row.deleted && row.type == 'video_playback_settings'
        ? VideoPlaybackSettings.fromJson(row.payload!)
        : const VideoPlaybackSettings();
  }

  Future<void> savePlaybackSettings(
    VideoLesson lesson,
    VideoPlaybackSettings settings,
  ) => repository.db.transaction(() async {
    await _checkLesson(lesson);
    if (!RegExp(r'^(auto|no|\d+)$').hasMatch(settings.audio) ||
        !RegExp(r'^(auto|no|embedded:\d+|external:[\w-]+)$')
            .hasMatch(settings.subtitle) ||
        settings.subtitleDelayMs.abs() > 60000 ||
        settings.translationDelayMs.abs() > 60000 ||
        settings.audioDelayMs.abs() > 10000 ||
        settings.fontSize < 14 ||
        settings.fontSize > 40) {
      throw ArgumentError('Некорректные настройки дорожек');
    }
    for (final (id, translation) in [
      (
        settings.subtitle.startsWith('external:')
            ? settings.subtitle.substring(9)
            : null,
        false,
      ),
      (settings.translation, true),
    ]) {
      if (id == null) continue;
      final row = await repository.record(id);
      if (row == null ||
          row.deleted ||
          row.type != 'video_subtitle' ||
          row.payload?['lessonId'] != lesson.id ||
          row.payload?['mediaVersion'] != lesson.mediaVersion ||
          (translation && row.payload?['format'] == 'ass')) {
        throw StateError(
          'Субтитры удалены или относятся к другой версии урока',
        );
      }
    }
    await _put(
      'video_playback_settings',
      'video-settings:${lesson.id}:${lesson.mediaVersion}',
      {
        ...settings.toJson(),
        'lessonId': lesson.id,
        'mediaVersion': lesson.mediaVersion,
      },
    );
  });

  Future<void> deleteSubtitles(
    VideoLesson lesson,
    VideoSubtitleRecord subtitle,
  ) => repository.db.transaction(() async {
    await _checkLesson(lesson);
    final row = await repository.record(subtitle.id);
    if (row == null ||
        row.deleted ||
        row.type != 'video_subtitle' ||
        row.revision != subtitle.revision ||
        row.payload?['lessonId'] != lesson.id ||
        row.payload?['mediaVersion'] != lesson.mediaVersion) {
      throw StateError('Субтитры уже удалены или изменились');
    }
    final settings = await playbackSettings(lesson);
    final data = {
      ...settings.toJson(),
      if (settings.subtitle == 'external:${subtitle.id}') 'subtitle': 'no',
      if (settings.translation == subtitle.id) 'translation': null,
    };
    await _put(
      'video_playback_settings',
      'video-settings:${lesson.id}:${lesson.mediaVersion}',
      {...data, 'lessonId': lesson.id, 'mediaVersion': lesson.mediaVersion},
    );
    await repository.db.customStatement(
      "UPDATE records SET deleted=1,revision=revision+1 WHERE id=? AND type='video_subtitle'",
      [subtitle.id],
    );
  });

  Future<VideoLesson> _checkLesson(VideoLesson lesson) async {
    final row = await repository.record(lesson.id);
    if (row == null ||
        row.deleted ||
        row.type != 'video_lesson' ||
        row.payload?['mediaVersion'] != lesson.mediaVersion) {
      throw StateError('Урок удалён или источник был заменён');
    }
    return VideoLesson.fromJson(row.id, row.payload!);
  }

  Future<List<VideoAnnotation>> annotations(VideoLesson lesson) async {
    final rows = await repository.db
        .customSelect(
          'SELECT id,revision,payload FROM records WHERE ${SchemaSql.videoAnnotationRows} '
          r"AND json_extract(payload,'$.lessonId')=? AND json_extract(payload,'$.mediaVersion')=? "
          r"ORDER BY json_extract(payload,'$.startMs'),id",
          variables: [Variable(lesson.id), Variable(lesson.mediaVersion)],
        )
        .get();
    return [
      for (final row in rows)
        VideoAnnotation.fromJson(
          row.read<String>('id'),
          row.read<int>('revision'),
          jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
        ),
    ];
  }

  Future<VideoAnnotation> saveAnnotation(
    VideoLesson lesson, {
    VideoAnnotation? existing,
    required String title,
    String body = '',
    required int startMs,
    int? endMs,
    int? durationMs,
    DateTime? at,
  }) async {
    final clean = title.trim(), text = body.trim();
    if (clean.isEmpty ||
        clean.runes.length > 140 ||
        text.runes.length > 20000 ||
        startMs < 0 ||
        (endMs != null && endMs <= startMs) ||
        (durationMs != null &&
            durationMs > 0 &&
            (endMs ?? startMs) > durationMs)) {
      throw ArgumentError(
        'Название: 1–140 знаков, заметка до 20000 знаков; время в пределах видео',
      );
    }
    if (existing != null &&
        (existing.lessonId != lesson.id ||
            existing.mediaVersion != lesson.mediaVersion)) {
      throw ArgumentError('Заметка относится к другому источнику');
    }
    return repository.db.transaction(() async {
      final storedLesson = await _checkLesson(lesson);
      final duration = storedLesson.durationMs ?? durationMs;
      if (duration != null && duration > 0 && (endMs ?? startMs) > duration) {
        throw ArgumentError('Время больше длительности видео');
      }
      if (existing != null) {
        final row = await repository.record(existing.id);
        if (row == null ||
            row.deleted ||
            row.type != 'video_annotation' ||
            row.revision != existing.revision ||
            row.payload?['lessonId'] != lesson.id ||
            row.payload?['mediaVersion'] != lesson.mediaVersion) {
          throw StateError(
            'Заметка изменилась или уже удалена. Обновите список',
          );
        }
      }
      final stamp = (at ?? DateTime.now()).toUtc();
      final annotation = VideoAnnotation(
        id: existing?.id ?? uuid.v4(),
        lessonId: lesson.id,
        mediaVersion: lesson.mediaVersion,
        title: clean,
        body: text,
        startMs: startMs,
        endMs: endMs,
        createdAt: existing?.createdAt ?? stamp,
        updatedAt: stamp,
        revision: (existing?.revision ?? 0) + 1,
      );
      await _put('video_annotation', annotation.id, annotation.toJson());
      return annotation;
    });
  }

  Future<VideoAnnotationDeletion> deleteAnnotation(
    VideoLesson lesson,
    VideoAnnotation annotation,
  ) => repository.db.transaction(() async {
    await _checkLesson(lesson);
    final row = await repository.record(annotation.id);
    if (annotation.lessonId != lesson.id ||
        annotation.mediaVersion != lesson.mediaVersion ||
        row == null ||
        row.deleted ||
        row.type != 'video_annotation' ||
        row.revision != annotation.revision ||
        row.payload?['lessonId'] != lesson.id ||
        row.payload?['mediaVersion'] != lesson.mediaVersion) {
      throw StateError('Заметка изменилась или уже удалена. Обновите список');
    }
    await repository.db.customStatement(
      "UPDATE records SET deleted=1,revision=revision+1 WHERE id=? AND type='video_annotation' AND deleted=0 AND revision=?",
      [annotation.id, annotation.revision],
    );
    return VideoAnnotationDeletion(annotation, annotation.revision + 1);
  });

  Future<void> restoreAnnotation(
    VideoLesson lesson,
    VideoAnnotationDeletion deletion,
  ) => repository.db.transaction(() async {
    await _checkLesson(lesson);
    final annotation = deletion.annotation,
        row = await repository.record(deletion.annotation.id);
    if (annotation.lessonId != lesson.id ||
        annotation.mediaVersion != lesson.mediaVersion ||
        row == null ||
        !row.deleted ||
        row.type != 'video_annotation' ||
        row.revision != deletion.revision ||
        row.payload?['lessonId'] != lesson.id ||
        row.payload?['mediaVersion'] != lesson.mediaVersion) {
      throw StateError('Удаление уже отменено или заметка изменилась');
    }
    await repository.db.customStatement(
      "UPDATE records SET deleted=0,revision=revision+1 WHERE id=? AND type='video_annotation' AND deleted=1 AND revision=?",
      [annotation.id, deletion.revision],
    );
  });

  Future<VideoProgress?> progress(VideoLesson lesson) async {
    final row = await repository.record('video-progress:${lesson.id}');
    if (row == null ||
        row.deleted ||
        row.type != 'video_progress' ||
        row.payload?['mediaVersion'] != lesson.mediaVersion) {
      return null;
    }
    return VideoProgress.fromJson(row.payload!);
  }

  Future<Map<String, VideoProgress>> allProgress() async => {
    for (final row in await repository.records('video_progress'))
      row.payload!['lessonId'] as String: VideoProgress.fromJson(row.payload!),
  };

  Future<void> checkpoint({
    required VideoLesson lesson,
    required VideoProgress progress,
    required List<VideoInterval> intervals,
    int? durationMs,
  }) async {
    if (progress.lessonId != lesson.id ||
        progress.mediaVersion != lesson.mediaVersion ||
        progress.positionMs < 0 ||
        !progress.speed.isFinite ||
        progress.speed < .5 ||
        progress.speed > 3) {
      throw ArgumentError('Некорректная позиция видео');
    }
    await repository.db.transaction(() async {
      final currentLesson = await repository.record(lesson.id);
      if (currentLesson == null ||
          currentLesson.deleted ||
          currentLesson.type != 'video_lesson' ||
          currentLesson.payload?['mediaVersion'] != lesson.mediaVersion) {
        throw StateError('Урок удалён или источник был заменён');
      }
      for (final interval in intervals) {
        if (interval.lessonId != lesson.id ||
            interval.mediaVersion != lesson.mediaVersion ||
            interval.startMs < 0 ||
            interval.endMs <= interval.startMs ||
            interval.wallMs <= 0 ||
            !interval.speed.isFinite ||
            interval.speed <= 0) {
          throw ArgumentError('Некорректный интервал просмотра');
        }
        await _put('video_interval', interval.id, {
          ...interval.toJson(),
          'mediaKind': lesson.isAudio ? 'music' : 'video',
        });
      }
      await _put(
        'video_progress',
        'video-progress:${lesson.id}',
        progress.toJson(),
      );
      if (durationMs != null && durationMs > 0) {
        final row = await repository.record(lesson.id);
        if (row != null &&
            !row.deleted &&
            row.type == 'video_lesson' &&
            row.payload?['mediaVersion'] == lesson.mediaVersion &&
            row.payload?['durationMs'] != durationMs) {
          await _put('video_lesson', lesson.id, {
            ...row.payload!,
            'durationMs': durationMs,
          });
        }
      }
      if (intervals.isNotEmpty || (durationMs != null && durationMs > 0)) {
        final effective = VideoLesson.fromJson(lesson.id, {
          ...currentLesson.payload!,
          if (durationMs != null && durationMs > 0) 'durationMs': durationMs,
        });
        await _recordCoverageMilestone(effective);
      }
    });
  }

  static const _mediaKind =
      "COALESCE(json_extract(payload,'\$.mediaKind'),"
      "(SELECT CASE WHEN json_extract(lesson.payload,'\$.audio')=1 THEN 'music' ELSE 'video' END "
      "FROM records AS lesson WHERE lesson.id=json_extract(records.payload,'\$.lessonId') AND json_valid(lesson.payload) LIMIT 1),'video')";

  Future<List<VideoInterval>> intervals({
    Set<String>? lessonIds,
    bool? music,
    DateTime? start,
  }) async {
    if (lessonIds?.isEmpty == true) return [];
    final rows = await repository.db
        .customSelect(
          'SELECT id,payload FROM records WHERE ${SchemaSql.videoIntervalRows} '
          "${lessonIds == null ? '' : "AND json_extract(payload,'\$.lessonId') IN (${List.filled(lessonIds.length, '?').join(',')}) "}"
          "${music == null ? '' : 'AND $_mediaKind=? '}"
          "${start == null ? '' : "AND ($_intervalStart + json_extract(payload,'\$.wallMs'))>?"}",
          variables: [
            if (lessonIds != null)
              for (final id in lessonIds) Variable(id),
            if (music != null) Variable(music ? 'music' : 'video'),
            if (start != null) Variable(start.millisecondsSinceEpoch),
          ],
        )
        .get();
    return [
      for (final row in rows)
        VideoInterval.fromJson(
          row.read<String>('id'),
          jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
        ),
    ];
  }

  Future<VideoPreferences> preferences() async {
    final raw = await repository.meta('video-preferences');
    return raw == null
        ? const VideoPreferences()
        : VideoPreferences.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> savePreferences(VideoPreferences value) async {
    if (value.dailyMinutes < 0 ||
        value.dailyMinutes > 1440 ||
        value.weeklyMinutes < 0 ||
        value.weeklyMinutes > 10080 ||
        value.completionPercent < 1 ||
        value.completionPercent > 100) {
      throw ArgumentError('Проверьте цели и порог просмотра (1–100%)');
    }
    await repository.setMeta('video-preferences', jsonEncode(value.toJson()));
  }

  Future<VideoLearningState> learningState(VideoLesson lesson) async {
    final row = await repository.record(
      'video-learning:${lesson.id}:${lesson.mediaVersion}',
    );
    return row != null && !row.deleted && row.type == 'video_learning'
        ? VideoLearningState.fromJson(row.payload!)
        : VideoLearningState(
            lessonId: lesson.id,
            mediaVersion: lesson.mediaVersion,
          );
  }

  Future<Map<String, VideoLearningState>> allLearningStates() async => {
    for (final row in await repository.records('video_learning'))
      '${row.payload!['lessonId']}:${row.payload!['mediaVersion']}':
          VideoLearningState.fromJson(row.payload!),
  };

  Future<void> setLearningState(
    VideoLesson lesson, {
    bool? manualComplete,
    bool? understood,
    DateTime? at,
  }) => repository.db.transaction(() async {
    final current = await repository.record(lesson.id);
    if (current == null ||
        current.deleted ||
        current.type != 'video_lesson' ||
        current.payload?['mediaVersion'] != lesson.mediaVersion) {
      throw StateError('Урок удалён или источник был заменён');
    }
    final state = await learningState(lesson),
        stamp = (at ?? DateTime.now()).toUtc().toIso8601String();
    final data = {
      ...state.toJson(),
      if (manualComplete != null)
        'manualCompletedAt': manualComplete
            ? state.manualCompletedAt?.toUtc().toIso8601String() ?? stamp
            : null,
      if (understood != null)
        'understoodAt': understood
            ? state.understoodAt?.toUtc().toIso8601String() ?? stamp
            : null,
    };
    await _put('video_learning', 'video-learning:${state.key}', data);
  });

  Future<void> _recordCoverageMilestone(VideoLesson lesson) async {
    if (lesson.isAudio) return;
    if (lesson.durationMs == null || lesson.durationMs! <= 0) return;
    final state = await learningState(lesson);
    if (state.coverageCompletedAt != null) return;
    final threshold = (await preferences()).completionPercent;
    final at = firstVideoCoverageCompletion(
      await intervals(lessonIds: {lesson.id}),
      lesson,
      threshold,
    );
    if (at != null) {
      await _put('video_learning', 'video-learning:${state.key}', {
        ...state.toJson(),
        'coverageCompletedAt': at.toUtc().toIso8601String(),
        'coverageThreshold': threshold,
      });
    }
  }

  /// Keyset pagination retains a stable boundary even when a checkpoint grows.
  Future<VideoHistoryPage> history({
    Set<String>? lessonIds,
    bool? music,
    DateTime? start,
    DateTime? end,
    VideoHistoryCursor? before,
    int limit = 20,
  }) async {
    if (limit < 1 || limit > 200) throw ArgumentError('Размер страницы: 1–200');
    if (lessonIds?.isEmpty == true) return const VideoHistoryPage([], null);
    final where = <String>[SchemaSql.videoIntervalRows];
    final values = <Variable>[];
    if (music != null) {
      where.add('$_mediaKind=?');
      values.add(Variable(music ? 'music' : 'video'));
    }
    if (lessonIds != null) {
      where.add(
        "json_extract(payload,'\$.lessonId') IN (${List.filled(lessonIds.length, '?').join(',')})",
      );
      values.addAll(lessonIds.map(Variable.new));
    }
    if (start != null) {
      where.add("($_intervalStart + json_extract(payload,'\$.wallMs')) > ?");
      values.add(Variable(start.millisecondsSinceEpoch));
    }
    if (end != null) {
      where.add('$_intervalStart < ?');
      values.add(Variable(end.millisecondsSinceEpoch));
    }
    if (before != null) {
      where.add('($_intervalStart < ? OR ($_intervalStart = ? AND id < ?))');
      values.addAll([
        Variable(before.startEpochMs),
        Variable(before.startEpochMs),
        Variable(before.id),
      ]);
    }
    values.add(Variable(limit + 1));
    final rows = await repository.db
        .customSelect(
          "SELECT id,payload,$_intervalStart AS sort_ms FROM records WHERE ${where.join(' AND ')} "
          'ORDER BY sort_ms DESC,id DESC LIMIT ?',
          variables: values,
        )
        .get();
    final visible = rows.take(limit).toList();
    return VideoHistoryPage(
      [
        for (final row in visible)
          VideoInterval.fromJson(
            row.read<String>('id'),
            jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
          ),
      ],
      rows.length > limit
          ? VideoHistoryCursor(
              visible.last.read<int>('sort_ms'),
              visible.last.read<String>('id'),
            )
          : null,
    );
  }

  Future<void> event(
    VideoLesson lesson,
    String kind,
    int positionMs, {
    Map<String, dynamic> extra = const {},
    DateTime? at,
  }) => _put('video_event', uuid.v4(), {
    'version': 1,
    'lessonId': lesson.id,
    'mediaVersion': lesson.mediaVersion,
    'kind': kind,
    'positionMs': positionMs,
    'at': (at ?? DateTime.now()).toUtc().toIso8601String(),
    ...extra,
  });
}
