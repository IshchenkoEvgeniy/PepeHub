import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../audio/audio_library_repository.dart';
import '../audio/audio_journal.dart';
import '../data/repository.dart';
import '../media/asset_store.dart';
import '../media/audio_artwork.dart';
import '../reader/reading_library.dart';
import 'activity_store.dart';
import 'cover_sync.dart';
import 'library_mapper.dart';
import 'library_repository.dart';
import 'models.dart';

/// Reads actual source data. Missing duration/pages stay unknown rather than zero.
class AutomaticMetadata {
  final AssetStore assets;
  AutomaticMetadata(this.assets);
  Repository get local => assets.repository;
  Future<Map<String, dynamic>> details(LibraryRecord book) async {
    final reading = ReadingLibrary(local);
    final audio = book.payload?['format'] == 'audio';
    final files = audio
        ? await assets.audioTracks(book.id)
        : (await assets.list()).where((a) => a.bookId == book.id).toList();
    Map<String, dynamic> result;
    if (audio) {
      final embedded = <String, dynamic>{};
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
        if (duration is num && duration > 0) {
          await AudioLibraryRepository(local.db)
              .saveDuration(track.id, Duration(milliseconds: duration.toInt()));
        }
        if (embedded.isEmpty) embedded.addAll(meta);
      }
      result = {
        ...embedded,
        ...?book.payload,
        ...await reading.value('audio-book:${book.id}'),
      };
      if ((result['authors'] as List?)?.isEmpty != false &&
          embedded['author'] is String) {
        result['authors'] = [embedded['author']];
      }
      if (embedded['genre'] is String && result['genres'] == null) {
        result['genres'] = [embedded['genre']];
      }
      if (embedded.isNotEmpty) result['embeddedMetadata'] = embedded;
      final summary = (await AudioLibraryRepository(local.db)
          .bookSummaries())[book.id];
      result['durationMinutes'] = summary?.total == null
          ? null
          : summary!.total! / 60000;
      result['listenedMinutes'] = summary?.position == null
          ? null
          : summary!.position! / 60000;
      final cover = await ArtworkStore(assets).load(book.id);
      if (cover?.scheme == 'file') result['cover'] = File.fromUri(cover!).path;
      result['unit'] = 'minutes';
    } else {
      final asset = files.firstOrNull;
      if (asset != null) await reading.index(assets, asset);
      result = await reading.bookInfo(book, asset?.hash);
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
    void span(dynamic at, int ms) {
      if (ms <= 0) return;
      elapsed += ms;
      final start = DateTime.tryParse('$at');
      if (start != null && (first == null || start.isBefore(first!))) {
        first = start;
      }
    }

    for (final session in (await reading.entries('reading-session:')).values) {
      if (audio || session['bookId'] != book.id) continue;
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
    for (final row in await AudioJournal(
      local,
    ).list('audio_event', bookId: book.id, limit: 100000)) {
      final s = row.payload!;
      if (audio && s['bookId'] == book.id && s['kind'] == 'listen') {
        span(s['at'], (s['wallMs'] as num?)?.toInt() ?? 0);
      }
    }
    for (final row in await AudioJournal(
      local,
    ).list('session', bookId: book.id, limit: 100000)) {
      final s = row.payload!;
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
    for (final foreign in await ActivityStore.foreign(
      local,
      audio ? 'audiobook' : 'book',
    )) {
      if (foreign['bookId'] == book.id) {
        span(foreign['startedAt'], foreign['durationMs'] as int);
      }
    }
    if (elapsed > 0) {
      final seconds = elapsed ~/ 1000;
      result['readingTime'] =
          '${(seconds ~/ 3600).toString().padLeft(2, '0')}:${(seconds ~/ 60 % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
      result['startedAt'] ??= first?.toUtc().toIso8601String();
      result['status'] ??= 'reading';
    }
    if (result['finishedAt'] != null || result['status'] == 'finished') {
      result['status'] = 'finished';
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
      final generated = LibraryMapper.fromBook(
        book,
        {
          ...snapshot,
          'fields': entry.item.fields.map((f) => f.toJson()).toList(),
        },
        await details(book),
        entry.item.id,
      );
      final baselineKey = 'obsidian-auto:${repo.namespace}:${entry.item.id}';
      final baseline = await ReadingLibrary(local).value(baselineKey);
      final changes = <String, dynamic>{};
      for (final field in generated.values.entries) {
        if (field.key == 'pepehub_time_from_journal') continue;
        if (field.value == null ||
            field.value == '' ||
            (field.value is List && (field.value as List).isEmpty)) {
          continue;
        }
        final current = entry.item.values[field.key];
        if (current == null ||
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
