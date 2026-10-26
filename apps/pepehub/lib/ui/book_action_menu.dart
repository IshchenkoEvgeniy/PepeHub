import 'dart:convert';

import 'package:flutter/material.dart';

import '../data/repository.dart';

enum BookActionGroup {
  library('Книга и коллекции', Icons.menu_book_outlined),
  progress('Чтение и прогресс', Icons.auto_stories_outlined),
  files('Файлы и обмен', Icons.folder_outlined),
  removal('Скрытие и удаление', Icons.delete_outline);

  final String label;
  final IconData icon;
  const BookActionGroup(this.label, this.icon);
}

class BookMenuAction {
  final String id, label;
  final BookActionGroup group;
  const BookMenuAction(this.id, this.label, this.group);
}

const bookMenuActions = [
  BookMenuAction('details', 'Карточка книги', BookActionGroup.library),
  BookMenuAction('favorite', 'В избранное', BookActionGroup.library),
  BookMenuAction('collections', 'Коллекции книги', BookActionGroup.library),
  BookMenuAction('reading-plan', 'План чтения', BookActionGroup.progress),
  BookMenuAction('planned', 'Отметить новой', BookActionGroup.progress),
  BookMenuAction('active', 'Отметить начатой', BookActionGroup.progress),
  BookMenuAction('finished', 'Отметить завершённой', BookActionGroup.progress),
  BookMenuAction('session', 'Записать сессию', BookActionGroup.progress),
  BookMenuAction('obsidian', 'Добавить в Obsidian', BookActionGroup.files),
  BookMenuAction('share', 'Поделиться файлом книги', BookActionGroup.files),
  BookMenuAction('source', 'Источник и файл', BookActionGroup.files),
  BookMenuAction('reveal-book', 'Показать папку файла', BookActionGroup.files),
  BookMenuAction(
    'metadata',
    'Обновить сведения из файла',
    BookActionGroup.files,
  ),
  BookMenuAction(
    'restore-deleted',
    'Добавить файл заново',
    BookActionGroup.files,
  ),
  BookMenuAction(
    'folder',
    'Переименовать / переместить папку',
    BookActionGroup.files,
  ),
  BookMenuAction('reconnect', 'Указать папку заново', BookActionGroup.files),
  BookMenuAction('hide-book', 'Убрать из списка', BookActionGroup.removal),
  BookMenuAction('delete-book', 'Удалить навсегда…', BookActionGroup.removal),
];

const bookMenuHiddenKey = 'book-menu-hidden-actions';

Future<String?> showBookActionMenu({
  required BuildContext context,
  required Repository repository,
  required String title,
  // Only actions supported by this book; labels can reflect its current state.
  required Map<String, String> available,
}) async {
  final raw = await repository.meta(bookMenuHiddenKey);
  var hidden = <String>{};
  try {
    final decoded = raw == null ? null : jsonDecode(raw);
    if (decoded is List) hidden = decoded.whereType<String>().toSet();
  } on FormatException {
    // A damaged local preference must not make book actions inaccessible.
  }
  if (!context.mounted) return null;
  return showDialog<String>(
    context: context,
    builder: (_) => _BookActionMenu(
      repository: repository,
      title: title,
      available: available,
      hidden: hidden,
    ),
  );
}

class _BookActionMenu extends StatefulWidget {
  final Repository repository;
  final String title;
  final Map<String, String> available;
  final Set<String> hidden;
  const _BookActionMenu({
    required this.repository,
    required this.title,
    required this.available,
    required this.hidden,
  });
  @override
  State<_BookActionMenu> createState() => _BookActionMenuState();
}

class _BookActionMenuState extends State<_BookActionMenu> {
  late Set<String> hidden = {...widget.hidden};
  bool configuring = false, saving = false;
  String? error;

  Future<void> _save(Set<String> next) async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.repository.setMeta(
        bookMenuHiddenKey,
        jsonEncode(next.toList()..sort()),
      );
      if (mounted) setState(() => hidden = next);
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Не удалось сохранить настройку меню');
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  void _setVisible(String id, bool visible) {
    final next = {...hidden};
    if (visible) {
      next.remove(id);
    } else {
      next.add(id);
    }
    _save(next);
  }

  @override
  Widget build(BuildContext context) {
    final visible = bookMenuActions
        .where(
          (action) =>
              widget.available.containsKey(action.id) &&
              !hidden.contains(action.id),
        )
        .toList();
    final scheme = Theme.of(context).colorScheme;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 520,
          maxHeight: MediaQuery.sizeOf(context).height * .85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 4, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      configuring ? 'Настроить действия' : 'Действия с книгой',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('book-menu-configure'),
                    tooltip: configuring
                        ? 'Готово'
                        : 'Настроить список действий',
                    onPressed: () => setState(() => configuring = !configuring),
                    icon: Icon(configuring ? Icons.check : Icons.tune),
                  ),
                  IconButton(
                    tooltip: 'Закрыть',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                configuring
                    ? 'Отметьте нужные функции. Настройка применяется ко всем книгам на этом устройстве.'
                    : widget.title,
                maxLines: configuring ? null : 2,
                overflow: configuring ? null : TextOverflow.ellipsis,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(error!, style: TextStyle(color: scheme.error)),
              ),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!configuring && visible.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'Все действия скрыты. Вернуть их можно кнопкой настройки вверху.',
                        ),
                      ),
                    for (final group in BookActionGroup.values)
                      if (configuring ||
                          visible.any((action) => action.group == group))
                        ExpansionTile(
                          key: ValueKey(
                            'book-menu-group:${group.name}:$configuring',
                          ),
                          initiallyExpanded:
                              configuring || group == BookActionGroup.library,
                          leading: Icon(group.icon),
                          title: Text(group.label),
                          children: [
                            for (final action
                                in configuring
                                    ? bookMenuActions.where(
                                        (a) => a.group == group,
                                      )
                                    : visible.where((a) => a.group == group))
                              if (configuring)
                                CheckboxListTile(
                                  key: ValueKey(
                                    'book-menu-visible:${action.id}',
                                  ),
                                  value: !hidden.contains(action.id),
                                  title: Text(action.label),
                                  onChanged: saving
                                      ? null
                                      : (value) => _setVisible(
                                          action.id,
                                          value == true,
                                        ),
                                )
                              else
                                ListTile(
                                  key: ValueKey(
                                    'book-menu-action:${action.id}',
                                  ),
                                  title: Text(widget.available[action.id]!),
                                  textColor: action.id == 'delete-book'
                                      ? scheme.error
                                      : null,
                                  onTap: () =>
                                      Navigator.pop(context, action.id),
                                ),
                          ],
                        ),
                  ],
                ),
              ),
            ),
            if (configuring)
              Padding(
                padding: const EdgeInsets.all(8),
                child: TextButton(
                  onPressed: saving || hidden.isEmpty ? null : () => _save({}),
                  child: const Text('Показать все функции'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
