import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/vocabulary/anki_export.dart';
import 'package:pepehub/vocabulary/vocabulary_repository.dart';

void main() {
  late AppDatabase db;
  late Repository repo;
  late VocabularyRepository vocabulary;
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = Repository(db);
    vocabulary = VocabularyRepository(repo);
  });
  tearDown(() => db.close());

  test('cards survive reopening, edits retain source, and no book sync operations are created', () async {
    const source = VocabularySource(
      kind: 'video',
      title: 'English',
      detail: 'Already',
      mediaId: 'lesson',
      mediaVersion: 'version1',
      positionMs: 65800,
      endMs: 70100,
    );
    final first = await vocabulary.save(
      front: 'He has already left.',
      back: 'Он уже ушёл.',
      kind: VocabularyKind.sentence,
      source: source,
      context: 'Present perfect',
      deck: 'English::Course',
      tags: ['grammar', 'past tense', 'grammar'],
    );
    final loaded = (await VocabularyRepository(repo).list()).single;
    expect(loaded.id, first.id);
    expect(loaded.tags, ['grammar', 'past_tense']);
    final changed = await vocabulary.save(
      existing: loaded,
      front: loaded.front,
      back: 'Он уже ушёл',
      source: const VocabularySource(
        kind: 'video',
        title: 'Wrong',
        positionMs: 0,
      ),
    );
    expect(changed.source!.toJson(), source.toJson());
    expect(changed.createdAt, first.createdAt);
    expect(changed.revision, first.revision + 1);
    await expectLater(
      vocabulary.save(existing: loaded, front: 'Stale', back: 'Old'),
      throwsStateError,
    );
    expect((await vocabulary.list()).single.back, 'Он уже ушёл');
    expect(await repo.pendingCount(), 0);
    await vocabulary.delete(changed);
    expect(await vocabulary.list(), isEmpty);
    await expectLater(
      vocabulary.save(existing: changed, front: 'Revive', back: 'No'),
      throwsStateError,
    );
  });

  test('Anki import is four quoted columns with escaped HTML, Unicode, source, tags and deck', () async {
    final card = await vocabulary.save(
      front: '# hello\t"world"\n<word> & 🌊',
      back: 'Ответ\r\n<script>alert("x")</script>',
      context: 'A\tB\nC',
      tags: ['English'],
      deck: 'English::A "quoted" deck',
      source: const VocabularySource(
        kind: 'audio',
        title: 'Book <one>',
        detail: 'Глава 2',
        positionMs: 3661000,
      ),
    );
    final text = ankiText([card]);
    expect(
      text,
      startsWith(
        '#separator:Tab\n#html:true\n#tags column:3\n#deck column:4\n',
      ),
    );
    final lines = const LineSplitter().convert(text);
    expect(lines, hasLength(6));
    final fields = lines.last.split('\t');
    expect(fields, hasLength(4));
    expect(
      fields.first,
      '"&#35; hello&#9;&quot;world&quot;<br>&lt;word&gt; &amp; 🌊"',
    );
    expect(
      fields[1],
      contains('&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;'),
    );
    expect(fields[1], contains('Book &lt;one&gt; · Глава 2 · 1:01:01'));
    expect(fields[1], contains('A&#9;B<br>C'));
    expect(fields[2], '"PepeHub PepeHub::word English"');
    expect(fields.last, '"English::A ""quoted"" deck"');
    expect(text, isNot(contains('<script>')));
    expect(ankiText([card]), text);
    expect((await vocabulary.list()).single.id, card.id);
  });

  test('incomplete or invalid cards do not create partial records', () async {
    await expectLater(
      vocabulary.save(front: 'hello', back: ' '),
      throwsArgumentError,
    );
    await expectLater(
      vocabulary.save(front: 'hello', back: 'привет', deck: 'bad\nheader'),
      throwsArgumentError,
    );
    await expectLater(
      vocabulary.save(front: 'x' * 5001, back: 'answer'),
      throwsArgumentError,
    );
    expect(await vocabulary.list(), isEmpty);
    expect(await repo.pendingCount(), 0);
  });
}
