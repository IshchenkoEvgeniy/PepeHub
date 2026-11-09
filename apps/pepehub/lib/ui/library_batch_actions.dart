import 'package:flutter/material.dart';

import '../library/library_features.dart';
import '../library/library_service.dart';
import '../library/metadata_values.dart';
import 'library_card_actions.dart';
import '../diagnostics/user_message.dart';

Future<void> libraryBatchAction(
  BuildContext context,
  LibraryService library,
  Iterable<String> selected,
  String action,
) async {
  final ids = selected.toList();
  if (ids.isEmpty) return;
  try {
    if (action == 'delete') {
      await deleteLibraryCards(context, library, ids, allowFileDeletion: false);
      return;
    }
    if (action == 'favorite' || action == 'hide' || action == 'show') {
      await library.editCards(ids, {
        action == 'favorite' ? 'pepehub_favorite' : 'pepehub_hidden':
            action != 'show',
      });
      return;
    }
    if (action == 'dates') {
      final changed = await library.fillDatesFromJournal(ids);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              changed == 0
                  ? 'В журнале нет данных для пустых дат'
                  : 'Даты заполнены из журнала: $changed',
            ),
          ),
        );
      }
      return;
    }
    if (action == 'status') {
      final selectedIds = ids.toSet();
      final cards = library.entries
          .where((e) => selectedIds.contains(e.item.id))
          .toList();
      final types = cards.map((e) => e.item.mediaType).toSet();
      final statuses =
          cards.length == selectedIds.length &&
              cards.every(
                (e) => libraryItemStatuses(e.item).containsKey('unread'),
              )
          ? seriesVolumeStatuses(types.length == 1 ? types.single : 'all')
          : libraryStatusesLocal;
      final status = await showDialog<String>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text('Статус · ${ids.length}'),
          children: [
            for (final entry in statuses.entries)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, entry.key),
                child: Text(entry.value),
              ),
          ],
        ),
      );
      if (status != null) await library.editCards(ids, {'status': status});
      return;
    }
    final label = action == 'author'
        ? 'Автор'
        : action == 'series'
        ? 'Серия'
        : 'Название коллекции';
    final text = TextEditingController();
    final existing = action == 'collection'
        ? library.visibleEntries
              .expand((e) => libraryCollections(e.item))
              .toSet()
              .toList()
        : library.suggestions[action] ?? [];
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('$label · ${ids.length}'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: text,
                  maxLength: 500,
                  decoration: InputDecoration(
                    labelText: label,
                    helperText: action == 'author'
                        ? 'Несколько авторов — через ;'
                        : null,
                  ),
                ),
                if (action != 'collection')
                  const Text('Значение заменится у всех выбранных карточек.'),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final item in existing.take(12))
                      ActionChip(
                        label: Text(item),
                        onPressed: () => text.text = item,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              if (text.text.trim().isNotEmpty) {
                Navigator.pop(context, text.text.trim());
              }
            },
            child: const Text('Применить'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    text.dispose();
    if (value == null) return;
    if (action == 'collection') {
      await library.editCards(ids, {}, addCollection: value);
    } else {
      await library.editCards(ids, {
        action: action == 'author' ? metadataStrings(value) : value,
      });
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(describeError(e))));
    }
  }
}

const libraryBatchLabels = {
  'collection': 'Добавить в коллекцию',
  'author': 'Изменить автора',
  'series': 'Изменить серию',
  'status': 'Изменить статус',
  'dates': 'Заполнить даты из журнала',
  'favorite': 'В избранное',
  'hide': 'Скрыть',
  'show': 'Вернуть из скрытых',
  'delete': 'Удалить карточки…',
};
