import 'package:flutter/material.dart';

bool readerShortcutsAllowed(BuildContext context) {
  if (ModalRoute.of(context)?.isCurrent == false) return false;
  final focus = FocusManager.instance.primaryFocus?.context;
  final editor = focus?.findAncestorWidgetOfExactType<EditableText>();
  return editor == null || editor.readOnly;
}

Future<void> showReaderShortcuts(
  BuildContext context, {
  bool pdf = false,
}) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: const Text('Горячие клавиши'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Ctrl+F — поиск по книге'),
          const Text('Пробел / Page Down — вперёд'),
          const Text('Shift+Пробел / Page Up — назад'),
          const Text('Home / End — начало / конец книги'),
          Text(
            pdf
                ? 'Стрелки — сдвиг страницы'
                : '↑ / ↓ — прокрутка; ← / → — страница',
          ),
          Text(pdf ? 'Ctrl+ + / − — масштаб' : 'Ctrl+ + / − — размер шрифта'),
          Text(
            pdf ? 'Ctrl+D — заметка к странице' : 'Ctrl+D — сохранить закладку',
          ),
          if (!pdf)
            const Text('Ctrl+B — список закладок; F3 / Shift+F3 — совпадения'),
          const Text('F11 — полный экран; Esc — выйти из полного экрана'),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Закрыть'),
      ),
    ],
  ),
);
