import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/reader/reading_library.dart';
import 'package:pepehub/sync/peer/app_sync_models.dart';
import 'package:pepehub/sync/peer/app_sync_review_page.dart';
import 'package:pepehub/sync/peer/peer_service.dart';
import 'package:pepehub/sync/peer/peer_models.dart';
import 'package:pepehub/sync/peer/peer_wire.dart';
import 'package:pepehub/vocabulary/vocabulary_repository.dart';

import 'app_sync_test.dart' show AppFixture;
import 'app_sync_service_test.dart' show ServiceFixture;
import 'peer_sync_test.dart' show deviceA, deviceB, MemorySecrets;
import 'video_player_tools_widget_test.dart' show ready;

ReadingNote _note(
  String book,
  String hash, {
  String? id,
  int chapter = -1,
  int end = 0,
  String comment = 'private note text',
}) => ReadingNote(
  id: id ?? uuid.v4(),
  bookId: book,
  hash: hash,
  bookTitle: 'English',
  chapterTitle: 'Unbound note',
  quote: 'private quote',
  comment: comment,
  color: 'yellow',
  updated: DateTime.now().toUtc().toIso8601String(),
  chapter: chapter,
  start: 0,
  end: end,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  tearDownAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = false);

  testWidgets(
    'review shows a preserved local note problem on a narrow phone without showing private note contents',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final a = AppFixture(deviceA);
      late PeerSyncService service;
      late ReadingNote bad;
      await tester.runAsync(() async {
        await a.open();
        final (book, hash) = await a.book();
        bad = _note(book, hash, chapter: -2);
        await ReadingLibrary(a.repo).saveNote(bad);
        service = PeerSyncService(
          a.files.store,
          secrets: MemorySecrets(),
          workDirectory: a.files.replica.work,
          configuredPort: 0,
          observeLifecycle: false,
        );
        await service.initialize();
      });
      addTearDown(
        () => tester.runAsync(() async {
          service.dispose();
          await a.close();
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: AppSyncReviewPage(service: service),
        ),
      );
      await ready(
        tester,
        () => find
            .textContaining('Локальные записи требуют проверки')
            .evaluate()
            .isNotEmpty,
      );
      expect(find.textContaining('chapter'), findsOneWidget);
      expect(find.text('private note text'), findsNothing);
      expect(find.text('Спорных или ожидающих данных нет.'), findsNothing);
      expect(tester.takeException(), isNull);
      expect(
        await tester.runAsync(() => a.repo.meta('reading-note:${bad.id}')),
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  Future<(AppFixture, AppFixture)> fixtures() async {
    final a = AppFixture(deviceA), b = AppFixture(deviceB);
    await a.open();
    await b.open();
    addTearDown(a.close);
    addTearDown(b.close);
    return (a, b);
  }

  test('Obsidian unbound notes retain chapter minus one and optional missing anchor hash across devices', () async {
    final (a, b) = await fixtures();
    final (book, hash) = await a.book();
    final (localBook, _) = await b.book();
    final anchored = _note(book, hash), unbound = _note(book, '');
    await ReadingLibrary(a.repo).saveNote(anchored);
    await ReadingLibrary(a.repo).saveNote(unbound);
    await b.pull(a);
    final notes = await ReadingLibrary(b.repo).notes();
    expect(notes, hasLength(2));
    expect(notes.every((n) => n.bookId == localBook && n.chapter == -1), true);
    expect(notes.singleWhere((n) => n.id == anchored.id).hash, hash);
    expect(notes.singleWhere((n) => n.id == unbound.id).hash, '');
    expect(notes.every((n) => n.comment == 'private note text'), true);
    expect(a.app.validationWarnings, isEmpty);
    expect(b.app.validationWarnings, isEmpty);
  });

  test('one invalid or malformed local note is preserved and cannot stop healthy notes and vocabulary', () async {
    final (a, b) = await fixtures();
    final (book, hash) = await a.book();
    await b.book();
    final bad = _note(book, hash, chapter: -2), good = _note(book, hash);
    final malformed = uuid.v4();
    await ReadingLibrary(a.repo).saveNote(bad);
    await ReadingLibrary(a.repo).saveNote(good);
    await a.repo.setMeta(
      'reading-note:$malformed',
      '{"comment":"private malformed text"',
    );
    final raw = await a.repo.meta('reading-note:${bad.id}');
    await VocabularyRepository(a.repo)
        .save(front: 'healthy', back: 'исправный');
    await b.pull(a);
    expect((await ReadingLibrary(b.repo).notes()).single.id, good.id);
    expect((await VocabularyRepository(b.repo).list()).single.front, 'healthy');
    expect(await a.repo.meta('reading-note:${bad.id}'), raw);
    expect(await b.repo.meta('reading-note:${bad.id}'), isNull);
    expect(
      await a.repo.meta('reading-note:$malformed'),
      contains('private malformed text'),
    );
    expect(a.app.codec.localProblems, hasLength(2));
    final warnings = a.app.validationWarnings.join('\n');
    expect(warnings, contains(bad.id));
    expect(warnings, contains('chapter'));
    expect(warnings, isNot(contains('private note text')));
    expect(warnings, isNot(contains('private malformed text')));
    expect(await a.store.heads('meta:reading-note:${bad.id}'), isEmpty);
  });

  test('invalid local edit is neither published as deletion nor overwritten by a remote edit, and can later be repaired', () async {
    final (a, b) = await fixtures();
    final (book, hash) = await a.book();
    final (otherBook, _) = await b.book();
    final original = _note(book, hash);
    await ReadingLibrary(a.repo).saveNote(original);
    await b.pull(a);
    final bad = _note(book, hash, id: original.id, end: -1);
    await ReadingLibrary(a.repo).saveNote(bad);
    await ReadingLibrary(
      b.repo,
    ).saveNote(_note(otherBook, hash, id: original.id, comment: 'remote edit'));
    await a.pull(b);
    expect(
      (jsonDecode((await a.repo.meta('reading-note:${original.id}'))!)
          as Map)['end'],
      -1,
    );
    expect(
      a.app.codec.localProblems.keys,
      contains('m:reading-note:${original.id}'),
    );
    expect(
      (await a.store.heads('meta:reading-note:${original.id}'))
          .every((v) => !v.deleted),
      true,
    );
    await ReadingLibrary(a.repo)
        .saveNote(_note(book, hash, id: original.id, comment: 'local repair'));
    await a.app.refresh();
    await a.app.applyPending();
    expect(a.app.codec.localProblems, isEmpty);
    final issue = (await a.app.issues()).singleWhere(
      (i) => i.key == 'meta:reading-note:${original.id}',
    );
    expect(issue.versions, hasLength(2));
    expect(issue.protected, false);
    expect(
      (await ReadingLibrary(a.repo).notes()).single.comment,
      'local repair',
    );
  });

  test('missing hash is allowed only for unbound notes and genuinely invalid anchors remain rejected', () async {
    final (a, b) = await fixtures();
    final (book, hash) = await a.book();
    await a.app.refresh();
    final common = a.media.outgoing[book]!;
    for (final note in [
      _note(common, '', chapter: 0),
      _note(common, hash, chapter: -2),
      _note(common, hash, end: -1),
    ]) {
      final version = AppSyncVersion(
        'meta:reading-note:${note.id}',
        note.toJson(),
        {deviceA: 1},
      );
      await expectLater(
        b.app.receive(
          version.header,
          (offset, count) async => version.bytes.sublist(
            offset,
            (offset + count).clamp(0, version.bytes.length),
          ),
        ),
        throwsA(isA<AppSyncRejectedRecord>()),
      );
      expect(await b.store.version(version.id), isNull);
    }
  });

  test('real peer exchange reports the phone note ID while transferring other profile data without logging note content', () async {
    final a = ServiceFixture(), b = ServiceFixture();
    await a.open(library: true);
    await b.open(library: true);
    addTearDown(a.close);
    addTearDown(b.close);
    await a.service.setEnabled(true);
    await b.service.pair(a.service.invitation('127.0.0.1'));
    await File(p.join(a.shared.path, 'book.txt'))
        .writeAsString('English lesson');
    await a.service.addFolder(
      a.shared.path,
      'Books',
      sharedWith: {b.service.deviceId},
      library: 'books',
    );
    await b.service.addFolder(
      b.shared.path,
      'Books',
      id: a.service.folders.single.id,
      sharedWith: {a.service.deviceId},
      library: 'books',
    );
    await b.service.syncDevice(b.service.devices.single);
    final book = (await b.repo.records('book')).single;
    final hash = (await b.service.assets!.list()).single.hash;
    final bad = _note(book.id, hash, chapter: -2), good = _note(book.id, hash);
    await ReadingLibrary(b.repo).saveNote(bad);
    await ReadingLibrary(b.repo).saveNote(good);
    await VocabularyRepository(b.repo)
        .save(front: 'word from phone', back: 'слово с телефона');
    await a.service.shareApplication(a.service.devices.single, true);
    await b.service.shareApplication(b.service.devices.single, true);
    await a.service.syncDevice(a.service.devices.single);
    expect(a.service.error, isNull, reason: a.service.journal.export());
    expect((await ReadingLibrary(a.repo).notes()).single.id, good.id);
    expect(
      (await VocabularyRepository(a.repo).list()).single.front,
      'word from phone',
    );
    expect(await b.repo.meta('reading-note:${bad.id}'), isNotNull);
    final journal = a.service.journal.export();
    expect(journal, contains(bad.id));
    expect(journal, contains('На втором устройстве: Запись'));
    expect(journal, isNot(contains('private quote')));
    expect(journal, isNot(contains('private note text')));
  });

  test('one rejected verified legacy payload cannot stop a valid subsequent record in the same manifest', () async {
    final a = ServiceFixture(), b = ServiceFixture();
    await a.open();
    await b.open();
    addTearDown(a.close);
    addTearDown(b.close);
    await a.service.setEnabled(true);
    await b.service.pair(a.service.invitation('127.0.0.1'));
    await b.service.shareApplication(b.service.devices.single, true);
    final port = a.service.port,
        key = (await b.service.secrets.read(b.service.devices.single.channel))!;
    await a.service.setEnabled(false);
    final badNote = _note(uuid.v4(), peerDigest([1]), chapter: -2);
    final bad = AppSyncVersion(
      'meta:reading-note:${badNote.id}',
      badNote.toJson(),
      {a.service.deviceId: 1},
    );
    final good = AppSyncVersion(
      'meta:reading-daily-goal',
      {'setting': 45},
      {a.service.deviceId: 2},
    );
    final versions = [bad, good]..sort((a, b) => a.id.compareTo(b.id));
    final remote = PeerWireServer(
      keyFor: (_) async => key,
      handle: (_, request, _) async {
        switch (request['op']) {
          case 'folders':
            return {'applicationData': true, 'folders': []};
          case 'app_manifest':
            return {'versions': versions.map((v) => v.header).toList()};
          case 'app_read':
            final version = versions.singleWhere((v) => v.id == request['id']),
                offset = request['offset'] as int,
                count = request['count'] as int;
            return {
              'bytes': base64Encode(
                version.bytes.sublist(
                  offset,
                  (offset + count).clamp(0, version.bytes.length),
                ),
              ),
            };
          case 'app_pull':
            return {'job': 'test'};
          case 'status':
            return {
              'job': {'state': 'done', 'warnings': <String>[]},
            };
          default:
            throw StateError('Unexpected test operation');
        }
      },
    );
    await remote.start(address: InternetAddress.loopbackIPv4, port: port);
    addTearDown(remote.close);
    await b.service.syncDevice(b.service.devices.single);
    expect(b.service.error, isNull, reason: b.service.journal.export());
    expect(await b.repo.meta('reading-daily-goal'), '45');
    expect(await b.repo.meta('reading-note:${badNote.id}'), isNull);
    expect(b.service.journal.export(), contains('не принята'));
    expect(b.service.journal.export(), isNot(contains('private note text')));
  });
}
