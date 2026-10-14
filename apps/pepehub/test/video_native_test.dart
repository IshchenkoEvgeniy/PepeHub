import 'dart:io';
import 'dart:async';

import 'package:drift/native.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/video/video_activity.dart';
import 'package:pepehub/video/video_controller.dart';
import 'package:pepehub/video/video_engine.dart';
import 'package:pepehub/video/video_repository.dart';
import 'package:pepehub/video/models.dart';
import 'package:pepehub/video/video_seek_previews.dart';
import 'package:pepehub/video/video_tools.dart';

/// Opt-in decoder check. The test fixture is generated locally with FFmpeg.
/// It does not validate Flutter texture rendering or GPU acceleration.
void main() {
  final library = Platform.environment['PEPEHUB_TEST_LIBMPV'];
  final fixture = Platform.environment['PEPEHUB_VIDEO_FIXTURE'];
  final available = Platform.isWindows && library != null && fixture != null;
  test(
    'native frame capture, audio-only switching and chapters use the decoder',
    () async {
      MediaKit.ensureInitialized(libmpv: library);
      final native = Player(
        configuration: const PlayerConfiguration(vo: 'null', muted: true),
      );
      final engine = NativeVideoEngine(native, attachSurface: false);
      addTearDown(engine.close);
      await native.setVideoTrack(VideoTrack.auto());
      final ready = native.stream.position
          .firstWhere((time) => time.inMilliseconds >= 200)
          .timeout(const Duration(seconds: 10));
      await engine.open(
        VideoLesson(
          id: 'native',
          itemId: 'native',
          title: 'Native',
          module: '',
          source:
              Platform.environment['PEPEHUB_VIDEO_CHAPTER_FIXTURE'] ?? fixture!,
          mediaVersion: 'v1',
          ordinal: 0,
        ),
        positionMs: 0,
        speed: 1,
      );
      await engine.play();
      await ready;
      await engine.pause();
      final frame = await engine.captureFrame();
      expect(frame, isNotNull);
      expect(frame!.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
      await engine.setAudioOnly(true);
      expect(await (native.platform as NativePlayer).getProperty('vid'), 'no');
      await engine.setAudioOnly(false);
      expect(
        await (native.platform as NativePlayer).getProperty('vid'),
        isNot('no'),
      );
      final chapters = await engine.readChapters();
      if (Platform.environment['PEPEHUB_VIDEO_CHAPTER_FIXTURE'] != null) {
        expect(chapters.map((chapter) => chapter.title), [
          'Introduction',
          'Practice',
        ]);
        expect(chapters.map((chapter) => chapter.startMs), [0, 3000]);
      }
      final preview = NativeVideoPreviewDecoder();
      addTearDown(preview.close);
      final lesson = VideoLesson(
        id: 'preview',
        itemId: 'preview',
        title: 'Preview',
        module: '',
        source: fixture!,
        mediaVersion: 'v1',
        ordinal: 0,
      );
      final before = engine.state.positionMs;
      final first = await preview.read(lesson, 0),
          second = await preview.read(lesson, 3000),
          again = await preview.read(lesson, 0);
      expect(first, isNotNull);
      expect(second, isNotNull);
      expect(sha256.convert(first!), isNot(sha256.convert(second!)));
      expect(sha256.convert(again!), sha256.convert(first));
      expect(
        engine.state.positionMs,
        inInclusiveRange(before - 150, before + 150),
      );
      expect(engine.state.playing, isFalse);
    },
    skip: available ? false : 'Native Windows fixture is not configured.',
  );
  test('native controller repeats a short fragment without counting seeks or speaking pauses', () async {
    MediaKit.ensureInitialized(libmpv: library);
    final db = AppDatabase(NativeDatabase.memory());
    final videos = VideoRepository(Repository(db));
    final item = await videos.addSources(
      title: 'Native loop',
      sources: [VideoSourceDraft(fixture!, 'Native loop')],
    );
    final native = Player(
      configuration: const PlayerConfiguration(vo: 'null', muted: true),
    );
    await native.setVideoTrack(VideoTrack.auto());
    final engine = NativeVideoEngine(native, attachSurface: false);
    final controller = VideoPlaybackController(
      repository: videos,
      engine: engine,
      lessons: await videos.lessons(itemId: item.id),
      checkpointPeriod: null,
    );
    addTearDown(() async {
      await controller.close();
      controller.dispose();
      await db.close();
    });
    final duration = native.stream.duration
        .firstWhere((duration) => duration.inMilliseconds > 0)
        .timeout(const Duration(seconds: 10));
    await controller.load(0, play: false);
    await duration;
    await controller.setSpeed(1.5);
    final finished = Completer<void>();
    void changed() {
      if (controller.loopCompletedPasses == 3 &&
          !controller.loopRunning &&
          !finished.isCompleted) {
        finished.complete();
      }
    }

    controller.addListener(changed);
    await controller.startLoop(
      const VideoLoopSettings(
        startMs: 1000,
        endMs: 1500,
        totalPasses: 3,
        pauseMs: 200,
      ),
    );
    await finished.future.timeout(const Duration(seconds: 10));
    controller.removeListener(changed);
    await controller.flush();
    expect(controller.loopCompletedPasses, 3);
    expect(engine.state.playing, isFalse);
    expect(controller.seekHistory, isEmpty);
    final stats = analyzeVideo(VideoAnalysisRequest(await videos.intervals()));
    // Position updates come from the decoder; frame cadence prevents exact millisecond equality.
    expect(stats.wallMs, inInclusiveRange(500, 1800));
    expect(stats.firstMs, inInclusiveRange(300, 900));
    expect(stats.repeatedMs, greaterThan(450));
    expect(stats.mediaMs, greaterThan(stats.wallMs));
    await controller.seek(6000);
    await controller.close();
    expect(
      (await videos.progress(controller.lessons.single))!.positionMs,
      inInclusiveRange(5850, 6150),
    );
  }, skip: available ? false : 'Set native Windows decoder and fixture paths.');
  test(
    'native decoder opens MP4, restores time, changes speed and seeks',
    () async {
      MediaKit.ensureInitialized(libmpv: library);
      final player = Player(
        configuration: const PlayerConfiguration(vo: 'null', muted: true),
      );
      addTearDown(player.dispose);
      await player.setVideoTrack(VideoTrack.auto());
      final duration = player.stream.duration
          .firstWhere((value) => value.inMilliseconds > 0)
          .timeout(const Duration(seconds: 10));
      await player.open(
        Media(fixture!, start: const Duration(seconds: 2)),
        play: false,
      );
      expect((await duration).inSeconds, greaterThanOrEqualTo(7));
      await player.setRate(1.5);
      final progressed = player.stream.position
          .firstWhere((value) => value.inMilliseconds >= 3000)
          .timeout(const Duration(seconds: 10));
      await player.play();
      expect((await progressed).inMilliseconds, greaterThanOrEqualTo(3000));
      await player.pause();
      final sought = player.stream.position
          .firstWhere((value) => value.inMilliseconds < 2000)
          .timeout(const Duration(seconds: 10));
      await player.seek(const Duration(seconds: 1));
      expect((await sought).inMilliseconds, lessThan(2000));
      expect(player.state.rate, 1.5);
      expect(player.state.videoParams.w, 320);
      expect(player.state.videoParams.h, 180);
    },
    skip: available ? false : 'Set PEPEHUB_TEST_LIBMPV and PEPEHUB_VIDEO_FIXTURE for the native Windows check.',
  );

  test('native decoder reads a direct HTTP source with byte ranges', () async {
    MediaKit.ensureInitialized(libmpv: library);
    final source = File(fixture!);
    final length = await source.length();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final range = RegExp(r'^bytes=(\d+)-(\d*)$')
          .firstMatch(request.headers.value('range') ?? '');
      final start = range == null ? 0 : int.parse(range[1]!);
      final end = range == null || range[2]!.isEmpty
          ? length - 1
          : int.parse(range[2]!);
      request.response.headers.contentType = ContentType('video', 'mp4');
      request.response.headers.set('Accept-Ranges', 'bytes');
      if (range != null) {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          'Content-Range',
          'bytes $start-$end/$length',
        );
      }
      request.response.contentLength = end - start + 1;
      try {
        await request.response.addStream(source.openRead(start, end + 1));
      } finally {
        await request.response.close();
      }
    });
    final player = Player(
      configuration: const PlayerConfiguration(vo: 'null', muted: true),
    );
    addTearDown(player.dispose);
    await player.setVideoTrack(VideoTrack.auto());
    final videoReady = player.stream.videoParams
        .firstWhere((params) => params.w == 320 && params.h == 180)
        .timeout(const Duration(seconds: 10));
    final duration = player.stream.duration
        .firstWhere((value) => value.inMilliseconds > 0)
        .timeout(const Duration(seconds: 10));
    await player.open(
      Media('http://127.0.0.1:${server.port}/lesson.mp4'),
      play: false,
    );
    expect((await duration).inSeconds, greaterThanOrEqualTo(7));
    await player.play();
    expect((await videoReady).w, 320);
  }, skip: available ? false : 'Native Windows fixture is not configured.');
}
