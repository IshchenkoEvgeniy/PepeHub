import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/pets/pet_catalog.dart';
import 'package:pepehub/pets/pets_service.dart';
import 'package:pepehub/pets/ui/pets_section.dart';
import 'package:pepehub/ui/shelf_components.dart';

/// Flutter GPU is not available in tests: the 3D home is a placeholder.
Widget _fakeScene(BuildContext _, Pet pet, Set<String> owned, Object _) =>
    ColoredBox(
      color: Colors.black12,
      child: Center(child: Text('scene:${pet.species}:${owned.length}')),
    );

Future<void> _settle(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  await tester.pump();
}

void main() {
  late AppDatabase db;
  late Repository repo;
  final now = DateTime(2026, 11, 20, 12);
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = Repository(db);
    PepeSection.hidden.value = {};
  });
  tearDown(() => db.close());

  Widget app() => MaterialApp(
    home: PetsSection(
      repository: repo,
      clock: () => now,
      sceneBuilder: (c, p, o, s) => _fakeScene(c, p, o, s),
      navigation: ShelfNavigation(
        current: PepeSection.pets,
        onSelect: (_) {},
        onSettings: () {},
      ),
    ),
  );

  testWidgets('starter choice, shop and journal', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app());
    await _settle(
      tester,
      () => find.text('Выберите первого питомца').evaluate().isNotEmpty,
    );
    expect(find.text('Лиса'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('starter-fox')));
    await _settle(tester, () => find.text('scene:fox:0').evaluate().isNotEmpty);
    expect(find.text('0 монет'), findsOneWidget);
    expect(find.text('Еды нет — загляните в магазин'), findsOneWidget);

    // Nothing is affordable without coins.
    await tester.tap(find.text('Магазин'));
    await tester.pumpAndSettle();
    final kibble = find.descendant(
      of: find.byKey(const ValueKey('shop-food_kibble')),
      matching: find.byType(FilledButton),
    );
    expect(tester.widget<FilledButton>(kibble).onPressed, isNull);

    // Earn an hour (test minutes) and buy food; it appears on the home tray.
    await tester.runAsync(() async {
      final service = PetsService(repo, clock: () => now);
      await service.addTestMinutes(60);
    });
    // Returning to the app recounts.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _settle(tester, () => find.text('60 монет').evaluate().isNotEmpty);
    expect(find.text('60 монет'), findsOneWidget);
    expect(tester.widget<FilledButton>(kibble).onPressed, isNotNull);
    await tester.tap(kibble);
    await _settle(tester, () => find.text('50 монет').evaluate().isNotEmpty);

    await tester.tap(find.text('Дом'));
    await tester.pumpAndSettle();
    expect(find.text('Корм ×1'), findsOneWidget);

    await tester.tap(find.text('Журнал'));
    await tester.pumpAndSettle();
    await _settle(
      tester,
      () => find.text('Покупка: Корм').evaluate().isNotEmpty,
    );
    expect(find.text('-10'), findsOneWidget);
    expect(find.textContaining('Чтение и прослушивание'), findsOneWidget);
  });

  testWidgets('hidden section leaves the bottom bar; 7 items fit 360 px', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final navigation = ShelfNavigation(
      current: PepeSection.books,
      onSelect: (_) {},
      onSettings: () {},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: ShelfBottomBar(navigation: navigation),
        ),
      ),
    );
    expect(find.text('Питомник'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'no overflow at 360 px');
    PepeSection.hidden.value = {PepeSection.pets};
    await tester.pump();
    expect(find.text('Питомник'), findsNothing);
    expect(find.text('Статистика'), findsOneWidget);
    PepeSection.hidden.value = {};
  });

  test('every decor item has a node name in the room', () {
    expect(
      shopItems.where((i) => i.kind == ShopKind.decor).map((i) => i.decorNode),
      ['Decor_book_stack', 'Decor_moon_lamp', 'Decor_globe', 'Decor_aquarium'],
    );
  });
}
