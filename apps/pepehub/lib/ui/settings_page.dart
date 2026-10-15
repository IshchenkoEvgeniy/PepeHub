import 'package:flutter/material.dart';

import '../sync/peer/peer_service.dart';
import '../sync/peer/peer_sync_page.dart';

import '../audio/statistics_export.dart' show ListeningGoals;
import '../library/library_service.dart';
import '../recommendations/recommendation_store.dart';
import 'app_theme.dart';
import 'pepe_widgets.dart';
import 'recommendations_page.dart';
import 'shelf_components.dart';
import '../vocabulary/vocabulary_page.dart';
import '../vocabulary/vocabulary_repository.dart';

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
  ListeningGoals listening = const ListeningGoals();
  final sections = {
    for (final name in ['Оформление', 'Цели', 'Рекомендации', 'Obsidian'])
      name: GlobalKey(),
  };
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
    ListeningGoals goals;
    try {
      goals = await ListeningGoals.load(repo);
    } catch (_) {
      goals = const ListeningGoals();
    }
    if (!mounted) return;
    setState(() {
      interval = [0, 30, 60, 300].contains(int.tryParse(values[0] ?? ''))
          ? int.parse(values[0]!)
          : 30;
      history = values[1] != 'false';
      covers = values[3] != 'false';
      notes = values[4] != 'false';
      goal = (int.tryParse(values[2] ?? '') ?? 30).clamp(0, 1440);
      listening = goals;
      loaded = true;
    });
  }

  Future<void> _save(String key, String value) async {
    await widget.library.local.setMeta(key, value);
    await widget.library.configureTimer();
  }

  Future<void> _setGoal(int value) async {
    final next = value.clamp(0, 1440);
    setState(() => goal = next);
    await _save('reading-daily-goal', '$next');
  }

  Future<void> _setListening({int? daily, int? weekly}) async {
    final next = ListeningGoals(
      dailyMinutes: (daily ?? listening.dailyMinutes).clamp(0, 1440),
      weeklyMinutes: (weekly ?? listening.weeklyMinutes).clamp(0, 10080),
    );
    setState(() => listening = next);
    try {
      await next.save(widget.library.local);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Цель не сохранена: $e')));
      }
    }
  }

  Widget _palettes(AppTheme appearance) => LayoutBuilder(
    builder: (context, size) {
      final columns = size.maxWidth < 420
          ? 2
          : size.maxWidth < 700
          ? 3
          : 5;
      final width = (size.maxWidth - 10 * (columns - 1)) / columns;
      return Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final style in AppStyle.values)
            SizedBox(width: width, child: _swatch(appearance, style)),
        ],
      );
    },
  );

  Widget _swatch(AppTheme appearance, AppStyle style) {
    final active = appearance.style == style;
    return Semantics(
      button: true,
      selected: active,
      child: Material(
        color: Color(style.background),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: active ? Color(style.accent) : Color(style.strongLine),
            width: active ? 2.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => appearance.preferences(style: style),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 54,
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Color(style.surface),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        height: 6,
                        width: 46,
                        decoration: BoxDecoration(
                          color: Color(style.text),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      Container(
                        height: 4,
                        width: 30,
                        decoration: BoxDecoration(
                          color: Color(style.muted),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      Row(
                        children: [
                          Container(
                            height: 12,
                            width: 34,
                            decoration: BoxDecoration(
                              color: Color(style.accent),
                              borderRadius: BorderRadius.circular(6),
                            ),
                          ),
                          const Spacer(),
                          if (active)
                            Icon(
                              Icons.check_circle,
                              size: 14,
                              color: Color(style.accent),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  style.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Color(style.text),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _switch(
    String title,
    String? subtitle,
    bool value,
    ValueChanged<bool> onChanged,
  ) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle),
    value: value,
    onChanged: onChanged,
  );

  Widget _goalLine(
    ShelfPalette palette,
    String title,
    String note,
    int value,
    int step,
    int max,
    ValueChanged<int> onChanged,
  ) => Container(
    padding: const EdgeInsets.symmetric(vertical: 10),
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: palette.line)),
    ),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 8,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 180, maxWidth: 360),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(note, style: TextStyle(fontSize: 12, color: palette.muted)),
            ],
          ),
        ),
        PepeStepper(
          value: value == 0 ? '—' : '$value',
          onMinus: value <= 0 ? null : () => onChanged(value - step),
          onPlus: value >= max ? null : () => onChanged(value + step),
        ),
      ],
    ),
  );

  Widget _section(String name, Widget child, {String? note}) => Padding(
    key: sections[name],
    padding: const EdgeInsets.only(bottom: 16),
    child: PepePanel(
      title: name,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                note,
                style: TextStyle(
                  fontSize: 12.5,
                  color: ShelfPalette.of(context).muted,
                ),
              ),
            ),
          child,
        ],
      ),
    ),
  );

  Widget _link(
    String title,
    String? subtitle,
    IconData icon,
    VoidCallback? onTap,
  ) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon),
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle),
    trailing: const Icon(Icons.chevron_right),
    onTap: onTap,
  );

  @override
  Widget build(BuildContext context) {
    final appearance = ThemeScope.of(context);
    if (appearance == null) {
      return const Scaffold(body: Center(child: Text('Настройки недоступны')));
    }
    final palette = ShelfPalette.of(context);
    final wide = pepeWide(context);
    final look = _section(
      'Оформление',
      note: 'Цвет оформления',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _palettes(appearance),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Размер текста: ${(appearance.textScale * 100).round()}%',
                ),
              ),
              Text(
                'Аа',
                style: AppFonts.book(
                  palette.text,
                  size: 16 * appearance.textScale,
                ),
              ),
            ],
          ),
          Slider(
            value: appearance.textScale,
            min: .9,
            max: 1.3,
            divisions: 4,
            label: '${(appearance.textScale * 100).round()}%',
            onChanged: (value) => appearance.preferences(textScale: value),
          ),
          _switch(
            'Компактный интерфейс',
            null,
            appearance.compact,
            (value) => appearance.preferences(compact: value),
          ),
          _switch(
            'Уменьшить анимации',
            null,
            appearance.reduceMotion,
            (value) => appearance.preferences(reduceMotion: value),
          ),
        ],
      ),
    );
    final goals = _section(
      'Цели',
      note: '0 — без цели. Цели видны в статистике и на главных экранах.',
      Column(
        children: [
          _goalLine(
            palette,
            'Цель чтения в день',
            goal == 0 ? 'Без цели' : '$goal мин · вся библиотека',
            goal,
            5,
            1440,
            _setGoal,
          ),
          _goalLine(
            palette,
            'Прослушивание в день',
            listening.dailyMinutes == 0
                ? 'Без цели'
                : '${listening.dailyMinutes} мин',
            listening.dailyMinutes,
            5,
            1440,
            (v) => _setListening(daily: v),
          ),
          _goalLine(
            palette,
            'Прослушивание в неделю',
            listening.weeklyMinutes == 0
                ? 'Без цели'
                : '${listening.weeklyMinutes} мин',
            listening.weeklyMinutes,
            30,
            10080,
            (v) => _setListening(weekly: v),
          ),
        ],
      ),
    );
    final recommendations = _section(
      'Рекомендации',
      _link(
        'Источники книжных рекомендаций',
        'Inventaire, Open Library и Author.Today',
        Icons.manage_search,
        () => Navigator.push<void>(
          context,
          MaterialPageRoute(
            builder: (_) => RecommendationSourcesPage(
              store: RecommendationStore(widget.library.local),
            ),
          ),
        ),
      ),
    );
    final obsidian = _section(
      'Obsidian',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _link(
            'Подключение',
            widget.library.config == null
                ? 'Не настроено'
                : widget.library.config!.url,
            Icons.link,
            () async {
              await widget.onConnection();
              if (mounted) setState(() {});
            },
          ),
          const SizedBox(height: 8),
          Text(
            'Автоматическая синхронизация',
            style: TextStyle(fontSize: 13, color: palette.muted),
          ),
          const SizedBox(height: 8),
          PepeChoices<int>(
            options: const [
              (0, 'Вручную'),
              (30, 'Каждые 30 с'),
              (60, 'Раз в минуту'),
              (300, 'Раз в 5 минут'),
            ],
            selected: interval,
            onSelect: (value) async {
              setState(() => interval = value);
              await _save('obsidian-sync-seconds', '$value');
            },
          ),
          const SizedBox(height: 8),
          _switch(
            'Синхронизировать журнал',
            'Дни, длительность и прогресс чтения и прослушивания связанных книг',
            history,
            (value) async {
              setState(() => history = value);
              await _save('obsidian-sync-history', '$value');
              if (value) await widget.library.sync();
            },
          ),
          _switch(
            'Синхронизировать обложки',
            'Обложки связанных книг и аудиокниг доступны без интернета',
            covers,
            (value) async {
              setState(() => covers = value);
              await _save('obsidian-sync-covers', '$value');
              if (value) await widget.library.sync();
            },
          ),
          _switch(
            'Синхронизировать заметки',
            'Цитаты, комментарии, теги, персонажи и заметки Obsidian',
            notes,
            (value) async {
              setState(() => notes = value);
              await _save('obsidian-sync-notes', '$value');
              if (value) await widget.library.sync();
            },
          ),
        ],
      ),
    );
    final data = PepePanel(
      title: 'Данные',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _link('Заметки Obsidian', null, Icons.notes, widget.onNotes),
          if (PeerSyncScope.of(context) case final service?)
            _link(
              'Устройства и общие папки',
              'Прямой обмен файлами между ПК и телефоном',
              Icons.sync,
              () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => PeerSyncPage(service: service),
                ),
              ),
            ),
          _link(
            'Словарь Anki',
            'Слова, предложения и экспорт карточек',
            Icons.style_outlined,
            () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => VocabularyPage(
                  repository: VocabularyRepository(widget.library.local),
                ),
              ),
            ),
          ),
          _link(
            'Журнал чтения и прослушивания',
            null,
            Icons.history,
            widget.onJournal,
          ),
          const SizedBox(height: 10),
          Text(
            widget.library.config == null
                ? 'Obsidian не подключён — данные хранятся только на этом устройстве.'
                : widget.library.syncing
                ? 'Идёт синхронизация…'
                : widget.library.error ?? 'Связь с Obsidian настроена.',
            style: TextStyle(fontSize: 12.5, color: palette.muted),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => widget.library.sync(),
              child: const Text(
                'Синхронизировать сейчас',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
    if (!loaded) {
      return const PepeSubpage(
        title: 'Настройки',
        settings: true,
        children: [
          Padding(
            padding: EdgeInsets.all(40),
            child: Center(child: CircularProgressIndicator()),
          ),
        ],
      );
    }
    if (!wide) {
      return PepeSubpage(
        title: 'Настройки',
        settings: true,
        children: [look, goals, recommendations, obsidian, data],
      );
    }
    return PepeSubpage(
      title: 'Настройки',
      settings: true,
      maxWidth: 1480,
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 200,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final name in sections.keys)
                    TextButton(
                      style: TextButton.styleFrom(
                        alignment: Alignment.centerLeft,
                        foregroundColor: palette.text,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 14,
                        ),
                      ),
                      onPressed: () {
                        final target = sections[name]!.currentContext;
                        if (target != null) {
                          Scrollable.ensureVisible(
                            target,
                            duration: const Duration(milliseconds: 300),
                          );
                        }
                      },
                      child: Text(
                        name,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 24),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 40),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [look, goals, recommendations, obsidian],
                ),
              ),
            ),
            const SizedBox(width: 24),
            SizedBox(
              width: 320,
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 40),
                child: data,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
