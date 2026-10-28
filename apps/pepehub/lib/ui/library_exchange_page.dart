import 'package:flutter/material.dart';

import '../library/library_service.dart';
import '../library/models.dart';
import 'obsidian_library_page.dart';
import 'shelf_components.dart';

class LibraryExchangePage extends StatefulWidget {
  final LibraryService service;
  final VoidCallback onSettings;
  const LibraryExchangePage({
    super.key,
    required this.service,
    required this.onSettings,
  });
  @override
  State<LibraryExchangePage> createState() => _LibraryExchangePageState();
}

class _LibraryExchangePageState extends State<LibraryExchangePage> {
  final selected = <String>{};
  Map<String, dynamic> bindings = {};
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    widget.service.addListener(_changed);
    _changed();
  }

  @override
  void dispose() {
    widget.service.removeListener(_changed);
    super.dispose();
  }

  Future<void> _changed() async {
    final values =
        await widget.service.exchange?.bindings() ?? <String, dynamic>{};
    if (mounted) setState(() => bindings = values);
  }

  Future<void> _action(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
      await _changed();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _finish(LibraryEntry entry) async {
    final item = entry.item.withValues({
      ...entry.item.values,
      'status': 'finished',
      if (entry.item.value('total') is num &&
          (entry.item.value('total') as num) > 0)
        'progress': entry.item.value('total'),
    });
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => LibraryMetadataEditor(
          item: item,
          collection: widget.service.collectionFor(item),
          suggestions: widget.service.suggestions,
          onPickCover: widget.service.chooseCover,
          coverResolver: widget.service.coverReferencePath,
          saveLabel: 'Сохранить завершённой',
          onSave: (values) =>
              widget.service.save(item.id, values, original: entry.item.values),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.service;
    final connected = service.config != null;
    final palette = ShelfPalette.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Импорт и экспорт')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Библиотека хранится в PepeHub и доступна без подключения. Здесь можно обмениваться её данными с Obsidian.',
                  style: TextStyle(color: palette.muted),
                ),
                const SizedBox(height: 20),
                ShelfPanel(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Obsidian',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        connected
                            ? 'Подключён. Изменения связанных карточек передаются при обмене. Новые локальные книги экспортируются по вашему выбору.'
                            : 'Не подключён. Добавлять книги и редактировать библиотеку можно уже сейчас.',
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          OutlinedButton.icon(
                            onPressed: busy ? null : widget.onSettings,
                            icon: const Icon(Icons.settings_outlined),
                            label: Text(
                              connected
                                  ? 'Настройки подключения'
                                  : 'Подключить Obsidian',
                            ),
                          ),
                          if (connected)
                            FilledButton.icon(
                              onPressed: busy || service.syncing
                                  ? null
                                  : () => _action(service.sync),
                              icon: const Icon(Icons.sync),
                              label: Text(
                                service.syncing
                                    ? 'Обмен…'
                                    : 'Импортировать и обновить',
                              ),
                            ),
                          if (connected)
                            OutlinedButton(
                              onPressed: busy || service.syncing
                                  ? null
                                  : () => _action(() => service.connect(null)),
                              child: const Text('Отключить'),
                            ),
                        ],
                      ),
                      if (service.error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            service.error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (service.inbox.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Text(
                    'Разобрать импорт · ${service.inbox.length}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Эти карточки сохранены, но не отмечены завершёнными. Можно перенести их в существующий раздел рекомендаций или уточнить результат чтения. Исходные данные Obsidian сохраняются.',
                  ),
                  const SizedBox(height: 12),
                  for (final entry in service.inbox)
                    ShelfPanel(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entry.item.title,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          Text(entry.item.authors),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              TextButton(
                                onPressed: busy
                                    ? null
                                    : () => _action(
                                        () => service.toRecommendations(
                                          entry.item.id,
                                        ),
                                      ),
                                child: const Text('В рекомендации'),
                              ),
                              TextButton(
                                onPressed: busy ? null : () => _finish(entry),
                                child: const Text('Уже завершена'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                ],
                if (connected && service.completed.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Text(
                    'Экспорт книг',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  for (final entry in service.completed) ...[
                    CheckboxListTile(
                      value: selected.contains(entry.item.id),
                      onChanged: busy
                          ? null
                          : (value) => setState(() {
                              if (value == true) {
                                selected.add(entry.item.id);
                              } else {
                                selected.remove(entry.item.id);
                              }
                            }),
                      title: Text(entry.item.title),
                      subtitle: Text(
                        bindings.containsKey(entry.item.id) &&
                                (bindings[entry.item.id] as Map)['detached'] !=
                                    true
                            ? 'Связана с Obsidian'
                            : 'Только в PepeHub',
                      ),
                    ),
                    if ((bindings[entry.item.id] as Map?)?['state']
                        case 'error' || 'conflict' || 'removed')
                      Text(
                        'Карточка Obsidian требует внимания: ${(bindings[entry.item.id] as Map?)?['message'] ?? ''}',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    if (((bindings[entry.item.id] as Map?)?['conflicts']
                                as Map? ??
                            {})
                        .isNotEmpty)
                      ExpansionTile(
                        title: const Text('Сравнить изменения'),
                        children: [
                          for (final field
                              in ((bindings[entry.item.id] as Map)['conflicts']
                                      as Map)
                                  .entries)
                            ListTile(
                              title: Text(
                                libraryLabels[field.key] ?? '${field.key}',
                              ),
                              subtitle: Text(
                                'PepeHub: ${metadataText(entry.item.values[field.key])}\nObsidian: ${metadataText(field.value)}',
                              ),
                            ),
                        ],
                      ),
                    if ((((bindings[entry.item.id] as Map?)?['conflicts']
                                    as Map? ??
                                {})
                            .isNotEmpty) ||
                        [
                          'conflict',
                          'error',
                          'removed',
                        ].contains((bindings[entry.item.id] as Map?)?['state']))
                      Wrap(
                        spacing: 8,
                        children: [
                          TextButton(
                            onPressed: busy
                                ? null
                                : () => _action(
                                    () => service.keepLocal(entry.item.id),
                                  ),
                            child: const Text('Оставить данные PepeHub'),
                          ),
                          TextButton(
                            onPressed: busy
                                ? null
                                : () => _action(
                                    () => service.useObsidian(entry.item.id),
                                  ),
                            child: const Text('Принять изменения Obsidian'),
                          ),
                        ],
                      ),
                  ],
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: busy || service.syncing || selected.isEmpty
                        ? null
                        : () => _action(() async {
                            for (final id in selected.toList()) {
                              await service.exportToObsidian(id);
                            }
                            if (service.error != null) {
                              throw StateError(service.error!);
                            }
                            if (mounted) setState(selected.clear);
                          }),
                    icon: const Icon(Icons.upload_outlined),
                    label: Text(
                      'Экспортировать выбранные · ${selected.length}',
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
