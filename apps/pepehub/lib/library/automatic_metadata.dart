import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:drift/drift.dart' show Variable;

import '../audio/audio_library_repository.dart';
import '../data/repository.dart';
import '../media/asset_store.dart';
import '../media/audio_artwork.dart';
import '../reader/reading_library.dart';
import 'activity_store.dart';
import 'cover_sync.dart';
import 'library_mapper.dart';
import 'library_repository.dart';
import 'models.dart';
import 'metadata_values.dart';

/// Reads actual source data. Missing duration/pages stay unknown rather than zero.
class AutomaticMetadata {
  final AssetStore assets;
  AutomaticMetadata(this.assets);
  Repository get local => assets.repository;
  final _foreign = <String, Future<List<Map<String, dynamic>>>>{};

  Future<Map<String, dynamic>> _cachedDetails(
    LibraryRecord book,
    String namespace,
  ) async {
    final revision =
        (await local.db
                .customSelect(
                  'SELECT revision FROM library_source_revisions_v1 WHERE book_id=?',
                  variables: [Variable(book.id)],
                )
                .getSingleOrNull())
            ?.read<int>('revision') ??
        0;
    final key = 'obsidian-source-meta:$namespace:${book.id}';
    final cached = await ReadingLibrary(local).value(key);
    final captured = DateTime.tryParse('${cached['capturedAt']}');
    if (cached['revision'] == revision &&
        cached['details'] is Map &&
        captured != null &&
        DateTime.now().difference(captured) >= Duration.zero &&
        DateTime.now().difference(captured) < const Duration(minutes: 10)) {
      return Map<String, dynamic>.from(cached['details'] as Map);
    }
    final result = await details(book);
    final exported = Map<String, dynamic>.from(result)
      ..removeWhere(
        (key, _) => [
          'starts',
          'lengths',
          'paragraphStarts',
          'chapters',
          'text',
          'paragraphs',
          'pdfPageLengths',
        ].contains(key),
      );
    await local.setMeta(
      key,
      jsonEncode({
        'revision': revision,
        'capturedAt': DateTime.now().toUtc().toIso8601String(),
        'details': exported,
      }),
    );
    return result;
  }

  Future<Map<String, dynamic>> details(LibraryRecord book) async {
    final reading = ReadingLibrary(local);
    final audio = book.payload?['format'] == 'audio';
    final files = audio
        ? await assets.audioTracks(book.id)
        : [
            for (final row
                in await local.db
                    .customSelect(
                      'SELECT * FROM local_assets WHERE book_id=? ORDER BY filename,id',
                      variables: [Variable(book.id)],
                    )
                    .get())
              LocalAsset.fromRow(row),
          ];
    Map<String, dynamic> result;
    String? explicitStatus;
    final lastTrackIds = <String>{};
    if (audio) {
      final embedded = <String, dynamic>{};
      final candidates = <String, Map<String, int>>{};
      final trackRows = await local.db
          .customSelect(
            'SELECT t.id,t.duration_ms,NOT EXISTS(SELECT 1 FROM audio_tracks later WHERE later.edition_id=t.edition_id AND later.ordinal>t.ordinal) AS is_last '
            'FROM audio_tracks t JOIN audio_editions e ON e.id=t.edition_id WHERE e.book_id=?',
            variables: [Variable(book.id)],
          )
          .get();
      lastTrackIds.addAll(
        trackRows
            .where((r) => r.read<int>('is_last') == 1)
            .map((r) => r.read<String>('id')),
      );
      final knownDurations = {
        for (final row in trackRows)
          row.read<String>('id'): row.readNullable<int>('duration_ms'),
      };
      for (final track in files) {
        final key = 'audio-metadata:${track.hash}';
        var meta = await reading.value(key);
        if (meta.isEmpty) {
          try {
            meta = Map<String, dynamic>.from(
              await const MethodChannel('app.pepehub/audio_folder')
                      .invokeMapMethod<String, dynamic>('metadata', {
                        'uri': track.path.startsWith('content:')
                            ? track.path
                            : File(track.path).uri.toString(),
                      }) ??
                  {},
            );
            if (meta.isNotEmpty) await local.setMeta(key, jsonEncode(meta));
          } on MissingPluginException {
            /* Desktop can use durations already recorded by the player. */
          } on PlatformException {
            /* Disconnected sources can be retried next time. */
          }
        }
        final duration = meta['durationMs'];
        if (duration is num &&
            duration > 0 &&
            knownDurations[track.id] != duration.toInt()) {
          await AudioLibraryRepository(local.db)
              .saveDuration(track.id, Duration(milliseconds: duration.toInt()));
        }
        for (final entry in meta.entries) {
          if (entry.value is String &&
              (entry.value as String).trim().isNotEmpty) {
            final votes = candidates[entry.key] ??= {};
            final text = (entry.value as String).trim();
            votes[text] = (votes[text] ?? 0) + 1;
          }
        }
      }
      for (final field in candidates.entries) {
        final ranked = field.value.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        embedded[field.key] = ranked.first.key;
      }
      result = {
        ...embedded,
        ...?book.payload,
        ...await reading.value('audio-book:${book.id}'),
      };
      if ((result['authors'] as List?)?.isEmpty != false &&
          embedded['writer'] is String) {
        result['authors'] = metadataStrings(embedded['writer']);
      }
      // Android's artist tag is commonly the narrator, not the book's author.
      result['narrator'] ??= embedded['author'] ?? embedded['albumArtist'];
      if (embedded['genre'] is String && result['genres'] == null) {
        result['genres'] = [embedded['genre']];
      }
      if (embedded.isNotEmpty) result['embeddedMetadata'] = embedded;
      final summary = (await AudioLibraryRepository(local.db)
          .bookSummaries(bookId: book.id))[book.id];
      result['durationMinutes'] = summary?.total == null
          ? null
          : summary!.total! / 60000;
      result['listenedMinutes'] = summary?.position == null
          ? null
          : summary!.position! / 60000;
      final cover = await ArtworkStore(assets).load(book.id);
      if (cover?.scheme == 'file') result['cover'] = File.fromUri(cover!).path;
      result['unit'] = 'minutes';
      explicitStatus = await local.meta('audio-status-override:${book.id}');
      if (explicitStatus != null && result['status'] != 'finished') {
        result['status'] = explicitStatus;
      }
    } else {
      final asset = files.firstOrNull;
      if (asset != null) await reading.index(assets, asset);
      result = await reading.bookInfo(book, asset?.hash);
      explicitStatus =
          ((await reading.value('reading-book:${book.id}'))['overrides']
                  as Map?)?['status']
              as String?;
      final position = asset == null
          ? <String, dynamic>{}
          : await reading.value('reader:${asset.hash}');
      final pages = result['pdfPages'] as num?;
      final length = result['length'] as num?;
      if (pages != null && pages > 0) {
        result['unit'] = 'pages';
        result['total'] = pages;
        result['progress'] = (pages * readingFraction(result, position))
            .round();
      } else if (length != null && length > 0) {
        result['unit'] = 'characters';
        result['total'] = length;
        result['progress'] = (length * readingFraction(result, position))
            .round();
      }
    }
    var elapsed = 0;
    DateTime? first;
    DateTime? last;
    void span(dynamic at, int ms) {
      if (ms <= 0) return;
      elapsed += ms;
      final start = DateTime.tryParse('$at');
      if (start != null && (first == null || start.isBefore(first!))) {
        first = start;
      }
      final end = start?.add(Duration(milliseconds: ms));
      if (end != null && (last == null || end.isAfter(last!))) last = end;
    }

    final sessions = audio
        ? const <Map<String, dynamic>>[]
        : [
            for (final row
                in await local.db
                    .customSelect(
                      "SELECT value FROM metadata WHERE key>='reading-session:' AND key<'reading-session;' "
                      "AND json_valid(value) AND json_extract(value,'\$.bookId')=?",
                      variables: [Variable(book.id)],
                    )
                    .get())
              jsonDecode(row.read<String>('value')) as Map<String, dynamic>,
          ];
    for (final session in sessions) {
      for (final raw in session['spans'] as List? ?? []) {
        final s = raw as Map;
        if (s['pepehubDeleted'] != true) {
          final start = DateTime.tryParse('${s['start']}'),
              end = DateTime.tryParse('${s['end']}');
          span(
            s['start'],
            (s['activeMs'] as num?)?.toInt() ??
                (start != null && end != null
                    ? end.difference(start).inMilliseconds
                    : 0),
          );
        }
      }
    }
    final audioEvents = !audio
        ? const <Map<String, dynamic>>[]
        : [
            for (final row
                in await local.db
                    .customSelect(
                      "SELECT payload FROM records WHERE type='audio_event' AND json_valid(payload) "
                      "AND deleted=0 AND json_extract(payload,'\$.bookId')=?",
                      variables: [Variable(book.id)],
                    )
                    .get())
              jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
          ];
    for (final s in audioEvents) {
      if (audio && s['bookId'] == book.id && s['kind'] == 'listen') {
        span(s['at'], (s['wallMs'] as num?)?.toInt() ?? 0);
      }
    }
    for (final row
        in await local.db
            .customSelect(
              "SELECT payload FROM records WHERE type='session' AND deleted=0 AND json_valid(payload) "
              "AND json_extract(payload,'\$.bookId')=?",
              variables: [Variable(book.id)],
            )
            .get()) {
      final s = jsonDecode(row.read<String>('payload')) as Map<String, dynamic>;
      if (s['bookId'] != book.id ||
          s['source'] == 'player' ||
          s['kind'] != (audio ? 'listening' : 'reading')) {
        continue;
      }
      for (final part in ActivityStore.manualSpans(s)) {
        if (part['pepehubDeleted'] != true) {
          span(part['start'], part['activeMs'] as int);
        }
      }
    }
    final mediaType = audio ? 'audiobook' : 'book';
    for (final foreign in await (_foreign[mediaType] ??= ActivityStore.foreign(
      local,
      mediaType,
    ))) {
      if (foreign['bookId'] == book.id) {
        span(foreign['startedAt'], foreign['durationMs'] as int);
      }
    }
    if (elapsed > 0) {
      final seconds = elapsed ~/ 1000;
      result['readingTime'] =
          '${(seconds ~/ 3600).toString().padLeft(2, '0')}:${(seconds ~/ 60 % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
      result['startedAt'] ??= first?.toUtc().toIso8601String();
      if (explicitStatus == null &&
          [
            '',
            'planned',
            'null',
          ].contains(canonicalLibraryStatus(result['status']))) {
        result['status'] = 'active';
      }
    }
    if (audio && explicitStatus != 'planned' && result['status'] != 'paused') {
      final completed =
          audioEvents
              .where(
                (e) =>
                    e['kind'] == 'completed' &&
                    lastTrackIds.contains(e['trackId']),
              )
              .map((e) => DateTime.tryParse('${e['at']}'))
              .whereType<DateTime>()
              .toList()
            ..sort();
      if (completed.isNotEmpty) {
        result['status'] = 'finished';
        result['finishedAt'] ??= completed.last.toUtc().toIso8601String();
      }
    }
    if (result['finishedAt'] != null || result['status'] == 'finished') {
      result['status'] = 'finished';
      result['finishedAt'] ??= last?.toUtc().toIso8601String();
      if (audio && result['durationMinutes'] != null) {
        result['listenedMinutes'] = result['durationMinutes'];
      }
      if (!audio && result['total'] != null) {
        result['progress'] = result['total'];
      }
    }
    return result;
  }

  Future<Map<String, dynamic>> withCover(
    LibraryRecord book,
    CoverSync? covers,
  ) async {
    final result = await details(book), path = result['cover'];
    if (covers != null &&
        path is String &&
        !path.startsWith('https:') &&
        !path.startsWith('pepehub-cover:')) {
      final file = File(path);
      try {
        if (await file.exists() && await file.length() <= 16777216) {
          result['cover'] =
              'pepehub-cover:${await covers.upload(await file.readAsBytes())}';
        }
      } catch (_) {
        /* Cached artwork still syncs in the regular cover exchange when online. */
      }
    }
    return result;
  }

  /// Fill gaps and keep fields we previously filled current; a user's remote edit wins.
  Future<void> refresh(
    LibraryRepository repo,
    Map<String, dynamic> snapshot,
  ) async {
    for (final entry in (await repo.entries()).values) {
      if (entry.sourceBookId == null || entry.state != 'synced') continue;
      final book = await local.record(entry.sourceBookId!);
      if (book == null || book.deleted) continue;
      final policy = await ReadingLibrary(local)
          .value('obsidian-policy:${repo.namespace}:${entry.item.id}');
      final source = matchLibraryProgress(
        await _cachedDetails(book, repo.namespace),
        entry.item,
      );
      final generated = LibraryMapper.fromBook(
        book,
        {
          ...snapshot,
          'fields': entry.item.fields.map((f) => f.toJson()).toList(),
          'collections': (snapshot['collections'] as List)
              .where((c) => (c as Map)['id'] == entry.item.collectionId)
              .toList(),
        },
        source,
        entry.item.id,
      );
      final baselineKey = 'obsidian-auto:${repo.namespace}:${entry.item.id}';
      final baseline = await ReadingLibrary(local).value(baselineKey);
      final changes = <String, dynamic>{};
      for (final field in generated.values.entries) {
        if (field.key == 'pepehub_time_from_journal') continue;
        final semantic =
            generated.fields
                .where((f) => f.key == field.key)
                .firstOrNull
                ?.field ??
            field.key;
        if (policy[semantic] == 'obsidian') continue;
        if (field.value == null ||
            field.value == '' ||
            (field.value is List && (field.value as List).isEmpty)) {
          continue;
        }
        final current = entry.item.values[field.key];
        if (policy[semantic] == 'local' ||
            current == null ||
            current == '' ||
            (current == 0 &&
                !baseline.containsKey(field.key) &&
                generated.fields.any(
                  (f) => f.key == field.key && f.field == 'progress',
                )) ||
            (baseline.containsKey(field.key) &&
                sameMetadataValue(current, baseline[field.key]))) {
          if (!sameMetadataValue(current, field.value)) {
            changes[field.key] = field.value;
          }
          baseline[field.key] = field.value;
        }
      }
      if (generated.fields.any(
        (f) => f.field == 'readingTime' && changes.containsKey(f.key),
      )) {
        changes['pepehub_time_from_journal'] = true;
      }
      await repo.mutate((entries) async {
        final live = entries[entry.item.id];
        if (live?.state != 'synced' ||
            !sameMetadataValue(live!.item.values, entry.item.values)) {
          return;
        }
        if (changes.isNotEmpty) {
          entries[entry.item.id] = LibraryEntry(
            entry.item.withValues({...entry.item.values, ...changes}),
            sourceBookId: entry.sourceBookId,
            state: 'pending',
            operation: {
              'operationId': uuid.v4(),
              'itemId': entry.item.id,
              'action': 'update',
              'collectionId': entry.item.collectionId,
              'mediaType': entry.item.mediaType,
              'base': {for (final k in changes.keys) k: entry.item.values[k]},
              'values': changes,
            },
          );
        }
        await local.setMeta(baselineKey, jsonEncode(baseline));
      });
    }
  }
}
