import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../audio/audio_folder.dart';
import '../audio/statistics_export.dart';
import '../data/repository.dart';
import '../statistics/statistics_exchange.dart';
import 'pepe_widgets.dart';

class StatisticsExchangePage extends StatefulWidget {
  final Repository repository;
  const StatisticsExchangePage({super.key, required this.repository});
  @override
  State<StatisticsExchangePage> createState() => _StatisticsExchangePageState();
}

class _StatisticsExchangePageState extends State<StatisticsExchangePage> {
  bool busy = false;
  String? message;
  Map<String, dynamic>? pending;
  StatisticsImportResult? preview;
  late final exchange = StatisticsExchange(widget.repository);
  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => message = 'Не удалось выполнить перенос: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _export() => _run(() async {
    final json = await exchange.exportJson();
    bool saved;
    if (Platform.isAndroid) {
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/PepeHub-statistics-${DateTime.now().microsecondsSinceEpoch}.json',
      );
      try {
        await file.writeAsString(json, flush: true);
        saved =
            await audioFolderChannel.invokeMethod<bool>('exportStatistics', {
              'name': 'PepeHub-complete-statistics.json',
              'mime': 'application/json',
              'path': file.path,
            }) ??
            false;
      } finally {
        if (await file.exists()) await file.delete();
      }
    } else {
      saved = await saveStatisticsFile(json, 'json');
    }
    if (mounted && saved) {
      setState(() => message = 'Чтение и аудио сохранены в одном JSON-файле.');
    }
  });
  Future<void> _choose() => _run(() async {
    String? text;
    if (Platform.isAndroid) {
      final path = await audioFolderChannel.invokeMethod<String>(
        'importStatistics',
      );
      if (path != null) {
        final file = File(path);
        try {
          if (await file.length() > 64 * 1024 * 1024) {
            throw const FormatException('Файл больше 64 МиБ');
          }
          text = await file.readAsString();
        } finally {
          if (await file.exists()) await file.delete();
        }
      }
    } else {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'JSON', extensions: ['json']),
        ],
      );
      if (file != null) {
        if (await file.length() > 64 * 1024 * 1024) {
          throw const FormatException('Файл больше 64 МиБ');
        }
        text = await file.readAsString();
      }
    }
    if (text == null) return;
    final data = await exchange.decode(text);
    final result = await exchange.importData(data);
    if (mounted) {
      setState(() {
        pending = data;
        preview = result;
      });
    }
  });
  Future<void> _import() => _run(() async {
    final result = await exchange.importData(pending!, apply: true);
    if (mounted) {
      setState(() {
        pending = null;
        preview = null;
        message = 'Импорт завершён. $result';
      });
    }
  });
  @override
  Widget build(BuildContext context) => PepeSubpage(
    title: 'Перенос статистики',
    children: [
      const Text(
        'Один JSON для всей истории чтения и прослушивания: исходные сессии и события, заметки журнала, даты, цели, планы и описания произведений. Книги, аудиофайлы и обложки в файл не входят.',
      ),
      const SizedBox(height: 16),
      const Text(
        'Повторный импорт не удваивает записи. При совпадении ID с другими данными местная запись сохраняется, конфликт пропускается. Карточки библиотеки автоматически не создаются; импортированные описания используются только в статистике.',
      ),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: busy ? null : _export,
        icon: const Icon(Icons.upload_file),
        label: const Text('Экспортировать всё · JSON'),
      ),
      OutlinedButton.icon(
        onPressed: busy ? null : _choose,
        icon: const Icon(Icons.download),
        label: const Text('Выбрать файл для импорта'),
      ),
      if (busy) const LinearProgressIndicator(),
      if (message != null)
        Padding(padding: const EdgeInsets.all(12), child: Text(message!)),
      if (preview != null)
        PepePanel(
          title: 'Предварительная проверка',
          child: Column(
            children: [
              Text('$preview'),
              const Text(
                'Добавить новые записи, пропустить совпадения и конфликты?',
              ),
              FilledButton(
                onPressed: busy ? null : _import,
                child: const Text('Импортировать новые записи'),
              ),
              TextButton(
                onPressed: busy
                    ? null
                    : () => setState(() {
                        pending = null;
                        preview = null;
                      }),
                child: const Text('Отмена'),
              ),
            ],
          ),
        ),
    ],
  );
}
