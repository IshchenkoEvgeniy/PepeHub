import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'models.dart';
import 'video_annotations.dart';
import 'video_annotations_panel.dart';
import 'video_controller.dart';
import 'video_engine.dart';
import 'video_fullscreen.dart';
import 'video_repository.dart';
import 'video_statistics_page.dart';
import 'video_tools.dart';
import 'video_tools_dialogs.dart';
import 'video_captions_controller.dart';
import 'video_caption_settings_dialog.dart';
import 'video_subtitle_import.dart';
import 'video_subtitles.dart';
import 'video_transcript_panel.dart';
import 'video_session.dart';
import 'video_compact_controls.dart';
import 'video_frame_export.dart';
import '../music/music_player_view.dart';
import 'video_seek_previews.dart';
import 'video_annotation_editor.dart';
import '../vocabulary/vocabulary_editor.dart';
import '../vocabulary/vocabulary_repository.dart';
import '../vocabulary/vocabulary_page.dart';

class VideoPlayerPage extends StatefulWidget {
  final VideoRepository repository;
  final VideoItem item;
  final List<VideoLesson> lessons;
  final int initialIndex;
  final Future<void> Function()? beforePlaying;
  final VideoPlaybackEngine Function()? engineFactory;
  final VideoFullscreenHost? fullscreenHost;
  final VideoSubtitlePicker? subtitlePicker;
  final VideoPlaybackSession? session;
  const VideoPlayerPage({
    super.key,
    required this.repository,
    required this.item,
    required this.lessons,
    this.initialIndex = 0,
    this.beforePlaying,
    this.engineFactory,
    this.fullscreenHost,
    this.subtitlePicker,
    this.session,
  });
  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  VideoPlaybackController? controller;
  VideoCaptionsController? captions;
  String? startupError;
  bool _leaving = false,
      _allowPop = false,
      _fullscreen = false,
      _changingFullscreen = false;
  bool _controlsVisible = true, _dialogOpen = false;
  bool _studyOpen = false;
  VideoAnnotationDraft? _annotation;
  bool _openingAnnotation = false;
  final _annotationKey = GlobalKey<VideoAnnotationEditorState>();
  final _vocabularyKey = GlobalKey<VocabularyEditorState>();
  late final _studyTabs = TabController(length: 4, vsync: this);
  bool _wasPlaying = false;
  double? _scrub;
  int? _pointA, _pointB;
  int _notesRefresh = 0, _rotation = 0;
  BoxFit _fit = BoxFit.contain;
  String? _lessonKey;
  final _surfaceKey = GlobalKey();
  final _focus = FocusNode(debugLabel: 'video-player');
  Timer? _controlsTimer;
  late final VideoPlaybackSession _session;
  late final bool _ownsSession;
  VideoFullscreenHost get _fullscreenHost => _session.window;
  final _zoom = TransformationController();
  final _previews = VideoSeekPreviews();
  bool? _previewsEnabled;
  bool get _showPreviews =>
      _previewsEnabled ??
      !RegExp(
        r'^https?://',
        caseSensitive: false,
      ).hasMatch(controller?.current?.source ?? '');
  bool _locked = false, _minimizing = false;
  Future<void> _presentation = Future.value();
  bool get _enabled =>
      controller?.current != null && !controller!.loading && !_leaving;

  @override
  void initState() {
    super.initState();
    _previews.addListener(_previewChanged);
    try {
      final shared = widget.session ?? VideoSessionScope.read(context);
      _ownsSession = shared == null;
      _session =
          shared ??
          VideoPlaybackSession(
            widget.repository,
            engineFactory: widget.engineFactory,
            window: widget.fullscreenHost,
            beforePlaying: widget.beforePlaying,
          );
      _session.addListener(_changed);
      _session.attachPage();
      unawaited(
        _perform(() async {
          try {
            await _session.open(
              widget.item,
              widget.lessons,
              widget.initialIndex,
            );
          } catch (e) {
            if (mounted) {
              setState(() => startupError = 'Видеоплеер не запустился: $e');
            }
          }
        }),
      );
    } catch (e) {
      startupError = 'Видеоплеер не запустился: $e';
    }
  }

  void _previewChanged() {
    if (mounted) setState(() {});
  }

  void _changed() {
    controller = _session.controller;
    captions = _session.captions;
    final lesson = controller?.current;
    final key = lesson == null ? null : '${lesson.id}:${lesson.mediaVersion}';
    if (key != _lessonKey) {
      _lessonKey = key;
      _pointA = _pointB = null;
      _scrub = null;
      _previews.dismiss();
      _zoom.value = Matrix4.identity();
    }
    final playing = controller?.state.playing == true;
    if (playing && !_wasPlaying) _showControls();
    _wasPlaying = playing;
    if (mounted) setState(() {});
  }

  Future<void> _perform(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось выполнить действие: $e')),
        );
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The shared session owns lifecycle, including PiP and audio in the background.
  }

  void _showControls() {
    _controlsTimer?.cancel();
    if (mounted) setState(() => _controlsVisible = true);
    if (!_dialogOpen && !_studyOpen && !_locked && _annotation == null) {
      _controlsTimer = Timer(const Duration(seconds: 4), () {
        if (mounted &&
            controller?.state.playing == true &&
            !_dialogOpen &&
            !_studyOpen) {
          setState(() => _controlsVisible = false);
        }
      });
    }
  }

  Future<void> _setFullscreen(bool enabled) async {
    if (_changingFullscreen || _fullscreen == enabled) return;
    setState(() => _changingFullscreen = true);
    final operation = _presentation.then((_) async {
      if (enabled && _session.miniWindow) {
        await _fullscreenHost.setMiniWindow(false);
        _session.miniWindow = false;
      }
      await _fullscreenHost.setFullscreen(enabled);
    });
    _presentation = operation.catchError((Object _) {});
    try {
      await operation;
      if (!mounted) {
        if (enabled) await _fullscreenHost.setFullscreen(false);
        return;
      }
      setState(() => _fullscreen = enabled);
      _showControls();
      _focus.requestFocus();
    } finally {
      if (mounted) setState(() => _changingFullscreen = false);
    }
  }

  Future<void> _back() async {
    if (_annotation != null) {
      if (_annotation!.forAnki) {
        await _vocabularyKey.currentState?.requestClose();
      } else {
        await _annotationKey.currentState?.requestClose();
      }
      return;
    }
    if (_studyOpen) {
      _closeStudy();
      return;
    }
    if (_locked) {
      setState(() => _locked = false);
      _showControls();
      return;
    }
    if (_session.miniWindow) {
      await _perform(() => _setMiniWindow(false));
      return;
    }
    if (_changingFullscreen) return;
    if (_fullscreen) {
      await _perform(() => _setFullscreen(false));
      return;
    }
    await _leave();
  }

  Future<void> _leave() async {
    if (_leaving) return;
    setState(() => _leaving = true);
    try {
      await _session.close();
      if (_fullscreen) await _setFullscreen(false);
      if (!mounted) return;
      setState(() => _allowPop = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
    } catch (e) {
      if (mounted) {
        setState(() => _leaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Не удалось сохранить просмотр. Повторите выход: $e'),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _controlsTimer?.cancel();
    _focus.dispose();
    _studyTabs.dispose();
    _zoom.dispose();
    _previews.removeListener(_previewChanged);
    _previews.dispose();
    _session.removeListener(_changed);
    if (_fullscreen || _changingFullscreen) {
      unawaited(
        _presentation
            .then((_) => _fullscreenHost.setFullscreen(false))
            .catchError((Object _) {}),
      );
    }
    _session.detachPage();
    if (_ownsSession) {
      _session.dispose();
    } else if (!_minimizing && !_leaving) {
      unawaited(_session.close().catchError((Object _) {}));
    }
    super.dispose();
  }

  Future<T?> _liveDialog<T>(Future<T?> Function() show) =>
      _dialog(show, pause: false);
  Future<T?> _dialog<T>(Future<T?> Function() show, {bool pause = true}) async {
    if (_dialogOpen) return null;
    setState(() => _dialogOpen = true);
    _controlsTimer?.cancel();
    try {
      if (pause) await controller?.pause();
      if (!mounted) return null;
      return await show();
    } finally {
      if (mounted) {
        setState(() => _dialogOpen = false);
        _showControls();
        _focus.requestFocus();
      }
    }
  }

  Future<void> _seekDialog() async {
    final player = controller!;
    final wasPlaying = player.state.playing;
    final target = await _dialog(
      () => showVideoSeekDialog(
        context,
        player.positionMs,
        player.state.durationMs,
      ),
    );
    if (target != null && mounted) await player.seek(target);
    if (wasPlaying && mounted) await player.play();
  }

  Future<void> _loopDialog({VideoAnnotation? annotation}) async {
    final player = controller!;
    final settings = await _dialog(
      () => showVideoLoopDialog(
        context,
        positionMs: player.positionMs,
        durationMs: player.state.durationMs,
        settings: player.loop,
        startMs: annotation?.startMs ?? _pointA,
        endMs: annotation?.endMs ?? _pointB,
      ),
    );
    if (settings != null && mounted) {
      setState(() {
        _pointA = settings.startMs;
        _pointB = settings.endMs;
      });
      await player.startLoop(settings);
    }
  }

  Future<void> _note({
    VideoAnnotation? existing,
    bool fragment = false,
    bool forAnki = false,
  }) async {
    final player = controller!, lesson = controller!.current!;
    await _openAnnotation(
      VideoAnnotationDraft(
        lesson: lesson,
        positionMs:
            existing?.startMs ?? (fragment ? _pointA! : player.positionMs),
        durationMs: player.state.durationMs,
        existing: existing,
        endMs: fragment ? _pointB : null,
        forAnki: forAnki,
      ),
    );
  }

  Future<void> _openAnnotation(
    VideoAnnotationDraft draft, {
    bool seek = false,
  }) async {
    if (_annotation != null || _openingAnnotation || _dialogOpen) return;
    _openingAnnotation = true;
    _controlsTimer?.cancel();
    try {
      if (!draft.forAnki) await controller!.pause();
      if (seek || draft.existing != null) {
        await controller!.seek(draft.positionMs);
      }
      if (mounted) setState(() => _annotation = draft);
    } finally {
      _openingAnnotation = false;
    }
  }

  void _finishAnnotation({bool saved = false}) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _annotation = null;
      if (saved) _notesRefresh++;
    });
    if (saved) _session.refresh();
    _showControls();
    _focus.requestFocus();
  }

  void _nextAnkiCard(VocabularyCard card) {
    final player = controller!;
    setState(() {
      _annotation = VideoAnnotationDraft(
        lesson: player.current!,
        positionMs: player.positionMs,
        durationMs: player.state.durationMs,
        forAnki: true,
      );
    });
  }

  Future<void> _statistics() async {
    if (_dialogOpen) return;
    setState(() => _dialogOpen = true);
    try {
      await controller?.pause();
      if (_fullscreen) await _setFullscreen(false);
      if (!mounted) return;
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => VideoStatisticsPage(
            repository: widget.repository,
            item: widget.item,
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _dialogOpen = false);
        _focus.requestFocus();
      }
    }
  }

  Future<void> _captionSettings() async {
    if (captions == null || !captions!.bound) return;
    await _dialog<void>(
      () => showDialog<void>(
        context: context,
        builder: (_) => VideoCaptionSettingsDialog(
          captions: captions!,
          picker: widget.subtitlePicker ?? pickVideoSubtitles,
        ),
      ),
    );
  }

  (int, int) _cueRange(VideoSubtitleRecord source, VideoSubtitleCue cue) {
    final player = controller!;
    if (player.current?.id != source.lessonId ||
        player.current?.mediaVersion != source.mediaVersion) {
      throw StateError('Реплика относится к другому уроку');
    }
    final limit = player.state.durationMs > 0
        ? player.state.durationMs
        : 1 << 53;
    final delay = captions!.delayFor(source.id);
    final start = (cue.startMs + delay).clamp(0, limit),
        end = (cue.endMs + delay).clamp(0, limit);
    if (end <= start) {
      throw StateError(
        'Реплика находится за пределами видео. Проверьте смещение субтитров',
      );
    }
    return (start, end);
  }

  Future<void> _seekCue(
    VideoSubtitleRecord source,
    VideoSubtitleCue cue,
  ) async {
    final (start, _) = _cueRange(source, cue);
    await controller!.seek(start);
  }

  Future<void> _repeatCue(
    VideoSubtitleRecord source,
    VideoSubtitleCue cue,
  ) async {
    var (start, end) = _cueRange(source, cue);
    final limit = controller!.state.durationMs > 0
        ? controller!.state.durationMs
        : 1 << 53;
    if (end - start < 500) {
      end = (start + 500).clamp(0, limit);
      start = (end - 500).clamp(0, limit);
    }
    final settings = await _dialog(
      () => showVideoLoopDialog(
        context,
        positionMs: controller!.positionMs,
        durationMs: controller!.state.durationMs,
        startMs: start,
        endMs: end,
        settings: controller!.loop,
      ),
    );
    if (settings != null && mounted) {
      _cueRange(source, cue);
      await controller!.startLoop(settings);
    }
  }

  Future<void> _noteCue(
    VideoSubtitleRecord source,
    VideoSubtitleCue cue, {
    bool forAnki = false,
  }) async {
    final (start, end) = _cueRange(source, cue);
    final lesson = controller!.current!;
    await _openAnnotation(
      VideoAnnotationDraft(
        lesson: lesson,
        positionMs: start,
        durationMs: controller!.state.durationMs,
        endMs: end,
        initialTitle: 'Фраза ${videoTimestamp(start)}',
        initialBody: cue.text,
        forAnki: forAnki,
      ),
      seek: true,
    );
  }

  Future<void> _command(String action) async {
    if (action == 'back') {
      await _back();
      return;
    }
    if (_annotation != null || _openingAnnotation) return;
    if (action == 'fullscreen') {
      await _setFullscreen(!_fullscreen);
      return;
    }
    if (action == 'help') {
      await _help();
      return;
    }
    if (!_enabled || _dialogOpen || _locked) return;
    final player = controller!;
    _showControls();
    switch (action) {
      case 'toggle':
        await player.toggle();
      case 'left':
        await player.skip(-10000);
      case 'right':
        await player.skip(10000);
      case 'fine-left':
        await player.skip(-1000);
      case 'fine-right':
        await player.skip(1000);
      case 'up':
        await player.adjustVolume(5);
      case 'down':
        await player.adjustVolume(-5);
      case 'mute':
        await player.toggleMute();
      case 'faster':
        await player.setSpeed((player.state.speed + .25).clamp(.5, 3));
      case 'slower':
        await player.setSpeed((player.state.speed - .25).clamp(.5, 3));
      case 'seek':
        await _seekDialog();
      case 'note':
        await _note();
      case 'loop':
        await _loopDialog();
      case 'undo':
        await player.returnFromSeek();
      case 'captions':
        await _captionSettings();
    }
  }

  Future<void> _help() async {
    await _dialog<void>(
      () => showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Горячие клавиши'),
          content: const SingleChildScrollView(
            child: Text(
              'Пробел / K — воспроизведение и пауза\n← / → / J / L — ±10 секунд\nShift + ← / → — ±1 секунда\n↑ / ↓ — громкость ±5%\nM — звук / без звука\nShift + , / . — скорость ±0,25×\nF — полный экран\nEsc — выйти из полного экрана / закрыть плеер\nCtrl + G — точный переход\nCtrl + B — закладка / заметка\nCtrl + R — повтор A–B\nCtrl + S — дорожки и субтитры\nAlt + ← — вернуться до перемотки\n\nДвойной щелчок по видео — полный экран.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Понятно'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _surface(VideoPlaybackController player) => GestureDetector(
    onTap: () {
      if (!_locked) {
        if (_controlsVisible && player.state.playing) {
          _controlsTimer?.cancel();
          setState(() => _controlsVisible = false);
        } else {
          _showControls();
        }
      }
    },
    onDoubleTap: _locked || _annotation != null
        ? null
        : () => _perform(() => _setFullscreen(!_fullscreen)),
    child: Stack(
      alignment: Alignment.center,
      children: [
        Positioned.fill(
          child: InteractiveViewer(
            key: const ValueKey('video-viewport'),
            transformationController: _zoom,
            minScale: 1,
            maxScale: 6,
            panEnabled: !_locked,
            scaleEnabled: !_locked,
            trackpadScrollCausesScale: true,
            onInteractionStart: (_) {
              _controlsTimer?.cancel();
              if (!_locked) setState(() => _controlsVisible = false);
            },
            onInteractionEnd: (_) {
              if (!_locked) _showControls();
            },
            child: RotatedBox(
              quarterTurns: _rotation,
              child: player.engine.surface == null
                  ? Container(
                      color: Colors.black,
                      child: const Center(
                        child: Icon(
                          Icons.ondemand_video,
                          size: 56,
                          color: Colors.white54,
                        ),
                      ),
                    )
                  : Video(
                      key: _surfaceKey,
                      controller: player.engine.surface!,
                      controls: NoVideoControls,
                      subtitleViewConfiguration:
                          const SubtitleViewConfiguration(visible: false),
                      fit: _fit,
                    ),
            ),
          ),
        ),
        if (player.loading || player.state.buffering)
          const CircularProgressIndicator(),
        if (captions != null)
          Positioned.fill(
            child: VideoCaptionOverlay(
              captions: captions!,
              bottom:
                  _controlsVisible &&
                      !_fullscreenHost.pip &&
                      _annotation == null
                  ? 130
                  : _annotation != null
                  ? 52
                  : 12,
              fontScale: _fullscreenHost.pip ? .65 : 1,
              maxLines: _fullscreenHost.pip ? 2 : 4,
            ),
          ),
      ],
    ),
  );

  Future<void> _setMiniWindow(bool enabled) async {
    if (_fullscreen) await _setFullscreen(false);
    await _fullscreenHost.setMiniWindow(enabled);
    setState(() => _session.miniWindow = enabled);
    _showControls();
  }

  Future<void> _minimize() async {
    if (_ownsSession) {
      throw StateError('Мини-плеер доступен из видеобиблиотеки');
    }
    if (_fullscreen) await _setFullscreen(false);
    if (_session.miniWindow) await _setMiniWindow(false);
    await controller!.flush();
    _session.requestMini();
    setState(() {
      _minimizing = true;
      _allowPop = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  Future<void> _sleepDialog() async {
    var minutes = '30';
    final form = GlobalKey<FormState>();
    final choice = await _liveDialog<String>(
      () => showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Таймер сна'),
          content: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (controller!.sleepRemainingMs != null)
                  Text(
                    'Осталось ${videoTimestamp(controller!.sleepRemainingMs!)}',
                  ),
                TextFormField(
                  key: const ValueKey('video-sleep-minutes'),
                  initialValue: minutes,
                  onChanged: (text) => minutes = text,
                  validator: (text) {
                    final value = int.tryParse(text ?? '');
                    return value == null || value < 1 || value > 1440
                        ? 'От 1 до 1440 минут'
                        : null;
                  },
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Минуты (1–1440)',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, 'off'),
              child: const Text('Выключить'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'end'),
              child: Text(
                controller?.current?.isAudio == true
                    ? 'До конца трека'
                    : 'До конца урока',
              ),
            ),
            FilledButton(
              onPressed: () {
                if (form.currentState!.validate()) {
                  Navigator.pop(context, 'minutes');
                }
              },
              child: const Text('Включить'),
            ),
          ],
        ),
      ),
    );
    if (choice != null) {
      await controller!.setSleepTimer(
        choice == 'minutes' ? Duration(minutes: int.parse(minutes)) : null,
        untilLessonEnd: choice == 'end',
      );
    }
  }

  Future<void> _captureFrame() async {
    final player = controller!;
    final lesson = player.current!;
    final saved = await _dialog<String>(() async {
      final bytes = await player.engine.captureFrame();
      if (bytes == null) {
        throw StateError(
          'Декодер не вернул кадр. Повторите после начала воспроизведения',
        );
      }
      final title = lesson.title.replaceAll(
        RegExp(r'[<>:"/\\|?*\x00-\x1f]'),
        '_',
      );
      return saveVideoFrame(
        bytes,
        'PepeHub-${title.substring(0, title.length.clamp(0, 80))}-${videoTimestamp(player.positionMs, precise: true).replaceAll(':', '-')}.png',
      );
    });
    if (saved != null && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Кадр сохранён: $saved')));
    }
  }

  Future<void> _tools() async {
    if (_dialogOpen) return;
    setState(() => _dialogOpen = true);
    _controlsTimer?.cancel();
    final player = controller!;
    final tools = <(String, String, IconData)>[
      ('loop', 'Повтор A–B', Icons.repeat),
      ('timer', 'Таймер сна', Icons.timer_outlined),
      ('note', 'Закладка / заметка', Icons.bookmark_add_outlined),
      ('anki', 'Карточка Anki', Icons.style_outlined),
      ('vocabulary', 'Словарь Anki', Icons.collections_bookmark_outlined),
      if (player.current?.isAudio != true)
        (
          'audio',
          player.audioOnly ? 'Вернуться к видео' : 'Аудиорежим',
          Icons.headphones_outlined,
        ),
      (
        'mute',
        player.state.volume == 0 ? 'Включить звук' : 'Без звука',
        Icons.volume_off_outlined,
      ),
      ('volume', 'Громкость', Icons.volume_up_outlined),
      if (player.current?.isAudio != true)
        ('fit', 'Размер и поворот', Icons.aspect_ratio),
      if (player.current?.isAudio != true)
        ('zoom', 'Сбросить масштаб', Icons.zoom_out_map),
      if (player.engine.canCaptureFrame && !player.audioOnly)
        (
          'previews',
          _showPreviews ? 'Превью: включены' : 'Превью: выключены',
          Icons.preview_outlined,
        ),
      if (player.engine.canCaptureFrame && !player.audioOnly)
        ('frame', 'Снимок кадра', Icons.photo_camera_outlined),
      if (!_ownsSession)
        ('mini', 'Мини-плеер', Icons.picture_in_picture_outlined),
      if (_fullscreenHost.supportsPip && !player.audioOnly)
        ('pip', 'Android PiP', Icons.picture_in_picture_alt),
      if (_fullscreenHost.supportsMiniWindow)
        (
          'window',
          _session.miniWindow ? 'Обычное окно' : 'Мини-окно Windows',
          Icons.open_in_new,
        ),
      ('seek', 'Перейти ко времени', Icons.av_timer),
      ('undo', 'До перемотки', Icons.undo),
      ('chapters', 'Главы', Icons.menu_book_outlined),
      ('lock', 'Блокировка', Icons.lock_outline),
      ('stats', 'Статистика', Icons.bar_chart),
      ('help', 'Горячие клавиши', Icons.keyboard_outlined),
    ];
    String? selected;
    try {
      selected = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        constraints: const BoxConstraints(maxWidth: 720),
        builder: (sheetContext) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetContext).height * .8,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
              child: LayoutBuilder(
                builder: (context, bounds) => GridView.count(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  crossAxisCount: (bounds.maxWidth / 112).floor().clamp(2, 6),
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: .98,
                  children: [
                    for (final (id, name, icon) in tools)
                      Tooltip(
                        message: name,
                        child: InkWell(
                          key: ValueKey('video-tool-$id'),
                          borderRadius: BorderRadius.circular(14),
                          onTap: () => Navigator.pop(sheetContext, id),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              CircleAvatar(
                                radius: 23,
                                backgroundColor:
                                    id == 'audio' && player.audioOnly
                                    ? Theme.of(context)
                                          .colorScheme
                                          .primaryContainer
                                    : Theme.of(context)
                                          .colorScheme
                                          .surfaceContainerHighest,
                                child: Icon(icon),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                name,
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _dialogOpen = false);
        _showControls();
      }
    }
    if (selected == null || !mounted) return;
    switch (selected) {
      case 'loop':
        await _loopDialog();
      case 'timer':
        await _sleepDialog();
      case 'note':
        await _note();
      case 'anki':
        await _note(forAnki: true);
      case 'vocabulary':
        await controller!.pause();
        if (!mounted) return;
        await Navigator.push<void>(
          context,
          MaterialPageRoute(
            builder: (_) => VocabularyPage(
              repository: VocabularyRepository(widget.repository.repository),
            ),
          ),
        );
      case 'audio':
        await _session.setAudioOnly(!player.audioOnly);
      case 'mute':
        await player.toggleMute();
      case 'volume':
        await _volumeDialog();
      case 'fit':
        await _fitDialog();
      case 'zoom':
        _zoom.value = Matrix4.identity();
      case 'previews':
        setState(() => _previewsEnabled = !_showPreviews);
        _previews.dismiss();
      case 'frame':
        await _captureFrame();
      case 'mini':
        await _minimize();
      case 'pip':
        await _fullscreenHost.enterPip();
      case 'window':
        await _setMiniWindow(!_session.miniWindow);
      case 'seek':
        await _seekDialog();
      case 'undo':
        await player.returnFromSeek();
      case 'chapters':
        await _studyPanel(initialTab: 3);
      case 'lock':
        setState(() => _locked = true);
      case 'stats':
        await _statistics();
      case 'help':
        await _help();
    }
  }

  Future<void> _volumeDialog() async {
    await _liveDialog<void>(
      () => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Громкость'),
          content: AnimatedBuilder(
            animation: controller!,
            builder: (context, _) => Slider(
              key: const ValueKey('video-volume'),
              value: controller!.state.volume.clamp(0, 100),
              max: 100,
              onChanged: (value) =>
                  _perform(() => controller!.setVolume(value)),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Готово'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _fitDialog() async {
    final value = await _liveDialog<String>(
      () => showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('Изображение'),
          children: [
            for (final entry in {
              'contain': 'Вписать целиком',
              'cover': 'Заполнить с обрезкой',
              'fill': 'Растянуть',
              'rotate': 'Повернуть на 90°',
              'zoom': 'Сбросить масштаб',
            }.entries)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, entry.key),
                child: Text(entry.value),
              ),
          ],
        ),
      ),
    );
    if (value != null) {
      setState(() {
        if (value == 'rotate') {
          _rotation = (_rotation + 1) % 4;
        } else if (value == 'zoom') {
          _zoom.value = Matrix4.identity();
        } else {
          _fit = {
            'contain': BoxFit.contain,
            'cover': BoxFit.cover,
            'fill': BoxFit.fill,
          }[value]!;
        }
      });
    }
  }

  Future<void> _studyPanel({int initialTab = 0}) async {
    if (_dialogOpen || _studyOpen || _annotation != null) return;
    _controlsTimer?.cancel();
    if (controller?.audioOnly != true) await controller?.pause();
    if (!mounted) return;
    _studyTabs.index = initialTab;
    setState(() => _studyOpen = true);
  }

  void _closeStudy() {
    setState(() => _studyOpen = false);
    FocusManager.instance.primaryFocus?.unfocus();
    _showControls();
    _focus.requestFocus();
  }

  Widget _studyContents() => ScaffoldMessenger(
    child: Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          Row(
            children: [
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  controller?.current?.isAudio == true
                      ? 'Плейлист и заметки'
                      : 'Материалы урока',
                ),
              ),
              IconButton(
                tooltip: controller?.current?.isAudio == true
                    ? 'Закрыть панель музыки'
                    : 'Закрыть панель урока',
                onPressed: _closeStudy,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          Expanded(
            child: Column(
              children: [
                TabBar(
                  controller: _studyTabs,
                  tabAlignment: TabAlignment.start,
                  isScrollable: true,
                  tabs: [
                    Tab(
                      text: controller?.current?.isAudio == true
                          ? 'Треки'
                          : 'Уроки',
                    ),
                    Tab(text: 'Расшифровка'),
                    Tab(text: 'Заметки'),
                    Tab(text: 'Главы'),
                  ],
                ),
                Expanded(
                  child: AnimatedBuilder(
                    animation: _session,
                    builder: (context, _) {
                      final player = controller!;
                      final order = player.playbackOrder;
                      return TabBarView(
                        controller: _studyTabs,
                        children: [
                          ListView.builder(
                            itemCount: order.length,
                            itemBuilder: (context, row) {
                              final i = order[row];
                              return ListTile(
                                key: ValueKey(
                                  'video-lesson-${player.lessons[i].id}',
                                ),
                                selected: player.index == i,
                                leading: Text('${row + 1}'),
                                title: Text(player.lessons[i].title),
                                subtitle: player.lessons[i].module.isEmpty
                                    ? null
                                    : Text(player.lessons[i].module),
                                onTap: _enabled && player.lessons[i].available
                                    ? () => _perform(() => player.load(i))
                                    : null,
                              );
                            },
                          ),
                          ListView(
                            padding: const EdgeInsets.all(12),
                            children: [
                              if (captions != null && captions!.bound) ...[
                                if (captions!.settings.translation != null)
                                  TextButton.icon(
                                    onPressed: captions!.busy
                                        ? null
                                        : () => _perform(
                                            () => captions!.save(
                                              VideoPlaybackSettings.fromJson({
                                                ...captions!.settings.toJson(),
                                                'translationVisible': !captions!
                                                    .settings
                                                    .translationVisible,
                                              }),
                                            ),
                                          ),
                                    icon: const Icon(Icons.translate),
                                    label: Text(
                                      captions!.settings.translationVisible
                                          ? 'Скрыть перевод'
                                          : 'Показать перевод',
                                    ),
                                  ),
                                VideoTranscriptPanel(
                                  key: ValueKey(_lessonKey),
                                  captions: captions!,
                                  onSeek: (source, cue) =>
                                      _perform(() => _seekCue(source, cue)),
                                  onRepeat: (source, cue) async {
                                    await _perform(
                                      () => _repeatCue(source, cue),
                                    );
                                  },
                                  onNote: (source, cue) async {
                                    await _perform(() => _noteCue(source, cue));
                                  },
                                  onAnki: (source, cue) => _perform(
                                    () => _noteCue(source, cue, forAnki: true),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          ListView(
                            padding: const EdgeInsets.all(12),
                            children: [
                              TextButton.icon(
                                onPressed: () =>
                                    _perform(() => _note(forAnki: true)),
                                icon: const Icon(Icons.style_outlined),
                                label: const Text('Карточка Anki'),
                              ),
                              if (player.current != null)
                                VideoAnnotationsPanel(
                                  repository: widget.repository,
                                  lesson: player.current!,
                                  refresh: _notesRefresh,
                                  onEdit: (note) async {
                                    await _perform(() => _note(existing: note));
                                  },
                                  onSeek: (note) =>
                                      _perform(() => player.seek(note.startMs)),
                                  onRepeat: (note) async {
                                    await _perform(
                                      () => _loopDialog(annotation: note),
                                    );
                                  },
                                ),
                            ],
                          ),
                          ListView(
                            children: [
                              if (_session.chapters.isEmpty)
                                const Padding(
                                  padding: EdgeInsets.all(20),
                                  child: Text(
                                    'В этом файле нет встроенных глав. Используйте заметки к времени или расшифровку.',
                                  ),
                                ),
                              for (final chapter in _session.chapters)
                                ListTile(
                                  title: Text(chapter.title),
                                  subtitle: Text(
                                    videoTimestamp(chapter.startMs),
                                  ),
                                  onTap: () => _perform(
                                    () => player.seek(chapter.startMs),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _playerBody(VideoPlaybackController player) => Theme(
    data: Theme.of(context).copyWith(
      brightness: Brightness.dark,
      colorScheme: Theme.of(context).colorScheme
          .copyWith(surface: Colors.black, onSurface: Colors.white),
      iconTheme: const IconThemeData(color: Colors.white),
      textTheme: Theme.of(context).textTheme
          .apply(bodyColor: Colors.white, displayColor: Colors.white),
    ),
    child: MouseRegion(
      onHover: (_) {
        if (!_locked) _showControls();
      },
      child: LayoutBuilder(
        builder: (context, bounds) {
          final noteLayout = _annotation == null
              ? null
              : VideoAnnotationLayout(
                  bounds.biggest,
                  MediaQuery.paddingOf(context),
                  _rotation.isOdd
                      ? 1 / player.engine.aspectRatio
                      : player.engine.aspectRatio,
                );
          return Stack(
            children: [
              Positioned.fromRect(
                rect: noteLayout?.video ?? (Offset.zero & bounds.biggest),
                child: KeyedSubtree(
                  key: const ValueKey('video-visible-frame'),
                  child: player.current?.isAudio == true
                      ? const SizedBox.expand()
                      : _surface(player),
                ),
              ),
              if (player.audioOnly)
                Positioned.fill(
                  child: IgnorePointer(
                    child: ColoredBox(
                      color: Colors.black,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              player.current?.isAudio == true
                                  ? Icons.music_note
                                  : Icons.headphones,
                              size: 64,
                              color: Colors.white70,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              player.current?.isAudio == true
                                  ? (player.current?.title ?? 'Музыка')
                                  : 'Аудиорежим',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 20,
                              ),
                            ),
                            if (player.current?.isAudio == true) ...[
                              const SizedBox(height: 8),
                              Text(
                                '${widget.item.title} · ${player.queueIndex + 1} из ${player.playbackOrder.length}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (!_fullscreenHost.pip && _annotation == null && !_studyOpen)
                Positioned.fill(
                  child: VideoCompactControls(
                    player: player,
                    enabled: _enabled,
                    fullscreen: _fullscreen,
                    visible:
                        player.current?.isAudio == true ||
                        _controlsVisible ||
                        !player.state.playing ||
                        player.error != null,
                    locked: _locked,
                    miniWindow: _session.miniWindow,
                    scrub: _scrub,
                    seekPreview: _scrub != null && _previews.image != null
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.memory(
                              _previews.image!,
                              key: const ValueKey('video-seek-preview'),
                              width: 160,
                              height: 90,
                              fit: BoxFit.contain,
                              gaplessPlayback: false,
                            ),
                          )
                        : null,
                    perform: _perform,
                    onBack: _back,
                    onMore: () => _perform(_tools),
                    onStudy: () => _perform(_studyPanel),
                    onCaptions: () => _perform(_captionSettings),
                    onNote: () => _perform(_note),
                    onFullscreen: () =>
                        _perform(() => _setFullscreen(!_fullscreen)),
                    onLock: () {
                      setState(() => _locked = !_locked);
                      _showControls();
                    },
                    onScrubStart: () => _controlsTimer?.cancel(),
                    onScrub: (value) {
                      setState(() => _scrub = value);
                      if (_showPreviews &&
                          player.engine.canCaptureFrame &&
                          !player.audioOnly &&
                          player.current != null) {
                        _previews.request(
                          player.current!,
                          value.round(),
                          player.state.durationMs,
                        );
                      }
                    },
                    onSeek: (value) {
                      setState(() => _scrub = null);
                      _previews.dismiss();
                      _perform(() => player.seek(value.round()));
                      _showControls();
                    },
                  ),
                ),
              if (noteLayout != null)
                Positioned(
                  left: noteLayout.video.left,
                  top: noteLayout.video.bottom - 44,
                  width: noteLayout.video.width,
                  height: 44,
                  child: Focus(
                    canRequestFocus: false,
                    descendantsAreFocusable: false,
                    child: Material(
                      color: Colors.black87,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            tooltip: 'Назад на 10 секунд',
                            onPressed: _enabled
                                ? () => _perform(
                                    () =>
                                        player.seek(player.positionMs - 10000),
                                  )
                                : null,
                            icon: const Icon(Icons.replay_10),
                          ),
                          IconButton(
                            key: const ValueKey('annotation-playback'),
                            tooltip: player.state.playing
                                ? 'Пауза видео'
                                : 'Продолжить видео',
                            onPressed: _enabled
                                ? () => _perform(player.toggle)
                                : null,
                            icon: Icon(
                              player.state.playing
                                  ? Icons.pause
                                  : Icons.play_arrow,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Вперёд на 10 секунд',
                            onPressed: _enabled
                                ? () => _perform(
                                    () =>
                                        player.seek(player.positionMs + 10000),
                                  )
                                : null,
                            icon: const Icon(Icons.forward_10),
                          ),
                          Text(
                            videoTimestamp(player.positionMs),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (player.error != null)
                Positioned(
                  top: 76,
                  left: 16,
                  right: 16,
                  child: SafeArea(
                    child: Material(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            Expanded(child: Text(player.error!)),
                            TextButton(
                              onPressed: () =>
                                  _perform(() => player.load(player.index)),
                              child: const Text('Повторить'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (_studyOpen && _annotation == null)
                Positioned.fill(
                  child: ModalBarrier(
                    color: Colors.black54,
                    dismissible: true,
                    onDismiss: _closeStudy,
                  ),
                ),
              Positioned(
                key: const ValueKey('video-study-panel'),
                left: ((bounds.maxWidth - 1000) / 2).clamp(0, double.infinity),
                right: ((bounds.maxWidth - 1000) / 2).clamp(0, double.infinity),
                bottom: 0,
                height: bounds.maxHeight * .82,
                child: ExcludeFocus(
                  excluding: !_studyOpen || _annotation != null,
                  child: Offstage(
                    offstage: !_studyOpen || _annotation != null,
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(24),
                      ),
                      child: Material(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerLow,
                        child: _studyContents(),
                      ),
                    ),
                  ),
                ),
              ),
              if (noteLayout != null)
                Positioned.fromRect(
                  rect: noteLayout.editor,
                  child: _annotation!.forAnki
                      ? VocabularyEditor(
                          key: _vocabularyKey,
                          repository: VocabularyRepository(
                            widget.repository.repository,
                          ),
                          initialFront: _annotation!.initialBody ?? '',
                          source: VocabularySource(
                            kind: 'video',
                            title: widget.item.title,
                            detail: _annotation!.lesson.title,
                            mediaId: _annotation!.lesson.id,
                            mediaVersion: _annotation!.lesson.mediaVersion,
                            positionMs: _annotation!.positionMs,
                            endMs: _annotation!.endMs,
                          ),
                          onSaved: (_) {
                            _finishAnnotation();
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Карточка добавлена в словарь Anki',
                                ),
                              ),
                            );
                          },
                          onSavedAndNext: _nextAnkiCard,
                          onCancel: _finishAnnotation,
                        )
                      : VideoAnnotationEditor(
                          key: _annotationKey,
                          repository: widget.repository,
                          draft: _annotation!,
                          onSaved: (_) => _finishAnnotation(saved: true),
                          onCancel: _finishAnnotation,
                          onAnki: (draft) =>
                              setState(() => _annotation = draft),
                        ),
                ),
            ],
          );
        },
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final player = controller;
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_back());
      },
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.space): _PlaybackIntent('toggle'),
          SingleActivator(LogicalKeyboardKey.keyK): _PlaybackIntent('toggle'),
          SingleActivator(LogicalKeyboardKey.arrowLeft): _PlaybackIntent(
            'left',
          ),
          SingleActivator(LogicalKeyboardKey.keyJ): _PlaybackIntent('left'),
          SingleActivator(LogicalKeyboardKey.arrowRight): _PlaybackIntent(
            'right',
          ),
          SingleActivator(LogicalKeyboardKey.keyL): _PlaybackIntent('right'),
          SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true):
              _PlaybackIntent('fine-left'),
          SingleActivator(LogicalKeyboardKey.arrowRight, shift: true):
              _PlaybackIntent('fine-right'),
          SingleActivator(LogicalKeyboardKey.arrowUp): _PlaybackIntent('up'),
          SingleActivator(LogicalKeyboardKey.arrowDown): _PlaybackIntent(
            'down',
          ),
          SingleActivator(LogicalKeyboardKey.keyM): _PlaybackIntent('mute'),
          SingleActivator(LogicalKeyboardKey.keyF): _PlaybackIntent(
            'fullscreen',
          ),
          SingleActivator(LogicalKeyboardKey.escape): _PlaybackIntent('back'),
          SingleActivator(LogicalKeyboardKey.comma, shift: true):
              _PlaybackIntent('slower'),
          SingleActivator(LogicalKeyboardKey.period, shift: true):
              _PlaybackIntent('faster'),
          SingleActivator(LogicalKeyboardKey.keyG, control: true):
              _PlaybackIntent('seek'),
          SingleActivator(LogicalKeyboardKey.keyB, control: true):
              _PlaybackIntent('note'),
          SingleActivator(LogicalKeyboardKey.keyR, control: true):
              _PlaybackIntent('loop'),
          SingleActivator(LogicalKeyboardKey.keyS, control: true):
              _PlaybackIntent('captions'),
          SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true):
              _PlaybackIntent('undo'),
        },
        child: Actions(
          actions: {
            _PlaybackIntent: _PlaybackAction(
              enabled: () {
                final focusContext =
                    FocusManager.instance.primaryFocus?.context;
                return focusContext?.widget is! EditableText &&
                    focusContext
                            ?.findAncestorWidgetOfExactType<EditableText>() ==
                        null;
              },
              onInvoke: (intent) {
                unawaited(_perform(() => _command(intent.action)));
              },
            ),
          },
          child: Focus(
            focusNode: _focus,
            autofocus: true,
            child: Scaffold(
              backgroundColor: Colors.black,
              body: startupError != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(startupError!),
                            const SizedBox(height: 16),
                            TextButton.icon(
                              onPressed: _back,
                              icon: const Icon(Icons.arrow_back),
                              label: const Text('Вернуться к библиотеке'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : player == null
                  ? const SizedBox.shrink()
                  : player.current?.isAudio == true &&
                        !_studyOpen &&
                        _annotation == null
                  ? MusicPlayerView(
                      player: player,
                      repository: widget.repository,
                      item: widget.item,
                      onBack: () => _perform(_back),
                      onMini: () => _perform(_minimize),
                      onNotes: () => _perform(() => _studyPanel()),
                      run: _perform,
                    )
                  : _playerBody(player),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlaybackIntent extends Intent {
  final String action;
  const _PlaybackIntent(this.action);
}

class _PlaybackAction extends Action<_PlaybackIntent> {
  final bool Function() enabled;
  final void Function(_PlaybackIntent) onInvoke;
  _PlaybackAction({required this.enabled, required this.onInvoke});
  @override
  bool isEnabled(_PlaybackIntent intent) => enabled();
  @override
  Object? invoke(_PlaybackIntent intent) {
    onInvoke(intent);
    return null;
  }
}
