import 'package:flutter/material.dart';

import '../sync/sync_client.dart';
import '../reader/book_formats.dart';

class AddBookDialog extends StatefulWidget {
  final bool? audioOnly;
  const AddBookDialog({super.key, this.audioOnly});
  @override
  State<AddBookDialog> createState() => _AddBookDialogState();
}

class _AddBookDialogState extends State<AddBookDialog> {
  final form = GlobalKey<FormState>();
  final title = TextEditingController(), author = TextEditingController();
  late String format = widget.audioOnly == true ? 'audio' : 'epub';
  @override
  void dispose() {
    title.dispose();
    author.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Новая книга'),
    content: SizedBox(
      width: 440,
      child: Form(
        key: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: title,
              autofocus: true,
              maxLength: 500,
              decoration: const InputDecoration(labelText: 'Название'),
              validator: (v) =>
                  v == null || v.trim().isEmpty ? 'Введите название' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: author,
              maxLength: 200,
              decoration: const InputDecoration(labelText: 'Автор'),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: format,
              decoration: const InputDecoration(labelText: 'Формат'),
              items: [
                for (final entry in {
                  if (widget.audioOnly != true) ...bookFormats,
                  if (widget.audioOnly != false) 'audio': 'Аудиокнига',
                }.entries)
                  DropdownMenuItem(value: entry.key, child: Text(entry.value)),
              ],
              onChanged: (value) {
                if (value != null) setState(() => format = value);
              },
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () {
          if (form.currentState!.validate()) {
            Navigator.pop(context, {
              'title': title.text,
              'author': author.text,
              'format': format,
            });
          }
        },
        child: const Text('Добавить'),
      ),
    ],
  );
}

class SessionDialog extends StatefulWidget {
  const SessionDialog({super.key});
  @override
  State<SessionDialog> createState() => _SessionDialogState();
}

class _SessionDialogState extends State<SessionDialog> {
  final form = GlobalKey<FormState>();
  final minutes = TextEditingController(text: '20');
  @override
  void dispose() {
    minutes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Записать сессию'),
    content: SizedBox(
      width: 420,
      child: Form(
        key: form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Ручная запись за последние указанные минуты. Время прослушивания плеер также учитывает автоматически.',
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: minutes,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Минуты'),
              validator: (v) {
                final n = int.tryParse(v ?? '');
                return n == null || n < 1 || n > 1440
                    ? 'Введите от 1 до 1440 минут'
                    : null;
              },
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () {
          if (form.currentState!.validate()) {
            Navigator.pop(context, int.parse(minutes.text));
          }
        },
        child: const Text('Сохранить'),
      ),
    ],
  );
}

class SyncDialog extends StatefulWidget {
  final SyncConfig? initial;
  const SyncDialog({super.key, this.initial});
  @override
  State<SyncDialog> createState() => _SyncDialogState();
}

class _SyncDialogState extends State<SyncDialog> {
  late final endpoint = TextEditingController(
    text: widget.initial?.endpoint ?? 'http://127.0.0.1:8787',
  );
  late final device = TextEditingController(
    text: widget.initial?.deviceId ?? '',
  );
  late final token = TextEditingController(text: widget.initial?.token ?? '');
  String? error;
  @override
  void dispose() {
    endpoint.dispose();
    device.dispose();
    token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Синхронизация'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Без подключения библиотека работает локально. Для обмена используйте адрес своего сервера и ключ устройства.',
            ),
            const SizedBox(height: 20),
            TextField(
              controller: endpoint,
              decoration: const InputDecoration(labelText: 'Адрес сервера'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: device,
              decoration: const InputDecoration(labelText: 'ID устройства'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: token,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Ключ устройства'),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Отмена'),
      ),
      FilledButton(
        onPressed: () {
          try {
            final config = SyncConfig(
              endpoint.text.trim(),
              device.text.trim(),
              token.text.trim(),
            );
            config.validate();
            Navigator.pop(context, config);
          } catch (e) {
            setState(() => error = '$e');
          }
        },
        child: const Text('Сохранить'),
      ),
    ],
  );
}
