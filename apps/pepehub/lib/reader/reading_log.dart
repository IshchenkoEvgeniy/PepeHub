import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../audio/audio_folder.dart';
import '../data/repository.dart';
import 'reading_activity.dart';
import 'reading_library.dart';

class ReadingLog {
  final Repository repository;
  ReadingLog(this.repository);
  Future<void> export(Map<String, dynamic> session) async {
    try {
      await _export(session);
      await repository.setMeta('reading-log-error:${session['bookId']}', '');
    } catch (e) {
      await repository.setMeta('reading-log-error:${session['bookId']}', '$e');
      rethrow;
    }
  }

  Future<void> _export(Map<String, dynamic> session) async {
    final library = ReadingLibrary(repository);
    final day = readingDay(
      DateTime.parse(session['startedAt'] as String).toLocal(),
    );
    final roots = await library.entries('reading-library-root:');
    final sessions = await library.entries('reading-session:');
    final manual = (await repository.records('session'))
        .where((row) => row.payload?['kind'] == 'reading')
        .toList();
    for (final root in roots.values) {
      final ids = (root['bookIds'] as List).cast<String>().toSet();
      if (!ids.contains(session['bookId'])) continue;
      if ((await repository.meta('reading-recovery-error:${root['path']}') ??
              '')
          .isNotEmpty) {
        throw StateError(
          'Журнал защищён до завершения восстановления истории.',
        );
      }
      final rows = await repository.db
          .customSelect('SELECT book_id,sha256 FROM local_assets')
          .get();
      final books = <Map<String, dynamic>>[];
      final hashes = <String, String>{};
      for (final row in rows) {
        final id = row.read<String>('book_id'),
            hash = row.read<String>('sha256');
        if (!ids.contains(id)) continue;
        hashes[id] = hash;
        books.add({
          'hash': hash,
          for (final prefix in ['reader', 'reading-coverage', 'reading-index'])
            prefix: await library.value('$prefix:$hash'),
          'dates': await library.value('reading-dates:$id'),
        });
      }
      final text = jsonEncode({
        'format': 'pepehub-reading-log',
        'version': 1,
        'day': day,
        'books': books,
        'sessions': sessions.values
            .where(
              (s) =>
                  ids.contains(s['bookId']) &&
                  readingDay(
                        DateTime.parse(s['startedAt'] as String).toLocal(),
                      ) ==
                      day,
            )
            .toList(),
        'manualSessions': [
          for (final row in manual)
            if (ids.contains(row.payload?['bookId']) &&
                readingDay(
                      DateTime.parse(row.payload!['startedAt'] as String)
                          .toLocal(),
                    ) ==
                    day &&
                hashes.containsKey(row.payload!['bookId']))
              {
                'id': row.id,
                'hash': hashes[row.payload!['bookId']],
                ...row.payload!,
              },
        ],
      });
      if (utf8.encode(text).length > 16 * 1024 * 1024) {
        throw StateError(
          'Журнал чтения превышает 16 МиБ; данные сохранены в приложении.',
        );
      }
      final path = root['path'] as String, name = 'reading-$day.json';
      if (path.startsWith('content:')) {
        await audioFolderChannel.invokeMethod<void>('readingJournal', {
          'root': path,
          'day': day,
          'name': name,
          'json': text,
          'replace': true,
        });
      } else {
        var directory = Directory(path);
        if (!await directory.exists()) {
          throw StateError('Папка чтения недоступна: $path');
        }
        for (final part in ['.pepehub', 'reading', 'logs', day]) {
          directory = Directory(p.join(directory.path, part));
          final type = await FileSystemEntity.type(
            directory.path,
            followLinks: false,
          );
          if (type != FileSystemEntityType.notFound &&
              type != FileSystemEntityType.directory) {
            throw StateError('Каталог журнала недоступен');
          }
          await directory.create();
        }
        final target = File(p.join(directory.path, name)),
            backup = File(p.join(directory.path, '$name.bak'));
        final temp = File('${target.path}.${uuid.v4()}.partial');
        try {
          await temp.writeAsString(text, flush: true);
          if (await target.exists()) {
            if (await backup.exists()) await backup.delete();
            await target.rename(backup.path);
          }
          await temp.rename(target.path);
        } finally {
          if (await temp.exists()) await temp.delete();
        }
      }
      await repository.setMeta(
        'reading-log-saved:${session['bookId']}',
        DateTime.now().toUtc().toIso8601String(),
      );
      await repository.setMeta(
        'reading-log-path:${session['bookId']}',
        '$path/.pepehub/reading/logs/$day/$name',
      );
    }
  }

  /// Rewrites every recorded day in each connected reading folder.
  Future<int> exportAll({String? bookId}) async {
    final automatic = (await ReadingLibrary(
      repository,
    ).entries('reading-session:')).values;
    final manual = (await repository.records('session'))
        .where((row) => row.payload?['kind'] == 'reading')
        .map((row) => row.payload!);
    final unique = <String, Map<String, dynamic>>{};
    for (final row in [...automatic, ...manual]) {
      final rowBookId = row['bookId'] as String?;
      final start = DateTime.tryParse(row['startedAt'] as String? ?? '');
      if (rowBookId == null ||
          start == null ||
          (bookId != null && rowBookId != bookId)) {
        continue;
      }
      unique['$rowBookId:${readingDay(start.toLocal())}'] = row;
    }
    for (final row in unique.values) {
      await export(row);
    }
    return unique.length;
  }
}
