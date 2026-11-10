part of 'library_page.dart';

/// Batch actions on the books selected on a file shelf.
extension _LibraryPageBatch on _LibraryPageState {
  Future<void> _batchBooks(String action) async {
    final chosen =
        books.where((book) => selectedBooks.contains(book.id)).toList()..sort(
          (a, b) => naturalAudioOrder(
            '${audioSourcePaths[a.id]?['relativePath'] ?? _title(a)}',
            '${audioSourcePaths[b.id]?['relativePath'] ?? _title(b)}',
          ),
        );
    if (chosen.isEmpty) return;
    if (action == 'merge') {
      final matchingRoot = roots
          .where(
            (root) => chosen.every((book) => root.bookIds.contains(book.id)),
          )
          .firstOrNull;
      final title = TextEditingController(
        text: matchingRoot?.title ?? _title(chosen.first),
      );
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Объединить аудиокниги'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Треки будут идти в показанном порядке. Исходные карточки скроются; позиции, события и заметки перейдут в объединённую книгу.',
                ),
                const SizedBox(height: 12),
                Text(chosen.map((book) => _title(book)).join(' → ')),
                TextField(
                  controller: title,
                  decoration: const InputDecoration(
                    labelText: 'Название книги',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Объединить'),
            ),
          ],
        ),
      );
      if (confirmed != true) {
        title.dispose();
        return;
      }
      final name = title.text;
      title.dispose();
      await _action(() async {
        await widget.audio?.stop();
        final id = await AudioMerge(widget.assets!)
            .merge(chosen.map((book) => book.id).toList(), name);
        await widget.audio?.sidecar.update(id, force: true);
        if (mounted) _update(selectedBooks.clear);
      });
      return;
    }
    if (action == 'delete') {
      await _deleteBooks(chosen);
      return;
    }
    await _action(() async {
      if (action == 'hide') {
        final ids = chosen.map((book) => book.id).toList();
        final actions = reading
            ? ReadingBookActions(widget.assets!)
            : AudioBookActions(widget.assets!);
        await actions.hideMany(ids);
        if (mounted) {
          _update(selectedBooks.clear);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              // Flutter keeps snack bars with an action until dismissed.
              persist: false,
              content: Text('Скрыто с полки: ${ids.length}'),
              action: SnackBarAction(
                label: 'Вернуть',
                onPressed: () =>
                    _action(() => actions.hideMany(ids, hidden: false)),
              ),
            ),
          );
        }
        return;
      }
      for (final book in chosen) {
        if (action == 'favorite') {
          final prefix = reading ? 'reading' : 'audio';
          await readingLibrary.update('$prefix-book:${book.id}', {
            'favorite': true,
          });
        } else {
          await widget.repository.put('book', book.id, {
            ...book.payload!,
            'status': action,
          });
          if (reading) {
            final prefs = await readingLibrary.value('reading-book:${book.id}');
            await readingLibrary.update('reading-book:${book.id}', {
              'overrides': {
                ...Map<String, dynamic>.from(prefs['overrides'] as Map? ?? {}),
                'status': action,
              },
            });
          } else {
            await widget.repository.setMeta(
              'audio-status-override:${book.id}',
              action,
            );
          }
        }
      }
      if (mounted) _update(selectedBooks.clear);
    });
  }

  Future<void> _deleteBooks(List<LibraryRecord> chosen) async {
    final assets = widget.assets;
    if (assets == null || chosen.isEmpty) return;
    List<String> moved = const [];
    await _action(() async {
      moved = await deleteBooksToTrash(context, assets, [
        for (final book in chosen)
          (
            id: book.id,
            title: _title(book),
            audio: book.payload?['format'] == 'audio',
            hasFile:
                shelfSources.first(book.id) != null ||
                (book.payload?['format'] == 'audio' &&
                    audioSourcePaths.containsKey(book.id)),
          ),
      ], beforeDelete: _checkBookClosed);
      if (mounted && moved.isNotEmpty) _update(selectedBooks.clear);
    });
    if (mounted) showMovedToTrash(context, assets, moved, onRestored: _reload);
  }
}
