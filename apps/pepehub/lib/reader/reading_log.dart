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
      for (final row in rows) {
        final id = row.read<String>('book_id'),
            hash = row.read<String>('sha256');
        if (!ids.contains(id)) continue;
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
    }
  }
}
