import 'package:flutter/material.dart';

import '../data/repository.dart';

class AppTheme extends ChangeNotifier {
  final Repository repository;
  ThemeMode mode = ThemeMode.dark;
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
    notifyListeners();
  }

  Future<void> set(ThemeMode value) async {
    await repository.setMeta('appearance-theme', value.name);
    if (_closed) return;
    mode = value;
    notifyListeners();
  }

  static ThemeData data(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final accent = dark ? const Color(0xffa69afb) : const Color(0xff7667d6);
    final background = dark ? const Color(0xff101116) : const Color(0xfff5f5fa);
    final panel = dark ? const Color(0xff191a23) : Colors.white;
    final line = dark ? const Color(0xff2b2c38) : const Color(0xffe3e3ed);
    final scheme =
        ColorScheme.fromSeed(
          seedColor: accent,
          brightness: brightness,
        ).copyWith(
          primary: accent,
          onPrimary: dark ? const Color(0xff181326) : Colors.white,
          primaryContainer: dark
              ? const Color(0xff29253f)
              : const Color(0xffeeebff),
          surface: panel,
          onSurface: dark ? const Color(0xffeeeef5) : const Color(0xff222333),
          onSurfaceVariant: dark
              ? const Color(0xff9295ab)
              : const Color(0xff727386),
          outline: dark ? const Color(0xff424454) : const Color(0xffc8c8d8),
          outlineVariant: line,
          surfaceContainerHighest: dark
              ? const Color(0xff262735)
              : const Color(0xffececf5),
        );
    return ThemeData(
      useMaterial3: true,
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
        fillColor: dark ? const Color(0xff141620) : const Color(0xfff8f8fc),
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
          backgroundColor: dark ? const Color(0xff8b7dde) : accent,
          foregroundColor: Colors.white,
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
