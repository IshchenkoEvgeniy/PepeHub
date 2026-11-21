import 'package:flutter/material.dart' show Color;

/// Starter species of the MVP. Models: `assets/pets/<id>_<stage>.glb`.
enum PetSpecies {
  cat('Кошка', 'Спокойная и любопытная'),
  fox('Лиса', 'Быстрая и хитрая'),
  dragon('Дракончик', 'Маленький, но гордый');

  final String label, motto;
  const PetSpecies(this.label, this.motto);

  static PetSpecies? byId(String id) =>
      values.where((s) => s.name == id).firstOrNull;
}

enum ShopKind { food, color, decor, accessory, freeze, upgrade }

extension ShopKindLabel on ShopKind {
  String get label => switch (this) {
    ShopKind.food => 'Еда',
    ShopKind.color => 'Окрасы',
    ShopKind.decor => 'Декор комнаты',
    ShopKind.accessory => 'Аксессуары',
    ShopKind.freeze => 'Серия дней',
    ShopKind.upgrade => 'Инкубатор',
  };

  /// Food and freezes are spent; everything else is bought once.
  bool get consumable => this == ShopKind.food || this == ShopKind.freeze;
}

/// Accessory sockets shared by every model (bones `Socket_*`).
enum PetSocket { head, face, neck, back }

class ShopItem {
  final String id, title, description;
  final ShopKind kind;
  final int price;

  /// Food: hours of satiety it restores (24 = full).
  final int satietyHours;

  /// Food: plays the happy clip after eating.
  final bool treat;

  /// Colors: body tint.
  final Color? tint;

  /// Accessories: socket and model.
  final PetSocket? socket;
  final String? model;

  /// Not sold: unlocked by an achievement.
  final bool rewardOnly;
  const ShopItem({
    required this.id,
    required this.title,
    required this.description,
    required this.kind,
    required this.price,
    this.satietyHours = 0,
    this.treat = false,
    this.tint,
    this.socket,
    this.model,
    this.rewardOnly = false,
  });

  /// Node name of a decor item inside `room_bedroom.glb`.
  String get decorNode => 'Decor_${id.substring('decor_'.length)}';
}

/// The permanent shop (no «today only» offers). Prices follow the concept:
/// food 10–40, colors 500–1500, decor 100–1500, accessories 150–600.
const shopItems = <ShopItem>[
  ShopItem(
    id: 'food_kibble',
    title: 'Корм',
    description: 'Обычная еда на полдня.',
    kind: ShopKind.food,
    price: 10,
    satietyHours: 12,
  ),
  ShopItem(
    id: 'food_fish',
    title: 'Рыбка',
    description: 'Сытно: хватит на сутки.',
    kind: ShopKind.food,
    price: 20,
    satietyHours: 24,
  ),
  ShopItem(
    id: 'food_berries',
    title: 'Ягоды',
    description: 'Сутки сытости и хорошее настроение.',
    kind: ShopKind.food,
    price: 25,
    satietyHours: 24,
    treat: true,
  ),
  ShopItem(
    id: 'food_cake',
    title: 'Пирожное',
    description: 'Праздничное угощение: сутки сытости и радость.',
    kind: ShopKind.food,
    price: 40,
    satietyHours: 24,
    treat: true,
  ),
  ShopItem(
    id: 'color_midnight',
    title: 'Полночь',
    description: 'Тёмный окрас для любого питомца.',
    kind: ShopKind.color,
    price: 600,
    tint: Color(0xFF3A3A50),
  ),
  ShopItem(
    id: 'color_snow',
    title: 'Снежный',
    description: 'Светлый, почти белый окрас.',
    kind: ShopKind.color,
    price: 800,
    tint: Color(0xFFF4F1EC),
  ),
  ShopItem(
    id: 'color_mint',
    title: 'Мятный',
    description: 'Редкий мятный окрас.',
    kind: ShopKind.color,
    price: 1200,
    tint: Color(0xFF8ED1B8),
  ),
  ShopItem(
    id: 'decor_book_stack',
    title: 'Стопка книг',
    description: 'Прочитанное — у кровати.',
    kind: ShopKind.decor,
    price: 150,
  ),
  ShopItem(
    id: 'decor_moon_lamp',
    title: 'Ночник-луна',
    description: 'Тёплый свет на подоконнике.',
    kind: ShopKind.decor,
    price: 400,
  ),
  ShopItem(
    id: 'decor_globe',
    title: 'Глобус',
    description: 'Для тех, кто путешествует по книгам.',
    kind: ShopKind.decor,
    price: 700,
  ),
  ShopItem(
    id: 'decor_aquarium',
    title: 'Аквариум',
    description: 'Три рыбки и водоросль.',
    kind: ShopKind.decor,
    price: 1500,
  ),
  ShopItem(
    id: 'acc_scarf',
    title: 'Шарф',
    description: 'Красный шарф в полоску.',
    kind: ShopKind.accessory,
    price: 250,
    socket: PetSocket.neck,
    model: 'assets/pets/acc_scarf.glb',
  ),
  ShopItem(
    id: 'acc_beanie',
    title: 'Шапочка',
    description: 'Голубая шапочка с помпоном.',
    kind: ShopKind.accessory,
    price: 400,
    socket: PetSocket.head,
    model: 'assets/pets/acc_beanie.glb',
  ),
  ShopItem(
    id: 'incubator_slot',
    title: 'Второй слот инкубатора',
    description: 'Высиживать два яйца одновременно.',
    kind: ShopKind.upgrade,
    price: 3000,
  ),
  // Achievement rewards: never sold.
  ShopItem(
    id: 'color_amber',
    title: 'Янтарный',
    description: 'За 10 книг дня.',
    kind: ShopKind.color,
    price: 0,
    tint: Color(0xFFE0A040),
    rewardOnly: true,
  ),
  ShopItem(
    id: 'color_sunset',
    title: 'Закат',
    description: 'За серию 30 дней.',
    kind: ShopKind.color,
    price: 0,
    tint: Color(0xFFE07A6A),
    rewardOnly: true,
  ),
  ShopItem(
    id: 'color_aurora',
    title: 'Сияние',
    description: 'За 100 часов чтения.',
    kind: ShopKind.color,
    price: 0,
    tint: Color(0xFF7FA8E8),
    rewardOnly: true,
  ),
  ShopItem(
    id: 'acc_glasses',
    title: 'Очки для чтения',
    description: 'За 10 часов чтения.',
    kind: ShopKind.accessory,
    price: 0,
    socket: PetSocket.face,
    model: 'assets/pets/acc_glasses.glb',
    rewardOnly: true,
  ),
  ShopItem(
    id: 'freeze',
    title: 'Заморозка серии',
    description:
        'Сохранит серию в пропущенный день. В запасе — не больше двух.',
    kind: ShopKind.freeze,
    price: 300,
  ),
];

ShopItem? shopItem(String id) => shopItems.where((i) => i.id == id).firstOrNull;
