/// Дыры второго прохода: строки вне `Text()` — фолбэки, ветки тернарников,
/// возвраты, склейки литералов и аргументы витрины. Гард `l10n_guard_test.dart`
/// ловит эти позиции, словарь обязан за ними поспевать.
/// Ключ — русская строка ровно как в коде (регистр и знаки включно).
final Map<String, String> enB11Holes = {
  // quest_publish_screen.dart
  'Ваш квест отправлен модераторам. Это может занять некоторое время.':
      'Your quest has been sent to the moderators. This may take a while.',
  // table_editor_screen.dart
  // lua_docs_screen.dart
  'Каждый вызов изолирован — локальные переменные вне функций не сохраняются между шагами.':
      'Every call is isolated — local variables outside functions are not kept between steps.',
  'Для сохранения состояния между блоками используйте core.set_var / core.set_table.':
      'To keep state between blocks use core.set_var / core.set_table.',
  'core.get_var(name) — возвращает текущее значение или nil.':
      'core.get_var(name) — returns the current value, or nil.',
  'core.set_var(name, value) — обновляет переменную в состоянии квеста.':
      'core.set_var(name, value) — updates the variable in the quest state.',
  "ВАЖНО: В синтаксисе Lua русские ключи пишите в кавычках и квадратных скобках: ['колонка'] = значение.":
      "IMPORTANT: in Lua syntax put non-Latin keys in quotes inside square brackets: ['column'] = value.",
  "columns — список колонок: {'предмет', 'кол'}.":
      "columns — the list of columns: {'item', 'count'}.",
  "rows — 1-based массив строк-словарей { ['колонка'] = значение }.":
      "rows — a 1-based array of row-dictionaries { ['column'] = value }.",
  'data — словарь ключ-значение для произвольных метаданных таблицы.':
      'data — a key-value map for arbitrary metadata of the table.',
  'В data живёт то же хранилище, что читают блок «Данные» и формулы лавка[\'ключ\']. Сетка (columns/rows) — отдельное содержимое: формулы видят её только через table_cell(...) или ссылку {лавка["цена"][1]}, а Lua меняет её целиком через core.set_table.':
      'data holds the same storage that the "Data" block and the shop[\'key\'] formulas read. The grid (columns/rows) is separate content: formulas see it only through table_cell(...) or a shop["price"][1] reference, and Lua rewrites it whole via core.set_table.',
  'После модификации таблицы сохраните её через core.set_table(имя, таблица).':
      'After changing a table, save it back with core.set_table(name, table).',
  'Все функции возвращают true, если команда записана, и false при пустом id.':
      'Every function returns true when the command was queued, and false for an empty id.',
  'play_music пишет и слот активной музыки — трек возобновится после загрузки сейва.':
      'play_music also writes the active music slot — the track resumes after loading a save.',
  'Смена видимости попадает в состояние игры: спрятанное остаётся спрятанным после перезапуска.':
      'Visibility changes are part of the game state: what was hidden stays hidden after a restart.',
  'Неизвестный адресат set_volume или нераспознанный режим set_item_visible — false, ничего не меняется.':
      'An unknown target for set_volume or an unrecognised mode for set_item_visible returns false and changes nothing.',
  'core.go_to(имя ноды) — возврат из функции после этого не обязателен.':
      'core.go_to(node name) — you do not have to return from the function after it.',
  'open_link вернёт false для локальных и приватных адресов, а также для схем кроме http/https.':
      'open_link returns false for local and private addresses, and for any scheme other than http/https.',
  'Задержки (wait) остаются за блоками: скрипт выполняется атомарно и не «спит» внутри. Плавный переход собирается из core.fade_out / core.fade_in.':
      'Delays (wait) stay with the blocks: a script runs atomically and never "sleeps" inside. A crossfade is assembled from core.fade_out / core.fade_in.',
  'Сетевые запросы (http_request) и вызов другого скрипта (call_script) в Lua пока не прокинуты.':
      'Network requests (http_request) and calling another script (call_script) are not wired into Lua yet.',
  'Нужен тайминг — ставьте блоки вокруг вызова скрипта: call_lua отвечает за логику, блоки — за ритм.':
      'Need timing — put blocks around the script call: call_lua owns the logic, blocks own the rhythm.',
  'Доступные библиотеки: math, string, table, utf8, coroutine и os только с time/clock/date/difftime.':
      'Available libraries: math, string, table, utf8, coroutine, and os limited to time/clock/date/difftime.',
  'Нет io, package, require, dofile, loadfile, debug; string.dump выключен, load принимает только текст, а не байткод.':
      'No io, package, require, dofile, loadfile or debug; string.dump is off and load accepts text only, never bytecode.',
  'Скачанный квест не читает файлы, не видит переменные окружения и не запускает процессы — даже если очень попросит.':
      'A downloaded quest cannot read files, see environment variables or start processes — however hard it tries.',
  'Запись в служебные каналы (_internal_*) запрещена: ссылки, звук и сохранения идут только через core.* с проверками движка.':
      'Writing to engine channels (_internal_*) is forbidden: links, sound and saves go only through core.* with engine-side checks.',
  'Потолки на вызов: 10 млн инструкций, 2 секунды, 32 МБ памяти, 256 команд в очередь; значения переменных и таблиц ограничены по размеру.':
      'Per-call ceilings: 10M instructions, 2 seconds, 32 MB of memory, 256 queued commands; variable and table values are size-limited.',
  'Верхняя панель и затухание (core.set_top_panel, fade_out, fade_in)':
      'Top panel and fading (core.set_top_panel, fade_out, fade_in)',
  'Панель игры и звук: те же служебные каналы, что у блоков set_top_panel и crossfade. Пишите половины затухания сами, если между ними должен идти код, а не вложенные блоки.':
      'Game panel and sound: the same service channels as the set_top_panel and crossfade blocks. Write the fade halves yourself when code, not nested blocks, has to run in between.',
  'Состояние панели попадает в сейв: спрятанная перед переходом останется спрятанной после загрузки.':
      'The panel state is part of the save: hidden before a transition, it stays hidden after loading.',
  'fade_out/fade_in принимают секунды (как поле duration у crossfade) и возвращают false, если очередь команд этого вызова уже полна.':
      'fade_out/fade_in take seconds (like the duration field of crossfade) and return false when this call has filled its command queue.',
  'Сохранения (core.save_game, open_saves, load_save, delete_save)':
      'Saves (core.save_game, open_saves, load_save, delete_save)',
  'Ручные точки сохранения из скрипта: движок кладёт ту же команду, что блок save_operation, а выполняет её клиент в открытой игровой сессии.':
      'Manual save points from a script: the engine queues the same command as the save_operation block, and the client runs it inside the open game session.',
  'load_save без имени открывает список, как блок save_operation; delete_save без имени ничего не делает и возвращает false.':
      'load_save without a name opens the list, like the save_operation block; delete_save without a name does nothing and returns false.',
  'В вебе сохранения выполняет клиент: у ядра нет доступа к файлам.':
      'On the web the client performs the save: the core has no file access.',
  'Отладка (core.log)': 'Debugging (core.log)',
  'Строки core.log попадают в журнал движка рядом с логами блоков — это единственный способ увидеть значения внутри скрипта, не ломая сцену.':
      'core.log lines land in the engine log next to block logs — the only way to see values inside a script without breaking the scene.',
  'Аргументы разделяются табуляцией, таблицы печатаются JSON-ом.':
      'Arguments are separated by tabs; tables are printed as JSON.',
  'За вызов сохраняется до 100 строк по 500 символов: цикл с логом не забьёт журнал.':
      'Up to 100 lines of 500 characters are kept per call, so a logging loop cannot flood the journal.',
  // action_picker_screen.dart
  'Блок «Данные» читает и пишет ключи хранилища скриптов — лавка[\'ключ\']. Ряды сетки он не трогает: для них ссылки {лавка["цена"][1]} и функции table_*.':
      'The "Data" block reads and writes the script storage keys of a table — shop[\'key\']. It never touches grid rows: for those use a shop["price"][1] link and the table_* functions.',
  '«Цикл (таблица)» проходит по рядам сетки, переменная получает целый ряд. Ключи хранилища — блок «Данные».':
      '"Loop (table)" walks the grid rows, and the variable receives a whole row. Storage keys are the "Data" block.',
  'Работает с хранилищем скриптов таблицы, ряды сетки не меняются.\n«Удалить» — по ключу или индексу; «Удалить значение» — по значению в списке.\nПустое поле «Путь» = промах: блок ничего не делает.':
      'Works with the script storage of the table; grid rows stay untouched.\n"Delete" works by key or index; "Delete value" removes a value from the list.\nAn empty "Path" field = a miss: the block does nothing.',
  'Идёт по рядам сетки таблицы. В переменную кладётся целый ряд-словарь: ряд["цена"].':
      'Iterates over the grid rows of the table. The variable gets a whole row-dictionary: row["price"].',
  'Переменные квеста — не то же, что ключи таблицы: их читает {имя}.':
      'Quest variables are not the same thing as table keys — a link with the name inside braces reads them.',
  // button_style_presets_screen.dart
  'Импортировано пресетов: {p0}, текстур: {p1}, пропущено текстур: {p2}':
      'Imported presets: {p0}, textures: {p1}, skipped textures: {p2}',
  // author_analytics_screen.dart
  '{p0} за окно': '{p0} over the window',
  // quest_analytics_screen.dart
  'с {p0} по {p1}': 'from {p0} to {p1}',
  'лайки': 'likes',
  'дизлайки': 'dislikes',
  'просмотр — открытая страница квеста; свой же просмотр автору не считается, повторный заход того же человека внутри получаса — тоже':
      "a view is an opened quest page; the author's own view does not count, and neither does the same person coming back within half an hour",
  'голоса берутся из текущего состояния: снятый сегодня лайк исчезнет из вчерашней колонки':
      "votes come from the current state: a like you retract today disappears from yesterday's column too",
  'игроки — те, кто наиграл в квесте не меньше десяти минут за день; открыл и через минуту вышел — не игрок':
      'players are those who played the quest for at least ten minutes in a day; opened it and left after a minute — not a player',
  'сравнение идёт с предыдущим окном той же длины, поэтому «просело» на 90 днях и «выросло» на 7 — это разные вопросы':
      'the comparison runs against the previous window of the same length, so "dropped" over 90 days and "grew" over 7 are different questions',
  // forum_lobby_screen.dart
  'Заголовок обязателен, до {p0} символов':
      'A title is required, up to {p0} characters',
  'Тело — до {p0} символов, поддерживается markdown и #теги':
      'The body is up to {p0} characters, markdown and #tags are supported',
  'Писать могут только участники — вступитесь':
      'Only members can post — join the community',
  'Пауза между публикациями считается по всем постам, а не по одному сообществу':
      'The pause between posts counts across all posts, not per single community',
  'Пожаловаться на сообщество — в меню сверху':
      'Report a community — from the menu at the top',
  // dm_models.dart
  'Нужны подписчики, опубликованный квест, отзывы, стрик или наигранные часы':
      'Needs followers, a published quest, reviews, a streak or hours played',

  // qst_parser.dart и qst_importer.dart: текст ошибки показывает
  // import_quest_screen.dart через `_showErrorDialog`.
  'Файл не найден: {p0}': 'File not found: {p0}',
  'Неподдерживаемый формат: {p0}. Ожидаются .qst, .txt или .urq':
      'Unsupported format: {p0}. Expected .qst, .txt or .urq',
  'Ошибка чтения файла: {p0}': 'Could not read the file: {p0}',
  'Не найдено ни одной ноды': 'No nodes found',
  'Ошибка парсинга: {p0}': 'Parse error: {p0}',
  // async_import_service.dart: статус импорта на экране «Мои квесты».
  'Распаковка архива (Rust стрим)...': 'Unpacking the archive (Rust stream)...',
  'Сохранение квеста...': 'Saving the quest...',
  'Завершение...': 'Finishing...',
  'Чтение файла URQ...': 'Reading the URQ file...',
  // template_save_dialog.dart: подсказки полей диалога.
  'Название шаблона *': 'Template name *',
  'Описание (необязательно)': 'Description (optional)',
  'Категория (например, UI)': 'Category (for example, UI)',
  // forum_provider.dart: текст ошибки уходит в снакбар.
  'Сервер не вернул сообщество': 'The server did not return the community',
  // table_editor_screen.dart: отчёт об удалении с кнопкой undo.
  // resources_screen.dart: снакбары операций над ресурсами.
  'Скопировано скриптов: {p0}': 'Scripts copied: {p0}',
  'Скопировано: {p0}, с ошибками: {p1}': 'Copied: {p0}, with errors: {p1}',
  'Добавлено {p0} фото': 'Added {p0} photos',
  'Добавлено {p0} аудио': 'Added {p0} audio files',
  'Добавлено {p0} видео': 'Added {p0} videos',
  'Добавлено {p0} шрифтов': 'Added {p0} fonts',
  'Файл "{p0}" заменён': 'File "{p0}" replaced',
  'Ошибка замены файла: {p0}': 'Could not replace the file: {p0}',
  'Сохранено: {p0}': 'Saved: {p0}',
  'Не удалось сохранить файл: {p0}': 'Could not save the file: {p0}',
  'Сохранено файлов: {p0}': 'Files saved: {p0}',
  'Не удалось сохранить: {p0}': 'Could not save: {p0}',
  // quest_cleaner_service.dart: стадии прогресса чистки квеста.
  'Чтение структуры квеста': 'Reading the quest structure',
  'Анализ глав и нод': 'Analysing chapters and nodes',
  'Проверка связности': 'Checking connectivity',
  'Анализ скриптов': 'Analysing scripts',
  'Анализ скриптов ({p0}/{p1})': 'Analysing scripts ({p0}/{p1})',
  'Проверка ресурсов': 'Checking resources',
  'Сканирование завершено': 'Scan complete',
  'Подготовка очистки': 'Preparing cleanup',
  'Создание авто-бэкапа': 'Creating an auto backup',
  'Применение: {p0}': 'Applying: {p0}',
  'Очистка завершена': 'Cleanup complete',
  //  ─ Тексты исключений: friendlyError(e) показывает их человеку ─
  // import_service.dart / async_import_service.dart: выбор файла и распаковка
  'Нет квестов для создания резервной копии.':
      'There are no quests to back up.',
  'Выбран неверный тип файла. Пожалуйста, выберите файл с расширением .mnd':
      'Wrong file type. Please pick a file with a .mnd extension',
  'Выбран неверный тип файла. Пожалуйста, выберите файл с расширением .mnd, .qst или .urq':
      'Wrong file type. Please pick a file with a .mnd, .qst or .urq extension',
  'Файл "config.json" не найден в архиве. Это не квест Meander.':
      'The archive has no "config.json". This is not a Meander quest.',
  'ID квеста не найден в config.json.': 'Quest ID not found in config.json.',
  'Старый формат шифрования MND_ENC_ больше не поддерживается. Попросите автора пересохранить квест в новой версии приложения.':
      'The old MND_ENC_ encryption format is no longer supported. Ask the author to re-save the quest in a newer version of the app.',
  'Не удалось распознать формат файла. Файл поврежден или не является квестом Meander.':
      'Could not recognise the file format. The file is corrupted or is not a Meander quest.',
  // export_service.dart
  'Квест не найден для экспорта': 'Quest not found for export',
  'Критический файл config.json не найден.':
      'Required file config.json not found.',
  // cloud_sync_service.dart
  'Не авторизованы': 'Not authorized',
  'Ошибка получения квоты: {p0}': 'Could not fetch the quota: {p0}',
  'Ошибка списка: {p0}': 'Could not fetch the list: {p0}',
  'Нет доступа к облачному хранилищу. Получите хотя бы starter-уровень.':
      'No access to cloud storage. Get at least the starter tier.',
  // github_sync_service.dart
  'Заполните токен, owner, repo и branch':
      'Fill in the token, owner, repo and branch',
  'GitHub token невалиден ({p0})': 'The GitHub token is invalid ({p0})',
  'Нет доступа к репозиторию {p0}/{p1} ({p2})':
      'No access to the repository {p0}/{p1} ({p2})',
  'Синхронизация выключена в настройках': 'Sync is turned off in settings',
  // post_media_service.dart
  'Чтобы прикреплять фото, войди в аккаунт': 'Sign in to attach photos',
  'Сервер не вернул ссылку на фото':
      'The server did not return a link to the photo',
  // table_export_service.dart: импорт таблиц из CSV и JSON
  'Файл CSV пуст': 'The CSV file is empty',
  'Файл CSV не содержит заголовков': 'The CSV file has no header row',
  'Файл не является корректным JSON': 'The file is not valid JSON',
  'JSON должен содержать объект таблицы':
      'The JSON must contain a table object',
  'Поле "columns" отсутствует или не список':
      'The "columns" field is missing or is not a list',
  'Поле "rows" отсутствует или не список':
      'The "rows" field is missing or is not a list',
  'Каждая строка должна быть объектом': 'Every row must be an object',
  'Неподдерживаемый формат: {p0}': 'Unsupported format: {p0}',
  // theme_registry.dart: импорт пресетов тем
  'Ожидался JSON-объект пресета темы.':
      'Expected a JSON object with a theme preset.',
  'Ожидался JSON-объект или массив пресетов тем.':
      'Expected a JSON object or an array of theme presets.',
  // quest_analytics_provider.dart
  'Сервер вернул не список статистики':
      'The server returned something other than a statistics list',
  // forum_provider.dart
  'Сервер не вернул обсуждение квеста':
      'The server did not return the quest discussion',
  // загрузка файлов: маркет ассетов, пресеты, музыка
  'Лимит 5/час': 'Limit of 5 per hour',
  'Дубликат файла': 'Duplicate file',
  'В архиве нет presets.json': 'The archive has no presets.json',
  'Слишком много загрузок. Подождите час (лимит 5/час).':
      'Too many uploads. Wait an hour (limit of 5 per hour).',
  'Такой файл уже загружен.': 'This file is already uploaded.',
  // market_download_provider.dart / node_provider.dart / avatar_editor_screen.dart
  'Загрузка превысила время ожидания': 'The download took too long',
  'Не удалось скачать файл': 'Could not download the file',
  'Файл не был создан': 'The file was not created',
  'Не удалось сохранить ноду {p0}': 'Could not save the node {p0}',
  'Слишком сильно отодвинули картинку — верните её в квадрат':
      'The picture is dragged too far out — bring it back into the square',
  // quest_provider.dart: подпись квеста и структура config
  'config.json не является JSON-объектом': 'config.json is not a JSON object',
  'backup config.json не является JSON-объектом':
      'backup config.json is not a JSON object',
  'Квест поврежден или модифицирован сторонним лицом (HMAC Error: нет подписи)':
      'The quest is corrupted or modified by a third party (HMAC Error: no signature)',
  'Квест поврежден или модифицирован сторонним лицом (HMAC Error)':
      'The quest is corrupted or modified by a third party (HMAC Error)',
  // menu_screen.dart: вход через браузер
  'Не удалось открыть браузер.': 'Could not open the browser.',
  'Не получен код авторизации.': 'No authorization code was received.',
};
