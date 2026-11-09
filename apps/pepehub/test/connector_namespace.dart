import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Namespace of a former Obsidian Companion connection. Old installations
/// keep cards, notes and history under it; they are only imported now.
class LegacyConnector {
  final String url, token;
  const LegacyConnector(this.url, this.token);
  String get namespace => sha256.convert(utf8.encode('$url\n$token')).toString();
}
