import 'package:flutter/material.dart';

import '../library/library_features.dart';
import '../library/library_service.dart';
import '../library/metadata_values.dart';
import '../library/models.dart';
import '../library/personal_library.dart';
import '../library/reading_insights.dart';
import 'book_activity_summary.dart';
import 'activity_page.dart';
import 'library_audio_time_sheet.dart';
import 'library_card_actions.dart';
import 'library_cover_search.dart';
import 'library_groups_page.dart';
import 'obsidian_library_dashboard.dart'
    show ShelfBookCover, metadataProgressLabel;
import 'obsidian_library_page.dart' show LibraryMetadataEditor;

Future<void> editLibraryEntry(
  BuildContext context,
  LibraryService library,
  LibraryEntry entry,
) => Navigator.push<void>(
  context,
  MaterialPageRoute(
    builder: (routeContext) => LibraryMetadataEditor(
      item: entry.item,
      entry: entry,
      collection: library.collectionFor(entry.item),
      suggestions: library.suggestions,
      coverResolver: library.coverReferencePath,
      onPickCover: library.chooseCover,
      onSearchCover: () => Navigator.push<String>(
        routeContext,
        MaterialPageRoute(
          builder: (_) =>
              LibraryCoverSearch(library: library, item: entry.item),
        ),
      ),
      onDelete: () =>
          deleteLibraryCards(routeContext, library, [entry.item.id]),
      onSave: (values) =>
          library.save(entry.item.id, values, original: entry.item.values),
    ),
  ),
);

class LibraryWorkPage extends StatefulWidget {
  final LibraryService library;
  final String itemId;
  const LibraryWorkPage({
    super.key,
    required this.library,
    required this.itemId,
  });
  @override
  State<LibraryWorkPage> createState() => _LibraryWorkPageState();
}

class _LibraryWorkPageState extends State<LibraryWorkPage> {
  List<Map<String, dynamic>> notes = [], history = [];
  String? error;
  int generation = 0;
  bool busy = false;
  LibraryEntry? get card => widget.library.entries
      .where((e) => e.item.id == widget.itemId)
      .firstOrNull;
  @override
  void initState() {
    super.initState();
    widget.library.addListener(_changed);
    _changed();
  }

  @override
  void dispose() {
    generation++;
    widget.library.removeListener(_changed);
    super.dispose();
  }

  Future<void> _changed() async {
    final current = ++generation;
    if (mounted) setState(() {});
    try {
      await widget.library.history!.capture();
      await widget.library.notes!.capture();
      final sessions = await widget.library.history!.entries(
        itemId: widget.itemId,
      );
      final quotes = await widget.library.notes!.entries(itemId: widget.itemId);
      if (mounted && current == generation) {
        setState(() {
          history = sessions;
          notes = quotes;
        });
      }
    } catch (e) {
      if (mounted && current == generation) setState(() => error = '$e');
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
      await _changed();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _review(LibraryEntry entry) async {
    final text = TextEditingController(
      text: '${entry.item.values['notes'] ?? ''}',
    );
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Впечатления о книге'),
        content: SizedBox(
          width: 500,
          child: TextField(
            controller: text,
            minLines: 4,
            maxLines: 12,
            maxLength: 100000,
            decoration: const InputDecoration(hintText: 'Что запомнилось?'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, text.text),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    text.dispose();
    if (value != null) {
      await _run(
        () => widget.library.save(entry.item.id, {
          ...entry.item.values,
          'notes': value,
        }, original: entry.item.values),
      );
    }
  }

  Future<void> _reread(LibraryEntry entry) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Завершено ещё одно прочтение?'),
        content: const Text(
          'Счётчик перечитываний увеличится на один. Дата завершения станет сегодняшней; прежняя дата сохранится в истории завершений.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Подтвердить'),
          ),
        ],
      ),
    );
    if (yes == true) {
      await _run(
        () => widget.library.editCards([entry.item.id], {}, reread: true),
      );
    }
  }

  void _group(String kind, String name) => Navigator.push(
    context,
    MaterialPageRoute(
      builder: (_) =>
          LibraryGroupsPage(library: widget.library, kind: kind, name: name),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final entry = card;
    if (entry == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Книга')),
        body: const Center(child: Text('Карточка не найдена')),
      );
    }
    final item = entry.item, library = widget.library;
    final status = libraryStatus(item);
    final dailyHistory = groupBookActivity(history);
    final progress = num.tryParse('${item.value('progress') ?? ''}');
    final total = num.tryParse('${item.value('total') ?? ''}');
    final dates = {
      'Добавлена': bookDateLabel(libraryAddedAt(item)),
      'Начало': bookDateLabel(item.value('startDate')),
      'Завершение': bookDateLabel(item.value('endDate')),
    };
    return Scaffold(
      appBar: AppBar(
        title: const Text('Карточка произведения'),
        actions: [
          IconButton(
            tooltip: 'Редактировать',
            onPressed: busy
                ? null
                : () => editLibraryEntry(context, library, entry),
            icon: const Icon(Icons.edit_outlined),
          ),
          PopupMenuButton<String>(
            enabled: !busy,
            onSelected: (action) async {
              if (action == 'delete') {
                await deleteLibraryCards(context, library, [item.id]);
              }
              if (!context.mounted) return;
              if (action == 'cover') {
                final cover = await Navigator.push<String>(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        LibraryCoverSearch(library: library, item: item),
                  ),
                );
                if (cover != null) {
                  await _run(
                    () => library.save(item.id, {
                      ...item.values,
                      'cover': cover,
                    }, original: item.values),
                  );
                }
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'cover',
                child: Text('Найти обложку в интернете'),
              ),
              PopupMenuItem(value: 'delete', child: Text('В корзину')),
            ],
          ),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 850),
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (isLibraryDeleted(item))
                Card(
                  child: ListTile(
                    title: const Text('Карточка в корзине'),
                    trailing: TextButton(
                      onPressed: () => _run(() => library.restoreCard(item.id)),
                      child: const Text('Восстановить'),
                    ),
                  ),
                ),
              Center(
                child: ShelfBookCover(
                  title: item.title,
                  mediaType: item.mediaType,
                  cover: '${item.value('cover') ?? ''}',
                  localPath: library.coverPath(item),
                  width: 140,
                  height: 210,
                ),
              ),
              const SizedBox(height: 16),
              SelectableText(
                item.title,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              Wrap(
                spacing: 6,
                children: [
                  for (final author in metadataStrings(item.value('author')))
                    ActionChip(
                      label: Text(author),
                      onPressed: () => _group('author', author),
                    ),
                ],
              ),
              if ('${item.value('series') ?? ''}'.trim().isNotEmpty)
                ActionChip(
                  label: Text(
                    'Серия: ${item.value('series')}${item.value('seriesIndex') == null ? '' : ' · ${item.value('seriesIndex')}'}',
                  ),
                  onPressed: () => _group('series', '${item.value('series')}'),
                ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: ValueKey('work-status:$status'),
                initialValue: libraryStatusesLocal.containsKey(status)
                    ? status
                    : null,
                decoration: const InputDecoration(labelText: 'Статус'),
                items: [
                  for (final e in libraryStatusesLocal.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: busy
                    ? null
                    : (value) => _run(
                        () => library.editCards([item.id], {'status': value}),
                      ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  Chip(
                    label: Text(
                      'Оценка: ${item.value('rating') ?? 'не указана'}',
                    ),
                  ),
                  Chip(
                    label: Text(
                      item.mediaType == 'audiobook' ? 'Аудиокнига' : 'Книга',
                    ),
                  ),
                  ActionChip(
                    avatar: Icon(
                      item.values['pepehub_favorite'] == true
                          ? Icons.favorite
                          : Icons.favorite_border,
                      size: 18,
                    ),
                    label: const Text('Избранное'),
                    onPressed: () => _run(() => library.favorite(item.id)),
                  ),
                  for (final collection in libraryCollections(item))
                    ActionChip(
                      label: Text(collection),
                      onPressed: () => _group('collection', collection),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text('Общий прогресс: ${metadataProgressLabel(item)}'),
              if (progress != null && total != null && total > 0) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: (progress / total).clamp(0, 1).toDouble(),
                ),
                Text('${(progress / total * 100).clamp(0, 100).round()} %'),
              ],
              if (item.mediaType == 'audiobook' &&
                  ['', 'minutes', 'hours'].contains(item.value('unit') ?? ''))
                TextButton(
                  onPressed: () =>
                      editLibraryAudioTime(context, library, entry),
                  child: const Text('Изменить время прослушивания'),
                ),
              const Divider(height: 32),
              for (final e in dates.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('${e.key}: ${e.value}'),
                ),
              Text('Перечитываний: ${libraryRereads(item)}'),
              TextButton.icon(
                onPressed: busy ? null : () => _reread(entry),
                icon: const Icon(Icons.repeat),
                label: const Text('Завершено ещё раз'),
              ),
              if (item.values['pepehub_completions'] is List) ...[
                const Text('История завершений'),
                for (final value
                    in (item.values['pepehub_completions'] as List)
                        .whereType<Map>()
                        .toList()
                        .reversed)
                  Text(
                    '${bookDateLabel(value['date'])} · оценка: ${value['rating'] ?? '—'}',
                  ),
              ],
              const Divider(height: 32),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Впечатления'),
                trailing: IconButton(
                  tooltip: 'Изменить впечатления',
                  onPressed: () => _review(entry),
                  icon: const Icon(Icons.edit_outlined),
                ),
              ),
              SelectableText(
                '${item.values['notes'] ?? ''}'.isEmpty
                    ? 'Пока нет впечатлений.'
                    : '${item.values['notes']}',
              ),
              if ('${item.values['description'] ?? ''}'.isNotEmpty)
                ExpansionTile(
                  title: const Text('Описание'),
                  children: [SelectableText('${item.values['description']}')],
                ),
              const Divider(height: 32),
              Text(
                'Цитаты и заметки · ${notes.length}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (notes.isEmpty)
                const Text('Сохранённые цитаты появятся здесь.'),
              for (final slot in notes)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if ('${slot['value']['quote']}'.isNotEmpty)
                          SelectableText('${slot['value']['quote']}'),
                        if ('${slot['value']['text']}'.isNotEmpty)
                          SelectableText('${slot['value']['text']}'),
                      ],
                    ),
                  ),
                ),
              const Divider(height: 32),
              Text(
                'История чтения и прослушивания',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Text(
                '${dailyHistory.length} дней · ${bookActivityTime(dailyHistory.fold<int>(0, (sum, d) => sum + d.durationMs))}',
              ),
              if (dailyHistory.isEmpty) const Text('Сессий пока нет.'),
              for (final day in dailyHistory.take(7))
                BookActivityDayTile(
                  day: day,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ActivityPage(
                        library: library,
                        itemId: item.id,
                        initialDay: day.day,
                      ),
                    ),
                  ),
                ),
              OutlinedButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        ActivityPage(library: library, itemId: item.id),
                  ),
                ),
                child: const Text('Открыть весь журнал'),
              ),
              if (busy) const LinearProgressIndicator(),
              if (error != null)
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
