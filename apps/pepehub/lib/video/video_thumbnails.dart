import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../ui/shelf_components.dart';
import 'models.dart';
import 'video_import.dart' show videoFilesChannel;
import 'video_seek_previews.dart';

/// Produces one small frame of a video. Replaceable in tests.
abstract class VideoFrameSource {
  /// Frames decoded at once: Android decodes in parallel, the desktop
  /// decoder is one player.
  int get concurrency;
  Future<Uint8List?> frame(VideoLesson lesson);
}

class PlatformVideoFrameSource implements VideoFrameSource {
  NativeVideoPreviewDecoder? _decoder;
  Timer? _idle;

  @override
  int get concurrency => Platform.isAndroid ? 2 : 1;

  @override
  Future<Uint8List?> frame(VideoLesson lesson) async {
    if (Platform.isAndroid) {
      return videoFilesChannel.invokeMethod<Uint8List>('thumbnail', {
        'uri': lesson.source,
        'size': 320,
      });
    }
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
      return null;
    }
    _idle?.cancel();
    final decoder = _decoder ??= NativeVideoPreviewDecoder();
    try {
      final duration = lesson.durationMs;
      // A tenth in, at most 30 s: past black intros, never past the end.
      final at = duration != null && duration > 0
          ? math.min(duration ~/ 10, 30000)
          : 3000;
      return await decoder.read(lesson, at) ??
          (at > 0 ? await decoder.read(lesson, 0) : null);
    } catch (_) {
      await _close();
      return null;
    } finally {
      _idle = Timer(const Duration(seconds: 20), _close);
    }
  }

  Future<void> _close() async {
    _idle?.cancel();
    final decoder = _decoder;
    _decoder = null;
    try {
      await decoder?.close();
    } catch (_) {
      /* Previews are optional. */
    }
  }
}

class _NoFrames implements VideoFrameSource {
  const _NoFrames();
  @override
  int get concurrency => 1;
  @override
  Future<Uint8List?> frame(VideoLesson lesson) async => null;
}

class _Request {
  final VideoLesson lesson;
  final completer = Completer<Uint8List?>();
  int listeners = 1;
  bool started = false;
  _Request(this.lesson);
}

/// Video previews for lists: decoded lazily for rows on screen, at most
/// [VideoFrameSource.concurrency] at a time, newest request first, kept on
/// disk in the app cache (not in the library) and briefly in memory.
class VideoThumbnails {
  final VideoFrameSource source;
  final Future<Directory?> Function() _directory;
  VideoThumbnails({
    VideoFrameSource? source,
    Future<Directory?> Function()? directory,
  }) : source = source ?? PlatformVideoFrameSource(),
       _directory = directory ?? _defaultDirectory;

  /// Widget tests never decode real files.
  static final VideoThumbnails instance = VideoThumbnails(
    source: Platform.environment.containsKey('FLUTTER_TEST')
        ? const _NoFrames()
        : null,
    directory: Platform.environment.containsKey('FLUTTER_TEST')
        ? () async => null
        : null,
  );

  static const _memoryEntries = 300, _memoryBytes = 24 * 1024 * 1024;
  static const _diskFiles = 4000;

  final _memory = <String, Uint8List>{};
  final _failed = <String>{};
  final _requests = <String, _Request>{};
  int _bytes = 0, _active = 0;
  Future<Directory?>? _dir;

  static Future<Directory?> _defaultDirectory() async {
    final cache = await getApplicationCacheDirectory();
    final dir = Directory(p.join(cache.path, 'video-thumbnails'));
    await dir.create(recursive: true);
    return dir;
  }

  static bool supports(VideoLesson lesson) =>
      !lesson.isRemote && !lesson.isAudio && !lesson.missing;

  String _key(VideoLesson lesson) => sha1
      .convert(utf8.encode('${lesson.source}\n${lesson.mediaVersion}'))
      .toString();

  /// The preview when it is already in memory.
  Uint8List? cached(VideoLesson lesson) {
    if (!supports(lesson)) return null;
    final key = _key(lesson);
    final bytes = _memory.remove(key);
    if (bytes != null) _memory[key] = bytes;
    return bytes;
  }

  /// Null when the video has no preview (a link, a damaged or deleted file).
  Future<Uint8List?> load(VideoLesson lesson) {
    if (!supports(lesson)) return Future.value();
    final key = _key(lesson);
    final memory = cached(lesson);
    if (memory != null) return Future.value(memory);
    if (_failed.contains(key)) return Future.value();
    final waiting = _requests[key];
    if (waiting != null) {
      waiting.listeners++;
      // Scrolled back: decode it next.
      if (!waiting.started) _requests[key] = _requests.remove(key)!;
      return waiting.completer.future;
    }
    final request = _requests[key] = _Request(lesson);
    unawaited(_fromDisk(key, request));
    return request.completer.future;
  }

  /// A row left the screen: its frame is not decoded unless another row
  /// still waits for it.
  void cancel(VideoLesson lesson) {
    if (!supports(lesson)) return;
    final key = _key(lesson);
    final request = _requests[key];
    if (request == null || request.started) return;
    if (--request.listeners > 0) return;
    _requests.remove(key);
    if (!request.completer.isCompleted) request.completer.complete();
  }

  Future<File?> _file(String key) async {
    final dir = await (_dir ??= _openDirectory());
    return dir == null ? null : File(p.join(dir.path, '$key.jpg'));
  }

  Future<Directory?> _openDirectory() async {
    try {
      final dir = await _directory();
      if (dir != null) unawaited(_prune(dir));
      return dir;
    } catch (_) {
      return null;
    }
  }

  /// Keeps the disk cache bounded: the oldest previews go first.
  Future<void> _prune(Directory dir) async {
    try {
      final files = await dir.list().where((e) => e is File).toList();
      if (files.length <= _diskFiles) return;
      final dated = [
        for (final file in files) (file as File, (await file.stat()).modified),
      ]..sort((a, b) => a.$2.compareTo(b.$2));
      for (final (file, _) in dated.take(files.length - _diskFiles ~/ 2)) {
        await file.delete();
      }
    } catch (_) {
      /* A cache that cannot be pruned still works. */
    }
  }

  Future<void> _fromDisk(String key, _Request request) async {
    try {
      final file = await _file(key);
      if (file != null && await file.exists()) {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) {
          _finish(key, request, bytes);
          return;
        }
      }
    } catch (_) {
      /* Decode it again. */
    }
    if (_requests[key] == request && !request.completer.isCompleted) _pump();
  }

  void _pump() {
    while (_active < source.concurrency) {
      final next = _requests.entries
          .toList()
          .reversed
          .where((entry) => !entry.value.started)
          .firstOrNull;
      if (next == null) return;
      next.value.started = true;
      _active++;
      unawaited(_decode(next.key, next.value));
    }
  }

  Future<void> _decode(String key, _Request request) async {
    Uint8List? bytes;
    try {
      bytes = await source
          .frame(request.lesson)
          .timeout(const Duration(seconds: 20));
      if (bytes != null && (bytes.isEmpty || bytes.length > 2 * 1024 * 1024)) {
        bytes = null;
      }
      if (bytes != null) {
        final file = await _file(key);
        await file?.writeAsBytes(bytes, flush: false);
      }
    } catch (_) {
      bytes = null;
    } finally {
      _active--;
    }
    if (bytes == null) _failed.add(key);
    _finish(key, request, bytes);
    _pump();
  }

  void _finish(String key, _Request request, Uint8List? bytes) {
    if (_requests[key] == request) _requests.remove(key);
    if (bytes != null) {
      _memory.remove(key);
      _memory[key] = bytes;
      _bytes += bytes.length;
      while (_memory.length > _memoryEntries || _bytes > _memoryBytes) {
        _bytes -= _memory.remove(_memory.keys.first)!.length;
      }
    }
    if (!request.completer.isCompleted) request.completer.complete(bytes);
  }
}

/// A 16:9 preview frame with a fallback icon and an optional corner label.
class VideoThumbnail extends StatefulWidget {
  final VideoLesson? lesson;

  /// Null fills the available width (tiles and large cards).
  final double? width;
  final IconData icon;
  final String? label;
  final VideoThumbnails? thumbnails;

  /// Selection mode: a check mark over the frame.
  final bool? checked;
  final double radius;
  const VideoThumbnail({
    super.key,
    required this.lesson,
    this.width = 96,
    this.icon = Icons.ondemand_video,
    this.label,
    this.thumbnails,
    this.checked,
    this.radius = 8,
  });

  @override
  State<VideoThumbnail> createState() => _VideoThumbnailState();
}

class _VideoThumbnailState extends State<VideoThumbnail> {
  Uint8List? bytes;
  VideoLesson? _requested;

  VideoThumbnails get _service => widget.thumbnails ?? VideoThumbnails.instance;

  @override
  void initState() {
    super.initState();
    _request();
  }

  @override
  void didUpdateWidget(VideoThumbnail old) {
    super.didUpdateWidget(old);
    final next = widget.lesson;
    if (next?.source != _requested?.source ||
        next?.mediaVersion != _requested?.mediaVersion) {
      _release();
      bytes = null;
      _request();
    }
  }

  void _request() {
    final lesson = widget.lesson;
    _requested = lesson;
    if (lesson == null) return;
    bytes = _service.cached(lesson);
    if (bytes != null) return;
    _service.load(lesson).then((value) {
      if (mounted && value != null && identical(_requested, lesson)) {
        setState(() => bytes = value);
      }
    });
  }

  void _release() {
    final lesson = _requested;
    if (lesson != null && bytes == null) _service.cancel(lesson);
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final image = bytes;
    final width = widget.width;
    Widget frame(double cacheWidth) => Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: palette.accent.withValues(alpha: 0.12)),
        if (image == null)
          Icon(widget.icon, color: palette.accent)
        else
          Image.memory(
            image,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            cacheWidth: (cacheWidth * MediaQuery.devicePixelRatioOf(context))
                .round()
                .clamp(1, 1280),
            errorBuilder: (_, _, _) => Icon(widget.icon, color: palette.accent),
          ),
        if (widget.label != null)
          Positioned(
            right: 4,
            bottom: 4,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                child: Text(
                  widget.label!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    height: 1.2,
                  ),
                ),
              ),
            ),
          ),
        if (widget.checked != null)
          Positioned(
            left: 4,
            top: 4,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: widget.checked! ? palette.accent : Colors.black45,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              child: Icon(
                Icons.check,
                size: 16,
                color: widget.checked! ? palette.onAccent : Colors.transparent,
              ),
            ),
          ),
      ],
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: width != null
          ? SizedBox(width: width, height: width * 9 / 16, child: frame(width))
          : AspectRatio(
              aspectRatio: 16 / 9,
              child: LayoutBuilder(
                builder: (_, constraints) => frame(
                  constraints.maxWidth.isFinite ? constraints.maxWidth : 320,
                ),
              ),
            ),
    );
  }
}
