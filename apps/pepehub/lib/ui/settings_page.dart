import 'package:flutter/material.dart';

import '../library/library_service.dart';
import 'app_theme.dart';
import 'recommendations_page.dart';
import '../recommendations/recommendation_store.dart';

class SettingsPage extends StatefulWidget {
  final LibraryService library;
  final Future<void> Function() onConnection;
  final VoidCallback onJournal;
  final VoidCallback? onNotes;
  const SettingsPage({
    super.key,
    required this.library,
    required this.onConnection,
    required this.onJournal,
    this.onNotes,
  });
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int interval = 30, goal = 30;
  bool history = true, covers = true, notes = true, loaded = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = widget.library.local;
    final values = await Future.wait([
      repo.meta('obsidian-sync-seconds'),
      repo.meta('obsidian-sync-history'),
      repo.meta('reading-daily-goal'),
      repo.meta('obsidian-sync-covers'),
      repo.meta('obsidian-sync-notes'),
    ]);
    if (!mounted) return;
    setState(() {
      interval = [0, 30, 60, 300].contains(int.tryParse(values[0] ?? ''))
          ? int.parse(values[0]!)
          : 30;
      history = values[1] != 'false';
      covers = values[3] != 'false';
      notes = values[4] != 'false';
      goal = (int.tryParse(values[2] ?? '') ?? 30).clamp(0, 1440);
      loaded = true;
    });
  }

  Future<void> _save(String key, String value) async {
    await widget.library.local.setMeta(key, value);
    await widget.library.configureTimer();
  }

  @override
  Widget build(BuildContext context) {
    final appearance = ThemeScope.of(context);
    if (appearance == null) {
      return const Scaffold(body: Center(child: Text('Настройки недоступны')));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: !loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  'Оформление',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                LayoutBuilder(
                  builder: (context, size) => Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final style in AppStyle.values)
                        SizedBox(
                          width: size.maxWidth < 500
                              ? (size.maxWidth - 10) / 2
                              : 160,
                          child: InkWell(
                            onTap: () => appearance.preferences(style: style),
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Color(style.background),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: appearance.style == style
                                      ? Color(style.accent)
                                      : Colors.white24,
                                  width: 2,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      for (final factor in [.0, .3, .7])
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            right: 6,
                                          ),
                                          child: CircleAvatar(
                                            radius: 8,
                                            backgroundColor: Color.lerp(
                                              Color(style.accent),
                                              Color(style.background),
                                              factor,
                                            ),
                                          ),
                                        ),
                                      const Spacer(),
                                      if (appearance.style == style)
                                        Icon(
                                          Icons.check,
                                          size: 18,
                                          color: Color(style.accent),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    style.label,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<ThemeMode>(
                  isExpanded: true,
                  initialValue: appearance.mode,
                  decoration: const InputDecoration(labelText: 'Режим'),
                  items: const [
                    DropdownMenuItem(
                      value: ThemeMode.system,
                      child: Text('Как в системе'),
                    ),
                    DropdownMenuItem(
                      value: ThemeMode.light,
                      child: Text('Светлый'),
                    ),
                    DropdownMenuItem(
                      value: ThemeMode.dark,
                      child: Text('Тёмный'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) appearance.set(value);
                  },
                ),
                const SizedBox(height: 12),
                Text('Размер текста: ${(appearance.textScale * 100).round()}%'),
                Slider(
                  value: appearance.textScale,
                  min: .9,
                  max: 1.3,
                  divisions: 4,
                  label: '${(appearance.textScale * 100).round()}%',
                  onChanged: (value) =>
                      appearance.preferences(textScale: value),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Компактный интерфейс'),
                  value: appearance.compact,
                  onChanged: (value) => appearance.preferences(compact: value),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Уменьшить анимации'),
                  value: appearance.reduceMotion,
                  onChanged: (value) =>
                      appearance.preferences(reduceMotion: value),
                ),
                const Divider(height: 32),
                Text('Чтение', style: Theme.of(context).textTheme.titleLarge),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Цель чтения в день'),
                  subtitle: Text(goal == 0 ? 'Без цели' : '$goal мин'),
                  trailing: const Icon(Icons.edit_outlined),
                  onTap: () async {
                    var draftGoal = '$goal';
                    final result = await showDialog<int>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Цель в минутах'),
                        content: TextFormField(
                          initialValue: draftGoal,
                          onChanged: (value) => draftGoal = value,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            helperText: '0 — без цели, до 1440 минут',
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('Отмена'),
                          ),
                          FilledButton(
                            onPressed: () {
                              final value = int.tryParse(draftGoal);
                              if (value != null &&
                                  value >= 0 &&
                                  value <= 1440) {
                                Navigator.pop(context, value);
                              }
                            },
                            child: const Text('Сохранить'),
                          ),
                        ],
                      ),
                    );
                    // The route may still be animating while its TextField disposes.
                    if (result != null && mounted) {
                      setState(() => goal = result);
                      await _save('reading-daily-goal', '$result');
                    }
                  },
                ),
                const Divider(height: 32),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Источники книжных рекомендаций'),
                  subtitle: const Text(
                    'Inventaire, Open Library и Author.Today',
                  ),
                  trailing: const Icon(Icons.manage_search),
                  onTap: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => RecommendationSourcesPage(
                        store: RecommendationStore(widget.library.local),
                      ),
                    ),
                  ),
                ),
                const Divider(height: 32),
                Text('Obsidian', style: Theme.of(context).textTheme.titleLarge),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Подключение'),
                  subtitle: Text(
                    widget.library.config == null
                        ? 'Не настроено'
                        : widget.library.config!.url,
                  ),
                  trailing: const Icon(Icons.link),
                  onTap: () async {
                    await widget.onConnection();
                    if (mounted) setState(() {});
                  },
                ),
                DropdownButtonFormField<int>(
                  isExpanded: true,
                  initialValue: interval,
                  decoration: const InputDecoration(
                    labelText: 'Автоматическая синхронизация',
                  ),
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('Только вручную')),
                    DropdownMenuItem(
                      value: 30,
                      child: Text('Каждые 30 секунд'),
                    ),
                    DropdownMenuItem(value: 60, child: Text('Каждую минуту')),
                    DropdownMenuItem(value: 300, child: Text('Каждые 5 минут')),
                  ],
                  onChanged: (value) async {
                    if (value == null) return;
                    setState(() => interval = value);
                    await _save('obsidian-sync-seconds', '$value');
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Синхронизировать журнал'),
                  subtitle: const Text(
                    'Дни, длительность и прогресс чтения и прослушивания связанных книг',
                  ),
                  value: history,
                  onChanged: (value) async {
                    setState(() => history = value);
                    await _save('obsidian-sync-history', '$value');
                    if (value) await widget.library.sync();
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Синхронизировать обложки'),
                  subtitle: const Text(
                    'Обложки связанных книг и аудиокниг доступны без интернета',
                  ),
                  value: covers,
                  onChanged: (value) async {
                    setState(() => covers = value);
                    await _save('obsidian-sync-covers', '$value');
                    if (value) await widget.library.sync();
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Синхронизировать заметки'),
                  subtitle: const Text(
                    'Цитаты, комментарии, теги, персонажи и заметки Obsidian',
                  ),
                  value: notes,
                  onChanged: (value) async {
                    setState(() => notes = value);
                    await _save('obsidian-sync-notes', '$value');
                    if (value) await widget.library.sync();
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Заметки Obsidian'),
                  trailing: const Icon(Icons.notes),
                  onTap: widget.onNotes,
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Журнал чтения и прослушивания'),
                  trailing: const Icon(Icons.history),
                  onTap: widget.onJournal,
                ),
                OutlinedButton.icon(
                  onPressed: () => widget.library.sync(),
                  icon: const Icon(Icons.sync),
                  label: const Text('Синхронизировать сейчас'),
                ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}
