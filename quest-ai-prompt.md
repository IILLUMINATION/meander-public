# Промт: создание квеста Meander (.mnd)

Ты — ИИ-агент в песочнице. У тебя есть только файловая система: создание каталогов и файлов, запись JSON и сборка ZIP. Никаких CLI, библиотек и инструментов проекта нет. Создай с нуля играбельный квест Meander и выдай один файл `.mnd`. Без заданной темы сделай короткий связный квест с выборами, переменными и достижимым финалом.

Формат ниже — готовая спецификация, не требуй пояснений и не ищи инструменты: плеер Meander читает `.mnd` как ZIP с описанными файлами. Не выдавай план вместо результата: собери каталог, проверь, упакуй.

ЖЁСТКИЕ ПРАВИЛА
- ВСЕГДА РОВНО ОДНА СТАРТОВАЯ НОДА; `config.startNodeId` — её точный `id`.
- ВСЕ ID УНИКАЛЬНЫ; ID — строки без пробелов (`n_start`, `ch1`, `s_talk`), UUID тоже годятся.
- КАЖДАЯ ССЫЛКА РАЗРЕШАЕТСЯ: `startNodeId`, `chapterId`, `node_id`, `script_id`, `behaviours[].script`, `resourcePath`.
- У КАЖДОЙ НОДЫ ЕСТЬ `chapterId`, `content.items` и файл `nodes/<id>.json`; её сводка есть в `nodes/index.json`.
- ВСЕ НОДЫ ДОСТИЖИМЫ ОТ СТАРТА; каждая ветка завершается переходом или финалом.
- ТОЛЬКО КАНОНИЧЕСКИЙ JSON: двойные кавычки, без комментариев и висячих запятых; `camelCase`.
- НЕ ССЫЛАЙСЯ НА ОТСУТСТВУЮЩИЕ ФАЙЛЫ; нет медиа — только текст, кнопки, таблицы.
- СКРИПТЫ ТОЛЬКО JSON, Lua не нужен.

ФАЙЛЫ
`.mnd` — ZIP с путями от корня квеста, без внешней папки, с 8-байтовым префиксом `MND_ZIP_`. Не шифруй. Содержимое: `config.json`, `nodes/index.json`, `nodes/<id>.json`, `scripts/<id>.json`, `res/metadata.json`, при необходимости `res/images|audio|videos|fonts/…`.

`config.json` — настройки, главы, старт, переменные, таблицы. Главы лежат в `tags`; значение переменной — `defaultValue`:

```json
{"id":"q1","title":"Название","author":"Автор","description":"Описание","version":"1.0.0",
 "startNodeId":"n_start","scriptEngineMode":"new",
 "tags":[{"id":"ch1","name":"Глава 1","cameraState":{"offsetX":0,"offsetY":0,"scale":1}}],
 "variables":[{"name":"золото","defaultValue":0}],"tables":[],"genres":[]}
```

`nodes/index.json` — порядок и сводки; сводка = тело ноды без `content` плюс `"type":"node"`:

```json
{"format_version":2,"card_preview_version":0,
 "nodes":[{"id":"n_start","title":"Начало","chapterId":"ch1","x":0,"y":0,"type":"node"}],
 "groups":[],"comments":[],"edges":[]}
```

`nodes/<id>.json` — полная нода:

```json
{"id":"n_start","title":"Начало","chapterId":"ch1","x":0,"y":0,
 "content":{"items":[
  {"id":"i1","type":"text","text":"Текст сцены."},
  {"id":"i2","type":"button","text":"Идти","behaviours":[{"event":"onPress","script":"scripts/s_go.json"}]}
 ]}}
```

Айтемы: `text`, `button`, `image`, `row`, `column`, `stack`, `audio`, `input`, `timer`, `delay`, `wait_input`, `modal`, `chat`, `video`, `plugin`, `spacer`. `row`/`column`/`stack` держат `children`. Текст — `text`; кнопка — `text` и `behaviours`; картинка — `resourcePath`; `input` — `variableName`, `placeholderText`, событие `onSubmit`. `scriptAssetId` У АЙТЕМА НЕ ОБРАБАТЫВАЕТ НАЖАТИЕ: только `behaviours` (legacy `scriptTriggers`). `row` кладёт детей по горизонтали, `column` — по вертикали, `stack` — слоями.

СКРИПТЫ
Файл: `{"name":"Переход","blocks":[...]}`. Действия оборачивай в событие:

```json
{"type":"event","eventType":"onPress","children":[{"type":"go_to_node","node_id":"n_next"}]}
```

События: `onQuestStart`, `onNodeEnter`, `onPress`, `onContentAppear`, `onDataChange` (с `watchPaths`), `function` (с `functionName`). Скрипт ноды — `scriptAssetId` = `scripts/<id>.json` с событием `onNodeEnter`; скрипт кнопки — в `behaviours` с `onPress`. Нет блоков-событий → для `onNodeEnter`/`onQuestStart`/`onContentAppear` выполнятся все блоки; для кнопки так не делай.

Блоки и точные поля:
- `assign_variable`: `variable`, `value` — литерал или выражение; создаёт переменную.
- `condition`: `expression`, `then_blocks`, `else_blocks`.
- `go_to_node`: `node_id` — точный ID.
- `wait`: `expression` — миллисекунды; обязателен внутри долгих циклов.
- `call_script`: `script_id` — id/имя без пути и расширения; `call_function`: `function_id`.
- `for_each`: `table`, `var_prefix` (`row`), `index_variable` (`i`), `children`; в строке доступны `{row_<колонка>}`.
- `while`: `expression` | `count` | `from`/`to`/`step`; `loop_var`, `max_iterations`, `children`.
- `table_operation`: `tableName`, `operation` (`get`, `set`, `add`, `remove`, `remove_value`, `clear`, `contains`), `path`, `value`, `targetVariable`.
- `set_visible`: `item_id`, `mode` (`show`, `hide`, `remove`, `toggle`); `set_image`: `item_id`, `source` (`res/images/…`).
- `save_operation`: `operation` (`save`, `open`, `load`, `delete`), `slotName`.
- `play_sound`/`stop_sound`/`play_music`/`stop_music`/`pause_resume`: `audio_id`, `volume`, `loop`, `global`, `target`.
- `set_volume`: `volume`, `target` (`contentAudio`/`tagAudio`); `set_blur`: `blur`; `set_top_panel`: `mode`; `crossfade`: `children`, `ms`; `open_link`: `url`; `http_request`: `url`, `method`, `headers`, `body`, `targetVariable`, `statusVariable`; `comment`: `text`.

ВЫРАЖЕНИЯ
`{имя}` — переменная. Операторы: `+ - * / %`, `== != < <= > >=`, `&& || !`, скобки. Пример: `{золото} >= 10 && {дверь_открыта} == false`. В тексте тоже работает: `У тебя {золото} монет.` Строковый литерал — в кавычках.

ТАБЛИЦЫ
В `config.tables`:

```json
[{"name":"лавка","columns":["товар","цена"],"rows":[{"товар":"меч","цена":10}],"rowNames":["меч"],"data":{"открыта":true}}]
```

Адреса: `{лавка["цена"]}` — колонка, `{лавка["цена"][1]}` — строка 1 (счёт с 1), `{лавка["цена"]["меч"]}` — по `rowNames`, `{лавка["открыта"]}` — из `data`. Промах — `null`. `rows`/`columns` зарезервированы. Ресурсы: `res/metadata.json` — объект (без ресурсов `{}`), файл — `res/<тип>/<uuid>.<ext>`.

УПАКОВКА
`quest/` — корень квеста:

```python
import os, zipfile
with zipfile.ZipFile("quest.zip", "w", zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk("quest"):
        for f in files:
            p = os.path.join(root, f)
            z.write(p, os.path.relpath(p, "quest"))
open("quest.mnd", "wb").write(b"MND_ZIP_" + open("quest.zip", "rb").read())
```

ПРОВЕРКА
- Все JSON парсятся; `format_version` = `2`; префикс `MND_ZIP_` на месте.
- `startNodeId` существует и это ровно одна нода; все `chapterId` есть в `tags`; ID уникальны.
- Индекс и `nodes/` совпадают по составу; `content` в индексе отсутствует.
- Все `node_id`, `script_id`, `behaviours[].script` разрешаются; ноды и финал достижимы; в циклах есть `wait`; нет ссылок на неупакованные файлы.
- Выдай готовый `.mnd` и его имя.