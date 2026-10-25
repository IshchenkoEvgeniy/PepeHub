import 'dart:convert';

import '../data/repository.dart';
import '../media/asset_store.dart';

/// A remote book card is not a downloaded book. Keep it discoverable without
/// including it in the ordinary shelf counts or deleting its reading history.
class ReadingShelfSources {
  final Map<String, List<LocalAsset>> byBook = {};
  final Map<String, Map<String, dynamic>> shared = {};
  final Map<String, String> sharedIds = {};
  final Map<String, Map<String, dynamic>> receivedFrom = {};
  ReadingShelfSources(Iterable<LocalAsset> assets) {
    for (final asset in assets) {
      (byBook[asset.bookId] ??= []).add(asset);
    }
  }
  LocalAsset? first(String id) => byBook[id]?.firstOrNull;
  bool remoteOnly(String id) => shared.containsKey(id) && first(id) == null;

  Future<void> load(Repository repository) async {
    for (final entry in (await repository.metadataPrefixes([
      'peer-book-origin:',
    ])).entries) {
      receivedFrom[entry.key.substring('peer-book-origin:'.length)] =
          Map<String, dynamic>.from(jsonDecode(entry.value) as Map);
    }
    final table = await repository.db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name='peer_app_alias'",
        )
        .get();
    if (table.isEmpty) return;
    for (final row
        in await repository.db
            .customSelect(
              "SELECT local_id,shared_id,data FROM peer_app_alias WHERE kind='book'",
            )
            .get()) {
      final data = jsonDecode(row.read<String>('data')) as Map;
      if (data['descriptor'] case final Map descriptor) {
        final id = row.read<String>('local_id');
        shared[id] = Map<String, dynamic>.from(descriptor);
        sharedIds[id] = row.read<String>('shared_id');
      }
    }
  }
}
