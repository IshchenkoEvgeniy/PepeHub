import 'dart:convert';

import '../audio/audio_roots.dart';
import '../audio/audio_sidecar.dart';
import '../reader/reading_library.dart';
import 'asset_store.dart';
import 'support_files.dart';

Future<void> recoverAudioRoot(AssetStore assets, AudioRoot root) async {
  final failures = <String>[];
  await assets.repository.setMeta(
    'recovery-error:${root.key}',
    'Восстановление не завершено',
  );
  final files = await supportFiles(root.path);
  final protectedPositions = <String>{};
  final protectedEvents = {
    for (final row
        in await assets.repository.db
            .customSelect("SELECT id FROM records WHERE type='audio_event'")
            .get())
      row.read<String>('id'),
  };
  for (final row
      in await assets.repository.db
          .customSelect(
            'SELECT e.book_id,p.position_ms FROM audio_progress p JOIN audio_editions e ON e.id=p.edition_id',
          )
          .get()) {
    if (row.read<int>('position_ms') > 0) {
      protectedPositions.add(row.read<String>('book_id'));
    }
  }
  // A deliberate rewind to zero is still protected when local listening exists.
  for (final record in await assets.repository.records('audio_event')) {
    final data = record.payload;
    if (data?['kind'] == 'listen' && (data?['wallMs'] as num? ?? 0) > 0) {
      protectedPositions.add(data!['bookId'] as String);
    }
  }
  // Snapshot names contain creation time. Restore newest available position
  // first, then merge older journals without rewinding existing progress.
  files.sort((a, b) {
    final x = a.name.contains('library-'), y = b.name.contains('library-');
    if (x != y) return x ? -1 : 1;
    final base = b.name
        .replaceFirst(RegExp(r'\.bak$'), '')
        .compareTo(a.name.replaceFirst(RegExp(r'\.bak$'), ''));
    return base != 0 ? base : a.name.compareTo(b.name);
  });
  for (final file in files) {
    if (!file.name.contains('library-') && !file.name.contains('events-')) {
      continue;
    }
    try {
      final snapshot = parseAudioSnapshot(await file.read());
      await restoreAudioSnapshot(
        assets,
        root,
        snapshot,
        backup: false,
        merge: true,
        preserveProgressBookIds: protectedPositions,
        preserveEventIds: protectedEvents,
      );
    } catch (e) {
      failures.add('${file.name}: $e');
    }
  }
  await assets.repository.setMeta(
    'recovery-error:${root.key}',
    failures.join('\n'),
  );
  if (failures.isNotEmpty) {
    throw StateError(
      'Часть истории не восстановлена. Исходные журналы сохранены. ${failures.first}',
    );
  }
}

Future<void> recoverReadingRoot(
  AssetStore assets,
  String path,
  List<String> ids,
) async {
  final repo = assets.repository;
  final library = ReadingLibrary(repo);
  final failures = <String>[];
  await repo.setMeta(
    'reading-recovery-error:$path',
    'Восстановление не завершено',
  );
  for (final file in await supportFiles(path)) {
    if (!file.name.contains('reading-')) continue;
    try {
      final packet = jsonDecode(await file.read()) as Map<String, dynamic>;
      if (packet['format'] != 'pepehub-reading-log' || packet['version'] != 1) {
        continue;
      }
      await repo.db.transaction(() async {
        for (final raw in packet['sessions'] as List) {
          final session = Map<String, dynamic>.from(raw as Map);
          final asset = await assets.byHash(session['hash'] as String);
          if (asset == null || !ids.contains(asset.bookId)) continue;
          session['bookId'] = asset.bookId;
          final key = 'reading-session:${session['id']}';
          final previous = await library.value(key);
          final end = DateTime.parse(session['endedAt'] as String);
          if (previous.isNotEmpty &&
              !end.isAfter(DateTime.parse(previous['endedAt'] as String))) {
            continue;
          }
          await repo.setMeta(key, jsonEncode(session));
          final pendingKey = 'reading-recovered-position:${asset.hash}';
          final pending = await library.value(pendingKey);
          if (pending.isEmpty ||
              end.isAfter(DateTime.parse(pending['endedAt'] as String))) {
            await repo.setMeta(
              pendingKey,
              jsonEncode({
                'position': session['position'],
                'endedAt': session['endedAt'],
              }),
            );
          }
          final dates = await library.value('reading-dates:${asset.bookId}');
          final started = session['startedAt'] as String;
          if (dates['startedAt'] == null ||
              DateTime.parse(started)
                  .isBefore(DateTime.parse(dates['startedAt'] as String))) {
            await library.update('reading-dates:${asset.bookId}', {
              'startedAt': started,
            });
          }
        }
        for (final raw in packet['manualSessions'] as List? ?? []) {
          final saved = Map<String, dynamic>.from(raw as Map);
          final hash = saved.remove('hash') as String?;
          final id = saved.remove('id') as String?;
          if (hash == null || id == null) continue;
          final asset = await assets.byHash(hash);
          if (asset == null || !ids.contains(asset.bookId)) continue;
          if (await repo.record(id) != null) continue;
          saved['bookId'] = asset.bookId;
          await repo.put('session', id, saved);
        }
        for (final raw in packet['books'] as List? ?? []) {
          final book = raw as Map;
          final hash = book['hash'] as String;
          final asset = await assets.byHash(hash);
          if (asset == null || !ids.contains(asset.bookId)) continue;
          for (final prefix in [
            'reader',
            'reading-coverage',
            'reading-index',
          ]) {
            final value = book[prefix];
            final key = '$prefix:$hash';
            if (value is Map &&
                value.isNotEmpty &&
                await repo.meta(key) == null) {
              await repo.setMeta(
                key,
                jsonEncode(
                  prefix == 'reading-index'
                      ? {...value, 'cover': null, 'needsCoverRefresh': true}
                      : value,
                ),
              );
            }
          }
          final dates = book['dates'];
          if (dates is Map) {
            await repo.setMeta(
              'reading-dates:${asset.bookId}',
              jsonEncode({
                ...dates,
                ...await library.value('reading-dates:${asset.bookId}'),
              }),
            );
          }
        }
      });
    } catch (e) {
      failures.add('${file.name}: $e');
    }
  }
  await repo.setMeta('reading-recovery-error:$path', failures.join('\n'));
  if (failures.isNotEmpty) {
    throw StateError(
      'Часть истории чтения не восстановлена. Журналы сохранены. ${failures.first}',
    );
  }
}
