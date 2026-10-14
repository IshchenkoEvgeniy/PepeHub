import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

import 'video_import.dart';

Future<String?> saveVideoFrame(Uint8List bytes, String name) async {
  if (bytes.isEmpty || bytes.length > 32 * 1024 * 1024) {
    throw StateError('Не удалось получить допустимый PNG-кадр');
  }
  if (Platform.isAndroid) {
    return videoFilesChannel.invokeMethod<String>('saveFrame', {
      'name': name,
      'bytes': bytes,
    });
  }
  final target = await getSaveLocation(
    suggestedName: name,
    acceptedTypeGroups: const [
      XTypeGroup(label: 'PNG', extensions: ['png']),
    ],
  );
  if (target == null) return null;
  await XFile.fromData(
    bytes,
    mimeType: 'image/png',
    name: name,
  ).saveTo(target.path);
  return target.path;
}
