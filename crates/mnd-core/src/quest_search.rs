//! Поиск по всему квесту — в ядре, а не в Dart.
//!
//! Поиск читает файлы квеста: ноды, визуальные и Lua-скрипты, таблицы,
//! переменные, ресурсы. Раньше это делал Dart-сервис: каждый символ запроса
//! шёл через асинхронный слой хранилища, а проход по нодам открывал тело
//! каждой ноды отдельным запросом. Здесь тот же обход делает Rust одним
//! вызовом — клиент получает готовый JSON с попаданиями и временем поиска.

use std::collections::BTreeMap;
use std::time::Instant;

use serde::Serialize;
use serde_json::Value;

use crate::contracts::{FsScriptAssetStore, ScriptAssetStore};
use crate::validation::load_nodes;

/// Сколько попаданий отдавать по каждому виду, если клиент не попросил иначе.
pub const DEFAULT_LIMIT_PER_KIND: usize = 12;

/// Вид результата. Строки совпадают с ключами, которыми клиент группирует
/// выдачу, поэтому меняются только вместе с клиентом.
pub mod kind {
    pub const NODE: &str = "node";
    pub const SCRIPT: &str = "script";
    pub const LUA: &str = "lua";
    pub const TABLE: &str = "table";
    pub const VARIABLE: &str = "variable";
    pub const RESOURCE: &str = "resource";

    /// Виды в порядке показа: сначала места, куда можно перейти, затем данные.
    pub const ALL: [&str; 6] = [NODE, SCRIPT, LUA, TABLE, VARIABLE, RESOURCE];
}

/// Одно попадание.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct SearchHit {
    /// `node|script|lua|table|variable|resource`.
    pub kind: &'static str,
    /// Чем открывается результат: id ноды, имя файла, имя таблицы/переменной.
    pub id: String,
    pub title: String,
    /// Где нашлось: «название ноды», папка скрипта, «таблица».
    pub context: String,
    /// Кусок текста со совпадением — автор видит, то ли это место.
    pub snippet: String,
}

/// Итог поиска: попадания, счётчики и стоимость.
#[derive(Debug, Clone, Default, Serialize)]
pub struct SearchReport {
    pub query: String,
    pub hits: Vec<SearchHit>,
    /// Сколько всего нашлось по каждому виду (включая не попавшие в выдачу).
    pub totals: BTreeMap<String, usize>,
    /// Показано попаданий.
    pub total: usize,
    /// Сколько всего совпадений до ограничения.
    pub matches: usize,
    pub elapsed_ms: u64,
    /// `limit` на вид, с которым считали totals.
    pub limit_per_kind: usize,
}

/// Найти `query` во всех данных квеста `quests/<quest_id>/`.
pub fn search_quest(quest_id: &str, quest_root: &str, query: &str) -> SearchReport {
    search_quest_with_limit(quest_id, quest_root, query, DEFAULT_LIMIT_PER_KIND)
}

/// То же с явным лимитом попаданий на вид.
pub fn search_quest_with_limit(
    quest_id: &str,
    quest_root: &str,
    query: &str,
    limit_per_kind: usize,
) -> SearchReport {
    let started = Instant::now();
    let query = query.trim().to_lowercase();
    let mut report = SearchReport {
        query: query.clone(),
        limit_per_kind,
        ..SearchReport::default()
    };
    if query.is_empty() {
        report.elapsed_ms = started.elapsed().as_millis() as u64;
        return report;
    }

    let store = FsScriptAssetStore::new(quest_root);
    let prefix = format!("quests/{quest_id}/");
    let mut sink = HitSink::new(limit_per_kind);

    search_nodes(&store, &prefix, &query, &mut sink);
    search_scripts(&store, &prefix, &query, &mut sink);
    search_config(&store, &prefix, &query, &mut sink);
    search_resources(&store, &prefix, &query, &mut sink);

    report.totals = sink.totals;
    report.matches = sink.matches;
    report.hits = sink.hits;
    report.total = report.hits.len();
    report.elapsed_ms = started.elapsed().as_millis() as u64;
    report
}

/// Накопление выдачи с лимитом на вид. Совпадения считаются всегда:
/// интерфейс показывает «12 из 30», а не «12».
struct HitSink {
    limit: usize,
    hits: Vec<SearchHit>,
    totals: BTreeMap<String, usize>,
    matches: usize,
}

impl HitSink {
    fn new(limit: usize) -> Self {
        Self {
            limit: limit.max(1),
            hits: Vec::new(),
            totals: BTreeMap::new(),
            matches: 0,
        }
    }

    fn push(&mut self, hit: SearchHit) {
        *self.totals.entry(hit.kind.to_string()).or_insert(0) += 1;
        self.matches += 1;
        let shown = self.hits.iter().filter(|h| h.kind == hit.kind).count();
        if shown < self.limit {
            self.hits.push(hit);
        }
    }
}

fn search_nodes(
    store: &dyn ScriptAssetStore,
    prefix: &str,
    query: &str,
    sink: &mut HitSink,
) {
    for node in load_nodes(store, prefix) {
        let title = node.title.clone();
        if title.to_lowercase().contains(query) {
            sink.push(SearchHit {
                kind: kind::NODE,
                id: node.id.clone(),
                title: if title.is_empty() {
                    node.id.clone()
                } else {
                    title
                },
                context: "название ноды".to_string(),
                snippet: String::new(),
            });
            continue;
        }
        let content = Value::Object(node.content.clone());
        if let Some((label, text)) = first_string_match(&content, query) {
            sink.push(SearchHit {
                kind: kind::NODE,
                id: node.id.clone(),
                title: if title.is_empty() {
                    node.id.clone()
                } else {
                    title
                },
                context: label,
                snippet: text,
            });
        }
    }
}

fn search_scripts(
    store: &dyn ScriptAssetStore,
    prefix: &str,
    query: &str,
    sink: &mut HitSink,
) {
    // Внутренние скрипты (`_internal_scripts`) — тоже скрипты квеста, но в
    // списке ресурсов их не видно: без второго прохода поиск по ним молчит.
    for folder in ["scripts", "_internal_scripts"] {
        let dir = format!("{prefix}{folder}");
        let files = store.list_dir(&dir);
        for full in files {
            let Some(name) = full.rsplit('/').next() else {
                continue;
            };
            if name.ends_with(".json") {
                let Some(value) = store.read_json(&full) else {
                    continue;
                };
                let script_name = value
                    .get("name")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|n| !n.is_empty())
                    .unwrap_or(name)
                    .to_string();
                if script_name.to_lowercase().contains(query) {
                    sink.push(SearchHit {
                        kind: kind::SCRIPT,
                        id: name.to_string(),
                        title: script_name,
                        context: folder.to_string(),
                        snippet: String::new(),
                    });
                    continue;
                }
                if let Some(blocks) = value.get("blocks")
                    && let Some((label, text)) = first_string_match(blocks, query)
                {
                    sink.push(SearchHit {
                        kind: kind::SCRIPT,
                        id: name.to_string(),
                        title: script_name,
                        context: label,
                        snippet: text,
                    });
                }
            } else if name.ends_with(".lua") {
                let Some(text) = store.read_text(&full) else {
                    continue;
                };
                let Some(line) = first_matching_line(&text, query) else {
                    continue;
                };
                sink.push(SearchHit {
                    kind: kind::LUA,
                    id: name.to_string(),
                    title: name.to_string(),
                    context: folder.to_string(),
                    snippet: line,
                });
            }
        }
    }
}

fn search_config(
    store: &dyn ScriptAssetStore,
    prefix: &str,
    query: &str,
    sink: &mut HitSink,
) {
    let Some(config) = store.read_json(&format!("{prefix}config.json")) else {
        return;
    };
    for raw in config
        .get("variables")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default()
    {
        let name = raw.get("name").and_then(Value::as_str).unwrap_or("");
        if name.is_empty() || !name.to_lowercase().contains(query) {
            continue;
        }
        sink.push(SearchHit {
            kind: kind::VARIABLE,
            id: name.to_string(),
            title: name.to_string(),
            context: "переменная".to_string(),
            snippet: raw
                .get("type")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
        });
    }
    for raw in config
        .get("tables")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default()
    {
        let name = raw.get("name").and_then(Value::as_str).unwrap_or("");
        if name.is_empty() {
            continue;
        }
        let snippet = if name.to_lowercase().contains(query) {
            Some("название таблицы".to_string())
        } else {
            raw.get("rows")
                .and_then(|rows| first_string_match(rows, query))
                .map(|(_, text)| text)
        };
        let Some(snippet) = snippet else { continue };
        sink.push(SearchHit {
            kind: kind::TABLE,
            id: name.to_string(),
            title: name.to_string(),
            context: "таблица".to_string(),
            snippet,
        });
    }
}

fn search_resources(
    store: &dyn ScriptAssetStore,
    prefix: &str,
    query: &str,
    sink: &mut HitSink,
) {
    let Some(metadata) = store.read_json(&format!("{prefix}res/metadata.json")) else {
        return;
    };
    let Some(entries) = metadata.as_object() else {
        return;
    };
    for (file_name, value) in entries {
        // `__folders__` — служебная запись виртуальных папок.
        if file_name == "__folders__" {
            continue;
        }
        let mut friendly_name = file_name.clone();
        let mut folder = "/".to_string();
        match value {
            Value::String(name) => friendly_name = name.clone(),
            Value::Object(entry) => {
                friendly_name = entry
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or(file_name)
                    .to_string();
                folder = entry
                    .get("folder")
                    .and_then(Value::as_str)
                    .unwrap_or("/")
                    .to_string();
            }
            _ => {}
        }
        if file_name.ends_with(".json") && friendly_name == *file_name {
            continue;
        }
        let haystack = format!("{friendly_name} {file_name}").to_lowercase();
        if !haystack.contains(query) {
            continue;
        }
        sink.push(SearchHit {
            kind: kind::RESOURCE,
            id: file_name.clone(),
            title: friendly_name,
            context: folder,
            snippet: file_name.clone(),
        });
    }
}

/// Первая строка JSON со значением, содержащим запрос: (метка поля, текст).
///
/// Метка нужна, чтобы результат «переменная gold» не путался с
/// «переменная score»: она собирает имена полей по пути до совпадения.
fn first_string_match(value: &Value, query: &str) -> Option<(String, String)> {
    let mut result = None;
    walk_strings(value, "", &mut |label, text| {
        if result.is_none() && text.to_lowercase().contains(query) {
            result = Some((label.to_string(), text.to_string()));
        }
    });
    result
}

fn walk_strings(value: &Value, label: &str, visit: &mut impl FnMut(&str, &str)) {
    match value {
        Value::String(text) => visit(label, text),
        Value::Object(map) => {
            for (key, child) in map {
                let joined = join_label(label, key);
                walk_strings(child, &joined, visit);
            }
        }
        Value::Array(items) => {
            for child in items {
                walk_strings(child, label, visit);
            }
        }
        _ => {}
    }
}

/// Подпись поля остаётся только для осмысленных ключей: `text`, `variable`,
/// `path`, `value`, `url`, `comment`, `name`, `title`. Иначе текст ответа
/// тонул бы в служебных именах вроде `fillColor`.
fn join_label(label: &str, key: &str) -> String {
    match key {
        "text" | "variable" | "path" | "value" | "url" | "comment" | "name" | "title" => {
            if label.is_empty() {
                key.to_string()
            } else {
                format!("{label} → {key}")
            }
        }
        _ => label.to_string(),
    }
}

fn first_matching_line(text: &str, query: &str) -> Option<String> {
    text.lines()
        .find(|line| line.to_lowercase().contains(query))
        .map(|line| line.trim().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static COUNTER: AtomicU64 = AtomicU64::new(0);

    fn fixture(files: &[(&str, &str)]) -> String {
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!(
            "mnd_search_{}_{}",
            std::process::id(),
            n
        ));
        let _ = std::fs::remove_dir_all(&dir);
        for (path, content) in files {
            let full = dir.join(path);
            if let Some(parent) = full.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            std::fs::write(&full, content).expect("write fixture");
        }
        dir.to_string_lossy().to_string()
    }

    fn sample_root() -> String {
        fixture(&[
            (
                "quests/q1/config.json",
                r#"{"id":"q1",
                    "variables":[{"name":"золото","type":"number"},{"name":"флаг_моста","type":"bool"}],
                    "tables":[{"name":"склад","columns":["предмет"],"rows":[["лампа"]]}]}"#,
            ),
            (
                "quests/q1/nodes/index.json",
                r#"{"nodes":[{"id":"n1","title":"Берег"},{"id":"n2","title":"Мост"}]}"#,
            ),
            (
                "quests/q1/nodes/n1.json",
                r#"{"id":"n1","title":"Берег","content":{"items":[{"type":"text","text":"Туман стоит над водой"}]}}"#,
            ),
            (
                "quests/q1/nodes/n2.json",
                r#"{"id":"n2","title":"Мост","content":{"items":[{"type":"text","text":"Доски скрипят"}]}}"#,
            ),
            (
                "quests/q1/scripts/aaa.json",
                r#"{"name":"Зажечь маяк","blocks":[{"type":"event","eventType":"onPress",
                    "children":[{"type":"assign_variable","variable":"флаг_моста","value":"1"}]}]}"#,
            ),
            (
                "quests/q1/_internal_scripts/bbb.json",
                r#"{"name":"Служебный","blocks":[{"type":"comment","text":"временный обход"}]}"#,
            ),
            (
                "quests/q1/scripts/ccc.lua",
                "function onQuestStart()\n  -- маяк спит\nend\n",
            ),
            (
                "quests/q1/res/metadata.json",
                r#"{"lamp.png":{"name":"Старая лампа","folder":"Свет"},"__folders__":["Свет"]}"#,
            ),
        ])
    }

    #[test]
    fn finds_inside_node_content_with_field_label() {
        let root = sample_root();
        let report = search_quest("q1", &root, "туман");
        assert_eq!(report.total, 1);
        let hit = &report.hits[0];
        assert_eq!(hit.kind, kind::NODE);
        assert_eq!(hit.id, "n1");
        assert_eq!(hit.context, "text");
        assert_eq!(hit.snippet, "Туман стоит над водой");
    }

    #[test]
    fn finds_nodes_by_title() {
        let report = search_quest("q1", &sample_root(), "мост");
        // Нода «Мост» и переменная «флаг_моста» — разные виды, обе видны.
        assert!(report.hits.iter().any(|h| h.kind == kind::NODE && h.id == "n2"));
        assert!(report.hits.iter().any(|h| h.kind == kind::VARIABLE && h.id == "флаг_моста"));
        assert_eq!(report.totals[kind::NODE], 1);
    }

    #[test]
    fn searches_internal_scripts_lua_and_resources() {
        let root = sample_root();

        let internal = search_quest("q1", &root, "обход");
        assert_eq!(internal.hits.len(), 1);
        assert_eq!(internal.hits[0].kind, kind::SCRIPT);
        assert_eq!(internal.hits[0].id, "bbb.json");
        assert_eq!(internal.hits[0].snippet, "временный обход");

        let lua = search_quest("q1", &root, "маяк спит");
        assert_eq!(lua.hits.len(), 1);
        assert_eq!(lua.hits[0].kind, kind::LUA);
        assert_eq!(lua.hits[0].id, "ccc.lua");

        let resource = search_quest("q1", &root, "старая");
        assert_eq!(resource.hits[0].kind, kind::RESOURCE);
        assert_eq!(resource.hits[0].title, "Старая лампа");
        assert_eq!(resource.hits[0].context, "Свет");
    }

    #[test]
    fn limits_hits_but_counts_all_matches() {
        let mut files: Vec<(String, String)> = Vec::new();
        let nodes: Vec<String> = (0..20)
            .map(|i| {
                format!(
                    r#"{{"id":"n{i}","title":"Ночь {i}","content":{{"items":[{{"type":"text","text":"фонарь"}}]}}}}"#
                )
            })
            .collect();
        files.push((
            "quests/q1/config.json".to_string(),
            r#"{"id":"q1"}"#.to_string(),
        ));
        files.push((
            "quests/q1/nodes/nodes.json".to_string(),
            format!(r#"{{"nodes":[{}]}}"#, nodes.join(",")),
        ));
        let refs: Vec<(&str, &str)> = files
            .iter()
            .map(|(p, c)| (p.as_str(), c.as_str()))
            .collect();
        let root = fixture(&refs);

        let report = search_quest_with_limit("q1", &root, "фонарь", 5);
        assert_eq!(report.total, 5, "лимит соблюдён");
        assert_eq!(report.matches, 20);
        assert_eq!(report.totals[kind::NODE], 20);
    }

    #[test]
    fn empty_query_skips_scanning() {
        let report = search_quest("q1", &sample_root(), "   ");
        assert!(report.hits.is_empty());
        assert_eq!(report.matches, 0);
    }
}
