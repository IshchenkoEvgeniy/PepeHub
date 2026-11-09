import 'package:flutter/material.dart';

import '../audio/audio_book_actions.dart';
import '../library/book_trash.dart';
import '../media/asset_store.dart';
import '../media/audio_player_scope.dart';
import '../reader/reading_book_actions.dart';
import 'library_card_actions.dart';

/// A book or audiobook the user is about to remove from PepeHub.
typedef BookToDelete = ({String id, String title, bool audio, bool hasFile});

/// How to remove: only from PepeHub (`false`), together with the files
/// (`true`), or cancelled (`null`).
Future<bool?> askBookDeletion(
  BuildContext context,
  List<BookToDelete> books, {
  int retentionDays = 30,
}) {
  final withFiles = books.any((book) => book.hasFile);
  final audioOnly = books.every((book) => book.audio);
  final trash = retentionDays == 0
      ? 'Книга попадёт в корзину и останется там, пока вы не очистите её.'
      : 'Книга попадёт в корзину на $retentionDays дней — оттуда её можно вернуть вместе с прогрессом, заметками и историей.';
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      scrollable: true,
      title: Text(
        books.length == 1
            ? 'Удалить «${books.single.title}»?'
            : 'Удалить выбранные книги (${books.length})?',
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(trash),
          if (withFiles) ...[
            const SizedBox(height: 12),
            Text(
              '«Вместе с файлом» удалит и ${audioOnly ? 'аудиофайлы' : 'файл'} '
              'с устройства — вернуть ${books.length == 1 ? 'его' : 'их'} '
              'из корзины уже не получится. Если папку синхронизирует '
              'стороннее приложение, удаление может повториться на других '
              'устройствах.',
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        if (withFiles)
          TextButton(
            key: const ValueKey('delete-with-files'),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Вместе с файлом'),
          ),
        FilledButton(
          key: const ValueKey('delete-from-pepehub'),
          onPressed: () => Navigator.pop(context, false),
          child: Text(withFiles ? 'Только из PepeHub' : 'В корзину'),
        ),
      ],
    ),
  );
}

/// Asks how to remove [books], deletes files when asked and moves the books
/// to the trash. Returns the ids moved to the trash (empty when cancelled).
///
/// [beforeDelete] runs for each book before its files go (close the reader).
Future<List<String>> deleteBooksToTrash(
  BuildContext context,
  AssetStore assets,
  List<BookToDelete> books, {
  void Function(String id)? beforeDelete,
}) async {
  if (books.isEmpty) return const [];
  final trash = BookTrash(assets.repository);
  final days = await trash.retentionDays();
  if (!context.mounted) return const [];
  final withFiles = await askBookDeletion(context, books, retentionDays: days);
  if (withFiles == null || !context.mounted) return const [];
  final player = AudioPlayerScope.of(context);
  final moved = <String>[];
  try {
    for (final book in books) {
      if (!context.mounted) break;
      beforeDelete?.call(book.id);
      if (player != null && player.current?.bookId == book.id) {
        await player.stop();
      }
      if (withFiles && book.hasFile) {
        final actions = book.audio
            ? AudioBookActions(assets)
            : ReadingBookActions(assets);
        if (!context.mounted ||
            !await deleteBookFilesWithAccess(context, actions, book.id)) {
          break;
        }
      }
      moved.add(book.id);
    }
  } finally {
    // Whatever was processed goes to the trash even if a later file failed.
    await trash.move(moved);
  }
  return moved;
}

/// «В корзине…» with «Вернуть».
void showMovedToTrash(
  BuildContext context,
  AssetStore assets,
  List<String> ids, {
  Future<void> Function()? onRestored,
}) {
  if (ids.isEmpty) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        ids.length == 1
            ? 'Книга перемещена в корзину'
            : 'В корзину перемещено книг: ${ids.length}',
      ),
      action: SnackBarAction(
        label: 'Вернуть',
        onPressed: () async {
          await BookTrash(assets.repository).restore(ids);
          await onRestored?.call();
        },
      ),
    ),
  );
}
