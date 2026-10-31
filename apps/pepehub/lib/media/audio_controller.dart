import '../audio/book_timeline.dart';
import '../audio/audio_journal.dart';
import '../audio/m4b_chapters.dart';
import '../audio/audio_sidecar.dart';
import '../audio/audio_resume.dart';

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import '../data/repository.dart';
import '../audio/audio_library_repository.dart';
import '../audio/models.dart';
import '../audio/audio_folder.dart';
import 'asset_store.dart';
import 'audio_artwork.dart';
import 'listening_clock.dart';
import 'shared_media_handler.dart';
import 'audio_focus.dart';

class AudioController extends BaseAudioHandler with ChangeNotifier {
  final AssetStore assets;
  AudioPlayer _player;
  AudioPlayer get player => _player;
  final AudioPlayer Function()? playerFactory;
  final Duration backendTimeout;
  final AudioSidecarWriter? sidecarWriter;
  final List<StreamSubscription<dynamic>> _playerSubscriptions = [];
  bool _backendUnresponsive = false;
  AudioProgress? _commandCheckpoint, _recoveryProgress, _lastObservedProgress;
  final DateTime Function() now;
  final AudioPlayer Function()? probeFactory;
  final Timer Function(Duration, void Function(Timer)) periodic;
  final int Function()? elapsedMilliseconds;
  int get _elapsedMs =>
      elapsedMilliseconds?.call() ?? monotonic.elapsedMilliseconds;
  late final systemHandler = SharedMediaHandler(this);
  Future<void> Function()? beforeBookPlayback;
  final Stopwatch monotonic = Stopwatch()..start();
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  List<LocalAsset> _tracks = [];
  final Map<String, Duration> _durations = {};
  int _activeIndex = 0;
  List<LocalAsset> get tracks => UnmodifiableListView(_tracks);
  int get trackIndex => _activeIndex;
  LocalAsset? get current => _activeIndex >= 0 && _activeIndex < _tracks.length
      ? _tracks[_activeIndex]
      : null;
  BookTimeline get timeline =>
      BookTimeline([for (final t in _tracks) _durations[t.id]?.inMilliseconds]);
  Duration? get bookDuration => timeline.totalMs == null
      ? null
      : Duration(milliseconds: timeline.totalMs!);
  Duration? get bookPosition {
    final value = timeline.positionMs(_activeIndex, position.inMilliseconds);
    return value == null ? null : Duration(milliseconds: value);
  }

  Duration? trackDuration(String id) => _durations[id];
  double? get bookFraction => bookDuration == null || bookPosition == null
      ? null
      : (bookPosition!.inMilliseconds / bookDuration!.inMilliseconds).clamp(
          0,
          1,
        );
  Duration? get remainingAtSpeed => bookDuration == null || bookPosition == null
      ? null
      : Duration(
          milliseconds:
              ((bookDuration! - bookPosition!).inMilliseconds.clamp(
                        0,
                        1 << 60,
                      ) /
                      speed)
                  .round(),
        );
  bool scanningDurations = false;
  String durationError = '';
  int get knownDurations =>
      _tracks.where((t) => _durations.containsKey(t.id)).length;
  int _durationGeneration = 0;
  Future<void> _durationWork = Future.value();

  /// A silent, independent decoder never seeks or pauses the playback queue.
  Future<void> scanDurations() {
    final generation = ++_durationGeneration;
    final tracks = List<LocalAsset>.of(_tracks);
    _durationWork = _durationWork
        .then((_) async {
          if (_closed || generation != _durationGeneration) return;
          scanningDurations = true;
          durationError = '';
          _notify();
          final probe =
              probeFactory?.call() ??
              AudioPlayer(
                handleInterruptions: false,
                handleAudioSessionActivation: false,
              );
          final failures = <String>[];
          try {
            for (final track in tracks) {
              if (_closed || generation != _durationGeneration) break;
              if ((_durations[track.id] ?? Duration.zero) > Duration.zero) {
                continue;
              }
              try {
                final length = await probe
                    .setAudioSource(AudioSource.uri(audioSourceUri(track.path)))
                    .timeout(const Duration(seconds: 12));
                if (_closed || generation != _durationGeneration) break;
                if (length == null || length <= Duration.zero) {
                  failures.add(track.filename);
                } else {
                  await audioLibrary.saveDuration(track.id, length);
                  if (_closed || generation != _durationGeneration) break;
                  _durations[track.id] = length;
                  _notify();
                }
              } catch (_) {
                failures.add(track.filename);
              }
            }
          } finally {
            await probe
                .dispose()
                .timeout(const Duration(seconds: 1))
                .catchError((Object _) {});
            if (!_closed && generation == _durationGeneration) {
              scanningDurations = false;
              durationError = failures.isEmpty
                  ? ''
                  : 'Не определена длительность файлов: ${failures.length}. Можно повторить проверку.';
              _notify();
            }
          }
        })
        .catchError((Object e) {
          if (!_closed && generation == _durationGeneration) {
            scanningDurations = false;
            durationError = 'Не удалось проверить длительности: $e';
            _notify();
          }
        });
    return _durationWork;
  }

  Future<void> seekBook(Duration target) => _command(() async {
    final location = timeline.locate(target.inMilliseconds);
    if (location != null) {
      await _seekTo(
        location.$1,
        Duration(milliseconds: location.$2),
        reason: 'book_timeline',
      );
    }
  });

  Future<void> _commands = Future.value();
  Future<void> _command(
    Future<void> Function() action, {
    bool duringShutdown = false,
    bool recoverBackend = true,
  }) {
    final next = _commands.then((_) async {
      if (_closed && !duringShutdown) return;
      if (_backendUnresponsive && !_closed && recoverBackend) {
        await _recoverBackend();
      }
      _commandCheckpoint = _locator == null || current == null
          ? null
          : AudioProgress(_currentLocator(), speed);
      await action();
    });
    _commands = next.catchError((Object e) {
      error = '$e';
      if (!_closed) _notify();
    });
    return _commands;
  }

  AudioLocator? _locator;
  String? get progressEditionId => _locator?.editionId;
  late final AudioLibraryRepository audioLibrary = AudioLibraryRepository(
    assets.repository.db,
  );
  String title = '', error = '';
  Uri? artwork;
  bool loading = false,
      _seeking = false,
      _loadingSource = false,
      _ready = false;
  late final sidecar = sidecarWriter ?? AudioSidecarWriter(assets);
  String sidecarError = '';
  late final journal = AudioJournal(assets.repository);
  final sampler = ListeningSampler();
  Future<void> _journalWrites = Future.value();
  final List<Future<void> Function()> _journalPending = [];
  List<BookChapter> chapters = [];
  String? _chapterTrack;
  String chapterError = '';
  bool _closed = false;
  Future<void>? _shutdownWork;
  final ValueNotifier<Duration> playbackPosition = ValueNotifier(Duration.zero);
  void _notify() {
    if (!_closed) {
      playbackPosition.value = position;
      notifyListeners();
    }
  }

  String? _loggedState;
  String sleepMode = 'off';
  int? _sleepPosition;
  String? _sleepTrack;
  double? _sleepVolume;
  (AudioPlayer, double)? _pendingSleepVolume;
  Future<void> _volumeWrites = Future.value();
  bool _writingVolume = false;
  double? _requestedSleepVolume;
  bool _sleepFiring = false, _sleepStopped = false;
  bool sleepFade = true, sleepRewind = true;
  bool resumeAfterInterruption = false;
  int sleepRewindSeconds = 10;
  AudioRewindSettings rewindSettings = const AudioRewindSettings();
  late final resumeStore = AudioResumeStore(assets.repository);
  AudioProgress? _parkedProgress;
  bool _wasPlaying = false;
  bool _interrupted = false, _resumeAfterInterruption = false;
  AudioInterruptionType? _interruptionType;
  int _interruptionGeneration = 0;
  int _sleepGeneration = 0;
  int? _sleepDeadlineMs;
  Timer? _checkpointTimer, _sleepTimer;
  DateTime? sleepUntil;
  ListeningClock? _clock;
  DateTime? _sessionStart;
  String? _sessionId;
  Future<void> _writes = Future.value();
  final List<Future<void> Function()> _pendingWrites = [];
  AudioController(
    this.assets,
    AudioPlayer player, {
    this.playerFactory,
    this.backendTimeout = const Duration(seconds: 3),
    this.sidecarWriter,
    DateTime Function()? now,
    this.probeFactory,
    this.elapsedMilliseconds,
    Timer Function(Duration, void Function(Timer))? periodic,
  }) : _player = player,
       now = now ?? DateTime.now,
       periodic = periodic ?? Timer.periodic {
    _attachPlayer();
    _checkpointTimer = this.periodic(
      const Duration(seconds: 10),
      (_) => unawaited(_persist()),
    );
  }

  void _attachPlayer() {
    final attached = player;
    bool currentPlayer() =>
        identical(attached, player) && !_backendUnresponsive && !_closed;
    _playerSubscriptions.add(
      player.playerStateStream.listen((state) {
        if (currentPlayer()) _stateChanged(state);
      }),
    );
    _playerSubscriptions.add(
      player.positionStream.listen((_) {
        if (!currentPlayer()) return;
        _observePosition();
        _sampleTelemetry();
        playbackPosition.value = position;
      }),
    );
    _playerSubscriptions.add(
      player.playbackEventStream.listen((event) {
        if (!currentPlayer()) return;
        if (_loadingSource || !_ready) return;
        final index = event.currentIndex;
        if (index == null || index < 0 || index >= _tracks.length) return;
        final changed = index != _activeIndex;
        if (changed && !_seeking && index == _activeIndex + 1 && playing) {
          _log('chapter_completed', {
            'trackId': _tracks[_activeIndex].id,
            'positionMs':
                _durations[_tracks[_activeIndex].id]?.inMilliseconds ??
                position.inMilliseconds,
          });
        }
        _activeIndex = index;
        final durationChanged =
            event.duration != null &&
            _durations[_tracks[index].id] != event.duration;
        if (event.duration != null) {
          _rememberDuration(_tracks[index].id, event.duration!);
        }
        if (changed) _log('track_changed');
        if (changed || durationChanged) _publishTrack();
        _publishState(player.playerState);
        if (changed && !_seeking) unawaited(_persist());
        if (changed || durationChanged) _notify();
      }),
    );
    _playerSubscriptions.add(
      player.errorStream.listen((e) {
        if (!currentPlayer()) return;
        error = 'Не удалось воспроизвести файл: ${e.message}';
        _retireBackend(_captureRecoveryProgress(), 'error', {
          'code': e.code.toString(),
        });
      }),
    );
  }

  AudioProgress? _captureRecoveryProgress() {
    if (_loadingSource || _seeking) return _commandCheckpoint;
    final observed = _lastObservedProgress;
    if (player.processingState == ProcessingState.idle &&
        observed?.locator.trackId == current?.id) {
      return observed;
    }
    return _locator == null || current == null
        ? null
        : AudioProgress(_currentLocator(), speed);
  }

  void _observePosition() {
    if (_ready &&
        !_loadingSource &&
        !_seeking &&
        !_backendUnresponsive &&
        _locator != null &&
        current != null &&
        (player.processingState == ProcessingState.ready ||
            player.processingState == ProcessingState.completed)) {
      _lastObservedProgress = AudioProgress(_currentLocator(), speed);
    }
  }

  void _retireBackend(
    AudioProgress? saved,
    String kind,
    Map<String, dynamic> details,
  ) {
    if (_backendUnresponsive) return;
    _sampleTelemetry(audible: false);
    _clock?.setAudible(false);
    _recoveryProgress = saved;
    _backendUnresponsive = true;
    _log(kind, details);
    unawaited(_persist(finish: true));
    final stuck = player;
    unawaited(
      stuck
          .stop()
          .timeout(const Duration(seconds: 1))
          .catchError((Object _) {}),
    );
    _publishState(player.playerState);
  }

  Future<T> _native<T>(
    String operation,
    Future<T> Function() run, {
    Duration? timeout,
  }) async {
    if (_backendUnresponsive) {
      throw StateError(
        'Аудиодвижок не отвечает. Повторите действие для восстановления.',
      );
    }
    try {
      return await run().timeout(timeout ?? backendTimeout);
    } on TimeoutException {
      _retireBackend(_commandCheckpoint, 'backend_timeout', {
        'operation': operation,
      });
      throw TimeoutException(
        'Аудиодвижок не ответил. Повторите действие: плеер восстановится с сохранённой позиции.',
      );
    } catch (e) {
      // just_audio updates position/speed/playing optimistically before its
      // native Future completes. A rejected command cannot be saved as success.
      _retireBackend(_commandCheckpoint, 'backend_error', {
        'operation': operation,
        'errorType': e.runtimeType.toString(),
      });
      rethrow;
    }
  }

  Future<void> _recoverBackend({bool restorePrevious = true}) async {
    final saved = restorePrevious ? _recoveryProgress : null;
    await _writes;
    final old = player;
    final restoredVolume = _sleepVolume ?? _requestedSleepVolume ?? old.volume;
    for (final subscription in _playerSubscriptions) {
      await subscription.cancel();
    }
    _playerSubscriptions.clear();
    // A late answer from the abandoned decoder cannot change the new player.
    unawaited(
      old
          .dispose()
          .timeout(const Duration(seconds: 1))
          .catchError((Object _) {}),
    );
    _player = playerFactory?.call() ?? AudioPlayer(handleInterruptions: false);
    _backendUnresponsive = false;
    if (!restorePrevious) _recoveryProgress = null;
    _attachPlayer();
    _ready = false;
    _loadingSource = true;
    loading = true;
    if (!_closed) _notify();
    try {
      if (saved != null && _tracks.isNotEmpty) {
        final index = _tracks.indexWhere(
          (track) => track.id == saved.locator.trackId,
        );
        if (index < 0) throw StateError('Трек для восстановления не найден');
        _commandCheckpoint = saved;
        await _native(
          'reload',
          () => player.setAudioSources(
            [
              for (final track in _tracks)
                AudioSource.uri(audioSourceUri(track.path)),
            ],
            initialIndex: index,
            initialPosition: Duration(milliseconds: saved.locator.positionMs),
          ),
          timeout: const Duration(seconds: 12),
        );
        await _native('speed', () => player.setSpeed(saved.speed));
        await _native('volume', () => player.setVolume(restoredVolume));
        _activeIndex = index;
        _locator = saved.locator;
        _sleepStopped = false;
        _parkedProgress = null;
        _ready = true;
        _recoveryProgress = null;
        error = '';
        _publishTrack();
        _publishState(player.playerState);
      }
    } catch (_) {
      // A failed replacement must not strand the screen with a disabled Play.
      // Retain the original checkpoint for another explicit retry.
      _recoveryProgress = saved;
      _backendUnresponsive = true;
      _ready = false;
      _publishState(player.playerState);
      rethrow;
    } finally {
      _loadingSource = false;
      loading = false;
      if (!_closed) _notify();
    }
  }

  static Future<AudioController> create(AssetStore assets) async {
    if (Platform.isWindows) {
      JustAudioMediaKit.ensureInitialized(windows: true, linux: false);
      JustAudioMediaKit.protocolWhitelist = const [
        'file',
        'http',
        'https',
        'tcp',
        'tls',
      ];
      JustAudioMediaKit.title = 'PepeHub';
    }
    final controller = AudioController(
      assets,
      AudioPlayer(handleInterruptions: false),
    );
    await controller.loadPlaybackPreferences();
    if (Platform.isAndroid) {
      await AudioService.init<SharedMediaHandler>(
        builder: () => controller.systemHandler,
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'app.pepehub.audio',
          androidNotificationChannelName: 'Медиа PepeHub',
          androidNotificationOngoing: false,
          androidStopForegroundOnPause: false,
          androidNotificationIcon: 'drawable/ic_audio_notification',
          notificationColor: Color(0xFF216B54),
          artDownscaleWidth: 512,
          artDownscaleHeight: 512,
          rewindInterval: Duration(seconds: 15),
          fastForwardInterval: Duration(seconds: 15),
        ),
      );
      final session = await AudioSession.instance;
      await session.configure(spokenAudioConfiguration);
      controller._subscriptions.add(
        session.interruptionEventStream.listen(
          (event) => unawaited(controller.handleInterruption(event)),
        ),
      );
      controller._subscriptions.add(
        session.becomingNoisyEventStream.listen((_) {
          if (identical(controller.systemHandler.owner, controller)) {
            unawaited(controller.pause());
          }
        }),
      );
    }
    return controller;
  }

  Future<void> loadPlaybackPreferences() async {
    final raw = await assets.repository.meta('audio-sleep-settings');
    if (raw == null) return;
    try {
      final settings = jsonDecode(raw) as Map;
      sleepFade = settings['fade'] != false;
      sleepRewind = settings['rewind'] != false;
      final seconds = settings['rewindSeconds'];
      sleepRewindSeconds = seconds is int && seconds > 0 && seconds <= 300
          ? seconds
          : 10;
      rewindSettings = AudioRewindSettings.fromJson(settings['resume']);
      resumeAfterInterruption = settings['resumeAfterInterruption'] == true;
    } catch (_) {
      /* Preserve readable defaults if older preferences are damaged. */
    }
  }

  Future<void> chooseArtwork() async {
    final book = current?.bookId;
    if (book == null) return;
    try {
      final selected = await ArtworkStore(assets).choose(book);
      if (selected != null && current?.bookId == book) {
        artwork = selected;
        _publishTrack();
        _notify();
      }
    } catch (e) {
      error = 'Обложка: $e';
      _notify();
    }
  }

  bool get playing =>
      !_backendUnresponsive &&
      player.playing &&
      player.processingState != ProcessingState.completed;
  bool get canPlay =>
      !_closed &&
      (_ready ||
          _sleepStopped ||
          _backendUnresponsive && _recoveryProgress != null) &&
      !loading;
  Duration get position => _backendUnresponsive && _recoveryProgress != null
      ? Duration(milliseconds: _recoveryProgress!.locator.positionMs)
      : _sleepStopped && _parkedProgress != null
      ? Duration(milliseconds: _parkedProgress!.locator.positionMs)
      : player.processingState == ProcessingState.completed
      ? (_durations[current?.id] ?? player.duration ?? player.position)
      : _ready &&
            !_loadingSource &&
            player.processingState == ProcessingState.idle &&
            _lastObservedProgress != null &&
            _lastObservedProgress!.locator.trackId == current?.id
      ? Duration(milliseconds: _lastObservedProgress!.locator.positionMs)
      : player.position;
  Duration get duration => _sleepStopped || _backendUnresponsive
      ? _durations[current?.id] ?? Duration.zero
      : player.duration ?? Duration.zero;
  double get speed => _backendUnresponsive && _recoveryProgress != null
      ? _recoveryProgress!.speed
      : _sleepStopped
      ? _parkedProgress?.speed ?? player.speed
      : player.speed;
  void _rememberDuration(String trackId, Duration value) {
    if (value <= Duration.zero || _durations[trackId] == value) return;
    _durations[trackId] = value;
    unawaited(
      audioLibrary.saveDuration(trackId, value).catchError((Object e) {
        error = 'Не удалось сохранить длительность: $e';
        _notify();
      }),
    );
  }

  void _publishTrack() {
    final asset = current;
    if (asset == null) return;
    _observePosition();
    if (_chapterTrack != asset.id) unawaited(_loadChapters(asset));
    mediaItem.add(
      MediaItem(
        id: asset.id,
        title: title,
        artist: asset.filename,
        album: title,
        artUri: artwork,
        duration: _durations[asset.id],
      ),
    );
    playbackState.add(
      playbackState.value.copyWith(
        queueIndex: _activeIndex,
        updatePosition: position,
        bufferedPosition: player.bufferedPosition,
        speed: speed,
      ),
    );
  }

  void _stateChanged(PlayerState state) {
    if (_backendUnresponsive) return;
    _observePosition();
    final paused =
        _wasPlaying &&
        !state.playing &&
        state.processingState != ProcessingState.completed &&
        _ready &&
        !_seeking &&
        !_loadingSource &&
        !_sleepFiring;
    _wasPlaying =
        state.playing && state.processingState != ProcessingState.completed;
    if (state.processingState == ProcessingState.completed &&
        !_seeking &&
        !_loadingSource &&
        sleepMode == 'duration') {
      setSleepTimer(null);
    }
    _sampleTelemetry();
    final description = '${state.playing}:${state.processingState.name}';
    if (_ready && !_seeking && !_loadingSource && description != _loggedState) {
      _loggedState = description;
      _log(
        state.processingState == ProcessingState.completed
            ? 'completed'
            : state.processingState == ProcessingState.buffering
            ? 'buffering'
            : state.playing
            ? 'play'
            : 'pause',
      );
    }
    final audible =
        current != null &&
        state.playing &&
        state.processingState == ProcessingState.ready &&
        !_seeking;
    if (audible && _clock == null) {
      _clock = ListeningClock(() => monotonic.elapsedMilliseconds);
      _sessionId = uuid.v4();
      _sessionStart = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().millisecondsSinceEpoch,
        isUtc: true,
      );
    }
    _clock?.setAudible(audible);
    if (!state.playing || state.processingState == ProcessingState.completed) {
      unawaited(_persist(finish: true, resumeReason: paused ? 'pause' : null));
    }
    _publishState(state);
  }

  void _publishState(PlayerState state) {
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.rewind,
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.fastForward,
          MediaControl.stop,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: switch (state.processingState) {
          ProcessingState.idle => AudioProcessingState.idle,
          ProcessingState.loading => AudioProcessingState.loading,
          ProcessingState.buffering => AudioProcessingState.buffering,
          ProcessingState.ready => AudioProcessingState.ready,
          ProcessingState.completed => AudioProcessingState.completed,
        },
        playing: playing,
        updatePosition: position,
        bufferedPosition: player.bufferedPosition,
        speed: speed,
        queueIndex: _activeIndex,
      ),
    );
    _notify();
  }

  Future<void> open(LocalAsset asset, String bookTitle) async {
    if (_closed) return;
    _resumeAfterInterruption = false;
    _interruptionGeneration++;
    await beforeBookPlayback?.call();
    await _command(() async {
      if (_backendUnresponsive) await _recoverBackend(restorePrevious: false);
      await _open(asset, bookTitle);
    }, recoverBackend: false);
  }

  Future<void> _open(LocalAsset asset, String bookTitle) async {
    if (current?.bookId == asset.bookId && _ready) return;
    ++_durationGeneration;
    scanningDurations = false;
    loading = true;
    error = '';
    _notify();
    try {
      await _stop();
      _loadingSource = true;
      _ready = false;
      title = bookTitle;
      artwork = null;
      final saved = await audioLibrary.progressForTrack(asset.id);
      _tracks = await assets.audioTracks(
        asset.bookId,
        editionId: saved.locator.editionId,
      );
      _durations
        ..clear()
        ..addAll(await audioLibrary.durations(saved.locator.editionId));
      _activeIndex = _tracks.indexWhere((t) => t.id == saved.locator.trackId);
      if (_activeIndex < 0) {
        throw StateError('Сохранённый трек отсутствует в составе книги');
      }
      if (!await audioSourceExists(current!.path)) {
        throw StateError(
          'Источник недоступен. Подключите папку повторно в карточке книги.',
        );
      }
      _locator = saved.locator;
      _commandCheckpoint = saved;
      artwork = await ArtworkStore(assets).load(asset.bookId);
      final items = _tracks
          .map(
            (t) => MediaItem(
              id: t.id,
              title: title,
              artist: t.filename,
              album: title,
              artUri: artwork,
              duration: _durations[t.id],
            ),
          )
          .toList();
      queue.add(items);
      await _native(
        'load',
        () => player.setAudioSources(
          [
            for (var i = 0; i < _tracks.length; i++)
              AudioSource.uri(audioSourceUri(_tracks[i].path), tag: items[i]),
          ],
          initialIndex: _activeIndex,
          initialPosition: Duration(milliseconds: saved.locator.positionMs),
        ),
        timeout: const Duration(seconds: 12),
      );
      await _native('speed', () => player.setSpeed(saved.speed));
      _parkedProgress = null;
      _ready = true;
      if (player.duration != null) {
        _rememberDuration(current!.id, player.duration!);
      }
      _publishTrack();
      unawaited(scanDurations());
      if (duration > Duration.zero && position > duration) {
        await _native('seek', () => player.seek(duration));
      }
    } catch (e) {
      error = '$e';
    } finally {
      _loadingSource = false;
      loading = false;
      _notify();
    }
  }

  @override
  Future<void> play() async {
    if (_closed) return;
    // An explicit Play can request focus again after a permanent interruption.
    if (_interrupted) {
      _interrupted = false;
      _resumeAfterInterruption = false;
      _interruptionGeneration++;
    }
    await beforeBookPlayback?.call();
    await _command(_play);
  }

  Future<void> _play() async {
    if (_backendUnresponsive) return;
    if (_interrupted) {
      _resumeAfterInterruption = true;
      return;
    }
    if (current == null || !canPlay) return;
    if (_sleepStopped) {
      await _open(current!, title);
      if (!_ready) {
        _sleepStopped = true;
        _notify();
        return;
      }
    }
    if (!_ready) return;
    error = '';
    try {
      final record = await assets.repository.record(current!.bookId);
      if (record?.payload?['status'] != 'finished') {
        await assets.repository.setMeta(
          'audio-status-override:${current!.bookId}',
          'active',
        );
      }
      if (player.processingState == ProcessingState.completed &&
          await resumeStore.load(_locator!.editionId) == null) {
        await _seekTo(0, Duration.zero);
      } else {
        await _applyResumeRewind();
      }
      // play() completes when playback finishes, not when it starts.
      final startedPlayer = player;
      unawaited(
        startedPlayer.play().catchError((Object e) {
          if (!identical(startedPlayer, player) ||
              _closed ||
              _backendUnresponsive) {
            return;
          }
          error = '$e';
          _retireBackend(_captureRecoveryProgress(), 'backend_error', {
            'operation': 'play',
          });
        }),
      );
    } catch (e) {
      error = '$e';
      _notify();
    }
  }

  AudioLocator _currentLocator({int? positionMs}) => AudioLocator(
    bookId: _locator!.bookId,
    editionId: _locator!.editionId,
    trackId: current!.id,
    manifestRevision: _locator!.manifestRevision,
    positionMs: positionMs ?? position.inMilliseconds,
  );

  Future<void> _applyResumeRewind() async {
    if (_locator == null || current == null) return;
    await _writes;
    final checkpoint = await resumeStore.load(_locator!.editionId);
    if (checkpoint == null) return;
    final saved = await audioLibrary.progressForTrack(current!.id);
    // A decoder may round initialPosition by a millisecond when reopening.
    // Validate the intent against durable progress, not its playback clock.
    // Manual navigation clears the intent; newer synced progress invalidates it.
    if (!sameAudioPosition(checkpoint.locator, saved.locator) ||
        !sameAudioPosition(
          checkpoint.locator,
          _currentLocator(positionMs: checkpoint.locator.positionMs),
        )) {
      await resumeStore.clear(_locator!.editionId);
      return;
    }
    final elapsed = now().difference(checkpoint.pausedAt);
    final seconds = checkpoint.reason == 'sleep'
        ? (sleepRewind ? sleepRewindSeconds : 0)
        : rewindSettings.secondsAfter(elapsed);
    final origin = _activeIndex,
        from = Duration(milliseconds: checkpoint.locator.positionMs);
    var index = origin, target = from.inMilliseconds - seconds * 1000;
    _seeking = true;
    _sampleTelemetry(audible: false);
    _clock?.setAudible(false);
    try {
      while (target < 0 && index > 0) {
        index--;
        target += (await _trackDuration(index)).inMilliseconds;
      }
      target = math.max(0, target);
      if (seconds > 0 && !await audioSourceExists(_tracks[index].path)) {
        throw StateError(
          'Источник недоступен: ${_tracks[index].filename}. Подключите папку повторно.',
        );
      }
      if (seconds > 0) {
        await _backendSeek(index, Duration(milliseconds: target));
      }
      _activeIndex = index;
      final resumed = AudioProgress(
        _currentLocator(positionMs: target),
        player.speed,
      );
      // Commit the new checkpoint and consumption together. A repeated Play or
      // restart must not rewind again from the already adjusted position.
      await assets.repository.db.transaction(() async {
        if (!await resumeStore.consume(checkpoint)) {
          throw StateError('Точка продолжения изменилась');
        }
        await audioLibrary.saveProgress(resumed);
      });
      if (seconds > 0) {
        _log('seek', {
          'fromTrackId': _tracks[origin].id,
          'fromMs': from.inMilliseconds,
          'reason': checkpoint.reason == 'sleep'
              ? 'sleep_rewind'
              : 'resume_rewind',
          'rewindSeconds': seconds,
          'pauseMs': math.max(0, elapsed.inMilliseconds),
        });
      }
      _publishTrack();
    } catch (_) {
      try {
        await _backendSeek(origin, from);
        _activeIndex = origin;
      } catch (_) {
        // A failed decoder must reopen from the durable original checkpoint
        // on retry, rather than treating its half-loaded position as a new one.
        _activeIndex = origin;
        _parkedProgress = AudioProgress(checkpoint.locator, player.speed);
        _ready = false;
        _sleepStopped = true;
        try {
          await _native('stop', () => player.stop());
        } catch (_) {
          /* Keep the recoverable checkpoint. */
        }
      }
      rethrow;
    } finally {
      _seeking = false;
    }
  }

  @override
  Future<void> pause() {
    _resumeAfterInterruption = false;
    _interruptionGeneration++;
    return _command(_pause);
  }

  Future<void> handleInterruption(AudioInterruptionEvent event) async {
    // audio_session is shared with music/video. Only its current sound owner
    // may respond; an inactive player must never pause or resume the other one.
    if (!identical(systemHandler.owner, this) || _closed) return;
    if (event.begin) {
      if (_interrupted) {
        if (event.type == AudioInterruptionType.unknown) {
          _interruptionType = event.type;
          _resumeAfterInterruption = false;
          _interruptionGeneration++;
        } else if (event.type == AudioInterruptionType.pause &&
            _interruptionType == AudioInterruptionType.duck) {
          _interruptionType = event.type;
        }
        return;
      }
      _interrupted = true;
      _interruptionType = event.type;
      _resumeAfterInterruption = playing;
      _interruptionGeneration++;
      if (playing) await _command(_pause);
    } else {
      final resume =
          (_interruptionType == AudioInterruptionType.duck ||
              resumeAfterInterruption) &&
          // iOS begins all interruptions as unknown; its end event supplies
          // shouldResume. On Android unknown means permanent focus loss.
          (_interruptionType != AudioInterruptionType.unknown ||
              Platform.isIOS) &&
          _interrupted &&
          _resumeAfterInterruption &&
          event.type != AudioInterruptionType.unknown;
      final generation = _interruptionGeneration;
      _interrupted = false;
      _interruptionType = null;
      _resumeAfterInterruption = false;
      if (resume && !_closed) {
        await _command(() async {
          // A focus return keeps the existing owner. Re-running the handover
          // hook could pause newly selected music while this action is queued.
          if (generation == _interruptionGeneration &&
              !_closed &&
              identical(systemHandler.owner, this)) {
            await _play();
          }
        });
      }
    }
  }

  Future<void> _pause() async {
    final wasPlaying = playing;
    try {
      await _native('pause', () => player.pause());
      await _persist(finish: true, resumeReason: wasPlaying ? 'pause' : null);
    } catch (e) {
      error = 'Не удалось поставить на паузу: $e';
      _notify();
    }
  }

  @override
  Future<void> stop() => _command(() async {
    final parked = _locator == null || current == null
        ? null
        : AudioProgress(_currentLocator(), speed);
    await _stop();
    if (parked != null) {
      _parkedProgress = parked;
      _sleepStopped = true;
      _publishTrack();
      _publishState(player.playerState);
    }
  }, recoverBackend: false);
  Future<void> _stop() async {
    _resumeAfterInterruption = false;
    _interruptionGeneration++;
    _sleepStopped = false;
    _sampleTelemetry(audible: false);
    _log('stop');
    final restoredVolume = _sleepVolume;
    if (restoredVolume != null) _requestedSleepVolume = restoredVolume;
    _sleepVolume = null;
    sleepMode = 'off';
    _sleepGeneration++;
    _sleepTimer?.cancel();
    sleepUntil = null;
    _sleepDeadlineMs = null;
    if (_backendUnresponsive) {
      await _persist(finish: true);
      await _writes;
      _ready = false;
      return;
    }
    await _native('pause', () => player.pause());
    if (restoredVolume != null) await _setSleepVolume(restoredVolume);
    await _persist(finish: true);
    _ready = false;
    await _native('stop', () => player.stop());
  }

  @override
  Future<void> seek(Duration position) =>
      _command(() => _seekTo(_activeIndex, position));

  Future<void> _backendSeek(int index, Duration target) async {
    if (Platform.isWindows &&
        (index != player.currentIndex ||
            player.processingState == ProcessingState.completed)) {
      // just_audio_media_kit 2.1.0 jumps and seeks before mpv finishes opening
      // the new file. Loading with initialIndex waits for native readiness.
      // It also clears completed state before seeking back into a finished book.
      final previousLoading = _loadingSource;
      _loadingSource = true;
      try {
        await _native(
          'load',
          () => player.setAudioSources(
            [
              for (final track in _tracks)
                AudioSource.uri(
                  audioSourceUri(track.path),
                  tag: MediaItem(
                    id: track.id,
                    title: track.filename,
                    album: title,
                  ),
                ),
            ],
            initialIndex: index,
            initialPosition: target,
          ),
          timeout: const Duration(seconds: 12),
        );
        _activeIndex = index;
        if (player.duration != null) {
          _rememberDuration(_tracks[index].id, player.duration!);
        }
      } finally {
        _loadingSource = previousLoading;
      }
    } else {
      // An unnecessary index makes the Windows adapter reopen even this file.
      await _native(
        'seek',
        () => player.seek(
          target,
          index: index == player.currentIndex ? null : index,
        ),
      );
    }
  }

  Future<void> _seekTo(
    int index,
    Duration target, {
    String reason = 'seek',
  }) async {
    if (_sleepStopped && current != null) await _open(current!, title);
    final fromTrack = current?.id, fromMs = position.inMilliseconds;
    final resume = playing;
    if (!_ready || index < 0 || index >= _tracks.length) return;
    if (!await audioSourceExists(_tracks[index].path)) {
      throw StateError(
        'Источник недоступен: ${_tracks[index].filename}. Подключите папку повторно.',
      );
    }
    _sampleTelemetry(audible: false);
    _seeking = true;
    _clock?.setAudible(false);
    try {
      final limit = _durations[_tracks[index].id]?.inMilliseconds;
      final ms = limit == null
          ? math.max(0, target.inMilliseconds)
          : target.inMilliseconds.clamp(0, limit);
      if (reason != 'sleep_boundary' &&
          (sleepMode == 'chapter' || sleepMode == 'track') &&
          (index != _activeIndex || ms >= (_sleepPosition ?? 0))) {
        setSleepTimer(null);
      }
      await _backendSeek(index, Duration(milliseconds: ms));
      _activeIndex = index;
      if (_locator != null) await resumeStore.clear(_locator!.editionId);
      _log('seek', {
        'fromTrackId': fromTrack,
        'fromMs': fromMs,
        'reason': reason,
      });
      _publishTrack();
    } catch (e) {
      error = 'Не удалось перемотать: $e';
    } finally {
      if (resume &&
          !playing &&
          player.processingState != ProcessingState.completed) {
        await _play();
      }
      _seeking = false;
      _stateChanged(player.playerState);
      unawaited(_persist());
    }
  }

  @override
  Future<void> skipToQueueItem(int index) =>
      _command(() => _seekTo(index, Duration.zero));
  @override
  Future<void> skipToNext() =>
      _command(() => _seekTo(_activeIndex + 1, Duration.zero));
  @override
  Future<void> skipToPrevious() =>
      _command(() => _seekTo(_activeIndex - 1, Duration.zero));

  Future<Duration> _trackDuration(int index) async {
    final cached = _durations[_tracks[index].id];
    if (cached != null) return cached;
    if (!await audioSourceExists(_tracks[index].path)) {
      throw StateError(
        'Источник недоступен: ${_tracks[index].filename}. Подключите папку повторно.',
      );
    }
    // Duration lookup must never pause or seek the playback decoder.
    final probe =
        probeFactory?.call() ??
        AudioPlayer(
          handleInterruptions: false,
          handleAudioSessionActivation: false,
        );
    try {
      final value = await probe
          .setAudioSource(AudioSource.uri(audioSourceUri(_tracks[index].path)))
          .timeout(backendTimeout);
      if (value == null || value <= Duration.zero) {
        throw StateError('Не определена длительность трека');
      }
      _rememberDuration(_tracks[index].id, value);
      return value;
    } finally {
      unawaited(
        probe
            .dispose()
            .timeout(const Duration(seconds: 1))
            .catchError((Object _) {}),
      );
    }
  }

  Future<void> _skipRelative(int seconds) => _command(() async {
    if (_sleepStopped && current != null) await _open(current!, title);
    if (!_ready) return;
    final origin = _activeIndex, start = position, resume = playing;
    _sampleTelemetry(audible: false);
    _seeking = true;
    _clock?.setAudible(false);
    var canResume = true;
    var reachedEnd = false;
    try {
      error = '';
      // Even uncached durations use an independent decoder.
      Future<Duration> lengthOf(int index) async {
        final cached = _durations[_tracks[index].id];
        if (cached != null) return cached;
        return _trackDuration(index);
      }

      var index = origin;
      var remaining = start.inMilliseconds + seconds * 1000;
      while (remaining < 0 && index > 0) {
        index--;
        remaining += (await lengthOf(index)).inMilliseconds;
      }
      while (index < _tracks.length - 1) {
        final length = await lengthOf(index);
        if (remaining < length.inMilliseconds) break;
        remaining -= length.inMilliseconds;
        index++;
      }
      final length = await lengthOf(index);
      if ((sleepMode == 'chapter' || sleepMode == 'track') &&
          (index != origin || remaining >= (_sleepPosition ?? 0))) {
        setSleepTimer(null);
      }
      reachedEnd =
          index == _tracks.length - 1 && remaining >= length.inMilliseconds;
      await _backendSeek(
        index,
        Duration(milliseconds: remaining.clamp(0, length.inMilliseconds)),
      );
      _activeIndex = index;
      if (_locator != null) await resumeStore.clear(_locator!.editionId);
      _log('seek', {
        'fromTrackId': _tracks[origin].id,
        'fromMs': start.inMilliseconds,
        'reason': seconds < 0 ? 'rewind' : 'forward',
      });
    } catch (_) {
      try {
        await _backendSeek(origin, start);
        _activeIndex = origin;
      } catch (_) {
        canResume = false;
      }
      rethrow;
    } finally {
      // Resume before slow SAF snapshots, and never turn a paused seek into Play.
      if (resume && canResume && !reachedEnd && !playing) await _play();
      _seeking = false;
      _publishTrack();
      _stateChanged(player.playerState);
      // Writes remain ordered by _persist; storage must not block queued taps.
      unawaited(_persist());
    }
  });

  Future<void> skipSeconds(int seconds) => _skipRelative(seconds);

  @override
  Future<void> rewind() => _skipRelative(-15);
  @override
  Future<void> fastForward() => _skipRelative(15);
  @override
  Future<void> setSpeed(double speed) => _command(() => _setSpeed(speed));
  Future<void> _setSpeed(double speed) async {
    if (!speed.isFinite || speed < 0.5 || speed > 3) {
      throw ArgumentError('Скорость от 0.5 до 3');
    }
    try {
      _sampleTelemetry(audible: false);
      final before = player.speed;
      await _native('speed', () => player.setSpeed(speed));
      _log('speed', {'fromSpeed': before, 'speed': speed});
      await _persist();
      _stateChanged(player.playerState);
    } catch (e) {
      error = 'Не удалось изменить скорость: $e';
      _notify();
    }
  }

  void _sampleTelemetry({bool? audible}) {
    final asset = current;
    if (asset == null) return;
    sampler.sample(
      bookId: asset.bookId,
      trackId: asset.id,
      positionMs: position.inMilliseconds,
      monotonicMs: monotonic.elapsedMilliseconds,
      speed: speed,
      audible:
          audible ??
          (_ready &&
              !_backendUnresponsive &&
              !_loadingSource &&
              !_seeking &&
              player.playing &&
              player.processingState == ProcessingState.ready),
      at: DateTime.now(),
    );
  }

  void _log(String kind, [Map<String, dynamic> extra = const {}]) {
    final asset = current;
    if (asset == null) return;
    final now = DateTime.now(), id = uuid.v4();
    final data = {
      'version': 1,
      'kind': kind,
      'bookId': asset.bookId,
      'trackId': asset.id,
      'positionMs': position.inMilliseconds,
      'speed': speed,
      'at': now.toUtc().toIso8601String(),
      'offsetMinutes': now.timeZoneOffset.inMinutes,
      'localDay': dayKey(now),
      'timezone': now.timeZoneName,
      ...extra,
    };
    unawaited(flushJournal());
    _journalPending.add(() async {
      journal.endInterval();
      await journal.put('audio_event', id, data);
    });
    unawaited(flushJournal());
  }

  Future<void> flushJournal() {
    _sampleTelemetry();
    for (final segment in sampler.pending) {
      _journalPending.add(() => journal.appendListening(segment));
    }
    sampler.pending.clear();
    _journalWrites = _journalWrites
        .then((_) async {
          while (_journalPending.isNotEmpty) {
            await _journalPending.first();
            _journalPending.removeAt(0);
          }
        })
        .catchError((Object e) {
          error = 'Не удалось записать подробный журнал: $e';
          _notify();
        });
    return _journalWrites;
  }

  Future<void> _loadChapters(LocalAsset asset) async {
    if (_closed) return;
    _chapterTrack = asset.id;
    chapters = [];
    chapterError = '';
    if (!RegExp(r'\.m4[ab]$', caseSensitive: false).hasMatch(asset.filename)) {
      return;
    }
    try {
      final result = await readM4bChapters(asset.path);
      if (!_closed && current?.id == asset.id) chapters = result;
    } catch (_) {
      if (current?.id == asset.id) {
        chapterError = 'Не удалось прочитать главы этого файла';
      }
    }
    if (!_closed) _notify();
  }

  Future<void> goToChapter(BookChapter chapter) => _command(
    () => _seekTo(
      _activeIndex,
      Duration(milliseconds: chapter.startMs),
      reason: 'chapter',
    ),
  );
  Future<void> goToLocation(
    String trackId,
    int milliseconds, {
    String reason = 'bookmark',
  }) => _command(() async {
    final index = _tracks.indexWhere((t) => t.id == trackId);
    if (index < 0) throw StateError('Трек отсутствует в книге');
    await _seekTo(index, Duration(milliseconds: milliseconds), reason: reason);
  });
  Future<void> addBookmark(String label) async {
    final asset = current;
    if (asset == null) return;
    await journal.bookmark(
      asset.bookId,
      asset.id,
      position.inMilliseconds,
      label,
    );
    await flushJournal();
    try {
      await sidecar.update(asset.bookId, force: true);
    } catch (e) {
      sidecarError = '$e';
    }
    _notify();
  }

  Future<void> updateSleepOptions({
    bool? fade,
    bool? rewind,
    int? rewindSeconds,
    AudioRewindSettings? resume,
    bool? resumeAfterInterruption,
  }) async {
    if (_closed) return;
    if (rewindSeconds != null && (rewindSeconds < 1 || rewindSeconds > 300)) {
      throw ArgumentError('Возврат от 1 до 300 секунд');
    }
    if (resume != null &&
        [
          resume.shortSeconds,
          resume.mediumSeconds,
          resume.longSeconds,
        ].any((v) => v < 0 || v > 300)) {
      throw ArgumentError('Возврат от 0 до 300 секунд');
    }
    sleepFade = fade ?? sleepFade;
    sleepRewind = rewind ?? sleepRewind;
    sleepRewindSeconds = rewindSeconds ?? sleepRewindSeconds;
    rewindSettings = resume ?? rewindSettings;
    this.resumeAfterInterruption =
        resumeAfterInterruption ?? this.resumeAfterInterruption;
    if (!sleepFade && _sleepVolume != null) {
      await _setSleepVolume(_sleepVolume!);
      _sleepVolume = null;
    }
    try {
      await assets.repository.setMeta(
        'audio-sleep-settings',
        jsonEncode({
          'fade': sleepFade,
          'rewind': sleepRewind,
          'rewindSeconds': sleepRewindSeconds,
          'resume': rewindSettings.toJson(),
          'resumeAfterInterruption': this.resumeAfterInterruption,
        }),
      );
    } catch (e) {
      error = 'Настройки таймера: $e';
    }
    _notify();
  }

  /// Keep only the latest fade/restore request. A slow volume write must neither
  /// flood the native player every 250 ms nor hold the playback command queue.
  Future<void> _setSleepVolume(double value) {
    if (_closed) return Future.value();
    _requestedSleepVolume = value;
    _pendingSleepVolume = (player, value);
    if (_writingVolume) return _volumeWrites;
    _writingVolume = true;
    return _volumeWrites = _drainSleepVolume();
  }

  Future<void> _drainSleepVolume() async {
    try {
      while (_pendingSleepVolume != null && !_closed) {
        final (owner, value) = _pendingSleepVolume!;
        _pendingSleepVolume = null;
        if (!identical(owner, player) || _backendUnresponsive) continue;
        final saved = _locator == null || current == null
            ? null
            : AudioProgress(_currentLocator(), speed);
        try {
          await owner.setVolume(value).timeout(backendTimeout);
        } catch (e) {
          if (identical(owner, player) && !_closed && !_backendUnresponsive) {
            error = 'Не удалось изменить громкость таймера: $e';
            if (e is TimeoutException) {
              _retireBackend(saved, 'backend_timeout', {'operation': 'volume'});
            } else {
              _notify();
            }
          }
        }
      }
    } finally {
      _writingVolume = false;
    }
  }

  void setSleepTimer(int? minutes, {String mode = 'duration'}) {
    if (_closed) return;
    if (!['duration', 'chapter', 'track'].contains(mode) ||
        minutes != null && minutes < 0) {
      throw ArgumentError('Некорректный таймер');
    }
    _sleepGeneration++;
    _sleepTimer?.cancel();
    if (_sleepVolume != null) unawaited(_setSleepVolume(_sleepVolume!));
    _sleepVolume = null;
    sleepUntil = null;
    _sleepDeadlineMs = null;
    _sleepPosition = null;
    _sleepTrack = null;
    sleepMode = 'off';
    if (minutes == null && mode == 'duration') {
      _log('sleep_cancelled');
      _notify();
      return;
    }
    if (current == null) return;
    sleepMode = mode;
    if (mode == 'duration') {
      sleepUntil = now().add(Duration(minutes: minutes!));
      _sleepDeadlineMs = _elapsedMs + Duration(minutes: minutes).inMilliseconds;
    } else {
      _sleepTrack = current!.id;
      _sleepPosition = duration.inMilliseconds;
      if (mode == 'chapter') {
        for (final chapter in chapters) {
          if (chapter.startMs > position.inMilliseconds) {
            _sleepPosition = chapter.startMs;
            break;
          }
        }
      }
      if (_sleepPosition == 0) {
        sleepMode = 'off';
        error = 'Длительность ещё неизвестна';
        _notify();
        return;
      }
    }
    _log('sleep_set', {
      'mode': mode,
      'minutes': minutes,
      'targetMs': _sleepPosition,
    });
    _sleepTimer = periodic(
      const Duration(milliseconds: 250),
      (_) => _checkSleep(),
    );
    _notify();
  }

  void extendSleep() {
    if (_closed) return;
    if (sleepUntil != null) {
      sleepUntil = sleepUntil!.add(const Duration(minutes: 15));
      _sleepDeadlineMs =
          (_sleepDeadlineMs ?? _elapsedMs) +
          const Duration(minutes: 15).inMilliseconds;
      if (_sleepVolume != null) {
        unawaited(_setSleepVolume(_sleepVolume!));
        _sleepVolume = null;
      }
      _log('sleep_extended', {'minutes': 15});
      _notify();
    } else {
      setSleepTimer(15);
    }
  }

  void _checkSleep() {
    if (_sleepFiring ||
        sleepMode == 'off' ||
        _seeking ||
        _loadingSource ||
        loading) {
      return;
    }
    final remaining = _sleepDeadlineMs != null
        ? _sleepDeadlineMs! - _elapsedMs
        : current?.id != _sleepTrack
        ? 0
        : ((_sleepPosition! - position.inMilliseconds) / speed).round();
    if (sleepUntil != null && remaining > 0) {
      sleepUntil = now().add(Duration(milliseconds: remaining));
    }
    if (remaining > 0) {
      if (sleepFade && remaining < 15000 && playing) {
        _sleepVolume ??= player.volume;
        unawaited(
          _setSleepVolume(_sleepVolume! * (remaining / 15000).clamp(0, 1)),
        );
      }
      return;
    }
    final targetTrack = sleepMode == 'duration' ? current?.id : _sleepTrack;
    final targetPosition = sleepMode == 'duration'
        ? position.inMilliseconds
        : _sleepPosition;
    final mode = sleepMode;
    final generation = _sleepGeneration, book = current?.bookId;
    _sleepFiring = true;
    _sleepTimer?.cancel();
    sleepUntil = null;
    _sleepDeadlineMs = null;
    sleepMode = 'off';
    unawaited(
      _command(() async {
        try {
          if (generation != _sleepGeneration ||
              current?.bookId != book ||
              _closed) {
            return;
          }
          _log('sleep_fired', {'mode': mode});
          await _pause();
          if (generation != _sleepGeneration) return;
          final index = _tracks.indexWhere((t) => t.id == targetTrack);
          if (index >= 0 &&
              targetPosition != null &&
              (index != _activeIndex ||
                  targetPosition != position.inMilliseconds)) {
            await _seekTo(
              index,
              Duration(milliseconds: targetPosition),
              reason: 'sleep_boundary',
            );
          }
          final parked = AudioProgress(_currentLocator(), speed);
          await _persist(finish: true, resumeReason: 'sleep');
          if (generation != _sleepGeneration) return;
          await _stop();
          _parkedProgress = parked;
          _sleepStopped = true;
        } finally {
          if (_sleepVolume != null &&
              (generation == _sleepGeneration || sleepMode == 'off')) {
            try {
              await _setSleepVolume(_sleepVolume!);
            } finally {
              _sleepVolume = null;
            }
          }
          _sleepFiring = false;
          _notify();
        }
      }),
    );
  }

  Future<void> _persist({bool finish = false, String? resumeReason}) {
    final asset = current;
    final locator = _locator;
    if (asset == null ||
        locator == null ||
        _loadingSource ||
        !_ready ||
        _seeking) {
      return Future.value();
    }
    final positionMs = position.inMilliseconds
            .clamp(
              0,
              _durations[asset.id]?.inMilliseconds ??
                  math.max(0, position.inMilliseconds),
            )
            .toInt(),
        savedSpeed = speed;
    final activeSeconds = (_clock?.milliseconds ?? 0) ~/ 1000,
        id = _sessionId,
        start = _sessionStart;
    final pausedAt = now();
    final end = DateTime.fromMillisecondsSinceEpoch(
      math.max(
        DateTime.now().millisecondsSinceEpoch,
        (start?.millisecondsSinceEpoch ?? 0) + activeSeconds * 1000,
      ),
      isUtc: true,
    );
    if (finish) {
      _clock = null;
      _sessionId = null;
      _sessionStart = null;
    }
    _pendingWrites.add(() async {
      await assets.repository.db.transaction(() async {
        await audioLibrary.saveProgress(
          AudioProgress(
            AudioLocator(
              bookId: locator.bookId,
              editionId: locator.editionId,
              trackId: asset.id,
              manifestRevision: locator.manifestRevision,
              positionMs: positionMs,
            ),
            savedSpeed,
          ),
        );
        if (resumeReason != null) {
          await resumeStore.save(
            AudioPauseCheckpoint(
              uuid.v4(),
              AudioLocator(
                bookId: locator.bookId,
                editionId: locator.editionId,
                trackId: asset.id,
                manifestRevision: locator.manifestRevision,
                positionMs: positionMs,
              ),
              pausedAt,
              resumeReason,
            ),
          );
        }
        if (id != null && start != null && activeSeconds > 0) {
          await assets.repository.put('session', id, {
            'bookId': asset.bookId,
            'kind': 'listening',
            'startedAt': start.toIso8601String(),
            'endedAt': end.toIso8601String(),
            'activeSeconds': activeSeconds,
            // The protocol requires an IANA zone. Platform abbreviations and
            // Windows display names are not IANA IDs; retain the actual local
            // offset separately for the journal's day boundaries.
            'timezone': 'UTC',
            'offsetMinutes': DateTime.now().timeZoneOffset.inMinutes,
            'source': 'player',
          }, coalesce: true);
        }
      });
    });
    _writes = _writes
        .then((_) async {
          while (_pendingWrites.isNotEmpty) {
            await _pendingWrites.first();
            _pendingWrites.removeAt(0);
          }
          await flushJournal();
          // Folder snapshots are independent of the durable local checkpoint.
          // A slow SAF provider must not hold Pause, Play or the command queue.
          unawaited(
            sidecar
                .update(asset.bookId, force: finish)
                .then((_) {
                  sidecarError = '';
                })
                .catchError((Object e) {
                  sidecarError =
                      '.pepehub: $e. Позиция сохранена в приложении.';
                  if (!_closed) _notify();
                }),
          );
        })
        .catchError((Object e) {
          error = 'Не удалось сохранить позицию или сессию: $e';
          _notify();
        });
    return _writes;
  }

  Future<void> prepareFolderChange() async {
    ++_durationGeneration;
    await _durationWork;
    await stop();
    await flushJournal();
  }

  Future<void> shutdown() => _shutdownWork ??= _shutdown();

  Future<void> _shutdown() async {
    _closed = true;
    ++_durationGeneration;
    _checkpointTimer?.cancel();
    _sleepTimer?.cancel();
    // The duration probe may take twelve seconds. Silence playback first.
    await _command(_pause, duringShutdown: true);
    await _persist(finish: true);
    await _writes;
    await _durationWork;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    for (final subscription in _playerSubscriptions) {
      await subscription.cancel();
    }
    await flushJournal();
    await player
        .dispose()
        .timeout(const Duration(seconds: 1))
        .catchError((Object _) {});
    await systemHandler.close();
    playbackPosition.dispose();
    super.dispose();
  }
}
