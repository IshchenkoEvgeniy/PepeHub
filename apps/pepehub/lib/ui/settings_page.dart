import 'dart:convert';

import 'package:flutter/material.dart';

import '../reader/reader_appearance.dart';
import '../reader/reader_layout.dart';
import '../sync/peer/peer_history_page.dart';
import 'goal_settings_page.dart';
import 'playback_settings_page.dart';
import 'storage_settings_page.dart';
import 'app_preferences.dart';
import 'goal_reminders.dart';
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
import 'audio_recovery_page.dart';
import 'hidden_deleted_page.dart';
import 'reading_roots_page.dart';
import 'import_folder_page.dart';
import 'recommendations_page.dart';
import 'settings_components.dart';
import 'library_data_page.dart';
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
    note: 'Читалка, плеер и общие цели',
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
    id: 'data',
    group: 'Данные',
    title: 'Экспорт и резервные копии',
    note: 'Сохранение, перенос и восстановление библиотеки',
    icon: Icons.backup_outlined,
  ),
  (
    id: 'storage',
    group: 'Данные',
    title: 'Место на диске и кэш',
    note: 'Размер данных и очистка временных файлов',
    icon: Icons.storage_outlined,
  ),
  (
    id: 'reminders',
    group: 'Основные',
    title: 'Напоминания о целях',
    note: 'Время напоминания в приложении',
    icon: Icons.notifications_outlined,
  ),
  (
    id: 'startup',
    group: 'Основные',
    title: 'Запуск приложения',
    note: 'Какую вкладку открывать',
    icon: Icons.home_outlined,
  ),
  (
    id: 'about',
    group: 'Приложение',
    title: 'О приложении',
    note: 'Версия и расположение данных',
    icon: Icons.info_outline,
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
  double? scaleDraft;
  bool loaded = false, saving = false;
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
      final counts = await repo.db
          .customSelect(
            "SELECT COUNT(CASE WHEN key >= 'reading-library-root:' AND key < 'reading-library-root;' THEN 1 END) AS reading, COUNT(CASE WHEN key >= 'audio-library-root:' AND key < 'audio-library-root;' THEN 1 END) AS audio FROM metadata WHERE (key >= 'reading-library-root:' AND key < 'reading-library-root;') OR (key >= 'audio-library-root:' AND key < 'audio-library-root;')",
          )
          .getSingle();
      if (!mounted) return;
      setState(() {
        readingRoots = counts.read<int>('reading');
        audioRoots = counts.read<int>('audio');
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

  void _go(String next, {bool replace = false}) {
    if (page == next && (!replace || navigation.isEmpty)) return;
    setState(() {
      if (replace) {
        navigation.clear();
      } else {
        navigation.add(page);
      }
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
  Future<void> _readerDefaults() async {
    await _change(() async {
      final raw = await widget.library.local.meta('reader:appearance');
      ReaderPreferences preferences;
      try {
        preferences = raw == null
            ? const ReaderPreferences()
            : ReaderPreferences.fromJson(
                jsonDecode(raw) as Map<String, dynamic>,
              );
      } catch (_) {
        preferences = const ReaderPreferences();
      }
      if (!mounted) return;
      final next = await showReaderAppearance(context, preferences);
      if (next != null) {
        await widget.library.local.setMeta(
          'reader:appearance',
          jsonEncode(next.toJson()),
        );
      }
    });
  }

  Widget _goals() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SettingsHeading(
        'Чтение и аудио',
        'Общий профиль читалки, настройки плеера и цели для всех книг.',
      ),
      SettingsGroup(
        children: [
          SettingsLink(
            title: 'Настройки читалки',
            subtitle: 'Шрифт, тема, поля, листание и зоны касания',
            icon: Icons.menu_book_outlined,
            onTap: saving ? null : _readerDefaults,
          ),
          SettingsLink(
            title: 'Настройки плеера аудиокниг',
            subtitle: 'Возврат после паузы, затухание и шаг перемотки',
            icon: Icons.headphones_outlined,
            onTap: () => _open(const PlaybackSettingsPage()),
          ),
          SettingsLink(
            title: 'Цели чтения и прослушивания',
            subtitle: 'Единый экран для настроек и статистики',
            icon: Icons.flag_outlined,
            onTap: () =>
                _open(GoalSettingsPage(repository: widget.library.local)),
          ),
        ],
      ),
      const SettingsNotice(
        'Профиль читалки применяется при открытии книги. Изменения оформления внутри читалки сохраняются в этот же профиль. У PDF отдельно сохраняется режим страниц.',
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
              title: 'Папка добавленных книг',
              enabled: assets != null,
              subtitle: 'Хранение отдельно добавленных текстовых книг',
              icon: Icons.drive_file_move_outlined,
              onTap: assets == null
                  ? null
                  : () => _open(ImportFolderPage(assets: assets)),
            ),
            SettingsLink(
              title: 'Папки книг',
              enabled: assets != null,
              subtitle: 'Источники текстовой библиотеки',
              value: 'Подключено: $readingRoots',
              icon: Icons.folder_open_outlined,
              onTap: assets == null
                  ? null
                  : () => _open(ReadingRootsPage(assets: assets)),
            ),
            SettingsLink(
              title: 'Папки аудиокниг',
              enabled: assets != null,
              subtitle: 'Источники аудиобиблиотеки',
              value: 'Подключено: $audioRoots',
              icon: Icons.headphones_outlined,
              onTap: assets == null
                  ? null
                  : () => _open(AudioRootsPage(assets: assets)),
            ),
            SettingsLink(
              title: 'Скрытое и удалённое',
              enabled: true,
              subtitle: 'Убранные книги, пропавшие файлы и корзина',
              icon: Icons.visibility_off_outlined,
              onTap: () => _open(HiddenDeletedPage(library: widget.library)),
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
            title: 'Цитаты и заметки',
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
              subtitle: 'Как найти источник и вернуть доступ к книге',
              icon: Icons.find_in_page_outlined,
              onTap: () => _go('missing-file'),
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
              subtitle: 'Версии файлов в общих папках',
              icon: Icons.manage_history,
              onTap: () => _go('file-history'),
            ),
            SettingsLink(
              title: 'Снимки и журналы аудиокниг',
              subtitle:
                  'Сохранить снимок или восстановить события прослушивания',
              icon: Icons.restore_page_outlined,
              enabled: widget.library.assets != null,
              onTap: widget.library.assets == null
                  ? null
                  : () => _open(
                      AudioRecoveryPage(assets: widget.library.assets!),
                    ),
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

  Widget _missingFile() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const SettingsHeading(
        'Почему книга без файла?',
        'Карточка и файл книги хранятся отдельно. Синхронизация карточки не всегда передаёт сам файл.',
      ),
      const SettingsNotice(
        '1. Откройте меню нужной книги → «Источник и файл»: там указаны путь и доступность.\n\n2. Если папку переместили или отключили, подключите её снова и обновите список. На Android может потребоваться заново разрешить доступ.\n\n3. Для карточки с другого устройства подключите соответствующую папку или добавьте файл и свяжите его с карточкой. История, цитаты и карточка сохраняются.',
      ),
      SettingsGroup(
        children: [
          SettingsLink(
            title: 'Проверить подключённые папки',
            subtitle: 'Источники книг и аудиокниг на этом устройстве',
            icon: Icons.folder_open_outlined,
            onTap: () => _go('files'),
          ),
        ],
      ),
    ],
  );
  Widget _fileHistory() {
    final peers = PeerSyncScope.of(context);
    final folders = peers?.folders ?? [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsHeading(
          'История файлов и очистка',
          'Выберите папку, чтобы посмотреть версии файлов и освободить место в её истории.',
        ),
        if (folders.isEmpty)
          const SettingsNotice(
            'Общих папок пока нет. История версий доступна для папок, добавленных в синхронизацию.',
          ),
        SettingsGroup(
          children: [
            for (final folder in folders)
              SettingsLink(
                title: folder.name,
                subtitle: folder.root,
                icon: Icons.history,
                onTap: () =>
                    _open(PeerHistoryPage(service: peers!, folder: folder)),
              ),
          ],
        ),
        SettingsLink(
          title: 'Общие папки для обмена',
          subtitle: 'Добавить или настроить папки синхронизации',
          icon: Icons.folder_shared_outlined,
          onTap: () => _go('sync-folders'),
        ),
      ],
    );
  }

  Widget _content(String current, AppTheme appearance) {
    if (current == 'data') {
      return LibraryDataPage(library: widget.library, embedded: true);
    }
    if (current == 'storage') {
      return StorageSettingsPage(assets: widget.library.assets, embedded: true);
    }
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
              ],
            )
          : PeerSyncPage(
              service: peers,
              embedded: true,
              section: part,
              onNavigate: (next) =>
                  _go(next == 'overview' ? 'sync' : 'sync-$next'),
            );
    }
    final child = switch (current) {
      'appearance' => _appearance(appearance),
      'reading' => _goals(),
      'files' => _files(),
      'startup' => StartupSettings(repository: widget.library.local),
      'about' => AboutAppSettings(
        repository: widget.library.local,
        assets: widget.library.assets,
      ),
      'reminders' => GoalReminderSettings(repository: widget.library.local),
      'missing-file' => _missingFile(),
      'file-history' => _fileHistory(),
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

  String _area(String current) => current.startsWith('sync')
      ? 'sync'
      : current.startsWith('update')
      ? 'updates'
      : ['missing-file', 'file-history'].contains(current)
      ? 'help'
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
                    onTap: () => _go(item.id, replace: true),
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
