import 'dart:convert';

import 'package:flutter/material.dart';

import '../library/models.dart';
import 'shelf_components.dart';

export 'obsidian_library_dashboard.dart' show ObsidianLibraryPage;

const libraryLabels = {
  'title': 'Название',
  'author': 'Авторы',
  'genre': 'Жанры',
  'series': 'Серия',
  'seriesIndex': 'Номер в серии',
  'status': 'Статус',
  'total': 'Всего страниц / минут',
  'progress': 'Прочитано страниц / прослушано минут',
  'rating': 'Рейтинг',
  'cover': 'Обложка (ссылка)',
  'format': 'Формат',
  'libraryType': 'Тип библиотеки',
  'startDate': 'Дата начала',
  'endDate': 'Дата завершения',
  'season': 'Сезон',
  'episode': 'Эпизод',
  'queueOrder': 'Порядок в очереди',
  'targetDate': 'Целевая дата',
  'unit': 'Единица прогресса',
};

String libraryState(LibraryEntry entry) => switch (entry.state) {
  'pending' => 'Ожидает Obsidian',
  'conflict' => 'Конфликт изменений',
  'error' => 'Не удалось сохранить',
  'removed' => 'Удалена из Obsidian',
  _ => 'В библиотеке',
};

class LibraryMetadataEditor extends StatefulWidget {
  final ObsidianLibraryItem item;
  final LibraryEntry? entry;
  final Future<void> Function(Map<String, dynamic>) onSave;
  final Future<void> Function()? onUseObsidian;
  final String saveLabel;
  const LibraryMetadataEditor({
    super.key,
    required this.item,
    required this.onSave,
    this.entry,
    this.onUseObsidian,
    this.saveLabel = 'Сохранить',
  });
  @override
  State<LibraryMetadataEditor> createState() => _LibraryMetadataEditorState();
}

class _LibraryMetadataEditorState extends State<LibraryMetadataEditor> {
  final form = GlobalKey<FormState>();
  final controllers = <String, TextEditingController>{};
  late final fields = {
    for (final field in widget.item.fields) field.key: field,
  };
  late final values = Map<String, dynamic>.from(widget.item.values);
  bool saving = false;
  String? error;
  bool get editable => widget.entry == null || widget.entry!.state == 'synced';
  @override
  void initState() {
    super.initState();
    for (final key in values.keys) {
      controllers[key] = TextEditingController(text: metadataText(values[key]));
    }
  }

  @override
  void dispose() {
    for (final controller in controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  dynamic _parse(String key, String text) {
    if (text == metadataText(widget.item.values[key])) {
      return widget.item.values[key];
    }
    if (text.trim().isEmpty) return null;
    final original = values[key], kind = fields[key]?.kind;
    if (original is Map ||
        original is List ||
        original is bool ||
        kind == 'json' ||
        (kind == 'list' && original is! String)) {
      final parsed = jsonDecode(text);
      if ((original is List || kind == 'list') && parsed is! List) {
        throw const FormatException(
          'Укажите список в JSON, например ["Автор"]',
        );
      }
      if (original is Map && parsed is! Map) {
        throw const FormatException('Укажите объект JSON');
      }
      if (original is bool && parsed is! bool) {
        throw const FormatException('Укажите true или false');
      }
      return parsed;
    }
    if (original is num || (kind == 'number' && original is! String)) {
      final number = num.tryParse(text.replaceAll(',', '.'));
      if (number == null || !number.isFinite) {
        throw const FormatException('Введите число');
      }
      return number;
    }
    return text;
  }

  Future<void> _save() async {
    if (!form.currentState!.validate()) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final next = {
        for (final entry in controllers.entries)
          entry.key: _parse(entry.key, entry.value.text),
      };
      await widget.onSave(next);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _addProperty() async {
    var name = '';
    final key = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Дополнительное свойство'),
        content: TextField(
          onChanged: (value) => name = value,
          decoration: const InputDecoration(labelText: 'Имя YAML-свойства'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, name.trim()),
            child: const Text('Добавить'),
          ),
        ],
      ),
    );
    if (key == null || key.isEmpty || !mounted) return;
    if (['pepehub_id', '__proto__', 'constructor', 'prototype'].contains(key) ||
        key.length > 200) {
      setState(() => error = 'Это имя свойства недоступно.');
      return;
    }
    setState(() {
      values.putIfAbsent(key, () => null);
      controllers.putIfAbsent(key, () => TextEditingController());
    });
  }

  Widget _field(String key) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextFormField(
      key: ValueKey('metadata:$key'),
      controller: controllers[key],
      enabled: editable && !saving,
      minLines: 1,
      maxLines: 5,
      decoration: InputDecoration(
        labelText: libraryLabels[fields[key]?.field] ?? key,
        helperText:
            '${values[key] is List || fields[key]?.kind == 'list' ? 'Список JSON · ' : ''}$key',
      ),
      validator: (text) {
        try {
          _parse(key, text ?? '');
          return null;
        } catch (e) {
          return '$e';
        }
      },
    ),
  );
  Widget _fieldsPanel(String title, IconData icon, Iterable<String> keys) =>
      ShelfPanel(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: ShelfPalette.of(context).accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            for (final key in keys) _field(key),
          ],
        ),
      );
  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    const progressFields = {
      'status',
      'total',
      'progress',
      'rating',
      'startDate',
      'endDate',
      'season',
      'episode',
      'queueOrder',
      'targetDate',
      'unit',
    };
    final main = controllers.keys.where(
      (key) =>
          fields.containsKey(key) &&
          !progressFields.contains(fields[key]!.field),
    );
    final progress = controllers.keys.where(
      (key) => progressFields.contains(fields[key]?.field),
    );
    final extra = controllers.keys.where((key) => !fields.containsKey(key));
    return Scaffold(
      appBar: AppBar(title: const Text('Метаданные книги')),
      bottomNavigationBar: editable
          ? SafeArea(
              child: Container(
                decoration: BoxDecoration(
                  color: palette.panel,
                  border: Border(top: BorderSide(color: palette.line)),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 14,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: saving ? null : () => Navigator.pop(context),
                      child: const Text('Отмена'),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: FilledButton.icon(
                        onPressed: saving ? null : _save,
                        icon: saving
                            ? const SizedBox(
                                width: 15,
                                height: 15,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.check_rounded, size: 17),
                        label: Text(saving ? 'Сохранение…' : widget.saveLabel),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null,
      body: Form(
        key: form,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1120),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    widget.item.mediaType == 'audiobook'
                        ? 'АУДИОКНИГА'
                        : 'КНИГА',
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 1.2,
                      color: palette.accent,
                    ),
                  ),
                  const SizedBox(height: 9),
                  Text(
                    widget.item.title,
                    style: const TextStyle(
                      fontSize: 25,
                      fontWeight: FontWeight.w700,
                      height: 1.35,
                    ),
                  ),
                  if (widget.item.authors.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 7),
                      child: Text(
                        widget.item.authors,
                        style: TextStyle(color: palette.muted),
                      ),
                    ),
                  if (widget.entry != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Row(
                        children: [
                          Icon(
                            Icons.diamond_outlined,
                            size: 15,
                            color: palette.accent,
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              libraryState(widget.entry!),
                              style: TextStyle(
                                fontSize: 12,
                                color: palette.muted,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (widget.entry?.message != null)
                    Text(widget.entry!.message!),
                  if (widget.entry?.state == 'conflict' ||
                      widget.entry?.state == 'error') ...[
                    ShelfPanel(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Изменения требуют внимания',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          if (widget.entry?.remote != null)
                            ExpansionTile(
                              title: const Text('Текущие метаданные Obsidian'),
                              children: [
                                SelectableText(
                                  const JsonEncoder.withIndent('  ')
                                      .convert(widget.entry!.remote!.values),
                                ),
                              ],
                            ),
                          TextButton(
                            onPressed: saving
                                ? null
                                : () async {
                                    await widget.onUseObsidian?.call();
                                    if (context.mounted) Navigator.pop(context);
                                  },
                            child: const Text('Принять версию Obsidian'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                  ],
                  const SizedBox(height: 10),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final primary = _fieldsPanel(
                        'Основное',
                        Icons.auto_stories_outlined,
                        main,
                      );
                      final activity = _fieldsPanel(
                        'Чтение и прослушивание',
                        Icons.schedule_outlined,
                        progress,
                      );
                      if (constraints.maxWidth < 780) {
                        return Column(
                          children: [
                            primary,
                            const SizedBox(height: 20),
                            activity,
                          ],
                        );
                      }
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: primary),
                          const SizedBox(width: 20),
                          Expanded(child: activity),
                        ],
                      );
                    },
                  ),
                  if (extra.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    _fieldsPanel(
                      'Дополнительные свойства',
                      Icons.tune_rounded,
                      extra,
                    ),
                  ],
                  if (editable)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        child: TextButton.icon(
                          onPressed: saving ? null : _addProperty,
                          icon: const Icon(Icons.add, size: 17),
                          label: const Text('Добавить свойство'),
                        ),
                      ),
                    ),
                  if (error != null)
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  const SizedBox(height: 10),
                  ShelfPanel(
                    child: ExpansionTile(
                      title: Text(
                        'Источник и служебные данные',
                        style: TextStyle(fontSize: 12, color: palette.muted),
                      ),
                      childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
                      expandedAlignment: Alignment.centerLeft,
                      children: [
                        if (widget.item.path.isNotEmpty)
                          SelectableText(
                            widget.item.path,
                            style: TextStyle(
                              fontSize: 11,
                              color: palette.muted,
                            ),
                          ),
                        const SizedBox(height: 8),
                        SelectableText(
                          'ID: ${widget.item.id}',
                          style: TextStyle(fontSize: 11, color: palette.muted),
                        ),
                        if (widget.item.modifiedAt > 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              'Изменено в Obsidian: ${DateTime.fromMillisecondsSinceEpoch(widget.item.modifiedAt).toLocal()}',
                              style: TextStyle(
                                fontSize: 11,
                                color: palette.muted,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
