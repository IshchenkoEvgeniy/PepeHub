import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/sync/sync_client.dart';

void main() {
  test(
    'two real Dart clients synchronize through Worker HTTP and SQLite',
    () async {
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      final server = await Process.start('node', [
        '--disable-warning=ExperimentalWarning',
        'scripts/e2e-server.ts',
      ], workingDirectory: '../..');
      final errors = <String>[];
      final stderr = server.stderr.transform(utf8.decoder).listen(errors.add);
      final a = AppDatabase(NativeDatabase.memory()),
          b = AppDatabase(NativeDatabase.memory());
      final ra = Repository(a), rb = Repository(b);
      await ra.setCloudTracking(true);
      await rb.setCloudTracking(true);
      final ca = http.Client(), cb = http.Client();
      try {
        final ready = await server.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .firstWhere((line) => line.startsWith('READY:'))
            .timeout(const Duration(seconds: 15));
        final endpoint = 'http://127.0.0.1:${ready.substring(6)}';
        final configA = SyncConfig(
          endpoint,
          '11111111-1111-4111-8111-111111111111',
          'a' * 64,
        );
        final configB = SyncConfig(
          endpoint,
          '22222222-2222-4222-8222-222222222222',
          'b' * 64,
        );
        final sa = SyncClient(ra, ca), sb = SyncClient(rb, cb);
        await ra.addBook('Русская книга', 'Автор', 'fb2');
        final book = (await ra.records('book')).single;
        await ra.addSession(book, 20);
        await sa.run(configA);
        await sb.run(configB);
        expect((await rb.records('book')).single.title, 'Русская книга');
        expect((await rb.records('book')).single.payload!['format'], 'fb2');
        expect(
          (await rb.records('session')).single.payload!['activeSeconds'],
          1200,
        );
        await ra.put('book', book.id, {...book.payload!, 'title': 'Правка A'});
        final bookB = (await rb.records('book')).single;
        await rb.put('book', bookB.id, {
          ...bookB.payload!,
          'title': 'Правка B',
        });
        await sa.run(configA);
        await sb.run(configB);
        expect((await rb.records('book')).single.title, 'Правка B');
        final conflict = (await rb.conflicts()).single;
        await rb.useServerVersion(conflict.read<String>('operation_id'));
        expect((await rb.records('book')).single.title, 'Правка A');
        expect(await rb.pendingCount(), 0);
        final listeningId = uuid.v4();
        await ra.put('session', listeningId, {
          'bookId': book.id,
          'kind': 'listening',
          'startedAt': '2026-10-13T10:00:00.000Z',
          'endedAt': '2026-10-13T10:01:00.000Z',
          'activeSeconds': 60,
          'timezone': 'UTC',
          'offsetMinutes': 180,
          'source': 'player',
        });
        await sa.run(configA);
        await sb.run(configB);
        expect((await rb.record(listeningId))!.payload!['offsetMinutes'], 180);
        expect(await ra.pendingCount(), 0);
        expect(errors, isEmpty);
      } finally {
        ca.close();
        cb.close();
        await a.close();
        await b.close();
        server.kill();
        await server.exitCode;
        await stderr.cancel();
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
