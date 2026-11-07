//! Канонизация и валидация формата визуальных скриптов.
//!
//! ЕДИНСТВЕННОЕ место, где живёт знание о легаси-формах. Порт семантики
//! из клиентского `parser.dart::_normalize` — расхождение ловится
//! golden-тестами на общих фикстурах (`tests/fixtures/script_format`).
//!
//! Правила нормализации (идемпотентны):
//! 1. Русские/старые алиасы типов → канонические
//!    (`задержка`→wait, `условие`→condition, `while_loop`→while, …).
//! 2. Легаси-события: тип зашит в `title` («При запуске ноды» и т.п.) →
//!    `type:"event"` + `eventType`.
//! 3. `wait`: легаси `milliseconds` → `expression`.
//! 4. `condition`: легаси `variable/comparison/value` (+русские ключи) →
//!    собранное `expression`; `если_да/если_нет` → `then_blocks/else_blocks`.

use serde_json::{Map, Value};

/// Канонические имена типов (реестр блоков — `blocks::registry`).
pub mod types {
    pub const EVENT: &str = "event";
    pub const CONDITION: &str = "condition";
    pub const ASSIGN_VARIABLE: &str = "assign_variable";
    pub const GO_TO_NODE: &str = "go_to_node";
    pub const CALL_SCRIPT: &str = "call_script";
    pub const CALL_FUNCTION: &str = "call_function";
    pub const CALL_LUA: &str = "call_lua";
    pub const TABLE_OPERATION: &str = "table_operation";
    pub const SET_IMAGE: &str = "set_image";
    pub const SET_VISIBLE: &str = "set_visible";
    pub const FOR_EACH: &str = "for_each";
    pub const WHILE: &str = "while";
    pub const WAIT: &str = "wait";
    pub const COMMENT: &str = "comment";
    pub const SET_VOLUME: &str = "set_volume";
    pub const SET_BLUR: &str = "set_blur";
    pub const PLAY_SOUND: &str = "play_sound";
    pub const STOP_SOUND: &str = "stop_sound";
    pub const PLAY_MUSIC: &str = "play_music";
    pub const STOP_MUSIC: &str = "stop_music";
    pub const PAUSE_RESUME: &str = "pause_resume";
    pub const CROSSFADE: &str = "crossfade";
    pub const OPEN_LINK: &str = "open_link";
    pub const HTTP_REQUEST: &str = "http_request";
}

const LEGACY_TITLE_ON_NODE_ENTER: &str = "При запуске ноды";
const LEGACY_TITLE_ON_PRESS: &str = "При нажатии";
const TITLE_ON_QUEST_START: &str = "При запуске квеста";
const TITLE_ON_DATA_CHANGE: &str = "При изменении данных";
const TITLE_FUNCTION: &str = "Функция";

fn canonical_type(raw: &str) -> Option<&'static str> {
    Some(match raw {
        "задержка" => types::WAIT,
        "условие" => types::CONDITION,
        "create_variable" | "set_variable" | "создать_переменную" | "изменить_переменную" => {
            types::ASSIGN_VARIABLE
        }
        "while_loop" | "пока" => types::WHILE,
        _ => return None,
    })
}

/// Нормализовать один блок (на месте). Идемпотентно.
pub fn normalize_block(block: &mut Map<String, Value>) {
    // 1. Алиас типа.
    if let Some(t) = block.get("type").and_then(Value::as_str)
        && let Some(canonical) = canonical_type(t)
    {
        block.insert("type".into(), Value::String(canonical.into()));
    }

    let type_str = block
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();

    // 2. Легаси-события: eventType выведен из title / отсутствует вовсе.
    if type_str == types::EVENT || (type_str.is_empty() && block.contains_key("title")) {
        if type_str.is_empty() {
            block.insert("type".into(), Value::String(types::EVENT.into()));
        }
        if !block
            .get("eventType")
            .and_then(Value::as_str)
            .is_some_and(|s| !s.trim().is_empty())
        {
            let title = block.get("title").and_then(Value::as_str).unwrap_or("");
            let event_type = match title {
                LEGACY_TITLE_ON_NODE_ENTER => "onNodeEnter",
                LEGACY_TITLE_ON_PRESS => "onPress",
                TITLE_ON_QUEST_START => "onQuestStart",
                TITLE_ON_DATA_CHANGE => "onDataChange",
                TITLE_FUNCTION => "function",
                _ => "onContentAppear",
            };
            block.insert("eventType".into(), Value::String(event_type.into()));
        }
        return;
    }

    // 3. wait: milliseconds → expression.
    if type_str == types::WAIT
        && !block.contains_key("expression")
        && block.contains_key("milliseconds")
    {
        let ms = block
            .get("milliseconds")
            .map(value_to_plain_string)
            .unwrap_or_default();
        block.insert("expression".into(), Value::String(ms));
    }

    // 4. condition: легаси-поля → expression + английские ветки.
    if type_str == types::CONDITION {
        if !block.contains_key("expression")
            && (block.contains_key("variable") || block.contains_key("переменная"))
        {
            let variable = block
                .get("variable")
                .or_else(|| block.get("переменная"))
                .map(value_to_plain_string)
                .unwrap_or_default();
            let comparison = block
                .get("comparison")
                .or_else(|| block.get("сравнение"))
                .map(value_to_plain_string)
                .filter(|s| !s.trim().is_empty())
                .unwrap_or_else(|| "==".into());
            let raw_value = block
                .get("value")
                .or_else(|| block.get("значение"))
                .map(value_to_plain_string)
                .unwrap_or_else(|| "0".into());

            let literal = quote_condition_value(&raw_value);
            block.insert(
                "expression".into(),
                Value::String(format!("{{{variable}}} {comparison} {literal}")),
            );
        }
        if let Some(then) = block.remove("если_да")
            && !block.contains_key("then_blocks")
        {
            block.insert("then_blocks".into(), then);
        }
        if let Some(els) = block.remove("если_нет")
            && !block.contains_key("else_blocks")
        {
            block.insert("else_blocks".into(), els);
        }
    }
}

/// Значение условия как строка без кавычек-обёртки Value::String.
fn value_to_plain_string(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

/// Числа и ссылки `{var}` — как есть; остальное — строка в одинарных кавычках.
/// Паритет с parser.dart и executor.rs:615-649.
pub fn quote_condition_value(value: &str) -> String {
    let is_numeric = value.parse::<f64>().is_ok();
    let is_var_ref = value.starts_with('{') && value.ends_with('}');
    let already_quoted = value.starts_with('\'') || value.starts_with('"');
    if is_numeric || is_var_ref || already_quoted {
        value.to_string()
    } else {
        format!("'{value}'")
    }
}

/// Рекурсивно нормализовать скрипт ({blocks:[…]}) или отдельный список
/// детей. Проходит по children/then_blocks/else_blocks. Идемпотентно.
pub fn normalize_script(script: &mut Value) {
    match script {
        Value::Array(items) => {
            for item in items.iter_mut() {
                normalize_script(item);
            }
        }
        Value::Object(map) => {
            normalize_block(map);
            for key in ["blocks", "children", "then_blocks", "else_blocks"] {
                if let Some(Value::Array(items)) = map.get_mut(key) {
                    for item in items.iter_mut() {
                        normalize_script(item);
                    }
                }
            }
        }
        _ => {}
    }
}

/// Удобная обёртка для объектов скрипта: клонирует, нормализует, отдаёт.
pub fn normalized_clone(script: &Map<String, Value>) -> Map<String, Value> {
    let mut copy = Value::Object(script.clone());
    normalize_script(&mut copy);
    match copy {
        Value::Object(map) => map,
        _ => script.clone(), // недостижимо
    }
}

// ─── Валидация ─────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq)]
pub struct ValidationIssue {
    /// Машиночитаемый код: unknown_type / missing_field / duplicate_id /
    /// bad_value / too_deep.
    pub code: &'static str,
    /// JSON-pointer-подобный путь: blocks[0].children[2]
    pub path: String,
    pub message: String,
    pub severity: Severity,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Severity {
    Error,
    Warning,
}

impl ValidationIssue {
    fn error(code: &'static str, path: &str, message: impl Into<String>) -> Self {
        Self {
            code,
            path: path.into(),
            message: message.into(),
            severity: Severity::Error,
        }
    }
    fn warning(code: &'static str, path: &str, message: impl Into<String>) -> Self {
        Self {
            code,
            path: path.into(),
            message: message.into(),
            severity: Severity::Warning,
        }
    }
}

/// Валидация уже нормализованного скрипта. Не исполняет выражения —
/// только структурные контракты типов из реестра ядра.
pub fn validate_script(script: &Map<String, Value>) -> Vec<ValidationIssue> {
    let mut issues = Vec::new();
    let mut seen_ids: std::collections::HashSet<String> = Default::default();
    walk_validate(
        script.get("blocks").and_then(Value::as_array),
        "blocks",
        0,
        &mut issues,
        &mut seen_ids,
    );
    issues
}

fn required_nonempty(block: &Map<String, Value>, keys: &[&str]) -> Option<String> {
    for k in keys {
        if let Some(v) = block.get(*k) {
            let s = value_to_plain_string(v);
            if !s.trim().is_empty() {
                return None;
            }
        }
    }
    Some(keys.first().map(|s| s.to_string()).unwrap_or_default())
}

fn walk_validate(
    blocks: Option<&Vec<Value>>,
    path: &str,
    depth: usize,
    issues: &mut Vec<ValidationIssue>,
    seen_ids: &mut std::collections::HashSet<String>,
) {
    let Some(blocks) = blocks else { return };
    if depth > 32 {
        issues.push(ValidationIssue::error(
            "too_deep",
            path,
            "глубина вложенности > 32",
        ));
        return;
    }

    for (i, item) in blocks.iter().enumerate() {
        let child_path = format!("{path}[{i}]");
        let Some(map) = item.as_object() else {
            issues.push(ValidationIssue::error(
                "bad_value",
                &child_path,
                "блок не является объектом",
            ));
            continue;
        };

        let raw_type = map.get("type").and_then(Value::as_str).unwrap_or("");
        let known = matches!(
            raw_type,
            types::EVENT
                | types::CONDITION
                | types::ASSIGN_VARIABLE
                | types::GO_TO_NODE
                | types::CALL_SCRIPT
                | types::CALL_FUNCTION
                | types::CALL_LUA
                | types::TABLE_OPERATION
                | types::SET_IMAGE
                | types::SET_VISIBLE
                | types::FOR_EACH
                | types::WHILE
                | types::WAIT
                | types::COMMENT
                | types::SET_VOLUME
                | types::SET_BLUR
                | types::PLAY_SOUND
                | types::STOP_SOUND
                | types::PLAY_MUSIC
                | types::STOP_MUSIC
                | types::PAUSE_RESUME
                | types::CROSSFADE
                | types::OPEN_LINK
                | types::HTTP_REQUEST
        );

        if let Some(id) = map.get("id").and_then(Value::as_str)
            && !seen_ids.insert(id.to_string())
        {
            issues.push(ValidationIssue::error(
                "duplicate_id",
                &child_path,
                format!("дубликат id '{id}' внутри скрипта"),
            ));
        }

        if !known && raw_type != "unknown" {
            issues.push(ValidationIssue::warning(
                "unknown_type",
                &child_path,
                format!("неизвестный тип блока '{raw_type}' (сохранён as-is)"),
            ));
        }

        // Обязательные поля по типу (после нормализации).
        match raw_type {
            types::ASSIGN_VARIABLE => {
                if let Some(field) = required_nonempty(map, &["variable"]) {
                    issues.push(ValidationIssue::error(
                        "missing_field",
                        &child_path,
                        format!("assign_variable без '{field}'"),
                    ));
                }
            }
            types::SET_IMAGE => {
                // Обе обязательны: без айтема нечего менять, без источника картинку
                // показывать нечем. `required_nonempty` — «хотя бы один ключ из
                // списка», поэтому проверяем каждое поле отдельно.
                for group in [["item_id", "айтем"], ["source", "источник"]] {
                    if let Some(field) = required_nonempty(map, &group) {
                        issues.push(ValidationIssue::error(
                            "missing_field",
                            &child_path,
                            format!("set_image без '{field}'"),
                        ));
                    }
                }
            }
            types::SET_VISIBLE => {
                if let Some(field) = required_nonempty(map, &["item_id", "айтем"]) {
                    issues.push(ValidationIssue::error(
                        "missing_field",
                        &child_path,
                        format!("set_visible без '{field}'"),
                    ));
                }
                // Без распознанного режима блок молча ничего не делает —
                // тихая ошибка, которую валидатор обязан показать.
                let raw_mode = ["mode", "режим", "visible", "видим"]
                    .iter()
                    .find_map(|k| map.get(*k));
                if !crate::blocks::set_visible::mode_recognized(raw_mode) {
                    issues.push(ValidationIssue::error(
                        "bad_value",
                        &child_path,
                        "set_visible без 'mode': ждём show / hide / remove / toggle",
                    ));
                }
            }
            types::GO_TO_NODE => {
                if let Some(field) = required_nonempty(map, &["node_id"]) {
                    issues.push(ValidationIssue::error(
                        "missing_field",
                        &child_path,
                        format!("go_to_node без '{field}'"),
                    ));
                }
            }
            types::CALL_LUA => {
                if let Some(field) = required_nonempty(map, &["function"]) {
                    issues.push(ValidationIssue::error(
                        "missing_field",
                        &child_path,
                        format!("call_lua без '{field}'"),
                    ));
                }
            }
            types::CALL_SCRIPT | types::CALL_FUNCTION => {
                let key = if raw_type == types::CALL_SCRIPT {
                    "script_id"
                } else {
                    "function_id"
                };
                if let Some(field) = required_nonempty(map, &[key]) {
                    issues.push(ValidationIssue::error(
                        "missing_field",
                        &child_path,
                        format!("{raw_type} без '{field}'"),
                    ));
                }
            }
            types::FOR_EACH => {
                if let Some(field) = required_nonempty(map, &["table", "таблица"]) {
                    issues.push(ValidationIssue::error(
                        "missing_field",
                        &child_path,
                        format!("for_each без '{field}' — не по чему идти"),
                    ));
                }
                // Пустое тело цикл выполняет молча, и блок выглядит сломанным;
                // валидатор обязан сказать это до запуска.
                let has_children = map
                    .get("children")
                    .and_then(Value::as_array)
                    .is_some_and(|a| !a.is_empty());
                if !has_children {
                    issues.push(ValidationIssue::error(
                        "missing_field",
                        &child_path,
                        "for_each без 'children' — на каждой строке выполнять нечего",
                    ));
                }
            }
            types::WHILE => {
                let has_mode = ["expression", "count", "to"].iter().any(|k| {
                    map.get(*k)
                        .is_some_and(|v| !value_to_plain_string(v).trim().is_empty())
                });
                if !has_mode {
                    issues.push(ValidationIssue::error(
                        "missing_field",
                        &child_path,
                        "while без режима (expression/to/count) — будет пропущен",
                    ));
                }
            }
            types::TABLE_OPERATION => {
                if let Some(field) = required_nonempty(map, &["tableName"]) {
                    issues.push(ValidationIssue::error(
                        "missing_field",
                        &child_path,
                        format!("table_operation без '{field}'"),
                    ));
                }
                let op = map.get("operation").and_then(Value::as_str);
                if let Some(op) = op
                    && !matches!(
                        op,
                        "get" | "set" | "add" | "remove" | "remove_value" | "clear" | "contains"
                    )
                {
                    issues.push(ValidationIssue::error(
                        "bad_value",
                        &child_path,
                        format!("неизвестная операция '{op}'"),
                    ));
                }
                // Часть промахов движок раньше глотал молча: блок «работает», а
                // данные те же. Предупреждаем там, где выполнение точно
                // ничего не изменит.
                let blank = |key: &str| match map.get(key) {
                    None => true,
                    Some(Value::Null) => true,
                    Some(Value::String(s)) => s.trim().is_empty(),
                    Some(_) => false,
                };
                match op.unwrap_or_default() {
                    "set" if blank("path") => issues.push(ValidationIssue::warning(
                        "bad_value",
                        &child_path,
                        "запись в таблицу без пути: корень не перезаписывается, \
                         блок ничего не изменит",
                    )),
                    "remove" | "remove_value" if blank("path") => {
                        issues.push(ValidationIssue::warning(
                            "bad_value",
                            &child_path,
                            "удаление без пути: корень таблицы удалить нельзя",
                        ));
                    }
                    "remove_value" if blank("value") => issues.push(ValidationIssue::warning(
                        "bad_value",
                        &child_path,
                        "удаление значения без самого значения — заполните \
                             «Значение» или берите операцию «Удалить» по ключу",
                    )),
                    "get" if blank("path") || blank("targetVariable") => {
                        let mut what: Vec<&str> = Vec::new();
                        if blank("path") {
                            what.push(
                                "пустой путь ничего не читает: в переменную уйдёт запасное \
                                 значение из поля «Значение»",
                            );
                        }
                        if blank("targetVariable") {
                            what.push("не указана переменная-приёмник — значение будет выброшено");
                        }
                        issues.push(ValidationIssue::warning(
                            "bad_value",
                            &child_path,
                            what.join("; "),
                        ));
                    }
                    _ => {}
                }
            }
            types::HTTP_REQUEST => {
                if let Some(url) = map.get("url").and_then(Value::as_str)
                    && !url.trim().is_empty()
                    && !url.starts_with("http://")
                    && !url.starts_with("https://")
                    && !url.contains('{')
                {
                    issues.push(ValidationIssue::warning(
                        "bad_value",
                        &child_path,
                        "url не http(s) и не формула — будет отклонён safety-чеком",
                    ));
                }
            }
            _ => {}
        }

        for key in ["children", "then_blocks", "else_blocks"] {
            if let Some(Value::Array(items)) = map.get(key) {
                walk_validate(
                    Some(items),
                    &format!("{child_path}.{key}"),
                    depth + 1,
                    issues,
                    seen_ids,
                );
            }
        }
    }
}

/// Число блоков-действий в скрипте (паритет с Dart
/// `ResourceService.countActionBlocks`, который подписывает карточку в
/// библиотеке): event-обёртки не считаются, вложенные в них блоки — да;
/// контейнеры считаются за 1 плюс вложенные.
///
/// Живёт здесь, рядом со знанием о формате скрипта; библиотека ресурсов
/// считает блоки одним проходом в ядре, не вычитывая сотни файлов в Dart.
pub fn count_action_blocks(blocks: &[Value]) -> usize {
    let mut count = 0;
    for block in blocks {
        let Some(map) = block.as_object() else {
            continue;
        };
        let ty = map
            .get("type")
            .and_then(Value::as_str)
            .or_else(|| map.get("действие").and_then(Value::as_str));
        let is_event_wrapper = ty == Some(types::EVENT) || (ty.is_none() && map.contains_key("title"));
        if !is_event_wrapper {
            count += 1;
        }
        for key in ["children", "then_blocks", "else_blocks", "если_да", "если_нет"] {
            if let Some(Value::Array(nested)) = map.get(key) {
                count += count_action_blocks(nested);
            }
        }
    }
    count
}

#[cfg(test)]
mod block_count_tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn event_wrapper_is_not_a_block_but_children_are() {
        let blocks = json!([
            {"type": "event", "title": "При запуске", "children": [
                {"type": "wait"},
                {"type": "comment"}
            ]},
            {"type": "go_to_node"},
        ]);
        assert_eq!(count_action_blocks(blocks.as_array().unwrap()), 3);
    }

    #[test]
    fn legacy_wrapper_without_type_is_ignored() {
        let blocks = json!([
            {"title": "При запуске ноды", "children": [{"type": "wait"}]}
        ]);
        assert_eq!(count_action_blocks(blocks.as_array().unwrap()), 1);
    }

    #[test]
    fn containers_count_as_one_plus_nested() {
        let blocks = json!([
            {"type": "condition", "then_blocks": [{"type": "wait"}], "else_blocks": []},
            {"type": "crossfade", "children": [{"type": "wait"}, {"type": "wait"}]}
        ]);
        assert_eq!(count_action_blocks(blocks.as_array().unwrap()), 5);
    }

    #[test]
    fn legacy_then_keys_are_counted_and_non_objects_are_skipped() {
        let blocks = json!([
            {"type": "condition", "если_да": [{"type": "wait"}], "если_нет": [{"type": "wait"}]},
            "мусор"
        ]);
        assert_eq!(count_action_blocks(blocks.as_array().unwrap()), 3);
    }
}

#[cfg(test)]
mod golden_tests {
    use super::*;
    use serde_json::json;

    fn fixtures_dir() -> std::path::PathBuf {
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/script_format")
    }

    #[test]
    fn golden_fixtures_normalize_matches_canonical_and_is_idempotent() {
        let mut checked = 0;
        for entry in std::fs::read_dir(fixtures_dir()).expect("fixtures dir") {
            let path = entry.unwrap().path();
            if path.extension().and_then(|e| e.to_str()) != Some("json") {
                continue;
            }
            let raw = std::fs::read_to_string(&path).unwrap();
            let case: Value = serde_json::from_str(&raw).unwrap();
            let input = case.get("input").cloned().unwrap();
            let canonical = case.get("canonical").cloned().unwrap();

            // 1) Нормализация входа даёт канон.
            let mut once = input.clone();
            normalize_script(&mut once);
            assert_eq!(once, canonical, "fixture {}", path.display());

            // 2) Идемпотентность: повторный прогон ничего не меняет.
            let mut twice = once.clone();
            normalize_script(&mut twice);
            assert_eq!(twice, canonical, "idempotence {}", path.display());

            // 3) Валидация канона не рождает ошибок на валидных фикстурах.
            if let Some(map) = canonical.as_object() {
                let issues = validate_script(map);
                assert!(
                    issues.iter().all(|i| i.severity == Severity::Warning),
                    "unexpected errors in {}: {:?}",
                    path.display(),
                    issues
                );
            }
            checked += 1;
        }
        assert!(checked >= 6, "ожидали ≥6 фикстур, нашли {checked}");
    }

    #[test]
    fn validate_catches_missing_fields_duplicates_and_unknown_ops() {
        let script = json!({
            "blocks": [
                {"type": "assign_variable", "id": "a1", "value": "1"},
                {"type": "go_to_node", "id": "g1"},
                {"type": "while", "id": "w1", "children": []},
                {"type": "call_lua", "id": "l1", "function": ""},
                {"type": "table_operation", "id": "t1", "operation": "upsert",
                 "tableName": "t", "path": "x"},
                {"type": "mystery", "id": "m1"}
            ]
        });
        let issues = validate_script(script.as_object().unwrap());
        let codes: Vec<_> = issues.iter().map(|i| (i.code, i.severity)).collect();
        assert!(codes.contains(&("missing_field", Severity::Error)));
        assert!(codes.contains(&("bad_value", Severity::Error)));
        assert!(codes.contains(&("unknown_type", Severity::Warning)));

        // Дубликат id.
        let dup = json!({"blocks": [
            {"type": "wait", "id": "same", "expression": "1"},
            {"type": "wait", "id": "same", "expression": "2"}
        ]});
        let issues = validate_script(dup.as_object().unwrap());
        assert!(issues.iter().any(|i| i.code == "duplicate_id"));
    }

    #[test]
    fn set_image_requires_both_item_and_source() {
        let messages = |script: Value| -> Vec<String> {
            validate_script(script.as_object().unwrap())
                .into_iter()
                .map(|i| i.message)
                .collect()
        };
        // Требуется И объект, и источник: по отдельности каждая дырка — ошибка.
        let only_item = json!({"blocks": [
            {"type": "set_image", "id": "s1", "item_id": "img"}
        ]});
        assert_eq!(messages(only_item), ["set_image без 'source'"]);
        let only_source = json!({"blocks": [
            {"type": "set_image", "id": "s1", "source": "res/a.png"}
        ]});
        assert_eq!(messages(only_source), ["set_image без 'item_id'"]);
        // Русские ключи — те же поля, что читает блок.
        let russian = json!({"blocks": [
            {"type": "set_image", "id": "s1", "айтем": "img", "источник": "res/a.png"}
        ]});
        assert!(messages(russian).is_empty());
    }

    #[test]
    fn set_visible_requires_item_and_known_mode() {
        let messages = |script: Value| -> Vec<String> {
            validate_script(script.as_object().unwrap())
                .into_iter()
                .map(|i| i.message)
                .collect()
        };
        let ok = json!({"blocks": [
            {"type": "set_visible", "id": "v1", "item_id": "photo", "mode": "hide"}
        ]});
        assert!(messages(ok).is_empty());
        // Без режима блок молча не делает ничего — это ошибка, а не предупреждение.
        let no_mode = json!({"blocks": [
            {"type": "set_visible", "id": "v1", "item_id": "photo"}
        ]});
        assert_eq!(
            messages(no_mode),
            ["set_visible без 'mode': ждём show / hide / remove / toggle"]
        );
        let junk_mode = json!({"blocks": [
            {"type": "set_visible", "id": "v1", "item_id": "photo", "mode": "спрячь"}
        ]});
        assert!(
            messages(junk_mode)
                .iter()
                .any(|m| m.starts_with("set_visible без 'mode'"))
        );
        let no_item = json!({"blocks": [
            {"type": "set_visible", "id": "v1", "mode": "скрыть"}
        ]});
        assert_eq!(messages(no_item), ["set_visible без 'item_id'"]);
    }

    #[test]
    fn for_each_requires_table_and_body() {
        let messages = |script: Value| -> Vec<String> {
            validate_script(script.as_object().unwrap())
                .into_iter()
                .map(|i| i.message)
                .collect()
        };
        let ok = json!({"blocks": [{
            "type": "for_each", "id": "f1", "table": "enemies",
            "children": [{"type": "wait", "id": "w1", "expression": "0"}]
        }]});
        assert!(messages(ok).is_empty());
        // Пустое тело и пустая таблица — оба варианта молчаливый no-op.
        let no_table = json!({"blocks": [{
            "type": "for_each", "id": "f1", "table": "",
            "children": [{"type": "wait", "id": "w1", "expression": "0"}]
        }]});
        assert!(
            messages(no_table)
                .iter()
                .any(|m| m.starts_with("for_each без 'table'"))
        );
        let no_body = json!({"blocks": [{
            "type": "for_each", "id": "f1", "table": "enemies", "children": []
        }]});
        assert!(
            messages(no_body)
                .iter()
                .any(|m| m.starts_with("for_each без 'children'"))
        );
        // Русские ключи — те же поля, что читает блок.
        let russian = json!({"blocks": [{
            "type": "for_each", "id": "f1", "таблица": "enemies",
            "children": [{"type": "wait", "id": "w1", "expression": "0"}]
        }]});
        assert!(messages(russian).is_empty());
    }
}

#[cfg(test)]
mod ffi_parity_probe {
    use super::*;
    #[test]
    fn russian_condition_via_public_normalize() {
        let raw = std::fs::read_to_string(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("tests/fixtures/script_format/russian_condition.json"),
        )
        .unwrap();
        let case: Value = serde_json::from_str(&raw).unwrap();
        let mut v = case["input"].clone();
        normalize_script(&mut v);
        assert_eq!(v, case["canonical"]);
    }
}

#[cfg(test)]
mod table_operation_validation_tests {
    use super::*;
    use serde_json::json;

    /// Все сообщения валидатора по одному блоку.
    fn messages(block: Value) -> Vec<String> {
        let script = json!({"blocks": [block]});
        validate_script(script.as_object().unwrap())
            .into_iter()
            .map(|i| i.message)
            .collect()
    }

    fn has(msgs: &[String], needle: &str) -> bool {
        msgs.iter().any(|m| m.contains(needle))
    }

    #[test]
    fn remove_value_is_a_known_operation() {
        let msgs = messages(json!({
            "type": "table_operation", "operation": "remove_value",
            "tableName": "инвентарь", "path": "items", "value": "'меч'"
        }));
        assert!(
            !has(&msgs, "неизвестная операция"),
            "валидатор не знает remove_value: {msgs:?}"
        );
    }

    #[test]
    fn unknown_operation_is_an_error() {
        let msgs = messages(json!({
            "type": "table_operation", "operation": "delete",
            "tableName": "x", "path": "a"
        }));
        assert!(has(&msgs, "неизвестная операция"), "{msgs:?}");
    }

    #[test]
    fn incomplete_blocks_warn_instead_of_failing_silently() {
        // Раньше эти три конфигурации проходили валидацию и молча ничего не
        // делали в рантайме.
        let set_no_path = messages(json!({
            "type": "table_operation", "operation": "set", "tableName": "x", "path": "", "value": "1"
        }));
        assert!(has(&set_no_path, "без пути"), "{set_no_path:?}");

        let remove_value_no_value = messages(json!({
            "type": "table_operation", "operation": "remove_value", "tableName": "x", "path": "items", "value": ""
        }));
        assert!(
            has(&remove_value_no_value, "без самого значения"),
            "{remove_value_no_value:?}"
        );

        let get_nowhere = messages(json!({
            "type": "table_operation", "operation": "get", "tableName": "x", "path": "gold", "targetVariable": ""
        }));
        assert!(has(&get_nowhere, "переменная-приёмник"), "{get_nowhere:?}");
    }

    #[test]
    fn get_without_path_warns_about_fallback_value() {
        // Ровно то, что выдаёт редактор по умолчанию: блок «Получить» с пустым
        // путём кладёт в переменную поле «Значение», а не данные таблицы.
        let msgs = messages(json!({
            "type": "table_operation", "operation": "get", "tableName": "x",
            "path": "", "value": "0", "targetVariable": "result"
        }));
        assert!(has(&msgs, "запасное значение"), "{msgs:?}");
    }

    #[test]
    fn complete_blocks_produce_no_table_warnings() {
        // Не должно быть вала предупреждений на корректных блоках: таких
        // блоков в существующих квестах десятки.
        for block in [
            json!({"type": "table_operation", "operation": "set", "tableName": "x", "path": "gold", "value": "{gold}+1"}),
            json!({"type": "table_operation", "operation": "get", "tableName": "x", "path": "gold", "targetVariable": "g"}),
            json!({"type": "table_operation", "operation": "add", "tableName": "x", "path": "items", "value": "'меч'"}),
            json!({"type": "table_operation", "operation": "remove", "tableName": "x", "path": "items[0]"}),
            json!({"type": "table_operation", "operation": "remove_value", "tableName": "x", "path": "items", "value": "'меч'"}),
            json!({"type": "table_operation", "operation": "clear", "tableName": "x"}),
            json!({"type": "table_operation", "operation": "contains", "tableName": "x", "path": "items", "value": "'меч'", "targetVariable": "has"}),
        ] {
            let msgs = messages(block.clone());
            assert!(msgs.is_empty(), "{block} → {msgs:?}");
        }
    }
}
