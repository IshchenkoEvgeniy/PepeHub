import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';

import '../media/audio_controller.dart';
import 'models.dart';
import 'video_captions_controller.dart';
import 'video_controller.dart';
import 'video_engine.dart';
import 'video_fullscreen.dart';
import 'video_repository.dart';
import 'video_import.dart';

/// Owns a decoder beyond a player route: page, mini-player and PiP use one session.
class VideoPlaybackSession extends BaseAudioHandler
    with ChangeNotifier, WidgetsBindingObserver {
  final VideoRepository repository;
  final AudioController? audio;
  final VideoPlaybackEngine Function() engineFactory;
  final VideoFullscreenHost window;
  final Future<void> Function()? beforePlaying;
  VideoPlaybackController? controller;
  VideoCaptionsController? captions;
  VideoItem? item;
  List<VideoChapter> chapters = [];
  bool inMini = false,
      miniWindow = false,
      pageAttached = false,
      _miniRequested = false,
      _disposed = false;
  AudioSession? _audioSession;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Future<void> _work = Future.value();
  Timer? _backgroundTimer;
  bool _foreground = true;
  String? _publishedLesson, _pipState;
  List<int>? _publishedOrder;
  VideoPlaybackSession(
    this.repository, {
    this.audio,
    VideoPlaybackEngine Function()? engineFactory,
    VideoFullscreenHost? window,
    this.beforePlaying,
  }) : engineFactory = engineFactory ?? NativeVideoEngine.create,
       window = window ?? VideoFullscreenHost() {
    WidgetsBinding.instance.addObserver(this);
    this.window.addListener(_windowChanged);
    this.window.onAction = (action) async {
      if (action == 'toggle') await controller?.toggle();
      if (action == 'back') await rewind();
      if (action == 'forward') await fastForward();
    };
    if (audio != null) audio!.beforeBookPlayback = _bookTakesSound;
    unawaited(this.window.initialize().catchError((Object _) {}));
  }
  Future<void> _serialize(Future<void> Function() action) {
    final next = _work.then((_) => action());
    _work = next.catchError((Object _) {});
    return next;
  }

  Future<void> open(VideoItem value, List<VideoLesson> lessons, int index) =>
      _serialize(() async {
        if (_disposed) return;
        if (index < 0 || index >= lessons.length) {
          throw RangeError.index(index, lessons);
        }
        if (!value.connected || !lessons[index].available) {
          throw StateError(
            'Источник недоступен. Обновите или переподключите папку курса',
          );
        }
        final previous = controller;
        if (previous != null &&
            item?.id == value.id &&
            previous.lessons.length == lessons.length &&
            List.generate(
              lessons.length,
              (i) =>
                  previous.lessons[i].id == lessons[i].id &&
                  previous.lessons[i].mediaVersion == lessons[i].mediaVersion,
            ).every((same) => same)) {
          item = value;
          if (previous.current?.id != lessons[index].id) {
            await previous.load(index);
          }
          return;
        }
        if (previous != null) await _closeCurrent();
        item = value;
        late VideoCaptionsController text;
        final player = VideoPlaybackController(
          repository: repository,
          engine: engineFactory(),
          lessons: List.of(lessons),
          beforePlaying: _takeSound,
          validateSource: (lesson) async {
            if (!controller!.engine.validatesLocalSources) return;
            if (!lesson.available) {
              throw StateError('Файл недоступен. Обновите папку курса');
            }
            final record = await repository.repository.record(lesson.id);
            final raw = record?.payload?['fileIdentity'];
            if (raw != null) {
              await verifyVideoSources([
                VideoSourceDraft(
                  lesson.source,
                  lesson.title,
                  identity: VideoFileIdentity.fromJson(
                    Map<String, dynamic>.from(raw as Map),
                  ),
                ),
              ]);
            }
          },
          afterPaused: () async {
            if (_audioSession != null) await _audioSession!.setActive(false);
          },
          configureLesson: (lesson) async {
            await text.loadLesson(lesson);
            chapters = await controller!.engine.readChapters();
          },
        );
        controller = player;
        captions = text = VideoCaptionsController(repository, player);
        player.addListener(_changed);
        text.addListener(_changed);
        _changed();
        await player.load(index);
      });
  Future<void> _takeSound() async {
    if (audio?.playing == true) await audio!.pause();
    await beforePlaying?.call();
    if (Platform.isAndroid || Platform.isIOS) {
      if (_audioSession == null) {
        final session = _audioSession = await AudioSession.instance;
        _subscriptions.add(
          session.interruptionEventStream.listen((event) {
            if (event.begin) unawaited(pause().catchError((Object _) {}));
          }),
        );
        _subscriptions.add(
          session.becomingNoisyEventStream.listen(
            (_) => unawaited(pause().catchError((Object _) {})),
          ),
        );
      }
      await _audioSession!.configure(
        controller?.current?.isAudio == true
            ? const AudioSessionConfiguration.music()
            : const AudioSessionConfiguration.speech(),
      );
      if (await _audioSession!.setActive(true) != true) {
        throw StateError('Другое приложение удерживает аудиофокус');
      }
    }
    audio?.systemHandler.setOwner(this);
  }

  Future<void> _bookTakesSound() async {
    await pause();
    // audio_session is shared by all players in the app. Restore the speech
    // profile before the audiobook takes focus after listening to music.
    await _audioSession?.configure(const AudioSessionConfiguration.speech());
    audio?.systemHandler.release(this);
  }

  Future<void> setAudioOnly(bool enabled) async {
    if (enabled && Platform.isAndroid && audio == null) {
      throw StateError(
        'Системная медиаслужба недоступна. Перезапустите приложение, чтобы включить фоновое аудио',
      );
    }
    await controller?.setAudioOnly(enabled);
  }

  void attachPage() {
    pageAttached = true;
    inMini = false;
    _miniRequested = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) _changed();
    });
  }

  void requestMini() {
    _miniRequested = true;
  }

  void detachPage() {
    pageAttached = false;
    inMini = _miniRequested && controller != null;
    _miniRequested = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) _changed();
    });
  }

  void _windowChanged() {
    _pipState = null;
    unawaited(controller?.setPipVisible(window.pip).catchError((Object _) {}));
    _changed();
  }

  void refresh() => _changed();

  void _changed() {
    if (_disposed) return;
    final player = controller;
    if (player != null) {
      final lesson = player.current;
      final key = lesson == null
          ? null
          : '${lesson.id}:${lesson.mediaVersion}:${player.state.durationMs}';
      if (_publishedLesson != key) {
        _publishedLesson = key;
        mediaItem.add(
          lesson == null
              ? null
              : MediaItem(
                  id: 'video:${lesson.id}',
                  title: lesson.title,
                  album: item?.title,
                  duration: player.state.durationMs > 0
                      ? Duration(milliseconds: player.state.durationMs)
                      : null,
                ),
        );
      }
      if (!identical(_publishedOrder, player.playbackOrder)) {
        _publishedOrder = player.playbackOrder;
        queue.add([
          for (final i in player.playbackOrder)
            MediaItem(
              id: 'video:${player.lessons[i].id}',
              title: player.lessons[i].title,
            ),
        ]);
      }
      playbackState.add(
        PlaybackState(
          controls: [
            player.current?.isAudio == true
                ? MediaControl.skipToPrevious
                : MediaControl.rewind,
            player.state.playing ? MediaControl.pause : MediaControl.play,
            player.current?.isAudio == true
                ? MediaControl.skipToNext
                : MediaControl.fastForward,
            MediaControl.stop,
          ],
          systemActions: const {
            MediaAction.seek,
            MediaAction.seekForward,
            MediaAction.seekBackward,
            MediaAction.skipToPrevious,
            MediaAction.skipToNext,
            MediaAction.setShuffleMode,
          },
          androidCompactActionIndices: const [0, 1, 2],
          processingState: player.loading
              ? AudioProcessingState.loading
              : player.state.buffering
              ? AudioProcessingState.buffering
              : player.state.completed
              ? AudioProcessingState.completed
              : AudioProcessingState.ready,
          playing: player.state.playing,
          updatePosition: Duration(milliseconds: player.positionMs),
          speed: player.state.speed,
          queueIndex: player.queueIndex,
          shuffleMode: player.shuffleEnabled
              ? AudioServiceShuffleMode.all
              : AudioServiceShuffleMode.none,
        ),
      );
      final nativePlaying =
          player.state.playing && !player.state.completed && !player.loading;
      final pipState =
          '$nativePlaying:${player.audioOnly}:${player.engine.aspectRatio}';
      if (_pipState != pipState) {
        _pipState = pipState;
        unawaited(
          window
              .updatePlayback(
                playing: nativePlaying,
                visual: !player.audioOnly,
                aspectRatio: player.engine.aspectRatio,
              )
              .catchError((Object _) {}),
        );
      }
    }
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _backgroundTimer?.cancel();
    _foreground = state == AppLifecycleState.resumed;
    final player = controller;
    if (player == null) return;
    // Exclude hidden visual time immediately; allow native PiP entry to report
    // its state before deciding to pause the decoder.
    unawaited(
      player
          .setForeground(_foreground, pauseHidden: false)
          .catchError((Object _) {}),
    );
    if (!_foreground) {
      _backgroundTimer = Timer(const Duration(milliseconds: 250), () {
        if (!_foreground && !window.pip && !player.audioOnly) {
          unawaited(player.pause().catchError((Object _) {}));
        }
      });
    }
  }

  @override
  Future<void> play() async {
    await controller?.play();
  }

  @override
  Future<void> pause() async {
    await controller?.pause();
    if (_audioSession != null) await _audioSession!.setActive(false);
  }

  @override
  Future<void> stop() async {
    if (!pageAttached && !window.pip) {
      await close();
      return;
    }
    await pause();
    audio?.systemHandler.release(this);
    playbackState.add(
      playbackState.value.copyWith(processingState: AudioProcessingState.idle),
    );
  }

  @override
  Future<void> seek(Duration position) async {
    await controller?.seek(position.inMilliseconds);
  }

  @override
  Future<void> rewind() async {
    await controller?.skip(-10000);
  }

  @override
  Future<void> fastForward() async {
    await controller?.skip(10000);
  }

  @override
  Future<void> skipToNext() async {
    await controller?.next();
  }

  @override
  Future<void> skipToPrevious() async {
    await controller?.previous();
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    final player = controller;
    if (player != null && index >= 0 && index < player.playbackOrder.length) {
      await player.load(player.playbackOrder[index]);
    }
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    await controller?.setShuffle(shuffleMode != AudioServiceShuffleMode.none);
  }

  @override
  Future<void> setSpeed(double speed) async {
    await controller?.setSpeed(speed);
  }

  @override
  Future<void> onTaskRemoved() => close();
  Future<void> _closeCurrent() async {
    final player = controller;
    if (player == null) return;
    await player.close();
    player.removeListener(_changed);
    captions?.removeListener(_changed);
    captions?.dispose();
    player.dispose();
    controller = null;
    captions = null;
    item = null;
    chapters = [];
    inMini = false;
    _publishedLesson = _pipState = null;
    _publishedOrder = null;
    audio?.systemHandler.release(this);
    if (_audioSession != null) await _audioSession!.setActive(false);
    if (miniWindow) {
      await window.setMiniWindow(false);
      miniWindow = false;
    }
    await window.updatePlayback(
      playing: false,
      visual: false,
      aspectRatio: 16 / 9,
    );
    playbackState.add(
      PlaybackState(processingState: AudioProcessingState.idle),
    );
  }

  Future<void> close() => _serialize(() async {
    await _closeCurrent();
    _changed();
  });
  @override
  void dispose() {
    _disposed = true;
    _backgroundTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    window.removeListener(_windowChanged);
    if (audio?.beforeBookPlayback == _bookTakesSound) {
      audio!.beforeBookPlayback = null;
    }
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(
      _work
          .then((_) => _closeCurrent())
          .catchError((Object _) async {
            final player = controller;
            player?.removeListener(_changed);
            captions?.removeListener(_changed);
            captions?.dispose();
            await player?.engine.close();
            player?.dispose();
            controller = null;
            captions = null;
            audio?.systemHandler.release(this);
            if (_audioSession != null) await _audioSession!.setActive(false);
            if (miniWindow) await window.setMiniWindow(false);
            await window.updatePlayback(
              playing: false,
              visual: false,
              aspectRatio: 16 / 9,
            );
          })
          .whenComplete(window.dispose)
          .catchError((Object _) {}),
    );
    super.dispose();
  }
}

class VideoSessionScope extends InheritedNotifier<VideoPlaybackSession> {
  const VideoSessionScope({
    super.key,
    required VideoPlaybackSession session,
    required super.child,
  }) : super(notifier: session);
  static VideoPlaybackSession? read(BuildContext context) =>
      (context
                  .getElementForInheritedWidgetOfExactType<VideoSessionScope>()
                  ?.widget
              as VideoSessionScope?)
          ?.notifier;
}
