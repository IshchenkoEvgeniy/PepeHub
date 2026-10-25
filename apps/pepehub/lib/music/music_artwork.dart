import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../media/embedded_artwork.dart';
import '../media/audio_artwork.dart' show findAudioArtwork;
import '../video/models.dart';

Future<String?> musicArtwork(VideoLesson lesson) async {
  if (lesson.isRemote) return null;
  try {
    final support = await getApplicationSupportDirectory();
    final folder = Directory(p.join(support.path, 'music-covers'));
    final key = sha256.convert('${lesson.id}:${lesson.mediaVersion}'.codeUnits);
    final target = File(p.join(folder.path, '$key.png'));
    if (await target.exists()) return target.path;
    Uint8List? bytes;
    if (lesson.source.startsWith('content:')) {
      bytes = await const MethodChannel('app.pepehub/audio_folder')
          .invokeMethod<Uint8List>('artwork', {'uri': lesson.source});
    } else {
      final source = lesson.source.startsWith('file:')
          ? File.fromUri(Uri.parse(lesson.source)).path
          : lesson.source;
      bytes = await embeddedArtwork(source);
      if (bytes == null) {
        final external = await findAudioArtwork(source);
        if (external != null &&
            await File.fromUri(external).length() <= 16 * 1024 * 1024) {
          bytes = await File.fromUri(external).readAsBytes();
        }
      }
    }
    if (bytes == null || bytes.length > 16 * 1024 * 1024) return null;
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 512,
      allowUpscaling: false,
    );
    try {
      final frame = await codec.getNextFrame();
      try {
        final png = await frame.image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (png == null) return null;
        await folder.create(recursive: true);
        final temporary = File('${target.path}.partial');
        await temporary.writeAsBytes(png.buffer.asUint8List(), flush: true);
        await temporary.rename(target.path);
        return target.path;
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  } catch (_) {
    return null;
  }
}
