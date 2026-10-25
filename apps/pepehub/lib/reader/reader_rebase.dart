import 'dart:convert';

import '../data/repository.dart' show uuid;
import 'reader_layout.dart';
import 'reading_library.dart';
import 'text_book.dart' show currentBookLayout;

/// Maps chapter-local anchors from one parsed layout of a book to another.
abstract interface class ReaderAnchorMap {
  ReaderDocument get before;
  ReaderDocument get after;
  ({int chapter, int offset}) at(int chapter, int offset);
}

int _absolute(ReaderAnchorMap map, int offset) {
  final c = map.before.starts
      .lastIndexWhere((s) => s <= offset)
      .clamp(0, map.before.starts.length - 1);
  final mapped = map.at(c, offset - map.before.starts[c]);
  return map.after.starts[mapped.chapter] + mapped.offset;
}

/// Rebase legacy plain-text anchors when restored navigation/code adds text.
class ReaderRebase implements ReaderAnchorMap {
  @override
  final ReaderDocument before, after;
  ReaderRebase(this.before, this.after);
  @override
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

  int absolute(int offset) => _absolute(this, offset);
}

/// Same paragraphs in the same order, different chapter boundaries (for
/// example FB2 nested sections split into chapters).
class ReaderParagraphRebase implements ReaderAnchorMap {
  @override
  final ReaderDocument before, after;
  late final List<int> _beforeFirst = _firsts(before),
      _afterFirst = _firsts(after);
  ReaderParagraphRebase(this.before, this.after) {
    final a = [for (final c in before.book.chapters) ...c.paragraphs];
    final b = [for (final c in after.book.chapters) ...c.paragraphs];
    var same = a.length == b.length;
    for (var i = 0; same && i < a.length; i++) {
      same = a[i] == b[i];
    }
    if (!same) {
      throw StateError('Текст книги изменился, позиции нельзя перенести');
    }
  }

  static List<int> _firsts(ReaderDocument document) {
    var count = 0;
    return [
      for (final c in document.book.chapters)
        (() {
          final first = count;
          count += c.paragraphs.length;
          return first;
        })(),
    ];
  }

  @override
  ({int chapter, int offset}) at(int chapter, int offset) {
    chapter = chapter.clamp(0, before.texts.length - 1);
    final place = before.paragraphAt(chapter, offset);
    final global = _beforeFirst[chapter] + place.paragraph;
    var target = 0;
    for (var c = 0; c < _afterFirst.length; c++) {
      if (_afterFirst[c] <= global &&
          after.book.chapters[c].paragraphs.isNotEmpty) {
        target = c;
      }
    }
    final local = global - _afterFirst[target];
    if (local >= after.book.chapters[target].paragraphs.length) {
      return (chapter: target, offset: after.texts[target].length);
    }
    return (chapter: target, offset: after.offset(target, local, place.within));
  }

  int absolute(int offset) => _absolute(this, offset);
}

/// Exact concatenated source, different chapter boundaries (TXT headings).
class ReaderLinearRebase implements ReaderAnchorMap {
  @override
  final ReaderDocument before, after;
  ReaderLinearRebase(this.before, this.after) {
    if (before.texts.join() != after.texts.join()) {
      throw StateError('Текст книги изменился');
    }
  }
  @override
  ({int chapter, int offset}) at(int chapter, int offset) {
    chapter = chapter.clamp(0, before.texts.length - 1);
    final absolute =
        before.starts[chapter] + offset.clamp(0, before.texts[chapter].length);
    var low = 0, high = after.starts.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (after.starts[middle] <= absolute) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    final next = (low - 1).clamp(0, after.texts.length - 1);
    return (
      chapter: next,
      offset: (absolute - after.starts[next]).clamp(
        0,
        after.texts[next].length,
      ),
    );
  }
}

class _ChainedRebase implements ReaderAnchorMap {
  final ReaderAnchorMap first, second;
  _ChainedRebase(this.first, this.second);
  @override
  ReaderDocument get before => first.before;
  @override
  ReaderDocument get after => second.after;
  @override
  ({int chapter, int offset}) at(int chapter, int offset) {
    final middle = first.at(chapter, offset);
    return second.at(middle.chapter, middle.offset);
  }
}

/// Brings saved anchors of one book to [currentBookLayout] once per device.
///
/// [legacy] parses the original (layout 1) projection; [previous] parses
/// layout 2 when its chapter boundaries differ from [next]. [prior] parses
/// layout 3 for TXT heading migration.
Future<void> migrateReaderLayout(
  ReadingLibrary library,
  String hash,
  ReaderDocument next,
  Future<ReaderDocument> Function() legacy, {
  Future<ReaderDocument> Function()? previous,
  Future<ReaderDocument> Function()? prior,
  Future<ReaderDocument> Function(int layout)? sourceLayout,
}) async {
  final repo = library.repository;
  final version = await repo.meta('reader-layout-version:$hash');
  if (version == '$currentBookLayout') return;
  final key = 'reader:$hash', saved = await library.value('reader:$hash');
  final notes = (await library.entries('reading-note:')).entries
      .where((e) => e.value['hash'] == hash)
      .toList();
  final coverage = await library.value('reading-coverage:$hash');
  final bookmarkPrefix = 'reader-bookmark:$hash:';
  final bookmarks = (await library.entries(bookmarkPrefix)).entries.toList();
  final hasData =
      saved.isNotEmpty ||
      notes.isNotEmpty ||
      coverage.isNotEmpty ||
      bookmarks.isNotEmpty;
  // Missing version predates the per-device migration marker.
  final from =
      int.tryParse(version ?? '') ?? (saved['layoutVersion'] == 2 ? 2 : 1);
  ReaderAnchorMap? mapping;
  ReaderAnchorMap? split;
  if (hasData) {
    final layout2 = from >= 3
        ? (sourceLayout != null
              ? await sourceLayout(from)
              : prior == null
              ? next
              : await prior())
        : (previous == null ? next : await previous());
    if (!identical(layout2, next)) {
      try {
        split = layout2.texts.join() == next.texts.join()
            ? ReaderLinearRebase(layout2, next)
            : ReaderParagraphRebase(layout2, next);
      } on StateError {
        // Unexpected text difference: keep anchors as they are rather than
        // blocking the book. Notes verify their quote before jumping.
      }
    }
    final restored =
        from == 1 &&
            (saved.isNotEmpty || notes.isNotEmpty || coverage.isNotEmpty)
        ? ReaderRebase(await legacy(), split?.before ?? next)
        : null;
    mapping = restored == null
        ? split
        : split == null
        ? restored
        : _ChainedRebase(restored, split);
  }
  final map = mapping;
  await repo.db.transaction(() async {
    if (map != null) {
      await repo.setMeta(
        from == 1
            ? 'reader-layout-backup:$hash'
            : 'reader-layout-backup-$currentBookLayout:$hash',
        jsonEncode({
          'reader': saved,
          'coverage': coverage,
          'notes': {for (final n in notes) n.key: n.value},
          'bookmarks': {for (final b in bookmarks) b.key: b.value},
        }),
      );
      ({int chapter, int offset})? place(Object? raw) {
        if (raw is! Map || raw['chapter'] is! num || raw['offset'] is! num) {
          return null;
        }
        return map.at(
          (raw['chapter'] as num).toInt(),
          (raw['offset'] as num).toInt(),
        );
      }

      if (saved.isNotEmpty) {
        final oldChapter = ((saved['chapter'] as num?)?.toInt() ?? 0).clamp(
          0,
          map.before.texts.length - 1,
        );
        final oldOffset =
            (saved['textOffset'] as num?)?.toInt() ??
            map.before.offset(
              oldChapter,
              (saved['paragraph'] as num?)?.toInt() ?? 0,
              (saved['offset'] as num?)?.toInt() ?? 0,
            );
        final mapped = map.at(oldChapter, oldOffset);
        final history = [
          for (final raw in saved['returnTo'] as List? ?? []) ?place(raw),
        ];
        final pinned = place(saved['pinnedChapter']);
        final paragraph = next.paragraphAt(mapped.chapter, mapped.offset);
        await library.update(key, {
          'chapter': mapped.chapter,
          'textOffset': mapped.offset,
          'paragraph': paragraph.paragraph,
          'offset': paragraph.within,
          'layoutVersion': 2,
          'returnTo': [
            for (final h in history) {'chapter': h.chapter, 'offset': h.offset},
          ],
          if (pinned != null)
            'pinnedChapter': {
              'chapter': pinned.chapter,
              'offset': pinned.offset,
            },
        });
      }
      for (final note in notes) {
        final chapter = (note.value['chapter'] as num?)?.toInt();
        final start = (note.value['start'] as num?)?.toInt();
        final end = (note.value['end'] as num?)?.toInt();
        if (chapter == null || start == null || end == null) continue;
        final a = map.at(chapter, start);
        var b = map.at(chapter, end);
        if (b.chapter != a.chapter) {
          final pieces = [
            for (var c = a.chapter; c <= b.chapter; c++)
              (
                chapter: c,
                start: c == a.chapter ? a.offset : 0,
                end: c == b.chapter ? b.offset : next.texts[c].length,
              ),
          ].where((piece) => piece.end > piece.start).toList();
          final text = pieces
              .map(
                (piece) =>
                    next.texts[piece.chapter].substring(piece.start, piece.end),
              )
              .join();
          // TXT boundaries preserve the exact source. A pre-existing quote
          // spanning a newly recognized heading must retain all of its text.
          if (pieces.isNotEmpty && text == note.value['quote']) {
            for (var i = 0; i < pieces.length; i++) {
              final piece = pieces[i];
              final id = i == 0 ? note.key : uuid.v4();
              await repo.setMeta(
                'reading-note:$id',
                jsonEncode({
                  ...note.value,
                  'id': id,
                  'chapter': piece.chapter,
                  'chapterTitle': next.book.chapters[piece.chapter].title,
                  'start': piece.start,
                  'end': piece.end,
                  'quote': next.texts[piece.chapter].substring(
                    piece.start,
                    piece.end,
                  ),
                }),
              );
            }
            continue;
          }
          // A quote that now crosses a chapter boundary keeps its first part.
          b = (chapter: a.chapter, offset: map.after.texts[a.chapter].length);
        }
        await repo.setMeta(
          'reading-note:${note.key}',
          jsonEncode({
            ...note.value,
            'chapter': a.chapter,
            if (split != null)
              'chapterTitle': next.book.chapters[a.chapter].title,
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
                _absolute(map, (raw[0] as num).toInt()),
                _absolute(map, (raw[1] as num).toInt()),
              ],
          ],
        });
      }
      for (final bookmark in bookmarks) {
        final mapped = place({
          'chapter': bookmark.value['chapter'],
          'offset': bookmark.value['offset'],
        });
        if (mapped == null) continue;
        await repo.setMeta(
          '$bookmarkPrefix${bookmark.key}',
          jsonEncode({
            ...bookmark.value,
            'chapter': mapped.chapter,
            'offset': mapped.offset,
          }),
        );
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
    await repo.setMeta('reader-layout-version:$hash', '$currentBookLayout');
  });
}
