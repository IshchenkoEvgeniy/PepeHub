import 'embedded_artwork.dart';

import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';

import 'asset_store.dart';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Artwork is optional: failure must never prevent listening to a book.
Future<Uri?> findAudioArtwork(String source) async {
  try {
    if (source.startsWith('content:')) {
      final uri = await const MethodChannel('app.pepehub/audio_folder')
          .invokeMethod<String>('cover', {'uri': source});
      return uri == null ? null : Uri.parse(uri);
    }
    final directory = Directory(p.dirname(source));
    final images = <File>[];
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is File &&
          [
            '.jpg',
            '.jpeg',
            '.png',
            '.webp',
          ].contains(p.extension(entry.path).toLowerCase())) {
        images.add(entry);
      }
    }
    images.sort(
      (a, b) =>
          artworkOrder(p.basename(a.path))
              .compareTo(artworkOrder(p.basename(b.path))),
    );
    return images.isEmpty ? null : images.first.uri;
  } catch (_) {
    return null;
  }
}

String artworkOrder(String name) {
  final lower = name.toLowerCase();
  final preferred = [
    'cover',
    'folder',
    'front',
    'обложка',
  ].indexOf(p.basenameWithoutExtension(lower));
  return '${preferred < 0 ? 9 : preferred}:$lower';
}

class ArtworkStore {
  final AssetStore assets;
  ArtworkStore(this.assets);
  Future<Uri?> load(String bookId) async {
    try {
      return await _load(bookId);
    } catch (_) {
      return null;
    }
  }

  Future<Uri?> _load(String bookId) async {
    if (await assets.repository.meta('audio-cover-hidden:$bookId') == 'true') {
      return null;
    }
    final saved = await assets.repository.meta('audio-cover:$bookId');
    if (saved != null && await File(saved).exists()) return File(saved).uri;
    final tracks = await assets.audioTracks(bookId);
    if (tracks.isEmpty) return null;
    final source = tracks.first.path;
    if (source.startsWith('content:')) {
      try {
        final bytes = await const MethodChannel('app.pepehub/audio_folder')
            .invokeMethod<Uint8List>('artwork', {'uri': source});
        if (bytes != null) return await save(bookId, bytes);
      } catch (_) {}
    } else {
      var current = source;
      for (var i = 0; i < 5; i++) {
        final found = await findAudioArtwork(current);
        if (found != null) {
          final file = File.fromUri(found);
          if (await file.length() <= 16 * 1024 * 1024) {
            return save(bookId, await file.readAsBytes());
          }
        }
        final dir = p.dirname(current);
        if (!RegExp(
          r'^(cd|disc|disk|диск|часть|part|том)[-_ .]*\d+$',
          caseSensitive: false,
        ).hasMatch(p.basename(dir))) {
          break;
        }
        current = p.join(p.dirname(dir), 'track.mp3');
      }
    }
    if (!source.startsWith('content:')) {
      final bytes = await embeddedArtwork(source);
      if (bytes != null) return save(bookId, bytes);
    }
    return null;
  }

  Future<Uri?> choose(String bookId) async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Обложка',
          extensions: ['jpg', 'jpeg', 'png', 'webp'],
          mimeTypes: ['image/jpeg', 'image/png', 'image/webp'],
        ),
      ],
    );
    if (file == null) return null;
    if (await file.length() > 16 * 1024 * 1024) {
      throw StateError('Обложка больше 16 МиБ');
    }
    return save(bookId, await file.readAsBytes());
  }

  Future<Uri> save(String bookId, Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 512,
      allowUpscaling: false,
    );
    try {
      final frame = await codec.getNextFrame();
      try {
        final data = await frame.image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (data == null) throw StateError('Изображение не прочитано');
        final dir = Directory(p.join(assets.directory.path, 'covers'));
        await dir.create(recursive: true);
        // New names avoid stale Flutter/MediaSession bitmap caches.
        final file = File(
          p.join(dir.path, '${DateTime.now().microsecondsSinceEpoch}.png'),
        );
        await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
        await assets.repository.setMeta('audio-cover:$bookId', file.path);
        await assets.repository.setMeta('audio-cover-hidden:$bookId', 'false');
        return file.uri;
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }
}
