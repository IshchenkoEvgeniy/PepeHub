import 'dart:convert';

import 'package:drift/native.dart';
import 'package:enough_convert/enough_convert.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/video/models.dart';
import 'package:pepehub/video/video_activity.dart';
import 'package:pepehub/video/video_captions_controller.dart';
import 'package:pepehub/video/video_controller.dart';
import 'package:pepehub/video/video_engine.dart';
import 'package:pepehub/video/video_repository.dart';
import 'package:pepehub/video/video_subtitle_import.dart';
import 'package:pepehub/video/video_subtitles.dart';

import 'support/video_engine.dart';

const englishSrt =
    '1\n00:00:01,000 --> 00:00:03,000\nHello &amp; welcome.\n\n2\n00:00:03,000 --> 00:00:05,000\nI had already finished.\n';
const russianVtt =
    'WEBVTT\n\n00:01.000 --> 00:03.000\nПривет!\n\n00:03.000 --> 00:05.000\nЯ уже закончил.\n';

class CaptionTestEngine extends TestVideoEngine {
  String selectedAudio = 'auto', selectedSubtitle = 'auto';
  String? ass;
  bool failSelection = false;
  bool nativeSubtitles = false;
  VideoPlaybackSettings configuration = const VideoPlaybackSettings();
  final List<String> audioAtPlay = [];
  @override
  bool get canSelectTracks => true;
  @override
  bool get rendersNativeSubtitles => nativeSubtitles;
  @override
  List<VideoTrackChoice> get audioTracks => const [
    VideoTrackChoice('auto', 'Автоматически'),
    VideoTrackChoice('no', 'Без аудио'),
    VideoTrackChoice('1', 'English', language: 'eng'),
    VideoTrackChoice('2', 'Español', language: 'spa'),
  ];
  @override
  List<VideoTrackChoice> get subtitleTracks => const [
    VideoTrackChoice('auto', 'Автоматически'),
    VideoTrackChoice('no', 'Без субтитров'),
    VideoTrackChoice('1', 'English CC'),
  ];
  @override
  List<String> get subtitleText =>
      selectedSubtitle == 'no' ? [] : ['Embedded caption'];
  @override
  Future<void> selectAudioTrack(String id) async {
    if (failSelection && id == '2') throw StateError('Track disappeared');
    selectedAudio = id;
  }

  @override
  Future<void> selectSubtitleTrack(String id) async {
    selectedSubtitle = id;
  }

  @override
  Future<void> externalAss(String text, String key) async {
    ass = text;
    selectedSubtitle = 'ass';
  }

  @override
  Future<void> configureSubtitles(VideoPlaybackSettings settings) async {
    configuration = settings;
  }

  @override
  Future<void> play() async {
    audioAtPlay.add(selectedAudio);
    await super.play();
  }
}

class CaptionHarness {
  final db = AppDatabase(NativeDatabase.memory());
  late final repository = Repository(db), videos = VideoRepository(repository);
  final engine = CaptionTestEngine();
  late VideoPlaybackController playback;
  late VideoCaptionsController captions;
  late List<VideoLesson> lessons;
  int ms = 0;
  Future<void> prepare({bool play = true}) async {
    final item = await videos.addSources(
      title: 'English course',
      sources: const [
        VideoSourceDraft('1.mp4', 'First'),
        VideoSourceDraft('2.mp4', 'Second'),
      ],
    );
    lessons = await videos.lessons(itemId: item.id);
    playback = VideoPlaybackController(
      repository: videos,
      engine: engine,
      lessons: lessons,
      checkpointPeriod: null,
      configureLesson: (lesson) => captions.loadLesson(lesson),
      nowMonotonic: () => ms,
      now: () => DateTime.utc(2026, 10, 14).add(Duration(milliseconds: ms)),
    );
    captions = VideoCaptionsController(videos, playback);
    if (play) await playback.load(0);
  }

  Future<void> close() async {
    captions.dispose();
    await playback.close();
    playback.dispose();
    await db.close();
  }

  Future<VideoSubtitleRecord?> import(
    String name,
    String text, {
    bool translation = false,
  }) => captions.importFile(
    VideoSubtitleFile(name, Uint8List.fromList(utf8.encode(text))),
    VideoSubtitleEncoding.automatic,
    translation: translation,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('SRT preserves text, overlaps and end-exclusive boundaries', () {
    final doc = parseVideoSubtitles(
      const VideoSubtitleParseRequest(
        '2\r\n00:00:02,000 --> 00:00:04,000\r\n<i>Second</i>\r\n\r\n1\r\n00:00:01,000 --> 00:00:03,000\r\nHello &amp;\r\nwelcome.\r\n',
        VideoSubtitleFormat.srt,
      ),
    );
    expect(doc.cues.first.startMs, 1000);
    expect(doc.cues.first.text, 'Hello &\nwelcome.');
    expect(doc.activeAt(2000).map((cue) => cue.text), [
      'Hello &\nwelcome.',
      'Second',
    ]);
    expect(doc.activeAt(3000).single.text, 'Second');
    expect(doc.activeAt(4000), isEmpty);
    expect(doc.nextIndex(2000), 2);
  });
  test(
    'WebVTT metadata, cue IDs, settings and voiced text normalize safely',
    () {
      final doc = parseVideoSubtitles(
        const VideoSubtitleParseRequest(
          'WEBVTT\nKind: captions\n\nNOTE comment\nignored --> arrow\n\nSTYLE\n::cue { color: lime; }\n\nREGION\nid:main\n\nintro\n00:01.000 --> 00:03.250 align:start position:10%\n<v Alice><b>Hello</b> &lt;world&gt;\n',
          VideoSubtitleFormat.vtt,
        ),
      );
      expect(doc.cues.single.text, 'Hello <world>');
      expect(doc.cues.single.endMs, 3250);
    },
  );
  test('BOM and explicit legacy encodings retain Unicode without silent replacement', () {
    expect(
      decodeVideoSubtitles([239, 187, 191, ...utf8.encode('Hello')]),
      'Hello',
    );
    final units = 'Привет 😊'.codeUnits;
    expect(
      decodeVideoSubtitles([
        255,
        254,
        for (final code in units) ...[code & 255, code >> 8],
      ]),
      'Привет 😊',
    );
    expect(
      decodeVideoSubtitles([
        254,
        255,
        for (final code in units) ...[code >> 8, code & 255],
      ]),
      'Привет 😊',
    );
    expect(
      decodeVideoSubtitles(
        const Windows1251Codec().encode('Привет'),
        encoding: VideoSubtitleEncoding.windows1251,
      ),
      'Привет',
    );
    expect(
      decodeVideoSubtitles(
        const Windows1252Codec().encode('café'),
        encoding: VideoSubtitleEncoding.windows1252,
      ),
      'café',
    );
    expect(() => decodeVideoSubtitles([255]), throwsFormatException);
    expect(() => decodeVideoSubtitles([255, 254, 0]), throwsFormatException);
    expect(
      () => decodeVideoSubtitles([255, 254, 0, 216]),
      throwsFormatException,
    );
  });
  test('bad clocks, empty cues, unsupported headers and oversized input are rejected', () {
    for (final text in [
      '',
      '1\n00:61:00,000 --> 01:00:00,000\nWrong',
      '1\n00:00:05,000 --> 00:00:01,000\nWrong',
      'broken',
    ]) {
      expect(
        () => parseVideoSubtitles(
          VideoSubtitleParseRequest(text, VideoSubtitleFormat.srt),
        ),
        throwsFormatException,
      );
    }
    expect(
      () => parseVideoSubtitles(
        const VideoSubtitleParseRequest(englishSrt, VideoSubtitleFormat.vtt),
      ),
      throwsFormatException,
    );
    expect(
      () => decodeVideoSubtitles(Uint8List(maxVideoSubtitleBytes + 1)),
      throwsFormatException,
    );
    expect(
      parseVideoSubtitles(
        const VideoSubtitleParseRequest(
          '[Script Info]\n[Events]\nFormat: Text\n',
          VideoSubtitleFormat.ass,
        ),
      ).cues,
      isEmpty,
    );
  });
  test('large overlapping transcript locates recent phrases without scanning all earlier cues', () {
    String time(int ms) =>
        '${(ms ~/ 3600000).toString().padLeft(2, '0')}:${(ms ~/ 60000 % 60).toString().padLeft(2, '0')}:${(ms ~/ 1000 % 60).toString().padLeft(2, '0')}.${(ms % 1000).toString().padLeft(3, '0')}';
    final text = [
      'WEBVTT',
      '',
      '00:00:00.000 --> 09:00:00.000\nLong cue',
      for (var i = 0; i < 5000; i++)
        '${time(i * 2000)} --> ${time(i * 2000 + 500)}\nPhrase $i',
    ].join('\n\n');
    final timer = Stopwatch()..start();
    final doc = parseVideoSubtitles(
      VideoSubtitleParseRequest(text, VideoSubtitleFormat.vtt),
    );
    final parseMs = timer.elapsedMilliseconds;
    timer.reset();
    for (var i = 4000; i < 5000; i++) {
      expect(doc.activeAt(i * 2000 + 100).map((cue) => cue.text), [
        'Long cue',
        'Phrase $i',
      ]);
    }
    debugPrint(
      'Subtitles: ${doc.cues.length} cues, parse ${parseMs}ms, 1000 lookups ${timer.elapsedMilliseconds}ms',
    );
  });
  test(
    'imports deduplicate locally and malformed data does not replace captions',
    () async {
      final h = CaptionHarness();
      await h.prepare();
      addTearDown(h.close);
      final first = (await h.import('English.srt', englishSrt))!;
      final duplicate = (await h.import('Renamed.srt', englishSrt))!;
      expect(duplicate.id, first.id);
      expect(h.captions.records, hasLength(1));
      expect(h.engine.selectedSubtitle, 'no');
      expect(h.captions.settings.subtitle, 'external:${first.id}');
      await expectLater(
        h.import('Broken.srt', 'broken'),
        throwsFormatException,
      );
      expect(h.captions.settings.subtitle, 'external:${first.id}');
      expect(await h.videos.subtitles(h.lessons.first), hasLength(1));
      expect(await h.repository.pending(), isEmpty);
    },
  );
  test('dual captions have independent delays and hiding translation changes no coverage', () async {
    final h = CaptionHarness();
    await h.prepare();
    addTearDown(h.close);
    await h.import('English.srt', englishSrt);
    await h.import('Russian.vtt', russianVtt, translation: true);
    await h.captions.save(
      VideoPlaybackSettings.fromJson({
        ...h.captions.settings.toJson(),
        'translationDelayMs': 1000,
      }),
    );
    h.ms = 1500;
    h.engine.tick(1500);
    expect(h.captions.primaryText, 'Hello & welcome.');
    expect(h.captions.translationText, '');
    h.ms = 2500;
    h.engine.tick(2500);
    expect(h.captions.translationText, 'Привет!');
    await h.captions.save(
      VideoPlaybackSettings.fromJson({
        ...h.captions.settings.toJson(),
        'translationVisible': false,
      }),
    );
    expect(h.captions.translationText, '');
    await h.playback.pause();
    final stats = analyzeVideo(
      VideoAnalysisRequest(await h.videos.intervals()),
    );
    expect(stats.mediaMs, 2500);
    expect(stats.wallMs, 2500);
  });
  test(
    'preferences restore before play and cannot cross a queued lesson change',
    () async {
      final h = CaptionHarness();
      await h.prepare(play: false);
      addTearDown(h.close);
      await h.videos.savePlaybackSettings(
        h.lessons.first,
        const VideoPlaybackSettings(
          audio: '2',
          subtitle: 'embedded:1',
          subtitleDelayMs: 1200,
          audioDelayMs: -100,
        ),
      );
      await h.playback.load(0);
      expect(h.engine.audioAtPlay, ['2']);
      expect(h.engine.selectedSubtitle, '1');
      expect(h.engine.configuration.subtitleDelayMs, 1200);
      final old = h.lessons.first, next = h.playback.next();
      var applied = false;
      final change = h.playback.changePresentation(old, () async {
        applied = true;
      });
      await next;
      expect(await change, isFalse);
      expect(applied, isFalse);
      expect(h.engine.selectedAudio, 'auto');
      expect(h.engine.configuration.subtitleDelayMs, 0);
      expect(h.captions.records, isEmpty);
    },
  );
  test('failed selection rolls back preferences; deletion clears source selections', () async {
    final h = CaptionHarness();
    await h.prepare();
    addTearDown(h.close);
    final first = (await h.import('English.srt', englishSrt))!;
    h.engine.failSelection = true;
    await expectLater(
      h.captions.save(
        VideoPlaybackSettings.fromJson({
          ...h.captions.settings.toJson(),
          'audio': '2',
        }),
      ),
      throwsStateError,
    );
    expect(h.engine.selectedAudio, 'auto');
    expect((await h.videos.playbackSettings(h.lessons.first)).audio, 'auto');
    h.engine.failSelection = false;
    await h.captions.remove(first);
    expect(h.captions.records, isEmpty);
    expect(h.captions.settings.subtitle, 'no');
    await expectLater(
      h.videos.savePlaybackSettings(
        h.lessons.first,
        VideoPlaybackSettings(subtitle: 'external:${first.id}'),
      ),
      throwsStateError,
    );
    final reimport = (await h.import('English.srt', englishSrt))!;
    expect(reimport.id, isNot(first.id));
  });
  test(
    'settings validate ranges and the translation source media version',
    () async {
      final h = CaptionHarness();
      await h.prepare();
      addTearDown(h.close);
      final file = (await h.import('English.srt', englishSrt))!;
      await expectLater(
        h.videos.savePlaybackSettings(
          h.lessons.last,
          VideoPlaybackSettings(translation: file.id),
        ),
        throwsStateError,
      );
      await expectLater(
        h.videos.savePlaybackSettings(
          h.lessons.first,
          const VideoPlaybackSettings(audioDelayMs: 10001),
        ),
        throwsArgumentError,
      );
      await expectLater(
        h.videos.savePlaybackSettings(
          h.lessons.first,
          const VideoPlaybackSettings(subtitleDelayMs: 60001),
        ),
        throwsArgumentError,
      );
      await expectLater(
        h.import('source.ass', '[Events]\n', translation: true),
        throwsArgumentError,
      );
    },
  );
}
