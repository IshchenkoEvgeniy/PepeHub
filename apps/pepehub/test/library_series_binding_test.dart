import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/library_features.dart';
import 'package:pepehub/library/library_service.dart';
import 'package:pepehub/library/models.dart';
import 'package:pepehub/library/personal_library.dart';
import 'package:pepehub/ui/obsidian_library_page.dart';

LibraryEntry member(
  String id, {
  String type = 'book',
  String? cycle = 'cycle',
  Map<String, dynamic> values = const {},
}) => LibraryEntry(
  personalLibraryItem(id, type, {
    'title': 'Книга $id',
    'series': 'Дисгардиум',
    'seriesIndex': 1,
    'status': 'finished',
    'author': ['Автор'],
    'genre': ['LitRPG'],
    'narrator': ['Чтец'],
    'language': 'Русский',
    'publisher': 'Издательство',
    'tags': ['Метка'],
    'pepehub_series_id': ?cycle,
    ...values,
  }),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late LibraryService library;
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    final client = MockClient((_) => throw StateError('No network'));
    library = LibraryService(Repository(db), client);
    addTearDown(() async {
      library.dispose();
      client.close();
      await db.close();
    });
  });

  test('name-only saved volumes rejoin their cycle without losing card or journals', () async {
    final entries = [
      member('first'),
      member(
        'orphan',
        type: 'audiobook',
        cycle: null,
        values: {
          'series': '  дисгардиум  ',
          'seriesIndex': 13.1,
          'cover': 'keep',
          'notes': 'Впечатления',
          'Custom': {'keep': true},
        },
      ),
    ];
    final orphan = entries.last;
    await library.repository.mutate(
      (cards) async =>
          cards.addEntries(entries.map((e) => MapEntry(e.item.id, e))),
    );
    await library.local.setMeta(
      'obsidian-notes:personal',
      '{"version":1,"cursor":0,"slots":{}}',
    );
    final journalBefore = await library.local.meta('obsidian-notes:personal');
    await library.loadCached();
    final groups = groupLibrarySeries(library.seriesEntries);
    expect(groups, hasLength(1));
    expect(groups.single.entries.map((e) => e.item.id), ['first', 'orphan']);
    final saved = (await library.repository.entries())['orphan']!;
    expect(saved.item.values, {
      ...orphan.item.values,
      'pepehub_series_id': 'cycle',
    });
    expect(saved.item.modifiedAt, orphan.item.modifiedAt);
    expect(await library.local.meta('obsidian-notes:personal'), journalBefore);
    expect(await library.local.records('book'), isEmpty);
  });

  test('single add accepts unread volumes, joins existing cycle and rejects standalone unread', () async {
    await library.repository.mutate(
      (cards) async => cards['first'] = member('first'),
    );
    for (final type in ['book', 'audiobook']) {
      await library.add(
        member(
          type,
          type: type,
          cycle: null,
          values: {'status': 'unread', 'seriesIndex': 13.1},
        ).item,
        '',
      );
    }
    expect(groupLibrarySeries(library.seriesEntries), hasLength(1));
    expect(library.unreadSeriesEntries, hasLength(2));
    await expectLater(
      library.add(
        member('standalone', values: {'status': 'unread', 'series': ''}).item,
        '',
      ),
      throwsArgumentError,
    );
  });

  test('ambiguous cycle names stay separate and explicit editor selection survives save', () async {
    await library.repository.mutate(
      (cards) async => cards.addAll({
        'one': member('one', cycle: 'one'),
        'two': member('two', cycle: 'two'),
        'orphan': member('orphan', cycle: null),
        'other': member('other', values: {'series': 'Другой цикл'}),
      }),
    );
    await library.loadCached();
    expect(
      (await library.repository.entries())['orphan']!
          .item
          .values['pepehub_series_id'],
      isNull,
    );
    final before = (await library.repository.entries())['other']!.item;
    await library.save(before.id, {
      ...before.values,
      'series': 'Дисгардиум',
      'pepehub_series_id': 'two',
    }, original: before.values);
    expect(
      (await library.repository.entries())['other']!
          .item
          .values['pepehub_series_id'],
      'two',
    );
  });

  test('common proposals ignore conflicting narrators and never include reading results', () {
    final group = groupLibrarySeries([
      member(
        'one',
        type: 'audiobook',
        values: {'rating': 10, 'progress': 100, 'notes': 'Не копировать'},
      ),
      member(
        'two',
        type: 'audiobook',
        values: {
          'narrator': ['Другой чтец'],
        },
      ),
    ]).single;
    final result = commonLibrarySeriesMetadata(
      group,
      library.emptyDraft(audio: true),
    );
    expect(result.keys.toSet(), {
      'author',
      'genre',
      'language',
      'publisher',
      'tags',
    });
  });

  for (final type in ['book', 'audiobook']) {
    testWidgets(
      'typing a cycle updates $type statuses and offers reviewed metadata',
      (tester) async {
        tester.view.physicalSize = Size(type == 'book' ? 1440 : 390, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final draft = library.emptyDraft(audio: type == 'audiobook');
        Map<String, dynamic>? saved;
        await tester.pumpWidget(
          MaterialApp(
            home: LibraryMetadataEditor(
              item: draft.withValues({
                ...draft.values,
                'title': 'Последняя битва. Том 1',
                'notes': 'Мои впечатления',
                'rating': 7,
                if (type == 'audiobook') 'author': ['Мой автор'],
              }),
              seriesEntries: [member('donor', type: 'audiobook')],
              onSave: (values) async => saved = values,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final series = find.byKey(const ValueKey('metadata:series'));
        await tester.ensureVisible(series);
        await tester.enterText(series, 'Дисгардиум');
        await tester.pumpAndSettle();
        // Dismiss the autocomplete overlay without selecting a different field.
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        final proposal = find.text('Взять данные из других книг цикла…');
        await tester.ensureVisible(proposal);
        await tester.tap(proposal);
        await tester.pumpAndSettle();
        expect(find.text('Автор'), findsOneWidget);
        if (type == 'audiobook') expect(find.text('Чтец'), findsOneWidget);
        await tester.tap(find.text('Заполнить выбранные поля'));
        await tester.pumpAndSettle();
        final status = find.byWidgetPredicate(
          (w) =>
              w is DropdownButtonFormField<String> &&
              w.decoration.labelText == 'Статус',
        );
        await tester.ensureVisible(status);
        await tester.tap(status);
        await tester.pumpAndSettle();
        expect(find.text('В планах'), findsNothing);
        expect(find.text('Чтение'), findsNothing);
        final unread = type == 'book' ? 'Не прочитана' : 'Не прослушана';
        await tester.tap(find.text(unread).last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Сохранить'));
        await tester.pumpAndSettle();
        expect(saved!['status'], 'unread');
        expect(saved!['pepehub_series_id'], 'cycle');
        expect(saved!['author'], [type == 'audiobook' ? 'Мой автор' : 'Автор']);
        expect(saved!['genre'], ['LitRPG']);
        expect(saved!['notes'], 'Мои впечатления');
        expect(saved!['rating'], 7);
        if (type == 'audiobook') expect(saved!['narrator'], ['Чтец']);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  test(
    '2000 mixed saved volumes reconnect by name without accessing source files',
    () async {
      await library.repository.mutate((cards) async {
        for (var i = 0; i < 2000; i++) {
          cards['$i'] = member(
            '$i',
            type: i.isEven ? 'book' : 'audiobook',
            cycle: i == 0 ? 'cycle' : null,
            values: {'seriesIndex': i + 1},
          );
        }
      });
      await library.loadCached();
      expect(
        groupLibrarySeries(library.seriesEntries).single.entries,
        hasLength(2000),
      );
      expect(await library.local.records('book'), isEmpty);
    },
  );
}
