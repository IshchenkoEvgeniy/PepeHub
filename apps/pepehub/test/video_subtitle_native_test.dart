import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/video/video_captions_controller.dart';
import 'package:pepehub/video/video_controller.dart';
import 'package:pepehub/video/video_engine.dart';
import 'package:pepehub/video/video_repository.dart';
import 'package:pepehub/video/video_subtitles.dart';

const assSample = '''[Script Info]
ScriptType: v4.00+
PlayResX: 320
PlayResY: 180
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,22,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,ASS phrase
''';

void main() {
  final library = Platform.environment['PEPEHUB_TEST_LIBMPV'];
  final fixture = Platform.environment['PEPEHUB_VIDEO_TRACK_FIXTURE'];
  final available = Platform.isWindows && library != null && fixture != null;
  test(
    'native tracks restore before play, embedded text and ASS switch, delays reach mpv',
    () async {
      MediaKit.ensureInitialized(libmpv: library);
      final db = AppDatabase(NativeDatabase.memory());
      final store = VideoRepository(Repository(db));
      final item = await store.addSources(
        title: 'Multitrack',
        sources: [VideoSourceDraft(fixture!, 'Lesson')],
      );
      final lessons = await store.lessons(itemId: item.id);
      await store.savePlaybackSettings(
        lessons.single,
        const VideoPlaybackSettings(
          audio: '2',
          subtitle: 'embedded:1',
          subtitleDelayMs: 500,
          audioDelayMs: 100,
        ),
      );
      final native = Player(
        configuration: const PlayerConfiguration(
          vo: 'null',
          muted: true,
          libass: true,
        ),
      );
      await native.setVideoTrack(VideoTrack.auto());
      final engine = NativeVideoEngine(
        native,
        attachSurface: false,
        rendersNativeSubtitles: true,
      );
      late VideoCaptionsController captions;
      final playback = VideoPlaybackController(
        repository: store,
        engine: engine,
        lessons: lessons,
        checkpointPeriod: null,
        configureLesson: (lesson) => captions.loadLesson(lesson),
      );
      captions = VideoCaptionsController(store, playback);
      addTearDown(() async {
        captions.dispose();
        await playback.close();
        playback.dispose();
        await db.close();
      });
      await playback.load(0, play: false);
      expect(
        engine.audioTracks.where((track) => track.id == '1' || track.id == '2'),
        hasLength(2),
      );
      expect(native.state.track.audio.id, '2');
      expect(native.state.track.subtitle.id, '1');
      final api = native.platform as NativePlayer;
      expect(
        double.parse(await api.getProperty('sub-delay')),
        closeTo(.5, .001),
      );
      expect(
        double.parse(await api.getProperty('audio-delay')),
        closeTo(.1, .001),
      );
      expect(await api.getProperty('sub-back-color'), '#80000000');
      expect(await api.getProperty('sub-ass-override'), 'no');
      final text = native.stream.subtitle
          .firstWhere((lines) => lines.any((line) => line.contains('Hello')))
          .timeout(const Duration(seconds: 8));
      await playback.seek(1600);
      await playback.play();
      await text;
      await playback.pause();
      final ass = await store.importSubtitles(
        lessons.single,
        name: 'styled.ass',
        text: assSample,
        format: VideoSubtitleFormat.ass,
      );
      await captions.loadLesson(lessons.single);
      final assText = native.stream.subtitle
          .firstWhere(
            (lines) => lines.any((line) => line.contains('ASS phrase')),
          )
          .timeout(const Duration(seconds: 8));
      await captions.save(
        VideoPlaybackSettings(subtitle: 'external:${ass.id}'),
      );
      await playback.seek(1800);
      await playback.play();
      await assText;
      await playback.pause();
      final trackCount = native.state.tracks.subtitle.length;
      await captions.save(
        VideoPlaybackSettings(subtitle: 'external:${ass.id}', fontSize: 26),
      );
      expect(native.state.tracks.subtitle.length, trackCount);
      expect(
        engine.subtitleTracks.any(
          (track) => track.title.startsWith('PepeHub external '),
        ),
        isFalse,
      );
      await captions.save(const VideoPlaybackSettings(subtitle: 'no'));
      expect(native.state.track.subtitle.id, 'no');
    },
    skip: available ? false : 'Set PEPEHUB_TEST_LIBMPV and PEPEHUB_VIDEO_TRACK_FIXTURE for multitrack native checks.',
  );
}
