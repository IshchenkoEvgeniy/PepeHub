import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/audio/audio_daily_totals.dart';
import 'package:pepehub/audio/audio_journal.dart';
import 'package:pepehub/audio/listening_analytics.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/music/music_metadata.dart';
import 'package:pepehub/reader/reading_library.dart';
import 'package:pepehub/sync/peer/app_sync_models.dart';
import 'package:pepehub/sync/peer/app_sync_presentation.dart';
import 'package:pepehub/sync/peer/peer_folder_setup_page.dart';
import 'package:pepehub/sync/peer/peer_qr.dart';
import 'package:pepehub/video/models.dart';
import 'package:pepehub/video/video_controller.dart';
import 'package:pepehub/video/video_repository.dart';

import 'support/video_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late Repository repository;
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repository = Repository(db);
  });
  tearDown(() => db.close());

  test(
    'metadata prefixes load the requested flags and preserve unrelated values',
    () async {
      for (var i = 0; i < 100; i++) {
        await repository.setMeta(
          'audio-library-hidden:$i',
          i.isEven ? '1' : '0',
        );
        await repository.setMeta('audio-status-override:$i', 'paused');
      }
      await repository.setMeta('private-token', 'unrelated');
      final flags = await repository.metadataPrefixes([
        'audio-library-hidden:',
        'audio-status-override:',
      ]);
      expect(flags.length, 200);
      expect(flags['audio-library-hidden:42'], '1');
      expect(flags, isNot(contains('private-token')));
      expect(await repository.metadataPrefixes([]), isEmpty);
    },
  );

  test('indexed notes select only the requested book even with unrelated damaged JSON', () async {
    final library = ReadingLibrary(repository);
    for (var i = 0; i < 200; i++) {
      await library.saveNote(
        ReadingNote(
          id: 'n$i',
          bookId: 'book$i',
          hash: 'hash$i',
          bookTitle: 'Book $i',
          chapterTitle: 'Chapter',
          quote: 'Quote',
          comment: '',
          color: 'yellow',
          updated: '2026-10-23',
          chapter: 0,
          start: 0,
          end: 5,
        ),
      );
    }
    await repository.setMeta('reading-note:damaged', '{broken');
    expect((await library.notes(hash: 'hash42')).single.bookId, 'book42');
    expect((await library.notes(bookIds: {'book2', 'book3'})).length, 2);
    expect(await library.notes(hash: 'hash2', bookIds: {'book3'}), isEmpty);
    expect(await library.notes(bookIds: {}), isEmpty);
    expect(await repository.meta('reading-note:damaged'), '{broken');
  });

  Map<String, dynamic> listen(
    String book, {
    int wall = 1000,
    String day = '2026-10-23',
    String? at,
  }) => {
    'kind': 'listen',
    'bookId': book,
    'trackId': 'track',
    'wallMs': wall,
    'positionMs': 0,
    'endMs': wall,
    'speed': 1.0,
    'localDay': day,
    'at': at ?? '${day}T12:00:00Z',
    'offsetMinutes': 0,
  };

  test('daily read model backfills once and tracks checkpoints, raw sync edits, tombstones and restores', () async {
    final journal = AudioJournal(repository);
    await journal.put('audio_event', 'event', listen('book'));
    final store = AudioDailyStore(repository);
    expect((await store.lifetime()).days, {'2026-10-23': 1000});
    await journal.put('audio_event', 'event', listen('book', wall: 2500));
    expect((await store.lifetime()).books, {'book': 2500});
    await repository.db.customStatement(
      'UPDATE records SET payload=? WHERE id=?',
      [jsonEncode(listen('other', day: '2026-10-22')), 'event'],
    );
    expect((await store.lifetime()).days, {'2026-10-22': 1000});
    expect((await store.lifetime()).books, {'other': 1000});
    await journal.deleteEvent('event');
    expect((await store.lifetime()).days, isEmpty);
    await journal.put('audio_event', 'event', listen('book'));
    expect((await store.lifetime()).days, {'2026-10-23': 1000});
    await repository.db.customStatement('DELETE FROM records WHERE id=?', [
      'event',
    ]);
    expect((await store.lifetime()).days, isEmpty);
  });

  test('daily aggregates roll back with source records and ignore non-listening events', () async {
    final store = AudioDailyStore(repository),
        journal = AudioJournal(repository);
    await store.ensure();
    await journal.put('audio_event', 'pause', {
      'kind': 'pause',
      'bookId': 'book',
      'localDay': '2026-10-23',
    });
    await expectLater(
      repository.db.transaction(() async {
        await journal.put('audio_event', 'event', listen('book'));
        throw StateError('simulate interrupted transaction');
      }),
      throwsStateError,
    );
    expect((await store.lifetime()).days, isEmpty);
    expect(await repository.record('event'), isNull);
  });

  test('selected-period aggregates match detailed analytics including timezone and year boundaries', () async {
    final events = [
      listen('a', wall: 4000, day: '2026-12-31', at: '2026-12-31T23:59:58Z'),
      {
        ...listen(
          'b',
          wall: 8000,
          day: '2027-01-01',
          at: '2026-12-31T23:59:56Z',
        ),
        'offsetMinutes': 120,
      },
      {
        ...listen(
          'c',
          wall: 1000,
          day: '2026-12-31',
          at: '2026-12-31T23:59:59Z',
        ),
        'kind': 'journal',
        'timeKnown': false,
        'mediaMs': 0,
      },
      {
        ...listen(
          'd',
          wall: 2000,
          day: '2027-01-01',
          at: '2027-01-01T00:00:00Z',
        ),
        'kind': 'journal',
        'mediaMs': 0,
      },
    ];
    for (var i = 0; i < events.length; i++) {
      await AudioJournal(repository).put('audio_event', '$i', events[i]);
    }
    final store = AudioDailyStore(repository);
    final start = DateTime.utc(2027), end = DateTime.utc(2028);
    final expected = analyzeListening({
      'events': events,
      'start': start.toIso8601String(),
      'end': end.toIso8601String(),
    }).selected;
    final actual = await store.period(start, end);
    expect(actual.days, expected.days);
    expect(actual.books, expected.books);
    expect((await store.lifetime()).days, AudioStats(events).days);
  });

  Future<
    ({
      VideoRepository repo,
      List<VideoLesson> songs,
      VideoPlaybackController player,
      TestVideoEngine engine,
    })
  >
  music() async {
    final repo = VideoRepository(repository);
    final item = await repo.addSources(
      title: 'Music',
      sources: [
        for (var i = 0; i < 4; i++) VideoSourceDraft('$i.mp3', 'Track $i'),
      ],
    );
    final songs = await repo.lessons(itemId: item.id),
        engine = TestVideoEngine();
    final player = VideoPlaybackController(
      repository: repo,
      engine: engine,
      lessons: songs,
      random: Random(2),
      checkpointPeriod: null,
    );
    await player.load(0);
    addTearDown(() async {
      await player.close();
      player.dispose();
    });
    return (repo: repo, songs: songs, player: player, engine: engine);
  }

  test('editable queue keeps the current song and position and does not reorder the library', () async {
    final h = await music();
    h.engine.tick(12000);
    await h.player.reorderQueue(0, 2);
    expect(h.player.playbackOrder, [1, 2, 0, 3]);
    expect(
      (h.player.index, h.player.queueIndex, h.player.positionMs),
      (0, 2, 12000),
    );
    await h.player.playNext(1);
    expect(h.player.playbackOrder, [2, 0, 1, 3]);
    await h.player.removeFromQueue(2);
    expect(h.player.playbackOrder, [0, 1, 3]);
    await h.player.setShuffle(true);
    expect(h.player.playbackOrder.toSet(), {0, 1, 3});
    expect(
      (await h.repo.lessons()).map((song) => song.id),
      h.songs.map((song) => song.id),
    );
    expect(h.engine.seeks, isEmpty);
  });

  test('queue, shuffle and repeat survive creating a new controller', () async {
    final h = await music();
    await h.player.setShuffle(true);
    await h.player.playNext(3);
    await h.player.removeFromQueue(2);
    await h.player.setRepeat(MusicRepeat.all);
    final order = List.of(h.player.playbackOrder);
    await h.player.close();
    final fresh = VideoPlaybackController(
      repository: h.repo,
      engine: TestVideoEngine(),
      lessons: await h.repo.lessons(),
      checkpointPeriod: null,
    );
    try {
      await fresh.load(0, play: false);
      expect(fresh.playbackOrder, order);
      expect(fresh.shuffleEnabled, isTrue);
      expect(fresh.repeatMode, MusicRepeat.all);
      expect(fresh.state.playing, isFalse);
    } finally {
      await fresh.close();
      fresh.dispose();
    }
  });

  test(
    'repeat one and all restart correctly and sleep-at-end takes precedence',
    () async {
      final h = await music();
      await h.player.setRepeat(MusicRepeat.one);
      h.engine.tick(120000, playing: false, completed: true);
      await h.player.flush();
      expect(h.player.index, 0);
      expect(h.player.state.playing, isTrue);
      await h.player.setRepeat(MusicRepeat.all);
      await h.player.load(3);
      h.engine.tick(120000, playing: false, completed: true);
      await h.player.flush();
      expect(h.player.index, 0);
      await h.player.setSleepTimer(null, untilLessonEnd: true);
      h.engine.tick(120000, playing: false, completed: true);
      await h.player.flush();
      expect(h.player.index, 0);
      expect(h.player.state.playing, isFalse);
    },
  );

  test(
    'music metadata preserves source identity, order and track version',
    () async {
      final h = await music();
      await h.player.updateMusicDetails(
        'New title',
        const MusicMetadata(artist: 'Artist', album: 'Album', trackNumber: 2),
      );
      final saved = (await h.repo.lessons()).first;
      expect(saved.id, h.songs.first.id);
      expect(saved.mediaVersion, h.songs.first.mediaVersion);
      expect(saved.source, h.songs.first.source);
      expect(saved.ordinal, 0);
      expect(saved.music!.artist, 'Artist');
      expect(saved.music!.trackNumber, 2);
    },
  );

  test('restoring a removed song while shuffled preserves it when shuffle is disabled', () async {
    final h = await music();
    await h.player.removeFromQueue(2);
    await h.player.setShuffle(true);
    await h.player.playNext(2);
    await h.player.next();
    expect(h.player.index, 2);
    await h.player.setShuffle(false);
    expect(h.player.playbackOrder, contains(2));
    expect(h.player.queueIndex, greaterThanOrEqualTo(0));
  });

  test('restored shuffle drops unavailable sources without stopping the remaining queue', () async {
    final h = await music();
    await h.player.setShuffle(true);
    final unavailable = h.player.playbackOrder[1];
    await h.player.close();
    await repository.db.customStatement(
      "UPDATE records SET payload=json_set(payload,'\$.available',json('false')) WHERE id=?",
      [h.songs[unavailable].id],
    );
    final fresh = VideoPlaybackController(
      repository: h.repo,
      engine: TestVideoEngine(),
      lessons: await h.repo.lessons(),
      checkpointPeriod: null,
    );
    try {
      await fresh.load(0, play: false);
      expect(fresh.playbackOrder, isNot(contains(unavailable)));
      expect(fresh.playbackOrder.length, 3);
      await fresh.next();
      expect(fresh.current!.available, isTrue);
    } finally {
      await fresh.close();
      fresh.dispose();
    }
  });

  test(
    'stale metadata editor cannot rename the next song after auto advance',
    () async {
      final h = await music();
      final original = h.player.current!;
      await h.player.next();
      await expectLater(
        h.player.updateMusicDetails(
          'Wrong song',
          const MusicMetadata(artist: 'Wrong'),
          lessonId: original.id,
          mediaVersion: original.mediaVersion,
        ),
        throwsStateError,
      );
      expect(h.player.current!.title, 'Track 1');
      expect((await h.repo.lessons())[1].title, 'Track 1');
    },
  );

  test('music history is separate from video even in audio-only course mode and with legacy records', () async {
    final h = await music();
    final course = await h.repo.addSources(
      title: 'Course',
      sources: [const VideoSourceDraft('lesson.mp4', 'Lesson')],
    );
    final video = (await h.repo.lessons(itemId: course.id)).single;
    VideoInterval interval(String id, VideoLesson lesson) => VideoInterval(
      id: id,
      sessionId: 'session',
      lessonId: lesson.id,
      mediaVersion: lesson.mediaVersion,
      mode: VideoActivityMode.audio,
      startedAt: DateTime.utc(2026, 10, 23),
      offsetMinutes: 0,
      startMs: 0,
      endMs: 1000,
      wallMs: 1000,
      speed: 1,
    );
    for (final pair in [('music', h.songs.first), ('video', video)]) {
      await AudioJournal(repository)
          .put('video_interval', pair.$1, interval(pair.$1, pair.$2).toJson());
    }
    expect((await h.repo.intervals(music: true)).map((row) => row.id), [
      'music',
    ]);
    expect((await h.repo.intervals(music: false)).map((row) => row.id), [
      'video',
    ]);
    expect(
      (await h.repo.history(music: false)).intervals.map((row) => row.id),
      ['video'],
    );
    await h.player.close();
    await repository.db.customStatement(
      'UPDATE records SET deleted=1 WHERE id=?',
      [h.songs.first.id],
    );
    expect((await h.repo.intervals(music: true)).single.id, 'music');
  });

  test('QR accepts only structured PepeHub invitations and never follows arbitrary links', () {
    final code = Uri(
      scheme: 'pepehub-peer',
      host: 'pair',
      queryParameters: {
        'v': '1',
        'device': '11111111-1111-1111-1111-111111111111',
        'invite': '22222222-2222-2222-2222-222222222222',
        'host': '192.168.1.10',
        'port': '42589',
        'key': base64Url.encode(List.filled(32, 1)),
      },
    ).toString();
    expect(peerInvitationFromQr(' $code '), code);
    for (final invalid in [
      'https://example.org',
      code.replaceFirst('42589', '99999'),
      code.replaceFirst('v=1', 'v=2'),
      'x' * 4097,
    ]) {
      expect(peerInvitationFromQr(invalid), isNull);
    }
  });

  test('field comparison and reader previews describe human changes', () {
    AppSyncVersion v(Map<String, dynamic>? data) => AppSyncVersion(
      'note:test',
      data,
      {'11111111-1111-1111-1111-111111111111': 1},
    );
    expect(
      appSyncChangedFields([
        v({'title': 'A', 'comment': 'Old'}),
        v({'title': 'A', 'comment': 'New'}),
      ]),
      ['Комментарий'],
    );
    expect(
      appSyncChangedFields([
        v({'title': 'A'}),
        v(null),
      ]),
      contains('Состояние'),
    );
    expect(
      appSyncChangedFields([
        v({'body': 'a' * 2500 + 'X'}),
        v({'body': 'a' * 2500 + 'Y'}),
      ]),
      ['Текст'],
    );
    expect(
      appSyncChangedFields([
        v({
          'tags': [
            {'x': 1},
          ],
        }),
        v({
          'tags': [
            {'x': 2},
          ],
        }),
      ]),
      ['Теги'],
    );
    expect(
      readerPositionDescription(
        {'chapter': 1, 'textOffset': 50},
        {
          'chapters': ['Start', 'The island'],
          'lengths': [20, 100],
        },
      ),
      'The island · 50% главы',
    );
    expect(readerPositionContext('Before 🙂 after', 8), contains('🙂'));
  });

  test(
    'folder preview reads names and sizes without creating sync files',
    () async {
      final root = await Directory.systemTemp.createTemp('pepehub-preview-');
      try {
        await File('${root.path}/one.txt').writeAsString('123');
        await Directory('${root.path}/.pepehub').create();
        await File('${root.path}/.pepehub/private').writeAsString('ignored');
        await Directory('${root.path}/nested').create();
        await File('${root.path}/nested/two.mp3').writeAsString('12345');
        final before =
            (await root
                  .list(recursive: true)
                  .map((entry) => entry.path)
                  .toList())
              ..sort();
        final preview = await previewPeerFolder(root.path);
        expect((preview.files, preview.bytes), (2, 8));
        expect(preview.examples.toSet(), {'one.txt', 'nested/two.mp3'});
        final after =
            (await root
                  .list(recursive: true)
                  .map((entry) => entry.path)
                  .toList())
              ..sort();
        expect(after, before);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
