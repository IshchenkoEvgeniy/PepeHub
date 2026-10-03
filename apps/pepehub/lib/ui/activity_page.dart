import 'package:flutter/material.dart';

import '../library/library_service.dart';
import '../library/models.dart';
import '../audio/audio_journal.dart' show dayKey;

String activityTime(num ms) {
  final seconds = (ms / 1000).round(), minutes = seconds ~/ 60;
  return minutes == 0
      ? '$seconds сек'
      : minutes < 60
      ? '$minutes мин'
      : '${minutes ~/ 60} ч ${minutes % 60} мин';
}

class ActivityPage extends StatefulWidget {
  final LibraryService library;
  final String? itemId;
  const ActivityPage({super.key, required this.library, this.itemId});
  @override
  State<ActivityPage> createState() => _ActivityPageState();
}

class _ActivityPageState extends State<ActivityPage> {
  List<Map<String, dynamic>> slots = [];
  String type = 'all', search = '';
  int days = 0;
  bool loading = true;
  String? error;
  @override
  void initState() {
    super.initState();
    widget.library.addListener(_changed);
    _load();
  }

  @override
  void dispose() {
    widget.library.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!widget.library.syncing) _load();
  }

  Future<void> _load() async {
    try {
      await widget.library.history?.capture();
      final values =
          await widget.library.history?.entries(itemId: widget.itemId) ??
          <Map<String, dynamic>>[];
      if (mounted) {
        setState(() {
          slots = values;
          loading = false;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          loading = false;
        });
      }
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
      await widget.library.sync();
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> _edit(Map<String, dynamic> slot) async {
    final value = Map<String, dynamic>.from(slot['value']);
    var minutes = (value['durationMs'] as num) / 60000,
        progress = value['progress'] as num,
        note = value['note'] as String;
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Запись журнала'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(value['day'] as String),
              const SizedBox(height: 12),
              TextFormField(
                initialValue: minutes.toStringAsFixed(3),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Длительность, мин',
                ),
                onChanged: (v) =>
                    minutes = double.tryParse(v.replaceAll(',', '.')) ?? -1,
              ),
              const SizedBox(height: 12),
              TextFormField(
                initialValue: '$progress',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: 'Прогресс (${value['unit']})',
                ),
                onChanged: (v) =>
                    progress = num.tryParse(v.replaceAll(',', '.')) ?? -1,
              ),
              const SizedBox(height: 12),
              TextFormField(
                initialValue: note,
                maxLines: 3,
                maxLength: 10000,
                decoration: const InputDecoration(labelText: 'Заметка'),
                onChanged: (v) => note = v,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              if (minutes.isFinite &&
                  minutes > 0 &&
                  minutes <= 1440 &&
                  progress.isFinite &&
                  progress >= 0 &&
                  progress <= 1e9) {
                Navigator.pop(context, true);
              }
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (saved == true) {
      await _run(
        () => widget.library.history!.edit(value['id'] as String, {
          ...value,
          'durationMs': (minutes * 60000).round(),
          'progress': progress,
          'mediaMs': value['unit'] == 'minutes'
              ? (progress * 60000).round()
              : value['mediaMs'],
          'note': note,
        }),
      );
    }
  }

  Future<void> _delete(Map<String, dynamic> value) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить запись журнала?'),
        content: const Text(
          'Удаление будет передано в Obsidian при синхронизации.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _run(
        () => widget.library.history!.edit(value['id'] as String, {
          ...value,
          'deleted': true,
        }),
      );
    }
  }

  Widget _row(Map<String, dynamic> slot, Map<String, String> titles) {
    final v = slot['value'] as Map, conflict = slot['conflict'] as Map?;
    final unit =
        const {
          'characters': 'симв.',
          'pages': 'стр.',
          'minutes': 'мин. аудио',
          'unknown': '',
        }[v['unit']] ??
        '';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  v['mediaType'] == 'book' ? Icons.menu_book : Icons.headphones,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    titles[v['itemId']] ?? 'Книга',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                if (conflict == null)
                  PopupMenuButton<String>(
                    onSelected: (value) => value == 'edit'
                        ? _edit(slot)
                        : _delete(Map<String, dynamic>.from(v)),
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: 'edit',
                        child: Text('Редактировать'),
                      ),
                      PopupMenuItem(value: 'delete', child: Text('Удалить')),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${activityTime(v['durationMs'] as num)}${v['progress'] == 0 ? '' : ' · ${v['progress']} $unit'}',
            ),
            if ((v['note'] as String).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(v['note'] as String),
              ),
            const SizedBox(height: 6),
            Text(
              '${v['origin'] == 'obsidian' ? 'Obsidian' : 'PepeHub'} · ${conflict != null
                  ? 'Конфликт'
                  : slot['operation'] != null || !sameMetadataValue(v, slot['synced'])
                  ? 'Ожидает обмена'
                  : 'Синхронизировано'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (conflict != null) ...[
              const SizedBox(height: 8),
              Text(
                'На сервере: ${activityTime(conflict['entry']['durationMs'] as num)}${conflict['entry']['deleted'] == true ? ' · удалено' : ''}',
              ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () => _run(
                      () => widget.library.history!.resolve(
                        v['id'] as String,
                        useRemote: true,
                      ),
                    ),
                    child: const Text('Взять с сервера'),
                  ),
                  TextButton(
                    onPressed: () => _run(
                      () => widget.library.history!.resolve(
                        v['id'] as String,
                        useRemote: false,
                      ),
                    ),
                    child: const Text('Оставить локальную'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final titles = {
      for (final e in widget.library.entries) e.item.id: e.item.title,
    };
    final cutoff = dayKey(
      DateTime.now().subtract(Duration(days: days == 0 ? 0 : days - 1)),
    );
    final visible = slots.where((s) {
      final v = s['value'];
      return (type == 'all' || v['mediaType'] == type) &&
          (days == 0 || (v['day'] as String).compareTo(cutoff) >= 0) &&
          '${titles[v['itemId']] ?? ''} ${v['note']}'.toLowerCase().contains(
            search.toLowerCase(),
          );
    }).toList();
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final slot in visible) {
      groups.putIfAbsent(slot['value']['day'] as String, () => []).add(slot);
    }
    final total = visible
        .where((s) => s['value']['deleted'] != true)
        .fold<int>(0, (sum, s) => sum + (s['value']['durationMs'] as int));
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.itemId == null
              ? 'Журнал чтения и прослушивания'
              : titles[widget.itemId] ?? 'Журнал книги',
        ),
        actions: [
          IconButton(
            tooltip: 'Синхронизировать',
            onPressed: widget.library.syncing ? null : widget.library.sync,
            icon: const Icon(Icons.sync),
          ),
        ],
      ),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (widget.library.config == null)
                  const Text(
                    'Подключите Obsidian в настройках. Журнал переносится для книг, связанных с карточками библиотеки.',
                  ),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (widget.library.error != null)
                  Text(
                    widget.library.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                Text(
                  '${groups.length} дней · ${visible.length} записей · ${activityTime(total)}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 16),
                TextField(
                  decoration: const InputDecoration(
                    labelText: 'Поиск по книге и заметке',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (v) => setState(() => search = v),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final entry in const {
                      'all': 'Все',
                      'book': 'Книги',
                      'audiobook': 'Аудиокниги',
                    }.entries)
                      ChoiceChip(
                        label: Text(entry.value),
                        selected: type == entry.key,
                        onSelected: (_) => setState(() => type = entry.key),
                      ),
                    for (final count in [0, 7, 30])
                      ChoiceChip(
                        label: Text(count == 0 ? 'Всё время' : '$count дней'),
                        selected: days == count,
                        onSelected: (_) => setState(() => days = count),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                if (visible.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'За этот период записей нет. Для переноса локального журнала свяжите книгу с карточкой Obsidian.',
                    ),
                  ),
                for (final group in groups.entries) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      '${group.key} · ${activityTime(group.value.where((s) => s['value']['deleted'] != true).fold<int>(0, (sum, s) => sum + (s['value']['durationMs'] as int)))}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  for (final slot in group.value) _row(slot, titles),
                ],
              ],
            ),
    );
  }
}
