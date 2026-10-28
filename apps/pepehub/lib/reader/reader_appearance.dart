import 'dart:async';

import 'package:flutter/material.dart';

import 'reader_layout.dart';
import 'reader_fonts.dart';
import '../ui/app_theme.dart';

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
  try {
    return await showModalBottomSheet<ReaderPreferences>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (context) => _AppearanceSheet(
        initial: initial,
        pdf: pdf,
        pdfModeLocked: pdfModeLocked,
        onPreview: (value) {
          if (active) onPreview?.call(value);
        },
        pdfPageTools: pdfPageTools,
        pdfPreview: pdfPreview,
      ),
    );
  } finally {
    // The route's closing animation can outlive its result. A delayed preview
    // must not reapply cancelled preferences while that animation finishes.
    active = false;
  }
}

class _AppearanceSheet extends StatefulWidget {
  final ReaderPreferences initial;
  final bool pdf, pdfModeLocked;
  final ValueChanged<ReaderPreferences>? onPreview;
  final Widget? pdfPageTools;
  final Widget Function(ReaderPreferences)? pdfPreview;
  const _AppearanceSheet({
    required this.initial,
    required this.pdf,
    required this.pdfModeLocked,
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
  @override
  void dispose() {
    preview?.cancel();
    super.dispose();
  }

  void change(ReaderPreferences next) {
    setState(() => value = next);
    preview?.cancel();
    preview = Timer(
      const Duration(milliseconds: 150),
      () => widget.onPreview?.call(value),
    );
  }

  Widget choices(
    String label,
    Map<String, String> options,
    String selected,
    ValueChanged<String> select,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final entry in options.entries)
              ChoiceChip(
                label: Text(entry.value),
                selected: selected == entry.key,
                showCheckmark: false,
                onSelected: (_) => select(entry.key),
              ),
          ],
        ),
      ],
    ),
  );

  Widget slider(
    String label,
    double current,
    double min,
    double max,
    int divisions,
    ValueChanged<double> select, {
    String? display,
    Key? key,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(label)),
            Text(display ?? '${current.round()}'),
          ],
        ),
        Slider(
          key: key,
          value: current,
          min: min,
          max: max,
          divisions: divisions,
          label: display ?? '${current.round()}',
          onChanged: select,
        ),
      ],
    ),
  );

  Widget textSettings() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      DropdownButtonFormField<String>(
        key: const ValueKey('reader-font'),
        initialValue: value.font,
        isExpanded: true,
        menuMaxHeight: 420,
        decoration: const InputDecoration(
          labelText: 'Шрифт',
          helperText: 'Українська · English · Русский',
        ),
        items: [
          for (final font in readerFonts)
            DropdownMenuItem(
              value: font.id,
              child: Text(
                '${font.name} · ${font.serif ? 'с засечками' : 'без засечек'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontFamily: font.family),
              ),
            ),
        ],
        onChanged: (font) => change(value.copy(font: font)),
      ),
      const SizedBox(height: 20),
      ReaderValueStepper(
        label: 'Размер текста',
        value: '${value.size.round()}',
        decreaseLabel: 'Уменьшить размер текста',
        increaseLabel: 'Увеличить размер текста',
        onDecrease: value.size > 12
            ? () => change(value.copy(size: value.size - 1))
            : null,
        onIncrease: value.size < 56
            ? () => change(value.copy(size: value.size + 1))
            : null,
      ),
      const SizedBox(height: 20),
      slider(
        'Межстрочный интервал',
        value.spacing,
        1.2,
        2.2,
        10,
        (v) => change(value.copy(spacing: v)),
        display: value.spacing.toStringAsFixed(1),
      ),
    ],
  );

  Widget pageSettings() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (widget.pdf) ...[
        if (widget.pdfPageTools != null) widget.pdfPageTools!,
        choices(
          'Листание',
          {
            'scroll': 'Вертикальная прокрутка',
            if (!widget.pdfModeLocked) 'pages': 'Горизонтальные страницы',
          },
          value.mode,
          (v) => change(value.copy(mode: v)),
        ),
      ] else ...[
        slider(
          'Поля',
          value.margin,
          12,
          48,
          18,
          (v) => change(value.copy(margin: v)),
        ),
        slider(
          'Высота страницы',
          value.pageHeightFactor,
          .65,
          1.5,
          17,
          (v) => change(value.copy(pageHeightFactor: v)),
          display: '${(value.pageHeightFactor * 100).round()}% экрана',
        ),
        choices(
          'Режим чтения',
          const {
            'seamless': 'Непрерывно',
            'pages': 'Перелистывание',
            'compact': 'Без пустых мест',
            'scroll': 'По главам',
          },
          value.mode,
          (v) => change(value.copy(mode: v)),
        ),
        slider(
          'Ширина колонки на ПК',
          value.columnWidth,
          360,
          1200,
          21,
          (v) => change(value.copy(columnWidth: v)),
          key: const ValueKey('reader-column-width'),
        ),
      ],
    ],
  );

  Widget colorSettings() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      choices(
        'Цвет страницы',
        const {
          'light': 'Светлая',
          'dark': 'Тёмная',
          'sepia': 'Сепия',
          'system': 'Как в системе',
        },
        value.palette,
        (v) => change(value.copy(palette: v)),
      ),
      if (widget.pdf)
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text(
            'Тёмная тема инвертирует страницы, сохраняя цвета иллюстраций.',
          ),
        ),
      SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        title: const Text('Показывать выделения'),
        subtitle: const Text('Скрытие не удаляет цитаты и заметки'),
        value: value.showHighlights,
        onChanged: (v) => change(value.copy(showHighlights: v)),
      ),
    ],
  );

  Widget controls() {
    const actions = {
      'previous': 'Назад',
      'controls': 'Панели',
      'next': 'Вперёд',
      'none': 'Без действия',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Короткое нажатие'),
        const SizedBox(height: 12),
        Row(
          children: [
            for (final zone in ['left', 'center', 'right'])
              Expanded(
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
                                ? 'Показать / скрыть панели'
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
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: 16,
                          horizontal: 4,
                        ),
                        child: Column(
                          children: [
                            Icon(switch (zone) {
                              'left' => Icons.arrow_back,
                              'right' => Icons.arrow_forward,
                              _ => Icons.touch_app_outlined,
                            }),
                            const SizedBox(height: 8),
                            Text(
                              actions[switch (zone) {
                                'left' => value.leftTap,
                                'right' => value.rightTap,
                                _ => value.centerTap,
                              }]!,
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        slider(
          'Ширина боковых зон',
          value.zoneWidth,
          .15,
          .4,
          5,
          (v) => change(value.copy(zoneWidth: v)),
          display: '${(value.zoneWidth * 100).round()}%',
        ),
        TextButton(
          onPressed: () => change(
            value.copy(
              leftTap: 'previous',
              centerTap: 'controls',
              rightTap: 'next',
              zoneWidth: .25,
            ),
          ),
          child: const Text('Сбросить зоны'),
        ),
        if (!widget.pdf)
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Показывать полосу прокрутки'),
            value: value.showScrollbar,
            onChanged: (v) => change(value.copy(showScrollbar: v)),
          ),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text(
            'Долгое нажатие выделяет текст. Нажатие в центре возвращает панели.',
          ),
        ),
      ],
    );
  }

  Widget sample() {
    final dark = value.isDark(MediaQuery.platformBrightnessOf(context));
    final colors = PepeColors.of(context);
    final background = dark
        ? colors.background
        : value.palette == 'sepia'
        ? const Color(0xfff3e8d0)
        : const Color(0xfffafafa);
    final foreground = dark
        ? Color.lerp(colors.text, colors.muted, .15)!
        : const Color(0xff302b24);
    return Container(
      key: const ValueKey('reader-appearance-preview'),
      height: 128,
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(14),
      ),
      child: widget.pdf && widget.pdfPreview != null
          ? widget.pdfPreview!(value)
          : ClipRect(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Їжак і ґанок. Є вечір.\nТихий вечер у реки.\nA quiet evening.',
                  maxLines: 3,
                  overflow: TextOverflow.fade,
                  style: value.style(foreground),
                ),
              ),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabs = widget.pdf
        ? ['Страница', 'Цвет', 'Управление']
        : ['Текст', 'Страница', 'Цвет', 'Управление'];
    return FractionallySizedBox(
      heightFactor: .86,
      child: SafeArea(
        top: false,
        child: DefaultTabController(
          length: tabs.length,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.pdf ? 'Оформление PDF' : 'Оформление чтения',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Отменить изменения',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              if (MediaQuery.sizeOf(context).height > 680) sample(),
              LayoutBuilder(
                builder: (context, box) => TabBar(
                  isScrollable:
                      box.maxWidth < 420 ||
                      MediaQuery.textScalerOf(context).scale(14) > 16,
                  tabAlignment:
                      box.maxWidth < 420 ||
                          MediaQuery.textScalerOf(context).scale(14) > 16
                      ? TabAlignment.start
                      : TabAlignment.fill,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 14),
                  tabs: [
                    for (final label in tabs)
                      Tab(
                        key: ValueKey('reader-appearance-tab:$label'),
                        text: label,
                      ),
                  ],
                ),
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    for (final content in [
                      if (!widget.pdf) textSettings(),
                      pageSettings(),
                      colorSettings(),
                      controls(),
                    ])
                      SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                        child: content,
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Отменить'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        key: const ValueKey('reader-appearance-done'),
                        onPressed: () => Navigator.pop(context, value),
                        child: const Text('Готово'),
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
