import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Keeps the screen on while a book is actively read.
///
/// Every [touch] (a tap, a page turn) extends the wake period; after [idle]
/// without activity the system may turn the screen off again, so a reader left
/// open on the table does not drain the battery.
class ReaderKeepAwake {
  ReaderKeepAwake({this.idle = const Duration(minutes: 10)});

  static const channel = MethodChannel('pepehub/video-window');
  final Duration idle;
  Timer? _timer;
  bool _enabled = false, _awake = false, _disposed = false;

  bool get awake => _awake;

  set enabled(bool value) {
    if (_disposed || _enabled == value) return;
    _enabled = value;
    if (value) {
      touch();
    } else {
      _timer?.cancel();
      _set(false);
    }
  }

  void touch() {
    if (!_enabled || _disposed) return;
    _timer?.cancel();
    _timer = Timer(idle, () => _set(false));
    _set(true);
  }

  void dispose() {
    _timer?.cancel();
    _set(false);
    _disposed = true;
  }

  void _set(bool value) {
    if (_awake == value || _disposed) return;
    _awake = value;
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.windows) {
      return;
    }
    unawaited(_send(value));
  }

  Future<void> _send(bool value) async {
    try {
      await channel.invokeMethod<void>('setReadingAwake', value);
    } on MissingPluginException {
      // Widget tests and older native hosts have no window channel.
    } on PlatformException {
      // The screen simply follows the system timeout.
    }
  }
}
