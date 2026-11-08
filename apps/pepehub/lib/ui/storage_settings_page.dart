import 'package:flutter/material.dart';

import '../media/asset_store.dart';
import '../media/storage_usage.dart';
import 'settings_components.dart';
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
  int indexBytes = 0;
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
      if (mounted) {
        setState(() {
          usage = measured;
          indexBytes = row.read<int>('bytes');
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

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: widget.embedded
        ? null
        : AppBar(title: const Text('Место на диске и кэш')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const SettingsHeading(
          'Место на диске и кэш',
          'Локальное хранилище PepeHub. Подключённые внешние папки в этот размер не входят.',
        ),
        if (widget.assets == null)
          const SettingsNotice('Хранилище файлов недоступно.'),
        if (busy) const LinearProgressIndicator(),
        if (error != null) SettingsNotice(error!),
        if (result != null) SettingsNotice(result!),
        if (usage != null) ...[
          ListTile(
            title: const Text('Локальные файлы приложения'),
            subtitle: SelectableText(widget.assets!.directory.path),
            trailing: Text(storageBytes(usage!.total)),
          ),
          ListTile(
            title: const Text('Временные копии книг и PDF'),
            trailing: Text(storageBytes(usage!.temporary)),
          ),
          ListTile(
            title: const Text('Сохранённые обложки'),
            trailing: Text(storageBytes(usage!.covers)),
          ),
          ListTile(
            title: const Text('Индексы чтения в базе данных'),
            trailing: Text(storageBytes(indexBytes)),
          ),
          const SettingsNotice(
            'Обложки и индексы сохраняются: они содержат выбранное оформление, метаданные и привязки к истории чтения. Превью видео хранятся в памяти и освобождаются при закрытии плеера.',
          ),
          FilledButton.icon(
            onPressed: busy ? null : _clear,
            icon: const Icon(Icons.cleaning_services_outlined),
            label: const Text('Очистить временные копии'),
          ),
        ],
        if (widget.assets != null)
          TextButton(
            onPressed: busy ? null : _measure,
            child: const Text('Пересчитать размер'),
          ),
      ],
    ),
  );
}
