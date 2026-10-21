import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

import 'audio_resume_controller_test.dart'
    show Harness, TestAudioPlayer, GatedDurationProbe;

class RefusingPlayer extends TestAudioPlayer {
  @override
  Future<Duration?> setAudioSources(
    List<AudioSource> sources, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
    ShuffleOrder? shuffleOrder,
  }) async => throw StateError('Source temporarily unavailable');
}

class GatedControlsPlayer extends TestAudioPlayer {
  Completer<void>? volumeGate, speedGate;
  bool rejectVolume = false;
  bool rejectSpeed = false, rejectSeek = false, rejectPlay = false;
  int volumeCalls = 0;
  @override
  Future<void> setVolume(double value) async {
    volumeCalls++;
    if (rejectVolume) throw StateError('volume unavailable');
    final gate = volumeGate;
    volumeGate = null;
    await gate?.future;
    volume = value;
  }

  @override
  Future<void> setSpeed(double value) async {
    speed = value; // just_audio exposes the requested speed before native ack.
    if (rejectSpeed) throw StateError('speed rejected');
    final gate = speedGate;
    speedGate = null;
    await gate?.future;
  }

  @override
  Future<void> seek(Duration? target, {int? index}) async {
    position = target ?? Duration.zero;
    if (rejectSeek) throw StateError('seek rejected');
    await super.seek(target, index: index);
  }

  @override
  Future<void> play() async {
    await super.play();
    if (rejectPlay) throw StateError('play rejected');
  }
}

class RejectOldBookPlayer extends TestAudioPlayer {
  @override
  Future<Duration?> setAudioSources(
    List<AudioSource> sources, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
    ShuffleOrder? shuffleOrder,
  }) {
    if (sources.length == 2) throw StateError('old book unavailable');
    return super.setAudioSources(
      sources,
      preload: preload,
      initialIndex: initialIndex,
      initialPosition: initialPosition,
      shuffleOrder: shuffleOrder,
    );
  }
}

class RoundedLoadPlayer extends TestAudioPlayer {
  int roundingMs = 0;
  @override
  Future<Duration?> setAudioSources(
    List<AudioSource> sources, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
    ShuffleOrder? shuffleOrder,
  }) => super.setAudioSources(
    sources,
    preload: preload,
    initialIndex: initialIndex,
    initialPosition: initialPosition == null
        ? null
        : initialPosition + Duration(milliseconds: roundingMs),
    shuffleOrder: shuffleOrder,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Harness h;
  setUp(() async {
    h = Harness();
    h.backendTimeout = const Duration(milliseconds: 40);
    await h.open();
  });
  tearDown(() => h.close());

  Future<GatedControlsPlayer> controlsPlayer() async {
    await h.controller.shutdown();
    final player = GatedControlsPlayer();
    h.initialPlayerFactory = () => player;
    await h.restart();
    return player;
  }

  for (final roundingMs in [-1, 1]) {
    test(
      'decoder rounding by $roundingMs ms cannot discard a sleep rewind',
      () async {
        await h.controller.shutdown();
        final player = RoundedLoadPlayer();
        h.initialPlayerFactory = () => player;
        await h.restart();
        await h.controller.seek(const Duration(seconds: 30));
        await h.controller.play();
        h.controller.setSleepTimer(1);
        await h.expire();
        player.roundingMs = roundingMs;
        await h.controller.play();
        expect(h.controller.playing, true);
        expect(h.controller.position.inMilliseconds, 20000);
        expect((await h.progress()).locator.positionMs, 20000);
        expect(await h.controller.resumeStore.load('edition'), isNull);
      },
    );
  }

  for (final operation in ['seek', 'speed', 'play']) {
    test(
      'a rejected optimistic $operation cannot change the durable checkpoint or leave phantom playback',
      () async {
        final player = await controlsPlayer();
        if (operation == 'seek') {
          player.rejectSeek = true;
          await h.controller.seek(const Duration(seconds: 50));
        } else if (operation == 'speed') {
          player.rejectSpeed = true;
          await h.controller.setSpeed(2);
        } else {
          player.rejectPlay = true;
          await h.controller.play();
        }
        await h.controller.flushJournal();
        expect(h.controller.error, contains('rejected'));
        expect(h.controller.playing, false);
        expect(h.controller.speed, 1);
        expect(h.controller.position.inMilliseconds, 3000);
        expect((await h.progress()).locator.positionMs, 3000);
        await h.controller.play();
        expect(identical(player, h.player), false);
        expect(h.controller.playing, true);
        expect(h.controller.position.inMilliseconds, 3000);
      },
    );
  }

  test(
    'opening a different book does not first try to reload the broken book',
    () async {
      await h.repo.put('book', 'other', {'title': 'Other', 'format': 'audio'});
      await h.db.customStatement('INSERT INTO audio_editions VALUES(?,?,1)', [
        'other-edition',
        'other',
      ]);
      final source = (await h.assets.audioTracks('book')).first;
      final otherFile = File('${h.root.path}/other.mp3');
      await otherFile.writeAsBytes([73, 68, 51, 42]);
      await h.db.customStatement(
        'INSERT INTO local_assets VALUES(?,?,?,?,?,?)',
        [
          'other-track',
          'other',
          source.filename,
          otherFile.path,
          'other-hash',
          4,
        ],
      );
      await h.db.customStatement('INSERT INTO audio_resources VALUES(?,?,?)', [
        'other-hash',
        otherFile.path,
        4,
      ]);
      await h.db.customStatement(
        'INSERT INTO audio_tracks VALUES(?,?,?,?,?,?)',
        [
          'other-track',
          'other-edition',
          'other-hash',
          0,
          'Other track',
          100000,
        ],
      );
      h.player.errors.add(PlayerException(1, 'Disconnected', 1));
      h.replacementPlayerFactory = () => RejectOldBookPlayer();
      await h.controller.open(
        (await h.assets.audioTracks('other')).first,
        'Other',
      );
      expect(h.controller.current!.bookId, 'other');
      expect(h.controller.canPlay, true);
      expect(h.controller.error, isEmpty);
      await h.controller.play();
      expect(h.controller.playing, true);
    },
  );

  test(
    'Stop after a decoder failure does not reopen an unavailable source',
    () async {
      h.player.errors.add(PlayerException(1, 'Disconnected', 1));
      var replacements = 0;
      h.replacementPlayerFactory = () {
        replacements++;
        return RefusingPlayer();
      };
      await h.controller.stop();
      expect(replacements, 0);
      expect(h.controller.playing, false);
      expect(h.controller.canPlay, true);
      expect(h.controller.position.inMilliseconds, 3000);
    },
  );

  test(
    'idle decoder error after a paused seek keeps the newly selected position',
    () async {
      await h.controller.seek(const Duration(seconds: 60));
      h.player.processingState = ProcessingState.idle;
      h.player.position = Duration.zero;
      h.player.emit();
      h.player.errors.add(PlayerException(1001, 'Source disconnected', 1));
      await h.controller.play();
      expect(h.controller.position.inSeconds, 60);
      expect((await h.progress()).locator.positionMs, 60000);
    },
  );

  test(
    'unacknowledged speed is not persisted as a successful speed change',
    () async {
      final player = await controlsPlayer(), gate = Completer<void>();
      player.speedGate = gate;
      try {
        await h.controller.setSpeed(2);
        expect(h.controller.speed, 1);
        expect((await h.progress()).speed, 1);
        await h.controller.play();
        expect(h.controller.speed, 1);
      } finally {
        gate.complete();
      }
    },
  );

  test(
    'fade volume rejection is reported without an unhandled future',
    () async {
      final player = await controlsPlayer();
      await h.controller.play();
      player.rejectVolume = true;
      h.controller.setSleepTimer(1);
      h.now = h.now.add(const Duration(seconds: 50));
      h.timers.last.fire();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(h.controller.error, contains('громкость'));
      player.rejectVolume = false;
      h.controller.setSleepTimer(null);
    },
  );

  test('cancelling a fade wins over a late native volume answer', () async {
    final player = await controlsPlayer();
    await player.setVolume(.7);
    await h.controller.play();
    final gate = Completer<void>();
    player.volumeGate = gate;
    h.controller.setSleepTimer(1);
    h.now = h.now.add(const Duration(seconds: 50));
    h.timers.last.fire();
    h.controller.setSleepTimer(null);
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(player.volume, .7);
  });

  test('a blocked fade coalesces ticks and does not hold Pause', () async {
    final player = await controlsPlayer();
    await player.setVolume(.7);
    await h.controller.play();
    final before = player.volumeCalls, gate = Completer<void>();
    player.volumeGate = gate;
    try {
      h.controller.setSleepTimer(1);
      h.now = h.now.add(const Duration(seconds: 50));
      for (var i = 0; i < 20; i++) {
        h.timers.last.fire();
      }
      expect(player.volumeCalls - before, 1);
      await h.controller.pause().timeout(const Duration(milliseconds: 500));
      expect(gate.isCompleted, false);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await h.controller.play();
      expect(h.controller.playing, true);
      expect(h.player.volume, .7);
    } finally {
      gate.complete();
    }
  });

  test(
    'Stop after a fade timeout preserves the original volume for recovery',
    () async {
      final player = await controlsPlayer();
      await player.setVolume(.7);
      await h.controller.play();
      final gate = Completer<void>();
      player.volumeGate = gate;
      try {
        h.controller.setSleepTimer(1);
        h.now = h.now.add(const Duration(seconds: 50));
        h.timers.last.fire();
        await Future<void>.delayed(const Duration(milliseconds: 80));
        await h.controller.stop();
        expect(h.controller.sleepMode, 'off');
        await h.controller.play();
        expect(h.controller.playing, true);
        expect(h.player.volume, .7);
      } finally {
        gate.complete();
      }
    },
  );

  test(
    'Stop preserves position and system Play can reopen the released source',
    () async {
      await h.controller.play();
      await h.controller.setSpeed(1.5);
      h.player.at(1, 32000);
      await h.controller.systemHandler.stop();
      expect(h.controller.playing, false);
      expect(h.player.processingState, ProcessingState.idle);
      expect(h.controller.canPlay, true);
      expect(h.controller.position.inSeconds, 32);
      expect(h.controller.speed, 1.5);
      expect((await h.progress()).locator.positionMs, 32000);
      await h.controller.systemHandler.play();
      expect(h.controller.playing, true);
      expect(h.controller.trackIndex, 1);
      expect(h.controller.position.inSeconds, 32);
      expect(h.controller.speed, 1.5);
    },
  );

  test('backend timeout updates system playback state immediately', () async {
    await h.controller.play();
    final previous = h.player, gate = Completer<void>();
    previous.pauseGate = gate;
    try {
      expect(h.controller.playbackState.value.playing, true);
      await h.controller.pause();
      expect(h.controller.playbackState.value.playing, false);
      expect(h.controller.canPlay, true);
      expect(h.controller.position.inMilliseconds, 3000);
    } finally {
      gate.complete();
    }
  });

  test(
    'a failed backend recovery remains retryable from the original checkpoint',
    () async {
      await h.controller.play();
      final previous = h.player, gate = Completer<void>();
      previous.pauseGate = gate;
      var attempts = 0;
      h.replacementPlayerFactory = () =>
          ++attempts == 1 ? RefusingPlayer() : TestAudioPlayer();
      try {
        await h.controller.pause();
        await h.controller.play();
        expect(h.controller.error, contains('temporarily unavailable'));
        expect(h.controller.canPlay, true);
        expect(h.controller.position.inMilliseconds, 3000);
        await h.controller.play();
        expect(attempts, 2);
        expect(h.controller.playing, true);
        expect(h.controller.position.inMilliseconds, 3000);
        expect(h.controller.error, isEmpty);
      } finally {
        gate.complete();
      }
    },
  );

  test('decoder error stops system state and Play reloads from the audible position', () async {
    await h.controller.play();
    h.player.at(1, 42000);
    final previous = h.player;
    previous.errors.add(PlayerException(1001, 'Decoder failure', 1));
    // Wait for the persistence queue without issuing a playback command.
    await h.controller.flushJournal();
    expect(h.controller.playing, false);
    expect(h.controller.playbackState.value.playing, false);
    expect(h.controller.position.inSeconds, 42);
    await h.controller.play();
    expect(identical(previous, h.player), false);
    expect(h.controller.position.inSeconds, 42);
    expect(h.controller.playing, true);
  });

  test('shutdown pauses before a blocked duration scan finishes', () async {
    await h.controller.shutdown();
    await h.db.customStatement(
      "UPDATE audio_tracks SET duration_ms=NULL WHERE id='track0'",
    );
    final probe = GatedDurationProbe();
    h.durationProbeFactory = () => probe;
    await h.restart();
    await h.controller.play();
    final closing = h.controller.shutdown();
    try {
      for (var i = 0; i < 100 && h.player.playing; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(probe.gate.isCompleted, false);
      expect(h.player.playing, false);
    } finally {
      probe.gate.complete(const Duration(seconds: 100));
      await closing;
    }
  });

  test(
    'shutdown is idempotent and late commands cannot reopen a disposed decoder',
    () async {
      await h.controller.play();
      await h.controller.shutdown();
      final opens = h.player.opens;
      await h.controller.play();
      await h.controller.seek(const Duration(seconds: 60));
      await h.controller.pause();
      await h.controller.shutdown();
      expect(h.player.playing, false);
      expect(h.player.opens, opens);
    },
  );
}
