part of 'library_page.dart';

/// The per-book menu and the actions behind it.
extension _LibraryPageBookMenu on _LibraryPageState {
  Future<void> _deletedBookInfo(LibraryRecord book) async {
    final add = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Файл книги удалён'),
        content: SingleChildScrollView(
          child: Text(
            '«${_title(book)}»\n\nПрогресс, заметки и статистика сохранены. Добавьте тот же файл заново или верните его в подключённую папку и обновите её. Файл с другим содержимым будет отдельной книгой.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Закрыть'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Добавить файл'),
          ),
        ],
      ),
    );
    if (add == true && mounted) await _importBook();
  }

  Future<void> _bookSource(LibraryRecord book) async {
    final canHide =
        widget.assets != null && !deletedReadingBooks.contains(book.id);
    final files = shelfSources.byBook[book.id] ?? <LocalAsset>[];
    final connected = roots.where((r) => r.bookIds.contains(book.id)).toList();
    final lines = <String>[
      if (files.isEmpty) 'Карточка без подключённого файла.',
      if (connected.isEmpty)
        'Связи с папкой библиотеки на этом устройстве нет.',
      for (final root in connected)
        'Папка библиотеки: ${root.title}\n${root.path}',
    ];
    for (final file in files) {
      bool available;
      try {
        available = await audioSourceExists(file.path);
      } catch (_) {
        available = false;
      }
      lines.add(
        '${widget.assets?.isManagedBookPath(file) == true ? 'Копия внутри приложения' : 'Подключённый файл'}: ${file.filename}\n${file.path}\n${available ? 'Доступен' : 'Нет доступа или файл отсутствует'} · ${file.bytes} байт',
      );
    }
    final source = readingSourcePaths[book.id];
    if (source != null) {
      lines.add(
        'Последний подключённый источник: ${source['root']}\n${source['relativePath']}',
      );
    }
    if (!mounted) return;
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Источник и файл'),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: SelectableText(
              '${_title(book)}\n\n${lines.join('\n\n')}${canHide ? '\n\n«Скрыть с полки» скрывает карточку только на этом устройстве. Файлы, заметки и история сохраняются.' : ''}',
            ),
          ),
        ),
        actions: [
          if (files.isNotEmpty)
            TextButton(
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(this.context);
                try {
                  await Clipboard.setData(
                    ClipboardData(text: files.map((f) => f.path).join('\n')),
                  );
                  if (!mounted) return;
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(
                        files.length == 1
                            ? 'Путь скопирован'
                            : 'Пути скопированы',
                      ),
                    ),
                  );
                } catch (error) {
                  if (!mounted) return;
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(
                        'Не удалось скопировать путь: ${describeError(error)}',
                      ),
                    ),
                  );
                }
              },
              child: const Text('Копировать путь'),
            ),
          if (canHide)
            TextButton(
              onPressed: () => Navigator.pop(context, 'hide-book'),
              child: const Text('Скрыть с полки'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
    if (action != null && mounted) await _bookMenu(book, action);
  }

  Future<void> _bookMenu(LibraryRecord book, String value) async {
    if (value == 'source') {
      await _bookSource(book);
      return;
    }
    if (value == 'restore-deleted') {
      await _importBook();
      return;
    }
    if (value == 'delete-library-card') {
      final entry = personalLibrary.sourceDraft(book.id);
      if (entry == null || !isSeriesCatalogItem(entry.item)) return;
      await deleteLibraryCards(
        context,
        personalLibrary,
        [entry.item.id],
        fromTrash: isLibraryDeleted(entry.item),
        checkBookClosed: () => _checkBookClosed(book.id),
      );
      return;
    }
    if (value == 'hide-book' ||
        value == 'delete-book' ||
        value == 'reveal-book') {
      if (widget.assets == null) return;
      final audio = book.payload?['format'] == 'audio';
      final actions = audio
          ? AudioBookActions(widget.assets!)
          : ReadingBookActions(widget.assets!);
      if (value == 'reveal-book') {
        await _action(() => actions.reveal(book.id));
        return;
      }
      if (value == 'delete-book') {
        await _deleteBooks([book]);
        return;
      }
      await _action(() async {
        if (audio && widget.audio?.current?.bookId == book.id) {
          await widget.audio!.stop();
        }
        _checkBookClosed(book.id);
        await actions.hide(book.id);
      });
      if (value == 'hide-book' && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            // Flutter keeps snack bars with an action until dismissed.
            persist: false,
            content: const Text(
              'Книга скрыта с полки. Файл и история сохранены.',
            ),
            action: SnackBarAction(
              label: 'Вернуть',
              onPressed: () =>
                  _action(() => actions.hide(book.id, hidden: false)),
            ),
          ),
        );
      }
      return;
    }
    if (value == 'obsidian') {
      try {
        await _addToLibrary(book);
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Не удалось добавить в библиотеку: ${describeError(error)}',
              ),
            ),
          );
        }
      }
      return;
    }
    if (value == 'share') {
      await _action(() async {
        final files = book.payload!['format'] == 'audio'
            ? await widget.assets!.audioTracks(book.id)
            : shelfSources.byBook[book.id] ?? <LocalAsset>[];
        await shareBookFiles(files);
      });
      return;
    }
    if (value == 'reading-plan') {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) =>
              ReadingPlanPage(repository: widget.repository, bookId: book.id),
        ),
      );
      return;
    }
    if (value == 'details') {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => ReadingBookPage(
            repository: widget.repository,
            book: book,
            assets: widget.assets,
            asset: shelfSources.first(book.id),
          ),
        ),
      );
      await _reload();
      return;
    }
    if (value == 'favorite') {
      final prefix = book.payload!['format'] == 'audio' ? 'audio' : 'reading';
      await _action(
        () => readingLibrary.update('$prefix-book:${book.id}', {
          'favorite': bookPrefs[book.id]?['favorite'] != true,
        }),
      );
      return;
    }
    if (value == 'collections') {
      await showLibraryCollections(
        context,
        widget.repository,
        bookId: book.id,
        audio: book.payload!['format'] == 'audio',
      );
      await _reload();
      return;
    }
    if (value == 'metadata') {
      final asset = shelfSources.first(book.id);
      if (asset != null && widget.assets != null) {
        await _action(
          () => readingLibrary.index(widget.assets!, asset, retry: true),
        );
      }
      return;
    }
    if (value == 'session') {
      await _addSession(book);
      return;
    }
    if (value == 'reconnect') {
      await _reconnectAudio(book);
      return;
    }
    if (value == 'folder') {
      if (widget.assets == null) return;
      await _action(
        () => showBookFolderDialog(
          context,
          widget.assets!,
          widget.audio,
          book.id,
        ),
      );
      return;
    }
    await _action(() async {
      await widget.repository.db.transaction(() async {
        await widget.repository.put('book', book.id, {
          ...book.payload!,
          'status': value,
          'finishedAt': value == 'finished'
              ? (book.payload?['finishedAt'] ??
                    DateTime.now().toUtc().toIso8601String())
              : null,
        });
        if (book.payload!['format'] == 'audio') {
          await widget.repository.setMeta(
            'audio-status-override:${book.id}',
            value,
          );
        } else {
          final prefs = await readingLibrary.value('reading-book:${book.id}');
          await readingLibrary.update('reading-book:${book.id}', {
            'overrides': {
              ...Map<String, dynamic>.from(prefs['overrides'] as Map? ?? {}),
              'status': value,
              'finishedAt': value == 'finished'
                  ? ((prefs['overrides'] as Map?)?['finishedAt'] ??
                        DateTime.now().toUtc().toIso8601String())
                  : null,
            },
          });
        }
      });
    });
    await personalLibrary.reload();
  }

  Widget _bookMenuButton(LibraryRecord book) {
    final audio = book.payload!['format'] == 'audio';
    final asset = shelfSources.first(book.id);
    final deleted = !audio && deletedReadingBooks.contains(book.id);
    return IconButton(
      tooltip: 'Действия с книгой',
      icon: const Icon(Icons.more_vert),
      onPressed: () async {
        final action = await showBookActionMenu(
          context: context,
          repository: widget.repository,
          title: _title(book),
          audio: audio,
          available: {
            if (deleted && widget.assets != null)
              'restore-deleted': 'Добавить файл заново',
            'obsidian':
                personalLibrary.sourceDraft(book.id) != null &&
                    isUnreadSeriesItem(
                      personalLibrary.sourceDraft(book.id)!.item,
                    ) &&
                    !isLibraryDeleted(
                      personalLibrary.sourceDraft(book.id)!.item,
                    )
                ? 'Карточка серии'
                : personalLibrary.forBook(book.id) == null ||
                      personalLibrary.forBook(book.id)!.state == 'removed' ||
                      (!isFinishedLibraryItem(
                            personalLibrary.forBook(book.id)!.item,
                          ) &&
                          personalLibrary
                                  .forBook(book.id)!
                                  .item
                                  .values['pepehub_auto_discovered'] !=
                              false)
                ? 'Добавить в библиотеку'
                : isLibraryDeleted(personalLibrary.forBook(book.id)!.item)
                ? 'Вернуть в библиотеку'
                : libraryState(personalLibrary.forBook(book.id)!),
            if (!deleted &&
                Platform.isAndroid &&
                widget.assets != null &&
                asset != null)
              'share': 'Поделиться файлом книги',
            'favorite': bookPrefs[book.id]?['favorite'] == true
                ? 'Убрать из избранного'
                : 'В избранное',
            'collections': 'Коллекции книги',
            if (personalLibrary.sourceDraft(book.id) case final entry?
                when isSeriesCatalogItem(entry.item))
              'delete-library-card': 'Удалить карточку библиотеки…',
            if (!audio) ...{
              'source': 'Источник и файл',
              if (widget.assets != null &&
                  asset != null &&
                  (!Platform.isAndroid ||
                      asset.path.startsWith('content:') ||
                      readingSourcePaths.containsKey(book.id)))
                'reveal-book': Platform.isAndroid
                    ? 'Показать папку файла'
                    : 'Показать в проводнике',
              'details': 'Карточка книги',
              'reading-plan': 'План чтения',
              if (!deleted && asset != null)
                'metadata': 'Обновить сведения из файла',
              if (widget.assets != null) ...{
                if (!deleted) 'hide-book': 'Скрыть с полки',
                'delete-book': 'Удалить…',
              },
            },
            'planned': 'Отметить новой',
            'active': 'Отметить начатой',
            'paused': 'Отложить',
            'abandoned': 'Отметить брошенной',
            'finished': 'Отметить завершённой',
            'session': 'Записать сессию',
            if (audio) ...{
              if (widget.assets != null) ...{
                'hide-book': 'Скрыть с полки',
                'delete-book': 'Удалить…',
              },
              'folder': 'Переименовать / переместить папку',
              'reconnect': 'Указать папку заново',
            },
          },
        );
        if (mounted && action != null) await _bookMenu(book, action);
      },
    );
  }
}
