import 'package:flutter/material.dart';

import '../../ui/audio_mini_player.dart';
import 'peer_diagnostics.dart';
import 'peer_models.dart';
import 'peer_service.dart';

class PeerDeletionsPage extends StatelessWidget {
  final PeerSyncService service;
  const PeerDeletionsPage({super.key, required this.service});

  Future<void> _resolve(
    BuildContext context,
    PeerPendingDeletion request,
    bool delete,
  ) async {
    final keepHistory = service.folders.any(
      (f) => f.id == request.folder && f.history.enabled,
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          delete ? 'Удалить файл на этом устройстве?' : 'Оставить файл?',
        ),
        content: SingleChildScrollView(
          child: Text(
            '${request.path}\n\n${delete ? (keepHistory ? 'Файл будет убран из рабочей папки. Предыдущая версия сохранится в истории общей папки в пределах заданных ограничений.' : 'Файл будет удалён с этого устройства без сохранения резервной версии: история выключена.') : 'Файл останется в общей папке. При следующей синхронизации он восстановится и на устройствах, где был удалён.'}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(delete ? 'Удалить' : 'Оставить файл'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await service.resolveDeletion(request, delete: delete);
    } catch (failure) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(peerFailureDescription(failure))),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: service,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Подтверждение удалений')),
      bottomNavigationBar: const AudioPlayerFooter(),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 840),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'На других устройствах удалены эти файлы. Здесь они сохраняются до вашего решения. Можно вернуться к списку позже.',
              ),
              if (service.busy)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: LinearProgressIndicator(),
                ),
              if (service.pendingDeletions.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text('Нет ожидающих удалений'),
                ),
              for (final request in service.pendingDeletions)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          service.folders
                                  .where((f) => f.id == request.folder)
                                  .firstOrNull
                                  ?.name ??
                              'Общая папка',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        SelectableText(request.path),
                        const SizedBox(height: 4),
                        Text(
                          'Запрос от: ${service.devices.where((d) => d.id == request.device).firstOrNull?.name ?? 'другого устройства'}',
                        ),
                        Text(
                          '${(request.local.bytes / (1024 * 1024)).toStringAsFixed(1)} МиБ · ${request.time.toLocal().toString().split('.').first}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton(
                              onPressed: service.busy
                                  ? null
                                  : () => _resolve(context, request, false),
                              child: const Text('Оставить файл'),
                            ),
                            FilledButton(
                              onPressed: service.busy
                                  ? null
                                  : () => _resolve(context, request, true),
                              child: const Text('Подтвердить удаление'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
