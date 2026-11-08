import 'package:flutter/material.dart';

import 'settings_components.dart';

/// Keyboard shortcuts as bound in the library, readers and video player.
/// Keep this list in step with the `SingleActivator` bindings of those screens.
const hotkeyGroups = <(String, List<(String, String)>)>[
  ('Библиотека, списки и настройки', [('Ctrl + K', 'Поиск')]),
  (
    'Читалка',
    [
      ('→  ·  PageDown  ·  Пробел', 'Следующая страница'),
      ('←  ·  PageUp  ·  Shift + Пробел', 'Предыдущая страница'),
      ('↓  ·  ↑', 'На строку вниз / вверх'),
      ('Home  ·  End', 'Начало / конец книги'),
      ('Ctrl + F', 'Поиск по книге'),
      ('F3  ·  Shift + F3', 'Следующее / предыдущее совпадение'),
      ('Ctrl + D', 'Быстрая закладка'),
      ('Ctrl + B', 'Список закладок'),
      ('Ctrl + =  ·  Ctrl + −', 'Крупнее / мельче шрифт'),
      ('F11  ·  Esc', 'Полный экран / выход из него'),
    ],
  ),
  (
    'PDF',
    [
      ('PageDown  ·  Пробел', 'Следующая страница'),
      ('PageUp  ·  Shift + Пробел', 'Предыдущая страница'),
      ('Home  ·  End', 'Первая / последняя страница'),
      ('Ctrl + F', 'Поиск'),
      ('Ctrl + D', 'Заметка к странице'),
      ('Ctrl + =  ·  Ctrl + −', 'Масштаб'),
      ('F11  ·  Esc', 'Полный экран / выход из него'),
    ],
  ),
  (
    'Видео',
    [
      ('Пробел  ·  K', 'Пауза / воспроизведение'),
      ('←  ·  J   /   →  ·  L', 'Назад / вперёд на 10 с'),
      ('Shift + ←  ·  Shift + →', 'Назад / вперёд на 1 с'),
      ('↑  ·  ↓', 'Громкость'),
      ('M', 'Без звука'),
      ('F', 'Полный экран'),
      ('Shift + <  ·  Shift + >', 'Медленнее / быстрее'),
      ('Ctrl + G', 'Перейти ко времени'),
      ('Ctrl + B', 'Закладка / заметка'),
      ('Ctrl + R', 'Повтор A–B'),
      ('Ctrl + S', 'Субтитры'),
      ('Alt + ←', 'Вернуться к месту до перемотки'),
      ('Esc', 'Назад'),
    ],
  ),
];

class HotkeysSettings extends StatelessWidget {
  const HotkeysSettings({super.key});
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SettingsHeading(
        'Горячие клавиши',
        'Работают на ПК и с подключённой клавиатурой. На Android в читалке можно листать кнопками громкости — включается в настройках читалки.',
      ),
      for (final (group, keys) in hotkeyGroups) ...[
        SettingsSubheading(group),
        SettingsGroup(
          children: [
            for (final (shortcut, action) in keys)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: Text(action)),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        shortcut,
                        textAlign: TextAlign.end,
                        style: const TextStyle(
                          fontFeatures: [FontFeature.tabularFigures()],
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    ],
  );
}
