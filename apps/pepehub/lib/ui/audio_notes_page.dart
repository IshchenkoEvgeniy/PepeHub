import 'package:flutter/material.dart';

import '../data/repository.dart';
import '../media/audio_controller.dart';
import 'audio_mini_player.dart';
import 'audio_page.dart';

const audioNoteLabels = {
  'thought': 'Мысль',
  'quote': 'Цитата',
  'character': 'Персонаж',
};

class AudioNotesPage extends StatefulWidget {
  final AudioController controller;
  final String bookId;
  const AudioNotesPage({
    super.key,
    required this.controller,
    required this.bookId,
  });
  @override
  State<AudioNotesPage> createState() => _AudioNotesPageState();
}

class _AudioNotesPageState extends State<AudioNotesPage> {
  List<LibraryRecord> notes = [];
  String filter = 'all';
  bool busy = false;
  String error = '';
  AudioController get audio => widget.controller;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await audio.journal.list(
        'audio_note',
        bookId: widget.bookId,
        limit: 100000,
      );
      if (mounted) {
        setState(() {
          notes = rows;
          error = '';
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> _saveSnapshot() async {
    try {
      await audio.sidecar.update(widget.bookId, force: true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Заметка сохранена в приложении. Не удалось обновить .pepehub: $e',
            ),
          ),
        );
      }
    }
  }

  Future<void> _edit([LibraryRecord? note]) async {
    // Capture the locator before opening the editor; playback may advance meanwhile.
    final track = note?.payload?['trackId'] as String? ?? audio.current?.id;
    final position =
        note?.payload?['positionMs'] as int? ?? audio.position.inMilliseconds;
    if (track == null ||
        (note == null && audio.current?.bookId != widget.bookId)) {
      return;
    }
    var title = note?.payload?['title'] as String? ?? '';
    var text = note?.payload?['text'] as String? ?? '';
    var kind = note?.payload?['kind'] as String? ?? 'thought';
    final form = GlobalKey<FormState>();
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          note == null
              ? 'Заметка к ${audioTime(Duration(milliseconds: position))}'
              : 'Редактировать заметку',
        ),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Form(
              key: form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: kind,
                    decoration: const InputDecoration(labelText: 'Тип'),
                    items: [
                      for (final entry in audioNoteLabels.entries)
                        DropdownMenuItem(
                          value: entry.key,
                          child: Text(entry.value),
                        ),
                    ],
                    onChanged: (v) {
                      if (v != null) kind = v;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    initialValue: title,
                    maxLength: 200,
                    decoration: const InputDecoration(
                      labelText: 'Заголовок / имя персонажа',
                    ),
                    onChanged: (v) => title = v,
                  ),
                  TextFormField(
                    initialValue: text,
                    minLines: 4,
                    maxLines: 8,
                    maxLength: 10000,
                    decoration: const InputDecoration(
                      labelText: 'Текст заметки',
                    ),
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? 'Введите текст' : null,
                    onChanged: (v) => text = v,
                  ),
                  const Text(
                    'Позиция закреплена за моментом открытия этой формы.',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) Navigator.pop(context, true);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (saved != true || !mounted) return;
    setState(() => busy = true);
    try {
      await audio.journal.saveNote(
        id: note?.id,
        bookId: widget.bookId,
        trackId: track,
        positionMs: position,
        kind: kind,
        title: title,
        text: text,
      );
      await _load();
      await _saveSnapshot();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _delete(LibraryRecord note) async {
    await audio.journal.deleteNote(note.id);
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Заметка удалена'),
          duration: const Duration(seconds: 10),
          action: SnackBarAction(
            label: 'Отменить',
            onPressed: () async {
              await audio.journal.deleteNote(note.id, restore: true);
              await _load();
              await _saveSnapshot();
            },
          ),
        ),
      );
    }
    await _saveSnapshot();
  }

  Future<void> _jump(LibraryRecord note) async {
    final data = note.payload!;
    if (audio.current?.bookId != widget.bookId) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Откройте эту книгу в плеере для перехода к заметке.',
            ),
          ),
        );
      }
      return;
    }
    await audio.goToLocation(
      data['trackId'] as String,
      data['positionMs'] as int,
      reason: 'note',
    );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Заметки к книге'),
      actions: [
        IconButton(
          tooltip: 'Добавить заметку',
          onPressed: busy ? null : () => _edit(),
          icon: const Icon(Icons.add),
        ),
      ],
    ),
    bottomNavigationBar: AudioMiniPlayer(
      controller: audio,
      onOpen: () => Navigator.pop(context),
    ),
    body: Column(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              for (final entry in {'all': 'Все', ...audioNoteLabels}.entries)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(entry.value),
                    selected: filter == entry.key,
                    onSelected: (_) => setState(() => filter = entry.key),
                  ),
                ),
            ],
          ),
        ),
        if (busy) const LinearProgressIndicator(),
        if (error.isNotEmpty) Text(error),
        Expanded(
          child:
              notes
                  .where((n) => filter == 'all' || n.payload!['kind'] == filter)
                  .isEmpty
              ? const Center(
                  child: Text(
                    'Сохраните мысль, цитату или персонажа\nк текущему моменту книги.',
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView(
                  children: [
                    for (final note in notes.where(
                      (n) => filter == 'all' || n.payload!['kind'] == filter,
                    ))
                      Card(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${audioNoteLabels[note.payload!['kind']]} · ${audioTime(Duration(milliseconds: note.payload!['positionMs'] as int))}',
                                style: Theme.of(context).textTheme.labelLarge,
                              ),
                              if ((note.payload!['title'] as String).isNotEmpty)
                                Text(
                                  note.payload!['title'] as String,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium,
                                ),
                              const SizedBox(height: 8),
                              SelectableText(note.payload!['text'] as String),
                              Row(
                                children: [
                                  TextButton.icon(
                                    onPressed: busy ? null : () => _jump(note),
                                    icon: const Icon(Icons.play_circle_outline),
                                    label: const Text('К моменту'),
                                  ),
                                  const Spacer(),
                                  IconButton(
                                    tooltip: 'Редактировать заметку',
                                    onPressed: busy ? null : () => _edit(note),
                                    icon: const Icon(Icons.edit_outlined),
                                  ),
                                  IconButton(
                                    tooltip: 'Удалить заметку',
                                    onPressed: busy
                                        ? null
                                        : () => _delete(note),
                                    icon: const Icon(Icons.delete_outline),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    ),
  );
}
