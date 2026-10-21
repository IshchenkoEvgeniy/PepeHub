import 'dart:convert';

import 'package:drift/drift.dart';

import '../../data/repository.dart';
import '../../reader/reading_activity.dart' show mergeReadingRanges;
import '../../reader/reading_library.dart';
import '../../reader/reader_bookmarks.dart';
import '../../recommendations/recommendation_store.dart';
import '../../video/models.dart';
import '../../video/video_annotations.dart';
import '../../video/video_subtitles.dart';
import '../../vocabulary/vocabulary_repository.dart';
import 'app_sync_media.dart';
import 'app_sync_models.dart';
import 'app_sync_usage.dart';
import 'app_sync_validation.dart';

const _recordTypes = {
  'book',
  'session',
  'audio_event',
  'audio_note',
  'audio_bookmark',
  'vocabulary_card',
  'video_interval',
  'video_annotation',
  'video_subtitle',
  'video_learning',
  'video_event',
  'video_playback_settings',
};
const _metaPrefixes = {
  'reading-note:',
  'reader-bookmark:',
  'reading-session:',
  'reading-coverage:',
  'reading-book:',
  'reading-dates:',
  'reading-plan:',
  'reading-collection:',
  'audio-book:',
  'audio-collection:',
};
const _settings = {
  'reader:appearance',
  'appearance-settings',
  'reading-daily-goal',
  'audio-listening-goals',
  'video-preferences',
};
const _bookFields = {
  'title',
  'authors',
  'format',
  'status',
  'genres',
  'tags',
  'isbn',
  'languages',
  'series',
  'seriesNumber',
  'description',
  'publisher',
  'publishedAt',
  'pages',
  'total',
  'unit',
  'position',
  'finishedAt',
  'startedAt',
};
const _localFields = {
  'path',
  'root',
  'cover',
  'coverPath',
  'sourcePath',
  'localPath',
  'fileIdentity',
  'cachePath',
};

Map<String, dynamic> _portable(Map<String, dynamic> value) {
  Object? visit(Object? v) {
    if (v is List) return v.map(visit).toList();
    if (v is Map) {
      return {
        for (final entry in v.entries)
          if (!_localFields.contains(entry.key))
            entry.key as String: visit(entry.value),
      };
    }
    return v;
  }

  return Map<String, dynamic>.from(visit(value) as Map);
}

class AppSyncCodec {
  final AppSyncMedia media;
  final Map<String, AppSyncLocalProblem> localProblems = {};
  final bool Function(String target)? isProtected;
  AppSyncCodec(this.media, {this.isProtected});
  Repository get repository => media.repository;
  bool blocked(String target) =>
      localProblems.containsKey(target) ||
      AppSyncUsage.protected(repository.db, target) ||
      target.startsWith('m:reading-note:') &&
          AppSyncUsage.protected(repository.db, 'reading-notes') ||
      target.startsWith('c:') &&
          AppSyncUsage.protected(repository.db, 'recommendations') ||
      (target.startsWith('r:audio_note:') ||
              target.startsWith('r:audio_bookmark:')) &&
          AppSyncUsage.protected(repository.db, 'audio-notes') ||
      (target.startsWith('r:audio_event:') ||
              target.startsWith('r:session:') ||
              target.startsWith('m:reading-session:')) &&
          AppSyncUsage.protected(repository.db, 'statistics-edit') ||
      isProtected?.call(target) == true;
  String _recordId(String target) {
    final value = target.substring(2), split = target.indexOf(':', 2);
    return split >= 0 && _recordTypes.contains(target.substring(2, split))
        ? target.substring(split + 1)
        : value;
  }

  Future<bool> needsRepair(String key) async {
    if (!key.startsWith('media:')) return false;
    final parts = key.split(':'), local = media.incoming[parts[2]];
    if (local == null) return true;
    if (parts[1] == 'lesson') {
      return (await repository.record(local))?.payload?['available'] != true;
    }
    if (parts[1] == 'item') return await repository.record(local) == null;
    final descriptor = media.documents[key];
    if (descriptor?['kind'] == 'audio') {
      final rows = await repository.db
          .customSelect(
            'SELECT t.id FROM audio_tracks t JOIN audio_editions e ON e.id=t.edition_id WHERE e.book_id=?',
            variables: [Variable(local)],
          )
          .get();
      return rows.length != (descriptor?['sources'] as List? ?? []).length;
    }
    return await repository.db
            .customSelect(
              'SELECT 1 FROM local_assets WHERE book_id=?',
              variables: [Variable(local)],
            )
            .getSingleOrNull() ==
        null;
  }

  String _out(String value) => media.outgoing[value] ?? value;
  String _in(String value) => media.incoming[value] ?? value;
  String _metaKey(String key, bool encode) {
    final translate = encode ? _out : _in;
    for (final prefix in [
      'reading-book:',
      'reading-dates:',
      'reading-plan:',
      'audio-book:',
      'reading-collection:',
      'audio-collection:',
    ]) {
      if (key.startsWith(prefix)) {
        return '$prefix${translate(key.substring(prefix.length))}';
      }
    }
    return key;
  }

  bool supported(String key) {
    if (key.startsWith('media:')) {
      return RegExp(r'^media:(book|item|lesson):[a-f0-9-]{36}$').hasMatch(key);
    }
    if (key.startsWith('position:')) {
      return RegExp(
        r'^position:(reader:[a-f0-9]{64}|(audio|video):[a-f0-9-]{36}:[a-f0-9]{64})$',
      ).hasMatch(key);
    }
    if (key.startsWith('record:')) {
      return _recordTypes.contains(key.split(':').elementAtOrNull(1));
    }
    if (key.startsWith('meta:')) {
      final meta = key.substring(5);
      return _settings.contains(meta) || _metaPrefixes.any(meta.startsWith);
    }
    return RegExp(r'^recommendation:(category|book):[a-f0-9-]{36}$')
        .hasMatch(key);
  }

  Future<Map<String, AppSyncLocal>> snapshot() async {
    final result = <String, AppSyncLocal>{};
    localProblems.clear();
    void include(AppSyncLocal local) {
      try {
        validate(
          AppSyncVersion(local.key, local.value, {
            '00000000-0000-0000-0000-000000000000': 1,
          }),
        );
        result[local.key] = local;
      } on FormatException catch (failure) {
        _problem(local.key, local.target, failure.message);
      } on TypeError {
        _problem(local.key, local.target, 'Неверный тип поля записи');
      } on ArgumentError {
        _problem(local.key, local.target, 'Недопустимое значение поля записи');
      }
    }

    for (final entry in media.documents.entries) {
      include(AppSyncLocal(entry.key, 'd:${entry.key}', entry.value));
    }
    final records = await repository.db
        .customSelect('SELECT * FROM records')
        .get();
    for (final row in records) {
      final type = row.read<String>('type'), localId = row.read<String>('id');
      if (!_recordTypes.contains(type)) continue;
      try {
        final record = LibraryRecord.fromRow(row);
        if (!_recordTypes.contains(record.type) || record.payload == null) {
          continue;
        }
        final data = record.payload!;
        if (record.type == 'book' && !media.outgoing.containsKey(record.id) ||
            data['bookId'] is String &&
                !media.outgoing.containsKey(data['bookId']) ||
            data['lessonId'] is String &&
                !media.outgoing.containsKey(data['lessonId'])) {
          continue;
        }
        var value = _portable(media.translate(data, encode: true));
        if (record.type == 'book') {
          value = {
            for (final field in _bookFields)
              if (value.containsKey(field)) field: value[field],
          };
        }
        var id = _out(record.id);
        if (record.type == 'video_learning') {
          id = 'video-learning:${value['lessonId']}:${value['mediaVersion']}';
        }
        if (record.type == 'video_playback_settings') {
          id = 'video-settings:${value['lessonId']}:${value['mediaVersion']}';
        }
        final key = 'record:${record.type}:$id';
        include(
          AppSyncLocal(
            key,
            'r:${record.type}:${record.id}',
            record.deleted ? null : value,
          ),
        );
      } on FormatException catch (failure) {
        _problem('record:$type:$localId', 'r:$type:$localId', failure.message);
      } on TypeError {
        _problem(
          'record:$type:$localId',
          'r:$type:$localId',
          'Неверный тип поля записи',
        );
      } on ArgumentError {
        _problem(
          'record:$type:$localId',
          'r:$type:$localId',
          'Недопустимое значение поля записи',
        );
      }
    }
    final metadata = await repository.db
        .customSelect('SELECT key,value FROM metadata')
        .get();
    for (final row in metadata) {
      final localKey = row.read<String>('key'), raw = row.read<String>('value');
      final localTarget =
          localKey.startsWith('reader:') &&
              appSyncHash.hasMatch(localKey.substring(7))
          ? 'p:reader:${localKey.substring(7)}'
          : 'm:$localKey';
      try {
        if (_settings.contains(localKey)) {
          Object? value;
          try {
            value = jsonDecode(raw);
          } catch (_) {
            value = raw;
          }
          final key = 'meta:$localKey';
          include(AppSyncLocal(key, 'm:$localKey', {'setting': value}));
          continue;
        }
        if (localKey.startsWith('reader:') &&
            appSyncHash.hasMatch(localKey.substring(7))) {
          final data = jsonDecode(raw) as Map<String, dynamic>,
              hash = localKey.substring(7);
          final key = 'position:reader:$hash';
          include(
            AppSyncLocal(key, 'p:reader:$hash', {
              'chapter': data['chapter'] ?? 0,
              'textOffset': data['textOffset'] ?? 0,
              if (data['pdfFinished'] != null)
                'pdfFinished': data['pdfFinished'],
            }),
          );
          continue;
        }
        if (!_metaPrefixes.any(localKey.startsWith)) continue;
        final decoded = jsonDecode(raw);
        if (decoded is! Map) {
          throw const FormatException('Запись должна быть объектом');
        }
        final data = Map<String, dynamic>.from(decoded);
        if (data['bookId'] is String &&
            !media.outgoing.containsKey(data['bookId'])) {
          continue;
        }
        if ([
              'reading-book:',
              'reading-dates:',
              'reading-plan:',
              'audio-book:',
            ].any(localKey.startsWith) &&
            !media.outgoing.containsKey(
              localKey.substring(localKey.indexOf(':') + 1),
            )) {
          continue;
        }
        final key = 'meta:${_metaKey(localKey, true)}';
        include(
          AppSyncLocal(
            key,
            'm:$localKey',
            _portable(media.translate(data, encode: true)),
          ),
        );
      } on FormatException catch (failure) {
        _problem('meta:$localKey', localTarget, failure.message);
      } on TypeError {
        _problem('meta:$localKey', localTarget, 'Неверный тип поля записи');
      } on ArgumentError {
        _problem(
          'meta:$localKey',
          localTarget,
          'Недопустимое значение поля записи',
        );
      }
    }
    final videoPositions = await repository.records('video_progress');
    for (final row in videoPositions) {
      final data = row.payload!, lesson = data['lessonId'] as String;
      if (!media.outgoing.containsKey(lesson)) continue;
      final value = media.translate(data, encode: true)..remove('updatedAt');
      if (!appSyncHash.hasMatch(value['mediaVersion'] as String)) continue;
      if (media.currentHashes[lesson] != value['mediaVersion']) continue;
      final key =
          'position:video:${value['lessonId']}:${value['mediaVersion']}';
      include(AppSyncLocal(key, 'p:video:$lesson', value));
    }
    for (final row
        in await repository.db
            .customSelect(
              'SELECT p.*,e.book_id FROM audio_progress p JOIN audio_editions e ON e.id=p.edition_id',
            )
            .get()) {
      final edition = row.read<String>('edition_id'),
          alias = media.aliases['edition:$edition'];
      if (alias == null) continue;
      if (!media.outgoing.containsKey(row.read<String>('book_id'))) continue;
      final manifest = (alias['data'] as Map)['manifest'] as String;
      if (media.currentAudioManifests[edition] != manifest ||
          row.read<int>('manifest_revision') !=
              (alias['data'] as Map)['revision']) {
        continue;
      }
      final book = _out(row.read<String>('book_id')),
          track = media.outgoing[row.read<String>('track_id')];
      if (track == null) continue;
      final key = 'position:audio:$book:$manifest';
      include(
        AppSyncLocal(key, 'p:audio:$edition', {
          'trackId': track,
          'positionMs': row.read<int>('position_ms'),
          'speed': row.read<double>('speed'),
        }),
      );
    }
    final shelf = await repository.meta(RecommendationStore.storageKey);
    if (shelf != null) {
      final data = RecommendationShelf.fromJson(
        jsonDecode(shelf) as Map<String, dynamic>,
      );
      for (final category in data.categories) {
        final key = 'recommendation:category:${_out(category.id)}';
        include(
          AppSyncLocal(key, 'c:category:${category.id}', {
            ...category.toJson(),
            'id': _out(category.id),
          }),
        );
      }
      for (final book in data.books) {
        final key = 'recommendation:book:${_out(book.id)}';
        include(
          AppSyncLocal(
            key,
            'c:book:${book.id}',
            _portable({
              ...book.toJson(),
              'id': _out(book.id),
              'categories': {
                for (final entry in book.categories.entries)
                  _out(entry.key): entry.value,
              },
            }),
          ),
        );
      }
    }
    return result;
  }

  void _problem(String key, String target, String description) {
    localProblems[target] = AppSyncLocalProblem(key, target, description);
  }

  Future<bool> exists(String target) async {
    if (target.startsWith('d:')) return true;
    if (target.startsWith('r:')) {
      return await repository.record(_recordId(target)) != null;
    }
    if (target.startsWith('m:')) {
      return await repository.meta(target.substring(2)) != null;
    }
    if (target.startsWith('p:')) {
      return true; // Positions are checkpoints, not deletion commands.
    }
    if (target.startsWith('c:')) {
      final shelf = await repository.meta(RecommendationStore.storageKey);
      if (shelf == null) return false;
      final parts = target.split(':'), data = jsonDecode(shelf) as Map;
      return (data[parts[1] == 'category' ? 'categories' : 'books'] as List)
          .any((e) => (e as Map)['id'] == parts[2]);
    }
    return true;
  }

  String target(String key) {
    if (key.startsWith('media:')) return 'd:$key';
    if (key.startsWith('meta:')) {
      return 'm:${_metaKey(key.substring(5), false)}';
    }
    if (key.startsWith('recommendation:')) {
      final parts = key.split(':');
      return 'c:${parts[1]}:${_in(parts[2])}';
    }
    if (key.startsWith('position:reader:')) {
      return 'p:reader:${key.substring(16)}';
    }
    if (key.startsWith('position:video:')) {
      return 'p:video:${_in(key.split(':')[2])}';
    }
    if (key.startsWith('position:audio:')) {
      final book = key.split(':')[2];
      final edition = media.aliases.values
          .where(
            (a) => a['kind'] == 'edition' && (a['data'] as Map)['book'] == book,
          )
          .firstOrNull;
      return 'p:audio:${edition?['local'] ?? book}';
    }
    final parts = key.split(':'), type = parts[1];
    var id = parts.skip(2).join(':');
    if (type == 'video_learning' || type == 'video_playback_settings') {
      final prefix = type == 'video_learning'
          ? 'video-learning'
          : 'video-settings';
      final shared = parts[3], local = _in(shared), version = parts[4];
      final versions =
          (media.aliases['lesson:$local']?['data'] as Map?)?['versions']
              as Map? ??
          {};
      id =
          '$prefix:$local:${versions.entries.where((e) => e.value == version).firstOrNull?.key ?? version}';
    }
    return 'r:$type:${_in(id)}';
  }

  void validate(AppSyncVersion version) {
    if (!supported(version.key)) {
      throw const FormatException('Вид данных не поддерживается');
    }
    validateAppSyncData(version);
    final value = version.value;
    if (value == null) {
      if (version.key.startsWith('media:') ||
          version.key.startsWith('position:')) {
        throw const FormatException(
          'Нельзя удалить источник или позицию этой командой',
        );
      }
      return;
    }
    var nodes = 0;
    void inspect(Object? v, int depth) {
      if (++nodes > 400000 || depth > 24) {
        throw const FormatException('Слишком сложная запись');
      }
      if (v is Map) {
        if (v.keys.any((k) => k is! String || _localFields.contains(k))) {
          throw const FormatException('В данных обнаружено локальное поле');
        }
        for (final x in v.values) {
          inspect(x, depth + 1);
        }
      } else if (v is List) {
        for (final x in v) {
          inspect(x, depth + 1);
        }
      } else if (v is num && !v.isFinite) {
        throw const FormatException('Некорректное число');
      }
    }

    // Media source pointers are relative to an explicitly connected shared folder.
    if (!version.key.startsWith('media:')) inspect(value, 0);
    if (version.key.startsWith('position:')) {
      for (final key in ['chapter', 'textOffset', 'positionMs']) {
        if (value.containsKey(key) &&
            (value[key] is! int ||
                (value[key] as int) < 0 ||
                (value[key] as int) > 9007199254740991)) {
          throw const FormatException('Некорректная позиция');
        }
      }
      if (value['speed'] case final num speed) {
        if (!speed.isFinite || speed < .5 || speed > 3) {
          throw const FormatException('Некорректная скорость');
        }
      }
      return;
    }
    final key = version.key;
    if (key.startsWith('record:vocabulary_card:')) {
      final card = VocabularyCard.fromRecord(
        LibraryRecord(key.split(':').last, 'vocabulary_card', 1, false, value),
      );
      if (card.front.trim().isEmpty ||
          card.back.trim().isEmpty ||
          card.front.runes.length > 5000 ||
          card.back.runes.length > 20000 ||
          card.context.length > 10000) {
        throw const FormatException('Некорректная карточка Anki');
      }
    }
    if (key.startsWith('record:video_interval:')) {
      final interval = VideoInterval.fromJson(key.split(':').last, value);
      if (interval.startMs < 0 ||
          interval.endMs <= interval.startMs ||
          interval.wallMs <= 0 ||
          interval.speed <= 0) {
        throw const FormatException('Некорректный интервал');
      }
    }
    if (key.startsWith('record:video_annotation:')) {
      VideoAnnotation.fromJson(key.split(':').last, 1, value);
    }
    if (key.startsWith('record:video_subtitle:')) {
      VideoSubtitleRecord.fromJson(key.split(':').last, 1, value);
      if (utf8.encode(value['text'] as String).length > maxVideoSubtitleBytes) {
        throw const FormatException('Субтитры слишком велики');
      }
    }
    if (key.startsWith('record:book:') &&
        (value['title'] is! String ||
            (value['title'] as String).trim().isEmpty)) {
      throw const FormatException('Нет названия книги');
    }
    if (key.startsWith('meta:reader-bookmark:')) ReaderBookmark.fromJson(value);
    if (key.startsWith('meta:reading-note:')) {
      for (final field in [
        'id',
        'bookId',
        'hash',
        'bookTitle',
        'chapterTitle',
        'quote',
        'comment',
        'color',
        'updated',
      ]) {
        if (value[field] is! String) {
          throw FormatException(
            'Некорректная заметка: поле $field должно быть текстом',
          );
        }
      }
      for (final field in ['chapter', 'start', 'end']) {
        if (value[field] is! int) {
          throw FormatException(
            'Некорректная заметка: поле $field должно быть целым числом',
          );
        }
      }
      final note = ReadingNote.fromJson(value);
      // Obsidian/imported notes use -1 to mean an unbound anchor. Preserve it;
      // inventing chapter zero would incorrectly attach the quote to the book.
      if (!(appSyncHash.hasMatch(note.hash) ||
              note.hash.isEmpty && note.chapter == -1) ||
          !appSyncUuid.hasMatch(note.bookId) ||
          note.chapter < -1 ||
          note.start < 0 ||
          note.end < note.start) {
        final fields = [
          if (!(appSyncHash.hasMatch(note.hash) ||
              note.hash.isEmpty && note.chapter == -1))
            'hash',
          if (!appSyncUuid.hasMatch(note.bookId)) 'bookId',
          if (note.chapter < -1) 'chapter',
          if (note.start < 0 || note.end < note.start) 'start/end',
        ];
        throw FormatException('Некорректная заметка: ${fields.join(', ')}');
      }
    }
    if (key.startsWith('meta:reading-collection:') ||
        key.startsWith('meta:audio-collection:')) {
      if (value['name'] is! String ||
          (value['name'] as String).trim().isEmpty ||
          (value['name'] as String).length > 100) {
        throw const FormatException('Некорректная коллекция');
      }
    }
    if (key.startsWith('recommendation:category:')) {
      RecommendationCategory.fromJson(value);
    }
    if (key.startsWith('recommendation:book:')) RecommendedBook.fromJson(value);
  }

  Future<bool> apply(AppSyncVersion version) async {
    validate(version);
    final key = version.key, source = target(version.key), raw = version.value;
    if (media.ambiguous.contains(key.split(':').elementAtOrNull(2)) ||
        raw != null &&
            [
              'bookId',
              'itemId',
              'lessonId',
            ].any((field) => media.ambiguous.contains(raw[field]))) {
      return false;
    }
    if (blocked(source) ||
        key.startsWith('recommendation:') && blocked('recommendations')) {
      return false;
    }
    if (key.startsWith('media:')) {
      return raw != null && await media.apply(key, raw);
    }
    if (key.startsWith('position:reader:')) {
      if (raw == null) return false;
      final hash = key.substring(16),
          old = await ReadingLibrary(repository).value('reader:$hash');
      await repository.setMeta(
        'reader:$hash',
        jsonEncode({
          ...old,
          ...raw,
          'updatedAt': DateTime.now().toUtc().toIso8601String(),
        }),
      );
      await repository.setMeta('pdf:$hash', '${(raw['chapter'] as int) + 1}');
      return true;
    }
    if (key.startsWith('position:video:')) {
      if (raw == null) return false;
      final data = media.translate(raw, encode: false),
          lesson = await repository.record(data['lessonId'] as String);
      if (media.currentHashes[data['lessonId']] != raw['mediaVersion']) {
        return false;
      }
      if (lesson == null ||
          lesson.deleted ||
          lesson.payload?['mediaVersion'] != data['mediaVersion']) {
        return false;
      }
      final duration = lesson.payload?['durationMs'] as int?;
      if (duration != null && (data['positionMs'] as int) > duration) {
        throw const FormatException('Позиция за пределами урока');
      }
      await _record('video_progress', 'video-progress:${lesson.id}', {
        ...data,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      }, false);
      return true;
    }
    if (key.startsWith('position:audio:')) {
      if (raw == null) return false;
      final edition = source.substring(8),
          alias = media.aliases['edition:$edition'];
      if (alias == null ||
          (alias['data'] as Map)['manifest'] != key.split(':')[3]) {
        return false;
      }
      if (media.currentAudioManifests[edition] != key.split(':')[3]) {
        return false;
      }
      final track = media.incoming[raw['trackId']];
      if (track == null) return false;
      final row = await repository.db
          .customSelect(
            'SELECT t.edition_id,t.duration_ms,e.manifest_revision FROM audio_tracks t JOIN audio_editions e ON e.id=t.edition_id WHERE t.id=?',
            variables: [Variable(track)],
          )
          .getSingleOrNull();
      if (row == null || row.read<String>('edition_id') != edition) {
        return false;
      }
      if (row.readNullable<int>('duration_ms') case final int duration) {
        if ((raw['positionMs'] as int) > duration) {
          throw const FormatException('Позиция за пределами трека');
        }
      }
      await repository.db.customStatement(
        'INSERT INTO audio_progress VALUES(?,?,?,?,?,?) ON CONFLICT(edition_id) DO UPDATE SET track_id=excluded.track_id,position_ms=excluded.position_ms,manifest_revision=excluded.manifest_revision,speed=excluded.speed,updated_at=excluded.updated_at',
        [
          edition,
          track,
          raw['positionMs'],
          row.read<int>('manifest_revision'),
          raw['speed'],
          DateTime.now().toUtc().toIso8601String(),
        ],
      );
      return true;
    }
    if (key.startsWith('meta:')) {
      final meta = source.substring(2);
      if (raw == null) {
        await repository.db.customStatement(
          'DELETE FROM metadata WHERE key=?',
          [meta],
        );
      } else if (_settings.contains(meta)) {
        final value = raw['setting'];
        await repository.setMeta(
          meta,
          value is String ? value : jsonEncode(value),
        );
      } else {
        final local = media.translate(raw, encode: false);
        if (local['bookId'] is String &&
            await repository.record(local['bookId'] as String) == null) {
          return false;
        }
        final previous = await repository.meta(meta);
        final hidden = previous == null
            ? <String, dynamic>{}
            : Map<String, dynamic>.from(jsonDecode(previous) as Map);
        await repository.setMeta(meta, jsonEncode({...hidden, ...local}));
      }
      return true;
    }
    if (key.startsWith('recommendation:')) {
      final previous = await repository.meta(RecommendationStore.storageKey);
      final data = previous == null
          ? <String, dynamic>{'version': 1, 'categories': [], 'books': []}
          : jsonDecode(previous) as Map<String, dynamic>;
      final parts = key.split(':'),
          field = parts[1] == 'category' ? 'categories' : 'books',
          id = _in(parts[2]);
      final value = raw == null
          ? null
          : {
              ...raw,
              'id': id,
              if (raw['categories'] is Map)
                'categories': {
                  for (final entry in (raw['categories'] as Map).entries)
                    _in(entry.key as String): entry.value,
                },
            };
      final values = [
        for (final e in data[field] as List)
          if ((e as Map)['id'] != id) e,
        ?value,
      ];
      await repository.setMeta(
        RecommendationStore.storageKey,
        jsonEncode({...data, field: values}),
      );
      return true;
    }
    final type = key.split(':')[1], id = _recordId(source);
    if (raw == null) {
      await _record(type, id, null, true);
      return true;
    }
    final data = media.translate(raw, encode: false);
    for (final field in ['bookId', 'lessonId']) {
      if (data[field] is String &&
          await repository.record(data[field] as String) == null) {
        return false;
      }
    }
    await _record(type, id, data, false);
    return true;
  }

  Future<void> _record(
    String type,
    String id,
    Map<String, dynamic>? value,
    bool deleted,
  ) async {
    final old = await repository.record(id);
    if (old != null && old.type != type) {
      throw StateError('ID принадлежит другому типу записи');
    }
    final data = value ?? old?.payload;
    await repository.db.customStatement(
      'INSERT INTO records VALUES(?,?,1,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,revision=records.revision+1,deleted=excluded.deleted',
      [id, type, deleted ? 1 : 0, jsonEncode(data)],
    );
  }

  static Map<String, dynamic> mergeCoverage(
    Iterable<AppSyncVersion> versions,
  ) => {
    'ranges': mergeReadingRanges([
      for (final version in versions)
        for (final range in version.value?['ranges'] as List? ?? [])
          [(range[0] as num).toInt(), (range[1] as num).toInt()],
    ]),
  };
}
