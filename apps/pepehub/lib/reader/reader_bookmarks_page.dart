import 'package:flutter/material.dart';

import 'reader_bookmarks.dart';
import 'reader_layout.dart';

class ReaderBookmarksPage extends StatefulWidget {
  final ReaderBookmarkStore store;
  final List<String> chapterTitles;
  final int chapter, offset;
  final ReaderDocument? document;
  const ReaderBookmarksPage({
    super.key,
    required this.store,
    required this.chapterTitles,
    required this.chapter,
    required this.offset,
    this.document,
  });

  @override
  State<ReaderBookmarksPage> createState() => _ReaderBookmarksPageState();
}

class _ReaderBookmarksPageState extends State<ReaderBookmarksPage> {
  List<ReaderBookmark>? bookmarks;
  String? error;
  bool busy = false;
  int loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final generation = ++loadGeneration;
    try {
      final result = await widget.store.list();
      if (mounted && generation == loadGeneration) {
        setState(() {
          bookmarks = result;
          error = null;
        });
      }
    } catch (e) {
      if (mounted && generation == loadGeneration) {
        setState(() => error = 'Не удалось загрузить закладки: $e');
      }
    }
  }

  Future<void> _write(Future<void> Function() action) async {
    if (busy || !mounted) return;
    setState(() => busy = true);
    try {
      await action();
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось сохранить закладки: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _name([ReaderBookmark? bookmark]) async {
    final title = await showDialog<String>(
      context: context,
      builder: (_) => _BookmarkNameDialog(
        initial: bookmark?.title ?? widget.chapterTitles[widget.chapter],
        renaming: bookmark != null,
      ),
    );
    if (title == null || !mounted) return;
    await _write(() async {
      if (bookmark == null) {
        await widget.store.add(
          title: title,
          chapter: widget.chapter,
          offset: widget.offset,
        );
      } else {
        await widget.store.rename(bookmark.id, title);
      }
    });
  }

  Future<void> _delete(ReaderBookmark bookmark) => _write(() async {
    final store = widget.store;
    final removed = await store.delete(bookmark.id);
    if (!mounted || removed == null) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Закладка удалена'),
          action: SnackBarAction(
            label: 'Отменить',
            onPressed: () async {
              try {
                await store.restore(removed);
                if (mounted) await _load();
              } catch (e) {
                if (messenger.mounted) {
                  messenger.showSnackBar(
                    SnackBar(content: Text('Не удалось вернуть закладку: $e')),
                  );
                }
              }
            },
          ),
        ),
      );
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Закладки'),
      actions: [
        IconButton(
          tooltip: 'Добавить закладку',
          onPressed: busy ? null : () => _name(),
          icon: const Icon(Icons.bookmark_add_outlined),
        ),
      ],
    ),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            children: [
              if (busy) const LinearProgressIndicator(),
              Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  onPressed: busy ? null : () => _name(),
                  icon: const Icon(Icons.add),
                  label: const Text('Запомнить текущее место'),
                ),
              ),
              if (error != null) ...[
                Padding(padding: const EdgeInsets.all(16), child: Text(error!)),
                TextButton(
                  onPressed: busy ? null : _load,
                  child: const Text('Повторить'),
                ),
              ] else if (bookmarks == null)
                const Expanded(
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (bookmarks!.isEmpty)
                const Expanded(child: Center(child: Text('Закладок пока нет')))
              else
                Expanded(
                  child: ListView.builder(
                    itemCount: bookmarks!.length,
                    itemBuilder: (context, index) {
                      final bookmark = bookmarks![index];
                      final valid =
                          bookmark.chapter < widget.chapterTitles.length;
                      final document = widget.document;
                      final place =
                          valid &&
                              document != null &&
                              bookmark.chapter < document.texts.length
                          ? (document.starts[bookmark.chapter] +
                                    bookmark.offset.clamp(
                                      0,
                                      document.texts[bookmark.chapter].length,
                                    ))
                                .clamp(0, document.length)
                          : null;
                      final excerpt = place == null
                          ? null
                          : readerExcerpt(
                              document!.texts[bookmark.chapter],
                              bookmark.offset.clamp(
                                0,
                                document.texts[bookmark.chapter].length,
                              ),
                              bookmark.offset.clamp(
                                0,
                                document.texts[bookmark.chapter].length,
                              ),
                              before: 20,
                              after: 100,
                            );
                      return ListTile(
                        leading: const Icon(Icons.bookmark_outline),
                        title: Text(bookmark.title),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              valid
                                  ? '${bookmark.chapter + 1}. ${widget.chapterTitles[bookmark.chapter]}'
                                        '${place == null || document!.length == 0 ? '' : ' · ${(place * 100 / document.length).toStringAsFixed(1)}%'}'
                                  : 'Глава недоступна',
                            ),
                            if (excerpt?.isNotEmpty == true)
                              Text(
                                excerpt!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                        onTap: busy || !valid
                            ? null
                            : () => Navigator.pop(context, bookmark),
                        trailing: PopupMenuButton<String>(
                          tooltip: 'Действия с закладкой',
                          enabled: !busy,
                          onSelected: (action) => action == 'rename'
                              ? _name(bookmark)
                              : _delete(bookmark),
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: 'rename',
                              child: Text('Переименовать'),
                            ),
                            PopupMenuItem(
                              value: 'delete',
                              child: Text('Удалить закладку'),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _BookmarkNameDialog extends StatefulWidget {
  final String initial;
  final bool renaming;
  const _BookmarkNameDialog({required this.initial, required this.renaming});
  @override
  State<_BookmarkNameDialog> createState() => _BookmarkNameDialogState();
}

class _BookmarkNameDialogState extends State<_BookmarkNameDialog> {
  final form = GlobalKey<FormState>();
  late final controller = TextEditingController(
    text: widget.initial.characters.take(120).toString(),
  );
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _save() {
    if (form.currentState!.validate()) {
      Navigator.pop(context, controller.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.renaming ? 'Переименовать закладку' : 'Новая закладка'),
    content: Form(
      key: form,
      child: TextFormField(
        controller: controller,
        autofocus: true,
        maxLength: 120,
        decoration: const InputDecoration(labelText: 'Название закладки'),
        validator: (value) =>
            value == null || value.trim().isEmpty ? 'Введите название' : null,
        onFieldSubmitted: (_) => _save(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(onPressed: _save, child: const Text('Сохранить')),
    ],
  );
}
