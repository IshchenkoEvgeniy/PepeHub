import 'dart:async';

import 'reader_routes.dart';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/repository.dart';
import '../media/asset_store.dart';
import 'text_book.dart';
import 'reader_layout.dart';
import 'reader_controls.dart';
import 'reader_viewport.dart';
import 'reading_library.dart';
import 'reading_notes_page.dart';
import 'reading_activity.dart';
import 'reading_log.dart';
import 'epub.dart';
import 'reader_resources.dart';
import 'reader_rebase.dart';

class _SeamlessBook {
  final String text;
  final List<int> starts;
  final List<BookMarkup> markup;
  final List<BookIllustration> illustrations;
  final List<BookFootnote> footnotes;

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
  int? highlightStart, highlightEnd;
  final history = <({int chapter, int offset})>[];
  Future<void> writes = Future.value();
  Timer? debounce;
  bool allowPop = false, closing = false;
  double? dragging;
  List<ReadingNote> notes = [];
  ReadingActivity? activity;
  String? activityError, displayTitle;
  bool foreground = true, viewportReady = false;
  int panels = 0;
  bool fullscreen = false;
  int? rangeStart;
  late final library = ReadingLibrary(widget.repository);
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
    WidgetsBinding.instance.addObserver(this);
    _load();
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
    if (foreground && panels == 0 && viewportReady) activity?.resume();
  }

  @override
  void dispose() {
    readerRoutes.unsubscribe(this);
    if (fullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    WidgetsBinding.instance.removeObserver(this);
    debounce?.cancel();
    _save();
    activity?.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) {
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
            ),
          ),
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
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'returnTo': [
        for (final place in history)
          {'chapter': place.chapter, 'offset': place.offset},
      ],
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
    activity?.move(document!.starts[chapter] + value);
    setState(() => offset = value);
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 300), _save);
  }

  void _seamlessPosition(_SeamlessBook flow, int absolute) {
    final place = flow.locate(absolute);
    final local = place.offset.clamp(0, document!.texts[place.chapter].length);
    if (place.chapter == chapter && local == offset) return;
    activity?.move(document!.starts[place.chapter] + local);
    setState(() {
      chapter = place.chapter;
      offset = local;
    });
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 300), _save);
  }

  Future<void> _seamlessAnnotate(
    BuildContext context,
    _SeamlessBook flow,
    int start,
    int end,
    bool comment,
  ) async {
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
      color: 'yellow',
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
      setState(() => notes = saved);
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
    activity?.move(
      document!.starts[c] + at,
      jump: !reading,
      chapterEnded: reading && c == chapter + 1,
    );
    debounce?.cancel();
    setState(() {
      if (remember) {
        history.add((chapter: chapter, offset: offset));
        if (history.length > 20) history.removeAt(0);
      }
      if (c != chapter) rangeStart = null;
      chapter = c;
      highlightStart = highlightEnd = null;
      offset = at.clamp(0, document!.texts[c].length);
      navigation++;
    });
    _save();
  }

  Future<void> _close() async {
    if (closing) return;
    closing = true;
    debounce?.cancel();
    await _save();
    if (!mounted) return;
    if (saveError != null) {
      closing = false;
      return;
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

  List<ReadingNote> _seamlessNotes(_SeamlessBook flow) => [
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

  Future<void> _resources(BuildContext context) async {
    await _pausePanel();
    if (!context.mounted) return;
    try {
      await showChapterResources(context, document!.book.chapters[chapter]);
    } finally {
      _resumePanel();
    }
  }

  Future<void> _openBookLink(String href) async {
    final book = document?.book;
    if (book == null) return;
    final target = bookResourcePath(book.chapters[chapter].path, href);
    final uri = Uri.tryParse(href);
    if (target != null) {
      final c = book.chapters.indexWhere((item) => item.path == target);
      if (c >= 0) {
        final id = uri == null ? '' : Uri.decodeComponent(uri.fragment);
        final anchor = book.chapters[c].markup
            .where((r) => r.anchor == id)
            .firstOrNull;
        _go(c, anchor?.start ?? 0);
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
    final next = await showReaderSettings(context, preferences);
    _resumePanel();
    if (next == null || !mounted) return;
    setState(() {
      preferences = next;
      navigation++;
    });
    await _save(appearance: true);
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
                child: ListView.builder(
                  itemCount: chapters.length,
                  itemBuilder: (context, i) => ListTile(
                    selected: i == chapter,
                    leading: Text('${i + 1}'),
                    title: Text(chapters[i].title),
                    onTap: () => Navigator.pop(context, i),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    _resumePanel();
    if (selected != null && mounted) _go(selected, 0);
  }

  Future<void> _search(BuildContext context) async {
    await _pausePanel();
    if (!context.mounted) return;
    final hit = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => Theme(
          data: Theme.of(context),
          child: ReaderSearch(document: document!),
        ),
      ),
    );
    _resumePanel();
    if (hit != null && mounted) {
      _go(hit['chapter'] as int, hit['offset'] as int);
      setState(() {
        highlightStart = hit['offset'] as int;
        highlightEnd = hit['end'] as int;
      });
    }
  }

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
    final dark =
        preferences.palette == 'dark' ||
        preferences.palette == 'system' &&
            Theme.of(context).brightness == Brightness.dark;
    final background = dark
        ? const Color(0xff20262a)
        : preferences.palette == 'sepia'
        ? const Color(0xfff3e8d0)
        : const Color(0xfffafafa);
    final foreground = dark ? const Color(0xffdedbd3) : const Color(0xff302b24);
    final theme = ThemeData(
      useMaterial3: true,
      brightness: dark ? Brightness.dark : Brightness.light,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff557b70),
        brightness: dark ? Brightness.dark : Brightness.light,
        surface: background,
      ),
      scaffoldBackgroundColor: background,
    );
    final progress = d.length == 0
        ? 0.0
        : (d.starts[chapter] + offset) / d.length;
    final wholeBookFlow = const [
      'seamless',
      'pages',
      'compact',
    ].contains(preferences.mode);
    final flow = wholeBookFlow ? _flowFor(d) : null;
    return Theme(
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
            appBar: fullscreen
                ? null
                : AppBar(
                    title: Text(
                      displayTitle ?? d.book.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    actions: [
                      IconButton(
                        tooltip: 'Заметки книги',
                        icon: const Icon(Icons.edit_note),
                        onPressed: () => _notes(context),
                      ),
                      if (history.isNotEmpty)
                        IconButton(
                          tooltip: 'Вернуться к прежнему месту',
                          icon: const Icon(Icons.undo),
                          onPressed: () {
                            final target = history.removeLast();
                            if (chapter == target.chapter &&
                                offset == target.offset) {
                              setState(() {});
                              _save();
                            } else {
                              _go(
                                target.chapter,
                                target.offset,
                                remember: false,
                              );
                            }
                          },
                        ),
                      IconButton(
                        tooltip: 'Оглавление',
                        icon: const Icon(Icons.list),
                        onPressed: () => _contents(context),
                      ),
                      IconButton(
                        tooltip: 'Поиск по книге',
                        icon: const Icon(Icons.search),
                        onPressed: () => _search(context),
                      ),
                      IconButton(
                        tooltip: 'Оформление чтения',
                        icon: const Icon(Icons.text_fields),
                        onPressed: () => _settings(context),
                      ),
                    ],
                  ),
            floatingActionButton: fullscreen
                ? FloatingActionButton.small(
                    tooltip: 'Выйти из полного экрана',
                    onPressed: _toggleFullscreen,
                    child: const Icon(Icons.fullscreen_exit),
                  )
                : null,
            body: Listener(
              onPointerDown: (_) => activity?.touch(),
              onPointerSignal: (_) => activity?.touch(),
              child: SafeArea(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 900),
                    child: Column(
                      children: [
                        if (!fullscreen)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 6,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${chapter + 1}/${d.texts.length} · ${d.book.chapters[chapter].title}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.labelMedium,
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Полный экран',
                                  onPressed: _toggleFullscreen,
                                  icon: const Icon(Icons.fullscreen),
                                ),
                                IconButton(
                                  tooltip: 'Сноски и иллюстрации',
                                  onPressed: () => _resources(context),
                                  icon: const Icon(
                                    Icons.photo_library_outlined,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        if (rangeStart != null)
                          Container(
                            padding: const EdgeInsets.only(left: 16),
                            color: theme.colorScheme.secondaryContainer,
                            child: Row(
                              children: [
                                const Expanded(
                                  child: Text(
                                    'Начало цитаты сохранено. Перелистните и выделите конец → «Закончить здесь».',
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Отменить длинную цитату',
                                  onPressed: () =>
                                      setState(() => rangeStart = null),
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
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                          ),
                        if (activityError != null)
                          Padding(
                            padding: const EdgeInsets.all(8),
                            child: Text(
                              activityError!,
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                          ),
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, box) {
                              final scaler = MediaQuery.textScalerOf(context);
                              final bold = MediaQuery.boldTextOf(context);
                              return ReaderViewport(
                                key: ValueKey(
                                  '${wholeBookFlow ? 'all' : chapter}:$navigation:${preferences.mode}:${box.maxWidth}:${box.maxHeight}:${scaler.scale(preferences.size)}:$bold',
                                ),
                                text: flow?.text ?? d.texts[chapter],
                                markup:
                                    flow?.markup ??
                                    d.book.chapters[chapter].markup,
                                illustrations:
                                    flow?.illustrations ??
                                    d.book.chapters[chapter].illustrations,
                                chapterBreaks:
                                    flow?.starts.skip(1).toList() ?? const [],
                                showScrollbar: preferences.showScrollbar,
                                onLink: _openBookLink,
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
                                anchor: flow == null
                                    ? offset
                                    : flow.starts[chapter] + offset,
                                preferences: preferences,
                                hideControls: fullscreen,
                                onToggleControls: _toggleFullscreen,
                                selectingRange: rangeStart != null,
                                onBoundary: (at, end) => flow == null
                                    ? _boundary(context, at, end)
                                    : _seamlessBoundary(context, flow, at, end),
                                footnotes:
                                    flow?.footnotes ??
                                    d.book.chapters[chapter].footnotes,
                                onFootnote: (note) => _footnote(context, note),
                                highlightStart: highlightStart == null
                                    ? null
                                    : (flow?.starts[chapter] ?? 0) +
                                          highlightStart!,
                                highlightEnd: highlightEnd == null
                                    ? null
                                    : (flow?.starts[chapter] ?? 0) +
                                          highlightEnd!,
                                notes: flow == null
                                    ? notes
                                          .where((n) => n.chapter == chapter)
                                          .toList()
                                    : _seamlessNotes(flow),
                                onAnnotate: (start, end, comment) =>
                                    flow == null
                                    ? _annotate(context, start, end, comment)
                                    : _seamlessAnnotate(
                                        context,
                                        flow,
                                        start,
                                        end,
                                        comment,
                                      ),
                                onLoading: () {
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
                                    : (value) => _seamlessPosition(flow, value),
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
                        ),
                        if (!fullscreen &&
                            const [
                              'pages',
                              'compact',
                            ].contains(preferences.mode))
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Row(
                              children: [
                                const Icon(Icons.menu_book_outlined, size: 18),
                                Expanded(
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      IgnorePointer(
                                        child: CustomPaint(
                                          painter: ReaderChapterTicksPainter(
                                            [
                                              0,
                                              for (final start
                                                  in flow!.starts.skip(1))
                                                flow.text.isEmpty
                                                    ? 0.0
                                                    : start / flow.text.length,
                                            ],
                                            theme.colorScheme.onSurface
                                                .withValues(alpha: .3),
                                          ),
                                        ),
                                      ),
                                      Slider(
                                        value: (dragging ?? progress).clamp(
                                          0,
                                          1,
                                        ),
                                        semanticFormatterCallback: (v) =>
                                            '${(v * 100).round()} процентов книги',
                                        onChanged: (v) =>
                                            setState(() => dragging = v),
                                        onChangeEnd: (v) {
                                          setState(() => dragging = null);
                                          final target = d.locate(v);
                                          _go(target.chapter, target.offset);
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                                SizedBox(
                                  width: 48,
                                  child: Text(
                                    '${((dragging ?? progress) * 100).toStringAsFixed(1)}%',
                                    style: theme.textTheme.labelSmall,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _pausePanel() async {
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
