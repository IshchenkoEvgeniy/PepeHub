import 'package:flutter/material.dart';

import '../library/library_service.dart';

class ObsidianNotesPage extends StatefulWidget {
  final LibraryService library;
  const ObsidianNotesPage({super.key, required this.library});
  @override
  State<ObsidianNotesPage> createState() => _ObsidianNotesPageState();
}

class _ObsidianNotesPageState extends State<ObsidianNotesPage> {
  List<Map<String, dynamic>> notes = [];
  String query = '', error = '';
  @override
  void initState() {
    super.initState();
    widget.library.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.library.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final values =
        await widget.library.notes?.entries() ?? <Map<String, dynamic>>[];
    if (mounted) setState(() => notes = values);
  }

  Future<void> _action(Future<void> Function() action) async {
    try {
      await action();
      await _load();
      await widget.library.sync();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Заметки Obsidian'),
      actions: [
        IconButton(
          tooltip: 'Синхронизировать',
          onPressed: () => _action(widget.library.sync),
          icon: const Icon(Icons.sync),
        ),
      ],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            decoration: const InputDecoration(
              labelText: 'Поиск по цитатам, заметкам и тегам',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (v) => setState(() => query = v.toLowerCase()),
          ),
        ),
        if (error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Expanded(
          child: notes.isEmpty
              ? const Center(
                  child: Text(
                    'Заметки связанных книг появятся после синхронизации.',
                  ),
                )
              : ListView(
                  children: [
                    for (final slot in notes)
                      if ('${slot['value']['title']} ${slot['value']['quote']} ${slot['value']['text']} ${slot['value']['tags']} ${slot['value']['characters']}'
                          .toLowerCase()
                          .contains(query))
                        Card(
                          margin: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 6,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: _note(slot),
                          ),
                        ),
                  ],
                ),
        ),
      ],
    ),
  );
  Widget _note(Map<String, dynamic> slot) {
    final value = Map<String, dynamic>.from(slot['value'] as Map),
        book = widget.library.entries
            .where((e) => e.item.id == value['itemId'])
            .firstOrNull
            ?.item
            .title;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          book ?? 'Книга Obsidian',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if ('${value['title']}'.isNotEmpty) Text('${value['title']}'),
        if ('${value['quote']}'.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: SelectableText('${value['quote']}'),
          ),
        SelectableText('${value['text']}'),
        if ((value['tags'] as List).isNotEmpty)
          Text('Теги: ${(value['tags'] as List).join(', ')}'),
        if ((value['characters'] as List).isNotEmpty)
          Text('Персонажи: ${(value['characters'] as List).join(', ')}'),
        if (slot['conflict'] != null) ...[
          const Text('Изменено с обеих сторон. Версия сервера:'),
          SelectableText(
            '${slot['conflict']['entry']['quote']}\n${slot['conflict']['entry']['text']}',
          ),
          Wrap(
            children: [
              for (final remote in [true, false])
                TextButton(
                  onPressed: () => _action(
                    () => widget.library.notes!.resolve(
                      value['id'] as String,
                      useRemote: remote,
                    ),
                  ),
                  child: Text(remote ? 'Взять с сервера' : 'Оставить мою'),
                ),
            ],
          ),
        ] else
          Wrap(
            children: [
              TextButton.icon(
                icon: const Icon(Icons.edit),
                label: const Text('Изменить'),
                onPressed: () async {
                  final changes = await showDialog<Map<String, dynamic>>(
                    context: context,
                    builder: (_) => _NoteEditor(value),
                  );
                  if (changes != null) {
                    await _action(
                      () => widget.library.notes!.edit(
                        value['id'] as String,
                        changes,
                      ),
                    );
                  }
                },
              ),
              TextButton.icon(
                icon: const Icon(Icons.delete_outline),
                label: const Text('Удалить'),
                onPressed: () async {
                  final yes = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Удалить заметку?'),
                      content: const Text(
                        'Удаление синхронизируется с Obsidian.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Отмена'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Удалить'),
                        ),
                      ],
                    ),
                  );
                  if (yes == true) {
                    await _action(
                      () => widget.library.notes!.edit(value['id'] as String, {
                        'deleted': true,
                      }),
                    );
                  }
                },
              ),
            ],
          ),
      ],
    );
  }
}

class _NoteEditor extends StatefulWidget {
  final Map<String, dynamic> value;
  const _NoteEditor(this.value);
  @override
  State<_NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<_NoteEditor> {
  late final controllers = {
    for (final key in ['title', 'quote', 'text', 'tags', 'characters'])
      key: TextEditingController(
        text: widget.value[key] is List
            ? (widget.value[key] as List).join(', ')
            : '${widget.value[key]}',
      ),
  };
  @override
  void dispose() {
    for (final c in controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Изменить заметку'),
    content: SizedBox(
      width: 550,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final field in {
              'title': 'Название',
              'quote': 'Цитата',
              'text': 'Комментарий',
              'tags': 'Теги',
              'characters': 'Персонажи',
            }.entries)
              if (field.key != 'quote' || widget.value['kind'] != 'audio')
                TextField(
                  controller: controllers[field.key],
                  minLines: field.key == 'text' || field.key == 'quote' ? 2 : 1,
                  maxLines: field.key == 'text' || field.key == 'quote' ? 8 : 1,
                  maxLength: field.key == 'title'
                      ? 200
                      : field.key == 'tags' || field.key == 'characters'
                      ? 1000
                      : field.key == 'text' && widget.value['kind'] == 'audio'
                      ? 10000
                      : 100000,
                  decoration: InputDecoration(labelText: field.value),
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
        onPressed: () => Navigator.pop(context, {
          for (final field in controllers.entries)
            field.key: field.key == 'tags' || field.key == 'characters'
                ? field.value.text
                      .split(',')
                      .map((v) => v.trim())
                      .where((v) => v.isNotEmpty)
                      .take(40)
                      .map((v) => v.substring(0, v.length.clamp(0, 80)))
                      .toList()
                : field.value.text,
        }),
        child: const Text('Сохранить'),
      ),
    ],
  );
}
