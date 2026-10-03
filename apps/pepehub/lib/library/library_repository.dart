import 'dart:convert';

import '../data/repository.dart';
import 'models.dart';

/// Uses the existing transactional SQLite metadata store, outside the legacy sync outbox.
class LibraryRepository {
  final Repository repository;
  final String namespace;
  LibraryRepository(this.repository, this.namespace);
  String get _key => 'obsidian-library:$namespace';
  Future<Map<String, LibraryEntry>> entries() async {
    final raw = await repository.meta(_key);
    if (raw == null) return {};
    final data = jsonDecode(raw) as Map<String, dynamic>;
    return data.map(
      (id, value) => MapEntry(
        id,
        LibraryEntry.fromJson(Map<String, dynamic>.from(value as Map)),
      ),
    );
  }

  Future<void> mutate(
    Future<void> Function(Map<String, LibraryEntry>) action,
  ) => repository.db.transaction(() async {
    final data = await entries();
    await action(data);
    await repository.setMeta(
      _key,
      jsonEncode(data.map((id, entry) => MapEntry(id, entry.toJson()))),
    );
  });
  Future<Map<String, dynamic>?> snapshot() async {
    final raw = await repository.meta('$_key:schema');
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<void> receive(Map<String, dynamic> snapshot) =>
      mutate((entries) async {
        if (snapshot['version'] != 1 || snapshot['ready'] != true) return;
        final remote = {
          for (final data in snapshot['items'] as List)
            (data as Map)['id'] as String: ObsidianLibraryItem.fromJson(
              Map<String, dynamic>.from(data),
            ),
        };
        for (final entry in remote.entries) {
          final old = entries[entry.key];
          entries[entry.key] = old?.operation != null
              ? LibraryEntry(
                  old!.item,
                  state: old.state,
                  sourceBookId: old.sourceBookId,
                  message: old.message,
                  operation: old.operation,
                  remote: entry.value,
                )
              : LibraryEntry(entry.value, sourceBookId: old?.sourceBookId);
        }
        for (final id in entries.keys.toList()) {
          final entry = entries[id]!;
          if (!remote.containsKey(id) && entry.operation != null) {
            entries[id] = LibraryEntry(
              entry.item,
              state: entry.state,
              sourceBookId: entry.sourceBookId,
              message: entry.message,
              operation: entry.operation,
            );
          }
          if (!remote.containsKey(id) && entry.operation == null) {
            // Keep the local card for inspection; never resurrect a remotely removed item.
            entries[id] = LibraryEntry(
              entry.item,
              state: 'removed',
              sourceBookId: entry.sourceBookId,
              message: 'Карточка больше не входит в библиотеку Obsidian.',
            );
          }
        }
        await repository.setMeta('$_key:schema', jsonEncode(snapshot));
      });
  Future<void> receipt(String id, Map<String, dynamic> receipt) =>
      mutate((entries) async {
        final entry = entries[id];
        if (entry == null ||
            entry.operation?['operationId'] != receipt['operationId']) {
          return;
        }
        switch (receipt['status']) {
          case 'applied':
            entries[id] = LibraryEntry(
              entry.item,
              sourceBookId: entry.sourceBookId,
            );
          case 'conflict':
          case 'error':
            entries[id] = LibraryEntry(
              entry.item,
              state: receipt['status'] as String,
              sourceBookId: entry.sourceBookId,
              message: receipt['message'] as String?,
              operation: entry.operation,
              remote: entry.remote,
            );
        }
      });
}
