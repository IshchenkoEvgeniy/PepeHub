import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'reader_layout.dart';
import 'reader_fonts.dart';
import '../ui/app_theme.dart';

/// Reading appearance as a light sheet over the open book.
///
/// Every change is shown on the page behind the sheet right away (via
/// [onPreview]); closing the sheet in any way keeps the changes. Only
/// «Отменить» returns null, which tells the caller to restore [initial].
Future<ReaderPreferences?> showReaderAppearance(
  BuildContext context,
  ReaderPreferences initial, {
  bool pdf = false,
  bool pdfModeLocked = false,
  ValueChanged<ReaderPreferences>? onPreview,
  Widget? pdfPageTools,
  Widget Function(ReaderPreferences)? pdfPreview,
}) async {
  var active = true;
  var latest = initial;
  var cancelled = false;
  try {
    final result = await showModalBottomSheet<ReaderPreferences>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      isScrollControlled: true,
      // The open page stays visible: it is the preview.
      barrierColor: Colors.black.withValues(
        alpha: onPreview == null ? .3 : .08,
      ),
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (context) => _AppearanceSheet(
        initial: initial,
        pdf: pdf,
        pdfModeLocked: pdfModeLocked,
        livePage: onPreview != null,
        onChanged: (value) => latest = value,
        onCancel: () => cancelled = true,
        onPreview: (value) {
          if (active) onPreview?.call(value);
        },
        pdfPageTools: pdfPageTools,
        pdfPreview: pdfPreview,
      ),
    );
    if (cancelled) return null;
    return result ?? latest;
  } finally {
    // The route's closing animation can outlive its result. A delayed preview
    // must not reapply cancelled preferences while that animation finishes.
    active = false;
  }
}

class _AppearanceSheet extends StatefulWidget {
  final ReaderPreferences initial;
  final bool pdf, pdfModeLocked, livePage;
  final ValueChanged<ReaderPreferences> onChanged;
  final VoidCallback onCancel;
  final ValueChanged<ReaderPreferences>? onPreview;
  final Widget? pdfPageTools;
  final Widget Function(ReaderPreferences)? pdfPreview;
  const _AppearanceSheet({
    required this.initial,
    required this.pdf,
    required this.pdfModeLocked,
    required this.livePage,
    required this.onChanged,
    required this.onCancel,
    this.onPreview,
    this.pdfPageTools,
    this.pdfPreview,
  });
  @override
  State<_AppearanceSheet> createState() => _AppearanceSheetState();
}

class _AppearanceSheetState extends State<_AppearanceSheet> {
  late ReaderPreferences value = widget.initial;
  Timer? preview;
  bool more = false;
  static const _fontTile = 84.0, _fontGap = 8.0;

  /// Opens with the chosen font in view.
  late final fontScroll = ScrollController(
    initialScrollOffset: math.max(
      0.0,
      readerFonts.indexWhere((f) => f.id == widget.initial.font) *
              (_fontTile + _fontGap) -
          _fontTile,
    ),
  );

  @override
  void dispose() {
    preview?.cancel();
    fontScroll.dispose();
    super.dispose();
  }

  bool get changed => !mapEquals(value.toJson(), widget.initial.toJson());

  void change(ReaderPreferences next) {
    setState(() => value = next);
    widget.onChanged(next);
    preview?.cancel();
    preview = Timer(
      const Duration(milliseconds: 150),
      () => widget.onPreview?.call(value),
    );
  }

  TextStyle get _label => TextStyle(
    fontFamily: AppFonts.body,
    fontSize: 12,
    letterSpacing: .3,
    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .6),
  );

  Widget section(String title, Widget child, {Key? key}) => Padding(
    key: key,
    padding: const EdgeInsets.only(bottom: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title.toUpperCase(), style: _label),
        const SizedBox(height: 8),
        child,
      ],
    ),
  );

  Widget slider(
    IconData icon,
    String label,
    double current,
    double min,
    double max,
    int divisions,
    ValueChanged<double> select, {
    String? display,
    Key? key,
  }) => Row(
    children: [
      Tooltip(
        message: label,
        child: Icon(
          icon,
          size: 20,
          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .7),
        ),
      ),
      Expanded(
        child: Slider(
          key: key,
          value: current.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          label: display ?? '${current.round()}',
          semanticFormatterCallback: (v) => '$label: ${display ?? v.round()}',
          onChanged: select,
        ),
      ),
      SizedBox(
        width: 36,
        child: Text(
          display ?? '${current.round()}',
          textAlign: TextAlign.end,
          style: Theme.of(context).textTheme.labelLarge,
        ),
      ),
    ],
  );

  Widget fontSize() {
    final scheme = Theme.of(context).colorScheme;
    Widget button(String tooltip, double size, VoidCallback? onTap) => Expanded(
      child: Tooltip(
        message: tooltip,
        child: OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: Text(
            'A',
            style: TextStyle(
              fontFamily: readerFont(value.font).family,
              fontSize: size,
            ),
          ),
        ),
      ),
    );
    return Row(
      children: [
        button(
          'Уменьшить размер текста',
          15,
          value.size > 12
              ? () => change(value.copy(size: value.size - 1))
              : null,
        ),
        SizedBox(
          width: 72,
          child: Semantics(
            liveRegion: true,
            label: 'Размер текста',
            child: Text(
              '${value.size.round()}',
              key: const ValueKey('reader-font-size'),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge
                  ?.copyWith(color: scheme.onSurface),
            ),
          ),
        ),
        button(
          'Увеличить размер текста',
          24,
          value.size < 56
              ? () => change(value.copy(size: value.size + 1))
              : null,
        ),
      ],
    );
  }

  Widget fonts() {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      key: const ValueKey('reader-font'),
      height: 80,
      child: ListView.separated(
        controller: fontScroll,
        scrollDirection: Axis.horizontal,
        itemCount: readerFonts.length,
        separatorBuilder: (_, _) => const SizedBox(width: _fontGap),
        itemBuilder: (context, i) {
          final font = readerFonts[i];
          final selected = font.id == value.font;
          return Semantics(
            selected: selected,
            button: true,
            label: 'Шрифт ${font.name}',
            child: InkWell(
              key: ValueKey('reader-font:${font.id}'),
              borderRadius: BorderRadius.circular(12),
              onTap: () => change(value.copy(font: font.id)),
              child: Container(
                width: _fontTile,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: selected ? scheme.primary : scheme.outlineVariant,
                    width: selected ? 2 : 1,
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Аа',
                      style: TextStyle(
                        fontFamily: font.family,
                        fontSize: 24,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      font.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurface.withValues(alpha: .7),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget palettes() {
    final colors = PepeColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    const light = Color(0xfffafafa), sepia = Color(0xfff3e8d0);
    final dark = colors.background;
    final options = [
      ('light', 'Светлая', [light]),
      ('sepia', 'Сепия', [sepia]),
      ('dark', 'Тёмная', [dark]),
      ('system', 'Как в системе', [light, dark]),
    ];
    return Row(
      children: [
        for (final (id, name, swatch) in options)
          Expanded(
            child: Semantics(
              selected: value.palette == id,
              button: true,
              label: 'Цвет страницы: $name',
              child: InkWell(
                key: ValueKey('reader-palette:$id'),
                borderRadius: BorderRadius.circular(12),
                onTap: () => change(value.copy(palette: id)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: value.palette == id
                                ? scheme.primary
                                : scheme.outlineVariant,
                            width: value.palette == id ? 2.5 : 1,
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final color in swatch)
                              Expanded(child: ColoredBox(color: color)),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurface.withValues(alpha: .75),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget readingMode() {
    if (widget.pdf) {
      return SegmentedButton<String>(
        key: const ValueKey('reader-mode'),
        showSelectedIcon: false,
        segments: [
          const ButtonSegment(
            value: 'scroll',
            label: Text('Прокрутка'),
            icon: Icon(Icons.swap_vert),
          ),
          ButtonSegment(
            value: 'pages',
            label: const Text('Страницы'),
            icon: const Icon(Icons.auto_stories_outlined),
            enabled: !widget.pdfModeLocked,
          ),
        ],
        selected: {value.mode == 'pages' ? 'pages' : 'scroll'},
        onSelectionChanged: (v) => change(value.copy(mode: v.first)),
      );
    }
    final paged = value.mode == 'pages';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<String>(
          key: const ValueKey('reader-mode'),
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
              value: 'pages',
              label: Text('Страницы'),
              icon: Icon(Icons.auto_stories_outlined),
            ),
            ButtonSegment(
              value: 'scrolling',
              label: Text('Прокрутка'),
              icon: Icon(Icons.swap_vert),
            ),
          ],
          selected: {paged ? 'pages' : 'scrolling'},
          onSelectionChanged: (v) => change(
            value.copy(mode: v.first == 'pages' ? 'pages' : 'compact'),
          ),
        ),
        if (!paged)
          SwitchListTile.adaptive(
            key: const ValueKey('reader-mode-chapters'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Каждая глава отдельно'),
            subtitle: const Text('Иначе вся книга идёт одной лентой'),
            value: value.mode == 'scroll',
            onChanged: (v) =>
                change(value.copy(mode: v ? 'scroll' : 'compact')),
          ),
      ],
    );
  }

  Widget alignment() => SegmentedButton<String>(
    key: const ValueKey('reader-align'),
    showSelectedIcon: false,
    segments: const [
      ButtonSegment(
        value: 'left',
        tooltip: 'По левому краю',
        label: Text('По левому краю'),
        icon: Icon(Icons.format_align_left),
      ),
      ButtonSegment(
        value: 'justify',
        tooltip: 'По ширине',
        label: Text('По ширине'),
        icon: Icon(Icons.format_align_justify),
      ),
    ],
    selected: {value.textAlign},
    onSelectionChanged: (v) => change(value.copy(textAlign: v.first)),
  );

  Widget tapZones() {
    const actions = {
      'previous': 'Назад',
      'controls': 'Меню',
      'next': 'Вперёд',
      'none': 'Ничего',
    };
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Нажатие по краям и в центре страницы', style: _label),
        const SizedBox(height: 8),
        Row(
          children: [
            for (final zone in ['left', 'center', 'right'])
              Expanded(
                flex: zone == 'center' ? 2 : 1,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: PopupMenuButton<String>(
                    tooltip: switch (zone) {
                      'left' => 'Левая зона',
                      'right' => 'Правая зона',
                      _ => 'Центральная зона',
                    },
                    initialValue: switch (zone) {
                      'left' => value.leftTap,
                      'right' => value.rightTap,
                      _ => value.centerTap,
                    },
                    itemBuilder: (_) => [
                      for (final action in actions.entries)
                        PopupMenuItem(
                          value: action.key,
                          child: Text(
                            action.key == 'controls'
                                ? 'Показать / скрыть меню'
                                : action.value,
                          ),
                        ),
                    ],
                    onSelected: (v) => change(
                      value.copy(
                        leftTap: zone == 'left' ? v : null,
                        centerTap: zone == 'center' ? v : null,
                        rightTap: zone == 'right' ? v : null,
                      ),
                    ),
                    child: Container(
                      height: 56,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        actions[switch (zone) {
                          'left' => value.leftTap,
                          'right' => value.rightTap,
                          _ => value.centerTap,
                        }]!,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        slider(
          Icons.width_normal_outlined,
          'Ширина боковых зон',
          value.zoneWidth,
          .15,
          .4,
          5,
          (v) => change(value.copy(zoneWidth: v)),
          display: '${(value.zoneWidth * 100).round()}%',
        ),
      ],
    );
  }

  Widget moreSettings() {
    final wide = MediaQuery.sizeOf(context).width >= 700;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        tapZones(),
        const SizedBox(height: 8),
        SwitchListTile.adaptive(
          key: const ValueKey('reader-keep-awake'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Не гасить экран'),
          subtitle: const Text('Экран погаснет через 10 минут без действий'),
          value: value.keepAwake,
          onChanged: (v) => change(value.copy(keepAwake: v)),
        ),
        if (!widget.pdf && defaultTargetPlatform == TargetPlatform.android)
          SwitchListTile.adaptive(
            key: const ValueKey('reader-volume-keys'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Листать кнопками громкости'),
            subtitle: const Text('Громкость вниз — вперёд, вверх — назад'),
            value: value.volumeKeys,
            onChanged: (v) => change(value.copy(volumeKeys: v)),
          ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: const Text('Показывать выделения'),
          subtitle: const Text('Скрытие не удаляет цитаты и заметки'),
          value: value.showHighlights,
          onChanged: (v) => change(value.copy(showHighlights: v)),
        ),
        if (!widget.pdf && value.mode != 'pages')
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Полоса прокрутки'),
            value: value.showScrollbar,
            onChanged: (v) => change(value.copy(showScrollbar: v)),
          ),
        if (!widget.pdf && wide)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: slider(
              Icons.view_column_outlined,
              'Ширина колонки на ПК',
              value.columnWidth,
              360,
              1200,
              21,
              (v) => change(value.copy(columnWidth: v)),
              key: const ValueKey('reader-column-width'),
            ),
          ),
        if (widget.pdf)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Тёмная тема инвертирует страницы, сохраняя цвета иллюстраций.',
            ),
          ),
      ],
    );
  }

  /// Sample text for screens without a live page behind the sheet (settings)
  /// and the PDF page preview.
  Widget? sample() {
    if (widget.pdf && widget.pdfPreview != null) {
      return _paper(widget.pdfPreview!(value));
    }
    if (widget.livePage || widget.pdf) return null;
    final dark = value.isDark(MediaQuery.platformBrightnessOf(context));
    final colors = PepeColors.of(context);
    final foreground = dark
        ? Color.lerp(colors.text, colors.muted, .15)!
        : const Color(0xff302b24);
    return _paper(
      ClipRect(
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Їжак і ґанок. Є вечір.\nТихий вечер у реки.\nA quiet evening.',
            textAlign: value.textAlign == 'justify'
                ? TextAlign.justify
                : TextAlign.left,
            maxLines: 3,
            overflow: TextOverflow.fade,
            style: value.style(foreground),
          ),
        ),
      ),
    );
  }

  Widget _paper(Widget child) {
    final dark = value.isDark(MediaQuery.platformBrightnessOf(context));
    final colors = PepeColors.of(context);
    final background = dark
        ? colors.background
        : value.palette == 'sepia'
        ? const Color(0xfff3e8d0)
        : const Color(0xfffafafa);
    return Container(
      key: const ValueKey('reader-appearance-preview'),
      height: 112,
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final preview = sample();
    final maxHeight = MediaQuery.sizeOf(context).height * .72;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.pdf ? 'Оформление PDF' : 'Оформление чтения',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  TextButton(
                    key: const ValueKey('reader-appearance-cancel'),
                    onPressed: changed
                        ? () {
                            widget.onCancel();
                            Navigator.pop(context);
                          }
                        : null,
                    child: const Text('Отменить'),
                  ),
                  IconButton(
                    key: const ValueKey('reader-appearance-done'),
                    tooltip: 'Готово',
                    onPressed: () => Navigator.pop(context, value),
                    icon: const Icon(Icons.check),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ?preview,
                    if (!widget.pdf) ...[
                      section('Размер текста', fontSize()),
                      section('Шрифт', fonts()),
                    ],
                    section('Цвет страницы', palettes()),
                    section(
                      widget.pdf ? 'Листание' : 'Режим чтения',
                      readingMode(),
                    ),
                    if (widget.pdf && widget.pdfPageTools != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 18),
                        child: widget.pdfPageTools!,
                      ),
                    if (!widget.pdf)
                      section(
                        'Текст на странице',
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            slider(
                              Icons.format_line_spacing,
                              'Межстрочный интервал',
                              value.spacing,
                              1.2,
                              2.2,
                              10,
                              (v) => change(value.copy(spacing: v)),
                              display: value.spacing.toStringAsFixed(1),
                            ),
                            slider(
                              Icons.format_indent_increase,
                              'Поля',
                              value.margin,
                              12,
                              48,
                              18,
                              (v) => change(value.copy(margin: v)),
                            ),
                            const SizedBox(height: 6),
                            alignment(),
                            if (value.textAlign == 'justify')
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Text(
                                  'Без переносов слов на узком экране между '
                                  'словами бывают большие пробелы.',
                                  style: _label.copyWith(letterSpacing: 0),
                                ),
                              ),
                          ],
                        ),
                      ),
                    Material(
                      type: MaterialType.transparency,
                      child: ListTile(
                        key: const ValueKey('reader-appearance-more'),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Управление и экран'),
                        subtitle: const Text(
                          'Зоны нажатия, подсветка экрана, выделения',
                        ),
                        trailing: Icon(
                          more ? Icons.expand_less : Icons.expand_more,
                        ),
                        onTap: () => setState(() => more = !more),
                      ),
                    ),
                    if (more) moreSettings(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ReaderValueStepper extends StatelessWidget {
  final String label, value, decreaseLabel, increaseLabel;
  final VoidCallback? onDecrease, onIncrease;
  const ReaderValueStepper({
    super.key,
    required this.label,
    required this.value,
    required this.decreaseLabel,
    required this.increaseLabel,
    this.onDecrease,
    this.onIncrease,
  });
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 8),
      Row(
        children: [
          IconButton.filledTonal(
            tooltip: decreaseLabel,
            onPressed: onDecrease,
            icon: const Icon(Icons.remove),
          ),
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Text(
                value,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
          ),
          IconButton.filledTonal(
            tooltip: increaseLabel,
            onPressed: onIncrease,
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    ],
  );
}
