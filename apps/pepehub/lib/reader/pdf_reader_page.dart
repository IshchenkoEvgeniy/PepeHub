import 'dart:async';

import 'reader_routes.dart';

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import '../data/repository.dart';
import '../media/asset_store.dart';
import 'pdf_support.dart';
import 'pdf_file_source.dart';
import 'pdf_image_regions.dart';
import 'pdf_search_page.dart';
import 'pdf_view_limits.dart';
import 'reader_layout.dart';
import 'reader_keep_awake.dart';
import 'reader_appearance.dart';
import 'pdf_page_tools.dart';

import 'package:url_launcher/url_launcher.dart';

import 'reader_bookmarks.dart';
import 'reader_bookmarks_page.dart';
import 'reader_contents.dart';
import 'reader_status_line.dart';
import 'reader_window.dart';
import 'reader_viewport.dart';
import 'reading_activity.dart';
import 'reading_library.dart';
import 'reading_log.dart';
import '../ui/reading_statistics_page.dart';
import 'reading_notes_page.dart';
import 'reader_shortcuts.dart';
import 'reader_progress_panel.dart';
import '../ui/app_theme.dart';
import '../vocabulary/vocabulary_editor.dart';
import '../vocabulary/vocabulary_repository.dart';
import '../diagnostics/user_message.dart';

typedef _PdfStoredState = ({
  Map<String, dynamic> position,
  int legacyPage,
  ReaderPreferences? preferences,
  List<ReadingNote> notes,
  String? title,
  Map<String, dynamic> textIndex,
  Map<String, dynamic> view,
});

class PdfReaderPage extends StatefulWidget {
  final Repository repository;
  final LocalAsset asset;
  final AssetStore? assets;
  final ReadingNote? initialNote;
  const PdfReaderPage({
    super.key,
    required this.repository,
    required this.asset,
    this.assets,
    this.initialNote,
  });
  @override
  State<PdfReaderPage> createState() => _PdfReaderPageState();
}

class _PdfReaderPageState extends State<PdfReaderPage>
    with WidgetsBindingObserver, RouteAware {
  final controller = PdfViewerController();
  PdfFileSource? fileSource;
  late final imageRegions = PdfImageRegions(
    fileSource?.path ?? widget.asset.path,
  );
  // Set in build; read by the page paint callback.
  bool darkPages = false;
  late final library = ReadingLibrary(widget.repository);
  late final Future<PdfDocumentRefDirect> initial = _initial();
  PdfDocument? document;
  Map<String, dynamic> textIndex = {};
  bool axisLocked = false;
  bool cropMargins = false;
  bool followingLink = false;
  int pageFitGeneration = 0;
  int appearanceGeneration = 0;
  final contentBounds = PdfContentBounds();
  ({int page, Matrix4 matrix, bool addedHistory})? linkReturn;
  double? lockedX, lockedZoom;
  Future<void> indexWork = Future.value();
  bool indexing = false;
  Timer? indexDelay;
  ReadingActivity? activity;
  Future<void> activityStart = Future.value();
  ReaderPreferences preferences = const ReaderPreferences(mode: 'scroll');
  final keepAwake = ReaderKeepAwake();
  void _pointerActivity(PointerEvent event) {
    if (event is PointerDownEvent) keepAwake.touch();
  }

  void _syncKeepAwake() {
    keepAwake.enabled = preferences.keepAwake && foreground && routeVisible;
    _syncWindow();
  }

  List<ReadingNote> _pageNotes = [];
  final notesByPage = <int, List<ReadingNote>>{};
  List<ReadingNote> get notes => _pageNotes;
  set notes(List<ReadingNote> value) {
    _pageNotes = value;
    notesByPage.clear();
    for (final note in value) {
      if (note.end > note.start) {
        (notesByPage[note.chapter + 1] ??= []).add(note);
      }
    }
  }

  Timer? positionDelay;
  String? _lastQueuedPosition;
  Future<List<PdfOutlineNode>>? outlineLoad;
  // Set once PdfViewer has measured every page; until then the PDFium worker
  // is reserved for the visible pages.
  bool pagesMeasured = false;
  final history = <int>[];
  final glyphs = <int, PdfPageText>{};
  final loadingGlyphs = <int>{};
  ({int page, int start, int end})? highlighted;
  int page = 1, count = 0, panels = 0;
  bool ready = false, foreground = true;
  bool navigating = false, finished = false, closing = false, allowPop = false;

  /// Header and footer float over the page, as in the text reader; a tap in
  /// the middle of the page shows them.
  bool controlsVisible = false;

  /// After a jump: a small «Вернуться» that fades on its own.
  bool jumpHint = false;
  Timer? jumpHintTimer;
  List<ReaderBookmark> bookmarks = [];
  bool savingBookmark = false;

  /// The outline flattened by page, for chapter names; read once, lazily.
  List<({String title, int page, int depth})>? outlineItems;
  late final readerWindow = ReaderWindow(onVolumeKey: _volumeKey);
  late final bookmarkStore = ReaderBookmarkStore(
    widget.repository,
    widget.asset.hash,
  );

  /// Height of the quiet line under the page.
  static const statusLineHeight = 26.0;
  String? saveError, displayTitle;
  Future<void> writes = Future.value();
  double? dragging;
  double get progress => readingFraction(
    {'pdfPages': count, ...textIndex},
    {
      'chapter': page - 1,
      'textOffset': finished ? _lastLength : 0,
      'pdfFinished': finished,
    },
  );
  String get positionKey => 'pdf:${widget.asset.hash}';
  @override
  void initState() {
    super.initState();
    // Any touch while reading extends the screen wake period.
    GestureBinding.instance.pointerRouter.addGlobalRoute(_pointerActivity);
    WidgetsBinding.instance.addObserver(this);
    // The page always fills the screen, as in the text reader.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    unawaited(_reloadBookmarks());
  }

  /// Volume keys turn pages only on the open book itself.
  void _syncWindow() {
    if (closing) return;
    readerWindow.configure(
      volumeKeys:
          preferences.volumeKeys &&
          ready &&
          foreground &&
          routeVisible &&
          panels == 0,
      navigationBar: preferences.systemNavigation,
    );
  }

  void _volumeKey(int direction) {
    if (!mounted || !ready || panels > 0 || !routeVisible) return;
    _go(page + direction, reading: true);
  }

  void _toggleControls() => setState(() => controlsVisible = !controlsVisible);

  void _showJumpHint() {
    jumpHintTimer?.cancel();
    jumpHint = true;
    jumpHintTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) setState(() => jumpHint = false);
    });
  }

  Future<void> _reloadBookmarks() async {
    try {
      final list = await bookmarkStore.list();
      if (mounted) setState(() => bookmarks = list);
    } catch (_) {
      // Marks are a convenience; the bookmarks page reports real errors.
    }
  }

  ReaderBookmark? get _bookmarkHere =>
      bookmarks.where((b) => b.chapter == page - 1).firstOrNull;

  /// Outline entry the page belongs to, or null without an outline.
  String? _chapterOf(int p) {
    final items = outlineItems;
    if (items == null || items.isEmpty) return null;
    String? title;
    for (final item in items) {
      if (item.page > p) break;
      title = item.title;
    }
    return title?.trim().isEmpty == true ? null : title?.trim();
  }

  Future<void> _loadOutlineItems() async {
    if (outlineItems != null) return;
    final outline = await _outline();
    final items = <({String title, int page, int depth})>[];
    void visit(List<PdfOutlineNode> nodes, int depth) {
      if (depth > 20 || items.length > 20000) return;
      for (final node in nodes) {
        final dest = node.dest;
        if (dest != null && dest.pageNumber >= 1 && dest.pageNumber <= count) {
          items.add((title: node.title, page: dest.pageNumber, depth: depth));
        }
        visit(node.children, depth + 1);
      }
    }

    visit(outline, 0);
    if (mounted) setState(() => outlineItems = items);
  }

  String _placeLabel(int p) {
    final chapter = _chapterOf(p);
    return 'стр. $p${chapter == null ? '' : ' · $chapter'}';
  }

  Future<void> _quickBookmark() async {
    if (savingBookmark || !ready) return;
    final at = page;
    setState(() => savingBookmark = true);
    try {
      await bookmarkStore.add(
        title: (_chapterOf(at) ?? 'Страница $at').characters
            .take(120)
            .toString(),
        chapter: at - 1,
        offset: 0,
      );
      await _reloadBookmarks();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          persist: false,
          content: const Text('Закладка сохранена'),
          action: SnackBarAction(label: 'Открыть', onPressed: _bookmarks),
        ),
      );
    } catch (e) {
      _message('Не удалось сохранить закладку: ${describeError(e)}');
    } finally {
      if (mounted) setState(() => savingBookmark = false);
    }
  }

  Future<void> _removeBookmark(ReaderBookmark bookmark) async {
    try {
      await bookmarkStore.delete(bookmark.id);
      await _reloadBookmarks();
      _message('Закладка удалена');
    } catch (e) {
      _message('Не удалось удалить закладку: ${describeError(e)}');
    }
  }

  Future<void> _bookmarks() async {
    if (!ready) return;
    try {
      final bookmark = await _panel(
        () => Navigator.push<ReaderBookmark>(
          context,
          MaterialPageRoute(
            builder: (_) => Theme(
              data: Theme.of(context),
              child: ReaderBookmarksPage(
                store: bookmarkStore,
                chapterTitles: [for (var p = 1; p <= count; p++) 'Страница $p'],
                describe: (b) => _placeLabel(b.chapter + 1),
                chapter: page - 1,
                offset: 0,
              ),
            ),
          ),
        ),
      );
      if (bookmark != null && mounted && bookmark.chapter < count) {
        await _go(bookmark.chapter + 1);
      }
    } finally {
      unawaited(_reloadBookmarks());
    }
  }

  /// Where «Вернуться» leads: back from a link, or the last jump.
  int get _returnPage => linkReturn?.page ?? history.last;

  void _undoJump() {
    jumpHintTimer?.cancel();
    jumpHint = false;
    if (linkReturn != null) {
      _returnFromPdfLink();
      return;
    }
    if (history.isEmpty) return;
    final target = history.removeLast();
    _go(target, remember: false);
  }

  Future<PdfDocument> _openDocument() async {
    if (!widget.asset.path.startsWith('content:')) {
      return openLocalPdf(widget.asset.path, progressive: true);
    }
    final assets = widget.assets ?? await AssetStore.open(widget.repository);
    fileSource = await PdfFileSource.open(widget.asset, assets);
    try {
      return await openLocalPdf(fileSource!.path, progressive: true);
    } catch (_) {
      if (!fileSource!.isDirect) rethrow;
      await fileSource!.close();
      fileSource = await PdfFileSource.open(
        widget.asset,
        assets,
        preferDirect: false,
      );
      return openLocalPdf(fileSource!.path, progressive: true);
    }
  }

  Future<PdfDocumentRefDirect> _initial() async {
    // PDFium parses only the first page here; PdfViewer measures the others
    // in the background, outward from the restored page. The stored reader
    // state is read from the database at the same time.
    final opening = await Future.wait<Object?>(
      [_openDocument(), _storedState()],
      cleanUp: (value) {
        if (value is PdfDocument) unawaited(value.dispose());
      },
    );
    final opened = opening[0] as PdfDocument;
    final stored = opening[1] as _PdfStoredState;
    document = opened;
    count = opened.pages.length;
    final saved = stored.position;
    page = (((saved['chapter'] as num?)?.toInt() ?? stored.legacyPage - 1) + 1)
        .clamp(1, count);
    finished = saved['pdfFinished'] == true;
    for (final p in (saved['pdfHistory'] as List? ?? []).whereType<int>().take(
      20,
    )) {
      history.add(p.clamp(1, count));
    }
    preferences = stored.preferences ?? preferences;
    notes = stored.notes;
    displayTitle = stored.title;
    // Opening must not materialize the text and glyphs of every page.
    textIndex = stored.textIndex;
    if (textIndex['pdfPages'] != count) {
      textIndex['pdfPages'] = count;
      writes = writes
          .then(
            (_) => library.update('reading-index:${widget.asset.hash}', {
              'pdfPages': count,
            }),
          )
          .catchError((Object error) {
            if (mounted) {
              setState(
                () => saveError = 'Индекс не сохранён: ${describeError(error)}',
              );
            }
          });
    }
    final view = stored.view;
    cropMargins = view['cropMargins'] == true;
    axisLocked = view['locked'] == true;
    lockedX = (view['x'] as num?)?.toDouble();
    lockedZoom = (view['zoom'] as num?)?.toDouble();
    if (lockedX?.isFinite != true ||
        lockedZoom?.isFinite != true ||
        (lockedZoom ?? 0) <= 0) {
      axisLocked = false;
      lockedX = lockedZoom = null;
    }
    if (!mounted) throw StateError('Просмотрщик закрыт');
    final note = widget.initialNote;
    if (note != null && note.hash == widget.asset.hash) {
      history.add(page);
      page = (note.chapter + 1).clamp(1, count);
      highlighted = (page: page, start: note.start, end: note.end);
    }
    return PdfDocumentRefDirect(opened, autoDispose: false);
  }

  /// Restore small metadata in one query, alongside notes and the book card.
  Future<_PdfStoredState> _storedState() async {
    final hash = widget.asset.hash;
    final keys = [
      'reader:$hash',
      positionKey,
      'reader:appearance',
      _pdfModeKey,
      _legacyPdfModeKey,
      'reading-index:$hash',
      'pdf-view:$hash',
      'reading-book:${widget.asset.bookId}',
    ];
    final values = await Future.wait<Object?>([
      widget.repository.db
          .customSelect(
            'SELECT key,value FROM metadata WHERE key IN (${List.filled(keys.length, '?').join(',')})',
            variables: keys.map(Variable.new).toList(),
          )
          .get()
          .then(
            (rows) => {
              for (final row in rows)
                row.read<String>('key'): row.read<String>('value'),
            },
          ),
      library.notes(hash: hash),
      widget.repository.record(widget.asset.bookId),
    ]);
    final raw = values[0] as Map<String, String>;
    Map<String, dynamic> value(String key) =>
        jsonDecode(raw[key] ?? '{}') as Map<String, dynamic>;
    final index = value('reading-index:$hash');
    final card = values[2] as LibraryRecord?;
    final overrides =
        value('reading-book:${widget.asset.bookId}')['overrides'] as Map?;
    return (
      position: value('reader:$hash'),
      legacyPage: int.tryParse(raw[positionKey] ?? '') ?? 1,
      preferences: _decodePreferences(raw),
      notes: values[1] as List<ReadingNote>,
      title:
          (overrides?['title'] ??
                  index['title'] ??
                  card?.payload?['title'] ??
                  widget.asset.filename)
              as String?,
      textIndex: index,
      view: value('pdf-view:$hash'),
    );
  }

  Future<void> _startActivity() async {
    final tracker = _tracker();
    try {
      await tracker.start(_absolute(page), waitForCheckpoint: false);
      activity = tracker;
      if (!mounted || closing) {
        await tracker.close();
      } else if (!foreground || !routeVisible || panels > 0) {
        await tracker.pause('panel');
      }
    } catch (error) {
      await tracker.close();
      if (mounted) {
        setState(
          () => saveError = 'Статистика не сохранена: ${describeError(error)}',
        );
      }
    }
  }

  /// The outline is read on the first request, not while the book opens:
  /// large books may have thousands of entries.
  Future<List<PdfOutlineNode>> _outline() => outlineLoad ??= (() async {
    try {
      return await document!.loadOutline();
    } catch (_) {
      return const <PdfOutlineNode>[]; // Page list remains available.
    }
  })();

  // Not under "reader:": that prefix holds JSON positions keyed by book hash,
  // and the library reads every "reader:*" value as a JSON object.
  static const _pdfModeKey = 'pdf-reader-mode';
  static const _legacyPdfModeKey = 'reader:pdf-mode';

  ReaderPreferences? _decodePreferences(Map<String, String> stored) {
    final raw = stored['reader:appearance'];
    final pdfMode = stored[_pdfModeKey] ?? stored[_legacyPdfModeKey];
    if (raw == null && pdfMode == null) return null;
    final restored = raw == null
        ? const ReaderPreferences()
        : ReaderPreferences.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    return restored.copy(
      mode: const ['pages', 'scroll'].contains(pdfMode)
          ? pdfMode
          : restored.mode == 'pages'
          ? 'pages'
          : 'scroll',
    );
  }

  ReadingActivity _tracker() => ReadingActivity(
    widget.repository,
    bookId: widget.asset.bookId,
    hash: widget.asset.hash,
    length: (textIndex['length'] as num?)?.toInt() ?? 0,
    export: ReadingLog(widget.repository).export,
    onError: (e) {
      if (mounted) {
        setState(
          () => saveError = 'Статистика не сохранена: ${describeError(e)}',
        );
      }
    },
  );
  int get _lastLength =>
      ((textIndex['lengths'] as List?)?.lastOrNull as num?)?.toInt() ?? 0;
  int _absolute(int p) {
    final starts = textIndex['starts'] as List? ?? [];
    return starts.length == count
        ? (starts[p.clamp(1, count) - 1] as num).toInt()
        : 0;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    _syncKeepAwake();
    if (foreground && routeVisible && ready && panels == 0) {
      activity?.resume();
      _prepareIndex();
    } else {
      if (ready) unawaited(_save());
      activity?.pause('background');
    }
  }

  bool routeVisible = true;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) readerRoutes.subscribe(this, route);
  }

  @override
  void didPushNext() {
    routeVisible = false;
    _syncKeepAwake();
    activity?.pause('another_screen');
  }

  @override
  void didPopNext() {
    routeVisible = true;
    _syncKeepAwake();
    if (foreground && panels == 0 && ready) {
      activity?.resume();
      _prepareIndex();
    }
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_pointerActivity);
    keepAwake.dispose();
    positionDelay?.cancel();
    final savedPosition = ready ? _save() : writes;
    indexDelay?.cancel();
    final regionsClosed = imageRegions.close();
    readerRoutes.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    jumpHintTimer?.cancel();
    readerWindow.reset();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    Future.wait<void>([
      savedPosition,
      activityStart.then((_) => activity?.close()),
    ]).ignore();
    // Wait for text extraction before releasing the native document.
    initial
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .then((_) => indexWork)
        .then((_) => document?.dispose())
        .whenComplete(() async {
          await regionsClosed;
          await fileSource?.close();
        });
    super.dispose();
  }

  Future<void> _save() {
    positionDelay?.cancel();
    positionDelay = null;
    final value = page;
    final snapshot = <String, dynamic>{
      'chapter': value - 1,
      'textOffset': finished ? _lastLength : 0,
      'pdfFinished': finished,
      'pdfHistory': history.toList(),
    };
    final signature = jsonEncode(snapshot);
    if (signature == _lastQueuedPosition) return writes;
    _lastQueuedPosition = signature;
    final json = jsonEncode({
      ...snapshot,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    });
    writes = writes
        .then(
          (_) => widget.repository.db.transaction(() async {
            await widget.repository.setMeta(positionKey, '$value');
            await widget.repository.setMeta(
              'reader:${widget.asset.hash}',
              json,
            );
          }),
        )
        .catchError((Object e) {
          _lastQueuedPosition = null;
          if (mounted) {
            setState(
              () => saveError = 'Позиция не сохранена: ${describeError(e)}',
            );
          }
        });
    return writes;
  }

  void _changed(int? value) {
    keepAwake.touch();
    if (value == null || !mounted || !ready || value == page) return;
    if (!navigating) {
      activity?.move(
        _absolute(value),
        jump: (value - page).abs() != 1,
        chapterEnded: value == page + 1,
        deferCheckpoint: true,
      );
    }
    setState(() {
      page = value;
      finished = false;
      // Reading moved on: the controls give way to the page.
      if (!navigating && dragging == null) controlsVisible = false;
    });
    positionDelay?.cancel();
    positionDelay = Timer(const Duration(seconds: 1), () => unawaited(_save()));
    if (cropMargins &&
        !axisLocked &&
        !navigating &&
        !followingLink &&
        panels == 0) {
      unawaited(_fitContent(page));
    }
  }

  Future<void> _fitContent(int at, {bool Function()? stillActive}) async {
    if (!ready || document == null || axisLocked) return;
    final generation = ++pageFitGeneration;
    Rect? bounds;
    try {
      bounds = await contentBounds.forPage(await loadedPdfPage(document!, at));
    } catch (_) {
      if (stillActive != null) rethrow;
      return;
    }
    if (!mounted ||
        !ready ||
        at != page ||
        generation != pageFitGeneration ||
        bounds == null ||
        stillActive?.call() == false) {
      return;
    }
    final layout = controller.layout.pageLayouts[at - 1];
    final rect = Rect.fromLTRB(
      layout.left + bounds.left * layout.width,
      layout.top + bounds.top * layout.height,
      layout.left + bounds.right * layout.width,
      layout.top + bounds.bottom * layout.height,
    );
    final zoom = (controller.viewSize.width - 16) / rect.width;
    await controller.goTo(
      controller.calcMatrixFor(
        Offset(
          rect.center.dx,
          rect.top + controller.viewSize.height / 2 / zoom,
        ),
        zoom: zoom,
      ),
      duration: Duration.zero,
    );
  }

  Future<void> _go(
    int value, {
    bool reading = false,
    bool remember = true,
    bool keepControls = false,
  }) async {
    if (!ready || navigating) return;
    value = value.clamp(1, count);
    if (value == page) {
      if (!reading) activity?.move(_absolute(value), jump: true);
      return;
    }
    if (remember && !reading) {
      linkReturn = null;
      history.add(page);
      if (history.length > 20) history.removeAt(0);
      _showJumpHint();
    }
    if (!keepControls) controlsVisible = false;
    activity?.move(
      _absolute(value),
      jump: !reading,
      chapterEnded: reading && value == page + 1,
    );
    navigating = true;
    try {
      setState(() {
        page = value;
        finished = false;
      });
      await controller.goToPage(pageNumber: value, duration: Duration.zero);
      if (cropMargins && !axisLocked && !followingLink) {
        await _fitContent(value);
      }
      await _save();
    } finally {
      navigating = false;
    }
  }

  Future<void> _followLink(PdfLink link) async {
    final dest = link.dest;
    if (dest != null) {
      if (!ready ||
          followingLink ||
          dest.pageNumber < 1 ||
          dest.pageNumber > count) {
        return;
      }
      final origin = (
        page: page,
        matrix: controller.value.clone(),
        addedHistory: dest.pageNumber != page,
      );
      followingLink = true;
      // An in-flight automatic margin fit must not replace the link's exact
      // destination or its saved return position.
      pageFitGeneration++;
      try {
        await _go(dest.pageNumber);
        if (!mounted || !ready) return;
        await controller.goTo(
          controller.calcMatrixForDest(dest),
          duration: Duration.zero,
        );
        if (mounted) {
          setState(() {
            linkReturn = origin;
            controlsVisible = false;
            _showJumpHint();
          });
        }
        await WidgetsBinding.instance.endOfFrame;
      } finally {
        followingLink = false;
      }
    } else if (link.url != null) {
      final uri = link.url!;
      await _panel(
        () => showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Внешняя ссылка'),
            content: SelectableText('$uri'),
            actions: [
              TextButton(
                onPressed: () => Clipboard.setData(ClipboardData(text: '$uri')),
                child: const Text('Копировать'),
              ),
              if (const ['http', 'https', 'mailto'].contains(uri.scheme))
                TextButton(
                  onPressed: () async {
                    Navigator.pop(context);
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  },
                  child: const Text('Открыть в браузере'),
                ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Закрыть'),
              ),
            ],
          ),
        ),
      );
    }
  }

  Future<void> _returnFromPdfLink() async {
    final target = linkReturn;
    if (target == null || followingLink) return;
    followingLink = true;
    pageFitGeneration++;
    try {
      setState(() => linkReturn = null);
      if (target.addedHistory &&
          history.isNotEmpty &&
          history.last == target.page) {
        history.removeLast();
      }
      await _go(target.page, remember: false);
      if (mounted && ready) {
        await controller.goTo(target.matrix, duration: Duration.zero);
        await WidgetsBinding.instance.endOfFrame;
      }
    } finally {
      followingLink = false;
    }
  }

  Future<T?> _panel<T>(Future<T?> Function() open) async {
    panels++;
    _syncWindow();
    await activity?.pause('panel');
    try {
      return mounted ? await open() : null;
    } finally {
      panels--;
      _syncWindow();
      if (mounted && foreground && routeVisible && panels == 0) {
        activity?.resume();
        _prepareIndex();
      }
    }
  }

  void _message(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _search() async {
    final hit = await _panel(
      () => Navigator.push<Map<String, dynamic>>(
        context,
        MaterialPageRoute(builder: (_) => PdfSearchPage(document: document!)),
      ),
    );
    if (hit != null && mounted) {
      await _reveal(
        (hit['chapter'] as int) + 1,
        hit['offset'] as int,
        hit['end'] as int,
      );
    }
  }

  Future<void> _reveal(int p, int start, int end) async {
    if (p < 1 || p > count) return;
    await _go(p);
    if (!mounted) return;
    setState(() => highlighted = (page: p, start: start, end: end));
    final text = await (await loadedPdfPage(document!, p)).loadStructuredText();
    if (!mounted || !ready) return;
    if (start >= 0 && end > start && end <= text.fullText.length) {
      await controller.goToRectInsidePage(
        pageNumber: p,
        rect: PdfPageTextRange(pageText: text, start: start, end: end).bounds,
        duration: Duration.zero,
      );
    }
    controller.invalidate();
  }

  Future<void> _notes() async {
    final selected = await _panel(
      () => Navigator.push<ReadingNote>(
        context,
        MaterialPageRoute(
          builder: (_) => ReadingNotesPage(
            repository: widget.repository,
            hash: widget.asset.hash,
          ),
        ),
      ),
    );
    final fresh = await library.notes(hash: widget.asset.hash);
    if (!mounted) return;
    setState(() => notes = fresh);
    controller.invalidate();
    if (selected != null) {
      await _reveal(selected.chapter + 1, selected.start, selected.end);
    }
  }

  Future<void> _annotate([
    PdfTextSelectionDelegate? selection,
    bool comment = true,
    String? color,
  ]) async {
    try {
      if (selection != null && !selection.isCopyAllowed) return;
      final ranges =
          await selection?.getSelectedTextRanges() ?? <PdfPageTextRange>[];
      final quote = ranges
          .map((r) => r.pageText.fullText.substring(r.start, r.end))
          .join('\n');
      if (quote.length > 100000) {
        _message('Выберите фрагмент до 100 000 знаков.');
        return;
      }
      selection?.clearTextSelection();
      final first = ranges.firstOrNull;
      final note = ReadingNote(
        id: uuid.v4(),
        bookId: widget.asset.bookId,
        hash: widget.asset.hash,
        bookTitle: displayTitle ?? widget.asset.filename,
        chapterTitle: 'Страница ${first?.pageNumber ?? page}',
        quote: quote,
        comment: '',
        color: color ?? preferences.highlightColor,
        updated: DateTime.now().toUtc().toIso8601String(),
        chapter: (first?.pageNumber ?? page) - 1,
        start: first?.start ?? 0,
        end: first?.end ?? 0,
      );
      final edited = comment
          ? await _panel(() => editReadingNote(context, note))
          : note;
      if (edited == null) return;
      await widget.repository.db.transaction(() async {
        if (ranges.isEmpty) {
          await library.saveNote(edited);
        } else {
          // One stable anchor per original page, also usable in reflow mode.
          for (final range in ranges) {
            await library.saveNote(
              ReadingNote.fromJson({
                ...edited.toJson(),
                'id': range == ranges.first ? edited.id : uuid.v4(),
                'chapter': range.pageNumber - 1,
                'chapterTitle': 'Страница ${range.pageNumber}',
                'start': range.start,
                'end': range.end,
                'quote': range.pageText.fullText.substring(
                  range.start,
                  range.end,
                ),
              }),
            );
          }
        }
        final raw = await widget.repository.meta('reader:appearance');
        final stored = raw == null
            ? const <String, dynamic>{}
            : jsonDecode(raw) as Map<String, dynamic>;
        await widget.repository.setMeta(
          'reader:appearance',
          jsonEncode({...stored, 'highlightColor': edited.color}),
        );
      });
      final fresh = await library.notes(hash: widget.asset.hash);
      if (!mounted) return;
      setState(() {
        notes = fresh;
        preferences = preferences.copy(highlightColor: edited.color);
      });
      controller.invalidate();
      _message(
        ranges.length > 1
            ? 'Цитата сохранена по страницам, с общим комментарием'
            : 'Заметка сохранена',
      );
    } catch (e) {
      _message('Не удалось сохранить заметку: ${describeError(e)}');
    }
  }

  Future<void> _anki(PdfTextSelectionDelegate selection) async {
    try {
      if (!selection.isCopyAllowed || !selection.hasSelectedText) return;
      final ranges = await selection.getSelectedTextRanges();
      final quote = ranges
          .map((r) => r.pageText.fullText.substring(r.start, r.end))
          .join('\n');
      if (quote.isEmpty) return;
      if (quote.length > 5000) {
        _message('Для карточки выберите до 5000 знаков.');
        return;
      }
      final source = VocabularySource(
        kind: 'book',
        title: displayTitle ?? widget.asset.filename,
        detail: 'Страница ${ranges.first.pageNumber}',
        mediaId: widget.asset.bookId,
        mediaVersion: widget.asset.hash,
      );
      await selection.clearTextSelection();
      if (!mounted) return;
      await _panel(
        () => Navigator.push<VocabularyCard>(
          context,
          MaterialPageRoute(
            builder: (_) => VocabularyEditorPage(
              repository: VocabularyRepository(widget.repository),
              source: source,
              initialFront: quote,
            ),
          ),
        ),
      );
    } catch (e) {
      _message('Не удалось создать карточку: ${describeError(e)}');
    }
  }

  Widget? _selectionMenu(
    BuildContext context,
    PdfViewerContextMenuBuilderParams params,
    double width,
  ) {
    final selection = params.textSelectionDelegate;
    if (!selection.hasSelectedText || !selection.isCopyAllowed) return null;
    // pdfrx otherwise wraps non-positioned builders in an unbounded Positioned.
    // The shared toolbar needs the bounded viewport to lay out and hit-test.
    return Positioned.fill(
      child: readerSelectionToolbar(
        context: context,
        width: width,
        anchors: TextSelectionToolbarAnchors(
          primaryAnchor: params.anchorA,
          secondaryAnchor: params.anchorB,
        ),
        onDismiss: params.dismissContextMenu,
        palette: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final color in noteColors.entries)
              IconButton(
                tooltip:
                    'Выделить: ${switch (color.key) {
                      'green' => 'зелёный',
                      'blue' => 'синий',
                      'pink' => 'розовый',
                      _ => 'жёлтый',
                    }}',
                onPressed: () {
                  params.dismissContextMenu();
                  _annotate(selection, false, color.key);
                },
                icon: DecoratedBox(
                  decoration: BoxDecoration(
                    color: color.value,
                    shape: BoxShape.circle,
                  ),
                  child: const SizedBox.square(dimension: 24),
                ),
              ),
          ],
        ),
        buttonItems: [
          ContextMenuButtonItem(
            type: ContextMenuButtonType.copy,
            onPressed: () {
              selection.copyTextSelection();
              params.dismissContextMenu();
            },
          ),
          ContextMenuButtonItem(
            label: 'Выделить',
            onPressed: () {
              params.dismissContextMenu();
              _annotate(selection, false);
            },
          ),
          ContextMenuButtonItem(
            label: 'Заметка',
            onPressed: () {
              params.dismissContextMenu();
              _annotate(selection);
            },
          ),
          ContextMenuButtonItem(
            label: 'Карточка Anki',
            onPressed: () {
              params.dismissContextMenu();
              _anki(selection);
            },
          ),
        ],
      ),
    );
  }

  int _pageAtFraction(double value) {
    final starts = textIndex['starts'] as List? ?? [];
    final length = (textIndex['length'] as num?)?.toInt() ?? 0;
    if (starts.length == count && length > 0) {
      final target = value * length;
      var low = 0, high = starts.length;
      while (low < high) {
        final mid = (low + high) >> 1;
        if ((starts[mid] as num) <= target) {
          low = mid + 1;
        } else {
          high = mid;
        }
      }
      return low.clamp(1, count);
    }
    return ((value * count).floor().clamp(0, count > 0 ? count - 1 : 0) + 1)
        .toInt();
  }

  /// Slides a control bar in from [from] and keeps it out of the way of taps
  /// while it is hidden.
  Widget _floating({
    required bool visible,
    required Offset from,
    required Widget child,
  }) => IgnorePointer(
    ignoring: !visible,
    child: AnimatedSlide(
      offset: visible ? Offset.zero : from,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 140),
        child: child,
      ),
    ),
  );

  String get _subtitle => _chapterOf(page) ?? 'Страница $page из $count';

  /// The header of the text reader: back, title and chapter, search,
  /// contents, appearance and «⋮» with the rest.
  Widget _header(BuildContext context, Color background, Color ink) {
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    Widget pill(String tooltip, String label, VoidCallback? onTap) => Tooltip(
      message: tooltip,
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          foregroundColor: ink.withValues(alpha: .62),
          shape: const StadiumBorder(),
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          textStyle: TextStyle(fontFamily: AppFonts.body, fontSize: 13),
        ),
        child: Text(label),
      ),
    );
    Widget icon(String tooltip, IconData data, VoidCallback? onTap) =>
        IconButton(
          tooltip: tooltip,
          color: ink.withValues(alpha: .85),
          onPressed: onTap,
          icon: Icon(data, size: 23),
        );
    final moreActions = PopupMenuButton<String>(
      key: const ValueKey('pdf-more'),
      tooltip: 'Другие действия',
      enabled: ready,
      iconColor: ink.withValues(alpha: .85),
      onSelected: (value) {
        switch (value) {
          case 'bookmark':
            _quickBookmark();
          case 'bookmarks':
            _bookmarks();
          case 'notes':
            _notes();
          case 'pageNote':
            _annotate();
          case 'lock':
            _toggleAxisLock();
          case 'highlights':
            _toggleHighlights();
          case 'finish':
            _finish();
          case 'statistics':
            _statistics();
          case 'keyboard':
            showReaderShortcuts(context, pdf: true);
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'bookmark',
          enabled: !savingBookmark,
          child: const Text('Добавить закладку'),
        ),
        const PopupMenuItem(value: 'bookmarks', child: Text('Закладки')),
        PopupMenuItem(
          value: 'notes',
          child: Text(notes.isEmpty ? 'Заметки' : 'Заметки · ${notes.length}'),
        ),
        const PopupMenuItem(
          value: 'pageNote',
          child: Text('Заметка к странице'),
        ),
        const PopupMenuDivider(),
        CheckedPopupMenuItem(
          value: 'lock',
          checked: axisLocked,
          child: const Text('Зафиксировать масштаб'),
        ),
        PopupMenuItem(
          value: 'highlights',
          child: Text(
            preferences.showHighlights
                ? 'Скрыть выделения'
                : 'Показать выделения',
          ),
        ),
        if (page == count && !finished)
          const PopupMenuItem(
            value: 'finish',
            child: Text('Отметить книгу прочитанной'),
          ),
        const PopupMenuItem(
          value: 'statistics',
          child: Text('Статистика чтения и журнал'),
        ),
        if (!readerTouchOnly)
          const PopupMenuItem(
            value: 'keyboard',
            child: Text('Горячие клавиши'),
          ),
      ],
    );
    final tools = wide
        ? <Widget>[
            pill('Оглавление', 'Оглавление', ready ? _contents : null),
            pill('Поиск по книге', 'Поиск', ready ? _search : null),
            pill('Оформление чтения', 'Aa', ready ? _appearance : null),
            pill(
              'Заметки книги',
              notes.isEmpty ? 'Заметки' : 'Заметки ${notes.length}',
              ready ? _notes : null,
            ),
            moreActions,
          ]
        : <Widget>[
            icon('Поиск по книге', Icons.search, ready ? _search : null),
            icon('Оглавление', Icons.toc, ready ? _contents : null),
            icon(
              'Оформление чтения',
              Icons.text_format,
              ready ? _appearance : null,
            ),
            moreActions,
          ];
    return Material(
      color: background,
      elevation: 2,
      shadowColor: Colors.black54,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 60,
          child: Row(
            children: [
              IconButton(
                tooltip: 'Закрыть книгу',
                color: ink,
                onPressed: _close,
                icon: const Icon(Icons.arrow_back),
              ),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayTitle ?? widget.asset.filename,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.book(ink, size: wide ? 20 : 17),
                    ),
                    Text(
                      _subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: AppFonts.body,
                        fontSize: 12,
                        color: ink.withValues(alpha: .6),
                      ),
                    ),
                  ],
                ),
              ),
              ...tools,
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    );
  }

  void _toggleHighlights() {
    setState(
      () => preferences = preferences.copy(
        showHighlights: !preferences.showHighlights,
      ),
    );
    controller.invalidate();
    unawaited(() async {
      try {
        final raw = await widget.repository.meta('reader:appearance');
        final stored = raw == null
            ? const <String, dynamic>{}
            : jsonDecode(raw) as Map<String, dynamic>;
        await widget.repository.setMeta(
          'reader:appearance',
          jsonEncode({...stored, 'showHighlights': preferences.showHighlights}),
        );
      } catch (e) {
        _message('Настройка не сохранена: ${describeError(e)}');
      }
    }());
  }

  void _statistics() => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => ReadingStatisticsPage(
        repository: widget.repository,
        bookId: widget.asset.bookId,
      ),
    ),
  );

  /// Outline chapters as ticks on the progress bar.
  List<double> get _ticks {
    final items = outlineItems;
    if (items == null || count <= 1) return const [];
    return [
      for (final item in items)
        if (item.depth == 0 && item.page > 1) _fractionOf(item.page),
    ];
  }

  double _fractionOf(int p) {
    final starts = textIndex['starts'] as List? ?? [];
    final length = (textIndex['length'] as num?)?.toInt() ?? 0;
    if (starts.length == count && length > 0) {
      return ((starts[p.clamp(1, count) - 1] as num) / length).clamp(0.0, 1.0);
    }
    return count == 0 ? 0 : ((p - 1) / count).clamp(0.0, 1.0);
  }

  /// The footer of the text reader: back, where you are, a bookmark, and
  /// the book's progress bar with bookmarks and notes on it.
  Widget _footer(BuildContext context, Color ink) {
    final accent = PepeColors.of(context).accent;
    final value = (dragging ?? progress).clamp(0.0, 1.0);
    final target = dragging == null ? page : _pageAtFraction(value);
    final here = dragging == null ? _bookmarkHere : null;
    final chapter = _chapterOf(target);
    final details = ['стр. $target из $count', ?chapter].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 48,
                child: history.isEmpty && linkReturn == null
                    ? null
                    : IconButton(
                        key: const ValueKey('reader-footer-back'),
                        tooltip: 'Вернуться на ${_placeLabel(_returnPage)}',
                        color: ink.withValues(alpha: .8),
                        onPressed: _undoJump,
                        icon: const Icon(Icons.undo),
                      ),
              ),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${(value * 100).toStringAsFixed(dragging == null ? 0 : 1)}%',
                      key: const ValueKey('reader-footer-place'),
                      style: TextStyle(
                        fontFamily: AppFonts.body,
                        fontSize: 19,
                        fontWeight: FontWeight.w600,
                        color: ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      details,
                      key: const ValueKey('pdf-footer-details'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: AppFonts.body,
                        fontSize: 12,
                        color: ink.withValues(alpha: .6),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 48,
                child: here == null
                    ? IconButton(
                        tooltip: 'Сохранить закладку',
                        color: ink.withValues(alpha: .8),
                        onPressed: savingBookmark || !ready
                            ? null
                            : _quickBookmark,
                        icon: const Icon(Icons.bookmark_add_outlined),
                      )
                    : IconButton(
                        key: const ValueKey('reader-footer-bookmarked'),
                        tooltip: 'Страница в закладках — убрать',
                        color: accent,
                        onPressed: () => _removeBookmark(here),
                        icon: const Icon(Icons.bookmark),
                      ),
              ),
            ],
          ),
          if (page == count && !finished && dragging == null)
            Center(
              child: TextButton.icon(
                onPressed: ready ? _finish : null,
                icon: const Icon(Icons.done),
                label: const Text('Отметить книгу прочитанной'),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ReaderProgressBar(
              value: value,
              ticks: _ticks,
              bookmarks: [
                for (final b in bookmarks) _fractionOf(b.chapter + 1),
              ],
              notes: [for (final n in notes) _fractionOf(n.chapter + 1)],
              ink: ink,
              accent: accent,
              enabled: ready,
              step: 1 / math.max(1, count),
              onChanged: (v) => setState(() => dragging = v),
              onChangeCancel: () => setState(() => dragging = null),
              onChangeEnd: (v) {
                setState(() => dragging = null);
                _go(_pageAtFraction(v), keepControls: true);
              },
            ),
          ),
        ],
      ),
    );
  }

  /// One quiet line under the page: battery, time, title, percent, pages.
  Widget _statusLine(Color ink) => ReaderStatusLine(
    title: displayTitle ?? widget.asset.filename,
    percent: '${(progress * 100).toStringAsFixed(2)}%',
    pages: '$page/$count',
    ink: ink,
    margin: 16,
    onTap: _toggleControls,
  );

  /// After a jump (contents, search, link, bookmark): a small way back that
  /// fades on its own.
  Widget _jumpBack(Color background, Color ink) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Material(
        key: const ValueKey('reader-jump-back'),
        color: Color.lerp(background, ink, .12),
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: _undoJump,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 7, 16, 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.undo, size: 18, color: ink.withValues(alpha: .8)),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    'Вернуться на ${_placeLabel(_returnPage)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: AppFonts.body,
                      fontSize: 13,
                      color: ink.withValues(alpha: .85),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  void _trimGlyphs() {
    if (!ready || glyphs.length <= 8) return;
    final visible = controller.visibleRect;
    trimPdfGlyphCache(glyphs, {
      for (final n in glyphs.keys)
        if (controller.layout.pageLayouts[n - 1].overlaps(visible)) n,
    });
  }

  void _paint(Canvas canvas, Rect rect, PdfPage pdfPage) {
    _trimGlyphs();
    if (darkPages) {
      // Undo the page inversion over photos and illustrations.
      final regions = imageRegions.regions(pdfPage.pageNumber, () {
        if (mounted && ready) controller.invalidate();
      });
      if (regions != null) PdfImageRegions.restore(canvas, rect, regions);
    }
    final relevant = preferences.showHighlights
        ? notesByPage[pdfPage.pageNumber] ?? const <ReadingNote>[]
        : const <ReadingNote>[];
    final hit = highlighted?.page == pdfPage.pageNumber ? highlighted : null;
    if (relevant.isEmpty && hit == null) return;
    final text = glyphs[pdfPage.pageNumber];
    if (text == null) {
      // A placeholder page has no text yet; the viewer repaints it once it is
      // measured. Caching its empty text would hide the highlights.
      if (!pdfPage.isLoaded) return;
      if (loadingGlyphs.add(pdfPage.pageNumber)) {
        pdfPage
            .loadStructuredText()
            .then((value) {
              if (!mounted) return;
              glyphs[pdfPage.pageNumber] = value;
              _trimGlyphs();
              controller.invalidate();
            })
            .catchError((Object e) {
              _message('Не удалось показать выделение: ${describeError(e)}');
            })
            .whenComplete(() => loadingGlyphs.remove(pdfPage.pageNumber));
      }
      return;
    }
    void draw(int start, int end, Color color) {
      if (start < 0 || end <= start || end > text.fullText.length) return;
      final range = PdfPageTextRange(pageText: text, start: start, end: end);
      for (final fragment in range.enumerateFragmentBoundingRects()) {
        canvas.drawRect(
          fragment.bounds
              .toRect(page: pdfPage, scaledPageSize: rect.size)
              .translate(rect.left, rect.top),
          Paint()..color = color.withValues(alpha: .4),
        );
      }
    }

    for (final note in relevant) {
      draw(note.start, note.end, noteColors[note.color] ?? Colors.amber);
    }
    if (hit != null) draw(hit.start, hit.end, Colors.orange);
  }

  /// The contents sheet of the text reader: the PDF outline with a search
  /// field, or the list of pages when the file has no outline.
  Future<void> _contents() async {
    await _loadOutlineItems();
    if (!mounted) return;
    final outline = outlineItems ?? const [];
    final items = outline.isNotEmpty
        ? outline
        : [
            for (var p = 1; p <= count; p++)
              (title: 'Страница $p', page: p, depth: 0),
          ];
    var current = 0;
    for (var i = 0; i < items.length; i++) {
      if (items[i].page <= page) current = i;
    }
    final titles = [for (final item in items) item.title];
    final selected = await _panel(
      () => showModalBottomSheet<int>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (context) => SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * .7,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      outline.isEmpty
                          ? 'Страницы · $count'
                          : 'Оглавление · ${outline.length}',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  Expanded(
                    child: ReaderContentsSearch(
                      titles: titles,
                      builder: (context, indexes) => ListView.builder(
                        itemCount: indexes.length,
                        itemBuilder: (context, row) {
                          final i = indexes[row];
                          final item = items[i];
                          return ListTile(
                            selected: i == current,
                            contentPadding: EdgeInsets.only(
                              left: 16 + item.depth * 14.0,
                              right: 16,
                            ),
                            title: Text(item.title),
                            trailing: Text('${item.page}'),
                            onTap: () => Navigator.pop(context, item.page),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (selected != null && mounted) await _go(selected);
  }

  Future<void> _appearance() async {
    final generation = ++appearanceGeneration;
    pageFitGeneration++;
    final original = preferences;
    final originalCrop = cropMargins;
    final originalMatrix = ready ? controller.value.clone() : null;
    final originalPage = page;
    final result = await _panel(
      () => showReaderAppearance(
        context,
        original,
        pdf: true,
        pdfModeLocked: axisLocked,
        onPreview: (value) {
          if (!mounted || generation != appearanceGeneration) return;
          final modeChanged = value.mode != preferences.mode;
          setState(
            () => preferences = axisLocked ? value.copy(mode: 'scroll') : value,
          );
          if (modeChanged) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && ready && generation == appearanceGeneration) {
                controller.goToPage(
                  pageNumber: originalPage,
                  duration: Duration.zero,
                );
              }
            });
          }
        },
        pdfPreview: (value) => ColorFiltered(
          colorFilter: value.isDark(MediaQuery.platformBrightnessOf(context))
              ? const ColorFilter.matrix([
                  -1,
                  0,
                  0,
                  0,
                  255,
                  0,
                  -1,
                  0,
                  0,
                  255,
                  0,
                  0,
                  -1,
                  0,
                  255,
                  0,
                  0,
                  0,
                  1,
                  0,
                ])
              : value.palette == 'sepia'
              ? const ColorFilter.mode(Color(0xfff3e8d0), BlendMode.modulate)
              : const ColorFilter.mode(Colors.transparent, BlendMode.srcOver),
          child: PdfPageView(
            document: document,
            pageNumber: originalPage,
            maximumDpi: 72,
          ),
        ),
        pdfPageTools: PdfPageTools(
          controller: controller,
          locked: axisLocked,
          page: originalPage,
          initialCrop: cropMargins,
          onToggleLock: () async {
            await _toggleAxisLock();
            return axisLocked;
          },
          onCrop: (value) async {
            if (value) {
              await _fitContent(
                originalPage,
                stillActive: () => generation == appearanceGeneration,
              );
            } else if (ready) {
              await controller.goTo(
                controller.calcMatrixFitWidthForPage(pageNumber: originalPage),
              );
            }
            if (mounted && generation == appearanceGeneration) {
              setState(() => cropMargins = value);
            }
          },
        ),
      ),
    );
    appearanceGeneration++;
    pageFitGeneration++;
    if (!mounted) return;
    if (result == null) {
      setState(() {
        preferences = original;
        cropMargins = originalCrop;
      });
      await WidgetsBinding.instance.endOfFrame;
      if (mounted && ready && originalMatrix != null) {
        followingLink = true;
        try {
          await controller.goTo(originalMatrix, duration: Duration.zero);
          await WidgetsBinding.instance.endOfFrame;
        } finally {
          followingLink = false;
        }
      }
      return;
    }
    final next = result;
    final modeChanged = next.mode != preferences.mode;
    setState(() => preferences = axisLocked ? next.copy(mode: 'scroll') : next);
    try {
      // Theme, highlights and tap zones are shared with the text reader, but
      // its page mode is not: PDF has only pages/scroll, the text reader also
      // has seamless/compact. Keep the text reader's mode intact.
      await widget.repository.db.transaction(() async {
        final raw = await widget.repository.meta('reader:appearance');
        final stored = raw == null
            ? <String, dynamic>{}
            : jsonDecode(raw) as Map<String, dynamic>;
        await widget.repository.setMeta(
          'reader:appearance',
          jsonEncode({
            ...stored,
            ...next.toJson(),
            'mode': stored['mode'] ?? const ReaderPreferences().mode,
          }),
        );
        await widget.repository.setMeta(_pdfModeKey, next.mode);
        await library.update('pdf-view:${widget.asset.hash}', {
          'cropMargins': cropMargins,
        });
        await widget.repository.db.customStatement(
          'DELETE FROM metadata WHERE key=?',
          [_legacyPdfModeKey],
        );
      });
    } catch (e) {
      _message('Настройки не сохранены: ${describeError(e)}');
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ready && modeChanged) {
        controller.goToPage(pageNumber: page, duration: Duration.zero);
      }
    });
  }

  void _prepareIndex({bool afterOpening = false}) {
    if (!mounted ||
        closing ||
        indexing ||
        !ready ||
        !pagesMeasured ||
        !foreground ||
        !routeVisible ||
        panels > 0 ||
        (textIndex['starts'] as List?)?.length == count) {
      return;
    }
    if (count > 100 && !afterOpening) {
      // Let the initial page become interactive before starting native reads.
      indexDelay ??= Timer(const Duration(milliseconds: 600), () {
        indexDelay = null;
        _prepareIndex(afterOpening: true);
      });
      return;
    }
    indexing = true;
    indexWork = (() async {
      try {
        final partialKey = 'reading-pdf-index-partial:${widget.asset.hash}';
        final partial = await library.value(partialKey);
        final index = await pdfStatisticsIndex(
          document!,
          partial: partial,
          onProgress: (index) => library.update(partialKey, index),
          cancelled: () =>
              !mounted || closing || panels > 0 || !foreground || !routeVisible,
        );
        if (index == null || !mounted || closing) return;
        await widget.repository.db.transaction(() async {
          await library.update('reading-index:${widget.asset.hash}', index);
          await widget.repository.db.customStatement(
            'DELETE FROM metadata WHERE key=?',
            [partialKey],
          );
        });
        // No coordinate change in an existing session; rebaseline in a new one.
        await activityStart;
        await activity?.close();
        if (!mounted || closing) return;
        setState(() => textIndex = index);
        final tracker = _tracker();
        activity = tracker;
        await tracker.start(_absolute(page));
        if (!mounted || closing) {
          await tracker.close();
        } else if (!foreground || !routeVisible || panels > 0) {
          await tracker.pause('panel');
        }
      } catch (e) {
        // The original PDF and page-based progress remain usable without text.
        if (mounted) {
          setState(
            () => saveError =
                'Текстовая статистика PDF недоступна: ${describeError(e)}',
          );
        }
      } finally {
        indexing = false;
      }
    })();
  }

  Future<void> _toggleAxisLock() async {
    if (!ready) return;
    if (axisLocked) {
      setState(() => axisLocked = false);
    } else {
      // When leaving horizontal page layout, retain the page-relative X/zoom.
      final currentRect = controller.layout.pageLayouts[page - 1];
      final relativeX = controller.centerPosition.dx - currentRect.left;
      final relativeY = controller.centerPosition.dy - currentRect.top;
      final zoom = controller.currentZoom;
      final vertical = preferences.mode == 'scroll';
      setState(() {
        preferences = preferences.copy(mode: 'scroll');
        if (vertical) {
          axisLocked = true;
          lockedX = controller.centerPosition.dx;
          lockedZoom = zoom;
        }
      });
      if (!vertical) {
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || !controller.isReady) return;
        final rect = controller.layout.pageLayouts[page - 1];
        setState(() {
          lockedX = rect.left + relativeX;
          lockedZoom = zoom;
          axisLocked = true;
        });
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
        controller.value = controller.calcMatrixFor(
          Offset(rect.left + relativeX, rect.top + relativeY),
          zoom: zoom,
        );
      }
    }
    try {
      await library.update('pdf-view:${widget.asset.hash}', {
        'locked': axisLocked,
        'x': lockedX,
        'zoom': lockedZoom,
      });
    } catch (e) {
      _message('Настройка не сохранена: ${describeError(e)}');
    }
  }

  Future<void> _finish() async {
    activity?.move(
      (textIndex['length'] as num?)?.toInt() ?? 0,
      chapterEnded: true,
    );
    setState(() => finished = true);
    await _save();
  }

  Future<void> _close() async {
    if (closing) return;
    closing = true;
    if (ready) await _save();
    await activityStart;
    await activity?.close();
    if (!mounted) return;
    setState(() => allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  void _keyZoom(bool increase) {
    if (!ready || !readerShortcutsAllowed(context)) return;
    if (axisLocked) {
      _message('Сначала снимите блокировку');
    } else if (increase) {
      controller.zoomUp();
    } else {
      controller.zoomDown();
    }
  }

  bool? _viewerKey(LogicalKeyboardKey key) {
    if (!ready || !readerShortcutsAllowed(context)) return null;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed || keyboard.isMetaPressed) {
      if (key == LogicalKeyboardKey.equal ||
          key == LogicalKeyboardKey.numpadAdd) {
        _keyZoom(true);
        return true;
      }
      if (key == LogicalKeyboardKey.minus ||
          key == LogicalKeyboardKey.numpadSubtract) {
        _keyZoom(false);
        return true;
      }
      return null; // Keep PDFium's copy and select-all bindings.
    }
    if (key == LogicalKeyboardKey.home || key == LogicalKeyboardKey.end) {
      _go(key == LogicalKeyboardKey.home ? 1 : count);
      return true;
    }
    if (key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.space) {
      final backwards =
          key == LogicalKeyboardKey.pageUp ||
          key == LogicalKeyboardKey.space && keyboard.isShiftPressed;
      _go(page + (backwards ? -1 : 1), reading: true);
      return true;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    _syncKeepAwake();
    final dark = preferences.isDark(MediaQuery.platformBrightnessOf(context));
    final pepe = PepeColors.of(context);
    final background = dark
        ? pepe.background
        : preferences.palette == 'sepia'
        ? const Color(0xfff3e8d0)
        : const Color(0xfffafafa);
    final foreground = dark
        ? Color.lerp(pepe.text, pepe.muted, .15)!
        : const Color(0xff302b24);
    final appTheme = Theme.of(context);
    final theme = appTheme.copyWith(
      brightness: dark ? Brightness.dark : Brightness.light,
    );
    final chromeBackground = appTheme.scaffoldBackgroundColor;
    final chromeInk = appTheme.colorScheme.onSurface;
    // The reading frame is fixed, as in the text reader: system bars stay
    // hidden and the controls float above the page.
    final insets = MediaQuery.viewPaddingOf(context);
    final topReserve = insets.top;
    final bottomReserve = insets.bottom + statusLineHeight;
    return Theme(
      data: theme,
      child: PopScope(
        canPop: allowPop,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          if (controlsVisible) {
            setState(() => controlsVisible = false);
          } else {
            _close();
          }
        },
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
              if (ready && readerShortcutsAllowed(context)) _search();
            },
            const SingleActivator(LogicalKeyboardKey.keyD, control: true): () {
              if (ready && readerShortcutsAllowed(context)) _quickBookmark();
            },
            const SingleActivator(LogicalKeyboardKey.keyB, control: true): () {
              if (ready && readerShortcutsAllowed(context)) _bookmarks();
            },
            const SingleActivator(LogicalKeyboardKey.pageDown): () =>
                _viewerKey(LogicalKeyboardKey.pageDown),
            const SingleActivator(LogicalKeyboardKey.pageUp): () =>
                _viewerKey(LogicalKeyboardKey.pageUp),
            const SingleActivator(LogicalKeyboardKey.space): () =>
                _viewerKey(LogicalKeyboardKey.space),
            const SingleActivator(LogicalKeyboardKey.space, shift: true): () =>
                _viewerKey(LogicalKeyboardKey.space),
            const SingleActivator(LogicalKeyboardKey.home): () =>
                _viewerKey(LogicalKeyboardKey.home),
            const SingleActivator(LogicalKeyboardKey.end): () =>
                _viewerKey(LogicalKeyboardKey.end),
            const SingleActivator(
              LogicalKeyboardKey.equal,
              control: true,
            ): () =>
                _keyZoom(true),
            const SingleActivator(
              LogicalKeyboardKey.equal,
              control: true,
              shift: true,
            ): () =>
                _keyZoom(true),
            const SingleActivator(
              LogicalKeyboardKey.minus,
              control: true,
            ): () =>
                _keyZoom(false),
            const SingleActivator(LogicalKeyboardKey.f11): () {
              if (readerShortcutsAllowed(context)) _toggleControls();
            },
            const SingleActivator(LogicalKeyboardKey.escape): () {
              if (controlsVisible && readerShortcutsAllowed(context)) {
                _toggleControls();
              }
            },
          },
          child: Focus(
            autofocus: true,
            child: Scaffold(
              backgroundColor: background,
              resizeToAvoidBottomInset: false,
              body: Listener(
                onPointerDown: (_) => activity?.touch(),
                onPointerSignal: (_) => activity?.touch(),
                child: FutureBuilder<PdfDocumentRefDirect>(
                  future: initial,
                  builder: (context, snapshot) {
                    final Widget pageArea;
                    if (snapshot.hasError) {
                      pageArea = Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'Не удалось открыть PDF: ${snapshot.error}',
                            style: TextStyle(color: foreground),
                          ),
                        ),
                      );
                    } else if (!snapshot.hasData) {
                      pageArea = Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(),
                            const SizedBox(height: 16),
                            Text(
                              'Открытие PDF…',
                              style: TextStyle(color: foreground),
                            ),
                          ],
                        ),
                      );
                    } else {
                      pageArea = _viewer(snapshot.data!, dark);
                    }
                    final failed = snapshot.hasError;
                    final showJumpBack =
                        jumpHint &&
                        !controlsVisible &&
                        (history.isNotEmpty || linkReturn != null);
                    final errors = [?saveError];
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        Padding(
                          padding: EdgeInsets.only(
                            top: topReserve,
                            bottom: bottomReserve,
                          ),
                          child: pageArea,
                        ),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: insets.bottom,
                          height: statusLineHeight,
                          child: _statusLine(foreground),
                        ),
                        // A bookmarked page carries a ribbon in its corner.
                        if (_bookmarkHere != null)
                          Positioned(
                            top: topReserve,
                            right: 6,
                            child: GestureDetector(
                              key: const ValueKey('reader-page-bookmark'),
                              onTap: _bookmarks,
                              child: Icon(
                                Icons.bookmark,
                                size: 22,
                                color: pepe.accent.withValues(alpha: .85),
                              ),
                            ),
                          ),
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: _floating(
                            // Without a document only the way out is useful.
                            visible: controlsVisible || failed,
                            from: const Offset(0, -1),
                            child: _header(
                              context,
                              chromeBackground,
                              chromeInk,
                            ),
                          ),
                        ),
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (showJumpBack)
                                _jumpBack(background, foreground),
                              for (final message in errors)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    8,
                                    0,
                                    8,
                                    8,
                                  ),
                                  child: Material(
                                    color: theme.colorScheme.surface,
                                    borderRadius: BorderRadius.circular(12),
                                    child: Padding(
                                      padding: const EdgeInsets.all(8),
                                      child: Text(
                                        message,
                                        style: TextStyle(
                                          color: theme.colorScheme.error,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              if (controlsVisible && !failed)
                                Material(
                                  key: const ValueKey('reader-footer'),
                                  color: chromeBackground,
                                  child: SafeArea(
                                    top: false,
                                    child: _footer(context, chromeInk),
                                  ),
                                )
                              else
                                SizedBox(height: bottomReserve),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _viewer(PdfDocumentRefDirect document, bool dark) {
    if (darkPages != dark) {
      darkPages = dark;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ready) controller.invalidate();
      });
    }
    final filter = dark
        ? const ColorFilter.matrix([
            -.82,
            0,
            0,
            0,
            235,
            0,
            -.82,
            0,
            0,
            232,
            0,
            0,
            -.82,
            0,
            225,
            0,
            0,
            0,
            1,
            0,
          ])
        : preferences.palette == 'sepia'
        ? const ColorFilter.matrix([
            .94,
            0,
            0,
            0,
            5,
            0,
            .89,
            0,
            0,
            4,
            0,
            0,
            .77,
            0,
            8,
            0,
            0,
            0,
            1,
            0,
          ])
        : const ColorFilter.mode(Colors.transparent, BlendMode.srcOver);
    return LayoutBuilder(
      builder: (context, constraints) => ColorFiltered(
        colorFilter: filter,
        child: PdfViewer(
          document,
          controller: controller,
          initialPageNumber: page,
          params: PdfViewerParams(
            // The reader's paper shows around the pages, as in the text
            // reader; the colour filter keeps it transparent.
            backgroundColor: Colors.transparent,
            onKey: (_, key, _) => _viewerKey(key),
            textSelectionParams: const PdfTextSelectionParams(
              showContextMenuAutomatically: true,
              magnifier: PdfViewerSelectionMagnifierParams(enabled: false),
            ),
            maxImageBytesCachedOnMemory: 24 * 1024 * 1024,
            horizontalCacheExtent: 0,
            verticalCacheExtent: .25,
            getPageRenderingScale: (_, p, _, scale) =>
                pdfRenderScale(p.width, p.height, scale),
            scaleEnabled: !axisLocked,
            panAxis: axisLocked ? PanAxis.vertical : PanAxis.free,
            normalizeMatrix: axisLocked && lockedX != null && lockedZoom != null
                ? (matrix, view, layout, _) => lockedPdfMatrix(
                    matrix,
                    view,
                    layout.documentSize,
                    x: lockedX!,
                    zoom: lockedZoom!,
                  )
                : null,
            calculateInitialPageNumber: (_, _) => page,
            onViewerReady: (_, _) {
              if (!mounted || ready) return;
              setState(() => ready = true);
              activityStart = _startActivity();
              _prepareIndex();
              if (foreground && routeVisible && panels == 0) {
                activity?.resume();
              }
              _save();
              final note = widget.initialNote;
              if (note != null) {
                _reveal(page, note.start, note.end);
              } else if (cropMargins && !axisLocked) {
                unawaited(_fitContent(page));
              }
            },
            onDocumentLoadFinished: (_, _) {
              if (!mounted) return;
              pagesMeasured = true;
              _prepareIndex();
              // Chapter names for the header, footer and progress ticks.
              unawaited(_loadOutlineItems());
            },
            onPageChanged: _changed,
            pagePaintCallbacks: [_paint],
            layoutPages: axisLocked || preferences.mode == 'scroll'
                ? null
                : (pages, params) {
                    final height =
                        pages.fold(0.0, (h, p) => math.max(h, p.height)) +
                        params.margin * 2;
                    var x = params.margin;
                    final layouts = <Rect>[];
                    for (final p in pages) {
                      layouts.add(
                        Rect.fromLTWH(
                          x,
                          (height - p.height) / 2,
                          p.width,
                          p.height,
                        ),
                      );
                      x += p.width + params.margin;
                    }
                    return PdfPageLayout(
                      pageLayouts: layouts,
                      documentSize: Size(x, height),
                    );
                  },
            onGeneralTap: (context, controller, details) {
              if (details.type != PdfViewerGeneralTapType.tap ||
                  controller.textSelectionDelegate.hasSelectedText ||
                  details.tapOn == PdfViewerPart.selectedText) {
                return false;
              }
              // With the controls open, any tap on the page hides them.
              if (controlsVisible) {
                setState(() => controlsVisible = false);
                return true;
              }
              switch (preferences.tapAt(
                details.localPosition.dx / constraints.maxWidth,
              )) {
                case 'previous':
                  _go(page - 1, reading: true);
                case 'next':
                  _go(page + 1, reading: true);
                case 'controls':
                  _toggleControls();
                default:
                  return false;
              }
              return true;
            },
            buildContextMenu: (context, params) =>
                _selectionMenu(context, params, constraints.maxWidth),
            linkHandlerParams: PdfLinkHandlerParams(
              enableAutoLinkDetection: false,
              onLinkTap: _followLink,
            ),
          ),
        ),
      ),
    );
  }
}
