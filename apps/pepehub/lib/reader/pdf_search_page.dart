import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

/// No whole-document text/glyph cache. A new query cancels the preceding scan.
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

  @override
  void dispose() {
    generation++;
    debounce?.cancel();
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
      final pattern = RegExp(RegExp.escape(needle), caseSensitive: false);
      for (final page in widget.document.pages) {
        if (cancelled()) return;
        final text = (await page.loadStructuredText()).fullText;
        if (cancelled()) return;
        for (final match in pattern.allMatches(text)) {
          results.add({
            'chapter': page.pageNumber - 1,
            'offset': match.start,
            'end': match.end,
            'excerpt': text.substring(
              math.max(0, match.start - 45),
              math.min(text.length, match.end + 80),
            ),
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
