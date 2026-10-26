import 'dart:convert';

import 'package:flutter/material.dart';

import '../data/repository.dart';

/// Font roles from the design: Oswald for display headings, Cormorant
/// Garamond for book titles, Onest for the interface and Lora for book text.
abstract final class AppFonts {
  static const body = 'Onest';
  static const display = 'Oswald';
  static const serif = 'CormorantGaramond';
  static const reading = 'ReaderLora';

  static TextStyle title(Color color, {double size = 34}) => TextStyle(
    fontFamily: display,
    fontSize: size,
    height: 1.05,
    fontWeight: FontWeight.w700,
    letterSpacing: .3,
    color: color,
  );

  /// Cormorant has a small x-height, so book titles are set a little larger.
  static TextStyle book(Color color, {double size = 18}) => TextStyle(
    fontFamily: serif,
    fontSize: size * 1.12,
    height: 1.12,
    fontWeight: FontWeight.w700,
    color: color,
  );
}

/// Colour palettes for the dark interface. Every palette is a complete set of
/// tokens, so screens never derive colours of their own.
enum AppStyle {
  dusk(
    'Сумерки',
    background: 0xff111a2b,
    surface: 0xff18233a,
    raised: 0xff22304d,
    line: 0xff2a3856,
    strongLine: 0xff3a4a6e,
    accent: 0xfff2a36b,
    accentSoft: 0xfff7c39b,
    onAccent: 0xff1a1208,
    text: 0xffeef0f5,
    muted: 0xff9fa9bf,
    navigation: 0xff0b1220,
  ),
  embers(
    'Угли',
    background: 0xff140e0a,
    surface: 0xff20160f,
    raised: 0xff2c1e14,
    line: 0xff3a2819,
    strongLine: 0xff4a3324,
    accent: 0xffff8a3d,
    accentSoft: 0xffffb36b,
    onAccent: 0xff1a0e06,
    text: 0xfff7ece2,
    muted: 0xffb39c8a,
    navigation: 0xff0c0805,
  ),
  pine(
    'Хвоя',
    background: 0xff0f1d1b,
    surface: 0xff162a27,
    raised: 0xff1f3733,
    line: 0xff2a4440,
    strongLine: 0xff36564f,
    accent: 0xffe39a62,
    accentSoft: 0xffefbb92,
    onAccent: 0xff1a1008,
    text: 0xffe9f0ec,
    muted: 0xff9bb3ad,
    navigation: 0xff0a1513,
  ),
  brass(
    'Латунь',
    background: 0xff0b1020,
    surface: 0xff131a2e,
    raised: 0xff1b2440,
    line: 0xff26304d,
    strongLine: 0xff3a4566,
    accent: 0xffd9b46a,
    accentSoft: 0xffebd29c,
    onAccent: 0xff14100a,
    text: 0xffece6d8,
    muted: 0xff9aa3bd,
    navigation: 0xff080c18,
  ),
  plum(
    'Слива',
    background: 0xff1a1420,
    surface: 0xff241c2c,
    raised: 0xff2f2539,
    line: 0xff3b3047,
    strongLine: 0xff4b3d59,
    accent: 0xfff4a98a,
    accentSoft: 0xfff8c7b3,
    onAccent: 0xff24120c,
    text: 0xfff3ecef,
    muted: 0xffb3a5b8,
    navigation: 0xff130e18,
  ),
  mono(
    'Чёрно-белый',
    background: 0xff000000,
    surface: 0xff141414,
    raised: 0xff262626,
    line: 0xff2a2a2a,
    strongLine: 0xff444444,
    accent: 0xffffffff,
    accentSoft: 0xffd9d9d9,
    onAccent: 0xff000000,
    text: 0xffffffff,
    muted: 0xff9a9a9a,
    navigation: 0xff000000,
  ),
  blue(
    'Синий',
    background: 0xff121212,
    surface: 0xff1e1e1e,
    raised: 0xff2c2c2c,
    line: 0xff2c2c2c,
    strongLine: 0xff444444,
    accent: 0xff2f6fed,
    accentSoft: 0xff8fb2f7,
    onAccent: 0xffffffff,
    text: 0xffffffff,
    muted: 0xffa0a0a0,
    navigation: 0xff0a0a0a,
  ),
  red(
    'Красный',
    background: 0xff121212,
    surface: 0xff1e1e1e,
    raised: 0xff2c2c2c,
    line: 0xff2c2c2c,
    strongLine: 0xff444444,
    accent: 0xffd93636,
    accentSoft: 0xfff08a8a,
    onAccent: 0xffffffff,
    text: 0xffffffff,
    muted: 0xffa0a0a0,
    navigation: 0xff0a0a0a,
  ),
  green(
    'Зелёный',
    background: 0xff121212,
    surface: 0xff1e1e1e,
    raised: 0xff2c2c2c,
    line: 0xff2c2c2c,
    strongLine: 0xff444444,
    accent: 0xff30c75a,
    accentSoft: 0xff8ee0a4,
    onAccent: 0xff000000,
    text: 0xffffffff,
    muted: 0xffa0a0a0,
    navigation: 0xff0a0a0a,
  ),
  yellow(
    'Жёлтый',
    background: 0xff121212,
    surface: 0xff1e1e1e,
    raised: 0xff2c2c2c,
    line: 0xff2c2c2c,
    strongLine: 0xff444444,
    accent: 0xffffd400,
    accentSoft: 0xffffe773,
    onAccent: 0xff000000,
    text: 0xffffffff,
    muted: 0xffa0a0a0,
    navigation: 0xff0a0a0a,
  );

  final String label;
  final int background,
      surface,
      raised,
      line,
      strongLine,
      accent,
      accentSoft,
      onAccent,
      text,
      muted,
      navigation;
  const AppStyle(
    this.label, {
    required this.background,
    required this.surface,
    required this.raised,
    required this.line,
    required this.strongLine,
    required this.accent,
    required this.accentSoft,
    required this.onAccent,
    required this.text,
    required this.muted,
    required this.navigation,
  });

  static const fallback = AppStyle.blue;
}

/// The active palette as colours, reachable from any widget through the theme.
@immutable
class PepeColors extends ThemeExtension<PepeColors> {
  final Color background,
      surface,
      raised,
      line,
      strongLine,
      accent,
      accentSoft,
      onAccent,
      text,
      muted,
      navigation;
  const PepeColors({
    required this.background,
    required this.surface,
    required this.raised,
    required this.line,
    required this.strongLine,
    required this.accent,
    required this.accentSoft,
    required this.onAccent,
    required this.text,
    required this.muted,
    required this.navigation,
  });

  factory PepeColors.from(AppStyle style) => PepeColors(
    background: Color(style.background),
    surface: Color(style.surface),
    raised: Color(style.raised),
    line: Color(style.line),
    strongLine: Color(style.strongLine),
    accent: Color(style.accent),
    accentSoft: Color(style.accentSoft),
    onAccent: Color(style.onAccent),
    text: Color(style.text),
    muted: Color(style.muted),
    navigation: Color(style.navigation),
  );

  static PepeColors of(BuildContext context) =>
      Theme.of(context).extension<PepeColors>() ??
      PepeColors.from(AppStyle.fallback);

  @override
  PepeColors copyWith({
    Color? background,
    Color? surface,
    Color? raised,
    Color? line,
    Color? strongLine,
    Color? accent,
    Color? accentSoft,
    Color? onAccent,
    Color? text,
    Color? muted,
    Color? navigation,
  }) => PepeColors(
    background: background ?? this.background,
    surface: surface ?? this.surface,
    raised: raised ?? this.raised,
    line: line ?? this.line,
    strongLine: strongLine ?? this.strongLine,
    accent: accent ?? this.accent,
    accentSoft: accentSoft ?? this.accentSoft,
    onAccent: onAccent ?? this.onAccent,
    text: text ?? this.text,
    muted: muted ?? this.muted,
    navigation: navigation ?? this.navigation,
  );

  @override
  PepeColors lerp(covariant ThemeExtension<PepeColors>? other, double t) {
    if (other is! PepeColors) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return PepeColors(
      background: mix(background, other.background),
      surface: mix(surface, other.surface),
      raised: mix(raised, other.raised),
      line: mix(line, other.line),
      strongLine: mix(strongLine, other.strongLine),
      accent: mix(accent, other.accent),
      accentSoft: mix(accentSoft, other.accentSoft),
      onAccent: mix(onAccent, other.onAccent),
      text: mix(text, other.text),
      muted: mix(muted, other.muted),
      navigation: mix(navigation, other.navigation),
    );
  }
}

class AppTheme extends ChangeNotifier {
  final Repository repository;
  AppStyle style = AppStyle.fallback;
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
    final raw = await repository.meta('appearance-settings');
    if (_closed) return;
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        final settings = decoded is Map<String, dynamic>
            ? decoded
            : <String, dynamic>{};
        // Styles from earlier versions are not palettes any more.
        style =
            AppStyle.values
                .where((s) => s.name == settings['style'])
                .firstOrNull ??
            AppStyle.fallback;
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

  /// The interface is dark only; [brightness] is accepted for older callers
  /// and ignored.
  static ThemeData data(
    Brightness brightness, {
    AppStyle style = AppStyle.fallback,
    bool compact = false,
  }) {
    final c = PepeColors.from(style);
    final scheme =
        ColorScheme.fromSeed(
          seedColor: c.accent,
          brightness: Brightness.dark,
        ).copyWith(
          primary: c.accent,
          onPrimary: c.onAccent,
          primaryContainer: Color.lerp(c.background, c.accent, .22),
          onPrimaryContainer: c.text,
          secondary: c.accentSoft,
          onSecondary: c.onAccent,
          secondaryContainer: c.raised,
          onSecondaryContainer: c.text,
          surface: c.surface,
          onSurface: c.text,
          onSurfaceVariant: c.muted,
          surfaceContainerLowest: c.background,
          surfaceContainerLow: c.background,
          surfaceContainer: c.surface,
          surfaceContainerHigh: c.raised,
          surfaceContainerHighest: c.raised,
          outline: c.strongLine,
          outlineVariant: c.line,
          error: const Color(0xffff7a70),
          onError: const Color(0xff2a0705),
        );
    final pill = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(22),
    );
    final textTheme = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: AppFonts.body,
    ).textTheme.apply(bodyColor: c.text, displayColor: c.text);
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      visualDensity: compact ? VisualDensity.compact : VisualDensity.standard,
      fontFamily: AppFonts.body,
      colorScheme: scheme,
      extensions: [c],
      scaffoldBackgroundColor: c.background,
      canvasColor: c.background,
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: c.background,
        foregroundColor: c.text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(
          fontFamily: AppFonts.display,
          fontSize: 19,
          fontWeight: FontWeight.w800,
          color: c.text,
        ),
      ),
      dividerTheme: DividerThemeData(color: c.line, thickness: 1, space: 1),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: c.accent,
        linearTrackColor: c.raised,
        circularTrackColor: Colors.transparent,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 18,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: c.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: c.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: c.accent, width: 1.5),
        ),
        labelStyle: TextStyle(color: c.muted, fontSize: 13),
        hintStyle: TextStyle(color: c.muted, fontSize: 13),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: c.surface,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: c.accent,
          foregroundColor: c.onAccent,
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: pill,
          textStyle: const TextStyle(
            fontFamily: AppFonts.body,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: c.text,
          minimumSize: const Size(0, 44),
          side: BorderSide(color: c.strongLine),
          shape: pill,
          textStyle: const TextStyle(
            fontFamily: AppFonts.body,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: c.accent),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected) ? c.accent : null,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) =>
                states.contains(WidgetState.selected) ? c.onAccent : null,
          ),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: c.accent,
        foregroundColor: c.onAccent,
        shape: pill,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: c.background,
        selectedColor: c.accent,
        disabledColor: c.surface,
        side: BorderSide(color: c.strongLine),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        labelStyle: TextStyle(
          fontFamily: AppFonts.body,
          fontSize: 13,
          color: WidgetStateColor.resolveWith(
            (states) =>
                states.contains(WidgetState.selected) ? c.onAccent : c.text,
          ),
        ),
        secondaryLabelStyle: TextStyle(
          fontFamily: AppFonts.body,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: c.onAccent,
        ),
        checkmarkColor: c.onAccent,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: c.muted,
        textColor: c.text,
        selectedColor: c.accent,
        selectedTileColor: Color.lerp(c.background, c.accent, .14),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: c.strongLine,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: c.raised,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: c.raised,
        contentTextStyle: TextStyle(fontFamily: AppFonts.body, color: c.text),
        actionTextColor: c.accent,
        behavior: SnackBarBehavior.floating,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? c.onAccent : c.muted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? c.accent : c.raised,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.transparent
              : c.strongLine,
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: c.accent,
        inactiveTrackColor: c.raised,
        thumbColor: c.accent,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: c.raised,
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: TextStyle(fontFamily: AppFonts.body, color: c.text),
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
