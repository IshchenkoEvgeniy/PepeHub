import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../library/library_service.dart';
import '../library/models.dart';
import '../recommendations/book_catalog.dart';
import '../recommendations/recommendation_store.dart';

class LibraryCoverSearch extends StatefulWidget {
  final LibraryService library;
  final ObsidianLibraryItem item;
  const LibraryCoverSearch({
    super.key,
    required this.library,
    required this.item,
  });
  @override
  State<LibraryCoverSearch> createState() => _LibraryCoverSearchState();
}

class _LibraryCoverSearchState extends State<LibraryCoverSearch> {
  late final query = TextEditingController(
    text: '${widget.item.title} ${widget.item.authors}'.trim(),
  );
  final client = http.Client();
  final sources = catalogSources.keys.toSet();
  List<CatalogBook> results = [];
  bool busy = false;
  String? error;
  int generation = 0;
  @override
  void dispose() {
    generation++;
    query.dispose();
    client.close();
    super.dispose();
  }

  Future<void> search() async {
    final current = ++generation;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final found = await BookCatalog(client).search(query.text, sources);
      if (!mounted || current != generation) return;
      final seen = <String>{};
      setState(() {
        results = found.books
            .where((b) => b.coverUrl != null && seen.add(b.coverUrl!))
            .toList();
        error = found.failures.isEmpty
            ? null
            : found.failures.entries
                  .map((e) => '${catalogSources[e.key]}: ${e.value}')
                  .join('\n');
        if (results.isEmpty && error == null) error = 'Обложки не найдены. Попробуйте название без имени автора или другое написание.';
      });
    } catch (e) {
      if (mounted && current == generation) setState(() => error = '$e');
    } finally {
      if (mounted && current == generation) setState(() => busy = false);
    }
  }

  Future<void> choose(CatalogBook book) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final store = widget.library.covers;
      if (store == null) throw StateError('Хранилище обложек недоступно');
      var uri = Uri.parse(book.coverUrl!);
      final data = BytesBuilder(copy: false);
      for (var redirect = 0; ; redirect++) {
        if (uri.scheme != 'https' || uri.userInfo.isNotEmpty || redirect > 3) {
          throw StateError('Небезопасный адрес обложки');
        }
        final response = await client
            .send(http.Request('GET', uri)..followRedirects = false)
            .timeout(const Duration(seconds: 20));
        if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
          await response.stream.listen((_) {}).cancel();
          uri = uri.resolve(response.headers['location'] ?? '');
          continue;
        }
        if (response.statusCode != 200 ||
            (response.contentLength ?? 0) > 16777216) {
          await response.stream.listen((_) {}).cancel();
          throw StateError('Не удалось скачать обложку');
        }
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 20),
        )) {
          data.add(chunk);
          if (data.length > 16777216) throw StateError('Обложка больше 16 МиБ');
        }
        break;
      }
      final hash = await store.upload(data.takeBytes());
      if (mounted) Navigator.pop(context, 'pepehub-cover:$hash');
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Найти обложку')),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              TextField(
                controller: query,
                enabled: !busy,
                maxLength: 300,
                onSubmitted: (_) => busy ? null : search(),
                decoration: const InputDecoration(
                  labelText: 'Название и автор',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
              Wrap(
                spacing: 8,
                children: [
                  for (final source in catalogSources.entries)
                    FilterChip(
                      label: Text(source.value),
                      selected: sources.contains(source.key),
                      onSelected: busy
                          ? null
                          : (selected) => setState(() {
                              selected
                                  ? sources.add(source.key)
                                  : sources.remove(source.key);
                            }),
                    ),
                ],
              ),
              const Text(
                'Поиск отправляет введённый запрос выбранным каталогам. Выбранная обложка сохраняется на устройстве.',
              ),
              FilledButton(
                onPressed: busy || sources.isEmpty ? null : search,
                child: const Text('Найти обложки'),
              ),
            ],
          ),
        ),
        if (busy) const LinearProgressIndicator(),
        if (error != null)
          Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 190,
              mainAxisExtent: 300,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: results.length,
            itemBuilder: (context, index) {
              final book = results[index];
              return Card(
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: busy ? null : () => choose(book),
                  child: Column(
                    children: [
                      Expanded(
                        child: Image.network(
                          book.coverUrl!,
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) =>
                              const Icon(Icons.broken_image_outlined),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          children: [
                            Text(
                              book.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              book.authors.join(', '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              book.sourceLabel,
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    ),
  );
}
