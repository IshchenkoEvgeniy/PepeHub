import 'dart:async';

import 'package:flutter/material.dart';

import 'reader_layout.dart';
import 'reader_search.dart';
import 'reader_appearance.dart';

Future<ReaderPreferences?> showReaderSettings(
  BuildContext context,
  ReaderPreferences initial, {
  ValueChanged<ReaderPreferences>? onPreview,
}) => showReaderAppearance(context, initial, onPreview: onPreview);

class ReaderSearch extends StatefulWidget {
  final ReaderDocument document;
  final int currentChapter;
  final ReaderSearchSession? session;
  const ReaderSearch({
    super.key,
    required this.document,
    this.currentChapter = 0,
    this.session,
  });
  @override
  State<ReaderSearch> createState() => _ReaderSearchState();
}

class _ReaderSearchState extends State<ReaderSearch> {
  final worker = ReaderSearchWorker();
  late final ReaderSearchSession session =
      widget.session ?? ReaderSearchSession();
  late final controller = TextEditingController(text: session.query);
  Timer? debounce;
  int generation = 0;
  bool busy = false;
  String error = '';
  List<Map<String, dynamic>> results = [];
  bool hasMore = false;
  int? get scope => session.inCurrentChapter ? widget.currentChapter : null;

  @override
  void initState() {
    super.initState();
    if (session.complete && session.scannedChapter == scope) {
      results = session.hits;
      hasMore = session.hasMore;
    } else {
      _changed(controller.text);
    }
  }

  @override
  void dispose() {
    debounce?.cancel();
    worker.cancel();
    controller.dispose();
    super.dispose();
  }

  void _changed(String text) {
    debounce?.cancel();
    worker.cancel();
    final token = ++generation;
    setState(() {
      session.query = text;
      session.complete = text.trim().isEmpty;
      session.hits = results = [];
      session.hasMore = hasMore = false;
      session.scannedChapter = scope;
      busy = text.trim().isNotEmpty;
      error = '';
    });
    if (!busy) return;
    debounce = Timer(const Duration(milliseconds: 250), () => _scan(token));
  }

  Future<void> _scan(int token, {bool more = false}) async {
    try {
      final next = await worker.search(
        texts: widget.document.texts,
        query: session.query,
        chapter: scope,
        after: more && results.isNotEmpty ? results.last : null,
      );
      if (!mounted || generation != token || next == null) return;
      setState(() {
        results = List.unmodifiable([if (more) ...results, ...next.hits]);
        hasMore = next.hasMore;
        session.hits = results;
        session.hasMore = hasMore;
        session.complete = true;
        session.scannedChapter = scope;
      });
    } catch (e) {
      if (mounted && generation == token) {
        setState(() => error = 'Не удалось выполнить поиск: $e');
      }
    } finally {
      if (mounted && generation == token) setState(() => busy = false);
    }
  }

  void _more() {
    if (busy || !hasMore) return;
    setState(() {
      busy = true;
      error = '';
    });
    _scan(generation, more: true);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Поиск по книге')),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  onChanged: _changed,
                  decoration: InputDecoration(
                    hintText: 'Слово или фраза',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: controller.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Очистить поиск',
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              controller.clear();
                              _changed('');
                            },
                          ),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('Вся книга'),
                      selected: !session.inCurrentChapter,
                      onSelected: (_) {
                        session.inCurrentChapter = false;
                        _changed(controller.text);
                      },
                    ),
                    ChoiceChip(
                      label: const Text('Текущая глава'),
                      selected: session.inCurrentChapter,
                      onSelected: (_) {
                        session.inCurrentChapter = true;
                        _changed(controller.text);
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (busy) const LinearProgressIndicator(),
          if (error.isNotEmpty)
            Padding(padding: const EdgeInsets.all(8), child: Text(error)),
          if (session.query.trim().isNotEmpty && (!busy || results.isNotEmpty))
            Text(
              results.isEmpty
                  ? 'Ничего не найдено'
                  : 'Совпадений: ${results.length}${hasMore ? '+' : ''}',
            ),
          Expanded(
            child: ListView.builder(
              itemCount: results.length + (hasMore ? 1 : 0),
              itemBuilder: (context, i) {
                if (i == results.length) {
                  return TextButton.icon(
                    onPressed: busy ? null : _more,
                    icon: const Icon(Icons.expand_more),
                    label: const Text('Показать ещё совпадения'),
                  );
                }
                final hit = results[i];
                return ListTile(
                  title: Text(
                    widget.document.book.chapters[hit['chapter'] as int].title,
                  ),
                  subtitle: Text(hit['excerpt'] as String),
                  onTap: () => Navigator.pop(context, hit),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}
