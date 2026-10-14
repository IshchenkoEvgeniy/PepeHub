import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/repository.dart' show uuid;
import 'models.dart';
import 'video_activity.dart';
import 'video_engine.dart';
import 'video_repository.dart';
import 'video_tools.dart';

class VideoPlaybackController extends ChangeNotifier {
  final VideoRepository repository;
  final VideoPlaybackEngine engine;
  final List<VideoLesson> lessons;
  final Future<void> Function()? beforePlaying;
  final Future<void> Function()? afterPaused;
  final Future<void> Function(VideoLesson)? configureLesson;
  final Future<void> Function(VideoLesson)? validateSource;
  final int Function() nowMonotonic;
  final DateTime Function() now;
  final Timer Function(Duration, void Function()) createSleepTimer;
  final VideoActivitySampler sampler = VideoActivitySampler();
  final Map<String, VideoInterval> _unwritten = {};
  String sessionId = uuid.v4();
  int? _inactiveSince;
  Future<void> _tail = Future.value();
  Future<void>? _closeFuture;
  Timer? _checkpointTimer;
  bool _transition = true,
      _foreground = true,
      _closed = false,
      _closing = false;
  bool _disposed = false, _lastCompleted = false;
  int _lastPosition = -1;
  bool _lastActive = false;
  int index = 0;
  VideoLesson? current;
  String? storageError;
  bool loading = false;
  VideoLoopSettings? loop;
  bool loopRunning = false, loopWaiting = false, _loopPending = false;
  bool _loopArmed = false;
  int loopCompletedPasses = 0, _loopEpoch = 0;
  Timer? _loopTimer;
  final List<VideoSeekEntry> _seekHistory = [];
  List<VideoSeekEntry> get seekHistory => List.unmodifiable(_seekHistory);
  double _unmutedVolume = 100;
  bool audioOnly = false, pipVisible = false;
  bool get _playAllowed => _foreground || pipVisible || audioOnly;
  Timer? _sleepTimer;
  int? _sleepDeadline;
  int _sleepEpoch = 0;
  String? _sleepEndLesson;
  int? get sleepRemainingMs => _sleepDeadline == null
      ? null
      : (_sleepDeadline! - nowMonotonic()).clamp(0, 86400000);
  bool get sleepAtLessonEnd => _sleepEndLesson != null;

  VideoPlaybackController({
    required this.repository,
    required this.engine,
    required this.lessons,
    this.beforePlaying,
    this.afterPaused,
    this.configureLesson,
    this.validateSource,
    int Function()? nowMonotonic,
    DateTime Function()? now,
    Timer Function(Duration, void Function())? createSleepTimer,
    Duration? checkpointPeriod = const Duration(seconds: 10),
  }) : nowMonotonic =
           nowMonotonic ?? (Stopwatch()..start()).elapsedMillisecondsNow,
       now = now ?? DateTime.now,
       createSleepTimer = createSleepTimer ?? Timer.new {
    engine.addListener(_engineChanged);
    if (checkpointPeriod != null) {
      _checkpointTimer = Timer.periodic(checkpointPeriod, (_) {
        if (!_closed && !_closing && current != null && !loading) {
          unawaited(flush().catchError((Object _) {}));
        }
      });
    }
  }

  VideoEngineState get state => engine.state;
  bool get active =>
      !_transition &&
      _playAllowed &&
      !_closed &&
      state.playing &&
      !state.buffering &&
      !state.completed &&
      state.error == null;
  int get positionMs => state.completed && state.durationMs > 0
      ? state.durationMs
      : state.positionMs;
  String? get error =>
      storageError ??
      (state.error == null
          ? null
          : 'Не удалось воспроизвести источник. Проверьте файл или ссылку.');

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _sample() {
    final lesson = current;
    if (lesson == null || _closed) return;
    final repeat = loop;
    if (loopRunning &&
        !loopWaiting &&
        active &&
        repeat != null &&
        positionMs >= repeat.startMs &&
        positionMs < repeat.endMs &&
        positionMs - repeat.startMs <= (repeat.endMs - repeat.startMs) ~/ 2) {
      _loopArmed = true;
    }
    if (active && !_lastActive) _resumeSession();
    if (!active && _lastActive) _inactiveSince ??= nowMonotonic();
    if (_lastPosition == positionMs && _lastActive == active) return;
    for (final interval in sampler.sample(
      sessionId: sessionId,
      lessonId: lesson.id,
      mediaVersion: lesson.mediaVersion,
      positionMs: positionMs,
      monotonicMs: nowMonotonic(),
      at: now(),
      speed: state.speed,
      active: active,
      mode: audioOnly ? VideoActivityMode.audio : VideoActivityMode.visual,
    )) {
      _unwritten[interval.id] = interval;
    }
    _lastPosition = positionMs;
    _lastActive = active;
  }

  void _resumeSession() {
    final inactive = _inactiveSince;
    if (inactive != null &&
        nowMonotonic() - inactive > const Duration(minutes: 5).inMilliseconds) {
      sessionId = uuid.v4();
    }
    _inactiveSince = null;
  }

  Future<void> _event(
    VideoLesson lesson,
    String kind,
    int position, {
    Map<String, dynamic> extra = const {},
  }) => repository.event(
    lesson,
    kind,
    position,
    at: now(),
    extra: {'sessionId': sessionId, ...extra},
  );

  void _boundary() {
    _sample();
    sampler.reset();
    _lastPosition = -1;
    _lastActive = false;
  }

  void _engineChanged() {
    if (_closed || _disposed) return;
    if (!_transition) _sample();
    final repeat = loop;
    if (!_transition &&
        loopRunning &&
        !loopWaiting &&
        _loopArmed &&
        !_loopPending &&
        _playAllowed &&
        repeat != null &&
        state.error == null &&
        !state.buffering &&
        (state.playing || state.completed) &&
        positionMs >= repeat.endMs) {
      final epoch = _loopEpoch;
      _loopPending = true;
      _loopArmed = false;
      unawaited(
        _command(() => _advanceLoop(epoch))
            .catchError((Object _) {
              _stopLoop();
              _notify();
            })
            .whenComplete(() {
              if (_loopEpoch == epoch) _loopPending = false;
            }),
      );
    }
    if (!_transition &&
        !loopRunning &&
        state.completed &&
        !_lastCompleted &&
        current != null) {
      final lesson = current!,
          position = positionMs,
          at = now(),
          session = sessionId;
      unawaited(
        _command(() async {
          await _persist();
          if (_sleepEndLesson == '${lesson.id}:${lesson.mediaVersion}') {
            _cancelSleep();
            await _pause();
          }
          await repository.event(
            lesson,
            'end',
            position,
            at: at,
            extra: {'sessionId': session},
          );
        }).catchError((Object _) {}),
      );
    }
    _lastCompleted = state.completed;
    _notify();
  }

  Future<void> _command(Future<void> Function() action) {
    if (_closed || _closing) return Future.value();
    return _enqueue(action);
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final operation = _tail.then((_) => action());
    _tail = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        storageError =
            'Не удалось выполнить действие или сохранить видео: $error';
        _notify();
      },
    );
    return operation;
  }

  Future<void> load(int nextIndex, {bool play = true}) =>
      _command(() => _load(nextIndex, play: play));
  Future<void> next() => _command(() => _load(index + 1));
  Future<void> previous() => _command(() => _load(index - 1));
  Future<void> _load(int nextIndex, {bool play = true}) async {
    if (nextIndex < 0 || nextIndex >= lessons.length) return;
    if (!lessons[nextIndex].available) {
      throw StateError(
        'Урок недоступен. Обновите или переподключите папку курса',
      );
    }
    _stopLoop(clear: true);
    _seekHistory.clear();
    _boundary();
    _transition = true;
    loading = true;
    _notify();
    try {
      if (current != null) {
        await engine.pause();
        await _persist();
      }
      final lesson = lessons[nextIndex];
      final saved = await repository.progress(lesson);
      // Clear the old lesson before opening, so a failed open cannot save the
      // new engine's position as progress for the previous lesson.
      current = null;
      index = nextIndex;
      await validateSource?.call(lesson);
      await engine.open(
        lesson,
        positionMs: saved?.positionMs ?? 0,
        speed: saved?.speed ?? 1,
      );
      current = lesson;
      if (audioOnly) await engine.setAudioOnly(true);
      if (_sleepEndLesson != null &&
          _sleepEndLesson != '${lesson.id}:${lesson.mediaVersion}') {
        _cancelSleep();
      }
      await configureLesson?.call(lesson);
      _lastCompleted = false;
      storageError = null;
      if (play && _playAllowed) {
        await beforePlaying?.call();
        await engine.play();
      }
      await _event(lesson, 'open', positionMs);
    } finally {
      loading = false;
      _transition = false;
      _boundary();
      _sample();
      _notify();
    }
  }

  Future<void> toggle() => _command(() => state.playing ? _pause() : _play());
  Future<void> play() => _command(_play);
  Future<void> _play() async {
    if (current == null || !_playAllowed) return;
    if (loopWaiting) _stopLoop();
    await beforePlaying?.call();
    _boundary();
    _transition = true;
    try {
      if (state.completed) await engine.seek(0);
      await engine.play();
    } finally {
      _transition = false;
      _boundary();
    }
    _sample();
    await _event(current!, 'play', positionMs);
    _notify();
  }

  Future<void> pause() => _command(_pause);
  Future<void> _pause() async {
    _stopLoop();
    await _pausePlayback();
  }

  Future<void> _pausePlayback() async {
    _boundary();
    _transition = true;
    try {
      await engine.pause();
      _inactiveSince ??= nowMonotonic();
      await afterPaused?.call();
      await _persist();
      if (current != null) {
        await _event(current!, 'pause', positionMs);
      }
    } finally {
      _transition = false;
      _sample();
      _notify();
    }
  }

  Future<void> seek(int targetMs) => _command(() => _seek(targetMs));
  Future<void> _seek(
    int targetMs, {
    String reason = 'user',
    bool stopLoop = true,
    bool remember = true,
  }) async {
    if (current == null) return;
    if (stopLoop) _stopLoop();
    final target = state.durationMs > 0
        ? targetMs.clamp(0, state.durationMs)
        : targetMs.clamp(0, 1 << 53);
    final from = positionMs;
    _boundary();
    _transition = true;
    try {
      // Persist the preceding interval before a discontinuity moves the clock.
      await _persist();
      await engine.seek(target);
      if (remember && target != from) {
        _seekHistory.add(VideoSeekEntry(from, target));
        if (_seekHistory.length > 50) _seekHistory.removeAt(0);
      }
      await _event(
        current!,
        'seek',
        target,
        extra: {'fromMs': from, 'toMs': target, 'reason': reason},
      );
      await _persist();
    } finally {
      _transition = false;
      _boundary();
      _sample();
      _notify();
    }
  }

  Future<void> skip(int milliseconds) =>
      _command(() => _seek(positionMs + milliseconds));
  Future<void> setSpeed(double speed) => _command(() async {
    if (!speed.isFinite || speed < .5 || speed > 3) {
      throw ArgumentError('Скорость: 0,5–3×');
    }
    _boundary();
    _transition = true;
    try {
      await _persist();
      await engine.setSpeed(speed);
      if (current != null) {
        await _event(current!, 'speed', positionMs, extra: {'speed': speed});
      }
      await _persist();
    } finally {
      _transition = false;
      _boundary();
      _sample();
      _notify();
    }
  });

  Future<void> setVolume(double volume) =>
      _command(() => engine.setVolume(volume.clamp(0, 100)));

  /// Presentation changes share the playback queue and never apply to a lesson
  /// that was replaced while an import dialog or settings save was pending.
  Future<bool> changePresentation(
    VideoLesson lesson,
    Future<void> Function() change,
  ) async {
    var applied = false;
    await _command(() async {
      if (current?.id != lesson.id ||
          current?.mediaVersion != lesson.mediaVersion) {
        return;
      }
      _boundary();
      _transition = true;
      try {
        await _persist();
        await change();
        applied = true;
      } finally {
        _transition = false;
        _boundary();
        _sample();
        _notify();
      }
    });
    return applied;
  }

  Future<void> adjustVolume(double delta) =>
      _command(() => engine.setVolume((state.volume + delta).clamp(0, 100)));
  Future<void> toggleMute() => _command(() async {
    if (state.volume > 0) {
      _unmutedVolume = state.volume.clamp(1, 100);
      await engine.setVolume(0);
    } else {
      await engine.setVolume(_unmutedVolume);
    }
  });

  Future<void> returnFromSeek() => _command(() async {
    if (_seekHistory.isEmpty) return;
    final previous = _seekHistory.last;
    await _seek(previous.fromMs, reason: 'undo', remember: false);
    _seekHistory.removeLast();
  });

  void _stopLoop({bool clear = false}) {
    _loopEpoch++;
    _loopTimer?.cancel();
    _loopTimer = null;
    loopRunning = loopWaiting = _loopPending = _loopArmed = false;
    if (clear) {
      loop = null;
      loopCompletedPasses = 0;
    }
  }

  Future<void> startLoop(VideoLoopSettings settings) => _command(() async {
    settings.validate(durationMs: state.durationMs);
    if (current == null || !_playAllowed) return;
    _stopLoop();
    loop = settings;
    loopCompletedPasses = 0;
    await _seek(
      settings.startMs,
      reason: 'loop-start',
      stopLoop: false,
      remember: false,
    );
    loopRunning = true;
    try {
      await _play();
      await _event(
        current!,
        'loop-start',
        positionMs,
        extra: {
          'startMs': settings.startMs,
          'endMs': settings.endMs,
          'totalPasses': settings.totalPasses,
          'pauseMs': settings.pauseMs,
        },
      );
    } catch (_) {
      _stopLoop();
      rethrow;
    }
    _notify();
  });

  Future<void> stopLoop() => _command(() async {
    _stopLoop();
    _notify();
  });

  Future<void> _advanceLoop(int epoch) async {
    final repeat = loop;
    if (_loopEpoch != epoch ||
        !loopRunning ||
        !_playAllowed ||
        repeat == null) {
      return;
    }
    await _pausePlayback();
    if (_loopEpoch != epoch || !loopRunning || !_playAllowed || _closing) {
      return;
    }
    loopCompletedPasses++;
    await _event(
      current!,
      'loop-pass',
      positionMs,
      extra: {'pass': loopCompletedPasses},
    );
    if (repeat.totalPasses != null &&
        loopCompletedPasses >= repeat.totalPasses!) {
      _stopLoop();
      if (positionMs != repeat.endMs) {
        await _seek(repeat.endMs, reason: 'loop-end', remember: false);
      }
      _notify();
      return;
    }
    if (repeat.pauseMs > 0) {
      loopWaiting = true;
      _loopTimer = Timer(Duration(milliseconds: repeat.pauseMs), () {
        unawaited(
          _command(() => _resumeLoop(epoch)).catchError((Object _) {
            _stopLoop();
            _notify();
          }),
        );
      });
      _notify();
    } else {
      await _resumeLoop(epoch);
    }
  }

  Future<void> _resumeLoop(int epoch) async {
    final repeat = loop;
    if (_loopEpoch != epoch ||
        !loopRunning ||
        !_playAllowed ||
        repeat == null ||
        _closing) {
      return;
    }
    loopWaiting = false;
    _loopArmed = false;
    await _seek(
      repeat.startMs,
      reason: 'loop-repeat',
      stopLoop: false,
      remember: false,
    );
    await _play();
    _notify();
  }

  Future<void> setForeground(bool visible, {bool pauseHidden = true}) {
    if (_closed || _closing) return Future.value();
    _boundary();
    _foreground = visible;
    if (!visible) _inactiveSince ??= nowMonotonic();
    _sample();
    return _command(() async {
      if (pauseHidden && !_playAllowed) await _pause();
      _sample();
      _notify();
    });
  }

  Future<void> setAudioOnly(bool enabled) => _command(() async {
    if (audioOnly == enabled) return;
    _boundary();
    await _persist();
    _transition = true;
    try {
      await engine.setAudioOnly(enabled);
      audioOnly = enabled;
      if (!_playAllowed) await _pause();
      if (current != null) {
        await _event(
          current!,
          'mode',
          positionMs,
          extra: {'mode': enabled ? 'audio' : 'visual'},
        );
      }
    } finally {
      _transition = false;
      _boundary();
      _sample();
      _notify();
    }
  });

  Future<void> setPipVisible(bool visible) => _command(() async {
    if (pipVisible == visible) return;
    _boundary();
    await _persist();
    pipVisible = visible;
    if (!_playAllowed) await _pause();
    _sample();
    _notify();
  });

  void _cancelSleep() {
    _sleepEpoch++;
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepDeadline = null;
    _sleepEndLesson = null;
  }

  Future<void> setSleepTimer(
    Duration? duration, {
    bool untilLessonEnd = false,
  }) => _command(() async {
    if (duration != null &&
        (duration < const Duration(seconds: 1) ||
            duration > const Duration(hours: 24))) {
      throw ArgumentError('Таймер: от 1 секунды до 24 часов');
    }
    _cancelSleep();
    if (untilLessonEnd && current != null) {
      _sleepEndLesson = '${current!.id}:${current!.mediaVersion}';
    }
    if (duration != null) {
      _sleepDeadline = nowMonotonic() + duration.inMilliseconds;
      final epoch = _sleepEpoch;
      _sleepTimer = createSleepTimer(
        duration,
        () => unawaited(
          _command(() async {
            if (epoch != _sleepEpoch) return;
            _cancelSleep();
            await _pause();
          }).catchError((Object _) {}),
        ),
      );
    }
    _notify();
  });

  Future<void> _persist() async {
    final lesson = current;
    if (lesson == null) return;
    final pending = _unwritten.values.toList();
    await repository.checkpoint(
      lesson: lesson,
      progress: VideoProgress(
        lessonId: lesson.id,
        mediaVersion: lesson.mediaVersion,
        positionMs: positionMs.clamp(0, 1 << 53),
        speed: state.speed,
        updatedAt: now(),
      ),
      intervals: pending,
      durationMs: state.durationMs > 0 ? state.durationMs : null,
    );
    for (final interval in pending) {
      if (identical(_unwritten[interval.id], interval)) {
        _unwritten.remove(interval.id);
      }
    }
    storageError = null;
  }

  Future<void> flush() => _command(() async {
    _sample();
    await _persist();
  });

  Future<void> close() {
    if (_closed) return Future.value();
    final previous = _closeFuture;
    if (previous != null) return previous;
    _closing = true;
    _cancelSleep();
    _stopLoop(clear: true);
    _checkpointTimer?.cancel();
    final operation = _enqueue(() async {
      _boundary();
      _transition = true;
      await engine.pause();
      await _persist();
      if (current != null) {
        await _event(current!, 'close', positionMs);
      }
      engine.removeListener(_engineChanged);
      await engine.close();
      _closed = true;
    });
    _closeFuture = operation.then<void>(
      (_) {},
      onError: (Object e, StackTrace s) {
        _closing = false;
        _closeFuture = null;
        _transition = false;
        Error.throwWithStackTrace(e, s);
      },
    );
    return _closeFuture!;
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelSleep();
    _stopLoop(clear: true);
    _checkpointTimer?.cancel();
    super.dispose();
  }
}

extension on Stopwatch {
  int elapsedMillisecondsNow() => elapsedMilliseconds;
}
