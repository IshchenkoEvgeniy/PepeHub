import 'audio_mini_player.dart';
import 'app_theme.dart';
import '../audio/audio_roots.dart';
import 'book_folder_dialog.dart';
import '../audio/audio_library_repository.dart';
import '../audio/audio_library_sort.dart';
import 'audio_statistics_page.dart';
import 'audio_cover.dart';

import 'dart:async';
import 'dart:convert';

import '../media/android_book_files.dart';

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../data/repository.dart';
import '../audio/audio_folder.dart';
import '../export/markdown.dart';
import '../media/asset_store.dart';
import '../media/audio_controller.dart';
import '../sync/sync_client.dart';
import 'dialogs.dart';
import 'audio_page.dart';
import 'audio_import_dialog.dart';
import 'audio_catalog_dialog.dart';
import 'audio_roots_page.dart';
import '../reader/reader_page.dart';
import '../reader/book_formats.dart';
import '../reader/pdf_reader_page.dart';
import '../reader/reading_roots.dart';
import 'reading_roots_page.dart';
import 'reading_statistics_page.dart';
import 'reading_book_page.dart';
import 'reading_plan_page.dart';
import '../reader/reading_library.dart';
import '../reader/reading_notes_page.dart';
import '../reader/reading_collections.dart';

class LibraryPage extends StatefulWidget {
  final Repository repository;
  final AssetStore? assets;
  final AudioController? audio;
  final String? audioError;
  const LibraryPage({
    super.key,
    required this.repository,
    this.assets,
    this.audio,
    this.audioError,
  });
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final storage = const FlutterSecureStorage(), httpClient = http.Client();
  List<LibraryRecord> books = [], sessions = [];
  List<LocalAsset> localAssets = [];
  Map<String, ({int? total, int? position, double speed})> audioSummaries = {};
  List<Map<String, dynamic>> conflicts = [];
  List<AudioRoot> roots = [];
  Map<String, String> statusOverrides = {};
  String? selectedRoot;
  bool showSearch = false;
  bool reading = false;
  String statusFilter = 'all';
  String query = '',
      filter = 'all',
      message = 'Изменения сохраняются на этом устройстве';
  int pending = 0;
  bool busy = false, loading = true;
  bool indexing = false, favoritesOnly = false;
  String readingSort = 'title';
  String audioSort = 'title';
  Map<String, DateTime> audioRecent = {};
  Map<String, Map<String, dynamic>> audioPrefs = {}, audioCollections = {};
  Map<String, Map<String, dynamic>> get bookPrefs =>
      reading ? readingPrefs : audioPrefs;
  Map<String, Map<String, dynamic>> get collections =>
      reading ? readingCollections : audioCollections;
  String? collectionFilter;
  Map<String, Map<String, dynamic>> readingIndex = {},
      readingPositions = {},
      readingPrefs = {},
      readingCollections = {};
  late final readingLibrary = ReadingLibrary(widget.repository);
  bool get showSync => false; // Final project stage; local features come first.
  late final syncClient = SyncClient(widget.repository, httpClient);
  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    final section = await widget.repository.meta('library-section');
    if (!mounted) return;
    reading = section == 'reading';
    await _reload();
    if (mounted && Platform.isAndroid && widget.assets != null) {
      incomingBooks = AndroidBookFiles(
        onFile: _receiveBook,
        onError: (error) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Не удалось открыть полученную книгу: $error'),
              ),
            );
          }
        },
      )..start();
    }
  }

  Future<void> _switchSection(bool next) async {
    Navigator.pop(context);
    if (busy || loading || reading == next) return;
    setState(() {
      reading = next;
      books = [];
      roots = [];
      selectedRoot = null;
      query = '';
      showSearch = false;
      filter = statusFilter = 'all';
      favoritesOnly = false;
      collectionFilter = null;
      loading = true;
    });
    await widget.repository.setMeta(
      'library-section',
      next ? 'reading' : 'audio',
    );
    await _reload();
  }

  @override
  void dispose() {
    incomingBooks?.dispose();
    httpClient.close();
    super.dispose();
  }

  AndroidBookFiles? incomingBooks;
  final openReaderHashes = <String>{};

  Future<void> _receiveBook(String path) async {
    if (!mounted || widget.assets == null) return;
    setState(() => message = 'Открытие полученной книги…');
    final asset = await widget.assets!.importBook(XFile(path));
    if (!mounted) return;
    if (openReaderHashes.contains(asset.hash)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Эта книга уже открыта. К предыдущему экрану можно вернуться кнопкой «Назад».',
          ),
        ),
      );
      return;
    }
    setState(() {
      reading = true;
      selectedRoot = collectionFilter = null;
      favoritesOnly = false;
      query = '';
      filter = statusFilter = 'all';
    });
    await widget.repository.setMeta('library-section', 'reading');
    // Do not hold the native intent queue or staging file until the reader closes.
    unawaited(_openReader(asset));
    await _reload();
  }

  int coverRevision = 0;
  Future<void> _reload() async {
    final readingSection = reading;
    coverRevision++;
    try {
      final allBooks = await widget.repository.records('book'),
          s = await widget.repository.records('session');
      final b = <LibraryRecord>[];
      final overrides = <String, String>{};
      for (final book in allBooks) {
        if ((book.payload!['format'] != 'audio') != readingSection) continue;
        if (readingSection) {
          if (await widget.repository.meta(
                'reading-library-hidden:${book.id}',
              ) !=
              '1') {
            b.add(book);
          }
          continue;
        }
        final override = await widget.repository.meta(
          'audio-status-override:${book.id}',
        );
        if (override != null) overrides[book.id] = override;
        if (await widget.repository.meta(
                  'audio-library-superseded:${book.id}',
                ) !=
                '1' &&
            await widget.repository.meta('audio-library-hidden:${book.id}') !=
                '1') {
          b.add(book);
        }
      }
      final p = await widget.repository.pendingCount(),
          c = await widget.repository.conflicts();
      final files = await widget.assets?.list() ?? <LocalAsset>[];
      final rootList = widget.assets == null
          ? <AudioRoot>[]
          : readingSection
          ? (await ReadingRoots(widget.assets!).list())
                .map(
                  (r) => AudioRoot(r.key, {
                    'root': r.path,
                    'title': r.title,
                    'bookIds': r.bookIds,
                  }),
                )
                .toList()
          : await AudioRoots(widget.assets!).list();
      final summary = readingSection
          ? <String, ({int? total, int? position, double speed})>{}
          : await AudioLibraryRepository(widget.repository.db).bookSummaries();
      if (readingSection) {
        final index = await readingLibrary.entries('reading-index:');
        final positions = await readingLibrary.entries('reader:');
        final prefs = await readingLibrary.entries('reading-book:');
        final groups = await readingLibrary.entries('reading-collection:');
        final order = await widget.repository.meta('reading-sort') ?? 'title';
        if (mounted && reading == readingSection) {
          readingIndex = index;
          readingPositions = positions;
          readingPrefs = prefs;
          readingCollections = groups;
          readingSort = order;
          if (!groups.containsKey(collectionFilter)) collectionFilter = null;
        }
      } else {
        final prefs = await readingLibrary.entries('audio-book:');
        final groups = await readingLibrary.entries('audio-collection:');
        final order = await widget.repository.meta('audio-sort') ?? 'title';
        final recent = await AudioLibraryRepository(widget.repository.db)
            .lastPlayed();
        if (mounted && reading == readingSection) {
          audioPrefs = prefs;
          audioCollections = groups;
          audioSort = order;
          audioRecent = recent;
          if (!groups.containsKey(collectionFilter)) collectionFilter = null;
        }
      }
      if (mounted && reading == readingSection) {
        setState(() {
          books = b;
          statusOverrides = overrides;
          roots = rootList;
          if (!roots.any((r) => r.key == selectedRoot)) selectedRoot = null;
          localAssets = files;
          audioSummaries = summary;
          sessions = s
              .where(
                (record) =>
                    record.payload?['kind'] ==
                    (readingSection ? 'reading' : 'listening'),
              )
              .toList();
          pending = p;
          conflicts = c.map((r) => r.data).toList();
          loading = false;
        });
      }
      if (readingSection &&
          mounted &&
          reading &&
          !indexing &&
          widget.assets != null) {
        final ids = b.map((b) => b.id).toSet();
        final missing = files
            .where(
              (a) =>
                  ids.contains(a.bookId) &&
                  (!readingIndex.containsKey(a.hash) ||
                      bookFormat(a.filename) == 'pdf' &&
                          readingIndex[a.hash]?['pdfCoverVersion'] == null &&
                          readingIndex[a.hash]?['error'] == null),
            )
            .toList();
        if (missing.isNotEmpty) _indexBooks(missing);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          message = 'Ошибка чтения: $e';
          loading = false;
        });
      }
    }
  }

  Future<void> _indexBooks(List<LocalAsset> files) async {
    setState(() => indexing = true);
    try {
      for (final file in files) {
        if (!mounted) break;
        await readingLibrary.index(widget.assets!, file);
      }
      if (mounted) await _reload();
    } catch (e) {
      if (mounted) setState(() => message = 'Ошибка индексирования: $e');
    } finally {
      if (mounted) setState(() => indexing = false);
    }
  }

  Map<String, dynamic> _textInfo(LibraryRecord b) {
    final asset = localAssets.where((a) => a.bookId == b.id).firstOrNull;
    return ReadingLibrary.effective(
      readingIndex[asset?.hash] ?? {},
      readingPrefs[b.id] ?? {},
    );
  }

  Map<String, dynamic> _textPosition(LibraryRecord b) {
    final asset = localAssets.where((a) => a.bookId == b.id).firstOrNull;
    return readingPositions[asset?.hash] ?? {};
  }

  String _title(LibraryRecord b) =>
      reading ? (_textInfo(b)['title'] as String? ?? b.title) : b.title;
  String _authors(LibraryRecord b) =>
      ((reading ? _textInfo(b)['authors'] : null) as List? ??
              b.payload!['authors'] as List)
          .join(', ');
  double _fraction(LibraryRecord b) =>
      readingFraction(_textInfo(b), _textPosition(b));

  Future<void> _allNotes() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ReadingNotesPage(
          repository: widget.repository,
          bookIds: books.map((b) => b.id).toSet(),
          onOpen: (note) async {
            final asset = localAssets
                .where((a) => a.bookId == note.bookId && a.hash == note.hash)
                .firstOrNull;
            if (asset == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Подключите файл этой книги.')),
              );
              return;
            }
            await _openReader(asset, note: note);
          },
        ),
      ),
    );
  }

  Future<void> _action(Future<void> Function() work) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await work();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      await _reload();
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _addBook() async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => AddBookDialog(audioOnly: !reading),
    );
    if (result != null) {
      await _action(
        () => widget.repository.addBook(
          result['title']!,
          result['author']!,
          result['format']!,
        ),
      );
    }
  }

  Future<void> _manageRoots() => _action(() async {
    if (!reading) await widget.audio?.stop();
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => reading
            ? ReadingRootsPage(assets: widget.assets!)
            : AudioRootsPage(assets: widget.assets!),
      ),
    );
  });

  Future<void> _importBook() => _action(() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Книги: EPUB, FB2, TXT, Markdown, HTML, DOCX, RTF, PDF',
          extensions: bookExtensions,
          mimeTypes: [
            'application/epub+zip',
            'application/pdf',
            'application/rtf',
            'text/rtf',
            'text/plain',
            'text/markdown',
            'text/html',
            'application/xml',
            'text/xml',
            'application/x-fictionbook+xml',
            'application/zip',
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
          ],
        ),
      ],
    );
    if (file == null) return;
    final asset = await widget.assets!.importBook(file);
    if (mounted) await _openReader(asset);
  });

  Future<void> _openReader(LocalAsset asset, {ReadingNote? note}) async {
    if (!openReaderHashes.add(asset.hash)) return;
    try {
      await _showReader(asset, note: note);
    } finally {
      openReaderHashes.remove(asset.hash);
    }
  }

  Future<void> _showReader(LocalAsset asset, {ReadingNote? note}) async {
    try {
      asset = await ReadingRoots(widget.assets!).forReading(asset);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось открыть книгу: $error')),
        );
      }
      return;
    }
    await widget.audio?.pause();
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => bookFormat(asset.filename) == 'pdf'
            ? PdfReaderPage(
                repository: widget.repository,
                asset: asset,
                initialNote: note,
              )
            : ReaderPage(
                repository: widget.repository,
                asset: asset,
                initialNote: note,
              ),
      ),
    );
    await _reload();
  }

  Future<void> _importAudio({bool folder = false}) async {
    LocalAsset? imported;
    await _action(() async {
      final selectedFolder = folder ? await pickAudioFolder() : null;
      if (folder && selectedFolder == null) return;
      if (selectedFolder != null) {
        if (!mounted) return;
        await widget.audio?.stop();
        if (!mounted) return;
        final count = await showDialog<int>(
          context: context,
          barrierDismissible: false,
          builder: (_) => AudioCatalogDialog(
            folder: selectedFolder,
            assets: widget.assets!,
          ),
        );
        if (count != null && mounted) {
          setState(
            () => message =
                'Подключено книг: $count. Аудиофайлы остаются в исходных папках.',
          );
        }
        return;
      }
      final files =
          selectedFolder?.files ??
          await openFiles(
            acceptedTypeGroups: [
              const XTypeGroup(
                label: 'Аудиокниги',
                extensions: audioExtensions,
                mimeTypes: ['audio/*', 'application/ogg'],
              ),
            ],
          );
      if (!mounted) return;
      if (files.isEmpty) {
        if (folder) throw StateError('В папке нет поддерживаемых аудиофайлов');
        return;
      }
      imported = await showDialog<LocalAsset>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AudioImportDialog(
          files: files,
          assets: widget.assets!,
          initialTitle: selectedFolder?.title,
          sourceRoot: selectedFolder?.root,
        ),
      );
      if (imported == null) return;
      if (mounted) {
        setState(
          () => message = folder
              ? 'Папка подключена. Файлы воспроизводятся без копирования.'
              : 'Аудиокнига скопирована в локальную библиотеку',
        );
      }
    });
    if (imported != null && mounted && widget.audio != null) {
      await _openAudio(imported!);
    }
  }

  Future<void> _openAudio(LocalAsset asset) async {
    final book = await widget.repository.record(asset.bookId);
    if (book == null || !mounted || widget.audio == null) return;
    await _action(() => widget.audio!.open(asset, book.title));
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => AudioPage(controller: widget.audio!)),
    );
    await _reload();
  }

  Future<void> _reconnectAudio(LibraryRecord book) => _action(() async {
    final folder = await pickAudioFolder();
    if (folder == null) return;
    await widget.audio?.stop();
    await widget.assets!.connectAudioFolder(
      folder.files,
      root: folder.root!,
      title: book.title,
      replaceBookId: book.id,
    );
    if (mounted) {
      setState(
        () => message = 'Папка подключена заново. Порядок и позиция сохранены.',
      );
    }
  });

  Future<void> _addSession(LibraryRecord book) async {
    final minutes = await showDialog<int>(
      context: context,
      builder: (_) => const SessionDialog(),
    );
    if (minutes != null) {
      await _action(() => widget.repository.addSession(book, minutes));
    }
  }

  Future<void> _settings() async {
    await _action(() async {
      final raw = await storage.read(key: 'sync_config');
      final config = raw == null
          ? null
          : SyncConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      if (!mounted) return;
      final result = await showDialog<SyncConfig>(
        context: context,
        builder: (_) => SyncDialog(initial: config),
      );
      if (result != null) {
        await storage.write(
          key: 'sync_config',
          value: jsonEncode(result.toJson()),
        );
        if (mounted) setState(() => message = 'Настройки сохранены');
      }
    });
  }

  Future<void> _sync() => _action(() async {
    final raw = await storage.read(key: 'sync_config');
    if (raw == null) {
      throw StateError('Сначала откройте настройки синхронизации');
    }
    await syncClient.run(
      SyncConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>),
    );
    if (mounted) {
      setState(
        () => message = 'Обмен завершён · ${TimeOfDay.now().format(context)}',
      );
    }
  });
  Future<void> _export() => _action(() async {
    final text = exportMarkdown(books, sessions);
    if (Platform.isAndroid) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Markdown для Obsidian'),
          content: SizedBox(
            width: 600,
            height: 400,
            child: SingleChildScrollView(child: SelectableText(text)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Закрыть'),
            ),
          ],
        ),
      );
      return;
    }
    final location = await getSaveLocation(
      suggestedName: 'PepeHub Library.md',
      acceptedTypeGroups: [
        const XTypeGroup(label: 'Markdown', extensions: ['md']),
      ],
    );
    if (location != null) {
      await XFile.fromData(
        utf8.encode(text),
        mimeType: 'text/markdown',
      ).saveTo(location.path);
      if (mounted) setState(() => message = 'Markdown экспортирован');
    }
  });
  Future<void> _resolve(Map<String, dynamic> conflict) async {
    final operation =
        jsonDecode(conflict['operation'] as String) as Map<String, dynamic>;
    final receipt =
        jsonDecode(conflict['receipt'] as String) as Map<String, dynamic>;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Конфликт изменений'),
        content: SizedBox(
          width: 550,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Локальная версия сохранена. Перед заменой при необходимости экспортируйте библиотеку. Принятие серверной версии отменит ожидающие локальные правки этой записи.',
                ),
                const SizedBox(height: 16),
                const Text('Локальная правка'),
                SelectableText(
                  const JsonEncoder.withIndent('  ')
                      .convert(operation['payload']),
                ),
                const SizedBox(height: 16),
                const Text('Серверная версия на момент конфликта'),
                SelectableText(
                  const JsonEncoder.withIndent('  ')
                      .convert(receipt['current']),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Оставить пока'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Принять серверную'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      await _action(
        () => widget.repository.useServerVersion(
          conflict['operation_id'] as String,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = books
        .where(
          (b) =>
              (selectedRoot == null ||
                  roots
                      .firstWhere((r) => r.key == selectedRoot)
                      .bookIds
                      .contains(b.id)) &&
              (statusFilter == 'all' || _status(b) == statusFilter) &&
              (filter == 'all' ||
                  (filter == 'books'
                      ? b.payload!['format'] != 'audio'
                      : b.payload!['format'] == filter)) &&
              (!favoritesOnly || bookPrefs[b.id]?['favorite'] == true) &&
              (collectionFilter == null ||
                  (bookPrefs[b.id]?['collections'] as List? ?? []).contains(
                    collectionFilter,
                  )) &&
              ('${_title(b)} ${_authors(b)} ${reading ? _textInfo(b)['series'] ?? '' : ''}'
                  .toLowerCase()
                  .contains(query.toLowerCase())),
        )
        .toList();
    if (reading) {
      visible.sort((a, b) {
        final result = switch (readingSort) {
          'author' => _authors(
            a,
          ).toLowerCase().compareTo(_authors(b).toLowerCase()),
          'series' => '${_textInfo(a)['series'] ?? ''}'.compareTo(
            '${_textInfo(b)['series'] ?? ''}',
          ),
          'progress' => _fraction(b).compareTo(_fraction(a)),
          'recent' => '${_textPosition(b)['updatedAt'] ?? ''}'.compareTo(
            '${_textPosition(a)['updatedAt'] ?? ''}',
          ),
          _ => _title(a).toLowerCase().compareTo(_title(b).toLowerCase()),
        };
        if (result == 0 && readingSort == 'series') {
          final number =
              (double.tryParse('${_textInfo(a)['seriesNumber']}') ?? 0)
                  .compareTo(
                    double.tryParse('${_textInfo(b)['seriesNumber']}') ?? 0,
                  );
          if (number != 0) return number;
        }
        return result != 0
            ? result
            : _title(a).toLowerCase().compareTo(_title(b).toLowerCase());
      });
    }
    if (!reading) {
      visible.sort(
        (a, b) => compareAudioBooks(
          a,
          b,
          order: audioSort,
          summaries: audioSummaries,
          recent: audioRecent,
        ),
      );
    }
    return Scaffold(
      drawer: Drawer(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'PepeHub',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                ),
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.headphones),
                title: const Text('Аудиокниги'),
                selected: !reading,
                enabled: !busy && !loading,
                onTap: () => _switchSection(false),
              ),
              ListTile(
                leading: const Icon(Icons.auto_stories_outlined),
                title: const Text('Книги'),
                selected: reading,
                enabled: !busy && !loading,
                onTap: () => _switchSection(true),
              ),
              const Spacer(),
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Своя библиотека, папки и статистика в каждом разделе.',
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: reading
          ? null
          : AudioMiniPlayer(controller: widget.audio),
      appBar: AppBar(
        title: Text(
          reading ? 'Книги' : 'Аудиокниги',
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'Папки библиотеки',
            onPressed: busy || widget.assets == null ? null : _manageRoots,
            icon: const Icon(Icons.folder_open),
          ),
          IconButton(
            tooltip: reading ? 'Статистика чтения' : 'Статистика прослушивания',
            icon: const Icon(Icons.bar_chart),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => reading
                    ? ReadingStatisticsPage(repository: widget.repository)
                    : AudioStatisticsPage(
                        repository: widget.repository,
                        controller: widget.audio,
                      ),
              ),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: 'Добавить',
            icon: const Icon(Icons.add),
            onSelected: (value) {
              if (value == 'new') _addBook();
              if (value == 'folder') {
                if (reading) {
                  _manageRoots();
                } else {
                  _importAudio(folder: true);
                }
              }
              if (value == 'audio') _importAudio();
              if (value == 'book') _importBook();
              if (value == 'export') _export();
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'new', child: Text('Добавить книгу')),
              PopupMenuItem(
                value: 'folder',
                child: Text('Добавить папку библиотеки'),
              ),
              if (reading)
                const PopupMenuItem(value: 'book', child: Text('Импорт книги')),
              if (!reading)
                const PopupMenuItem(
                  value: 'audio',
                  child: Text('Копировать аудиофайлы'),
                ),
              PopupMenuItem(value: 'export', child: Text('Экспорт Markdown')),
            ],
          ),
          if (showSync)
            IconButton(
              tooltip: 'Настройки синхронизации',
              onPressed: busy ? null : _settings,
              icon: const Icon(Icons.settings_outlined),
            ),
          const SizedBox(width: 12),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1200),
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: DropdownButton<String?>(
                                isExpanded: true,
                                value: selectedRoot,
                                items: [
                                  const DropdownMenuItem<String?>(
                                    value: null,
                                    child: Text('Вся библиотека'),
                                  ),
                                  for (final root in roots)
                                    DropdownMenuItem(
                                      value: root.key,
                                      child: Text(
                                        root.title,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                ],
                                onChanged: (v) =>
                                    setState(() => selectedRoot = v),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Поиск',
                              onPressed: () => setState(() {
                                showSearch = !showSearch;
                                if (!showSearch) query = '';
                              }),
                              icon: const Icon(Icons.search),
                            ),
                            if (reading)
                              PopupMenuButton<String>(
                                tooltip: 'Формат книг',
                                icon: const Icon(Icons.filter_list),
                                onSelected: (v) => setState(() => filter = v),
                                itemBuilder: (_) => [
                                  const PopupMenuItem(
                                    value: 'all',
                                    child: Text('Все форматы'),
                                  ),
                                  for (final entry in bookFormats.entries)
                                    PopupMenuItem(
                                      value: entry.key,
                                      child: Text(entry.value),
                                    ),
                                ],
                              ),
                            IconButton(
                              tooltip: 'Обновить список',
                              onPressed: busy ? null : _reload,
                              icon: const Icon(Icons.refresh),
                            ),
                            PopupMenuButton<ThemeMode>(
                              tooltip: 'Тема оформления',
                              icon: const Icon(Icons.brightness_6_outlined),
                              onSelected: (mode) =>
                                  ThemeScope.of(context)?.set(mode),
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: ThemeMode.system,
                                  child: Text('Как в системе'),
                                ),
                                PopupMenuItem(
                                  value: ThemeMode.light,
                                  child: Text('Светлая тема'),
                                ),
                                PopupMenuItem(
                                  value: ThemeMode.dark,
                                  child: Text('Тёмная тема'),
                                ),
                              ],
                            ),
                          ],
                        ),
                        if (books.isEmpty)
                          TextButton.icon(
                            onPressed: busy ? null : _addBook,
                            icon: const Icon(Icons.add),
                            label: const Text('Добавить книгу'),
                          ),
                        if (showSync) ...[
                          TextButton(
                            onPressed: _sync,
                            child: const Text('Синхронизировать'),
                          ),
                          for (final c in conflicts)
                            TextButton(
                              onPressed: () => _resolve(c),
                              child: const Text('Разобрать конфликт'),
                            ),
                        ],
                        if (message.startsWith('Ошибка')) Text(message),
                        const SizedBox(height: 8),
                        if (showSearch)
                          TextField(
                            onChanged: (v) => setState(() => query = v),
                            decoration: const InputDecoration(
                              hintText: 'Название или автор',
                              prefixIcon: Icon(Icons.search),
                              filled: true,
                            ),
                          ),
                        const SizedBox(height: 8),
                        ...[
                          if (reading && indexing)
                            const LinearProgressIndicator(),
                          Wrap(
                            spacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              FilterChip(
                                label: const Text('Избранное'),
                                avatar: const Icon(
                                  Icons.star_outline,
                                  size: 18,
                                ),
                                selected: favoritesOnly,
                                onSelected: (v) =>
                                    setState(() => favoritesOnly = v),
                              ),
                              PopupMenuButton<String>(
                                tooltip: reading
                                    ? 'Сортировка книг'
                                    : 'Сортировка аудиокниг',
                                icon: const Icon(Icons.sort),
                                onSelected: (v) async {
                                  final key = reading
                                      ? 'reading-sort'
                                      : 'audio-sort';
                                  await _action(
                                    () => widget.repository.setMeta(key, v),
                                  );
                                },
                                itemBuilder: (_) => [
                                  for (final e in {
                                    'title': 'По названию',
                                    'author': 'По автору',
                                    if (reading) 'series': 'По серии',
                                    'progress': 'По прогрессу',
                                    'recent': reading
                                        ? 'Недавно открытые'
                                        : 'Недавняя активность',
                                    if (!reading)
                                      'duration': 'Сначала короткие',
                                    if (!reading)
                                      'duration-desc': 'Сначала длинные',
                                  }.entries)
                                    CheckedPopupMenuItem(
                                      value: e.key,
                                      checked:
                                          (reading ? readingSort : audioSort) ==
                                          e.key,
                                      child: Text(e.value),
                                    ),
                                ],
                              ),
                              if (reading)
                                TextButton.icon(
                                  onPressed: _allNotes,
                                  icon: const Icon(Icons.edit_note),
                                  label: const Text('Заметки'),
                                ),
                              TextButton.icon(
                                onPressed: () async {
                                  await showLibraryCollections(
                                    context,
                                    widget.repository,
                                    audio: !reading,
                                  );
                                  await _reload();
                                },
                                icon: const Icon(
                                  Icons.collections_bookmark_outlined,
                                ),
                                label: const Text('Коллекции'),
                              ),
                              if (collections.isNotEmpty)
                                DropdownButton<String>(
                                  value: collectionFilter,
                                  hint: const Text('Все коллекции'),
                                  items: [
                                    const DropdownMenuItem(
                                      value: null,
                                      child: Text('Все коллекции'),
                                    ),
                                    for (final e in collections.entries)
                                      DropdownMenuItem(
                                        value: e.key,
                                        child: Text(e.value['name'] as String),
                                      ),
                                  ],
                                  onChanged: (v) =>
                                      setState(() => collectionFilter = v),
                                ),
                            ],
                          ),
                        ],
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (final entry in {
                                'all': 'Все',
                                'planned': 'Новые',
                                'active': 'Начатые',
                                'finished': 'Завершённые',
                              }.entries)
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: ChoiceChip(
                                    label: Text(entry.value),
                                    selected: statusFilter == entry.key,
                                    onSelected: (_) => setState(
                                      () => statusFilter = entry.key,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                    ),
                  ),
                ),
                if (loading)
                  const SliverToBoxAdapter(
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (visible.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(40),
                      child: Column(
                        children: [
                          const Icon(
                            Icons.bookmarks_outlined,
                            size: 52,
                            color: Color(0xff779083),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            books.isEmpty
                                ? 'Начните с первой книги'
                                : 'Ничего не найдено',
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (!reading && widget.audioError != null)
                            Text(
                              widget.audioError!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          const SizedBox(height: 8),
                          Text(
                            books.isEmpty
                                ? 'Подключите папку или добавьте книгу.'
                                : 'Попробуйте изменить поиск или фильтр.',
                          ),
                        ],
                      ),
                    ),
                  ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  sliver: SliverList.builder(
                    itemCount: visible.length,
                    itemBuilder: (_, i) => _bookCard(visible[i]),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 40)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _status(LibraryRecord book) {
    if (book.payload!['format'] != 'audio') {
      final manual =
          (readingPrefs[book.id]?['overrides'] as Map?)?['status'] as String?;
      if (manual != null) return manual;
    }
    if (statusOverrides.containsKey(book.id)) return statusOverrides[book.id]!;
    final status = book.payload!['status'] as String;
    if (status == 'finished') return status;
    if (book.payload!['format'] != 'audio') {
      final progress = _fraction(book);
      return progress >= 1
          ? 'finished'
          : progress > 0
          ? 'active'
          : status;
    }
    return (audioSummaries[book.id]?.position ?? 0) > 0 ? 'active' : status;
  }

  Future<void> _bookMenu(LibraryRecord book, String value) async {
    if (value == 'share') {
      await _action(() async {
        final files = book.payload!['format'] == 'audio'
            ? await widget.assets!.audioTracks(book.id)
            : localAssets.where((a) => a.bookId == book.id).toList();
        await shareBookFiles(files);
      });
      return;
    }
    if (value == 'reading-plan') {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) =>
              ReadingPlanPage(repository: widget.repository, bookId: book.id),
        ),
      );
      return;
    }
    if (value == 'details') {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => ReadingBookPage(
            repository: widget.repository,
            book: book,
            assets: widget.assets,
            asset: localAssets.where((a) => a.bookId == book.id).firstOrNull,
          ),
        ),
      );
      await _reload();
      return;
    }
    if (value == 'favorite') {
      final prefix = book.payload!['format'] == 'audio' ? 'audio' : 'reading';
      await _action(
        () => readingLibrary.update('$prefix-book:${book.id}', {
          'favorite': bookPrefs[book.id]?['favorite'] != true,
        }),
      );
      return;
    }
    if (value == 'collections') {
      await showLibraryCollections(
        context,
        widget.repository,
        bookId: book.id,
        audio: book.payload!['format'] == 'audio',
      );
      await _reload();
      return;
    }
    if (value == 'metadata') {
      final asset = localAssets.where((a) => a.bookId == book.id).firstOrNull;
      if (asset != null && widget.assets != null) {
        await _action(
          () => readingLibrary.index(widget.assets!, asset, retry: true),
        );
      }
      return;
    }
    if (value == 'session') {
      await _addSession(book);
      return;
    }
    if (value == 'reconnect') {
      await _reconnectAudio(book);
      return;
    }
    if (value == 'folder') {
      if (widget.assets == null) return;
      await _action(
        () => showBookFolderDialog(
          context,
          widget.assets!,
          widget.audio,
          book.id,
        ),
      );
      return;
    }
    await _action(() async {
      await widget.repository.db.transaction(() async {
        await widget.repository.put('book', book.id, {
          ...book.payload!,
          'status': value,
        });
        if (book.payload!['format'] == 'audio') {
          await widget.repository.setMeta(
            'audio-status-override:${book.id}',
            value,
          );
        } else {
          final prefs = await readingLibrary.value('reading-book:${book.id}');
          await readingLibrary.update('reading-book:${book.id}', {
            'overrides': {
              ...Map<String, dynamic>.from(prefs['overrides'] as Map? ?? {}),
              'status': value,
            },
          });
        }
      });
    });
  }

  Widget _bookCard(LibraryRecord book) {
    final audio = book.payload!['format'] == 'audio';
    final asset = localAssets.where((a) => a.bookId == book.id).firstOrNull;
    final summary = audioSummaries[book.id];
    final selected = widget.audio?.current?.bookId == book.id;
    final scheme = Theme.of(context).colorScheme;
    final status = _status(book);
    final fraction = !audio
        ? _fraction(book)
        : summary?.total == null || summary?.position == null
        ? null
        : (summary!.position! / summary.total!).clamp(0.0, 1.0);
    return Material(
      color: selected ? scheme.primaryContainer : Colors.transparent,
      child: InkWell(
        onTap: asset == null || busy
            ? null
            : () => audio ? _openAudio(asset) : _openReader(asset),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 4,
                height: 158,
                color: status == 'finished'
                    ? scheme.primary
                    : status == 'active'
                    ? const Color(0xffe3ac59)
                    : scheme.outlineVariant,
              ),
              const SizedBox(width: 5),
              Container(
                width: 108,
                height: 158,
                color: scheme.surfaceContainerHighest,
                child: audio && widget.assets != null
                    ? AudioCover(
                        key: ValueKey('${book.id}:$coverRevision'),
                        assets: widget.assets!,
                        bookId: book.id,
                      )
                    : !audio && _textInfo(book)['cover'] != null
                    ? Image.file(
                        File(_textInfo(book)['cover'] as String),
                        fit: BoxFit.cover,
                        cacheWidth: 240,
                        errorBuilder: (_, _, _) =>
                            const Icon(Icons.menu_book, size: 48),
                      )
                    : Icon(
                        audio ? Icons.headphones : Icons.menu_book,
                        size: 48,
                        color: scheme.primary,
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 158,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${bookPrefs[book.id]?['favorite'] == true ? '★ ' : ''}${_title(book)}',
                        maxLines: audio ? 4 : 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 18,
                          height: 1.2,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (_authors(book).isNotEmpty)
                        Text(
                          _authors(book),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      const Spacer(),
                      if (!audio && _textInfo(book)['series'] != null)
                        Text(
                          '${_textInfo(book)['series']} ${_textInfo(book)['seriesNumber'] ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: scheme.primary),
                        ),
                      if (!audio &&
                          (_textInfo(book)['chapters'] as List? ?? [])
                              .isNotEmpty)
                        Text(
                          '${(_textInfo(book)['chapters'] as List)[((_textPosition(book)['chapter'] as num?)?.toInt() ?? 0).clamp(0, (_textInfo(book)['chapters'] as List).length - 1)]}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              !audio && _textInfo(book)['length'] != null
                                  ? '${formatLabel(book.payload!['format'] as String)} · ${((fraction ?? 0) * 100).toStringAsFixed(1)}%'
                                  : summary?.total == null
                                  ? (audio
                                        ? 'Аудиокнига'
                                        : formatLabel(
                                            book.payload!['format'] as String,
                                          ))
                                  : '${audioTime(Duration(milliseconds: summary!.position ?? 0))} / ${audioTime(Duration(milliseconds: summary.total!))}  ${((fraction ?? 0) * 100).toStringAsFixed(0)}%',
                              style: TextStyle(
                                fontSize: 12,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          PopupMenuButton<String>(
                            tooltip: 'Действия с книгой',
                            onSelected: (v) => _bookMenu(book, v),
                            itemBuilder: (_) => [
                              if (Platform.isAndroid &&
                                  widget.assets != null &&
                                  asset != null)
                                const PopupMenuItem(
                                  value: 'share',
                                  child: Text('Поделиться файлом книги'),
                                ),
                              PopupMenuItem(
                                value: 'favorite',
                                child: Text(
                                  bookPrefs[book.id]?['favorite'] == true
                                      ? 'Убрать из избранного'
                                      : 'В избранное',
                                ),
                              ),
                              const PopupMenuItem(
                                value: 'collections',
                                child: Text('Коллекции книги'),
                              ),
                              if (!audio) ...[
                                const PopupMenuItem(
                                  value: 'details',
                                  child: Text('Карточка книги'),
                                ),
                                const PopupMenuItem(
                                  value: 'reading-plan',
                                  child: Text('План чтения'),
                                ),
                                const PopupMenuItem(
                                  value: 'metadata',
                                  child: Text('Обновить сведения из файла'),
                                ),
                              ],
                              const PopupMenuItem(
                                value: 'planned',
                                child: Text('Отметить новой'),
                              ),
                              const PopupMenuItem(
                                value: 'active',
                                child: Text('Отметить начатой'),
                              ),
                              const PopupMenuItem(
                                value: 'finished',
                                child: Text('Отметить завершённой'),
                              ),
                              const PopupMenuItem(
                                value: 'session',
                                child: Text('Записать сессию'),
                              ),
                              if (audio)
                                const PopupMenuItem(
                                  value: 'folder',
                                  child: Text(
                                    'Переименовать / переместить папку',
                                  ),
                                ),
                              if (audio)
                                const PopupMenuItem(
                                  value: 'reconnect',
                                  child: Text('Указать папку заново'),
                                ),
                            ],
                          ),
                        ],
                      ),
                      if (fraction != null)
                        LinearProgressIndicator(value: fraction, minHeight: 3),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
