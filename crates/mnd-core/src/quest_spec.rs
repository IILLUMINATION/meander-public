//! Машиночитаемое описание формата квеста — «карта» для того, кто пишет
//! квест через CLI (`mnd-cli quest spec`).
//!
//! Зачем отдельный модуль: у автора-человека есть редактор, где всё видно
//! глазами, а у генератора — только текст и код возврата. Без списка блоков,
//! полей айтемов и правил ссылок он угадывает формат и получает отказ уже
//! после записи файлов.
//!
//! Список блоков берётся из реестра исполнителя ([`crate::blocks::catalog`]),
//! виды диагностики — из [`crate::validation::DiagnosticKind::ALL`], поэтому
//! справка не отстаёт от кода. Всё остальное — фиксированные правила формата.

use serde_json::{Value, json};

/// Полное описание формата в виде JSON-документа.
pub fn describe() -> Value {
    json!({
        "formatVersion": 2,
        "layout": {
            "questDir": "quests/<questId>/",
            "config": "config.json — заголовок, главы (tags), стартовая нода, таблицы, переменные",
            "nodeIndex": "nodes/index.json — порядок и сводки нод (тела без content)",
            "nodeBody": "nodes/<nodeId>.json — нода целиком, включая content.items",
            "scripts": "scripts/<scriptId>.json — скрипты, по файлу на скрипт",
            "resources": "res/images|audio|videos|fonts/<uuid>.<ext> + res/metadata.json"
        },
        "workflow": [
            "mnd-cli quest spec — этот документ",
            "mnd-cli quest new --title \"…\" → id квеста и стартовой ноды",
            "mnd-cli quest apply --file quest.json [--dry-run] — собрать квест планом",
            "mnd-cli quest validate --quest-id <id> — проверить",
            "mnd-cli --quest-id <id> run /path/scenario.txt — прогнать сценарий headless"
        ],
        "plan": {
            "about": "Декларативный документ: перечисленное состояние применяется к квесту одной транзакцией. Объекты ищутся по id, иначе по названию; найденные обновляются, отсутствующие создаются.",
            "idempotent": "Повторное применение того же плана не создаёт дублей: items заменяют содержимое ноды целиком, таблицы и переменные — по имени, скрипты — по id/имени.",
            "camelCase": "Поля — camelCase (startNode, backgroundImage, rowNames); snake_case тоже принимается.",
            "strict": "Неизвестное поле — ошибка: опечатка не должна молча теряться.",
            "validation": "План проверяется валидатором на состоянии «как будет после записи»; при ошибках на диск ничего не пишется (кроме --force).",
            "fields": {
                "quest": {"title": "string", "author": "string", "description": "string", "startNode": "ссылка на ноду"},
                "chapters": [{"id": "опционально", "name": "string", "cameraScale": "number"}],
                "nodes": [{
                    "id": "опционально, uuid существующей ноды",
                    "title": "string — имя ноды, по нему же ищется",
                    "chapter": "ссылка на главу (id или название)",
                    "x": "number", "y": "number", "start": "bool — сделать стартовой",
                    "color": "ARGB int", "backgroundImage": "файл|res/…|имя ресурса",
                    "backgroundAudio": "то же", "backgroundAudioVolume": "number",
                    "script": "ссылка на скрипт, запускаемый при входе",
                    "timer": "секунды", "timerNode": "ссылка на ноду",
                    "items": "массив айтемов — заменяет содержимое ноды"
                }],
                "scripts": [{"id": "опционально", "name": "string", "event": "onPress|onEnter|onAppear|onQuestStart", "blocks": "массив блоков"}],
                "tables": [{"name": "string", "columns": ["…"], "rows": "массив объектов или массивов", "rowNames": ["…"], "data": "объект"}],
                "variables": [{"name": "string", "default": "любое JSON-значение"}],
                "delete": {"nodes": ["ссылки"], "scripts": ["ссылки"]}
            },
            "example": {
                "quest": {"title": "Мост", "startNode": "Старт"},
                "chapters": [{"name": "Пролог"}],
                "nodes": [
                    {"title": "Старт", "chapter": "Пролог", "start": true, "items": [
                        {"type": "text", "text": "Туман над водой."},
                        {"type": "image", "image": "assets/bridge.png"},
                        {"type": "button", "text": "Идти", "script": "Переход"}
                    ]},
                    {"title": "Мост", "chapter": "Пролог", "items": [{"type": "text", "text": "Доски скрипят."}]}
                ],
                "scripts": [{"name": "Переход", "event": "onPress", "blocks": [
                    {"goto": "Мост"}
                ]}],
                "tables": [{"name": "предметы", "columns": ["name", "price"], "rows": [["Меч", 10]]}],
                "variables": [{"name": "золото", "default": 100}]
            }
        },
        "items": {
            "types": ["text", "image", "button", "row", "stack", "audio", "video", "input", "timer", "modal", "plugin"],
            "commonFields": {
                "id": "uuid; не задан — создаётся",
                "type": "см. types, по умолчанию text",
                "text": "текст/подпись для text|button|input",
                "flex": "доля места в раскладке (по умолчанию 1)",
                "isHidden": "bool", "locked": "bool", "animateIn": "bool",
                "children": "вложенные айтемы для row|stack",
                "scriptAssetId": "ссылка на скрипт по нажатию"
            },
            "shortcuts": {
                "image": "строка — файл на диске (скопируется в res/images), путь res/… или имя ресурса; кладётся в resourcePath",
                "audio": "то же для звука",
                "script": "ссылка на скрипт по id или имени; кладётся в scriptAssetId"
            },
            "layout": "Айтемы ноды идут сверху вниз; row раскладывает children по горизонтали, stack — слоями."
        },
        "scripts": {
            "shape": "{\"blocks\": [ {\"type\": \"event\", \"eventType\": \"onPress\", \"children\": [блоки]} ]}",
            "planShortcuts": {
                "goto": "{\"goto\": \"Нода\"} → go_to_node с разрешённым node_id",
                "call": "{\"call\": \"Скрипт\"} → call_script"
            },
            "nestedBlocks": "condition: then_blocks/else_blocks; for_each и while: children; crossfade: children",
            "references": {
                "node_id": "id, уникальный префикс id (≥4) или название ноды",
                "script_id": "id, имя скрипта или путь scripts/<id>.json",
                "item_id": "id айтема (проверяется по всем нодам квеста)"
            }
        },
        "events": {
            "onPress": "нажатие кнопки/айтема",
            "onEnter": "вход в ноду (в файле — eventType onNodeEnter)",
            "onAppear": "появление контента (eventType onContentAppear)",
            "onQuestStart": "старт квеста"
        },
        "expressions": {
            "variables": "{имя} — значение переменной; {таблица.строка.колонка} — ячейка",
            "operators": "+ - * / % == != < <= > >= && || !",
            "example": "{золото} >= 10"
        },
        "blocks": block_docs(),
        "validation": {
            "kinds": crate::validation::DiagnosticKind::ALL
                .iter()
                .map(|k| k.as_str())
                .collect::<Vec<_>>(),
            "errorsBlockWrite": true,
            "hint": "у каждой диагностики есть message (что и где) и fixHint (что сделать)"
        }
    })
}

/// Справка по блокам: имя, алиасы, категория и главные поля.
///
/// Список имён — из реестра исполнителя; поля описаны рядом, потому что они
/// читаются обработчиком, а не объявлены декларативно.
fn block_docs() -> Value {
    let mut out = Vec::new();
    for entry in crate::blocks::catalog() {
        let (fields, note) = block_fields(entry.name);
        out.push(json!({
            "type": entry.name,
            "title": entry.title,
            "aliases": entry.aliases,
            "category": entry.category,
            "fields": fields,
            "note": note,
        }));
    }
    Value::Array(out)
}

fn block_fields(name: &str) -> (Vec<&'static str>, &'static str) {
    match name {
        "event" => (
            vec!["eventType", "children"],
            "корневой блок скрипта; в плане создаётся сам",
        ),
        "assign_variable" => (
            vec!["variable", "value"],
            "value — JSON-значение или выражение; создаёт переменную при отсутствии",
        ),
        "table_operation" => (
            vec!["tableName", "operation", "path", "value", "targetVariable"],
            "operation: get (path → targetVariable) | set (path+value) | add (path-список) \
             | remove (path-ключ) | remove_value (path+value) | clear (path) | contains (path+value)",
        ),
        "set_image" => (
            vec!["item_id", "source"],
            "item_id проверяется по всем нодам; source — путь res/…",
        ),
        "set_visible" => (vec!["item_id", "mode"], "mode: show|hide|remove|toggle"),
        "condition" => (
            vec!["expression", "then_blocks", "else_blocks"],
            "либо expression целиком, либо variable+comparison+value",
        ),
        "go_to_node" => (
            vec!["node_id"],
            "переход на ноду; в плане можно {\"goto\": \"Название\"}",
        ),
        "wait" => (vec!["expression"], "миллисекунды: число или выражение"),
        "for_each" => (
            vec!["table", "children", "itemVariable", "indexVariable"],
            "перебирает строки таблицы",
        ),
        "while" => (
            vec!["expression", "children"],
            "цикл с условием; нужен wait внутри",
        ),
        "call_script" => (
            vec!["script_id"],
            "вызов другого скрипта; в плане можно {\"call\": \"Имя\"}",
        ),
        "call_function" => (vec!["function_id"], "вызов именованной функции скрипта"),
        "call_lua" => (vec!["script", "function", "args"], "вызов Lua-функции"),
        "comment" => (vec!["text"], "комментарий на канвасе, ничего не исполняет"),
        "play_sound" | "stop_sound" | "play_music" | "stop_music" | "pause_resume" => (
            vec!["audio_id", "volume", "loop", "global"],
            "звук; в старых квестах тип может называться type=playSound и т.п.",
        ),
        "crossfade" => (vec!["children", "ms"], "плавная смена сцены"),
        "open_link" => (vec!["url"], "открывает ссылку во внешнем браузере"),
        "http_request" => (
            vec![
                "url",
                "method",
                "headers",
                "body",
                "targetVariable",
                "statusVariable",
            ],
            "сетевой запрос; результат пишется в переменную",
        ),
        "save_operation" => (
            vec!["operation", "slotName"],
            "operation: save|open|load|delete",
        ),
        "set_blur" => (vec!["blur"], "размытие слоя"),
        "set_volume" => (vec!["volume", "target"], "громкость"),
        _ => (vec![], "поля см. в реестре блоков"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_registered_block_is_documented() {
        let doc = describe();
        let blocks = doc["blocks"].as_array().expect("blocks — массив");
        let names: Vec<&str> = blocks.iter().filter_map(|b| b["type"].as_str()).collect();
        for expected in [
            "assign_variable",
            "table_operation",
            "set_image",
            "set_visible",
            "condition",
            "go_to_node",
            "wait",
            "for_each",
            "while",
            "call_script",
            "call_function",
            "call_lua",
            "comment",
            "play_sound",
            "stop_sound",
            "play_music",
            "stop_music",
            "pause_resume",
            "crossfade",
            "open_link",
            "http_request",
            "save_operation",
            "set_blur",
            "set_volume",
        ] {
            assert!(names.contains(&expected), "блок {expected} не описан");
        }
    }

    #[test]
    fn diagnostic_list_matches_serialization() {
        for kind in crate::validation::DiagnosticKind::ALL {
            let value = serde_json::to_value(kind).unwrap();
            assert_eq!(value.as_str(), Some(kind.as_str()));
        }
    }
}
