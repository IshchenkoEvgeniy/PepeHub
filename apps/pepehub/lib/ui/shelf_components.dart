import 'package:flutter/material.dart';

/// Shared visual language of the Shelf reading dashboard.
class ShelfPalette {
  final bool dark;
  const ShelfPalette(this.dark);
  factory ShelfPalette.of(BuildContext context) =>
      ShelfPalette(Theme.of(context).brightness == Brightness.dark);
  Color get background =>
      dark ? const Color(0xff101116) : const Color(0xfff5f5fa);
  Color get panel => dark ? const Color(0xff191a23) : Colors.white;
  Color get sidebar => dark ? const Color(0xff15161e) : const Color(0xffefeff7);
  Color get line => dark ? const Color(0xff2b2c38) : const Color(0xffe3e3ed);
  Color get muted => dark ? const Color(0xff8c8d9f) : const Color(0xff727386);
  Color get accent => dark ? const Color(0xffa69afb) : const Color(0xff7667d6);
  Color get selected =>
      dark ? const Color(0xff29253f) : const Color(0xffeeebff);
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
      shape: RoundedRectangleBorder(
        side: BorderSide(color: palette.line),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
    );
  }
}

class ShelfShell extends StatelessWidget {
  final String title;
  final Widget drawer, body;
  final Widget? sidebar, bottomNavigationBar;
  final List<Widget> actions;
  const ShelfShell({
    super.key,
    required this.title,
    required this.drawer,
    required this.body,
    this.sidebar,
    this.bottomNavigationBar,
    this.actions = const [],
  });
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final desktop = constraints.maxWidth >= 1050 && sidebar != null;
      final palette = ShelfPalette.of(context);
      return Scaffold(
        drawer: desktop ? null : drawer,
        bottomNavigationBar: bottomNavigationBar,
        body: SafeArea(
          child: Row(
            children: [
              if (desktop) SizedBox(width: 224, child: sidebar),
              Expanded(
                child: Column(
                  children: [
                    Container(
                      height: 64,
                      decoration: BoxDecoration(
                        border: Border(bottom: BorderSide(color: palette.line)),
                      ),
                      padding: EdgeInsets.symmetric(
                        horizontal: desktop ? 28 : 12,
                      ),
                      child: Row(
                        children: [
                          if (!desktop)
                            Builder(
                              builder: (context) => IconButton(
                                tooltip: 'Open navigation menu',
                                icon: const Icon(Icons.menu_rounded),
                                onPressed: () =>
                                    Scaffold.of(context).openDrawer(),
                              ),
                            ),
                          if (constraints.maxWidth >= 620) ...[
                            Text(
                              'Личное пространство',
                              style: TextStyle(
                                fontSize: 12,
                                color: palette.muted,
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: Text(
                                '/',
                                style: TextStyle(color: palette.line),
                              ),
                            ),
                          ],
                          Expanded(
                            child: Text(
                              title,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          ...actions,
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 520;
        final heading = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ОБЗОР КОЛЛЕКЦИИ',
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 1.5,
                color: palette.muted,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              title,
              style: TextStyle(
                fontSize: narrow ? 28 : 34,
                letterSpacing: -1,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 7),
            Text(
              subtitle,
              style: TextStyle(color: palette.muted, fontSize: 14),
            ),
          ],
        );
        if (narrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heading,
              if (action != null) ...[const SizedBox(height: 18), action!],
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: heading),
            ?action,
          ],
        );
      },
    );
  }
}

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
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 760 ? 4 : 2;
      final compact = constraints.maxWidth < 520;
      final width = (constraints.maxWidth - 12 * (columns - 1)) / columns;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          _stat(
            context,
            width,
            'Вся коллекция',
            total,
            '$books книг · $audio аудиокниг',
            Icons.local_library_outlined,
            'all',
            0,
            compact,
          ),
          _stat(
            context,
            width,
            'В процессе',
            active,
            'Читаете и слушаете сейчас',
            Icons.schedule_outlined,
            'active',
            1,
            compact,
          ),
          _stat(
            context,
            width,
            'Завершено',
            finished,
            'Истории, которые остались с вами',
            Icons.check_rounded,
            'finished',
            2,
            compact,
          ),
          _stat(
            context,
            width,
            'В планах',
            planned,
            'Впереди много интересного',
            Icons.bookmark_border_rounded,
            'planned',
            3,
            compact,
          ),
        ],
      );
    },
  );
  Widget _stat(
    BuildContext context,
    double width,
    String label,
    int value,
    String hint,
    IconData icon,
    String key,
    int tone,
    bool compact,
  ) {
    final palette = ShelfPalette.of(context);
    final color = [
      palette.accent,
      const Color(0xffd1b775),
      const Color(0xff8ebfae),
      const Color(0xff8da9d6),
    ][tone];
    return SizedBox(
      width: width,
      child: Semantics(
        button: onStatus != null,
        selected: selected == key && key != 'all',
        child: ShelfPanel(
          child: InkWell(
            onTap: onStatus == null ? null : () => onStatus!(key),
            child: Padding(
              padding: EdgeInsets.all(compact ? 13 : 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          label,
                          style: TextStyle(fontSize: 12, color: palette.muted),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.all(7),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: .13),
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: Icon(icon, size: 17, color: color),
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  Text(
                    '$value',
                    style: const TextStyle(
                      fontSize: 30,
                      height: 1.2,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (!compact) ...[
                    const SizedBox(height: 9),
                    SizedBox(
                      height:
                          34 * MediaQuery.textScalerOf(context).scale(11) / 11,
                      child: Text(
                        hint,
                        maxLines: 2,
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.5,
                          color: palette.muted,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
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
      'active' => const Color(0xffd1b775),
      'finished' => const Color(0xff8ebfae),
      _ => const Color(0xff8da9d6),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: palette.dark ? .14 : .12),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        switch (status) {
          'active' => 'В процессе',
          'finished' => 'Завершено',
          _ => 'В планах',
        },
        style: TextStyle(
          fontSize: 11,
          color: palette.dark ? color : Color.lerp(color, Colors.black, .35),
        ),
      ),
    );
  }
}

class ShelfSidebar extends StatelessWidget {
  final String section;
  final int count;
  final bool enabled;
  final bool connected;
  final VoidCallback onReading, onAudio, onLibrary, onSettings;
  final VoidCallback? onStatistics;
  final Map<String, int> statuses;
  final String status;
  final ValueChanged<String>? onStatus;
  const ShelfSidebar({
    super.key,
    required this.section,
    required this.count,
    required this.onReading,
    required this.onAudio,
    required this.onLibrary,
    required this.onSettings,
    this.onStatistics,
    this.enabled = true,
    this.connected = false,
    this.statuses = const {},
    this.status = 'all',
    this.onStatus,
  });
  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    return Container(
      decoration: BoxDecoration(
        color: palette.sidebar,
        border: Border(right: BorderSide(color: palette.line)),
      ),
      child: Material(
        color: palette.sidebar,
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 30, 16, 28),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: palette.accent,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.library_books_rounded,
                        color: Colors.white,
                        size: 21,
                      ),
                    ),
                    const SizedBox(width: 11),
                    const Text(
                      'PepeHub',
                      style: TextStyle(
                        fontSize: 23,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -.8,
                      ),
                    ),
                    Text(
                      '.',
                      style: TextStyle(
                        color: palette.accent,
                        fontSize: 27,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  children: [
                    _caption(palette, 'ЛИЧНОЕ ПРОСТРАНСТВО'),
                    _navigation(
                      context,
                      'Книги',
                      Icons.auto_stories_outlined,
                      section == 'reading',
                      onReading,
                    ),
                    _navigation(
                      context,
                      'Аудиокниги',
                      Icons.headphones_outlined,
                      section == 'audio',
                      onAudio,
                    ),
                    _navigation(
                      context,
                      'Библиотека',
                      Icons.local_library_outlined,
                      section == 'metadata',
                      onLibrary,
                      count,
                    ),
                    const SizedBox(height: 24),
                    if (onStatus != null) ...[
                      _caption(palette, 'МОЯ КОЛЛЕКЦИЯ'),
                      for (final entry in const {
                        'active': 'В процессе',
                        'finished': 'Завершено',
                        'planned': 'В планах',
                      }.entries)
                        _navigation(
                          context,
                          entry.value,
                          switch (entry.key) {
                            'active' => Icons.schedule,
                            'finished' => Icons.done,
                            _ => Icons.bookmark_border,
                          },
                          status == entry.key,
                          () => onStatus!(
                            status == entry.key ? 'all' : entry.key,
                          ),
                          statuses[entry.key] ?? 0,
                        ),
                    ],
                    if (onStatistics != null) ...[
                      const SizedBox(height: 24),
                      _caption(palette, 'ОБЗОР'),
                      _navigation(
                        context,
                        'Статистика',
                        Icons.bar_chart_rounded,
                        false,
                        onStatistics!,
                      ),
                    ],
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
                child: ShelfPanel(
                  child: InkWell(
                    onTap: onSettings,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Row(
                        children: [
                          Icon(
                            Icons.diamond_outlined,
                            color: palette.accent,
                            size: 17,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Obsidian',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  connected
                                      ? 'Библиотека подключена'
                                      : 'Подключить библиотеку',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: palette.muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (connected)
                            const Icon(
                              Icons.check_circle_outline,
                              size: 14,
                              color: Color(0xff8ebfae),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              Container(
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: palette.line)),
                ),
                padding: const EdgeInsets.all(18),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 16,
                      backgroundColor: palette.selected,
                      child: Text(
                        'P',
                        style: TextStyle(
                          color: palette.accent,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Личная библиотека',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            'Ваше пространство чтения',
                            style: TextStyle(fontSize: 9, color: palette.muted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _caption(ShelfPalette palette, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
    child: Text(
      text,
      style: TextStyle(color: palette.muted, fontSize: 10, letterSpacing: 1.1),
    ),
  );
  Widget _navigation(
    BuildContext context,
    String title,
    IconData icon,
    bool selected,
    VoidCallback action, [
    int? badge,
  ]) {
    final palette = ShelfPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: ListTile(
        dense: true,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        selected: selected,
        selectedTileColor: palette.selected,
        selectedColor: palette.accent,
        iconColor: palette.muted,
        textColor: palette.muted,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        leading: Icon(icon, size: 19),
        title: Text(title, style: const TextStyle(fontSize: 13)),
        trailing: badge == null
            ? null
            : Text('$badge', style: const TextStyle(fontSize: 11)),
        enabled: enabled,
        onTap: action,
      ),
    );
  }
}
