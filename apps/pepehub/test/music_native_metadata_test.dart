import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:pepehub/video/models.dart';
import 'package:pepehub/video/video_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['PEPEHUB_TEST_LIBMPV'];
  final fixture = Platform.environment['PEPEHUB_TEST_TAGGED_MP3'];
  test(
    'native decoder reads artist album title track and caches embedded art',
    () async {
      final support = await Directory.systemTemp.createTemp(
        'pepehub-music-tags-',
      );
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => support.path);
      MediaKit.ensureInitialized(libmpv: library);
      final player = Player(
        configuration: const PlayerConfiguration(vo: 'null', muted: true),
      );
      final engine = NativeVideoEngine(player, attachSurface: false);
      try {
        await (player.platform as NativePlayer).setProperty('ao', 'null');
        final ready = player.stream.duration
            .firstWhere((duration) => duration.inSeconds >= 3)
            .timeout(const Duration(seconds: 10));
        final song = VideoLesson(
          id: 'tagged',
          itemId: 'playlist',
          title: 'Original',
          module: '',
          source: fixture!,
          mediaVersion: 'v1',
          ordinal: 0,
          audio: true,
        );
        await engine.open(song, positionMs: 0, speed: 1);
        final metadata = await engine.readMusicMetadata(song);
        await ready;
        expect(metadata!.$1, 'Music native title');
        expect(metadata.$2.artist, 'Test artist');
        expect(metadata.$2.album, 'Test album');
        expect(metadata.$2.trackNumber, 2);
        expect(metadata.$2.coverPath, isNotNull);
        final cover = File(metadata.$2.coverPath!);
        expect(await cover.exists(), isTrue);
        expect((await cover.readAsBytes()).take(4), [137, 80, 78, 71]);
        expect(
          (await engine.readMusicMetadata(song))!.$2.coverPath,
          cover.path,
        );
      } finally {
        await engine.close();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        await support.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows || library == null || fixture == null
        ? 'Set PEPEHUB_TEST_LIBMPV and PEPEHUB_TEST_TAGGED_MP3 (title/artist/album/track + artwork fixture).'
        : false,
  );
}
