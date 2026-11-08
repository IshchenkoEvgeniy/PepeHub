import 'package:flutter/material.dart';

import '../media/asset_store.dart';
import '../media/storage_usage.dart';
import 'settings_components.dart';
import '../diagnostics/error_log.dart';
import '../diagnostics/user_message.dart';

String storageBytes(int bytes) => bytes < 1024
    ? '$bytes Б'
    : bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} КБ'
    : bytes < 1024 * 1024 * 1024
    ? '${(bytes / 1048576).toStringAsFixed(1)} МБ'
    : '${(bytes / 1073741824).toStringAsFixed(2)} ГБ';

class StorageSettingsPage extends StatefulWidget {
  final AssetStore? assets;
  final bool embedded;
  const StorageSettingsPage({super.key, this.assets, this.embedded = false});
  @override
  State<StorageSettingsPage> createState() => _StorageSettingsPageState();
}

class _StorageSettingsPageState extends State<StorageSettingsPage> {
  ({int total, int temporary, int covers})? usage;
  int indexBytes = 0, databaseBytes = 0, freeBytes = 0, logBytes = 0;
  String? error, result;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure({bool preserveError = false}) async {
    if (widget.assets == null) return;
    setState(() {
      busy = true;
      if (!preserveError) error = null;
    });
    try {
      final store = widget.assets!;
      final measured = await StorageUsage(store.directory).measure();
      final row = await store.repository.db
          .customSelect(
            "SELECT COALESCE(SUM(length(CAST(value AS BLOB))),0) AS bytes FROM metadata WHERE key >= 'reading-index:' AND key < 'reading-index;' OR key >= 'reading-pdf-index-partial:' AND key < 'reading-pdf-index-partial;'",
          )
          .getSingle();
      final pages = await store.repository.db
          .customSelect(
            'SELECT (SELECT page_count FROM pragma_page_count()) AS pages, (SELECT freelist_count FROM pragma_freelist_count()) AS free, (SELECT page_size FROM pragma_page_size()) AS size',
          )
          .getSingle();
      final logs = await ErrorLog.size();
      if (mounted) {
        setState(() {
          usage = measured;
          indexBytes = row.read<int>('bytes');
          final size = pages.read<int>('size');
          databaseBytes = pages.read<int>('pages') * size;
          freeBytes = pages.read<int>('free') * size;
          logBytes = logs;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => error = 'Не удалось измерить хранилище: ${describeError(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _clear() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Очистить временные копии?'),
        content: const Text(
          'Закройте открытые книги. Временные копии книг и PDF будут удалены. При следующем открытии потребуется доступ к исходной папке. Карточки, история, цитаты, обложки и оригиналы сохранятся.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Очистить'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    setState(() {
      busy = true;
      error = null;
      result = null;
    });
    try {
      final bytes = await StorageUsage(widget.assets!.directory)
          .clearTemporaryCopies();
      PaintingBinding.instance.imageCache.clear();
      if (mounted) {
        setState(
          () => result =
              'Освобождено ${storageBytes(bytes)}. Кэш изображений в памяти очищен.',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () =>
              error = 'Не удалось полностью очистить кэш: ${describeError(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
    await _measure(preserveError: true);
  }

  Future<bool> _confirm(String title, String text, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ==
      true;

  Future<void> _task(Future<String> Function() action, String failure) async {
    setState(() {
      busy = true;
      error = null;
      result = null;
    });
    try {
      final message = await action();
      if (mounted) setState(() => result = message);
    } catch (e) {
      if (mounted) setState(() => error = '$failure: ${describeError(e)}');
    } finally {
      if (mounted) setState(() => busy = false);
    }
    await _measure(preserveError: true);
  }

  Future<void> _compact() async {
    if (!await _confirm(
      'Сжать базу данных?',
      'Освобождённое место внутри базы вернётся системе. Это может занять до минуты; приложение на это время может притормаживать. Данные не меняются.',
      'Сжать',
    )) {
      return;
    }
    if (!mounted) return;
    final before = databaseBytes;
    await _task(() async {
      await widget.assets!.repository.db.customStatement('VACUUM');
      final row = await widget.assets!.repository.db
          .customSelect(
            'SELECT (SELECT page_count FROM pragma_page_count()) * (SELECT page_size FROM pragma_page_size()) AS bytes',
          )
          .getSingle();
      final saved = before - row.read<int>('bytes');
      return saved > 0
          ? 'База данных сжата, освобождено ${storageBytes(saved)}.'
          : 'База данных уже компактна.';
    }, 'Не удалось сжать базу');
  }

  Future<void> _clearLog() async {
    if (!await _confirm(
      'Очистить журнал ошибок?',
      'Записи об ошибках будут удалены с устройства.',
      'Очистить',
    )) {
      return;
    }
    if (!mounted) return;
    await _task(() async {
      final bytes = logBytes;
      await ErrorLog.clear();
      return 'Журнал ошибок очищен, освобождено ${storageBytes(bytes)}.';
    }, 'Не удалось очистить журнал');
  }

  Widget _row(String title, int bytes, {Widget? subtitle, Widget? action}) =>
      ListTile(
        title: Text(title),
        subtitle: subtitle,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [Text(storageBytes(bytes)), ?action],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final list = ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
      children: [
        const SettingsHeading(
          'Хранилище',
          'Место, которое занимает PepeHub на этом устройстве. Подключённые папки книг и аудиокниг в этот размер не входят.',
        ),
        if (widget.assets == null)
          const SettingsNotice('Хранилище файлов недоступно.'),
        if (busy)
          const Padding(
            padding: EdgeInsets.only(bottom: 18),
            child: LinearProgressIndicator(),
          ),
        if (error != null) SettingsNotice(error!),
        if (result != null) SettingsNotice(result!),
        if (usage != null) ...[
          const SettingsSubheading('Можно очистить'),
          SettingsGroup(
            children: [
              _row(
                'Временные копии книг и PDF',
                usage!.temporary,
                subtitle: const Text('Создаются заново при открытии книги'),
              ),
              _row('Журнал ошибок', logBytes),
              _row(
                'Свободное место внутри базы',
                freeBytes,
                subtitle: const Text('Возвращается системе при сжатии'),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: busy ? null : _clear,
                icon: const Icon(Icons.cleaning_services_outlined),
                label: const Text('Очистить временные копии'),
              ),
              OutlinedButton.icon(
                key: const ValueKey('storage-compact'),
                onPressed: busy ? null : _compact,
                icon: const Icon(Icons.compress),
                label: const Text('Сжать базу данных'),
              ),
              OutlinedButton.icon(
                onPressed: busy || logBytes == 0 ? null : _clearLog,
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('Очистить журнал ошибок'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const SettingsSubheading('Сохраняется'),
          SettingsGroup(
            children: [
              _row('База данных', databaseBytes),
              _row('Из них индексы чтения', indexBytes),
              _row('Сохранённые обложки', usage!.covers),
              _row(
                'Все локальные файлы приложения',
                usage!.total,
                subtitle: SelectableText(widget.assets!.directory.path),
              ),
            ],
          ),
          Text(
            'Обложки и индексы хранят выбранное оформление, метаданные и привязки к истории чтения, поэтому не очищаются.',
            style: TextStyle(color: Theme.of(context).hintColor),
          ),
        ],
        if (widget.assets != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: busy ? null : _measure,
              child: const Text('Пересчитать размер'),
            ),
          ),
      ],
    );
    if (widget.embedded) return list;
    return Scaffold(
      appBar: AppBar(title: const Text('Хранилище')),
      body: list,
    );
  }
}
