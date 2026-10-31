import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/library_backup.dart';
import 'package:pepehub/library/library_features.dart';
import 'package:pepehub/library/library_service.dart';
import 'package:pepehub/library/models.dart';
import 'package:pepehub/library/personal_library.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/reader/reading_library.dart';
import 'package:pepehub/ui/library_groups_page.dart';
import 'package:pepehub/ui/library_work_page.dart';
import 'package:pepehub/ui/app_theme.dart';
import 'package:pepehub/ui/shelf_components.dart';
import 'package:pepehub/ui/obsidian_library_page.dart';

class _NoProbeLibrary extends LibraryService {
  _NoProbeLibrary(super.local, super.client);
  @override
  Future<ObsidianLibraryItem> prepareDraft(LibraryRecord book) =>
      throw StateError('Shelf files must not be scanned by the archive');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late Repository local;
  late LibraryService library;
  late Directory root;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    local = Repository(db);
    root = await Directory.systemTemp.createTemp('pepehub-catalog-features-');
    final client = MockClient(
      (_) => throw StateError('No connection should be used'),
    );
    library = LibraryService(local, client, assets: AssetStore(local, root));
    addTearDown(client.close);
  });
  tearDown(() async {
    library.dispose();
    await db.close();
    await root.delete(recursive: true);
  });
  Future<String> add(
    String title, {
    String type = 'book',
    Map<String, dynamic> values = const {},
  }) async {
    final id = uuid.v4();
    await library.add(
      personalLibraryItem(id, type, {
        'title': title,
        'author': ['Автор'],
        'status': 'finished',
        ...values,
      }),
      '',
    );
    return id;
  }

  test(
    'saved archive never scans or automatically adds connected files',
    () async {
      await add('Сохранённая книга');
      final archive = _NoProbeLibrary(local, library.client);
      addTearDown(archive.dispose);
      for (final format in ['epub', 'audio']) {
        await local.addBook('Новый файл', 'Автор', format);
      }
      await archive.reload();
      expect(archive.completed.single.item.title, 'Сохранённая книга');
      expect(archive.entries, hasLength(1));
      expect(archive.loading, isFalse);
    },
  );

  test('explicit addition updates a discovered card for both books and audio without duplication', () async {
    for (final format in ['epub', 'audio']) {
      await local.addBook('Источник $format', 'Автор', format);
      final source = (await local.records('book'))
          .firstWhere((e) => e.payload!['format'] == format);
      final obsolete = library.draft(source, source.payload!).withValues({
        ...library.draft(source, source.payload!).values,
        'pepehub_auto_discovered': true,
      });
      await library.repository.mutate((cards) async {
        cards[obsolete.id] = LibraryEntry(obsolete, sourceBookId: source.id);
      });
      await library.reload();
      expect(library.forBook(source.id), isNull);
      final old = library.sourceDraft(source.id)!;
      expect(old.item.values['pepehub_auto_discovered'], isTrue);
      final draft = old.item.withValues({
        ...old.item.values,
        'status': 'finished',
        'rating': 9,
      });
      await library.add(draft, source.id, original: old.item.values);
      final card = library.forBook(source.id)!;
      expect(card.item.id, old.item.id);
      expect(card.item.value('rating'), 9);
      expect(libraryStatus(card.item), 'finished');
      expect(card.item.values['pepehub_auto_discovered'], isFalse);
      expect(libraryCompletionDate(card.item), isNotNull);
      expect(
        library.entries.where((e) => e.sourceBookId == source.id),
        hasLength(1),
      );
      expect((await local.record(source.id))!.payload!['status'], 'finished');
    }
  });

  test('archive migration hides automatic drafts and queues while preserving every saved record', () async {
    final wanted = <String>[];
    for (final status in ['finished', 'paused', 'abandoned']) {
      wanted.add(
        await add('Моя $status', values: {'status': status, 'rating': 9}),
      );
    }
    await library.repository.mutate((cards) async {
      for (final status in ['planned', 'active', 'finished']) {
        final id = uuid.v4();
        cards[id] = LibraryEntry(
          personalLibraryItem(id, 'book', {
            'title': 'Автоматическая $status',
            'status': status,
            'pepehub_auto_discovered': true,
            'notes': 'Сохранённое впечатление',
          }),
          sourceBookId: 'old-$status',
        );
      }
      for (final status in ['planned', 'active']) {
        final id = uuid.v4();
        cards[id] = LibraryEntry(
          personalLibraryItem(id, 'book', {
            'title': 'Старая очередь $status',
            'status': status,
          }),
        );
      }
    });
    await local.setMeta('library-manual-archive-v1', '0');
    await library.reload();
    expect(library.entries, hasLength(8));
    expect(
      library.visibleEntries.map((e) => e.item.id).toSet(),
      wanted.toSet(),
    );
    expect(library.forBook('old-finished'), isNull);
    expect(
      library.sourceDraft('old-finished')!.item.values['notes'],
      'Сохранённое впечатление',
    );
    expect(
      library.sourceDraft('old-finished')!.item.values['pepehub_source_only'],
      isTrue,
    );
    expect(libraryStatusesLocal.keys.toSet(), {
      'finished',
      'paused',
      'abandoned',
    });
    await expectLater(
      add('Нельзя', values: {'status': 'planned'}),
      throwsArgumentError,
    );
    await expectLater(
      library.editCards([wanted.first], {'status': 'active'}),
      throwsArgumentError,
    );
    await library.reload();
    expect(library.visibleEntries, hasLength(3));
  });

  test(
    'catalog cache respects transaction rollback and external replacement',
    () async {
      final id = await add('Исходное');
      final stored = await local.meta(personalLibraryKey);
      await expectLater(
        local.db.transaction(() async {
          await library.repository.mutate((cards) async {
            cards[id] = LibraryEntry(
              cards[id]!.item.withValues({
                ...cards[id]!.item.values,
                'title': 'Отменено',
              }),
            );
          });
          throw StateError('Rollback');
        }),
        throwsStateError,
      );
      expect((await library.repository.entries())[id]!.item.title, 'Исходное');
      final changed = jsonDecode(stored!) as Map<String, dynamic>;
      ((changed[id] as Map)['item'] as Map)['values']['title'] =
          'Восстановлено';
      await local.setMeta(personalLibraryKey, jsonEncode(changed));
      expect(
        (await library.repository.entries())[id]!.item.title,
        'Восстановлено',
      );
    },
  );

  test('unchanged sources reuse metadata, source changes invalidate it and manual authors stay intact', () async {
    await local.addBook('Источник', 'Автор', 'epub');
    final book = (await local.records('book')).single;
    final draft = await library.prepareDraft(book);
    await library.add(
      draft.withValues({...draft.values, 'status': 'finished'}),
      book.id,
    );
    await library.reload();
    final id = library.forBook(book.id)!.item.id;
    final first = library
        .forBook(book.id)!
        .item
        .values['pepehub_source_revision_v1'];
    final key = 'obsidian-source-meta:$personalLibraryNamespace:${book.id}';
    final cached = await local.meta(key);
    await library.reload();
    expect(await local.meta(key), cached);
    await local.put('book', book.id, {
      ...book.payload!,
      'authors': ['Изменённый автор'],
    });
    await library.reload();
    expect(library.forBook(book.id)!.item.authors, 'Изменённый автор');
    expect(
      library.forBook(book.id)!.item.values['pepehub_source_revision_v1'],
      isNot(first),
    );
    await library.editCards(
      [id],
      {
        'author': ['Мой автор'],
      },
    );
    await local.put('book', book.id, {
      ...book.payload!,
      'authors': ['Другие теги'],
    });
    await library.reload();
    expect(library.forBook(book.id)!.item.authors, 'Мой автор');
  });

  testWidgets(
    'phone library shows its first book without scrolling and keeps advanced controls folded',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() => add('Книга на первом экране'));
      await tester.runAsync(() async {
        for (final family in ['Onest', 'Oswald', 'CormorantGaramond']) {
          await (FontLoader(family)..addFont(
                File('assets/fonts/$family.ttf')
                    .readAsBytes()
                    .then(ByteData.sublistView),
              ))
              .load();
        }
        await (FontLoader('MaterialIcons')..addFont(
              File(
                '../../.tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
              ).readAsBytes().then(ByteData.sublistView),
            ))
            .load();
      });
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.data(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.3)),
            child: child!,
          ),
          home: RepaintBoundary(
            key: boundary,
            child: ObsidianLibraryPage(
              service: library,
              navigation: ShelfNavigation(
                current: PepeSection.library,
                onSelect: (_) {},
                onSettings: () {},
              ),
              onSettings: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        await File('build/library-compact-phone.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
      });
      expect(find.byKey(const ValueKey('library-status:all')), findsNothing);
      expect(find.text('Книга на первом экране').hitTestable(), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Книга на первом экране')).dy,
        lessThan(650),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  test('addition date is immutable through edits and sorting has both directions with unknown dates last', () async {
    final first = await add(
      'Б',
      values: {'pepehub_added_at': '2026-01-01T00:00:00Z'},
    );
    final second = await add(
      'А',
      values: {'pepehub_added_at': '2026-02-01T00:00:00Z'},
    );
    final original = library.entries.firstWhere((e) => e.item.id == first).item;
    await library.save(first, {
      ...original.values,
      'title': 'Новое название',
    }, original: original.values);
    expect(
      libraryAddedAt(
        library.entries.firstWhere((e) => e.item.id == first).item,
      ),
      DateTime.utc(2026, 1, 1),
    );
    final list = [...library.entries]
      ..sort((a, b) => compareLibraryEntries(a, b, 'added', descending: true));
    expect(list.map((e) => e.item.id), [second, first]);
    list.sort((a, b) => compareLibraryEntries(a, b, 'added'));
    expect(list.map((e) => e.item.id), [first, second]);
    final unknown = LibraryEntry(
      personalLibraryItem(uuid.v4(), 'book', {'title': 'Без даты'}),
    );
    expect(
      compareLibraryEntries(unknown, list.first, 'added', descending: true),
      greaterThan(0),
    );
  });

  test('batch metadata, collections and paused/dropped states preserve other values and real source status', () async {
    await local.addBook('Источник', 'Автор', 'epub');
    final source = (await local.records('book')).single;
    final draft = await library.prepareDraft(source);
    await library.add(
      draft.withValues({...draft.values, 'status': 'finished'}),
      source.id,
    );
    await library.reload();
    final id = library.forBook(source.id)!.item.id;
    final second = await add('Вторая', values: {'rating': 8});
    await library.editCards(
      [id, second],
      {
        'author': ['Новый автор'],
        'series': 'Серия',
        'status': 'paused',
      },
      addCollection: 'Любимые',
    );
    expect(
      library.visibleEntries.where((e) => libraryStatus(e.item) == 'active'),
      isEmpty,
    );
    expect(
      library.visibleEntries.every((e) => libraryStatus(e.item) == 'paused'),
      isTrue,
    );
    expect((await local.record(source.id))!.payload!['status'], 'paused');
    expect(
      library.visibleEntries.every(
        (e) => libraryCollections(e.item).contains('Любимые'),
      ),
      isTrue,
    );
    await library.editCards([second], {'status': 'abandoned'});
    expect(
      library.entries
          .firstWhere((e) => e.item.id == second)
          .item
          .value('rating'),
      8,
    );
    await library.reload();
    expect(libraryStatus(library.forBook(source.id)!.item), 'paused');
    await library.editCards([id], {'status': 'finished'});
    expect(libraryCompletionDate(library.forBook(source.id)!.item), isNotNull);
  });

  test('rereading increments explicitly and preserves the previous completion date', () async {
    final id = await add(
      'Книга',
      values: {'endDate': '2025-01-03', 'rating': 9},
    );
    await library.editCards([id], {}, reread: true);
    final card = library.entries.single.item;
    expect(libraryRereads(card), 1);
    expect(
      (card.values['pepehub_completions'] as List).first['date'],
      '2025-01-03',
    );
    await library.editCards([id], {'series': 'Исправление'});
    expect(libraryRereads(library.entries.single.item), 1);
  });

  test('ZIP roundtrip preserves offline covers, trash and series settings, and keeps a recovery copy', () async {
    final image = await File(
      'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png',
    ).readAsBytes();
    final hash = sha256.convert(image).toString();
    final cover = File(library.covers!.path(hash));
    await cover.parent.create(recursive: true);
    await cover.writeAsBytes(image);
    final id = await add(
      'Сохранить',
      values: {
        'cover': 'pepehub-cover:$hash',
        'notes': 'Впечатление',
        'rereadCount': 2,
      },
    );
    await library.deleteCards([id]);
    await local.setMeta('library-series-length:серия', '4');
    final backup = LibraryBackup(library),
        bytes = await LibraryBackup(library).create();
    final preview = backup.inspect(bytes);
    expect(preview.cards[id]!.item.values['notes'], 'Впечатление');
    expect(preview.covers[hash], image);
    await library.restoreCard(id);
    await backup.restore(preview, replace: true);
    expect(library.trash.single.item.id, id);
    expect(library.coverPath(library.trash.single.item), cover.path);
    expect(await local.meta('library-series-length:серия'), '4');
    expect(
      await (await backup.directory())
          .list()
          .where((e) => e.path.endsWith('.zip'))
          .length,
      1,
    );
    final second = await backup.create();
    expect(backup.inspect(second).cards.keys, contains(id));
  });

  test('invalid ZIP paths and altered cover content are rejected before changing the catalog', () async {
    final id = await add('Исходная');
    final backup = LibraryBackup(library);
    final archive = Archive()..addFile(ArchiveFile('../outside.txt', 1, [1]));
    expect(
      () => backup.inspect(Uint8List.fromList(ZipEncoder().encode(archive))),
      throwsFormatException,
    );
    expect(library.entries.single.item.id, id);
    final good = ZipDecoder().decodeBytes(await backup.create());
    final bad = Archive();
    for (final file in good.files) {
      bad.addFile(ArchiveFile(file.name, file.size, file.content));
    }
    bad.addFile(ArchiveFile('covers/${'a' * 64}.png', 3, [1, 2, 3]));
    expect(
      () => backup.inspect(Uint8List.fromList(ZipEncoder().encode(bad))),
      throwsFormatException,
    );
  });

  test('restoring native quotes on the same device never creates duplicate reader notes', () async {
    await local.addBook('С цитатой', 'Автор', 'epub');
    final source = (await local.records('book')).single;
    final draft = await library.prepareDraft(source);
    await library.add(
      draft.withValues({...draft.values, 'status': 'finished'}),
      source.id,
    );
    await library.reload();
    final reading = ReadingLibrary(local);
    await reading.saveNote(
      ReadingNote(
        id: uuid.v4(),
        bookId: source.id,
        hash: 'a' * 64,
        bookTitle: 'С цитатой',
        chapterTitle: 'Глава',
        quote: 'Цитата',
        comment: 'Комментарий',
        color: 'yellow',
        updated: '2026-10-29T10:00:00.000Z',
        chapter: 0,
        start: 1,
        end: 7,
        tags: const [],
        characters: const [],
      ),
    );
    final backup = LibraryBackup(library);
    final preview = backup.inspect(await backup.create());
    expect((preview.notes['slots'] as Map), hasLength(1));
    await backup.restore(preview);
    await library.notes!.capture();
    expect(await reading.notes(), hasLength(1));
    expect(await library.notes!.entries(), hasLength(1));
    await backup.restore(backup.inspect(await backup.create()));
    expect(await reading.notes(), hasLength(1));
  });

  test('exports quote CSV values, neutralize formulas and preserve Markdown punctuation', () async {
    await add('=HYPERLINK("test")', values: {'notes': '[текст] *важно*'});
    final backup = LibraryBackup(library);
    expect(backup.exportText('csv'), contains('"\'=HYPERLINK(""test"")"'));
    expect(backup.exportText('md'), contains(r'\[текст\] \*важно\*'));
    expect(jsonDecode(backup.exportText('json'))['books'], hasLength(1));
  });

  testWidgets(
    'work page displays impressions first and opens the editor as a separate action',
    (tester) async {
      final id = await tester.runAsync(
        () => add(
          'Произведение',
          values: {'notes': 'Мои впечатления', 'rating': 9},
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryWorkPage(library: library, itemId: id!),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LibraryMetadataEditor), findsNothing);
      expect(find.text('Карточка произведения'), findsOneWidget);
      expect(find.text('Произведение'), findsOneWidget);
      await tester.tap(find.byTooltip('Редактировать'));
      await tester.pumpAndSettle();
      expect(find.byType(LibraryMetadataEditor), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'series shows known gaps and author page includes both books and audiobooks',
    (tester) async {
      await tester.runAsync(() async {
        await add('Первый', values: {'series': 'Цикл', 'seriesIndex': 1});
        await add(
          'Третий',
          type: 'audiobook',
          values: {'series': 'Цикл', 'seriesIndex': 3, 'status': 'paused'},
        );
        await local.setMeta('library-series-length:цикл', '4');
      });
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryGroupsPage(
            library: library,
            kind: 'series',
            name: 'Цикл',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Том 2 — нет в библиотеке'), findsOneWidget);
      expect(find.text('Том 4 — нет в библиотеке'), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          home: LibraryGroupsPage(
            key: UniqueKey(),
            library: library,
            kind: 'author',
            name: 'Автор',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Первый'), findsOneWidget);
      expect(find.text('Третий'), findsOneWidget);
      expect(
        find.text('Завершено 1 из 2 · книги и аудиокниги'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
