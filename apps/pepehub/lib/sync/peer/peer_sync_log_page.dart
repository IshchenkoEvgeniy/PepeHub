import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ui/audio_mini_player.dart';
import 'peer_diagnostics.dart';

String _time(DateTime date) {
  final local = date.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

String _bytes(int bytes) {
  if (bytes < 1024) return '$bytes Б';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} КиБ';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МиБ';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} ГиБ';
}

class PeerSyncStatusPanel extends StatelessWidget {
  final PeerSyncJournal journal;
  const PeerSyncStatusPanel({super.key, required this.journal});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: journal,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final activity in journal.activities)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    activity.stage,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  if (activity.peer != null) Text(activity.peer!),
                  if (activity.subject != null)
                    Text(
                      activity.subject!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value:
                        activity.totalBytes != null &&
                            activity.totalBytes! > 0 &&
                            activity.bytes != null
                        ? (activity.bytes! / activity.totalBytes!).clamp(
                            0.0,
                            1.0,
                          )
                        : activity.total != null &&
                              activity.total! > 0 &&
                              activity.completed != null
                        ? (activity.completed! / activity.total!).clamp(
                            0.0,
                            1.0,
                          )
                        : null,
                  ),
                  const SizedBox(height: 6),
                  if (activity.bytes != null && activity.totalBytes != null)
                    Text(
                      '${_bytes(activity.bytes!)} / ${_bytes(activity.totalBytes!)}'
                      '${activity.totalBytes! > 0 ? ' · ${(100 * activity.bytes! / activity.totalBytes!).clamp(0, 100).toStringAsFixed(0)}%' : ''}',
                    ),
                  if (activity.completed != null)
                    Text(
                      activity.total == null
                          ? 'Проверено файлов: ${activity.completed}'
                          : 'Обработано записей: ${activity.completed} / ${activity.total}',
                    ),
                  Text(
                    'Начато в ${_time(activity.started)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.receipt_long_outlined),
          title: const Text('Журнал синхронизации'),
          subtitle: Text(
            journal.entries.isEmpty
                ? 'Этапы обмена, файлы и причины ошибок'
                : '${journal.entries.length} событий · можно открыть во время обмена',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => PeerSyncLogPage(journal: journal),
            ),
          ),
        ),
      ],
    ),
  );
}

class PeerSyncLogPage extends StatefulWidget {
  final PeerSyncJournal journal;
  const PeerSyncLogPage({super.key, required this.journal});
  @override
  State<PeerSyncLogPage> createState() => _PeerSyncLogPageState();
}

class _PeerSyncLogPageState extends State<PeerSyncLogPage> {
  bool problemsOnly = false;
  String query = '';

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.journal.export()));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Журнал скопирован')));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.journal,
    builder: (context, _) {
      final entries = widget.journal.entries.reversed
          .where(
            (entry) =>
                (!problemsOnly || entry.level != PeerLogLevel.info) &&
                (query.isEmpty || entry.text.toLowerCase().contains(query)),
          )
          .toList();
      return Scaffold(
        appBar: AppBar(title: const Text('Журнал синхронизации')),
        bottomNavigationBar: const AudioPlayerFooter(),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 840),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _copy,
                            icon: const Icon(Icons.copy),
                            label: const Text('Копировать журнал'),
                          ),
                          TextButton.icon(
                            onPressed: widget.journal.entries.isEmpty
                                ? null
                                : widget.journal.clear,
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('Очистить'),
                          ),
                        ],
                      ),
                      Text(
                        'Последние ${PeerSyncJournal.limit} событий сохраняются на этом устройстве. Новые события сверху.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (widget.journal.storageError != null)
                        Text(
                          widget.journal.storageError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      const SizedBox(height: 8),
                      TextField(
                        decoration: const InputDecoration(
                          isDense: true,
                          prefixIcon: Icon(Icons.search),
                          hintText: 'Поиск устройства, файла или ошибки',
                        ),
                        onChanged: (value) =>
                            setState(() => query = value.trim().toLowerCase()),
                      ),
                      const SizedBox(height: 4),
                      FilterChip(
                        label: const Text('Только проблемы'),
                        selected: problemsOnly,
                        onSelected: (value) =>
                            setState(() => problemsOnly = value),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: entries.isEmpty
                      ? Center(
                          child: Text(
                            problemsOnly || query.isNotEmpty
                                ? 'Подходящих событий нет'
                                : 'События появятся при подключении и обмене',
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                          itemCount: entries.length,
                          itemBuilder: (context, index) {
                            final entry = entries[index];
                            final color = switch (entry.level) {
                              PeerLogLevel.error => Theme.of(
                                context,
                              ).colorScheme.error,
                              PeerLogLevel.warning => Colors.orange,
                              PeerLogLevel.info => Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            };
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      top: 2,
                                      right: 10,
                                    ),
                                    child: Icon(
                                      switch (entry.level) {
                                        PeerLogLevel.error =>
                                          Icons.error_outline,
                                        PeerLogLevel.warning =>
                                          Icons.warning_amber_rounded,
                                        PeerLogLevel.info => Icons.info_outline,
                                      },
                                      size: 20,
                                      color: color,
                                    ),
                                  ),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '${_time(entry.time)} · ${entry.time.toLocal().day}.${entry.time.toLocal().month} · ${entry.label}',
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelSmall
                                              ?.copyWith(color: color),
                                        ),
                                        if (entry.peer != null)
                                          Text(
                                            entry.peer!,
                                            style: Theme.of(context)
                                                .textTheme
                                                .labelLarge,
                                          ),
                                        if (entry.subject != null)
                                          SelectableText(
                                            entry.subject!,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall,
                                          ),
                                        SelectableText(entry.message),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
