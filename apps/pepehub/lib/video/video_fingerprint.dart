import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'models.dart';

/// A bounded sample identifies rename candidates. It is not a full-file proof.
Future<VideoFileIdentity> fingerprintVideoFile(String path) async {
  const part = 65536;
  final file = File(path), before = await File(path).stat();
  final handle = await file.open();
  try {
    final head = await handle.read(part);
    var tail = <int>[];
    if (before.size > part) {
      await handle.setPosition((before.size - part).clamp(0, before.size));
      tail = await handle.read(part);
    }
    final after = await file.stat();
    if (after.size != before.size || after.modified != before.modified) {
      throw StateError('Файл изменился во время проверки: $path');
    }
    final hash = sha256.convert([
      ...utf8.encode('head-tail-v1:${before.size}:'),
      ...head,
      ...tail,
    ]).toString();
    return VideoFileIdentity(
      before.size,
      before.modified.millisecondsSinceEpoch,
      hash,
    );
  } finally {
    await handle.close();
  }
}
