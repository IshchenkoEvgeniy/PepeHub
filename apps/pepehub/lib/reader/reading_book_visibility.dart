import 'package:drift/drift.dart' show Variable;

import '../data/repository.dart';

/// File availability is local; it never changes a book's reading status or
/// creates a record tombstone. Writers use their existing metadata transaction.
class ReadingBookVisibility {
  final Repository repository;
  const ReadingBookVisibility(this.repository);
  static const prefix = 'reading-deleted:';

  Future<Set<String>> deletedIds() async => {
    for (final row
        in await repository.db
            .customSelect(
              'SELECT key FROM metadata WHERE key>=? AND key<? AND value=?',
              variables: [
                Variable(prefix),
                Variable('$prefix\uffff'),
                const Variable('1'),
              ],
            )
            .get())
      row.read<String>('key').substring(prefix.length),
  };

  Future<void> deleted(String id, {bool byUser = false}) async {
    await repository.setMeta('$prefix$id', '1');
    await repository.setMeta('reading-library-hidden:$id', '1');
    if (byUser) await repository.setMeta('reading-user-hidden:$id', '0');
  }

  Future<void> available(String id) async {
    await repository.setMeta('$prefix$id', '0');
    await repository.setMeta(
      'reading-library-hidden:$id',
      await repository.meta('reading-user-hidden:$id') == '1' ? '1' : '0',
    );
  }
}
