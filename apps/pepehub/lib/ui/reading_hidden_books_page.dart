import 'package:flutter/material.dart';

import '../data/repository.dart';
import '../media/asset_store.dart';
import '../reader/reading_book_actions.dart';
import '../reader/reading_book_visibility.dart';
import '../audio/audio_book_actions.dart';
import 'audio_mini_player.dart';

class ReadingHiddenBooksPage extends StatefulWidget {
  final AssetStore assets;
  final bool audio;
  const ReadingHiddenBooksPage({
    super.key,
    required this.assets,
    this.audio = false,
  });
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
    final flags = await widget.assets.repository.metadataPrefixes([
      widget.audio ? 'audio-library-hidden:' : 'reading-library-hidden:',
      if (widget.audio) 'audio-library-superseded:',
      if (widget.audio) 'audio-user-hidden:',
    ]);
    for (final book in await widget.assets.repository.shelfBooks(
      audio: widget.audio,
    )) {
      if ((book.payload?['format'] == 'audio') == widget.audio &&
          !deleted.contains(book.id) &&
          flags['audio-library-superseded:${book.id}'] != '1' &&
          (flags['${widget.audio ? 'audio' : 'reading'}-library-hidden:${book.id}'] ==
                  '1' ||
              widget.audio && flags['audio-user-hidden:${book.id}'] == '1')) {
        result.add(book);
      }
    }
    if (mounted) setState(() => books = result);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.audio ? 'Убранные аудиокниги' : 'Убранные книги'),
    ),
    bottomNavigationBar: const AudioPlayerFooter(),
    body: ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: books.length + 1,
      itemBuilder: (context, index) => index == 0
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
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
              ],
            )
          : _bookRow(books[index - 1]),
    ),
  );

  Widget _bookRow(LibraryRecord book) => ListTile(
    title: Text(book.title),
    trailing: IconButton(
      tooltip: 'Вернуть в список',
      icon: const Icon(Icons.restore),
      onPressed: () async {
        try {
          await (widget.audio
                  ? AudioBookActions(widget.assets)
                  : ReadingBookActions(widget.assets))
              .hide(book.id, hidden: false);
          await _load();
        } catch (_) {
          if (mounted) {
            setState(() => error = 'Не удалось вернуть книгу');
          }
        }
      },
    ),
  );
}
