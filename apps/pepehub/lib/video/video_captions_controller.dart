import 'package:flutter/foundation.dart';

import 'models.dart';
import 'video_controller.dart';
import 'video_repository.dart';
import 'video_subtitle_import.dart';
import 'video_subtitles.dart';

class VideoCaptionsController extends ChangeNotifier {
  final VideoRepository repository;
  final VideoPlaybackController playback;
  VideoLesson? lesson;
  VideoPlaybackSettings settings = const VideoPlaybackSettings();
  List<VideoSubtitleRecord> records = [];
  Map<String, VideoSubtitleDocument> documents = {};
  bool busy = false, _disposed = false;
  int _generation = 0;
  String? error;
  VideoCaptionsController(this.repository, this.playback) {
    playback.addListener(_positionChanged);
  }
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool get bound =>
      !_disposed &&
      lesson != null &&
      lesson!.id == playback.current?.id &&
      lesson!.mediaVersion == playback.current?.mediaVersion;
  void _positionChanged() {
    _notify();
  }

  VideoSubtitleRecord? record(String id) {
    for (final value in records) {
      if (value.id == id) return value;
    }
    return null;
  }

  String? get primaryId => settings.subtitle.startsWith('external:')
      ? settings.subtitle.substring(9)
      : null;
  int delayFor(String id) => primaryId == id
      ? settings.subtitleDelayMs
      : settings.translation == id
      ? settings.translationDelayMs
      : 0;
  String get primaryText {
    if (!bound || settings.subtitle == 'no') return '';
    final id = primaryId;
    if (id != null && record(id)?.format != VideoSubtitleFormat.ass) {
      return documents[id]
              ?.activeAt(playback.positionMs - settings.subtitleDelayMs)
              .map((cue) => cue.text)
              .join('\n') ??
          '';
    }
    return playback.engine.rendersNativeSubtitles
        ? ''
        : playback.engine.subtitleText
              .where((text) => text.trim().isNotEmpty)
              .join('\n');
  }

  String get translationText =>
      !bound || !settings.translationVisible || settings.translation == null
      ? ''
      : documents[settings.translation]
                ?.activeAt(playback.positionMs - settings.translationDelayMs)
                .map((cue) => cue.text)
                .join('\n') ??
            '';

  /// Called inside the lesson-open queue, before playback starts.
  Future<void> loadLesson(VideoLesson value) async {
    if (_disposed) return;
    final generation = ++_generation;
    lesson = value;
    records = [];
    documents = {};
    settings = const VideoPlaybackSettings();
    error = null;
    _notify();
    final saved = await repository.playbackSettings(value),
        sources = await repository.subtitles(value);
    final parsed = <String, VideoSubtitleDocument>{};
    for (final source in sources) {
      try {
        parsed[source.id] = await compute(
          parseVideoSubtitles,
          VideoSubtitleParseRequest(source.text, source.format),
        );
      } catch (e) {
        error = 'Не удалось прочитать ${source.name}: $e';
      }
      if (_disposed || generation != _generation) return;
    }
    if (_disposed || generation != _generation) return;
    records = sources;
    documents = parsed;
    settings = saved;
    if (playback.engine.canSelectTracks) {
      await playback.engine.waitForTracks();
      if (_disposed || generation != _generation) return;
      await _apply(saved);
    }
    _notify();
  }

  Future<void> _apply(VideoPlaybackSettings value) async {
    final engine = playback.engine;
    if (!engine.canSelectTracks) return;
    final audioId = engine.audioTracks.any((track) => track.id == value.audio)
        ? value.audio
        : 'auto';
    await engine.selectAudioTrack(audioId);
    if (value.subtitle.startsWith('external:')) {
      final source = record(value.subtitle.substring(9));
      if (source?.format == VideoSubtitleFormat.ass) {
        await engine.externalAss(source!.text, source.id);
      } else {
        await engine.selectSubtitleTrack('no');
      }
    } else {
      final id = value.subtitle.startsWith('embedded:')
          ? value.subtitle.substring(9)
          : value.subtitle;
      await engine.selectSubtitleTrack(
        engine.subtitleTracks.any((track) => track.id == id) ? id : 'auto',
      );
    }
    await engine.configureSubtitles(value);
  }

  Future<void> save(VideoPlaybackSettings value) async {
    if (!bound || busy) return;
    final source = lesson!, generation = _generation, previous = settings;
    busy = true;
    error = null;
    _notify();
    try {
      final applied = await playback.changePresentation(source, () async {
        try {
          await _apply(value);
          await repository.savePlaybackSettings(source, value);
        } catch (_) {
          await _apply(previous);
          rethrow;
        }
      });
      if (applied && bound && generation == _generation) settings = value;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<VideoSubtitleRecord?> importFile(
    VideoSubtitleFile file,
    VideoSubtitleEncoding encoding, {
    bool translation = false,
  }) async {
    if (!bound || busy) return null;
    final source = lesson!, generation = _generation;
    final text = decodeVideoSubtitles(file.bytes, encoding: encoding);
    final extension = file.name.split('.').last.toLowerCase();
    final format = text.trimLeft().startsWith('WEBVTT') || extension == 'vtt'
        ? VideoSubtitleFormat.vtt
        : ['ass', 'ssa'].contains(extension)
        ? VideoSubtitleFormat.ass
        : VideoSubtitleFormat.srt;
    if (translation && format == VideoSubtitleFormat.ass) {
      throw ArgumentError('Второй перевод поддерживает SRT/WebVTT');
    }
    busy = true;
    _notify();
    try {
      final added = await repository.importSubtitles(
        source,
        name: file.name,
        text: text,
        format: format,
      );
      final parsed = await compute(
        parseVideoSubtitles,
        VideoSubtitleParseRequest(text, format),
      );
      if (!bound || generation != _generation) return added;
      if (!records.any((record) => record.id == added.id)) {
        records = [...records, added];
      }
      documents = {...documents, added.id: parsed};
      final candidate = VideoPlaybackSettings.fromJson({
        ...settings.toJson(),
        if (translation)
          'translation': added.id
        else
          'subtitle': 'external:${added.id}',
        if (translation) 'translationDelayMs': 0 else 'subtitleDelayMs': 0,
      });
      final applied = await playback.changePresentation(source, () async {
        final previous = settings;
        try {
          await _apply(candidate);
          await repository.savePlaybackSettings(source, candidate);
        } catch (_) {
          await _apply(previous);
          rethrow;
        }
      });
      if (applied && bound && generation == _generation) settings = candidate;
      return added;
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> remove(VideoSubtitleRecord subtitle) async {
    if (!bound || busy) return;
    final source = lesson!;
    busy = true;
    _notify();
    try {
      await playback.changePresentation(source, () async {
        await repository.deleteSubtitles(source, subtitle);
        await loadLesson(source);
      });
    } finally {
      busy = false;
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    playback.removeListener(_positionChanged);
    super.dispose();
  }
}
