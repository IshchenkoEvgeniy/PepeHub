import 'package:flutter/material.dart';

import '../data/repository.dart';

class AppTheme extends ChangeNotifier {
  final Repository repository;
  ThemeMode mode = ThemeMode.system;
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
        ThemeMode.system;
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
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff399b9a),
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: dark
          ? const Color(0xff171c20)
          : const Color(0xfff5f6f2),
      appBarTheme: AppBarTheme(
        backgroundColor: dark
            ? const Color(0xff171c20)
            : const Color(0xfff5f6f2),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: dark ? const Color(0xff232b30) : Colors.white,
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
