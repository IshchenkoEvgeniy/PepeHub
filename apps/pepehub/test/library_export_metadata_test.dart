import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/audio/audio_library_repository.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/library_mapper.dart';
import 'package:pepehub/library/metadata_values.dart';
import 'package:pepehub/library/models.dart';

void main() {
  const collection = {
    'id': 'book',
    'mediaType': 'book',
    'statuses': {
      'planned': 'В планах',
      'active': 'Чтение',
      'paused': 'На паузе',
      'finished': 'Прочитано',
    },
    'progressUnits': ['pages', 'minutes', 'percent'],
  };
  const fields = [
    LibraryField('Status', 'status', 'text'),
    LibraryField('Total', 'total', 'number'),
    LibraryField('Progress', 'progress', 'number'),
    LibraryField('Unit', 'unit', 'text'),
  ];
  test(
    'export uses configured statuses and percentage without synthetic pages',
    () {
      final item = LibraryMapper.fromBook(
        LibraryRecord('book', 'book', 1, false, {
          'title': 'Book',
          'format': 'epub',
        }),
        {
          'fields': fields.map((f) => f.toJson()).toList(),
          'collections': [collection],
        },
        {
          'status': 'finished',
          'unit': 'characters',
          'total': 2000,
          'progress': 2000,
        },
        'id',
      );
      expect(item.value('status'), 'Прочитано');
      expect(item.value('unit'), 'percent');
      expect(item.value('total'), 100);
      expect(item.value('progress'), 100);
      expect(item.values['pepehub_text_length'], 2000);
    },
  );
  test('an existing edition page count scales source text progress', () {
    final target = ObsidianLibraryItem(
      id: 'id',
      path: 'book.md',
      collectionId: 'book',
      mediaType: 'book',
      fields: fields,
      values: {'Total': 300, 'Unit': 'pages'},
    );
    final details = matchLibraryProgress({
      'unit': 'characters',
      'total': 2000,
      'progress': 500,
    }, target);
    expect(details, {'unit': 'pages', 'total': 300, 'progress': 75});
  });
  test('filename parsing remains a proposal and preserves author and narrator roles', () {
    expect(
      suggestAudioTitle('Кирилл Клеванский - Матабар II [Сергей Уделов]'),
      {
        'title': 'Матабар',
        'author': ['Кирилл Клеванский'],
        'seriesIndex': 2,
        'narrator': 'Сергей Уделов',
      },
    );
    expect(suggestAudioTitle('Unstructured title'), isNull);
  });
  test(
    'suggestions preserve commas inside list values and remove case duplicates',
    () {
      expect(metadataStrings(['Doe, John', ' doe, john ', 'Другой автор']), [
        'Doe, John',
        'Другой автор',
      ]);
      expect(exportLibraryStatus('reading', collection), 'Чтение');
      expect(exportLibraryStatus('custom status', collection), 'custom status');
    },
  );
  test('alternative audio editions are not added together', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    for (final (edition, duration, played) in [
      ('old', 60000, '2026-10-01'),
      ('new', 120000, '2026-10-28'),
    ]) {
      await db.customStatement('INSERT INTO audio_editions VALUES(?,?,1)', [
        edition,
        'book',
      ]);
      await db.customStatement('INSERT INTO audio_resources VALUES(?,?,1)', [
        edition,
        'track.mp3',
      ]);
      await db.customStatement('INSERT INTO audio_tracks VALUES(?,?,?,?,?,?)', [
        edition,
        edition,
        edition,
        0,
        edition,
        duration,
      ]);
      await db.customStatement(
        'INSERT INTO audio_progress VALUES(?,?,1000,1,1,?)',
        [edition, edition, played],
      );
    }
    final summary = (await AudioLibraryRepository(db)
        .bookSummaries(bookId: 'book'))['book']!;
    expect(summary.total, 120000);
    expect(summary.position, 1000);
  });
  test('audio exports retain an existing hours unit', () {
    final target = ObsidianLibraryItem(
      id: 'id',
      path: 'book.md',
      collectionId: 'book',
      mediaType: 'audiobook',
      fields: fields,
      values: {'Unit': 'hours'},
    );
    final details = matchLibraryProgress({
      'unit': 'minutes',
      'durationMinutes': 120,
      'listenedMinutes': 60,
    }, target);
    expect(details['unit'], 'hours');
    expect(details['durationMinutes'], 2);
    expect(details['listenedMinutes'], 1);
  });
}
