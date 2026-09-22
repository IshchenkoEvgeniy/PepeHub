import '../audio/book_timeline.dart';
import '../audio/audio_journal.dart';
import '../audio/m4b_chapters.dart';
import '../audio/audio_sidecar.dart';

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

class AudioController extends BaseAudioHandler with ChangeNotifier {
  final AssetStore assets;
  final AudioPlayer player;
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
          notifyListeners();
          final probe = AudioPlayer(
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
                  notifyListeners();
                }
              } catch (_) {
                failures.add(track.filename);
              }
            }
          } finally {
            await probe.dispose();
            if (!_closed && generation == _durationGeneration) {
              scanningDurations = false;
              durationError = failures.isEmpty
                  ? ''
                  : 'Не определена длительность файлов: ${failures.length}. Можно повторить проверку.';
              notifyListeners();
            }
          }
        })
        .catchError((Object e) {
          if (!_closed && generation == _durationGeneration) {
            scanningDurations = false;
            durationError = 'Не удалось проверить длительности: $e';
            notifyListeners();
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
  Future<void> _command(Future<void> Function() action) {
    final next = _commands.then((_) => action());
    _commands = next.catchError((Object e) {
      error = '$e';
      notifyListeners();
    });
    return _commands;
  }

  AudioLocator? _locator;
  late final AudioLibraryRepository audioLibrary = AudioLibraryRepository(
    assets.repository.db,
  );
  String title = '', error = '';
  Uri? artwork;
  bool loading = false,
      _seeking = false,
      _loadingSource = false,
      _ready = false;
  late final sidecar = AudioSidecarWriter(assets);
  String sidecarError = '';
  late final journal = AudioJournal(assets.repository);
  final sampler = ListeningSampler();
  Future<void> _journalWrites = Future.value();
  final List<Future<void> Function()> _journalPending = [];
  List<BookChapter> chapters = [];
  String? _chapterTrack;
  String chapterError = '';
  bool _closed = false;
  String? _loggedState;
  String sleepMode = 'off';
  int? _sleepPosition;
  String? _sleepTrack;
  double? _sleepVolume;
  bool _sleepFiring = false, _sleepStopped = false;
  bool sleepFade = true, sleepRewind = true;
  Timer? _checkpointTimer, _sleepTimer;
  DateTime? sleepUntil;
  ListeningClock? _clock;
  DateTime? _sessionStart;
  String? _sessionId;
  Future<void> _writes = Future.value();
  final List<Future<void> Function()> _pendingWrites = [];
  AudioController(this.assets, this.player) {
    _subscriptions.add(player.playerStateStream.listen(_stateChanged));
    _subscriptions.add(
      player.positionStream.listen((_) {
        _sampleTelemetry();
        notifyListeners();
      }),
    );
    _subscriptions.add(
      player.playbackEventStream.listen((event) {
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
        if (changed || durationChanged) notifyListeners();
      }),
    );
    _subscriptions.add(
      player.errorStream.listen((e) {
        error = 'Не удалось воспроизвести файл: ${e.message}';
        _sampleTelemetry(audible: false);
        _log('error', {'code': e.code.toString()});
        _clock?.setAudible(false);
        unawaited(_persist(finish: true));
        notifyListeners();
      }),
    );
    _checkpointTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => unawaited(_persist()),
    );
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
    final controller = AudioController(assets, AudioPlayer());
    try {
      final saved = await assets.repository.meta('audio-sleep-settings');
      if (saved != null) {
        final settings = jsonDecode(saved);
        controller.sleepFade = settings['fade'] != false;
        controller.sleepRewind = settings['rewind'] != false;
      }
    } catch (_) {}
    if (Platform.isAndroid) {
      await AudioService.init<AudioController>(
        builder: () => controller,
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'app.pepehub.audio',
          androidNotificationChannelName: 'Аудиокниги',
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
      await session.configure(const AudioSessionConfiguration.speech());
    }
    return controller;
  }

  Future<void> chooseArtwork() async {
    final book = current?.bookId;
    if (book == null) return;
    try {
      final selected = await ArtworkStore(assets).choose(book);
      if (selected != null && current?.bookId == book) {
        artwork = selected;
        _publishTrack();
        notifyListeners();
      }
    } catch (e) {
      error = 'Обложка: $e';
      notifyListeners();
    }
  }

  bool get playing =>
      player.playing && player.processingState != ProcessingState.completed;
  bool get canPlay => (_ready || _sleepStopped) && !loading;
  Duration get position => player.processingState == ProcessingState.completed
      ? (_durations[current?.id] ?? player.duration ?? player.position)
      : player.position;
  Duration get duration => player.duration ?? Duration.zero;
  double get speed => player.speed;
  void _rememberDuration(String trackId, Duration value) {
    if (value <= Duration.zero || _durations[trackId] == value) return;
    _durations[trackId] = value;
    unawaited(
      audioLibrary.saveDuration(trackId, value).catchError((Object e) {
        error = 'Не удалось сохранить длительность: $e';
        notifyListeners();
      }),
    );
  }

  void _publishTrack() {
    final asset = current;
    if (asset == null) return;
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
      unawaited(_persist(finish: true));
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
        speed: player.speed,
        queueIndex: _activeIndex,
      ),
    );
    notifyListeners();
  }

  Future<void> open(LocalAsset asset, String bookTitle) =>
      _command(() => _open(asset, bookTitle));
  Future<void> _open(LocalAsset asset, String bookTitle) async {
    if (current?.bookId == asset.bookId && _ready) return;
    ++_durationGeneration;
    scanningDurations = false;
    loading = true;
    error = '';
    notifyListeners();
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
      await player.setAudioSources(
        [
          for (var i = 0; i < _tracks.length; i++)
            AudioSource.uri(audioSourceUri(_tracks[i].path), tag: items[i]),
        ],
        initialIndex: _activeIndex,
        initialPosition: Duration(milliseconds: saved.locator.positionMs),
      );
      await player.setSpeed(saved.speed);
      _ready = true;
      if (player.duration != null) {
        _rememberDuration(current!.id, player.duration!);
      }
      _publishTrack();
      unawaited(scanDurations());
      if (duration > Duration.zero && position > duration) {
        await player.seek(duration);
      }
    } catch (e) {
      error = '$e';
    } finally {
      _loadingSource = false;
      loading = false;
      notifyListeners();
    }
  }

  @override
  Future<void> play() => _command(_play);
  Future<void> _play() async {
    if (current == null || !canPlay) return;
    if (_sleepStopped) await _open(current!, title);
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
      if (player.processingState == ProcessingState.completed) {
        await _seekTo(0, Duration.zero);
      }
      // play() completes when playback finishes, not when it starts.
      unawaited(
        player.play().catchError((Object e) {
          error = '$e';
          notifyListeners();
        }),
      );
    } catch (e) {
      error = '$e';
      notifyListeners();
    }
  }

  @override
  Future<void> pause() => _command(_pause);
  Future<void> _pause() async {
    try {
      await player.pause();
      await _persist(finish: true);
    } catch (e) {
      error = 'Не удалось поставить на паузу: $e';
      notifyListeners();
    }
  }

  @override
  Future<void> stop() => _command(_stop);
  Future<void> _stop() async {
    _sleepStopped = false;
    _sampleTelemetry(audible: false);
    _log('stop');
    if (_sleepVolume != null) await player.setVolume(_sleepVolume!);
    _sleepVolume = null;
    sleepMode = 'off';
    _sleepTimer?.cancel();
    sleepUntil = null;
    await player.pause();
    await _persist(finish: true);
    _ready = false;
    await player.stop();
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
        await player.setAudioSources(
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
      await player.seek(
        target,
        index: index == player.currentIndex ? null : index,
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
      await _backendSeek(index, Duration(milliseconds: ms));
      _activeIndex = index;
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
    await _backendSeek(index, Duration.zero);
    final event = player.playbackEvent;
    final value = event.currentIndex == index && event.duration != null
        ? event.duration!
        : (await player.playbackEventStream
                  .firstWhere(
                    (e) => e.currentIndex == index && e.duration != null,
                  )
                  .timeout(const Duration(seconds: 10)))
              .duration!;
    _rememberDuration(_tracks[index].id, value);
    return value;
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
      // Cached durations let us seek without interrupting playback. Only the
      // legacy duration fallback opens files on the main decoder and needs pause.
      Future<Duration> lengthOf(int index) async {
        final cached = _durations[_tracks[index].id];
        if (cached != null) return cached;
        await player.pause();
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
      reachedEnd =
          index == _tracks.length - 1 && remaining >= length.inMilliseconds;
      await _backendSeek(
        index,
        Duration(milliseconds: remaining.clamp(0, length.inMilliseconds)),
      );
      _activeIndex = index;
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
      await player.setSpeed(speed);
      _log('speed', {'fromSpeed': before, 'speed': speed});
      await _persist();
      _stateChanged(player.playerState);
    } catch (e) {
      error = 'Не удалось изменить скорость: $e';
      notifyListeners();
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
          notifyListeners();
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
    if (!_closed) notifyListeners();
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
    notifyListeners();
  }

  Future<void> updateSleepOptions({bool? fade, bool? rewind}) async {
    sleepFade = fade ?? sleepFade;
    sleepRewind = rewind ?? sleepRewind;
    if (!sleepFade && _sleepVolume != null) {
      await player.setVolume(_sleepVolume!);
      _sleepVolume = null;
    }
    try {
      await assets.repository.setMeta(
        'audio-sleep-settings',
        jsonEncode({'fade': sleepFade, 'rewind': sleepRewind}),
      );
    } catch (e) {
      error = 'Настройки таймера: $e';
    }
    notifyListeners();
  }

  void setSleepTimer(int? minutes, {String mode = 'duration'}) {
    _sleepTimer?.cancel();
    if (_sleepVolume != null) unawaited(player.setVolume(_sleepVolume!));
    _sleepVolume = null;
    sleepUntil = null;
    _sleepPosition = null;
    _sleepTrack = null;
    sleepMode = 'off';
    if (minutes == null && mode == 'duration') {
      _log('sleep_cancelled');
      notifyListeners();
      return;
    }
    if (current == null) return;
    sleepMode = mode;
    if (mode == 'duration') {
      sleepUntil = DateTime.now().add(Duration(minutes: minutes!));
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
        notifyListeners();
        return;
      }
    }
    _log('sleep_set', {
      'mode': mode,
      'minutes': minutes,
      'targetMs': _sleepPosition,
    });
    _sleepTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _checkSleep(),
    );
    notifyListeners();
  }

  void extendSleep() {
    if (sleepUntil != null) {
      sleepUntil = sleepUntil!.add(const Duration(minutes: 15));
      if (_sleepVolume != null) {
        unawaited(player.setVolume(_sleepVolume!));
        _sleepVolume = null;
      }
      _log('sleep_extended', {'minutes': 15});
      notifyListeners();
    } else {
      setSleepTimer(15);
    }
  }

  void _checkSleep() {
    if (_sleepFiring || sleepMode == 'off') return;
    final remaining = sleepUntil != null
        ? sleepUntil!.difference(DateTime.now()).inMilliseconds
        : current?.id != _sleepTrack
        ? 0
        : ((_sleepPosition! - position.inMilliseconds) / speed).round();
    if (remaining > 0) {
      if (sleepFade && remaining < 15000 && playing) {
        _sleepVolume ??= player.volume;
        unawaited(
          player.setVolume(_sleepVolume! * (remaining / 15000).clamp(0, 1)),
        );
      }
      return;
    }
    final targetTrack = sleepMode == 'duration' ? current?.id : _sleepTrack;
    final targetPosition = sleepMode == 'duration'
        ? position.inMilliseconds
        : _sleepPosition;
    final mode = sleepMode;
    _sleepFiring = true;
    _sleepTimer?.cancel();
    sleepUntil = null;
    sleepMode = 'off';
    unawaited(
      _command(() async {
        try {
          _log('sleep_fired', {'mode': mode});
          await _pause();
          final index = _tracks.indexWhere((t) => t.id == targetTrack);
          if (index >= 0 && targetPosition != null) {
            await _seekTo(
              index,
              Duration(
                milliseconds: targetPosition - (sleepRewind ? 10000 : 0),
              ),
              reason: 'sleep_rewind',
            );
          }
          if (_sleepVolume != null) await player.setVolume(_sleepVolume!);
          await _stop();
          _sleepStopped = true;
        } finally {
          _sleepVolume = null;
          _sleepFiring = false;
          notifyListeners();
        }
      }),
    );
  }

  Future<void> _persist({bool finish = false}) {
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
        if (id != null && start != null && activeSeconds > 0) {
          await assets.repository.put('session', id, {
            'bookId': asset.bookId,
            'kind': 'listening',
            'startedAt': start.toIso8601String(),
            'endedAt': end.toIso8601String(),
            'activeSeconds': activeSeconds,
            'timezone': DateTime.now().timeZoneName,
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
          try {
            await sidecar.update(asset.bookId, force: finish);
            sidecarError = '';
          } catch (e) {
            sidecarError = '.pepehub: $e. Позиция сохранена в приложении.';
            notifyListeners();
          }
        })
        .catchError((Object e) {
          error = 'Не удалось сохранить позицию или сессию: $e';
          notifyListeners();
        });
    return _writes;
  }

  Future<void> prepareFolderChange() async {
    ++_durationGeneration;
    await _durationWork;
    await stop();
    await flushJournal();
  }

  Future<void> shutdown() async {
    _closed = true;
    ++_durationGeneration;
    await _durationWork;
    _checkpointTimer?.cancel();
    _sleepTimer?.cancel();
    await pause();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await flushJournal();
    await player.dispose();
    super.dispose();
  }
}
