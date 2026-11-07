//! FFI-поверхность хранилища квестов (план 020-C2).
//!
//! Stateless: каждый вызов получает корень документов (root) и путь
//! относительно него. Локи живут в ядре по абсолютному пути файла.

use mnd_core::quest_store::{FsQuestStore, MetaMutation, StoreOp};
use serde_json::Value;

fn store(root: &str) -> FsQuestStore {
    FsQuestStore::new(root)
}

fn parse_or_null(json: &str) -> Value {
    serde_json::from_str(json).unwrap_or(Value::Null)
}

fn ok_json(extra: Value) -> String {
    let mut obj = serde_json::Map::new();
    obj.insert("ok".into(), Value::Bool(true));
    if let Value::Object(map) = extra {
        for (k, v) in map {
            obj.insert(k, v);
        }
    }
    serde_json::to_string(&Value::Object(obj)).unwrap_or_else(|_| r#"{"ok":true}"#.into())
}

fn err_json(code: &str, message: &str) -> String {
    serde_json::json!({"ok": false, "error": code, "message": message}).to_string()
}

/// Прочитать JSON-файл квеста → строка или null.
pub async fn quest_store_read_json(root: String, rel_path: String) -> Option<String> {
    store(&root).read_json(&rel_path).map(|v| v.to_string())
}

/// Прочитать текстовый файл квеста → строка или null.
pub async fn quest_store_read_text(root: String, rel_path: String) -> Option<String> {
    store(&root).read_text(&rel_path)
}

/// Атомарная запись JSON.
pub async fn quest_store_write_json(root: String, rel_path: String, json: String) -> String {
    let value = parse_or_null(&json);
    match store(&root).write_json(&rel_path, &value) {
        Ok(()) => ok_json(Value::Null),
        Err(e) => err_json(e.code, &e.message),
    }
}

/// Атомарная запись текста.
pub async fn quest_store_write_text(root: String, rel_path: String, text: String) -> String {
    match store(&root).write_text(&rel_path, &text) {
        Ok(()) => ok_json(Value::Null),
        Err(e) => err_json(e.code, &e.message),
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn quest_store_exists(root: String, rel_path: String) -> bool {
    store(&root).exists(&rel_path)
}

pub async fn quest_store_delete(root: String, rel_path: String) -> String {
    match store(&root).delete(&rel_path) {
        Ok(()) => ok_json(Value::Null),
        Err(e) => err_json(e.code, &e.message),
    }
}

/// Список файлов каталога; extension без точки или с ней.
pub async fn quest_store_list_files(
    root: String,
    rel_dir: String,
    extension: Option<String>,
) -> Vec<String> {
    store(&root).list_files(&rel_dir, extension.as_deref())
}

/// Массовый снимок каталога для библиотеки ресурсов: имена, размеры, mtime,
/// а для JSON — имя из содержимого и число блоков-действий. Один переход
/// через мост и один обход каталога вместо N чтений из Dart.
///
/// Возвращает JSON-массив `[{file,size,mtimeMs,name,blocks}]`.
pub async fn quest_store_scan_files(
    root: String,
    rel_dir: String,
    extension: Option<String>,
    parse_json: bool,
) -> String {
    let facts = store(&root).scan_files(&rel_dir, extension.as_deref(), parse_json);
    let items: Vec<Value> = facts
        .into_iter()
        .map(|f| {
            serde_json::json!({
                "file": f.file_name,
                "size": f.size_bytes,
                "mtimeMs": f.modified_ms,
                "name": f.json_name,
                "blocks": f.block_count,
            })
        })
        .collect();
    serde_json::to_string(&items).unwrap_or_else(|_| "[]".to_string())
}

/// Многофайловая транзакция. ops_json:
/// [{"op":"write_json","path":"…","value":…} |
///  {"op":"write_text","path":"…","text":"…"} |
///  {"op":"remove","path":"…"}]
pub async fn quest_store_transact(root: String, ops_json: String) -> String {
    let Ok(list) = serde_json::from_str::<Value>(&ops_json) else {
        return err_json("bad_request", "ops не является JSON");
    };
    let Some(items) = list.as_array() else {
        return err_json("bad_request", "ops должен быть массивом");
    };

    let mut ops = Vec::with_capacity(items.len());
    for item in items {
        let op = item.get("op").and_then(Value::as_str).unwrap_or("");
        let path = item.get("path").and_then(Value::as_str).unwrap_or("");
        if path.is_empty() {
            return err_json("bad_request", "операция без 'path'");
        }
        match op {
            "write_json" => ops.push(StoreOp::WriteJson {
                rel: path.into(),
                value: item.get("value").cloned().unwrap_or(Value::Null),
            }),
            "write_text" => ops.push(StoreOp::WriteText {
                rel: path.into(),
                content: item
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .into(),
            }),
            "remove" => ops.push(StoreOp::Remove { rel: path.into() }),
            other => return err_json("bad_request", &format!("неизвестный op '{other}'")),
        }
    }

    match store(&root).transact(&ops) {
        Ok(paths) => ok_json(serde_json::json!({ "committed": paths })),
        Err(e) => err_json(e.code, &e.message),
    }
}

/// Атомарный read-modify-write metadata.json квеста.
/// mutations_json: [{"op":"set"|"remove","key":"<имя файла>","value":…}]
pub async fn quest_store_metadata_mutate(
    root: String,
    quest_id: String,
    mutations_json: String,
) -> String {
    let Ok(list) = serde_json::from_str::<Value>(&mutations_json) else {
        return err_json("bad_request", "mutations не является JSON");
    };
    let Some(items) = list.as_array() else {
        return err_json("bad_request", "mutations должен быть массивом");
    };

    let mut mutations = Vec::with_capacity(items.len());
    for item in items {
        let op = item.get("op").and_then(Value::as_str).unwrap_or("");
        let key = item
            .get("key")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        if key.is_empty() {
            return err_json("bad_request", "мутация без 'key'");
        }
        match op {
            "set" => mutations.push(MetaMutation::Set {
                key,
                value: item.get("value").cloned().unwrap_or(Value::Null),
            }),
            "remove" => mutations.push(MetaMutation::Remove { key }),
            other => {
                return err_json("bad_request", &format!("неизвестный op '{other}'"));
            }
        }
    }

    match store(&root).metadata_mutate(&quest_id, &mutations) {
        Ok(meta) => ok_json(serde_json::json!({ "metadata": meta })),
        Err(e) => err_json(e.code, &e.message),
    }
}
