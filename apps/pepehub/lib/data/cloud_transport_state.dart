import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import 'database.dart';

/// Optional legacy cloud transport state. Local revisions and peer vectors are
/// never interpreted as revisions issued by the cloud server.
class CloudTransportState {
  final AppDatabase db;
  CloudTransportState(this.db);
  Future<bool> get enabled async =>
      (await db
              .customSelect(
                "SELECT value FROM metadata WHERE key='cloud-transport-enabled'",
              )
              .getSingleOrNull())
          ?.read<String>('value') ==
      '1';

  Future<void> initialize() async {
    await db.customStatement(
      'CREATE TABLE IF NOT EXISTS cloud_local_state(id TEXT PRIMARY KEY,digest TEXT NOT NULL)',
    );
    await db.customStatement(
      'CREATE TABLE IF NOT EXISTS legacy_cloud_outbox(operation_id TEXT PRIMARY KEY,entity_id TEXT NOT NULL,operation TEXT NOT NULL,state TEXT NOT NULL,receipt TEXT,attempted INTEGER NOT NULL,archived_at TEXT NOT NULL)',
    );
    if (await enabled) return;
    // Retain exact operations, receipts and attempt flags before removing them
    // from the active queue. Repeating this migration is safe.
    await db.customStatement(
      "INSERT OR IGNORE INTO legacy_cloud_outbox SELECT operation_id,entity_id,operation,state,receipt,attempted,? FROM outbox",
      [DateTime.now().toUtc().toIso8601String()],
    );
    await db.customStatement('DELETE FROM outbox');
  }

  String digest(String type, bool deleted, Map<String, dynamic>? payload) {
    Object? canonical(Object? v) => v is Map
        ? {
            for (final key in v.keys.cast<String>().toList()..sort())
              key: canonical(v[key]),
          }
        : v is List
        ? v.map(canonical).toList()
        : v;
    return sha256
        .convert(utf8.encode(jsonEncode([type, deleted, canonical(payload)])))
        .toString();
  }

  Future<void> remember(String id, String digest) => db.customStatement(
    'INSERT INTO cloud_local_state(id,digest) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET digest=excluded.digest',
    [id, digest],
  );
  Future<String?> known(String id) async =>
      (await db
              .customSelect(
                'SELECT digest FROM cloud_local_state WHERE id=?',
                variables: [Variable(id)],
              )
              .getSingleOrNull())
          ?.read<String>('digest');
  Future<int> nextBase(String id) async {
    final queued = await db
        .customSelect(
          'SELECT operation FROM outbox WHERE entity_id=? ORDER BY sequence DESC LIMIT 1',
          variables: [Variable(id)],
        )
        .getSingleOrNull();
    if (queued != null) {
      return ((jsonDecode(queued.read<String>('operation'))
                  as Map)['baseRevision']
              as int) +
          1;
    }
    return (await db
                .customSelect(
                  'SELECT revision FROM remote_records WHERE id=?',
                  variables: [Variable(id)],
                )
                .getSingleOrNull())
            ?.read<int>('revision') ??
        0;
  }
}
