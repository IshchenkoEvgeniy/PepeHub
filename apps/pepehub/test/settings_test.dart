import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/library_service.dart';
import 'package:pepehub/ui/app_theme.dart';
import 'package:pepehub/ui/settings_page.dart';
import 'package:pepehub/ui/library_data_page.dart';
import 'package:pepehub/ui/shelf_components.dart';

void main() {
  test('ten distinct palettes, appearance and accessibility preferences persist across restart', () async {
    final db = AppDatabase(NativeDatabase.memory()), repo = Repository(db);
    addTearDown(db.close);
    final appearance = AppTheme(repo);
    addTearDown(appearance.dispose);
    expect(AppStyle.values.length, 12);
    expect(AppStyle.values.where((s) => s.light).toList(), [
      AppStyle.paper,
      AppStyle.daylight,
    ]);
    expect(
      AppStyle.values
          .map(
            (s) => AppTheme.data(Brightness.dark, style: s).colorScheme.primary,
          )
          .toSet()
          .length,
      12,
    );
    expect(
      AppTheme.data(Brightness.dark, style: AppStyle.paper).brightness,
      Brightness.light,
    );
    for (final style in AppStyle.values) {
      await appearance.preferences(
        style: style,
        textScale: 1.3,
        compact: true,
        reduceMotion: true,
      );
      final restored = AppTheme(repo);
      await restored.load();
      expect(restored.style, style);
      expect(restored.textScale, 1.3);
      expect(restored.compact, true);
      expect(restored.reduceMotion, true);
      restored.dispose();
    }
    // Following the system keeps the last dark and light palettes.
    await appearance.preferences(style: AppStyle.pine);
    await appearance.preferences(style: AppStyle.daylight, followSystem: true);
    final paired = AppTheme(repo);
    await paired.load();
    expect(paired.followSystem, true);
    expect(paired.darkStyle, AppStyle.pine);
    expect(paired.lightStyle, AppStyle.daylight);
    expect(paired.themeMode, ThemeMode.system);
    expect(paired.effective(Brightness.light), AppStyle.daylight);
    expect(paired.effective(Brightness.dark), AppStyle.pine);
    expect(paired.lightTheme.brightness, Brightness.light);
    expect(paired.darkTheme.brightness, Brightness.dark);
    paired.dispose();
    await appearance.reset();
    final reset = AppTheme(repo);
    await reset.load();
    expect(reset.style, AppStyle.fallback);
    expect(reset.followSystem, false);
    expect(reset.textScale, 1);
    expect(reset.compact, false);
    expect(reset.themeMode, ThemeMode.dark);
    reset.dispose();
    // Settings saved before light palettes existed keep their dark palette.
    await repo.setMeta(
      'appearance-settings',
      '{"style":"embers","textScale":1.1}',
    );
    await appearance.load();
    expect(appearance.style, AppStyle.embers);
    expect(appearance.darkStyle, AppStyle.embers);
    expect(appearance.lightStyle, AppStyle.fallbackLight);
    await repo.setMeta(
      'appearance-settings',
      '{"textScale":"invalid","style":"missing"}',
    );
    await appearance.load();
    expect(appearance.style, AppStyle.fallback);
    expect(appearance.textScale, 1);
  });
  testWidgets(
    'settings and every palette fit a narrow phone at increased text size',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = AppDatabase(NativeDatabase.memory()),
          repo = Repository(db),
          client = MockClient((_) async => throw StateError('offline'));
      final library = LibraryService(repo, client), appearance = AppTheme(repo);
      await tester.pumpWidget(
        ListenableBuilder(
          listenable: appearance,
          builder: (context, _) => ThemeScope(
            controller: appearance,
            child: MaterialApp(
              theme: AppTheme.data(Brightness.dark, style: appearance.style),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(1.4)),
                child: child!,
              ),
              home: SettingsPage(library: library),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-entry:interface')));
      await tester.pumpAndSettle();
      for (final style in AppStyle.values) {
        await tester.ensureVisible(find.text(style.label));
        await tester.pumpAndSettle();
        await tester.tap(find.text(style.label));
        await tester.pumpAndSettle();
        expect(appearance.style, style);
        expect(tester.takeException(), isNull);
        final context = tester.element(find.byType(SettingsPage));
        expect(ShelfPalette.of(context).accent, Color(style.accent));
      }
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-entry:sync')), findsNothing);
      await tester.ensureVisible(
        find.byKey(const ValueKey('settings-entry:data')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('settings-entry:data')));
      await tester.pumpAndSettle();
      expect(find.text('Папка библиотеки'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Создать резервную копию'),
        200,
        scrollable: find
            .descendant(
              of: find.byType(LibraryDataPage),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      appearance.dispose();
      library.dispose();
      client.close();
      await db.close();
    },
  );
}
