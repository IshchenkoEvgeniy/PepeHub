import 'dart:async';

import 'package:flutter/services.dart';

import 'asset_store.dart';

const bookFilesChannel = MethodChannel('app.pepehub/book_files');

/// Cold-start drain and warm intents share a serial queue. Native staging is
/// released even if validation/import fails; it contains only the incoming file.
class AndroidBookFiles {
  final Future<void> Function(String path) onFile;
  final void Function(Object error) onError;
  bool disposed = false, draining = false, requested = false;
  AndroidBookFiles({required this.onFile, required this.onError});

  void start() {
    bookFilesChannel.setMethodCallHandler((call) async {
      if (call.method == 'available') unawaited(drain());
    });
    unawaited(drain());
  }

  Future<void> drain() async {
    if (disposed) return;
    requested = true;
    if (draining) return;
    draining = true;
    try {
      do {
        requested = false;
        while (!disposed) {
          Map<String, dynamic>? file;
          try {
            file = await bookFilesChannel.invokeMapMethod<String, dynamic>(
              'next',
            );
          } on PlatformException catch (e) {
            // Native 'next' consumes the bad URI before reporting the error.
            if (e.code != 'book_file') rethrow;
            if (!disposed) onError(e);
            continue;
          }
          if (file == null) break;
          try {
            if (!disposed) await onFile(file['path'] as String);
          } catch (e) {
            if (!disposed) onError(e);
          } finally {
            await bookFilesChannel.invokeMethod<void>('release', {
              'token': file['token'],
            });
          }
        }
      } while (requested && !disposed);
    } catch (e) {
      if (!disposed) onError(e);
    } finally {
      draining = false;
    }
  }

  void dispose() {
    disposed = true;
    bookFilesChannel.setMethodCallHandler(null);
  }
}

String bookShareMime(String filename) => switch (filename
    .toLowerCase()
    .split('.')
    .last) {
  'pdf' => 'application/pdf',
  'epub' => 'application/epub+zip',
  'fb2' => 'application/x-fictionbook+xml',
  'zip' => 'application/zip',
  'txt' => 'text/plain',
  'md' || 'markdown' => 'text/markdown',
  'html' || 'htm' => 'text/html',
  'xhtml' => 'application/xhtml+xml',
  'rtf' => 'application/rtf',
  'docx' =>
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'mp3' => 'audio/mpeg',
  'm4a' || 'm4b' => 'audio/mp4',
  'aac' => 'audio/aac',
  'ogg' || 'opus' => 'audio/ogg',
  'flac' => 'audio/flac',
  'wav' => 'audio/wav',
  _ => 'application/octet-stream',
};

Future<void> shareBookFiles(List<LocalAsset> files) async {
  if (files.isEmpty) throw StateError('Локальный файл книги не найден');
  if (files.length > 500) {
    throw StateError('Android: за один раз можно отправить до 500 глав');
  }
  final types = files.map((a) => bookShareMime(a.filename)).toSet();
  await bookFilesChannel.invokeMethod<void>('share', {
    'paths': files.map((a) => a.path).toList(),
    'names': files.map((a) => a.filename).toList(),
    'mime': types.length == 1
        ? types.single
        : types.every((t) => t.startsWith('audio/'))
        ? 'audio/*'
        : '*/*',
  });
}
