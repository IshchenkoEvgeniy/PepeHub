import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'models.dart';
import 'video_subtitles.dart';

class VideoChapter {
  final String title;
  final int startMs;
  const VideoChapter(this.title, this.startMs);
}

class VideoTrackChoice {
  final String id, title;
  final String? language;
  final bool image;
  const VideoTrackChoice(
    this.id,
    this.title, {
    this.language,
    this.image = false,
  });
  String get label =>
      [title, if (language?.isNotEmpty == true) language!].join(' · ');
}

class VideoEngineState {
  final int positionMs, durationMs;
  final bool playing, buffering, completed;
  final double speed, volume;
  final String? error;
  const VideoEngineState({
    this.positionMs = 0,
    this.durationMs = 0,
    this.playing = false,
    this.buffering = false,
    this.completed = false,
    this.speed = 1,
    this.volume = 100,
    this.error,
  });
}

/// A narrow adapter keeps the journal independent of the native decoder.
abstract class VideoPlaybackEngine extends ChangeNotifier {
  VideoEngineState get state;
  VideoController? get surface => null;
  bool get canSelectTracks => false;
  bool get rendersNativeSubtitles => false;
  List<VideoTrackChoice> get audioTracks => const [];
  List<VideoTrackChoice> get subtitleTracks => const [];
  List<String> get subtitleText => const [];
  double get aspectRatio => 16 / 9;
  bool get canCaptureFrame => false;
  bool get validatesLocalSources => false;
  Future<Uint8List?> captureFrame() async =>
      throw UnsupportedError('Снимок кадра недоступен');
  Future<List<VideoChapter>> readChapters() async => const [];
  Future<void> setAudioOnly(bool enabled) async {}
  Future<void> waitForTracks() async {}
  Future<void> selectAudioTrack(String id) async =>
      throw UnsupportedError('Аудиодорожки недоступны');
  Future<void> selectSubtitleTrack(String id) async =>
      throw UnsupportedError('Субтитры недоступны');
  Future<void> externalAss(String text, String key) async =>
      throw UnsupportedError('ASS недоступен');
  Future<void> configureSubtitles(VideoPlaybackSettings settings) async {}
  Future<void> open(
    VideoLesson lesson, {
    required int positionMs,
    required double speed,
  });
  Future<void> play();
  Future<void> pause();
  Future<void> seek(int positionMs);
  Future<void> setSpeed(double speed);
  Future<void> setVolume(double volume);
  Future<void> close();
}

class NativeVideoEngine extends VideoPlaybackEngine {
  final Player player;
  @override
  final VideoController? surface;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  String? _error;
  String? _externalAssKey;
  @override
  final bool rendersNativeSubtitles;

  /// Owns the supplied player; a surface-free instance also supports decoder tests.
  NativeVideoEngine(
    this.player, {
    bool attachSurface = true,
    this.rendersNativeSubtitles = false,
  }) : surface = attachSurface ? VideoController(player) : null {
    for (final stream in <Stream<dynamic>>[
      player.stream.position,
      player.stream.duration,
      player.stream.playing,
      player.stream.buffering,
      player.stream.completed,
      player.stream.rate,
      player.stream.volume,
      player.stream.track,
      player.stream.tracks,
      player.stream.subtitle,
    ]) {
      _subscriptions.add(stream.listen((_) => notifyListeners()));
    }
    _subscriptions.add(
      player.stream.error.listen((message) {
        _error = message;
        notifyListeners();
      }),
    );
  }

  factory NativeVideoEngine.create() {
    MediaKit.ensureInitialized();
    return NativeVideoEngine(
      Player(
        configuration: const PlayerConfiguration(
          title: 'PepeHub — Медиа',
          libass: true,
        ),
      ),
      rendersNativeSubtitles: true,
    );
  }

  @override
  VideoEngineState get state => VideoEngineState(
    positionMs: player.state.position.inMilliseconds,
    durationMs: player.state.duration.inMilliseconds,
    playing: player.state.playing,
    buffering: player.state.buffering,
    completed: player.state.completed,
    speed: player.state.rate,
    volume: player.state.volume,
    error: _error,
  );

  @override
  Future<void> open(
    VideoLesson lesson, {
    required int positionMs,
    required double speed,
  }) async {
    _error = null;
    _externalAssKey = null;
    await player.open(
      Media(
        lesson.source,
        start: positionMs > 0 ? Duration(milliseconds: positionMs) : null,
      ),
      play: false,
    );
    await player.setRate(speed);
  }

  @override
  Future<void> play() => player.play();
  @override
  Future<void> pause() => player.pause();
  @override
  Future<void> seek(int positionMs) async {
    await player.seek(Duration(milliseconds: positionMs));
    // The native command can finish before the time-pos event arrives. Saving
    // immediately must not persist the position from before the seek.
    bool arrived(Duration position) =>
        (position.inMilliseconds - positionMs).abs() <= 150;
    if (!arrived(player.state.position)) {
      await player.stream.position
          .firstWhere(arrived)
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () =>
                throw StateError('Источник не подтвердил переход ко времени'),
          );
    }
  }

  @override
  Future<void> setSpeed(double speed) => player.setRate(speed);
  @override
  Future<void> setVolume(double volume) => player.setVolume(volume);
  @override
  double get aspectRatio => player.state.videoParams.aspect ?? 16 / 9;
  @override
  bool get canCaptureFrame => true;
  @override
  bool get validatesLocalSources => true;
  @override
  Future<Uint8List?> captureFrame() => player.screenshot(format: 'image/png');
  @override
  Future<void> setAudioOnly(bool enabled) =>
      player.setVideoTrack(enabled ? VideoTrack.no() : VideoTrack.auto());
  @override
  Future<List<VideoChapter>> readChapters() async {
    final native = player.platform;
    if (native is! NativePlayer) return const [];
    final count =
        (int.tryParse(await native.getProperty('chapter-list/count')) ?? 0)
            .clamp(0, 2000);
    final chapters = <VideoChapter>[];
    for (var i = 0; i < count; i++) {
      final seconds = double.tryParse(
        await native.getProperty('chapter-list/$i/time'),
      );
      if (seconds == null || !seconds.isFinite || seconds < 0) continue;
      final title = await native.getProperty('chapter-list/$i/title');
      chapters.add(
        VideoChapter(
          title.isEmpty ? 'Глава ${i + 1}' : title,
          (seconds * 1000).round(),
        ),
      );
    }
    return chapters;
  }

  @override
  bool get canSelectTracks => true;
  @override
  List<VideoTrackChoice> get audioTracks => [
    for (final track in player.state.tracks.audio)
      VideoTrackChoice(
        track.id,
        track.id == 'auto'
            ? 'Автоматически'
            : track.id == 'no'
            ? 'Без аудио'
            : track.title?.isNotEmpty == true
            ? track.title!
            : 'Аудиодорожка ${track.id}',
        language: track.language,
      ),
  ];
  @override
  List<VideoTrackChoice> get subtitleTracks => [
    for (final track in player.state.tracks.subtitle)
      if (!track.data &&
          !track.uri &&
          track.title?.startsWith('PepeHub external ') != true)
        VideoTrackChoice(
          track.id,
          track.id == 'auto'
              ? 'Автоматически'
              : track.id == 'no'
              ? 'Без субтитров'
              : track.title?.isNotEmpty == true
              ? track.title!
              : 'Дорожка ${track.id}',
          language: track.language,
          image: track.image == true,
        ),
  ];
  @override
  List<String> get subtitleText => player.state.subtitle;
  @override
  Future<void> waitForTracks() async {
    bool ready() =>
        player.state.tracks.video.any((t) => t.id != 'auto' && t.id != 'no') ||
        player.state.tracks.audio.any((t) => t.id != 'auto' && t.id != 'no') ||
        player.state.tracks.subtitle.any((t) => t.id != 'auto' && t.id != 'no');
    if (ready()) return;
    final completion = Completer<void>();
    void changed(dynamic _) {
      if (ready() && !completion.isCompleted) completion.complete();
    }

    final tracks = player.stream.tracks.listen(changed),
        duration = player.stream.duration.listen(changed);
    try {
      if (!ready()) {
        await completion.future.timeout(
          const Duration(seconds: 5),
          onTimeout: () {},
        );
      }
    } finally {
      await tracks.cancel();
      await duration.cancel();
    }
  }

  @override
  Future<void> selectAudioTrack(String id) async {
    final matches = player.state.tracks.audio.where((track) => track.id == id);
    if (matches.isEmpty) throw StateError('Аудиодорожка больше не доступна');
    await player.setAudioTrack(matches.first);
  }

  @override
  Future<void> selectSubtitleTrack(String id) async {
    _externalAssKey = null;
    final matches = player.state.tracks.subtitle.where(
      (track) => track.id == id,
    );
    if (matches.isEmpty) {
      throw StateError('Дорожка субтитров больше не доступна');
    }
    await player.setSubtitleTrack(matches.first);
  }

  @override
  Future<void> externalAss(String text, String key) async {
    if (_externalAssKey == key) return;
    await player.setSubtitleTrack(
      SubtitleTrack.data(text, title: 'PepeHub external $key'),
    );
    _externalAssKey = key;
  }

  @override
  Future<void> configureSubtitles(VideoPlaybackSettings settings) async {
    final native = player.platform;
    if (native is! NativePlayer) {
      throw UnsupportedError('Настройки доступны в нативном плеере');
    }
    await native.setProperty('sub-delay', '${settings.subtitleDelayMs / 1000}');
    await native.setProperty('audio-delay', '${settings.audioDelayMs / 1000}');
    await native.setProperty('sub-font-size', '${settings.fontSize * 2.5}');
    await native.setProperty(
      'sub-back-color',
      settings.subtitleBackground ? '#80000000' : '#00000000',
    );
    // Preserve authored ASS styling; plain-text subtitles use the settings above.
    await native.setProperty('sub-ass-override', 'no');
  }

  @override
  Future<void> close() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await player.dispose();
    dispose();
  }
}
