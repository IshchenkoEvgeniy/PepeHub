import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../data/repository.dart';
import 'models.dart';
import 'media_formats.dart';
import 'video_activity.dart' show firstVideoCoverageCompletion;
import 'video_annotations.dart';
import 'video_subtitles.dart';

class VideoSourceDraft {
  final String source, title, module;
  final String? relativeName;
  final VideoFileIdentity? identity;
  final bool audio;
  const VideoSourceDraft(
    this.source,
    this.title, {
    this.module = '',
    this.relativeName,
    this.identity,
    this.audio = false,
  });
  bool get isAudio => audio || isMusicSource(relativeName ?? source);
}

/// Local-only video records. Never enqueue them in the book sync outbox.
class VideoRepository {
  final Repository repository;
  VideoRepository(this.repository);
  Future<void>? _indexes;
  static const _intervalStart =
      "COALESCE(json_extract(payload,'\$.startEpochMs'),"
      "CAST(ROUND(unixepoch(json_extract(payload,'\$.startedAt'),'subsec')*1000) AS INTEGER))";

  Future<void>
  ensureIndexes() => _indexes ??= repository.db.transaction(() async {
    await repository.db.customStatement(
      "CREATE INDEX IF NOT EXISTS video_lesson_item ON records "
      "(json_extract(payload,'\$.itemId'),json_extract(payload,'\$.ordinal'),id) "
      "WHERE type='video_lesson' AND deleted=0",
    );
    await repository.db.customStatement(
      "CREATE INDEX IF NOT EXISTS video_interval_lesson ON records "
      "(json_extract(payload,'\$.lessonId'),json_extract(payload,'\$.mediaVersion')) "
      "WHERE type='video_interval' AND deleted=0",
    );
    await repository.db.customStatement(
      "CREATE INDEX IF NOT EXISTS video_interval_history ON records "
      "($_intervalStart DESC,id DESC) WHERE type='video_interval' AND deleted=0",
    );
    await repository.db.customStatement(
      "CREATE INDEX IF NOT EXISTS video_annotation_lesson ON records "
      r"(json_extract(payload,'$.lessonId'),json_extract(payload,'$.mediaVersion'),json_extract(payload,'$.startMs'),id) "
      "WHERE type='video_annotation' AND deleted=0",
    );
    await repository.db.customStatement(
      "CREATE INDEX IF NOT EXISTS video_subtitle_lesson ON records "
      r"(json_extract(payload,'$.lessonId'),json_extract(payload,'$.mediaVersion'),json_extract(payload,'$.digest')) "
      "WHERE type='video_subtitle' AND deleted=0",
    );
  });

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

  Future<List<VideoItem>> items() async => [
    for (final row in await repository.records('video_item'))
      VideoItem.fromJson(row.id, row.payload!),
  ];

  Future<List<VideoLesson>> lessons({String? itemId}) async {
    final rows = await repository.db
        .customSelect(
          "SELECT * FROM records WHERE type='video_lesson' AND deleted=0 "
          "${itemId == null ? '' : "AND json_extract(payload,'\$.itemId')=? "}"
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
      final existingLessons = await lessons();
      VideoItem? existing;
      if (root != null) {
        for (final item in existingItems) {
          if (item.root == root) {
            existing = item;
            break;
          }
        }
      } else if (sources.length == 1) {
        for (final lesson in existingLessons) {
          if (lesson.source == sources.single.source) {
            for (final item in existingItems) {
              if (item.id == lesson.itemId) {
                existing = item;
                break;
              }
            }
            if (existing != null) return existing;
          }
        }
      }
      final item =
          existing ??
          VideoItem(
            id: uuid.v4(),
            title: clean,
            kind: root != null || sources.length > 1
                ? VideoItemKind.course
                : VideoItemKind.video,
            root: root,
          );
      if (existing == null) await _put('video_item', item.id, item.toJson());
      final own = existingLessons.where((l) => l.itemId == item.id).toList();
      final known = own.map((l) => l.source).toSet();
      var ordinal = own.isEmpty
          ? 0
          : own.map((l) => l.ordinal).reduce((a, b) => a > b ? a : b) + 1;
      for (final source in sources) {
        if (!known.add(source.source)) continue;
        final lesson = VideoLesson(
          id: uuid.v4(),
          itemId: item.id,
          title: source.title.trim(),
          module: source.module,
          source: source.source,
          mediaVersion: uuid.v4(),
          ordinal: ordinal++,
          audio: source.isAudio,
        );
        await _put('video_lesson', lesson.id, {
          ...lesson.toJson(),
          if (source.identity != null)
            'fileIdentity': source.identity!.toJson(),
          if (source.relativeName != null) 'relativeName': source.relativeName,
        });
      }
      return item;
    });
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
        ...old.payload!,
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
    await ensureIndexes();
    final rows = await repository.db
        .customSelect(
          "SELECT id,revision,payload FROM records WHERE type='video_subtitle' AND deleted=0 "
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
    await ensureIndexes();
    final digest = sha256
        .convert(utf8.encode('${format.name}\n$text'))
        .toString();
    return repository.db.transaction(() async {
      await _checkLesson(lesson);
      final duplicate = await repository.db
          .customSelect(
            "SELECT id,revision,payload FROM records WHERE type='video_subtitle' AND deleted=0 "
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
    await ensureIndexes();
    final rows = await repository.db
        .customSelect(
          "SELECT id,revision,payload FROM records WHERE type='video_annotation' AND deleted=0 "
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
    await ensureIndexes();
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
        await _put('video_interval', interval.id, interval.toJson());
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

  Future<List<VideoInterval>> intervals({Set<String>? lessonIds}) async {
    if (lessonIds?.isEmpty == true) return [];
    await ensureIndexes();
    final rows = await repository.db
        .customSelect(
          "SELECT id,payload FROM records WHERE type='video_interval' AND deleted=0 "
          "${lessonIds == null ? '' : "AND json_extract(payload,'\$.lessonId') IN (${List.filled(lessonIds.length, '?').join(',')}) "}",
          variables: [
            if (lessonIds != null)
              for (final id in lessonIds) Variable(id),
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
    DateTime? start,
    DateTime? end,
    VideoHistoryCursor? before,
    int limit = 20,
  }) async {
    if (limit < 1 || limit > 200) throw ArgumentError('Размер страницы: 1–200');
    if (lessonIds?.isEmpty == true) return const VideoHistoryPage([], null);
    await ensureIndexes();
    final where = <String>["type='video_interval'", 'deleted=0'];
    final values = <Variable>[];
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
