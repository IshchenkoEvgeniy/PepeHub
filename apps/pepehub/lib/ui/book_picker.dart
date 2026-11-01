import 'package:flutter/material.dart';

/// A bounded, searchable picker: even a large catalogue builds only visible rows.
class BookPicker extends StatelessWidget {
  final Map<String, String> titles;
  final String? value;
  final ValueChanged<String?> onChanged;
  const BookPicker({
    super.key,
    required this.titles,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => TextButton.icon(
    icon: const Icon(Icons.menu_book_outlined, size: 18),
    label: SizedBox(
      width: 160,
      child: Text(
        titles[value] ?? 'Все книги',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
    onPressed: () async {
      final result = await showDialog<({String? id})>(
        context: context,
        builder: (_) => _BookPickerDialog(titles: titles, value: value),
      );
      if (result != null) onChanged(result.id);
    },
  );
}

class _BookPickerDialog extends StatefulWidget {
  final Map<String, String> titles;
  final String? value;
  const _BookPickerDialog({required this.titles, this.value});
  @override
  State<_BookPickerDialog> createState() => _BookPickerDialogState();
}

class _BookPickerDialogState extends State<_BookPickerDialog> {
  late final books = widget.titles.entries.toList()
    ..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));
  String query = '';
  @override
  Widget build(BuildContext context) {
    final visible = books
        .where((b) => b.value.toLowerCase().contains(query))
        .toList();
    return AlertDialog(
      title: const Text('Выбрать книгу'),
      content: SizedBox(
        width: 480,
        height: 480,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Найти книгу',
              ),
              onChanged: (text) =>
                  setState(() => query = text.trim().toLowerCase()),
            ),
            ListTile(
              title: const Text('Все книги'),
              selected: widget.value == null,
              onTap: () => Navigator.pop(context, (id: null)),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Найдено: ${visible.length}'),
            ),
            Expanded(
              child: visible.isEmpty
                  ? const Center(child: Text('Книги не найдены'))
                  : ListView.builder(
                      itemCount: visible.length,
                      itemBuilder: (_, index) {
                        final book = visible[index];
                        return ListTile(
                          title: Text(
                            book.value,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          selected: widget.value == book.key,
                          onTap: () => Navigator.pop(context, (id: book.key)),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
      ],
    );
  }
}
