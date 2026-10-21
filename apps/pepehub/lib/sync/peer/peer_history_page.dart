import 'dart:async';

import 'package:flutter/material.dart';

import '../../ui/audio_mini_player.dart';
import 'peer_diagnostics.dart';
import 'peer_history.dart';
import 'peer_models.dart';
import 'peer_service.dart';

String peerHistorySize(int bytes) {
  if (bytes < 1024) return '$bytes Б';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} КБ';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(0)} МБ';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} ГБ';
}

class PeerHistoryPage extends StatefulWidget {
  final PeerSyncService service;
  final PeerFolder folder;
  const PeerHistoryPage({
    super.key,
    required this.service,
    required this.folder,
  });
  @override
  State<PeerHistoryPage> createState() => _PeerHistoryPageState();
}

class _PeerHistoryPageState extends State<PeerHistoryPage> {
  PeerHistorySummary? report;
  String? error;
  bool working = false, dirty = false;
  late bool enabled;
  late int days, bytes;
  PeerFolder get folder =>
      widget.service.folders.firstWhere((f) => f.id == widget.folder.id);
  @override
  void initState() {
    super.initState();
    enabled = folder.history.enabled;
    days = folder.history.maxDays;
    bytes = folder.history.maxBytes;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  Future<void> _run(Future<PeerHistorySummary> Function() action) async {
    setState(() {
      working = true;
      error = null;
    });
    try {
      final next = await action();
      if (mounted) setState(() => report = next);
    } catch (failure) {
      widget.service.recordFailure(failure);
      if (mounted) setState(() => error = peerFailureDescription(failure));
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> _load() => _run(() => widget.service.manageHistory(folder));
  Future<void> _save() => _run(() async {
    await widget.service.configureFolder(
      folder,
      history: PeerHistorySettings(
        enabled: enabled,
        maxDays: days,
        maxBytes: bytes,
      ),
    );
    if (mounted) setState(() => dirty = false);
    return widget.service.manageHistory(folder, prune: enabled);
  });
  Future<void> _clear() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Очистить историю версий?'),
        content: Text(
          'Будут безвозвратно удалены сохранённые версии: ${report?.files ?? 0} файлов, ${peerHistorySize(report?.bytes ?? 0)}. Текущие книги, аудио и видео останутся в общей папке.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Очистить историю'),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      await _run(() => widget.service.manageHistory(folder, clear: true));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.service,
    builder: (context, _) {
      final disabled = working || widget.service.busy;
      final dayOptions = {7, 30, 90, 365, days}.toList()..sort();
      final byteOptions = {
        100 * 1024 * 1024,
        500 * 1024 * 1024,
        1024 * 1024 * 1024,
        5 * 1024 * 1024 * 1024,
        bytes,
      }.toList()..sort();
      return Scaffold(
        appBar: AppBar(title: const Text('История версий')),
        bottomNavigationBar: const AudioPlayerFooter(),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(folder.name, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            SwitchListTile(
              key: const Key('history-enabled'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Сохранять предыдущие версии'),
              subtitle: const Text(
                'Только на этом устройстве. По умолчанию выключено.',
              ),
              value: enabled,
              onChanged: disabled
                  ? null
                  : (value) => setState(() {
                      enabled = value;
                      dirty = true;
                    }),
            ),
            const Text(
              'При включении старые версии заменённых и подтверждённо удалённых файлов сохраняются в .pepehub/p2p/versions внутри общей папки.',
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int>(
              key: ValueKey('history-days-$days'),
              initialValue: days,
              decoration: const InputDecoration(labelText: 'Срок хранения'),
              items: [
                for (final value in dayOptions)
                  DropdownMenuItem(value: value, child: Text('$value дней')),
              ],
              onChanged: disabled || !enabled
                  ? null
                  : (value) => setState(() {
                      days = value!;
                      dirty = true;
                    }),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int>(
              key: ValueKey('history-bytes-$bytes'),
              initialValue: bytes,
              decoration: const InputDecoration(
                labelText: 'Максимальный объём',
              ),
              items: [
                for (final value in byteOptions)
                  DropdownMenuItem(
                    value: value,
                    child: Text(peerHistorySize(value)),
                  ),
              ],
              onChanged: disabled || !enabled
                  ? null
                  : (value) => setState(() {
                      bytes = value!;
                      dirty = true;
                    }),
            ),
            const SizedBox(height: 12),
            const Text(
              'При включённой истории старые копии автоматически удаляются по сроку и объёму, начиная с самых ранних. Выключение сохраняет уже созданные копии до явной очистки.',
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: disabled || !dirty ? null : _save,
              child: const Text('Сохранить настройки'),
            ),
            const Divider(height: 32),
            if (report case final status?) ...[
              Text(
                'В истории: ${status.files} файлов · ${peerHistorySize(status.bytes)}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (status.legacy > 0)
                Text(
                  'Копий рядом с книгами: ${status.legacy}. Перенос не завершён; подробности ниже.',
                ),
              if (status.unknown > 0)
                Text(
                  'Неизвестных элементов в папке истории: ${status.unknown}. Они сохраняются при очистке.',
                ),
              for (final warning in status.warnings)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(warning),
                ),
            ],
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (working)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: LinearProgressIndicator(),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: disabled ? null : _load,
                  child: const Text('Обновить и перенести старые копии'),
                ),
                OutlinedButton(
                  onPressed: disabled || !folder.history.enabled
                      ? null
                      : () => _run(
                          () =>
                              widget.service.manageHistory(folder, prune: true),
                        ),
                  child: const Text('Применить лимиты сейчас'),
                ),
                OutlinedButton(
                  onPressed: disabled || (report?.files ?? 0) == 0
                      ? null
                      : _clear,
                  child: const Text('Очистить историю'),
                ),
              ],
            ),
            const SizedBox(height: 24),
          ],
        ),
      );
    },
  );
}
