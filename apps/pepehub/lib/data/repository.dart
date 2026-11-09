import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/foundation.dart';

import 'database.dart';

const uuid = Uuid();

class LibraryRecord {
  final String id, type;
  final int revision;
  final bool deleted;
  final Map<String, dynamic>? payload;
  // Local insertion order, projected only for file shelves. Updates retain the
  // rowid, so status edits and reconnects do not make old files look new.
  final int? localOrder;
  const LibraryRecord(
    this.id,
    this.type,
    this.revision,
    this.deleted,
    this.payload, {
    this.localOrder,
  });
  factory LibraryRecord.fromRow(QueryRow row) => LibraryRecord(
    row.read<String>('id'),
    row.read<String>('type'),
    row.read<int>('revision'),
    row.read<int>('deleted') == 1,
    jsonDecode(row.read<String>('payload')) as Map<String, dynamic>?,
    localOrder: row.data.containsKey('local_order')
        ? row.read<int>('local_order')
        : null,
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
  static const removedShelfBookPrefix = 'book-shelf-removed:';

  static final _externalChanges = Expando<ValueNotifier<int>>();
  ValueListenable<int> get externalChanges =>
      _externalChanges[db] ??= ValueNotifier(0);
  void notifyExternalChange() {
    final notifier = _externalChanges[db] ??= ValueNotifier(0);
    notifier.value++;
  }

  /// Local shelf removal keeps the identity used by progress and notes.
  Future<void> removeShelfBooks(Iterable<String> ids) async {
    final selected = ids.toSet();
    if (selected.isEmpty) return;
    await db.customStatement(
      "INSERT OR REPLACE INTO metadata(key,value) SELECT ?||value,'1' FROM json_each(?)",
      [removedShelfBookPrefix, jsonEncode(selected.toList())],
    );
    notifyExternalChange();
  }

  /// Only an explicit add can return a removed work to the shelf.
  Future<void> restoreRemovedShelfBook(String id, {required bool audio}) async {
    final marker = '$removedShelfBookPrefix$id';
    if (await meta(marker) == null) return;
    final kind = audio ? 'audio' : 'reading';
    await db.customStatement('DELETE FROM metadata WHERE key IN (?,?,?,?)', [
      marker,
      '$kind-user-hidden:$id',
      '$kind-library-hidden:$id',
      audio ? 'audio-source-missing:$id' : 'reading-deleted:$id',
    ]);
  }

  final AppDatabase db;
  Repository(this.db);
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
                "SELECT * FROM records WHERE type=? AND deleted=0 "
                "${type == 'book' ? r"ORDER BY json_extract(payload,'$.title'), id" : ''}",
                variables: [Variable(type)],
              )
              .get())
          .map(LibraryRecord.fromRow)
          .toList();
  Future<List<LibraryRecord>> shelfBooks({required bool audio}) async =>
      (await db
              .customSelect(
                "SELECT records.*,rowid AS local_order FROM records WHERE type='book' AND deleted=0 AND (IFNULL(json_extract(payload,'\$.format'),'')='audio')=? ORDER BY json_extract(payload,'\$.title'),id",
                variables: [Variable(audio ? 1 : 0)],
              )
              .get())
          .map(LibraryRecord.fromRow)
          .toList();

  Future<List<LibraryRecord>> bookHeaders() async =>
      (await db
              .customSelect(
                "SELECT id,type,revision,deleted,json_object('title',json_extract(payload,'\$.title'),'format',json_extract(payload,'\$.format')) AS payload "
                "FROM records WHERE type='book' AND deleted=0 AND json_valid(payload) ORDER BY json_extract(payload,'\$.title'),id",
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
      final existing = await record(id);
      if (existing?.deleted == true) throw StateError('Книга удалена');
      await _write(
        'records',
        LibraryRecord(id, type, (existing?.revision ?? 0) + 1, false, payload),
      );
    });
  }

  /// Marks a library card or a manual session as deleted.
  Future<void> delete(String type, String id) async {
    if (type != 'book' && type != 'session') {
      throw ArgumentError('Удалить можно книгу или сессию');
    }
    await db.transaction(() async {
      final existing = await record(id);
      if (existing == null || existing.deleted) return;
      if (existing.type != type) throw StateError('Тип записи изменился');
      await _write(
        'records',
        LibraryRecord(id, type, existing.revision + 1, true, null),
      );
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
}
