import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'reader_layout.dart';

/// Retains bounded plain text, never native glyph arrays, across query edits.
class PdfSearchTextCache {
  final int maxCharacters, maxPages;
  final _pages = <int,String>{};
  int _characters = 0;
  bool _closed = false;
  PdfSearchTextCache({
    this.maxCharacters = 8 * 1024 * 1024,
    this.maxPages = 4096,
  });
  int get cachedPages => _pages.length;
  Future<String> page(int number, Future<String> Function() load) async {
    final hit = _pages.remove(number);
    if (hit != null) {
      _pages[number] = hit;
      return hit;
    }
    final text = await load();
    if (_closed || text.length > maxCharacters) return text;
    while (_pages.isNotEmpty &&
        (_characters + text.length > maxCharacters ||
            _pages.length >= maxPages)) {
      _characters -= _pages.remove(_pages.keys.first)!.length;
    }
    _pages[number] = text;
    _characters += text.length;
    return text;
  }

  void close() {
    _closed = true;
    _pages.clear();
    _characters = 0;
  }
}

class PdfSearchPage extends StatefulWidget {
  final PdfDocument document;
  const PdfSearchPage({super.key, required this.document});
  @override
  State<PdfSearchPage> createState() => _PdfSearchPageState();
}

class _PdfSearchPageState extends State<PdfSearchPage> {
  Timer? debounce;
  int generation = 0, scanned = 0;
  bool busy = false;
  String query = '', error = '';
  final results = <Map<String, dynamic>>[];
  Future<void> pending = Future.value();
  final textCache = PdfSearchTextCache();

  @override
  void dispose() {
    generation++;
    debounce?.cancel();
    textCache.close();
    super.dispose();
  }

  void _changed(String value) {
    debounce?.cancel();
    final token = ++generation;
    setState(() {
      query = value.trim();
      scanned = 0;
      results.clear();
      error = '';
      busy = query.isNotEmpty;
    });
    if (!busy) return;
    final needle = query;
    debounce = Timer(const Duration(milliseconds: 300), () {
      // At most one native page extraction at a time, even during fast typing.
      pending = pending.then((_) => _scan(needle, token));
    });
  }

  Future<void> _scan(String needle, int token) async {
    bool cancelled() => !mounted || token != generation;
    if (cancelled()) return;
    try {
      if (widget.document.permissions?.allowsCopying == false) {
        throw const FormatException('Автор PDF запретил извлечение текста');
      }
      final pattern = readerSearchPattern(needle);
      for (final page in widget.document.pages) {
        if (cancelled()) return;
        final text = await textCache.page(
          page.pageNumber,
          () async => (await page.loadStructuredText()).fullText,
        );
        if (cancelled()) return;
        for (final match in pattern.allMatches(text)) {
          results.add({
            'chapter': page.pageNumber - 1,
            'offset': match.start,
            'end': match.end,
            'excerpt': readerExcerpt(text, match.start, match.end, after: 80),
          });
          if (results.length >= 200) break;
        }
        setState(() => scanned = page.pageNumber);
        if (results.length >= 200) break;
        await Future<void>.delayed(Duration.zero);
      }
    } catch (e) {
      if (!cancelled()) {
        setState(() => error = 'Не удалось прочитать текст: $e');
      }
    } finally {
      if (!cancelled()) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Поиск по книге')),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              autofocus: true,
              onChanged: _changed,
              decoration: const InputDecoration(
                hintText: 'Слово или фраза',
                prefixIcon: Icon(Icons.search),
              ),
            ),
          ),
          if (busy) ...[
            LinearProgressIndicator(
              value: scanned / widget.document.pages.length,
            ),
            Text(
              'Проверено страниц: $scanned / ${widget.document.pages.length}',
            ),
            TextButton(
              onPressed: () {
                generation++;
                debounce?.cancel();
                setState(() => busy = false);
              },
              child: const Text('Остановить поиск'),
            ),
          ],
          if (error.isNotEmpty) Text(error),
          if (query.isNotEmpty)
            Text(
              results.length >= 200
                  ? 'Показаны первые 200 совпадений'
                  : 'Совпадений: ${results.length}',
            ),
          Expanded(
            child: ListView.builder(
              itemCount: results.length,
              itemBuilder: (context, i) {
                final hit = results[i];
                return ListTile(
                  title: Text('Страница ${(hit['chapter'] as int) + 1}'),
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
