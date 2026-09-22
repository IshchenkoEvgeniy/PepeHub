import 'dart:async';

import 'reader_routes.dart';

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';

import '../data/repository.dart';
import '../media/asset_store.dart';
import 'pdf_support.dart';
import 'pdf_search_page.dart';
import 'pdf_view_limits.dart';
import 'reader_layout.dart';
import 'reader_viewport.dart';
import 'reader_page.dart';
import 'reading_activity.dart';
import 'reading_library.dart';
import 'reading_log.dart';
import 'reading_notes_page.dart';

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
  late final library = ReadingLibrary(widget.repository);
  late final Future<PdfDocumentRefDirect> initial = _initial();
  PdfDocument? document;
  ReaderDocument? textDocument;
  Map<String, dynamic> textIndex = {};
  bool axisLocked = false;
  double? lockedX, lockedZoom;
  Future<void> textWork = Future.value();
  Future<void> indexWork = Future.value();
  bool indexing = false, preparingText = false;
  ReadingActivity? activity;
  ReaderPreferences preferences = const ReaderPreferences();
  List<ReadingNote> notes = [];
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
  @override
  void initState() {
    super.initState();
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
    final raw = await widget.repository.meta('reader:appearance');
    if (raw != null) preferences = ReaderPreferences.fromJson(jsonDecode(raw));
    notes = await library.notes(hash: widget.asset.hash);
    final card = await widget.repository.record(widget.asset.bookId);
    displayTitle = card == null
        ? widget.asset.filename
        : (await library.bookInfo(card, widget.asset.hash))['title'] as String?;
    // Opening must not materialize the text and glyphs of every page.
    textIndex = await library.value('reading-index:${widget.asset.hash}');
    await library.update('reading-index:${widget.asset.hash}', {
      'pdfPages': count,
    });
    final view = await library.value('pdf-view:${widget.asset.hash}');
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
    readerRoutes.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    if (fullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    activity?.close();
    // Wait for text extraction before releasing the native document.
    initial
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .then((_) => indexWork)
        .then((_) => textWork)
        .then((_) => document?.dispose());
    super.dispose();
  }

  Future<void> _save() {
    final value = page;
    final json = jsonEncode({
      'chapter': value - 1,
      'textOffset': finished ? _lastLength : 0,
      'pdfFinished': finished,
      'pdfHistory': history.toList(),
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
      );
    }
    setState(() {
      page = value;
      finished = false;
    });
    _save();
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
      await _save();
    } finally {
      navigating = false;
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

  Future<void> _annotate([PdfTextSelectionDelegate? selection]) async {
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
        color: 'yellow',
        updated: DateTime.now().toUtc().toIso8601String(),
        chapter: (first?.pageNumber ?? page) - 1,
        start: first?.start ?? 0,
        end: first?.end ?? 0,
      );
      final edited = await _panel(() => editReadingNote(context, note));
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
      });
      final fresh = await library.notes(hash: widget.asset.hash);
      if (!mounted) return;
      setState(() => notes = fresh);
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

  void _paint(Canvas canvas, Rect rect, PdfPage pdfPage) {
    final relevant = notes.where(
      (n) => n.chapter == pdfPage.pageNumber - 1 && n.end > n.start,
    );
    final hit = highlighted?.page == pdfPage.pageNumber ? highlighted : null;
    if (relevant.isEmpty && hit == null) return;
    final text = glyphs[pdfPage.pageNumber];
    if (text == null) {
      if (loadingGlyphs.add(pdfPage.pageNumber)) {
        pdfPage
            .loadStructuredText()
            .then((value) {
              if (!mounted) return;
              if (glyphs.length >= 8) glyphs.remove(glyphs.keys.first);
              glyphs[pdfPage.pageNumber] = value;
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
    final next = await _panel(
      () => showModalBottomSheet<ReaderPreferences>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (context) {
          var value = preferences;
          return StatefulBuilder(
            builder: (context, update) => SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Оформление PDF',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      initialValue: value.palette,
                      decoration: const InputDecoration(labelText: 'Тема'),
                      items: [
                        for (final e in {
                          'light': 'Светлая',
                          'dark': 'Тёмная (инверсия страниц)',
                          'sepia': 'Сепия',
                          'system': 'Системная',
                        }.entries)
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                      ],
                      onChanged: (v) =>
                          update(() => value = value.copy(palette: v)),
                    ),
                    DropdownButtonFormField<String>(
                      initialValue: value.mode,
                      decoration: const InputDecoration(labelText: 'Навигация'),
                      items: const [
                        DropdownMenuItem(
                          value: 'pages',
                          child: Text('Горизонтальные страницы'),
                        ),
                        DropdownMenuItem(
                          value: 'scroll',
                          child: Text('Вертикальная прокрутка'),
                        ),
                      ],
                      onChanged: (v) =>
                          update(() => value = value.copy(mode: v)),
                    ),
                    for (final zone in ['left', 'center', 'right'])
                      DropdownButtonFormField<String>(
                        initialValue: switch (zone) {
                          'left' => value.leftTap,
                          'right' => value.rightTap,
                          _ => value.centerTap,
                        },
                        decoration: InputDecoration(
                          labelText: switch (zone) {
                            'left' => 'Нажатие слева',
                            'right' => 'Нажатие справа',
                            _ => 'Нажатие в центре',
                          },
                        ),
                        items: [
                          for (final e in {
                            'previous': 'Назад',
                            'next': 'Вперёд',
                            'controls': 'Показать / скрыть панели',
                            'none': 'Без действия',
                          }.entries)
                            DropdownMenuItem(
                              value: e.key,
                              child: Text(e.value),
                            ),
                        ],
                        onChanged: (v) => update(
                          () => value = switch (zone) {
                            'left' => value.copy(leftTap: v),
                            'right' => value.copy(rightTap: v),
                            _ => value.copy(centerTap: v),
                          },
                        ),
                      ),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        'Шрифт, межстрочный интервал и поля доступны в текстовом режиме. В оригинале сохраняется вёрстка PDF; используйте масштаб.',
                      ),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, value),
                      child: const Text('Применить'),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    if (next == null || !mounted) return;
    setState(() => preferences = axisLocked ? next.copy(mode: 'scroll') : next);
    try {
      await widget.repository.setMeta(
        'reader:appearance',
        jsonEncode(next.toJson()),
      );
    } catch (e) {
      _message('Настройки не сохранены: $e');
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ready) {
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

  void _prepareIndex() {
    // Large documents must not decode every page alongside the visible page.
    // Existing indexes remain usable; text mode builds an index on demand.
    if (count > 100) return;
    if (!mounted ||
        closing ||
        indexing ||
        preparingText ||
        !ready ||
        !foreground ||
        !routeVisible ||
        (textIndex['starts'] as List?)?.length == count) {
      return;
    }
    indexing = true;
    indexWork = (() async {
      try {
        final index = await pdfStatisticsIndex(
          document!,
          cancelled: () =>
              !mounted ||
              closing ||
              preparingText ||
              !foreground ||
              !routeVisible,
        );
        if (index == null || !mounted || closing) return;
        await library.update('reading-index:${widget.asset.hash}', index);
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
    final appearance = await widget.repository.meta('reader:appearance');
    if (!mounted) return;
    setState(() {
      notes = fresh;
      if (appearance != null) {
        preferences = ReaderPreferences.fromJson(jsonDecode(appearance));
      }
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

  @override
  Widget build(BuildContext context) => PopScope(
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
    child: Scaffold(
      appBar: fullscreen
          ? null
          : AppBar(
              title: Text(displayTitle ?? widget.asset.filename),
              actions: [
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
                    }.entries)
                      PopupMenuItem(value: e.key, child: Text(e.value)),
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
                child: Text('Не удалось открыть PDF: ${snapshot.error}'),
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
            final dark =
                preferences.palette == 'dark' ||
                preferences.palette == 'system' &&
                    Theme.of(context).brightness == Brightness.dark;
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
              builder: (context, constraints) => Stack(
                children: [
                  ColorFiltered(
                    colorFilter: filter,
                    child: PdfViewer(
                      snapshot.data!,
                      controller: controller,
                      initialPageNumber: page,
                      params: PdfViewerParams(
                        textSelectionParams: const PdfTextSelectionParams(
                          showContextMenuAutomatically: true,
                          magnifier: PdfViewerSelectionMagnifierParams(
                            enabled: false,
                          ),
                        ),
                        maxImageBytesCachedOnMemory: 24 * 1024 * 1024,
                        horizontalCacheExtent: 0,
                        verticalCacheExtent: .25,
                        getPageRenderingScale: (_, p, _, scale) =>
                            pdfRenderScale(p.width, p.height, scale),
                        scaleEnabled: !axisLocked,
                        panAxis: axisLocked ? PanAxis.vertical : PanAxis.free,
                        normalizeMatrix:
                            axisLocked && lockedX != null && lockedZoom != null
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
                          if (!mounted) return;
                          setState(() => ready = true);
                          _prepareIndex();
                          if (foreground && routeVisible && panels == 0) {
                            activity?.resume();
                          }
                          _save();
                          final note = widget.initialNote;
                          if (note != null) _reveal(page, note.start, note.end);
                        },
                        onPageChanged: _changed,
                        pagePaintCallbacks: [_paint],
                        layoutPages: axisLocked || preferences.mode == 'scroll'
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
                          if (details.type != PdfViewerGeneralTapType.tap ||
                              controller
                                  .textSelectionDelegate
                                  .hasSelectedText ||
                              details.tapOn == PdfViewerPart.selectedText) {
                            return false;
                          }
                          switch (preferences.tapAt(
                            details.localPosition.dx / constraints.maxWidth,
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
                        customizeContextMenuItems: (params, items) {
                          if (params.textSelectionDelegate.isCopyAllowed &&
                              params.textSelectionDelegate.hasSelectedText) {
                            items.add(
                              ContextMenuButtonItem(
                                label: 'Цитата / заметка',
                                onPressed: () {
                                  params.dismissContextMenu();
                                  _annotate(params.textSelectionDelegate);
                                },
                              ),
                            );
                          }
                        },
                        buildContextMenu: (context, params) {
                          final selection = params.textSelectionDelegate;
                          if (!selection.hasSelectedText ||
                              !selection.isCopyAllowed) {
                            return null;
                          }
                          return readerSelectionToolbar(
                            context: context,
                            width: constraints.maxWidth,
                            anchors: TextSelectionToolbarAnchors(
                              primaryAnchor: Offset(
                                constraints.maxWidth / 2,
                                80,
                              ),
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
                                label: 'Цитата / заметка',
                                onPressed: () {
                                  params.dismissContextMenu();
                                  _annotate(selection);
                                },
                              ),
                            ],
                          );
                        },
                        linkHandlerParams: PdfLinkHandlerParams(
                          enableAutoLinkDetection: false,
                          onLinkTap: (link) {
                            if (link.dest != null) _go(link.dest!.pageNumber);
                          },
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
          : SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (saveError != null)
                    Text(
                      saveError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  if (ready)
                    Slider(
                      value: dragging ?? page.toDouble(),
                      min: 1,
                      max: math.max(2, count).toDouble(),
                      label: 'Страница $page',
                      onChanged: count <= 1
                          ? null
                          : (v) => setState(() => dragging = v),
                      onChangeEnd: count <= 1
                          ? null
                          : (v) {
                              setState(() => dragging = null);
                              _go(v.round());
                            },
                    ),
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'Вернуться на прежнее место',
                        onPressed: !ready || history.isEmpty
                            ? null
                            : () {
                                final target = history.removeLast();
                                _go(target, remember: false);
                              },
                        icon: const Icon(Icons.undo),
                      ),
                      IconButton(
                        tooltip: 'Предыдущая страница',
                        onPressed: !ready || page <= 1
                            ? null
                            : () => _go(page - 1, reading: true),
                        icon: const Icon(Icons.chevron_left),
                      ),
                      Expanded(
                        child: Text(
                          'Страница $page / $count · ${(progress * 100).floor()}%',
                          textAlign: TextAlign.center,
                        ),
                      ),
                      IconButton(
                        tooltip: page == count
                            ? 'Завершить последнюю страницу'
                            : 'Следующая страница',
                        onPressed: !ready || finished
                            ? null
                            : () => page == count
                                  ? _finish()
                                  : _go(page + 1, reading: true),
                        icon: Icon(
                          page == count ? Icons.done : Icons.chevron_right,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Цитаты и заметки',
                        onPressed: ready ? _notes : null,
                        icon: const Icon(Icons.bookmarks_outlined),
                      ),
                    ],
                  ),
                ],
              ),
            ),
    ),
  );
}
