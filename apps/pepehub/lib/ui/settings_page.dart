import 'package:flutter/material.dart';

import '../audio/statistics_export.dart' show ListeningGoals;
import '../library/library_service.dart';
import '../recommendations/recommendation_store.dart';
import '../sync/peer/peer_service.dart';
import '../sync/peer/peer_sync_page.dart';
import '../sync/peer/peer_sync_log_page.dart';
import '../updates/update_page.dart';
import '../updates/update_service.dart';
import '../vocabulary/vocabulary_page.dart';
import '../vocabulary/vocabulary_repository.dart';
import 'app_theme.dart';
import 'audio_mini_player.dart';
import 'audio_roots_page.dart';
import 'pepe_widgets.dart';
import 'reading_hidden_books_page.dart';
import 'reading_roots_page.dart';
import 'recommendations_page.dart';
import 'settings_components.dart';
import 'shelf_components.dart';

const _catalog = [
  (
    id: 'appearance',
    group: 'Основные',
    title: 'Оформление',
    note: 'Тема, размер текста и плотность',
    icon: Icons.palette_outlined,
  ),
  (
    id: 'reading',
    group: 'Основные',
    title: 'Чтение и аудио',
    note: 'Цели чтения и прослушивания',
    icon: Icons.menu_book_outlined,
  ),
  (
    id: 'files',
    group: 'Данные',
    title: 'Файлы и библиотека',
    note: 'Источники, папки и скрытые книги',
    icon: Icons.folder_open_outlined,
  ),
  (
    id: 'sync',
    group: 'Данные',
    title: 'Синхронизация',
    note: 'Устройства, папки и правила обмена',
    icon: Icons.sync,
  ),
  (
    id: 'integrations',
    group: 'Данные',
    title: 'Каталоги и инструменты',
    note: 'Рекомендации, Anki и заметки',
    icon: Icons.extension_outlined,
  ),
  (
    id: 'updates',
    group: 'Приложение',
    title: 'Обновления',
    note: 'Версия, загрузка и установка',
    icon: Icons.system_update_outlined,
  ),
  (
    id: 'help',
    group: 'Приложение',
    title: 'Помощь и диагностика',
    note: 'Журналы и служебные сведения',
    icon: Icons.help_outline,
  ),
];

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
  double? scaleDraft;
  bool history = true,
      covers = true,
      notes = true,
      loaded = false,
      saving = false;
  ListeningGoals listening = const ListeningGoals();
  String page = 'home';
  String? error;
  final navigation = <String>[];
  int readingRoots = 0, audioRoots = 0;

  @override
  void initState() {
    super.initState();
    widget.library.addListener(_libraryChanged);
    _load();
  }

  @override
  void dispose() {
    widget.library.removeListener(_libraryChanged);
    super.dispose();
  }

  void _libraryChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
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
        final saved = await ListeningGoals.load(repo);
        goals = ListeningGoals(
          dailyMinutes: saved.dailyMinutes.clamp(0, 1440),
          weeklyMinutes: saved.weeklyMinutes.clamp(0, 10080),
        );
      } on FormatException {
        goals = const ListeningGoals();
      } on TypeError {
        goals = const ListeningGoals();
      }
      final roots = await repo.metadataPrefixes([
        'reading-library-root:',
        'audio-library-root:',
      ]);
      if (!mounted) return;
      setState(() {
        final seconds = int.tryParse(values[0] ?? '');
        interval = [0, 30, 60, 300, 900, 1800, 3600].contains(seconds)
            ? seconds!
            : 30;
        history = values[1] != 'false';
        covers = values[3] != 'false';
        notes = values[4] != 'false';
        goal = (int.tryParse(values[2] ?? '') ?? 30).clamp(0, 1440);
        listening = goals;
        readingRoots = roots.keys
            .where((k) => k.startsWith('reading-library-root:'))
            .length;
        audioRoots = roots.length - readingRoots;
        loaded = true;
        error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          error = 'Не удалось прочитать настройки: $e';
          loaded = true;
        });
      }
    }
  }

  Future<void> _change(Future<void> Function() action) async {
    if (saving) return;
    setState(() => saving = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Изменение не сохранено: $e')));
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> _save(String key, String value) async {
    await widget.library.local.setMeta(key, value);
    if (key.startsWith('obsidian-sync-')) await widget.library.configureTimer();
  }

  Future<void> _setGoal(int value) => _change(() async {
    final next = value.clamp(0, 1440);
    await _save('reading-daily-goal', '$next');
    if (mounted) setState(() => goal = next);
  });
  Future<void> _setListening({int? daily, int? weekly}) => _change(() async {
    final next = ListeningGoals(
      dailyMinutes: (daily ?? listening.dailyMinutes).clamp(0, 1440),
      weeklyMinutes: (weekly ?? listening.weeklyMinutes).clamp(0, 10080),
    );
    await next.save(widget.library.local);
    if (mounted) setState(() => listening = next);
  });
  void _go(String next) {
    if (page == next) return;
    setState(() {
      navigation.add(page);
      page = next;
    });
  }

  void _back() {
    if (navigation.isNotEmpty) {
      setState(() => page = navigation.removeLast());
    } else {
      Navigator.maybePop(context);
    }
  }

  Future<void> _open(Widget child) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => child),
    );
    if (mounted) await _load();
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
          onTap: saving
              ? null
              : () => _change(() => appearance.preferences(style: style)),
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
    onChanged: saving ? null : onChanged,
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
          onMinus: saving || value <= 0 ? null : () => onChanged(value - step),
          onPlus: saving || value >= max ? null : () => onChanged(value + step),
        ),
      ],
    ),
  );

  Widget _groupTitle(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 18, 0, 10),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: ShelfPalette.of(context).muted,
        letterSpacing: .8,
      ),
    ),
  );
  Widget _home() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final group in ['Основные', 'Данные', 'Приложение']) ...[
        _groupTitle(group),
        SettingsGroup(
          children: [
            for (final item in _catalog.where((c) => c.group == group))
              SettingsLink(
                key: ValueKey('settings-entry:${item.id}'),
                title: item.title,
                subtitle: item.note,
                icon: item.icon,
                onTap: () => _go(item.id),
              ),
          ],
        ),
      ],
    ],
  );
  Widget _appearance(AppTheme appearance) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SettingsHeading(
        'Оформление',
        'Цвет и размер элементов интерфейса. Настройки текста книги доступны в читалке.',
      ),
      SettingsNotice(
        'Предпросмотр · ${appearance.style.label} · ${((scaleDraft ?? appearance.textScale) * 100).round()}%',
      ),
      _palettes(appearance),
      const SizedBox(height: 22),
      SettingsGroup(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Размер текста интерфейса: ${((scaleDraft ?? appearance.textScale) * 100).round()}%',
                ),
                Slider(
                  value: scaleDraft ?? appearance.textScale,
                  min: .9,
                  max: 1.3,
                  divisions: 4,
                  label:
                      '${((scaleDraft ?? appearance.textScale) * 100).round()}%',
                  onChanged: saving
                      ? null
                      : (value) => setState(() => scaleDraft = value),
                  onChangeEnd: (value) async {
                    await _change(
                      () => appearance.preferences(textScale: value),
                    );
                    if (mounted) setState(() => scaleDraft = null);
                  },
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _switch(
              'Компактный интерфейс',
              'Меньше отступов в списках.',
              appearance.compact,
              (value) => _change(() => appearance.preferences(compact: value)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _switch(
              'Уменьшить анимации',
              null,
              appearance.reduceMotion,
              (value) =>
                  _change(() => appearance.preferences(reduceMotion: value)),
            ),
          ),
        ],
      ),
    ],
  );
  Widget _goals() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SettingsHeading(
        'Чтение и аудио',
        'Цели чтения и аудиокниг учитываются отдельно. 0 — без цели.',
      ),
      SettingsGroup(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                _goalLine(
                  ShelfPalette.of(context),
                  'Цель чтения в день',
                  goal == 0 ? 'Без цели' : '$goal мин · вся библиотека',
                  goal,
                  5,
                  1440,
                  _setGoal,
                ),
                _goalLine(
                  ShelfPalette.of(context),
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
                  ShelfPalette.of(context),
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
          ),
        ],
      ),
      const SettingsNotice(
        'Шрифт, поля и режим чтения меняются в открытой книге. Скорость и таймер сна — в проигрывателе аудиокниги. Очередь, перемешивание и повтор — в музыкальном плеере. Музыка не входит в цель прослушивания аудиокниг.',
      ),
    ],
  );
  Widget _files() {
    final assets = widget.library.assets;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsHeading(
          'Файлы и библиотека',
          'Локальные источники полки. Подключение папки здесь само по себе не разрешает её передачу другим устройствам.',
        ),
        SettingsGroup(
          children: [
            SettingsLink(
              title: 'Папки книг',
              subtitle: 'Источники текстовой библиотеки',
              value: 'Подключено: $readingRoots',
              icon: Icons.folder_open_outlined,
              onTap: assets == null
                  ? null
                  : () => _open(ReadingRootsPage(assets: assets)),
            ),
            SettingsLink(
              title: 'Папки аудиокниг',
              subtitle: 'Источники аудиобиблиотеки',
              value: 'Подключено: $audioRoots',
              icon: Icons.headphones_outlined,
              onTap: assets == null
                  ? null
                  : () => _open(AudioRootsPage(assets: assets)),
            ),
            SettingsLink(
              title: 'Скрытые книги',
              subtitle: 'Вернуть карточку без повторного импорта',
              icon: Icons.visibility_off_outlined,
              onTap: assets == null
                  ? null
                  : () => _open(ReadingHiddenBooksPage(assets: assets)),
            ),
          ],
        ),
        const SettingsNotice(
          'Путь и доступность файла видны в меню книги → «Источник и файл». Карточки синхронизации без локального файла находятся на полке во вкладке «Без файла». Скрытие карточки не удаляет книгу или историю.',
        ),
        SettingsGroup(
          children: [
            SettingsLink(
              title: 'Общие папки для обмена',
              subtitle: 'Отдельно разрешить передачу файлов',
              icon: Icons.folder_shared_outlined,
              onTap: () => _go('sync-folders'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _obsidian() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SettingsHeading(
        'Obsidian',
        'Отдельное подключение к каталогу и заметкам. Его расписание не меняет обмен между ПК и телефоном.',
      ),
      SettingsGroup(
        children: [
          SettingsLink(
            title: 'Подключение',
            subtitle: widget.library.config == null
                ? 'Не настроено'
                : 'Связь с каталогом настроена',
            icon: Icons.link,
            onTap: () async {
              await widget.onConnection();
              if (mounted) await _load();
            },
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Автоматический обмен с Obsidian'),
                const SizedBox(height: 8),
                DropdownButton<int>(
                  key: const ValueKey('obsidian-interval'),
                  isExpanded: true,
                  value: interval,
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('Вручную')),
                    DropdownMenuItem(value: 30, child: Text('Каждые 30 с')),
                    DropdownMenuItem(value: 60, child: Text('Раз в минуту')),
                    DropdownMenuItem(value: 300, child: Text('Раз в 5 минут')),
                    DropdownMenuItem(value: 900, child: Text('Раз в 15 минут')),
                    DropdownMenuItem(
                      value: 1800,
                      child: Text('Раз в 30 минут'),
                    ),
                    DropdownMenuItem(value: 3600, child: Text('Раз в час')),
                  ],
                  onChanged: saving
                      ? null
                      : (value) {
                          if (value != null) {
                            _change(() async {
                              await _save('obsidian-sync-seconds', '$value');
                              if (mounted) setState(() => interval = value);
                            });
                          }
                        },
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _switch(
              'Синхронизировать журнал',
              'Дни, длительность и прогресс связанных книг',
              history,
              (value) => _change(() async {
                await _save('obsidian-sync-history', value ? 'true' : 'false');
                if (mounted) setState(() => history = value);
              }),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _switch(
              'Синхронизировать обложки',
              'Обложки связанных книг и аудиокниг',
              covers,
              (value) => _change(() async {
                await _save('obsidian-sync-covers', value ? 'true' : 'false');
                if (mounted) setState(() => covers = value);
              }),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _switch(
              'Синхронизировать заметки',
              'Цитаты, комментарии, теги и заметки Obsidian',
              notes,
              (value) => _change(() async {
                await _save('obsidian-sync-notes', value ? 'true' : 'false');
                if (mounted) setState(() => notes = value);
              }),
            ),
          ),
        ],
      ),
      if (widget.library.error != null) SettingsNotice(widget.library.error!),
      FilledButton.icon(
        onPressed:
            widget.library.config == null || widget.library.syncing || saving
            ? null
            : () => _change(widget.library.sync),
        icon: widget.library.syncing
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.sync),
        label: Text(
          widget.library.syncing ? 'Обмен с Obsidian…' : 'Обменять с Obsidian',
        ),
      ),
      const SizedBox(height: 12),
      const Text(
        'Обмен с Obsidian и синхронизация устройств запускаются разными кнопками.',
      ),
    ],
  );
  Widget _integrations() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SettingsHeading(
        'Каталоги и инструменты',
        'Настройки источников и вход в словарь и заметки.',
      ),
      SettingsGroup(
        children: [
          SettingsLink(
            title: 'Источники книжных рекомендаций',
            subtitle: 'Inventaire, Open Library и Author.Today',
            icon: Icons.manage_search,
            onTap: () => _open(
              RecommendationSourcesPage(
                store: RecommendationStore(widget.library.local),
              ),
            ),
          ),
          SettingsLink(
            title: 'Словарь Anki',
            subtitle: 'Слова, предложения и экспорт карточек',
            icon: Icons.style_outlined,
            onTap: () => _open(
              VocabularyPage(
                repository: VocabularyRepository(widget.library.local),
              ),
            ),
          ),
        ],
      ),
      SettingsGroup(
        children: [
          SettingsLink(
            title: 'Obsidian',
            subtitle: 'Подключение, журнал, обложки и заметки',
            icon: Icons.link,
            onTap: () => _go('obsidian'),
          ),
          SettingsLink(
            title: 'Заметки Obsidian',
            subtitle: 'Открыть отдельный рабочий экран',
            icon: Icons.notes_outlined,
            onTap: widget.onNotes,
          ),
        ],
      ),
    ],
  );
  Widget _help() {
    final peers = PeerSyncScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsHeading(
          'Помощь и диагностика',
          'Источники книг, результаты обмена и журналы.',
        ),
        SettingsGroup(
          children: [
            SettingsLink(
              title: 'Почему книга без файла?',
              subtitle: 'Проверить источник и связь с папкой',
              icon: Icons.find_in_page_outlined,
              onTap: () => _go('files'),
            ),
            SettingsLink(
              title: 'Журнал синхронизации',
              subtitle: 'Результаты, ошибки и объём данных',
              icon: Icons.receipt_long_outlined,
              onTap: peers == null
                  ? null
                  : () => _open(PeerSyncLogPage(journal: peers.journal)),
            ),
            SettingsLink(
              title: 'Журнал чтения и прослушивания',
              subtitle: 'Просмотр и экспорт своих записей',
              icon: Icons.history,
              onTap: widget.onJournal,
            ),
            SettingsLink(
              title: 'История файлов и очистка',
              subtitle: 'Сначала выберите общую папку',
              icon: Icons.manage_history,
              onTap: () => _go('sync-folders'),
            ),
            SettingsLink(
              title: 'Обновление приложения',
              subtitle: 'Версия и служебные сведения',
              icon: Icons.system_update_outlined,
              onTap: () => _go('updates'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _content(String current, AppTheme appearance) {
    if (current == 'updates' || current == 'update-details') {
      final updates = UpdateScope.of(context);
      return updates == null
          ? const SettingsNotice('Обновления недоступны в этой сборке.')
          : UpdatePage(
              service: updates,
              embedded: true,
              details: current == 'update-details',
              onDetails: () => _go('update-details'),
            );
    }
    if (current == 'sync' || current.startsWith('sync-')) {
      final peers = PeerSyncScope.of(context);
      final part = current == 'sync' ? 'overview' : current.substring(5);
      return peers == null
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SettingsHeading(
                  'Синхронизация',
                  'Прямой обмен между устройствами.',
                ),
                const SettingsNotice(
                  'Прямая синхронизация недоступна в этой сборке.',
                ),
                SettingsGroup(
                  children: [
                    SettingsLink(
                      title: 'Obsidian',
                      subtitle: 'Отдельное подключение к каталогу и заметкам',
                      icon: Icons.link,
                      onTap: () => _go('obsidian'),
                    ),
                  ],
                ),
              ],
            )
          : PeerSyncPage(
              service: peers,
              embedded: true,
              section: part,
              onNavigate: (next) =>
                  _go(next == 'overview' ? 'sync' : 'sync-$next'),
              onObsidian: () => _go('obsidian'),
            );
    }
    final child = switch (current) {
      'appearance' => _appearance(appearance),
      'reading' => _goals(),
      'files' => _files(),
      'obsidian' => _obsidian(),
      'integrations' => _integrations(),
      'help' => _help(),
      _ => _home(),
    };
    return ListView(
      key: ValueKey('settings-content:$current'),
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
      children: [if (error != null) SettingsNotice(error!), child],
    );
  }

  String _area(String current) =>
      current.startsWith('sync') || current == 'obsidian'
      ? 'sync'
      : current.startsWith('update')
      ? 'updates'
      : current;
  Widget _sidebar(String current) => SizedBox(
    width: 248,
    child: Material(
      color: ShelfPalette.of(context).panel,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            right: BorderSide(color: ShelfPalette.of(context).line),
          ),
        ),
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            for (final group in ['Основные', 'Данные', 'Приложение']) ...[
              _groupTitle(group),
              for (final item in _catalog.where((c) => c.group == group))
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: ListTile(
                    key: ValueKey('settings-nav:${item.id}'),
                    selected: _area(current) == item.id,
                    selectedTileColor: ShelfPalette.of(context).selected,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    leading: Icon(item.icon),
                    title: Text(item.title),
                    onTap: () => _go(item.id),
                  ),
                ),
            ],
          ],
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final appearance = ThemeScope.of(context);
    if (appearance == null) {
      return const Scaffold(body: Center(child: Text('Настройки недоступны')));
    }
    return LayoutBuilder(
      builder: (context, size) {
        final wide = size.maxWidth >= 960;
        final current = page == 'home' && wide ? 'appearance' : page;
        return PopScope<void>(
          canPop: navigation.isEmpty,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && navigation.isNotEmpty) _back();
          },
          child: Scaffold(
            appBar: AppBar(
              leading: BackButton(onPressed: _back),
              title: const Text('Настройки'),
            ),
            bottomNavigationBar: const AudioPlayerFooter(),
            body: !loaded
                ? const Center(child: CircularProgressIndicator())
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (wide) _sidebar(current),
                      Expanded(
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 900),
                            child: _content(current, appearance),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        );
      },
    );
  }
}
