import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Own covers of videos and courses: PNG files in the app folder. An item
/// keeps only the file name, so the folder can move with the app data.
class VideoCovers {
  static final instance = VideoCovers();

  /// Set in tests; otherwise the app support folder.
  Directory? directory;
  VideoCovers({this.directory});

  static final _name = RegExp(r'^[a-f0-9-]{36}\.png$');

  /// Resolved once by [ready]; null before that or for a foreign name.
  File? file(String? name) {
    final folder = directory;
    if (folder == null || name == null || !_name.hasMatch(name)) return null;
    return File(p.join(folder.path, name));
  }

  Future<Directory> ready() async {
    final existing = directory;
    if (existing != null) return existing;
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      // Widget tests have no app folder; they pass [directory] when needed.
      throw StateError('Папка обложек недоступна');
    }
    final support = await getApplicationSupportDirectory();
    return directory = Directory(p.join(support.path, 'video-covers'));
  }

  /// Saves [bytes] (any image the platform decodes) at most 960 px wide.
  Future<String> save(Uint8List bytes) async {
    final png = await _normalize(bytes);
    final folder = await ready();
    await folder.create(recursive: true);
    final name = '${const Uuid().v4()}.png';
    final target = File(p.join(folder.path, name));
    final partial = File('${target.path}.partial');
    await partial.writeAsBytes(png, flush: true);
    await partial.rename(target.path);
    return name;
  }

  /// Saves PNG bytes as they are, for tests without an image codec.
  Future<String> saveRaw(Uint8List png) async {
    final folder = await ready();
    await folder.create(recursive: true);
    final name = '${const Uuid().v4()}.png';
    await File(p.join(folder.path, name)).writeAsBytes(png, flush: true);
    return name;
  }

  Future<void> discard(String? name) async {
    if (name == null) return;
    await ready();
    final target = file(name);
    try {
      if (target != null && await target.exists()) await target.delete();
    } on FileSystemException {
      // A locked cover stays; it is only a few hundred kilobytes.
    }
  }

  /// Picture chosen by the user, or null when the dialog was closed.
  static Future<Uint8List?> choose() async {
    final selected = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Картинка',
          extensions: ['png', 'jpg', 'jpeg', 'webp'],
          mimeTypes: ['image/png', 'image/jpeg', 'image/webp'],
        ),
      ],
    );
    if (selected == null) return null;
    if (await selected.length() > 32 * 1024 * 1024) {
      throw StateError('Картинка больше 32 МБ');
    }
    return selected.readAsBytes();
  }

  static Future<Uint8List> _normalize(Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > 32 * 1024 * 1024) {
      throw StateError('Картинка пустая или больше 32 МБ');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      if (descriptor.width * descriptor.height > 60000000) {
        throw StateError('Слишком большая картинка');
      }
      final scale = (960 / descriptor.width).clamp(0.0, 1.0);
      final codec = await descriptor.instantiateCodec(
        targetWidth: (descriptor.width * scale).round().clamp(1, 960),
        targetHeight: (descriptor.height * scale).round().clamp(1, 4000),
      );
      try {
        final frame = await codec.getNextFrame();
        try {
          final data = await frame.image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          if (data == null) throw StateError('Картинка не прочитана');
          return data.buffer.asUint8List();
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor.dispose();
      buffer.dispose();
    }
  }
}
