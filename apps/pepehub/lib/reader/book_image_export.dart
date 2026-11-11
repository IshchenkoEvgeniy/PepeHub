import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

import '../video/video_import.dart' show videoFilesChannel;

/// File type of an embedded book image, from its first bytes.
({String extension, String mime, String label}) bookImageType(Uint8List b) {
  bool starts(List<int> signature, [int at = 0]) {
    if (b.length < at + signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (b[at + i] != signature[i]) return false;
    }
    return true;
  }

  if (starts(const [0x89, 0x50, 0x4e, 0x47])) {
    return (extension: 'png', mime: 'image/png', label: 'PNG');
  }
  if (starts(const [0xff, 0xd8, 0xff])) {
    return (extension: 'jpg', mime: 'image/jpeg', label: 'JPEG');
  }
  if (starts(const [0x47, 0x49, 0x46, 0x38])) {
    return (extension: 'gif', mime: 'image/gif', label: 'GIF');
  }
  if (starts(const [0x52, 0x49, 0x46, 0x46]) &&
      starts(const [0x57, 0x45, 0x42, 0x50], 8)) {
    return (extension: 'webp', mime: 'image/webp', label: 'WebP');
  }
  if (starts(const [0x42, 0x4d])) {
    return (extension: 'bmp', mime: 'image/bmp', label: 'BMP');
  }
  final head = String.fromCharCodes(b.take(256)).toLowerCase();
  if (head.contains('<svg') || head.contains('<?xml')) {
    return (extension: 'svg', mime: 'image/svg+xml', label: 'SVG');
  }
  return (extension: 'img', mime: 'image/*', label: 'изображение');
}

/// A file name for a saved illustration: book, then caption or number.
String bookImageFileName(Uint8List bytes, {String? book, String? label}) {
  String clean(String value) => value
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final parts = [
    if (book != null && clean(book).isNotEmpty) clean(book),
    if (label != null && clean(label).isNotEmpty) clean(label),
  ];
  var base = parts.isEmpty ? 'Иллюстрация' : parts.join(' — ');
  if (base.length > 120) base = base.substring(0, 120).trim();
  return '$base.${bookImageType(bytes).extension}';
}

/// Saves an illustration where the user chooses. Returns the saved location
/// or null when the dialog was cancelled.
Future<String?> saveBookImage(Uint8List bytes, String name) async {
  if (bytes.isEmpty || bytes.length > 32 * 1024 * 1024) {
    throw StateError('Изображение пустое или больше 32 МиБ');
  }
  final type = bookImageType(bytes);
  if (Platform.isAndroid) {
    return videoFilesChannel.invokeMethod<String>('saveFrame', {
      'name': name,
      'bytes': bytes,
      'mime': type.mime,
    });
  }
  final target = await getSaveLocation(
    suggestedName: name,
    acceptedTypeGroups: [
      XTypeGroup(label: type.label, extensions: [type.extension]),
    ],
  );
  if (target == null) return null;
  await XFile.fromData(bytes, mimeType: type.mime, name: name)
      .saveTo(target.path);
  return target.path;
}
