import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pepehub/data/database.dart';
import 'package:pepehub/data/repository.dart';
import 'package:pepehub/pets/pet_catalog.dart';
import 'package:pepehub/pets/pet_progress.dart';
import 'package:pepehub/pets/pets_service.dart';
import 'package:pepehub/pets/ui/pet_scene.dart';
import 'package:pepehub/pets/ui/pets_section.dart';
import 'package:flutter/rendering.dart';
import 'package:pepehub/ui/app_theme.dart';
import 'package:pepehub/ui/shelf_components.dart';

/// Flutter GPU is not available in tests: the 3D room is a placeholder.
Widget _fakeScene(BuildContext _, PetSceneArgs a) => ColoredBox(
  color: Colors.black12,
  child: Center(
    child: Text('scene:${a.pet.species}:${a.owned.length}:${a.room.key}'),
  ),
);

Future<void> _settle(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 300 && !done(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  await tester.pump();
}

bool _has(Finder f) => f.evaluate().isNotEmpty;

Finder _balance(String value) => find.descendant(
  of: find.byKey(const ValueKey('pets-balance')),
  matching: find.text(value),
);

/// Closes «Пока вас не было» when it is on screen.
Future<void> _takeReward(WidgetTester tester) async {
  await _settle(tester, () => _has(find.byKey(const ValueKey('reward-take'))));
  if (_has(find.byKey(const ValueKey('reward-take')))) {
    await tester.tap(find.byKey(const ValueKey('reward-take')));
    await tester.pumpAndSettle();
  }
}

void main() {
  late AppDatabase db;
  late Repository repo;
  final now = DateTime(2026, 11, 20, 12);
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    repo = Repository(db);
    PepeNavLayout.current.value = PepeNavLayout.defaults();
  });
  tearDown(() => db.close());

  Widget app({DateTime Function()? clock}) => MaterialApp(
    home: PetsSection(
      repository: repo,
      clock: clock ?? () => now,
      sceneBuilder: _fakeScene,
      navigation: ShelfNavigation(
        current: PepeSection.pets,
        onSelect: (_) {},
        onSettings: () {},
      ),
    ),
  );

  testWidgets('starter, reward card, shop, kitchen and journal', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app());
    await _settle(tester, () => _has(find.text('Выберите первого питомца')));
    expect(find.text('Лиса'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('starter-fox')));
    await _settle(tester, () => _has(find.text('scene:fox:0:living')));
    expect(_balance('0'), findsOneWidget);
    expect(find.byKey(const ValueKey('room-title')), findsOneWidget);

    // Nothing is affordable without coins.
    await tester.tap(find.byKey(const ValueKey('dock-shop')));
    await tester.pumpAndSettle();
    final kibble = find.descendant(
      of: find.byKey(const ValueKey('shop-food_kibble')),
      matching: find.byType(FilledButton),
    );
    expect(tester.widget<FilledButton>(kibble).onPressed, isNull);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    // An hour of (test) reading; returning to the app recounts and shows
    // «while you were away».
    await tester.runAsync(() async {
      final service = PetsService(repo, clock: () => now);
      await service.addTestMinutes(60);
    });
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _settle(tester, () => _has(find.text('Пока вас не было')));
    expect(find.text('60 мин'), findsOneWidget);
    await _takeReward(tester);
    await _settle(tester, () => _has(_balance('60')));

    await tester.tap(find.byKey(const ValueKey('dock-shop')));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(kibble).onPressed, isNotNull);
    await tester.tap(kibble);
    await _settle(tester, () => _has(find.text('Куплено: Корм')));
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await _settle(tester, () => _has(_balance('50')));

    // The kitchen tray feeds with one tap.
    await tester.tap(find.byKey(const ValueKey('dock-food')));
    await tester.pumpAndSettle();
    expect(find.text('scene:fox:0:kitchen'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('food-food_kibble')),
        matching: find.text('×1'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('food-food_kibble')));
    await _settle(
      tester,
      () => _has(
        find.descendant(
          of: find.byKey(const ValueKey('food-food_kibble')),
          matching: find.text('+'),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('side-journal')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Журнал'));
    await tester.pumpAndSettle();
    await _settle(tester, () => _has(find.text('Покупка: Корм')));
    expect(find.text('-10'), findsOneWidget);
    expect(find.textContaining('Чтение и прослушивание'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('developer panel grants coins and items', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final service = PetsService(repo, clock: () => now);
      await service.enable(species: PetSpecies.cat);
      await service.setDevEnabled(true);
    });
    await tester.pumpWidget(app());
    await _settle(tester, () => _has(find.text('scene:cat:0:living')));
    await tester.tap(find.byKey(const ValueKey('pets-dev')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('dev-coins-1000')));
    await _settle(tester, () => _has(_balance('1000')));
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('dev-items')),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.byKey(const ValueKey('dev-items')));
    await _settle(tester, () => _has(find.text('Все предметы открыты')));
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    // Owned decor reaches the scene.
    expect(find.textContaining('scene:cat:'), findsOneWidget);
    expect(find.text('scene:cat:0:living'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone, dark app theme: no app bar, sections button, readable '
      'sheets', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await PetsService(repo, clock: () => now).enable(species: PetSpecies.cat);
    });
    PepeSection? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.data(Brightness.dark, style: AppStyle.fallback),
        home: PetsSection(
          repository: repo,
          clock: () => now,
          sceneBuilder: _fakeScene,
          navigation: ShelfNavigation(
            current: PepeSection.pets,
            onSelect: (s) => selected = s,
            onSettings: () {},
          ),
        ),
      ),
    );
    await _settle(tester, () => _has(find.text('scene:cat:0:living')));
    // The room takes the whole screen: no bottom bar of the app.
    expect(find.byType(ShelfBottomBar), findsNothing);
    expect(find.byKey(const ValueKey('dock-shop')), findsOneWidget);

    // Text in the cream sheets is dark even in a dark app theme.
    await tester.tap(find.byKey(const ValueKey('side-pets')));
    await tester.pumpAndSettle();
    final level = tester.renderObject<RenderParagraph>(find.text('Уровень'));
    expect(level.text.style?.color, PetsLook.ink);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    // The sections button leads to the other sections.
    await tester.tap(find.byKey(const ValueKey('side-sections')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-more:books')));
    await tester.pumpAndSettle();
    expect(selected, PepeSection.books);
    expect(tester.takeException(), isNull);
  });
  testWidgets('bottom bar: what does not fit goes behind «Ещё»', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    PepeSection? selected;
    PepeNavItem? opened;
    final navigation = ShelfNavigation(
      current: PepeSection.books,
      onSelect: (s) => selected = s,
      onSettings: () {},
      onOpen: (item) => opened = item,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: ShelfBottomBar(navigation: navigation),
        ),
      ),
    );
    // 360 px holds five buttons: four sections and «Ещё».
    expect(find.byKey(const ValueKey('nav:books')), findsOneWidget);
    expect(find.byKey(const ValueKey('nav:statistics')), findsNothing);
    expect(find.byKey(const ValueKey('nav:more')), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'no overflow at 360 px');
    await tester.tap(find.byKey(const ValueKey('nav:more')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-more:pets')));
    await tester.pumpAndSettle();
    expect(selected, PepeSection.pets);

    // A page entry moved into the bar opens its page.
    PepeNavLayout.current.value = PepeNavLayout(
      [PepeNavItem.notes, ...PepeNavItem.values],
      {PepeNavItem.notes, PepeNavItem.books, PepeNavItem.audio},
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('nav:pets')), findsNothing);
    final bar = tester.getTopLeft(find.byKey(const ValueKey('nav:notes')));
    expect(bar.dx, lessThan(tester.getTopLeft(find.text('Книги')).dx));
    await tester.tap(find.byKey(const ValueKey('nav:notes')));
    expect(opened, PepeNavItem.notes);
  });

  test('navigation layout survives storage and unknown entries', () async {
    final layout = PepeNavLayout(
      [PepeNavItem.statistics, PepeNavItem.books],
      {PepeNavItem.statistics, PepeNavItem.vocabulary},
    );
    expect(layout.order.length, PepeNavItem.values.length);
    expect(layout.bar, [PepeNavItem.statistics, PepeNavItem.vocabulary]);
    final restored = PepeNavLayout.fromJson({
      ...layout.toJson(),
      'order': ['future-section', ...layout.toJson()['order']! as List],
    });
    expect(restored, layout);
    // «Питомник» hidden in an earlier version starts behind «Ещё».
    await PepeNavLayout.load(repo);
    expect(PepeNavLayout.current.value.bar, contains(PepeNavItem.pets));
    await repo.setMeta('pets-section-hidden', '1');
    await PepeNavLayout.load(repo);
    expect(PepeNavLayout.current.value.more, contains(PepeNavItem.pets));
    await PepeNavLayout.save(layout);
    PepeNavLayout.current.value = PepeNavLayout.defaults();
    await PepeNavLayout.load(repo);
    expect(PepeNavLayout.current.value, layout);
  });

  testWidgets('incubator, path, talents and achievements', (tester) async {
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var day = now;
    await tester.runAsync(() async {
      final service = PetsService(repo, clock: () => day);
      await service.enable(species: PetSpecies.cat);
      // 14 days of 4 hours: level 25+, coins for an egg.
      for (var i = 0; i < 14; i++) {
        await service.addTestMinutes(240);
        await service.sync();
        day = day.add(const Duration(days: 1));
      }
    });
    await tester.pumpWidget(app(clock: () => day));
    await _settle(tester, () => _has(find.text('scene:cat:0:living')));
    await _takeReward(tester);

    await tester.tap(find.byKey(const ValueKey('side-pets')));
    await tester.pumpAndSettle();
    expect(find.text('Питомцы •'), findsOneWidget, reason: 'path pending');

    await tester.tap(find.text('Инкубатор'));
    await tester.pumpAndSettle();
    expect(find.text('Свободный слот'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('offer-fox')),
        matching: find.byType(FilledButton),
      ),
    );
    await _settle(tester, () => _has(find.text('0:00 из 10:00')));
    expect(find.text('Свободный слот'), findsNothing);

    await tester.tap(find.text('Питомцы •'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('path-catBookish')), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('path-catBookish')),
        matching: find.byType(FilledButton),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Выбрать').last);
    await _settle(tester, () => _has(find.textContaining('Книжная:')));
    await tester.tap(find.byKey(const ValueKey('talent-greet')));
    await _settle(
      tester,
      () => !_has(find.byKey(const ValueKey('talent-greet'))),
    );
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('side-achievements')));
    await tester.pumpAndSettle();
    expect(find.text('Неделя чтения'), findsOneWidget, reason: 'honor chip');
    await tester.scrollUntilVisible(
      find.text('Свой путь'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('Свой путь'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('every model, room, decor and icon the screen may load is bundled', () {
    final assets = <String>{
      for (final s in PetSpecies.values) ...[
        for (final level in [1, 10, 25, 45, 70, 90, 100])
          for (final path in [null, ...PetPath.of(s.name).map((p) => p.name)])
            PetGrowth.modelAsset(s.name, level, path),
        eggIcon(s.name),
      ],
      for (final i in shopItems) ...[
        i.icon,
        if (i.model != null) i.model!,
        if (i.kind == ShopKind.decor) i.decorModel,
      ],
      'assets/pets/fx_rank.glb',
      'assets/pets/rooms/rooms.json',
      'assets/pets/rooms/shadow.png',
    };
    final rooms = jsonDecode(
      File('assets/pets/rooms/rooms.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final spots = <String>{};
    for (final r in (rooms['rooms'] as Map<String, dynamic>).values) {
      final room = r as Map<String, dynamic>;
      assets.add(room['background'] as String);
      if (room['foreground'] != null) assets.add(room['foreground'] as String);
      for (final d in room['decor'] as List) {
        spots.add((d as Map)['id'] as String);
      }
    }
    for (final a in assets) {
      expect(File(a).existsSync(), isTrue, reason: a);
    }
    // Every decor item of the shop has a home in some room.
    expect(
      spots,
      containsAll(
        shopItems.where((i) => i.kind == ShopKind.decor).map((i) => i.id),
      ),
    );
  });
}
