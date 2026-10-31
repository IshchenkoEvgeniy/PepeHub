import 'package:flutter/material.dart';

import '../../ui/audio_mini_player.dart';
import 'app_sync_engine.dart';
import 'app_sync_models.dart';
import 'peer_service.dart';
import 'app_sync_presentation.dart';
import '../../reader/reading_library.dart';
import '../../reader/reading_roots.dart';
import '../../reader/text_book.dart';

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
  Map<String, Map<String, dynamic>> readerIndexes = {};
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
      final indexes = <String, Map<String, dynamic>>{};
      for (final issue in next.where(
        (issue) => issue.key.startsWith('position:reader:'),
      )) {
        final hash = issue.key.substring('position:reader:'.length);
        try {
          indexes[hash] = await ReadingLibrary(widget.service.store.repository)
              .value('reading-index:$hash');
        } catch (_) {
          indexes[hash] = {};
        }
      }
      if (mounted) {
        setState(() {
          issues = next;
          readerIndexes = indexes;
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
      final hash = version.key.substring('position:reader:'.length);
      return readerPositionDescription(value, readerIndexes[hash] ?? {});
    }
    if (version.key.startsWith('position:')) {
      final seconds = (value['positionMs'] as int) ~/ 1000;
      return '${seconds ~/ 3600}:${(seconds ~/ 60 % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')} · ${value['speed']}×';
    }
    return appSyncDisplayFields(value).entries
        .where((entry) => entry.key != 'Состояние')
        .take(5)
        .map((entry) => '${entry.key}: ${entry.value}')
        .join('\n');
  }

  String _devices(AppSyncVersion version) => version.clock.keys
      .map(
        (id) => id == widget.service.deviceId
            ? widget.service.name
            : widget.service.devices
                      .where((device) => device.id == id)
                      .firstOrNull
                      ?.name ??
                  id.substring(0, 8),
      )
      .join(', ');

  Widget _comparison(AppSyncIssue issue) {
    final fields = appSyncChangedFields(issue.versions);
    if (fields.isEmpty) return const SizedBox.shrink();
    final values = [
      for (final version in issue.versions) appSyncDisplayFields(version.value),
    ];
    return ExpansionTile(
      title: Text('Сравнить изменения (${fields.length})'),
      children: [
        for (final field in fields)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(field, style: Theme.of(context).textTheme.titleSmall),
                for (var i = 0; i < issue.versions.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText(
                          '${_devices(issue.versions[i])}\n${values[i][field] ?? 'Нет значения'}',
                        ),
                        if (values[i][field]?.endsWith('…') == true)
                          TextButton(
                            onPressed: () => showDialog<void>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: Text(
                                  '$field · ${_devices(issue.versions[i])}',
                                ),
                                content: SizedBox(
                                  width: 700,
                                  child: SingleChildScrollView(
                                    child: SelectableText(
                                      appSyncDisplayFields(
                                            issue.versions[i].value,
                                            complete: true,
                                          )[field] ??
                                          'Нет значения',
                                    ),
                                  ),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(context),
                                    child: const Text('Закрыть'),
                                  ),
                                ],
                              ),
                            ),
                            child: const Text('Показать полностью'),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Future<String> _context(AppSyncVersion version) async {
    final assets = widget.service.assets;
    if (assets == null || version.value == null) {
      return 'Файл книги недоступен на этом устройстве.';
    }
    final hash = version.key.substring('position:reader:'.length);
    final asset = await assets.byHash(hash);
    if (asset == null) {
      return 'Добавьте тот же файл книги на это устройство, чтобы увидеть фрагмент.';
    }
    if (asset.filename.toLowerCase().endsWith('.pdf')) {
      return 'Для PDF сравните номера страниц и откройте документ в читалке.';
    }
    final readable = await ReadingRoots(assets).forReading(asset);
    final book = await loadTextBook(readable.path, readable.filename);
    final chapter = version.value!['chapter'] as int;
    if (chapter < 0 || chapter >= book.chapters.length) {
      return 'Эта глава отсутствует в локальном файле.';
    }
    final text = book.chapters[chapter].text;
    return '${book.chapters[chapter].title}\n\n${readerPositionContext(text, version.value!['textOffset'] as int)}';
  }

  Future<void> _showContext(AppSyncVersion version) async {
    final future = _context(version);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_preview(version)),
        content: SizedBox(
          width: 600,
          child: FutureBuilder<String>(
            future: future,
            builder: (context, snapshot) =>
                snapshot.connectionState != ConnectionState.done
                ? const SizedBox(
                    height: 80,
                    child: Center(child: CircularProgressIndicator()),
                  )
                : SingleChildScrollView(
                    child: SelectableText(
                      snapshot.hasError
                          ? 'Не удалось открыть фрагмент. Файл и спорные позиции сохранены.'
                          : snapshot.data ?? '',
                    ),
                  ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
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
                            _comparison(issue),
                            for (final version in issue.versions)
                              Padding(
                                padding: const EdgeInsets.only(top: 14),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(_preview(version)),
                                    if (version.key.startsWith(
                                          'position:reader:',
                                        ) &&
                                        version.value != null)
                                      TextButton.icon(
                                        onPressed: () => _showContext(version),
                                        icon: const Icon(Icons.menu_book),
                                        label: const Text('Показать фрагмент'),
                                      ),
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
