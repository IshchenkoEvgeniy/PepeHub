import 'package:flutter/material.dart';

import '../library/library_service.dart';
import 'pepe_widgets.dart';
import 'shelf_components.dart';

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
    await widget.library.notes?.capture();
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
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final wide = pepeWide(context);
    final visible = [
      for (final slot in notes)
        if ('${slot['value']['title']} ${slot['value']['quote']} ${slot['value']['text']} ${slot['value']['tags']} ${slot['value']['characters']}'
            .toLowerCase()
            .contains(query))
          slot,
    ];
    final conflicts = notes.where((n) => n['conflict'] != null).length;
    final pad = wide ? 28.0 : 16.0;
    return PepeSubpage(
      title: 'Цитаты и заметки',
      back: 'Библиотека',
      section: PepeSection.library,
      subtitle: notes.isEmpty
          ? null
          : '${notes.length} заметок${conflicts == 0 ? '' : ' · конфликтов: $conflicts'}',
      actions: [
        IconButton(
          tooltip: 'Синхронизировать',
          onPressed: () => _action(widget.library.sync),
          icon: const Icon(Icons.sync),
        ),
      ],
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: pad),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: TextField(
                decoration: const InputDecoration(
                  labelText: 'Поиск по цитатам, заметкам и тегам',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (v) => setState(() => query = v.toLowerCase()),
              ),
            ),
          ),
          if (error.isNotEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(pad, 12, pad, 0),
              child: Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 12),
          Expanded(
            child: notes.isEmpty
                ? Center(
                    child: Text(
                      'Заметки связанных книг появятся после синхронизации.',
                      style: TextStyle(color: palette.muted),
                    ),
                  )
                : ListView(
                    padding: EdgeInsets.fromLTRB(pad, 0, pad, 28),
                    children: [
                      for (final slot in visible)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _card(palette, slot),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _card(ShelfPalette palette, Map<String, dynamic> slot) {
    final conflict = slot['conflict'] != null;
    return Material(
      color: palette.panel,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: 4,
            child: ColoredBox(
              color: conflict ? palette.accent : palette.strongLine,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 16, 10),
            child: _note(slot),
          ),
        ],
      ),
    );
  }

  Widget _note(Map<String, dynamic> slot) {
    final palette = ShelfPalette.of(context);
    final value = Map<String, dynamic>.from(slot['value'] as Map),
        book = widget.library.entries
            .where((e) => e.item.id == value['itemId'])
            .firstOrNull
            ?.item
            .title;
    final tags = value['tags'] as List,
        characters = value['characters'] as List;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              value['kind'] == 'audio'
                  ? Icons.headphones_outlined
                  : Icons.menu_book_outlined,
              size: 16,
              color: palette.muted,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                [
                  book ?? 'Книга Obsidian',
                  if ('${value['title']}'.isNotEmpty) '${value['title']}',
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: palette.muted,
                ),
              ),
            ),
          ],
        ),
        if ('${value['quote']}'.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: SelectableText(
              '${value['quote']}',
              style: AppFonts.book(
                palette.text,
                size: 17,
              ).copyWith(height: 1.45),
            ),
          ),
        if ('${value['text']}'.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SelectableText(
              '${value['text']}',
              style: TextStyle(
                fontSize: 13.5,
                height: 1.45,
                color: palette.text.withValues(alpha: .85),
              ),
            ),
          ),
        if (tags.isNotEmpty || characters.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 10,
              runSpacing: 4,
              children: [
                for (final t in tags)
                  Text(
                    '#$t',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: palette.accent,
                    ),
                  ),
                if (characters.isNotEmpty)
                  Text(
                    'Персонажи: ${characters.join(', ')}',
                    style: TextStyle(fontSize: 12, color: palette.muted),
                  ),
              ],
            ),
          ),
        if (slot['conflict'] != null) ...[
          Container(
            margin: const EdgeInsets.only(top: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: palette.raised,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Изменено с обеих сторон. Версия сервера:',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: palette.accent,
                  ),
                ),
                const SizedBox(height: 6),
                SelectableText(
                  '${slot['conflict']['entry']['quote']}\n${slot['conflict']['entry']['text']}',
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ),
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
                        'Заметка будет удалена из библиотеки и связанного источника.',
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
