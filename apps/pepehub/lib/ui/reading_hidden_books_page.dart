import 'package:flutter/material.dart';

import '../data/repository.dart';
import '../media/asset_store.dart';
import '../reader/reading_book_actions.dart';
import '../reader/reading_book_visibility.dart';
import 'audio_mini_player.dart';

class ReadingHiddenBooksPage extends StatefulWidget {
  final AssetStore assets;
  const ReadingHiddenBooksPage({super.key, required this.assets});
  @override
  State<ReadingHiddenBooksPage> createState() => _ReadingHiddenBooksPageState();
}

class _ReadingHiddenBooksPageState extends State<ReadingHiddenBooksPage> {
  List<LibraryRecord> books = [];
  String? error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final result = <LibraryRecord>[];
    final deleted = await ReadingBookVisibility(widget.assets.repository)
        .deletedIds();
    for (final book in await widget.assets.repository.records('book')) {
      if (book.payload?['format'] != 'audio' &&
          !deleted.contains(book.id) &&
          await widget.assets.repository.meta(
                'reading-library-hidden:${book.id}',
              ) ==
              '1') {
        result.add(book);
      }
    }
    if (mounted) setState(() => books = result);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Убранные книги')),
    bottomNavigationBar: const AudioPlayerFooter(),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Файлы убранных книг могут оставаться в папках. Прогресс, заметки и статистика сохранены. Если файл удалён, для чтения его нужно добавить заново.',
        ),
        if (error != null) Text(error!),
        if (books.isEmpty)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Убранных книг нет'),
          ),
        for (final book in books)
          ListTile(
            title: Text(book.title),
            trailing: IconButton(
              tooltip: 'Вернуть в список',
              icon: const Icon(Icons.restore),
              onPressed: () async {
                try {
                  await ReadingBookActions(widget.assets)
                      .hide(book.id, hidden: false);
                  await _load();
                } catch (_) {
                  if (mounted) {
                    setState(() => error = 'Не удалось вернуть книгу');
                  }
                }
              },
            ),
          ),
      ],
    ),
  );
}
