import 'package:flutter/foundation.dart';

import '../audio/audio_folder.dart';

bool isMp3Source(String path, String filename) =>
    filename.toLowerCase().endsWith('.mp3') ||
    audioSourceUri(path).path.toLowerCase().endsWith('.mp3');

/// Android's MP3 extractor must see the audio length without trailing APE art.
/// The private provider resolves the bounds lazily when a decoder opens a file.
Uri audioPlaybackUri(String path, String filename) {
  final source = audioSourceUri(path);
  if (defaultTargetPlatform != TargetPlatform.android ||
      !isMp3Source(path, filename)) {
    return source;
  }
  return Uri(
    scheme: 'content',
    host: 'app.pepehub.pepehub.audioplayback',
    path: '/audio.mp3',
    queryParameters: {'source': source.toString()},
  );
}
