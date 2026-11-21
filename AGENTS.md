# Правила библиотеки PepeHub

- «Библиотека» — личный архив результатов чтения и прослушивания, а также состава серий. Помимо `finished` (завершено), `abandoned` (брошено) и `paused` (отложено), для томов серий допустим `unread` (не прочитано / не прослушано).
- `planned` и `active` относятся к вкладкам файлов «Книги» / «Аудиокниги» и рекомендациям. В библиотеке их не показывать и не предлагать.
- Наличие файла или подключённой папки само по себе не добавляет произведение в библиотеку. Добавление выполняется явным действием пользователя. При миграциях сохранять его карточки, цитаты, историю и обложки.
- Списки должны работать на сотнях и тысячах произведений: создавать строки лениво, не загружать все аудиотреки и полные текстовые индексы ради экрана списка. Изменения проверять сценариями большого каталога, включая книги и аудиокниги.
- В хранилище карточек вместе с карточками библиотеки лежат служебные записи вкладок файлов (`planned`, `active`, черновики, записи для файлов из корзины). Их сотни; Библиотеку от них отделяет только `isLibraryArchiveItem`. Не расширять набор статусов библиотеки и не ослаблять этот фильтр: иначе служебные записи появятся в Библиотеке, запишутся в папку `PepeHub-library` и через Syncthing уйдут на другие устройства.
- Любое изменение того, что считается карточкой библиотеки, сначала проверять на реальной папке библиотеки (сколько карточек было и станет), а не только на тестах.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

When the user types `/graphify`, use the installed graphify skill or instructions before doing anything else.

Rules:
- When graphify-out/graph.json exists, run `graphify query "<question>"` before your first grep, search or source-file read for a codebase question, and put this rule in every subagent prompt that explores code. Read raw files only for lines the graph or an earlier read already located. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. When the answer is under a Markdown heading, `graphify section "<heading>"` prints that section's text, so the .md need not be opened. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- Dirty graphify-out/ files are expected after hooks or incremental updates; dirty graph files are not a reason to skip graphify. Only skip graphify if the task is about stale or incorrect graph output, or the user explicitly says not to use it.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
- A committed graphify-out/graph.json is rewritten whole on every build, so a large diff to it in a pull request is expected. Do not flag it as churn or suggest skipping the graph rebuild or its hooks.
