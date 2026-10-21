import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/shared_media_handler.dart';
import 'package:pepehub/video/models.dart';
import 'package:pepehub/video/video_controller.dart';
import 'package:pepehub/video/video_repository.dart';
import 'package:pepehub/video/video_session.dart';

import 'support/video_engine.dart';

class _Harness {
  final db = AppDatabase(NativeDatabase.memory());
  late final repository = Repository(db), videos = VideoRepository(repository);
  final engine = TestVideoEngine();
  late VideoPlaybackController player;
  late List<VideoLesson> lessons;
  Future<void> open({int count = 7, int start = 3, bool mixed = false}) async {
    final item = await videos.addSources(
      title: 'Shuffle playlist',
      sources: [
        for (var i = 0; i < count; i++)
          VideoSourceDraft('song-$i.mp3', 'Song $i'),
        if (mixed) const VideoSourceDraft('lesson.mp4', 'Video'),
        if (mixed) const VideoSourceDraft('unavailable.mp3', 'Unavailable'),
      ],
    );
    if (mixed) {
      final row = (await videos.lessons()).last;
      await repository.db.customStatement(
        "UPDATE records SET payload=json_set(payload,'\$.available',json('false')) WHERE id=?",
        [row.id],
      );
    }
    lessons = await videos.lessons(itemId: item.id);
    player = VideoPlaybackController(
      repository: videos,
      engine: engine,
      lessons: lessons,
      checkpointPeriod: null,
      random: Random(21),
    );
    await player.load(start);
  }

  Future<void> close() async {
    await player.close();
    player.dispose();
    await db.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('shuffle anchors the current song and forms a complete immutable permutation', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.close);
    h.engine.tick(42000);
    final originalIds = h.lessons.map((lesson) => lesson.id).toList();
    await h.player.setShuffle(true);
    final order = h.player.playbackOrder;
    expect(h.player.shuffleEnabled, isTrue);
    expect(order.first, 3);
    expect(order.toSet(), {0, 1, 2, 3, 4, 5, 6});
    expect(order, hasLength(7));
    expect(h.player.positionMs, 42000);
    expect(h.engine.state.playing, isTrue);
    expect(h.engine.seeks, isEmpty);
    expect(h.player.queueIndex, 0);
    expect(h.player.canGoPrevious, isFalse);
    expect(() => order.add(8), throwsUnsupportedError);
    await h.player.setShuffle(true);
    expect(identical(h.player.playbackOrder, order), isTrue);
    expect((await h.videos.lessons()).map((lesson) => lesson.id), originalIds);
    expect(await h.repository.pending(), isEmpty);
  });

  test('automatic shuffle plays each song once and stops at the end without wrapping', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.close);
    await h.player.setShuffle(true);
    final order = List.of(h.player.playbackOrder), heard = [h.player.index];
    for (var i = 1; i < order.length; i++) {
      h.engine.tick(120000, playing: false, completed: true);
      await h.player.flush();
      heard.add(h.player.index);
      expect(h.player.index, order[i]);
      expect(h.player.state.playing, isTrue);
    }
    expect(heard.toSet(), hasLength(7));
    h.engine.tick(120000, playing: false, completed: true);
    await h.player.flush();
    expect(h.player.index, order.last);
    expect(h.player.state.completed, isTrue);
    expect(h.player.canGoNext, isFalse);
    await h.player.next();
    expect(h.player.index, order.last);
  });

  test('previous follows shuffled history; disabling restores the original order without seeking', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.close);
    await h.player.setShuffle(true);
    final order = List.of(h.player.playbackOrder);
    await h.player.next();
    await h.player.next();
    expect(h.player.index, order[2]);
    await h.player.previous();
    expect(h.player.index, order[1]);
    await h.player.next();
    expect(h.player.index, order[2]);
    h.engine.tick(23000);
    await h.player.setShuffle(false);
    expect(h.player.playbackOrder, [0, 1, 2, 3, 4, 5, 6]);
    expect((h.player.index, h.player.positionMs), (order[2], 23000));
    expect(h.engine.seeks, isEmpty);
    if (h.player.canGoNext) {
      await h.player.next();
      expect(h.player.index, order[2] + 1);
    }
  });

  test('shuffled selection maps original IDs, excludes video and unavailable files', () async {
    final h = _Harness();
    await h.open(mixed: true);
    addTearDown(h.close);
    await h.player.setShuffle(true);
    final order = h.player.playbackOrder;
    expect(order.toSet(), {0, 1, 2, 3, 4, 5, 6});
    final selected = order[4];
    await h.player.load(selected);
    expect(h.player.queueIndex, 4);
    await h.player.next();
    expect(h.player.index, order[5]);
    // Explicitly selecting a video restores its normal queue and presentation.
    await h.player.load(7);
    expect(h.player.shuffleEnabled, isFalse);
    expect(h.player.audioOnly, isFalse);
    expect(h.player.playbackOrder, List.generate(9, (i) => i));
  });

  test('a failed shuffled source can be skipped without repeating or losing the queue', () async {
    final h = _Harness();
    await h.open();
    addTearDown(h.close);
    await h.player.setShuffle(true);
    final order = h.player.playbackOrder;
    h.engine.failOpen = true;
    await expectLater(h.player.next(), throwsStateError);
    expect((h.player.index, h.player.queueIndex), (order[1], 1));
    h.engine.failOpen = false;
    await h.player.next();
    expect((h.player.index, h.player.queueIndex), (order[2], 2));
    expect(identical(h.player.playbackOrder, order), isTrue);
  });

  test('sleep until end prevents shuffled auto-advance and single-track playlists cannot shuffle', () async {
    final h = _Harness();
    await h.open();
    try {
      await h.player.setShuffle(true);
      await h.player.setSleepTimer(null, untilLessonEnd: true);
      h.engine.tick(120000, playing: false, completed: true);
      await h.player.flush();
      expect(h.player.index, 3);
      expect(h.player.queueIndex, 0);
      expect(h.player.state.playing, isFalse);
    } finally {
      await h.close();
    }
    final single = _Harness();
    await single.open(count: 1, start: 0);
    try {
      expect(single.player.canShuffle, isFalse);
      await single.player.setShuffle(true);
      expect(single.player.shuffleEnabled, isFalse);
      expect(single.player.playbackOrder, [0]);
    } finally {
      await single.close();
    }
  });

  test('system shuffle and queue navigation are forwarded to the same session and survive mini-player reuse', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final videos = VideoRepository(Repository(db));
    final item = await videos.addSources(
      title: 'Music',
      sources: [
        for (var i = 0; i < 4; i++) VideoSourceDraft('$i.mp3', 'Song $i'),
      ],
    );
    final lessons = await videos.lessons(itemId: item.id);
    final engine = TestVideoEngine();
    final session = VideoPlaybackSession(videos, engineFactory: () => engine);
    final shared = SharedMediaHandler(BaseAudioHandler())..setOwner(session);
    try {
      await session.open(item, lessons, 3);
      engine.tick(12000);
      await shared.setShuffleMode(AudioServiceShuffleMode.all);
      final player = session.controller!,
          order = session.controller!.playbackOrder;
      expect(session.queue.value.map((song) => song.id), [
        for (final i in order) 'video:${lessons[i].id}',
      ]);
      expect(
        session.playbackState.value.shuffleMode,
        AudioServiceShuffleMode.all,
      );
      expect(session.playbackState.value.queueIndex, 0);
      await shared.skipToQueueItem(2);
      expect(player.index, order[2]);
      await shared.skipToPrevious();
      expect(player.index, order[1]);
      session.attachPage();
      session.requestMini();
      session.detachPage();
      await session.open(item, lessons, player.index);
      expect(identical(session.controller, player), isTrue);
      expect(identical(player.playbackOrder, order), isTrue);
      await shared.setShuffleMode(AudioServiceShuffleMode.none);
      expect(session.queue.value.map((song) => song.id), [
        for (final lesson in lessons) 'video:${lesson.id}',
      ]);
      expect(session.playbackState.value.queueIndex, player.index);
    } finally {
      await shared.close();
      await session.close();
      session.dispose();
      await db.close();
    }
  });
}
