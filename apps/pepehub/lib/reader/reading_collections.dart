import 'package:flutter/material.dart';

import '../data/repository.dart';
import 'reading_library.dart';

Future<void> showReadingCollections(
  BuildContext context,
  Repository repository, {
  String? bookId,
}) => showLibraryCollections(context, repository, bookId: bookId);

Future<void> showLibraryCollections(
  BuildContext context,
  Repository repository, {
  String? bookId,
  bool audio = false,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) =>
      _Collections(repository: repository, bookId: bookId, audio: audio),
);

class _Collections extends StatefulWidget {
  final Repository repository;
  final String? bookId;
  final bool audio;
  const _Collections({
    required this.repository,
    this.bookId,
    required this.audio,
  });
  @override
  State<_Collections> createState() => _CollectionsState();
}

class _CollectionsState extends State<_Collections> {
  late final library = ReadingLibrary(widget.repository);
  String get prefix => widget.audio ? 'audio' : 'reading';
  Map<String, Map<String, dynamic>> collections = {};
  Set<String> selected = {};
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await library.entries('$prefix-collection:');
    final prefs = widget.bookId == null
        ? <String, dynamic>{}
        : await library.value('$prefix-book:${widget.bookId}');
    if (mounted) {
      setState(() {
        collections = all;
        selected = (prefs['collections'] as List? ?? []).cast<String>().toSet();
      });
    }
  }

  Future<void> _work(Future<void> Function() f) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await f();
      await _load();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _name([String? id]) async {
    final controller = TextEditingController(
      text: collections[id]?['name'] as String? ?? '',
    );
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(id == null ? 'Новая коллекция' : 'Название коллекции'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 100,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(context, controller.text.trim());
              }
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(seconds: 1), controller.dispose);
    if (name == null) return;
    await _work(() async {
      final key = id ?? uuid.v4();
      await library.update('$prefix-collection:$key', {'name': name});
      if (id == null && widget.bookId != null) {
        await library.update('$prefix-book:${widget.bookId}', {
          'collections': [...selected, key],
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * .7,
      child: Column(
        children: [
          Text(
            widget.bookId == null
                ? (widget.audio ? 'Коллекции аудиокниг' : 'Коллекции')
                : 'Коллекции книги',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          TextButton.icon(
            onPressed: busy ? null : _name,
            icon: const Icon(Icons.add),
            label: const Text('Создать коллекцию'),
          ),
          if (error != null) Text(error!),
          if (busy) const LinearProgressIndicator(),
          Expanded(
            child: ListView(
              children: [
                for (final entry in collections.entries)
                  ListTile(
                    leading: widget.bookId == null
                        ? const Icon(Icons.collections_bookmark_outlined)
                        : Checkbox(
                            value: selected.contains(entry.key),
                            onChanged: busy
                                ? null
                                : (v) => _work(() async {
                                    final next = {...selected};
                                    if (v == true) {
                                      next.add(entry.key);
                                    } else {
                                      next.remove(entry.key);
                                    }
                                    await library.update(
                                      '$prefix-book:${widget.bookId}',
                                      {'collections': next.toList()},
                                    );
                                  }),
                          ),
                    title: Text(entry.value['name'] as String),
                    trailing: PopupMenuButton<String>(
                      enabled: !busy,
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'rename',
                          child: Text('Переименовать'),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Text('Удалить коллекцию'),
                        ),
                      ],
                      onSelected: (v) async {
                        if (v == 'rename') {
                          await _name(entry.key);
                          return;
                        }
                        await _work(() async {
                          await widget.repository.db.transaction(() async {
                            final books = await library.entries(
                              '$prefix-book:',
                            );
                            for (final book in books.entries) {
                              final ids =
                                  (book.value['collections'] as List? ?? [])
                                      .cast<String>();
                              if (ids.contains(entry.key)) {
                                await library.update(
                                  '$prefix-book:${book.key}',
                                  {
                                    'collections': ids
                                        .where((id) => id != entry.key)
                                        .toList(),
                                  },
                                );
                              }
                            }
                            await widget.repository.db.customStatement(
                              'DELETE FROM metadata WHERE key=?',
                              ['$prefix-collection:${entry.key}'],
                            );
                          });
                        });
                      },
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
