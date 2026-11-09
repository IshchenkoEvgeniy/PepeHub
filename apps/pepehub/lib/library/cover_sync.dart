import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;

import '../media/asset_store.dart';

class CoverSync {
  final AssetStore assets;
  CoverSync.local(this.assets);
  String path(String hash) =>
      p.join(assets.directory.path, 'obsidian-covers', 'personal', '$hash.png');
  static String? referenceHash(dynamic value) =>
      value is String && RegExp(r'^pepehub-cover:[a-f0-9]{64}$').hasMatch(value)
      ? value.substring(14)
      : null;

  Future<void> discardCached(String hash) async {
    final file = File(path(hash)).absolute;
    try {
      if (await FileSystemEntity.type(file.path, followLinks: false) ==
              FileSystemEntityType.file &&
          p.equals(await file.resolveSymbolicLinks(), p.normalize(file.path))) {
        await file.delete();
      }
    } on FileSystemException {
      // A cache file may be locked or already removed. The archive is saved.
    }
  }

  static bool validPng(Uint8List bytes) =>
      bytes.length >= 24 &&
      bytes.length <= 2097152 &&
      [
        137,
        80,
        78,
        71,
        13,
        10,
        26,
        10,
      ].asMap().entries.every((e) => bytes[e.key] == e.value) &&
      ByteData.sublistView(bytes).getUint32(16) > 0 &&
      ByteData.sublistView(bytes).getUint32(16) <= 2048 &&
      ByteData.sublistView(bytes).getUint32(20) > 0 &&
      ByteData.sublistView(bytes).getUint32(20) <= 2048;
  Future<Uint8List> normalize(Uint8List bytes) async {
    if (bytes.length > 16777216) {
      throw StateError('Исходная обложка превышает 16 МиБ');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes),
        descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      if (descriptor.width * descriptor.height > 40000000) {
        throw StateError('Слишком большое изображение');
      }
      final scale =
          (640 /
                  (descriptor.width > descriptor.height
                      ? descriptor.width
                      : descriptor.height))
              .clamp(0.0, 1.0);
      final codec = await descriptor.instantiateCodec(
        targetWidth: (descriptor.width * scale).round().clamp(1, 640),
        targetHeight: (descriptor.height * scale).round().clamp(1, 640),
      );
      try {
        final frame = await codec.getNextFrame();
        try {
          final data = await frame.image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          if (data == null) throw StateError('Изображение не прочитано');
          final result = data.buffer.asUint8List();
          if (!validPng(result)) {
            throw StateError('Обложка превышает поддерживаемый размер');
          }
          return result;
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

  Future<String> upload(Uint8List original) async {
    final bytes = await normalize(original),
        hash = sha256.convert(bytes).toString();
    await _cache(hash, bytes);
    return hash;
  }

  Future<String?> choose() async {
    final selected = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Обложка',
          extensions: ['png', 'jpg', 'jpeg', 'webp'],
          mimeTypes: ['image/png', 'image/jpeg', 'image/webp'],
        ),
      ],
    );
    if (selected == null) return null;
    if (await selected.length() > 16777216) {
      throw StateError('Обложка превышает 16 МиБ');
    }
    return 'pepehub-cover:${await upload(await selected.readAsBytes())}';
  }

  Future<void> _cache(String hash, Uint8List bytes) async {
    final file = File(path(hash));
    await file.parent.create(recursive: true);
    final partial = File('${file.path}.partial');
    await partial.writeAsBytes(bytes, flush: true);
    if (await file.exists()) await file.delete();
    await partial.rename(file.path);
  }
}
