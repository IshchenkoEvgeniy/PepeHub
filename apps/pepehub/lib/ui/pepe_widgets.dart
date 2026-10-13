import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'shelf_components.dart';

export 'app_theme.dart' show AppFonts;

/// Main-section navigation published by the library page, so screens pushed
/// above it can show the same rail on wide windows.
abstract final class PepeRoot {
  static ShelfNavigation? navigation;
}

bool pepeWide(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= ShelfShell.wideBreakpoint;

/// Short duration: «4 ч», «4 ч 5 мин», «45 мин», «30 с».
String pepeTime(int ms) {
  final minutes = ms ~/ 60000;
  if (minutes <= 0) return '${ms ~/ 1000} с';
  if (minutes < 60) return '$minutes мин';
  final h = minutes ~/ 60, m = minutes % 60;
  return m == 0 ? '$h ч' : '$h ч $m мин';
}

const pepeMonthNames = [
  'январь',
  'февраль',
  'март',
  'апрель',
  'май',
  'июнь',
  'июль',
  'август',
  'сентябрь',
  'октябрь',
  'ноябрь',
  'декабрь',
];

const pepeMonthGenitive = [
  'января',
  'февраля',
  'марта',
  'апреля',
  'мая',
  'июня',
  'июля',
  'августа',
  'сентября',
  'октября',
  'ноября',
  'декабря',
];

String pepeDate(DateTime d) => '${d.day} ${pepeMonthGenitive[d.month - 1]}';

const pepeWeekdays = [
  'понедельник',
  'вторник',
  'среда',
  'четверг',
  'пятница',
  'суббота',
  'воскресенье',
];

String pepeClock(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// «12 400 зн.» / «1,2 млн зн.»
String pepeChars(int n) {
  if (n >= 1000000) {
    return '${(n / 1000000).toStringAsFixed(1).replaceAll('.', ',')} млн зн.';
  }
  final digits = '$n';
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write('\u00a0');
    out.write(digits[i]);
  }
  return '$out зн.';
}

/// Frame for screens opened from a section: the rail on wide windows, a
/// compact header with a back button on phones. Give either [children]
/// (placed in a scrolling list under the header) or a custom [body].
class PepeSubpage extends StatelessWidget {
  final String title;
  final String? back, subtitle;
  final PepeSection? section;
  final bool settings;
  final List<Widget> actions;
  final List<Widget>? children;
  final Widget? body;
  final Widget? bottomNavigationBar, floatingActionButton;
  final double maxWidth;
  final Future<void> Function()? onRefresh;
  const PepeSubpage({
    super.key,
    required this.title,
    this.back,
    this.subtitle,
    this.section,
    this.settings = false,
    this.actions = const [],
    this.children,
    this.body,
    this.bottomNavigationBar,
    this.floatingActionButton,
    this.maxWidth = 1340,
    this.onRefresh,
  }) : assert((children == null) != (body == null));

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final palette = ShelfPalette.of(context);
      final wide = constraints.maxWidth >= ShelfShell.wideBreakpoint;
      final root = PepeRoot.navigation;
      final rail = wide && root != null && (section != null || settings);
      final pad = wide ? 28.0 : 16.0;
      final header = _header(context, palette, wide, pad);
      Widget content;
      if (children != null) {
        Widget list = ListView(
          padding: EdgeInsets.fromLTRB(pad, 0, pad, 36),
          children: [header, ...children!],
        );
        if (onRefresh != null) {
          list = RefreshIndicator(onRefresh: onRefresh!, child: list);
        }
        content = list;
      } else {
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: pad),
              child: header,
            ),
            Expanded(child: body!),
          ],
        );
      }
      return Scaffold(
        backgroundColor: palette.background,
        bottomNavigationBar: bottomNavigationBar,
        floatingActionButton: floatingActionButton,
        body: SafeArea(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (rail)
                ShelfRail(
                  navigation: ShelfNavigation(
                    current: section,
                    settingsSelected: settings,
                    subpage: true,
                    onSettings: () {
                      Navigator.of(context).popUntil((r) => r.isFirst);
                      if (!settings) root.onSettings();
                    },
                    onSelect: (next) {
                      Navigator.of(context).popUntil((r) => r.isFirst);
                      if (next != root.current) root.onSelect(next);
                    },
                  ),
                ),
              Expanded(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxWidth),
                    child: content,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _header(
    BuildContext context,
    ShelfPalette palette,
    bool wide,
    double pad,
  ) {
    final canPop = Navigator.of(context).canPop();
    final heading = Text(
      title.toUpperCase(),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: AppFonts.title(palette.text, size: wide ? 44 : 28),
    );
    final note = subtitle == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              subtitle!,
              style: TextStyle(fontSize: 13, height: 1.4, color: palette.muted),
            ),
          );
    if (wide) {
      return Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (canPop)
              Row(
                children: [
                  const BackButton(),
                  if (back != null)
                    Text(
                      back!,
                      style: TextStyle(fontSize: 13, color: palette.muted),
                    ),
                ],
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(child: heading),
                ...actions,
              ],
            ),
            ?note,
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (canPop)
                const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: BackButton(),
                ),
              Expanded(child: heading),
              ...actions,
            ],
          ),
          ?note,
        ],
      ),
    );
  }
}

/// Rounded block on the page background.
class PepePanel extends StatelessWidget {
  final Widget child;
  final String? title;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final bool outlined;
  const PepePanel({
    super.key,
    required this.child,
    this.title,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(20, 18, 20, 18),
    this.color,
    this.outlined = false,
  });
  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    return Material(
      color: outlined ? Colors.transparent : color ?? palette.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: outlined ? BorderSide(color: palette.line) : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: padding,
        child: title == null
            ? child
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(child: PepeHeading(title!)),
                      ?trailing,
                    ],
                  ),
                  const SizedBox(height: 12),
                  child,
                ],
              ),
      ),
    );
  }
}

class PepeHeading extends StatelessWidget {
  final String text;
  final double size;
  const PepeHeading(this.text, {super.key, this.size = 22});
  @override
  Widget build(BuildContext context) => Text(
    text,
    style: AppFonts.book(
      ShelfPalette.of(context).text,
      size: size,
    ).copyWith(fontWeight: FontWeight.w700),
  );
}

/// Uppercase display label used for blocks on detail screens.
class PepeCaption extends StatelessWidget {
  final String text;
  const PepeCaption(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: TextStyle(
      fontFamily: AppFonts.display,
      fontSize: 15,
      fontWeight: FontWeight.w800,
      letterSpacing: .6,
      color: ShelfPalette.of(context).text,
    ),
  );
}

/// Lays children side by side when there is room and stacks them otherwise.
class PepeRow extends StatelessWidget {
  final List<(int, Widget)> children;
  final double gap, breakpoint;
  const PepeRow({
    super.key,
    required this.children,
    this.gap = 16,
    this.breakpoint = 720,
  });
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < breakpoint) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) SizedBox(height: gap),
              children[i].$2,
            ],
          ],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) SizedBox(width: gap),
            Expanded(flex: children[i].$1, child: children[i].$2),
          ],
        ],
      );
    },
  );
}

/// A big number with a short label below.
class PepeFigure extends StatelessWidget {
  final String value, label;
  final double size;
  final Color? color;
  const PepeFigure(
    this.value,
    this.label, {
    super.key,
    this.size = 32,
    this.color,
  });
  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            maxLines: 1,
            style: AppFonts.title(color ?? palette.text, size: size),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: TextStyle(fontSize: 12, height: 1.3, color: palette.muted),
        ),
      ],
    );
  }
}

/// A row of figures between an accent rule and a thin line.
class PepeFigureStrip extends StatelessWidget {
  final List<(String, String)> figures;
  const PepeFigureStrip(this.figures, {super.key});
  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: palette.accent),
          bottom: BorderSide(color: palette.line),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final fit = math.max(
            2,
            math.min(figures.length, constraints.maxWidth ~/ 150),
          );
          final rows = (figures.length / fit).ceil();
          final perRow = (figures.length / rows).ceil();
          final width = constraints.maxWidth / perRow;
          return Wrap(
            children: [
              for (final (value, label) in figures)
                SizedBox(
                  width: width,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(0, 14, 14, 14),
                    child: PepeFigure(value, label),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Rounded choice buttons; the selected one is filled with the text colour.
class PepeChoices<T> extends StatelessWidget {
  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T> onSelect;
  final String? keyPrefix;
  const PepeChoices({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelect,
    this.keyPrefix,
  });
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 6,
    children: [
      for (final (value, label) in options)
        ShelfPill(
          key: keyPrefix == null ? null : ValueKey('$keyPrefix:$value'),
          label: label,
          selected: value == selected,
          onTap: () => onSelect(value),
        ),
    ],
  );
}

/// Ring with a number in the middle, for daily goals.
class PepeRing extends StatelessWidget {
  final double value;
  final String center, below;
  final double size;
  const PepeRing({
    super.key,
    required this.value,
    required this.center,
    required this.below,
    this.size = 108,
  });
  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: CircularProgressIndicator(
              value: value.clamp(0.0, 1.0),
              strokeWidth: size / 11,
              strokeCap: StrokeCap.round,
              backgroundColor: palette.raised,
              color: palette.accent,
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(center, style: AppFonts.title(palette.text, size: size / 4)),
              Text(
                below,
                style: TextStyle(fontSize: size / 10, color: palette.muted),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Daily bars. [values] are milliseconds, oldest first; [goalMinutes] draws
/// a dashed line and colours the days that reached it.
class PepeBars extends StatelessWidget {
  final List<int> values;
  final List<String> tooltips;
  final int goalMinutes;
  final double height;
  final String? startLabel, endLabel;
  const PepeBars({
    super.key,
    required this.values,
    this.tooltips = const [],
    this.goalMinutes = 0,
    this.height = 140,
    this.startLabel,
    this.endLabel,
  });
  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final goalMs = goalMinutes * 60000;
    final top = math.max(
      1,
      math.max(values.fold<int>(0, math.max), (goalMs * 1.25).round()),
    );
    final gap = values.length > 20 ? 2.0 : 4.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: height,
          child: Stack(
            children: [
              Positioned.fill(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (var i = 0; i < values.length; i++)
                      Expanded(
                        child: Tooltip(
                          message: i < tooltips.length ? tooltips[i] : '',
                          child: Padding(
                            padding: EdgeInsets.symmetric(horizontal: gap / 2),
                            child: Container(
                              height: math.max(3, values[i] / top * height),
                              decoration: BoxDecoration(
                                color: i == values.length - 1
                                    ? palette.accentSoft
                                    : values[i] <= 0
                                    ? palette.raised
                                    : goalMs > 0 && values[i] >= goalMs
                                    ? palette.accent
                                    : palette.muted,
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(3),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (goalMs > 0)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: goalMs / top * height,
                  child: const _Dashes(),
                ),
            ],
          ),
        ),
        Container(height: 1, color: palette.line),
        if (startLabel != null || endLabel != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                Text(
                  startLabel ?? '',
                  style: TextStyle(fontSize: 11, color: palette.muted),
                ),
                const Spacer(),
                Text(
                  endLabel ?? '',
                  style: TextStyle(fontSize: 11, color: palette.muted),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Dashes extends StatelessWidget {
  const _Dashes();
  @override
  Widget build(BuildContext context) {
    final color = ShelfPalette.of(context).muted.withValues(alpha: .7);
    return LayoutBuilder(
      builder: (context, constraints) {
        final count = (constraints.maxWidth / 9).floor();
        return Row(
          children: [
            for (var i = 0; i < count; i++)
              Container(
                width: 5,
                height: 2,
                margin: const EdgeInsets.only(right: 4),
                color: color,
              ),
          ],
        );
      },
    );
  }
}

/// A line of small squares, one per day, oldest first.
class PepeStreak extends StatelessWidget {
  final List<int> values;
  final int goalMinutes;
  final double height;
  const PepeStreak({
    super.key,
    required this.values,
    this.goalMinutes = 0,
    this.height = 20,
  });
  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    return Row(
      children: [
        for (var i = 0; i < values.length; i++)
          Expanded(
            child: Container(
              height: height,
              margin: EdgeInsets.only(right: i == values.length - 1 ? 0 : 3),
              decoration: BoxDecoration(
                color: values[i] <= 0
                    ? palette.raised
                    : goalMinutes <= 0 || values[i] >= goalMinutes * 60000
                    ? palette.accent
                    : palette.muted,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
      ],
    );
  }
}

/// Month grid coloured by time per day. [dayValue] receives each date.
class PepeMonthCalendar extends StatelessWidget {
  final DateTime month;
  final int Function(DateTime day) dayValue;
  final int goalMinutes;
  final String title;
  final VoidCallback onPrevious, onNext;
  final ValueChanged<DateTime>? onDay;
  final String Function(int ms) describe;
  const PepeMonthCalendar({
    super.key,
    required this.month,
    required this.dayValue,
    required this.title,
    required this.onPrevious,
    required this.onNext,
    required this.describe,
    this.goalMinutes = 0,
    this.onDay,
  });
  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    final first = DateTime(month.year, month.month);
    final count = DateTime(month.year, month.month + 1, 0).day;
    final offset = first.weekday - 1;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final values = [
      for (var d = 1; d <= count; d++) dayValue(DateTime(first.year, first.month, d)),
    ];
    final maximum = math.max(1, values.fold<int>(0, math.max));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: PepeHeading(title)),
            IconButton(
              tooltip: 'Предыдущий месяц',
              onPressed: onPrevious,
              icon: const Icon(Icons.chevron_left),
            ),
            IconButton(
              tooltip: 'Следующий месяц',
              onPressed: onNext,
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            for (final d in const ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'])
              Expanded(
                child: Text(
                  d,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: palette.muted),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 7,
            mainAxisSpacing: 5,
            crossAxisSpacing: 5,
          ),
          itemCount: ((offset + count + 6) ~/ 7) * 7,
          itemBuilder: (context, i) {
            final number = i - offset + 1;
            if (number < 1 || number > count) return const SizedBox();
            final date = DateTime(first.year, first.month, number);
            final ms = values[number - 1];
            final future = date.isAfter(today);
            final reached = goalMinutes > 0
                ? ms >= goalMinutes * 60000
                : ms >= maximum * .6;
            final fill = future || ms <= 0
                ? Colors.transparent
                : reached
                ? palette.accent
                : palette.raised;
            final ink = future
                ? palette.muted.withValues(alpha: .5)
                : reached
                ? palette.onAccent
                : ms > 0
                ? palette.text
                : palette.muted;
            return Tooltip(
              message: describe(ms),
              child: Material(
                color: fill,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: date == today
                      ? BorderSide(color: palette.accentSoft, width: 2)
                      : ms <= 0 && !future
                      ? BorderSide(color: palette.line)
                      : BorderSide.none,
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: onDay == null || future ? null : () => onDay!(date),
                  child: Center(
                    child: Text(
                      '$number',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: ms > 0 ? FontWeight.w700 : FontWeight.w400,
                        color: ink,
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// A horizontal share bar under a label, for "by book" lists.
class PepeShareRow extends StatelessWidget {
  final String title, value;
  final String? note;
  final double share;
  final Widget? leading;
  final VoidCallback? onTap;
  const PepeShareRow({
    super.key,
    required this.title,
    required this.value,
    required this.share,
    this.note,
    this.leading,
    this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: palette.line)),
        ),
        child: Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 12)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppFonts.book(palette.text, size: 17),
                  ),
                  const SizedBox(height: 7),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: share.clamp(0.0, 1.0),
                      minHeight: 5,
                      color: palette.accent,
                      backgroundColor: palette.raised,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (note != null)
                  Text(
                    note!,
                    style: TextStyle(fontSize: 11, color: palette.muted),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Plus/minus control around a number.
class PepeStepper extends StatelessWidget {
  final String value;
  final VoidCallback? onMinus, onPlus;
  const PepeStepper({
    super.key,
    required this.value,
    this.onMinus,
    this.onPlus,
  });
  @override
  Widget build(BuildContext context) {
    final palette = ShelfPalette.of(context);
    Widget button(IconData icon, String tip, VoidCallback? onTap) =>
        IconButton(
          tooltip: tip,
          onPressed: onTap,
          style: IconButton.styleFrom(
            side: BorderSide(color: palette.strongLine),
          ),
          icon: Icon(icon, size: 18),
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        button(Icons.remove, 'Меньше', onMinus),
        SizedBox(
          width: 64,
          child: Text(
            value,
            textAlign: TextAlign.center,
            style: AppFonts.title(palette.text, size: 26),
          ),
        ),
        button(Icons.add, 'Больше', onPlus),
      ],
    );
  }
}

/// Coloured square standing in for a cover.
class PepeSpine extends StatelessWidget {
  final String title;
  final double width, height;
  const PepeSpine(
    this.title, {
    super.key,
    this.width = 32,
    this.height = 48,
  });
  static const _tones = [
    Color(0xff2e7d78),
    Color(0xff2b4a8c),
    Color(0xff8a6a4f),
    Color(0xff5e4b8b),
    Color(0xffb4553a),
    Color(0xff3f6b4f),
    Color(0xff38505a),
    Color(0xffc85c6e),
  ];
  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: _tones[title.codeUnits.fold<int>(0, (a, b) => a + b) %
          _tones.length],
      borderRadius: BorderRadius.circular(4),
    ),
  );
}
