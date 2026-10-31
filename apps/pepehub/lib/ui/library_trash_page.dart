import 'package:flutter/material.dart';

import '../library/library_service.dart';
import 'shelf_components.dart';

class LibraryTrashPage extends StatelessWidget {
  final LibraryService service;
  const LibraryTrashPage({super.key, required this.service});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Корзина библиотеки')),
    body: ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final cards = service.trash
          ..sort(
            (a, b) => '${b.item.values['pepehub_deleted_at']}'.compareTo(
              '${a.item.values['pepehub_deleted_at']}',
            ),
          );
        return ListView.builder(
          padding: const EdgeInsets.all(20),
          itemCount: cards.isEmpty ? 2 : cards.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 20),
                child: Text(
                  'Удалённые карточки хранятся здесь до восстановления. Файлы книг не удаляются.',
                  style: TextStyle(color: ShelfPalette.of(context).muted),
                ),
              );
            }
            if (cards.isEmpty) {
              return const ListTile(
                leading: Icon(Icons.delete_outline),
                title: Text('Корзина пуста'),
              );
            }
            final card = cards[index - 1];
            return ListTile(
              title: Text(card.item.title),
              subtitle: Text(card.item.authors),
              leading: Icon(
                card.item.mediaType == 'audiobook'
                    ? Icons.headphones
                    : Icons.menu_book,
              ),
              trailing: IconButton(
                tooltip: 'Восстановить',
                icon: const Icon(Icons.restore),
                onPressed: () async {
                  try {
                    await service.restoreCard(card.item.id);
                  } catch (error) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text('$error')));
                    }
                  }
                },
              ),
            );
          },
        );
      },
    ),
  );
}
