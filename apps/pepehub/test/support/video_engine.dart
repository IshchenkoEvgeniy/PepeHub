import 'package:pepehub/video/models.dart';
import 'package:pepehub/video/video_engine.dart';

class TestVideoEngine extends VideoPlaybackEngine {
  VideoEngineState _state = const VideoEngineState(durationMs: 120000);
  bool closed = false, failOpen = false;
  final List<int> seeks = [];
  @override
  VideoEngineState get state => _state;

  void tick(
    int positionMs, {
    bool? playing,
    bool? buffering,
    bool? completed,
    double? speed,
    double? volume,
  }) {
    _state = VideoEngineState(
      positionMs: positionMs,
      durationMs: _state.durationMs,
      playing: playing ?? _state.playing,
      buffering: buffering ?? _state.buffering,
      completed: completed ?? _state.completed,
      speed: speed ?? _state.speed,
      volume: volume ?? _state.volume,
    );
    notifyListeners();
  }

  @override
  Future<void> open(
    VideoLesson lesson, {
    required int positionMs,
    required double speed,
  }) async {
    if (failOpen) throw StateError('Unavailable source');
    tick(
      positionMs,
      playing: false,
      buffering: false,
      completed: false,
      speed: speed,
    );
  }

  @override
  Future<void> play() async => tick(_state.positionMs, playing: true);
  @override
  Future<void> pause() async => tick(_state.positionMs, playing: false);
  @override
  Future<void> seek(int positionMs) async {
    seeks.add(positionMs);
    tick(positionMs, completed: false);
  }

  @override
  Future<void> setSpeed(double speed) async =>
      tick(_state.positionMs, speed: speed);
  @override
  Future<void> setVolume(double volume) async =>
      tick(_state.positionMs, volume: volume);
  @override
  Future<void> close() async {
    if (!closed) {
      closed = true;
      dispose();
    }
  }
}
