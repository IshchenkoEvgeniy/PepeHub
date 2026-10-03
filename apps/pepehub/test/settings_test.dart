import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/library/library_service.dart';
import 'package:pepehub/ui/app_theme.dart';
import 'package:pepehub/ui/settings_page.dart';
import 'package:pepehub/ui/shelf_components.dart';

void main() {
  test('ten distinct styles, appearance and accessibility preferences persist across restart', () async {
    final db = AppDatabase(NativeDatabase.memory()), repo = Repository(db);
    addTearDown(db.close);
    final appearance = AppTheme(repo);
    addTearDown(appearance.dispose);
    expect(AppStyle.values.length, 10);
    expect(
      AppStyle.values
          .map(
            (s) => AppTheme.data(Brightness.dark, style: s).colorScheme.primary,
          )
          .toSet()
          .length,
      10,
    );
    for (final style in AppStyle.values) {
      await appearance.preferences(
        style: style,
        textScale: 1.3,
        compact: true,
        reduceMotion: true,
      );
      await appearance.set(ThemeMode.light);
      final restored = AppTheme(repo);
      await restored.load();
      expect(restored.style, style);
      expect(restored.mode, ThemeMode.light);
      expect(restored.textScale, 1.3);
      expect(restored.compact, true);
      expect(restored.reduceMotion, true);
      restored.dispose();
    }
    await repo.setMeta(
      'appearance-settings',
      '{"textScale":"invalid","style":"missing"}',
    );
    await appearance.load();
    expect(appearance.style, AppStyle.shelf);
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
              home: SettingsPage(
                library: library,
                onConnection: () async {},
                onJournal: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final style in AppStyle.values) {
        await tester.ensureVisible(find.text(style.label));
        await tester.tap(find.text(style.label));
        await tester.pumpAndSettle();
        expect(appearance.style, style);
        expect(tester.takeException(), isNull);
        final context = tester.element(find.byType(SettingsPage));
        expect(ShelfPalette.of(context).accent, Color(style.accent));
      }
      await tester.scrollUntilVisible(
        find.text('Синхронизировать сейчас'),
        400,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      appearance.dispose();
      library.dispose();
      client.close();
      await db.close();
    },
  );
}
