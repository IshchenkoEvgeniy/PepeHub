import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android reader window: volume buttons turn pages and the phone navigation
/// bar can stay visible. The keys are intercepted natively, so they work
/// regardless of which Flutter widget has the keyboard focus, and the volume
/// itself does not change while the option is on.
class ReaderWindow {
  ReaderWindow({required this.onVolumeKey});

  static const channel = MethodChannel('pepehub/reader-window');
  static ReaderWindow? _active;

  /// +1 — volume down (forward), −1 — volume up (back).
  final ValueChanged<int> onVolumeKey;
  ({bool volumeKeys, bool navigationBar})? _sent;

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  void configure({required bool volumeKeys, required bool navigationBar}) {
    if (!supported) return;
    if (!identical(_active, this)) {
      _active = this;
      _sent = null;
      channel.setMethodCallHandler(_handle);
    }
    final next = (volumeKeys: volumeKeys, navigationBar: navigationBar);
    if (_sent == next) return;
    _sent = next;
    unawaited(
      _send('configure', {
        'volumeKeys': volumeKeys,
        'navigationBar': navigationBar,
      }),
    );
  }

  void reset() {
    if (!supported || !identical(_active, this)) return;
    _active = null;
    _sent = null;
    channel.setMethodCallHandler(null);
    unawaited(_send('reset'));
  }

  /// Android share sheet for a quotation; false where it is unavailable.
  static Future<bool> shareText(String text) async {
    if (!supported) return false;
    try {
      await channel.invokeMethod<void>('shareText', text);
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// Battery charge for the reader status line; null where unknown.
  static Future<({int level, bool charging})?> battery() async {
    if (!supported) return null;
    try {
      final value = await channel.invokeMethod<Map<Object?, Object?>>(
        'battery',
      );
      final level = value?['level'];
      if (level is! num) return null;
      return (level: level.toInt(), charging: value?['charging'] == true);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<void> _handle(MethodCall call) async {
    if (call.method == 'volumeKey' && identical(_active, this)) {
      final direction = call.arguments;
      if (direction is num) onVolumeKey(direction.sign.toInt());
    }
  }

  Future<void> _send(String method, [Object? arguments]) async {
    try {
      await channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // Widget tests and older native hosts have no reader window channel.
    } on PlatformException {
      // The volume buttons simply keep changing the volume.
    }
  }
}
