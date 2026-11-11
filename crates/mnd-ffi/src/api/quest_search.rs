//! FFI-слой поиска по квесту.
//!
//! Обёртка над `mnd_core::quest_search::search_quest`. Результат — JSON
//! `SearchReport` (`hits`, `totals`, `matches`, `elapsed_ms`), который клиент
//! разбирает моделью `QuestSearchReport`. Как и валидатор, всегда отдаёт
//! валидный JSON: пустой отчёт лучше исключения в UI.

use mnd_core::quest_search::{DEFAULT_LIMIT_PER_KIND, search_quest_with_limit};

/// Поиск `query` по нодам, скриптам, таблицам, переменным и ресурсам квеста.
///
/// `limit_per_kind` ограничивает выдачу, но не счётчики: интерфейс показывает
/// «12 из 30», поэтому `totals` считаются по всем совпадениям.
pub fn search_quest(
    quest_id: String,
    quest_root: String,
    query: String,
    limit_per_kind: Option<u32>,
) -> String {
    let limit = limit_per_kind
        .map(|n| n as usize)
        .unwrap_or(DEFAULT_LIMIT_PER_KIND);
    let report = search_quest_with_limit(&quest_id, &quest_root, &query, limit);
    serde_json::to_string(&report).unwrap_or_else(|_| {
        r#"{"query":"","hits":[],"totals":{},"total":0,"matches":0,"elapsed_ms":0,"limit_per_kind":12}"#
            .to_string()
    })
}

/// Версия формата отчёта поиска (для клиентской миграции).
pub fn quest_search_schema_version() -> u32 {
    1
}
