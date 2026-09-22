import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/audio/audio_library_repository.dart';
import 'package:pepehub/audio/models.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/media/listening_clock.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  late AppDatabase db;
  late Repository repository;
  late Directory root;
  late AssetStore assets;
  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    root = await Directory.systemTemp.createTemp('pepehub-audio-test-');
    db = AppDatabase(NativeDatabase.memory());
    repository = Repository(db);
    assets = AssetStore(repository, Directory('${root.path}/managed'));
  });
  tearDown(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  test('import copies a selected audio file, deduplicates by content, preserves original and local position', () async {
    final original = File('${root.path}/My book.mp3');
    // Header fixture exercises import, not native decoding.
    final bytes = [
      73,
      68,
      51,
      4,
      0,
      0,
      0,
      0,
      0,
      0,
      ...List<int>.filled(1000, 0),
    ];
    await original.writeAsBytes(bytes);
    final first = await assets.importAudio(XFile(original.path));
    final second = await assets.importAudio(XFile(original.path));
    expect(second.id, first.id);
    expect(await original.readAsBytes(), bytes);
    expect(await File(first.path).readAsBytes(), bytes);
    expect((await repository.records('book')).length, 1);
    expect(await repository.pendingCount(), 1);
    final library = AudioLibraryRepository(db);
    final initial = (await library.progressForTrack(first.id)).locator;
    await library.saveProgress(
      AudioProgress(
        AudioLocator(
          bookId: initial.bookId,
          editionId: initial.editionId,
          trackId: first.id,
          positionMs: 42123,
          manifestRevision: 1,
        ),
        1.5,
      ),
    );
    final saved = await library.progressForTrack(first.id);
    expect(saved.locator.positionMs, 42123);
    expect(saved.speed, 1.5);
    final queued = (await repository.pending()).single.read<String>(
      'operation',
    );
    expect(queued.contains(root.path), false);
    expect(
      (await assets.directory.list().toList()).where(
        (f) => f.path.endsWith('.part'),
      ),
      isEmpty,
    );
  });
  test(
    'wrong content and size limit never create cards or leave temporary files',
    () async {
      final selected = File('${root.path}/invalid.mp3');
      await selected.writeAsBytes(List.filled(100, 0));
      await expectLater(
        assets.importAudio(XFile(selected.path)),
        throwsArgumentError,
      );
      await expectLater(
        assets.importAudio(XFile(selected.path), maxBytes: 50),
        throwsArgumentError,
      );
      expect(await repository.records('book'), isEmpty);
      expect(await repository.pendingCount(), 0);
      expect(await assets.directory.list().toList(), isEmpty);
    },
  );
  test('audio time uses wall time and excludes pause, buffering and seek', () {
    var now = 0;
    final clock = ListeningClock(() => now);
    clock.setAudible(true);
    now = 10000;
    clock.setAudible(false);
    now = 40000;
    expect(clock.milliseconds, 10000);
    // Resume at 2x: twenty seconds of content still correspond to ten real seconds.
    clock.setAudible(true);
    now = 50000;
    clock.setAudible(false);
    expect(clock.milliseconds, 20000);
    now = 1000000;
    expect(clock.milliseconds, 20000);
  });
  test('v1 database migrates without losing a card or changing an old pending payload', () async {
    final file = File('${root.path}/legacy.sqlite');
    final raw = sqlite.sqlite3.open(file.path);
    final bookId = uuid.v4(), operationId = uuid.v4();
    final payload = jsonEncode({
      'title': 'Старая библиотека',
      'authors': <String>[],
      'format': 'epub',
      'status': 'planned',
    });
    final operation = jsonEncode({
      'schemaVersion': 1,
      'operationId': operationId,
      'deviceId': uuid.v4(),
      'entityType': 'book',
      'entityId': bookId,
      'baseRevision': 0,
      'action': 'put',
      'payload': jsonDecode(payload),
    });
    raw.execute(
      'CREATE TABLE records(id TEXT PRIMARY KEY,type TEXT,revision INTEGER,deleted INTEGER,payload TEXT)',
    );
    raw.execute(
      'CREATE TABLE remote_records(id TEXT PRIMARY KEY,type TEXT,revision INTEGER,deleted INTEGER,payload TEXT)',
    );
    raw.execute(
      "CREATE TABLE outbox(sequence INTEGER PRIMARY KEY AUTOINCREMENT,operation_id TEXT UNIQUE,entity_id TEXT,operation TEXT,state TEXT DEFAULT 'pending',receipt TEXT)",
    );
    raw.execute('CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT)');
    raw.execute('INSERT INTO records VALUES(?,?,?,?,?)', [
      bookId,
      'book',
      1,
      0,
      payload,
    ]);
    raw.execute(
      'INSERT INTO outbox(operation_id,entity_id,operation) VALUES(?,?,?)',
      [operationId, bookId, operation],
    );
    raw.execute('PRAGMA user_version=1');
    raw.close();
    final upgraded = AppDatabase(NativeDatabase(file));
    try {
      final legacy = Repository(upgraded);
      expect((await legacy.records('book')).single.title, 'Старая библиотека');
      final pending = (await legacy.pending()).single;
      expect(pending.read<String>('operation'), operation);
      expect(pending.read<int>('attempted'), 1);
      expect(await AssetStore(legacy, assets.directory).list(), isEmpty);
    } finally {
      await upgraded.close();
    }
  });
  test('checkpoints coalesce until first network attempt and never alter a retry payload', () async {
    await repository.addBook('Audio', '', 'audio');
    final book = (await repository.records('book')).single;
    final session = uuid.v4();
    Map<String, dynamic> data(int seconds) => {
      'bookId': book.id,
      'kind': 'listening',
      'startedAt': '2026-09-12T10:00:00.000Z',
      'endedAt': '2026-09-12T11:00:00.000Z',
      'activeSeconds': seconds,
      'timezone': 'UTC',
      'source': 'player',
    };
    await repository.put('session', session, data(10), coalesce: true);
    await repository.put('session', session, data(20), coalesce: true);
    expect(await repository.pendingCount(), 2); // book + one session
    final pending = (await repository.pending()).last;
    final frozen = await repository.freezeOperation(
      pending.read<String>('operation_id'),
    );
    await repository.put('session', session, data(30), coalesce: true);
    expect(await repository.pendingCount(), 3);
    final unchanged = (await repository.pending())[1].read<String>('operation');
    expect(jsonDecode(unchanged), frozen);
    expect((await repository.record(session))!.payload!['activeSeconds'], 30);
  });
}
