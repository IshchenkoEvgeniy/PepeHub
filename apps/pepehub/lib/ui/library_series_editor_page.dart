import 'dart:convert';

import 'package:flutter/material.dart';

import '../data/repository.dart' show uuid;
import '../library/library_features.dart';
import '../library/library_service.dart';
import '../library/metadata_values.dart';
import '../library/models.dart';
import '../library/personal_library.dart';
import '../library/series_draft.dart';
import 'app_theme.dart';
import 'library_cover_search.dart';
import 'metadata_input.dart';
import 'obsidian_library_page.dart' show LibraryMetadataEditor;

class _Volume {
  final String source;
  ObsidianLibraryItem item;
  bool selected = true, allowDuplicate = false, customType = false;
  final Set<String> overrides = {};
  _Volume(this.source, this.item);
}

Future<void> openLibrarySeriesEditor(
  BuildContext context,
  LibraryService library, {
  LibrarySeriesGroup? series,
}) async {
  final added = await Navigator.push<int>(
    context,
    MaterialPageRoute(
      builder: (_) => LibrarySeriesEditorPage(library: library, series: series),
    ),
  );
  if (added != null && context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Добавлено томов: $added')));
  }
}

/// All edits, including the full metadata editor, stay in memory until the
/// reviewed selection is saved in one catalog transaction.
class LibrarySeriesEditorPage extends StatefulWidget {
  final LibraryService library;
  final LibrarySeriesGroup? series;
  const LibrarySeriesEditorPage({
    super.key,
    required this.library,
    this.series,
  });
  @override
  State<LibrarySeriesEditorPage> createState() =>
      _LibrarySeriesEditorPageState();
}

class _LibrarySeriesEditorPageState extends State<LibrarySeriesEditorPage> {
  final form = GlobalKey<FormState>();
  final name = TextEditingController(), authors = TextEditingController();
  final narrators = TextEditingController(), genres = TextEditingController();
  final language = TextEditingController(), publisher = TextEditingController();
  final tags = TextEditingController();
  final titles = TextEditingController(),
      firstIndex = TextEditingController(text: '1');
  late final String seriesId;
  late final Map<String, List<String>> suggestions;
  String mediaType = 'book', status = 'finished';
  String bookFormat = 'E-book';
  List<_Volume> volumes = [];
  Map<String, dynamic> previousDefaults = {};
  Map<String, String> conflicts = {};
  String? error;
  bool reviewing = false, saving = false;

  @override
  void initState() {
    super.initState();
    suggestions = widget.library.suggestions;
    final group = widget.series;
    final first = group?.entries.firstOrNull?.item;
    name.text = group?.name ?? '';
    authors.text = jsonEncode(metadataStrings(first?.value('author')));
    Object? common(String field, {String? type}) {
      final members =
          group?.entries
              .where((e) => type == null || e.item.mediaType == type)
              .toList() ??
          [];
      if (members.isEmpty) return null;
      Object? property(LibraryEntry e) =>
          e.item.value(field) ?? e.item.values[field];
      final value = property(members.first);
      return members.every((e) => sameMetadataValue(property(e), value))
          ? value
          : null;
    }

    narrators.text = jsonEncode(
      metadataStrings(common('narrator', type: 'audiobook')),
    );
    genres.text = jsonEncode(metadataStrings(common('genre')));
    tags.text = jsonEncode(metadataStrings(common('tags')));
    language.text = '${common('language') ?? ''}';
    publisher.text = '${common('publisher') ?? ''}';
    final format = common('format', type: 'book');
    if (format == 'Paper') bookFormat = 'Paper';
    mediaType = first?.mediaType ?? 'book';
    final existingId = first?.values['pepehub_series_id'];
    seriesId = existingId is String && existingId.isNotEmpty
        ? existingId
        : uuid.v4();
    if (group != null) {
      final indices = group.entries
          .map((e) => num.tryParse('${e.item.value('seriesIndex')}'))
          .whereType<num>()
          .where((n) => n.isFinite && n >= 0);
      final maximum = indices.fold<num>(0, (a, b) => a > b ? a : b);
      firstIndex.text = '${maximum.floor() + 1}';
    }
  }

  @override
  void dispose() {
    name.dispose();
    authors.dispose();
    narrators.dispose();
    genres.dispose();
    language.dispose();
    publisher.dispose();
    tags.dispose();
    titles.dispose();
    firstIndex.dispose();
    super.dispose();
  }

  void _checkConflicts() {
    conflicts = seriesDraftConflicts(
      volumes.map((v) => v.item),
      widget.library.entries,
      existingSeriesKey: widget.series?.key,
    );
    for (final volume in volumes) {
      if (conflicts.containsKey(volume.item.id) && !volume.allowDuplicate) {
        volume.selected = false;
      }
    }
  }

  void _prepare() {
    if (!form.currentState!.validate()) return;
    final parsed = parseSeriesTitles(
      titles.text,
      firstIndex: num.parse(firstIndex.text.replaceAll(',', '.')),
    );
    if (parsed.isEmpty || parsed.length > 1000) {
      setState(
        () => error = 'Введите от 1 до 1000 названий, каждое с новой строки.',
      );
      return;
    }
    final old = {for (final v in volumes) v.source: v};
    final defaults = <String, dynamic>{
      'author': _tokens(authors),
      'genre': _tokens(genres),
      if (mediaType == 'audiobook') 'narrator': _tokens(narrators),
      'language': language.text.trim().isEmpty ? null : language.text.trim(),
      'publisher': publisher.text.trim().isEmpty ? null : publisher.text.trim(),
      'tags': _tokens(tags),
      'status': status,
      'format': mediaType == 'audiobook' ? 'Audiobook' : bookFormat,
      'unit': mediaType == 'audiobook' ? 'minutes' : 'pages',
    };
    final next = <_Volume>[];
    for (var i = 0; i < parsed.length; i++) {
      final row = parsed[i];
      // Include the occurrence so identical pasted titles keep distinct drafts.
      final source = '$i:${row.index}:${row.title}';
      final previous = old[source];
      final values = <String, dynamic>{
        'title': row.title,
        'seriesIndex': row.index,
        ...defaults,
        ...?previous?.item.values,
        for (final e in defaults.entries)
          if (previous != null &&
              !previous.overrides.contains(e.key) &&
              e.key != 'unit' &&
              (e.key != 'format' || !previous.customType) &&
              sameMetadataValue(
                previous.item.values[e.key],
                previousDefaults[e.key],
              ))
            e.key: e.value,
        'series': name.text.trim(),
        'pepehub_series_id': seriesId,
      };
      final type = previous?.customType == true
          ? previous!.item.mediaType
          : mediaType;
      if (previous != null && previous.item.mediaType != type) {
        values.addAll({
          'format': type == 'audiobook' ? 'Audiobook' : bookFormat,
          'unit': type == 'audiobook' ? 'minutes' : 'pages',
          'total': null,
          'progress': null,
        });
      }
      if (type == 'book') values.remove('narrator');
      final item = personalLibraryItem(
        previous?.item.id ?? uuid.v4(),
        type,
        values,
      );
      final volume = previous ?? _Volume(source, item);
      volume.item = item;
      next.add(volume);
    }
    setState(() {
      volumes = next;
      previousDefaults = defaults;
      _checkConflicts();
      reviewing = true;
      error = null;
    });
  }

  List<String> _tokens(TextEditingController controller) {
    try {
      return metadataStrings(jsonDecode(controller.text));
    } on FormatException {
      return metadataStrings(controller.text);
    }
  }

  Future<void> _edit(_Volume volume) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (routeContext) => LibraryMetadataEditor(
          item: volume.item,
          lockedFields: const {'series'},
          collection: widget.library.collectionFor(volume.item),
          suggestions: widget.library.suggestions,
          coverResolver: widget.library.coverReferencePath,
          onPickCover: widget.library.chooseCover,
          onSearchCover: () => Navigator.push<String>(
            routeContext,
            MaterialPageRoute(
              builder: (_) => LibraryCoverSearch(
                library: widget.library,
                item: volume.item,
              ),
            ),
          ),
          saveLabel: 'Применить к тому',
          onSave: (values) async {
            final next = personalLibraryItem(
              volume.item.id,
              volume.item.mediaType,
              {
                ...values,
                'series': name.text.trim(),
                'pepehub_series_id': seriesId,
              },
            );
            validateSeriesDraft(next);
            setState(() {
              for (final key in next.values.keys) {
                final tokens = const {
                  'author',
                  'genre',
                  'narrator',
                  'tags',
                }.contains(key);
                if (!sameMetadataValue(
                  tokens
                      ? metadataStrings(volume.item.values[key])
                      : volume.item.values[key],
                  tokens ? metadataStrings(next.values[key]) : next.values[key],
                )) {
                  volume.overrides.add(key);
                }
              }
              volume.item = next;
              _checkConflicts();
            });
          },
        ),
      ),
    );
  }

  void _type(_Volume volume, String type) {
    if (type == volume.item.mediaType) return;
    setState(() {
      volume.customType = true;
      final values = <String, dynamic>{
        ...volume.item.values,
        'format': type == 'audiobook' ? 'Audiobook' : bookFormat,
        'unit': type == 'audiobook' ? 'minutes' : 'pages',
        if (type == 'audiobook') 'narrator': _tokens(narrators),
        // Pages cannot silently become minutes (or the reverse).
        'total': null, 'progress': null,
      };
      if (type == 'book') values.remove('narrator');
      volume.item = personalLibraryItem(volume.item.id, type, values);
      _checkConflicts();
    });
  }

  Future<void> _save() async {
    if (saving) return;
    final chosen = volumes.where((v) => v.selected).toList();
    if (chosen.isEmpty) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final ids = await widget.library.addSeries(
        chosen.map((v) => v.item),
        allowDuplicateIds: {
          for (final v in chosen)
            if (v.allowDuplicate) v.item.id,
        },
        existingSeriesKey: widget.series?.key,
      );
      if (mounted) Navigator.pop(context, ids.length);
    } catch (failure) {
      if (mounted) {
        setState(() {
          error = '$failure';
          _checkConflicts();
          saving = false;
        });
      }
    }
  }

  Widget _tokenField(
    String field,
    String label,
    TextEditingController controller,
  ) => MetadataTokensField(
    key: ValueKey('series-$field'),
    controller: controller,
    initial: _tokens(controller),
    label: label,
    suggestions: suggestions[field] ?? [],
    enabled: true,
  );

  Widget _extra() => ExpansionTile(
    key: const ValueKey('series-extra'),
    tilePadding: EdgeInsets.zero,
    title: const Text('Издание и теги'),
    childrenPadding: const EdgeInsets.only(top: 8, bottom: 16),
    maintainState: true,
    children: [
      if (mediaType == 'book') ...[
        DropdownButtonFormField<String>(
          key: const ValueKey('series-format'),
          initialValue: bookFormat,
          decoration: const InputDecoration(labelText: 'Формат издания'),
          items: const [
            DropdownMenuItem(value: 'E-book', child: Text('Электронная книга')),
            DropdownMenuItem(value: 'Paper', child: Text('Бумажная книга')),
          ],
          onChanged: (v) => setState(() => bookFormat = v!),
        ),
        const SizedBox(height: 16),
      ],
      TextFormField(
        key: const ValueKey('series-language'),
        controller: language,
        decoration: const InputDecoration(labelText: 'Язык'),
      ),
      const SizedBox(height: 16),
      TextFormField(
        key: const ValueKey('series-publisher'),
        controller: publisher,
        decoration: const InputDecoration(labelText: 'Издательство'),
      ),
      const SizedBox(height: 16),
      _tokenField('tags', 'Теги', tags),
    ],
  );

  Widget _shared({bool includeExtra = true}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('Общее для серии', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 16),
      TextFormField(
        key: const ValueKey('series-name'),
        controller: name,
        enabled: widget.series == null,
        decoration: const InputDecoration(labelText: 'Название серии'),
        validator: (v) =>
            v == null || v.trim().isEmpty ? 'Укажите название серии' : null,
      ),
      const SizedBox(height: 16),
      MetadataTokensField(
        key: const ValueKey('series-authors'),
        controller: authors,
        initial: _tokens(authors),
        label: 'Авторы',
        suggestions: suggestions['author'] ?? [],
        enabled: true,
      ),
      const SizedBox(height: 16),
      DropdownButtonFormField<String>(
        key: const ValueKey('series-type'),
        initialValue: mediaType,
        decoration: const InputDecoration(labelText: 'Тип произведений'),
        items: const [
          DropdownMenuItem(value: 'book', child: Text('Книги')),
          DropdownMenuItem(value: 'audiobook', child: Text('Аудиокниги')),
        ],
        onChanged: (v) => setState(() => mediaType = v!),
      ),
      const SizedBox(height: 16),
      if (mediaType == 'audiobook') ...[
        _tokenField('narrator', 'Чтецы', narrators),
        const SizedBox(height: 16),
      ],
      _tokenField('genre', 'Жанры', genres),
      const SizedBox(height: 16),
      DropdownButtonFormField<String>(
        key: const ValueKey('series-status'),
        initialValue: status,
        decoration: const InputDecoration(labelText: 'Статус томов'),
        items: [
          for (final e in seriesVolumeStatuses(mediaType).entries)
            DropdownMenuItem(value: e.key, child: Text(e.value)),
        ],
        onChanged: (v) => setState(() => status = v!),
      ),
      if (includeExtra) ...[const SizedBox(height: 16), _extra()],
    ],
  );

  Widget _paste() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('Тома по порядку', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 16),
      TextFormField(
        key: const ValueKey('series-first-index'),
        controller: firstIndex,
        decoration: const InputDecoration(labelText: 'Номер первого тома'),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        validator: (v) {
          final n = num.tryParse((v ?? '').replaceAll(',', '.'));
          return n == null || !n.isFinite || n < 0
              ? 'Укажите число не меньше нуля'
              : null;
        },
      ),
      const SizedBox(height: 16),
      TextFormField(
        key: const ValueKey('series-titles'),
        controller: titles,
        minLines: 5,
        maxLines: 12,
        keyboardType: TextInputType.multiline,
        decoration: const InputDecoration(
          labelText: 'Названия томов',
          alignLabelWithHint: true,
          hintText: 'Каждое название с новой строки',
          helperText: 'Можно с номерами: 1. Название, 0.5. Предыстория',
          helperMaxLines: 2,
        ),
        validator: (v) =>
            v == null || v.trim().isEmpty ? 'Добавьте названия томов' : null,
      ),
      const SizedBox(height: 16),
      const Text(
        'Даты, оценки и объём можно указать отдельно для каждого тома на следующем шаге.',
      ),
    ],
  );

  Widget _volume(_Volume volume) {
    final item = volume.item;
    final warning = conflicts[item.id];
    final details = [
      ...metadataStrings(item.value('genre')),
      if (item.mediaType == 'audiobook' &&
          metadataStrings(item.values['narrator']).isNotEmpty)
        'Чтецы: ${metadataStrings(item.values['narrator']).join(', ')}',
    ].join(' · ');
    return Padding(
      key: ValueKey('series-volume:${item.id}'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Checkbox(
            value: volume.selected,
            onChanged: saving
                ? null
                : (selected) => setState(() {
                    volume.selected = selected!;
                    volume.allowDuplicate = selected && warning != null;
                  }),
          ),
          Expanded(
            child: InkWell(
              onTap: saving ? null : () => _edit(volume),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Том ${item.value('seriesIndex')} · ${item.title}',
                      style: AppFonts.book(
                        Theme.of(context).colorScheme.onSurface,
                        size: 17,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${item.mediaType == 'audiobook' ? 'Аудиокнига' : 'Книга'} · ${seriesVolumeStatuses(item.mediaType)[libraryStatus(item)]}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (details.isNotEmpty)
                      Text(
                        details,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    if (warning != null)
                      Text(
                        warning,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Изменить том',
            onPressed: saving ? null : () => _edit(volume),
            icon: const Icon(Icons.edit_outlined),
          ),
          PopupMenuButton<String>(
            enabled: !saving,
            tooltip: 'Тип тома',
            onSelected: (type) => _type(volume, type),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'book', child: Text('Книга')),
              PopupMenuItem(value: 'audiobook', child: Text('Аудиокнига')),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chosen = volumes.where((v) => v.selected).length;
    return PopScope(
      canPop: !saving && !reviewing,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && reviewing && !saving) {
          setState(() {
            reviewing = false;
            error = null;
          });
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            widget.series == null ? 'Добавить серию' : 'Добавить тома',
          ),
          leading: reviewing
              ? IconButton(
                  tooltip: 'К общим сведениям',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: saving
                      ? null
                      : () => setState(() {
                          reviewing = false;
                          error = null;
                        }),
                )
              : null,
        ),
        body: Form(
          key: form,
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.all(20),
                sliver: SliverToBoxAdapter(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1040),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (!reviewing) ...[
                            const Text(
                              'Добавьте тома серии, включая ещё не прочитанные или не прослушанные.',
                            ),
                            const SizedBox(height: 24),
                            LayoutBuilder(
                              builder: (context, constraints) =>
                                  constraints.maxWidth >= 760
                                  // 1040 = 340 + 24 + 676; both edges stay on the same column.
                                  ? Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        SizedBox(width: 340, child: _shared()),
                                        const SizedBox(width: 24),
                                        Expanded(child: _paste()),
                                      ],
                                    )
                                  : Column(
                                      children: [
                                        _shared(includeExtra: false),
                                        const SizedBox(height: 24),
                                        _paste(),
                                        const SizedBox(height: 16),
                                        _extra(),
                                      ],
                                    ),
                            ),
                          ] else ...[
                            Text(
                              name.text.trim(),
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Выбрано $chosen из ${volumes.length} томов. Нажмите на том, чтобы уточнить карточку.',
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 12,
                              runSpacing: 8,
                              children: [
                                TextButton(
                                  onPressed: saving
                                      ? null
                                      : () => setState(() {
                                          for (final v in volumes) {
                                            v.selected = !conflicts.containsKey(
                                              v.item.id,
                                            );
                                          }
                                        }),
                                  child: const Text('Выбрать без совпадений'),
                                ),
                                PopupMenuButton<String>(
                                  enabled: !saving,
                                  onSelected: (value) => setState(() {
                                    for (final v in volumes.where(
                                      (v) => v.selected,
                                    )) {
                                      v.overrides.add('status');
                                      v.item = v.item.withValues({
                                        ...v.item.values,
                                        'status': value,
                                      });
                                    }
                                  }),
                                  itemBuilder: (_) => [
                                    for (final e in seriesVolumeStatuses(
                                      mediaType,
                                    ).entries)
                                      PopupMenuItem(
                                        value: e.key,
                                        child: Text(e.value),
                                      ),
                                  ],
                                  child: const Padding(
                                    padding: EdgeInsets.symmetric(vertical: 12),
                                    child: Text('Статус выбранным'),
                                  ),
                                ),
                              ],
                            ),
                            if (conflicts.isNotEmpty)
                              const Text(
                                'Совпадения не выбраны. Отметьте их, если хотите создать отдельные карточки.',
                              ),
                            const SizedBox(height: 8),
                            const Text(
                              'Неуказанные даты останутся пустыми. Каждый том сохранится отдельной карточкой.',
                            ),
                          ],
                          if (error != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: Text(
                                error!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (reviewing)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                  sliver: SliverList.builder(
                    itemCount: volumes.length,
                    itemBuilder: (context, i) => Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 1040),
                        child: _volume(volumes[i]),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              12,
              20,
              12 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Center(
              heightFactor: 1,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1040),
                child: SizedBox(
                  width: double.infinity,
                  child: Align(
                    heightFactor: 1,
                    alignment: Alignment.centerRight,
                    child: SizedBox(
                      width: MediaQuery.sizeOf(context).width >= 760
                          ? 320
                          : double.infinity,
                      child: FilledButton(
                        key: const ValueKey('series-primary'),
                        onPressed: saving || reviewing && chosen == 0
                            ? null
                            : reviewing
                            ? _save
                            : _prepare,
                        child: Text(
                          saving
                              ? 'Сохранение…'
                              : reviewing
                              ? 'Добавить томов: $chosen'
                              : 'Проверить тома',
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
