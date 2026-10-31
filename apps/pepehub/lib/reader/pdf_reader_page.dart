import 'dart:async';

import '../sync/peer/app_sync_usage.dart';

import 'reader_routes.dart';

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import '../data/repository.dart';
import '../media/asset_store.dart';
import 'pdf_support.dart';
import 'pdf_image_regions.dart';
import 'pdf_search_page.dart';
import 'pdf_view_limits.dart';
import 'reader_layout.dart';
import 'reader_appearance.dart';
import 'pdf_page_tools.dart';

import 'package:url_launcher/url_launcher.dart';

import 'reader_viewport.dart';
import 'reader_page.dart';
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

class PdfReaderPage extends StatefulWidget {
  final Repository repository;
  final LocalAsset asset;
  final ReadingNote? initialNote;
  const PdfReaderPage({
    super.key,
    required this.repository,
    required this.asset,
    this.initialNote,
  });
  @override
  State<PdfReaderPage> createState() => _PdfReaderPageState();
}

class _PdfReaderPageState extends State<PdfReaderPage>
    with WidgetsBindingObserver, RouteAware {
  final controller = PdfViewerController();
  late final imageRegions = PdfImageRegions(widget.asset.path);
  // Set in build; read by the page paint callback.
  bool darkPages = false;
  late final library = ReadingLibrary(widget.repository);
  late final Future<PdfDocumentRefDirect> initial = _initial();
  PdfDocument? document;
  ReaderDocument? textDocument;
  Map<String, dynamic> textIndex = {};
  bool axisLocked = false;
  bool cropMargins = false;
  bool followingLink = false;
  int pageFitGeneration = 0;
  int appearanceGeneration = 0;
  final contentBounds = PdfContentBounds();
  ({int page, Matrix4 matrix, bool addedHistory})? linkReturn;
  double? lockedX, lockedZoom;
  Future<void> textWork = Future.value();
  Future<void> indexWork = Future.value();
  bool indexing = false, preparingText = false;
  Timer? indexDelay;
  ReadingActivity? activity;
  ReaderPreferences preferences = const ReaderPreferences(mode: 'scroll');
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
  List<PdfOutlineNode> outline = [];
  final history = <int>[];
  final glyphs = <int, PdfPageText>{};
  final loadingGlyphs = <int>{};
  ({int page, int start, int end})? highlighted;
  int page = 1, count = 0, panels = 0;
  bool ready = false, foreground = true, fullscreen = false;
  bool navigating = false, finished = false, closing = false, allowPop = false;
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
  void Function()? _releaseSync;
  @override
  void initState() {
    super.initState();
    final releasePosition = AppSyncUsage.hold(
      widget.repository.db,
      'p:reader:${widget.asset.hash}',
    );
    final releaseNotes = AppSyncUsage.hold(
      widget.repository.db,
      'reading-notes',
    );
    _releaseSync = () {
      releasePosition();
      releaseNotes();
    };
    WidgetsBinding.instance.addObserver(this);
  }

  Future<PdfDocumentRefDirect> _initial() async {
    final opened = await openLocalPdf(widget.asset.path);
    document = opened;
    count = opened.pages.length;
    final saved = await library.value('reader:${widget.asset.hash}');
    final legacy =
        int.tryParse(await widget.repository.meta(positionKey) ?? '') ?? 1;
    page = (((saved['chapter'] as num?)?.toInt() ?? legacy - 1) + 1).clamp(
      1,
      count,
    );
    finished = saved['pdfFinished'] == true;
    for (final p in (saved['pdfHistory'] as List? ?? []).whereType<int>().take(
      20,
    )) {
      history.add(p.clamp(1, count));
    }
    preferences = await _storedPreferences() ?? preferences;
    notes = await library.notes(hash: widget.asset.hash);
    final card = await widget.repository.record(widget.asset.bookId);
    displayTitle = card == null
        ? widget.asset.filename
        : (await library.bookInfo(card, widget.asset.hash))['title'] as String?;
    // Opening must not materialize the text and glyphs of every page.
    textIndex = await library.value('reading-index:${widget.asset.hash}');
    if (textIndex['pdfPages'] != count) {
      await library.update('reading-index:${widget.asset.hash}', {
        'pdfPages': count,
      });
      textIndex['pdfPages'] = count;
    }
    final view = await library.value('pdf-view:${widget.asset.hash}');
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
    try {
      outline = await opened.loadOutline();
    } catch (_) {
      /* Page list remains available. */
    }
    final note = widget.initialNote;
    if (note != null && note.hash == widget.asset.hash) {
      history.add(page);
      page = (note.chapter + 1).clamp(1, count);
      highlighted = (page: page, start: note.start, end: note.end);
    }
    final tracker = _tracker();
    await tracker.start(_absolute(page));
    await tracker.pause('loading');
    activity = tracker;
    if (!mounted) {
      await tracker.close();
      throw StateError('Просмотрщик закрыт');
    }
    return PdfDocumentRefDirect(opened, autoDispose: false);
  }

  // Not under "reader:": that prefix holds JSON positions keyed by book hash,
  // and the library reads every "reader:*" value as a JSON object.
  static const _pdfModeKey = 'pdf-reader-mode';
  static const _legacyPdfModeKey = 'reader:pdf-mode';

  /// Shared reader appearance with the PDF's own page mode.
  Future<ReaderPreferences?> _storedPreferences() async {
    final raw = await widget.repository.meta('reader:appearance');
    final pdfMode =
        await widget.repository.meta(_pdfModeKey) ??
        await widget.repository.meta(_legacyPdfModeKey);
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
      if (mounted) setState(() => saveError = 'Статистика не сохранена: $e');
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
    activity?.pause('another_screen');
  }

  @override
  void didPopNext() {
    routeVisible = true;
    if (foreground && panels == 0 && ready) {
      activity?.resume();
      _prepareIndex();
    }
  }

  @override
  void dispose() {
    positionDelay?.cancel();
    final savedPosition = ready ? _save() : writes;
    indexDelay?.cancel();
    imageRegions.close();
    readerRoutes.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    if (fullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    Future.wait<void>([savedPosition, if (activity != null) activity!.close()])
        .then(
          (_) => _releaseSync?.call(),
          onError: (Object _, StackTrace _) => _releaseSync?.call(),
        );
    // Wait for text extraction before releasing the native document.
    initial
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .then((_) => indexWork)
        .then((_) => textWork)
        .then((_) => document?.dispose());
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
          if (mounted) setState(() => saveError = 'Позиция не сохранена: $e');
        });
    return writes;
  }

  void _changed(int? value) {
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
      bounds = await contentBounds.forPage(document!.pages[at - 1]);
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
    }
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
        if (mounted) setState(() => linkReturn = origin);
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
    await activity?.pause('panel');
    try {
      return mounted ? await open() : null;
    } finally {
      panels--;
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
    final text = await document!.pages[p - 1].loadStructuredText();
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
      _message('Не удалось сохранить заметку: $e');
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
      _message('Не удалось создать карточку: $e');
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
        onMore: params.dismissContextMenu,
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

  Widget _footer() {
    final pepe = PepeColors.of(context);
    final ink = Theme.of(context).colorScheme.onSurface;
    final value = (dragging ?? progress).clamp(0.0, 1.0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (saveError != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(saveError!, style: const TextStyle(color: Colors.red)),
          ),
        ReaderBottomPanel(
          child: ReaderProgressFooter(
            value: value,
            ink: ink,
            accent: pepe.accent,
            onChanged: !ready ? null : (v) => setState(() => dragging = v),
            onChangeCancel: () => setState(() => dragging = null),
            step: 1 / math.max(1, count),
            onChangeEnd: !ready
                ? null
                : (v) {
                    setState(() => dragging = null);
                    _go(_pageAtFraction(v));
                  },
            details: [
              Text(
                'Страница ${dragging == null ? page : _pageAtFraction(value)} / $count · ${(value * 100).floor()}%',
              ),
            ],
            actions: [
              IconButton(
                tooltip: 'Вернуться на прежнее место',
                visualDensity: VisualDensity.compact,
                onPressed: !ready || history.isEmpty && linkReturn == null
                    ? null
                    : () {
                        if (linkReturn != null) {
                          _returnFromPdfLink();
                          return;
                        }
                        final target = history.removeLast();
                        _go(target, remember: false);
                      },
                icon: const Icon(Icons.undo),
              ),
              IconButton(
                tooltip: 'Предыдущая страница',
                visualDensity: VisualDensity.compact,
                onPressed: !ready || page <= 1
                    ? null
                    : () => _go(page - 1, reading: true),
                icon: const Icon(Icons.chevron_left),
              ),
              IconButton(
                tooltip: page == count
                    ? 'Завершить последнюю страницу'
                    : 'Следующая страница',
                visualDensity: VisualDensity.compact,
                onPressed: !ready || finished
                    ? null
                    : () => page == count
                          ? _finish()
                          : _go(page + 1, reading: true),
                icon: Icon(page == count ? Icons.done : Icons.chevron_right),
              ),
              IconButton(
                tooltip: 'Цитаты и заметки',
                visualDensity: VisualDensity.compact,
                onPressed: ready ? _notes : null,
                icon: const Icon(Icons.bookmarks_outlined),
              ),
            ],
          ),
        ),
      ],
    );
  }

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
              _message('Не удалось показать выделение: $e');
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

  Future<void> _contents() async {
    final items = <({String title, int page, int depth})>[];
    void visit(List<PdfOutlineNode> nodes, int depth) {
      if (depth > 20 || items.length > 20000) return;
      for (final node in nodes) {
        if (node.dest != null) {
          items.add((
            title: node.title,
            page: node.dest!.pageNumber,
            depth: depth,
          ));
        }
        visit(node.children, depth + 1);
      }
    }

    visit(outline, 0);
    if (items.isEmpty) {
      for (var p = 1; p <= count; p++) {
        items.add((title: 'Страница $p', page: p, depth: 0));
      }
    }
    final selected = await _panel(
      () => showModalBottomSheet<int>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Column(
            children: [
              Text(
                outline.isEmpty ? 'Страницы PDF' : 'Оглавление PDF',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, i) {
                    final item = items[i];
                    return ListTile(
                      contentPadding: EdgeInsets.only(
                        left: 16 + item.depth * 12,
                        right: 16,
                      ),
                      title: Text(item.title),
                      trailing: Text('${item.page}'),
                      selected: item.page == page,
                      onTap: () => Navigator.pop(context, item.page),
                    );
                  },
                ),
              ),
            ],
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
      _message('Настройки не сохранены: $e');
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ready && modeChanged) {
        controller.goToPage(pageNumber: page, duration: Duration.zero);
      }
    });
  }

  Future<void> _textMode() async {
    if (preparingText) return;
    preparingText = true;
    await indexWork;
    try {
      await _openTextMode();
    } finally {
      preparingText = false;
      _prepareIndex();
    }
  }

  void _prepareIndex({bool afterOpening = false}) {
    if (!mounted ||
        closing ||
        indexing ||
        preparingText ||
        !ready ||
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
              !mounted ||
              closing ||
              preparingText ||
              panels > 0 ||
              !foreground ||
              !routeVisible,
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
          setState(() => saveError = 'Текстовая статистика PDF недоступна: $e');
        }
      } finally {
        indexing = false;
      }
    })();
  }

  Future<void> _openTextMode() async {
    if (textDocument == null) {
      var cancelled = false;
      final progress = ValueNotifier<int>(0);
      final preparing = pdfReadingDocument(
        document!,
        displayTitle ?? widget.asset.filename,
        cancelled: () => cancelled || !mounted,
        onProgress: (v) {
          if (!cancelled && mounted) progress.value = v;
        },
      );
      Object? failure;
      var completionRegistered = false;
      textWork = preparing
          .then((value) {
            if (!cancelled && mounted) textDocument = value;
          })
          .catchError((Object e) {
            failure = e;
          });
      await _panel(
        () => showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) {
            if (!completionRegistered) {
              completionRegistered = true;
              textWork.then((_) {
                if (!cancelled && dialogContext.mounted) {
                  final route = ModalRoute.of(dialogContext)!;
                  if (route.isCurrent) {
                    Navigator.pop(dialogContext);
                  } else {
                    Navigator.of(dialogContext).removeRoute(route);
                  }
                }
              });
            }
            return PopScope(
              canPop: false,
              child: AlertDialog(
                title: const Text('Подготовка текстового режима'),
                content: ValueListenableBuilder<int>(
                  valueListenable: progress,
                  builder: (_, value, _) => Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      LinearProgressIndicator(value: value / count),
                      Text('Страниц: $value / $count'),
                      const Text(
                        'Оригинал PDF можно читать без этой подготовки.',
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () {
                      cancelled = true;
                      Navigator.pop(dialogContext);
                    },
                    child: const Text('Отмена'),
                  ),
                ],
              ),
            );
          },
        ),
      );
      cancelled = true;
      // The notifier may still be referenced by one pending native read.
      await textWork;
      progress.dispose();
      if (!mounted || textDocument == null) {
        if (failure != null) _message('$failure');
        return;
      }
      if (textDocument!.texts.every((t) => t.trim().isEmpty)) {
        textDocument = null;
        _message('В PDF нет текстового слоя. Для текстового режима нужен OCR.');
        return;
      }
      // Keep the same structured UTF-16 coordinate system as saved quotations.
      final index = pdfTextIndex(textDocument!);
      await library.update('reading-index:${widget.asset.hash}', index);
      textIndex = index;
    }
    if (!mounted || !routeVisible) return;
    await _save();
    // End this session before another reader writes coverage for the same book.
    await activity?.close();
    final wasFullscreen = fullscreen;
    if (wasFullscreen) _fullscreen(false);
    await _panel(
      () => Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => ReaderPage(
            repository: widget.repository,
            asset: widget.asset,
            suppliedDocument: textDocument,
          ),
        ),
      ),
    );
    if (!mounted) return;
    final saved = await library.value('reader:${widget.asset.hash}');
    final fresh = await library.notes(hash: widget.asset.hash);
    final appearance = await _storedPreferences();
    if (!mounted) return;
    setState(() {
      notes = fresh;
      if (appearance != null) preferences = appearance;
    });
    final nextActivity = _tracker();
    final target = (((saved['chapter'] as num?)?.toInt() ?? page - 1) + 1)
        .clamp(1, count);
    await nextActivity.start(_absolute(target));
    if (!mounted) {
      await nextActivity.close();
      return;
    }
    activity = nextActivity;
    if (!foreground || !routeVisible) await nextActivity.pause('background');
    await _go(target);
    controller.invalidate();
    if (wasFullscreen) _fullscreen(true);
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
      _message('Настройка не сохранена: $e');
    }
  }

  void _fullscreen(bool value) {
    setState(() => fullscreen = value);
    SystemChrome.setEnabledSystemUIMode(
      value ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
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
    final dark = preferences.isDark(MediaQuery.platformBrightnessOf(context));
    final pepe = PepeColors.of(context);
    final background = dark
        ? pepe.background
        : preferences.palette == 'sepia'
        ? const Color(0xfff3e8d0)
        : const Color(0xfffafafa);
    final appTheme = Theme.of(context);
    final theme = appTheme.copyWith(
      brightness: dark ? Brightness.dark : Brightness.light,
    );
    return Theme(
      data: theme,
      child: PopScope(
        canPop: allowPop,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) {
            if (fullscreen) {
              _fullscreen(false);
            } else {
              _close();
            }
          }
        },
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
              if (ready && readerShortcutsAllowed(context)) _search();
            },
            const SingleActivator(LogicalKeyboardKey.keyD, control: true): () {
              if (ready && readerShortcutsAllowed(context)) _annotate();
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
              if (readerShortcutsAllowed(context)) _fullscreen(!fullscreen);
            },
            const SingleActivator(LogicalKeyboardKey.escape): () {
              if (fullscreen && readerShortcutsAllowed(context)) {
                _fullscreen(false);
              }
            },
          },
          child: Focus(
            autofocus: true,
            child: Scaffold(
              backgroundColor: background,
              resizeToAvoidBottomInset: false,
              appBar: fullscreen
                  ? null
                  : AppBar(
                      title: Text(displayTitle ?? widget.asset.filename),
                      actions: [
                        IconButton(
                          tooltip: 'Статистика чтения и журнал',
                          icon: const Icon(Icons.bar_chart_outlined),
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => ReadingStatisticsPage(
                                repository: widget.repository,
                                bookId: widget.asset.bookId,
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Поиск по книге',
                          onPressed: ready ? _search : null,
                          icon: const Icon(Icons.search),
                        ),
                        IconButton(
                          tooltip: axisLocked
                              ? 'Разблокировать масштаб и движение'
                              : 'Зафиксировать масштаб и горизонталь',
                          onPressed: ready ? _toggleAxisLock : null,
                          icon: Icon(axisLocked ? Icons.lock : Icons.lock_open),
                        ),
                        PopupMenuButton<String>(
                          enabled: ready,
                          onSelected: (v) {
                            switch (v) {
                              case 'contents':
                                _contents();
                              case 'notes':
                                _notes();
                              case 'bookmark':
                                _annotate();
                              case 'appearance':
                                _appearance();
                              case 'text':
                                _textMode();
                              case 'fullscreen':
                                _fullscreen(true);
                              case 'zoomIn':
                                if (axisLocked) {
                                  _message('Сначала снимите блокировку');
                                } else {
                                  controller.zoomUp();
                                }
                              case 'zoomOut':
                                if (axisLocked) {
                                  _message('Сначала снимите блокировку');
                                } else {
                                  controller.zoomDown();
                                }
                              case 'keyboard':
                                showReaderShortcuts(context, pdf: true);
                            }
                          },
                          itemBuilder: (_) => [
                            for (final e in {
                              'contents': 'Оглавление и страницы',
                              'notes': 'Цитаты и заметки',
                              'bookmark': 'Заметка к странице',
                              'appearance': 'Оформление',
                              'text': 'Текстовый режим',
                              'fullscreen': 'Полный экран',
                              'zoomIn': 'Увеличить масштаб',
                              'zoomOut': 'Уменьшить масштаб',
                              'keyboard': 'Горячие клавиши',
                            }.entries)
                              PopupMenuItem(
                                value: e.key,
                                child: Text(
                                  e.value,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
              body: Listener(
                onPointerDown: (_) => activity?.touch(),
                onPointerSignal: (_) => activity?.touch(),
                child: FutureBuilder<PdfDocumentRefDirect>(
                  future: initial,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return Center(
                        child: Text(
                          'Не удалось открыть PDF: ${snapshot.error}',
                        ),
                      );
                    }
                    if (!snapshot.hasData) {
                      return Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(),
                            const SizedBox(height: 16),
                            const Text('Открытие PDF…'),
                          ],
                        ),
                      );
                    }
                    final dark = preferences.isDark(
                      MediaQuery.platformBrightnessOf(context),
                    );
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
                        : const ColorFilter.mode(
                            Colors.transparent,
                            BlendMode.srcOver,
                          );
                    return LayoutBuilder(
                      builder: (context, constraints) => Stack(
                        children: [
                          ColorFiltered(
                            colorFilter: filter,
                            child: PdfViewer(
                              snapshot.data!,
                              controller: controller,
                              initialPageNumber: page,
                              params: PdfViewerParams(
                                onKey: (_, key, _) => _viewerKey(key),
                                textSelectionParams:
                                    const PdfTextSelectionParams(
                                      showContextMenuAutomatically: true,
                                      magnifier:
                                          PdfViewerSelectionMagnifierParams(
                                            enabled: false,
                                          ),
                                    ),
                                maxImageBytesCachedOnMemory: 24 * 1024 * 1024,
                                horizontalCacheExtent: 0,
                                verticalCacheExtent: .25,
                                getPageRenderingScale: (_, p, _, scale) =>
                                    pdfRenderScale(p.width, p.height, scale),
                                scaleEnabled: !axisLocked,
                                panAxis: axisLocked
                                    ? PanAxis.vertical
                                    : PanAxis.free,
                                normalizeMatrix:
                                    axisLocked &&
                                        lockedX != null &&
                                        lockedZoom != null
                                    ? (matrix, view, layout, _) =>
                                          lockedPdfMatrix(
                                            matrix,
                                            view,
                                            layout.documentSize,
                                            x: lockedX!,
                                            zoom: lockedZoom!,
                                          )
                                    : null,
                                calculateInitialPageNumber: (_, _) => page,
                                onViewerReady: (_, _) {
                                  if (!mounted) return;
                                  setState(() => ready = true);
                                  _prepareIndex();
                                  if (foreground &&
                                      routeVisible &&
                                      panels == 0) {
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
                                onPageChanged: _changed,
                                pagePaintCallbacks: [_paint],
                                layoutPages:
                                    axisLocked || preferences.mode == 'scroll'
                                    ? null
                                    : (pages, params) {
                                        final height =
                                            pages.fold(
                                              0.0,
                                              (h, p) => math.max(h, p.height),
                                            ) +
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
                                  if (details.type !=
                                          PdfViewerGeneralTapType.tap ||
                                      controller
                                          .textSelectionDelegate
                                          .hasSelectedText ||
                                      details.tapOn ==
                                          PdfViewerPart.selectedText) {
                                    return false;
                                  }
                                  switch (preferences.tapAt(
                                    details.localPosition.dx /
                                        constraints.maxWidth,
                                  )) {
                                    case 'previous':
                                      _go(page - 1, reading: true);
                                    case 'next':
                                      _go(page + 1, reading: true);
                                    case 'controls':
                                      _fullscreen(!fullscreen);
                                    default:
                                      return false;
                                  }
                                  return true;
                                },
                                buildContextMenu: (context, params) =>
                                    _selectionMenu(
                                      context,
                                      params,
                                      constraints.maxWidth,
                                    ),
                                linkHandlerParams: PdfLinkHandlerParams(
                                  enableAutoLinkDetection: false,
                                  onLinkTap: _followLink,
                                ),
                              ),
                            ),
                          ),
                          if (fullscreen)
                            Positioned(
                              top: 8,
                              right: 8,
                              child: SafeArea(
                                child: IconButton.filledTonal(
                                  tooltip: 'Выйти из полного экрана',
                                  onPressed: () => _fullscreen(false),
                                  icon: const Icon(Icons.fullscreen_exit),
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              bottomNavigationBar: fullscreen
                  ? null
                  : Material(
                      color: appTheme.scaffoldBackgroundColor,
                      child: SafeArea(child: _footer()),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
