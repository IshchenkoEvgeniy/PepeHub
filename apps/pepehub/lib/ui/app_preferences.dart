import 'package:flutter/material.dart';

import '../data/repository.dart';
import '../media/asset_store.dart';
import '../updates/update_service.dart';
import 'settings_components.dart';

const startupSections = {
  'last': 'Последняя открытая вкладка',
  'metadata': 'Библиотека',
  'reading': 'Книги',
  'audio': 'Аудиокниги',
  'recommendations': 'Рекомендации',
  'statistics': 'Статистика',
  'video': 'Видео',
};

Future<String?> startupSection(Repository repository) async {
  final preferred = await repository.meta('startup-section');
  return preferred != null &&
          preferred != 'last' &&
          startupSections.containsKey(preferred)
      ? preferred
      : repository.meta('library-section');
}

class StartupSettings extends StatefulWidget {
  final Repository repository;
  const StartupSettings({super.key, required this.repository});
  @override
  State<StartupSettings> createState() => _StartupSettingsState();
}

class _StartupSettingsState extends State<StartupSettings> {
  String? value, error;
  bool saving = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final saved = await widget.repository.meta('startup-section');
      if (mounted) {
        setState(
          () => value = startupSections.containsKey(saved) ? saved : 'last',
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  Future<void> _save(String next) async {
    setState(() => saving = true);
    try {
      await widget.repository.setMeta('startup-section', next);
      if (mounted) {
        setState(() {
          value = next;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = 'Изменение не сохранено: $e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SettingsHeading(
        'Запуск приложения',
        'Выбранная вкладка откроется при следующем запуске.',
      ),
      if (error != null) SettingsNotice(error!),
      if (value == null && error == null)
        const Center(child: CircularProgressIndicator()),
      if (value != null)
        DropdownButtonFormField<String>(
          key: ValueKey(value),
          initialValue: value,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Начальная вкладка'),
          items: [
            for (final entry in startupSections.entries)
              DropdownMenuItem(value: entry.key, child: Text(entry.value)),
          ],
          onChanged: saving
              ? null
              : (next) {
                  if (next != null) _save(next);
                },
        ),
    ],
  );
}

class AboutAppSettings extends StatefulWidget {
  final Repository repository;
  final AssetStore? assets;
  const AboutAppSettings({super.key, required this.repository, this.assets});
  @override
  State<AboutAppSettings> createState() => _AboutAppSettingsState();
}

class _AboutAppSettingsState extends State<AboutAppSettings> {
  String? databasePath, error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await widget.repository.db
          .customSelect('PRAGMA database_list')
          .get();
      final main = rows
          .where((row) => row.read<String>('name') == 'main')
          .first;
      final path = main.read<String>('file');
      if (mounted) {
        setState(() => databasePath = path.isEmpty ? 'База в памяти' : path);
      }
    } catch (e) {
      if (mounted) setState(() => error = 'Не удалось прочитать путь базы: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final updates = UpdateScope.of(context);
    final info = updates?.app;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsHeading(
          'О приложении',
          'PepeHub — личная библиотека, читалка и журнал чтения и прослушивания.',
        ),
        SelectableText(
          info == null
              ? 'Версия недоступна в этой сборке'
              : 'Версия ${info.version} (${info.versionCode}) · ${info.platform}',
        ),
        const SizedBox(height: 24),
        Text('База данных', style: Theme.of(context).textTheme.titleMedium),
        SelectableText(databasePath ?? error ?? 'Определяем расположение…'),
        const SizedBox(height: 20),
        Text(
          'Локальное хранилище файлов',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        SelectableText(
          widget.assets?.directory.path ?? 'Хранилище файлов не подключено',
        ),
        const SizedBox(height: 20),
        const SettingsNotice(
          'Подключённые папки книг и аудиокниг могут находиться отдельно. Их пути доступны в разделе «Файлы и библиотека». Экспорт и резервные копии сохраняются в выбранное вами место.',
        ),
      ],
    );
  }
}
