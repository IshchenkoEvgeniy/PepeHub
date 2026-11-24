import 'dart:convert';

import 'package:flutter/material.dart';

import '../data/repository.dart';
import 'app_preferences.dart';
import 'shelf_components.dart';

/// Everything the bottom bar and the rail can show: the sections and a few
/// pages that are otherwise reached through a section.
enum PepeNavItem {
  books('Книги', Icons.menu_book_outlined, Icons.menu_book),
  audio('Аудиокниги', Icons.headphones_outlined, Icons.headphones),
  video('Медиа', Icons.perm_media_outlined, Icons.perm_media),
  library('Библиотека', Icons.local_library_outlined, Icons.local_library),
  recommendations('Рекомендации', Icons.star_outline, Icons.star_rounded),
  statistics('Статистика', Icons.bar_chart_outlined, Icons.bar_chart_rounded),
  pets('Питомник', Icons.pets_outlined, Icons.pets),
  notes('Заметки', Icons.edit_note_outlined, Icons.edit_note),
  vocabulary('Словарь', Icons.style_outlined, Icons.style),
  settings('Настройки', Icons.tune_outlined, Icons.tune_rounded);

  final String label;
  final IconData icon, selectedIcon;
  const PepeNavItem(this.label, this.icon, this.selectedIcon);

  /// The section this entry switches to; null for pages opened on top.
  PepeSection? get section => switch (this) {
    books => PepeSection.books,
    audio => PepeSection.audio,
    video => PepeSection.video,
    library => PepeSection.library,
    recommendations => PepeSection.recommendations,
    statistics => PepeSection.statistics,
    pets => PepeSection.pets,
    notes || vocabulary || settings => null,
  };

  static PepeNavItem of(PepeSection section) => values.byName(section.name);

  String get hint => switch (this) {
    notes => 'Цитаты и заметки из всех книг',
    vocabulary => 'Карточки Anki из книг и видео',
    settings => 'На телефоне также есть кнопка в шапке',
    pets => 'Питомцы за чтение и прослушивание',
    _ => 'Раздел приложения',
  };
}

/// Order of every entry and which of them stand in the bar. The others are
/// behind «Ещё», as are the ones a narrow screen cannot fit.
@immutable
class PepeNavLayout {
  final List<PepeNavItem> order;
  final Set<PepeNavItem> inBar;
  const PepeNavLayout._(this.order, this.inBar);

  factory PepeNavLayout(List<PepeNavItem> order, Set<PepeNavItem> inBar) {
    final seen = <PepeNavItem>{};
    final full = [
      for (final item in order)
        if (seen.add(item)) item,
      for (final item in PepeNavItem.values)
        if (!seen.contains(item)) item,
    ];
    return PepeNavLayout._(
      List.unmodifiable(full),
      Set.unmodifiable(inBar.isEmpty ? {PepeNavItem.books} : inBar),
    );
  }

  /// All sections in the bar in their usual order; the extra pages behind
  /// «Ещё». «Питомник» hidden in an earlier version starts behind «Ещё».
  factory PepeNavLayout.defaults({bool petsHidden = false}) =>
      PepeNavLayout(PepeNavItem.values, {
        for (final item in PepeNavItem.values)
          if (item.section != null && !(petsHidden && item == PepeNavItem.pets))
            item,
      });

  static const storageKey = 'navigation-layout-v1';

  /// Width one bar entry needs for its icon and label.
  static const slotWidth = 72.0;

  static final current = ValueNotifier<PepeNavLayout>(PepeNavLayout.defaults());

  static Repository? _repository;

  List<PepeNavItem> get bar => [
    for (final item in order)
      if (inBar.contains(item)) item,
  ];

  List<PepeNavItem> get more => [
    for (final item in order)
      if (!inBar.contains(item)) item,
  ];

  /// What a bottom bar of [width] shows and what goes behind «Ещё».
  ({List<PepeNavItem> bar, List<PepeNavItem> more}) split(double width) {
    final slots = (width / slotWidth).floor().clamp(3, 8);
    var shown = bar, rest = more;
    final needed = shown.length + (rest.isEmpty ? 0 : 1);
    if (needed > slots) {
      final keep = slots - 1;
      rest = [...shown.skip(keep), ...rest];
      shown = shown.take(keep).toList();
    }
    return (bar: shown, more: rest);
  }

  /// The rail is tall enough for every entry in the bar; settings keep
  /// their own place at its bottom.
  ({List<PepeNavItem> bar, List<PepeNavItem> more}) get rail => (
    bar: [
      for (final item in bar)
        if (item != PepeNavItem.settings) item,
    ],
    more: [
      for (final item in more)
        if (item != PepeNavItem.settings) item,
    ],
  );

  PepeNavLayout copyWith({List<PepeNavItem>? order, Set<PepeNavItem>? inBar}) =>
      PepeNavLayout(order ?? this.order, inBar ?? this.inBar);

  Map<String, Object> toJson() => {
    'order': [for (final item in order) item.name],
    'bar': [for (final item in bar) item.name],
  };

  /// Unknown names (from a newer version) are skipped; entries this file
  /// does not mention are appended behind «Ещё».
  static PepeNavLayout? fromJson(Object? json) {
    if (json is! Map) return null;
    PepeNavItem? named(Object? name) =>
        PepeNavItem.values.where((item) => item.name == name).firstOrNull;
    final order = [
      for (final name in json['order'] as List? ?? const []) ?named(name),
    ];
    final bar = {
      for (final name in json['bar'] as List? ?? const []) ?named(name),
    };
    if (order.isEmpty) return null;
    return PepeNavLayout(order, bar);
  }

  static Future<void> load(Repository repository) async {
    _repository = repository;
    PepeNavLayout? stored;
    try {
      final raw = await repository.meta(storageKey);
      stored = raw == null ? null : fromJson(jsonDecode(raw));
    } catch (_) {
      stored = null;
    }
    current.value =
        stored ??
        PepeNavLayout.defaults(petsHidden: await petsSectionHidden(repository));
  }

  static Future<void> save(PepeNavLayout layout) async {
    final previous = current.value;
    current.value = layout;
    final repository = _repository;
    if (repository == null) return;
    try {
      await repository.setMeta(storageKey, jsonEncode(layout.toJson()));
    } catch (_) {
      current.value = previous;
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is PepeNavLayout &&
      _listEquals(order, other.order) &&
      inBar.length == other.inBar.length &&
      inBar.containsAll(other.inBar);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(order), Object.hashAllUnordered(inBar));

  static bool _listEquals(List<Object> a, List<Object> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Settings → «Нижняя панель»: drag to reorder, the switch puts an entry in
/// the bar or behind «Ещё». The preview shows a phone-wide bar.
class NavigationLayoutPage extends StatefulWidget {
  const NavigationLayoutPage({super.key});
  @override
  State<NavigationLayoutPage> createState() => _NavigationLayoutPageState();
}

class _NavigationLayoutPageState extends State<NavigationLayoutPage> {
  late PepeNavLayout draft = PepeNavLayout.current.value;
  String? error;

  Future<void> _change(PepeNavLayout next) async {
    setState(() {
      draft = next;
      error = null;
    });
    try {
      await PepeNavLayout.save(next);
    } catch (e) {
      if (mounted) {
        setState(() {
          draft = PepeNavLayout.current.value;
          error = 'Не удалось сохранить панель: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final phone = draft.split(360);
    final order = draft.order;
    return Scaffold(
      backgroundColor: palette.background,
      appBar: AppBar(
        title: const Text('Нижняя панель'),
        actions: [
          TextButton(
            onPressed: draft == PepeNavLayout.defaults()
                ? null
                : () => _change(PepeNavLayout.defaults()),
            child: const Text('Сбросить'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(
              'Перетащите, чтобы поменять порядок. Выключенные пункты '
              'открываются кнопкой «Ещё». На телефоне шириной 360 точек '
              'помещается ${phone.bar.length + (phone.more.isEmpty ? 0 : 1)} '
              'кнопок — лишние тоже уйдут в «Ещё».',
              style: TextStyle(color: palette.muted, fontSize: 13),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 360,
                  child: MediaQuery.removePadding(
                    context: context,
                    removeBottom: true,
                    child: ShelfBottomBar(
                      key: const ValueKey('navigation-preview'),
                      layout: draft,
                      navigation: ShelfNavigation(
                        current: PepeSection.books,
                        onSelect: (_) {},
                        onSettings: () {},
                        enabled: false,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          Expanded(
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              padding: const EdgeInsets.only(bottom: 24),
              itemCount: order.length,
              onReorderItem: (from, to) {
                final next = [...order];
                final item = next.removeAt(from);
                next.insert(to, item);
                _change(draft.copyWith(order: next));
              },
              itemBuilder: (context, i) {
                final item = order[i];
                final on = draft.inBar.contains(item);
                final last = on && draft.inBar.length == 1;
                return Material(
                  key: ValueKey('nav-layout:${item.name}'),
                  color: palette.background,
                  child: ListTile(
                    leading: ReorderableDragStartListener(
                      index: i,
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(Icons.drag_indicator),
                      ),
                    ),
                    title: Row(
                      children: [
                        Icon(item.icon, size: 20, color: palette.muted),
                        const SizedBox(width: 10),
                        Flexible(child: Text(item.label)),
                      ],
                    ),
                    subtitle: Text(
                      on ? 'В панели' : 'В «Ещё» · ${item.hint}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Switch(
                      key: ValueKey('nav-layout-switch:${item.name}'),
                      value: on,
                      onChanged: last
                          ? null
                          : (value) => _change(
                              draft.copyWith(
                                inBar: value
                                    ? {...draft.inBar, item}
                                    : ({...draft.inBar}..remove(item)),
                              ),
                            ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> openNavigationLayout(BuildContext context) => Navigator.push(
  context,
  MaterialPageRoute<void>(builder: (_) => const NavigationLayoutPage()),
);
