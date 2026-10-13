// Opt-in documentation renderer. Uses real product widgets, a memory database,
// synthetic books and a fixed player state. Never opens a user's library.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pepehub/audio/audio_journal.dart';
import 'package:pepehub/audio/m4b_chapters.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/library_service.dart';
import 'package:pepehub/library/models.dart';
import 'package:pepehub/library/obsidian_sync_service.dart';
import 'package:pepehub/main.dart';
import 'package:pepehub/media/asset_store.dart';
import 'package:pepehub/media/audio_controller.dart';
import 'package:pepehub/reader/epub.dart';
import 'package:pepehub/reader/reader_layout.dart';
import 'package:pepehub/reader/reader_page.dart';
import 'package:pepehub/reader/reading_library.dart';
import 'package:pepehub/reader/reading_notes_page.dart';
import 'package:pepehub/recommendations/book_catalog.dart';
import 'package:pepehub/recommendations/recommendation_store.dart';
import 'package:pepehub/ui/app_theme.dart';
import 'package:pepehub/ui/audio_page.dart';
import 'package:pepehub/ui/obsidian_library_dashboard.dart';
import 'package:pepehub/ui/recommendations_page.dart';
import 'package:pepehub/ui/settings_page.dart';
import 'package:pepehub/ui/shelf_components.dart';
import 'package:pepehub/ui/statistics_hub_page.dart';

class DocumentationPlayer extends ChangeNotifier implements AudioController {
  @override
  final AssetStore assets;
  @override
  final List<LocalAsset> tracks;
  DocumentationPlayer(this.assets, this.tracks, this.artwork);
  @override
  Uri? artwork;
  @override
  String title = 'Северный ветер',
      error = '',
      sidecarError = '',
      chapterError = '',
      durationError = '',
      sleepMode = 'time';
  @override
  bool loading = false,
      scanningDurations = false,
      sleepFade = true,
      sleepRewind = true;
  @override
  List<BookChapter> chapters = [];
  @override
  DateTime? sleepUntil = DateTime(2026, 10, 13, 23);
  @override
  LocalAsset get current => tracks[1];
  @override
  int get trackIndex => 1;
  @override
  int get knownDurations => tracks.length;
  @override
  bool get canPlay => true;
  @override
  bool get playing => true;
  @override
  double get speed => 1.25;
  @override
  Duration get position => const Duration(minutes: 18, seconds: 24);
  @override
  Duration get duration => const Duration(minutes: 45);
  @override
  Duration get bookPosition =>
      const Duration(hours: 1, minutes: 3, seconds: 24);
  @override
  Duration get bookDuration => const Duration(hours: 6);
  @override
  double get bookFraction => bookPosition.inSeconds / bookDuration.inSeconds;
  @override
  Duration get remainingAtSpeed => Duration(
    seconds: ((bookDuration - bookPosition).inSeconds / speed).round(),
  );
  @override
  Duration trackDuration(String id) => const Duration(minutes: 45);
  @override
  AudioJournal get journal => AudioJournal(assets.repository);
  @override
  Future<void> flushJournal() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const demoTitles = [
  'Северный ветер',
  'Атлас тишины',
  'Архитектура привычек',
  'Город у моря',
  'Завтра начинается сегодня',
  'Дорога к маяку',
];
const demoAuthors = [
  'Анна Волкова',
  'Михаил Лесной',
  'Елена Соколова',
  'Илья Северин',
  'Мария Орлова',
  'Алексей Мирный',
];
const demoParagraphs = [
  'В тот вечер северный ветер принёс в город запах моря. Анна остановилась на пустой набережной и впервые за долгое время никуда не спешила.',
  'Она достала из кармана маленький блокнот. На первой странице было всего три слова: «Замечать. Запоминать. Возвращаться». За этими словами начиналась история, которую она собиралась написать.',
  'За рекой зажглись окна старой библиотеки. Между полками там всегда находилось место для неожиданной встречи — с человеком, с мыслью, с книгой, которую раньше не замечаешь.',
  'Чтение не требовало от неё закончить всё сегодня. Достаточно было одной главы, одной отмеченной строки, одного вопроса, который хотелось унести с собой.',
  'Город медленно стихал. Вдали прозвучал корабельный гудок, и Анна улыбнулась: иногда путь начинается с разрешения остановиться.',
];

Future<File> demoCover(Directory directory, int index) async {
  const colors = [
    Color(0xff315263),
    Color(0xff6d463f),
    Color(0xff38594e),
    Color(0xff5b486d),
    Color(0xff78603b),
    Color(0xff374574),
  ];
  final recorder = ui.PictureRecorder();
  final painter = Canvas(recorder);
  painter.drawRect(
    const Rect.fromLTWH(0, 0, 360, 520),
    Paint()..color = colors[index],
  );
  painter.drawCircle(
    const Offset(290, 90),
    150,
    Paint()..color = const Color(0xffefe4cb).withValues(alpha: .1),
  );
  painter.drawCircle(
    const Offset(45, 500),
    220,
    Paint()..color = const Color(0xff0d1a25).withValues(alpha: .23),
  );
  painter.drawLine(
    const Offset(30, 155),
    const Offset(330, 155),
    Paint()
      ..color = const Color(0xffefdab1)
      ..strokeWidth = 1,
  );
  void text(String value, double y, double size, String family, Color color) {
    final paragraph = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(
          fontFamily: family,
          fontSize: size,
          color: color,
          height: 1.12,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 295);
    paragraph.paint(painter, Offset(32, y));
  }

  text(
    demoAuthors[index].toUpperCase(),
    56,
    16,
    'Onest',
    const Color(0xffefe4cb),
  );
  text(
    demoTitles[index],
    187,
    47,
    'CormorantGaramond',
    const Color(0xfffbefda),
  );
  text('ДЕМОНСТРАЦИОННАЯ КНИГА', 465, 11, 'Onest', const Color(0xffefe4cb));
  final picture = recorder.endRecording(),
      image = await picture.toImage(360, 520);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  final file = await File('${directory.path}/cover-$index.png')
      .writeAsBytes(bytes!.buffer.asUint8List());
  image.dispose();
  picture.dispose();
  return file;
}

void main() {
  testWidgets(
    'render README gallery from actual 0.19.0 widgets',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      debugPrintSynchronously('Loading fonts');
      await tester.runAsync(() async {
        for (final family in {
          'Roboto': 'Onest.ttf',
          'Onest': 'Onest.ttf',
          'Oswald': 'Oswald.ttf',
          'CormorantGaramond': 'CormorantGaramond.ttf',
          'ReaderLora': 'Lora.ttf',
          'Manrope': 'Manrope.ttf',
        }.entries) {
          await (FontLoader(family.key)..addFont(
                File('assets/fonts/${family.value}')
                    .readAsBytes()
                    .then(ByteData.sublistView),
              ))
              .load();
          debugPrintSynchronously('Loaded ${family.key}');
        }
        await (FontLoader('MaterialIcons')..addFont(
              File(
                    'build/unit_test_assets/fonts/MaterialIcons-Regular.otf',
              ).readAsBytes().then(ByteData.sublistView),
            ))
            .load();
      });
      debugPrintSynchronously('Fonts ready');
      final temporary = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('pepehub-readme-'),
      ))!;
      final db = AppDatabase(NativeDatabase.memory()), repo = Repository(db);
      debugPrintSynchronously('Temporary ready');
      final assets = AssetStore(repo, Directory('${temporary.path}/assets'));
      final library = ReadingLibrary(repo),
          books = <LocalAsset>[],
          covers = <File>[];
      final appearance = AppTheme(repo);
      final client = MockClient(
        (_) => throw StateError(
          'Documentation must not contact external services',
        ),
      );
      final service = LibraryService(repo, client, assets: assets);
      final key = GlobalKey();
      final output = Directory('../../docs/screenshots');
      await tester.runAsync(() => output.create(recursive: true));
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      try {
        debugPrintSynchronously('Seeding');
        await tester.runAsync(() async {
          for (var i = 0; i < demoTitles.length; i++) {
            covers.add(await demoCover(temporary, i));
            final source = await File('${temporary.path}/${demoTitles[i]}.txt')
                .writeAsString(
                  List.generate(
                    5 + i,
                    (_) => demoParagraphs.join('\n\n'),
                  ).join('\n\n'),
                );
            final asset = await assets.importBook(XFile(source.path));
            books.add(asset);
            await repo.put('book', asset.bookId, {
              'title': demoTitles[i],
              'authors': [demoAuthors[i]],
              'format': 'txt',
              'status': i == 2
                  ? 'finished'
                  : i < 2
                  ? 'active'
                  : 'planned',
            });
            await library.index(assets, asset);
            await library.update('reading-index:${asset.hash}', {
              'title': demoTitles[i],
              'authors': [demoAuthors[i]],
              'cover': covers[i].path,
              'series': i < 2 ? 'Морские истории' : null,
              'metadataVersion': 2,
            });
            await library.update('reader:${asset.hash}', {
              'chapter': 0,
              'paragraph': i == 2
                  ? 999
                  : i < 2
                  ? 6 + i * 3
                  : 0,
            });
            await library.update('reading-book:${asset.bookId}', {
              'favorite': i == 0,
            });
          }
          for (var i = 0; i < 3; i++) {
            await library.saveNote(
              ReadingNote(
                id: uuid.v4(),
                bookId: books[0].bookId,
                hash: books[0].hash,
                bookTitle: demoTitles[0],
                chapterTitle: 'Глава 1. Набережная',
                quote: demoParagraphs[i + 1],
                comment: [
                  'Хочу возвращаться к этой мысли, когда день становится слишком шумным.',
                  'Библиотека как место встречи, а не просто хранения книг.',
                  'Одна глава в день — хороший ритм.',
                ][i],
                color: ['yellow', 'blue', 'green'][i],
                updated: '2026-10-13T12:00:00.000Z',
                chapter: 0,
                start: demoParagraphs
                    .take(i + 1)
                    .fold<int>(0, (total, text) => total + text.length + 2),
                end:
                    demoParagraphs
                        .take(i + 1)
                        .fold<int>(
                          0,
                          (total, text) => total + text.length + 2,
                        ) +
                    demoParagraphs[i + 1].length,
                tags: [
                  ['Идеи', 'Тишина', 'Привычки'][i],
                ],
                characters: ['Анна'],
              ),
            );
          }
          final now = DateTime.now();
          for (var day = 0; day < 28; day++) {
            if (day % 6 == 0) continue;
            final start = DateTime(now.year, now.month, now.day - day, 19, 10),
                minutes = 20 + (day % 5) * 8;
            await repo.put('session', uuid.v4(), {
              'bookId': books[day % books.length].bookId,
              'kind': 'reading',
              'startedAt': start.toUtc().toIso8601String(),
              'endedAt': start
                  .add(Duration(minutes: minutes))
                  .toUtc()
                  .toIso8601String(),
              'activeSeconds': minutes * 60,
              'timezone': 'UTC',
              'offsetMinutes': start.timeZoneOffset.inMinutes,
              'source': 'manual',
            });
            await AudioJournal(repo).put(
              'audio_event',
              uuid.v4(),
              ListeningSegment(
                books[0].bookId,
                'demo-track',
                0,
                minutes * 75000,
                minutes * 60000,
                1.25,
                start,
              ).data,
            );
          }
          final store = RecommendationStore(repo),
              category = await store.saveCategory('Следующие книги'),
              top = await store.saveCategory('Любимые истории');
          for (var i = 0; i < 4; i++) {
            await store.saveBook(
              RecommendedBook(
                id: uuid.v4(),
                catalog: CatalogBook(
                  source: 'manual',
                  sourceId: 'demo-$i',
                  sourceUrl: '',
                  data: {
                    'title': demoTitles[i],
                    'authors': [demoAuthors[i]],
                    'description': demoParagraphs[i],
                    'subjects': ['Современная проза', 'Путешествия'],
                  },
                ),
                notes: [
                  'Для тихого вечера',
                  'Продолжение морских историй',
                  'Обсудить в книжном клубе',
                  'Совет друга',
                ][i],
                categories: {category: i + 1, if (i < 2) top: i + 1},
                createdAt: '2026-10-13T12:00:00.000Z',
              ),
            );
          }
        });
        debugPrintSynchronously('Seed ready');
        ShelfNavigation nav(PepeSection section) => ShelfNavigation(
          current: section,
          onSelect: (_) {},
          onSettings: () {},
        );
        Future<void> capture(
          String name,
          Widget page, {
          Size size = const Size(1440, 1000),
          bool app = false,
        }) async {
          debugPrintSynchronously('Rendering $name');
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          await tester.pumpWidget(
            RepaintBoundary(
              key: key,
              child: app
                  ? page
                  : ThemeScope(
                      controller: appearance,
                      child: MaterialApp(
                        debugShowCheckedModeBanner: false,
                        theme: AppTheme.data(Brightness.dark),
                        home: page,
                      ),
                    ),
            ),
          );
          // Data loads schedule image decodes on later frames. Let real I/O
          // and isolates complete between frames before capturing the widget.
          for (var frame = 0; frame < 5; frame++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 350)),
            );
            await tester.pump(const Duration(milliseconds: 100));
          }
          await tester.pumpAndSettle();
          debugPrintSynchronously('Settled $name');
          expect(tester.takeException(), isNull, reason: name);
          // Predecode local fixture covers in the real async zone. Native file
          // image decoding otherwise remains pending in the fake test clock.
          await tester.runAsync(() async {
            for (final widget in tester.widgetList<Image>(find.byType(Image))) {
              final provider = widget.image;
              final source = provider is ResizeImage
                  ? provider.imageProvider
                  : provider;
              if (source is! FileImage) continue;
              final codec = await ui.instantiateImageCodec(
                await source.file.readAsBytes(),
              );
              final frame = await codec.getNextFrame();
              codec.dispose();
              final cacheKey = await provider.obtainKey(
                createLocalImageConfiguration(key.currentContext!),
              );
              PaintingBinding.instance.imageCache.evict(cacheKey);
              PaintingBinding.instance.imageCache.putIfAbsent(
                cacheKey,
                () => OneFrameImageStreamCompleter(
                  Future.value(ImageInfo(image: frame.image)),
                ),
              );
            }
          });
          await tester.pumpWidget(const SizedBox());
          await tester.pumpWidget(
            RepaintBoundary(
              key: key,
              child: app
                  ? page
                  : ThemeScope(
                      controller: appearance,
                      child: MaterialApp(
                        debugShowCheckedModeBanner: false,
                        theme: AppTheme.data(Brightness.dark),
                        home: page,
                      ),
                    ),
            ),
          );
          for (var frame = 0; frame < 5; frame++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 350)),
            );
            await tester.pump(const Duration(milliseconds: 100));
          }
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: name);
          if (name == 'notes' &&
              find.text(demoParagraphs[2]).evaluate().isNotEmpty) {
            await tester.tap(find.text(demoParagraphs[2]).first);
            await tester.pumpAndSettle();
          }
          await tester.runAsync(() async {
            debugPrintSynchronously('Capturing $name');
            final boundary =
                key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage(pixelRatio: 1.5),
                bytes = await image.toByteData(format: ui.ImageByteFormat.png);
            await File('${output.path}/$name.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }

        await repo.setMeta('library-section', 'reading');
        await capture(
          'books-desktop',
          PepeHubApp(repository: repo, assets: assets),
          app: true,
        );
        await capture(
          'books-mobile',
          PepeHubApp(repository: repo, assets: assets),
          app: true,
          size: const Size(430, 932),
        );
        final document = ReaderDocument(
          EpubBook(
            demoTitles[0],
            [demoAuthors[0]],
            [
              const EpubChapter(
                'chapter-1',
                'Глава 1. Набережная',
                demoParagraphs,
              ),
            ],
          ),
        );
        await library.update('reader:${books[0].hash}', {
          'chapter': 0,
          'paragraph': 0,
          'offset': 0,
        });
        await capture(
          'reader',
          ReaderPage(
            repository: repo,
            asset: books[0],
            suppliedDocument: document,
          ),
          size: const Size(1200, 900),
        );
        await capture(
          'notes',
          ReadingNotesPage(repository: repo),
          size: const Size(1200, 1000),
        );
        await capture(
          'statistics',
          StatisticsHubPage(
            repository: repo,
            navigation: nav(PepeSection.statistics),
          ),
        );
        await capture(
          'recommendations',
          RecommendationsPage(
            store: RecommendationStore(repo),
            catalog: BookCatalog(client, interval: Duration.zero),
            navigation: nav(PepeSection.recommendations),
          ),
        );
        final tracks = [
          for (var i = 0; i < 8; i++)
            LocalAsset(
              id: 'track-$i',
              bookId: books[0].bookId,
              filename:
                  'Глава ${i + 1}. ${['Набережная', 'Старый маяк', 'Письмо', 'Путь домой'][i % 4]}',
              path: 'demo-$i',
              hash: 'demo-$i',
              bytes: 0,
            ),
        ];
        final player = DocumentationPlayer(
          assets,
          tracks,
          Uri.file(covers[0].path),
        );
        await capture(
          'player',
          AudioPage(controller: player),
          size: const Size(1200, 1000),
        );
        player.dispose();
        service.config = ObsidianConfig(
          'https://example.test',
          'documentation',
        );
        service.entries = [
          for (var i = 0; i < 6; i++)
            LibraryEntry(
              ObsidianLibraryItem(
                id: uuid.v4(),
                path: 'Книги/${demoTitles[i]}.md',
                collectionId: 'book',
                mediaType: 'book',
                values: {
                  'Title': demoTitles[i],
                  'Author': demoAuthors[i],
                  'Status': i == 2
                      ? 'finished'
                      : i < 2
                      ? 'active'
                      : 'planned',
                  'Progress': i == 2
                      ? 320
                      : i < 2
                      ? 130
                      : 0,
                  'Total': 320,
                  'Series': i < 2 ? 'Морские истории' : '',
                },
                fields: const [
                  LibraryField('Title', 'title', 'text'),
                  LibraryField('Author', 'author', 'text'),
                  LibraryField('Status', 'status', 'text'),
                  LibraryField('Progress', 'progress', 'number'),
                  LibraryField('Total', 'total', 'number'),
                  LibraryField('Series', 'series', 'text'),
                ],
              ),
            ),
        ];
        await capture(
          'obsidian',
          ObsidianLibraryPage(
            service: service,
            navigation: nav(PepeSection.library),
            onSettings: () {},
          ),
        );
        await capture(
          'settings',
          SettingsPage(
            library: service,
            onConnection: () async {},
            onJournal: () {},
            onNotes: () {},
          ),
          size: const Size(1200, 1000),
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)),
        );
        await tester.runAsync(() async {
          service.dispose();
          client.close();
          appearance.dispose();
          await db.close();
          PaintingBinding.instance.imageCache.clear();
          PaintingBinding.instance.imageCache.clearLiveImages();
          try {
            await temporary.delete(recursive: true);
          } on FileSystemException {
            // Windows can retain a memory-mapped image until the test process
            // exits. Only synthetic fixtures remain in this system-temp folder.
            debugPrintSynchronously(
              'Synthetic image fixtures retained: ${temporary.path}',
            );
          }
        });
      }
    },
    skip: Platform.environment['PEPEHUB_README_SCREENSHOTS'] != '1',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
