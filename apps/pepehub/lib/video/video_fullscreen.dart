import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Presentation only: never owns or reopens the playback engine.
class VideoFullscreenHost extends ChangeNotifier {
  static const channel = MethodChannel('pepehub/video-window');
  static VideoFullscreenHost? _channelOwner;
  bool _disposed = false;
  bool pip = false, supportsPip = false, supportsMiniWindow = false;
  bool supportsOrientation = false, supportsBrightness = false;
  bool _available = false;
  Future<void> Function(String)? onAction;
  Future<void> initialize() async {
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.windows) {
      return;
    }
    _channelOwner = this;
    channel.setMethodCallHandler((call) async {
      if (_disposed) return;
      if (call.method == 'pipChanged') {
        pip = call.arguments == true;
        notifyListeners();
      } else if (call.method == 'pipAction') {
        await onAction?.call(call.arguments as String);
      }
    });
    try {
      final caps = await channel.invokeMapMethod<String, dynamic>(
        'getCapabilities',
      );
      if (_disposed) return;
      supportsPip = caps?['pip'] == true;
      _available = caps != null;
      supportsMiniWindow = caps?['miniWindow'] == true;
      supportsOrientation = caps?['orientation'] == true;
      supportsBrightness = caps?['brightness'] == true;
      notifyListeners();
    } on MissingPluginException {
      /* Surface-free tests have no native host. */
    }
  }

  Future<void> updatePlayback({
    required bool playing,
    required bool visual,
    required double aspectRatio,
  }) async {
    if (!_available) return;
    await channel.invokeMethod<void>('setPlayback', {
      'playing': playing,
      'visual': visual,
      'aspectRatio': aspectRatio.clamp(.5, 2.35),
    });
  }

  Future<void> enterPip() async {
    if (!supportsPip) {
      throw UnsupportedError('На этом устройстве PiP недоступен');
    }
    final entered = await channel.invokeMethod<bool>('enterPip');
    if (entered != true) throw StateError('Система не разрешила режим PiP');
  }

  Future<void> setMiniWindow(bool enabled) async {
    if (!supportsMiniWindow) throw UnsupportedError('Мини-окно недоступно');
    await channel.invokeMethod<void>('setMiniWindow', enabled);
  }

  Future<void> setFullscreen(bool enabled) async {
    if (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.android) {
      await channel.invokeMethod<void>('setFullscreen', enabled);
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      await SystemChrome.setEnabledSystemUIMode(
        enabled ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      );
    }
  }

  /// Locks the phone to the video's orientation in fullscreen:
  /// `landscape`, `portrait`, or null to give rotation back.
  Future<void> setOrientation(String? mode) async {
    if (!supportsOrientation) return;
    await channel.invokeMethod<void>('setOrientation', mode ?? 'restore');
  }

  /// Brightness of the app window, 0..1.
  Future<double?> brightness() async {
    if (!supportsBrightness) return null;
    return (await channel.invokeMethod<num>('getBrightness'))?.toDouble();
  }

  /// Changes only the app window; null returns it to the system level.
  Future<void> setBrightness(double? value) async {
    if (!supportsBrightness) return;
    await channel.invokeMethod<void>('setBrightness', value ?? -1.0);
  }

  @override
  void dispose() {
    _disposed = true;
    if (identical(_channelOwner, this)) {
      channel.setMethodCallHandler(null);
      _channelOwner = null;
    }
    super.dispose();
  }
}
