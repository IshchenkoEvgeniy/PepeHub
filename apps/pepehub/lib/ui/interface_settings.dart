import 'package:flutter/material.dart';

import '../data/repository.dart';
import 'app_preferences.dart';
import 'app_theme.dart';
import 'settings_components.dart';
import 'shelf_components.dart';
import '../diagnostics/user_message.dart';

/// Theme, text size, density, motion and the start tab.
class InterfaceSettings extends StatefulWidget {
  final AppTheme appearance;
  final Repository repository;
  const InterfaceSettings({
    super.key,
    required this.appearance,
    required this.repository,
  });
  @override
  State<InterfaceSettings> createState() => _InterfaceSettingsState();
}

class _InterfaceSettingsState extends State<InterfaceSettings> {
  double? scaleDraft;
  bool saving = false;
  int startupGeneration = 0;
  AppTheme get appearance => widget.appearance;

  Future<void> _change(Future<void> Function() action) async {
    if (saving) return;
    setState(() => saving = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Изменение не сохранено: ${describeError(e)}'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  bool _marked(AppStyle style) => appearance.followSystem
      ? style == appearance.lightStyle || style == appearance.darkStyle
      : style == appearance.style;

  Widget _palettes(List<AppStyle> styles) => LayoutBuilder(
    builder: (context, size) {
      final columns = size.maxWidth < 420
          ? 2
          : size.maxWidth < 700
          ? 3
          : 5;
      final width = (size.maxWidth - 10 * (columns - 1)) / columns;
      return Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final style in styles)
            SizedBox(width: width, child: _swatch(style)),
        ],
      );
    },
  );

  Widget _swatch(AppStyle style) {
    final active = _marked(style);
    return Semantics(
      button: true,
      selected: active,
      child: Material(
        key: ValueKey('palette:${style.name}'),
        color: Color(style.background),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: active ? Color(style.accent) : Color(style.strongLine),
            width: active ? 2.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: saving
              ? null
              : () => _change(() => appearance.preferences(style: style)),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 54,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Color(style.surface),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _bar(style.text, 46, 6),
                      _bar(style.muted, 30, 4),
                      Row(
                        children: [
                          _bar(style.accent, 34, 12),
                          const Spacer(),
                          if (active)
                            Icon(
                              Icons.check_circle,
                              size: 14,
                              color: Color(style.accent),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  style.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Color(style.text),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bar(int color, double width, double height) => Container(
    height: height,
    width: width,
    decoration: BoxDecoration(
      color: Color(color),
      borderRadius: BorderRadius.circular(height / 2),
    ),
  );

  /// A miniature of the shelf in the current palette, size and density.
  Widget _preview(double scale) {
    final palette = ShelfPalette.of(context);
    final compact = appearance.compact;
    final gap = compact ? 8.0 : 12.0;
    Widget book(String title, String author, double progress, Color cover) =>
        Padding(
          padding: EdgeInsets.symmetric(vertical: gap / 2),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 48,
                decoration: BoxDecoration(
                  color: cover,
                  borderRadius: BorderRadius.circular(5),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.book(palette.text, size: 16),
                    ),
                    Text(
                      author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: palette.muted, fontSize: 12),
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 3,
                        color: palette.accent,
                        backgroundColor: palette.raised,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(
          MediaQuery.textScalerOf(context).scale(1) /
              appearance.textScale *
              scale,
        ),
      ),
      child: Container(
        key: const ValueKey('interface-preview'),
        margin: const EdgeInsets.only(bottom: 18),
        padding: EdgeInsets.fromLTRB(16, gap + 2, 16, gap),
        decoration: BoxDecoration(
          color: palette.background,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: palette.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'КНИГИ',
                    style: AppFonts.title(palette.text, size: 24),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: palette.accent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'Читаю',
                    style: TextStyle(
                      color: palette.onAccent,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: gap),
            book('Северный ветер', 'Анна Белова', .62, const Color(0xff2e7d78)),
            Divider(height: gap, color: palette.line),
            book('Дом у реки', 'Пётр Лунин', .18, const Color(0xff8a6a4f)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scale = scaleDraft ?? appearance.textScale;
    final systemMotion = MediaQueryData.fromView(View.of(context))
        .disableAnimations;
    final light = [
      for (final s in AppStyle.values)
        if (s.light) s,
    ];
    final dark = [
      for (final s in AppStyle.values)
        if (!s.light) s,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsHeading(
          'Интерфейс',
          'Цвета и размер элементов приложения. Шрифт и поля книги настраиваются в читалке.',
        ),
        _preview(scale),
        const SettingsSubheading('Тема'),
        SettingsGroup(
          children: [
            SwitchListTile(
              key: const ValueKey('interface-follow-system'),
              title: const Text('Как в системе'),
              subtitle: Text(
                appearance.followSystem
                    ? 'Светлая — «${appearance.lightStyle.label}», тёмная — «${appearance.darkStyle.label}». Нажмите на палитру, чтобы заменить.'
                    : 'Светлая палитра днём, тёмная ночью',
              ),
              value: appearance.followSystem,
              onChanged: saving
                  ? null
                  : (value) => _change(
                      () => appearance.preferences(followSystem: value),
                    ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 0, 10),
          child: Text(
            'Светлые',
            style: TextStyle(color: ShelfPalette.of(context).muted),
          ),
        ),
        _palettes(light),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 18, 0, 10),
          child: Text(
            'Тёмные',
            style: TextStyle(color: ShelfPalette.of(context).muted),
          ),
        ),
        _palettes(dark),
        const SizedBox(height: 22),
        const SettingsSubheading('Текст и движение'),
        SettingsGroup(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Размер текста интерфейса: ${(scale * 100).round()}%'),
                  Slider(
                    value: scale,
                    min: .9,
                    max: 1.3,
                    divisions: 4,
                    label: '${(scale * 100).round()}%',
                    onChanged: saving
                        ? null
                        : (value) => setState(() => scaleDraft = value),
                    onChangeEnd: (value) async {
                      await _change(
                        () => appearance.preferences(textScale: value),
                      );
                      if (mounted) setState(() => scaleDraft = null);
                    },
                  ),
                ],
              ),
            ),
            SwitchListTile(
              title: const Text('Компактный интерфейс'),
              subtitle: const Text('Меньше отступов в списках'),
              value: appearance.compact,
              onChanged: saving
                  ? null
                  : (value) =>
                        _change(() => appearance.preferences(compact: value)),
            ),
            SwitchListTile(
              title: const Text('Уменьшить анимации'),
              subtitle: Text(
                systemMotion
                    ? 'Уже включено в настройках системы'
                    : 'Переходы и эффекты без движения',
              ),
              value: systemMotion || appearance.reduceMotion,
              onChanged: saving || systemMotion
                  ? null
                  : (value) => _change(
                      () => appearance.preferences(reduceMotion: value),
                    ),
            ),
          ],
        ),
        const SettingsSubheading('Запуск'),
        SettingsGroup(
          children: [
            StartupSettings(
              key: ValueKey('startup:$startupGeneration'),
              repository: widget.repository,
            ),
          ],
        ),
        SettingsResetButton(
          what: 'тема, размер текста, плотность, анимации и стартовая вкладка',
          enabled: !saving,
          onReset: () => _change(() async {
            await appearance.reset();
            await StartupSettings.reset(widget.repository);
            if (mounted) setState(() => startupGeneration++);
          }),
        ),
      ],
    );
  }
}
