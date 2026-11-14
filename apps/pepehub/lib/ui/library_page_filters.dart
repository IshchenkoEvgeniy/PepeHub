part of 'library_page.dart';

/// Filter chips, the filter sheet and the shelf view switch.
extension _LibraryPageFilters on _LibraryPageState {
  /// Active filters as removable chips under the search field.
  List<Widget> _activeFilters() {
    if (_activeFilterCount == 0) return const [SizedBox(height: 12)];
    final root = roots.where((r) => r.key == selectedRoot).firstOrNull;
    final collection = collections[collectionFilter]?['name'] as String?;
    return [
      const SizedBox(height: 6),
      Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (selectedRoot != null)
            InputChip(
              key: const ValueKey('active-folder-filter'),
              avatar: const Icon(Icons.folder_outlined, size: 18),
              label: Text(
                'Папка: ${root?.title ?? selectedRoot}',
                overflow: TextOverflow.ellipsis,
              ),
              onDeleted: () => _update(() => selectedRoot = null),
              deleteButtonTooltipMessage: 'Показать всю библиотеку',
            ),
          if (reading && filter != 'all')
            InputChip(
              key: const ValueKey('active-format-filter'),
              label: Text('Формат: ${formatLabel(filter)}'),
              onDeleted: () => _update(() => filter = 'all'),
              deleteButtonTooltipMessage: 'Сбросить формат',
            ),
          if (collectionFilter != null)
            InputChip(
              key: const ValueKey('active-collection-filter'),
              avatar: const Icon(Icons.collections_bookmark_outlined, size: 18),
              label: Text('Коллекция: ${collection ?? ''}'),
              onDeleted: () => _update(() => collectionFilter = null),
              deleteButtonTooltipMessage: 'Сбросить коллекцию',
            ),
          if (favoritesOnly)
            InputChip(
              key: const ValueKey('active-favorites-filter'),
              avatar: const Icon(Icons.star, size: 18),
              label: const Text('Только избранное'),
              onDeleted: () => _update(() => favoritesOnly = false),
              deleteButtonTooltipMessage: 'Показать все книги',
            ),
          TextButton(
            key: const ValueKey('shelf-reset-filters'),
            onPressed: _resetFilters,
            child: const Text('Сбросить всё'),
          ),
        ],
      ),
      const SizedBox(height: 12),
    ];
  }

  Future<void> _showFilters() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setSheet) {
        void apply(VoidCallback change) {
          _update(change);
          setSheet(() {});
        }

        final labelStyle = Theme.of(sheetContext).textTheme.labelLarge;
        Widget section(String title, List<Widget> children) => Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: labelStyle),
              const SizedBox(height: 8),
              ...children,
            ],
          ),
        );
        Widget choices<T>(
          Map<T, String> options,
          T selected,
          ValueChanged<T> select,
        ) => Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final entry in options.entries)
              ChoiceChip(
                label: Text(entry.value),
                selected: selected == entry.key,
                showCheckmark: false,
                onSelected: (_) => apply(() => select(entry.key)),
              ),
          ],
        );
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Фильтры',
                        style: Theme.of(sheetContext).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 16),
                      if (roots.isNotEmpty)
                        section('Папка', [
                          Row(
                            children: [
                              Expanded(
                                child: DropdownButton<String?>(
                                  key: const ValueKey('library-folder'),
                                  isExpanded: true,
                                  value: selectedRoot,
                                  items: [
                                    const DropdownMenuItem<String?>(
                                      value: null,
                                      child: Text('Вся библиотека'),
                                    ),
                                    for (final root in roots)
                                      DropdownMenuItem(
                                        value: root.key,
                                        child: Text(
                                          root.title,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                  ],
                                  onChanged: (v) =>
                                      apply(() => selectedRoot = v),
                                ),
                              ),
                              IconButton(
                                key: const ValueKey('library-pin-folder'),
                                tooltip: selectedRoot == null
                                    ? 'Открывать всю библиотеку по умолчанию'
                                    : selectedRoot == pinnedRoot
                                    ? 'Открепить папку по умолчанию'
                                    : 'Открывать эту папку по умолчанию',
                                onPressed:
                                    busy ||
                                        (selectedRoot == null &&
                                            pinnedRoot == null)
                                    ? null
                                    : () async {
                                        await _pinFolder();
                                        setSheet(() {});
                                      },
                                icon: Icon(
                                  selectedRoot != null &&
                                          selectedRoot == pinnedRoot
                                      ? Icons.push_pin
                                      : Icons.push_pin_outlined,
                                ),
                              ),
                            ],
                          ),
                        ]),
                      if (reading)
                        section('Формат', [
                          choices<String>(
                            {'all': 'Все форматы', ...bookFormats},
                            filter,
                            (v) => filter = v,
                          ),
                        ]),
                      section('Коллекция', [
                        if (collections.isNotEmpty)
                          choices<String?>(
                            {
                              null: 'Все коллекции',
                              for (final e in collections.entries)
                                e.key: e.value['name'] as String,
                            },
                            collectionFilter,
                            (v) => collectionFilter = v,
                          ),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            key: const ValueKey('manage-collections'),
                            onPressed: () async {
                              await showLibraryCollections(
                                sheetContext,
                                widget.repository,
                                audio: !reading,
                              );
                              await _reload();
                              if (sheetContext.mounted) setSheet(() {});
                            },
                            icon: const Icon(
                              Icons.collections_bookmark_outlined,
                            ),
                            label: Text(
                              collections.isEmpty
                                  ? 'Создать коллекцию'
                                  : 'Управлять коллекциями',
                            ),
                          ),
                        ),
                      ]),
                      SwitchListTile.adaptive(
                        key: const ValueKey('filter-favorites'),
                        contentPadding: EdgeInsets.zero,
                        secondary: const Icon(Icons.star_outline),
                        title: const Text('Только избранное'),
                        value: favoritesOnly,
                        onChanged: (v) => apply(() => favoritesOnly = v),
                      ),
                    ],
                  ),
                ),
              ),
              // Kept outside the scroll view: always reachable with large text.
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: OverflowBar(
                  alignment: MainAxisAlignment.spaceBetween,
                  overflowAlignment: OverflowBarAlignment.end,
                  overflowSpacing: 4,
                  children: [
                    TextButton(
                      onPressed: _activeFilterCount == 0
                          ? null
                          : () {
                              _resetFilters();
                              setSheet(() {});
                            },
                      child: const Text('Сбросить всё'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(sheetContext),
                      child: const Text('Готово'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    ),
  );

  Widget _viewChoices() => LayoutBuilder(
    builder: (context, size) {
      final series = shelfView == 'series';
      final grid = !series && _useCovers(size.maxWidth);
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Список',
            visualDensity: VisualDensity.compact,
            isSelected: !grid && !series,
            onPressed: busy || savingView ? null : () => _setShelfView('list'),
            icon: const Icon(Icons.view_list_outlined),
            selectedIcon: const Icon(Icons.view_list),
          ),
          IconButton(
            tooltip: 'Обложки',
            visualDensity: VisualDensity.compact,
            isSelected: grid,
            onPressed: busy || savingView
                ? null
                : () => _setShelfView('covers'),
            icon: const Icon(Icons.grid_view_outlined),
            selectedIcon: const Icon(Icons.grid_view),
          ),
          IconButton(
            key: const ValueKey('shelf-view-series'),
            tooltip: 'Серии',
            visualDensity: VisualDensity.compact,
            isSelected: series,
            onPressed: busy || savingView
                ? null
                : () => _setShelfView('series'),
            icon: const Icon(Icons.collections_bookmark_outlined),
            selectedIcon: const Icon(Icons.collections_bookmark),
          ),
        ],
      );
    },
  );
}
