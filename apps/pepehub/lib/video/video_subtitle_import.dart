import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

import 'video_subtitles.dart';

class VideoSubtitleFile {
  final String name;
  final Uint8List bytes;
  const VideoSubtitleFile(this.name, this.bytes);
}

typedef VideoSubtitlePicker = Future<VideoSubtitleFile?> Function();

Future<VideoSubtitleFile?> pickVideoSubtitles() async {
  if (Platform.isAndroid) {
    final result = await const MethodChannel('app.pepehub/video_files')
        .invokeMapMethod<String, dynamic>('pickSubtitle');
    if (result == null) return null;
    return VideoSubtitleFile(
      result['name'] as String,
      result['bytes'] as Uint8List,
    );
  }
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'Субтитры', extensions: ['srt', 'vtt', 'ass', 'ssa']),
    ],
  );
  if (file == null) return null;
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in file.openRead()) {
    if (bytes.length + chunk.length > maxVideoSubtitleBytes) {
      throw const FormatException('Субтитры больше 8 МиБ');
    }
    bytes.add(chunk);
  }
  return VideoSubtitleFile(file.name, bytes.takeBytes());
}
