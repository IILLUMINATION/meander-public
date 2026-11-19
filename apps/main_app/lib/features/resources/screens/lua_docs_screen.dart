import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:canvas_app/core/l10n/l10n.dart';
import 'package:canvas_app/shared/widgets/adaptive_ui.dart';

/// Полноценный экран интерактивной документации по Lua-скриптам в Meander.
class LuaDocsScreen extends StatefulWidget {
  const LuaDocsScreen({super.key});

  @override
  State<LuaDocsScreen> createState() => _LuaDocsScreenState();
}

class _LuaDocsScreenState extends State<LuaDocsScreen> {
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final docItems = _getFilteredDocs(_searchQuery);

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        title: Text(
          tr('Документация Lua'),
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
      ),
      body: AdaptiveContent(
        maxWidth: 860,
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: SearchBar(
                  controller: _searchController,
                  onChanged: (val) =>
                      setState(() => _searchQuery = val.trim().toLowerCase()),
                  hintText: tr('Поиск по API, примерам, таблицам...'),
                  leading: const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Icon(Icons.search_rounded),
                  ),
                  trailing: [
                    if (_searchQuery.isNotEmpty)
                      IconButton(
                        icon: const Icon(Icons.clear_rounded),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      ),
                  ],
                  elevation: const WidgetStatePropertyAll(0),
                  backgroundColor: WidgetStatePropertyAll(
                    scheme.surfaceContainerHigh,
                  ),
                  shape: WidgetStatePropertyAll(
                    RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: docItems.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.search_off_rounded,
                              size: 48,
                              color: scheme.onSurfaceVariant,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              tr('Ничего не найдено'),
                              style: TextStyle(
                                color: scheme.onSurfaceVariant,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                        itemCount: docItems.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 16),
                        itemBuilder: (context, index) {
                          final item = docItems[index];
                          return _DocCard(
                            item: item,
                            scheme: scheme,
                            isDark: isDark,
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<_DocItem> _getFilteredDocs(String query) {
    if (query.isEmpty) return _kDocs;
    return _kDocs.where((doc) {
      return doc.title.toLowerCase().contains(query) ||
          doc.description.toLowerCase().contains(query) ||
          (doc.code != null && doc.code!.toLowerCase().contains(query));
    }).toList();
  }
}

class _DocItem {
  final String title;
  final String category;
  final IconData icon;
  final String description;
  final String? code;
  final List<String> bulletPoints;

  const _DocItem({
    required this.title,
    required this.category,
    required this.icon,
    required this.description,
    this.code,
    this.bulletPoints = const [],
  });
}

class _DocCard extends StatelessWidget {
  final _DocItem item;
  final ColorScheme scheme;
  final bool isDark;

  const _DocCard({
    required this.item,
    required this.scheme,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: isDark
            ? scheme.surfaceContainerHigh
            : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.5),
          width: 0.8,
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  item.icon,
                  size: 20,
                  color: scheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.category.toUpperCase(),
                      style: TextStyle(
                        color: scheme.primary,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.6,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            item.description,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 13.5,
              height: 1.45,
            ),
          ),
          if (item.bulletPoints.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final point in item.bulletPoints)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 6, right: 8),
                      child: CircleAvatar(
                        radius: 3,
                        backgroundColor: scheme.primary,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        point,
                        style: TextStyle(
                          color: scheme.onSurface,
                          fontSize: 13,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
          if (item.code != null) ...[
            const SizedBox(height: 12),
            _DocCodeBox(code: item.code!, scheme: scheme, isDark: isDark),
          ],
        ],
      ),
    );
  }
}

class _DocCodeBox extends StatelessWidget {
  final String code;
  final ColorScheme scheme;
  final bool isDark;

  const _DocCodeBox({
    required this.code,
    required this.scheme,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: isDark
            ? const Color(0xFF181A1F)
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: scheme.outlineVariant.withValues(alpha: 0.4),
          width: 0.8,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SelectableText(
              code,
              style: TextStyle(
                color: isDark ? const Color(0xFFABB2BF) : scheme.onSurface,
                fontFamily: GoogleFonts.jetBrainsMono().fontFamily,
                fontSize: 12.5,
                height: 1.45,
              ),
            ),
          ),
          IconButton(
            icon: Icon(
              Icons.copy_rounded,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
            tooltip: tr('Копировать пример'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: code));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(tr('Код скопирован в буфер')),
                    behavior: SnackBarBehavior.floating,
                    duration: const Duration(seconds: 2),
                    backgroundColor: scheme.primary,
                  ),
                );
              }
            },
          ),
        ],
      ),
    );
  }
}

// Геттер, а не final-таблица: список строится под текущий язык, иначе
// переключение языка не перекрасило бы эти подписи.
List<_DocItem> get _kDocs => [
  _DocItem(
    title: tr('Быстрый старт & Функция start()'),
    category: tr('Основы'),
    icon: Icons.play_arrow_rounded,
    description: tr(
      'Скрипт вызывается блоком call_lua или триггером. При вызове исполняется функция, указанная в блоке (по умолчанию start).',
    ),
    code: """function start()
    local hp = core.get_var('hp') or 100
    core.set_var('hp', hp - 15)

    if hp <= 0 then
        return { node = 'game_over' }
    end
    return { node = 'next_chapter' }
end""",
    bulletPoints: [
      tr(
        'Каждый вызов изолирован — локальные переменные вне функций не сохраняются между шагами.',
      ),
      tr(
        'Для сохранения состояния между блоками используйте core.set_var / core.set_table.',
      ),
    ],
  ),
  _DocItem(
    title: tr('Переменные движка (core.get_var / core.set_var)'),
    category: tr('Переменные'),
    icon: Icons.data_object_rounded,
    description: tr(
      'Интерфейс работы с переменными квеста. Поддерживает числа, строки и булевы значения.',
    ),
    code: tr('''-- Получить значение переменной (nil если не существует)
local gold = core.get_var('gold') or 0

-- Записать новое значение
core.set_var('gold', gold + 50)
core.set_var('has_sword', true)
core.set_var('player_name', 'Артур')'''),
    bulletPoints: [
      tr('core.get_var(name) — возвращает текущее значение или nil.'),
      tr(
        'core.set_var(name, value) — обновляет переменную в состоянии квеста.',
      ),
    ],
  ),
  _DocItem(
    title: tr('Таблицы квеста (QuestTable, get_table / set_table)'),
    category: tr('Таблицы'),
    icon: Icons.table_chart_rounded,
    description: tr(
      "QuestTable — единое хранилище таблиц со структурой { name, columns, rows, data }. В Lua нелатинские (русские) имена колонок в словарях задаются в скобках ['имя'].",
    ),
    code: """function buy_item()
    -- Получаем таблицу или создаём новую, если её ещё нет
    local inv = core.get_table('инвентарь') or {
        name = 'инвентарь',
        columns = {'предмет', 'кол'},
        rows = {},
        data = {}
    }
    
    -- Добавляем новую запись в rows (русские ключи — через ['имя'])
    local n = #inv.rows
    inv.rows[n + 1] = {
        ['предмет'] = 'Зелье лечения',
        ['кол'] = 3
    }
    
    -- Сохраняем обратно в движок
    core.set_table('инвентарь', inv)
end""",
    bulletPoints: [
      tr(
        "ВАЖНО: В синтаксисе Lua русские ключи пишите в кавычках и квадратных скобках: ['колонка'] = значение.",
      ),
      tr("columns — список колонок: {'предмет', 'кол'}."),
      tr("rows — 1-based массив строк-словарей { ['колонка'] = значение }."),
      tr("data — словарь ключ-значение для произвольных метаданных таблицы."),
      tr(
        "В data живёт то же хранилище, что читают блок «Данные» и формулы лавка['ключ']. Сетка (columns/rows) — отдельное содержимое: формулы видят её только через table_cell(...) или ссылку {лавка[\"цена\"][1]}, а Lua меняет её целиком через core.set_table.",
      ),
      tr(
        "После модификации таблицы сохраните её через core.set_table(имя, таблица).",
      ),
    ],
  ),
  _DocItem(
    title: tr(
      'Триггеры событий (onQuestStart, onNodeEnter, onPress, onContentAppear, onDataChange)',
    ),
    category: tr('События'),
    icon: Icons.bolt_rounded,
    description: tr(
      'Lua-файлы могут выступать обработчиками событий триггеров квеста. onQuestStart движок вызывает у .lua-файлов из папки scripts/ квеста — один раз при запуске игры, до первой ноды; список «глобальных скриптов» в настройках квеста для этого не нужен. onDataChange — диспетчер изменений данных: файл должен объявлять это событие (см. ниже), подписки задаёт визуальный блок «При изменении данных».',
    ),
    code: """-- Запуск квеста: стартовые переменные и общие функции
-- (файл лежит в scripts/ квеста, движок найдёт его сам)
function onQuestStart()
    core.set_var('gold', 0)
end
-- для скрипта ноды то же самое делает функция start(), если onQuestStart нет

-- Триггер нажатия кнопки / контента
function onPress(item_id)
    if item_id == 'btn_attack' then
        core.set_var('boss_hp', (core.get_var('boss_hp') or 100) - 20)
    end
end

-- Триггер входа в ноду
function onNodeEnter()
    core.set_var('visited_count', (core.get_var('visited_count') or 0) + 1)
end

-- Диспетчер изменений: paths — список путей, которые изменились с прошлого
-- шага ('gold', 'table.лавка.цена', 'table.лавка.цена.3'). Файл обязан
-- объявлять событие: добавьте в него пустую function onDataChange(paths) end,
-- иначе движок его не найдёт. Скрипт из scripts/ следит всё время,
-- скрипт ноды — только пока игрок в ней.
function onDataChange(paths)
    for _, path in ipairs(paths) do
        if path == 'gold' then
            core.play_sound('coin', 0.5)
        end
    end
end""",
  ),
  _DocItem(
    title: tr(
      'Звук и музыка (core.play_sound, stop_sound, play_music, stop_music, pause_resume)',
    ),
    category: tr('Эффекты'),
    icon: Icons.volume_up_rounded,
    description: tr(
      'Аудио из скрипта работает ровно так же, как блоки play_sound / play_music: команды попадают в ту же очередь и переживают сохранение.',
    ),
    code:
        """-- Короткий звук: id из библиотеки ресурсов, громкость 0..1 (по умолчанию 1)
core.play_sound('hit', 0.4)

-- Музыка: третий аргумент — таблица опций
core.play_music('boss_theme', {
    volume = 0.5,
    loop = false,      -- по умолчанию true
    global = true,     -- играть дальше на других нодах
})

core.stop_sound('hit')     -- без аргумента — остановить все
core.stop_music()
core.pause_resume('music', 'pause')  -- action: pause / resume / toggle""",
    bulletPoints: [
      tr(
        'Все функции возвращают true, если команда записана, и false при пустом id.',
      ),
      tr(
        'play_music пишет и слот активной музыки — трек возобновится после загрузки сейва.',
      ),
    ],
  ),
  _DocItem(
    title: tr(
      'Контент ноды (core.set_item_visible, set_item_image, set_volume, set_blur)',
    ),
    category: tr('Эффекты'),
    icon: Icons.visibility_rounded,
    description: tr(
      'Тот же язык, что у блоков set_visible, set_image и настроек громкости/блюра, — с теми же значениями.',
    ),
    code: """-- Спрятать, убрать или показать айтем по id
core.set_item_visible('photo', 'hidden')  -- не видно, место в рядке занято
core.set_item_visible('photo', 'gone')    -- не видно и ряд схлопывается
core.set_item_visible('photo', 'show')
core.set_item_visible('photo', 'toggle')  -- прятать с сохранением места

-- Сменить картинку (и true/1 тоже считаются)
core.set_item_visible('boss', false)

-- Заменить источник изображения
core.set_item_image('portrait', 'res/images/cat.png')

-- Громкость контента ноды / тегов, фон размыть
core.set_volume('contentAudio', 0.3)
core.set_volume('tagAudio', 0.8)
core.set_blur(12)""",
    bulletPoints: [
      tr(
        'Смена видимости попадает в состояние игры: спрятанное остаётся спрятанным после перезапуска.',
      ),
      tr(
        'Неизвестный адресат set_volume или нераспознанный режим set_item_visible — false, ничего не меняется.',
      ),
    ],
  ),
  _DocItem(
    title: tr('Переход и внешняя ссылка (core.go_to, core.open_link)'),
    category: tr('Управление'),
    icon: Icons.alt_route_rounded,
    description: tr(
      'go_to ведёт на другую ноду по имени, open_link открывает ссылку — оба проверяются движком до исполнения.',
    ),
    code: """-- Переход: явный go_to важнее возвращаемой таблицы
function onPress(item_id)
    if item_id == 'door' then
        core.go_to('тёмный коридор')
        return
    end
    -- можно и через возврат — движок читает ключ node
    return { node = 'next_chapter' }
end

-- Ссылка наружу (фильтр тот же, что у блока open_link)
if core.open_link('https://example.com/manual') then
    core.set_var('link_shown', true)
end""",
    bulletPoints: [
      tr(
        'core.go_to(имя ноды) — возврат из функции после этого не обязателен.',
      ),
      tr(
        'open_link вернёт false для локальных и приватных адресов, а также для схем кроме http/https.',
      ),
    ],
  ),
  _DocItem(
    title: tr(
      'Верхняя панель и затухание (core.set_top_panel, fade_out, fade_in)',
    ),
    category: tr('Эффекты'),
    icon: Icons.movie_filter_rounded,
    description: tr(
      'Панель игры и звук: те же служебные каналы, что у блоков set_top_panel и crossfade. Пишите половины затухания сами, если между ними должен идти код, а не вложенные блоки.',
    ),
    code: """-- Спрятать панель на катсцене и вернуть после
core.set_top_panel('hide')   -- show / hide / toggle
-- ...
core.set_top_panel('show')

-- Затухание звука в секундах: блок crossfade делает оба шага вокруг детей
core.fade_out(1.5)
-- смена музыки/сцены
core.play_music('night_theme', { volume = 0.6 })
core.fade_in(0.5)""",
    bulletPoints: [
      tr(
        'Состояние панели попадает в сейв: спрятанная перед переходом останется спрятанной после загрузки.',
      ),
      tr(
        'fade_out/fade_in принимают секунды (как поле duration у crossfade) и возвращают false, если очередь команд этого вызова уже полна.',
      ),
    ],
  ),
  _DocItem(
    title: tr(
      'Сохранения (core.save_game, open_saves, load_save, delete_save)',
    ),
    category: tr('Управление'),
    icon: Icons.save_alt_rounded,
    description: tr(
      'Ручные точки сохранения из скрипта: движок кладёт ту же команду, что блок save_operation, а выполняет её клиент в открытой игровой сессии.',
    ),
    code: """-- Сохранить под именем (пустое имя — «Сохранение»)
core.save_game('Перед боссом')

-- Открыть список сохранений / загрузить по имени / удалить
core.open_saves()
core.load_save('Перед боссом')
core.delete_save('Черновик')

-- Проверить, что команда ушла
if core.save_game('Чекпоинт') then
    core.log('сейв запрошен')
end""",
    bulletPoints: [
      tr(
        'load_save без имени открывает список, как блок save_operation; delete_save без имени ничего не делает и возвращает false.',
      ),
      tr('В вебе сохранения выполняет клиент: у ядра нет доступа к файлам.'),
    ],
  ),
  _DocItem(
    title: tr('Отладка (core.log)'),
    category: tr('Основы'),
    icon: Icons.terminal_rounded,
    description: tr(
      'Строки core.log попадают в журнал движка рядом с логами блоков — это единственный способ увидеть значения внутри скрипта, не ломая сцену.',
    ),
    code: """function onPress(item_id)
    core.log('нажали', item_id)
    local gold = core.get_var('gold') or 0
    core.log('золото до', gold)
    core.set_var('gold', gold + 10)
end

-- Таблица печатается как JSON, строки — как есть
core.log({hp = 10, name = 'Арт'})""",
    bulletPoints: [
      tr('Аргументы разделяются табуляцией, таблицы печатаются JSON-ом.'),
      tr(
        'За вызов сохраняется до 100 строк по 500 символов: цикл с логом не забьёт журнал.',
      ),
    ],
  ),
  _DocItem(
    title: tr('Чего Lua пока не хватает'),
    category: tr('Ограничения'),
    icon: Icons.hourglass_bottom_rounded,
    description: tr(
      'Эффекты, переменные, сохранения и отладка доступны из скрипта; темп сцены — нет.',
    ),
    bulletPoints: [
      tr(
        'Задержки (wait) остаются за блоками: скрипт выполняется атомарно и не «спит» внутри. Плавный переход собирается из core.fade_out / core.fade_in.',
      ),
      tr(
        'Сетевые запросы (http_request) и вызов другого скрипта (call_script) в Lua пока не прокинуты.',
      ),
      tr(
        'Нужен тайминг — ставьте блоки вокруг вызова скрипта: call_lua отвечает за логику, блоки — за ритм.',
      ),
    ],
  ),
  _DocItem(
    title: tr('Песочница и безопасность'),
    category: tr('Безопасность'),
    icon: Icons.shield_rounded,
    description: tr(
      'Исполнение скриптов строго изолировано в безопасной песочнице Rust-ядра:',
    ),
    bulletPoints: [
      tr(
        'Доступные библиотеки: math, string, table, utf8, coroutine и os только с time/clock/date/difftime.',
      ),
      tr(
        'Нет io, package, require, dofile, loadfile, debug; string.dump выключен, load принимает только текст, а не байткод.',
      ),
      tr(
        'Скачанный квест не читает файлы, не видит переменные окружения и не запускает процессы — даже если очень попросит.',
      ),
      tr(
        'Запись в служебные каналы (_internal_*) запрещена: ссылки, звук и сохранения идут только через core.* с проверками движка.',
      ),
      tr(
        'Потолки на вызов: 10 млн инструкций, 2 секунды, 32 МБ памяти, 256 команд в очередь; значения переменных и таблиц ограничены по размеру.',
      ),
    ],
  ),
];
