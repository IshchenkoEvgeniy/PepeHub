import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'audio_mini_player.dart';

import '../library/models.dart';
import '../library/metadata_values.dart';
import '../library/personal_library.dart';
import 'metadata_input.dart';
import 'shelf_components.dart';

export 'obsidian_library_dashboard.dart' show ObsidianLibraryPage;

const libraryLabels = {
  'title': 'Название',
  'author': 'Авторы',
  'genre': 'Жанры',
  'series': 'Серия',
  'seriesIndex': 'Номер в серии',
  'status': 'Статус',
  'total': 'Общий объём',
  'progress': 'Прочитано / прослушано',
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
  'readingTime': 'Время чтения / прослушивания',
  'notes': 'Впечатления',
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
  final Future<String?> Function()? onPickCover;
  final Map<String, List<String>> suggestions;
  final Map<String, dynamic>? collection;
  final List<Map<String, dynamic>> collections;
  final Map<String, String> syncPolicy;
  final Future<void> Function(Map<String, String>)? onSavePolicy;
  final String? Function(String)? coverResolver;
  const LibraryMetadataEditor({
    super.key,
    required this.item,
    required this.onSave,
    this.entry,
    this.onUseObsidian,
    this.saveLabel = 'Сохранить',
    this.onPickCover,
    this.suggestions = const {},
    this.collection,
    this.collections = const [],
    this.syncPolicy = const {},
    this.onSavePolicy,
    this.coverResolver,
  });
  @override
  State<LibraryMetadataEditor> createState() => _LibraryMetadataEditorState();
}

class _LibraryMetadataEditorState extends State<LibraryMetadataEditor> {
  final form = GlobalKey<FormState>();
  final controllers = <String, TextEditingController>{};
  final focusNodes = <String, FocusNode>{};
  late final policy = Map<String, String>.from(widget.syncPolicy);
  late final fields = {
    for (final field in widget.item.fields) field.key: field,
  };
  late final values = Map<String, dynamic>.from(widget.item.values);
  bool saving = false;
  int editGeneration = 0;
  String? error;
  bool get personal =>
      widget.item.fields == personalLibraryFields ||
      widget.item.fields.any((f) => f.key == 'title' && f.field == 'title') &&
          widget.item.path.isEmpty;
  bool get editable =>
      personal || widget.entry == null || widget.entry!.state == 'synced';
  Map<String, dynamic>? get selectedCollection {
    final key = fields.values
        .where((f) => f.field == 'libraryType')
        .firstOrNull
        ?.key;
    final id = controllers[key]?.text;
    return widget.collections.where((c) => c['id'] == id).firstOrNull ??
        widget.collection;
  }

  @override
  void initState() {
    super.initState();
    for (final key in values.keys) {
      controllers[key] = TextEditingController(
        text: _fieldText(key, values[key]),
      );
    }
    if (widget.collection?['statuses'] is Map) {
      final key = fields.values
          .where((f) => f.field == 'status')
          .firstOrNull
          ?.key;
      if (key != null) {
        controllers[key]!.text = exportLibraryStatus(
          values[key],
          widget.collection,
        );
      }
    }
  }

  @override
  void dispose() {
    for (final controller in controllers.values) {
      controller.dispose();
    }
    for (final node in focusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  String _fieldText(String key, dynamic value) =>
      value is List && value.every((v) => v is String)
      ? value.join(', ')
      : metadataText(value);
  dynamic _parse(String key, String text) {
    if (text == _fieldText(key, widget.item.values[key])) {
      return widget.item.values[key];
    }
    if (text.trim().isEmpty) return null;
    final original = values[key], kind = fields[key]?.kind;
    if (kind == 'list' ||
        (original is List && original.every((v) => v is String))) {
      if (text.trimLeft().startsWith('[')) {
        final parsed = jsonDecode(text);
        if (parsed is! List) {
          throw const FormatException('Введите имена через запятую');
        }
        return parsed;
      }
      return text
          .split(RegExp(r'[,;\n]'))
          .map((v) => v.trim())
          .where((v) => v.isNotEmpty)
          .toList();
    }
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
    if (original is num ||
        (kind == 'number' && original is! String) ||
        ['total', 'progress', 'seriesIndex'].contains(fields[key]?.field)) {
      final number = num.tryParse(text.replaceAll(',', '.'));
      if (number == null || !number.isFinite) {
        throw const FormatException('Введите число');
      }
      return number;
    }
    return text;
  }

  Future<void> _save() async {
    if (saving || !editable) return;
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
      dynamic property(String field) =>
          next[fields.values.where((f) => f.field == field).firstOrNull?.key];
      final start = DateTime.tryParse('${property('startDate')}');
      final end = DateTime.tryParse('${property('endDate')}');
      if (start != null && end != null && end.isBefore(start)) {
        throw const FormatException('Дата завершения раньше даты начала');
      }
      final total = num.tryParse('${property('total')}');
      final progress = num.tryParse('${property('progress')}');
      if (total != null && total > 0 && progress != null && progress > total) {
        throw const FormatException('Прогресс больше общего объёма');
      }
      await widget.onSavePolicy?.call(policy);
      await widget.onSave(next);
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _suggestTitle() async {
    final proposal = suggestAudioTitle(widget.item.title);
    if (proposal == null) return;
    final chosen = proposal.keys.toSet();
    final apply = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Разобрать название'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Предложение по имени файла. Проверьте автора, часть и чтеца перед применением.',
                ),
                for (final entry in proposal.entries)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(libraryLabels[entry.key] ?? 'Чтец'),
                    subtitle: Text(
                      entry.value is List
                          ? (entry.value as List).join(', ')
                          : '${entry.value}',
                    ),
                    value: chosen.contains(entry.key),
                    onChanged: (value) => update(() {
                      if (value == true) {
                        chosen.add(entry.key);
                      } else {
                        chosen.remove(entry.key);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Применить'),
            ),
          ],
        ),
      ),
    );
    if (apply != true || !mounted) return;
    setState(() {
      for (final field in chosen) {
        final key =
            fields.values.where((f) => f.field == field).firstOrNull?.key ??
            field;
        final value = proposal[field];
        values[key] = value;
        (controllers[key] ??= TextEditingController()).text = value is List
            ? jsonEncode(value)
            : '$value';
      }
      editGeneration++;
    });
  }

  Widget _policyPanel() => ShelfPanel(
    child: ExpansionTile(
      title: const Text('Автообновление из приложения'),
      subtitle: const Text('Статус, прогресс и ручные правки'),
      childrenPadding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Авто обновляет данные, заполненные приложением. Ручные изменения сохраняются. Для связанных карточек можно явно выбрать источник.',
        ),
        const SizedBox(height: 12),
        for (final field in [
          'status',
          'progress',
          'startDate',
          'endDate',
          'readingTime',
          'author',
          'genre',
          'series',
        ])
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: DropdownButtonFormField<String>(
              initialValue: policy[field] ?? 'auto',
              isExpanded: true,
              decoration: InputDecoration(
                labelText: field == 'progress'
                    ? 'Прогресс, объём и единицы'
                    : libraryLabels[field],
              ),
              items: const [
                DropdownMenuItem(
                  value: 'auto',
                  child: Text('Авто · сохранять мои правки'),
                ),
                DropdownMenuItem(
                  value: 'local',
                  child: Text('Обновлять из приложения'),
                ),
                DropdownMenuItem(
                  value: 'obsidian',
                  child: Text('Сохранять ручное значение'),
                ),
              ],
              onChanged: !editable || saving
                  ? null
                  : (value) {
                      policy[field] = value!;
                      if (field == 'progress') {
                        policy['total'] = value;
                        policy['unit'] = value;
                      }
                    },
            ),
          ),
      ],
    ),
  );

  Future<void> _addProperty() async {
    var name = '';
    final key = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Дополнительное свойство'),
        content: TextField(
          onChanged: (value) => name = value,
          decoration: const InputDecoration(labelText: 'Название свойства'),
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

  String? _validate(String key, String? text) {
    try {
      final parsed = _parse(key, text ?? '');
      final field = fields[key]?.field ?? key;
      if (field == 'title' && '${parsed ?? ''}'.trim().isEmpty) {
        return 'Укажите название';
      }
      if (['startDate', 'endDate', 'targetDate'].contains(field) &&
          parsed != null &&
          DateTime.tryParse('$parsed') == null) {
        return 'Выберите дату';
      }
      if (parsed is num &&
          ['progress', 'total', 'rating', 'seriesIndex'].contains(field) &&
          parsed < 0) {
        return 'Укажите число не меньше нуля';
      }
      return null;
    } catch (_) {
      return 'Проверьте значение';
    }
  }

  Future<void> _date(String key) async {
    final value =
        DateTime.tryParse(controllers[key]!.text)?.toLocal() ?? DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: value.isBefore(DateTime(1900))
          ? DateTime(1900)
          : value.isAfter(DateTime(2200))
          ? DateTime(2200)
          : value,
      firstDate: DateTime(1900),
      lastDate: DateTime(2200),
    );
    if (selected != null && mounted) {
      setState(
        () => controllers[key]!.text =
            '${selected.year}-${selected.month.toString().padLeft(2, '0')}-${selected.day.toString().padLeft(2, '0')}',
      );
    }
  }

  Future<void> _rating(String key) async {
    final selected = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Оценка по шкале 0–10'),
        content: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var score = 0; score <= 10; score++)
              ActionChip(
                label: Text('$score'),
                onPressed: () => Navigator.pop(context, score),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
        ],
      ),
    );
    if (selected != null && mounted) {
      setState(() => controllers[key]!.text = '$selected');
    }
  }

  Widget _field(String key) {
    final semantic = fields[key]?.field ?? key;
    if (personal && ['status', 'libraryType'].contains(semantic)) {
      return const SizedBox.shrink();
    }
    final label =
        libraryLabels[semantic] ??
        {
          'narrator': 'Чтец',
          'language': 'Язык',
          'publisher': 'Издательство',
          'tags': 'Теги',
        }[key] ??
        key;
    final enabled = editable && !saving;
    final suggestions = widget.suggestions[semantic] ?? const <String>[];
    if (['author', 'genre', 'tags'].contains(semantic)) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: MetadataTokensField(
          key: ValueKey('tokens:$key:$editGeneration'),
          controller: controllers[key]!,
          initial: _parse(key, controllers[key]!.text),
          label: label,
          suggestions: suggestions,
          enabled: enabled,
        ),
      );
    }
    if (semantic == 'status' ||
        semantic == 'unit' ||
        semantic == 'format' ||
        semantic == 'libraryType') {
      final statuses = libraryStatuses(selectedCollection);
      final options = <String>{
        if (controllers[key]!.text.isNotEmpty) controllers[key]!.text,
        ...suggestions.map(
          (s) => semantic == 'status'
              ? statuses[canonicalLibraryStatus(s)] ?? s
              : s,
        ),
        if (semantic == 'status') ...statuses.values,
        if (semantic == 'unit')
          ...((selectedCollection?['progressUnits'] as List?)?.cast<String>() ??
                  ['pages', 'minutes', 'hours', 'characters'])
              .where(
                (unit) =>
                    widget.item.mediaType != 'audiobook' ||
                    ['minutes', 'hours'].contains(unit),
              ),
        if (semantic == 'format') ...['E-book', 'Audiobook', 'Paper'],
        if (semantic == 'libraryType')
          ...widget.collections
              .where(
                (c) =>
                    c['mediaType'] == widget.item.mediaType ||
                    c['id'] == 'book',
              )
              .map((c) => '${c['id']}'),
      };
      const unitLabels = {
        'pages': 'Страницы',
        'minutes': 'Минуты',
        'hours': 'Часы',
        'percent': 'Проценты',
        'characters': 'Символы',
      };
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: DropdownButtonFormField<String>(
          key: ValueKey('choice:$key:${controllers[key]!.text}'),
          initialValue: controllers[key]!.text.isEmpty
              ? null
              : controllers[key]!.text,
          isExpanded: true,
          decoration: InputDecoration(labelText: label),
          items: [
            for (final value in options)
              DropdownMenuItem(
                value: value,
                child: Text(
                  semantic == 'unit'
                      ? unitLabels[value] ?? value
                      : statuses[canonicalLibraryStatus(value)] ?? value,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: !enabled
              ? null
              : (value) {
                  final old = statuses;
                  final previous = controllers[key]!.text;
                  controllers[key]!.text = value ?? '';
                  String? propertyKey(String field) => fields.values
                      .where((f) => f.field == field)
                      .firstOrNull
                      ?.key;
                  if (semantic == 'status') {
                    final canonical =
                        statuses.entries
                            .where((e) => e.value == value)
                            .firstOrNull
                            ?.key ??
                        canonicalLibraryStatus(value);
                    if (canonical == 'finished' || canonical == 'active') {
                      final dateKey = propertyKey(
                        canonical == 'finished' ? 'endDate' : 'startDate',
                      );
                      if (dateKey != null &&
                          controllers[dateKey]!.text.isEmpty) {
                        final now = DateTime.now();
                        controllers[dateKey]!.text =
                            '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
                      }
                    }
                    if (canonical == 'finished') {
                      final totalKey = propertyKey('total'),
                          progressKey = propertyKey('progress');
                      if (totalKey != null &&
                          progressKey != null &&
                          controllers[totalKey]!.text.isNotEmpty) {
                        controllers[progressKey]!.text =
                            controllers[totalKey]!.text;
                      }
                    }
                    setState(() {});
                  }
                  if (semantic == 'unit' && previous != value) {
                    final totalKey = propertyKey('total'),
                        progressKey = propertyKey('progress');
                    final total = num.tryParse(
                      controllers[totalKey]?.text ?? '',
                    );
                    for (final target in [
                      totalKey,
                      progressKey,
                    ].whereType<String>()) {
                      final amount = num.tryParse(controllers[target]!.text);
                      if (amount == null) continue;
                      final factor = previous == 'minutes' && value == 'hours'
                          ? 1 / 60
                          : previous == 'hours' && value == 'minutes'
                          ? 60
                          : value == 'percent' && total != null && total > 0
                          ? 100 / total
                          : null;
                      if (factor != null) {
                        controllers[target]!.text =
                            '${(amount * factor * 100).round() / 100}';
                      }
                    }
                    setState(() {});
                  }
                  if (semantic == 'libraryType') {
                    final statusKey = fields.values
                        .where((f) => f.field == 'status')
                        .firstOrNull
                        ?.key;
                    if (statusKey != null) {
                      final text = controllers[statusKey]!.text;
                      final canonical =
                          old.entries
                              .where((e) => e.value == text)
                              .firstOrNull
                              ?.key ??
                          canonicalLibraryStatus(text);
                      controllers[statusKey]!.text =
                          libraryStatuses(selectedCollection)[canonical] ??
                          text;
                    }
                    setState(() {});
                  }
                },
        ),
      );
    }
    final numeric =
        fields[key]?.kind == 'number' ||
        values[key] is num ||
        ['total', 'progress', 'seriesIndex'].contains(semantic);
    final isDate = ['startDate', 'endDate', 'targetDate'].contains(semantic);
    final decoration = InputDecoration(
      labelText: label,
      helperText: semantic == 'total' || semantic == 'progress'
          ? 'В выбранных единицах объёма'
          : semantic == 'readingTime'
          ? 'Фактическое время, ЧЧ:ММ:СС'
          : null,
      suffixIcon: isDate
          ? IconButton(
              tooltip: 'Выбрать дату',
              onPressed: enabled ? () => _date(key) : null,
              icon: const Icon(Icons.calendar_today_outlined),
            )
          : semantic == 'rating'
          ? IconButton(
              tooltip: 'Выбрать оценку',
              onPressed: enabled ? () => _rating(key) : null,
              icon: const Icon(Icons.star_outline_rounded),
            )
          : semantic == 'cover' && widget.onPickCover != null
          ? IconButton(
              tooltip: 'Выбрать файл обложки',
              icon: const Icon(Icons.image_outlined),
              onPressed: !enabled
                  ? null
                  : () async {
                      try {
                        final selected = await widget.onPickCover!();
                        if (selected != null && mounted) {
                          setState(() => controllers[key]!.text = selected);
                        }
                      } catch (e) {
                        if (mounted) setState(() => error = '$e');
                      }
                    },
            )
          : null,
    );
    Widget input(
      TextEditingController controller,
      FocusNode? node,
      VoidCallback? submit,
    ) => TextFormField(
      key: ValueKey('metadata:$key'),
      controller: controller,
      focusNode: node,
      enabled: enabled,
      minLines: 1,
      maxLines: numeric || isDate || suggestions.isNotEmpty
          ? 1
          : semantic == 'title'
          ? 2
          : 5,
      keyboardType: numeric
          ? const TextInputType.numberWithOptions(decimal: true)
          : null,
      decoration: decoration,
      validator: (text) => _validate(key, text),
      onChanged: semantic == 'cover' ? (_) => setState(() {}) : null,
      onFieldSubmitted: submit == null ? null : (_) => submit(),
    );
    final field = suggestions.isEmpty
        ? input(controllers[key]!, null, null)
        : RawAutocomplete<String>(
            textEditingController: controllers[key],
            focusNode: focusNodes.putIfAbsent(key, () => FocusNode()),
            optionsBuilder: (value) => suggestions
                .where(
                  (s) => s.toLowerCase().contains(value.text.toLowerCase()),
                )
                .take(8),
            fieldViewBuilder: (context, controller, node, submit) =>
                input(controller, node, submit),
            optionsViewBuilder: (context, onSelected, options) => Align(
              alignment: Alignment.topLeft,
              child: Material(
                elevation: 6,
                borderRadius: BorderRadius.circular(16),
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: (MediaQuery.sizeOf(context).width - 96).clamp(
                      160,
                      420,
                    ),
                    maxHeight: 240,
                  ),
                  child: ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: [
                      for (final option in options)
                        ListTile(
                          title: Text(option),
                          onTap: () => onSelected(option),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [field, if (semantic == 'cover') _coverPreview(key)],
      ),
    );
  }

  Widget _coverPreview(String key) {
    final reference = controllers[key]!.text;
    final path = widget.coverResolver?.call(reference);
    final remote = Uri.tryParse(reference);
    final Widget? picture = path != null
        ? Image.file(
            File(path),
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
          )
        : remote?.scheme == 'https'
        ? Image.network(
            reference,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
          )
        : null;
    if (picture == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(width: 88, height: 120, child: picture),
      ),
    );
  }

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
      'readingTime',
    };
    final main = controllers.keys.where(
      (key) =>
          (fields.containsKey(key) &&
              !progressFields.contains(fields[key]!.field)) ||
          ['narrator', 'language', 'publisher', 'tags', 'notes'].contains(key),
    );
    final progress = controllers.keys.where(
      (key) => progressFields.contains(fields[key]?.field),
    );
    final extra = controllers.keys.where(
      (key) =>
          !fields.containsKey(key) &&
          !key.startsWith('pepehub_') &&
          ![
            'narrator',
            'language',
            'publisher',
            'tags',
            'notes',
            'embeddedMetadata',
          ].contains(key),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Метаданные книги')),
      bottomNavigationBar: AudioPlayerFooter(
        child: editable
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
                          label: Text(
                            saving ? 'Сохранение…' : widget.saveLabel,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            : null,
      ),
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
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable:
                        controllers[fields.values
                            .where((f) => f.field == 'title')
                            .firstOrNull
                            ?.key] ??
                        controllers.values.first,
                    builder: (context, value, _) => Text(
                      value.text.isEmpty ? 'Новая книга' : value.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  if (editable &&
                      widget.item.mediaType == 'audiobook' &&
                      suggestAudioTitle(widget.item.title) != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: saving ? null : _suggestTitle,
                        icon: const Icon(Icons.auto_fix_high_outlined),
                        label: const Text('Разобрать имя файла'),
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
                            Icons.local_library_outlined,
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
                  if (widget.onSavePolicy != null) ...[
                    const SizedBox(height: 20),
                    _policyPanel(),
                  ],
                  if (extra.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    ExpansionTile(
                      title: const Text('Дополнительные свойства'),
                      children: [
                        _fieldsPanel(
                          'Сведения об издании',
                          Icons.tune_rounded,
                          extra,
                        ),
                      ],
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
                        for (final field in fields.values)
                          Text(
                            '${libraryLabels[field.field] ?? field.field}: ${field.key}',
                            style: TextStyle(
                              fontSize: 11,
                              color: palette.muted,
                            ),
                          ),
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
                              'Изменено: ${DateTime.fromMillisecondsSinceEpoch(widget.item.modifiedAt).toLocal()}',
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
