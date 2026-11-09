import 'catalog_search.dart';
import 'audio_mini_player.dart';
import 'app_theme.dart';
import 'app_preferences.dart';
import 'book_action_menu.dart';
import 'settings_page.dart';
import 'activity_page.dart';
import 'library_link_review.dart';
import 'pepe_widgets.dart';
import 'shelf_components.dart';
import 'folder_scan_panel.dart';
import 'shelf_book_details.dart';
import 'recommendations_page.dart';
import 'statistics_hub_page.dart';
import '../video/video_library_page.dart';
import '../video/video_repository.dart';
import '../recommendations/recommendation_store.dart';
import '../recommendations/book_catalog.dart';
import '../audio/audio_roots.dart';
import 'book_folder_dialog.dart';
import '../audio/audio_library_repository.dart';
import '../audio/audio_library_sort.dart';
import 'audio_statistics_page.dart';
import 'audio_cover.dart';

import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;

import 'dart:convert';

import '../media/android_book_files.dart';

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../data/repository.dart';
import '../audio/audio_folder.dart';
import '../audio/audio_import.dart' show naturalAudioOrder;
import '../audio/audio_merge.dart';
import '../export/markdown.dart';
import '../media/asset_store.dart';
import '../media/audio_controller.dart';
import '../media/library_folder_preference.dart';
import '../sync/sync_client.dart';
import 'dialogs.dart';
import 'audio_page.dart';
import 'audio_import_dialog.dart';
import 'audio_catalog_dialog.dart';
import 'audio_roots_page.dart';
import '../reader/reader_page.dart';
import '../reader/book_formats.dart';
import '../reader/text_book.dart' show currentBookLayout;
import '../reader/pdf_reader_page.dart';
import '../reader/reading_roots.dart';
import '../reader/reading_shelf_sources.dart';

import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, LogicalKeyboardKey;

import '../reader/reading_book_actions.dart';
import '../audio/audio_book_actions.dart';
import '../reader/reading_book_visibility.dart';
import '../sync/peer/peer_service.dart';
import 'reading_roots_page.dart';
import 'hidden_deleted_page.dart';
import 'book_delete_dialog.dart';
import '../library/book_trash.dart';
import '../library/hidden_files.dart';
import 'reading_statistics_page.dart';
import 'reading_book_page.dart';
import 'reading_plan_page.dart';
import '../reader/reading_library.dart';
import '../reader/reading_notes_page.dart';
import '../reader/reading_collections.dart';
import '../library/library_service.dart';
import '../library/personal_library.dart';
import '../library/library_features.dart';
import 'library_data_page.dart';
import 'library_card_actions.dart';
import 'library_work_page.dart';
import 'obsidian_library_page.dart';
import '../diagnostics/user_message.dart';

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
  List<LibraryRecord> books = [];
  ReadingShelfSources shelfSources = ReadingShelfSources([]);
  Map<String, Map<String, dynamic>> effectiveReadingInfo = {};
  bool _remoteOnly(LibraryRecord book) =>
      reading && shelfSources.remoteOnly(book.id);
  List<LocalAsset> localAssets = [];
  Map<String, ({int? total, int? position, double speed})> audioSummaries = {};
  List<Map<String, dynamic>> conflicts = [];
  List<AudioRoot> roots = [];
  Map<String, String> statusOverrides = {};
  String? selectedRoot;
  String? pinnedRoot;
  final readingSearch = TextEditingController(),
      audioSearch = TextEditingController();
  final searchFocus = FocusNode();
  final searchKey = GlobalKey();
  TextEditingController get searchController =>
      reading ? readingSearch : audioSearch;
  String readingView = 'auto', audioView = 'auto';
  bool savingView = false;
  String get shelfView => reading ? readingView : audioView;
  bool _useCovers(double width) =>
      shelfView == 'covers' || shelfView == 'auto' && width >= 900;
  bool reading = false;
  bool metadataSection = false;
  bool recommendationsSection = false;
  bool statisticsSection = false;
  bool videoSection = false;
  late final videoLibrary = VideoRepository(widget.repository);
  late final recommendations = RecommendationStore(widget.repository);
  late final bookCatalog = BookCatalog(httpClient);
  late final obsidianLibrary = LibraryService(
    widget.repository,
    httpClient,
    assets: widget.assets,
  );
  String statusFilter = 'all';
  Set<String> deletedReadingBooks = {};

  /// Books of this section in «Скрытые и недоступные» (hidden, missing file,
  /// no file) plus the trash.
  int unavailableCount = 0;
  static bool _trashPurged = false;
  String query = '',
      filter = 'all',
      message = 'Изменения сохраняются на этом устройстве';
  bool busy = false, loading = true;
  bool indexing = false, favoritesOnly = false;
  final Set<String> selectedBooks = {};
  String readingSort = 'title';
  String audioSort = 'title';
  bool readingSortReverse = false, audioSortReverse = false;
  bool get sortReverse => reading ? readingSortReverse : audioSortReverse;

  /// Characters per minute measured for each book, and over all books.
  Map<String, double> readingRates = {};
  double? overallReadingRate;
  Map<String, DateTime> audioRecent = {};
  Map<String, Map<String, dynamic>> audioPrefs = {},
      audioCollections = {},
      audioSourcePaths = {};
  Map<String, Map<String, dynamic>> get bookPrefs =>
      reading ? readingPrefs : audioPrefs;
  Map<String, Map<String, dynamic>> get collections =>
      reading ? readingCollections : audioCollections;
  String? collectionFilter;
  Map<String, Map<String, dynamic>> readingIndex = {},
      readingPositions = {},
      readingPrefs = {},
      readingCollections = {},
      readingSourcePaths = {};
  late final readingLibrary = ReadingLibrary(widget.repository);
  bool get showSync => false; // Final project stage; local features come first.
  late final syncClient = SyncClient(widget.repository, httpClient);
  @override
  void initState() {
    super.initState();
    widget.repository.externalChanges.addListener(_remoteChanged);
    activeFolderScan.addListener(_folderScanChanged);
    folderScanOutcome.addListener(_folderScanFinished);
    obsidianLibrary.addListener(_libraryChanged);
    _initialize();
  }

  void _libraryChanged() {
    if (mounted) setState(() {});
    if (_remoteRefresh == null &&
        !obsidianLibrary.syncing &&
        !obsidianLibrary.loading &&
        mounted &&
        !metadataSection &&
        !recommendationsSection &&
        !statisticsSection &&
        !videoSection) {
      unawaited(_reload());
    }
  }

  Future<void> _loadObsidian() async {
    // Local migration only. Old connection settings never start network traffic.
    try {
      await widget.repository.setMeta('obsidian-library-enabled', 'false');
      await obsidianLibrary.reload();
    } catch (e) {
      if (mounted) {
        setState(
          () => obsidianLibrary.error =
              'Не удалось загрузить библиотеку: ${describeError(e)}',
        );
      }
    }
  }

  Future<void> _initialize() async {
    final section = await startupSection(widget.repository);
    if (!mounted) return;
    reading = section == 'reading';
    metadataSection = section == 'metadata';
    recommendationsSection = section == 'recommendations';
    statisticsSection = section == 'statistics';
    videoSection = section == 'video';
    unawaited(_loadObsidian());
    await _reload(restoreDefault: true);
    if (mounted && Platform.isAndroid && widget.assets != null) {
      incomingBooks = AndroidBookFiles(
        onFile: _receiveBook,
        onError: (error) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Не удалось открыть полученную книгу: ${describeError(error)}',
                ),
              ),
            );
          }
        },
      )..start();
    }
  }

  Future<void> _switchSection(bool next, {bool closeDrawer = true}) async {
    if (closeDrawer) Navigator.pop(context);
    if (busy ||
        loading ||
        (!metadataSection &&
            !recommendationsSection &&
            !statisticsSection &&
            !videoSection &&
            reading == next)) {
      return;
    }
    setState(() {
      metadataSection = false;
      recommendationsSection = false;
      statisticsSection = false;
      videoSection = false;
      reading = next;
      selectedBooks.clear();
      books = [];
      roots = [];
      selectedRoot = null;
      _searchDebounce?.cancel();
      query = searchController.text;
      filter = statusFilter = 'all';
      favoritesOnly = false;
      collectionFilter = null;
      loading = true;
    });
    await widget.repository.setMeta(
      'library-section',
      next ? 'reading' : 'audio',
    );
    await _reload(restoreDefault: true);
  }

  @override
  void dispose() {
    widget.repository.externalChanges.removeListener(_remoteChanged);
    activeFolderScan.removeListener(_folderScanChanged);
    folderScanOutcome.removeListener(_folderScanFinished);
    _searchDebounce?.cancel();
    readingSearch.dispose();
    audioSearch.dispose();
    searchFocus.dispose();
    incomingBooks?.dispose();
    obsidianLibrary.removeListener(_libraryChanged);
    obsidianLibrary.dispose();
    httpClient.close();
    super.dispose();
  }

  void _folderScanChanged() {
    if (mounted) setState(() {});
  }

  /// A folder scan the user left running has ended: report it here.
  void _folderScanFinished() {
    final outcome = folderScanOutcome.value;
    if (outcome == null || !mounted) return;
    folderScanOutcome.value = null;
    final scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(outcome.message),
        backgroundColor: outcome.failed ? scheme.error : null,
        action: outcome.failed && widget.assets != null
            ? SnackBarAction(label: 'Папки', onPressed: _manageRoots)
            : null,
      ),
    );
    unawaited(_reload());
  }

  Future<void>? _remoteRefresh;
  bool _remoteAgain = false;
  Future<void> _remoteChanged() {
    if (!mounted) return Future<void>.value();
    _remoteAgain = true;
    return _remoteRefresh ??= _drainRemoteRefresh();
  }

  Future<void> _drainRemoteRefresh() async {
    try {
      do {
        _remoteAgain = false;
        // Service notifications still repaint the archive, but the file shelf
        // is refreshed once after metadata updates have committed.
        await obsidianLibrary.reload();
        if (mounted) await _reload();
      } while (_remoteAgain && mounted);
    } catch (e) {
      if (mounted) {
        setState(
          () => obsidianLibrary.error =
              'Не удалось обновить библиотеку: ${describeError(e)}',
        );
      }
    } finally {
      _remoteRefresh = null;
    }
  }

  AndroidBookFiles? incomingBooks;
  final openReaderHashes = <String>{};

  Future<void> _receiveBook(AndroidBookSource source) async {
    if (!mounted || widget.assets == null) return;
    setState(() => message = 'Открытие полученной книги…');
    final asset = await widget.assets!.addBook(
      source.file,
      persistent: source.persistent,
    );
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
      metadataSection = false;
      recommendationsSection = false;
      statisticsSection = false;
      videoSection = false;
      selectedRoot = collectionFilter = null;
      favoritesOnly = false;
      query = '';
      readingSearch.clear();
      _searchDebounce?.cancel();
      filter = statusFilter = 'all';
    });
    await widget.repository.setMeta('library-section', 'reading');
    // Do not hold the native intent queue or staging file until the reader closes.
    unawaited(_openReader(asset));
    await _reload();
  }

  Map<String, String> _coverVersions = {};
  Future<void>? _pdfModeMigration;
  Future<void>? _shelfReload;
  bool _reloadAgain = false, _restoreRoot = false;
  Future<void> _reload({bool restoreDefault = false}) {
    _reloadAgain = true;
    _restoreRoot |= restoreDefault;
    return _shelfReload ??= _drainShelfReload();
  }

  Future<void> _drainShelfReload() async {
    try {
      do {
        _reloadAgain = false;
        final restore = _restoreRoot;
        _restoreRoot = false;
        await _reloadOnce(restoreDefault: restore);
      } while (_reloadAgain && mounted);
    } finally {
      _shelfReload = null;
    }
  }

  Future<void> _reloadOnce({bool restoreDefault = false}) async {
    final readingSection = reading;

    try {
      if (!_trashPurged) {
        _trashPurged = true;
        await BookTrash(widget.repository).purgeExpired();
      }
      final repo = widget.repository;
      final assets = widget.assets;
      // Independent reads start together: the database isolate runs them
      // back to back instead of idling between sequential round trips.
      final hiddenFuture = hiddenFiles(repo);
      final trashFuture = BookTrash(repo).list();
      final coverFuture = repo.metadataPrefixes([
        'audio-cover:',
        'audio-cover-hidden:',
      ]);
      final booksFuture = repo.shelfBooks(audio: !readingSection);
      final deletedFuture = readingSection
          ? ReadingBookVisibility(repo).deletedIds()
          : Future.value(<String>{});
      final flagsFuture = repo.metadataPrefixes(
        readingSection
            ? [Repository.removedShelfBookPrefix, 'reading-library-hidden:']
            : [
                Repository.removedShelfBookPrefix,
                'audio-status-override:',
                'audio-library-superseded:',
                'audio-library-hidden:',
                'audio-user-hidden:',
              ],
      );
      final conflictsFuture = showSync
          ? repo.conflicts().then((rows) => rows.map((r) => r.data).toList())
          : Future.value(<Map<String, dynamic>>[]);
      final filesFuture =
          assets?.shelfAssets(audio: !readingSection) ??
          Future.value(<LocalAsset>[]);
      final rootsFuture = assets == null
          ? Future.value(<AudioRoot>[])
          : readingSection
          ? ReadingRoots(assets).list().then(
              (list) => list
                  .map(
                    (r) => AudioRoot(r.key, {
                      'root': r.path,
                      'title': r.title,
                      'bookIds': r.bookIds,
                    }),
                  )
                  .toList(),
            )
          : AudioRoots(assets).list();
      final defaultRootFuture = LibraryFolderPreference(
        repo,
        reading: readingSection,
      ).load();
      final summaryFuture = readingSection
          ? Future.value(
              <String, ({int? total, int? position, double speed})>{},
            )
          : AudioLibraryRepository(repo.db).bookSummaries();
      // Attaches handlers to every read at once and rethrows the first error.
      await Future.wait<Object?>([
        hiddenFuture,
        trashFuture,
        coverFuture,
        booksFuture,
        deletedFuture,
        flagsFuture,
        conflictsFuture,
        filesFuture,
        rootsFuture,
        defaultRootFuture,
        summaryFuture,
      ]);
      // File-less cards are counted on the shelf (see _statusCounts).
      final unavailable =
          (await hiddenFuture)
              .where((f) => f.audio != readingSection && f.tab != 2)
              .length +
          (await trashFuture).where((f) => f.audio != readingSection).length;
      final coverMetadata = await coverFuture;
      final allBooks = await booksFuture;
      final b = <LibraryRecord>[];
      final deleted = await deletedFuture;
      final overrides = <String, String>{};
      final flags = await flagsFuture;
      for (final book in allBooks) {
        if (flags['${Repository.removedShelfBookPrefix}${book.id}'] == '1') {
          continue;
        }
        if ((book.payload!['format'] != 'audio') != readingSection) continue;
        if (readingSection) {
          if (deleted.contains(book.id) ||
              flags['reading-library-hidden:${book.id}'] != '1') {
            b.add(book);
          }
          continue;
        }
        final override = flags['audio-status-override:${book.id}'];
        if (override != null) overrides[book.id] = override;
        if (flags['audio-library-superseded:${book.id}'] != '1' &&
            flags['audio-user-hidden:${book.id}'] != '1' &&
            flags['audio-library-hidden:${book.id}'] != '1') {
          b.add(book);
        }
      }
      final c = await conflictsFuture;
      final files = await filesFuture;
      final sources = ReadingShelfSources(files);
      final rootList = await rootsFuture;
      final defaultRoot = await defaultRootFuture;
      final summary = await summaryFuture;
      if (readingSection) {
        try {
          await (_pdfModeMigration ??= migrateLegacyPdfMode(repo));
        } catch (_) {
          /* The listing below tolerates the legacy value anyway. */
        }
        final sourcesLoad = sources.load(repo);
        final positionsFuture = readingLibrary.entries('reader:');
        final indexFuture = positionsFuture.then(readingLibrary.shelfIndex);
        final prefsFuture = readingLibrary.entries('reading-book:');
        final sourcePathsFuture = readingLibrary.entries(
          'reading-source-path:',
        );
        final groupsFuture = readingLibrary.entries('reading-collection:');
        final datesFuture = readingLibrary.entries('reading-dates:');
        final orderFuture = repo.meta('reading-sort');
        final reverseFuture = repo.meta('reading-sort-reverse');
        final viewFuture = repo.meta('reading-shelf-view');
        // Time estimates are optional; the shelf still lists books.
        final speedsFuture = readingLibrary
            .speedSamples()
            .then<Map<String, ({int ms, int chars})>>(
              (value) => value,
              onError: (Object _) => <String, ({int ms, int chars})>{},
            );
        await Future.wait<Object?>([
          sourcesLoad,
          positionsFuture,
          indexFuture,
          prefsFuture,
          sourcePathsFuture,
          groupsFuture,
          datesFuture,
          orderFuture,
          reverseFuture,
          viewFuture,
          speedsFuture,
        ]);
        final positions = await positionsFuture;
        final index = await indexFuture;
        final prefs = await prefsFuture;
        final sourcePaths = await sourcePathsFuture;
        final groups = await groupsFuture;
        final dates = await datesFuture;
        final order = await orderFuture ?? 'title';
        final reverse = await reverseFuture;
        final view = await viewFuture;
        final speeds = await speedsFuture;
        if (mounted && reading == readingSection) {
          effectiveReadingInfo = {
            for (final book in b)
              book.id: ReadingLibrary.effective(
                index[sources.first(book.id)?.hash] ?? {},
                prefs[book.id] ?? {},
                dates[book.id] ?? {},
              ),
          };
          var totalMs = 0, totalChars = 0;
          readingRates = {};
          for (final MapEntry(:key, :value) in speeds.entries) {
            totalMs += value.ms;
            totalChars += value.chars;
            final rate = readingRate(value.ms, value.chars);
            if (rate != null) readingRates[key] = rate;
          }
          overallReadingRate = readingRate(totalMs, totalChars);
          readingSortReverse = reverse == '1';
          readingIndex = index;
          readingPositions = positions;
          readingPrefs = prefs;
          readingSourcePaths = sourcePaths;
          readingCollections = groups;
          readingSort = order;
          readingView = const ['list', 'covers'].contains(view)
              ? view!
              : 'auto';
          if (!groups.containsKey(collectionFilter)) collectionFilter = null;
        }
      } else {
        final prefsFuture = readingLibrary.entries('audio-book:');
        final groupsFuture = readingLibrary.entries('audio-collection:');
        final sourcePathsFuture = readingLibrary.entries('audio-source-path:');
        final orderFuture = repo.meta('audio-sort');
        final reverseFuture = repo.meta('audio-sort-reverse');
        final viewFuture = repo.meta('audio-shelf-view');
        final recentFuture = AudioLibraryRepository(repo.db).lastPlayed();
        await Future.wait<Object?>([
          prefsFuture,
          groupsFuture,
          sourcePathsFuture,
          orderFuture,
          reverseFuture,
          viewFuture,
          recentFuture,
        ]);
        final prefs = await prefsFuture;
        final groups = await groupsFuture;
        final sourcePaths = await sourcePathsFuture;
        final order = await orderFuture ?? 'title';
        final reverse = await reverseFuture;
        final view = await viewFuture;
        final recent = await recentFuture;
        if (mounted && reading == readingSection) {
          audioPrefs = prefs;
          audioCollections = groups;
          audioSourcePaths = sourcePaths;
          audioSort = order;
          audioSortReverse = reverse == '1';
          audioView = const ['list', 'covers'].contains(view) ? view! : 'auto';
          audioRecent = recent;
          if (!groups.containsKey(collectionFilter)) collectionFilter = null;
        }
      }
      if (mounted && reading == readingSection) {
        setState(() {
          _coverVersions = {
            for (final book in b)
              book.id:
                  '${coverMetadata['audio-cover:${book.id}'] ?? ''}:${coverMetadata['audio-cover-hidden:${book.id}'] ?? ''}',
          };
          books = b;
          deletedReadingBooks = deleted;
          unavailableCount = unavailable;
          statusOverrides = overrides;
          roots = rootList;
          pinnedRoot = defaultRoot;
          if (restoreDefault ||
              selectedRoot != null &&
                  !roots.any((r) => r.key == selectedRoot)) {
            selectedRoot = roots.any((r) => r.key == defaultRoot)
                ? defaultRoot
                : null;
          }
          localAssets = files;
          shelfSources = sources;
          audioSummaries = summary;
          conflicts = c;
          loading = false;
        });
      }
      if (readingSection &&
          mounted &&
          reading &&
          !indexing &&
          widget.assets != null) {
        final ids = b
            .where((b) => !deleted.contains(b.id))
            .map((b) => b.id)
            .toSet();
        final missing = files
            .where(
              (a) =>
                  ids.contains(a.bookId) &&
                  (!readingIndex.containsKey(a.hash) ||
                      bookFormat(a.filename) == 'txt' &&
                          readingIndex[a.hash]?['layoutVersion'] !=
                              currentBookLayout &&
                          readingIndex[a.hash]?['error'] == null ||
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
          message = 'Ошибка чтения: ${describeError(e)}';
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
      if (mounted) {
        setState(() => message = 'Ошибка индексирования: ${describeError(e)}');
      }
    } finally {
      if (mounted) setState(() => indexing = false);
    }
  }

  Map<String, dynamic> _textInfo(LibraryRecord b) {
    return effectiveReadingInfo[b.id] ?? {};
  }

  Map<String, dynamic> _textPosition(LibraryRecord b) {
    final asset = shelfSources.first(b.id);
    return readingPositions[asset?.hash] ?? {};
  }

  String _sourcePath(LibraryRecord book) =>
      readingSourcePaths[book.id]?['relativePath'] as String? ??
      shelfSources.first(book.id)?.filename ??
      '';

  static final _filenamePrefix = RegExp(r'^\s*(\d+(?:[._-]\d+)*[.)]?)\s+');
  static final _titlePrefix = RegExp(r'^\s*\d+[.)\s]');
  String _title(LibraryRecord b) {
    if (!reading) return b.title;
    final title = _textInfo(b)['title'] as String? ?? b.title;
    if (readingPrefs[b.id]?['title'] != null) return title;
    final filename = p.posix.basename(_sourcePath(b));
    final prefix = _filenamePrefix.firstMatch(filename)?.group(1);
    if (prefix == null || _titlePrefix.hasMatch(title)) {
      return title;
    }
    return '$prefix $title';
  }

  String _readingOrderKey(LibraryRecord b) {
    final path = _sourcePath(b);
    return path.isEmpty ? _title(b) : path;
  }

  String _authors(LibraryRecord b) =>
      ((reading ? _textInfo(b)['authors'] : null) as List? ??
              b.payload!['authors'] as List)
          .join(', ');
  double _fraction(LibraryRecord b) =>
      readingFraction(_textInfo(b), _textPosition(b));

  /// ISO date the book was finished, or '' (sorts after any date).
  String _finishedKey(LibraryRecord b) =>
      _status(b) == 'finished' ? '${_textInfo(b)['finishedAt'] ?? ''}' : '';

  /// Text length in characters; a PDF is estimated from its page count.
  int? _textLength(LibraryRecord b) {
    final length = (_textInfo(b)['length'] as num?)?.toInt() ?? 0;
    if (length > 0) return length;
    final pages = (_textInfo(b)['pdfPages'] as num?)?.toInt() ?? 0;
    return pages > 0 ? pages * 1800 : null;
  }

  String? _textRemaining(LibraryRecord b) {
    if (_status(b) == 'finished') return null;
    final length = (_textInfo(b)['length'] as num?)?.toInt() ?? 0;
    return textRemainingLabel(
      length: length,
      fraction: _fraction(b),
      rate: readingRates[b.id] ?? overallReadingRate,
    );
  }

  String? _lastOpened(LibraryRecord b) =>
      lastOpenedLabel(_textPosition(b)['updatedAt'], DateTime.now());

  Future<void> _allNotes() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ReadingNotesPage(
          repository: widget.repository,
          bookIds: books.map((b) => b.id).toSet(),
          onOpen: (note) async {
            if (deletedReadingBooks.contains(note.bookId)) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Файл книги удалён. Добавьте тот же файл, чтобы открыть заметку в тексте.',
                  ),
                ),
              );
              return;
            }
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

  Future<void> _pinFolder() => _action(() async {
    final next = selectedRoot == pinnedRoot ? null : selectedRoot;
    await LibraryFolderPreference(
      widget.repository,
      reading: reading,
    ).set(next);
    if (!mounted) return;
    setState(() => pinnedRoot = next);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          next == null
              ? 'По умолчанию будет открываться вся библиотека'
              : 'Эта папка будет открываться по умолчанию',
        ),
      ),
    );
  });

  Future<void> _action(Future<void> Function() work) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await work();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(readingBookActionMessage(e))));
      }
    } finally {
      await _reload();
      if (mounted) setState(() => busy = false);
    }
  }

  void _toggleBook(String id) => setState(() {
    if (!selectedBooks.add(id)) selectedBooks.remove(id);
  });

  Future<void> _batchBooks(String action) async {
    final chosen =
        books.where((book) => selectedBooks.contains(book.id)).toList()..sort(
          (a, b) => naturalAudioOrder(
            '${audioSourcePaths[a.id]?['relativePath'] ?? _title(a)}',
            '${audioSourcePaths[b.id]?['relativePath'] ?? _title(b)}',
          ),
        );
    if (chosen.isEmpty) return;
    if (action == 'merge') {
      final matchingRoot = roots
          .where(
            (root) => chosen.every((book) => root.bookIds.contains(book.id)),
          )
          .firstOrNull;
      final title = TextEditingController(
        text: matchingRoot?.title ?? _title(chosen.first),
      );
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Объединить аудиокниги'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Треки будут идти в показанном порядке. Исходные карточки скроются; позиции, события и заметки перейдут в объединённую книгу.',
                ),
                const SizedBox(height: 12),
                Text(chosen.map((book) => _title(book)).join(' → ')),
                TextField(
                  controller: title,
                  decoration: const InputDecoration(
                    labelText: 'Название книги',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Объединить'),
            ),
          ],
        ),
      );
      if (confirmed != true) {
        title.dispose();
        return;
      }
      final name = title.text;
      title.dispose();
      await _action(() async {
        await widget.audio?.stop();
        final id = await AudioMerge(widget.assets!)
            .merge(chosen.map((book) => book.id).toList(), name);
        await widget.audio?.sidecar.update(id, force: true);
        if (mounted) setState(selectedBooks.clear);
      });
      return;
    }
    if (action == 'delete') {
      await _deleteBooks(chosen);
      return;
    }
    await _action(() async {
      if (action == 'hide') {
        final ids = chosen.map((book) => book.id).toList();
        final actions = reading
            ? ReadingBookActions(widget.assets!)
            : AudioBookActions(widget.assets!);
        await actions.hideMany(ids);
        if (mounted) {
          setState(selectedBooks.clear);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Скрыто с полки: ${ids.length}'),
              action: SnackBarAction(
                label: 'Вернуть',
                onPressed: () =>
                    _action(() => actions.hideMany(ids, hidden: false)),
              ),
            ),
          );
        }
        return;
      }
      for (final book in chosen) {
        if (action == 'favorite') {
          final prefix = reading ? 'reading' : 'audio';
          await readingLibrary.update('$prefix-book:${book.id}', {
            'favorite': true,
          });
        } else {
          await widget.repository.put('book', book.id, {
            ...book.payload!,
            'status': action,
          });
          if (reading) {
            final prefs = await readingLibrary.value('reading-book:${book.id}');
            await readingLibrary.update('reading-book:${book.id}', {
              'overrides': {
                ...Map<String, dynamic>.from(prefs['overrides'] as Map? ?? {}),
                'status': action,
              },
            });
          } else {
            await widget.repository.setMeta(
              'audio-status-override:${book.id}',
              action,
            );
          }
        }
      }
      if (mounted) setState(selectedBooks.clear);
    });
  }

  Future<void> _deleteBooks(List<LibraryRecord> chosen) async {
    final assets = widget.assets;
    if (assets == null || chosen.isEmpty) return;
    List<String> moved = const [];
    await _action(() async {
      moved = await deleteBooksToTrash(context, assets, [
        for (final book in chosen)
          (
            id: book.id,
            title: _title(book),
            audio: book.payload?['format'] == 'audio',
            hasFile:
                shelfSources.first(book.id) != null ||
                (book.payload?['format'] == 'audio' &&
                    audioSourcePaths.containsKey(book.id)),
          ),
      ], beforeDelete: _checkBookClosed);
      if (mounted && moved.isNotEmpty) setState(selectedBooks.clear);
    });
    if (mounted) showMovedToTrash(context, assets, moved, onRestored: _reload);
  }

  Future<void> _openUnavailable() async {
    if (widget.assets == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => HiddenDeletedPage(
          library: obsidianLibrary,
          initialMedia: reading ? 'book' : 'audio',
        ),
      ),
    );
    if (mounted) await _reload();
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
    final picked = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => reading
            ? ReadingRootsPage(assets: widget.assets!)
            : AudioRootsPage(assets: widget.assets!),
      ),
    );
    // A folder tapped on the folders screen opens the shelf filtered by it.
    if (picked != null) {
      await _reload();
      if (mounted && roots.any((r) => r.key == picked)) {
        setState(() => selectedRoot = picked);
      }
    }
  });

  Future<void> _importBook() => _action(() async {
    const mimeTypes = [
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
      'application/octet-stream',
    ];
    if (Platform.isAndroid) {
      final source = await pickAndroidBook(mimeTypes);
      if (source == null || !mounted) return;
      final asset = await widget.assets!.addBook(
        source.file,
        persistent: source.persistent,
      );
      if (mounted) await _openReader(asset);
      return;
    }
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Книги: EPUB, FB2, TXT, Markdown, HTML, DOCX, RTF, PDF',
          extensions: bookExtensions,
          mimeTypes: mimeTypes,
        ),
      ],
    );
    if (file == null) return;
    final asset = await widget.assets!.addBook(file);
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
    await widget.audio?.pause();
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => bookFormat(asset.filename) == 'pdf'
            ? PdfReaderPage(
                assets: widget.assets,
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
    final sessions = (await widget.repository.records('session'))
        .where((s) => s.payload?['kind'] == (reading ? 'reading' : 'listening'))
        .toList();
    final text = exportMarkdown(books, sessions);
    if (Platform.isAndroid) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Экспорт Markdown'),
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

  Future<void> _metadataSection({bool closeDrawer = true}) async {
    if (closeDrawer) Navigator.pop(context);
    if (busy || loading) return;
    setState(() {
      metadataSection = true;
      recommendationsSection = false;
      statisticsSection = false;
      videoSection = false;
      selectedBooks.clear();
    });
    await widget.repository.setMeta('library-section', 'metadata');
    await obsidianLibrary.reload();
  }

  PepeSection get _section => videoSection
      ? PepeSection.video
      : statisticsSection
      ? PepeSection.statistics
      : recommendationsSection
      ? PepeSection.recommendations
      : metadataSection
      ? PepeSection.library
      : reading
      ? PepeSection.books
      : PepeSection.audio;

  ShelfNavigation get _navigation => ShelfNavigation(
    current: _section,
    enabled: !busy && !loading,
    onSettings: _appSettings,
    onSelect: _selectSection,
  );

  Future<void> _selectSection(PepeSection section) async {
    if (busy || loading) return;
    switch (section) {
      case PepeSection.books:
        await _switchSection(true, closeDrawer: false);
      case PepeSection.audio:
        await _switchSection(false, closeDrawer: false);
      case PepeSection.video:
        setState(() {
          videoSection = true;
          metadataSection = false;
          recommendationsSection = false;
          statisticsSection = false;
          selectedBooks.clear();
        });
        await widget.repository.setMeta('library-section', 'video');
      case PepeSection.library:
        await _metadataSection(closeDrawer: false);
      case PepeSection.recommendations:
        setState(() {
          recommendationsSection = true;
          videoSection = false;
          metadataSection = false;
          statisticsSection = false;
          selectedBooks.clear();
        });
        await widget.repository.setMeta('library-section', 'recommendations');
      case PepeSection.statistics:
        setState(() {
          statisticsSection = true;
          videoSection = false;
          recommendationsSection = false;
          metadataSection = false;
          selectedBooks.clear();
        });
        await widget.repository.setMeta('library-section', 'statistics');
    }
  }

  void _journal() => Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => ActivityPage(library: obsidianLibrary)),
  );
  void _appSettings() => Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => SettingsPage(library: obsidianLibrary)),
  );

  Future<void> _obsidianSettings() => Navigator.push<void>(
    context,
    MaterialPageRoute(
      builder: (_) => LibraryDataPage(library: obsidianLibrary),
    ),
  );

  Future<void> _addToObsidian(LibraryRecord book) async {
    await obsidianLibrary.loadCached();
    if (!mounted) return;
    final linked =
        obsidianLibrary.forBook(book.id) ??
        obsidianLibrary.sourceDraft(book.id);
    if (linked != null &&
        isSeriesCatalogItem(linked.item) &&
        !isLibraryDeleted(linked.item) &&
        (isFinishedLibraryItem(linked.item) ||
            linked.item.values['pepehub_auto_discovered'] == false)) {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) =>
              LibraryWorkPage(library: obsidianLibrary, itemId: linked.item.id),
        ),
      );
      return;
    }
    if (linked != null && linked.state != 'removed') {
      final editableItem = linked.item.withValues({
        ...linked.item.values,
        'status': 'finished',
        'pepehub_deleted_at': null,
        'pepehub_recommendation_only': false,
      });
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => LibraryMetadataEditor(
            saveLabel: 'Добавить в библиотеку',
            coverResolver: obsidianLibrary.coverReferencePath,
            suggestions: obsidianLibrary.suggestions,
            seriesEntries: obsidianLibrary.seriesEntries,
            collection: obsidianLibrary.collectionFor(linked.item),
            collections:
                (obsidianLibrary.snapshot?['collections'] as List? ?? [])
                    .map((c) => Map<String, dynamic>.from(c as Map))
                    .toList(),
            syncPolicy: obsidianLibrary.policies[linked.item.id] ?? const {},
            onSavePolicy: (policy) =>
                obsidianLibrary.savePolicy(linked.item.id, policy),
            onPickCover: obsidianLibrary.chooseCover,
            item: editableItem,
            entry: linked,
            onSave: (values) => obsidianLibrary.add(
              linked.item.withValues(values),
              book.id,
              original: linked.item.values,
            ),
          ),
        ),
      );
      return;
    }
    // Link a file to an existing personal card rather than duplicating it.
    if (obsidianLibrary.entries.any(
      (e) => e.state == 'synced' && e.sourceBookId == null,
    )) {
      final choice = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('Добавить в библиотеку'),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 'create'),
              child: const Text('Создать карточку в библиотеке'),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 'link'),
              child: const Text('Связать с существующей карточкой'),
            ),
          ],
        ),
      );
      if (!mounted || choice == null) return;
      if (choice == 'link') {
        final id = await showDialog<String>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('Карточка библиотеки'),
            children: [
              for (final entry in obsidianLibrary.entries.where(
                (e) => e.state == 'synced' && e.sourceBookId == null,
              ))
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, entry.item.id),
                  child: Text(
                    '${entry.item.title}\n${entry.item.authors}\n${entry.item.path}',
                  ),
                ),
            ],
          ),
        );
        if (id != null && mounted) {
          final target = obsidianLibrary.entries
              .where((e) => e.item.id == id)
              .first
              .item;
          final preview = await obsidianLibrary.previewLink(book, target);
          if (!mounted) return;
          final policy = await reviewLibraryLink(context, target, preview);
          if (policy != null) {
            await obsidianLibrary.link(id, book.id, policy: policy);
          }
        }
        return;
      }
    }
    final source = await obsidianLibrary.prepareDraft(book);
    final draft = source.withValues({...source.values, 'status': 'finished'});
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => LibraryMetadataEditor(
          coverResolver: obsidianLibrary.coverReferencePath,
          suggestions: obsidianLibrary.suggestions,
          seriesEntries: obsidianLibrary.seriesEntries,
          collection: obsidianLibrary.collectionFor(draft),
          collections: (obsidianLibrary.snapshot?['collections'] as List? ?? [])
              .map((c) => Map<String, dynamic>.from(c as Map))
              .toList(),
          onSavePolicy: (policy) =>
              obsidianLibrary.savePolicy(draft.id, policy),
          onPickCover: obsidianLibrary.chooseCover,
          item: draft,
          saveLabel: 'Добавить в библиотеку',
          onSave: (values) => obsidianLibrary.add(
            draft.withValues(values),
            book.id,
            original: draft.values,
          ),
        ),
      ),
    );
  }

  Future<void> _archiveRecommendation(RecommendedBook book) async {
    final audio = await showDialog<bool>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Сохранить результат'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Книга прочитана'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Аудиокнига прослушана'),
          ),
        ],
      ),
    );
    if (audio == null || !mounted) return;
    await obsidianLibrary.reload();
    final draft = obsidianLibrary.fromRecommendation(book, audio: audio);
    final existing = obsidianLibrary.entries
        .where((e) => e.item.id == draft.id)
        .firstOrNull;
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => LibraryMetadataEditor(
          item: draft,
          collection: obsidianLibrary.collectionFor(draft),
          suggestions: obsidianLibrary.suggestions,
          seriesEntries: obsidianLibrary.seriesEntries,
          coverResolver: obsidianLibrary.coverReferencePath,
          onPickCover: obsidianLibrary.chooseCover,
          saveLabel: 'Сохранить в библиотеке',
          onSave: (values) => existing == null
              ? obsidianLibrary.add(draft.withValues(values), '')
              : obsidianLibrary.save(
                  existing.item.id,
                  values,
                  original: existing.item.values,
                ),
        ),
      ),
    );
  }

  Future<void> _focusSearch() async {
    final field = searchKey.currentContext;
    if (field != null) {
      await Scrollable.ensureVisible(
        field,
        duration: const Duration(milliseconds: 180),
        alignment: .1,
      );
    }
    if (mounted) searchFocus.requestFocus();
  }

  void _searchChanged(String value) {
    _searchDebounce?.cancel();
    final section = reading;
    _searchDebounce = Timer(const Duration(milliseconds: 200), () {
      if (mounted &&
          reading == section &&
          !metadataSection &&
          !recommendationsSection &&
          !statisticsSection &&
          !videoSection) {
        setState(() => query = value);
      }
    });
  }

  Future<void> _setShelfView(String value) async {
    if (busy || savingView) return;
    final section = reading;
    setState(() => savingView = true);
    try {
      await widget.repository.setMeta(
        '${section ? 'reading' : 'audio'}-shelf-view',
        value,
      );
      if (mounted) {
        setState(() {
          if (section) {
            readingView = value;
          } else {
            audioView = value;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Не удалось сохранить вид полки: ${describeError(e)}',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => savingView = false);
    }
  }

  /// Filters other than the status tabs and the search text.
  int get _activeFilterCount => [
    selectedRoot != null,
    reading && filter != 'all',
    collectionFilter != null,
    favoritesOnly,
  ].where((active) => active).length;

  void _resetFilters() => setState(() {
    selectedRoot = null;
    filter = 'all';
    collectionFilter = null;
    favoritesOnly = false;
  });

  Future<void> _setSortReverse(bool value) async {
    final key = reading ? 'reading-sort-reverse' : 'audio-sort-reverse';
    await _action(() => widget.repository.setMeta(key, value ? '1' : '0'));
  }

  Widget _shelfToolbar() {
    final count = _activeFilterCount;
    final sort = reading ? readingSort : audioSort;
    final orders = {
      'added': 'Недавно добавленные',
      'title': 'По названию',
      'author': 'По автору',
      if (reading) 'series': 'По серии',
      'progress': 'По прогрессу',
      'recent': reading ? 'Недавно открытые' : 'Недавняя активность',
      if (reading) 'finished': 'По дате прочтения',
      if (reading) 'length': 'Сначала короткие',
      if (reading) 'length-desc': 'Сначала длинные',
      if (!reading) 'duration': 'Сначала короткие',
      if (!reading) 'duration-desc': 'Сначала длинные',
    };
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Badge(
          isLabelVisible: count > 0,
          label: Text('$count'),
          child: OutlinedButton.icon(
            key: const ValueKey('shelf-filters'),
            onPressed: busy ? null : _showFilters,
            icon: const Icon(Icons.tune, size: 18),
            label: const Text('Фильтры'),
          ),
        ),
        PopupMenuButton<String>(
          tooltip: reading ? 'Сортировка книг' : 'Сортировка аудиокниг',
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          icon: const Icon(Icons.sort),
          onSelected: (v) async {
            if (v == 'reverse') {
              await _setSortReverse(!sortReverse);
              return;
            }
            final key = reading ? 'reading-sort' : 'audio-sort';
            await _action(() => widget.repository.setMeta(key, v));
          },
          itemBuilder: (_) => [
            for (final e in orders.entries)
              CheckedPopupMenuItem(
                value: e.key,
                checked: sort == e.key,
                child: Text(e.value),
              ),
            const PopupMenuDivider(),
            CheckedPopupMenuItem(
              key: const ValueKey('sort-reverse'),
              value: 'reverse',
              checked: sortReverse,
              child: const Text('Обратный порядок'),
            ),
          ],
        ),
        _viewChoices(),
        if (reading)
          IconButton(
            tooltip: 'Все заметки',
            visualDensity: VisualDensity.compact,
            onPressed: _allNotes,
            icon: const Icon(Icons.edit_note),
          ),
        IconButton(
          tooltip: 'Обновить список',
          visualDensity: VisualDensity.compact,
          onPressed: busy
              ? null
              : reading
              ? _refreshReadingFolders
              : _reload,
          icon: const Icon(Icons.refresh),
        ),
      ],
    );
  }

  /// Active filters as removable chips under the search field.
  List<Widget> _activeFilters() {
    if (_activeFilterCount == 0) return const [SizedBox(height: 12)];
    final root = roots.where((r) => r.key == selectedRoot).firstOrNull;
    final collection = collections[collectionFilter]?['name'] as String?;
    return [
      const SizedBox(height: 6),
      Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (selectedRoot != null)
            InputChip(
              key: const ValueKey('active-folder-filter'),
              avatar: const Icon(Icons.folder_outlined, size: 18),
              label: Text(
                'Папка: ${root?.title ?? selectedRoot}',
                overflow: TextOverflow.ellipsis,
              ),
              onDeleted: () => setState(() => selectedRoot = null),
              deleteButtonTooltipMessage: 'Показать всю библиотеку',
            ),
          if (reading && filter != 'all')
            InputChip(
              key: const ValueKey('active-format-filter'),
              label: Text('Формат: ${formatLabel(filter)}'),
              onDeleted: () => setState(() => filter = 'all'),
              deleteButtonTooltipMessage: 'Сбросить формат',
            ),
          if (collectionFilter != null)
            InputChip(
              key: const ValueKey('active-collection-filter'),
              avatar: const Icon(Icons.collections_bookmark_outlined, size: 18),
              label: Text('Коллекция: ${collection ?? ''}'),
              onDeleted: () => setState(() => collectionFilter = null),
              deleteButtonTooltipMessage: 'Сбросить коллекцию',
            ),
          if (favoritesOnly)
            InputChip(
              key: const ValueKey('active-favorites-filter'),
              avatar: const Icon(Icons.star, size: 18),
              label: const Text('Только избранное'),
              onDeleted: () => setState(() => favoritesOnly = false),
              deleteButtonTooltipMessage: 'Показать все книги',
            ),
          TextButton(
            key: const ValueKey('shelf-reset-filters'),
            onPressed: _resetFilters,
            child: const Text('Сбросить всё'),
          ),
        ],
      ),
      const SizedBox(height: 12),
    ];
  }

  Future<void> _showFilters() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setSheet) {
        void apply(VoidCallback change) {
          setState(change);
          setSheet(() {});
        }

        final labelStyle = Theme.of(sheetContext).textTheme.labelLarge;
        Widget section(String title, List<Widget> children) => Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: labelStyle),
              const SizedBox(height: 8),
              ...children,
            ],
          ),
        );
        Widget choices<T>(
          Map<T, String> options,
          T selected,
          ValueChanged<T> select,
        ) => Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final entry in options.entries)
              ChoiceChip(
                label: Text(entry.value),
                selected: selected == entry.key,
                showCheckmark: false,
                onSelected: (_) => apply(() => select(entry.key)),
              ),
          ],
        );
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Фильтры',
                        style: Theme.of(sheetContext).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 16),
                      if (roots.isNotEmpty)
                        section('Папка', [
                          Row(
                            children: [
                              Expanded(
                                child: DropdownButton<String?>(
                                  key: const ValueKey('library-folder'),
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
                                      apply(() => selectedRoot = v),
                                ),
                              ),
                              IconButton(
                                key: const ValueKey('library-pin-folder'),
                                tooltip: selectedRoot == null
                                    ? 'Открывать всю библиотеку по умолчанию'
                                    : selectedRoot == pinnedRoot
                                    ? 'Открепить папку по умолчанию'
                                    : 'Открывать эту папку по умолчанию',
                                onPressed:
                                    busy ||
                                        (selectedRoot == null &&
                                            pinnedRoot == null)
                                    ? null
                                    : () async {
                                        await _pinFolder();
                                        setSheet(() {});
                                      },
                                icon: Icon(
                                  selectedRoot != null &&
                                          selectedRoot == pinnedRoot
                                      ? Icons.push_pin
                                      : Icons.push_pin_outlined,
                                ),
                              ),
                            ],
                          ),
                        ]),
                      if (reading)
                        section('Формат', [
                          choices<String>(
                            {'all': 'Все форматы', ...bookFormats},
                            filter,
                            (v) => filter = v,
                          ),
                        ]),
                      section('Коллекция', [
                        if (collections.isNotEmpty)
                          choices<String?>(
                            {
                              null: 'Все коллекции',
                              for (final e in collections.entries)
                                e.key: e.value['name'] as String,
                            },
                            collectionFilter,
                            (v) => collectionFilter = v,
                          ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            key: const ValueKey('manage-collections'),
                            onPressed: () async {
                              await showLibraryCollections(
                                sheetContext,
                                widget.repository,
                                audio: !reading,
                              );
                              await _reload();
                              if (sheetContext.mounted) setSheet(() {});
                            },
                            icon: const Icon(
                              Icons.collections_bookmark_outlined,
                            ),
                            label: Text(
                              collections.isEmpty
                                  ? 'Создать коллекцию'
                                  : 'Управлять коллекциями',
                            ),
                          ),
                        ),
                      ]),
                      SwitchListTile.adaptive(
                        key: const ValueKey('filter-favorites'),
                        contentPadding: EdgeInsets.zero,
                        secondary: const Icon(Icons.star_outline),
                        title: const Text('Только избранное'),
                        value: favoritesOnly,
                        onChanged: (v) => apply(() => favoritesOnly = v),
                      ),
                    ],
                  ),
                ),
              ),
              // Kept outside the scroll view: always reachable with large text.
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: OverflowBar(
                  alignment: MainAxisAlignment.spaceBetween,
                  overflowAlignment: OverflowBarAlignment.end,
                  overflowSpacing: 4,
                  children: [
                    TextButton(
                      onPressed: _activeFilterCount == 0
                          ? null
                          : () {
                              _resetFilters();
                              setSheet(() {});
                            },
                      child: const Text('Сбросить всё'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(sheetContext),
                      child: const Text('Готово'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    ),
  );

  Widget _viewChoices() => LayoutBuilder(
    builder: (context, size) {
      final grid = _useCovers(size.maxWidth);
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Список',
            visualDensity: VisualDensity.compact,
            isSelected: !grid,
            onPressed: busy || savingView ? null : () => _setShelfView('list'),
            icon: const Icon(Icons.view_list_outlined),
            selectedIcon: const Icon(Icons.view_list),
          ),
          IconButton(
            tooltip: 'Обложки',
            visualDensity: VisualDensity.compact,
            isSelected: grid,
            onPressed: busy || savingView
                ? null
                : () => _setShelfView('covers'),
            icon: const Icon(Icons.grid_view_outlined),
            selectedIcon: const Icon(Icons.grid_view),
          ),
        ],
      );
    },
  );

  List<Object?>? _visibleInputs;
  List<LibraryRecord> _visibleCache = [];
  Timer? _searchDebounce;
  List<LibraryRecord> _visibleBooks() {
    final inputs = <Object?>[
      books,
      roots,
      selectedRoot,
      reading,
      statusFilter,
      filter,
      favoritesOnly,
      collectionFilter,
      query,
      readingSort,
      audioSort,
      readingSortReverse,
      audioSortReverse,
      bookPrefs,
      audioSummaries,
      audioRecent,
      audioSourcePaths,
      readingSourcePaths,
      readingPositions,
      effectiveReadingInfo,
      shelfSources,
      deletedReadingBooks,
      statusOverrides,
    ];
    if (listEquals(inputs, _visibleInputs)) return _visibleCache;
    final rootIds = selectedRoot == null
        ? null
        : roots
              .where((r) => r.key == selectedRoot)
              .firstOrNull
              ?.bookIds
              .toSet();
    final terms = catalogSearchTerms(query);
    final visible = books
        .where(
          (b) =>
              (rootIds == null || rootIds.contains(b.id)) &&
              // Missing and file-less books live in «Скрытые и недоступные».
              (!reading ||
                  !deletedReadingBooks.contains(b.id) && !_remoteOnly(b)) &&
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
              matchesCatalogSearch(
                '${_title(b)} ${_authors(b)} ${reading ? _textInfo(b)['series'] ?? '' : b.payload?['series'] ?? ''}',
                terms,
              ),
        )
        .toList();
    if (reading) {
      visible.sort((a, b) {
        // Books without a finish date or an indexed size stay last whichever
        // direction is chosen.
        final missing = switch (readingSort) {
          'finished' => (_finishedKey(a).isEmpty, _finishedKey(b).isEmpty),
          'length' ||
          'length-desc' => (_textLength(a) == null, _textLength(b) == null),
          _ => (false, false),
        };
        if (missing.$1 != missing.$2) return missing.$1 ? 1 : -1;
        var result = missing.$1
            ? 0
            : switch (readingSort) {
                'added' => (b.localOrder ?? 0).compareTo(a.localOrder ?? 0),
                'author' => naturalAudioOrder(_authors(a), _authors(b)),
                'series' => naturalAudioOrder(
                  '${_textInfo(a)['series'] ?? ''}',
                  '${_textInfo(b)['series'] ?? ''}',
                ),
                'progress' => _fraction(b).compareTo(_fraction(a)),
                'recent' => '${_textPosition(b)['updatedAt'] ?? ''}'.compareTo(
                  '${_textPosition(a)['updatedAt'] ?? ''}',
                ),
                'finished' => _finishedKey(b).compareTo(_finishedKey(a)),
                'length' => _textLength(a)!.compareTo(_textLength(b)!),
                'length-desc' => _textLength(b)!.compareTo(_textLength(a)!),
                _ => naturalAudioOrder(
                  _readingOrderKey(a),
                  _readingOrderKey(b),
                ),
              };
        if (result == 0 && readingSort == 'series') {
          result = (double.tryParse('${_textInfo(a)['seriesNumber']}') ?? 0)
              .compareTo(
                double.tryParse('${_textInfo(b)['seriesNumber']}') ?? 0,
              );
        }
        if (result != 0) return readingSortReverse ? -result : result;
        return naturalAudioOrder(_title(a), _title(b));
      });
    }
    if (!reading) {
      visible.sort((a, b) {
        if (audioSort == 'title') {
          final pathA = audioSourcePaths[a.id]?['relativePath'] as String?;
          final pathB = audioSourcePaths[b.id]?['relativePath'] as String?;
          if (pathA != null && pathB != null) {
            final byPath = naturalAudioOrder(pathA, pathB);
            if (byPath != 0) return byPath;
          }
        }
        return compareAudioBooks(
          a,
          b,
          order: audioSort,
          summaries: audioSummaries,
          recent: audioRecent,
        );
      });
      if (audioSortReverse) {
        final reversed = visible.reversed.toList();
        visible
          ..clear()
          ..addAll(reversed);
      }
    }
    _visibleInputs = inputs;
    return _visibleCache = visible;
  }

  @override
  Widget build(BuildContext context) {
    PepeRoot.navigation = _navigation;
    if (videoSection) {
      return VideoLibraryPage(
        repository: videoLibrary,
        navigation: _navigation,
        audio: widget.audio,
      );
    }
    if (statisticsSection) {
      return StatisticsHubPage(
        repository: widget.repository,
        library: obsidianLibrary,
        audio: widget.audio,
        navigation: _navigation,
        onJournal: _journal,
      );
    }
    if (recommendationsSection) {
      return RecommendationsPage(
        store: recommendations,
        catalog: bookCatalog,
        navigation: _navigation,
        onCompleted: _archiveRecommendation,
      );
    }
    if (metadataSection) {
      return ObsidianLibraryPage(
        service: obsidianLibrary,
        navigation: _navigation,
        onSettings: () => unawaited(_obsidianSettings()),
      );
    }
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            _focusSearch,
      },
      child: Focus(autofocus: true, child: _fileShelf(context)),
    );
  }

  Widget _fileShelf(BuildContext context) {
    final liveCount = books
        .where((b) => !deletedReadingBooks.contains(b.id) && !_remoteOnly(b))
        .length;
    final visible = _visibleBooks();
    // Every match is listed in the same order with or without filters: a
    // "now reading" card above would pull started books out of the list only
    // while no filter is set, so the shelf looked different per folder.
    final listed = visible;
    return ShelfShell(
      title: selectedBooks.isNotEmpty
          ? 'Выбрано: ${selectedBooks.length}'
          : reading
          ? 'Книги'
          : 'Аудиокниги',
      navigation: _navigation,
      bottomNavigationBar: AudioMiniPlayer(controller: widget.audio),
      actions: selectedBooks.isNotEmpty
          ? [
              IconButton(
                tooltip: 'Выбрать все видимые',
                onPressed: () => setState(
                  () => selectedBooks.addAll(visible.map((book) => book.id)),
                ),
                icon: const Icon(Icons.select_all),
              ),
              PopupMenuButton<String>(
                tooltip: 'Действия с выбранными',
                onSelected: _batchBooks,
                itemBuilder: (_) => [
                  if (!reading &&
                      selectedBooks.length > 1 &&
                      widget.assets != null)
                    const PopupMenuItem(
                      value: 'merge',
                      child: Text('Объединить в аудиокнигу'),
                    ),
                  const PopupMenuItem(
                    value: 'favorite',
                    child: Text('Добавить в избранное'),
                  ),
                  if (widget.assets != null) ...const [
                    PopupMenuItem(value: 'hide', child: Text('Скрыть с полки')),
                    PopupMenuItem(value: 'delete', child: Text('Удалить…')),
                  ],
                  const PopupMenuItem(
                    value: 'planned',
                    child: Text('Отметить новыми'),
                  ),
                  const PopupMenuItem(
                    value: 'active',
                    child: Text('Отметить начатыми'),
                  ),
                  const PopupMenuItem(value: 'paused', child: Text('Отложить')),
                  const PopupMenuItem(
                    value: 'abandoned',
                    child: Text('Бросить'),
                  ),
                  const PopupMenuItem(
                    value: 'finished',
                    child: Text('Отметить завершёнными'),
                  ),
                ],
              ),
              IconButton(
                tooltip: 'Отменить выбор',
                onPressed: () => setState(selectedBooks.clear),
                icon: const Icon(Icons.close),
              ),
            ]
          : [
              IconButton(
                tooltip: 'Выбрать видимые книги',
                onPressed: busy || visible.isEmpty
                    ? null
                    : () => setState(
                        () => selectedBooks.addAll(
                          visible.map((book) => book.id),
                        ),
                      ),
                icon: const Icon(Icons.select_all),
              ),
              IconButton(
                tooltip: 'Папки библиотеки',
                onPressed: busy || widget.assets == null ? null : _manageRoots,
                icon: const Icon(Icons.folder_open),
              ),
              IconButton(
                tooltip: reading
                    ? 'Статистика чтения'
                    : 'Статистика прослушивания',
                icon: const Icon(Icons.bar_chart),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => reading
                        ? ReadingStatisticsPage(
                            repository: widget.repository,
                            library: obsidianLibrary,
                          )
                        : AudioStatisticsPage(
                            repository: widget.repository,
                            controller: widget.audio,
                            library: obsidianLibrary,
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
                  if (value == 'hidden') _openUnavailable();
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'new',
                    child: Text('Новая карточка без файла'),
                  ),
                  PopupMenuItem(
                    value: 'folder',
                    child: Text(
                      reading
                          ? 'Подключить папку книг…'
                          : 'Подключить папку аудиокниг…',
                    ),
                  ),
                  if (reading)
                    const PopupMenuItem(
                      value: 'book',
                      child: Text('Открыть файл…'),
                    ),
                  const PopupMenuItem(
                    value: 'hidden',
                    child: Text('Скрытые и недоступные'),
                  ),
                  if (!reading)
                    const PopupMenuItem(
                      value: 'audio',
                      child: Text('Добавить аудиофайлы…'),
                    ),
                  PopupMenuItem(
                    value: 'export',
                    child: Text('Экспорт Markdown'),
                  ),
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
      body: SafeArea(
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1480),
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _statusTabs(),
                        // A folder scan continues after its screen closes.
                        if (activeFolderScan.value case final scan?) ...[
                          const SizedBox(height: 12),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 820),
                            child: FolderScanPanel(progress: scan),
                          ),
                        ],
                        if (unavailableCount +
                                    (_statusCounts()['remote'] ?? 0) >
                                0 &&
                            widget.assets != null)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              key: const ValueKey('open-unavailable'),
                              onPressed: _openUnavailable,
                              icon: const Icon(
                                Icons.visibility_off_outlined,
                                size: 18,
                              ),
                              label: Text(
                                'Скрытые, недоступные и корзина: ${unavailableCount + (_statusCounts()['remote'] ?? 0)}',
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (books.isEmpty)
                          TextButton.icon(
                            onPressed: busy ? null : _addBook,
                            icon: const Icon(Icons.add),
                            label: const Text('Новая карточка без файла'),
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
                        TextField(
                          key: searchKey,
                          controller: searchController,
                          focusNode: searchFocus,
                          onChanged: _searchChanged,
                          decoration: InputDecoration(
                            hintText: 'Название, автор или серия',
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: searchController.text.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: 'Очистить поиск',
                                    icon: const Icon(Icons.close),
                                    onPressed: () {
                                      _searchDebounce?.cancel();
                                      searchController.clear();
                                      setState(() => query = '');
                                      searchFocus.requestFocus();
                                    },
                                  ),
                            filled: true,
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (reading && indexing)
                          const LinearProgressIndicator(),
                        _shelfToolbar(),
                        ..._activeFilters(),
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
                            liveCount == 0
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
                            liveCount == 0
                                ? 'Подключите папку или добавьте книгу.'
                                : 'Попробуйте изменить поиск или фильтр.',
                          ),
                        ],
                      ),
                    ),
                  ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  // Both display modes build only visible shelf rows/tiles.
                  sliver: SliverLayoutBuilder(
                    builder: (context, constraints) {
                      final width = constraints.crossAxisExtent;
                      if (!_useCovers(width)) {
                        return SliverList.builder(
                          itemCount: listed.length,
                          itemBuilder: (_, i) => Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _bookCard(listed[i]),
                          ),
                        );
                      }
                      final gap = width < 600 ? 12.0 : 18.0;
                      final columns = width < 300
                          ? 1
                          : (width / 210).floor().clamp(width < 900 ? 2 : 4, 8);
                      final scale =
                          MediaQuery.textScalerOf(context).scale(14) / 14;
                      final tile = (width - gap * (columns - 1)) / columns;
                      return SliverGrid.builder(
                        itemCount: listed.length,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          crossAxisSpacing: gap,
                          mainAxisSpacing: gap,
                          mainAxisExtent:
                              tile * (reading ? 1.5 : 1) +
                              (reading ? 160 : 184) * scale,
                        ),
                        itemBuilder: (_, i) => _bookTile(listed[i], tile),
                      );
                    },
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
    if (['finished', 'paused', 'abandoned'].contains(status)) return status;
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

  Future<void> _refreshReadingFolders() => _action(() async {
    if (widget.assets == null) return;
    final store = ReadingRoots(widget.assets!);
    for (final root in await store.list()) {
      if (selectedRoot == null || selectedRoot == root.key) {
        await store.connect(await rescanAudioFolder(root.path, books: true));
      }
    }
  });

  Future<void> _deletedBookInfo(LibraryRecord book) async {
    final add = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Файл книги удалён'),
        content: SingleChildScrollView(
          child: Text(
            '«${_title(book)}»\n\nПрогресс, заметки и статистика сохранены. Добавьте тот же файл заново или верните его в подключённую папку и обновите её. Файл с другим содержимым будет отдельной книгой.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Закрыть'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Добавить файл'),
          ),
        ],
      ),
    );
    if (add == true && mounted) await _importBook();
  }

  void _checkBookClosed(String id) {
    if (localAssets.any(
      (asset) => asset.bookId == id && openReaderHashes.contains(asset.hash),
    )) {
      throw StateError('Сначала закройте эту книгу');
    }
  }

  Future<void> _bookSource(LibraryRecord book) async {
    final canHide =
        widget.assets != null && !deletedReadingBooks.contains(book.id);
    final files = shelfSources.byBook[book.id] ?? <LocalAsset>[];
    final descriptor = shelfSources.shared[book.id];
    final connected = roots.where((r) => r.bookIds.contains(book.id)).toList();
    final peers = PeerSyncScope.of(context);
    final lines = <String>[
      if (files.isEmpty)
        descriptor == null
            ? 'Карточка без подключённого файла. Первоначальный источник не записан.'
            : 'Карточка участвует в синхронизации. Сам файл на этом устройстве не подключён. Обмен данными приложения переносит карточки и историю отдельно от файлов.',
      if (connected.isEmpty)
        'Связи с папкой библиотеки на этом устройстве нет.',
      for (final root in connected)
        'Папка библиотеки: ${root.title}\n${root.path}',
    ];
    for (final file in files) {
      bool available;
      try {
        available = await audioSourceExists(file.path);
      } catch (_) {
        available = false;
      }
      lines.add(
        '${widget.assets?.isManagedBookPath(file) == true ? 'Копия внутри приложения' : 'Подключённый файл'}: ${file.filename}\n${file.path}\n${available ? 'Доступен' : 'Нет доступа или файл отсутствует'} · ${file.bytes} байт',
      );
    }
    for (final raw in descriptor?['sources'] as List? ?? []) {
      final source = raw as Map;
      final folder = peers?.folders
          .where((f) => f.id == source['folder'])
          .firstOrNull;
      lines.add(
        'Источник в обмене: ${source['name']}\n${folder == null ? 'Общая папка на этом устройстве не подключена' : 'Общая папка: ${folder.name}'}${source['path'] == null ? '' : '\nПуть в общей папке: ${source['path']}'}',
      );
    }
    if (descriptor != null) {
      final origin = shelfSources.receivedFrom[shelfSources.sharedIds[book.id]];
      lines.add(
        origin == null
            ? 'Устройство первоначального импорта в старых данных не записано.'
            : 'Последняя передача карточки: ${origin['name']}\n${origin['receivedAt']}',
      );
      lines.add(
        'Карточка синхронизации сама по себе не означает наличие файла на телефоне или ПК.',
      );
    }
    final source = readingSourcePaths[book.id];
    if (source != null) {
      lines.add(
        'Последний подключённый источник: ${source['root']}\n${source['relativePath']}',
      );
    }
    if (!mounted) return;
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Источник и файл'),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: SelectableText(
              '${_title(book)}\n\n${lines.join('\n\n')}${canHide ? '\n\n«Скрыть с полки» скрывает карточку только на этом устройстве. Файлы, заметки и история сохраняются.' : ''}',
            ),
          ),
        ),
        actions: [
          if (files.isNotEmpty)
            TextButton(
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(this.context);
                try {
                  await Clipboard.setData(
                    ClipboardData(text: files.map((f) => f.path).join('\n')),
                  );
                  if (!mounted) return;
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(
                        files.length == 1
                            ? 'Путь скопирован'
                            : 'Пути скопированы',
                      ),
                    ),
                  );
                } catch (error) {
                  if (!mounted) return;
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(
                        'Не удалось скопировать путь: ${describeError(error)}',
                      ),
                    ),
                  );
                }
              },
              child: const Text('Копировать путь'),
            ),
          if (canHide)
            TextButton(
              onPressed: () => Navigator.pop(context, 'hide-book'),
              child: const Text('Скрыть с полки'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
    if (action != null && mounted) await _bookMenu(book, action);
  }

  Future<void> _bookMenu(LibraryRecord book, String value) async {
    if (value == 'source') {
      await _bookSource(book);
      return;
    }
    if (value == 'restore-deleted') {
      await _importBook();
      return;
    }
    if (value == 'delete-library-card') {
      final entry = obsidianLibrary.sourceDraft(book.id);
      if (entry == null || !isSeriesCatalogItem(entry.item)) return;
      await deleteLibraryCards(
        context,
        obsidianLibrary,
        [entry.item.id],
        fromTrash: isLibraryDeleted(entry.item),
        checkBookClosed: () => _checkBookClosed(book.id),
      );
      return;
    }
    if (value == 'hide-book' ||
        value == 'delete-book' ||
        value == 'reveal-book') {
      if (widget.assets == null) return;
      final audio = book.payload?['format'] == 'audio';
      final actions = audio
          ? AudioBookActions(widget.assets!)
          : ReadingBookActions(widget.assets!);
      if (value == 'reveal-book') {
        await _action(() => actions.reveal(book.id));
        return;
      }
      if (value == 'delete-book') {
        await _deleteBooks([book]);
        return;
      }
      await _action(() async {
        if (audio && widget.audio?.current?.bookId == book.id) {
          await widget.audio!.stop();
        }
        _checkBookClosed(book.id);
        await actions.hide(book.id);
      });
      if (value == 'hide-book' && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Книга скрыта с полки. Файл и история сохранены.',
            ),
            action: SnackBarAction(
              label: 'Вернуть',
              onPressed: () =>
                  _action(() => actions.hide(book.id, hidden: false)),
            ),
          ),
        );
      }
      return;
    }
    if (value == 'obsidian') {
      try {
        await _addToObsidian(book);
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Не удалось добавить в библиотеку: ${describeError(error)}',
              ),
            ),
          );
        }
      }
      return;
    }
    if (value == 'share') {
      await _action(() async {
        final files = book.payload!['format'] == 'audio'
            ? await widget.assets!.audioTracks(book.id)
            : shelfSources.byBook[book.id] ?? <LocalAsset>[];
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
            asset: shelfSources.first(book.id),
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
      final asset = shelfSources.first(book.id);
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
          'finishedAt': value == 'finished'
              ? (book.payload?['finishedAt'] ??
                    DateTime.now().toUtc().toIso8601String())
              : null,
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
              'finishedAt': value == 'finished'
                  ? ((prefs['overrides'] as Map?)?['finishedAt'] ??
                        DateTime.now().toUtc().toIso8601String())
                  : null,
            },
          });
        }
      });
    });
    await obsidianLibrary.reload();
  }

  Widget _bookCard(LibraryRecord book) {
    final audio = book.payload!['format'] == 'audio';
    final asset = shelfSources.first(book.id);
    final summary = audioSummaries[book.id];
    final selected = widget.audio?.current?.bookId == book.id;
    final scheme = Theme.of(context).colorScheme;
    final status = _status(book);
    final deleted = !audio && deletedReadingBooks.contains(book.id);
    final fraction = !audio
        ? _fraction(book)
        : summary?.total == null ||
              summary!.total! <= 0 ||
              summary.position == null
        ? null
        : (summary.position! / summary.total!).clamp(0.0, 1.0);
    final details = audio
        ? ''
        : [_textRemaining(book), _lastOpened(book)].nonNulls.join(' · ');
    return Material(
      key: ValueKey('book-card:${book.id}'),
      color: selected ? scheme.primaryContainer : scheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onLongPress: busy ? null : () => _toggleBook(book.id),
        onTap: busy
            ? null
            : selectedBooks.isNotEmpty
            ? () => _toggleBook(book.id)
            : deleted
            ? () => _deletedBookInfo(book)
            : asset == null
            ? () => _bookSource(book)
            : () => audio ? _openAudio(asset) : _openReader(asset),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 54,
                height: 81,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: audio && widget.assets != null
                            ? AudioCover(
                                key: ValueKey(
                                  '${book.id}:${_coverVersions[book.id]}',
                                ),
                                assets: widget.assets!,
                                bookId: book.id,
                              )
                            : !audio && _textInfo(book)['cover'] != null
                            ? Image.file(
                                File(_textInfo(book)['cover'] as String),
                                fit: BoxFit.cover,
                                cacheWidth: 160,
                                errorBuilder: (_, _, _) =>
                                    const Icon(Icons.menu_book, size: 28),
                              )
                            : ColoredBox(
                                color: scheme.surfaceContainerHighest,
                                child: Icon(
                                  audio
                                      ? Icons.headphones_outlined
                                      : Icons.auto_stories_outlined,
                                  size: 28,
                                  color: scheme.primary,
                                ),
                              ),
                      ),
                      if (selectedBooks.isNotEmpty)
                        Positioned(
                          top: 0,
                          left: 0,
                          child: Checkbox(
                            value: selectedBooks.contains(book.id),
                            onChanged: busy
                                ? null
                                : (_) => _toggleBook(book.id),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${bookPrefs[book.id]?['favorite'] == true ? '★ ' : ''}${_title(book)}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.book(scheme.onSurface, size: 17),
                    ),
                    if (_authors(book).isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          _authors(book),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    if (!audio && _textInfo(book)['series'] != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          '${_textInfo(book)['series']} ${_textInfo(book)['seriesNumber'] ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 10, color: scheme.primary),
                        ),
                      ),
                    if (!audio && asset == null)
                      const Text(
                        'Файл не подключён на этом устройстве',
                        style: TextStyle(fontSize: 11),
                      ),
                    const SizedBox(height: 9),
                    Wrap(
                      spacing: 12,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        ShelfStatus(
                          deleted ? 'deleted' : status,
                          activeLabel: reading ? 'Читаю' : 'Слушаю',
                        ),
                        Text(
                          !audio
                              ? '${formatLabel(book.payload!['format'] as String?)} · ${((fraction ?? 0) * 100).toStringAsFixed(1)}%'
                              : fraction == null
                              ? 'Аудиокнига'
                              : '${(fraction * 100).round()}% прослушано',
                          style: TextStyle(
                            fontSize: 10,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    if (audio && audioRemainingLabel(summary) != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          audioRemainingLabel(summary)!,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    if (!audio && !deleted && details.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          details,
                          key: ValueKey('book-details:${book.id}'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    if (fraction != null) ...[
                      const SizedBox(height: 9),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: fraction,
                          minHeight: 3,
                          color: status == 'finished'
                              ? scheme.onSurfaceVariant
                              : scheme.primary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 4),
              _bookMenuButton(book),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bookMenuButton(LibraryRecord book) {
    final audio = book.payload!['format'] == 'audio';
    final asset = shelfSources.first(book.id);
    final deleted = !audio && deletedReadingBooks.contains(book.id);
    return IconButton(
      tooltip: 'Действия с книгой',
      icon: const Icon(Icons.more_vert),
      onPressed: () async {
        final action = await showBookActionMenu(
          context: context,
          repository: widget.repository,
          title: _title(book),
          audio: audio,
          available: {
            if (deleted && widget.assets != null)
              'restore-deleted': 'Добавить файл заново',
            'obsidian':
                obsidianLibrary.sourceDraft(book.id) != null &&
                    isUnreadSeriesItem(
                      obsidianLibrary.sourceDraft(book.id)!.item,
                    ) &&
                    !isLibraryDeleted(
                      obsidianLibrary.sourceDraft(book.id)!.item,
                    )
                ? 'Карточка серии'
                : obsidianLibrary.forBook(book.id) == null ||
                      obsidianLibrary.forBook(book.id)!.state == 'removed' ||
                      (!isFinishedLibraryItem(
                            obsidianLibrary.forBook(book.id)!.item,
                          ) &&
                          obsidianLibrary
                                  .forBook(book.id)!
                                  .item
                                  .values['pepehub_auto_discovered'] !=
                              false)
                ? 'Добавить в библиотеку'
                : isLibraryDeleted(obsidianLibrary.forBook(book.id)!.item)
                ? 'Вернуть в библиотеку'
                : libraryState(obsidianLibrary.forBook(book.id)!),
            if (!deleted &&
                Platform.isAndroid &&
                widget.assets != null &&
                asset != null)
              'share': 'Поделиться файлом книги',
            'favorite': bookPrefs[book.id]?['favorite'] == true
                ? 'Убрать из избранного'
                : 'В избранное',
            'collections': 'Коллекции книги',
            if (obsidianLibrary.sourceDraft(book.id) case final entry?
                when isSeriesCatalogItem(entry.item))
              'delete-library-card': 'Удалить карточку библиотеки…',
            if (!audio) ...{
              'source': 'Источник и файл',
              if (widget.assets != null &&
                  asset != null &&
                  (!Platform.isAndroid ||
                      asset.path.startsWith('content:') ||
                      readingSourcePaths.containsKey(book.id)))
                'reveal-book': Platform.isAndroid
                    ? 'Показать папку файла'
                    : 'Показать в проводнике',
              'details': 'Карточка книги',
              'reading-plan': 'План чтения',
              if (!deleted && asset != null)
                'metadata': 'Обновить сведения из файла',
              if (widget.assets != null) ...{
                if (!deleted) 'hide-book': 'Скрыть с полки',
                'delete-book': 'Удалить…',
              },
            },
            'planned': 'Отметить новой',
            'active': 'Отметить начатой',
            'paused': 'Отложить',
            'abandoned': 'Отметить брошенной',
            'finished': 'Отметить завершённой',
            'session': 'Записать сессию',
            if (audio) ...{
              if (widget.assets != null) ...{
                'hide-book': 'Скрыть с полки',
                'delete-book': 'Удалить…',
              },
              'folder': 'Переименовать / переместить папку',
              'reconnect': 'Указать папку заново',
            },
          },
        );
        if (mounted && action != null) await _bookMenu(book, action);
      },
    );
  }

  List<Object?>? _countInputs;
  Map<String, int> _counts = {};
  Map<String, int> _statusCounts() {
    final inputs = <Object?>[
      books,
      reading,
      deletedReadingBooks,
      shelfSources,
      statusOverrides,
      readingPrefs,
    ];
    if (listEquals(inputs, _countInputs)) return _counts;
    final counts = <String, int>{};
    void add(String key) => counts[key] = (counts[key] ?? 0) + 1;
    for (final book in books) {
      if (deletedReadingBooks.contains(book.id)) {
        add('deleted');
      } else if (_remoteOnly(book)) {
        add('remote');
      } else {
        add('all');
        add(_status(book));
      }
    }
    _countInputs = inputs;
    return _counts = counts;
  }

  Widget _statusTabs() {
    final colors = PepeColors.of(context);
    final counts = _statusCounts();
    int count(String key) => counts[key] ?? 0;
    final labels = {
      'all': 'Все',
      'active': reading ? 'Читаю' : 'Слушаю',
      'planned': 'В планах',
      'paused': 'Отложены',
      'abandoned': 'Брошены',
      'finished': reading ? 'Прочитано' : 'Прослушано',
    };
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final entry in labels.entries)
              Semantics(
                button: true,
                selected: statusFilter == entry.key,
                child: InkWell(
                  key: ValueKey('status-tab:${entry.key}'),
                  onTap: () => setState(() {
                    statusFilter = entry.key;
                    selectedBooks.clear();
                  }),
                  child: Container(
                    height: 46,
                    margin: const EdgeInsets.only(right: 22),
                    decoration: BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          width: 3,
                          color: statusFilter == entry.key
                              ? colors.accent
                              : Colors.transparent,
                        ),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          entry.value,
                          style: TextStyle(
                            fontFamily: AppFonts.display,
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            letterSpacing: .3,
                            color: statusFilter == entry.key
                                ? colors.accent
                                : colors.muted,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${count(entry.key)}',
                          style: TextStyle(
                            fontSize: 13,
                            color: statusFilter == entry.key
                                ? colors.accent
                                : colors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _coverPlaceholder(bool audio, PepeColors colors) => ColoredBox(
    color: colors.raised,
    child: Center(
      child: Icon(
        audio ? Icons.headphones_outlined : Icons.auto_stories_outlined,
        size: 34,
        color: colors.muted,
      ),
    ),
  );

  /// Cover tile used on wide windows.
  Widget _bookTile(LibraryRecord book, double width) {
    final audio = book.payload!['format'] == 'audio';
    final asset = shelfSources.first(book.id);
    final summary = audioSummaries[book.id];
    final playing = widget.audio?.current?.bookId == book.id;
    final colors = PepeColors.of(context);
    final status = _status(book);
    final deleted = !audio && deletedReadingBooks.contains(book.id);
    final total = summary?.total, position = summary?.position;
    final double? fraction = !audio
        ? _fraction(book).clamp(0.0, 1.0)
        : total == null || position == null || total <= 0
        ? null
        : (position / total).clamp(0.0, 1.0);
    final cover = _textInfo(book)['cover'];
    return Material(
      key: ValueKey('book-card:${book.id}'),
      color: playing
          ? Color.lerp(colors.surface, colors.accent, .18)
          : colors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onLongPress: busy ? null : () => _toggleBook(book.id),
        onTap: busy
            ? null
            : selectedBooks.isNotEmpty
            ? () => _toggleBook(book.id)
            : deleted
            ? () => _deletedBookInfo(book)
            : asset == null
            ? () => _bookSource(book)
            : () => audio ? _openAudio(asset) : _openReader(asset),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: width * (audio ? 1 : 1.5),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  audio && widget.assets != null
                      ? AudioCover(
                          key: ValueKey(
                            'tile:${book.id}:${_coverVersions[book.id]}',
                          ),
                          assets: widget.assets!,
                          bookId: book.id,
                        )
                      : !audio && cover != null
                      ? Image.file(
                          File(cover as String),
                          fit: BoxFit.cover,
                          cacheWidth: (width * 2).round(),
                          errorBuilder: (_, _, _) =>
                              _coverPlaceholder(audio, colors),
                        )
                      : _coverPlaceholder(audio, colors),
                  if (selectedBooks.isNotEmpty)
                    Positioned(
                      top: 4,
                      left: 4,
                      child: Checkbox(
                        value: selectedBooks.contains(book.id),
                        onChanged: busy ? null : (_) => _toggleBook(book.id),
                      ),
                    ),
                  if (fraction != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(
                        value: fraction,
                        minHeight: 4,
                        color: status == 'finished'
                            ? colors.muted
                            : colors.accent,
                        backgroundColor: Colors.black.withValues(alpha: .4),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 2, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${bookPrefs[book.id]?['favorite'] == true ? '★ ' : ''}${_title(book)}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.book(colors.text, size: 15),
                    ),
                    if (_authors(book).isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          _authors(book),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: colors.muted),
                        ),
                      ),
                    if (audio && audioRemainingLabel(summary) != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          audioRemainingLabel(summary)!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: colors.muted),
                        ),
                      ),
                    if (!audio && !deleted && _textRemaining(book) != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          _textRemaining(book)!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: colors.muted),
                        ),
                      ),
                    const Spacer(),
                    Row(
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              Flexible(
                                child: ShelfStatus(
                                  deleted ? 'deleted' : status,
                                  activeLabel: reading ? 'Читаю' : 'Слушаю',
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                fraction == null
                                    ? (audio
                                          ? 'Аудио'
                                          : formatLabel(
                                              book.payload!['format']
                                                  as String?,
                                            ))
                                    : '${(fraction * 100).round()}%',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: colors.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        _bookMenuButton(book),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
