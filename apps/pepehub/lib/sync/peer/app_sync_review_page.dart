import 'dart:convert';

import 'package:flutter/material.dart';

import '../../ui/audio_mini_player.dart';
import 'app_sync_engine.dart';
import 'app_sync_models.dart';
import 'peer_service.dart';

class AppSyncReviewPage extends StatefulWidget {
  final PeerSyncService service;
  const AppSyncReviewPage({super.key, required this.service});
  @override
  State<AppSyncReviewPage> createState() => _AppSyncReviewPageState();
}

class _AppSyncReviewPageState extends State<AppSyncReviewPage> {
  List<AppSyncIssue> issues = [];
  bool loading = true;
  String? error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await widget.service.initialize();
      final app = widget.service.application!;
      await app.refresh();
      await app.applyPending();
      final next = await app.issues();
      if (mounted) {
        setState(() {
          issues = next;
          error = null;
          loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          loading = false;
        });
      }
    }
  }

  String _title(String key) {
    if (key.startsWith('position:reader:')) return 'Место чтения';
    if (key.startsWith('position:video:')) return 'Позиция видео';
    if (key.startsWith('position:audio:')) return 'Позиция аудиокниги';
    if (key.startsWith('media:')) return 'Книга или курс';
    if (key.contains('vocabulary_card')) return 'Карточка Anki';
    if (key.contains('annotation') || key.contains('note:')) return 'Заметка';
    if (key.startsWith('recommendation:')) return 'Подборки книг';
    if (key.contains('session') ||
        key.contains('interval') ||
        key.contains('audio_event')) {
      return 'История и статистика';
    }
    return 'Данные библиотеки';
  }

  String _preview(AppSyncVersion version) {
    final value = version.value;
    if (value == null) return 'Удалено на другом устройстве';
    if (version.key.startsWith('position:reader:')) {
      return 'Глава ${(value['chapter'] as int) + 1}, смещение ${value['textOffset']}';
    }
    if (version.key.startsWith('position:')) {
      final seconds = (value['positionMs'] as int) ~/ 1000;
      return '${seconds ~/ 3600}:${(seconds ~/ 60 % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')} · ${value['speed']}×';
    }
    final text = [
      for (final field in ['title', 'front', 'back', 'body', 'text', 'name'])
        if (value[field] is String) value[field] as String,
    ].join('\n');
    final result = text.isEmpty ? jsonEncode(value) : text;
    return result.length > 1200 ? '${result.substring(0, 1200)}…' : result;
  }

  Future<void> _choose(AppSyncIssue issue, AppSyncVersion version) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Применить эту версию?'),
        content: Text(_preview(version)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Применить'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    setState(() => loading = true);
    try {
      await widget.service.application!.resolve(
        issue.key,
        version.id,
        issue.versions.map((v) => v.id).toSet(),
      );
      await _load();
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Спорные и ожидающие данные'),
      actions: [
        IconButton(
          onPressed: loading || widget.service.busy ? null : _load,
          icon: const Icon(Icons.refresh),
          tooltip: 'Обновить',
        ),
      ],
    ),
    bottomNavigationBar: const AudioPlayerFooter(),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: loading
            ? const CircularProgressIndicator()
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const Text(
                    'Разные позиции и независимые правки сохраняются до вашего выбора. Открытая книга и загруженный плеер продолжают работать со своей позицией.',
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (widget
                      .service
                      .application!
                      .codec
                      .localProblems
                      .isNotEmpty)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Локальные записи требуют проверки (${widget.service.application!.codec.localProblems.length})',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const Text(
                              'Исходные записи сохранены. Они не передаются и не заменяются входящими правками. Проверьте их отдельно; остальные данные продолжают синхронизироваться.',
                            ),
                            for (final problem
                                in widget
                                    .service
                                    .application!
                                    .codec
                                    .localProblems
                                    .values
                                    .take(100))
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: SelectableText(
                                  '${problem.reference}\n${problem.description}',
                                ),
                              ),
                            if (widget
                                    .service
                                    .application!
                                    .codec
                                    .localProblems
                                    .length >
                                100)
                              const Text(
                                'Показаны первые 100 записей. Остальные исходные записи также сохранены.',
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (issues.isEmpty &&
                      widget.service.application!.codec.localProblems.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 28),
                      child: Text('Спорных или ожидающих данных нет.'),
                    ),
                  for (final issue in issues)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _title(issue.key),
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            Text(
                              issue.protected
                                  ? widget
                                            .service
                                            .application!
                                            .codec
                                            .localProblems
                                            .containsKey(issue.target)
                                        ? 'Локальная запись требует исправления; исходные данные сохранены.'
                                        : 'Закройте эту книгу или остановите плеер, затем обновите список.'
                                  : issue.pending
                                  ? 'Ожидает источника или применения'
                                  : 'Есть независимые версии',
                            ),
                            for (final version in issue.versions)
                              Padding(
                                padding: const EdgeInsets.only(top: 14),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(_preview(version)),
                                    const SizedBox(height: 6),
                                    Text(
                                      'Устройства версии: ${version.clock.keys.map((id) => id == widget.service.deviceId ? widget.service.name : widget.service.devices.where((d) => d.id == id).firstOrNull?.name ?? id.substring(0, 8)).join(', ')}',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall,
                                    ),
                                    TextButton(
                                      onPressed:
                                          issue.protected || widget.service.busy
                                          ? null
                                          : () => _choose(issue, version),
                                      child: Text(
                                        version.deleted
                                            ? 'Подтвердить удаление'
                                            : 'Использовать эту версию',
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
      ),
    ),
  );
}
