import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';

import '../audio/audio_folder.dart';
import 'reading_library.dart';

String exportReadingNotes(List<ReadingNote> notes, String format) {
  if (format == 'json') {
    return const JsonEncoder.withIndent('  ').convert({
      'format': 'pepehub-reading-notes',
      'version': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'notes': notes.map((n) => n.toJson()).toList(),
    });
  }
  // Escape user text so quotes/comments cannot become embedded HTML or links.
  String plain(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAllMapped(RegExp(r'[\\`*_{}\[\]()#+.!|~-]'), (m) => '\\${m[0]}');
  final out = StringBuffer('# Заметки PepeHub\n\n');
  final books = <String, List<ReadingNote>>{};
  for (final note in notes) {
    books.putIfAbsent(note.bookId, () => []).add(note);
  }
  for (final group in books.values) {
    group.sort(
      (a, b) => a.chapter != b.chapter
          ? a.chapter.compareTo(b.chapter)
          : a.start.compareTo(b.start),
    );
    out.writeln('## ${plain(group.first.bookTitle)}\n');
    for (final n in group) {
      out.writeln('### ${plain(n.chapterTitle)}\n');
      out.writeln(n.quote.split('\n').map((s) => '> ${plain(s)}').join('\n'));
      if (n.comment.isNotEmpty) out.writeln('\n${plain(n.comment)}');
      out.writeln(
        '\nЦвет: ${n.color} · Позиция: ${n.chapter + 1}:${n.start}–${n.end}',
      );
      if (n.tags.isNotEmpty) out.writeln('Теги: ${plain(n.tags.join(', '))}');
      if (n.characters.isNotEmpty) {
        out.writeln('Персонажи: ${plain(n.characters.join(', '))}');
      }
      out.writeln('\n');
    }
  }
  return out.toString();
}

Future<bool> saveReadingNotesExport(
  List<ReadingNote> notes,
  String format,
) async {
  final text = exportReadingNotes(notes, format);
  if (utf8.encode(text).length > 16 * 1024 * 1024) {
    throw StateError('Экспорт больше 16 МиБ. Выберите книгу или фильтр.');
  }
  final name =
      'PepeHub-notes-${DateTime.now().toIso8601String().substring(0, 10)}.$format';
  if (Platform.isAndroid) {
    return await audioFolderChannel.invokeMethod<bool>('exportStatistics', {
          'name': name,
          'mime': format == 'md' ? 'text/markdown' : 'application/json',
          'text': text,
        }) ??
        false;
  }
  final location = await getSaveLocation(
    suggestedName: name,
    acceptedTypeGroups: [
      XTypeGroup(label: format.toUpperCase(), extensions: [format]),
    ],
  );
  if (location == null) return false;
  await File(location.path).writeAsString(text, flush: true);
  return true;
}
