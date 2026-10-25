import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/foundation.dart';

import 'database.dart';
import 'cloud_transport_state.dart';

const uuid = Uuid();

class LibraryRecord {
  final String id, type;
  final int revision;
  final bool deleted;
  final Map<String, dynamic>? payload;
  const LibraryRecord(
    this.id,
    this.type,
    this.revision,
    this.deleted,
    this.payload,
  );
  factory LibraryRecord.fromRow(QueryRow row) => LibraryRecord(
    row.read<String>('id'),
    row.read<String>('type'),
    row.read<int>('revision'),
    row.read<int>('deleted') == 1,
    jsonDecode(row.read<String>('payload')) as Map<String, dynamic>?,
  );
  factory LibraryRecord.fromJson(Map<String, dynamic> json) => LibraryRecord(
    json['entityId'] as String,
    json['entityType'] as String,
    json['revision'] as int,
    json['deleted'] as bool,
    json['payload'] as Map<String, dynamic>?,
  );
  String get title => payload?['title'] as String? ?? '';
}

class Repository {
  static final _externalChanges = Expando<ValueNotifier<int>>();
  ValueListenable<int> get externalChanges =>
      _externalChanges[db] ??= ValueNotifier(0);
  void notifyExternalChange() {
    final notifier = _externalChanges[db] ??= ValueNotifier(0);
    notifier.value++;
  }

  final AppDatabase db;
  Repository(this.db);
  late final cloud = CloudTransportState(db);
  Future<void> initializeTransports() => db.transaction(cloud.initialize);
  Future<void> setCloudTracking(bool value) async {
    await db.transaction(() async {
      await setMeta('cloud-transport-enabled', value ? '1' : '0');
      await cloud.initialize();
    });
  }

  String _digest(LibraryRecord record) =>
      cloud.digest(record.type, record.deleted, record.payload);
  Future<void> _rememberCloud(LibraryRecord record) =>
      cloud.remember(record.id, _digest(record));
  Future<void> _applyCloudRecord(LibraryRecord remote) async {
    final local = await record(remote.id);
    final next = LibraryRecord(
      remote.id,
      remote.type,
      local == null
          ? 1
          : local.revision + (_digest(local) == _digest(remote) ? 0 : 1),
      remote.deleted,
      remote.payload,
    );
    await _write('records', next);
    await _rememberCloud(next);
  }

  Future<bool> _cloudClean(String id) async {
    final local = await record(id);
    return local == null || await cloud.known(id) == _digest(local);
  }

  Future<void> _queueCloudCurrent(LibraryRecord local) async {
    final operation = {
      'schemaVersion': 1,
      'operationId': uuid.v4(),
      'deviceId': await deviceId(),
      'entityType': local.type,
      'entityId': local.id,
      'baseRevision': await cloud.nextBase(local.id),
      'action': local.deleted ? 'delete' : 'put',
      'payload': local.deleted ? null : local.payload,
    };
    await db.customStatement(
      'INSERT INTO outbox(operation_id,entity_id,operation) VALUES(?,?,?)',
      [operation['operationId'], local.id, jsonEncode(operation)],
    );
    await _rememberCloud(local);
  }

  /// Capture changes made through the peer/local paths only when the cloud
  /// transport is explicitly enabled, using its own confirmed server baseline.
  Future<void> prepareCloudChanges() async {
    await cloud.initialize();
    if (!await cloud.enabled) throw StateError('Облачный транспорт не включён');
    await db.transaction(() async {
      for (final row
          in await db
              .customSelect(
                "SELECT * FROM records WHERE type IN ('book','session') ORDER BY id",
              )
              .get()) {
        final local = LibraryRecord.fromRow(row);
        if (await cloud.known(local.id) == _digest(local)) continue;
        if (await db
                .customSelect(
                  "SELECT 1 FROM outbox WHERE entity_id=? AND state='conflict' LIMIT 1",
                  variables: [Variable(local.id)],
                )
                .getSingleOrNull() !=
            null) {
          continue;
        }
        await _queueCloudCurrent(local);
      }
    });
  }

  Future<String?> meta(String key) async =>
      (await db
              .customSelect(
                'SELECT value FROM metadata WHERE key=?',
                variables: [Variable(key)],
              )
              .getSingleOrNull())
          ?.read<String>('value');

  /// A fixed number of indexed queries, independent of the library size.
  Future<Map<String, String>> metadataPrefixes(List<String> prefixes) async {
    if (prefixes.isEmpty) return {};
    final rows = await db
        .customSelect(
          'SELECT key,value FROM metadata WHERE ${List.filled(prefixes.length, '(key>=? AND key<?)').join(' OR ')}',
          variables: [
            for (final prefix in prefixes) ...[
              Variable(prefix),
              Variable('$prefix\uffff'),
            ],
          ],
        )
        .get();
    return {
      for (final row in rows)
        row.read<String>('key'): row.read<String>('value'),
    };
  }

  Future<void> setMeta(String key, String value) => db.customStatement(
    'INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',
    [key, value],
  );
  Future<String> deviceId() async {
    var id = await meta('device_id');
    if (id == null) {
      id = uuid.v4();
      await setMeta('device_id', id);
    }
    return id;
  }

  Future<List<LibraryRecord>> records(String type) async =>
      (await db
              .customSelect(
                r"SELECT * FROM records WHERE type=? AND deleted=0 ORDER BY json_extract(payload,'$.title'), id",
                variables: [Variable(type)],
              )
              .get())
          .map(LibraryRecord.fromRow)
          .toList();
  Future<List<LibraryRecord>> shelfBooks({required bool audio}) async =>
      (await db
              .customSelect(
                "SELECT * FROM records WHERE type='book' AND deleted=0 AND (json_extract(payload,'\$.format')='audio')=? ORDER BY json_extract(payload,'\$.title'),id",
                variables: [Variable(audio ? 1 : 0)],
              )
              .get())
          .map(LibraryRecord.fromRow)
          .toList();

  Future<LibraryRecord?> record(String id) async {
    final row = await db
        .customSelect(
          'SELECT * FROM records WHERE id=?',
          variables: [Variable(id)],
        )
        .getSingleOrNull();
    return row == null ? null : LibraryRecord.fromRow(row);
  }

  Future<void> _write(String table, LibraryRecord record) => db.customStatement(
    'INSERT INTO $table(id,type,revision,deleted,payload) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET type=excluded.type,revision=excluded.revision,deleted=excluded.deleted,payload=excluded.payload',
    [
      record.id,
      record.type,
      record.revision,
      record.deleted ? 1 : 0,
      jsonEncode(record.payload),
    ],
  );

  Future<void> put(
    String type,
    String id,
    Map<String, dynamic> payload, {
    bool coalesce = false,
  }) async {
    if (type == 'book' &&
        ((payload['title'] as String?)?.trim().isEmpty ?? true)) {
      throw ArgumentError('Введите название');
    }
    await db.transaction(() async {
      await cloud.initialize();
      final device = await deviceId();
      final existing = await record(id);
      if (existing?.deleted == true) throw StateError('Книга удалена');
      if (!await cloud.enabled || type != 'book' && type != 'session') {
        await _write(
          'records',
          LibraryRecord(
            id,
            type,
            (existing?.revision ?? 0) + 1,
            false,
            payload,
          ),
        );
        return;
      }
      final blocked = await db
          .customSelect(
            "SELECT 1 FROM outbox WHERE entity_id=? AND state='conflict'",
            variables: [Variable(id)],
          )
          .getSingleOrNull();
      if (blocked != null) {
        throw StateError('Сначала разрешите конфликт этой записи');
      }
      if (coalesce && existing != null) {
        final latest = await db
            .customSelect(
              'SELECT * FROM outbox WHERE entity_id=? ORDER BY sequence DESC LIMIT 1',
              variables: [Variable(id)],
            )
            .getSingleOrNull();
        if (latest != null &&
            latest.read<int>('attempted') == 0 &&
            latest.read<String>('state') == 'pending') {
          final queued = jsonDecode(
            latest.read<String>('operation'),
          ) as Map<String, dynamic>;
          queued['payload'] = payload;
          await db.customStatement(
            'UPDATE outbox SET operation=? WHERE operation_id=?',
            [jsonEncode(queued), latest.read<String>('operation_id')],
          );
          await _write(
            'records',
            LibraryRecord(id, type, existing.revision, false, payload),
          );
          await _rememberCloud((await record(id))!);
          return;
        }
      }
      final operation = {
        'schemaVersion': 1,
        'operationId': uuid.v4(),
        'deviceId': device,
        'entityType': type,
        'entityId': id,
        'baseRevision': await cloud.nextBase(id),
        'action': 'put',
        'payload': payload,
      };
      await _write(
        'records',
        LibraryRecord(id, type, (existing?.revision ?? 0) + 1, false, payload),
      );
      await db.customStatement(
        'INSERT INTO outbox(operation_id,entity_id,operation) VALUES(?,?,?)',
        [operation['operationId'], id, jsonEncode(operation)],
      );
      await _rememberCloud((await record(id))!);
    });
  }

  /// Queue a synced tombstone for a library card or a manual session.
  Future<void> delete(String type, String id) async {
    if (type != 'book' && type != 'session') {
      throw ArgumentError('Удалять через синхронизацию можно книгу или сессию');
    }
    await db.transaction(() async {
      await cloud.initialize();
      final existing = await record(id);
      if (existing == null || existing.deleted) return;
      if (existing.type != type) throw StateError('Тип записи изменился');
      if (!await cloud.enabled) {
        await _write(
          'records',
          LibraryRecord(id, type, existing.revision + 1, true, null),
        );
        return;
      }
      final blocked = await db
          .customSelect(
            "SELECT 1 FROM outbox WHERE entity_id=? AND state='conflict'",
            variables: [Variable(id)],
          )
          .getSingleOrNull();
      if (blocked != null) {
        throw StateError('Сначала разрешите конфликт этой записи');
      }
      final operation = {
        'schemaVersion': 1,
        'operationId': uuid.v4(),
        'deviceId': await deviceId(),
        'entityType': type,
        'entityId': id,
        'baseRevision': await cloud.nextBase(id),
        'action': 'delete',
        'payload': null,
      };
      await _write(
        'records',
        LibraryRecord(id, type, existing.revision + 1, true, null),
      );
      await db.customStatement(
        'INSERT INTO outbox(operation_id,entity_id,operation) VALUES(?,?,?)',
        [operation['operationId'], id, jsonEncode(operation)],
      );
      await _rememberCloud((await record(id))!);
    });
  }

  Future<void> addBook(String title, String author, String format) =>
      put('book', uuid.v4(), {
        'title': title.trim(),
        'authors': author.trim().isEmpty ? <String>[] : [author.trim()],
        'format': format,
        'status': 'planned',
      });
  Future<void> addSession(LibraryRecord book, int minutes) async {
    if (minutes < 1 || minutes > 1440) {
      throw ArgumentError('Продолжительность от 1 до 1440 минут');
    }
    final end = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().millisecondsSinceEpoch,
      isUtc: true,
    );
    await put('session', uuid.v4(), {
      'bookId': book.id,
      'kind': book.payload!['format'] == 'audio' ? 'listening' : 'reading',
      'startedAt': end.subtract(Duration(minutes: minutes)).toIso8601String(),
      'endedAt': end.toIso8601String(),
      'activeSeconds': minutes * 60,
      'timezone': 'UTC',
      'source': 'manual',
    });
  }

  Future<List<QueryRow>> pending() => db
      .customSelect(
        "SELECT * FROM outbox WHERE state='pending' AND entity_id NOT IN (SELECT entity_id FROM outbox WHERE state='conflict') ORDER BY sequence",
      )
      .get();
  Future<Map<String, dynamic>> freezeOperation(String operationId) =>
      db.transaction(() async {
        await db.customStatement(
          'UPDATE outbox SET attempted=1 WHERE operation_id=?',
          [operationId],
        );
        final row = await db
            .customSelect(
              'SELECT operation FROM outbox WHERE operation_id=?',
              variables: [Variable(operationId)],
            )
            .getSingle();
        return jsonDecode(row.read<String>('operation'))
            as Map<String, dynamic>;
      });
  Future<int> pendingCount() async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM outbox').getSingle())
          .read<int>('n');
  Future<List<QueryRow>> conflicts() => db
      .customSelect(
        "SELECT * FROM outbox WHERE state='conflict' ORDER BY sequence",
      )
      .get();

  Future<void> configureIdentity(String device, String server) async {
    final identity = '$server|$device';
    final pinned = await meta('sync_identity');
    if (pinned != null && pinned != identity) {
      throw StateError(
        'Эта база уже связана с другим сервером или устройством. Смена аккаунта пока не поддерживается.',
      );
    }
    await db.transaction(() async {
      // Before the first network attempt, offline-created operations can adopt a provisioned device.
      if (pinned == null) {
        for (final row in await pending()) {
          final op =
              jsonDecode(row.read<String>('operation')) as Map<String, dynamic>;
          op['deviceId'] = device;
          await db.customStatement(
            'UPDATE outbox SET operation=? WHERE operation_id=?',
            [jsonEncode(op), op['operationId']],
          );
        }
      }
      await setMeta('device_id', device);
      await setMeta('sync_identity', identity);
    });
  }

  Future<void> applyReceipt(Map<String, dynamic> receipt) =>
      db.transaction(() async {
        await cloud.initialize();
        final row = await db
            .customSelect(
              'SELECT entity_id FROM outbox WHERE operation_id=?',
              variables: [Variable(receipt['operationId'] as String)],
            )
            .getSingleOrNull();
        if (row == null) return;
        final id = row.read<String>('entity_id');
        if (receipt['status'] == 'conflict') {
          await db.customStatement(
            "UPDATE outbox SET state='conflict',receipt=? WHERE operation_id=?",
            [jsonEncode(receipt), receipt['operationId']],
          );
          return;
        }
        await db.customStatement('DELETE FROM outbox WHERE operation_id=?', [
          receipt['operationId'],
        ]);
        var remote = LibraryRecord.fromJson(
          receipt['current'] as Map<String, dynamic>,
        );
        final known = await db
            .customSelect(
              'SELECT * FROM remote_records WHERE id=?',
              variables: [Variable(id)],
            )
            .getSingleOrNull();
        if (known != null && known.read<int>('revision') > remote.revision) {
          remote = LibraryRecord.fromRow(known);
        } else {
          await _write('remote_records', remote);
        }
        if ((await db
                        .customSelect(
                          'SELECT COUNT(*) AS n FROM outbox WHERE entity_id=?',
                          variables: [Variable(id)],
                        )
                        .getSingle())
                    .read<int>('n') ==
                0 &&
            await _cloudClean(id)) {
          await _applyCloudRecord(remote);
        }
      });
  Future<void> applyPage(Map<String, dynamic> page) => db.transaction(() async {
    await cloud.initialize();
    for (final item in page['changes'] as List) {
      final incoming = LibraryRecord.fromJson(item as Map<String, dynamic>);
      final known = await db
          .customSelect(
            'SELECT revision FROM remote_records WHERE id=?',
            variables: [Variable(incoming.id)],
          )
          .getSingleOrNull();
      if (known != null && known.read<int>('revision') >= incoming.revision) {
        continue;
      }
      final clean = await _cloudClean(incoming.id);
      final count =
          (await db
                  .customSelect(
                    'SELECT COUNT(*) AS n FROM outbox WHERE entity_id=?',
                    variables: [Variable(incoming.id)],
                  )
                  .getSingle())
              .read<int>('n');
      if (count == 0 && !clean && await cloud.enabled) {
        final local = await record(incoming.id);
        if (local != null &&
            (local.type == 'book' || local.type == 'session')) {
          await _queueCloudCurrent(local);
        }
      }
      await _write('remote_records', incoming);
      if (count == 0 && clean) {
        await _applyCloudRecord(incoming);
      }
    }
    await setMeta('cursor', '${page['cursor']}');
  });
  Future<void> useServerVersion(String operationId) => db.transaction(() async {
    await cloud.initialize();
    final row = await db
        .customSelect(
          "SELECT * FROM outbox WHERE operation_id=? AND state='conflict'",
          variables: [Variable(operationId)],
        )
        .getSingle();
    final id = row.read<String>('entity_id');
    final receipt =
        jsonDecode(row.read<String>('receipt')) as Map<String, dynamic>;
    final latest = await db
        .customSelect(
          'SELECT * FROM remote_records WHERE id=?',
          variables: [Variable(id)],
        )
        .getSingleOrNull();
    final remote = latest == null
        ? (receipt['current'] == null
              ? null
              : LibraryRecord.fromJson(
                  receipt['current'] as Map<String, dynamic>,
                ))
        : LibraryRecord.fromRow(latest);
    await db.customStatement('DELETE FROM outbox WHERE entity_id=?', [id]);
    if (remote == null) {
      await db.customStatement('DELETE FROM records WHERE id=?', [id]);
    } else {
      await _applyCloudRecord(remote);
    }
  });
}
