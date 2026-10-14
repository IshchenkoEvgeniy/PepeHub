import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'models.dart';
import 'video_engine.dart';

abstract class VideoPreviewDecoder {
  Future<Uint8List?> read(VideoLesson lesson, int positionMs);
  Future<void> close();
}

/// An independent paused decoder: never takes audio focus or writes activity.
class NativeVideoPreviewDecoder implements VideoPreviewDecoder {
  NativeVideoEngine? _engine;
  String? _source;
  @override
  Future<Uint8List?> read(VideoLesson lesson, int positionMs) async {
    var engine = _engine;
    if (engine == null) {
      MediaKit.ensureInitialized();
      final player = Player(
        configuration: const PlayerConfiguration(vo: 'null', muted: true),
      );
      engine = _engine = NativeVideoEngine(player, attachSurface: false);
      await player.setAudioTrack(AudioTrack.no());
      await player.setSubtitleTrack(SubtitleTrack.no());
      await player.setVideoTrack(VideoTrack.auto());
      await (player.platform as NativePlayer).setProperty('vf', 'scale=320:-2');
    }
    final source = '${lesson.id}:${lesson.mediaVersion}:${lesson.source}';
    if (_source != source) {
      await engine.open(lesson, positionMs: 0, speed: 1);
      _source = source;
    }
    await engine.seek(positionMs);
    final native = engine.player.platform as NativePlayer;
    for (var attempt = 0; attempt < 40; attempt++) {
      if (await native.getProperty('seeking') != 'yes') {
        final bytes = await engine.captureFrame();
        if (bytes != null && bytes.isNotEmpty) return bytes;
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    return null;
  }

  @override
  Future<void> close() async {
    final engine = _engine;
    _engine = null;
    _source = null;
    await engine?.close();
  }
}

/// Debounced latest-request-wins previews, bounded to 24 frames / 4 MiB.
class VideoSeekPreviews extends ChangeNotifier {
  final VideoPreviewDecoder Function() factory;
  final Duration debounce, idleTimeout;
  VideoSeekPreviews({
    VideoPreviewDecoder Function()? factory,
    this.debounce = const Duration(milliseconds: 180),
    this.idleTimeout = const Duration(seconds: 30),
  }) : factory = factory ?? NativeVideoPreviewDecoder.new;
  final Map<int, Uint8List> _cache = {};
  VideoPreviewDecoder? _decoder;
  Timer? _debounceTimer, _idleTimer;
  (VideoLesson, int, int)? _pending;
  bool _working = false, _disposed = false;
  int _epoch = 0, _bytes = 0;
  String? _source;
  Uint8List? image;
  int? positionMs;

  void request(VideoLesson lesson, int targetMs, int durationMs) {
    if (_disposed || durationMs <= 0) return;
    final source = '${lesson.id}:${lesson.mediaVersion}:${lesson.source}';
    if (_source != source) {
      _source = source;
      _cache.clear();
      _bytes = 0;
    }
    // Quantize to a second and keep away from EOF, where no frame may exist.
    final target = ((targetMs ~/ 1000) * 1000).clamp(
      0,
      (durationMs - 100).clamp(0, durationMs),
    );
    final epoch = ++_epoch;
    _debounceTimer?.cancel();
    _idleTimer?.cancel();
    image = _cache.remove(target);
    if (image != null) _cache[target] = image!;
    positionMs = target;
    notifyListeners();
    _pending = null;
    if (image == null) {
      _debounceTimer = Timer(debounce, () {
        _pending = (lesson, target, epoch);
        unawaited(_drain());
      });
    } else {
      _scheduleRelease();
    }
  }

  void dismiss() {
    _epoch++;
    _debounceTimer?.cancel();
    _pending = null;
    image = null;
    positionMs = null;
    if (!_disposed) notifyListeners();
    _scheduleRelease();
  }

  Future<void> _drain() async {
    if (_working || _disposed) return;
    _working = true;
    try {
      while (!_disposed && _pending != null) {
        final (lesson, target, epoch) = _pending!;
        _pending = null;
        try {
          final bytes = await (_decoder ??= factory()).read(lesson, target);
          if (_disposed || epoch != _epoch) continue;
          if (bytes != null && bytes.length <= 4 * 1024 * 1024) {
            _bytes += bytes.length;
            _cache[target] = bytes;
            while (_cache.length > 24 || _bytes > 4 * 1024 * 1024) {
              _bytes -= _cache.remove(_cache.keys.first)!.length;
            }
            image = bytes;
            notifyListeners();
          }
        } catch (_) {
          // An unseekable source still has the ordinary timeline and timestamp.
          await _release();
        }
      }
    } finally {
      _working = false;
      if (_disposed) {
        await _release();
      } else {
        _scheduleRelease();
      }
    }
  }

  void _scheduleRelease() {
    _idleTimer?.cancel();
    if (_disposed) return;
    _idleTimer = Timer(idleTimeout, () {
      if (!_working && _pending == null) unawaited(_release());
    });
  }

  Future<void> _release() async {
    final decoder = _decoder;
    _decoder = null;
    try {
      await decoder?.close();
    } catch (_) {
      /* The main decoder is independent. */
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _pending = null;
    _debounceTimer?.cancel();
    _idleTimer?.cancel();
    _cache.clear();
    if (!_working) unawaited(_release());
    super.dispose();
  }
}
