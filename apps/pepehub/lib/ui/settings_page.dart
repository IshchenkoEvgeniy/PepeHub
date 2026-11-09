import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../diagnostics/error_log_page.dart';
import '../diagnostics/user_message.dart';
import '../library/library_service.dart';
import '../media/audio_player_scope.dart';
import '../reader/reader_appearance.dart';
import '../reader/reader_layout.dart';
import '../recommendations/recommendation_store.dart';
import '../updates/update_page.dart';
import '../updates/update_service.dart';
import 'app_preferences.dart';
import 'app_theme.dart';
import 'audio_mini_player.dart';
import 'audio_recovery_page.dart';
import 'audio_roots_page.dart';
import 'goal_settings_page.dart';
import 'hidden_deleted_page.dart';
import 'hotkeys_settings.dart';
import 'import_folder_page.dart';
import 'interface_settings.dart';
import 'library_data_page.dart';
import 'playback_settings_page.dart';
import 'reading_roots_page.dart';
import 'recommendations_page.dart';
import 'settings_components.dart';
import 'shelf_components.dart';
import 'storage_settings_page.dart';

/// Top-level sections of the settings catalog, in display order.
enum SettingsArea {
  interface(
    'Основные',
    'Интерфейс',
    'Тема, размер текста и стартовая вкладка',
    Icons.palette_outlined,
  ),
  reading(
    'Основные',
    'Чтение и аудио',
    'Читалка, плеер, цели и напоминания',
    Icons.menu_book_outlined,
  ),
  files(
    'Данные',
    'Библиотека и файлы',
    'Папки книг, скрытые книги и рекомендации',
    Icons.folder_open_outlined,
  ),
  data(
    'Данные',
    'Резервные копии и экспорт',
    'Папка библиотеки, копии и экспорт',
    Icons.backup_outlined,
  ),
  storage(
    'Данные',
    'Хранилище',
    'Место на диске, кэш и сжатие базы',
    Icons.storage_outlined,
  ),
  about(
    'Приложение',
    'О приложении',
    'Версия, обновления и расположение данных',
    Icons.info_outline,
  ),
  help(
    'Приложение',
    'Диагностика и справка',
    'Журналы, восстановление и горячие клавиши',
    Icons.help_outline,
  );

  final String group, title, note;
  final IconData icon;
  const SettingsArea(this.group, this.title, this.note, this.icon);

  static const groups = ['Основные', 'Данные', 'Приложение'];
}

/// A place in settings: the catalog, a section, or a page inside a section.
@immutable
class SettingsRoute {
  final SettingsArea? area;

  /// Page inside [area]: `player` and `goals` in reading; `details` in about;
  /// `missing-file` and `hotkeys` in help.
  final String? page;
  const SettingsRoute(SettingsArea this.area, [this.page]);
  const SettingsRoute.home() : area = null, page = null;

  @override
  bool operator ==(Object other) =>
      other is SettingsRoute && other.area == area && other.page == page;
  @override
  int get hashCode => Object.hash(area, page);
}

/// One searchable setting: what it is called, where it lives and other words
/// people may type for it.
typedef SettingsSearchEntry = ({
  String title,
  SettingsRoute route,
  String keywords,
});

const settingsSearchIndex = <SettingsSearchEntry>[
  (
    title: 'Тема и палитра',
    route: SettingsRoute(SettingsArea.interface),
    keywords: 'цвет оформление светлая тёмная темная ночь день бумага',
  ),
  (
    title: 'Как в системе',
    route: SettingsRoute(SettingsArea.interface),
    keywords: 'светлая тёмная автоматически система',
  ),
  (
    title: 'Размер текста интерфейса',
    route: SettingsRoute(SettingsArea.interface),
    keywords: 'шрифт масштаб крупнее мельче',
  ),
  (
    title: 'Компактный интерфейс',
    route: SettingsRoute(SettingsArea.interface),
    keywords: 'плотность отступы',
  ),
  (
    title: 'Уменьшить анимации',
    route: SettingsRoute(SettingsArea.interface),
    keywords: 'движение эффекты переходы',
  ),
  (
    title: 'Начальная вкладка',
    route: SettingsRoute(SettingsArea.interface),
    keywords: 'запуск старт открывать',
  ),
  (
    title: 'Настройки читалки',
    route: SettingsRoute(SettingsArea.reading),
    keywords: 'шрифт поля листание зоны касания кнопки громкости профиль',
  ),
  (
    title: 'Плеер аудиокниг',
    route: SettingsRoute(SettingsArea.reading, 'player'),
    keywords: 'аудио плеер звук',
  ),
  (
    title: 'Скорость для новых книг',
    route: SettingsRoute(SettingsArea.reading, 'player'),
    keywords: 'скорость воспроизведения по умолчанию',
  ),
  (
    title: 'Шаг перемотки',
    route: SettingsRoute(SettingsArea.reading, 'player'),
    keywords: 'назад вперёд вперед секунды',
  ),
  (
    title: 'Возврат после паузы и таймера',
    route: SettingsRoute(SettingsArea.reading, 'player'),
    keywords: 'сон таймер затухание звонок прерывание',
  ),
  (
    title: 'Цели чтения и прослушивания',
    route: SettingsRoute(SettingsArea.reading, 'goals'),
    keywords: 'минут в день неделю план',
  ),
  (
    title: 'Напоминания',
    route: SettingsRoute(SettingsArea.reading, 'goals'),
    keywords: 'уведомления время напомнить',
  ),
  (
    title: 'Папки книг',
    route: SettingsRoute(SettingsArea.files),
    keywords: 'источники текстовые подключить',
  ),
  (
    title: 'Папки аудиокниг',
    route: SettingsRoute(SettingsArea.files),
    keywords: 'источники аудио подключить',
  ),
  (
    title: 'Папка добавленных книг',
    route: SettingsRoute(SettingsArea.files),
    keywords: 'импорт хранение',
  ),
  (
    title: 'Скрытые и недоступные',
    route: SettingsRoute(SettingsArea.files),
    keywords: 'корзина удалённые удаленные ненайденные',
  ),
  (
    title: 'Источники рекомендаций',
    route: SettingsRoute(SettingsArea.files),
    keywords: 'open library inventaire author.today каталоги',
  ),
  (
    title: 'Резервные копии',
    route: SettingsRoute(SettingsArea.data),
    keywords: 'бэкап восстановить экспорт перенос папка библиотеки синхронизация syncthing телефон пк',
  ),
  (
    title: 'Место на диске',
    route: SettingsRoute(SettingsArea.storage),
    keywords: 'кэш очистить временные размер база сжать',
  ),
  (
    title: 'Обновления',
    route: SettingsRoute(SettingsArea.about),
    keywords: 'версия apk установить',
  ),
  (
    title: 'Расположение данных',
    route: SettingsRoute(SettingsArea.about),
    keywords: 'путь база хранилище отладка',
  ),
  (
    title: 'Журнал ошибок',
    route: SettingsRoute(SettingsArea.help),
    keywords: 'сбои диагностика',
  ),
  (
    title: 'Журнал синхронизации',
    route: SettingsRoute(SettingsArea.help),
    keywords: 'обмен ошибки',
  ),
  (
    title: 'Снимки и журналы аудиокниг',
    route: SettingsRoute(SettingsArea.help),
    keywords: 'восстановить прослушивание',
  ),
  (
    title: 'Почему книга без файла?',
    route: SettingsRoute(SettingsArea.help, 'missing-file'),
    keywords: 'нет файла источник недоступна',
  ),
  (
    title: 'Горячие клавиши',
    route: SettingsRoute(SettingsArea.help, 'hotkeys'),
    keywords: 'клавиатура сочетания shortcuts',
  ),
];

String _normalize(String text) => text.toLowerCase().replaceAll('ё', 'е');

/// Entries matching every word of [query], in index order.
List<SettingsSearchEntry> searchSettings(String query) {
  final words = _normalize(query)
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return const [];
  return [
    for (final entry in settingsSearchIndex)
      if (words.every(
        (word) => _normalize(
          '${entry.title} ${entry.route.area!.title} ${entry.keywords}',
        ).contains(word),
      ))
        entry,
  ];
}

class SettingsPage extends StatefulWidget {
  final LibraryService library;
  const SettingsPage({super.key, required this.library});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool loaded = false;
  SettingsRoute route = const SettingsRoute.home();
  String? error;
  final navigation = <SettingsRoute>[];
  int readingRoots = 0, audioRoots = 0;
  bool wide = false;
  final search = TextEditingController();
  final searchFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.library.addListener(_libraryChanged);
    search.addListener(_searchChanged);
    _load();
  }

  @override
  void dispose() {
    widget.library.removeListener(_libraryChanged);
    search.dispose();
    searchFocus.dispose();
    super.dispose();
  }

  void _libraryChanged() {
    if (mounted) setState(() {});
  }

  void _searchChanged() {
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
          error = 'Не удалось прочитать настройки: ${describeError(e)}';
          loaded = true;
        });
      }
    }
  }

  void _go(SettingsRoute next, {bool replace = false}) {
    if (route == next && (!replace || navigation.isEmpty)) return;
    setState(() {
      if (replace) {
        navigation.clear();
      } else {
        navigation.add(route);
      }
      route = next;
    });
  }

  void _openFromSearch(SettingsRoute next) {
    search.clear();
    searchFocus.unfocus();
    // On a phone the catalog stays below, so «back» returns to the search.
    _go(next, replace: wide);
  }

  void _back() {
    if (navigation.isNotEmpty) {
      setState(() => route = navigation.removeLast());
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

  Widget _searchField() => TextField(
    key: const ValueKey('settings-search'),
    controller: search,
    focusNode: searchFocus,
    textInputAction: TextInputAction.search,
    decoration: InputDecoration(
      hintText: 'Поиск настроек',
      prefixIcon: const Icon(Icons.search),
      suffixIcon: search.text.isEmpty
          ? null
          : IconButton(
              tooltip: 'Очистить',
              onPressed: search.clear,
              icon: const Icon(Icons.close),
            ),
    ),
    onSubmitted: (_) {
      final results = searchSettings(search.text);
      if (results.isNotEmpty) _openFromSearch(results.first.route);
    },
  );

  Widget _searchResults({bool dense = false}) {
    final results = searchSettings(search.text);
    if (results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'Ничего не найдено',
          style: TextStyle(color: ShelfPalette.of(context).muted),
        ),
      );
    }
    final links = [
      for (final entry in results)
        SettingsLink(
          key: ValueKey('settings-search-result:${entry.title}'),
          title: entry.title,
          subtitle: entry.route.area!.title,
          icon: entry.route.area!.icon,
          onTap: () => _openFromSearch(entry.route),
        ),
    ];
    return dense
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: links,
          )
        : SettingsGroup(children: links);
  }

  Widget _home() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _searchField(),
      if (search.text.trim().isNotEmpty) ...[
        const SizedBox(height: 18),
        _searchResults(),
      ] else
        for (final group in SettingsArea.groups) ...[
          _groupTitle(group),
          SettingsGroup(
            children: [
              for (final area in SettingsArea.values.where(
                (a) => a.group == group,
              ))
                SettingsLink(
                  key: ValueKey('settings-entry:${area.name}'),
                  title: area.title,
                  subtitle: area.note,
                  icon: area.icon,
                  onTap: () => _go(SettingsRoute(area)),
                ),
            ],
          ),
        ],
    ],
  );

  Future<ReaderPreferences> _readerPreferences() async {
    final raw = await widget.library.local.meta('reader:appearance');
    try {
      return raw == null
          ? const ReaderPreferences()
          : ReaderPreferences.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const ReaderPreferences();
    }
  }

  Future<void> _readerDefaults() async {
    try {
      final preferences = await _readerPreferences();
      if (!mounted) return;
      final next = await showReaderAppearance(context, preferences);
      if (next != null) {
        await widget.library.local.setMeta(
          'reader:appearance',
          jsonEncode(next.toJson()),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Изменение не сохранено: ${describeError(e)}'),
          ),
        );
      }
    }
  }

  Widget _reading() {
    final player = AudioPlayerScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsHeading(
          'Чтение и аудио',
          'Общий профиль читалки, плеер аудиокниг, цели и напоминания.',
        ),
        SettingsGroup(
          children: [
            SettingsLink(
              title: 'Настройки читалки',
              subtitle: 'Шрифт, тема, поля, листание и зоны касания',
              icon: Icons.menu_book_outlined,
              onTap: _readerDefaults,
            ),
            SettingsLink(
              key: const ValueKey('settings-link:player'),
              title: 'Плеер аудиокниг',
              subtitle: 'Скорость, шаг перемотки, возврат после паузы',
              value: player == null
                  ? null
                  : 'Шаг ${player.seekStepSeconds}/${player.seekForwardSeconds} с',
              icon: Icons.headphones_outlined,
              onTap: () =>
                  _go(const SettingsRoute(SettingsArea.reading, 'player')),
            ),
            SettingsLink(
              key: const ValueKey('settings-link:goals'),
              title: 'Цели и напоминания',
              subtitle: 'Минуты в день и в неделю, ежедневное напоминание',
              icon: Icons.flag_outlined,
              onTap: () =>
                  _go(const SettingsRoute(SettingsArea.reading, 'goals')),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
          child: Text(
            'Оформление, изменённое внутри читалки, сохраняется в этот же профиль. У PDF режим страниц хранится отдельно.',
            style: TextStyle(color: ShelfPalette.of(context).muted),
          ),
        ),
        SettingsResetButton(
          what: 'профиль читалки',
          onReset: () async {
            try {
              await widget.library.local.setMeta(
                'reader:appearance',
                jsonEncode(const ReaderPreferences().toJson()),
              );
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Сброс не выполнен: ${describeError(e)}'),
                  ),
                );
              }
            }
          },
        ),
      ],
    );
  }

  Widget _files() {
    final assets = widget.library.assets;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsHeading(
          'Библиотека и файлы',
          'Источники книг на этом устройстве. Подключённая папка не передаётся другим устройствам, пока её не добавят в общие.',
        ),
        SettingsGroup(
          children: [
            SettingsLink(
              title: 'Папки книг',
              enabled: assets != null,
              subtitle: 'Источники текстовой библиотеки',
              value: libraryCount(readingRoots, 'папка', 'папки', 'папок'),
              icon: Icons.folder_open_outlined,
              onTap: assets == null
                  ? null
                  : () => _open(ReadingRootsPage(assets: assets)),
            ),
            SettingsLink(
              title: 'Папки аудиокниг',
              enabled: assets != null,
              subtitle: 'Источники аудиобиблиотеки',
              value: libraryCount(audioRoots, 'папка', 'папки', 'папок'),
              icon: Icons.headphones_outlined,
              onTap: assets == null
                  ? null
                  : () => _open(AudioRootsPage(assets: assets)),
            ),
            SettingsLink(
              title: 'Папка добавленных книг',
              enabled: assets != null,
              subtitle: 'Куда сохраняются отдельно добавленные книги',
              icon: Icons.drive_file_move_outlined,
              onTap: assets == null
                  ? null
                  : () => _open(ImportFolderPage(assets: assets)),
            ),
            SettingsLink(
              title: 'Скрытые и недоступные',
              subtitle: 'Скрытые книги, ненайденные файлы и корзина',
              icon: Icons.visibility_off_outlined,
              onTap: () => _open(HiddenDeletedPage(library: widget.library)),
            ),
          ],
        ),
        const SettingsSubheading('Рекомендации'),
        SettingsGroup(
          children: [
            SettingsLink(
              title: 'Источники рекомендаций',
              subtitle: 'Inventaire, Open Library и Author.Today',
              icon: Icons.manage_search,
              onTap: () => _open(
                RecommendationSourcesPage(
                  store: RecommendationStore(widget.library.local),
                ),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
          child: Text(
            'Скрытие карточки не удаляет книгу и историю. Если у книги нет файла — см. «Диагностика и справка».',
            style: TextStyle(color: ShelfPalette.of(context).muted),
          ),
        ),
      ],
    );
  }

  Widget _help() {
    final assets = widget.library.assets;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsHeading(
          'Диагностика и справка',
          'Ответы на частые вопросы, журналы и восстановление.',
        ),
        const SettingsSubheading('Справка'),
        SettingsGroup(
          children: [
            SettingsLink(
              key: const ValueKey('settings-link:missing-file'),
              title: 'Почему книга без файла?',
              subtitle: 'Как найти источник и вернуть доступ к книге',
              icon: Icons.find_in_page_outlined,
              onTap: () =>
                  _go(const SettingsRoute(SettingsArea.help, 'missing-file')),
            ),
            SettingsLink(
              key: const ValueKey('settings-link:hotkeys'),
              title: 'Горячие клавиши',
              subtitle: 'Читалка, PDF, видео и поиск',
              icon: Icons.keyboard_outlined,
              onTap: () =>
                  _go(const SettingsRoute(SettingsArea.help, 'hotkeys')),
            ),
          ],
        ),
        const SettingsSubheading('Диагностика'),
        SettingsGroup(
          children: [
            SettingsLink(
              title: 'Журнал ошибок',
              subtitle: 'Сбои приложения с подробностями',
              icon: Icons.bug_report_outlined,
              onTap: () => _open(const ErrorLogPage()),
            ),
            SettingsLink(
              title: 'Снимки и журналы аудиокниг',
              subtitle: 'Сохранить снимок или восстановить прослушивание',
              icon: Icons.restore_page_outlined,
              onTap: assets == null
                  ? null
                  : () => _open(AudioRecoveryPage(assets: assets)),
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
        'Карточка и файл книги хранятся отдельно. Папка библиотеки переносит карточки, но не сами файлы книг.',
      ),
      const SettingsNotice(
        '1. Откройте меню книги → «Источник и файл»: там указаны путь и доступность.\n\n2. Если папку переместили или отключили, подключите её снова и обновите список. На Android может понадобиться заново разрешить доступ.\n\n3. Чтобы книга была на обоих устройствах, держите её файл в папке, которую синхронизирует Syncthing, и подключите эту папку как источник книг на каждом устройстве.',
      ),
      SettingsGroup(
        children: [
          SettingsLink(
            title: 'Проверить подключённые папки',
            subtitle: 'Источники книг и аудиокниг на этом устройстве',
            icon: Icons.folder_open_outlined,
            onTap: () =>
                _go(const SettingsRoute(SettingsArea.files), replace: true),
          ),
        ],
      ),
    ],
  );

  /// Pages with their own scrolling list (data, storage, about).
  Widget? _embedded(SettingsRoute current) {
    final area = current.area;
    switch (area) {
      case SettingsArea.data:
        return LibraryDataPage(library: widget.library, embedded: true);
      case SettingsArea.storage:
        return StorageSettingsPage(
          assets: widget.library.assets,
          embedded: true,
        );
      case SettingsArea.about:
        final updates = UpdateScope.of(context);
        final about = AboutAppSettings(
          repository: widget.library.local,
          assets: widget.library.assets,
        );
        if (updates == null) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
            children: [
              const SettingsHeading(
                'О приложении',
                'PepeHub — личная библиотека, читалка и журнал чтения и прослушивания.',
              ),
              const SettingsNotice('Обновления недоступны в этой сборке.'),
              about,
            ],
          );
        }
        return UpdatePage(
          service: updates,
          embedded: true,
          heading: 'О приложении',
          details: current.page == 'details',
          onDetails: () =>
              _go(const SettingsRoute(SettingsArea.about, 'details')),
          extra: [about],
        );
      default:
        return null;
    }
  }

  Widget _section(SettingsRoute current, AppTheme appearance) =>
      switch ((current.area, current.page)) {
        (SettingsArea.interface, _) => InterfaceSettings(
          appearance: appearance,
          repository: widget.library.local,
        ),
        (SettingsArea.reading, 'player') => const PlaybackSettings(),
        (SettingsArea.reading, 'goals') => GoalAndReminderSettings(
          repository: widget.library.local,
        ),
        (SettingsArea.reading, _) => _reading(),
        (SettingsArea.files, _) => _files(),
        (SettingsArea.help, 'missing-file') => _missingFile(),
        (SettingsArea.help, 'hotkeys') => const HotkeysSettings(),
        (SettingsArea.help, _) => _help(),
        _ => _home(),
      };

  Widget _content(SettingsRoute current, AppTheme appearance) {
    final embedded = _embedded(current);
    final key = ValueKey(
      'settings-content:${current.area?.name ?? 'home'}:${current.page ?? ''}',
    );
    if (embedded != null) {
      if (error == null) return KeyedSubtree(key: key, child: embedded);
      return Column(
        key: key,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: SettingsNotice(error!),
          ),
          Expanded(child: embedded),
        ],
      );
    }
    return ListView(
      key: key,
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
      children: [
        if (error != null) SettingsNotice(error!),
        _section(current, appearance),
      ],
    );
  }

  Widget _sidebar(SettingsRoute current) => SizedBox(
    width: 260,
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
            _searchField(),
            if (search.text.trim().isNotEmpty) ...[
              const SizedBox(height: 12),
              _searchResults(dense: true),
            ] else
              for (final group in SettingsArea.groups) ...[
                _groupTitle(group),
                for (final area in SettingsArea.values.where(
                  (a) => a.group == group,
                ))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: ListTile(
                      key: ValueKey('settings-nav:${area.name}'),
                      selected: current.area == area,
                      selectedTileColor: ShelfPalette.of(context).selected,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      leading: Icon(area.icon),
                      title: Text(area.title),
                      onTap: () => _go(SettingsRoute(area), replace: true),
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
        wide = size.maxWidth >= 960;
        final current = route.area == null && wide
            ? const SettingsRoute(SettingsArea.interface)
            : route;
        return PopScope<void>(
          canPop: navigation.isEmpty,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop && navigation.isNotEmpty) _back();
          },
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(
                LogicalKeyboardKey.keyK,
                control: true,
              ): () {
                if (!wide && route.area != null) {
                  _go(const SettingsRoute.home(), replace: true);
                }
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => searchFocus.requestFocus(),
                );
              },
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
          ),
        );
      },
    );
  }
}
