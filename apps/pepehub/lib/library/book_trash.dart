import 'package:drift/drift.dart' show Variable;

import '../data/repository.dart';
import 'purged_books.dart';

/// A book or audiobook removed from PepeHub and kept in the trash.
class TrashedBook {
  final String id, title;
  final bool audio, hasSource;

  /// When it was removed; null for removals made before the trash existed.
  final DateTime? removedAt;
  const TrashedBook(
    this.id,
    this.title, {
    required this.audio,
    required this.hasSource,
    this.removedAt,
  });
}

/// One trash for books and audiobooks removed from PepeHub.
///
/// Removal keeps the record, progress, notes and history, so restoring is
/// lossless. A book stays here for [retentionDays] (30 by default) and is then
/// deleted for good. Files are never touched by the trash itself.
class BookTrash {
  final Repository repository;
  const BookTrash(this.repository);

  static const removedAtPrefix = 'book-shelf-removed-at:';
  static const retentionKey = 'book-trash-retention-days';

  /// Retention starts no earlier than this, so updating the app never deletes
  /// books removed by older versions straight away.
  static const policyStartKey = 'book-trash-policy-start';
  static const retentionChoices = [0, 7, 30, 90];

  Future<void> move(Iterable<String> ids) async {
    final selected = ids.toSet();
    if (selected.isEmpty) return;
    final now = DateTime.now().toUtc().toIso8601String();
    await repository.db.transaction(() async {
      await repository.removeShelfBooks(selected);
      for (final id in selected) {
        await repository.setMeta('$removedAtPrefix$id', now);
      }
    });
    repository.notifyExternalChange();
  }

  Future<void> restore(Iterable<String> ids) async {
    final selected = ids.toSet();
    if (selected.isEmpty) return;
    await repository.db.transaction(() async {
      for (final id in selected) {
        final book = await repository.record(id);
        await repository.restoreRemovedShelfBook(
          id,
          audio: book?.payload?['format'] == 'audio',
        );
        await repository.db.customStatement(
          'DELETE FROM metadata WHERE key=?',
          ['$removedAtPrefix$id'],
        );
      }
    });
    repository.notifyExternalChange();
  }

  /// Books in the trash, newest first. List projection only.
  Future<List<TrashedBook>> list() async {
    final rows = await repository.db
        .customSelect(
          '''
      SELECT b.id,json_extract(b.payload,'\$.title') AS title,
        IFNULL(json_extract(b.payload,'\$.format'),'')='audio' AS audio,
        at.value AS removed_at,
        (EXISTS(SELECT 1 FROM local_assets a WHERE a.book_id=b.id)
          OR EXISTS(SELECT 1 FROM audio_editions e WHERE e.book_id=b.id)) AS has_source
      FROM metadata m
      JOIN records b ON b.id=substr(m.key,?) AND b.type='book' AND b.deleted=0
      LEFT JOIN metadata at ON at.key=?||b.id
      WHERE m.key>=? AND m.key<? AND m.value='1'
      ''',
          variables: [
            Variable(Repository.removedShelfBookPrefix.length + 1),
            const Variable(removedAtPrefix),
            const Variable(Repository.removedShelfBookPrefix),
            Variable('${Repository.removedShelfBookPrefix}￿'),
          ],
        )
        .get();
    final books = [
      for (final row in rows)
        TrashedBook(
          row.read<String>('id'),
          row.readNullable<String>('title') ?? 'Без названия',
          audio: row.read<int>('audio') == 1,
          hasSource: row.read<int>('has_source') == 1,
          removedAt: DateTime.tryParse(
            row.readNullable<String>('removed_at') ?? '',
          )?.toLocal(),
        ),
    ];
    books.sort((a, b) {
      final x = a.removedAt, y = b.removedAt;
      if (x == null || y == null) {
        return x == null && y == null
            ? a.title.compareTo(b.title)
            : (x == null ? 1 : -1);
      }
      return y.compareTo(x);
    });
    return books;
  }

  /// Deletes books for good: the record, its file registrations, folder
  /// bindings, shelf settings and the personal library's service record for
  /// the file. Cards the user added to the library, statistics and notes stay.
  /// Reconnecting the folder later adds the files as new books.
  Future<void> purge(Iterable<String> ids) async {
    final selected = ids.toSet();
    if (selected.isEmpty) return;
    await repository.db.transaction(() async {
      for (final id in selected) {
        await repository.delete('book', id);
        await repository.db.customStatement(
          'DELETE FROM local_assets WHERE book_id=?',
          [id],
        );
        await repository.db.customStatement(
          "DELETE FROM metadata WHERE key>='audio-folder:' AND key<'audio-folder;' AND value=?",
          [id],
        );
        final keys = [
          '$removedAtPrefix$id',
          '${Repository.removedShelfBookPrefix}$id',
          ...purgedBookMetaKeys(id),
        ];
        await repository.db.customStatement(
          'DELETE FROM metadata WHERE key IN '
          '(${List.filled(keys.length, '?').join(',')})',
          keys,
        );
      }
      await discardPurgedBookDrafts(repository, sourceIds: selected);
    });
    repository.notifyExternalChange();
  }

  Future<int> retentionDays() async {
    final value = int.tryParse(await repository.meta(retentionKey) ?? '');
    return retentionChoices.contains(value) ? value! : 30;
  }

  Future<void> setRetention(int days) async {
    if (!retentionChoices.contains(days)) {
      throw ArgumentError('Срок хранения: 0, 7, 30 или 90 дней');
    }
    await repository.setMeta(retentionKey, '$days');
    await purgeExpired();
  }

  /// Removes books kept longer than the retention period. Returns how many.
  Future<int> purgeExpired({DateTime? now}) async {
    final days = await retentionDays();
    if (days == 0) return 0;
    final current = now ?? DateTime.now();
    var start = DateTime.tryParse(await repository.meta(policyStartKey) ?? '');
    if (start == null) {
      start = current;
      await repository.setMeta(
        policyStartKey,
        current.toUtc().toIso8601String(),
      );
    }
    final cutoff = current.subtract(Duration(days: days));
    final expired = [
      for (final book in await list())
        if ((book.removedAt == null || book.removedAt!.isBefore(start)
                ? start
                : book.removedAt!)
            .isBefore(cutoff))
          book.id,
    ];
    await purge(expired);
    return expired.length;
  }
}
