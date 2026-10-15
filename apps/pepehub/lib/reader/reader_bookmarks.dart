import 'dart:convert';

import 'package:flutter/widgets.dart' show StringCharacters;

import '../data/repository.dart';
import 'reading_library.dart';

class ReaderBookmark {
  final String id, title, createdAt;
  final int chapter, offset;
  const ReaderBookmark({
    required this.id,
    required this.title,
    required this.chapter,
    required this.offset,
    required this.createdAt,
  });

  factory ReaderBookmark.fromJson(Map<String, dynamic> data) {
    if (data['layoutVersion'] != 2 ||
        data['id'] is! String ||
        (data['id'] as String).isEmpty ||
        data['title'] is! String ||
        (data['title'] as String).trim().isEmpty ||
        data['chapter'] is! int ||
        (data['chapter'] as int) < 0 ||
        data['offset'] is! int ||
        (data['offset'] as int) < 0 ||
        data['createdAt'] is! String) {
      throw const FormatException('Некорректная закладка');
    }
    return ReaderBookmark(
      id: data['id'] as String,
      title: data['title'] as String,
      chapter: data['chapter'] as int,
      offset: data['offset'] as int,
      createdAt: data['createdAt'] as String,
    );
  }

  Map<String, dynamic> toJson() => {
    'layoutVersion': 2,
    'id': id,
    'title': title,
    'chapter': chapter,
    'offset': offset,
    'createdAt': createdAt,
  };
}

/// Local bookmarks are independent of position autosaves and quoted notes.
/// Individual keys avoid overwriting another bookmark with a stale list.
class ReaderBookmarkStore {
  final Repository repository;
  final String hash;
  ReaderBookmarkStore(this.repository, this.hash);
  String get _prefix => 'reader-bookmark:$hash:';

  Future<List<ReaderBookmark>> list() async {
    final entries = await ReadingLibrary(repository).entries(_prefix);
    final values = [
      for (final data in entries.values) ReaderBookmark.fromJson(data),
    ];
    values.sort((a, b) {
      final compared = a.createdAt.compareTo(b.createdAt);
      return compared == 0 ? a.id.compareTo(b.id) : compared;
    });
    return values;
  }

  static String _title(String title) {
    final value = title.trim();
    if (value.isEmpty || value.characters.length > 120) {
      throw const FormatException('Название: от 1 до 120 знаков');
    }
    return value;
  }

  Future<ReaderBookmark> add({
    required String title,
    required int chapter,
    required int offset,
  }) async {
    if (chapter < 0 || offset < 0) throw ArgumentError('Некорректная позиция');
    final bookmark = ReaderBookmark(
      id: uuid.v4(),
      title: _title(title),
      chapter: chapter,
      offset: offset,
      createdAt: DateTime.now().toUtc().toIso8601String(),
    );
    await repository.setMeta(
      '$_prefix${bookmark.id}',
      jsonEncode(bookmark.toJson()),
    );
    return bookmark;
  }

  Future<void> rename(String id, String title) =>
      repository.db.transaction(() async {
        final normalized = _title(title);
        final key = '$_prefix$id';
        final raw = await repository.meta(key);
        if (raw == null) throw StateError('Закладка уже удалена');
        final bookmark = ReaderBookmark.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        await repository.setMeta(
          key,
          jsonEncode({...bookmark.toJson(), 'title': normalized}),
        );
      });

  Future<ReaderBookmark?> delete(String id) =>
      repository.db.transaction(() async {
        final key = '$_prefix$id';
        final raw = await repository.meta(key);
        if (raw == null) return null;
        final bookmark = ReaderBookmark.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        await repository.db.customStatement(
          'DELETE FROM metadata WHERE key=?',
          [key],
        );
        return bookmark;
      });

  Future<void> restore(ReaderBookmark bookmark) =>
      repository.db.transaction(() async {
        final key = '$_prefix${bookmark.id}';
        if (await repository.meta(key) == null) {
          await repository.setMeta(key, jsonEncode(bookmark.toJson()));
        }
      });
}
