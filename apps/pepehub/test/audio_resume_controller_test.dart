import 'dart:async';

import 'package:pepehub/audio/audio_sidecar.dart';

import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_session/audio_session.dart';
import 'package:pepehub/audio/audio_resume.dart';
import 'package:pepehub/audio/models.dart';
import 'package:pepehub/audio/m4b_chapters.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/media/audio_controller.dart';
import 'package:pepehub/video/video_session.dart';
import 'package:pepehub/video/video_repository.dart';
import 'package:pepehub/media/audio_focus.dart';

import 'support/video_engine.dart';

class TestTimer implements Timer {
  final void Function(Timer) callback;
  bool active = true;
  int ticks = 0;
  TestTimer(this.callback);
  void fire() {
    if (active) {
      ticks++;
      callback(this);
    }
  }

  @override
  bool get isActive => active;
  @override
  int get tick => ticks;
  @override
  void cancel() {
    active = false;
  }
}

class TestAudioPlayer extends Fake implements AudioPlayer {
  final states = StreamController<PlayerState>.broadcast(sync: true),
      positions = StreamController<Duration>.broadcast(sync: true),
      events = StreamController<PlaybackEvent>.broadcast(sync: true),
      errors = StreamController<PlayerException>.broadcast(sync: true);
  @override
  bool playing = false;
  @override
  double speed = 1, volume = 1;
  @override
  Duration position = Duration.zero;
  @override
  ProcessingState processingState = ProcessingState.idle;
  @override
  int? currentIndex = 0;
  final List<Duration> lengths;
  final List<(int, int)> seeks = [];
  int opens = 0;
  int pauses = 0;
  bool failSeek = false;
  Completer<void>? pauseGate, seekGate;
  TestAudioPlayer([
    this.lengths = const [Duration(seconds: 100), Duration(seconds: 100)],
  ]);
  @override
  Duration? get duration => processingState == ProcessingState.idle
      ? null
      : lengths[currentIndex ?? 0];
  @override
  Duration get bufferedPosition => position;
  @override
  PlayerState get playerState => PlayerState(playing, processingState);
  @override
  PlaybackEvent get playbackEvent => PlaybackEvent(
    processingState: processingState,
    currentIndex: currentIndex,
    duration: duration,
    updatePosition: position,
  );
  @override
  Stream<PlayerState> get playerStateStream => states.stream;
  @override
  Stream<Duration> get positionStream => positions.stream;
  @override
  Stream<PlaybackEvent> get playbackEventStream => events.stream;
  @override
  Stream<PlayerException> get errorStream => errors.stream;
  void emit() {
    if (states.isClosed) return;
    events.add(playbackEvent);
    states.add(playerState);
    positions.add(position);
  }

  void at(int index, int ms, {bool completed = false}) {
    currentIndex = index;
    position = Duration(milliseconds: ms);
    processingState = completed
        ? ProcessingState.completed
        : ProcessingState.ready;
    emit();
  }

  @override
  Future<Duration?> setAudioSource(
    AudioSource audioSource, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) => setAudioSources(
    [audioSource],
    preload: preload,
    initialIndex: initialIndex,
    initialPosition: initialPosition,
  );

  @override
  Future<Duration?> setAudioSources(
    List<AudioSource> sources, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
    ShuffleOrder? shuffleOrder,
  }) async {
    if (failSeek && initialIndex == 0) throw StateError('decoder open failed');
    opens++;
    at(
      initialIndex ?? 0,
      (initialPosition ?? Duration.zero).inMilliseconds,
      completed:
          (initialPosition ?? Duration.zero) >= lengths[initialIndex ?? 0],
    );
    return duration;
  }

  @override
  Future<void> play() async {
    playing = true;
    emit();
  }

  @override
  Future<void> pause() async {
    pauses++;
    final gate = pauseGate;
    pauseGate = null;
    await gate?.future;
    playing = false;
    emit();
  }

  @override
  Future<void> stop() async {
    playing = false;
    processingState = ProcessingState.idle;
    position = Duration.zero;
    states.add(playerState);
    positions.add(position);
  }

  @override
  Future<void> seek(Duration? target, {int? index}) async {
    final gate = seekGate;
    seekGate = null;
    await gate?.future;
    if (failSeek) throw StateError('seek failed');
    seeks.add((index ?? currentIndex ?? 0, target?.inMilliseconds ?? 0));
    at(index ?? currentIndex ?? 0, target?.inMilliseconds ?? 0);
  }

  @override
  Future<void> setSpeed(double value) async {
    speed = value;
  }

  @override
  Future<void> setVolume(double value) async {
    volume = value;
  }

  @override
  Future<void> dispose() async {
    await states.close();
    await positions.close();
    await events.close();
    await errors.close();
  }
}

class Harness {
  AudioSidecarWriter? sidecarWriter;
  AudioPlayer Function()? durationProbeFactory;
  TestAudioPlayer Function()? initialPlayerFactory;
  TestAudioPlayer Function()? replacementPlayerFactory;
  Duration backendTimeout = const Duration(seconds: 3);
  final db = AppDatabase(NativeDatabase.memory());
  late final repo = Repository(db);
  late Directory root;
  late AssetStore assets;
  late AudioController controller;
  late TestAudioPlayer player;
  final timers = <TestTimer>[];
  DateTime now = DateTime.utc(2026, 10, 17, 20);
  int? fixedMonotonic;
  Future<void> open({int index = 1, int ms = 3000, double speed = 1}) async {
    root = await Directory.systemTemp.createTemp('pepe-audio-resume-');
    assets = AssetStore(repo, Directory('${root.path}/assets'));
    await repo.put('book', 'book', {'title': 'Book', 'format': 'audio'});
    await db.customStatement('INSERT INTO audio_editions VALUES(?,?,1)', [
      'edition',
      'book',
    ]);
    for (var i = 0; i < 2; i++) {
      final file = File('${root.path}/$i.mp3');
      await file.writeAsBytes([73, 68, 51, i]);
      await db.customStatement('INSERT INTO local_assets VALUES(?,?,?,?,?,?)', [
        'track$i',
        'book',
        '$i.mp3',
        file.path,
        'hash$i',
        4,
      ]);
      await db.customStatement('INSERT INTO audio_resources VALUES(?,?,?)', [
        'hash$i',
        file.path,
        4,
      ]);
      await db.customStatement('INSERT INTO audio_tracks VALUES(?,?,?,?,?,?)', [
        'track$i',
        'edition',
        'hash$i',
        i,
        'Track $i',
        100000,
      ]);
    }
    await repo.db.customStatement(
      'INSERT INTO audio_progress VALUES(?,?,?,?,?,?)',
      ['edition', 'track$index', ms, 1, speed, now.toIso8601String()],
    );
    await restart();
  }

  Future<void> restart() async {
    player = initialPlayerFactory?.call() ?? TestAudioPlayer();
    controller = AudioController(
      assets,
      player,
      playerFactory: () =>
          player = replacementPlayerFactory?.call() ?? TestAudioPlayer(),
      backendTimeout: backendTimeout,
      sidecarWriter: sidecarWriter,
      now: () => now,
      elapsedMilliseconds: () =>
          fixedMonotonic ??
          now.difference(DateTime.utc(2026, 10, 17, 20)).inMilliseconds,
      probeFactory: durationProbeFactory ?? () => TestAudioPlayer(),
      periodic: (duration, callback) {
        final timer = TestTimer(callback);
        timers.add(timer);
        return timer;
      },
    );
    await controller.loadPlaybackPreferences();
    await controller.open((await assets.audioTracks('book')).first, 'Book');
  }

  Future<void> expire() async {
    now = now.add(const Duration(minutes: 2));
    timers.last.fire();
    // Observe the timer's own stop; a manual Pause would mask a bug that
    // incorrectly resumes after an interruption despite timer expiry.
    for (var n = 0; n < 200; n++) {
      if (player.processingState == ProcessingState.idle &&
          controller.canPlay) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    throw StateError('Таймер не остановил воспроизведение');
  }

  Future<void> close() async {
    await controller.shutdown();
    await db.close();
    await root.delete(recursive: true);
  }

  Future<AudioProgress> progress() =>
      controller.audioLibrary.progressForTrack('track0');
}

class GatedSidecar extends AudioSidecarWriter {
  final gate = Completer<void>();
  int calls = 0;
  GatedSidecar(super.assets);
  @override
  Future<void> update(String bookId, {bool force = false}) {
    calls++;
    return gate.future;
  }
}

class GatedDurationProbe extends TestAudioPlayer {
  final gate = Completer<Duration?>();
  @override
  Future<Duration?> setAudioSource(
    AudioSource audioSource, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) => gate.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = true);
  tearDownAll(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = false);
  late Harness h;
  setUp(() async {
    h = Harness();
    await h.open();
  });
  tearDown(() async => h.close());
  test(
    'cross-track rewind with an unknown duration never pauses the main decoder',
    () async {
      await h.controller.shutdown();
      await h.db.customStatement(
        "UPDATE audio_tracks SET duration_ms=NULL WHERE id='track0'",
      );
      final background = GatedDurationProbe();
      var probes = 0;
      h.durationProbeFactory = () =>
          ++probes == 1 ? background : TestAudioPlayer();
      await h.restart();
      try {
        await h.controller.play();
        final pauses = h.player.pauses;
        await h.controller.skipSeconds(-10).timeout(const Duration(seconds: 1));
        expect(h.controller.error, isEmpty);
        expect(probes, greaterThanOrEqualTo(2));
        expect(h.player.pauses, pauses);
        expect(h.controller.trackIndex, 0);
        expect(h.controller.position.inSeconds, 93);
        expect(h.controller.playing, true);
      } finally {
        background.gate.complete(const Duration(seconds: 100));
      }
    },
  );
  test(
    'slow folder snapshot never holds Pause, Play, seeking or speed changes',
    () async {
      await h.controller.shutdown();
      final writer = GatedSidecar(h.assets);
      h.sidecarWriter = writer;
      await h.restart();
      try {
        await h.controller.play();
        await h.controller.pause().timeout(const Duration(milliseconds: 500));
        expect(writer.gate.isCompleted, false);
        expect(writer.calls, greaterThan(0));
        expect((await h.progress()).locator.positionMs, 3000);
        await h.controller.play().timeout(const Duration(milliseconds: 500));
        await h.controller
            .skipSeconds(15)
            .timeout(const Duration(milliseconds: 500));
        await h.controller
            .setSpeed(1.5)
            .timeout(const Duration(milliseconds: 500));
        await h.controller.pause().timeout(const Duration(milliseconds: 500));
        expect(h.controller.position.inSeconds, 18);
        expect(h.controller.speed, 1.5);
        expect((await h.progress()).locator.positionMs, 18000);
      } finally {
        writer.gate.complete();
      }
    },
  );
  for (final operation in ['pause', 'seek']) {
    test(
      'a stuck $operation times out; next command rebuilds decoder and ignores late completion',
      () async {
        await h.controller.shutdown();
        h.backendTimeout = const Duration(milliseconds: 30);
        await h.restart();
        await h.controller.play();
        final abandoned = h.player, gate = Completer<void>();
        if (operation == 'pause') {
          abandoned.pauseGate = gate;
        } else {
          abandoned.seekGate = gate;
        }
        await (operation == 'pause'
                ? h.controller.pause()
                : h.controller.seek(const Duration(seconds: 50)))
            .timeout(const Duration(seconds: 1));
        expect(h.controller.error, contains('Аудиодвижок'));
        await h.controller
            .seek(const Duration(seconds: 20))
            .timeout(const Duration(seconds: 1));
        expect(identical(abandoned, h.player), false);
        expect(h.controller.position.inSeconds, 20);
        expect(h.controller.playing, false);
        gate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(h.controller.position.inSeconds, 20);
        expect(h.controller.playing, false);
        await h.controller.play().timeout(const Duration(seconds: 1));
        expect(h.controller.playing, true);
      },
    );
  }
  test('timer parks the exact position and Play rewinds once across files, preserving speed and statistics', () async {
    await h.controller.play();
    await h.controller.setSpeed(2);
    h.controller.setSleepTimer(1);
    await h.expire();
    expect(h.controller.position.inMilliseconds, 3000);
    expect(h.controller.trackIndex, 1);
    expect(h.player.processingState, ProcessingState.idle);
    expect(h.player.volume, 1);
    expect((await h.progress()).locator.positionMs, 3000);
    expect((await h.controller.resumeStore.load('edition'))!.reason, 'sleep');
    h.now = h.now.add(const Duration(hours: 8));
    await h.controller.play();
    expect(h.controller.trackIndex, 0);
    expect(h.controller.position.inMilliseconds, 93000);
    expect(h.controller.speed, 2);
    expect(h.controller.playing, true);
    expect((await h.progress()).locator.positionMs, 93000);
    expect(await h.controller.resumeStore.load('edition'), isNull);
    final seeks = h.player.seeks.length;
    await h.controller.play();
    expect(h.player.seeks.length, seeks);
    await h.controller.flushJournal();
    final events = await h.controller.journal.list('audio_event');
    expect(
      events.where((e) => e.payload?['reason'] == 'sleep_rewind'),
      hasLength(1),
    );
    final sessions = await h.repo.records('session');
    expect(
      sessions.where((e) => (e.payload?['activeSeconds'] as int? ?? 0) >= 10),
      isEmpty,
    );
  });
  test('sleep return survives controller shutdown and app restart without double rewind', () async {
    await h.controller.play();
    h.controller.setSleepTimer(1);
    await h.expire();
    await h.controller.shutdown();
    await h.restart();
    expect(h.controller.position.inMilliseconds, 3000);
    await h.controller.play();
    expect(h.controller.position.inMilliseconds, 93000);
    await h.controller.pause();
    await h.controller.shutdown();
    await h.restart();
    await h.controller.play();
    expect(h.controller.position.inMilliseconds, 93000);
  });
  test(
    'manual seek after sleep cancels return even after a long pause',
    () async {
      await h.controller.play();
      h.controller.setSleepTimer(1);
      await h.expire();
      await h.controller.seek(const Duration(seconds: 50));
      h.now = h.now.add(const Duration(hours: 10));
      await h.controller.play();
      expect(h.controller.position.inMilliseconds, 50000);
      expect(h.controller.trackIndex, 1);
    },
  );
  test(
    'disabled sleep return is independent of adaptive pause return',
    () async {
      await h.controller.updateSleepOptions(rewind: false);
      await h.controller.play();
      h.controller.setSleepTimer(1);
      await h.expire();
      h.now = h.now.add(const Duration(hours: 2));
      await h.controller.play();
      expect(h.controller.position.inMilliseconds, 3000);
      h.player.at(1, 50000);
      await h.controller.pause();
      final paused = (await h.controller.resumeStore.load('edition'))!.pausedAt;
      h.now = h.now.add(const Duration(seconds: 40));
      await h.controller.pause();
      expect(
        (await h.controller.resumeStore.load('edition'))!.pausedAt,
        paused,
      );
      h.now = h.now.add(const Duration(minutes: 2));
      await h.controller.play();
      expect(h.controller.position.inMilliseconds, 40000);
    },
  );
  test('missing preceding source keeps the original checkpoint and pending return for retry', () async {
    await h.controller.play();
    h.controller.setSleepTimer(1);
    await h.expire();
    await File('${h.root.path}/0.mp3').delete();
    await h.controller.play();
    expect(h.controller.playing, false);
    expect(h.controller.error, contains('Источник недоступен'));
    expect((await h.progress()).locator.positionMs, 3000);
    expect(await h.controller.resumeStore.load('edition'), isNotNull);
    await File('${h.root.path}/0.mp3').writeAsBytes([73, 68, 51, 0]);
    await h.controller.play();
    expect(h.controller.position.inMilliseconds, 93000);
  });
  test(
    'a replacement timer invalidates an expiry queued behind another command',
    () async {
      await h.controller.play();
      final gate = Completer<void>();
      h.player.pauseGate = gate;
      final pause = h.controller.pause();
      await Future<void>.delayed(Duration.zero);
      h.controller.setSleepTimer(1);
      h.now = h.now.add(const Duration(minutes: 2));
      h.timers.last.fire();
      h.controller.setSleepTimer(15);
      gate.complete();
      await pause;
      await h.controller.pause();
      expect(h.player.processingState, ProcessingState.ready);
      expect(h.controller.sleepMode, 'duration');
      expect(h.controller.sleepUntil, isNotNull);
      await h.controller.flushJournal();
      expect(
        (await h.controller.journal.list('audio_event'))
            .where((e) => e.payload?['kind'] == 'sleep_fired'),
        isEmpty,
      );
    },
  );
  test('rewind options preserve legacy disabled preference and persist new amounts', () async {
    await h.controller.updateSleepOptions(
      rewindSeconds: 45,
      resume: const AudioRewindSettings(
        shortSeconds: 5,
        mediumSeconds: 15,
        longSeconds: 60,
      ),
    );
    await h.controller.shutdown();
    await h.restart();
    expect(h.controller.sleepRewindSeconds, 45);
    expect(h.controller.rewindSettings.longSeconds, 60);
    await h.repo.setMeta(
      'audio-sleep-settings',
      '{"fade":false,"rewind":false}',
    );
    await h.controller.loadPlaybackPreferences();
    expect(h.controller.sleepRewind, false);
    expect(h.controller.sleepFade, false);
  });
  test('chapter boundary pauses at the boundary; manual chapter navigation cancels it', () async {
    await h.controller.seek(const Duration(seconds: 10));
    h.controller.chapters = [
      BookChapter('Chapter', 0),
      BookChapter('Next', 20000),
    ];
    await h.controller.play();
    h.controller.setSleepTimer(null, mode: 'chapter');
    h.player.at(1, 20000);
    h.timers.last.fire();
    await h.controller.pause();
    expect(h.controller.position.inMilliseconds, 20000);
    await h.controller.play();
    expect(h.controller.position.inMilliseconds, 10000);
    h.controller.setSleepTimer(null, mode: 'track');
    await h.controller.skipToPrevious();
    expect(h.controller.sleepMode, 'off');
  });
  test(
    'timer at book end resumes with return instead of restarting the book',
    () async {
      await h.controller.play();
      h.controller.setSleepTimer(null, mode: 'track');
      h.player.at(1, 100000, completed: true);
      h.timers.last.fire();
      await h.controller.pause();
      expect(h.controller.position.inMilliseconds, 100000);
      await h.controller.play();
      expect(h.controller.trackIndex, 1);
      expect(h.controller.position.inMilliseconds, 90000);
    },
  );
  test(
    'ordinary completion cancels a duration timer and restarts normally',
    () async {
      await h.controller.play();
      h.controller.setSleepTimer(60);
      h.player.at(1, 100000, completed: true);
      await h.controller.pause();
      expect(h.controller.sleepMode, 'off');
      expect(await h.controller.resumeStore.load('edition'), isNull);
      await h.controller.play();
      expect(h.controller.trackIndex, 0);
      expect(h.controller.position, Duration.zero);
    },
  );
  test('audio-focus interruption resumes through rewind; manual pause and expired timer prevent auto-resume', () async {
    await h.controller.updateSleepOptions(resumeAfterInterruption: true);
    h.player.at(1, 50000);
    await h.controller.play();
    await h.controller.handleInterruption(
      AudioInterruptionEvent(true, AudioInterruptionType.pause),
    );
    expect(h.controller.playing, false);
    h.now = h.now.add(const Duration(minutes: 2));
    await h.controller.handleInterruption(
      AudioInterruptionEvent(false, AudioInterruptionType.pause),
    );
    expect(h.controller.playing, true);
    expect(h.controller.position.inMilliseconds, 40000);
    await h.controller.handleInterruption(
      AudioInterruptionEvent(true, AudioInterruptionType.pause),
    );
    await h.controller.pause();
    await h.controller.handleInterruption(
      AudioInterruptionEvent(false, AudioInterruptionType.pause),
    );
    expect(h.controller.playing, false);
    await h.controller.play();
    h.controller.setSleepTimer(1);
    await h.controller.handleInterruption(
      AudioInterruptionEvent(true, AudioInterruptionType.pause),
    );
    await h.expire();
    await h.controller.handleInterruption(
      AudioInterruptionEvent(false, AudioInterruptionType.pause),
    );
    expect(h.controller.playing, false);
    expect((await h.controller.resumeStore.load('edition'))!.reason, 'sleep');
  });
  test('fade cancellation restores the original volume; disabled return keeps the exact checkpoint', () async {
    await h.player.setVolume(.7);
    await h.controller.play();
    h.controller.setSleepTimer(1);
    h.now = h.now.add(const Duration(seconds: 50));
    h.timers.last.fire();
    expect(h.player.volume, lessThan(.7));
    h.controller.extendSleep();
    await Future<void>.delayed(Duration.zero);
    expect(h.player.volume, .7);
    h.controller.setSleepTimer(null);
    expect(h.player.volume, .7);
    await h.controller.updateSleepOptions(
      rewind: false,
      resume: const AudioRewindSettings(enabled: false),
    );
    h.controller.setSleepTimer(1);
    await h.expire();
    await h.controller.play();
    expect(h.controller.position.inMilliseconds, 3000);
  });
  test('wall-clock changes cannot fire a duration timer early', () async {
    h.fixedMonotonic = 0;
    await h.controller.play();
    h.controller.setSleepTimer(1);
    h.now = h.now.add(const Duration(days: 1));
    h.fixedMonotonic = 1000;
    h.timers.last.fire();
    await h.controller.pause();
    expect(h.controller.sleepMode, 'duration');
    expect(h.player.processingState, ProcessingState.ready);
    h.fixedMonotonic = 61000;
    h.timers.last.fire();
    await h.controller.pause();
    expect(h.player.processingState, ProcessingState.idle);
  });
  test(
    'notification pauses briefly and resumes even when call resume is disabled',
    () async {
      var handovers = 0;
      h.controller.beforeBookPlayback = () async {
        handovers++;
      };
      expect(spokenAudioConfiguration.androidWillPauseWhenDucked, isFalse);
      expect(h.controller.resumeAfterInterruption, isFalse);
      await h.controller.play();
      await h.controller.handleInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.duck),
      );
      expect(h.controller.playing, isFalse);
      await h.controller.handleInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.duck),
      );
      await h.controller.handleInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.duck),
      );
      expect(h.controller.playing, isTrue);
      expect(
        handovers,
        1,
        reason: 'Focus return must not repeat ownership handover',
      );
      await h.controller.handleInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.duck),
      );
      await h.controller.pause();
      await h.controller.handleInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.duck),
      );
      expect(h.controller.playing, isFalse);
    },
  );

  test('a notification upgraded to exclusive or permanent focus does not restart the book', () async {
    for (final type in [
      AudioInterruptionType.pause,
      AudioInterruptionType.unknown,
    ]) {
      await h.controller.play();
      await h.controller.handleInterruption(
        AudioInterruptionEvent(true, AudioInterruptionType.duck),
      );
      await h.controller.handleInterruption(AudioInterruptionEvent(true, type));
      await h.controller.handleInterruption(
        AudioInterruptionEvent(false, AudioInterruptionType.pause),
      );
      expect(h.controller.playing, isFalse);
    }
  });

  test('expired sleep timer cancels notification resume', () async {
    await h.controller.play();
    h.controller.setSleepTimer(1);
    await h.controller.handleInterruption(
      AudioInterruptionEvent(true, AudioInterruptionType.duck),
    );
    await h.expire();
    await h.controller.handleInterruption(
      AudioInterruptionEvent(false, AudioInterruptionType.duck),
    );
    expect(h.controller.playing, isFalse);
  });

  test('only the current sound owner handles shared notifications after switching music and book', () async {
    final videos = VideoRepository(h.controller.assets.repository);
    final item = await videos.addSources(
      title: 'Music',
      sources: [const VideoSourceDraft('song.mp3', 'Song')],
    );
    final session = VideoPlaybackSession(
      videos,
      audio: h.controller,
      engineFactory: TestVideoEngine.new,
    );
    try {
      await h.controller.play();
      await session.open(item, await videos.lessons(itemId: item.id), 0);
      expect(h.controller.playing, isFalse);
      expect(session.controller!.state.playing, isTrue);
      final begin = AudioInterruptionEvent(true, AudioInterruptionType.duck);
      final end = AudioInterruptionEvent(false, AudioInterruptionType.duck);
      await h.controller.handleInterruption(begin);
      await session.handleInterruption(begin);
      await h.controller.handleInterruption(end);
      await session.handleInterruption(end);
      expect(session.controller!.state.playing, isTrue);
      expect(h.controller.playing, isFalse);
      await h.controller.play();
      expect(session.controller!.state.playing, isFalse);
      await h.controller.handleInterruption(begin);
      await session.handleInterruption(begin);
      await session.handleInterruption(end);
      await h.controller.handleInterruption(end);
      expect(h.controller.playing, isTrue);
      expect(session.controller!.state.playing, isFalse);
    } finally {
      await session.close();
      session.dispose();
    }
  });

  test('automatic call resume is opt-in and explicit Play recovers after a permanent interruption', () async {
    await h.controller.play();
    await h.controller.handleInterruption(
      AudioInterruptionEvent(true, AudioInterruptionType.pause),
    );
    await h.controller.handleInterruption(
      AudioInterruptionEvent(false, AudioInterruptionType.pause),
    );
    expect(h.controller.playing, false);
    await h.controller.play();
    await h.controller.handleInterruption(
      AudioInterruptionEvent(true, AudioInterruptionType.unknown),
    );
    expect(h.controller.playing, false);
    await h.controller.play();
    expect(h.controller.playing, true);
  });
  for (final trackIndex in [0, 1]) {
    test(
      'a new external checkpoint on track $trackIndex invalidates an older local return intent',
      () async {
        await h.controller.play();
        await h.controller.pause();
        await h.controller.shutdown();
        await h.controller.audioLibrary.saveProgress(
          AudioProgress(
            AudioLocator(
              bookId: 'book',
              editionId: 'edition',
              trackId: 'track$trackIndex',
              positionMs: 20000,
              manifestRevision: 1,
            ),
            1,
          ),
        );
        h.now = h.now.add(const Duration(days: 1));
        await h.restart();
        await h.controller.play();
        expect(h.controller.position.inMilliseconds, 20000);
        expect(h.controller.trackIndex, trackIndex);
        expect(await h.controller.resumeStore.load('edition'), isNull);
      },
    );
  }
  test('failed rewind preserves pending intent and can be retried without double consumption', () async {
    await h.controller.play();
    h.controller.setSleepTimer(1);
    await h.expire();
    h.player.failSeek = true;
    await h.controller.play();
    expect(h.controller.playing, false);
    expect(await h.controller.resumeStore.load('edition'), isNotNull);
    h.player.failSeek = false;
    await h.controller.play();
    expect(h.controller.position.inMilliseconds, 93000);
    expect(await h.controller.resumeStore.load('edition'), isNull);
  });
  test(
    'missing active source after sleep stays retryable when the folder returns',
    () async {
      await h.controller.play();
      h.controller.setSleepTimer(1);
      await h.expire();
      await File('${h.root.path}/1.mp3').delete();
      await h.controller.play();
      expect(h.controller.playing, false);
      expect(h.controller.canPlay, true);
      expect(h.controller.position.inMilliseconds, 3000);
      expect(await h.controller.resumeStore.load('edition'), isNotNull);
      await File('${h.root.path}/1.mp3').writeAsBytes([73, 68, 51, 1]);
      await h.controller.play();
      expect(h.controller.position.inMilliseconds, 93000);
      expect(h.controller.playing, true);
    },
  );
}
