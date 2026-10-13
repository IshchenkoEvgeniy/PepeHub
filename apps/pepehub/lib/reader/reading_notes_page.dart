import 'package:flutter/material.dart';

import '../data/repository.dart';
import 'reading_library.dart';
import 'reading_notes_export.dart';
import '../ui/pepe_widgets.dart';
import '../ui/shelf_components.dart';

const noteColors = <String, Color>{
  'yellow': Color(0xffffdf80),
  'green': Color(0xffa6dfb2),
  'blue': Color(0xffa3cff5),
  'pink': Color(0xfff1b6d0),
};

Future<ReadingNote?> editReadingNote(
  BuildContext context,
  ReadingNote note,
) async {
  return showDialog<ReadingNote>(
    context: context,
    builder: (_) => _ReadingNoteEditor(note: note),
  );
}

class _ReadingNoteEditor extends StatefulWidget {
  final ReadingNote note;
  const _ReadingNoteEditor({required this.note});
  @override
  State<_ReadingNoteEditor> createState() => _ReadingNoteEditorState();
}

class _ReadingNoteEditorState extends State<_ReadingNoteEditor> {
  ReadingNote get note => widget.note;
  late final text = TextEditingController(text: note.comment);
  late final tags = TextEditingController(text: note.tags.join(', '));
  late final characters = TextEditingController(
    text: note.characters.join(', '),
  );
  late String color = note.color;
  @override
  void dispose() {
    text.dispose();
    tags.dispose();
    characters.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Цитата и заметка'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(note.quote, maxLines: 6, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: [
                for (final entry in noteColors.entries)
                  Semantics(
                    label: switch (entry.key) {
                      'green' => 'Зелёный',
                      'blue' => 'Синий',
                      'pink' => 'Розовый',
                      _ => 'Жёлтый',
                    },
                    child: ChoiceChip(
                      label: Icon(
                        color == entry.key ? Icons.check : Icons.circle,
                        color: Colors.black54,
                      ),
                      selected: color == entry.key,
                      backgroundColor: entry.value,
                      selectedColor: entry.value,
                      onSelected: (_) => setState(() => color = entry.key),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: text,
              minLines: 2,
              maxLines: 5,
              maxLength: 10000,
              decoration: const InputDecoration(
                labelText: 'Комментарий',
                hintText: 'Мысль, персонаж или пояснение',
              ),
            ),
            TextField(
              controller: tags,
              maxLength: 1000,
              decoration: const InputDecoration(
                labelText: 'Теги',
                hintText: 'Через запятую: идея, сюжет',
              ),
            ),
            TextField(
              controller: characters,
              maxLength: 1000,
              decoration: const InputDecoration(
                labelText: 'Персонажи',
                hintText: 'Имена через запятую',
              ),
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
        onPressed: () => Navigator.pop(
          context,
          ReadingNote.fromJson({
            ...note.toJson(),
            'comment': text.text.trim(),
            'color': color,
            'tags': normalizeNoteLabels(tags.text.split(',')),
            'characters': normalizeNoteLabels(characters.text.split(',')),
            'updated': DateTime.now().toUtc().toIso8601String(),
          }),
        ),
        child: const Text('Сохранить'),
      ),
    ],
  );
}

class ReadingNotesPage extends StatefulWidget {
  final Repository repository;
  final String? hash;
  final Set<String>? bookIds;
  final Future<void> Function(ReadingNote)? onOpen;
  const ReadingNotesPage({
    super.key,
    required this.repository,
    this.hash,
    this.bookIds,
    this.onOpen,
  });
  @override
  State<ReadingNotesPage> createState() => _ReadingNotesPageState();
}

class _ReadingNotesPageState extends State<ReadingNotesPage> {
  late final library = ReadingLibrary(widget.repository);
  List<ReadingNote> notes = [];
  String query = '';
  String? error;
  String? color, tag, character;
  bool exporting = false;
  bool loading = true;
  String? selected, bookFilter;
  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final result = await library.notes(
        hash: widget.hash,
        bookIds: widget.bookIds,
      );
      if (mounted) {
        setState(() {
          notes = result;
          loading = false;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          loading = false;
        });
      }
    }
  }

  Future<void> _work(Future<void> Function() work) async {
    try {
      await work();
      await _reload();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Не удалось сохранить: $e')));
      }
    }
  }

  Future<void> _export(String v, List<ReadingNote> visible) async {
    setState(() => exporting = true);
    try {
      final saved = await saveReadingNotesExport(
        v.startsWith('all:') ? notes : visible,
        v.split(':').last,
      );
      if (saved && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Заметки экспортированы')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Экспорт не выполнен: $e')));
      }
    } finally {
      if (mounted) setState(() => exporting = false);
    }
  }

  Future<void> _open(ReadingNote note) async {
    if (widget.onOpen == null) {
      Navigator.pop(context, note);
    } else {
      await widget.onOpen!(note);
      await _reload();
    }
  }

  Future<void> _edit(ReadingNote note) async {
    final updated = await editReadingNote(context, note);
    if (updated != null) await _work(() => library.saveNote(updated));
  }

  Future<void> _delete(ReadingNote note) => _work(() async {
    await library.deleteNote(note.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Заметка удалена'),
        duration: const Duration(seconds: 4),
        persist: false,
        action: SnackBarAction(
          label: 'Отменить',
          onPressed: () => _work(() => library.saveNote(note)),
        ),
      ),
    );
  });

  Widget _card(ShelfPalette palette, ReadingNote note, bool wide) {
    final tint = noteColors[note.color] ?? noteColors['yellow']!;
    final active = wide && selected == note.id;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: active ? palette.selected : palette.panel,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: wide
              ? () => setState(() => selected = note.id)
              : () => _open(note),
          onDoubleTap: wide ? () => _open(note) : null,
          child: Stack(
            children: [
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: 5,
                child: ColoredBox(color: tint),
              ),
              Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(width: 5),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 4, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          note.quote.isEmpty ? note.chapterTitle : note.quote,
                          maxLines: 5,
                          overflow: TextOverflow.ellipsis,
                          style: AppFonts.book(
                            palette.text,
                            size: 17,
                          ).copyWith(height: 1.45),
                        ),
                        if (note.comment.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            note.comment,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.4,
                              color: palette.text.withValues(alpha: .82),
                            ),
                          ),
                        ],
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            Text(
                              '${note.bookTitle} · ${note.chapterTitle}',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: palette.muted,
                              ),
                            ),
                            for (final t in note.tags)
                              Text(
                                '#$t',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                  color: palette.accent,
                                ),
                              ),
                            if (note.characters.isNotEmpty)
                              Text(
                                'Персонажи: ${note.characters.join(', ')}',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: palette.muted,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Действия с заметкой',
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'edit', child: Text('Изменить')),
                    PopupMenuItem(value: 'delete', child: Text('Удалить')),
                  ],
                  onSelected: (v) => v == 'edit' ? _edit(note) : _delete(note),
                ),
              ],
            ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _filterRow(
    ShelfPalette palette,
    String label,
    int count,
    bool active,
    VoidCallback onTap, {
    Color? dot,
  }) => Material(
    color: active ? palette.selected : Colors.transparent,
    borderRadius: BorderRadius.circular(10),
    child: InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            if (dot != null) ...[
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
            Text(
              '$count',
              style: TextStyle(fontSize: 12, color: palette.muted),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _sidebar(
    ShelfPalette palette,
    TextField search,
    List<String> tags,
    List<String> characters,
    Map<String, int> books,
  ) => ListView(
    padding: const EdgeInsets.only(bottom: 24),
    children: [
      search,
      if (books.length > 1) ...[
        const SizedBox(height: 20),
        const PepeCaption('Книги'),
        const SizedBox(height: 6),
        _filterRow(
          palette,
          'Все книги',
          notes.length,
          bookFilter == null,
          () => setState(() => bookFilter = null),
        ),
        for (final e in books.entries)
          _filterRow(
            palette,
            e.key,
            e.value,
            bookFilter == e.key,
            () => setState(() => bookFilter = e.key),
          ),
      ],
      const SizedBox(height: 20),
      const PepeCaption('Цвет'),
      const SizedBox(height: 6),
      _filterRow(
        palette,
        'Все цвета',
        notes.length,
        color == null,
        () => setState(() => color = null),
      ),
      for (final c in noteColors.keys)
        _filterRow(
          palette,
          noteColorLabel(c),
          notes.where((n) => n.color == c).length,
          color == c,
          () => setState(() => color = c),
          dot: noteColors[c],
        ),
      if (tags.isNotEmpty) ...[
        const SizedBox(height: 20),
        const PepeCaption('Теги'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final t in tags)
              ShelfPill(
                label: '#$t',
                selected: tag == t,
                onTap: () => setState(() => tag = tag == t ? null : t),
              ),
          ],
        ),
      ],
      if (characters.isNotEmpty) ...[
        const SizedBox(height: 20),
        const PepeCaption('Персонажи'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final c in characters)
              ShelfPill(
                label: c,
                selected: character == c,
                onTap: () =>
                    setState(() => character = character == c ? null : c),
              ),
          ],
        ),
      ],
    ],
  );

  Widget _detail(ShelfPalette palette, ReadingNote? note) {
    if (note == null) {
      return PepePanel(
        outlined: true,
        child: Text(
          'Выберите заметку, чтобы увидеть её целиком. Двойное нажатие открывает место в книге.',
          style: TextStyle(fontSize: 13, height: 1.45, color: palette.muted),
        ),
      );
    }
    final tint = noteColors[note.color] ?? noteColors['yellow']!;
    final updated = DateTime.tryParse(note.updated)?.toLocal();
    return SingleChildScrollView(
      child: PepePanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: tint,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    note.chapterTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: palette.muted),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              decoration: BoxDecoration(
                color: tint.withValues(alpha: .14),
                border: Border(left: BorderSide(color: tint, width: 3)),
              ),
              child: SelectableText(
                note.quote.isEmpty ? '—' : note.quote,
                style: AppFonts.book(
                  palette.text,
                  size: 19,
                ).copyWith(height: 1.5),
              ),
            ),
            const SizedBox(height: 16),
            const PepeCaption('Комментарий'),
            const SizedBox(height: 6),
            Text(
              note.comment.isEmpty ? 'Без комментария' : note.comment,
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                color: note.comment.isEmpty ? palette.muted : palette.text,
              ),
            ),
            if (note.tags.isNotEmpty || note.characters.isNotEmpty) ...[
              const SizedBox(height: 14),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final t in note.tags) ShelfPill(label: '#$t'),
                  for (final c in note.characters) ShelfPill(label: c),
                ],
              ),
            ],
            const SizedBox(height: 14),
            Text(
              [
                note.bookTitle,
                if (updated != null) 'изменено ${pepeDate(updated)}',
              ].join(' · '),
              style: TextStyle(fontSize: 12, color: palette.muted),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: () => _open(note),
                  icon: const Icon(Icons.menu_book_outlined, size: 18),
                  label: const Text('Открыть в книге'),
                ),
                OutlinedButton(
                  onPressed: () => _edit(note),
                  child: const Text('Изменить заметку'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final wide = pepeWide(context);
    final visible = filterReadingNotes(
      notes,
      query: query,
      color: color,
      tag: tag,
      character: character,
    ).where((n) => bookFilter == null || n.bookTitle == bookFilter).toList();
    final tags = normalizeNoteLabels(notes.expand((n) => n.tags), limit: null)
      ..sort();
    final characters = normalizeNoteLabels(
      notes.expand((n) => n.characters),
      limit: null,
    )..sort();
    final books = <String, int>{};
    for (final n in notes) {
      books[n.bookTitle] = (books[n.bookTitle] ?? 0) + 1;
    }
    final search = TextField(
      onChanged: (v) => setState(() => query = v),
      decoration: const InputDecoration(
        prefixIcon: Icon(Icons.search),
        labelText: 'Цитаты, комментарии, теги, персонажи',
      ),
    );
    final status = [
      if (exporting || loading) const LinearProgressIndicator(),
      if (error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      if (!loading && visible.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Text(
            notes.isEmpty
                ? 'Заметок нет. Выделите текст в книге и нажмите «Заметка».'
                : 'По этому фильтру заметок нет.',
            style: TextStyle(color: palette.muted),
          ),
        ),
    ];
    final list = ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: visible.length,
      itemBuilder: (context, i) => _card(palette, visible[i], wide),
    );
    final Widget body;
    if (wide) {
      final current = visible.where((n) => n.id == selected).firstOrNull;
      body = Padding(
        padding: const EdgeInsets.fromLTRB(28, 0, 28, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 250,
              child: _sidebar(palette, search, tags, characters, books),
            ),
            const SizedBox(width: 24),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ...status,
                  Expanded(child: list),
                ],
              ),
            ),
            const SizedBox(width: 24),
            SizedBox(
              width: 340,
              child: Align(
                alignment: Alignment.topCenter,
                child: _detail(palette, current),
              ),
            ),
          ],
        ),
      );
    } else {
      body = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            search,
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  PopupMenuButton<String>(
                    tooltip: 'Фильтр по цвету',
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: '', child: Text('Все цвета')),
                      for (final c in noteColors.keys)
                        PopupMenuItem(value: c, child: Text(noteColorLabel(c))),
                    ],
                    onSelected: (v) =>
                        setState(() => color = v.isEmpty ? null : v),
                    child: IgnorePointer(
                      child: ShelfPill(
                        label: color == null
                            ? 'Все цвета'
                            : noteColorLabel(color!),
                        selected: color != null,
                        onTap: () {},
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  PopupMenuButton<String>(
                    tooltip: 'Фильтр по тегу',
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: '', child: Text('Все теги')),
                      for (final t in tags)
                        PopupMenuItem(value: t, child: Text(t)),
                    ],
                    onSelected: (v) =>
                        setState(() => tag = v.isEmpty ? null : v),
                    child: IgnorePointer(
                      child: ShelfPill(
                        label: tag ?? 'Все теги',
                        selected: tag != null,
                        onTap: () {},
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  PopupMenuButton<String>(
                    tooltip: 'Фильтр по персонажу',
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: '',
                        child: Text('Все персонажи'),
                      ),
                      for (final c in characters)
                        PopupMenuItem(value: c, child: Text(c)),
                    ],
                    onSelected: (v) =>
                        setState(() => character = v.isEmpty ? null : v),
                    child: IgnorePointer(
                      child: ShelfPill(
                        label: character ?? 'Все персонажи',
                        selected: character != null,
                        onTap: () {},
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            ...status,
            Expanded(child: list),
          ],
        ),
      );
    }
    return PepeSubpage(
      title: widget.hash == null ? 'Заметки' : 'Заметки книги',
      back: widget.hash == null ? 'Библиотека' : 'Книга',
      section: PepeSection.books,
      subtitle: notes.isEmpty
          ? null
          : 'Показано ${visible.length} из ${notes.length}',
      maxWidth: 1480,
      actions: [
        PopupMenuButton<String>(
          tooltip: 'Экспорт заметок',
          enabled: !exporting && notes.isNotEmpty,
          icon: const Icon(Icons.file_download_outlined),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'all:md', child: Text('Все заметки · Markdown')),
            PopupMenuItem(value: 'all:json', child: Text('Все заметки · JSON')),
            PopupMenuItem(
              value: 'filtered:md',
              child: Text('По фильтру · Markdown'),
            ),
            PopupMenuItem(
              value: 'filtered:json',
              child: Text('По фильтру · JSON'),
            ),
          ],
          onSelected: (v) => _export(v, visible),
        ),
      ],
      body: body,
    );
  }
}

String noteColorLabel(String color) => switch (color) {
  'green' => 'Зелёный',
  'blue' => 'Синий',
  'pink' => 'Розовый',
  _ => 'Жёлтый',
};
