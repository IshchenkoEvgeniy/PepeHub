import 'package:flutter/material.dart';

import 'app_theme.dart';

/// Older name for the palette tokens, kept so existing screens read the
/// active palette without change.
class ShelfPalette {
  final bool dark;
  final ThemeData? theme;
  const ShelfPalette(this.dark, [this.theme]);
  factory ShelfPalette.of(BuildContext context) =>
      ShelfPalette(true, Theme.of(context));
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

/// The five top-level sections of the app, in navigation order.
enum PepeSection {
  books('Книги', Icons.menu_book_outlined, Icons.menu_book),
  audio('Аудиокниги', Icons.headphones_outlined, Icons.headphones),
  library(
    'Библиотека',
    Icons.local_library_outlined,
    Icons.local_library,
  ),
  recommendations('Рекомендации', Icons.star_outline, Icons.star_rounded),
  statistics('Статистика', Icons.bar_chart_outlined, Icons.bar_chart_rounded);

  final String label;
  final IconData icon, selectedIcon;
  const PepeSection(this.label, this.icon, this.selectedIcon);
}

class ShelfNavigation {
  /// Highlighted section; null on screens that belong to none.
  final PepeSection? current;
  final ValueChanged<PepeSection> onSelect;
  final VoidCallback onSettings;
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
    this.enabled = true,
    this.settingsSelected = false,
    this.subpage = false,
  });
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
  const ShelfShell({
    super.key,
    required this.title,
    required this.navigation,
    required this.body,
    this.bottomNavigationBar,
    this.actions = const [],
  });

  static const wideBreakpoint = 900.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= wideBreakpoint;
      final palette = ShelfPalette.of(context);
      final extra = bottomNavigationBar;
      return Scaffold(
        backgroundColor: palette.background,
        bottomNavigationBar: wide
            ? extra
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (extra != null)
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
                          if (!wide)
                            IconButton(
                              tooltip: 'Настройки',
                              onPressed: navigation.onSettings,
                              icon: const Icon(Icons.tune_rounded),
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

class ShelfBottomBar extends StatelessWidget {
  final ShelfNavigation navigation;
  const ShelfBottomBar({super.key, required this.navigation});
  @override
  Widget build(BuildContext context) {
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
            child: Row(
              children: [
                for (final section in PepeSection.values)
                  Expanded(
                    child: _NavigationItem(
                      section: section,
                      navigation: navigation,
                      vertical: true,
                    ),
                  ),
              ],
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
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
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
            for (final section in PepeSection.values)
              SizedBox(
                height: 76,
                child: _NavigationItem(
                  section: section,
                  navigation: navigation,
                  vertical: true,
                ),
              ),
            const Spacer(),
            Tooltip(
              message: 'Настройки',
              child: InkWell(
                onTap: navigation.onSettings,
                child: SizedBox(
                  height: 64,
                  width: double.infinity,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.tune_rounded,
                        color: navigation.settingsSelected
                            ? palette.accent
                            : palette.muted,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Настройки',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: navigation.settingsSelected
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: navigation.settingsSelected
                              ? palette.accent
                              : palette.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

class _NavigationItem extends StatelessWidget {
  final PepeSection section;
  final ShelfNavigation navigation;
  final bool vertical;
  const _NavigationItem({
    required this.section,
    required this.navigation,
    required this.vertical,
  });
  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final selected = navigation.current == section;
    final color = selected ? palette.accent : palette.muted;
    return Tooltip(
      message: section.label,
      child: Semantics(
        selected: selected,
        button: true,
        child: InkWell(
          onTap: navigation.enabled && (!selected || navigation.subpage)
              ? () => navigation.onSelect(section)
              : null,
          child: Column(
            children: [
              Container(
                height: 3,
                margin: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: selected ? palette.accent : Colors.transparent,
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
                      Icon(
                        selected ? section.selectedIcon : section.icon,
                        size: 22,
                        color: color,
                      ),
                      const SizedBox(height: 4),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          section.label,
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
          side: BorderSide(
            color: selected ? palette.text : palette.strongLine,
          ),
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
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
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
  const ShelfStatus(this.status, {super.key});
  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final color = switch (status) {
      'active' => palette.accent,
      'finished' => palette.muted,
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
          'active' => 'В процессе',
          'finished' => 'Завершено',
          _ => 'В планах',
        },
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
