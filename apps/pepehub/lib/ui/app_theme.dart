import 'dart:convert';

import 'package:flutter/material.dart';

import '../data/repository.dart';

enum AppStyle {
  shelf('Shelf', 0xffa69afb, 0xff101116),
  forest('Лес', 0xff82cfa3, 0xff101a16),
  ocean('Океан', 0xff7abff0, 0xff101923),
  sunset('Закат', 0xffffad83, 0xff231619),
  rose('Роза', 0xffed9ac3, 0xff20151d),
  amber('Янтарь', 0xffe7bf70, 0xff211b11),
  graphite('Графит', 0xffb9c3cf, 0xff17191c),
  sepia('Бумага', 0xffceb58b, 0xff211e18),
  mint('Мята', 0xff79d9ce, 0xff0d1b1c),
  indigo('Индиго', 0xff9eafff, 0xff14172a);

  final String label;
  final int accent, background;
  const AppStyle(this.label, this.accent, this.background);
}

class AppTheme extends ChangeNotifier {
  final Repository repository;
  ThemeMode mode = ThemeMode.dark;
  AppStyle style = AppStyle.shelf;
  double textScale = 1;
  bool compact = false, reduceMotion = false;
  bool _closed = false;
  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }

  AppTheme(this.repository);
  Future<void> load() async {
    final value = await repository.meta('appearance-theme');
    if (_closed) return;
    mode =
        ThemeMode.values.where((m) => m.name == value).firstOrNull ??
        ThemeMode.dark;
    final raw = await repository.meta('appearance-settings');
    if (_closed) return;
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        final settings = decoded is Map<String, dynamic>
            ? decoded
            : <String, dynamic>{};
        style =
            AppStyle.values
                .where((s) => s.name == settings['style'])
                .firstOrNull ??
            AppStyle.shelf;
        textScale =
            (settings['textScale'] is num ? settings['textScale'] as num : 1)
                .toDouble()
                .clamp(0.9, 1.3);
        compact = settings['compact'] == true;
        reduceMotion = settings['reduceMotion'] == true;
      } on FormatException {
        /* Keep usable defaults for older preferences. */
      }
    }
    notifyListeners();
  }

  Future<void> set(ThemeMode value) async {
    await repository.setMeta('appearance-theme', value.name);
    if (_closed) return;
    mode = value;
    notifyListeners();
  }

  Future<void> preferences({
    AppStyle? style,
    double? textScale,
    bool? compact,
    bool? reduceMotion,
  }) async {
    if (_closed) return;
    this.style = style ?? this.style;
    this.textScale = (textScale ?? this.textScale).clamp(0.9, 1.3);
    this.compact = compact ?? this.compact;
    this.reduceMotion = reduceMotion ?? this.reduceMotion;
    notifyListeners();
    await repository.setMeta(
      'appearance-settings',
      jsonEncode({
        'style': this.style.name,
        'textScale': this.textScale,
        'compact': this.compact,
        'reduceMotion': this.reduceMotion,
      }),
    );
  }

  static ThemeData data(
    Brightness brightness, {
    AppStyle style = AppStyle.shelf,
    bool compact = false,
  }) {
    final dark = brightness == Brightness.dark;
    final seed = Color(style.accent);
    final accent = dark
        ? seed
        : HSLColor.fromColor(seed)
              .withLightness(style == AppStyle.graphite ? 0.35 : 0.38)
              .toColor();
    final background = dark
        ? Color(style.background)
        : Color.lerp(seed, Colors.white, .94)!;
    final panel = dark ? Color.lerp(background, seed, .065)! : Colors.white;
    final line = dark
        ? Color.lerp(background, seed, .19)!
        : Color.lerp(seed, Colors.white, .8)!;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: accent,
          brightness: brightness,
        ).copyWith(
          primary: accent,
          onPrimary: dark ? const Color(0xff181326) : Colors.white,
          primaryContainer: Color.lerp(background, accent, dark ? .18 : .1),
          surface: panel,
          onSurface: dark ? const Color(0xffeeeef5) : const Color(0xff222333),
          onSurfaceVariant: dark
              ? const Color(0xff9295ab)
              : const Color(0xff727386),
          outline: dark ? const Color(0xff424454) : const Color(0xffc8c8d8),
          outlineVariant: line,
          surfaceContainerHighest: Color.lerp(panel, accent, .10),
        );
    return ThemeData(
      useMaterial3: true,
      visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
      fontFamily: 'Manrope',
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        titleTextStyle: TextStyle(
          fontFamily: 'Manrope',
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),
      dividerTheme: DividerThemeData(color: line, thickness: 1, space: 1),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Color.lerp(background, panel, .45),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(7),
          borderSide: BorderSide(color: line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(7),
          borderSide: BorderSide(color: line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(7),
          borderSide: BorderSide(color: accent, width: 1.5),
        ),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
        hintStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: panel,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: line),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: scheme.onPrimary,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
          textStyle: const TextStyle(
            fontFamily: 'Manrope',
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: line),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
          textStyle: const TextStyle(fontFamily: 'Manrope', fontSize: 12),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: panel,
        selectedColor: scheme.primaryContainer,
        side: BorderSide(color: line),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        labelStyle: TextStyle(
          fontFamily: 'Manrope',
          fontSize: 12,
          color: scheme.onSurface,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
      ),
    );
  }
}

class ThemeScope extends InheritedNotifier<AppTheme> {
  const ThemeScope({
    super.key,
    required AppTheme controller,
    required super.child,
  }) : super(notifier: controller);
  static AppTheme? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ThemeScope>()?.notifier;
}
