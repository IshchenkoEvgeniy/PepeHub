import 'package:flutter/material.dart';

import '../data/repository.dart';
import 'reading_library.dart';
import 'reading_notes_export.dart';

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
  final text = TextEditingController(text: note.comment);
  final tags = TextEditingController(text: note.tags.join(', '));
  final characters = TextEditingController(text: note.characters.join(', '));
  var color = note.color;
  final result = await showDialog<ReadingNote>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
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
      ),
    ),
  );
  // The dialog route retains its field until its closing animation ends.
  Future<void>.delayed(const Duration(seconds: 1), () {
    text.dispose();
    tags.dispose();
    characters.dispose();
  });
  return result;
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

  @override
  Widget build(BuildContext context) {
    final visible = filterReadingNotes(
      notes,
      query: query,
      color: color,
      tag: tag,
      character: character,
    );
    final tags = normalizeNoteLabels(notes.expand((n) => n.tags), limit: null)
      ..sort();
    final characters = normalizeNoteLabels(
      notes.expand((n) => n.characters),
      limit: null,
    )..sort();
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.hash == null ? 'Заметки библиотеки' : 'Заметки книги',
        ),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Экспорт заметок',
            enabled: !exporting && notes.isNotEmpty,
            icon: const Icon(Icons.file_download_outlined),
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'all:md',
                child: Text('Все заметки · Markdown'),
              ),
              PopupMenuItem(
                value: 'all:json',
                child: Text('Все заметки · JSON'),
              ),
              PopupMenuItem(
                value: 'filtered:md',
                child: Text('По фильтру · Markdown'),
              ),
              PopupMenuItem(
                value: 'filtered:json',
                child: Text('По фильтру · JSON'),
              ),
            ],
            onSelected: (v) async {
              setState(() => exporting = true);
              try {
                final saved = await saveReadingNotesExport(
                  v.startsWith('all:') ? notes : visible,
                  v.split(':').last,
                );
                if (saved && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Заметки экспортированы')),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Экспорт не выполнен: $e')),
                  );
                }
              } finally {
                if (mounted) setState(() => exporting = false);
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              onChanged: (v) => setState(() => query = v),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                labelText: 'Цитаты, комментарии, теги, персонажи',
              ),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                PopupMenuButton<String>(
                  tooltip: 'Фильтр по цвету',
                  child: Chip(
                    avatar: Icon(
                      Icons.palette_outlined,
                      color: noteColors[color],
                    ),
                    label: Text(
                      color == null ? 'Все цвета' : noteColorLabel(color!),
                    ),
                  ),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: '', child: Text('Все цвета')),
                    for (final c in noteColors.keys)
                      PopupMenuItem(value: c, child: Text(noteColorLabel(c))),
                  ],
                  onSelected: (v) =>
                      setState(() => color = v.isEmpty ? null : v),
                ),
                const SizedBox(width: 8),
                PopupMenuButton<String>(
                  tooltip: 'Фильтр по тегу',
                  child: Chip(label: Text(tag ?? 'Все теги')),
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: '', child: Text('Все теги')),
                    for (final t in tags)
                      PopupMenuItem(value: t, child: Text(t)),
                  ],
                  onSelected: (v) => setState(() => tag = v.isEmpty ? null : v),
                ),
                const SizedBox(width: 8),
                PopupMenuButton<String>(
                  tooltip: 'Фильтр по персонажу',
                  child: Chip(label: Text(character ?? 'Все персонажи')),
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
                ),
              ],
            ),
          ),
          if (exporting) const LinearProgressIndicator(),
          if (error != null) Text(error!),
          if (loading) const LinearProgressIndicator(),
          if (!loading && visible.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Заметок нет. Выделите текст в книге и нажмите «Заметка».',
              ),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: visible.length,
              itemBuilder: (context, i) {
                final note = visible[i];
                return Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  child: ListTile(
                    leading: Container(
                      width: 5,
                      height: 64,
                      color: noteColors[note.color] ?? noteColors['yellow'],
                    ),
                    title: Text(
                      note.quote,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        [
                          if (note.comment.isNotEmpty) note.comment,
                          if (note.tags.isNotEmpty)
                            note.tags.map((t) => '#$t').join(' · '),
                          if (note.characters.isNotEmpty)
                            'Персонажи: ${note.characters.join(', ')}',
                          '${note.bookTitle} · ${note.chapterTitle}',
                        ].join('\n'),
                      ),
                    ),
                    onTap: () async {
                      if (widget.onOpen == null) {
                        Navigator.pop(context, note);
                      } else {
                        await widget.onOpen!(note);
                        await _reload();
                      }
                    },
                    trailing: PopupMenuButton<String>(
                      tooltip: 'Действия с заметкой',
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('Изменить')),
                        PopupMenuItem(value: 'delete', child: Text('Удалить')),
                      ],
                      onSelected: (v) async {
                        if (v == 'edit') {
                          final updated = await editReadingNote(context, note);
                          if (updated != null) {
                            await _work(() => library.saveNote(updated));
                          }
                        } else {
                          await _work(() async {
                            await library.deleteNote(note.id);
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: const Text('Заметка удалена'),
                                action: SnackBarAction(
                                  label: 'Отменить',
                                  onPressed: () =>
                                      _work(() => library.saveNote(note)),
                                ),
                              ),
                            );
                          });
                        }
                      },
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

String noteColorLabel(String color) => switch (color) {
  'green' => 'Зелёный',
  'blue' => 'Синий',
  'pink' => 'Розовый',
  _ => 'Жёлтый',
};
