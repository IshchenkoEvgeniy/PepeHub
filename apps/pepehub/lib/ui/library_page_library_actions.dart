part of 'library_page.dart';

/// Adding shelf books and recommendations to the personal library.
extension _LibraryPageLibraryActions on _LibraryPageState {
  Future<void> _addToLibrary(LibraryRecord book) async {
    await personalLibrary.loadCached();
    if (!mounted) return;
    final linked =
        personalLibrary.forBook(book.id) ??
        personalLibrary.sourceDraft(book.id);
    if (linked != null &&
        isSeriesCatalogItem(linked.item) &&
        !isLibraryDeleted(linked.item) &&
        (isFinishedLibraryItem(linked.item) ||
            linked.item.values['pepehub_auto_discovered'] == false)) {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) =>
              LibraryWorkPage(library: personalLibrary, itemId: linked.item.id),
        ),
      );
      return;
    }
    if (linked != null && linked.state != 'removed') {
      final editableItem = linked.item.withValues({
        ...linked.item.values,
        'status': 'finished',
        'pepehub_deleted_at': null,
        'pepehub_recommendation_only': false,
      });
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => LibraryMetadataEditor(
            saveLabel: 'Добавить в библиотеку',
            coverResolver: personalLibrary.coverReferencePath,
            suggestions: personalLibrary.suggestions,
            seriesEntries: personalLibrary.seriesEntries,
            collection: personalLibrary.collectionFor(linked.item),
            collections:
                (personalLibrary.snapshot?['collections'] as List? ?? [])
                    .map((c) => Map<String, dynamic>.from(c as Map))
                    .toList(),
            syncPolicy: personalLibrary.policies[linked.item.id] ?? const {},
            onSavePolicy: (policy) =>
                personalLibrary.savePolicy(linked.item.id, policy),
            onPickCover: personalLibrary.chooseCover,
            item: editableItem,
            entry: linked,
            onSave: (values) => personalLibrary.add(
              linked.item.withValues(values),
              book.id,
              original: linked.item.values,
            ),
          ),
        ),
      );
      return;
    }
    // Link a file to an existing personal card rather than duplicating it.
    if (personalLibrary.entries.any(
      (e) => e.state == 'synced' && e.sourceBookId == null,
    )) {
      final choice = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('Добавить в библиотеку'),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 'create'),
              child: const Text('Создать карточку в библиотеке'),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 'link'),
              child: const Text('Связать с существующей карточкой'),
            ),
          ],
        ),
      );
      if (!mounted || choice == null) return;
      if (choice == 'link') {
        final id = await showDialog<String>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('Карточка библиотеки'),
            children: [
              for (final entry in personalLibrary.entries.where(
                (e) => e.state == 'synced' && e.sourceBookId == null,
              ))
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, entry.item.id),
                  child: Text(
                    '${entry.item.title}\n${entry.item.authors}\n${entry.item.path}',
                  ),
                ),
            ],
          ),
        );
        if (id != null && mounted) {
          final target = personalLibrary.entries
              .where((e) => e.item.id == id)
              .first
              .item;
          final preview = await personalLibrary.previewLink(book, target);
          if (!mounted) return;
          final policy = await reviewLibraryLink(context, target, preview);
          if (policy != null) {
            await personalLibrary.link(id, book.id, policy: policy);
          }
        }
        return;
      }
    }
    final source = await personalLibrary.prepareDraft(book);
    final draft = source.withValues({...source.values, 'status': 'finished'});
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => LibraryMetadataEditor(
          coverResolver: personalLibrary.coverReferencePath,
          suggestions: personalLibrary.suggestions,
          seriesEntries: personalLibrary.seriesEntries,
          collection: personalLibrary.collectionFor(draft),
          collections: (personalLibrary.snapshot?['collections'] as List? ?? [])
              .map((c) => Map<String, dynamic>.from(c as Map))
              .toList(),
          onSavePolicy: (policy) =>
              personalLibrary.savePolicy(draft.id, policy),
          onPickCover: personalLibrary.chooseCover,
          item: draft,
          saveLabel: 'Добавить в библиотеку',
          onSave: (values) => personalLibrary.add(
            draft.withValues(values),
            book.id,
            original: draft.values,
          ),
        ),
      ),
    );
  }

  Future<void> _archiveRecommendation(RecommendedBook book) async {
    final audio = await showDialog<bool>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Сохранить результат'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Книга прочитана'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Аудиокнига прослушана'),
          ),
        ],
      ),
    );
    if (audio == null || !mounted) return;
    await personalLibrary.reload();
    final draft = personalLibrary.fromRecommendation(book, audio: audio);
    final existing = personalLibrary.entries
        .where((e) => e.item.id == draft.id)
        .firstOrNull;
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => LibraryMetadataEditor(
          item: draft,
          collection: personalLibrary.collectionFor(draft),
          suggestions: personalLibrary.suggestions,
          seriesEntries: personalLibrary.seriesEntries,
          coverResolver: personalLibrary.coverReferencePath,
          onPickCover: personalLibrary.chooseCover,
          saveLabel: 'Сохранить в библиотеке',
          onSave: (values) => existing == null
              ? personalLibrary.add(draft.withValues(values), '')
              : personalLibrary.save(
                  existing.item.id,
                  values,
                  original: existing.item.values,
                ),
        ),
      ),
    );
  }
}
