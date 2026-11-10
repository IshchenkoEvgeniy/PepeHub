import 'package:flutter/material.dart';

import '../audio/audio_book_actions.dart';
import '../library/library_features.dart';
import '../library/library_service.dart';
import '../library/personal_library.dart';
import '../media/audio_player_scope.dart';
import '../reader/reading_book_actions.dart';
import '../diagnostics/user_message.dart';

enum _Removal { trash, card, files }

Future<bool> deleteLibraryCards(
  BuildContext context,
  LibraryService service,
  Iterable<String> ids, {
  bool fromTrash = false,
  bool allowFileDeletion = true,
  VoidCallback? checkBookClosed,
}) async {
  final selected = ids.toSet();
  if (selected.isEmpty) return false;
  try {
    return await _removeLibraryCards(
      context,
      service,
      selected,
      fromTrash: fromTrash,
      allowFileDeletion: allowFileDeletion,
      checkBookClosed: checkBookClosed,
    );
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Не удалось завершить удаление. ${describeError(error)}',
          ),
        ),
      );
    }
    return false;
  }
}

Future<bool> _removeLibraryCards(
  BuildContext context,
  LibraryService service,
  Set<String> selected, {
  required bool fromTrash,
  required bool allowFileDeletion,
  required VoidCallback? checkBookClosed,
}) async {
  final single = selected.length == 1;
  final entry = single
      ? service.entries
            .where((entry) => entry.item.id == selected.single)
            .firstOrNull
      : null;
  final sourceId = entry?.sourceBookId;
  final assets = service.assets;
  final source = allowFileDeletion && assets != null && sourceId != null
      ? await service.local.record(sourceId)
      : null;
  final audio = source?.payload?['format'] == 'audio';
  final ReadingBookActions? fileActions =
      source != null && source.type == 'book' && !source.deleted
      ? audio
            ? AudioBookActions(assets!)
            : ReadingBookActions(assets!)
      : null;
  final withFiles =
      fileActions != null && await fileActions.hasRegisteredFiles(sourceId!);
  if (!context.mounted) return false;
  final player = withFiles && audio ? AudioPlayerScope.of(context) : null;
  final choice = await showDialog<_Removal>(
    context: context,
    builder: (context) => AlertDialog(
      scrollable: true,
      title: Text(
        entry != null
            ? 'Удаление «${entry.item.title}»'
            : 'Удаление карточек (${selected.length})',
      ),
      content: Text(
        'При окончательном удалении исчезнут карточка, её цитаты и журнал библиотеки. '
        'При удалении только карточки файл книги останется на устройстве. '
        'Прогресс и заметки читалки и плеера сохранятся.'
        '${fromTrash ? '' : '\n\nИз корзины карточку можно восстановить.'}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        if (!fromTrash)
          TextButton(
            onPressed: () => Navigator.pop(context, _Removal.trash),
            child: const Text('В корзину'),
          ),
        FilledButton.tonal(
          onPressed: () => Navigator.pop(context, _Removal.card),
          child: Text(
            single ? 'Удалить только карточку' : 'Удалить только карточки',
          ),
        ),
        if (withFiles)
          TextButton(
            onPressed: () => Navigator.pop(context, _Removal.files),
            child: const Text('Удалить карточку и файлы…'),
          ),
      ],
    ),
  );
  if (choice == null || !context.mounted) return false;
  if (choice == _Removal.files) {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Удалить карточку и файлы навсегда?'),
        content: const Text(
          'Файлы этой книги будут удалены с устройства, в том числе из подключённой '
          'папки. Если папку синхронизирует стороннее приложение, удаление может '
          'распространиться на другие устройства.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить карточку и файлы'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return false;
    final current = (await service.repository.entries())[selected.single];
    if (current == null ||
        current.sourceBookId != sourceId ||
        (fromTrash && !isLibraryDeleted(current.item)) ||
        (!isLibraryDeleted(current.item) &&
            !isSeriesCatalogItem(current.item))) {
      throw StateError('Карточка изменилась. Откройте меню удаления заново.');
    }
    checkBookClosed?.call();
    if (player != null && player.current?.bookId == sourceId) {
      await player.stop();
    }
    if (!context.mounted ||
        !await deleteBookFilesWithAccess(context, fileActions!, sourceId!)) {
      return false;
    }
  }
  var removed = selected.length;
  if (choice == _Removal.trash) {
    await service.deleteCards(selected);
  } else {
    removed = await service.purgeCards(selected, includeVisible: !fromTrash);
    if (removed == 0) return false;
  }
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        // Flutter keeps snack bars with an action until dismissed.
        persist: false,
        content: Text(switch (choice) {
          _Removal.trash => 'В корзине: ${selected.length}',
          _Removal.card => 'Карточек удалено: $removed. Файлы сохранены.',
          _Removal.files => 'Карточка и файлы удалены.',
        }),
        action: choice == _Removal.trash
            ? SnackBarAction(
                label: 'Вернуть',
                onPressed: () => service.restoreCards(selected),
              )
            : null,
      ),
    );
  }
  return true;
}

Future<bool> deleteBookFilesWithAccess(
  BuildContext context,
  ReadingBookActions actions,
  String id,
) async {
  final requested = <String>{};
  while (context.mounted) {
    try {
      await actions.deleteForever(id);
      return true;
    } on ReadingBookWriteAccessRequired catch (failure) {
      final root = failure.root;
      if (root == null || !requested.add(root)) rethrow;
      if (!context.mounted) return false;
      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Нужен доступ к папке'),
          content: const Text(
            'Android не разрешает удалять файлы из этой папки. Нажмите «Выбрать папку» и подтвердите доступ к той же папке в системном окне.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Выбрать папку'),
            ),
          ],
        ),
      );
      if (confirm != true || !context.mounted) return false;
      if (!await actions.requestWriteAccess(failure)) return false;
      // Recheck every file after the picker, which may have taken time.
    }
  }
  return false;
}
