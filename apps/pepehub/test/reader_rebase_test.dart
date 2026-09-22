import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/reader/epub.dart';
import 'package:pepehub/reader/reader_layout.dart';
import 'package:pepehub/reader/reader_rebase.dart';
import 'package:pepehub/reader/reading_library.dart';

import 'epub_test.dart' show fixture;

void main() {
  test(
    'legacy anchors and notes survive restored code whitespace exactly once',
    () async {
      final bytes = fixture(
        overrides: {
          'OPS/first.xhtml': '<html><body><h1>Title</h1><pre>line one\n  line two</pre><p>After code.</p></body></html>',
        },
      );
      final before = ReaderDocument(parseEpub(bytes, legacyProjection: true));
      final after = ReaderDocument(parseEpub(bytes));
      final start = before.texts.first.indexOf('line two');
      final expected = after.texts.first.indexOf('line two');
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = Repository(db);
      final library = ReadingLibrary(repo);
      await repo.setMeta(
        'reader:book',
        jsonEncode({'chapter': 0, 'textOffset': start}),
      );
      await repo.setMeta(
        'reading-note:note',
        jsonEncode({
          'hash': 'book',
          'chapter': 0,
          'start': start,
          'end': start + 8,
        }),
      );
      await migrateReaderLayout(library, 'book', after, () async => before);
      expect((await library.value('reader:book'))['textOffset'], expected);
      final note = await library.value('reading-note:note');
      expect(
        after.texts.first.substring(note['start'] as int, note['end'] as int),
        'line two',
      );
      expect(await repo.meta('reader-layout-backup:book'), isNotNull);
      await migrateReaderLayout(
        library,
        'book',
        after,
        () async => throw StateError('Already migrated'),
      );
      expect((await library.value('reader:book'))['textOffset'], expected);
    },
  );
}
