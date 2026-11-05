import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/media/audio_source.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);
  test('Android MP3 playback preserves SAF and file URIs inside the bounded provider', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    for (final path in [
      'content://documents/tree/root/document/root%2F01%20Глава.mp3',
      '/storage/emulated/0/Books/01 Глава.mp3',
    ]) {
      final uri = audioPlaybackUri(path, '01 Глава.MP3');
      expect(uri.authority, 'app.pepehub.pepehub.audioplayback');
      expect(
        Uri.parse(uri.queryParameters['source']!).scheme,
        path.startsWith('content:') ? 'content' : 'file',
      );
    }
    expect(
      audioPlaybackUri('content://documents/chapter', 'chapter.m4b').toString(),
      'content://documents/chapter',
    );
  });
  test('desktop MP3 playback retains the original source', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(audioPlaybackUri('C:/Books/one.mp3', 'one.mp3').scheme, 'file');
  });
}
