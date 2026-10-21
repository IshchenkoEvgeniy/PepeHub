import 'dart:convert';

import 'package:drift/drift.dart';

import '../../data/database.dart';

import 'app_sync_models.dart';
import 'peer_models.dart';
import 'peer_store.dart';

class AppSyncStore {
  final PeerStore peer;
  AppSyncStore(this.peer);
  AppDatabase get db => peer.repository.db;
  Future<void> initialize() async {
    await db.customStatement(
      'CREATE TABLE IF NOT EXISTS peer_app_versions(id TEXT PRIMARY KEY,entity_key TEXT NOT NULL,payload TEXT NOT NULL,active INTEGER NOT NULL)',
    );
    await db.customStatement(
      'CREATE INDEX IF NOT EXISTS peer_app_heads ON peer_app_versions(entity_key,active)',
    );
    await db.customStatement(
      'CREATE TABLE IF NOT EXISTS peer_app_projection(entity_key TEXT PRIMARY KEY,target TEXT NOT NULL,digest TEXT NOT NULL,clock TEXT NOT NULL,materialized INTEGER NOT NULL)',
    );
    await db.customStatement(
      'CREATE TABLE IF NOT EXISTS peer_app_alias(kind TEXT NOT NULL,local_id TEXT NOT NULL,shared_id TEXT NOT NULL,data TEXT NOT NULL,PRIMARY KEY(kind,local_id))',
    );
    await db.customStatement(
      'CREATE INDEX IF NOT EXISTS peer_app_shared ON peer_app_alias(kind,shared_id)',
    );
  }

  Future<List<AppSyncVersion>> heads([String? key]) async => [
    for (final row
        in await db
            .customSelect(
              'SELECT payload FROM peer_app_versions WHERE active=1 ${key == null ? '' : 'AND entity_key=?'} ORDER BY entity_key,id',
              variables: [if (key != null) Variable(key)],
            )
            .get())
      AppSyncVersion.fromJson(
        jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
      ),
  ];
  Future<AppSyncVersion?> version(String id) async {
    final row = await db
        .customSelect(
          'SELECT payload FROM peer_app_versions WHERE id=?',
          variables: [Variable(id)],
        )
        .getSingleOrNull();
    return row == null
        ? null
        : AppSyncVersion.fromJson(
            jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
          );
  }

  Future<bool> merge(AppSyncVersion incoming) async {
    final current = await heads(incoming.key);
    for (final old in current) {
      final relation = comparePeerClocks(old.clock, incoming.clock);
      if (relation == 0 && old.content != incoming.content) {
        throw StateError('Один вектор версий описывает разные данные');
      }
      if (relation == 1 || relation == 0) return false;
    }
    for (final old in current) {
      if (comparePeerClocks(old.clock, incoming.clock) == -1) {
        await db.customStatement(
          'UPDATE peer_app_versions SET active=0 WHERE id=?',
          [old.id],
        );
      }
    }
    await db.customStatement(
      'INSERT INTO peer_app_versions VALUES(?,?,?,1) ON CONFLICT(id) DO UPDATE SET active=1',
      [incoming.id, incoming.key, appSyncJson(incoming.toJson())],
    );
    return true;
  }

  Future<Map<String, AppSyncProjection>> projections() async => {
    for (final row
        in await db.customSelect('SELECT * FROM peer_app_projection').get())
      row.read<String>('entity_key'): AppSyncProjection(
        row.read<String>('entity_key'),
        row.read<String>('target'),
        row.read<String>('digest'),
        Map<String, int>.from(jsonDecode(row.read<String>('clock')) as Map),
        row.read<int>('materialized') == 1,
      ),
  };
  Future<void> project(AppSyncProjection value) => db.customStatement(
    'INSERT INTO peer_app_projection VALUES(?,?,?,?,?) ON CONFLICT(entity_key) DO UPDATE SET target=excluded.target,digest=excluded.digest,clock=excluded.clock,materialized=excluded.materialized',
    [
      value.key,
      value.target,
      value.digest,
      appSyncJson(value.clock),
      value.materialized ? 1 : 0,
    ],
  );
  Future<List<Map<String, dynamic>>> aliases() async => [
    for (final row
        in await db
            .customSelect('SELECT * FROM peer_app_alias ORDER BY kind,local_id')
            .get())
      {
        'kind': row.read<String>('kind'),
        'local': row.read<String>('local_id'),
        'shared': row.read<String>('shared_id'),
        'data': jsonDecode(row.read<String>('data')),
      },
  ];
  Future<void> alias(
    String kind,
    String local,
    String shared,
    Map<String, dynamic> data,
  ) => db.customStatement(
    'INSERT INTO peer_app_alias VALUES(?,?,?,?) ON CONFLICT(kind,local_id) DO UPDATE SET shared_id=excluded.shared_id,data=excluded.data',
    [kind, local, shared, appSyncJson(data)],
  );
}
