import 'dart:convert';

import 'reader_layout.dart';
import 'reading_library.dart';

/// Rebase legacy plain-text anchors when restored navigation/code adds text.
class ReaderRebase {
  final ReaderDocument before, after;
  ReaderRebase(this.before, this.after);
  ({int chapter, int offset}) at(int chapter, int offset) {
    chapter = chapter.clamp(0, before.texts.length - 1);
    final old = before.book.chapters[chapter];
    final target = after.book.chapters.indexWhere((c) => c.path == old.path);
    if (target < 0) {
      return (chapter: chapter.clamp(0, after.texts.length - 1), offset: 0);
    }
    if (before.texts[chapter] == after.texts[target]) {
      return (
        chapter: target,
        offset: offset.clamp(0, after.texts[target].length),
      );
    }
    final next = after.book.chapters[target].paragraphs;
    var oldStart = 0, newStart = 0, cursor = 0;
    for (final paragraph in old.paragraphs) {
      final normalized = paragraph.replaceAll(RegExp(r'\s+'), ' ').trim();
      var match = cursor;
      while (match < next.length &&
          next[match].replaceAll(RegExp(r'\s+'), ' ').trim() != normalized) {
        match++;
      }
      if (match >= next.length) {
        throw StateError(
          'Не удалось безопасно перенести позицию главы ${old.title}',
        );
      }
      while (cursor < match) {
        newStart += next[cursor++].length + 2;
      }
      if (offset <= oldStart + paragraph.length) {
        final within = (offset - oldStart).clamp(0, paragraph.length);
        final normalizedOffset = paragraph
            .substring(0, within)
            .replaceAll(RegExp(r'\s+'), ' ')
            .trimLeft()
            .length;
        final positions = <int>[];
        for (final token in RegExp(r'\S+').allMatches(next[match])) {
          if (positions.isNotEmpty) positions.add(token.start - 1);
          positions.addAll(
            List.generate(token.end - token.start, (i) => token.start + i),
          );
        }
        final mapped = normalizedOffset >= positions.length
            ? next[match].length
            : positions[normalizedOffset];
        return (chapter: target, offset: newStart + mapped);
      }
      oldStart += paragraph.length + 2;
      newStart += next[cursor++].length + 2;
    }
    return (chapter: target, offset: after.texts[target].length);
  }

  int absolute(int offset) {
    final c = before.starts
        .lastIndexWhere((s) => s <= offset)
        .clamp(0, before.starts.length - 1);
    final mapped = at(c, offset - before.starts[c]);
    return after.starts[mapped.chapter] + mapped.offset;
  }
}

Future<void> migrateReaderLayout(
  ReadingLibrary library,
  String hash,
  ReaderDocument next,
  Future<ReaderDocument> Function() legacy,
) async {
  final repo = library.repository;
  if (await repo.meta('reader-layout-version:$hash') == '2') return;
  final key = 'reader:$hash', saved = await library.value('reader:$hash');
  final notes = (await library.entries('reading-note:')).entries
      .where((e) => e.value['hash'] == hash)
      .toList();
  final coverage = await library.value('reading-coverage:$hash');
  final mapping =
      saved['layoutVersion'] != 2 &&
          (saved.isNotEmpty || notes.isNotEmpty || coverage.isNotEmpty)
      ? ReaderRebase(await legacy(), next)
      : null;
  await repo.db.transaction(() async {
    if (mapping != null) {
      await repo.setMeta(
        'reader-layout-backup:$hash',
        jsonEncode({
          'reader': saved,
          'coverage': coverage,
          'notes': {for (final n in notes) n.key: n.value},
        }),
      );
      if (saved.isNotEmpty) {
        final oldChapter = ((saved['chapter'] as num?)?.toInt() ?? 0).clamp(
          0,
          mapping.before.texts.length - 1,
        );
        final oldOffset =
            (saved['textOffset'] as num?)?.toInt() ??
            mapping.before.offset(
              oldChapter,
              (saved['paragraph'] as num?)?.toInt() ?? 0,
              (saved['offset'] as num?)?.toInt() ?? 0,
            );
        final mapped = mapping.at(oldChapter, oldOffset);
        final history = [
          for (final raw in saved['returnTo'] as List? ?? [])
            mapping.at(raw['chapter'] as int, raw['offset'] as int),
        ];
        await library.update(key, {
          'chapter': mapped.chapter,
          'textOffset': mapped.offset,
          'layoutVersion': 2,
          'returnTo': [
            for (final h in history) {'chapter': h.chapter, 'offset': h.offset},
          ],
        });
      }
      for (final note in notes) {
        final a = mapping.at(
          note.value['chapter'] as int,
          note.value['start'] as int,
        );
        final b = mapping.at(
          note.value['chapter'] as int,
          note.value['end'] as int,
        );
        await repo.setMeta(
          'reading-note:${note.key}',
          jsonEncode({
            ...note.value,
            'chapter': a.chapter,
            'start': a.offset,
            'end': b.offset,
          }),
        );
      }
      if (coverage['ranges'] is List) {
        await library.update('reading-coverage:$hash', {
          'ranges': [
            for (final raw in coverage['ranges'] as List)
              [
                mapping.absolute(raw[0] as int),
                mapping.absolute(raw[1] as int),
              ],
          ],
        });
      }
    }
    await library.update('reading-index:$hash', {
      'starts': next.starts,
      'length': next.length,
      'lengths': [for (final t in next.texts) t.length],
      'chapters': [for (final c in next.book.chapters) c.title],
      'paragraphStarts': [
        for (final c in next.book.chapters) paragraphOffsets(c.paragraphs),
      ],
    });
    await repo.setMeta('reader-layout-version:$hash', '2');
  });
}
