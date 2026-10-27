import 'dart:async';

import '../sync/peer/app_sync_usage.dart';

import 'reader_routes.dart';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/repository.dart';
import '../media/asset_store.dart';
import 'text_book.dart';
import 'reader_layout.dart';
import 'reader_controls.dart';
import 'reader_search.dart';
import 'reader_bookmarks.dart';
import 'reader_bookmarks_page.dart';
import 'reader_contents.dart';
import 'reader_viewport.dart';
import '../vocabulary/vocabulary_editor.dart';
import '../vocabulary/vocabulary_repository.dart';
import 'reading_library.dart';
import 'reading_notes_page.dart';
import 'reading_activity.dart';
import 'reading_log.dart';
import '../ui/app_theme.dart';
import '../ui/reading_statistics_page.dart';
import 'epub.dart';
import 'reader_resources.dart';
import 'reader_rebase.dart';
import 'book_formats.dart';
import 'reader_layout_frame.dart';
import 'reading_daily_totals.dart';
import 'reader_shortcuts.dart';
import 'reader_progress_panel.dart';

class _SeamlessBook {
  final String text;
  final List<int> starts;
  final List<BookMarkup> markup;
  final List<BookIllustration> illustrations;
  final List<BookFootnote> footnotes;
  late final List<int> chapterBreaks = List.unmodifiable(starts.skip(1));

  _SeamlessBook(ReaderDocument document)
    : starts = _starts(document.texts),
      text = document.texts.join('\n\n'),
      markup = _markup(document),
      illustrations = _illustrations(document),
      footnotes = _footnotes(document);

  static List<int> _starts(List<String> texts) {
    var offset = 0;
    return [
      for (var i = 0; i < texts.length; i++)
        (() {
          final start = offset;
          offset += texts[i].length + (i + 1 < texts.length ? 2 : 0);
          return start;
        })(),
    ];
  }

  static List<BookMarkup> _markup(ReaderDocument document) {
    final starts = _starts(document.texts);
    return [
      for (var chapter = 0; chapter < document.book.chapters.length; chapter++)
        for (final value in document.book.chapters[chapter].markup)
          BookMarkup(
            starts[chapter] + value.start,
            starts[chapter] + value.end,
            heading: value.heading,
            depth: value.depth,
            bold: value.bold,
            italic: value.italic,
            code: value.code,
            href: value.href,
            anchor: value.anchor,
            block: value.block,
            marker: value.marker,
            align: value.align,
          ),
    ];
  }

  static List<BookIllustration> _illustrations(ReaderDocument document) {
    final starts = _starts(document.texts);
    return [
      for (var chapter = 0; chapter < document.book.chapters.length; chapter++)
        for (final value in document.book.chapters[chapter].illustrations)
          BookIllustration(
            value.label,
            value.bytes,
            offset: starts[chapter] + value.offset,
          ),
    ];
  }

  static List<BookFootnote> _footnotes(ReaderDocument document) {
    final starts = _starts(document.texts);
    return [
      for (var chapter = 0; chapter < document.book.chapters.length; chapter++)
        for (final value in document.book.chapters[chapter].footnotes)
          BookFootnote(
            value.label,
            value.text,
            starts[chapter] + value.start,
            starts[chapter] + value.end,
          ),
    ];
  }

  ({int chapter, int offset}) locate(int absolute) {
    final chapter = starts
        .lastIndexWhere((value) => value <= absolute)
        .clamp(0, starts.length - 1);
    return (chapter: chapter, offset: absolute - starts[chapter]);
  }
}

class ReaderPage extends StatefulWidget {
  final Repository repository;
  final LocalAsset asset;
  final ReadingNote? initialNote;
  final ReaderDocument? suppliedDocument;
  const ReaderPage({
    super.key,
    required this.repository,
    required this.asset,
    this.initialNote,
    this.suppliedDocument,
  });
  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage>
    with WidgetsBindingObserver, RouteAware {
  ReaderDocument? document;
  ReaderDocument? bookFlowDocument;
  _SeamlessBook? bookFlow;
  ReaderPreferences preferences = const ReaderPreferences();
  String? error, saveError;
  int chapter = 0, offset = 0, navigation = 0;
  int? highlightStart, highlightEnd, highlightChapter;
  final searchSession = ReaderSearchSession();
  int? searchIndex;
  bool searchOpen = false, loadingMoreHits = false;
  final moreSearchWorker = ReaderSearchWorker();
  bool savingBookmark = false;
  final history = <({int chapter, int offset})>[];
  ({int chapter, int offset})? linkReturn;
  ({int chapter, int offset})? pinnedChapter;
  Future<void> writes = Future.value();
  Timer? debounce;
  bool allowPop = false, closing = false, tocOpen = true;
  final todayReading = ValueNotifier<int?>(null);
  Timer? todayTimer;
  Future<void>? todayWork;
  final positionChanges = ValueNotifier(0);
  final panelPosition = ValueNotifier((chapter: 0, percent: 0));
  final noteChapter = ValueNotifier(0);
  ReaderDocument? _titlesDocument;
  List<String> _chapterTitles = const [];
  List<String> _titlesFor(ReaderDocument d) {
    if (!identical(d, _titlesDocument)) {
      _titlesDocument = d;
      _chapterTitles = List.unmodifiable(d.book.chapters.map((c) => c.title));
    }
    return _chapterTitles;
  }

  void _notifyPosition() {
    positionChanges.value++;
    noteChapter.value = chapter;
    final length = document!.texts[chapter].length;
    panelPosition.value = (
      chapter: chapter,
      percent: length == 0 ? 0 : (offset * 100 / length).round(),
    );
  }

  final dragProgress = ValueNotifier<double?>(null);
  final viewportController = ReaderViewportController();
  final screenGeometry = ReaderScreenGeometry();
  List<ReadingNote>? _cachedSourceNotes;
  _SeamlessBook? _cachedNotesFlow;
  List<ReadingNote> _cachedFlowNotes = const [];
  ReaderDocument? _tickDocument;
  List<double> _bookTicks = const [];
  List<ReadingNote> notes = [];
  ReadingActivity? activity;
  String? activityError, displayTitle;
  bool foreground = true, viewportReady = false;
  int panels = 0;
  bool fullscreen = false;
  int? rangeStart;
  late final library = ReadingLibrary(widget.repository);
  // Scrolling reports positions every 250 ms; reading statistics only need
  // the place where the text came to rest.
  late final settledMoves = SettledReadingMoves((at) => activity?.move(at));
  String get positionKey => 'reader:${widget.asset.hash}';

  _SeamlessBook _flowFor(ReaderDocument source) {
    if (!identical(bookFlowDocument, source)) {
      bookFlowDocument = source;
      bookFlow = _SeamlessBook(source);
    }
    return bookFlow!;
  }

  @override
  void initState() {
    super.initState();
    todayTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _loadToday(),
    );
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
    _load();
  }

  bool routeVisible = true;
  void Function()? _releaseSync;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) readerRoutes.subscribe(this, route);
  }

  @override
  void didPushNext() {
    settledMoves.flush();
    routeVisible = false;
    activity?.pause('another_screen');
  }

  @override
  void didPopNext() {
    routeVisible = true;
    if (foreground && panels == 0 && viewportReady) activity?.resume();
  }

  @override
  void dispose() {
    todayTimer?.cancel();
    todayReading.dispose();
    positionChanges.dispose();
    panelPosition.dispose();
    noteChapter.dispose();
    moreSearchWorker.cancel();
    dragProgress.dispose();
    readerRoutes.unsubscribe(this);
    if (fullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    WidgetsBinding.instance.removeObserver(this);
    debounce?.cancel();
    settledMoves.flush();
    Future.wait<void>([_save(), if (activity != null) activity!.close()]).then(
      (_) => _releaseSync?.call(),
      onError: (Object _, StackTrace _) => _releaseSync?.call(),
    );
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) {
      settledMoves.flush();
      activity?.pause('background');
    } else if (routeVisible && panels == 0 && viewportReady) {
      activity?.resume();
    }
    if (state != AppLifecycleState.resumed) {
      debounce?.cancel();
      _save();
    }
  }

  Future<void> _load() async {
    try {
      final parsed =
          widget.suppliedDocument ??
          ReaderDocument(
            await loadTextBook(widget.asset.path, widget.asset.filename),
          );
      if (widget.suppliedDocument == null) {
        await migrateReaderLayout(
          library,
          widget.asset.hash,
          parsed,
          () async => ReaderDocument(
            await loadTextBook(
              widget.asset.path,
              widget.asset.filename,
              legacyProjection: true,
              layout: 2,
            ),
          ),
          previous:
              const ['fb2', 'txt'].contains(bookFormat(widget.asset.filename))
              ? () async => ReaderDocument(
                  await loadTextBook(
                    widget.asset.path,
                    widget.asset.filename,
                    layout: 2,
                  ),
                )
              : null,
          prior: bookFormat(widget.asset.filename) == 'txt'
              ? () async => ReaderDocument(
                  await loadTextBook(
                    widget.asset.path,
                    widget.asset.filename,
                    layout: 3,
                  ),
                )
              : null,
          sourceLayout: bookFormat(widget.asset.filename) == 'txt'
              ? (layout) async => ReaderDocument(
                  await loadTextBook(
                    widget.asset.path,
                    widget.asset.filename,
                    layout: layout,
                  ),
                )
              : null,
        );
      }
      final raw = await widget.repository.meta(positionKey);
      final saved = raw == null
          ? <String, dynamic>{}
          : jsonDecode(raw) as Map<String, dynamic>;
      if (raw == null) {
        final recovered = await library.value(
          'reading-recovered-position:${widget.asset.hash}',
        );
        final absolute = (recovered['position'] as num?)?.toInt();
        if (absolute != null && parsed.length > 0) {
          final place = parsed.locate(
            (absolute / parsed.length).clamp(0.0, 1.0),
          );
          saved.addAll({'chapter': place.chapter, 'textOffset': place.offset});
        }
      }
      final appearance = await widget.repository.meta('reader:appearance');
      final savedNotes = await library.notes(hash: widget.asset.hash);
      final card = await widget.repository.record(widget.asset.bookId);
      final info = card == null
          ? <String, dynamic>{}
          : await library.bookInfo(card, widget.asset.hash);
      if (!mounted) return;
      setState(() {
        document = parsed;
        notes = savedNotes;
        displayTitle = info['title'] as String?;
        chapter = ((saved['chapter'] as num?)?.toInt() ?? 0).clamp(
          0,
          parsed.texts.length - 1,
        );
        offset =
            ((saved['textOffset'] as num?)?.toInt() ??
                    parsed.offset(
                      chapter,
                      (saved['paragraph'] as num?)?.toInt() ?? 0,
                      (saved['offset'] as num?)?.toInt() ?? 0,
                    ))
                .clamp(0, parsed.texts[chapter].length);
        preferences = appearance == null
            ? ReaderPreferences.fromJson({'size': saved['fontSize']})
            : ReaderPreferences.fromJson(
                jsonDecode(appearance) as Map<String, dynamic>,
              );
        final savedSearch = saved['search'];
        if (savedSearch is Map) {
          searchSession.query = savedSearch['query'] is String
              ? savedSearch['query'] as String
              : '';
          searchSession.inCurrentChapter =
              savedSearch['inCurrentChapter'] == true;
        }
        for (final value in (saved['returnTo'] as List? ?? []).take(20)) {
          final c = (value['chapter'] as num).toInt().clamp(
            0,
            parsed.texts.length - 1,
          );
          history.add((
            chapter: c,
            offset: (value['offset'] as num).toInt().clamp(
              0,
              parsed.texts[c].length,
            ),
          ));
        }
        final pinned = saved['pinnedChapter'];
        if (pinned is Map &&
            pinned['chapter'] is num &&
            pinned['offset'] is num) {
          final c = (pinned['chapter'] as num).toInt().clamp(
            0,
            parsed.texts.length - 1,
          );
          pinnedChapter = (
            chapter: c,
            offset: (pinned['offset'] as num).toInt().clamp(
              0,
              parsed.texts[c].length,
            ),
          );
        }
      });
      if (widget.initialNote != null) {
        final refreshed = savedNotes.where(
          (n) => n.id == widget.initialNote!.id,
        );
        _openNote(refreshed.isEmpty ? widget.initialNote! : refreshed.first);
      }
      final tracker = ReadingActivity(
        widget.repository,
        bookId: widget.asset.bookId,
        hash: widget.asset.hash,
        length: parsed.length,
        export: ReadingLog(widget.repository).export,
        onError: (e) {
          if (mounted) {
            setState(
              () => activityError = 'Статистика или журнал не сохранены: $e',
            );
          }
        },
      );
      await tracker.start(parsed.starts[chapter] + offset);
      if (!mounted) {
        await tracker.close();
        return;
      }
      activity = tracker;
      _loadToday();
      if (!foreground || !routeVisible || panels > 0 || !viewportReady) {
        await tracker.pause('loading');
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> _save({bool appearance = false}) {
    final d = document;
    if (d == null) return writes;
    final p = d.paragraphAt(chapter, offset);
    final json = jsonEncode({
      'layoutVersion': 2,
      'chapter': chapter,
      'paragraph': p.paragraph,
      'offset': p.within,
      'textOffset': offset,
      'fontSize': preferences.size,
      'search': {
        'query': searchSession.query,
        'inCurrentChapter': searchSession.inCurrentChapter,
      },
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'returnTo': [
        for (final place in history)
          {'chapter': place.chapter, 'offset': place.offset},
      ],
      if (pinnedChapter != null)
        'pinnedChapter': {
          'chapter': pinnedChapter!.chapter,
          'offset': pinnedChapter!.offset,
        },
    });
    final settings = jsonEncode(preferences.toJson());
    writes = writes
        .then(
          (_) => widget.repository.db.transaction(() async {
            await widget.repository.setMeta(positionKey, json);
            if (appearance) {
              await widget.repository.setMeta('reader:appearance', settings);
            }
          }),
        )
        .then((_) {
          if (mounted && saveError != null) setState(() => saveError = null);
        })
        .catchError((Object e) {
          if (mounted) setState(() => saveError = 'Позиция не сохранена: $e');
        });
    return writes;
  }

  void _position(int value) {
    if (value == offset) return;
    final atPin =
        pinnedChapter?.chapter == chapter && pinnedChapter?.offset == offset;
    settledMoves.add(document!.starts[chapter] + value);
    offset = value;
    _notifyPosition();
    if (atPin !=
        (pinnedChapter?.chapter == chapter &&
            pinnedChapter?.offset == offset)) {
      setState(() {});
    }
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 300), _save);
  }

  void _seamlessPosition(_SeamlessBook flow, int absolute) {
    final place = flow.locate(absolute);
    final local = place.offset.clamp(0, document!.texts[place.chapter].length);
    if (place.chapter == chapter && local == offset) return;
    final atPin =
        pinnedChapter?.chapter == chapter && pinnedChapter?.offset == offset;
    settledMoves.add(document!.starts[place.chapter] + local);
    chapter = place.chapter;
    offset = local;
    _notifyPosition();
    if (atPin !=
        (pinnedChapter?.chapter == chapter &&
            pinnedChapter?.offset == offset)) {
      setState(() {});
    }
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 300), _save);
  }

  Future<void> _anki(
    BuildContext context,
    int start,
    int end,
    _SeamlessBook? flow,
  ) async {
    final d = document;
    if (d == null) return;
    final text = flow?.text ?? d.texts[chapter];
    if (start < 0 || end <= start || end > text.length) return;
    if (end - start > 5000) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Для карточки выберите до 5000 знаков.')),
      );
      return;
    }
    final first = flow?.locate(start);
    final noteChapter = first?.chapter ?? chapter;
    final source = VocabularySource(
      kind: 'book',
      title: displayTitle ?? d.book.title,
      detail:
          '${d.book.chapters[noteChapter].title} · позиция ${(first?.offset ?? start) + 1}',
      mediaId: widget.asset.bookId,
      mediaVersion: widget.asset.hash,
    );
    final quote = text.substring(start, end);
    await _pausePanel();
    if (!context.mounted) return;
    try {
      await Navigator.push<VocabularyCard>(
        context,
        MaterialPageRoute(
          builder: (_) => VocabularyEditorPage(
            repository: VocabularyRepository(widget.repository),
            source: source,
            initialFront: quote,
          ),
        ),
      );
    } finally {
      if (mounted) _resumePanel();
    }
  }

  Future<void> _seamlessAnnotate(
    BuildContext context,
    _SeamlessBook flow,
    int start,
    int end,
    bool comment, {
    String? color,
  }) async {
    final first = flow.locate(start);
    final last = flow.locate((end - 1).clamp(start, flow.text.length));
    if (first.chapter != last.chapter) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Выделение через границу глав пока не поддерживается.'),
        ),
      );
      return;
    }
    await _annotate(
      context,
      first.offset,
      last.offset + 1,
      comment,
      chapterIndex: first.chapter,
      color: color,
    );
  }

  void _openNote(ReadingNote note) {
    final d = document!;
    if (widget.suppliedDocument != null &&
        note.hash == widget.asset.hash &&
        note.chapter >= 0 &&
        note.chapter < d.texts.length &&
        note.start == 0 &&
        note.end == 0 &&
        note.quote.isEmpty) {
      _go(note.chapter, 0);
      return;
    }
    if (note.hash != widget.asset.hash ||
        note.chapter < 0 ||
        note.chapter >= d.texts.length ||
        note.start < 0 ||
        note.end > d.texts[note.chapter].length ||
        note.start >= note.end ||
        d.texts[note.chapter].substring(note.start, note.end) != note.quote) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Исходный фрагмент изменился. Цитата сохранена в заметке.',
          ),
        ),
      );
      return;
    }
    _go(note.chapter, note.start);
    setState(() {
      highlightChapter = note.chapter;
      highlightStart = note.start;
      highlightEnd = note.end;
    });
  }

  Future<void> _notes(BuildContext context) async {
    await _pausePanel();
    if (!context.mounted) return;
    final note = await Navigator.push<ReadingNote>(
      context,
      MaterialPageRoute(
        builder: (_) => ReadingNotesPage(
          repository: widget.repository,
          hash: widget.asset.hash,
        ),
      ),
    );
    _resumePanel();
    final saved = await library.notes(hash: widget.asset.hash);
    if (!mounted) return;
    setState(() => notes = saved);
    if (note != null) _openNote(note);
  }

  Future<void> _annotate(
    BuildContext context,
    int start,
    int end,
    bool comment, {
    int? chapterIndex,
    String? color,
  }) async {
    final d = document!;
    final noteChapter = chapterIndex ?? chapter;
    if (start < 0 || end <= start || end > d.texts[noteChapter].length) return;
    if (end - start > 100000) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Выберите фрагмент до 100 000 знаков.')),
      );
      return;
    }
    final note = ReadingNote(
      id: uuid.v4(),
      bookId: widget.asset.bookId,
      hash: widget.asset.hash,
      bookTitle: displayTitle ?? d.book.title,
      chapterTitle: d.book.chapters[noteChapter].title,
      quote: d.texts[noteChapter].substring(start, end),
      comment: '',
      color: color ?? preferences.highlightColor,
      updated: DateTime.now().toUtc().toIso8601String(),
      chapter: noteChapter,
      start: start,
      end: end,
    );
    if (comment) await _pausePanel();
    if (!context.mounted) return;
    final result = comment ? await editReadingNote(context, note) : note;
    if (comment) _resumePanel();
    if (result == null) return;
    try {
      await library.saveNote(result);
      final saved = await library.notes(hash: widget.asset.hash);
      if (!mounted) return;
      setState(() {
        notes = saved;
        preferences = preferences.copy(highlightColor: result.color);
      });
      await _save(appearance: true);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Выделение сохранено')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось сохранить заметку: $e')),
        );
      }
    }
  }

  void _go(int c, int at, {bool remember = true, bool reading = false}) {
    if (chapter == c && offset == at) return;
    settledMoves.flush();
    activity?.move(
      document!.starts[c] + at,
      jump: !reading,
      deferCheckpoint: !reading,
      chapterEnded: reading && c == chapter + 1,
    );
    debounce?.cancel();
    final wholeFlow = preferences.mode != 'scroll';
    final reuse =
        (wholeFlow || c == chapter) &&
        viewportController.seek(
          wholeFlow ? _flowFor(document!).starts[c] + at : at,
        );
    setState(() {
      if (remember) {
        history.add((chapter: chapter, offset: offset));
        if (history.length > 20) history.removeAt(0);
      }
      if (c != chapter) rangeStart = null;
      chapter = c;
      highlightStart = highlightEnd = null;
      offset = at.clamp(0, document!.texts[c].length);
      if (!reuse) navigation++;
    });
    _save();
  }

  Future<void> _close() async {
    if (closing) return;
    closing = true;
    debounce?.cancel();
    settledMoves.flush();
    await _save();
    if (!mounted) return;
    if (saveError != null) {
      // Never trap the reader in a book when the database refuses writes.
      final choice = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Позиция не сохранена'),
          content: Text(
            '$saveError\n\nЕсли выйти сейчас, книга откроется на последнем '
            'сохранённом месте.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Остаться'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'retry'),
              child: const Text('Повторить'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, 'leave'),
              child: const Text('Выйти без сохранения'),
            ),
          ],
        ),
      );
      closing = false;
      if (!mounted) return;
      if (choice == 'retry') return _close();
      if (choice != 'leave') return;
      closing = true;
    }
    await activity?.close();
    if (!mounted) return;
    setState(() => allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  void _toggleFullscreen() {
    setState(() => fullscreen = !fullscreen);
    SystemChrome.setEnabledSystemUIMode(
      fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  void _boundary(BuildContext context, int at, bool end) {
    if (!end || rangeStart == null) {
      setState(() => rangeStart = at);
      return;
    }
    final start = rangeStart!;
    if (at <= start) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Конец цитаты должен быть после её начала.'),
        ),
      );
      return;
    }
    setState(() => rangeStart = null);
    _annotate(context, start, at, true);
  }

  void _seamlessBoundary(
    BuildContext context,
    _SeamlessBook flow,
    int at,
    bool end,
  ) {
    if (!end || rangeStart == null) {
      setState(() => rangeStart = at);
      return;
    }
    final start = rangeStart!;
    final first = flow.locate(start);
    final last = flow.locate((at - 1).clamp(start, flow.text.length));
    if (at <= start || first.chapter != last.chapter) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Начало и конец цитаты должны быть в одной главе.'),
        ),
      );
      return;
    }
    setState(() => rangeStart = null);
    _annotate(
      context,
      first.offset,
      last.offset + 1,
      true,
      chapterIndex: first.chapter,
    );
  }

  List<ReadingNote> _seamlessNotes(_SeamlessBook flow) {
    if (identical(_cachedSourceNotes, notes) &&
        identical(_cachedNotesFlow, flow)) {
      return _cachedFlowNotes;
    }
    _cachedSourceNotes = notes;
    _cachedNotesFlow = flow;
    return _cachedFlowNotes = [
      for (final note in notes)
        if (note.chapter >= 0 && note.chapter < flow.starts.length)
          ReadingNote(
            id: note.id,
            bookId: note.bookId,
            hash: note.hash,
            bookTitle: note.bookTitle,
            chapterTitle: note.chapterTitle,
            quote: note.quote,
            comment: note.comment,
            color: note.color,
            updated: note.updated,
            chapter: note.chapter,
            start: flow.starts[note.chapter] + note.start,
            end: flow.starts[note.chapter] + note.end,
            tags: note.tags,
            characters: note.characters,
          ),
    ];
  }

  Future<void> _resources(BuildContext context) async {
    await _pausePanel();
    if (!context.mounted) return;
    try {
      await showChapterResources(context, document!.book.chapters[chapter]);
    } finally {
      _resumePanel();
    }
  }

  /// [source] is the chapter that contains the link. In whole-book modes it
  /// can differ from [chapter], which follows the top of the screen.
  Future<void> _openBookLink(String href, int source) async {
    final book = document?.book;
    if (book == null) return;
    source = source.clamp(0, book.chapters.length - 1);
    final target = bookResourcePath(book.chapters[source].path, href);
    final uri = Uri.tryParse(href);
    if (target != null) {
      final c = book.chapters.indexWhere((item) => item.path == target);
      if (c >= 0) {
        var id = uri?.fragment ?? '';
        try {
          id = Uri.decodeComponent(id);
        } catch (_) {
          /* Malformed escape: match the anchor literally. */
        }
        final anchor = book.chapters[c].markup
            .where((r) => r.anchor == id)
            .firstOrNull;
        final destination = anchor?.start ?? 0;
        if (c != chapter || destination != offset) {
          linkReturn = (chapter: chapter, offset: offset);
          _go(c, destination);
        }
        return;
      }
    }
    await _pausePanel();
    if (!mounted) return;
    try {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Ссылка'),
          content: SelectableText(href),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: href));
                Navigator.pop(context);
              },
              child: const Text('Копировать ссылку'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Закрыть'),
            ),
          ],
        ),
      );
    } finally {
      _resumePanel();
    }
  }

  void _returnFromLink() {
    final target = linkReturn;
    if (target == null) return;
    linkReturn = null;
    _go(target.chapter, target.offset, remember: false);
  }

  void _toggleChapterPin() {
    setState(() {
      pinnedChapter = pinnedChapter == null
          ? (chapter: chapter, offset: offset)
          : null;
    });
    _save();
  }

  void _returnToPinnedChapter() {
    final target = pinnedChapter;
    if (target != null) _go(target.chapter, target.offset);
  }

  Future<void> _bookmarks(BuildContext context) async {
    await _pausePanel();
    if (!context.mounted) return;
    try {
      final bookmark = await Navigator.push<ReaderBookmark>(
        context,
        MaterialPageRoute(
          builder: (_) => Theme(
            data: Theme.of(context),
            child: ReaderBookmarksPage(
              document: document,
              store: ReaderBookmarkStore(widget.repository, widget.asset.hash),
              chapterTitles: [for (final c in document!.book.chapters) c.title],
              chapter: chapter,
              offset: offset,
            ),
          ),
        ),
      );
      if (bookmark != null &&
          mounted &&
          bookmark.chapter < document!.texts.length) {
        _go(bookmark.chapter, bookmark.offset);
      }
    } finally {
      _resumePanel();
    }
  }

  Future<void> _quickBookmark() async {
    if (savingBookmark || document == null) return;
    viewportController.flushPosition();
    final savedChapter = chapter, savedOffset = offset;
    final title = document!.book.chapters[savedChapter].title.trim();
    setState(() => savingBookmark = true);
    try {
      await ReaderBookmarkStore(widget.repository, widget.asset.hash).add(
        title: (title.isEmpty ? 'Глава ${savedChapter + 1}' : title).characters
            .take(120)
            .toString(),
        chapter: savedChapter,
        offset: savedOffset,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Закладка сохранена'),
          action: SnackBarAction(
            label: 'Открыть',
            onPressed: () => _bookmarks(context),
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось сохранить закладку: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => savingBookmark = false);
    }
  }

  void _toggleHighlights() {
    setState(
      () => preferences = preferences.copy(
        showHighlights: !preferences.showHighlights,
      ),
    );
    _save(appearance: true);
  }

  Future<void> _footnote(BuildContext context, BookFootnote note) async {
    await _pausePanel();
    if (!context.mounted) return;
    try {
      await showBookFootnote(context, note);
    } finally {
      _resumePanel();
    }
  }

  Future<void> _settings(BuildContext context) async {
    await _pausePanel();
    if (!context.mounted) return;
    final original = preferences;
    final next = await showReaderSettings(
      context,
      original,
      onPreview: (value) {
        if (mounted) setState(() => preferences = value);
      },
    );
    _resumePanel();
    if (!mounted) return;
    setState(() {
      preferences = next ?? original;
    });
    await _save(appearance: true);
  }

  void _fontStep(double change) {
    if (!readerShortcutsAllowed(context)) return;
    viewportController.flushPosition();
    final size = (preferences.size + change).clamp(12.0, 56.0);
    if (size == preferences.size) return;
    setState(() => preferences = preferences.copy(size: size));
    _save(appearance: true);
  }

  Future<void> _contents(BuildContext context) async {
    await _pausePanel();
    if (!context.mounted) return;
    final chapters = document!.book.chapters;
    final selected = await showModalBottomSheet<int>(
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
                    'Оглавление · ${chapters.length}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                Expanded(
                  child: ReaderContentsSearch(
                    titles: [for (final c in chapters) c.title],
                    builder: (context, indexes) => ListView.builder(
                      itemCount: indexes.length,
                      itemBuilder: (context, row) {
                        final i = indexes[row];
                        return ListTile(
                          selected: i == chapter,
                          leading: Text('${i + 1}'),
                          title: Text(chapters[i].title),
                          onTap: () => Navigator.pop(context, i),
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
    );
    _resumePanel();
    if (selected != null && mounted) _go(selected, 0);
  }

  Future<void> _search(BuildContext context, {ThemeData? appearance}) async {
    moreSearchWorker.cancel();
    if (searchOpen) return;
    searchOpen = true;
    try {
      await _pausePanel();
      if (!context.mounted) return;
      final hit = await Navigator.push<Map<String, dynamic>>(
        context,
        MaterialPageRoute(
          builder: (_) => Theme(
            data: appearance ?? Theme.of(context),
            child: ReaderSearch(
              document: document!,
              currentChapter: chapter,
              session: searchSession,
            ),
          ),
        ),
      );
      if (!mounted) return;
      if (hit != null) {
        _revealSearchHit(searchSession.hits.indexOf(hit));
      } else {
        setState(() {
          searchIndex = null;
          highlightStart = highlightEnd = null;
        });
      }
      await _save();
    } finally {
      searchOpen = false;
      _resumePanel();
    }
  }

  Future<void> _nextSearchHit() async {
    final index = searchIndex;
    if (index == null || loadingMoreHits || searchOpen) return;
    if (index + 1 < searchSession.hits.length) {
      _revealSearchHit(index + 1);
      return;
    }
    if (!searchSession.hasMore || searchSession.hits.isEmpty) return;
    final hits = searchSession.hits;
    final query = searchSession.query;
    setState(() => loadingMoreHits = true);
    try {
      final batch = await moreSearchWorker.search(
        texts: document!.texts,
        query: query,
        chapter: searchSession.scannedChapter,
        after: hits.last,
      );
      if (!mounted ||
          batch == null ||
          searchSession.query != query ||
          !identical(searchSession.hits, hits)) {
        return;
      }
      setState(() {
        searchSession.hits = List.unmodifiable([...hits, ...batch.hits]);
        searchSession.hasMore = batch.hasMore;
      });
      if (!searchOpen && searchIndex == index && batch.hits.isNotEmpty) {
        _revealSearchHit(hits.length);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось продолжить поиск: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => loadingMoreHits = false);
    }
  }

  void _revealSearchHit(int index) {
    if (index < 0 || index >= searchSession.hits.length) return;
    final hit = searchSession.hits[index];
    _go(hit['chapter'] as int, hit['offset'] as int);
    setState(() {
      searchIndex = index;
      highlightChapter = hit['chapter'] as int;
      highlightStart = hit['offset'] as int;
      highlightEnd = hit['end'] as int;
    });
  }

  Widget _searchBar(BuildContext context) => Row(
    children: [
      IconButton(
        tooltip: 'Предыдущее совпадение',
        icon: const Icon(Icons.keyboard_arrow_up),
        onPressed: searchIndex! > 0
            ? () => _revealSearchHit(searchIndex! - 1)
            : null,
      ),
      Expanded(
        child: Text(
          '«${searchSession.query}» · ${searchIndex! + 1}/${searchSession.hits.length}${searchSession.hasMore ? '+' : ''}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      IconButton(
        tooltip: 'Следующее совпадение',
        icon: const Icon(Icons.keyboard_arrow_down),
        onPressed:
            loadingMoreHits ||
                !(searchIndex! + 1 < searchSession.hits.length ||
                    searchSession.hasMore)
            ? null
            : _nextSearchHit,
      ),
      IconButton(
        tooltip: 'Закрыть результаты поиска',
        icon: const Icon(Icons.close),
        onPressed: () => setState(() {
          searchIndex = null;
          highlightStart = highlightEnd = null;
        }),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final d = document;
    if (d == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Открытие книги')),
        body: Center(
          child: error == null
              ? const CircularProgressIndicator()
              : Padding(padding: const EdgeInsets.all(24), child: Text(error!)),
        ),
      );
    }
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
    final theme = ThemeData(
      useMaterial3: true,
      brightness: dark ? Brightness.dark : Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: dark ? pepe.accent : const Color(0xff557b70),
        brightness: dark ? Brightness.dark : Brightness.light,
        surface: background,
      ),
      scaffoldBackgroundColor: background,
      extensions: [pepe],
    );
    final wholeBookFlow = const [
      'seamless',
      'pages',
      'compact',
    ].contains(preferences.mode);
    final flow = wholeBookFlow ? _flowFor(d) : null;
    final pinnedAway =
        pinnedChapter != null &&
        (pinnedChapter!.chapter != chapter || pinnedChapter!.offset != offset);
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () =>
            readerShortcutsAllowed(context)
            ? _search(context, appearance: theme)
            : null,
        const SingleActivator(LogicalKeyboardKey.keyD, control: true): () {
          if (readerShortcutsAllowed(context)) _quickBookmark();
        },
        const SingleActivator(LogicalKeyboardKey.keyB, control: true): () {
          if (readerShortcutsAllowed(context)) _bookmarks(context);
        },
        const SingleActivator(LogicalKeyboardKey.equal, control: true): () =>
            _fontStep(2),
        const SingleActivator(
          LogicalKeyboardKey.equal,
          control: true,
          shift: true,
        ): () =>
            _fontStep(2),
        const SingleActivator(
          LogicalKeyboardKey.numpadAdd,
          control: true,
        ): () =>
            _fontStep(2),
        const SingleActivator(LogicalKeyboardKey.minus, control: true): () =>
            _fontStep(-2),
        const SingleActivator(
          LogicalKeyboardKey.numpadSubtract,
          control: true,
        ): () =>
            _fontStep(-2),
        const SingleActivator(LogicalKeyboardKey.f11): () {
          if (readerShortcutsAllowed(context)) _toggleFullscreen();
        },
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (fullscreen && readerShortcutsAllowed(context)) {
            _toggleFullscreen();
          }
        },
        const SingleActivator(LogicalKeyboardKey.f3): () {
          if (readerShortcutsAllowed(context) && searchIndex != null) {
            _nextSearchHit();
          }
        },
        const SingleActivator(LogicalKeyboardKey.f3, shift: true): () {
          if (readerShortcutsAllowed(context) && searchIndex != null) {
            _revealSearchHit(searchIndex! - 1);
          }
        },
      },
      child: Theme(
        data: theme,
        child: Builder(
          builder: (context) => PopScope(
            canPop: allowPop,
            onPopInvokedWithResult: (didPop, result) {
              if (!didPop) {
                if (fullscreen) {
                  _toggleFullscreen();
                } else {
                  _close();
                }
              }
            },
            child: Scaffold(
              resizeToAvoidBottomInset: false,
              extendBodyBehindAppBar: true,
              extendBody: true,
              appBar: fullscreen
                  ? null
                  : PreferredSize(
                      preferredSize: const Size.fromHeight(62),
                      child: ValueListenableBuilder(
                        valueListenable: positionChanges,
                        builder: (context, _, _) => _header(
                          context,
                          d,
                          background,
                          foreground,
                          d.length == 0
                              ? 0
                              : (d.starts[chapter] + offset) / d.length,
                        ),
                      ),
                    ),
              bottomNavigationBar: Visibility(
                visible: !fullscreen,
                maintainState: true,
                child: Material(
                  color: background,
                  child: SafeArea(
                    top: false,
                    child: ListenableBuilder(
                      listenable: Listenable.merge([
                        positionChanges,
                        dragProgress,
                        todayReading,
                      ]),
                      builder: (context, _) => _footer(
                        d,
                        d.length == 0
                            ? 0
                            : (d.starts[chapter] + offset) / d.length,
                        foreground,
                      ),
                    ),
                  ),
                ),
              ),
              body: Listener(
                onPointerDown: (_) => activity?.touch(),
                onPointerSignal: (_) => activity?.touch(),
                child: SizedBox.expand(
                  child: LayoutBuilder(
                    builder: (context, outer) {
                      final android =
                          Theme.of(context).platform == TargetPlatform.android;
                      final view = View.of(context);
                      final screen = android
                          ? screenGeometry.resolve(
                              display:
                                  view.display.size / view.devicePixelRatio,
                              window: outer.biggest,
                            )
                          : outer.biggest;
                      final wideLayout = outer.maxWidth >= 1000;
                      final showToc = wideLayout && tocOpen;
                      final showNotes = wideLayout && outer.maxWidth >= 1250;
                      final sideWidth =
                          (wideLayout ? 280.0 : 0.0) +
                          (showNotes ? 300.0 : 0.0);
                      final pageSize = Size(
                        (screen.width - sideWidth).clamp(
                          0.0,
                          preferences.columnWidth,
                        ),
                        screen.height,
                      );
                      final readerWidth = (outer.maxWidth - sideWidth).clamp(
                        0.0,
                        preferences.columnWidth,
                      );
                      final croppedBottom = (pageSize.height - outer.maxHeight)
                          .clamp(0.0, double.infinity);
                      final reader = Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: preferences.columnWidth,
                          ),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ReaderLayoutFrame(
                                pageSize: android ? pageSize : null,
                                onResize: viewportController.flushPosition,
                                builder: (context, box) {
                                  final scaler = MediaQuery.textScalerOf(
                                    context,
                                  );
                                  final bold = MediaQuery.boldTextOf(context);
                                  return ReaderViewport(
                                    controller: viewportController,
                                    key: ValueKey((
                                      wholeBookFlow ? -1 : chapter,
                                      navigation,
                                      preferences.mode,
                                      preferences.pageHeightFactor,
                                      preferences.font,
                                      preferences.size,
                                      preferences.spacing,
                                      preferences.margin,
                                      box.maxWidth,
                                      box.maxHeight,
                                      scaler,
                                      bold,
                                    )),
                                    text: flow?.text ?? d.texts[chapter],
                                    markup:
                                        flow?.markup ??
                                        d.book.chapters[chapter].markup,
                                    illustrations:
                                        flow?.illustrations ??
                                        d.book.chapters[chapter].illustrations,
                                    chapterBreaks:
                                        flow?.chapterBreaks ?? const [],
                                    showScrollbar:
                                        !fullscreen &&
                                        preferences.showScrollbar,
                                    onLink: (href, at) => _openBookLink(
                                      href,
                                      flow?.locate(at).chapter ?? chapter,
                                    ),
                                    style: preferences
                                        .style(foreground)
                                        .copyWith(
                                          fontWeight: bold
                                              ? FontWeight.w700
                                              : FontWeight.w400,
                                        ),
                                    scaler: scaler,
                                    width: box.maxWidth,
                                    height: box.maxHeight,
                                    margin: preferences.margin,
                                    pageHeightFactor:
                                        preferences.pageHeightFactor,
                                    anchor: flow == null
                                        ? offset
                                        : flow.starts[chapter] + offset,
                                    preferences: preferences,
                                    hideControls: fullscreen,
                                    controlsBottomInset:
                                        MediaQuery.paddingOf(context).bottom +
                                        croppedBottom,
                                    controlsSideInset:
                                        ((pageSize.width - readerWidth) / 2)
                                            .clamp(0.0, double.infinity),
                                    onToggleControls: _toggleFullscreen,
                                    selectingRange: rangeStart != null,
                                    onBoundary: (at, end) => flow == null
                                        ? _boundary(context, at, end)
                                        : _seamlessBoundary(
                                            context,
                                            flow,
                                            at,
                                            end,
                                          ),
                                    footnotes:
                                        flow?.footnotes ??
                                        d.book.chapters[chapter].footnotes,
                                    onFootnote: (note) =>
                                        _footnote(context, note),
                                    highlightStart:
                                        highlightStart == null ||
                                            highlightChapter == null ||
                                            flow == null &&
                                                highlightChapter != chapter
                                        ? null
                                        : (flow?.starts[highlightChapter!] ??
                                                  0) +
                                              highlightStart!,
                                    highlightEnd:
                                        highlightEnd == null ||
                                            highlightChapter == null ||
                                            flow == null &&
                                                highlightChapter != chapter
                                        ? null
                                        : (flow?.starts[highlightChapter!] ??
                                                  0) +
                                              highlightEnd!,
                                    notes: flow == null
                                        ? notes
                                              .where(
                                                (n) => n.chapter == chapter,
                                              )
                                              .toList()
                                        : _seamlessNotes(flow),
                                    onAnki: (start, end) =>
                                        _anki(context, start, end, flow),
                                    onAnnotate: (start, end, comment) =>
                                        flow == null
                                        ? _annotate(
                                            context,
                                            start,
                                            end,
                                            comment,
                                          )
                                        : _seamlessAnnotate(
                                            context,
                                            flow,
                                            start,
                                            end,
                                            comment,
                                          ),
                                    onHighlight: (start, end, color) =>
                                        flow == null
                                        ? _annotate(
                                            context,
                                            start,
                                            end,
                                            false,
                                            color: color,
                                          )
                                        : _seamlessAnnotate(
                                            context,
                                            flow,
                                            start,
                                            end,
                                            false,
                                            color: color,
                                          ),
                                    onLoading: () {
                                      settledMoves.flush();
                                      viewportReady = false;
                                      activity?.pause('layout');
                                    },
                                    onReady: () {
                                      viewportReady = true;
                                      if (this.foreground &&
                                          routeVisible &&
                                          panels == 0) {
                                        activity?.resume();
                                      }
                                    },
                                    scrolling: preferences.mode != 'pages',
                                    compactFlow: preferences.mode == 'compact',
                                    firstChapter: wholeBookFlow || chapter == 0,
                                    lastChapter:
                                        wholeBookFlow ||
                                        chapter == d.texts.length - 1,
                                    onPosition: flow == null
                                        ? _position
                                        : (value) =>
                                              _seamlessPosition(flow, value),
                                    onSeek: (value) {
                                      final target =
                                          flow?.locate(value) ??
                                          (chapter: chapter, offset: value);
                                      _go(
                                        target.chapter,
                                        target.offset,
                                        remember: false,
                                        reading: true,
                                      );
                                    },
                                    onBookBoundary: (end) {
                                      final c = end ? d.texts.length - 1 : 0;
                                      _go(c, end ? d.texts[c].length : 0);
                                    },
                                    onChapter: (delta) {
                                      final c = chapter + delta;
                                      _go(
                                        c,
                                        delta < 0 ? d.texts[c].length : 0,
                                        remember: false,
                                        reading: true,
                                      );
                                    },
                                  );
                                },
                              ),
                              if (!fullscreen)
                                Positioned(
                                  left: 8,
                                  right: 8,
                                  // Keep page arrows/slider available while the
                                  // reader is completing a long quotation.
                                  bottom:
                                      MediaQuery.paddingOf(context).bottom +
                                      (preferences.mode != 'compact' &&
                                              (preferences.mode != 'pages' ||
                                                  !fullscreen)
                                          ? 56
                                          : 8),
                                  child: Material(
                                    color: background,
                                    borderRadius: BorderRadius.circular(12),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (searchIndex != null &&
                                            searchSession.hits.isNotEmpty)
                                          _searchBar(context),
                                        if (!fullscreen &&
                                            (linkReturn != null || pinnedAway))
                                          Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 12,
                                            ),
                                            child: Wrap(
                                              spacing: 8,
                                              children: [
                                                if (linkReturn != null)
                                                  ActionChip(
                                                    avatar: const Icon(
                                                      Icons.undo,
                                                      size: 18,
                                                    ),
                                                    label: const Text(
                                                      'Вернуться после ссылки',
                                                    ),
                                                    onPressed: _returnFromLink,
                                                  ),
                                                if (pinnedAway)
                                                  ActionChip(
                                                    avatar: const Icon(
                                                      Icons.push_pin,
                                                      size: 18,
                                                    ),
                                                    label: Text(
                                                      'К главе ${pinnedChapter!.chapter + 1}',
                                                    ),
                                                    onPressed:
                                                        _returnToPinnedChapter,
                                                  ),
                                              ],
                                            ),
                                          ),
                                        if (rangeStart != null)
                                          Container(
                                            padding: const EdgeInsets.only(
                                              left: 16,
                                            ),
                                            color: theme
                                                .colorScheme
                                                .secondaryContainer,
                                            child: Row(
                                              children: [
                                                const Expanded(
                                                  child: Text(
                                                    'Начало цитаты сохранено. Перелистните и выделите конец → «Закончить здесь».',
                                                  ),
                                                ),
                                                IconButton(
                                                  tooltip:
                                                      'Отменить длинную цитату',
                                                  onPressed: () => setState(
                                                    () => rangeStart = null,
                                                  ),
                                                  icon: const Icon(Icons.close),
                                                ),
                                              ],
                                            ),
                                          ),
                                        if (saveError != null)
                                          Padding(
                                            padding: const EdgeInsets.all(8),
                                            child: Text(
                                              saveError!,
                                              style: TextStyle(
                                                color: theme.colorScheme.error,
                                              ),
                                            ),
                                          ),
                                        if (activityError != null)
                                          Padding(
                                            padding: const EdgeInsets.all(8),
                                            child: Text(
                                              activityError!,
                                              style: TextStyle(
                                                color: theme.colorScheme.error,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                      // Reserve desktop columns independently of chrome so
                      // hiding controls never changes the measured text width.
                      final body = Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (wideLayout)
                            SizedBox(
                              width: 280,
                              child: Padding(
                                padding: MediaQuery.paddingOf(context),
                                child: Visibility(
                                  visible: !fullscreen && showToc,
                                  maintainState: true,
                                  child: ValueListenableBuilder(
                                    valueListenable: panelPosition,
                                    builder: (context, _, _) => _contentsPanel(
                                      d,
                                      foreground,
                                      background,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          Expanded(child: reader),
                          if (showNotes)
                            SizedBox(
                              width: 300,
                              child: Padding(
                                padding: MediaQuery.paddingOf(context),
                                child: Visibility(
                                  visible: !fullscreen,
                                  maintainState: true,
                                  child: ValueListenableBuilder(
                                    valueListenable: noteChapter,
                                    builder: (context, _, _) =>
                                        _notesPanel(d, foreground, background),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                      return body;
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _loadToday() =>
      todayWork ??= _readToday().whenComplete(() => todayWork = null);

  Future<void> _readToday() async {
    try {
      final total = await ReadingDailyTotals(widget.repository)
          .day(DateTime.now());
      if (mounted) todayReading.value = total;
    } catch (_) {}
  }

  void _undoJump() {
    final target = history.removeLast();
    if (chapter == target.chapter && offset == target.offset) {
      setState(() {});
      _save();
    } else {
      _go(target.chapter, target.offset, remember: false);
    }
  }

  String _chapterLine(ReaderDocument d) {
    final title = d.book.chapters[chapter].title.trim();
    if (title.isEmpty) return 'Глава ${chapter + 1} из ${d.texts.length}';
    return title.toLowerCase().startsWith('глава')
        ? title
        : 'Глава ${chapter + 1}. $title';
  }

  PreferredSizeWidget _header(
    BuildContext context,
    ReaderDocument d,
    Color background,
    Color ink,
    double progress,
  ) {
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    final raised = Color.lerp(background, ink, .12)!;
    Widget pill(
      String tooltip,
      String label,
      VoidCallback? onTap, {
      bool on = false,
    }) => Tooltip(
      message: tooltip,
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          foregroundColor: on ? ink : ink.withValues(alpha: .62),
          backgroundColor: on ? raised : Colors.transparent,
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
          visualDensity: VisualDensity.compact,
          color: ink.withValues(alpha: .8),
          onPressed: onTap,
          icon: Icon(data, size: 22),
        );
    final pinTooltip = pinnedChapter == null
        ? 'Закрепить эту главу'
        : 'Открепить главу';
    final moreActions = PopupMenuButton<String>(
      tooltip: 'Другие действия',
      iconColor: ink.withValues(alpha: .8),
      onSelected: (value) {
        switch (value) {
          case 'bookmarks':
            _bookmarks(context);
          case 'highlights':
            _toggleHighlights();
          case 'pin':
            _toggleChapterPin();
          case 'resources':
            _resources(context);
          case 'statistics':
            _statistics(context);
          case 'keyboard':
            showReaderShortcuts(context);
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'keyboard', child: Text('Горячие клавиши')),
        const PopupMenuItem(value: 'bookmarks', child: Text('Закладки')),
        PopupMenuItem(
          value: 'highlights',
          child: Text(
            preferences.showHighlights
                ? 'Скрыть выделения'
                : 'Показать выделения',
          ),
        ),
        if (!wide) ...[
          PopupMenuItem(value: 'pin', child: Text(pinTooltip)),
          const PopupMenuItem(
            value: 'resources',
            child: Text('Сноски и иллюстрации'),
          ),
          const PopupMenuItem(
            value: 'statistics',
            child: Text('Статистика чтения и журнал'),
          ),
        ],
      ],
    );
    final tools = wide
        ? <Widget>[
            if (history.isNotEmpty)
              icon('Вернуться к прежнему месту', Icons.undo, _undoJump),
            icon(
              pinTooltip,
              pinnedChapter == null ? Icons.push_pin_outlined : Icons.push_pin,
              _toggleChapterPin,
            ),
            pill(
              'Оглавление',
              'Оглавление',
              () => setState(() => tocOpen = !tocOpen),
              on: tocOpen,
            ),
            pill('Поиск по книге', 'Поиск', () => _search(context)),
            pill('Оформление чтения', 'Aa', () => _settings(context)),
            pill(
              'Заметки книги',
              notes.isEmpty ? 'Заметки' : 'Заметки ${notes.length}',
              () => _notes(context),
            ),
            pill('Сноски и иллюстрации', 'Сноски', () => _resources(context)),
            pill(
              'Статистика чтения и журнал',
              'Статистика',
              () => _statistics(context),
            ),
            pill('Полный экран', 'Полный экран', _toggleFullscreen),
            moreActions,
          ]
        : <Widget>[
            if (history.isNotEmpty)
              icon('Вернуться к прежнему месту', Icons.undo, _undoJump),
            icon('Оглавление', Icons.list, () => _contents(context)),
            icon('Поиск по книге', Icons.search, () => _search(context)),
            icon(
              'Оформление чтения',
              Icons.text_fields,
              () => _settings(context),
            ),
            icon('Заметки книги', Icons.edit_note, () => _notes(context)),
            icon('Полный экран', Icons.fullscreen, _toggleFullscreen),
            moreActions,
          ];
    return PreferredSize(
      preferredSize: const Size.fromHeight(62),
      child: Material(
        color: background,
        child: SafeArea(
          bottom: false,
          child: Container(
            height: 62,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: ink.withValues(alpha: .12)),
              ),
            ),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Закрыть книгу',
                  color: ink,
                  onPressed: () => Navigator.maybePop(context),
                  icon: const Icon(Icons.chevron_left, size: 26),
                ),
                const SizedBox(width: 2),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayTitle ?? d.book.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppFonts.book(ink, size: wide ? 21 : 18),
                      ),
                      Text(
                        _chapterLine(d),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: AppFonts.body,
                          fontSize: 12,
                          color: ink.withValues(alpha: .58),
                        ),
                      ),
                    ],
                  ),
                ),
                ...tools,
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _statistics(BuildContext context) => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => ReadingStatisticsPage(
        repository: widget.repository,
        bookId: widget.asset.bookId,
      ),
    ),
  );

  Widget _footer(ReaderDocument d, double progress, Color ink) {
    final value = (dragProgress.value ?? progress).clamp(0.0, 1.0);
    if (!identical(_tickDocument, d)) {
      _tickDocument = d;
      _bookTicks = <double>[
        if (d.length > 0)
          for (var i = 1; i < d.texts.length; i++) d.starts[i] / d.length,
      ];
    }
    final left = (d.texts[chapter].length - offset).clamp(0, 1 << 40);
    final tracker = activity;
    final perMinute =
        tracker != null &&
            tracker.speedActiveMs >= 60000 &&
            tracker.speedChars >= 300
        ? tracker.speedChars / (tracker.speedActiveMs / 60000)
        : null;
    final minutesLeft = perMinute == null ? null : (left / perMinute).ceil();
    return ReaderBottomPanel(
      child: ReaderProgressFooter(
        value: value,
        ticks: _bookTicks,
        ink: ink,
        accent: PepeColors.of(context).accent,
        onChanged: (v) => dragProgress.value = v,
        onChangeCancel: () => dragProgress.value = null,
        onChangeEnd: (v) {
          dragProgress.value = null;
          final target = d.locate(v);
          _go(target.chapter, target.offset);
        },
        details: [
          Text(
            '${(value * 100).toStringAsFixed(dragProgress.value == null ? 0 : 1)}% книги · глава ${chapter + 1} из ${d.texts.length}',
          ),
          if (minutesLeft != null)
            Text(
              minutesLeft <= 1
                  ? 'до конца главы меньше минуты'
                  : 'до конца главы около $minutesLeft мин',
            ),
          if (todayReading.value != null)
            Text('сегодня ${todayReading.value! ~/ 60000} мин чтения'),
        ],
        actions: [
          IconButton(
            tooltip: 'Сохранить закладку',
            visualDensity: VisualDensity.compact,
            onPressed: savingBookmark ? null : _quickBookmark,
            icon: const Icon(Icons.bookmark_add_outlined),
          ),
        ],
      ),
    );
  }

  Widget _contentsPanel(ReaderDocument d, Color ink, Color background) {
    final pepe = PepeColors.of(context);
    final raised = Color.lerp(background, ink, .1)!;
    final pinned = pinnedChapter;
    return Container(
      decoration: BoxDecoration(
        border: Border(right: BorderSide(color: ink.withValues(alpha: .12))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 18, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Text(
                    'ОГЛАВЛЕНИЕ',
                    style: TextStyle(
                      fontFamily: AppFonts.display,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: .5,
                      color: ink,
                    ),
                  ),
                ),
                Text(
                  'Глав: ${d.texts.length}',
                  style: TextStyle(
                    fontSize: 12,
                    color: ink.withValues(alpha: .55),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ReaderContentsSearch(
              titles: _titlesFor(d),
              builder: (context, indexes) => ListView.builder(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                itemCount: indexes.length,
                itemBuilder: (context, row) {
                  final i = indexes[row];
                  final current = i == chapter;
                  final length = d.texts[i].length;
                  final mark = pinned?.chapter == i
                      ? 'закреплена'
                      : current
                      ? '${length == 0 ? 0 : (offset * 100 / length).round()}%'
                      : i < chapter
                      ? '✓'
                      : '';
                  return Material(
                    color: current ? raised : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: current ? null : () => _go(i, 0),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 26,
                              child: Text(
                                '${i + 1}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: current
                                      ? pepe.accent
                                      : ink.withValues(alpha: .5),
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                d.book.chapters[i].title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: AppFonts.body,
                                  fontSize: 13,
                                  fontWeight: current
                                      ? FontWeight.w700
                                      : FontWeight.w400,
                                  color: i < chapter
                                      ? ink.withValues(alpha: .55)
                                      : ink,
                                ),
                              ),
                            ),
                            if (mark.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(left: 6),
                                child: Text(
                                  mark,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: current
                                        ? pepe.accent
                                        : ink.withValues(alpha: .5),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          if (pinned != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: Material(
                color: Colors.transparent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: ink.withValues(alpha: .2)),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: _returnToPinnedChapter,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      'Глава ${pinned.chapter + 1} закреплена. Вернуться к ней можно одним нажатием, где бы вы ни были в книге.',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.45,
                        color: ink.withValues(alpha: .6),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _notesPanel(ReaderDocument d, Color ink, Color background) {
    final pepe = PepeColors.of(context);
    final card = Color.lerp(background, ink, .06)!;
    final here = notes.where((n) => n.chapter == chapter).toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    final length = d.texts[chapter].length;
    return Container(
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: ink.withValues(alpha: .12))),
      ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
        children: [
          Text(
            'В ЭТОЙ ГЛАВЕ',
            style: TextStyle(
              fontFamily: AppFonts.display,
              fontSize: 16,
              fontWeight: FontWeight.w700,
              letterSpacing: .5,
              color: ink,
            ),
          ),
          if (here.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'Заметок пока нет. Выделите текст и нажмите «Заметка».',
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.45,
                  color: ink.withValues(alpha: .55),
                ),
              ),
            ),
          for (final note in here)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Material(
                color: card,
                borderRadius: BorderRadius.circular(14),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () => _openNote(note),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color:
                                    noteColors[note.color] ??
                                    noteColors['yellow'],
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              length == 0
                                  ? 'Глава ${chapter + 1}'
                                  : '${(note.start * 100 / length).round()}% главы',
                              style: TextStyle(
                                fontSize: 11,
                                color: ink.withValues(alpha: .55),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          note.quote.isEmpty ? '—' : note.quote,
                          maxLines: 5,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: AppFonts.reading,
                            fontStyle: FontStyle.italic,
                            fontSize: 14,
                            height: 1.45,
                            color: ink,
                          ),
                        ),
                        if (note.comment.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              note.comment,
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13, color: ink),
                            ),
                          ),
                        if (note.tags.isNotEmpty || note.characters.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              [
                                for (final t in note.tags) '#$t',
                                for (final c in note.characters) '@$c',
                              ].join('  '),
                              style: TextStyle(
                                fontSize: 11,
                                color: pepe.accentSoft,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _pausePanel() async {
    settledMoves.flush();
    panels++;
    activity?.pause('panel');
  }

  void _resumePanel() {
    panels = (panels - 1).clamp(0, 100);
    if (mounted && foreground && routeVisible && panels == 0 && viewportReady) {
      activity?.resume();
    }
  }
}
