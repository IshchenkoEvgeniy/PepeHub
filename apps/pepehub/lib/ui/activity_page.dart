import 'package:flutter/material.dart';

import '../library/library_service.dart';
import '../library/models.dart';
import '../audio/audio_journal.dart' show dayKey;
import 'pepe_widgets.dart';
import 'shelf_components.dart';

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
        content: const Text('Запись будет удалена из журнала библиотеки.'),
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

  String _status(Map<String, dynamic> slot) {
    if (slot['conflict'] == null) return 'В библиотеке';
    final v = slot['value'] as Map;
    return slot['conflict'] != null
        ? 'Конфликт'
        : slot['operation'] != null || !sameMetadataValue(v, slot['synced'])
        ? 'Ожидает обмена'
        : 'Синхронизировано';
  }

  Widget _chip(ShelfPalette palette, String text, {bool strong = false}) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: strong ? palette.accent : Colors.transparent,
          border: Border.all(
            color: strong ? palette.accent : palette.strongLine,
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            fontWeight: strong ? FontWeight.w700 : FontWeight.w500,
            color: strong ? palette.onAccent : palette.muted,
          ),
        ),
      );

  Widget _row(
    ShelfPalette palette,
    Map<String, dynamic> slot,
    Map<String, String> titles,
    bool wide,
  ) {
    final v = slot['value'] as Map, conflict = slot['conflict'] as Map?;
    final unit =
        const {
          'characters': 'симв.',
          'pages': 'стр.',
          'minutes': 'мин. аудио',
          'unknown': '',
        }[v['unit']] ??
        '';
    final status = _status(slot);
    final deleted = v['deleted'] == true;
    final title = titles[v['itemId']] ?? 'Книга';
    final menu = conflict == null
        ? PopupMenuButton<String>(
            tooltip: 'Действия с записью',
            onSelected: (value) => value == 'edit'
                ? _edit(slot)
                : _delete(Map<String, dynamic>.from(v)),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('Редактировать')),
              PopupMenuItem(value: 'delete', child: Text('Удалить')),
            ],
          )
        : const SizedBox(width: 48);
    final duration = Text(
      activityTime(v['durationMs'] as num),
      style: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        decoration: deleted ? TextDecoration.lineThrough : null,
      ),
    );
    final progress = v['progress'] == 0 ? '—' : '${v['progress']} $unit';
    final origin = v['origin'] == 'obsidian' ? 'Obsidian' : 'PepeHub';
    final head = Row(
      children: [
        Icon(
          v['mediaType'] == 'book'
              ? Icons.menu_book_outlined
              : Icons.headphones_outlined,
          size: 20,
          color: palette.muted,
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 5,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.book(palette.text, size: 16),
              ),
              if ((v['note'] as String).isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    v['note'] as String,
                    maxLines: wide ? 1 : 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: palette.muted),
                  ),
                ),
              if (!wide)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      duration,
                      if (v['progress'] != 0)
                        Text(
                          '· $progress',
                          style: TextStyle(fontSize: 12, color: palette.muted),
                        ),
                      _chip(palette, origin),
                      _chip(palette, status, strong: conflict != null),
                    ],
                  ),
                ),
            ],
          ),
        ),
        if (wide) ...[
          SizedBox(width: 100, child: duration),
          SizedBox(
            width: 130,
            child: Text(
              progress,
              style: TextStyle(fontSize: 13, color: palette.muted),
            ),
          ),
          SizedBox(
            width: 90,
            child: Align(
              alignment: Alignment.centerLeft,
              child: _chip(palette, origin),
            ),
          ),
          SizedBox(
            width: 150,
            child: Align(
              alignment: Alignment.centerLeft,
              child: _chip(palette, status, strong: conflict != null),
            ),
          ),
        ],
        menu,
      ],
    );
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: palette.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          head,
          if (conflict != null)
            Container(
              margin: const EdgeInsets.only(top: 8, left: 32),
              padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
              decoration: BoxDecoration(
                color: palette.raised,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Здесь: ${activityTime(v['durationMs'] as num)} · На сервере: ${activityTime(conflict['entry']['durationMs'] as num)}${conflict['entry']['deleted'] == true ? ' · удалено' : ''}',
                    style: const TextStyle(fontSize: 13),
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
              ),
            ),
        ],
      ),
    );
  }

  Widget _filters(
    ShelfPalette palette,
    int groups,
    int count,
    int total,
    int conflicts,
    bool wide,
  ) {
    final search = TextField(
      decoration: const InputDecoration(
        labelText: 'Поиск по книге и заметке',
        prefixIcon: Icon(Icons.search),
      ),
      onChanged: (v) => setState(() => this.search = v),
    );
    final kinds = PepeChoices<String>(
      options: const [
        ('all', 'Все'),
        ('book', 'Книги'),
        ('audiobook', 'Аудиокниги'),
      ],
      selected: type,
      onSelect: (v) => setState(() => type = v),
    );
    final periods = PepeChoices<int>(
      options: const [(0, 'Всё время'), (7, '7 дней'), (30, '30 дней')],
      selected: days,
      onSelect: (v) => setState(() => days = v),
    );
    final totals = Wrap(
      spacing: 24,
      runSpacing: 12,
      children: [
        PepeFigure(activityTime(total), 'Всего', size: 26),
        PepeFigure('$groups', 'Дней', size: 26),
        PepeFigure('$count', 'Записей', size: 26),
        if (conflicts > 0)
          PepeFigure(
            '$conflicts',
            'Конфликтов',
            size: 26,
            color: palette.accent,
          ),
      ],
    );
    if (!wide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          totals,
          const SizedBox(height: 16),
          search,
          const SizedBox(height: 12),
          kinds,
          const SizedBox(height: 8),
          periods,
        ],
      );
    }
    return PepePanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          search,
          const SizedBox(height: 20),
          const PepeCaption('Тип'),
          const SizedBox(height: 8),
          kinds,
          const SizedBox(height: 20),
          const PepeCaption('Период'),
          const SizedBox(height: 8),
          periods,
          const SizedBox(height: 22),
          totals,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final wide = pepeWide(context);
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
    final conflicts = slots.where((s) => s['conflict'] != null).length;
    final waiting = slots.where((s) => _status(s) == 'Ожидает обмена').length;

    final notices = <Widget>[
      if (error != null || widget.library.error != null)
        PepePanel(
          outlined: true,
          child: Text(
            [?error, ?widget.library.error].join('\n'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      if (conflicts > 0)
        Material(
          color: palette.accent,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
            child: Row(
              children: [
                Icon(Icons.call_split, color: palette.onAccent),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Конфликтов: $conflicts. Запись изменили и здесь, и в Obsidian — выберите, какую версию оставить.',
                    style: TextStyle(
                      color: palette.onAccent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
    ];

    final table = <Widget>[
      if (wide)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: DefaultTextStyle(
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: .6,
              color: palette.muted,
            ),
            child: const Row(
              children: [
                SizedBox(width: 32),
                Expanded(flex: 5, child: Text('КНИГА')),
                SizedBox(width: 100, child: Text('ВРЕМЯ')),
                SizedBox(width: 130, child: Text('ПРОГРЕСС')),
                SizedBox(width: 90, child: Text('ИСТОЧНИК')),
                SizedBox(width: 150, child: Text('СТАТУС')),
                SizedBox(width: 48),
              ],
            ),
          ),
        ),
      if (visible.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Text(
            'За этот период записей нет. История появляется у книг, добавленных в библиотеку.',
            style: TextStyle(color: palette.muted),
          ),
        ),
      for (final group in groups.entries) ...[
        Padding(
          padding: const EdgeInsets.only(top: 18, bottom: 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _dayTitle(group.key),
                  style: AppFonts.title(palette.text, size: 18),
                ),
              ),
              Text(
                activityTime(
                  group.value
                      .where((s) => s['value']['deleted'] != true)
                      .fold<int>(
                        0,
                        (sum, s) => sum + (s['value']['durationMs'] as int),
                      ),
                ),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: palette.muted,
                ),
              ),
            ],
          ),
        ),
        for (final slot in group.value) _row(palette, slot, titles, wide),
      ],
    ];

    final filters = _filters(
      palette,
      groups.length,
      visible.length,
      total,
      conflicts,
      wide,
    );

    return PepeSubpage(
      title: widget.itemId == null
          ? 'Журнал'
          : titles[widget.itemId] ?? 'Журнал книги',
      back: widget.itemId == null ? 'Статистика' : 'Журнал',
      section: PepeSection.statistics,
      subtitle: widget.itemId == null
          ? 'Чтение и прослушивание · ${waiting == 0 ? 'всё синхронизировано' : 'ожидают обмена: $waiting'}'
          : null,
      actions: [
        IconButton(
          tooltip: 'Синхронизировать',
          onPressed: widget.library.syncing ? null : widget.library.sync,
          icon: widget.library.syncing
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.sync),
        ),
      ],
      children: loading
          ? const [
              Padding(
                padding: EdgeInsets.all(40),
                child: Center(child: CircularProgressIndicator()),
              ),
            ]
          : wide
          ? [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 300, child: filters),
                  const SizedBox(width: 24),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final n in notices) ...[
                          n,
                          const SizedBox(height: 12),
                        ],
                        ...table,
                      ],
                    ),
                  ),
                ],
              ),
            ]
          : [
              for (final n in notices) ...[n, const SizedBox(height: 12)],
              filters,
              const SizedBox(height: 8),
              ...table,
            ],
    );
  }

  String _dayTitle(String key) {
    final date = DateTime.tryParse(key);
    if (date == null) return key;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final difference = today.difference(date).inDays;
    final label = difference == 0
        ? 'Сегодня'
        : difference == 1
        ? 'Вчера'
        : pepeWeekdays[date.weekday - 1];
    return '${pepeDate(date)} · $label';
  }
}
