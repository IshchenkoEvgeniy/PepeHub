import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'audio_mini_player.dart';
import 'navigation_layout.dart';

export 'navigation_layout.dart'
    show NavigationLayoutPage, PepeNavItem, PepeNavLayout, openNavigationLayout;

/// Older name for the palette tokens, kept so existing screens read the
/// active palette without change.
class ShelfPalette {
  final bool dark;
  final ThemeData? theme;
  const ShelfPalette(this.dark, [this.theme]);
  factory ShelfPalette.of(BuildContext context) => ShelfPalette(
    Theme.of(context).brightness == Brightness.dark,
    Theme.of(context),
  );
  PepeColors get colors =>
      theme?.extension<PepeColors>() ?? PepeColors.from(AppStyle.fallback);
  Color get background => colors.background;
  Color get panel => colors.surface;
  Color get raised => colors.raised;
  Color get sidebar => colors.navigation;
  Color get line => colors.line;
  Color get strongLine => colors.strongLine;
  Color get muted => colors.muted;
  Color get text => colors.text;
  Color get accent => colors.accent;
  Color get accentSoft => colors.accentSoft;
  Color get onAccent => colors.onAccent;
  Color get selected => Color.lerp(colors.background, colors.accent, .18)!;
}

class ShelfPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const ShelfPanel({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
  });
  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    return Material(
      color: palette.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
    );
  }
}

/// Top-level sections of the app, in navigation order.
enum PepeSection {
  books('Книги', Icons.menu_book_outlined, Icons.menu_book),
  audio('Аудиокниги', Icons.headphones_outlined, Icons.headphones),
  video('Медиа', Icons.perm_media_outlined, Icons.perm_media),
  library('Библиотека', Icons.local_library_outlined, Icons.local_library),
  recommendations('Рекомендации', Icons.star_outline, Icons.star_rounded),
  statistics('Статистика', Icons.bar_chart_outlined, Icons.bar_chart_rounded),
  pets('Питомник', Icons.pets_outlined, Icons.pets);

  final String label;
  final IconData icon, selectedIcon;
  const PepeSection(this.label, this.icon, this.selectedIcon);
}

class ShelfNavigation {
  /// Highlighted section; null on screens that belong to none.
  final PepeSection? current;
  final ValueChanged<PepeSection> onSelect;
  final VoidCallback onSettings;

  /// Opens a page entry of the bar («Заметки», «Словарь»).
  final ValueChanged<PepeNavItem>? onOpen;
  final bool enabled;

  /// Highlights the settings entry of the rail.
  final bool settingsSelected;

  /// On screens opened above a section the highlighted entry stays tappable
  /// and leads back to the section.
  final bool subpage;
  const ShelfNavigation({
    required this.current,
    required this.onSelect,
    required this.onSettings,
    this.onOpen,
    this.enabled = true,
    this.settingsSelected = false,
    this.subpage = false,
  });

  bool isSelected(PepeNavItem item) => item == PepeNavItem.settings
      ? settingsSelected
      : item.section != null && item.section == current;

  void open(PepeNavItem item) {
    final section = item.section;
    if (section != null) {
      onSelect(section);
    } else if (item == PepeNavItem.settings) {
      onSettings();
    } else {
      onOpen?.call(item);
    }
  }
}

/// Page frame: large section title, the bottom bar on phones and a rail on
/// wide windows. [bottomNavigationBar] (for example the mini player) sits
/// directly above the bar.
class ShelfShell extends StatelessWidget {
  final String title;
  final ShelfNavigation navigation;
  final Widget body;
  final Widget? bottomNavigationBar;
  final List<Widget> actions;

  /// False hides the large section title: the body fills the page
  /// (the pets room is a full-screen scene with its own header).
  final bool header;

  /// False hides the phone bottom bar: a full-screen section (the pets room)
  /// offers [showNavigationSheet] instead. The rail of wide windows stays.
  final bool bottomBar;
  const ShelfShell({
    super.key,
    required this.title,
    required this.navigation,
    required this.body,
    this.bottomNavigationBar,
    this.actions = const [],
    this.header = true,
    this.bottomBar = true,
  });

  static const wideBreakpoint = 900.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= wideBreakpoint;
      final palette = ShelfPalette.of(context);
      final extra = AudioPlayerFooter(child: bottomNavigationBar);
      return Scaffold(
        backgroundColor: palette.background,
        bottomNavigationBar: wide || !bottomBar
            ? extra
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  MediaQuery.removePadding(
                    context: context,
                    removeBottom: true,
                    child: extra,
                  ),
                  ShelfBottomBar(navigation: navigation),
                ],
              ),
        body: SafeArea(
          bottom: false,
          child: Row(
            children: [
              if (wide) ShelfRail(navigation: navigation),
              Expanded(
                child: Column(
                  children: [
                    if (header)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 14, 8, 6),
                        child: Row(
                          children: [
                            Expanded(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  title.toUpperCase(),
                                  maxLines: 1,
                                  style: AppFonts.title(
                                    palette.text,
                                    size: constraints.maxWidth < 400 ? 30 : 36,
                                  ),
                                ),
                              ),
                            ),
                            ...actions,
                            // No second settings button when the bar has one.
                            if (!wide)
                              ValueListenableBuilder(
                                valueListenable: PepeNavLayout.current,
                                builder: (context, layout, _) =>
                                    layout
                                        .split(constraints.maxWidth)
                                        .bar
                                        .contains(PepeNavItem.settings)
                                    ? const SizedBox.shrink()
                                    : IconButton(
                                        tooltip: 'Настройки',
                                        onPressed: navigation.onSettings,
                                        icon: const Icon(Icons.tune_rounded),
                                      ),
                              ),
                          ],
                        ),
                      ),
                    Expanded(child: body),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// The phone bar: the entries chosen in «Нижняя панель», as many as fit,
/// then «Ещё» with the rest. [layout] overrides the saved one (preview).
class ShelfBottomBar extends StatelessWidget {
  final ShelfNavigation navigation;
  final PepeNavLayout? layout;
  const ShelfBottomBar({super.key, required this.navigation, this.layout});
  @override
  Widget build(BuildContext context) => layout != null
      ? _bar(context, layout!)
      : ValueListenableBuilder(
          valueListenable: PepeNavLayout.current,
          builder: (context, value, _) => _bar(context, value),
        );

  Widget _bar(BuildContext context, PepeNavLayout layout) {
    final palette = ShelfPalette.of(context);
    return Material(
      color: palette.sidebar,
      child: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: palette.line)),
        ),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 64,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final split = layout.split(constraints.maxWidth);
                return Row(
                  children: [
                    for (final item in split.bar)
                      Expanded(
                        child: _NavigationItem(
                          item: item,
                          navigation: navigation,
                        ),
                      ),
                    if (split.more.isNotEmpty)
                      Expanded(
                        child: _MoreItem(
                          items: split.more,
                          navigation: navigation,
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class ShelfRail extends StatelessWidget {
  final ShelfNavigation navigation;
  const ShelfRail({super.key, required this.navigation});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: PepeNavLayout.current,
    builder: (context, layout, _) => _rail(context, layout),
  );

  Widget _rail(BuildContext context, PepeNavLayout layout) {
    final palette = ShelfPalette.of(context);
    final rail = layout.rail;
    return Material(
      color: palette.sidebar,
      child: Container(
        width: 104,
        decoration: BoxDecoration(
          border: Border(right: BorderSide(color: palette.line)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 22),
            Text(
              'PepeHub',
              style: TextStyle(
                fontFamily: AppFonts.display,
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: palette.text,
              ),
            ),
            const SizedBox(height: 22),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final item in rail.bar)
                      SizedBox(
                        height: 76,
                        child: _NavigationItem(
                          item: item,
                          navigation: navigation,
                        ),
                      ),
                    if (rail.more.isNotEmpty)
                      SizedBox(
                        height: 76,
                        child: _MoreItem(
                          items: rail.more,
                          navigation: navigation,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            SizedBox(
              height: 64,
              width: double.infinity,
              child: _NavigationItem(
                item: PepeNavItem.settings,
                navigation: navigation,
                marker: false,
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

/// Icon over a label with the accent marker on top, shared by the bar, the
/// rail and «Ещё».
class _NavigationTile extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected, marker;
  final VoidCallback? onTap, onLongPress;
  const _NavigationTile({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.onLongPress,
    this.marker = true,
  });
  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final color = selected ? palette.accent : palette.muted;
    return Tooltip(
      message: label,
      child: Semantics(
        selected: selected,
        button: true,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Column(
            children: [
              Container(
                height: 3,
                margin: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: selected && marker
                      ? palette.accent
                      : Colors.transparent,
                  borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(3),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon, size: 22, color: color),
                      const SizedBox(height: 4),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          label,
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: color,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavigationItem extends StatelessWidget {
  final PepeNavItem item;
  final ShelfNavigation navigation;
  final bool marker;
  const _NavigationItem({
    required this.item,
    required this.navigation,
    this.marker = true,
  });
  @override
  Widget build(BuildContext context) {
    final selected = navigation.isSelected(item);
    return _NavigationTile(
      key: ValueKey('nav:${item.name}'),
      label: item.label,
      icon: selected ? item.selectedIcon : item.icon,
      selected: selected,
      marker: marker,
      onTap: navigation.enabled && (!selected || navigation.subpage)
          ? () => navigation.open(item)
          : null,
      onLongPress: navigation.enabled
          ? () => openNavigationLayout(context)
          : null,
    );
  }
}

/// «Ещё»: the entries left out of the bar, and a way to arrange it.
class _MoreItem extends StatelessWidget {
  final List<PepeNavItem> items;
  final ShelfNavigation navigation;
  const _MoreItem({required this.items, required this.navigation});
  @override
  Widget build(BuildContext context) {
    final selected = items.any(navigation.isSelected);
    return _NavigationTile(
      key: const ValueKey('nav:more'),
      label: 'Ещё',
      icon: selected ? Icons.more_horiz_rounded : Icons.more_horiz,
      selected: selected,
      onTap: navigation.enabled
          ? () => showNavigationSheet(context, navigation, items: items)
          : null,
      onLongPress: navigation.enabled
          ? () => openNavigationLayout(context)
          : null,
    );
  }
}

/// Navigation entries in a sheet: «Ещё» shows the ones left out of the bar;
/// full-screen sections that hide the bar show every entry ([items] null).
Future<void> showNavigationSheet(
  BuildContext context,
  ShelfNavigation navigation, {
  List<PepeNavItem>? items,
}) async {
  final palette = ShelfPalette.of(context);
  final entries = items ?? PepeNavLayout.current.value.order;
  final chosen = await showModalBottomSheet<Object>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final item in entries)
              ListTile(
                key: ValueKey('nav-more:${item.name}'),
                leading: Icon(
                  navigation.isSelected(item) ? item.selectedIcon : item.icon,
                  color: navigation.isSelected(item)
                      ? palette.accent
                      : palette.muted,
                ),
                title: Text(item.label),
                selected: navigation.isSelected(item),
                onTap: () => Navigator.pop(sheet, item),
              ),
            const Divider(height: 1),
            ListTile(
              key: const ValueKey('nav-more:customize'),
              leading: const Icon(Icons.dashboard_customize_outlined),
              title: const Text('Настроить панель'),
              onTap: () => Navigator.pop(sheet, 'customize'),
            ),
          ],
        ),
      ),
    ),
  );
  if (!context.mounted) return;
  if (chosen is PepeNavItem) {
    if (!navigation.isSelected(chosen) || navigation.subpage) {
      navigation.open(chosen);
    }
  } else if (chosen == 'customize') {
    await openNavigationLayout(context);
  }
}

/// A short line under the page title, with an optional action beside it.
/// The page title itself is drawn by [ShelfShell].
class ShelfIntro extends StatelessWidget {
  final String title, subtitle;
  final Widget? action;
  const ShelfIntro({
    super.key,
    required this.title,
    required this.subtitle,
    this.action,
  });
  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final text = Text(
      subtitle,
      style: TextStyle(color: palette.muted, fontSize: 14, height: 1.4),
    );
    if (action == null) return text;
    return LayoutBuilder(
      builder: (context, constraints) => constraints.maxWidth < 520
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [text, const SizedBox(height: 14), action!],
            )
          : Row(
              children: [
                Expanded(child: text),
                const SizedBox(width: 16),
                action!,
              ],
            ),
    );
  }
}

/// Status filter as a row of pills with counts.
class ShelfSummary extends StatelessWidget {
  final int total, books, audio, active, finished, planned;
  final String? selected;
  final ValueChanged<String>? onStatus;
  const ShelfSummary({
    super.key,
    required this.total,
    required this.books,
    required this.audio,
    required this.active,
    required this.finished,
    required this.planned,
    this.selected,
    this.onStatus,
  });
  @override
  Widget build(BuildContext context) {
    final entries = [
      ('all', 'Все', total),
      ('active', 'В процессе', active),
      ('planned', 'В планах', planned),
      ('finished', 'Завершено', finished),
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (key, label, count) in entries)
          ShelfPill(
            label: label,
            count: count,
            selected: (selected ?? 'all') == key,
            onTap: onStatus == null ? null : () => onStatus!(key),
          ),
      ],
    );
  }
}

/// A rounded filter button; the selected one is drawn in the text colour.
class ShelfPill extends StatelessWidget {
  final String label;
  final int? count;
  final bool selected;
  final VoidCallback? onTap;
  const ShelfPill({
    super.key,
    required this.label,
    this.count,
    this.selected = false,
    this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final ink = selected ? palette.background : palette.text;
    return Semantics(
      button: onTap != null,
      selected: selected,
      child: Material(
        color: selected ? palette.text : Colors.transparent,
        shape: StadiumBorder(
          side: BorderSide(color: selected ? palette.text : palette.strongLine),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
            child: count == null
                ? Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: ink,
                    ),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: ink,
                        ),
                      ),
                      if (count != null) ...[
                        const SizedBox(width: 6),
                        Text(
                          '$count',
                          style: TextStyle(
                            fontSize: 13,
                            color: selected ? ink : palette.muted,
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

class ShelfStatus extends StatelessWidget {
  final String status;

  /// Label for `active`, e.g. «Слушаю» on the audiobook shelf so the badge
  /// matches its tab; «В процессе» where the media type is mixed.
  final String? activeLabel;
  const ShelfStatus(this.status, {super.key, this.activeLabel});
  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final color = switch (status) {
      'active' => palette.accent,
      'finished' || 'deleted' => palette.muted,
      _ => palette.accentSoft,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: palette.strongLine),
      ),
      child: Text(
        switch (status) {
          'active' => activeLabel ?? 'В процессе',
          'finished' => 'Завершено',
          'deleted' => 'Файл удалён',
          'paused' => 'Отложена',
          'abandoned' => 'Брошена',
          _ => 'В планах',
        },
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: .3,
          color: color,
        ),
      ),
    );
  }
}
