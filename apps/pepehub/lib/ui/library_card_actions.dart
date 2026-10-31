import 'package:flutter/material.dart';

import '../library/library_service.dart';

Future<bool> deleteLibraryCards(
  BuildContext context,
  LibraryService service,
  Iterable<String> ids,
) async {
  final selected = ids.toList();
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(
        selected.length == 1
            ? 'Убрать книгу в корзину?'
            : 'Убрать книги в корзину · ${selected.length}?',
      ),
      content: const Text(
        'Карточки можно восстановить из корзины библиотеки. Файлы книг и рекомендации сохранятся.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('В корзину'),
        ),
      ],
    ),
  );
  if (confirmed != true) return false;
  await service.deleteCards(selected);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('В корзине: ${selected.length}'),
        action: SnackBarAction(
          label: 'Вернуть',
          onPressed: () async {
            for (final id in selected) {
              await service.restoreCard(id);
            }
          },
        ),
      ),
    );
  }
  return true;
}
