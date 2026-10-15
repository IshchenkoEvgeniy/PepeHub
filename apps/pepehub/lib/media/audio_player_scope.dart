import 'package:flutter/widgets.dart';

import 'audio_controller.dart';

/// Shares the existing queue with page chrome, including routes above a section.
class AudioPlayerScope extends InheritedWidget {
  final AudioController? controller;
  const AudioPlayerScope({
    super.key,
    required this.controller,
    required super.child,
  });

  static AudioController? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AudioPlayerScope>()
      ?.controller;

  @override
  bool updateShouldNotify(AudioPlayerScope oldWidget) =>
      controller != oldWidget.controller;
}
