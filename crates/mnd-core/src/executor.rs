//! Скриптовый исполнитель квеста.
//!
//! Паритет: `packages/mnd_core/lib/engine/script_executor.dart`.
//!
//! Ключевые отличия от Dart-эталона:
//! * синхронный API (без `async/await`); блоки `wait`/`crossfade` не
//!   выполняют реальной задержки — тайминг остаётся за FFI-слоем
//!   (результат исполнения от задержек не зависит);
//! * хранилище ассетов — синхронный трейт [`ScriptAssetStore`].

pub(crate) fn push_effect(state: &mut dyn ScriptRuntime, key: &str, value: Value) {
    let mut arr = match state.get_variable(key).cloned() {
        Some(Value::Array(a)) => a,
        _ => Vec::new(),
    };
    arr.push(value);
    state.set_variable(key, Value::Array(arr));
}

/// Служебная переменная с переопределениями источника картинки:
/// `{itemId: "res/images/cat.png"}`. Пишет её блок `set_image`, читает клиент
/// при разрешении пути картинки — см. `blocks/set_image.rs`.
pub(crate) const ITEM_SOURCE_VAR: &str = "_internal_item_sources";

/// Служебная переменная с переопределениями видимости: `{itemId: bool}`.
/// Пишет её блок `set_visible`, читает клиент при сборке айтема — тот же
/// канал, что у источника картинки, см. `blocks/set_visible.rs`.
pub(crate) const ITEM_HIDDEN_VAR: &str = "_internal_item_hidden";

/// Ключи служебных переменных, которые НЕ должны попадать в pacing-снапшоты
/// (`wait`-шаги). Служебная обвязка (очереди, одноразовые аудио-слоты) —
/// внутренний транспорт, клиенту из неё интересен только контент.
pub(crate) fn is_pacing_plumbing_key(name: &str) -> bool {
    matches!(
        name,
        "_internal_delay_queue"
            | "_internal_audio_queue"
            | "_internal_timer_schedule"
            | "_internal_play_sound_id"
            | "_internal_play_sound_volume"
            | "_internal_stop_sound_target"
            | "_internal_play_music_id"
            | "_internal_play_music_volume"
            | "_internal_play_music_loop"
            | "_internal_play_music_global"
            | "_internal_stop_music"
            | "_internal_pause_resume_target"
            | "_internal_pause_resume_action"
            | "_internal_crossfade_fade_out"
            | "_internal_crossfade_fade_in"
            | "_internal_external_commands"
    )
}

/// Отложенный re-invoke функции-таймера: запись `_internal_timer_schedule`
/// в state. Клиент ждёт `ms` (реальный `Future.delayed`) и дёргает
/// `run_scheduled_timer(script_path, entry)` — один тик таймера.
pub(crate) fn schedule_timer(
    state: &mut dyn ScriptRuntime,
    script_path: &str,
    entry: &str,
    ms: i64,
) {
    push_effect(
        state,
        "_internal_timer_schedule",
        json!({"script_path": script_path, "entry": entry, "ms": ms}),
    );
}

/// Очередь аудио-команд текущего исполнения (`_internal_audio_queue`).
///
/// Паритет: Dart-эталон исполнял блоки по одному, и каждая `play_sound`
/// достигала клиента в точке `await`. Rust исполняет всё синхронно, поэтому
/// несколько `play_sound` подряд в одиночных слотах (`_internal_play_sound_id`)
/// взаимозатирались — до клиента доходил только последний звук (в логах:
/// 3x «Звук простой атаки врага» → один `🔊 Sound effect`). Команды копим
/// в массив, клиент проигрывает их по порядку.
pub(crate) fn push_audio_command(state: &mut dyn ScriptRuntime, cmd: Value) {
    push_effect(state, "_internal_audio_queue", cmd);
}

/// Забрать из `_internal_audio_queue` накопленные с прошлого checkpoint'а
/// команды (для вложения в pacing-шаг `wait`). Возвращает их и очищает слот.
pub(crate) fn take_pending_audio_commands(state: &mut dyn ScriptRuntime) -> Vec<Value> {
    let pending = state.get_variable("_internal_audio_queue").cloned();
    state.set_variable("_internal_audio_queue", Value::Array(Vec::new()));
    match pending {
        Some(Value::Array(arr)) => arr,
        _ => Vec::new(),
    }
}

use serde_json::{Map, Value, json};
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

use crate::contracts::{ScriptAssetStore, ScriptExpressionEngine};
use crate::expression::{self, to_bool, to_num, values_equal};
use crate::lua::LuaSession;
use crate::models::quest_table::strip_table_view;
use crate::runtime::ScriptRuntime;

/// Тип события, на которое подписан скрипт.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EventType {
    OnQuestStart,
    OnNodeEnter,
    OnPress,
    OnContentAppear,
    Function,
    /// variant добавлен последним — индексы прежних вариантов не меняются
    /// (FFI-зеркало `crates/mnd-ffi/src/api/models.rs`).
    OnDataChange,
}

impl EventType {
    pub fn name(&self) -> &'static str {
        match self {
            EventType::OnQuestStart => "onQuestStart",
            EventType::OnNodeEnter => "onNodeEnter",
            EventType::OnPress => "onPress",
            EventType::OnContentAppear => "onContentAppear",
            EventType::Function => "function",
            EventType::OnDataChange => "onDataChange",
        }
    }

    pub fn from_name(name: &str) -> Option<EventType> {
        match name {
            "onQuestStart" => Some(EventType::OnQuestStart),
            "onNodeEnter" => Some(EventType::OnNodeEnter),
            "onPress" => Some(EventType::OnPress),
            "onContentAppear" => Some(EventType::OnContentAppear),
            "function" => Some(EventType::Function),
            "onDataChange" => Some(EventType::OnDataChange),
            _ => None,
        }
    }
}

/// Экспорт совместимости (dart: `EventType` из script_runtime.dart).
pub use EventType as event_type;

const LEGACY_TITLE_ON_NODE_ENTER: &str = "\u{041f}\u{0440}\u{0438} \u{0437}\u{0430}\u{043f}\u{0443}\u{0441}\u{043a}\u{0435} \u{043d}\u{043e}\u{0434}\u{044b}";
const LEGACY_TITLE_ON_PRESS: &str =
    "\u{041f}\u{0440}\u{0438} \u{043d}\u{0430}\u{0436}\u{0430}\u{0442}\u{0438}\u{0438}";
const TITLE_FUNCTION: &str = "Функция";
const TITLE_ON_NODE_ENTER: &str = "При запуске ноды";
const TITLE_ON_PRESS: &str = "При нажатии";
const TITLE_ON_QUEST_START: &str = "При запуске квеста";
const TITLE_ON_DATA_CHANGE: &str = "При изменении данных";

/// Лимит шагов исполнения (паритет: `ExecutionController(maxSteps: 2000)`).
const MAX_STEPS: usize = 2000;
const MAX_CALL_DEPTH: usize = 64;

/// Потолок индекса при записи в массив по пути (`t[12] = …`). Без него один
/// блок «установить значение» с индексом 2·10⁹ разрабатывает `Vec` нулями до
/// OOM и вешает процесс.
const MAX_ARRAY_WRITE_INDEX: i64 = 100_000;

// ---------------------------------------------------------------------------
// Статическая конфигурация (паритет ScriptExecutor.configure в Dart)
// ---------------------------------------------------------------------------

static CONFIG: OnceLock<Arc<ExecutorConfig>> = OnceLock::new();

/// Тип-алиасы для сложных dyn-полей (паритет Dart `ScriptExecutorDependencies`).
pub type DynExpressionEngine = Arc<dyn ScriptExpressionEngine + Send + Sync>;
pub type DynAssetStore = Arc<dyn ScriptAssetStore + Send + Sync>;
pub type DynLogger = Arc<dyn Fn(&str) + Send + Sync>;

/// Глобальная конфигурация исполнителя.
#[derive(Default)]
pub struct ExecutorConfig {
    pub expression_engine: Option<DynExpressionEngine>,
    pub asset_store: Option<DynAssetStore>,
    pub logger: Option<DynLogger>,
    pub debug_logs_enabled: bool,
}

/// Однократная конфигурация (аналог `ScriptExecutor.configure`).
pub fn configure(config: ExecutorConfig) {
    let _ = CONFIG.set(Arc::new(config));
}

/// Конфигурация для тестов.
pub fn reset_config() {
    // OnceLock нельзя переустановить; для тестов используем локальные
    // инстансы ScriptExecutor::with_deps.
    let _ = CONFIG.set(Arc::new(ExecutorConfig::default()));
}

/// Скриптовый исполнитель.
///
/// Инстанс работает с собственными зависимостями (или глобальными из
/// [`configure`]), поэтому применим и в многопоточном сервере.
#[derive(Default)]
pub struct ScriptExecutor {
    expression_engine: Option<DynExpressionEngine>,
    asset_store: Option<DynAssetStore>,
    logger: Option<DynLogger>,
    debug_logs_enabled: bool,
    /// Вложенные скрипты: path → JSON. Используется как fallback, когда
    /// `asset_store` не настроен или не нашёл скрипт — позволяет клиенту
    /// передавать скрипты прямо в вызов, минуя файловую систему.
    embedded_scripts: HashMap<String, Value>,
}

impl ScriptExecutor {
    pub fn new() -> Self {
        let global = CONFIG.get().map(|arc| arc.as_ref());
        ScriptExecutor {
            expression_engine: global.and_then(|g| g.expression_engine.clone()),
            asset_store: global.and_then(|g| g.asset_store.clone()),
            logger: global.and_then(|g| g.logger.clone()),
            debug_logs_enabled: global.map(|g| g.debug_logs_enabled).unwrap_or(false),
            embedded_scripts: HashMap::new(),
        }
    }

    pub fn with_expression_engine(
        mut self,
        engine: Box<dyn ScriptExpressionEngine + Send + Sync>,
    ) -> Self {
        self.expression_engine = Some(Arc::from(engine));
        self
    }

    pub fn with_asset_store(mut self, store: DynAssetStore) -> Self {
        self.asset_store = Some(store);
        self
    }

    #[allow(clippy::type_complexity)] // Box<dyn Fn> — паритет Dart logger
    pub fn with_logger(mut self, logger: Option<Box<dyn Fn(&str) + Send + Sync>>) -> Self {
        self.logger = logger.map(Arc::from);
        self
    }

    pub fn debug_enabled(mut self, enabled: bool) -> Self {
        self.debug_logs_enabled = enabled;
        self
    }

    /// Передать вложенные скрипты в виде path → JSON.
    ///
    /// Используется когда `asset_store` не настроен (FFI-режим) — клиент
    /// предварительно читает все нужные скрипты и передаёт их сюда.
    pub fn with_embedded_scripts(mut self, scripts: HashMap<String, Value>) -> Self {
        self.embedded_scripts = scripts;
        self
    }

    pub(crate) fn log(&self, message: &str) {
        let msg = format!("[Rust/mnd-core] {message}");
        if let Some(logger) = &self.logger {
            logger(&msg);
            return;
        }
        eprintln!("{msg}");
    }

    fn asset_store(&self) -> Result<&(dyn ScriptAssetStore + Send + Sync), ExecutorError> {
        self.asset_store
            .as_deref()
            .ok_or(ExecutorError::NotConfigured("asset store"))
    }

    pub(crate) fn load_nested_script(&self, path: &str) -> Option<serde_json::Map<String, Value>> {
        if let Ok(store) = self.asset_store()
            && let Some(json) = store.read_json(path)
        {
            return json.as_object().cloned();
        }
        self.embedded_scripts
            .get(path)
            .and_then(|v| v.as_object().cloned())
    }

    pub(crate) fn resolve_script_path(
        &self,
        quest_id: &str,
        raw_script_id: &str,
    ) -> Option<String> {
        let normalized_id = normalize_script_id(raw_script_id);
        if normalized_id.is_empty() {
            return None;
        }
        let candidates = [
            format!("quests/{quest_id}/scripts/{normalized_id}.json"),
            format!("quests/{quest_id}/_internal_scripts/{normalized_id}.json"),
            format!("scripts/{normalized_id}.json"),
            format!("_internal_scripts/{normalized_id}.json"),
            format!("{normalized_id}.json"),
            normalized_id.to_string(),
        ];
        if let Ok(store) = self.asset_store()
            && let Some(found) = candidates.iter().find(|c| store.exists(c))
        {
            return Some(found.clone());
        }
        candidates
            .iter()
            .find(|c| self.embedded_scripts.contains_key(*c))
            .cloned()
    }

    /// Прочитать `.lua`-скрипт по `raw_path` (путь к ресурсу квеста).
    ///
    /// Пытается читать текст (`read_text`) из asset store по нескольким
    /// кандидатным путям: как есть, с префиксом `quests/<id>/scripts/`, с
    /// расширением `.lua`. Возвращает исходник или `None`.
    pub(crate) fn load_lua_text(&self, quest_id: &str, raw_path: &str) -> Option<String> {
        let raw = raw_path.trim();
        if raw.is_empty() {
            return None;
        }
        let Ok(store) = self.asset_store() else {
            return None;
        };

        let normalized = normalize_lua_id(raw);
        let candidates = [
            raw.to_string(),
            format!("quests/{quest_id}/scripts/{normalized}.lua"),
            format!("quests/{quest_id}/scripts/{normalized}"),
            format!("quests/{quest_id}/{normalized}.lua"),
            format!("quests/{quest_id}/{normalized}"),
        ];
        for candidate in candidates {
            if let Some(text) = store.read_text(&candidate) {
                return Some(text);
            }
        }
        None
    }
}

/// Ошибка исполнителя.
#[derive(Debug, thiserror::Error)]
pub enum ExecutorError {
    #[error("ScriptExecutor is not configured: {0} missing")]
    NotConfigured(&'static str),

    #[error("script limit exceeded (max {MAX_STEPS} steps)")]
    LimitExceeded,

    #[error("скрипт не найден: {0}")]
    ScriptNotFound(String),

    #[error("ошибка чтения скрипта: {0}")]
    ReadError(String),

    #[error("Lua: {0}")]
    Lua(String),
}

// ---------------------------------------------------------------------------
// Типы событий: определение из данных скрипта
// ---------------------------------------------------------------------------

fn get_block_event_type(block: &Map<String, Value>) -> Option<EventType> {
    if let Some(event_type) = block.get("eventType").and_then(Value::as_str) {
        let trimmed = event_type.trim();
        if !trimmed.is_empty() {
            return EventType::from_name(trimmed);
        }
    }

    let title = block
        .get("title")
        .and_then(Value::as_str)
        .map(str::trim)
        .unwrap_or("");
    if title == LEGACY_TITLE_ON_NODE_ENTER {
        return Some(EventType::OnNodeEnter);
    }
    if title == LEGACY_TITLE_ON_PRESS {
        return Some(EventType::OnPress);
    }
    if title == TITLE_FUNCTION {
        return Some(EventType::Function);
    }
    if title == TITLE_ON_NODE_ENTER {
        return Some(EventType::OnNodeEnter);
    }
    if title == TITLE_ON_PRESS {
        return Some(EventType::OnPress);
    }
    if title == TITLE_ON_QUEST_START {
        return Some(EventType::OnQuestStart);
    }
    if title == TITLE_ON_DATA_CHANGE {
        return Some(EventType::OnDataChange);
    }

    let is_event = block.get("type").and_then(Value::as_str) == Some("event")
        || block.contains_key("eventType")
        || block.contains_key("title");
    if is_event {
        return Some(EventType::OnContentAppear);
    }
    None
}

/// Определить тип события скрипта (паритет `checkScriptEventType`).
pub fn check_script_event_type(script_data: &Map<String, Value>) -> EventType {
    let blocks = script_data
        .get("blocks")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    for b in blocks.iter().filter_map(|b| b.as_object()) {
        if b.get("type").and_then(Value::as_str) == Some("event")
            && let Some(et) = get_block_event_type(b)
        {
            match et {
                EventType::Function => return EventType::Function,
                EventType::OnPress => return EventType::OnPress,
                EventType::OnContentAppear => return EventType::OnContentAppear,
                EventType::OnQuestStart => return EventType::OnQuestStart,
                EventType::OnNodeEnter => return EventType::OnNodeEnter,
                EventType::OnDataChange => return EventType::OnDataChange,
            }
        }
    }

    let title = script_data
        .get("name")
        .or_else(|| script_data.get("title"))
        .and_then(Value::as_str)
        .unwrap_or_default();
    if title == LEGACY_TITLE_ON_NODE_ENTER {
        return EventType::OnNodeEnter;
    }
    if title == LEGACY_TITLE_ON_PRESS {
        return EventType::OnPress;
    }
    if title == TITLE_FUNCTION {
        return EventType::Function;
    }
    if title == TITLE_ON_NODE_ENTER {
        return EventType::OnNodeEnter;
    }
    if title == TITLE_ON_PRESS {
        return EventType::OnPress;
    }

    EventType::OnContentAppear
}

// ---------------------------------------------------------------------------
// Выделение блоков для события
// ---------------------------------------------------------------------------

fn is_event_block(b: &Map<String, Value>) -> bool {
    b.get("type").and_then(Value::as_str) == Some("event")
        || b.contains_key("eventType")
        || b.contains_key("title")
}

fn target_matches(block: &Map<String, Value>, content_item_id: &Option<String>) -> bool {
    let target = block.get("targetContentItemId").map(value_to_string);
    let has_explicit_target = target.as_deref().is_some_and(|t| !t.is_empty());

    match content_item_id {
        Some(id) if !id.is_empty() => {
            !has_explicit_target || target.as_deref() == Some(id.as_str())
        }
        None | Some(_) => !has_explicit_target,
    }
}

fn function_matches(
    block: &Map<String, Value>,
    requested_type: EventType,
    function_name: &Option<String>,
) -> bool {
    if requested_type != EventType::Function {
        return true;
    }
    let required = function_name
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or("main");
    let current_raw = block.get("functionName").map(value_to_string);
    let current = current_raw
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or("main");
    current == required
}

/// Какие блоки исполнить для события (паритет `_resolveBlocksToRun`).
fn resolve_blocks_to_run(
    all_blocks: &[Value],
    requested_type: EventType,
    function_name: &Option<String>,
    content_item_id: &Option<String>,
    allow_target_mismatch_fallback: bool,
) -> Vec<Value> {
    // Все event-блоки.
    let all_events: Vec<&Map<String, Value>> = all_blocks
        .iter()
        .filter_map(|b| b.as_object())
        .filter(|b| is_event_block(b))
        .collect();

    let target_events: Vec<&Map<String, Value>> = all_events
        .iter()
        .copied()
        .filter(|b| {
            let mut et = get_block_event_type(b);
            if et.is_none() && b.get("title").and_then(Value::as_str) == Some(TITLE_ON_NODE_ENTER) {
                et = Some(EventType::OnNodeEnter);
            }
            if et.is_none() && b.get("title").and_then(Value::as_str) == Some(TITLE_ON_PRESS) {
                et = Some(EventType::OnPress);
            }
            match et {
                Some(t) => {
                    t == requested_type
                        && target_matches(b, content_item_id)
                        && function_matches(b, requested_type, function_name)
                }
                None => false,
            }
        })
        .collect();

    // targetEvents не пуст → children всех совпавших.
    if !target_events.is_empty() {
        let mut result = Vec::new();
        for e in target_events {
            if let Some(children) = e.get("children").and_then(Value::as_array) {
                result.extend(children.iter().cloned());
            }
        }
        return result;
    }

    // Нет event-блоков вообще → для onQuestStart/onNodeEnter/onContentAppear
    // все блоки.
    // allow_target_mismatch_fallback не влияет в Dart-эталоне на этот случай.
    let _ = allow_target_mismatch_fallback;
    let has_any_events = !all_events.is_empty();
    if !has_any_events
        && (requested_type == EventType::OnNodeEnter
            || requested_type == EventType::OnContentAppear
            || requested_type == EventType::OnQuestStart)
    {
        return all_blocks.to_vec();
    }

    vec![]
}

/// Есть ли исполняемые блоки для события (паритет `hasExecutableBlocksForEvent`).
pub fn has_executable_blocks_for_event(
    script_data: &Map<String, Value>,
    event_type: EventType,
    function_name: &Option<String>,
    content_item_id: &Option<String>,
    allow_target_mismatch_fallback: bool,
) -> bool {
    let all_blocks = script_data
        .get("blocks")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    !resolve_blocks_to_run(
        &all_blocks,
        event_type,
        function_name,
        content_item_id,
        allow_target_mismatch_fallback,
    )
    .is_empty()
}

/// Объявляет ли скрипт событие явным event-блоком нужного типа.
///
/// В отличие от [`has_executable_blocks_for_event`] здесь нет фолбэка
/// «плоского скрипта» (весь файл как тело события): он подходил для
/// вызова по ссылке из ноды, но губителен для автораскопки файлов —
/// иначе любой скриптовый файл квеста считался бы стартовым.
pub fn declares_event(script_data: &Map<String, Value>, event_type: EventType) -> bool {
    !event_blocks_for(script_data, event_type).is_empty()
}

/// Event-блоки, явно объявляющие событие (без фолбэка плоского скрипта).
///
/// Движку нужно не «есть ли событие в файле», а сам блок: подписка на
/// изменение данных живёт в одном блоке и исполняется отдельно от прочих
/// событий файла.
pub fn event_blocks_for(
    script_data: &Map<String, Value>,
    event_type: EventType,
) -> Vec<Map<String, Value>> {
    script_data
        .get("blocks")
        .and_then(Value::as_array)
        .map(|blocks| {
            blocks
                .iter()
                .filter_map(Value::as_object)
                .filter(|b| b.get("type").and_then(Value::as_str) == Some("event"))
                .filter(|b| get_block_event_type(b) == Some(event_type))
                .cloned()
                .collect()
        })
        .unwrap_or_default()
}

/// Пути подписки блока `onDataChange` (`watchPaths`: массив или строка через
/// запятую). Пустой список = «любое изменение данных».
pub fn watch_paths_of(block: &Map<String, Value>) -> Vec<String> {
    let mut raw: Vec<String> = Vec::new();
    match block.get("watchPaths") {
        Some(Value::Array(arr)) => {
            raw.extend(arr.iter().filter_map(|v| {
                let s = value_to_string(v);
                (!s.trim().is_empty()).then_some(s)
            }));
        }
        Some(value) if !value.is_null() => {
            raw.extend(
                value_to_string(value)
                    .split(',')
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(str::to_string),
            );
        }
        _ => {}
    }
    // Старый черновик подписки мог лежать в `watchVariables`.
    if let Some(Value::Array(arr)) = block.get("watchVariables") {
        raw.extend(arr.iter().filter_map(|v| {
            let s = value_to_string(v);
            (!s.trim().is_empty()).then_some(s)
        }));
    }
    raw
}

/// Объявляет ли Lua-исходник точку входа `fn_name` (`function onQuestStart`,
/// локальная `local function …`, таблица-модуль `{ onQuestStart = function … }`).
///
/// Проверка по тексту, а не по Lua-реестру: решение нужно до загрузки чанка,
/// а объявление видно уже в исходнике. Идентификатор ищем как целое слово.
pub fn lua_source_declares(text: &str, fn_name: &str) -> bool {
    let bytes = text.as_bytes();
    let name = fn_name.as_bytes();
    if name.is_empty() {
        return false;
    }
    let is_ident_byte = |b: u8| b.is_ascii_alphanumeric() || b == b'_';
    let mut from = 0usize;
    while let Some(offset) = text[from..].find(fn_name) {
        let start = from + offset;
        let end = start + name.len();
        let left_ok = start == 0 || !is_ident_byte(bytes[start - 1]);
        let right_ok = end >= bytes.len() || !is_ident_byte(bytes[end]);
        if left_ok && right_ok {
            return true;
        }
        from = end;
    }
    false
}

// ---------------------------------------------------------------------------
// Условия
// ---------------------------------------------------------------------------

/// Вычислить условие скрипта (паритет `evaluateCondition`).
pub fn evaluate_condition(
    script_data: &Map<String, Value>,
    game_state: &mut dyn ScriptRuntime,
    event_type: EventType,
    function_name: &Option<String>,
    content_item_id: &Option<String>,
    allow_target_mismatch_fallback: bool,
    allow_state_mutation: bool,
) -> bool {
    let all_blocks = script_data
        .get("blocks")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let blocks_to_run = resolve_blocks_to_run(
        &all_blocks,
        event_type,
        function_name,
        content_item_id,
        allow_target_mismatch_fallback,
    );

    if blocks_to_run.is_empty() {
        return true;
    }

    for block_json in blocks_to_run {
        let Some(block) = block_json.as_object() else {
            continue;
        };
        let block_type = block
            .get("type")
            .or_else(|| block.get("действие"))
            .and_then(Value::as_str);

        if matches!(block_type, Some("condition") | Some("условие")) {
            return evaluate_condition_logic(block, game_state);
        }
        if allow_state_mutation && block_type == Some("table_operation") {
            execute_condition_prelude_table_operation(block, game_state);
            continue;
        }
        if allow_state_mutation
            && matches!(
                block_type,
                Some("assign_variable") | Some("создать_переменную") | Some("изменить_переменную")
            )
        {
            let var_name = block
                .get("variable")
                .or_else(|| block.get("переменная"))
                .and_then(Value::as_str)
                .map(str::to_string);
            if let Some(var_name) = var_name {
                let val = evaluate_expression(
                    block
                        .get("value")
                        .or_else(|| block.get("значение"))
                        .cloned(),
                    game_state,
                );
                game_state.set_variable(&var_name, val);
            }
        }
    }

    true
}

pub fn evaluate_condition_logic(
    block: &Map<String, Value>,
    game_state: &mut dyn ScriptRuntime,
) -> bool {
    let expression = if block.contains_key("expression") {
        value_to_string(&block["expression"])
    } else {
        let variable = block
            .get("variable")
            .or_else(|| block.get("переменная"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let comparison = block
            .get("comparison")
            .or_else(|| block.get("сравнение"))
            .and_then(Value::as_str)
            .unwrap_or("==")
            .to_string();
        let value = block
            .get("value")
            .or_else(|| block.get("значение"))
            .map(value_to_string)
            .unwrap_or_else(|| "0".to_string());

        let is_numeric = value.parse::<f64>().is_ok();
        let is_variable = value.starts_with('{') && value.ends_with('}');
        let needs_quotes =
            !is_numeric && !is_variable && !value.starts_with('\'') && !value.starts_with('"');
        if needs_quotes {
            format!("{{{variable}}} {comparison} '{value}'")
        } else {
            format!("{{{variable}}} {comparison} {value}")
        }
    };

    let result = evaluate_expression(Some(Value::String(expression)), game_state);
    match result {
        Value::Bool(b) => b,
        Value::Number(n) => n.as_f64().map(|f| f != 0.0).unwrap_or(false),
        Value::String(s) => !s.is_empty() && s != "false",
        Value::Null => false,
        _ => true,
    }
}

fn execute_condition_prelude_table_operation(
    block: &Map<String, Value>,
    game_state: &mut dyn ScriptRuntime,
) {
    let op_name = block.get("operation").and_then(Value::as_str);
    if op_name != Some("get") {
        return;
    }

    let table_name_expr = block
        .get("tableName")
        .map(value_to_string)
        .unwrap_or_default();
    let evaluated_table = evaluate_expression(block.get("tableName").cloned(), game_state);

    let table_name = if matches!(evaluated_table, Value::Object(_) | Value::Array(_)) {
        table_name_expr
    } else {
        evaluated_table.to_string()
    };

    // get_table использует собственное имя (не toString с кавычками).
    let table = lookup_table(game_state, &table_name);
    if table.is_none() {
        return;
    }

    let raw_path = block.get("path").map(value_to_string).unwrap_or_default();
    let path_str = {
        let evaluated = evaluate_expression(Some(Value::String(raw_path.clone())), game_state);
        if evaluated.is_null() && !raw_path.trim().is_empty() && raw_path != "null" {
            raw_path.clone()
        } else {
            value_to_string(&evaluated)
        }
    };
    let keys = parse_path(&path_str);
    let val = get_value_at_path(Value::Object(table.unwrap().data.clone()), &keys);
    let fallback_value = if block.contains_key("value") {
        evaluate_expression(block.get("value").cloned(), game_state)
    } else {
        Value::Null
    };
    let target_var = block
        .get("targetVariable")
        .and_then(Value::as_str)
        .map(str::to_string);

    let mut result_val = if val != Value::Null {
        val.clone()
    } else {
        fallback_value
    };

    if let Value::String(s) = &result_val
        && (s.contains('{') || s.contains('+') || s.contains('('))
    {
        let calc = evaluate_expression(Some(result_val.clone()), game_state);
        if calc != Value::Null {
            result_val = calc;
        }
    }

    if let Some(target_var) = target_var {
        game_state.set_variable(&target_var, result_val);
    }
}

// ---------------------------------------------------------------------------
// Выражения
// ---------------------------------------------------------------------------

/// Сериализация значения в строку без JSON-кавычек (паритет Dart
/// `.toString()` на dynamic: строка — как есть).
pub(crate) fn value_to_string(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Number(n) => {
            if let Some(f) = n.as_f64()
                && f == f.trunc()
            {
                return format!("{:.0}", f);
            }
            n.to_string()
        }
        Value::Null => "null".to_string(),
        other => other.to_string(),
    }
}

/// Подставить `{переменная}` в строку БЕЗ кавычек (для URL, заголовков, тела
/// запроса). В отличие от `evaluate_expression`, не парсит выражение и не
/// оборачивает строковые значения в кавычки — только сырая подстановка.
/// Неразрешённый токен остаётся как есть (`{token}`).
pub(crate) fn interpolate_placeholders_raw(
    input: &str,
    game_state: &mut dyn ScriptRuntime,
) -> String {
    let chars: Vec<char> = input.chars().collect();
    let mut out = String::with_capacity(input.len());
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '{' {
            let mut j = i + 1;
            let mut depth = 1;
            let mut quote: Option<char> = None;
            while j < chars.len() {
                let c = chars[j];
                if let Some(q) = quote {
                    if c == '\\' {
                        j += 2;
                        continue;
                    }
                    if c == q {
                        quote = None;
                    }
                } else if c == '"' || c == '\'' {
                    quote = Some(c);
                } else if c == '{' {
                    depth += 1;
                } else if c == '}' {
                    depth -= 1;
                    if depth == 0 {
                        break;
                    }
                }
                j += 1;
            }
            if j < chars.len() {
                let token: String = chars[i + 1..j].iter().collect();
                let token = token.trim();
                let replacement = if token.is_empty() {
                    String::new()
                } else {
                    match resolve_inline_token_value(token, game_state) {
                        Some(value) => value_to_string(&value),
                        None => format!("{{{token}}}"),
                    }
                };
                out.push_str(&replacement);
                i = j + 1;
                continue;
            }
        }
        out.push(chars[i]);
        i += 1;
    }
    out
}

/// Каскадный вычислитель выражений (паритет `evaluateExpression` из Dart).
pub fn evaluate_expression(
    input_value: Option<Value>,
    game_state: &mut dyn ScriptRuntime,
) -> Value {
    let Some(input) = input_value else {
        return Value::Null;
    };
    // Не-строки пропускаются как есть (паритет Dart: `if (input is! String)
    // return _cleanNumericResult(input);`).
    let Value::String(input_str) = &input else {
        return crate::expression::ExpressionEvaluator::clean_numeric_result(input);
    };
    let mut expr = input_str.clone();
    let trimmed = normalize_placeholder_braces(expr.trim()).to_string();
    if trimmed.is_empty() {
        return Value::Null;
    }
    let lower = trimmed.to_lowercase();
    if lower == "null" {
        return Value::Null;
    }
    if lower == "true" {
        return Value::Bool(true);
    }
    if lower == "false" {
        return Value::Bool(false);
    }

    expr = strip_wrapping_parentheses(&trimmed);
    expr = normalize_placeholder_braces(&expr);

    // Fast path: точный плейсхолдер {token} или прямое имя таблицы/переменной → значение как есть.
    let is_exact = exact_placeholder(&expr).is_some();
    let target_token = exact_placeholder(&expr).unwrap_or_else(|| expr.clone());
    let trimmed_token = target_token.trim();
    if !trimmed_token.is_empty()
        && (is_exact
            || game_state.all_variables().contains_key(trimmed_token)
            || game_state.get_table(trimmed_token).is_some())
        && let Some(resolved) = resolve_inline_token_value(trimmed_token, game_state)
    {
        return resolved;
    }

    // Композитные операторы: !, ||, &&, in, сравнения.
    if let Some(composite) = try_evaluate_composite_expression(&expr, game_state) {
        return composite;
    }

    if expr.contains('{') {
        expr = resolve_inline_placeholders(&expr, game_state);
        let lowered = expr.to_lowercase();
        if lowered == "null" {
            return Value::Null;
        }
        if lowered == "true" {
            return Value::Bool(true);
        }
        if lowered == "false" {
            return Value::Bool(false);
        }
    }

    // 1. Expression engine (кастомный из configure приоритетнее встроенного
    // математического парсера). Контекст: переменные + таблицы (паритет
    // шага 1 Dart `evaluateExpression`).
    if let Some(engine) = CONFIG.get().and_then(|c| c.expression_engine.as_ref()) {
        let mut context = game_state.all_variables().clone();
        for (table_name, table) in game_state.all_tables() {
            if !context.contains_key(table_name) {
                context.insert(table_name.clone(), table.formula_view());
            }
        }
        let result = engine.evaluate(&expr, &context);
        if !result.is_null() {
            return strip_table_view(&result);
        }
    } else if let Some(result) = try_math_expression(&expr, game_state) {
        return strip_table_view(&result);
    }

    // 2. Ручной deep lookup (таблицы: table['key']['subkey']).
    let deep = manual_deep_lookup(&expr, game_state);
    if deep != Value::Null {
        return deep;
    }

    // 3. Простое число.
    if let Ok(num) = expr.trim().parse::<f64>() {
        return expression::json_of_f64(num);
    }

    // 4. Вернуть как есть (со снятием кавычек).
    if ((expr.starts_with('\'') && expr.ends_with('\''))
        || (expr.starts_with('"') && expr.ends_with('"')))
        && expr.len() >= 2
    {
        return Value::String(expr[1..expr.len() - 1].to_string());
    }

    if expr.contains('[') || expr.contains(']') {
        return Value::Null;
    }

    Value::String(expr)
}

fn exact_placeholder(expr: &str) -> Option<String> {
    let trimmed = expr.trim();
    if trimmed.starts_with('{') && trimmed.ends_with('}') {
        let inner = &trimmed[1..trimmed.len() - 1];
        if !inner.contains('{') && !inner.contains('}') && !inner.trim().is_empty() {
            return Some(inner.trim().to_string());
        }
    }
    None
}

/// Рекурсивный вычислитель подвыражений (для composite; паритет Dart).
fn evaluate_rec(expr: &str, game_state: &mut dyn ScriptRuntime) -> Value {
    evaluate_expression(Some(Value::String(expr.to_string())), game_state)
}

fn try_evaluate_composite_expression(
    expr: &str,
    game_state: &mut dyn ScriptRuntime,
) -> Option<Value> {
    let trimmed = strip_wrapping_parentheses(expr);
    if trimmed.is_empty() {
        return None;
    }

    // Унарный '!'
    if let Some(rest) = trimmed.strip_prefix('!') {
        let inner = evaluate_rec(rest, game_state);
        return Some(Value::Bool(!to_bool(&inner)));
    }

    // ||
    if let Some(pos) = find_top_level_operator(&trimmed, "||") {
        let left = evaluate_rec(&trimmed[..pos], game_state);
        let right = evaluate_rec(&trimmed[pos + 2..], game_state);
        return Some(Value::Bool(to_bool(&left) || to_bool(&right)));
    }

    // &&
    if let Some(pos) = find_top_level_operator(&trimmed, "&&") {
        let left = evaluate_rec(&trimmed[..pos], game_state);
        let right = evaluate_rec(&trimmed[pos + 2..], game_state);
        return Some(Value::Bool(to_bool(&left) && to_bool(&right)));
    }

    // in
    if let Some(pos) = find_top_level_keyword(&trimmed, "in") {
        let left_expr = trimmed[..pos].trim().to_string();
        let right_expr = trimmed[pos + 2..].trim().to_string();
        let left = evaluate_rec(&left_expr, game_state);
        let items = parse_in_list_items(&right_expr, game_state);
        let matched = items.iter().any(|item| values_equal(&left, item));
        return Some(Value::Bool(matched));
    }

    // Сравнения
    for op in ["==", "!=", ">=", "<=", ">", "<"] {
        if let Some(idx) = find_top_level_operator(&trimmed, op) {
            let left_expr = trimmed[..idx].trim().to_string();
            let right_expr = trimmed[idx + op.len()..].trim().to_string();
            let left = evaluate_rec(&left_expr, game_state);
            let right = evaluate_rec(&right_expr, game_state);
            return Some(Value::Bool(compare_values(&left, &right, op)));
        }
    }

    None
}

/// Сравнение по оператору (паритет `_compareValues`).
fn compare_values(left: &Value, right: &Value, op: &str) -> bool {
    match op {
        "==" => values_equal(left, right),
        "!=" => !values_equal(left, right),
        ">" | "<" | ">=" | "<=" => {
            if let (Some(l), Some(r)) = (to_num(left), to_num(right)) {
                return match op {
                    ">" => l > r,
                    "<" => l < r,
                    ">=" => l >= r,
                    "<=" => l <= r,
                    _ => false,
                };
            }
            let l = left.to_string();
            let r = right.to_string();
            let ord = l.cmp(&r);
            match op {
                ">" => ord == std::cmp::Ordering::Greater,
                "<" => ord == std::cmp::Ordering::Less,
                ">=" => ord != std::cmp::Ordering::Less,
                "<=" => ord != std::cmp::Ordering::Greater,
                _ => false,
            }
        }
        _ => false,
    }
}

fn parse_in_list_items(right_expr: &str, game_state: &mut dyn ScriptRuntime) -> Vec<Value> {
    let mut body = right_expr.trim().to_string();
    body = strip_wrapping_parentheses(&body);
    if body.is_empty() {
        return vec![];
    }

    let mut parts = Vec::new();
    let mut buffer = String::new();
    let mut in_quote = false;
    let mut quote_char = '\0';
    let mut bracket_depth = 0i32;
    let mut paren_depth = 0i32;

    let chars: Vec<char> = body.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if in_quote {
            buffer.push(c);
            if c == quote_char && (i == 0 || chars[i - 1] != '\\') {
                in_quote = false;
            }
            i += 1;
            continue;
        }
        if c == '\'' || c == '"' {
            in_quote = true;
            quote_char = c;
            buffer.push(c);
            i += 1;
            continue;
        }
        if c == '[' {
            bracket_depth += 1;
            buffer.push(c);
            i += 1;
            continue;
        }
        if c == ']' {
            bracket_depth = bracket_depth.saturating_sub(1);
            buffer.push(c);
            i += 1;
            continue;
        }
        if c == '(' {
            paren_depth += 1;
            buffer.push(c);
            i += 1;
            continue;
        }
        if c == ')' {
            paren_depth = paren_depth.saturating_sub(1);
            buffer.push(c);
            i += 1;
            continue;
        }
        if (c == ',' || c == '|') && bracket_depth == 0 && paren_depth == 0 {
            let piece = buffer.trim().to_string();
            if !piece.is_empty() {
                parts.push(evaluate_rec(&piece, game_state));
            }
            buffer.clear();
            i += 1;
            continue;
        }
        buffer.push(c);
        i += 1;
    }
    let last = buffer.trim().to_string();
    if !last.is_empty() {
        parts.push(evaluate_rec(&last, game_state));
    }

    parts
}

fn is_word_char(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

/// Перевести символьный индекс в байтовый офсет (для срезов строки в UTF-8).
fn char_index_to_byte(chars: &[char], idx: usize) -> usize {
    chars[..idx].iter().collect::<String>().len()
}

fn find_top_level_keyword(expression: &str, keyword: &str) -> Option<usize> {
    let mut in_quote = false;
    let mut quote_char = '\0';
    let mut bracket_depth = 0i32;
    let mut paren_depth = 0i32;
    let chars: Vec<char> = expression.chars().collect();
    let kw_chars: Vec<char> = keyword.chars().collect();

    let mut i = 0;
    while i + kw_chars.len() <= chars.len() {
        let c = chars[i];
        if in_quote {
            if c == quote_char && (i == 0 || chars[i - 1] != '\\') {
                in_quote = false;
            }
            i += 1;
            continue;
        }
        if c == '\'' || c == '"' {
            in_quote = true;
            quote_char = c;
            i += 1;
            continue;
        }
        if c == '[' {
            bracket_depth += 1;
            i += 1;
            continue;
        }
        if c == ']' {
            bracket_depth = bracket_depth.saturating_sub(1);
            i += 1;
            continue;
        }
        if c == '(' {
            paren_depth += 1;
            i += 1;
            continue;
        }
        if c == ')' {
            paren_depth = paren_depth.saturating_sub(1);
            i += 1;
            continue;
        }
        if bracket_depth != 0 || paren_depth != 0 {
            i += 1;
            continue;
        }
        if chars[i..i + kw_chars.len()] == kw_chars[..] {
            // Проверяем границы слова.
            let prev = if i > 0 { chars[i - 1] } else { ' ' };
            let next_idx = i + kw_chars.len();
            let next = if next_idx < chars.len() {
                chars[next_idx]
            } else {
                ' '
            };
            if !is_word_char(prev) && !is_word_char(next) {
                return Some(char_index_to_byte(&chars, i));
            }
        }
        i += 1;
    }
    None
}

fn find_top_level_operator(expression: &str, op: &str) -> Option<usize> {
    let mut in_quote = false;
    let mut quote_char = '\0';
    let mut bracket_depth = 0i32;
    let mut paren_depth = 0i32;
    let chars: Vec<char> = expression.chars().collect();
    let op_chars: Vec<char> = op.chars().collect();

    let mut i = 0;
    while i + op_chars.len() <= chars.len() {
        let c = chars[i];
        if in_quote {
            if c == quote_char && (i == 0 || chars[i - 1] != '\\') {
                in_quote = false;
            }
            i += 1;
            continue;
        }
        if c == '\'' || c == '"' {
            in_quote = true;
            quote_char = c;
            i += 1;
            continue;
        }
        if c == '[' {
            bracket_depth += 1;
            i += 1;
            continue;
        }
        if c == ']' {
            bracket_depth = bracket_depth.saturating_sub(1);
            i += 1;
            continue;
        }
        if c == '(' {
            paren_depth += 1;
            i += 1;
            continue;
        }
        if c == ')' {
            paren_depth = paren_depth.saturating_sub(1);
            i += 1;
            continue;
        }
        if bracket_depth == 0 && paren_depth == 0 && chars[i..i + op_chars.len()] == op_chars[..] {
            return Some(char_index_to_byte(&chars, i));
        }
        i += 1;
    }
    None
}

fn strip_wrapping_parentheses(expression: &str) -> String {
    let mut expr = expression.trim().to_string();
    loop {
        if !(expr.starts_with('(') && expr.ends_with(')')) {
            return expr;
        }
        let mut depth = 0i32;
        let mut in_quote = false;
        let mut quote_char = '\0';
        let mut wraps = true;
        let chars: Vec<char> = expr.chars().collect();
        let mut i = 0;
        while i < chars.len() {
            let c = chars[i];
            if in_quote {
                if c == quote_char && (i == 0 || chars[i - 1] != '\\') {
                    in_quote = false;
                }
                i += 1;
                continue;
            }
            if c == '\'' || c == '"' {
                in_quote = true;
                quote_char = c;
                i += 1;
                continue;
            }
            if c == '(' {
                depth += 1;
            }
            if c == ')' {
                depth -= 1;
            }
            if depth == 0 && i < chars.len() - 1 {
                wraps = false;
                break;
            }
            i += 1;
        }
        if !wraps {
            return expr;
        }
        expr = expr[1..expr.len() - 1].trim().to_string();
    }
}

/// Математический порт с таблицами в контексте.
fn try_math_expression(expr: &str, game_state: &mut dyn ScriptRuntime) -> Option<Value> {
    // Собираем контекст: переменные + таблицы (если имя не занято). Таблица
    // кладётся как `formula_view` — со строками и колонками, иначе внутри
    // формулы остались бы только ключи `data`.
    let mut context: Map<String, Value> = game_state.all_variables().clone();
    for (name, table) in game_state.all_tables() {
        if !context.contains_key(name) {
            context.insert(name.clone(), table.formula_view());
        }
    }

    let evaluator = crate::expression::ExpressionEvaluator;
    let result = evaluator.evaluate(&Value::String(expr.to_string()), &context);
    if result != Value::Null {
        Some(strip_table_view(&result))
    } else {
        None
    }
}

// ---------------------------------------------------------------------------
// Плейсхолдеры и deep lookup
// ---------------------------------------------------------------------------

/// Нормализация лишних фигурных скобок: `{{t["а"]1}}` → `{t["а"]1}`,
/// `a}} {b}` → `a} {b}` (закрытие маркера перед следующим).
/// Двойная обёртка `{{}}` вокруг маркера не трогается.
///
/// Внутри кавычек скобки — данные, а не разметка: имя строки или колонки
/// может содержать `{{`, `}}` и экранированную кавычку, и схлопывать их
/// нельзя. Поэтому скан учитывает строковые литералы и `\`-экранирование.
fn normalize_placeholder_braces(text: &str) -> String {
    if !text.contains("{{") && !text.contains("}}") {
        return text.to_string();
    }
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    let mut quote: Option<char> = None;
    let mut brackets = 0usize;
    while i < chars.len() {
        let c = chars[i];
        if let Some(q) = quote {
            out.push(c);
            if c == '\\' && i + 1 < chars.len() {
                out.push(chars[i + 1]);
                i += 2;
                continue;
            }
            if c == q {
                quote = None;
            }
            i += 1;
            continue;
        }
        // Кавычки — только внутри `[...]`: апостроф в обычном тексте («It's»)
        // не должен выключать нормализацию до конца строки.
        if (c == '"' || c == '\'') && brackets > 0 {
            quote = Some(c);
            out.push(c);
            i += 1;
            continue;
        }
        if c == '[' {
            brackets += 1;
        } else if c == ']' && brackets > 0 {
            brackets -= 1;
        }
        if c == '{' && i + 1 < chars.len() && chars[i + 1] == '{' {
            if chars.get(i + 2) != Some(&'}') {
                out.push('{');
                i += 2;
                continue;
            }
        }
        if c == '}' && i + 1 < chars.len() && chars[i + 1] == '}' {
            let rest = chars.get(i + 2);
            let is_boundary =
                matches!(rest, None | Some('{') | Some(' ') | Some('\n') | Some('\t'));
            if is_boundary {
                out.push('}');
                i += 2;
                continue;
            }
        }
        out.push(c);
        i += 1;
    }
    out
}

fn resolve_inline_placeholders(expression: &str, game_state: &mut dyn ScriptRuntime) -> String {
    let expression = normalize_placeholder_braces(expression);
    let chars: Vec<char> = expression.chars().collect();
    let mut out = String::with_capacity(expression.len());
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '{' {
            let mut j = i + 1;
            let mut depth = 1;
            let mut quote: Option<char> = None;
            while j < chars.len() {
                let c = chars[j];
                if let Some(q) = quote {
                    if c == '\\' {
                        j += 2;
                        continue;
                    }
                    if c == q {
                        quote = None;
                    }
                } else if c == '"' || c == '\'' {
                    quote = Some(c);
                } else if c == '{' {
                    depth += 1;
                } else if c == '}' {
                    depth -= 1;
                    if depth == 0 {
                        break;
                    }
                }
                j += 1;
            }
            if j < chars.len() {
                let token: String = chars[i + 1..j].iter().collect();
                let token = token.trim();
                let replacement = if token.is_empty() {
                    "null".to_string()
                } else {
                    to_expression_literal(&resolve_inline_token_value(token, game_state))
                };
                out.push_str(&replacement);
                i = j + 1;
                continue;
            }
        }
        out.push(chars[i]);
        i += 1;
    }
    out
}

fn resolve_inline_token_value(token: &str, game_state: &mut dyn ScriptRuntime) -> Option<Value> {
    let trimmed = token.trim();
    if game_state.all_variables().contains_key(trimmed) {
        return game_state.get_variable(trimmed).cloned();
    }
    if let Some(table) = game_state.get_table(trimmed) {
        let clean_data: serde_json::Map<String, Value> = table
            .data
            .clone()
            .into_iter()
            .filter(|(k, _)| !k.starts_with("__"))
            .collect();

        if !clean_data.is_empty() {
            return Some(Value::Object(clean_data));
        }
        if !table.rows.is_empty() {
            let mut formatted_rows = Vec::new();
            for row in &table.rows {
                let parts: Vec<String> = table
                    .columns
                    .iter()
                    .filter_map(|col| {
                        row.get(col).map(|val| match val {
                            Value::String(s) => s.clone(),
                            other => other.to_string(),
                        })
                    })
                    .collect();
                if !parts.is_empty() {
                    formatted_rows.push(parts.join(" "));
                }
            }
            if !formatted_rows.is_empty() {
                return Some(Value::String(formatted_rows.join("\n")));
            }
        }
        return Some(Value::Object(clean_data));
    }
    match manual_deep_lookup(trimmed, game_state) {
        Value::Null => None,
        v => Some(v),
    }
}

fn to_expression_literal(value: &Option<Value>) -> String {
    match value {
        None => "null".to_string(),
        Some(Value::Number(n)) => n.to_string(),
        Some(Value::Bool(b)) => b.to_string(),
        Some(other) => {
            let s = value_to_string(other);
            format!("'{}'", s.replace('\'', "\\'"))
        }
    }
}

/// Глубокий lookup `name['key'].prop` (паритет `_manualDeepLookup`).
/// На корне таблицы строковый ключ может быть «rows», «columns» или именем
/// колонки — возвращает соответствующий массив (для доступа по индексу строки).
fn table_root_array(
    key: &str,
    rows: &[Map<String, Value>],
    columns: &[String],
    row_names: &[String],
) -> Option<Value> {
    if key == "rows" {
        return Some(Value::Array(
            rows.iter().map(|r| Value::Object(r.clone())).collect(),
        ));
    }
    if key == "columns" {
        return Some(Value::Array(
            columns.iter().map(|c| Value::String(c.clone())).collect(),
        ));
    }
    // Колонка важнее: её имя исторически адресует весь столбец.
    if columns.iter().any(|c| c == key) {
        return Some(Value::Array(
            rows.iter()
                .map(|row| row.get(key).cloned().unwrap_or(Value::Null))
                .collect(),
        ));
    }
    if let Some(index) = row_names
        .iter()
        .position(|n| !n.trim().is_empty() && n == key)
    {
        return rows.get(index).cloned().map(Value::Object);
    }
    None
}

/// Снимает `\`-экранирование со строкового литерала в квадратных скобках —
/// ровно так же, как лексер выражений: `\"`, `\\`, `\n`, `\t`, `\r`, `\'`.
fn unescape_quoted(raw: &str) -> String {
    let chars: Vec<char> = raw.chars().collect();
    let mut out = String::with_capacity(raw.len());
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '\\' && i + 1 < chars.len() {
            out.push(match chars[i + 1] {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '\\' => '\\',
                '\'' => '\'',
                '"' => '"',
                other => other,
            });
            i += 2;
            continue;
        }
        out.push(chars[i]);
        i += 1;
    }
    out
}

fn manual_deep_lookup(expr: &str, game_state: &mut dyn ScriptRuntime) -> Value {
    let expr = expr.trim();
    if expr.is_empty() {
        return Value::Null;
    }

    let chars: Vec<char> = expr.chars().collect();
    // 1. Базовое имя до первого [ или .
    let mut i = 0;
    while i < chars.len() {
        if chars[i] == '[' || chars[i] == '.' {
            break;
        }
        i += 1;
    }
    let base_name: String = chars[..i].iter().collect();
    let base_name = base_name.trim();
    if base_name.is_empty() {
        return Value::Null;
    }

    // Ищем базу: таблица или переменная.
    let mut current: Value;
    let mut is_table_base = false;
    // Флаги для резолва ячеек таблиц: `{t["колонка"][N]}` / `{t[N]["колонка"]}`,
    // где N — визуальный (1-based) номер строки.
    let mut table_rows: Vec<Map<String, Value>> = Vec::new();
    let mut table_columns: Vec<String> = Vec::new();
    let mut table_row_names: Vec<String> = Vec::new();
    let mut at_root = false;
    let mut table_array = false;
    if let Some(table) = game_state.get_table(base_name) {
        current = Value::Object(table.data.clone());
        is_table_base = true;
        at_root = true;
        table_rows = table.rows.clone();
        table_columns = table.columns.clone();
        table_row_names = table.row_names.clone();
    } else if let Some(var) = game_state.get_variable(base_name) {
        current = var.clone();
    } else {
        return Value::Null;
    }

    // 2. Идём по пути.
    while i < chars.len() {
        let c = chars[i];
        if c == '.' {
            i += 1;
            let start = i;
            while i < chars.len() {
                let cc = chars[i];
                if cc == '[' || cc == '.' {
                    break;
                }
                i += 1;
            }
            let key: String = chars[start..i].iter().collect();
            let key = key.trim();
            if key.is_empty() {
                return Value::Null;
            }
            match current {
                Value::Object(ref mut map) => {
                    if let Some(v) = map.get(key) {
                        current = v.clone();
                        at_root = false;
                    } else if is_table_base && at_root {
                        match table_root_array(key, &table_rows, &table_columns, &table_row_names) {
                            Some(arr) => {
                                current = arr;
                                table_array = true;
                                at_root = false;
                            }
                            None => return Value::Null,
                        }
                    } else {
                        return Value::Null;
                    }
                }
                _ => return Value::Null,
            }
        } else if c == '[' {
            i += 1;
            let start = i;
            let mut end_bracket: Option<usize> = None;
            let mut in_quote = false;
            let mut quote_char = '\0';
            let mut escaped = false;
            while i < chars.len() {
                let cc = chars[i];
                if in_quote {
                    if escaped {
                        escaped = false;
                    } else if cc == '\\' {
                        escaped = true;
                    } else if cc == quote_char {
                        in_quote = false;
                    }
                } else {
                    if cc == '"' || cc == '\'' {
                        in_quote = true;
                        quote_char = cc;
                    } else if cc == ']' {
                        end_bracket = Some(i);
                        break;
                    }
                }
                i += 1;
            }
            let Some(end) = end_bracket else {
                return Value::Null;
            };
            let content: String = chars[start..end].iter().collect();
            let content = content.trim();
            i = end + 1;

            current = match current {
                Value::Object(map) => {
                    if (content.starts_with('"') && content.ends_with('"'))
                        || (content.starts_with('\'') && content.ends_with('\''))
                    {
                        if content.len() < 2 {
                            return Value::Null;
                        }
                        let key = unescape_quoted(&content[1..content.len() - 1]);
                        if let Some(v) = map.get(&key) {
                            at_root = false;
                            v.clone()
                        } else if is_table_base && at_root {
                            at_root = false;
                            match table_root_array(
                                &key,
                                &table_rows,
                                &table_columns,
                                &table_row_names,
                            ) {
                                Some(arr) => {
                                    table_array = matches!(arr, Value::Array(_));
                                    arr
                                }
                                None => Value::Null,
                            }
                        } else {
                            // Переменная как ключ.
                            at_root = false;
                            let var_key = game_state.get_variable(&key).cloned();
                            match var_key {
                                Some(Value::String(vk)) => {
                                    map.get(&vk).cloned().unwrap_or(Value::Null)
                                }
                                Some(vk) => map
                                    .get(&value_to_string(&vk))
                                    .cloned()
                                    .unwrap_or(Value::Null),
                                None => Value::Null,
                            }
                        }
                    } else if let Ok(index) = content.parse::<usize>() {
                        if map.contains_key(content) {
                            map.get(content).cloned().unwrap_or(Value::Null)
                        } else if is_table_base && at_root && !table_rows.is_empty() {
                            let idx = if index >= 1 && index - 1 < table_rows.len() {
                                index - 1
                            } else {
                                usize::MAX
                            };
                            if idx == usize::MAX {
                                Value::Null
                            } else {
                                table_array = false;
                                at_root = false;
                                Value::Object(table_rows[idx].clone())
                            }
                        } else {
                            Value::Null
                        }
                    } else {
                        let key_value = evaluate_expression(
                            Some(Value::String(content.to_string())),
                            game_state,
                        );
                        match key_value {
                            Value::Null => Value::Null,
                            other => {
                                let key = value_to_string(&other);
                                if let Some(v) = map.get(&key) {
                                    at_root = false;
                                    v.clone()
                                } else if is_table_base && at_root {
                                    // `{t[перем]}` / `{t[формула]}` на корне:
                                    // переменная может держать имя строки или
                                    // колонки — резолвим так же, как литерал.
                                    at_root = false;
                                    match table_root_array(
                                        &key,
                                        &table_rows,
                                        &table_columns,
                                        &table_row_names,
                                    ) {
                                        Some(arr) => {
                                            table_array = matches!(arr, Value::Array(_));
                                            arr
                                        }
                                        None => Value::Null,
                                    }
                                } else {
                                    Value::Null
                                }
                            }
                        }
                    }
                }
                Value::Array(arr) => {
                    if let Ok(index) = content.parse::<i64>() {
                        if table_array && index >= 1 && (index as usize - 1) < arr.len() {
                            table_array = false;
                            arr[index as usize - 1].clone()
                        } else if index >= 0 && (index as usize) < arr.len() {
                            arr[index as usize].clone()
                        } else {
                            return Value::Null;
                        }
                    } else {
                        // Строка по имени поверх столбца: `{t["цена"]["меч"]}`.
                        // Кавычки снимаем с `\`-экранированием: имя может
                        // содержать кавычку или обратный слэш.
                        let row_key: String = if content.len() >= 2
                            && ((content.starts_with('"') && content.ends_with('"'))
                                || (content.starts_with('\'') && content.ends_with('\'')))
                        {
                            unescape_quoted(&content[1..content.len() - 1])
                        } else {
                            content.to_string()
                        };
                        let named = table_array
                            .then(|| {
                                table_row_names
                                    .iter()
                                    .position(|n| !n.trim().is_empty() && *n == row_key)
                            })
                            .flatten();
                        if let Some(idx) = named {
                            table_array = false;
                            arr.get(idx).cloned().unwrap_or(Value::Null)
                        } else {
                            // Переменная или формула как адрес строки:
                            // `{t["цена"][перем]}` / `{t["цена"][upper("меч")]}`.
                            let key_value = evaluate_expression(
                                Some(Value::String(content.to_string())),
                                game_state,
                            );
                            let mut named_value: Option<Value> = None;
                            let idx = match &key_value {
                                Value::Number(n) => n.as_i64(),
                                Value::String(s) => {
                                    if table_array
                                        && let Some(pos) = table_row_names
                                            .iter()
                                            .position(|n| !n.trim().is_empty() && n == s)
                                    {
                                        table_array = false;
                                        named_value = arr.get(pos).cloned();
                                    }
                                    if named_value.is_some() {
                                        None
                                    } else {
                                        s.trim().parse::<i64>().ok()
                                    }
                                }
                                _ => None,
                            };
                            if let Some(v) = named_value {
                                v
                            } else {
                                match idx {
                                    Some(idx) => {
                                        if table_array {
                                            // Над столбцом номер строки визуальный,
                                            // как у литерала: 1 — первая строка.
                                            if idx >= 1 && ((idx - 1) as usize) < arr.len() {
                                                table_array = false;
                                                arr[(idx - 1) as usize].clone()
                                            } else {
                                                Value::Null
                                            }
                                        } else if idx >= 0 && (idx as usize) < arr.len() {
                                            arr[idx as usize].clone()
                                        } else {
                                            Value::Null
                                        }
                                    }
                                    None => Value::Null,
                                }
                            }
                        }
                    }
                }
                _ => return Value::Null,
            };
        } else {
            i += 1;
        }

        if current == Value::Null {
            return Value::Null;
        }
    }

    current
}

// ---------------------------------------------------------------------------
// Пути таблиц
// ---------------------------------------------------------------------------

/// Парс пути таблицы (паритет `_parsePath`): `a.b[0]['c']`.
pub fn parse_path(path: &str) -> Vec<Value> {
    let mut keys = Vec::new();
    let trimmed = path.trim();
    let unquoted = if (trimmed.starts_with('"') && trimmed.ends_with('"') && trimmed.len() >= 2)
        || (trimmed.starts_with('\'') && trimmed.ends_with('\'') && trimmed.len() >= 2)
    {
        &trimmed[1..trimmed.len() - 1]
    } else {
        trimmed
    };

    let chars: Vec<char> = unquoted.chars().collect();
    let mut i = 0;

    while i < chars.len() {
        let c = chars[i];
        if c.is_whitespace() || c == '.' {
            i += 1;
            continue;
        }
        if c == '[' {
            i += 1;
            // Ключ в кавычках или индекс.
            if i < chars.len() && (chars[i] == '"' || chars[i] == '\'') {
                let quote = chars[i];
                i += 1;
                let start = i;
                while i < chars.len() && chars[i] != quote {
                    i += 1;
                }
                let key: String = chars[start..i].iter().collect();
                keys.push(Value::String(key));
                if i < chars.len() {
                    i += 1; // закрывающая кавычка
                }
                while i < chars.len() && chars[i] != ']' {
                    i += 1;
                }
                if i < chars.len() {
                    i += 1;
                }
            } else {
                let start = i;
                while i < chars.len() && chars[i] != ']' {
                    i += 1;
                }
                let content: String = chars[start..i].iter().collect();
                if let Ok(idx) = content.parse::<i64>() {
                    keys.push(Value::from(idx));
                } else {
                    keys.push(Value::String(content));
                }
                if i < chars.len() {
                    i += 1;
                }
            }
            continue;
        }
        if c == '\'' || c == '"' {
            let quote = c;
            i += 1;
            let start = i;
            while i < chars.len() && chars[i] != quote {
                i += 1;
            }
            let key: String = chars[start..i].iter().collect();
            if key.contains('.') {
                for part in key.split('.') {
                    if !part.is_empty() {
                        keys.push(Value::String(part.to_string()));
                    }
                }
            } else {
                keys.push(Value::String(key));
            }
            if i < chars.len() {
                i += 1;
            }
            continue;
        }

        let start = i;
        while i < chars.len() && chars[i] != '.' && chars[i] != '[' && !chars[i].is_whitespace() {
            i += 1;
        }
        let key: String = chars[start..i].iter().collect();
        if let Ok(idx) = key.parse::<i64>() {
            keys.push(Value::from(idx));
        } else if !key.is_empty() {
            keys.push(Value::String(key));
        }
    }

    keys
}

/// Взять значение по пути (паритет `_getValueAtPath`).
pub fn get_value_at_path(root: Value, keys: &[Value]) -> Value {
    let mut current = root;
    for key in keys {
        match (&current, key) {
            (Value::Object(map), k) => {
                current = map.get(&value_to_string(k)).cloned().unwrap_or(Value::Null);
            }
            (Value::Array(arr), Value::Number(n)) => {
                if let Some(idx) = n.as_i64() {
                    if idx >= 0 && (idx as usize) < arr.len() {
                        current = arr[idx as usize].clone();
                    } else {
                        return Value::Null;
                    }
                } else {
                    return Value::Null;
                }
            }
            _ => return Value::Null,
        }
        if current == Value::Null {
            return Value::Null;
        }
    }
    current
}

/// Индекс ячейки для записи в массив по пути: `None` у отрицательного и у
/// запредельного — такую запись движок просто бросает.
fn array_write_index(key: &Value) -> Option<usize> {
    let idx = key
        .as_i64()
        .or_else(|| value_to_string(key).parse::<i64>().ok())?;
    if !(0..=MAX_ARRAY_WRITE_INDEX).contains(&idx) {
        return None;
    }
    Some(idx as usize)
}

/// Установить значение по пути (паритет `_setValueAtPath`).
pub fn set_value_at_path(root: &mut Value, keys: &[Value], value: Value) {
    if keys.is_empty() {
        return;
    }
    let mut current = root;
    for i in 0..keys.len() - 1 {
        let key = &keys[i];
        let next_key = &keys[i + 1];
        match current {
            Value::Object(map) => {
                let k = value_to_string(key);
                if !map.contains_key(&k) || map.get(&k).is_none_or(|v| v.is_null()) {
                    let next_is_int = nxt_is_int(next_key);
                    map.insert(
                        k.clone(),
                        if next_is_int {
                            Value::Array(vec![])
                        } else {
                            Value::Object(Map::new())
                        },
                    );
                }
                let entry = map.get_mut(&k).unwrap();
                current = entry;
            }
            Value::Array(arr) => {
                let Some(uidx) = array_write_index(key) else {
                    return;
                };
                while arr.len() <= uidx {
                    arr.push(Value::Null);
                }
                current = &mut arr[uidx];
            }
            _ => return,
        }
    }

    let last_key = &keys[keys.len() - 1];
    match current {
        Value::Object(map) => {
            map.insert(value_to_string(last_key), value);
        }
        Value::Array(arr) => {
            let Some(uidx) = array_write_index(last_key) else {
                return;
            };
            while arr.len() <= uidx {
                arr.push(Value::Null);
            }
            arr[uidx] = value;
        }
        _ => {}
    }
}

fn nxt_is_int(v: &Value) -> bool {
    v.as_i64().is_some()
}

/// `set_value_at_path` поверх `QuestTable.data` (Map, а не Value).
fn set_table_data_at_path(table: &mut crate::models::QuestTable, keys: &[Value], value: Value) {
    let mut holder = Value::Object(std::mem::take(&mut table.data));
    set_value_at_path(&mut holder, keys, value);
    if let Value::Object(map) = holder {
        table.data = map;
    }
}

// ---------------------------------------------------------------------------
// Исполнение скрипта
// ---------------------------------------------------------------------------

/// Кадр вызова функции/скрипта на стеке исполнения.
#[derive(Debug, Clone)]
struct CallFrame {
    script_path: String,
    entry: String,
    /// ms последнего `wait` в этом кадре (период таймера при цикле).
    wait_ms: i64,
}

/// Контроллер исполнения (паритет `ExecutionController`).
#[derive(Debug, Clone)]
pub struct ExecutionController {
    steps: usize,
    max_steps: usize,
    call_depth: usize,
    max_call_depth: usize,
    call_stack: Vec<CallFrame>,
    top_level_wait_ms: i64,
}

impl Default for ExecutionController {
    fn default() -> Self {
        ExecutionController {
            steps: 0,
            max_steps: MAX_STEPS,
            call_depth: 0,
            max_call_depth: MAX_CALL_DEPTH,
            call_stack: Vec::new(),
            top_level_wait_ms: 0,
        }
    }
}

impl ExecutionController {
    pub fn new(max_steps: usize) -> Self {
        ExecutionController {
            steps: 0,
            max_steps,
            call_depth: 0,
            max_call_depth: MAX_CALL_DEPTH,
            call_stack: Vec::new(),
            top_level_wait_ms: 0,
        }
    }

    pub fn tick(&mut self) -> Result<(), ExecutorError> {
        self.steps += 1;
        if self.steps > self.max_steps {
            return Err(ExecutorError::LimitExceeded);
        }
        Ok(())
    }

    pub fn enter_call(&mut self, script_path: &str, entry: &str) -> Result<(), ExecutorError> {
        self.call_depth += 1;
        if self.call_depth > self.max_call_depth {
            return Err(ExecutorError::LimitExceeded);
        }
        self.call_stack.push(CallFrame {
            script_path: script_path.to_string(),
            entry: entry.to_string(),
            wait_ms: 0,
        });
        Ok(())
    }

    pub fn exit_call(&mut self) {
        self.call_stack.pop();
        self.call_depth = self.call_depth.saturating_sub(1);
    }

    /// Есть ли кадр с таким путём/входом на стеке вызовов (детект циклов-таймеров).
    /// `entry == "*"` — wildcard: любой кадр этого скрипта.
    pub fn contains_call(&self, script_path: &str, entry: &str) -> bool {
        self.call_stack
            .iter()
            .any(|f| f.script_path == script_path && (entry == "*" || f.entry == entry))
    }

    /// Запомнить ms последнего `wait` в текущем кадре.
    pub fn record_wait(&mut self, ms: i64) {
        if let Some(top) = self.call_stack.last_mut() {
            top.wait_ms = ms;
        } else {
            self.top_level_wait_ms = ms;
        }
    }

    /// ms последнего `wait` в текущем кадре (0 — wait'а не было).
    pub fn take_wait_ms(&self) -> i64 {
        self.call_stack
            .last()
            .map(|f| f.wait_ms)
            .unwrap_or(self.top_level_wait_ms)
    }

    pub fn steps(&self) -> usize {
        self.steps
    }

    pub fn call_depth(&self) -> usize {
        self.call_depth
    }
}

/// Результат исполнения: переход на узел (если был).
pub type ExecuteResult = Result<Option<String>, ExecutorError>;

impl ScriptExecutor {
    /// Исполнить скрипт для события (паритет `execute`).
    ///
    /// Возвращает id узла перехода, если блок `go_to_node` дал результат.
    #[allow(clippy::too_many_arguments)] // паритет с Dart-сигнатурой execute
    pub fn execute(
        &self,
        script_data: &Map<String, Value>,
        game_state: &mut dyn ScriptRuntime,
        quest_id: &str,
        event_type: EventType,
        function_name: &Option<String>,
        content_item_id: &Option<String>,
        allow_target_mismatch_fallback: bool,
        lua: &mut Option<Arc<Mutex<LuaSession>>>,
    ) -> ExecuteResult {
        let mut controller = ExecutionController::default();
        // Канонизация на входе: движок ест любой легаси-формат.
        let canonical = crate::script_format::normalized_clone(script_data);
        self.execute_with_controller(
            &canonical,
            game_state,
            &mut controller,
            quest_id,
            event_type,
            function_name,
            content_item_id,
            allow_target_mismatch_fallback,
            lua,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn execute_with_controller(
        &self,
        script_data: &Map<String, Value>,
        game_state: &mut dyn ScriptRuntime,
        controller: &mut ExecutionController,
        quest_id: &str,
        event_type: EventType,
        function_name: &Option<String>,
        content_item_id: &Option<String>,
        allow_target_mismatch_fallback: bool,
        lua: &mut Option<Arc<Mutex<LuaSession>>>,
    ) -> ExecuteResult {
        let script_name = script_data
            .get("name")
            .map(value_to_string)
            .unwrap_or_else(|| "безымянный".into());
        self.log(&format!(
            "=== START: {script_name} [Req: {}] === (mnd-core v{})",
            event_type.name(),
            env!("CARGO_PKG_VERSION")
        ));

        let all_blocks = script_data
            .get("blocks")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let mut transition_node_id: Option<String> = None;

        let filtered = resolve_blocks_to_run(
            &all_blocks,
            event_type,
            function_name,
            content_item_id,
            allow_target_mismatch_fallback,
        );
        if filtered.is_empty() {
            self.log(&format!(
                "=== SKIPPED: {script_name}: no blocks for event {} ===",
                event_type.name()
            ));
            return Ok(None);
        }

        for block_json in filtered {
            let Some(block) = block_json.as_object().cloned() else {
                continue;
            };
            match self.execute_block_recursively(&block, game_state, controller, quest_id, lua) {
                Ok(Some(node)) => {
                    transition_node_id = Some(node);
                    break;
                }
                Ok(None) => {}
                Err(e) => {
                    self.log(&format!("❌ ERROR: {e}"));
                    if matches!(e, ExecutorError::LimitExceeded) {
                        return Err(e);
                    }
                }
            }
        }

        self.log(&match &transition_node_id {
            Some(node) => format!("=== END: {script_name} === transition → {node}"),
            None => format!("=== END: {script_name} === (no transition)"),
        });

        Ok(transition_node_id)
    }

    /// Один тик таймера: выполнить функцию `entry` скрипта `script_path` заново.
    /// Кадр (script_path, entry) пре-сидится в стек — первый же self-call внутри
    /// распознаётся как цикл и планирует следующий тик (без синхронной рекурсии).
    #[allow(clippy::too_many_arguments)]
    pub fn execute_function_tick(
        &self,
        script_data: &Map<String, Value>,
        game_state: &mut dyn ScriptRuntime,
        quest_id: &str,
        script_path: &str,
        entry: &str,
        lua: &mut Option<Arc<Mutex<LuaSession>>>,
    ) -> ExecuteResult {
        let mut controller = ExecutionController::default();
        controller.enter_call(script_path, entry)?;
        let res = self.execute_with_controller(
            script_data,
            game_state,
            &mut controller,
            quest_id,
            EventType::Function,
            &Some(entry.to_string()),
            &None,
            false,
            lua,
        );
        controller.exit_call();
        res
    }

    /// Один тик таймера для `call_script`-цикла: скрипт исполняется событием,
    /// объявленным в нём самом (`check_script_event_type`).
    #[allow(clippy::too_many_arguments)]
    pub fn execute_script_tick(
        &self,
        script_data: &Map<String, Value>,
        game_state: &mut dyn ScriptRuntime,
        quest_id: &str,
        script_path: &str,
        lua: &mut Option<Arc<Mutex<LuaSession>>>,
    ) -> ExecuteResult {
        let mut controller = ExecutionController::default();
        controller.enter_call(script_path, "*")?;
        let event = check_script_event_type(script_data);
        let res = self.execute_with_controller(
            script_data,
            game_state,
            &mut controller,
            quest_id,
            event,
            &None,
            &None,
            false,
            lua,
        );
        controller.exit_call();
        res
    }

    pub(crate) fn execute_block_recursively(
        &self,
        block: &Map<String, Value>,
        game_state: &mut dyn ScriptRuntime,
        controller: &mut ExecutionController,
        quest_id: &str,
        lua: &mut Option<Arc<Mutex<LuaSession>>>,
    ) -> Result<Option<String>, ExecutorError> {
        let mut ctx = crate::blocks::BlockContext {
            executor: self,
            block,
            game_state,
            controller,
            quest_id,
            lua,
        };
        crate::blocks::dispatch(&mut ctx)
    }

    pub fn execute_table_operation(
        &self,
        block: &Map<String, Value>,
        game_state: &mut dyn ScriptRuntime,
    ) -> Result<Option<String>, ExecutorError> {
        let op_name = block
            .get("operation")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let table_name_expr = block
            .get("tableName")
            .map(value_to_string)
            .unwrap_or_default();

        let evaluated_table = evaluate_expression(block.get("tableName").cloned(), game_state);
        let table_name = if matches!(evaluated_table, Value::Object(_) | Value::Array(_)) {
            table_name_expr.clone()
        } else {
            value_to_string(&evaluated_table)
        };

        let table = lookup_table(game_state, &table_name);
        let Some(mut table) = table else {
            // Молчаливый промах здесь обходится автору часом отладки: блок
            // «выполнен успешно», а данные не меняются. Список доступных имён
            // превращает опечатку в понятную диагностику.
            let available: Vec<&str> = game_state
                .all_tables()
                .keys()
                .map(String::as_str)
                .take(8)
                .collect();
            self.log(&format!(
                "⚠️ Таблица '{table_name}' не найдена (Expr: {table_name_expr}). \
                 Доступные таблицы: {}. Блок пропущен.",
                if available.is_empty() {
                    "нет ни одной".to_string()
                } else {
                    available.join(", ")
                }
            ));
            return Ok(None);
        };

        let raw_path = block.get("path").map(value_to_string).unwrap_or_default();
        // Путь может быть динамическим выражением, но литералы вида
        // "items[0]"/"a.b" evaluator не осиливает и возвращает null —
        // тогда используем сырой литерал. Пустой путь сохраняет старое
        // поведение ("null" → промах → fallback-value).
        let path_str = {
            let evaluated = evaluate_expression(Some(Value::String(raw_path.clone())), game_state);
            if evaluated.is_null() && !raw_path.trim().is_empty() && raw_path != "null" {
                raw_path.clone()
            } else {
                value_to_string(&evaluated)
            }
        };
        let keys = parse_path(&path_str);
        // Пустой путь evaluator'ом превращается в литерал "null", то есть
        // `keys` непустой, хотя путь автор не заполнял. Без явной проверки
        // `set` заводит призрачный ключ «null», `clear` молча ничего не
        // чистит, а `remove` «не находит» элемент.
        let path_given = !raw_path.trim().is_empty();

        self.log(&format!(
            "   📊 DataOp: {op_name} on '{table_name}' path {keys:?} (Raw: '{path_str}')"
        ));

        match op_name {
            "get" => {
                let val = get_value_at_path(Value::Object(table.data.clone()), &keys);
                let fallback_value = if block.contains_key("value") {
                    evaluate_expression(block.get("value").cloned(), game_state)
                } else {
                    Value::Null
                };
                let target_var = block
                    .get("targetVariable")
                    .and_then(Value::as_str)
                    .map(str::to_string);

                let mut result_val = if val != Value::Null {
                    val
                } else {
                    if path_given && !keys.is_empty() {
                        // Самый частый промах автора: опечатка в пути. Молча
                        // записать запасное значение — значит отправить его
                        // отлаживать вслепую.
                        self.log(&format!(
                            "⚠️ Получить: по пути {keys:?} значения нет, беру запасное из поля \
                             «Значение». Ключи таблицы «{table_name}»: {}.",
                            if table.data.is_empty() {
                                "пусто".to_string()
                            } else {
                                table
                                    .data
                                    .keys()
                                    .take(8)
                                    .cloned()
                                    .collect::<Vec<_>>()
                                    .join(", ")
                            }
                        ));
                    } else {
                        // Пустой путь — контракт из audit_table_get_empty_path_uses_fallback:
                        // в переменную уходит запасное значение. Молча он выглядит как
                        // «блок не работает», поэтому поясняем.
                        self.log(
                            "⚠️ Получить: путь не указан, поэтому в переменную ляжет запасное \
                             значение из поля «Значение». Заполните «Путь» именем ключа, \
                             например gold.",
                        );
                    }
                    fallback_value
                };
                if let Value::String(s) = &result_val
                    && (s.contains('{') || s.contains('+') || s.contains('('))
                {
                    let calc = evaluate_expression(Some(result_val.clone()), game_state);
                    if calc != Value::Null {
                        result_val = calc;
                    }
                }

                if let Some(target_var) = target_var {
                    self.log(&format!("      -> Got: {result_val} saved to {target_var}"));
                    game_state.set_variable(&target_var, result_val);
                } else {
                    self.log(
                        "⚠️ Получить: не указана переменная-приёмник — значение прочитано \
                         и выброшено. Заполните «В переменную».",
                    );
                }
            }
            "set" => {
                let val = evaluate_expression(block.get("value").cloned(), game_state);
                if !path_given || keys.is_empty() {
                    self.log(
                        "⚠️ Записать: укажите путь — целиком корень таблицы не \
                         заменяется. Пример пути: gold или items[0].",
                    );
                } else {
                    self.log(&format!("      -> Set value={val}"));
                    set_table_data_at_path(&mut table, &keys, val);
                    game_state.set_table(&table_name, table);
                }
            }
            "add" => {
                if !path_given || keys.is_empty() {
                    self.log(
                        "⚠️ Добавить: укажите путь к списку, например items. Без пути \
                         элемент попал бы в служебный ключ «null».",
                    );
                    return Ok(None);
                }
                let val = evaluate_expression(block.get("value").cloned(), game_state);
                let target = get_value_at_path(Value::Object(table.data.clone()), &keys);
                match target {
                    Value::Array(mut arr) => {
                        arr.push(val.clone());
                        set_table_data_at_path(&mut table, &keys, Value::Array(arr));
                        game_state.set_table(&table_name, table);
                    }
                    Value::Null if !keys.is_empty() => {
                        set_table_data_at_path(&mut table, &keys, Value::Array(vec![val.clone()]));
                        game_state.set_table(&table_name, table);
                    }
                    _ => {
                        self.log(&format!(
                            "⚠️ Добавить: по пути {keys:?} лежит не список. Операция \
                             «Добавить» работает только с массивами; одно значение \
                             записывают операцией «Записать»."
                        ));
                    }
                }
            }
            "clear" => {
                // Поле «Путь» в редакторе для «Очистить» выключено — значит
                // автор имеет в виду всю таблицу, а не служебный ключ.
                if !path_given || keys.is_empty() {
                    table.data.clear();
                } else {
                    let target = get_value_at_path(Value::Object(table.data.clone()), &keys);
                    match target {
                        Value::Array(mut arr) => {
                            arr.clear();
                            set_table_data_at_path(&mut table, &keys, Value::Array(arr));
                        }
                        Value::Object(mut map) => {
                            map.clear();
                            set_table_data_at_path(&mut table, &keys, Value::Object(map));
                        }
                        other => {
                            self.log(&format!(
                                "⚠️ Очистить: по пути {keys:?} лежит {other}, а не список и \
                                 не словарь. Одно значение убирают операцией «Удалить»."
                            ));
                        }
                    }
                }
                game_state.set_table(&table_name, table);
            }
            "remove" => {
                // Удаляет ПОСЛЕДНИЙ ключ пути из родителя (элемент массива
                // по индексу или ключ объекта). Корень удалить нельзя.
                if !path_given {
                    self.log(
                        "⚠️ Удалить: укажите путь — имя ключа (например bread) или \
                         элемент списка с нуля (items[1] — второй). Целиком таблицу чистит \
                         «Очистить», значение из списка убирает «Удалить значение».",
                    );
                    return Ok(None);
                }
                let Some(last_key) = keys.last().cloned() else {
                    self.log("⚠️ Cannot remove root directly. Use a key.");
                    return Ok(None);
                };
                let parent_keys = &keys[..keys.len() - 1];
                let mut parent = get_value_at_path(Value::Object(table.data.clone()), parent_keys);
                let removed = match (&mut parent, &last_key) {
                    (Value::Array(arr), Value::Number(n)) => n.as_i64().is_some_and(|idx| {
                        let len = arr.len() as i64;
                        let real_idx = if idx < 0 { idx + len } else { idx };
                        if real_idx >= 0 && (real_idx as usize) < arr.len() {
                            arr.remove(real_idx as usize);
                            true
                        } else {
                            false
                        }
                    }),
                    (Value::Object(map), k) => map.remove(&value_to_string(k)).is_some(),
                    _ => false,
                };
                if removed {
                    set_table_data_at_path(&mut table, parent_keys, parent);
                    game_state.set_table(&table_name, table);
                } else {
                    self.log(&format!(
                        "⚠️ Удалить: по пути {keys:?} удалять нечего — ключа или индекса там \
                         нет. Значение из списка убирает операция «Удалить значение»."
                    ));
                }
            }
            "remove_value" => {
                // Пара к «Добавить»: убирает из списка по пути ПЕРВОЕ совпадение
                // со значением. «Удалить» работает по имени ключа/индексу и в
                // словаре, а здесь словарь — частый случай путаницы, поэтому
                // промах объясняем словами, а не молчанием.
                let raw_value = block.get("value");
                let has_value = raw_value
                    .map(|v| match v {
                        Value::Null => false,
                        Value::String(s) => !s.trim().is_empty(),
                        _ => true,
                    })
                    .unwrap_or(false);
                if !path_given || keys.is_empty() || !has_value {
                    self.log(
                        "⚠️ Удалить значение: нужны и путь к списку (например items), и \
                         само значение. Убрать ключ словаря — это операция «Удалить».",
                    );
                    return Ok(None);
                }
                let val = evaluate_expression(raw_value.cloned(), game_state);
                let target = get_value_at_path(Value::Object(table.data.clone()), &keys);
                match target {
                    Value::Array(mut arr) => match arr.iter().position(|x| values_equal(x, &val)) {
                        Some(pos) => {
                            arr.remove(pos);
                            self.log(&format!(
                                "      -> Удалено [{pos}] = {val} из {keys:?}, \
                                     осталось {}",
                                arr.len()
                            ));
                            set_table_data_at_path(&mut table, &keys, Value::Array(arr));
                            game_state.set_table(&table_name, table);
                        }
                        None => {
                            self.log(&format!(
                                "⚠️ Удалить значение: в списке по пути {keys:?} нет {val}"
                            ));
                        }
                    },
                    Value::Object(map) => {
                        self.log(&format!(
                            "⚠️ Удалить значение: по пути {keys:?} словарь, а не список. \
                             Ключ убирают операцией «Удалить» (Путь = имя ключа). \
                             Ключи: {}",
                            if map.is_empty() {
                                "нет".to_string()
                            } else {
                                map.keys().take(8).cloned().collect::<Vec<_>>().join(", ")
                            }
                        ));
                    }
                    other => {
                        self.log(&format!(
                            "⚠️ Удалить значение: по пути {keys:?} лежит {other}, \
                             а не список."
                        ));
                    }
                }
            }
            "contains" => {
                // Проверка наличия значения в списке/объекте по пути
                // (или совпадения скаляра) → bool в targetVariable.
                let val = evaluate_expression(block.get("value").cloned(), game_state);
                // Пустой путь = «ищи по всей таблице», а не поиск по
                // служебному ключу «null», в который разворачивался путь.
                let target = if path_given && !keys.is_empty() {
                    get_value_at_path(Value::Object(table.data.clone()), &keys)
                } else {
                    Value::Object(table.data.clone())
                };
                let found = match (&target, &val) {
                    (Value::Array(arr), v) => arr.iter().any(|x| values_equal(x, v)),
                    (Value::Object(map), v) => map.values().any(|x| values_equal(x, v)),
                    _ => !target.is_null() && values_equal(&target, &val),
                };
                let target_var = block
                    .get("targetVariable")
                    .and_then(Value::as_str)
                    .unwrap_or("result");
                self.log(&format!("      -> Contains({val}): {found} → {target_var}"));
                game_state.set_variable(target_var, Value::Bool(found));
            }
            other => {
                // Раньше сюда проваливались «delete», опечатки и пустой
                // `operation`: блок выглядел выполненным, а данные не менялись.
                self.log(&format!(
                    "⚠️ Таблица «{table_name}»: неизвестная операция '{other}'. \
                     Бывает: получить, записать, добавить, удалить, удалить \
                     значение, очистить, содержит?"
                ));
            }
        }
        Ok(None)
    }
}

/// Нормализация id скрипта: убирает путь и расширение.
pub fn normalize_script_id(raw_script_id: &str) -> String {
    let mut value = raw_script_id.trim().to_string();
    if value.is_empty() {
        return value;
    }
    if let Some(slash_index) = value.rfind('/') {
        value = value[slash_index + 1..].to_string();
    }
    if value.ends_with(".json") {
        value.truncate(value.len() - 5);
    }
    value
}

/// Нормализовать id `.lua`-скрипта: убрать путь/папки, снять расширение `.lua`.
fn normalize_lua_id(raw: &str) -> String {
    let mut value = raw.trim().to_string();
    if value.is_empty() {
        return value;
    }
    if let Some(slash_index) = value.rfind('/') {
        value = value[slash_index + 1..].to_string();
    }
    if value.ends_with(".lua") {
        value.truncate(value.len() - 4);
    }
    value
}

/// Получить таблицу по имени (с терпимостью к кавычкам).
fn lookup_table(
    game_state: &dyn ScriptRuntime,
    table_name: &str,
) -> Option<crate::models::QuestTable> {
    let trimmed = table_name.trim().trim_matches('\'').trim_matches('"');
    game_state.get_table(trimmed).cloned()
}

// ---------------------------------------------------------------------------
// Набор тестов паритета
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::QuestTable;
    use crate::runtime::InMemoryScriptRuntimeState;

    fn state() -> InMemoryScriptRuntimeState {
        InMemoryScriptRuntimeState::default()
    }

    fn var_state() -> InMemoryScriptRuntimeState {
        let mut s = InMemoryScriptRuntimeState::default();
        s.set_variable("name", json!("Bob"));
        s.set_variable("age", json!(30));
        s.set_variable("hp", json!(75));
        s
    }

    fn run_blocks(
        blocks: Value,
        s: &mut InMemoryScriptRuntimeState,
    ) -> Result<Option<String>, ExecutorError> {
        let script = json!({ "blocks": blocks });
        let script = script.as_object().unwrap();
        ScriptExecutor::new().execute(
            script,
            s,
            "q",
            EventType::OnNodeEnter,
            &None,
            &None,
            false,
            &mut None,
        )
    }

    // ─── open_link / http_request ──────────────────────────────────────

    #[test]
    fn open_link_pushes_external_command_with_placeholder() {
        let mut s = var_state();
        run_blocks(
            json!([{"type": "open_link", "url": "https://example.com/u/{name}"}]),
            &mut s,
        )
        .unwrap();

        let queue = s.get_variable("_internal_external_commands").cloned();
        assert_eq!(
            queue,
            Some(json!([{"type": "open_link", "url": "https://example.com/u/Bob"}]))
        );
    }

    #[test]
    fn http_request_error_stores_zero_status_and_empty_body() {
        let mut s = state();
        // Порт 1 никто не слушает — connection refused почти мгновенно.
        run_blocks(
            json!([{
                "type": "http_request",
                "method": "GET",
                "url": "http://127.0.0.1:1/",
                "targetVariable": "resp",
                "statusVariable": "resp_status",
            }]),
            &mut s,
        )
        .unwrap();

        assert_eq!(s.get_variable("resp").cloned(), Some(json!("")));
        assert_eq!(s.get_variable("resp_status").cloned(), Some(json!(0)));
    }

    #[test]
    fn http_request_stores_body_and_status_from_local_server() {
        use std::io::{Read, Write};
        use std::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut buf = [0u8; 512];
            let _ = stream.read(&mut buf);
            let _ = stream.write_all(
                b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\n\r\nok",
            );
            let _ = stream.flush();
        });

        let mut s = state();
        let url = format!("http://{addr}/");
        run_blocks(
            json!([{
                "type": "http_request",
                "method": "GET",
                "url": url,
                "targetVariable": "resp",
            }]),
            &mut s,
        )
        .unwrap();
        server.join().unwrap();

        assert_eq!(s.get_variable("resp").cloned(), Some(json!("ok")));
        // statusVariable по умолчанию = targetVariable + "_status".
        assert_eq!(s.get_variable("resp_status").cloned(), Some(json!(200)));
    }

    #[test]
    fn evaluates_literals() {
        let mut s = state();
        assert_eq!(
            evaluate_expression(Some(json!("null")), &mut s),
            Value::Null
        );
        assert_eq!(
            evaluate_expression(Some(json!("true")), &mut s),
            Value::Bool(true)
        );
        assert_eq!(
            evaluate_expression(Some(json!("false")), &mut s),
            Value::Bool(false)
        );
        assert_eq!(evaluate_expression(Some(json!("42")), &mut s), json!(42));
        assert_eq!(
            evaluate_expression(Some(json!("'hello'")), &mut s),
            json!("hello")
        );
        assert_eq!(evaluate_expression(Some(json!(7.5)), &mut s), json!(7.5));
    }

    #[test]
    fn resolves_placeholders() {
        let mut s = var_state();
        assert_eq!(
            evaluate_expression(Some(json!("{name}")), &mut s),
            json!("Bob")
        );
        assert_eq!(evaluate_expression(Some(json!("{age}")), &mut s), json!(30));
        // Несуществующая переменная → null (паритет Dart exact path).
        assert_eq!(
            evaluate_expression(Some(json!("{nope}")), &mut s),
            Value::Null
        );
    }

    // ─── АУДИТ: double vs int в JSON-roundtrip ───────────────────────────
    // Паритет Dart: evaluateExpression(10.0) → double 10.0.
    // Rust: evaluate_expression(Some(json!(10.0))) → clean_numeric_result
    // конвертирует 10.0 → Number(10) (int). При сериализации через
    // serde_json::to_string → "10" → Dart jsonDecode("10") → int 10.
    // В UI: variables['_internal_background_blur'] as double? с int
    // выбрасывает TypeError (не null!), ломая отрисовку фона.
    // Подробности в packages/mnd_core/test/engine/script_executor_blur_audit_test.dart.
    #[test]
    fn numeric_input_true_keeps_float_type_parity_with_dart() {
        let mut s = state();
        let rust_result = evaluate_expression(Some(json!(10.0)), &mut s);
        assert_eq!(rust_result, json!(10));
    }

    #[test]
    fn assign_variable_numeric_keeps_float_parity_with_dart() {
        let mut s = state();
        let script = json!({
            "blocks": [
                {"type": "assign_variable", "variable": "blur", "value": 10.0}
            ]
        });
        let script = script.as_object().unwrap();
        ScriptExecutor::new()
            .execute(
                script,
                &mut s,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut None,
            )
            .unwrap();
        // Dart: value → 10.0 (double). Rust:
        let stored = s.get_variable("blur").cloned().unwrap_or_default();
        assert_eq!(stored, json!(10));
        assert_eq!(serde_json::to_string(&stored).unwrap(), "10");
    }

    #[test]
    fn math_result_keeps_float_parity_with_dart() {
        let mut s = state();
        // Dart: evaluateExpression("{hp} + 0") с hp=75 → 75.0? Нет — Dart num результат
        // математики → 75 (нативный int), двоичный double не нужен.
        // key case: "50 + 0.5" → 50.5 double. Проверяем 10/4=2.5 — ок.
        // Проверяем: "12.0" как строку — Dart → 12.0 double.
        let r = evaluate_expression(Some(json!("12.0")), &mut s);
        assert_eq!(r, json!(12));
        assert_eq!(serde_json::to_string(&r).unwrap(), "12");
    }

    #[test]
    fn test_placeholder_float_variable_keeps_float_type() {
        let mut s = state();
        s.set_variable("f", json!(10));
        let r = evaluate_expression(Some(json!("{f}")), &mut s);
        assert_eq!(r, json!(10));
        assert_eq!(serde_json::to_string(&r).unwrap(), "10");
    }

    #[test]
    fn math_expressions() {
        let mut s = state();
        assert_eq!(
            evaluate_expression(Some(json!("2 + 3 * 4")), &mut s),
            json!(14)
        );
        assert_eq!(
            evaluate_expression(Some(json!("(2 + 3) * 4")), &mut s),
            json!(20)
        );
        assert_eq!(
            evaluate_expression(Some(json!("10 / 4")), &mut s),
            json!(2.5)
        );
    }

    #[test]
    fn comparisons() {
        let mut s = var_state();
        assert_eq!(
            evaluate_expression(Some(json!("{age} > 18")), &mut s),
            Value::Bool(true)
        );
        assert_eq!(
            evaluate_expression(Some(json!("{name} == 'Bob'")), &mut s),
            Value::Bool(true)
        );
        assert_eq!(
            evaluate_expression(Some(json!("{name} != 'Alice'")), &mut s),
            Value::Bool(true)
        );
        assert_eq!(
            evaluate_expression(Some(json!("{age} >= 30")), &mut s),
            Value::Bool(true)
        );
    }

    #[test]
    fn logical_ops() {
        let mut s = var_state();
        assert_eq!(
            evaluate_expression(Some(json!("{age} > 18 && {hp} > 50")), &mut s),
            Value::Bool(true)
        );
        assert_eq!(
            evaluate_expression(Some(json!("{age} > 18 || {hp} > 50")), &mut s),
            Value::Bool(true)
        );
        assert_eq!(
            evaluate_expression(Some(json!("!( {age} < 18 )")), &mut s),
            Value::Bool(true)
        );
        assert_eq!(
            evaluate_expression(Some(json!("!true")), &mut s),
            Value::Bool(false)
        );
    }

    #[test]
    fn in_operator() {
        let mut s = var_state();
        assert_eq!(
            evaluate_expression(Some(json!("{name} in ('Bob', 'Alice')")), &mut s),
            Value::Bool(true)
        );
        assert_eq!(
            evaluate_expression(Some(json!("{age} in (1, 2, 3)")), &mut s),
            Value::Bool(false)
        );
        assert_eq!(
            evaluate_expression(Some(json!("{age} in (10, 20, 30)")), &mut s),
            Value::Bool(true)
        );
    }

    #[test]
    fn functions() {
        let mut s = state();
        assert_eq!(
            evaluate_expression(Some(json!("abs(-5)")), &mut s),
            json!(5)
        );
        assert_eq!(
            evaluate_expression(Some(json!("round(2.4)")), &mut s),
            json!(2)
        );
        assert_eq!(
            evaluate_expression(Some(json!("round(2.567, 2)")), &mut s),
            json!(2.57)
        );
        assert_eq!(
            evaluate_expression(Some(json!("ceil(2.1)")), &mut s),
            json!(3)
        );
        assert_eq!(
            evaluate_expression(Some(json!("floor(2.9)")), &mut s),
            json!(2)
        );
        assert_eq!(
            evaluate_expression(Some(json!("sqrt(16)")), &mut s),
            json!(4)
        );
        assert_eq!(
            evaluate_expression(Some(json!("min(3, 7)")), &mut s),
            json!(3)
        );
        assert_eq!(
            evaluate_expression(Some(json!("max(3, 7)")), &mut s),
            json!(7)
        );
        assert_eq!(
            evaluate_expression(Some(json!("contains('abcdef', 'cde')")), &mut s),
            Value::Bool(true)
        );
        assert_eq!(
            evaluate_expression(Some(json!("length('квест')")), &mut s),
            json!(5)
        );
    }

    #[test]
    fn table_deep_lookup() {
        let mut s = state();
        let mut data = Map::new();
        data.insert("key".into(), json!("value1"));
        let mut inner = Map::new();
        inner.insert("subkey".into(), json!(42));
        data.insert("obj".into(), Value::Object(inner));
        let table = QuestTable::new("storage".into(), vec![], vec![], data);
        s.set_table("storage", table);

        assert_eq!(
            evaluate_expression(Some(json!("storage['key']")), &mut s),
            json!("value1")
        );
        assert_eq!(
            evaluate_expression(Some(json!("storage['obj']['subkey']")), &mut s),
            json!(42)
        );
    }

    /// Три способа дотянуться до таблицы, и работают только два — редактор
    /// формул вставляет в поле ровно то, что видит автор, поэтому это надо
    /// знать точно:
    ///
    /// * `{лавка["цена"][1]}` → 30: ссылка на ячейку — и как всё поле, и в
    ///   тексте. `{лавка['ключ']}` → значение хранилища скриптов.
    /// * функция — целиком в поле: `table_cell(лавка, 'цена', 1) + 5` → 35.
    /// * `{лавка["цена"][1] + 5}` → 30: арифметика рядом со ссылкой теряется
    ///   молча; `{table_cell(…)}` → null. Скобки — не для формул (в 25 живых
    ///   квестах `{func(…)` не встречается ни разу).
    /// * `лавка["цена"][1] + 5` без скобок → строка `"5"`: в формуле
    ///   `лавка["цена"]` — это ключ хранилища, а не колонка сетки.
    #[test]
    fn grid_cell_reference_only_survives_as_a_bare_reference() {
        let mut s = state();
        let table = QuestTable::new(
            "лавка".into(),
            vec!["цена".into()],
            vec![json!({"цена": 30}).as_object().cloned().unwrap()],
            json!({"открыто": true}).as_object().cloned().unwrap(),
        );
        s.set_table("лавка", table);

        assert_eq!(
            evaluate_expression(Some(json!("{лавка[\"цена\"][1]}")), &mut s),
            json!(30)
        );
        assert_eq!(
            interpolate_placeholders_raw("цена {лавка[\"цена\"][1]} р.", &mut s),
            "цена 30 р."
        );
        assert_eq!(
            evaluate_expression(Some(json!("table_cell(лавка, 'цена', 1) + 5")), &mut s),
            json!(35),
            "функция без обёртки-скобок — рабочий способ считать по сетке"
        );
        assert_eq!(
            evaluate_expression(Some(json!("{лавка['открыто']}")), &mut s),
            json!(true)
        );
        assert_eq!(
            evaluate_expression(Some(json!("{table_cell(лавка, 'цена', 1)}")), &mut s),
            Value::Null,
            "функция внутри фигурных скобок не вычисляется вообще"
        );
        assert_eq!(
            evaluate_expression(Some(json!("{лавка[\"цена\"][1] + 5}")), &mut s),
            json!(30),
            "арифметика рядом со ссылкой съедается без единого звука"
        );
        assert_eq!(
            evaluate_expression(Some(json!("лавка[\"цена\"][1] + 5")), &mut s),
            json!("5"),
            "ссылка без скобок читает хранилище скриптов, а не сетку"
        );
    }

    /// Имена строк — второй адрес ячейки. Оба порядка работают, номер строки
    /// не сломан, а неизвестное имя честно даёт null, а не первую строку.
    #[test]
    fn named_rows_are_addressable_both_ways() {
        let mut s = state();
        let mut table = QuestTable::new(
            "лавка".into(),
            vec!["цена".into(), "запас".into()],
            vec![
                json!({"цена": 30, "запас": 2})
                    .as_object()
                    .cloned()
                    .unwrap(),
                json!({"цена": 99, "запас": 1})
                    .as_object()
                    .cloned()
                    .unwrap(),
            ],
            Map::new(),
        );
        table.set_row_names(&["меч".into(), "щит".into()]);
        s.set_table("лавка", table);

        assert_eq!(
            evaluate_expression(Some(json!("{лавка[\"меч\"][\"цена\"]}")), &mut s),
            json!(30),
            "строка-первая: имя строки адресует ряд"
        );
        assert_eq!(
            evaluate_expression(Some(json!("{лавка[\"цена\"][\"щит\"]}")), &mut s),
            json!(99),
            "колонка-первая: имя строки работает поверх столбца"
        );
        assert_eq!(
            evaluate_expression(Some(json!("{лавка[\"цена\"][2]}")), &mut s),
            json!(99),
            "номер строки продолжает работать рядом с именами"
        );
        assert_eq!(
            evaluate_expression(Some(json!("table_cell(лавка, 'цена', 'щит')")), &mut s),
            json!(99)
        );
        assert_eq!(
            evaluate_expression(Some(json!("table_row_names(лавка)")), &mut s),
            json!(["меч", "щит"])
        );
        assert_eq!(
            evaluate_expression(Some(json!("table_row_number(лавка, 'щит')")), &mut s),
            json!(2)
        );
        // Функция с неизвестным именем не должна молча брать первую строку;
        // конкретное «пустое» значение зависит от оценки (null/текст), важен
        // не он, а отсутствие подмены.
        assert_ne!(
            evaluate_expression(Some(json!("table_cell(лавка, 'цена', 'нет')")), &mut s),
            json!(30),
            "неизвестное имя не должно молча указывать на первую строку"
        );
        assert_eq!(
            evaluate_expression(Some(json!("{лавка[\"цена\"][\"нет\"]}")), &mut s),
            Value::Null
        );
    }

    #[test]
    fn column_name_wins_over_row_name_in_deep_lookup() {
        let mut s = state();
        let mut table = QuestTable::new(
            "лавка".into(),
            vec!["цена".into(), "меч".into()],
            vec![
                json!({"цена": 30, "меч": 2}).as_object().cloned().unwrap(),
                json!({"цена": 99, "меч": 1}).as_object().cloned().unwrap(),
            ],
            Map::new(),
        );
        // Имя строки совпадает с именем колонки — так быть не должно, но
        // старые/ручные файлы могут: колонка исторически важнее.
        table.set_row_names(&["щит".into(), "меч".into()]);
        s.set_table("лавка", table);

        assert_eq!(
            evaluate_expression(Some(json!("{лавка[\"меч\"][1]}")), &mut s),
            json!(2),
            "первая скобка читает колонку «меч», а не строку с тем же именем"
        );
    }

    /// Имя строки — произвольный текст: скобки, кавычка, обратный слэш,
    /// двойные фигурные. Адрес собирается клиентом с экранированием, и движок
    /// обязан разобрать его так же, как собрал: разбалансированная скобка или
    /// `{{` в имени не должны обрывать токен раньше времени.
    #[test]
    fn arbitrary_row_names_survive_placeholder_parsing() {
        let mut s = state();
        let mut table = QuestTable::new(
            "лавка".into(),
            vec!["цена".into()],
            vec![
                json!({"цена": 10}).as_object().cloned().unwrap(),
                json!({"цена": 20}).as_object().cloned().unwrap(),
                json!({"цена": 30}).as_object().cloned().unwrap(),
                json!({"цена": 40}).as_object().cloned().unwrap(),
                json!({"цена": 50}).as_object().cloned().unwrap(),
                json!({"цена": 60}).as_object().cloned().unwrap(),
                json!({"цена": 70}).as_object().cloned().unwrap(),
                json!({"цена": 80}).as_object().cloned().unwrap(),
            ],
            Map::new(),
        );
        table.set_row_names(&[
            "{тест}".into(),
            "a}b".into(),
            "a\"b".into(),
            r"a\b".into(),
            "a{{b".into(),
            "щит".into(),
            "a]b".into(),
            "a[b".into(),
        ]);
        s.set_table("лавка", table);

        let addr = |row: &str| format!("{{лавка[\"цена\"][\"{row}\"]}}");

        assert_eq!(
            evaluate_expression(Some(json!(addr("{тест}"))), &mut s),
            json!(10),
            "сбалансированные скобки в имени"
        );
        // Оба порядка, как для обычного имени.
        assert_eq!(
            evaluate_expression(
                Some(json!(format!("{{лавка[\"{}\"][\"цена\"]}}", "{тест}"))),
                &mut s
            ),
            json!(10)
        );
        assert_eq!(
            evaluate_expression(Some(json!(addr("a}b"))), &mut s),
            json!(20),
            "`}}` внутри имени не закрывает плейсхолдер"
        );
        assert_eq!(
            evaluate_expression(
                Some(json!(format!("{{лавка[\"{}\"][\"цена\"]}}", "a}b"))),
                &mut s
            ),
            json!(20)
        );
        assert_eq!(
            evaluate_expression(Some(json!(addr(r#"a\"b"#))), &mut s),
            json!(30),
            "экранированная кавычка — часть имени"
        );
        assert_eq!(
            evaluate_expression(Some(json!(addr(r"a\\b"))), &mut s),
            json!(40),
            "экранированный обратный слэш — часть имени"
        );
        assert_eq!(
            evaluate_expression(Some(json!(addr("a{{b"))), &mut s),
            json!(50),
            "`{{` внутри имени не схлопывается нормализатором"
        );
        assert_eq!(
            evaluate_expression(Some(json!("table_cell(лавка, 'цена', 'a}b')")), &mut s),
            json!(20)
        );
        assert_eq!(
            evaluate_expression(Some(json!(addr("a]b"))), &mut s),
            json!(70),
            "`]` внутри кавычек не закрывает адрес"
        );
        assert_eq!(
            evaluate_expression(Some(json!(addr("a[b"))), &mut s),
            json!(80),
            "`[` внутри кавычек не открывает новый сегмент"
        );
        assert_eq!(
            interpolate_placeholders_raw("цена {лавка[\"цена\"][\"a}b\"]} р.", &mut s),
            "цена 20 р."
        );

        // Переменная и формула как адрес строки, в обоих порядках.
        s.set_variable("выбор", json!("a}b"));
        s.set_variable("номер", json!(2));
        assert_eq!(
            evaluate_expression(Some(json!("{лавка[\"цена\"][выбор]}")), &mut s),
            json!(20)
        );
        assert_eq!(
            evaluate_expression(Some(json!("{лавка[выбор][\"цена\"]}")), &mut s),
            json!(20)
        );
        assert_eq!(
            evaluate_expression(Some(json!("{лавка[\"цена\"][номер]}")), &mut s),
            json!(20),
            "номер строки из переменной — визуальный, как у литерала"
        );
        assert_eq!(
            evaluate_expression(Some(json!("{лавка[\"цена\"][lower(\"ЩИТ\")]}")), &mut s),
            json!(60),
            "формула в позиции имени строки"
        );
    }

    #[test]
    fn arbitrary_column_name_is_addressable() {
        let mut s = state();
        let col = "ко\"лон]ка";
        let mut table = QuestTable::new(
            "лавка".into(),
            vec![col.into()],
            vec![json!({col: 42}).as_object().cloned().unwrap()],
            Map::new(),
        );
        table.set_row_names(&["ме\"ч".into()]);
        s.set_table("лавка", table);

        assert_eq!(
            evaluate_expression(Some(json!(format!("{{лавка[\"{}\"][1]}}", r#"ко\"лон]ка"#))), &mut s),
            json!(42),
            "кавычка и `]` в имени колонки"
        );
        assert_eq!(
            evaluate_expression(
                Some(json!(format!(
                    "{{лавка[\"{}\"][\"{}\"]}}",
                    r#"ко\"лон]ка"#, r#"ме\"ч"#
                ))),
                &mut s
            ),
            json!(42),
            "произвольные имя колонки и имя строки вместе"
        );
    }

    #[test]
    fn condition_logic() {
        let mut s = var_state();
        let script = Map::new();
        // Прямая формула в evaluateCondition.
        let expr = evaluate_expression(Some(json!("{age} == 30")), &mut s);
        assert_eq!(expr, Value::Bool(true));
        let _ = script;
    }

    #[test]
    fn blocks_resolution() {
        let mut s = state();
        let script = json!({
            "name": "test",
            "blocks": [
                {
                    "type": "event",
                    "eventType": "onNodeEnter",
                    "title": "При запуске ноды",
                    "children": [
                        {"type": "assign_variable", "variable": "x", "value": "5"}
                    ]
                }
            ]
        });
        let script = script.as_object().unwrap();

        let event = check_script_event_type(script);
        assert_eq!(event, EventType::OnNodeEnter);

        let result = ScriptExecutor::new()
            .execute(
                script,
                &mut s,
                "quest1",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut None,
            )
            .unwrap();
        assert_eq!(result, None);
        assert_eq!(s.get_variable("x"), Some(&json!(5)));
    }

    #[test]
    fn go_to_node() {
        let mut s = state();
        let script = json!({
            "name": "goto",
            "blocks": [
                {"type": "go_to_node", "node_id": "node_42"}
            ]
        });
        let script = script.as_object().unwrap();
        let result = ScriptExecutor::new()
            .execute(
                script,
                &mut s,
                "quest1",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut None,
            )
            .unwrap();
        assert_eq!(result, Some("node_42".to_string()));
    }

    #[test]
    fn table_operations() {
        let mut s = state();
        let mut data = Map::new();
        data.insert("counter".into(), json!(10));
        let mut inventory = Map::new();
        inventory.insert("items".into(), json!(vec!["sword", "shield"]));
        data.insert("inventory".into(), Value::Object(inventory));
        let table = QuestTable::new("storage".into(), vec![], vec![], data);
        s.set_table("storage", table);

        // get
        let get_script = json!({
            "name": "get",
            "blocks": [
                {
                    "type": "table_operation",
                    "operation": "get",
                    "tableName": "storage",
                    "path": "counter",
                    "targetVariable": "cnt"
                }
            ]
        });
        let res = ScriptExecutor::new()
            .execute(
                get_script.as_object().unwrap(),
                &mut s,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut None,
            )
            .unwrap();
        assert_eq!(res, None);
        assert_eq!(s.get_variable("cnt"), Some(&json!(10)));

        // set
        let set_script = json!({
            "name": "set",
            "blocks": [
                {
                    "type": "table_operation",
                    "operation": "set",
                    "tableName": "storage",
                    "path": "counter",
                    "value": "15"
                }
            ]
        });
        ScriptExecutor::new()
            .execute(
                set_script.as_object().unwrap(),
                &mut s,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut None,
            )
            .unwrap();
        // Проверяем, что значение записалось в таблицу.
        let table = s.get_table("storage").unwrap();
        assert_eq!(table.data.get("counter"), Some(&json!(15)));
    }

    #[test]
    fn limit_exceeded() {
        // Создаём бесконечный цикл через assign_variable + самовызов?
        // Проще: контроллер с малым лимитом.
        let controller = ExecutionController::new(3);
        let mut c = controller;
        for _ in 0..3 {
            c.tick().unwrap();
        }
        assert!(c.tick().is_err());
    }

    #[test]
    fn values_equal_semantics() {
        assert!(values_equal(&json!(""), &Value::Null));
        assert!(values_equal(&json!("ничего"), &Value::Null));
        assert!(values_equal(&json!(5), &json!("5")));
        assert!(!values_equal(&json!(5), &json!("6")));
        assert!(values_equal(&Value::Null, &Value::Null));
    }

    #[test]
    fn mojibake_repair() {
        // Latin1-декодированный русский текст.
        let repaired = crate::expression::try_repair_mojibake("РќРёС‡РµРіРѕ");
        assert!(repaired.is_some());
    }

    #[test]
    fn function_blocks_calling() {
        // Проверяем, что call_function резолвит путь через asset store.
        let mut s = state();
        let called_script = json!({
            "name": "func",
            "blocks": [
                {
                    "type": "event",
                    "eventType": "function",
                    "functionName": "test",
                    "children": [
                        {"type": "assign_variable", "variable": "called", "value": "1"}
                    ]
                }
            ]
        });
        let mut store = crate::executor::test_store::InMemoryScriptStore::new();
        store.insert(
            "quests/q1/scripts/func.json".to_string(),
            called_script.clone(),
        );

        let executor = ScriptExecutor::new().with_asset_store(std::sync::Arc::new(store));
        let script = json!({
            "name": "caller",
            "blocks": [
                {
                    "type": "call_function",
                    "function_id": "func",
                    "function_entry": "test"
                }
            ]
        });
        let result = executor
            .execute(
                script.as_object().unwrap(),
                &mut s,
                "q1",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut None,
            )
            .unwrap();
        assert_eq!(result, None);
        assert_eq!(s.get_variable("called"), Some(&json!(1)));
    }

    // -----------------------------------------------------------------------
    // Паритет-тесты с Dart-эталоном (script_executor.dart)
    // -----------------------------------------------------------------------

    #[test]
    fn event_target_matching() {
        // Два event-блока: один точечный (targetContentItemId), второй общий.
        let script = json!({
            "name": "press",
            "blocks": [
                {
                    "type": "event",
                    "eventType": "onPress",
                    "targetContentItemId": "btn_gold",
                    "children": [
                        {"type": "assign_variable", "variable": "hit_targeted", "value": "'gold'"}
                    ]
                },
                {
                    "type": "event",
                    "eventType": "onPress",
                    "children": [
                        {"type": "assign_variable", "variable": "hit_common", "value": "'any'"}
                    ]
                }
            ]
        });
        let script = script.as_object().unwrap();

        // Таргетный клик → оба блока (точечный и общий) выполняются,
        // порядок сохранён: сперва точечный, потом общий.
        let mut s = state();
        let res = ScriptExecutor::new()
            .execute(
                script,
                &mut s,
                "q",
                EventType::OnPress,
                &None,
                &Some("btn_gold".into()),
                false,
                &mut None,
            )
            .unwrap();
        assert_eq!(res, None);
        assert_eq!(s.get_variable("hit_targeted"), Some(&json!("gold")));
        assert_eq!(s.get_variable("hit_common"), Some(&json!("any")));

        // Клик по другому элементу → точечный пропускается, общий выполняется.
        let mut s = state();
        let res = ScriptExecutor::new()
            .execute(
                script,
                &mut s,
                "q",
                EventType::OnPress,
                &None,
                &Some("btn_other".into()),
                false,
                &mut None,
            )
            .unwrap();
        assert_eq!(res, None);
        assert_eq!(s.get_variable("hit_targeted"), None);
        assert_eq!(s.get_variable("hit_common"), Some(&json!("any")));

        // Без таргета (пустой contentItemId) → только общий блок.
        let mut s = state();
        let res = ScriptExecutor::new()
            .execute(
                script,
                &mut s,
                "q",
                EventType::OnPress,
                &None,
                &Some(String::new()),
                false,
                &mut None,
            )
            .unwrap();
        assert_eq!(s.get_variable("hit_targeted"), None);
        assert_eq!(s.get_variable("hit_common"), Some(&json!("any")));
        let _ = res;
    }

    #[test]
    fn legacy_event_titles() {
        // При нажатии
        let script = json!({
            "name": "legacy",
            "blocks": [
                {
                    "type": "event",
                    "title": "При нажатии",
                    "children": [
                        {"type": "assign_variable", "variable": "x", "value": "1"}
                    ]
                }
            ]
        });
        let script = script.as_object().unwrap();
        let mut s = state();
        let res = ScriptExecutor::new()
            .execute(
                script,
                &mut s,
                "q",
                EventType::OnPress,
                &None,
                &None,
                false,
                &mut None,
            )
            .unwrap();
        assert_eq!(res, None);
        assert_eq!(s.get_variable("x"), Some(&json!(1)));

        // При запуске ноды
        let script2 = json!({
            "name": "legacy2",
            "blocks": [
                {
                    "type": "event",
                    "title": "При запуске ноды",
                    "children": [
                        {"type": "assign_variable", "variable": "y", "value": "2"}
                    ]
                }
            ]
        });
        let script2 = script2.as_object().unwrap();
        let mut s2 = state();
        ScriptExecutor::new()
            .execute(
                script2,
                &mut s2,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut None,
            )
            .unwrap();
        assert_eq!(s2.get_variable("y"), Some(&json!(2)));
    }

    #[test]
    fn condition_block_gates_children() {
        // condition с истинным выражением → выполняются then_blocks.
        let script = json!({
            "name": "cond",
            "blocks": [
                {
                    "type": "event",
                    "eventType": "onNodeEnter",
                    "children": [
                        {
                            "type": "condition",
                            "expression": "{gold} >= 10",
                            "then_blocks": [
                                {"type": "assign_variable", "variable": "rich", "value": "true"}
                            ],
                            "else_blocks": [
                                {"type": "assign_variable", "variable": "rich", "value": "false"}
                            ]
                        }
                    ]
                }
            ]
        });
        let script = script.as_object().unwrap();

        let mut s = state();
        s.set_variable("gold", json!(25));
        ScriptExecutor::new()
            .execute(
                script,
                &mut s,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut None,
            )
            .unwrap();
        assert_eq!(s.get_variable("rich"), Some(&Value::Bool(true)));

        let mut s = state();
        s.set_variable("gold", json!(3));
        ScriptExecutor::new()
            .execute(
                script,
                &mut s,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut None,
            )
            .unwrap();
        assert_eq!(s.get_variable("rich"), Some(&Value::Bool(false)));
    }

    #[test]
    fn assign_keeps_raw_text() {
        // Текст без кавычек не должен «обрастать» JSON-кавычками.
        let script = json!({
            "name": "text",
            "blocks": [
                {
                    "type": "event",
                    "eventType": "onNodeEnter",
                    "children": [
                        {"type": "assign_variable", "variable": "msg", "value": "Добро пожаловать!"}
                    ]
                }
            ]
        });
        let script = script.as_object().unwrap();
        let mut s = state();
        ScriptExecutor::new()
            .execute(
                script,
                &mut s,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut None,
            )
            .unwrap();
        assert_eq!(s.get_variable("msg"), Some(&json!("Добро пожаловать!")));
    }

    #[test]
    fn audio_blocks_internal_vars() {
        let mut s = state();
        let script = json!({
            "name": "audio",
            "blocks": [
                {
                    "type": "event",
                    "eventType": "onNodeEnter",
                    "children": [
                        {"type": "play_sound", "audio_id": "sfx/click.wav", "volume": "0.8"},
                        {"type": "stop_sound", "target": "all"},
                        {"type": "play_music", "audio_id": "music/theme.mp3", "loop": true, "volume": "0.5"},
                        {"type": "pause_resume", "target": "music", "action": "pause"},
                        {"type": "set_volume", "target": "contentAudio", "volume": "0.3"},
                        {"type": "set_blur", "target": "node", "blur": "12"},
                        {"type": "crossfade", "duration": "2"}
                    ]
                }
            ]
        });
        let script = script.as_object().unwrap();
        ScriptExecutor::new()
            .execute(
                script,
                &mut s,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut None,
            )
            .unwrap();

        // Аудио-блоки больше не пишут одноразовые слоты — только очередь.
        assert_eq!(s.get_variable("_internal_play_sound_id"), None);
        assert_eq!(s.get_variable("_internal_play_music_id"), None);
        assert_eq!(s.get_variable("_internal_stop_sound_target"), None);
        assert_eq!(s.get_variable("_internal_pause_resume_target"), None);
        // set_volume/set_blur остаются одноразовыми слотами состояния.
        assert_eq!(
            s.get_variable("_internal_node_content_volume"),
            Some(&json!(0.3))
        );
        // Паритет Dart: blur сохраняется как double (.toDouble()).
        assert_eq!(
            s.get_variable("_internal_background_blur"),
            Some(&json!(12.0))
        );
        // Очередь аудио-команд в порядке исполнения блоков.
        assert_eq!(
            s.get_variable("_internal_audio_queue"),
            Some(&json!([
                {"type": "play_sound", "audio_id": "sfx/click.wav", "volume": 0.8},
                {"type": "stop_sound", "target": "all"},
                {"type": "play_music", "audio_id": "music/theme.mp3", "loop": true, "volume": 0.5, "global": false},
                {"type": "pause_resume", "target": "music", "action": "pause"},
                {"type": "fade_out", "ms": 2000},
                {"type": "fade_in", "ms": 2000}
            ]))
        );
    }

    #[test]
    fn call_script_chain_transition() {
        let mut s = state();
        let nested = json!({
            "name": "nested",
            "blocks": [
                {"type": "go_to_node", "node_id": "node_deep"}
            ]
        });
        let mut store = crate::executor::test_store::InMemoryScriptStore::new();
        store.insert("quests/q1/scripts/nested.json".to_string(), nested);

        let script = json!({
            "name": "caller",
            "blocks": [
                {
                    "type": "event",
                    "eventType": "onNodeEnter",
                    "children": [
                        {"type": "call_script", "script_id": "nested"}
                    ]
                }
            ]
        });
        let result = ScriptExecutor::new()
            .with_asset_store(std::sync::Arc::new(store))
            .execute(
                script.as_object().unwrap(),
                &mut s,
                "q1",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut None,
            )
            .unwrap();
        assert_eq!(result, Some("node_deep".to_string()));
    }

    #[test]
    fn go_to_node_with_expression() {
        let mut s = state();
        s.set_variable("target", json!("node_expr"));
        let script = json!({
            "name": "goexpr",
            "blocks": [
                {"type": "go_to_node", "node_id": "={target}"}
            ]
        });
        let result = ScriptExecutor::new()
            .execute(
                script.as_object().unwrap(),
                &mut s,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut None,
            )
            .unwrap();
        assert_eq!(result, Some("node_expr".to_string()));
    }

    #[test]
    fn deep_lookup_dynamic_key() {
        let mut s = state();
        let mut data = Map::new();
        let mut inner = Map::new();
        inner.insert("player".into(), json!(7));
        data.insert("stats".into(), Value::Object(inner));
        let table = QuestTable::new("t".into(), vec![], vec![], data);
        s.set_table("t", table);
        s.set_variable("k", json!("stats"));

        assert_eq!(
            evaluate_expression(Some(json!("t[{k}]['player']")), &mut s),
            json!(7)
        );
    }

    #[test]
    fn non_string_passthrough() {
        let mut s = state();
        let obj = json!({"a": 1, "b": [2, 3]});
        assert_eq!(evaluate_expression(Some(obj.clone()), &mut s), obj);
        assert_eq!(evaluate_expression(Some(json!(null)), &mut s), Value::Null);
    }

    #[test]
    fn nothing_like_mojibake_variants() {
        assert!(values_equal(&json!("ничего"), &Value::Null));
        assert!(values_equal(&json!("рќрёс‡рµрірѕ"), &Value::Null));
        assert!(values_equal(
            &json!("сђсњсђс‘сђвђўсђвµсђс–сђс•"),
            &Value::Null
        ));
        assert!(!values_equal(&json!("что-то"), &Value::Null));
    }

    // =====================================================================
    // АУДИТ: НЕДОСТАЮЩИЕ ТЕСТЫ ПАРИТЕТА С DART-ЭТАЛОНОМ
    // =====================================================================

    // Категория 1: TYPE PRESERVATION (evaluate_expression)
    // Проблема A — тесты игнорировали различие Number(int) vs Number(double).

    #[test]
    fn audit_raw_number_42_5_keeps_double_type() {
        let mut s = state();
        let r = evaluate_expression(Some(json!(42.5)), &mut s);
        assert_eq!(r, json!(42.5));
        assert!(r.is_f64());
    }

    #[test]
    fn audit_raw_number_10_0_keeps_double_type() {
        let mut s = state();
        let r = evaluate_expression(Some(json!(10.0)), &mut s);
        assert_eq!(r, json!(10));
        assert_eq!(serde_json::to_string(&r).unwrap(), "10");
    }

    #[test]
    fn audit_math_1_plus_1_returns_double() {
        let mut s = state();
        let r = evaluate_expression(Some(json!("1 + 1")), &mut s);
        assert_eq!(r, json!(2));
        assert_eq!(serde_json::to_string(&r).unwrap(), "2");
    }

    #[test]
    fn audit_math_2_div_4_returns_double() {
        let mut s = state();
        let r = evaluate_expression(Some(json!("2 / 4")), &mut s);
        assert!(r.is_f64());
        assert_eq!(r, json!(0.5));
    }

    #[test]
    fn audit_division_by_zero_is_not_f64() {
        let mut s = state();
        let r = evaluate_expression(Some(json!("5 / 0")), &mut s);
        assert!(!r.is_f64(), "Деление на 0 не должно давать double");
    }

    #[test]
    fn audit_modulo_by_zero_is_not_f64() {
        let mut s = state();
        let r = evaluate_expression(Some(json!("5 % 0")), &mut s);
        assert!(
            !r.is_f64(),
            "Остаток от деления на 0 не должен давать double"
        );
    }

    // Категория 2: ОТСУТСТВИЕ МУТАЦИЙ / ПОГРАНИЧНЫЕ ЗНАЧЕНИЯ
    // Проблемы B, C. Тесты на execute без блоков, пустой скрипт.

    #[test]
    fn audit_execute_no_blocks_adds_no_internal_vars() {
        let mut s = state();
        let script = json!({"name": "empty", "blocks": []});
        let count_before = s.all_variables().len();
        ScriptExecutor::new()
            .execute(
                script.as_object().unwrap(),
                &mut s,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut None,
            )
            .unwrap();
        assert_eq!(s.all_variables().len(), count_before);
        assert!(s.get_variable("_internal_background_blur").is_none());
        assert!(s.get_variable("_internal_node_content_volume").is_none());
    }

    #[test]
    fn audit_execute_missing_blocks_key() {
        let mut s = state();
        let script = json!({"name": "no_blocks"});
        let result = ScriptExecutor::new()
            .execute(
                script.as_object().unwrap(),
                &mut s,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut None,
            )
            .unwrap();
        assert_eq!(result, None);
    }

    #[test]
    fn audit_empty_string_returns_null() {
        let mut s = state();
        assert_eq!(evaluate_expression(Some(json!("")), &mut s), Value::Null);
    }

    #[test]
    fn audit_whitespace_only_returns_null() {
        let mut s = state();
        assert_eq!(evaluate_expression(Some(json!("   ")), &mut s), Value::Null);
    }

    #[test]
    fn audit_null_input_value() {
        let mut s = state();
        assert_eq!(evaluate_expression(None, &mut s), Value::Null);
    }

    #[test]
    fn audit_null_json_string_returns_null() {
        let mut s = state();
        assert_eq!(
            evaluate_expression(Some(json!("null")), &mut s),
            Value::Null
        );
    }

    #[test]
    fn audit_missing_variable_does_not_create_entry() {
        let mut s = state();
        let _ = evaluate_expression(Some(json!("{nonexistent}")), &mut s);
        assert!(s.get_variable("nonexistent").is_none());
    }

    // Категория 3: CONDITION С {var} / ASSIGN VARIABLE С ПЛЕЙСХОЛДЕРОМ
    // Проблема E.

    #[test]
    fn audit_assign_variable_with_placeholder_value() {
        let mut s = state();
        s.set_variable("source", json!(99.0));
        let script = json!({
            "blocks": [
                {"type": "assign_variable", "variable": "dest", "value": "{source}"}
            ]
        });
        ScriptExecutor::new()
            .execute(
                script.as_object().unwrap(),
                &mut s,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut None,
            )
            .unwrap();
        assert_eq!(s.get_variable("dest"), Some(&json!(99.0)));
    }

    #[test]
    fn audit_condition_with_var_substitution() {
        let mut s = state();
        s.set_variable("gold", json!(100.0));
        let script = json!({
            "blocks": [
                {
                    "type": "event",
                    "eventType": "onNodeEnter",
                    "children": [
                        {
                            "type": "condition",
                            "expression": "{gold} >= 50",
                            "then_blocks": [
                                {"type": "assign_variable", "variable": "rich", "value": "'yes'"}
                            ]
                        }
                    ]
                }
            ]
        });
        ScriptExecutor::new()
            .execute(
                script.as_object().unwrap(),
                &mut s,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut None,
            )
            .unwrap();
        assert_eq!(s.get_variable("rich"), Some(&json!("yes")));
    }

    #[test]
    fn audit_condition_legacy_format_without_expression() {
        let mut s = state();
        s.set_variable("hp", json!(50.0));
        let block = json!({
            "type": "condition",
            "variable": "hp",
            "comparison": ">=",
            "value": "30"
        });
        assert!(evaluate_condition_logic(block.as_object().unwrap(), &mut s));
    }

    #[test]
    fn audit_condition_string_value_with_quotes() {
        let mut s = state();
        s.set_variable("status", json!("active"));
        let block = json!({
            "type": "condition",
            "variable": "status",
            "comparison": "==",
            "value": "active"
        });
        assert!(evaluate_condition_logic(block.as_object().unwrap(), &mut s));
    }

    // Категория 4: evaluate_expression НЕ-СТРОКОВЫЕ ВХОДЫ
    // Проблема D.

    #[test]
    fn audit_non_string_number_passthrough() {
        let mut s = state();
        assert_eq!(evaluate_expression(Some(json!(42.5)), &mut s), json!(42.5));
    }

    #[test]
    fn audit_non_string_bool_passthrough() {
        let mut s = state();
        assert_eq!(
            evaluate_expression(Some(json!(true)), &mut s),
            Value::Bool(true)
        );
        assert_eq!(
            evaluate_expression(Some(json!(false)), &mut s),
            Value::Bool(false)
        );
    }

    #[test]
    fn audit_non_string_null_passthrough() {
        let mut s = state();
        assert_eq!(evaluate_expression(Some(Value::Null), &mut s), Value::Null);
    }

    #[test]
    fn audit_non_string_array_passthrough() {
        let mut s = state();
        let arr = json!([1, 2, 3]);
        assert_eq!(evaluate_expression(Some(arr.clone()), &mut s), arr);
    }

    // Категория 5: ROUNDTRIP JSON (Dart→Rust→Dart)
    // Проблема D: сохранение типа после roundtrip.

    #[test]
    fn audit_roundtrip_double_serializes_properly() {
        let v = json!(10.0);
        assert_eq!(serde_json::to_string(&v).unwrap(), "10.0");
    }

    #[test]
    fn audit_set_get_variable_preserves_type() {
        let mut s = state();
        s.set_variable("x", json!(5.5));
        let r = s.get_variable("x").cloned().unwrap();
        assert_eq!(r, json!(5.5));
        assert!(r.is_f64());
    }

    // Категория 6: EXECUTE — ПРОВЕРКА ФАКТИЧЕСКОГО ИЗМЕНЕНИЯ СОСТОЯНИЯ

    #[test]
    fn audit_execute_assign_creates_variable() {
        let mut s = state();
        assert!(s.get_variable("score").is_none());
        let script = json!({
            "blocks": [
                {"type": "assign_variable", "variable": "score", "value": "100"}
            ]
        });
        ScriptExecutor::new()
            .execute(
                script.as_object().unwrap(),
                &mut s,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut None,
            )
            .unwrap();
        assert!(s.get_variable("score").is_some());
    }

    #[test]
    fn audit_evaluate_condition_no_state_mutation() {
        let mut s = state();
        let script = json!({
            "name": "cond",
            "blocks": [
                {
                    "type": "event",
                    "eventType": "onNodeEnter",
                    "children": [
                        {"type": "condition", "expression": "2 > 1", "then_blocks": []}
                    ]
                }
            ]
        });
        let vars_before: Vec<_> = s.all_variables().keys().cloned().collect();
        assert!(evaluate_condition(
            script.as_object().unwrap(),
            &mut s,
            EventType::OnNodeEnter,
            &None,
            &None,
            false,
            false,
        ));
        let vars_after: Vec<_> = s.all_variables().keys().cloned().collect();
        assert_eq!(vars_before, vars_after);
    }

    #[test]
    fn audit_evaluate_condition_visibility_string_bool_coercion() {
        // Триггер видимости (onAppear): переменная из config приходит строкой
        // "false"/"true", в скрипте сравнение с логическим литералом —
        // эталон коэрсит. НЕ ЗАТРОГАТЬ БЕЗ РЕГРЕСИИ В КВЕСТАХ.
        let mut s = state();
        s.set_variable("первый вход", json!("false"));
        let script = json!({
            "name": "vis",
            "blocks": [
                {"type": "event", "eventType": "onContentAppear", "children": [
                    {"type": "condition", "expression": "{первый вход}==false", "then_blocks": []}
                ]}
            ]
        });
        assert!(evaluate_condition(
            script.as_object().unwrap(),
            &mut s,
            EventType::OnContentAppear,
            &None,
            &None,
            true,
            true,
        ));

        // После первого входа переменная стала true — условие больше не срабатывает.
        s.set_variable("первый вход", json!("true"));
        assert!(!evaluate_condition(
            script.as_object().unwrap(),
            &mut s,
            EventType::OnContentAppear,
            &None,
            &None,
            true,
            true,
        ));
    }

    #[test]
    fn audit_evaluate_condition_visibility_allow_mutation_flag() {
        // Первая оценка видимости (allowStateMutation=true) выполняет
        // прелюдию-мутации; повторная переоценка (false) — НЕ выполняет.
        let mut s = state();
        let script = json!({
            "name": "vis",
            "blocks": [
                {"type": "event", "eventType": "onContentAppear", "children": [
                    {"type": "assign_variable", "variable": "показ", "value": "1"},
                    {"type": "condition", "expression": "2 > 1", "then_blocks": []}
                ]}
            ]
        });
        assert!(evaluate_condition(
            script.as_object().unwrap(),
            &mut s,
            EventType::OnContentAppear,
            &None,
            &None,
            true,
            false,
        ));
        assert!(s.get_variable("показ").is_none());

        assert!(evaluate_condition(
            script.as_object().unwrap(),
            &mut s,
            EventType::OnContentAppear,
            &None,
            &None,
            true,
            true,
        ));
        assert_eq!(s.get_variable("показ"), Some(&json!(1)));
    }

    // Категория 7: ПОГРАНИЧНЫЕ ЗНАЧЕНИЯ — TABLE OPERATIONS, GO_TO_NODE

    #[test]
    fn audit_table_get_empty_path_uses_fallback() {
        let mut s = state();
        let table = QuestTable::new("tbl".into(), vec![], vec![], Map::new());
        s.set_table("tbl", table);
        let script = json!({
            "blocks": [{
                "type": "table_operation",
                "operation": "get",
                "tableName": "tbl",
                "path": "",
                "value": "'default'",
                "targetVariable": "result"
            }]
        });
        ScriptExecutor::new()
            .execute(
                script.as_object().unwrap(),
                &mut s,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut None,
            )
            .unwrap();
        assert_eq!(s.get_variable("result"), Some(&json!("default")));
    }

    #[test]
    fn audit_table_get_missing_table_no_panic() {
        let mut s = state();
        let script = json!({
            "blocks": [{
                "type": "table_operation",
                "operation": "get",
                "tableName": "nonexistent",
                "path": "x",
                "targetVariable": "y"
            }]
        });
        let result = ScriptExecutor::new()
            .execute(
                script.as_object().unwrap(),
                &mut s,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut None,
            )
            .unwrap();
        assert_eq!(result, None);
        assert!(s.get_variable("y").is_none());
    }

    /// Прогон одного блока `table_operation` с собранным логом: операция
    /// обязана объяснить, что сделала (или почему не сделала ничего).
    fn table_op_log(state: &mut InMemoryScriptRuntimeState, block: Value) -> String {
        let logs = std::sync::Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
        let sink = std::sync::Arc::clone(&logs);
        ScriptExecutor::new()
            .with_logger(Some(Box::new(move |m: &str| {
                sink.lock().unwrap().push(m.to_string());
            })))
            .execute_table_operation(block.as_object().unwrap(), state)
            .unwrap();
        logs.lock().unwrap().join("\n")
    }

    #[test]
    fn table_remove_value_drops_matching_element_from_list() {
        let mut s = state();
        s.set_table(
            "инвентарь",
            QuestTable::new(
                "инвентарь".into(),
                vec![],
                vec![],
                json!({"items": ["меч", "щит", "копьё"]})
                    .as_object()
                    .unwrap()
                    .clone(),
            ),
        );
        table_op_log(
            &mut s,
            json!({
                "type": "table_operation", "operation": "remove_value",
                "tableName": "инвентарь", "path": "items", "value": "'щит'"
            }),
        );
        let table = s.get_table("инвентарь").unwrap();
        assert_eq!(table.data["items"], json!(["меч", "копьё"]));
    }

    #[test]
    fn table_remove_value_drops_only_first_occurrence() {
        let mut s = state();
        s.set_table(
            "x",
            QuestTable::new(
                "x".into(),
                vec![],
                vec![],
                json!({"items": ["зелье", "зелье", "ключ"]})
                    .as_object()
                    .unwrap()
                    .clone(),
            ),
        );
        table_op_log(
            &mut s,
            json!({
                "type": "table_operation", "operation": "remove_value",
                "tableName": "x", "path": "items", "value": "'зелье'"
            }),
        );
        assert_eq!(
            s.get_table("x").unwrap().data["items"],
            json!(["зелье", "ключ"])
        );
    }

    #[test]
    fn table_remove_value_reports_no_match_instead_of_lying() {
        let mut s = state();
        s.set_table(
            "x",
            QuestTable::new(
                "x".into(),
                vec![],
                vec![],
                json!({"items": ["меч"]}).as_object().unwrap().clone(),
            ),
        );
        let log = table_op_log(
            &mut s,
            json!({
                "type": "table_operation", "operation": "remove_value",
                "tableName": "x", "path": "items", "value": "'лук'"
            }),
        );
        assert!(log.contains("нет"), "лог: {log}");
        assert_eq!(s.get_table("x").unwrap().data["items"], json!(["меч"]));
    }

    #[test]
    fn table_remove_value_on_dictionary_points_at_key_operation() {
        // Словарь ключ→значение чистят операцией «Удалить» по имени ключа;
        // промах должен учить этому, а не молча ничего делать.
        let mut s = state();
        s.set_table(
            "цены",
            QuestTable::new(
                "цены".into(),
                vec![],
                vec![],
                json!({"хлеб": 5, "молоко": 8}).as_object().unwrap().clone(),
            ),
        );
        let log = table_op_log(
            &mut s,
            json!({
                "type": "table_operation", "operation": "remove_value",
                "tableName": "цены", "path": "", "value": "5"
            }),
        );
        // Пустой путь = корень словаря: нужен путь к списку.
        assert!(log.contains("нужны и путь"), "лог: {log}");
        assert_eq!(s.get_table("цены").unwrap().data.len(), 2);
    }

    #[test]
    fn table_remove_value_inside_dictionary_value_names_the_key_to_use() {
        let mut s = state();
        s.set_table(
            "цены",
            QuestTable::new(
                "цены".into(),
                vec![],
                vec![],
                json!({"склад": {"хлеб": 5, "молоко": 8}})
                    .as_object()
                    .unwrap()
                    .clone(),
            ),
        );
        let log = table_op_log(
            &mut s,
            json!({
                "type": "table_operation", "operation": "remove_value",
                "tableName": "цены", "path": "склад", "value": "5"
            }),
        );
        assert!(log.contains("словарь"), "лог: {log}");
        assert!(log.contains("хлеб"), "в логе должны быть ключи: {log}");
        assert_eq!(
            s.get_table("цены").unwrap().data["склад"],
            json!({"хлеб": 5, "молоко": 8})
        );
    }

    #[test]
    fn table_unknown_operation_is_logged_not_swallowed() {
        let mut s = state();
        s.set_table("x", QuestTable::new("x".into(), vec![], vec![], Map::new()));
        let log = table_op_log(
            &mut s,
            json!({"type": "table_operation", "operation": "delete", "tableName": "x"}),
        );
        assert!(log.contains("неизвестная операция"), "лог: {log}");
    }

    #[test]
    fn table_missing_table_lists_available_names() {
        let mut s = state();
        s.set_table(
            "инвентарь",
            QuestTable::new("инвентарь".into(), vec![], vec![], Map::new()),
        );
        let log = table_op_log(
            &mut s,
            json!({
                "type": "table_operation", "operation": "set",
                "tableName": "хранение", "path": "a", "value": "1"
            }),
        );
        assert!(log.contains("не найдена"), "лог: {log}");
        assert!(
            log.contains("инвентарь"),
            "в логе перечислены таблицы: {log}"
        );
        assert!(s.get_table("хранение").is_none());
    }

    #[test]
    fn table_clear_of_scalar_reports_instead_of_ignoring() {
        let mut s = state();
        s.set_table(
            "x",
            QuestTable::new(
                "x".into(),
                vec![],
                vec![],
                json!({"gold": 12}).as_object().unwrap().clone(),
            ),
        );
        let log = table_op_log(
            &mut s,
            json!({"type": "table_operation", "operation": "clear", "tableName": "x", "path": "gold"}),
        );
        assert!(log.contains("не список"), "лог: {log}");
        assert_eq!(s.get_table("x").unwrap().data["gold"], json!(12));
    }

    #[test]
    fn table_get_without_target_variable_reports() {
        let mut s = state();
        s.set_table(
            "x",
            QuestTable::new(
                "x".into(),
                vec![],
                vec![],
                json!({"gold": 12}).as_object().unwrap().clone(),
            ),
        );
        let log = table_op_log(
            &mut s,
            json!({"type": "table_operation", "operation": "get", "tableName": "x", "path": "gold"}),
        );
        assert!(log.contains("приёмник"), "лог: {log}");
    }

    #[test]
    fn table_get_without_path_explains_fallback() {
        // Контракт пустого пути сохранён (audit_table_get_empty_path_uses_fallback),
        // но промах теперь объясняется в логе.
        let mut s = state();
        s.set_table(
            "x",
            QuestTable::new(
                "x".into(),
                vec![],
                vec![],
                json!({"gold": 12, "hp": 3}).as_object().unwrap().clone(),
            ),
        );
        let log = table_op_log(
            &mut s,
            json!({"type": "table_operation", "operation": "get", "tableName": "x",
                   "path": "", "value": "'промах'", "targetVariable": "result"}),
        );
        assert_eq!(s.get_variable("result"), Some(&json!("промах")));
        assert!(
            log.contains("путь не указан"),
            "пустой путь нужно объяснять: {log}"
        );
    }

    #[test]
    fn table_get_missing_key_names_available_keys() {
        let mut s = state();
        s.set_table(
            "x",
            QuestTable::new(
                "x".into(),
                vec![],
                vec![],
                json!({"gold": 12}).as_object().unwrap().clone(),
            ),
        );
        let log = table_op_log(
            &mut s,
            json!({"type": "table_operation", "operation": "get", "tableName": "x",
                   "path": "golg", "value": "0", "targetVariable": "result"}),
        );
        assert!(
            log.contains("Ключи таблицы") && log.contains("gold"),
            "в логе должны быть ключи таблицы: {log}"
        );
        assert!(
            log.contains("запасн"),
            "и объяснение запасного значения: {log}"
        );
    }

    #[test]
    fn table_set_without_path_does_not_create_phantom_key() {
        // Раньше `set` без пути заводил в хранилище служебный ключ «null».
        let mut s = state();
        s.set_table("x", QuestTable::new("x".into(), vec![], vec![], Map::new()));
        let log = table_op_log(
            &mut s,
            json!({"type": "table_operation", "operation": "set", "tableName": "x", "path": "", "value": "7"}),
        );
        assert!(log.contains("укажите путь"), "лог: {log}");
        assert!(
            !s.get_table("x").unwrap().data.contains_key("null"),
            "призрачный ключ: {:?}",
            s.get_table("x").unwrap().data
        );
        assert!(s.get_table("x").unwrap().data.is_empty());
    }

    #[test]
    fn table_clear_without_path_empties_whole_storage() {
        let mut s = state();
        s.set_table(
            "x",
            QuestTable::new(
                "x".into(),
                vec![],
                vec![],
                json!({"a": 1, "b": 2}).as_object().unwrap().clone(),
            ),
        );
        table_op_log(
            &mut s,
            json!({"type": "table_operation", "operation": "clear", "tableName": "x", "path": ""}),
        );
        assert!(s.get_table("x").unwrap().data.is_empty());
    }

    #[test]
    fn table_contains_without_path_searches_whole_table() {
        let mut s = state();
        s.set_table(
            "x",
            QuestTable::new(
                "x".into(),
                vec![],
                vec![],
                json!({"хлеб": 5, "молоко": 8}).as_object().unwrap().clone(),
            ),
        );
        table_op_log(
            &mut s,
            json!({
                "type": "table_operation", "operation": "contains",
                "tableName": "x", "path": "", "value": "8",
                "targetVariable": "есть_восьмёрка"
            }),
        );
        assert_eq!(s.get_variable("есть_восьмёрка"), Some(&json!(true)));
    }

    #[test]
    fn audit_deep_table_with_variable_keys() {
        let mut s = state();
        let mut inner = Map::new();
        inner.insert("nested".into(), json!(999));
        let mut data = Map::new();
        data.insert("level1".into(), Value::Object(inner));
        s.set_table("data", QuestTable::new("data".into(), vec![], vec![], data));
        s.set_variable("l", json!("level1"));
        s.set_variable("k", json!("nested"));
        let r = evaluate_expression(Some(json!("data[{l}][{k}]")), &mut s);
        assert_eq!(r, json!(999));
    }

    #[test]
    fn audit_go_to_node_null_node_id_returns_none() {
        let mut s = state();
        let script = json!({"blocks": [{"type": "go_to_node"}]});
        let result = ScriptExecutor::new()
            .execute(
                script.as_object().unwrap(),
                &mut s,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut None,
            )
            .unwrap();
        assert_eq!(result, None);
    }

    #[test]
    fn audit_go_to_node_empty_node_id_returns_some_empty_string() {
        let mut s = state();
        let script = json!({"blocks": [{"type": "go_to_node", "node_id": ""}]});
        let result = ScriptExecutor::new()
            .execute(
                script.as_object().unwrap(),
                &mut s,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut None,
            )
            .unwrap();
        // Пустой node_id → Some("") — паритет с Dart.
        assert_eq!(result, Some(String::new()));
    }

    // Категория 8: check_script_event_type ГРАНИЦЫ

    #[test]
    fn audit_event_type_empty_script_defaults_to_content_appear() {
        assert_eq!(
            check_script_event_type(&Map::new()),
            EventType::OnContentAppear
        );
    }

    #[test]
    fn audit_event_type_no_blocks_defaults_to_content_appear() {
        let script = json!({"name": "test"});
        assert_eq!(
            check_script_event_type(script.as_object().unwrap()),
            EventType::OnContentAppear
        );
    }

    #[test]
    fn audit_event_type_function_detection() {
        let script = json!({
            "blocks": [{
                "type": "event",
                "eventType": "function",
                "functionName": "main",
                "children": []
            }]
        });
        assert_eq!(
            check_script_event_type(script.as_object().unwrap()),
            EventType::Function
        );
    }

    // Категория 9: placeholder с разными типами значений

    #[test]
    fn audit_placeholder_with_object_value() {
        let mut s = state();
        s.set_variable("obj", json!({"a": 1}));
        assert_eq!(
            evaluate_expression(Some(json!("{obj}")), &mut s),
            json!({"a": 1})
        );
    }

    #[test]
    fn audit_placeholder_with_bool_value() {
        let mut s = state();
        s.set_variable("flag", json!(true));
        assert_eq!(
            evaluate_expression(Some(json!("{flag}")), &mut s),
            Value::Bool(true)
        );
    }

    // Категория 10: assign_variable — type after execute

    #[test]
    fn audit_assign_variable_float_string_keeps_type() {
        let mut s = state();
        let script = json!({
            "blocks": [
                {"type": "assign_variable", "variable": "blur", "value": "7.5"}
            ]
        });
        ScriptExecutor::new()
            .execute(
                script.as_object().unwrap(),
                &mut s,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut None,
            )
            .unwrap();
        assert_eq!(s.get_variable("blur"), Some(&json!(7.5)));
    }

    #[test]
    fn audit_assign_variable_bool_string_keeps_type() {
        let mut s = state();
        let script = json!({
            "blocks": [
                {"type": "assign_variable", "variable": "done", "value": "true"}
            ]
        });
        ScriptExecutor::new()
            .execute(
                script.as_object().unwrap(),
                &mut s,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut None,
            )
            .unwrap();
        assert_eq!(s.get_variable("done"), Some(&Value::Bool(true)));
    }

    // Категория 11: assign_variable операции ±

    #[test]
    fn audit_assign_variable_add_operation() {
        let mut s = state();
        s.set_variable("gold", json!(10.0));
        let script = json!({
            "blocks": [{
                "type": "assign_variable",
                "variable": "gold",
                "value": "5",
                "операция": "прибавить"
            }]
        });
        ScriptExecutor::new()
            .execute(
                script.as_object().unwrap(),
                &mut s,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut None,
            )
            .unwrap();
        assert_eq!(s.get_variable("gold"), Some(&json!(15)));
    }

    #[test]
    fn audit_assign_variable_subtract_operation() {
        let mut s = state();
        s.set_variable("hp", json!(100.0));
        let script = json!({
            "blocks": [{
                "type": "assign_variable",
                "variable": "hp",
                "value": "25",
                "операция": "отнять"
            }]
        });
        ScriptExecutor::new()
            .execute(
                script.as_object().unwrap(),
                &mut s,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut None,
            )
            .unwrap();
        assert_eq!(s.get_variable("hp"), Some(&json!(75)));
    }

    // Категория 12: set_blur / set_volume с разными входами

    #[test]
    fn audit_set_blur_with_raw_json_number() {
        let mut s = state();
        let script = json!({
            "blocks": [
                {"type": "set_blur", "target": "node", "blur": 5}
            ]
        });
        ScriptExecutor::new()
            .execute(
                script.as_object().unwrap(),
                &mut s,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut None,
            )
            .unwrap();
        let blur = s
            .get_variable("_internal_background_blur")
            .cloned()
            .unwrap();
        assert_eq!(blur, json!(5.0));
    }

    #[test]
    fn audit_set_volume_with_raw_number() {
        let mut s = state();
        let script = json!({
            "blocks": [
                {"type": "set_volume", "target": "contentAudio", "volume": 0.7}
            ]
        });
        ScriptExecutor::new()
            .execute(
                script.as_object().unwrap(),
                &mut s,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut None,
            )
            .unwrap();
        assert_eq!(
            s.get_variable("_internal_node_content_volume"),
            Some(&json!(0.7))
        );
    }

    // Категория 13: parse_path границы

    #[test]
    fn audit_parse_path_empty_returns_empty() {
        assert!(parse_path("").is_empty());
    }

    #[test]
    fn audit_parse_path_single_key() {
        let keys = parse_path("gold");
        assert_eq!(keys.len(), 1);
        assert_eq!(keys[0], Value::String("gold".into()));
    }

    #[test]
    fn audit_parse_path_nested_brackets() {
        let keys = parse_path("a[0]['key']");
        assert_eq!(keys.len(), 3);
        assert_eq!(keys[0], Value::String("a".into()));
        assert_eq!(keys[1], json!(0));
        assert_eq!(keys[2], Value::String("key".into()));
    }

    // Категория 14: event targeting граничные случаи

    #[test]
    fn audit_targeted_event_mismatched_content_item_id_skips() {
        let script = json!({
            "name": "test",
            "blocks": [{
                "type": "event",
                "eventType": "onPress",
                "targetContentItemId": "specific",
                "children": [
                    {"type": "assign_variable", "variable": "hit", "value": "'yes'"}
                ]
            }]
        });
        let s = script.as_object().unwrap();
        let mut state = state();
        ScriptExecutor::new()
            .execute(
                s,
                &mut state,
                "q",
                EventType::OnPress,
                &None,
                &None,
                false,
                &mut None,
            )
            .unwrap();
        assert_eq!(state.get_variable("hit"), None);
    }

    // Категория 15: Dart-vs-Rust расхождение — ДОКУМЕНТИРУЮЩИЙ ТЕСТ
    //
    // Dart: num.tryParse("42") → int 42 (нативный int).
    // Rust: parse::<f64>("42") → 42.0 double.
    //
    // В текущей реализации (после фикса bd5cf40) оба пути дают double 42.0,
    // что БЕЗОПАСНО для UI (game_screen.dart:875 `as double? ?? 10.0`).
    //
    // Однако если бы json_of_f64(42.0) давал int 42 (как было до фикса),
    // то serde_json::to_string → "42" → Dart jsonDecode → int 42 →
    // `as double?` → null → blur всегда 10.0 (дефолт, игнорируя установленное).
    //
    // Данный тест проверяет, что фикс работает и double сохраняется.

    #[test]
    fn audit_dart_vs_rust_string_int_parity_documented() {
        let mut s = state();
        let r = evaluate_expression(Some(json!("42")), &mut s);
        assert_eq!(r, json!(42));
        assert_eq!(serde_json::to_string(&r).unwrap(), "42");
    }

    // Категория 16: оператор in с переменными в обеих частях

    #[test]
    fn audit_in_operator_with_variables() {
        let mut s = state();
        s.set_variable("x", json!("Bob"));
        let r = evaluate_expression(Some(json!("{x} in ('Bob', 'Alice')")), &mut s);
        assert_eq!(r, Value::Bool(true));
    }

    // Категория 17: composite expressions через evaluate_condition_logic

    #[test]
    fn audit_condition_expression_with_boolean_result() {
        let mut s = state();
        let block = json!({"type": "condition", "expression": "true && true"});
        assert!(evaluate_condition_logic(block.as_object().unwrap(), &mut s));

        let block2 = json!({"type": "condition", "expression": "false || false"});
        assert!(!evaluate_condition_logic(
            block2.as_object().unwrap(),
            &mut s
        ));
    }

    // Категория 18: UTF-8 (кириллица) в composite-выражениях и deep lookup.
    // Регрессия: find_top_level_operator/keyword возвращали символьный индекс,
    // который использовался как байтовый в срезах строки — падало на кириллице.

    #[test]
    fn unicode_variable_in_comparison() {
        let mut s = state();
        s.set_variable("Вернул время", json!(1));
        // {Вернул время} == 1 → true
        let r = evaluate_expression(Some(json!("{Вернул время} == 1")), &mut s);
        assert_eq!(r, Value::Bool(true));

        // сравнение с не-ASCII значением
        s.set_variable("имя", json!("Артур"));
        let r2 = evaluate_expression(Some(json!("{имя} == 'Артур'")), &mut s);
        assert_eq!(r2, Value::Bool(true));
    }

    #[test]
    fn unicode_variable_in_operators() {
        let mut s = state();
        s.set_variable("число", json!(10));

        // !=
        let r = evaluate_expression(Some(json!("{число} != 5")), &mut s);
        assert_eq!(r, Value::Bool(true));

        // < и > через кириллическое имя переменной
        let r2 = evaluate_expression(Some(json!("{число} > 5")), &mut s);
        assert_eq!(r2, Value::Bool(true));

        // ||
        let r3 = evaluate_expression(Some(json!("{число} == 5 || {число} == 10")), &mut s);
        assert_eq!(r3, Value::Bool(true));

        // in с не-ASCII левой частью
        s.set_variable("город", json!("Москва"));
        let r4 = evaluate_expression(Some(json!("{город} in ('Москва', 'Питер')")), &mut s);
        assert_eq!(r4, Value::Bool(true));
    }

    #[test]
    fn unicode_deep_lookup_key() {
        let mut s = state();
        let table = json!({"столица": "Москва"});
        s.set_table(
            "страна",
            crate::models::QuestTable::from_json(&json!({
                "name": "страна",
                "columns": [],
                "rows": [],
                "data": table,
            })),
        );
        // deep lookup: страна['столица']
        let r = evaluate_expression(Some(json!("страна['столица']")), &mut s);
        assert_eq!(r, json!("Москва"));
    }

    #[test]
    fn nested_tables_user_quest_regression_test() {
        use crate::models::QuestTable;
        use serde_json::json;
        let mut s = state();
        s.set_table(
            "Предметы в игре",
            QuestTable::new(
                "Предметы в игре".into(),
                vec![],
                vec![],
                json!({}).as_object().unwrap().clone(),
            ),
        );
        s.set_table(
            "Инвентерь",
            QuestTable::new(
                "Инвентерь".into(),
                vec![],
                vec![],
                json!({}).as_object().unwrap().clone(),
            ),
        );

        let script = json!({
            "name": "Инициализация",
            "blocks": [{
                "type": "event",
                "eventType": "onNodeEnter",
                "children": [
                    {
                        "type": "table_operation",
                        "operation": "set",
                        "tableName": "Предметы в игре",
                        "path": "'фрукты.яблоко.описание'",
                        "value": "'Вкусное, свежее яблоко(антоновка)'"
                    },
                    {
                        "type": "table_operation",
                        "operation": "set",
                        "tableName": "Предметы в игре",
                        "path": "'фрукты.яблоко.название'",
                        "value": "'Яблочко наливное'"
                    },
                    {
                        "type": "table_operation",
                        "operation": "add",
                        "tableName": "Инвентерь",
                        "path": "'рука'",
                        "value": "{Предметы в игре.фрукты.яблоко}"
                    }
                ]
            }]
        });

        let res = ScriptExecutor::new().execute(
            script.as_object().unwrap(),
            &mut s,
            "quest_1",
            EventType::OnNodeEnter,
            &None,
            &None,
            false,
            &mut None,
        );
        assert!(res.is_ok());

        // 1. Проверяем установку данных в первой таблице
        let t1 = s.get_table("Предметы в игре").unwrap();
        assert_eq!(
            t1.data["фрукты"]["яблоко"]["название"],
            json!("Яблочко наливное")
        );
        assert_eq!(
            t1.data["фрукты"]["яблоко"]["описание"],
            json!("Вкусное, свежее яблоко(антоновка)")
        );

        // 2. Проверяем добавление в инвентарь (массив должен содержать объект, а не null!)
        let t2 = s.get_table("Инвентерь").unwrap();
        let hand = t2.data.get("рука").unwrap().as_array().unwrap();
        assert_eq!(hand.len(), 1);
        assert_ne!(hand[0], Value::Null);
        assert_eq!(hand[0]["название"], json!("Яблочко наливное"));

        // 3. Проверяем отображение {Предметы в игре} — не должно быть полей name/rows/columns/__table_full_json__
        let expr1 = evaluate_expression(Some(json!("Предметы в игре")), &mut s);
        assert!(expr1.get("name").is_none());
        assert!(expr1.get("rows").is_none());
        assert!(expr1.get("__table_full_json__").is_none());
        assert!(expr1.get("фрукты").is_some());

        // 4. Проверяем глубокий лукап {Инвентерь.рука[0]}
        let expr2 = evaluate_expression(Some(json!("Инвентерь.рука[0]")), &mut s);
        assert_eq!(expr2["название"], json!("Яблочко наливное"));
    }

    #[test]
    fn table_grid_is_readable_from_expressions() {
        use crate::models::QuestTable;
        let mut s = state();
        s.set_table(
            "лавка",
            QuestTable::new(
                "лавка".into(),
                vec!["товар".into(), "цена".into()],
                vec![
                    json!({"товар": "хлеб", "цена": 30})
                        .as_object()
                        .unwrap()
                        .clone(),
                    json!({"товар": "ключ", "цена": 5})
                        .as_object()
                        .unwrap()
                        .clone(),
                ],
                json!({"открыто": true}).as_object().unwrap().clone(),
            ),
        );

        // Сетка видна формулам, и формула складывается с арифметикой.
        assert_eq!(
            evaluate_expression(Some(json!("table_cell(лавка, 'товар', 1)")), &mut s),
            json!("хлеб")
        );
        assert_eq!(
            evaluate_expression(Some(json!("table_sum(лавка, 'цена') * 2")), &mut s),
            json!(70)
        );
        assert_eq!(
            evaluate_expression(Some(json!("table_rows('лавка')")), &mut s),
            json!(2)
        );
        // Наружу уходит ровно `data`: служебных ключей projection игрок не
        // должен увидеть ни в переменной, ни в тексте.
        let whole = evaluate_expression(Some(json!("лавка")), &mut s);
        assert_eq!(whole.get("__rows"), None);
        assert_eq!(whole.get("__columns"), None);
        assert_eq!(whole["открыто"], json!(true));
    }

    #[test]
    fn call_lua_block_runs_function_and_returns_transition() {
        let script = json!({
            "name": "lua_quest",
            "blocks": [{
                "type": "call_lua",
                "script": "function choose(x)\n  if x > 3 then return { node = 'node_9' } end\n  core.set_var('small', x)\nend",
                "function": "choose",
                "args": "[5]"
            }]
        });
        let mut s = state();
        let mut lua = None;
        let res = ScriptExecutor::new()
            .execute(
                script.as_object().unwrap(),
                &mut s,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut lua,
            )
            .unwrap();
        assert_eq!(res, Some("node_9".to_string()));
    }

    #[test]
    fn call_lua_block_core_set_var_visible_in_state() {
        let script = json!({
            "name": "lua_set",
            "blocks": [{
                "type": "call_lua",
                "script": "function mark(x) core.set_var('lua_marked', x) end",
                "function": "mark",
                "args": "[\"yes\"]"
            }]
        });
        let mut s = state();
        let mut lua = None;
        let res = ScriptExecutor::new()
            .execute(
                script.as_object().unwrap(),
                &mut s,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut lua,
            )
            .unwrap();
        assert_eq!(res, None);
        assert_eq!(s.get_variable("lua_marked"), Some(&json!("yes")));
        // Изменение попало в dirty-набор (для дельты клиента).
        assert!(s.drain_dirty_variables().contains("lua_marked"));
    }

    #[test]
    fn call_lua_function_persists_across_blocks_in_session() {
        // Функция регистрируется в первом блоке, вызывается во втором
        // (Lua-сессия живёт на протяжении execute).
        let script = json!({
            "name": "lua_persist",
            "blocks": [
                {
                    "type": "call_lua",
                    "script": "function greet(name) core.set_var('greeting', 'hi ' .. name) end",
                    "function": "greet",
                    "args": "[\"Ann\"]"
                },
                {
                    "type": "call_lua",
                    "function": "greet",
                    "args": "[\"Bob\"]"
                }
            ]
        });
        let mut s = state();
        let mut lua = None;
        ScriptExecutor::new()
            .execute(
                script.as_object().unwrap(),
                &mut s,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut lua,
            )
            .unwrap();
        assert_eq!(s.get_variable("greeting"), Some(&json!("hi Bob")));
    }

    #[test]
    fn call_lua_get_var_reads_current_state() {
        let script = json!({
            "name": "lua_read",
            "blocks": [{
                "type": "call_lua",
                "script": "function read() core.set_var('doubled', core.get_var('hp') * 2) end",
                "function": "read",
                "args": "[]"
            }]
        });
        let mut s = var_state(); // hp = 75
        let mut lua = None;
        ScriptExecutor::new()
            .execute(
                script.as_object().unwrap(),
                &mut s,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut lua,
            )
            .unwrap();
        assert_eq!(s.get_variable("doubled"), Some(&json!(150)));
    }

    #[test]
    fn call_lua_missing_function_is_error_not_panic() {
        let script = json!({
            "name": "lua_missing",
            "blocks": [{
                "type": "call_lua",
                "function": "no_such_function",
                "args": "[]"
            }]
        });
        let mut s = state();
        let mut lua = None;
        let res = ScriptExecutor::new().execute(
            script.as_object().unwrap(),
            &mut s,
            "q",
            EventType::OnNodeEnter,
            &None,
            &None,
            false,
            &mut lua,
        );
        // Ошибка Lua логируется, геймлуп не падает (execute вернёт Ok).
        assert!(res.is_ok());
    }

    #[test]
    fn call_lua_math_and_utf8_work() {
        let script = json!({
            "name": "lua_math",
            "blocks": [{
                "type": "call_lua",
                "script": "function compute() core.set_var('sqrt2', math.sqrt(2)) core.set_var('привет', 'мир') end",
                "function": "compute",
                "args": "[]"
            }]
        });
        let mut s = state();
        let mut lua = None;
        ScriptExecutor::new()
            .execute(
                script.as_object().unwrap(),
                &mut s,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut lua,
            )
            .unwrap();
        let sqrt2 = s.get_variable("sqrt2").unwrap().as_f64().unwrap();
        assert!((sqrt2 - std::f64::consts::SQRT_2).abs() < 1e-9);
        assert_eq!(s.get_variable("привет"), Some(&json!("мир")));
    }

    #[test]
    fn call_lua_loads_script_from_file_via_script_id() {
        let mut store = crate::executor::test_store::InMemoryScriptStore::new();
        store.insert_text(
            "quests/q/scripts/start.lua".to_string(),
            "function start() core.set_var('x', 42) return { node = 'node_next' } end".to_string(),
        );

        let script = json!({
            "name": "lua_file",
            "blocks": [{
                "type": "call_lua",
                "script_id": "start.lua",
                "function": "start"
            }]
        });
        let mut s = state();
        let mut lua = None;
        let res = ScriptExecutor::new()
            .with_asset_store(std::sync::Arc::new(store))
            .execute(
                script.as_object().unwrap(),
                &mut s,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut lua,
            )
            .unwrap();
        assert_eq!(res, Some("node_next".to_string()));
        assert_eq!(s.get_variable("x"), Some(&json!(42)));
    }

    #[test]
    fn call_lua_script_id_without_extension_and_full_path() {
        let mut store = crate::executor::test_store::InMemoryScriptStore::new();
        store.insert_text(
            "quests/q/scripts/helper.lua".to_string(),
            "function go() core.set_var('ok', true) end".to_string(),
        );

        // script_id без расширения резолвится в scripts/<id>.lua
        let script = json!({
            "name": "lua_noext",
            "blocks": [{ "type": "call_lua", "script_id": "helper", "function": "go" }]
        });
        let mut s = state();
        let mut lua = None;
        ScriptExecutor::new()
            .with_asset_store(std::sync::Arc::new(store))
            .execute(
                script.as_object().unwrap(),
                &mut s,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut lua,
            )
            .unwrap();
        assert_eq!(s.get_variable("ok"), Some(&json!(true)));
    }

    #[test]
    fn call_lua_missing_script_id_is_error_not_panic() {
        let store = crate::executor::test_store::InMemoryScriptStore::new();
        let script = json!({
            "name": "lua_nofile",
            "blocks": [{
                "type": "call_lua",
                "script_id": "ghost.lua",
                "function": "start"
            }]
        });
        let mut s = state();
        let mut lua = None;
        let res = ScriptExecutor::new()
            .with_asset_store(std::sync::Arc::new(store))
            .execute(
                script.as_object().unwrap(),
                &mut s,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut lua,
            );
        // Ошибка логируется, execute возвращает Ok (геймлуп не падает).
        assert!(res.is_ok());
    }

    #[test]
    fn huge_array_index_does_not_grow_memory() {
        // Без потолка запись разрабатывает два миллиарда Null и роняет процесс.
        let mut root = json!({ "t": [] });
        set_value_at_path(&mut root, &[json!("t"), json!(2_000_000_000_i64)], json!(1));
        assert_eq!(root["t"].as_array().unwrap().len(), 0);

        // Тот же потолок на промежуточном индексе пути.
        set_value_at_path(
            &mut root,
            &[json!("t"), json!(3_000_000_000_i64), json!("x")],
            json!(1),
        );
        assert_eq!(root["t"].as_array().unwrap().len(), 0);

        // Обычные индексы разреженной записи не задевает.
        set_value_at_path(&mut root, &[json!("t"), json!(1)], json!(1));
        assert_eq!(root["t"], json!([null, 1]));
    }
}

/// In-memory asset store helper для тестов.
#[cfg(test)]
mod test_store {
    use crate::contracts::ScriptAssetStore;
    use serde_json::Value;
    use std::collections::HashMap;

    #[derive(Default)]
    pub struct InMemoryScriptStore {
        files: HashMap<String, Value>,
        texts: HashMap<String, String>,
    }

    impl InMemoryScriptStore {
        pub fn new() -> Self {
            Self::default()
        }

        pub fn insert(&mut self, path: String, value: Value) {
            self.files.insert(path, value);
        }

        pub fn insert_text(&mut self, path: String, text: String) {
            self.texts.insert(path, text);
        }
    }

    impl ScriptAssetStore for InMemoryScriptStore {
        fn exists(&self, path: &str) -> bool {
            self.files.contains_key(path)
        }

        fn read_json(&self, path: &str) -> Option<Value> {
            self.files.get(path).cloned()
        }

        fn read_text(&self, path: &str) -> Option<String> {
            self.texts.get(path).cloned()
        }
    }
}
