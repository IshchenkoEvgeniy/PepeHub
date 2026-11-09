import '../data/repository.dart';
import 'activity_store.dart';
import 'library_exchange.dart';
import 'library_features.dart';
import 'library_repository.dart';
import 'note_store.dart';
import 'personal_library.dart';

/// Per-book shelf settings that mean nothing once a book is deleted for good:
/// reconnecting its folder adds the files as new books with new ids.
/// Statistics (sessions, reading days, listening events) and native notes are
/// not listed: they stay in the history as a book from the archive.
List<String> purgedBookMetaKeys(String id) => [
  'reading-book:$id',
  'reading-plan:$id',
  'reading-user-hidden:$id',
  'reading-library-hidden:$id',
  'reading-deleted:$id',
  'reading-source-path:$id',
  'reading-imported:$id',
  'reading-import-location:$id',
  'audio-status-override:$id',
  'audio-user-hidden:$id',
  'audio-library-hidden:$id',
  'audio-source-missing:$id',
  'audio-source-path:$id',
  'audio-folder-book:$id',
  'audio-cover:$id',
  'audio-cover-hidden:$id',
  'audio-cover-missing:$id',
];

/// Removes the personal library's service records (file statuses, positions,
/// automatic drafts) whose source book is gone: listed in [sourceIds], or, when
/// [sourceIds] is null, already deleted for good by the trash. Cards the user added to the
/// library are never touched: a library card outlives its file.
/// Returns how many records were removed.
Future<int> discardPurgedBookDrafts(
  Repository local, {
  Set<String>? sourceIds,
}) => local.db.transaction(() async {
  final repository = LibraryRepository(
    local,
    personalLibraryNamespace,
    storageKey: personalLibraryKey,
  );
  final removed = <String>{};
  final gone = <String, bool>{};
  Future<bool> isGone(String source) async {
    if (sourceIds != null) return sourceIds.contains(source);
    final cached = gone[source];
    if (cached != null) return cached;
    final record = await local.record(source);
    // The trash leaves a deletion marker. A book in the trash keeps its
    // record, and an unknown id proves nothing, so both stay.
    return gone[source] = record?.deleted == true;
  }

  await repository.mutate((cards) async {
    for (final e in cards.entries.toList()) {
      final source = e.value.sourceBookId;
      if (source == null || isSeriesCatalogItem(e.value.item)) continue;
      if (!await isGone(source)) continue;
      cards.remove(e.key);
      removed.add(e.key);
    }
  });
  if (removed.isEmpty) return 0;
  for (final store in [
    ActivityStore(local, personalLibraryNamespace),
    NoteStore(local, personalLibraryNamespace),
  ]) {
    await store.mutate((state) async {
      (state['slots'] as Map).removeWhere(
        (_, slot) => removed.contains((slot['value'] as Map)['itemId']),
      );
    });
  }
  await LibraryExchange.detachRemovedCards(local, removed);
  for (final id in removed) {
    await local.db.customStatement('DELETE FROM metadata WHERE key IN (?,?)', [
      'obsidian-policy:$personalLibraryNamespace:$id',
      'obsidian-auto:$personalLibraryNamespace:$id',
    ]);
  }
  return removed.length;
});
