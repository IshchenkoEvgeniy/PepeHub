import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions, Variable;
import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/audio/audio_link.dart';
import 'package:pepehub/audio/audio_library_repository.dart';
import 'package:pepehub/audio/audio_journal.dart';
import 'package:pepehub/audio/models.dart';
import 'package:pepehub/recommendations/recommendation_store.dart';
import 'package:pepehub/library/activity_store.dart';
import 'package:pepehub/library/models.dart';
import 'package:pepehub/sync/peer/app_sync_engine.dart';
import 'package:pepehub/sync/peer/app_sync_media.dart';
import 'package:pepehub/sync/peer/app_sync_models.dart';
import 'package:pepehub/sync/peer/app_sync_store.dart';
import 'package:pepehub/sync/peer/app_sync_usage.dart';
import 'package:pepehub/sync/peer/peer_models.dart';
import 'package:pepehub/video/models.dart';
import 'package:pepehub/video/video_repository.dart';
import 'package:pepehub/music/music_metadata.dart';
import 'package:pepehub/vocabulary/vocabulary_repository.dart';

import 'peer_sync_test.dart' show ReplicaFixture, deviceA, deviceB;

class AppFixture {
  final ReplicaFixture files;
  late final store = AppSyncStore(files.store);
  late final media = AppSyncMedia(store, () => [files.replica.folder]);
  late final app = AppSyncEngine(files.store, files.id, media);
  late final videos = VideoRepository(files.store.repository);
  AppFixture(String id) : files = ReplicaFixture(id);
  Repository get repo => files.store.repository;
  Future<void> open() async {
    await files.open();
    await app.initialize();
  }

  Future<VideoLesson> course() async {
    await files.write('English/1.mp4', [1, 2, 3]);
    await files.replica.scan();
    final item = await videos.addSources(
      title: 'English',
      root: p.join(files.root.path, 'English'),
      sources: [
        VideoSourceDraft(
          p.join(files.root.path, 'English/1.mp4'),
          'Lesson 1',
          relativeName: '1.mp4',
        ),
      ],
    );
    return (await videos.lessons(itemId: item.id)).single;
  }

  Future<void> position(VideoLesson lesson, int position) => videos.checkpoint(
    lesson: lesson,
    progress: VideoProgress(
      lessonId: lesson.id,
      mediaVersion: lesson.mediaVersion,
      positionMs: position,
      speed: 1.25,
      updatedAt: DateTime.now(),
    ),
    intervals: [],
  );
  Future<void> pull(AppFixture other) async {
    await app.refresh();
    await other.app.refresh();
    for (final version in await other.store.heads()) {
      await app.receive(
        version.header,
        (offset, count) => other.app.read(version.id, offset, count),
      );
    }
    await app.applyPending();
  }

  Future<void> close() => files.close();
  Future<(String, String)> book() async {
    await files.write('book.txt', utf8.encode('English lesson'));
    await files.replica.scan();
    final hash = peerDigest(utf8.encode('English lesson')), id = uuid.v4();
    await repo.put('book', id, {
      'title': 'English',
      'authors': [],
      'format': 'txt',
      'status': 'planned',
    });
    await files.db.customStatement(
      'INSERT INTO local_assets VALUES(?,?,?,?,?,?)',
      [
        uuid.v4(),
        id,
        'book.txt',
        p.join(files.root.path, 'book.txt'),
        hash,
        14,
      ],
    );
    return (id, hash);
  }

  Future<(String, String)> audioBook() async {
    await files.write('audio/1.mp3', [1, 2, 3, 4]);
    await files.replica.scan();
    final path = p.join(files.root.path, 'audio', '1.mp3');
    final book = await AudioLinkService(repo)
        .connect([XFile(path)], root: p.dirname(path), title: 'Audio course');
    final track = await files.db
        .customSelect(
          'SELECT t.id FROM audio_tracks t JOIN audio_editions e ON e.id=t.edition_id WHERE e.book_id=?',
          variables: [Variable(book)],
        )
        .getSingle();
    return (book, track.read<String>('id'));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  tearDownAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = false);
  late AppFixture a, b;
  setUp(() async {
    a = AppFixture(deviceA);
    b = AppFixture(deviceB);
    await a.open();
    await b.open();
  });
  tearDown(() async {
    await a.close();
    await b.close();
  });

  test('music sync preserves tags and interval type but never exports a local cover path', () async {
    await a.files.write('song.mp3', [1, 2, 3, 4]);
    await a.files.replica.scan();
    final item = await a.videos.addSources(
      title: 'Music',
      sources: [
        VideoSourceDraft(p.join(a.files.root.path, 'song.mp3'), 'Song'),
      ],
    );
    final song = (await a.videos.lessons(itemId: item.id)).single;
    final tagged = await a.videos.saveMusicDetails(
      song,
      'Tagged song',
      const MusicMetadata(
        artist: 'Artist',
        album: 'Album',
        trackNumber: 3,
        coverPath: 'C:/private-local-cover.png',
      ),
    );
    await a.videos.checkpoint(
      lesson: tagged,
      progress: VideoProgress(
        lessonId: tagged.id,
        mediaVersion: tagged.mediaVersion,
        positionMs: 1000,
        speed: 1,
        updatedAt: DateTime.now(),
      ),
      intervals: [
        VideoInterval(
          id: uuid.v4(),
          sessionId: uuid.v4(),
          lessonId: tagged.id,
          mediaVersion: tagged.mediaVersion,
          mode: VideoActivityMode.audio,
          startedAt: DateTime.now().toUtc(),
          offsetMinutes: 0,
          startMs: 0,
          endMs: 1000,
          wallMs: 1000,
          speed: 1,
        ),
      ],
    );
    await a.app.refresh();
    final versions = await a.store.heads();
    expect(
      jsonEncode(versions.map((version) => version.toJson()).toList()),
      isNot(contains('private-local-cover')),
    );
    await b.files.receive(a.files);
    await b.pull(a);
    final received = (await b.videos.lessons()).single;
    expect(received.isAudio, isTrue);
    expect(received.music!.artist, 'Artist');
    expect(received.music!.album, 'Album');
    expect(received.music!.trackNumber, 3);
    expect(received.music!.coverPath, isNull);
    expect((await b.videos.intervals(music: true)).single.mediaKind, 'music');
    expect(await b.videos.intervals(music: false), isEmpty);
  });
  test('direct sessions and their Obsidian mirrors deduplicate, including after deletion', () async {
    final first = await a.book(), second = await b.book();
    final session = uuid.v4(), item = uuid.v4();
    await a.repo.setMeta(
      'reading-session:$session',
      jsonEncode({
        'id': session,
        'bookId': first.$1,
        'hash': first.$2,
        'startedAt': '2026-10-15T10:00:00Z',
        'endedAt': '2026-10-15T10:01:00Z',
        'position': 50,
        'length': 1000,
        'spans': [],
        'events': [],
      }),
    );
    await b.repo.setMeta('obsidian-active-namespace', 'test');
    final entry = LibraryEntry(
      ObsidianLibraryItem(
        id: item,
        path: 'Book.md',
        collectionId: 'books',
        mediaType: 'book',
        values: {},
        fields: [],
      ),
      sourceBookId: second.$1,
    );
    await b.repo.setMeta(
      'obsidian-library:test',
      jsonEncode({item: entry.toJson()}),
    );
    await b.repo.setMeta(
      'obsidian-activity:test',
      jsonEncode({
        'version': 1,
        'cursor': 0,
        'slots': {
          'mirror': {
            'value': {
              'id': uuid.v4(),
              'itemId': item,
              'mediaType': 'book',
              'deleted': false,
              'day': '2026-10-15',
            },
            'source': {'kind': 'reader', 'id': session, 'bookId': first.$1},
          },
        },
      }),
    );
    expect(await ActivityStore.foreign(b.repo, 'book'), hasLength(1));
    await b.pull(a);
    expect(await ActivityStore.foreign(b.repo, 'book'), isEmpty);
    await a.files.db.customStatement('DELETE FROM metadata WHERE key=?', [
      'reading-session:$session',
    ]);
    await b.pull(a);
    expect(await ActivityStore.foreign(b.repo, 'book'), isEmpty);
  });
  test('same course at different paths retains local IDs and receives the correct content-version position', () async {
    final first = await a.course(), second = await b.course();
    expect(first.id, isNot(second.id));
    expect(first.mediaVersion, isNot(second.mediaVersion));
    await a.position(first, 42000);
    await b.pull(a);
    final lessons = await b.videos.lessons();
    expect(lessons.single.id, second.id);
    expect(p.normalize(lessons.single.source), p.normalize(second.source));
    expect(lessons.single.mediaVersion, second.mediaVersion);
    expect((await b.videos.progress(lessons.single))!.positionMs, 42000);
    final keys = (await b.store.heads()).map((v) => v.id).toSet();
    await b.pull(a);
    expect((await b.store.heads()).map((v) => v.id).toSet(), keys);
  });
  test('received shared files create a local course with a local source, not the sender path', () async {
    final lesson = await a.course();
    await a.position(lesson, 12000);
    await b.files.receive(a.files);
    await b.pull(a);
    final local = (await b.videos.lessons()).single;
    expect(
      p.normalize(local.source),
      p.normalize(p.join(b.files.root.path, 'English/1.mp4')),
    );
    expect((await b.videos.progress(local))!.positionMs, 12000);
  });
  test('concurrent positions remain available for explicit selection and then converge', () async {
    final first = await a.course(), second = await b.course();
    await a.position(first, 42000);
    await b.position(second, 9000);
    await b.pull(a);
    await a.pull(b);
    expect((await b.videos.progress(second))!.positionMs, 9000);
    final issue = (await b.app.issues()).singleWhere(
      (i) => i.key.startsWith('position:video:'),
    );
    expect(issue.versions, hasLength(2));
    final selected = issue.versions.singleWhere(
      (v) => v.value!['positionMs'] == 42000,
    );
    await b.app.resolve(
      issue.key,
      selected.id,
      issue.versions.map((v) => v.id).toSet(),
    );
    await a.pull(b);
    expect((await a.videos.progress(first))!.positionMs, 42000);
    expect((await b.videos.progress(second))!.positionMs, 42000);
  });
  test('active player defers a remote checkpoint and preserves a local edit made during that deferral', () async {
    final first = await a.course(), second = await b.course();
    final release = AppSyncUsage.hold(b.files.db, 'p:video:${second.id}');
    await a.position(first, 42000);
    await b.pull(a);
    expect(await b.videos.progress(second), isNull);
    expect((await b.app.issues()).any((i) => i.protected), true);
    await b.position(second, 8000);
    release();
    await b.app.applyPending();
    final issue = (await b.app.issues()).singleWhere(
      (i) => i.key.startsWith('position:video:'),
    );
    expect(issue.versions.map((v) => v.value!['positionMs']).toSet(), {
      42000,
      8000,
    });
  });
  test('Anki inserts and updates are idempotent, tombstones cannot resurrect on a stale device', () async {
    final vocabulary = VocabularyRepository(a.repo);
    final card = await vocabulary.save(front: 'already', back: 'уже');
    await b.pull(a);
    await b.pull(a);
    expect((await VocabularyRepository(b.repo).list()).single.id, card.id);
    final changed = await vocabulary.save(
      existing: card,
      front: 'already',
      back: 'уже; ранее',
    );
    await b.pull(a);
    expect(
      (await VocabularyRepository(b.repo).list()).single.back,
      changed.back,
    );
    await vocabulary.delete(changed);
    await b.pull(a);
    await a.pull(b);
    expect(await VocabularyRepository(b.repo).list(), isEmpty);
    expect(await vocabulary.list(), isEmpty);
  });
  test('metadata deletions propagate and private application settings never enter the exchange', () async {
    const hash =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    await a.repo.setMeta(
      'reader:$hash',
      jsonEncode({'chapter': 2, 'textOffset': 37, 'updatedAt': '2026-10-15'}),
    );
    await a.repo.setMeta('obsidian-token', 'private');
    await a.repo.setMeta('peer-sync-enabled', '1');
    await a.repo.setMeta(
      'reading-collection:collection',
      jsonEncode({'name': 'English'}),
    );
    await b.pull(a);
    expect(jsonDecode((await b.repo.meta('reader:$hash'))!)['textOffset'], 37);
    expect(await b.repo.meta('obsidian-token'), isNull);
    await a.files.db.customStatement('DELETE FROM metadata WHERE key=?', [
      'reading-collection:collection',
    ]);
    await b.pull(a);
    expect(await b.repo.meta('reading-collection:collection'), isNull);
  });
  test(
    'hash mismatch and unsupported metadata cannot change existing local data',
    () async {
      final version = AppSyncVersion(
        'meta:obsidian-token',
        {'setting': 'injected'},
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
        throwsFormatException,
      );
      expect(await b.repo.meta('obsidian-token'), isNull);
      final source = AppSyncVersion(
        'media:item:${uuid.v4()}',
        {
          'kind': 'course',
          'title': 'Injected',
          'favorite': false,
          'root': 'C:/private',
        },
        {deviceA: 1},
      );
      await expectLater(
        b.app.receive(
          source.header,
          (offset, count) async => source.bytes.sublist(
            offset,
            (offset + count).clamp(0, source.bytes.length),
          ),
        ),
        throwsFormatException,
      );
      expect(await b.videos.items(), isEmpty);
      final valid = AppSyncVersion(
        'meta:reading-daily-goal',
        {'setting': 30},
        {deviceA: 1},
      );
      await expectLater(
        b.app.receive(
          valid.header,
          (offset, count) async => List.filled(count, 0),
        ),
        throwsStateError,
      );
      expect(await b.repo.meta('reading-daily-goal'), isNull);
    },
  );
  test('text and PDF positions use the content hash and preserve an independently imported book ID', () async {
    final first = await a.book(), second = await b.book();
    expect(first.$1, isNot(second.$1));
    expect(first.$2, second.$2);
    await a.repo.setMeta(
      'reader:${first.$2}',
      jsonEncode({'chapter': 3, 'textOffset': 52, 'pdfFinished': true}),
    );
    await b.pull(a);
    expect((await b.repo.records('book')).single.id, second.$1);
    final position =
        jsonDecode((await b.repo.meta('reader:${second.$2}'))!) as Map;
    expect(position['chapter'], 3);
    expect(position['textOffset'], 52);
    expect(position['pdfFinished'], true);
    expect(await b.repo.meta('pdf:${second.$2}'), '4');
  });
  test('linked audio with opaque local resource IDs resumes the matching local edition and track', () async {
    final first = await a.audioBook(), second = await b.audioBook();
    final libraryA = AudioLibraryRepository(a.files.db),
        libraryB = AudioLibraryRepository(b.files.db);
    final progress = await libraryA.progressForTrack(first.$2);
    await libraryA.saveProgress(
      AudioProgress(
        AudioLocator(
          bookId: first.$1,
          editionId: progress.locator.editionId,
          trackId: first.$2,
          positionMs: 31000,
          manifestRevision: progress.locator.manifestRevision,
        ),
        1.5,
      ),
    );
    await b.pull(a);
    final received = await libraryB.progressForTrack(second.$2);
    expect(received.locator.bookId, second.$1);
    expect(received.locator.trackId, second.$2);
    expect(received.locator.positionMs, 31000);
    expect(received.speed, 1.5);
    expect((await b.repo.records('book')).single.id, second.$1);
  });
  test('reading sessions deduplicate by ID and coverage converges as a union', () async {
    final first = await a.book();
    await b.book();
    final session = uuid.v4();
    final data = {
      'id': session,
      'bookId': first.$1,
      'hash': first.$2,
      'startedAt': '2026-10-15T10:00:00Z',
      'endedAt': '2026-10-15T10:01:00Z',
      'position': 50,
      'length': 1000,
      'newChars': 50,
      'repeatChars': 0,
      'spans': <Object>[],
      'events': <Object>[],
    };
    await a.repo.setMeta('reading-session:$session', jsonEncode(data));
    await a.repo.setMeta(
      'reading-coverage:${first.$2}',
      jsonEncode({
        'ranges': [
          [0, 150],
        ],
      }),
    );
    await b.repo.setMeta(
      'reading-coverage:${first.$2}',
      jsonEncode({
        'ranges': [
          [100, 200],
        ],
      }),
    );
    await b.pull(a);
    await a.pull(b);
    await b.pull(a);
    expect(
      (await b.files.db
              .customSelect(
                "SELECT value FROM metadata WHERE key LIKE 'reading-session:%'",
              )
              .get())
          .length,
      1,
    );
    expect(
      jsonDecode(
        (await a.repo.meta('reading-coverage:${first.$2}'))!,
      )['ranges'],
      [
        [0, 200],
      ],
    );
    expect(
      jsonDecode(
        (await b.repo.meta('reading-coverage:${first.$2}'))!,
      )['ranges'],
      [
        [0, 200],
      ],
    );
  });
  test('audio and video listening intervals are updated in place rather than counted twice', () async {
    final first = await a.audioBook();
    await b.audioBook();
    await AudioJournal(a.repo).appendListening(
      ListeningSegment(
        first.$1,
        first.$2,
        0,
        1000,
        1000,
        1,
        DateTime.utc(2026, 10, 15),
      ),
    );
    await b.pull(a);
    await b.pull(a);
    expect(await b.repo.records('audio_event'), hasLength(1));
    final lessonA = await a.course();
    await b.course();
    final interval = VideoInterval(
      id: uuid.v4(),
      sessionId: uuid.v4(),
      lessonId: lessonA.id,
      mediaVersion: lessonA.mediaVersion,
      mode: VideoActivityMode.visual,
      startedAt: DateTime.utc(2026, 10, 15),
      offsetMinutes: 180,
      startMs: 0,
      endMs: 2000,
      wallMs: 1000,
      speed: 2,
    );
    await a.videos.checkpoint(
      lesson: lessonA,
      progress: VideoProgress(
        lessonId: lessonA.id,
        mediaVersion: lessonA.mediaVersion,
        positionMs: 2000,
        speed: 2,
        updatedAt: DateTime.now(),
      ),
      intervals: [interval],
    );
    await b.pull(a);
    await a.pull(b);
    await b.pull(a);
    expect(await b.repo.records('video_interval'), hasLength(1));
    expect(
      (await b.repo.records('video_interval')).single.payload!['wallMs'],
      1000,
    );
  });
  test('default recommendation categories match across devices and category membership uses local IDs', () async {
    final shelfA = RecommendationStore(a.repo),
        shelfB = RecommendationStore(b.repo);
    final initialA = await shelfA.load(), initialB = await shelfB.load();
    await shelfA.saveBook(
      RecommendedBook(
        id: uuid.v4(),
        catalog: const CatalogBook(
          source: 'manual',
          sourceId: '',
          sourceUrl: '',
          data: {'title': 'English grammar'},
        ),
        notes: 'Study',
        categories: {initialA.categories.first.id: 1},
        createdAt: '2026-10-15T12:00:00Z',
      ),
    );
    expect(initialA.categories.first.id, isNot(initialB.categories.first.id));
    await b.pull(a);
    await a.pull(b);
    expect((await shelfB.load()).categories, hasLength(3));
    expect((await shelfB.load()).books.single.categories.keys.toSet(), {
      initialB.categories.first.id,
    });
    expect(
      (await shelfB.load()).categories.first.id,
      initialB.categories.first.id,
    );
  });
  test('a source changed behind an existing lesson cannot receive the old version position', () async {
    final first = await a.course(), second = await b.course();
    await b.pull(a);
    await a.position(first, 42000);
    await b.files.write('English/1.mp4', [9, 9, 9]);
    await b.files.replica.scan();
    await b.pull(a);
    expect(await b.videos.progress(second), isNull);
    expect(
      (await b.app.issues()).any((i) => i.key.startsWith('position:video:')),
      true,
    );
  });
}
