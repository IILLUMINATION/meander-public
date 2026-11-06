//! Матрица доступа к таблицам квеста: форматы хранения, все формы адреса,
//! кавычки/скобки в именах строк и колонок, границы и промахи.
//!
//! Два входа в один и тот же резолвер:
//! - текст автора — `{t["кол"]["имя"]}` и `{{...}}`;
//! - путь клиента — `resolveTextVariables` вырезает внешние скобки и отдаёт
//!   движку голый адрес `t["кол"]["имя"]` (`evaluateSync` в плеере).
//!
//! Все три формы обязаны давать одинаковый результат.

use serde_json::{json, Map, Value};

use mnd_core::executor::evaluate_expression;
use mnd_core::models::quest_table::QuestTable;
use mnd_core::runtime::{InMemoryScriptRuntimeState, ScriptRuntime};

type State = InMemoryScriptRuntimeState;

fn eval(expr: &str, state: &mut State) -> Value {
    evaluate_expression(Some(json!(expr)), state)
}

/// Три записи одного адреса обязаны давать одно значение: `{addr}`, `{{addr}}`
/// и голый `addr` (то, что реально прилетает от клиента).
fn assert_forms(addr: &str, expected: Value, state: &mut State) {
    assert_eq!(
        eval(&format!("{{{addr}}}"), state),
        expected,
        "{addr}: {{...}}"
    );
    assert_eq!(
        eval(&format!("{{{{{addr}}}}}"), state),
        expected,
        "{addr}: {{{{...}}}}"
    );
    assert_eq!(eval(addr, state), expected, "{addr}: голый адрес клиента");
}

/// Экранировать имя строки/колонки для записи строковым литералом в `["..."]`.
fn q(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

/// Таблица с простыми данными: 2 строки, имена, key-value хранилище.
fn shop_state() -> State {
    let table = QuestTable::with_row_names(
        "shop".into(),
        vec!["цена".into(), "остаток".into()],
        vec![
            json!({"цена": 10, "остаток": 5})
                .as_object()
                .cloned()
                .unwrap(),
            json!({"цена": 20, "остаток": 0})
                .as_object()
                .cloned()
                .unwrap(),
        ],
        vec!["меч".into(), "щит".into()],
        json!({"уровень": 3, "открыт": true})
            .as_object()
            .cloned()
            .unwrap(),
    );
    let mut tables = std::collections::HashMap::new();
    tables.insert("shop".to_string(), table);
    State::new(None, Some(tables))
}

#[test]
fn data_kv_and_column_and_row_basics() {
    let mut s = shop_state();
    assert_forms("shop[\"уровень\"]", json!(3), &mut s);
    assert_forms("shop[\"открыт\"]", json!(true), &mut s);
    // Колонка целиком — массив.
    assert_forms("shop[\"цена\"]", json!([10, 20]), &mut s);
    // Строка по визуальному (1-based) номеру.
    assert_forms("shop[\"цена\"][1]", json!(10), &mut s);
    assert_forms("shop[\"цена\"][2]", json!(20), &mut s);
}

#[test]
fn row_by_name_both_orders() {
    let mut s = shop_state();
    assert_forms("shop[\"цена\"][\"меч\"]", json!(10), &mut s);
    assert_forms("shop[\"меч\"][\"цена\"]", json!(10), &mut s);
    assert_forms("shop[\"остаток\"][\"щит\"]", json!(0), &mut s);
    // Без кавычек имя тоже адресуется.
    assert_forms("shop[\"цена\"][меч]", json!(10), &mut s);
    // Одинарные кавычки равнозначны двойным.
    assert_forms("shop['цена']['меч']", json!(10), &mut s);
}

#[test]
fn out_of_range_and_misses_are_null() {
    let mut s = shop_state();
    assert_eq!(eval("shop[\"v\"][0]", &mut s), Value::Null);
    assert_eq!(eval("shop[\"цена\"][0]", &mut s), Value::Null);
    assert_eq!(eval("shop[\"цена\"][3]", &mut s), Value::Null);
    assert_eq!(eval("shop[\"цена\"][\"нет\"]", &mut s), Value::Null);
    assert_eq!(eval("shop[\"нет\"]", &mut s), Value::Null);
    assert_eq!(eval("noshops[\"цена\"][1]", &mut s), Value::Null);
    // Пустое имя строки не адресуется.
    assert_eq!(eval("shop[\"цена\"][\"\"]", &mut s), Value::Null);
}

// ── Кавычки/скобки/экранирование в именах ─────────────────────────────────

/// Таблица, где имя каждой строки — отдельный «неудобный» символ/последовательность.
fn tricky_state() -> State {
    let names: Vec<&str> = vec![
        "меч",
        "a}b",
        "a{b",
        "a]b",
        "a[b",
        "a\"b",
        "a\\b",
        "a{{b",
        "a}}b",
        "с пробелом",
        "юникод",
        "a.b",
        "a'b",
        "{test}",
        "{x}y",
        "2", // число-имя строки
    ];
    let rows: Vec<Map<String, Value>> = names
        .iter()
        .enumerate()
        .map(|(i, _)| {
            json!({ "v": format!("r{i}") })
                .as_object()
                .cloned()
                .unwrap()
        })
        .collect();
    let table = QuestTable::with_row_names(
        "tricky".into(),
        vec!["v".into()],
        rows,
        names.iter().map(|s| s.to_string()).collect(),
        json!({}).as_object().cloned().unwrap(),
    );
    let mut tables = std::collections::HashMap::new();
    tables.insert("tricky".to_string(), table);
    State::new(None, Some(tables))
}

#[test]
fn every_row_name_reaches_its_cell_through_all_three_forms() {
    let names: Vec<&str> = vec![
        "меч",
        "a}b",
        "a{b",
        "a]b",
        "a[b",
        "a\"b",
        "a\\b",
        "a{{b",
        "a}}b",
        "с пробелом",
        "юникод",
        "a.b",
        "a'b",
        "{test}",
        "{x}y",
        "2",
    ];
    for (i, name) in names.iter().enumerate() {
        let addr = format!("tricky[\"v\"][\"{}\"]", q(name));
        let mut s = tricky_state();
        assert_forms(&addr, json!(format!("r{i}")), &mut s);
        // И обратный порядок: строка-сначала.
        let mut s2 = tricky_state();
        assert_forms(
            &format!("tricky[\"{}\"][\"v\"]", q(name)),
            json!(format!("r{i}")),
            &mut s2,
        );
    }
}

#[test]
fn numeric_row_name_is_name_not_index() {
    // `t["v"]["2"]` — имя строки `2`, а не визуальный номер 2.
    let mut s = tricky_state();
    assert_forms("tricky[\"v\"][\"2\"]", json!("r15"), &mut s);
    // Без кавычек `2` — уже индекс (вторая строка).
    assert_forms("tricky[\"v\"][2]", json!("r1"), &mut s);
}

#[test]
fn braces_inside_quoted_row_name_are_data_not_placeholder() {
    // Имя `{test}` — но переменной `test` нет (она не должна подставляться).
    let mut s = tricky_state();
    assert_forms("tricky[\"v\"][\"{test}\"]", json!("r13"), &mut s);
}

#[test]
fn unquoted_names_and_single_quotes_in_tricky_names() {
    let mut s = tricky_state();
    // Одинарная кавычка в имени как часть строкового литерала.
    assert_forms("tricky[\"v\"][\"a'b\"]", json!("r12"), &mut s);
    // Имя без кавычек — идентификатор до следующего `]`/`.`.
    assert_forms("tricky[\"v\"][a.b]", json!("r11"), &mut s);
}

/// Имена строк с `{{`/`}}` не должны схлопываться подстановкой.
#[test]
fn double_brace_row_names_survive() {
    let mut s = tricky_state();
    assert_eq!(
        eval("tricky[\"v\"][\"a{{b\"]", &mut s),
        json!("r7"),
        "двойная открывающая скобка в имени"
    );
    assert_eq!(
        eval("tricky[\"v\"][\"a}}b\"]", &mut s),
        json!("r8"),
        "двойная закрывающая скобка в имени"
    );
}

// ── Переменные / формулы как ключи ─────────────────────────────────────────

#[test]
fn variable_as_segment_key() {
    let mut s = shop_state();
    s.set_variable("col".into(), json!("цена"));
    s.set_variable("row".into(), json!("щит"));
    s.set_variable("idx".into(), json!(2));
    assert_eq!(eval("shop[col][1]", &mut s), json!(10));
    assert_eq!(eval("shop[\"цена\"][row]", &mut s), json!(20));
    assert_eq!(eval("shop[\"цена\"][idx]", &mut s), json!(20));
}

#[test]
fn formula_as_segment_key() {
    let mut s = shop_state();
    // `upper("меч")` → "МЕЧ" — но имена с учётом регистра; здесь подставляем имя.
    assert_eq!(eval("shop[\"цена\"][\"ме\" + \"ч\"]", &mut s), json!(10));
}

// ── Резервированные ключи и dot-доступ ─────────────────────────────────────

#[test]
fn reserved_words_block_column_and_row_names() {
    let mut s = State::new(
        None,
        Some({
            let mut t = std::collections::HashMap::new();
            let table = QuestTable::with_row_names(
                "t".into(),
                vec!["columns".into(), "rows".into()],
                vec![json!({"columns": "C", "rows": "R"})
                    .as_object()
                    .cloned()
                    .unwrap()],
                vec!["S".into()],
                json!({}).as_object().cloned().unwrap(),
            );
            t.insert("t".into(), table);
            t
        }),
    );
    // `columns`/`rows` возвращают сами массивы, а не ячейки/строки.
    assert_eq!(eval("t[\"columns\"]", &mut s), json!(["columns", "rows"]));
    assert_eq!(
        eval("t[\"rows\"]", &mut s),
        json!([{"columns": "C", "rows": "R"}])
    );
}

#[test]
fn dot_access_on_column_and_data() {
    let mut s = shop_state();
    assert_eq!(eval("shop.цена", &mut s), json!([10, 20]));
    assert_eq!(eval("shop.уровень", &mut s), json!(3));
    assert_eq!(eval("shop.открыт", &mut s), json!(true));
}

// ── Функции таблиц ─────────────────────────────────────────────────────────

#[test]
fn table_helpers() {
    let mut s = shop_state();
    assert_eq!(eval("table_rows(shop)", &mut s), json!(2));
    assert_eq!(
        eval("table_columns(shop)", &mut s),
        json!(["цена", "остаток"])
    );
    assert_eq!(eval("table_column(shop, 'цена')", &mut s), json!([10, 20]));
    assert_eq!(eval("table_cell(shop, 'цена', 1)", &mut s), json!(10));
    assert_eq!(eval("table_cell(shop, 'цена', 'меч')", &mut s), json!(10));
    assert_eq!(eval("table_row_names(shop)", &mut s), json!(["меч", "щит"]));
    assert_eq!(
        eval("table_row(shop, 1)", &mut s),
        json!({"цена": 10, "остаток": 5})
    );
    assert_eq!(eval("table_row_number(shop, 'щит')", &mut s), json!(2));
    assert_eq!(eval("table_sum(shop, 'цена')", &mut s), json!(30));
    assert_eq!(eval("table_avg(shop, 'цена')", &mut s), json!(15));
    assert_eq!(eval("table_row_number(shop)", &mut s), json!(0));
}

// ── Формат хранения ───────────────────────────────────────────────────────

#[test]
fn from_json_legacy_top_level_keys_become_data() {
    let t = QuestTable::from_json(&json!({
        "name": "legacy",
        "columns": ["hp"],
        "rows": [{"hp": 7}],
        "rowNames": ["a"],
        "secret": 42,
    }));
    assert_eq!(t.data.get("secret"), Some(&json!(42)));
    assert_eq!(t.data.get("name"), None);
    let mut tables = std::collections::HashMap::new();
    tables.insert("legacy".to_string(), t);
    let mut s = State::new(None, Some(tables));
    assert_forms("legacy[\"secret\"]", json!(42), &mut s);
}

#[test]
fn row_names_shorter_or_longer_than_rows_are_normalized() {
    let short = QuestTable::from_json(&json!({
        "name": "t", "columns": ["c"],
        "rows": [{"c": 1}, {"c": 2}, {"c": 3}],
        "rowNames": ["a"],
    }));
    assert_eq!(
        short.row_names,
        vec!["a".to_string(), "".to_string(), "".to_string()]
    );

    let long = QuestTable::from_json(&json!({
        "name": "t", "columns": ["c"],
        "rows": [{"c": 1}],
        "rowNames": ["a", "b"],
    }));
    assert_eq!(long.row_names, vec!["a".to_string()]);
    assert_eq!(long.rows.len(), 1);
}

#[test]
fn row_names_are_trimmed() {
    let t = QuestTable::from_json(&json!({
        "name": "t", "columns": ["c"],
        "rows": [{"c": 1}],
        "rowNames": ["  имя  "],
    }));
    assert_eq!(t.row_names, vec!["имя".to_string()]);
}

#[test]
fn to_json_from_json_roundtrip_is_identity() {
    let t = QuestTable::with_row_names(
        "rt".into(),
        vec!["c".into()],
        vec![json!({"c": 1}).as_object().cloned().unwrap()],
        vec!["имя".into()],
        json!({"k": "v"}).as_object().cloned().unwrap(),
    );
    assert_eq!(QuestTable::from_json(&t.to_json()), t);
}

#[test]
fn nested_table_cell_roundtrip() {
    let inner = QuestTable::with_row_names(
        "inner".into(),
        vec!["x".into()],
        vec![json!({"x": "глубокая"}).as_object().cloned().unwrap()],
        vec!["row".into()],
        json!({"meta": true}).as_object().cloned().unwrap(),
    );
    let cell = inner.to_nested_value();
    assert!(QuestTable::is_nested_value(&cell));
    assert_eq!(QuestTable::from_cell_value(&cell), Some(inner));
}

#[test]
fn table_name_with_space_and_cyrillic_reaches() {
    let table = QuestTable::with_row_names(
        "моя таблица".into(),
        vec!["к".into()],
        vec![json!({"к": "v"}).as_object().cloned().unwrap()],
        vec!["r".into()],
        json!({}).as_object().cloned().unwrap(),
    );
    let mut tables = std::collections::HashMap::new();
    tables.insert("моя таблица".into(), table);
    let mut s = State::new(None, Some(tables));
    assert_forms("моя таблица[\"к\"][\"r\"]", json!("v"), &mut s);
}

#[test]
fn value_types_roundtrip_through_cells() {
    let rows = vec![
        json!({"t": "a\"b", "n": 7, "b": true, "z": null, "arr": [1, 2], "o": {"k": "v"}})
            .as_object()
            .cloned()
            .unwrap(),
    ];
    let table = QuestTable::with_row_names(
        "types".into(),
        vec![
            "t".into(),
            "n".into(),
            "b".into(),
            "z".into(),
            "arr".into(),
            "o".into(),
        ],
        rows,
        vec!["r".into()],
        json!({}).as_object().cloned().unwrap(),
    );
    let mut tables = std::collections::HashMap::new();
    tables.insert("types".into(), table);
    let mut s = State::new(None, Some(tables));
    assert_forms("types[\"t\"][\"r\"]", json!("a\"b"), &mut s);
    assert_forms("types[\"n\"][\"r\"]", json!(7), &mut s);
    assert_forms("types[\"b\"][\"r\"]", json!(true), &mut s);
    assert_forms("types[\"z\"][\"r\"]", Value::Null, &mut s);
    assert_forms("types[\"arr\"][\"r\"]", json!([1, 2]), &mut s);
    assert_forms("types[\"o\"][\"r\"]", json!({"k": "v"}), &mut s);
    // После обращения к строке значение — обычный JSON: индекс обычного
    // массива с 0, а не визуальный номер строки.
    assert_eq!(eval("types[\"arr\"][1][0]", &mut s), json!(1));
    assert_eq!(eval("types[\"arr\"][1][1]", &mut s), json!(2));
}
