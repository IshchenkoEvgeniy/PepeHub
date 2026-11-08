import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/repository.dart';
import '../media/asset_store.dart';
import '../updates/update_service.dart';
import 'settings_components.dart';
import '../diagnostics/error_log.dart';
import '../diagnostics/user_message.dart';

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
  static Future<void> reset(Repository repository) =>
      repository.setMeta('startup-section', 'last');
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
      if (mounted) setState(() => error = describeError(e));
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
      if (mounted) {
        setState(() => error = 'Изменение не сохранено: ${describeError(e)}');
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => SettingsDropdownTile<String>(
    key: const ValueKey('startup-section'),
    title: 'Начальная вкладка',
    subtitle: error ?? 'Открывается при запуске приложения',
    value: value,
    items: startupSections.keys.toList(),
    label: (key) => startupSections[key]!,
    onChanged: saving ? null : _save,
  );
}

/// Where PepeHub keeps its data, plus a copyable diagnostic summary.
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
      if (mounted) {
        setState(
          () => error = 'Не удалось прочитать путь базы: ${describeError(e)}',
        );
      }
    }
  }

  Future<void> _copy() async {
    final info = UpdateScope.of(context)?.app;
    final log = await ErrorLog.read().catchError((_) => '');
    final recent = log
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList()
        .reversed
        .take(40)
        .toList()
        .reversed
        .join('\n');
    final text = [
      'PepeHub ${info?.version ?? '—'} (${info?.versionCode ?? '—'}) · ${info?.platform ?? Platform.operatingSystem}',
      'ОС: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'База данных: ${databasePath ?? error ?? '—'}',
      'Хранилище: ${widget.assets?.directory.path ?? '—'}',
      if (recent.isNotEmpty) ...[
        '',
        'Последние записи журнала ошибок:',
        recent,
      ],
    ].join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сведения для отладки скопированы')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SettingsSubheading('Расположение данных'),
      SettingsGroup(
        children: [
          ListTile(
            title: const Text('База данных'),
            subtitle: SelectableText(
              databasePath ?? error ?? 'Определяем расположение…',
            ),
          ),
          ListTile(
            title: const Text('Локальное хранилище файлов'),
            subtitle: SelectableText(
              widget.assets?.directory.path ?? 'Хранилище файлов не подключено',
            ),
          ),
        ],
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          key: const ValueKey('about-copy-debug'),
          onPressed: _copy,
          icon: const Icon(Icons.copy_all_outlined),
          label: const Text('Скопировать сведения для отладки'),
        ),
      ),
      const SizedBox(height: 8),
      Text(
        'Версия, система, пути и последние ошибки — чтобы приложить к сообщению о проблеме. Перед отправкой просмотрите текст: в путях бывают названия книг.',
        style: TextStyle(color: Theme.of(context).hintColor),
      ),
    ],
  );
}
