//! FFI-слой для игрового движка верхнего уровня (`GameEngine`).
//!
//! `GameEngine` — stateful объект сессии квеста. Клиент создаёт движок,
//! передав сырые JSON (config/nodes/templates/scripts) или корень квеста на
//! диске, и получает целочисленный **handle** (`u32`). Дальше все методы
//! принимают этот handle вместо opaque-объекта FRB.
//!
//! Причины перехода с `#[frb(opaque)]` на handle+registry:
//! 1. FRB 2.12.0 нестабильно не доставляет результат async-вызовов для
//!    opaque `&mut` (Rust завершается, `await` в Dart не завершается →
//!    зависание UI). Плоские аргументы/результаты (`u32`, `String`) такого
//!    бага не имеют.
//! 2. Лёгкие методы помечены `#[frb(sync)]` (выполняются без порта), тяжёлые
//!    (сериализация NodeView/SaveSlot/дельт) остаются async, чтобы не
//!    блокировать UI-поток и не повторить OOM/фриз на большом JSON.
//!
//! Poison: если Mutex движка отравлен паникой другого вызова, мы **не**
//! продолжаем работу с несогласованным состоянием — логируем факт и
//! возвращаем маркер ошибки `{"error":"engine_poisoned"}` (для
//! `Option<String>` — `Some(marker)`), который Dart превращает в
//! `GameEnginePoisonedException`.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Once;
use std::sync::{Arc, Mutex, OnceLock};

use flutter_rust_bridge::frb;
use serde_json::Value;

use mnd_core::engine::{GameEngine, GameEngineConfig, NextStep, PlatformInfo};
use mnd_core::models::{Quest, SaveSlot, SavedNode, TemplateItem};

/// Маркер ошибки: движок с этим handle был отравлен паникой и непригоден.
const POISON_MARKER: &str = "{\"error\":\"engine_poisoned\"}";
/// Маркер ошибки: handle не найден в реестре (уже dispose или никогда не создан).
const NOT_FOUND_MARKER: &str = "{\"error\":\"engine_not_found\"}";

/// Дописать строку в `/tmp/mnd_rust_panic.log` (НЕ перезаписывать: причина
/// паники не должна затираться последующим poison-сообщением).
fn append_panic_log(msg: &str) {
    use std::io::Write;
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open("/tmp/mnd_rust_panic.log")
    {
        let _ = writeln!(file, "{msg}");
    }
}

/// Установить panic hook, пишущий в файл — ловит паники в фоновых потоках FRB.
static PANIC_HOOK_INIT: Once = Once::new();
fn ensure_panic_hook() {
    PANIC_HOOK_INIT.call_once(|| {
        // На wasm хук не ставим: файла для лога там нет, а `set_hook` ещё и
        // затёр бы `console_error_panic_hook` (фича FRB `wasm-start`). Без него
        // паника ушла бы в `abort` и из браузера было бы видно только
        // `RuntimeError: unreachable` без причины.
        #[cfg(not(target_arch = "wasm32"))]
        std::panic::set_hook(Box::new(|info| {
            let msg = format!("[RUST PANIC] {info}");
            eprintln!("{msg}");
            append_panic_log(&msg);
        }));
    });
}

fn log_engine_poisoned(handle: u32) {
    let msg = format!(
        "[RUST] game_engine: handle {handle} mutex poisoned after a panic; refusing to continue"
    );
    eprintln!("{msg}");
    append_panic_log(&msg);
}

fn log_engine_panic(handle: u32, payload: &(dyn std::any::Any + Send)) {
    let detail = if let Some(s) = payload.downcast_ref::<&str>() {
        (*s).to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "(non-string panic payload)".to_string()
    };
    let msg = format!("[RUST] game_engine: handle {handle} panicked inside engine call: {detail}");
    eprintln!("{msg}");
    append_panic_log(&msg);
}

// ---------------------------------------------------------------------------
// Реестр движков
// ---------------------------------------------------------------------------

type EngineRegistry = Mutex<HashMap<u32, Arc<Mutex<GameEngine>>>>;

static NEXT_HANDLE: AtomicU32 = AtomicU32::new(1);
static ENGINES: OnceLock<EngineRegistry> = OnceLock::new();

fn registry() -> &'static EngineRegistry {
    ENGINES.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Гейт операций над одним движком (handle → mutex-«занято»).
///
/// Нужен потому, что `with_engine_detached` исполняет скрипт на КЛОНЕ движка
/// (сеть внутри `http_request` не держит `Mutex` движка и не вешает UI), а
/// потом пишет клон обратно. Два перекрывающихся асинхронных вызова на одном
/// handle пишут обратно каждый свой клон: последний затирает курсор раскрытия
/// предыдущего, и `next_item` отдаёт один и тот же ряд дважды (#211 — строки
/// «дублируются» в инвентаре, когда у детей ряда есть onAppear-скрипт:
/// `execute_behaviour` из контейнера идёт вразнобой с чередой `next_item`).
/// Гейт сериализует именно тяжёлые операции; короткие синхронные `with_engine`
/// его не берут — иначе зависший на 15 с запрос жёг бы UI-поток.
type OpGateRegistry = Mutex<HashMap<u32, Arc<Mutex<()>>>>;

static OP_GATES: OnceLock<OpGateRegistry> = OnceLock::new();

fn op_gate(handle: u32) -> Arc<Mutex<()>> {
    let mut gates = OP_GATES
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    gates
        .entry(handle)
        .or_insert_with(|| Arc::new(Mutex::new(())))
        .clone()
}

fn remove_op_gate(handle: u32) {
    OP_GATES
        .get_or_init(|| Mutex::new(HashMap::new()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .remove(&handle);
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EngineError {
    NotFound,
    Poisoned,
    /// Паника внутри вызова движка — поймана, чтобы не улететь через FFI-границу
    /// (UB) и не затереть причину.
    Panicked,
}

/// Достать движок по handle и выполнить `f` под его мьютексом.
///
/// - Poisoned: мьютекс уже отравлен предыдущей паникой — не продолжаем работу,
///   логируем и возвращаем ошибку.
/// - Panicked: `f` сам паникует — ловим panic, логируем payload, удаляем
///   сломанный движок из реестра и возвращаем ошибку.
fn with_engine<T>(handle: u32, f: impl FnOnce(&mut GameEngine) -> T) -> Result<T, EngineError> {
    let entry = registry()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .get(&handle)
        .cloned();
    let Some(entry) = entry else {
        return Err(EngineError::NotFound);
    };
    let mut guard = match entry.lock() {
        Ok(guard) => guard,
        Err(_poisoned) => {
            log_engine_poisoned(handle);
            return Err(EngineError::Poisoned);
        }
    };
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| f(&mut guard))) {
        Ok(result) => Ok(result),
        Err(payload) => {
            log_engine_panic(handle, &payload);
            drop(guard);
            // Сломанный движок больше не используем.
            registry()
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .remove(&handle);
            Err(EngineError::Panicked)
        }
    }
}

/// Вариант `with_engine` без удержания `Mutex` во время выполнения `f`.
///
/// Клонирует движок под коротким lock, выполняет `f` на клоне **без**
/// удержания мьютекса (сеть `http_request` внутри скрипта не блокирует
/// FRB-воркер и другие handle), затем атомарно записывает результат обратно.
/// Паники ловятся аналогично `with_engine`, отравленный движок удаляется.
///
/// Вся операция идёт под гейтом handle (см. `op_gate`): без него два
/// перекрывающихся detached-вызова затирают запись друг друга и движок
/// теряет уже сделанную работу (курсор раскрытия откатывался — #211).
fn with_engine_detached<T>(
    handle: u32,
    f: impl FnOnce(&mut GameEngine) -> T,
) -> Result<T, EngineError> {
    // Гейт держим до записи обратно: клон → f → запись = одна транзакция.
    let gate = op_gate(handle);
    let _gate = gate.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let entry = registry()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .get(&handle)
        .cloned();
    let Some(entry) = entry else {
        return Err(EngineError::NotFound);
    };
    // Короткий lock только для клонирования.
    let mut engine_copy = match entry.lock() {
        Ok(guard) => guard.clone(),
        Err(_poisoned) => {
            log_engine_poisoned(handle);
            return Err(EngineError::Poisoned);
        }
    };
    let result =
        match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| f(&mut engine_copy))) {
            Ok(v) => v,
            Err(payload) => {
                log_engine_panic(handle, &payload);
                registry()
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner())
                    .remove(&handle);
                remove_op_gate(handle);
                return Err(EngineError::Panicked);
            }
        };
    // Записать обратно под lock.
    let write_back = match entry.lock() {
        Ok(mut guard) => {
            *guard = engine_copy;
            Ok(result)
        }
        Err(_poisoned) => {
            log_engine_poisoned(handle);
            Err(EngineError::Poisoned)
        }
    };
    write_back
}

/// Плоский вход запуска движка.
#[derive(Debug, Clone)]
pub struct GameEngineInit {
    pub quest_id: String,
    /// JSON дескриптора квеста (`config.json`). Игнорируется, если задан `quest_root`.
    pub config_json: String,
    /// JSON массива нод (`nodes.json` → поле `nodes`). Игнорируется, если задан `quest_root`.
    pub nodes_json: String,
    /// JSON массива шаблонов (может быть `[]`). Игнорируется, если задан `quest_root`.
    pub templates_json: String,
    /// Платформа: `os` = "android"/"ios"/"web"/"linux"/... .
    pub platform_os: String,
    pub is_web: bool,
    /// Вложенные скрипты: путь → JSON-строка. Игнорируется, если задан `quest_root`.
    pub embedded_scripts: HashMap<String, String>,
    /// Корень квеста на диске (каталог документов приложения).
    /// Когда задан — движок сам читает config/nodes/templates/скрипты
    /// по требованию (без предварительного бандлинга).
    pub quest_root: Option<String>,
}

/// Создать движок сессии и вернуть его handle. Асинхронный (не `#[frb(sync)]`):
/// читает квест с диска (`from_disk`), поэтому не должен блокировать UI-поток.
///
/// Обёрнут в `catch_unwind`: паника внутри создания не должна пройти через
/// FFI-границу (UB, `panic in a function that cannot unwind` → abort).
pub fn game_engine_new(init: GameEngineInit) -> u32 {
    ensure_panic_hook();
    eprintln!(
        "[RUST] game_engine_new: entering, quest_id={}",
        init.quest_id
    );
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        // Режим «тупой клиент»: движок владеет данными, читает квест с диска.
        let engine = if let Some(root) = &init.quest_root {
            GameEngine::from_disk(&init.quest_id, root).unwrap_or_else(|| {
                // Нет config.json — падаем мягко: пустой движок без нод.
                GameEngine::new(
                    init.quest_id.clone(),
                    Quest::from_json(&Value::Null),
                    Vec::new(),
                    Vec::new(),
                    GameEngineConfig::default(),
                )
            })
        } else {
            let config_value: Value =
                serde_json::from_str(&init.config_json).unwrap_or(Value::Null);
            let config = Quest::from_json(&config_value);
            let nodes: Vec<SavedNode> = parse_array(&init.nodes_json, SavedNode::from_json);
            let templates: Vec<TemplateItem> =
                parse_array(&init.templates_json, TemplateItem::from_json);
            let embedded_scripts: HashMap<String, Value> = init
                .embedded_scripts
                .into_iter()
                .filter_map(|(k, v)| {
                    serde_json::from_str::<Value>(&v).ok().map(|mut script| {
                        mnd_core::script_format::normalize_script(&mut script);
                        (k, script)
                    })
                })
                .collect();

            GameEngine::new(
                init.quest_id.clone(),
                config,
                nodes,
                templates,
                GameEngineConfig {
                    platform: PlatformInfo {
                        os: init.platform_os,
                        is_web: init.is_web,
                    },
                    embedded_scripts,
                    asset_store: None,
                    save_store: None,
                },
            )
        };

        let handle = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
        registry()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .insert(handle, Arc::new(Mutex::new(engine)));
        handle
    }));
    match result {
        Ok(handle) => handle,
        Err(payload) => {
            let detail = if let Some(s) = payload.downcast_ref::<&str>() {
                (*s).to_string()
            } else if let Some(s) = payload.downcast_ref::<String>() {
                s.clone()
            } else {
                "(non-string panic)".to_string()
            };
            let msg = format!("[RUST] game_engine_new panicked: {detail}");
            eprintln!("{msg}");
            append_panic_log(&msg);
            // Возвращаем 0 как невалидный handle — Dart проверит и покажет ошибку.
            0
        }
    }
}

/// Удалить движок из реестра (освобождает память). Идемпотентен.
#[frb(sync)]
pub fn game_engine_dispose(handle: u32) {
    registry()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .remove(&handle);
    remove_op_gate(handle);
}

// ---------------------------------------------------------------------------
// Тяжёлые методы (async, сериализуют NodeView/SaveSlot/дельту/очередь)
// ---------------------------------------------------------------------------

/// Запустить новую игру. Возвращает JSON `NodeView` либо null.
///
/// Выполняется через `with_engine_detached`: сеть `http_request` внутри
/// `onNodeEnter` не держит `Mutex<GameEngine>` — FRB-воркер и UI не фризятся.
pub fn game_engine_start_new(handle: u32, start_node_id: Option<String>) -> Option<String> {
    ensure_panic_hook();
    match with_engine_detached(handle, |engine| engine.start_new(start_node_id.as_deref())) {
        Ok(Some(view)) => Some(node_view_to_json(&view)),
        Ok(None) => None,
        Err(EngineError::Poisoned | EngineError::Panicked) => Some(POISON_MARKER.to_string()),
        Err(EngineError::NotFound) => Some(NOT_FOUND_MARKER.to_string()),
    }
}

/// Запустить из сейва (JSON SaveSlot). Возвращает JSON `NodeView` либо null.
pub fn game_engine_start_from_save(handle: u32, save_json: String) -> Option<String> {
    ensure_panic_hook();
    match with_engine_detached(handle, |engine| {
        let save = SaveSlot::from_json(&serde_json::from_str(&save_json).unwrap_or_default());
        engine
            .start_from_save(&save)
            .map(|view| node_view_to_json(&view))
    }) {
        Ok(result) => result,
        Err(EngineError::Poisoned | EngineError::Panicked) => Some(POISON_MARKER.to_string()),
        Err(EngineError::NotFound) => Some(NOT_FOUND_MARKER.to_string()),
    }
}

/// Загрузить ноду напрямую. Возвращает JSON `NodeView` либо null.
pub fn game_engine_load_node(handle: u32, node_id: String) -> Option<String> {
    ensure_panic_hook();
    match with_engine_detached(handle, |engine| {
        engine
            .load_node(&node_id)
            .map(|view| node_view_to_json(&view))
    }) {
        Ok(result) => result,
        Err(EngineError::Poisoned | EngineError::Panicked) => Some(POISON_MARKER.to_string()),
        Err(EngineError::NotFound) => Some(NOT_FOUND_MARKER.to_string()),
    }
}

/// Снапшот текущего состояния (для автосейва): JSON
/// `{currentNodeId, variables, tables}`.
pub fn game_engine_snapshot(handle: u32) -> String {
    ensure_panic_hook();
    match with_engine(handle, |engine| {
        let snap = engine.current_state_snapshot();
        serde_json::json!({
            "currentNodeId": snap.current_node_id,
            "variables": snap.variables,
            "tables": snap.tables,
        })
        .to_string()
    }) {
        Ok(result) => result,
        Err(EngineError::Poisoned | EngineError::Panicked) => POISON_MARKER.to_string(),
        Err(EngineError::NotFound) => NOT_FOUND_MARKER.to_string(),
    }
}

/// Сохранить текущее состояние движка в произвольный слот. Возвращает JSON
/// `SaveSlot` либо null (нет хранилища/игра не начата).
pub fn game_engine_save_slot(handle: u32, slot_name: String) -> Option<String> {
    ensure_panic_hook();
    match with_engine(handle, |engine| {
        engine
            .save_current_slot(&slot_name)
            .map(|s| s.to_json().to_string())
    }) {
        Ok(result) => result,
        Err(EngineError::Poisoned | EngineError::Panicked) => Some(POISON_MARKER.to_string()),
        Err(EngineError::NotFound) => Some(NOT_FOUND_MARKER.to_string()),
    }
}

/// Собрать `SaveSlot` из текущего состояния без записи в хранилище.
///
/// `current_node_id` переопределяет текущую ноду (пустая строка — оставить
/// текущую). Используется клиентом для восстановления сессии движка
/// (например, пересоздание после редактирования) без знания внутренней
/// сериализации сейва.
pub fn game_engine_to_save_slot(
    handle: u32,
    slot_name: String,
    current_node_id: String,
) -> Option<String> {
    ensure_panic_hook();
    match with_engine(handle, |engine| {
        let slot = if current_node_id.is_empty() {
            engine.to_save_slot(&slot_name)?
        } else {
            engine.to_save_slot_at(&slot_name, &current_node_id)?
        };
        Some(slot.to_json().to_string())
    }) {
        Ok(result) => result,
        Err(EngineError::Poisoned | EngineError::Panicked) => Some(POISON_MARKER.to_string()),
        Err(EngineError::NotFound) => Some(NOT_FOUND_MARKER.to_string()),
    }
}

/// Автосохранение: перезаписывает слот `_autosave`. Возвращает JSON `SaveSlot` либо null.
pub fn game_engine_perform_autosave(handle: u32) -> Option<String> {
    ensure_panic_hook();
    match with_engine(handle, |engine| {
        engine.perform_autosave().map(|s| s.to_json().to_string())
    }) {
        Ok(result) => result,
        Err(EngineError::Poisoned | EngineError::Panicked) => Some(POISON_MARKER.to_string()),
        Err(EngineError::NotFound) => Some(NOT_FOUND_MARKER.to_string()),
    }
}

/// Список сейв-слотов квеста: JSON-массив `SaveSlot`.
pub fn game_engine_list_saves(handle: u32) -> String {
    ensure_panic_hook();
    match with_engine(handle, |engine| {
        serde_json::json!(engine
            .list_saves()
            .iter()
            .map(|s| s.to_json())
            .collect::<Vec<_>>())
        .to_string()
    }) {
        Ok(result) => result,
        Err(EngineError::Poisoned | EngineError::Panicked) => POISON_MARKER.to_string(),
        Err(EngineError::NotFound) => NOT_FOUND_MARKER.to_string(),
    }
}

/// Прочитать конкретный слот: JSON `SaveSlot` либо null.
pub fn game_engine_read_save(handle: u32, slot_id: String) -> Option<String> {
    ensure_panic_hook();
    match with_engine(handle, |engine| {
        engine.read_save(&slot_id).map(|s| s.to_json().to_string())
    }) {
        Ok(result) => result,
        Err(EngineError::Poisoned | EngineError::Panicked) => Some(POISON_MARKER.to_string()),
        Err(EngineError::NotFound) => Some(NOT_FOUND_MARKER.to_string()),
    }
}

/// Собрать и очистить дельту изменённого состояния. Возвращает JSON
/// `{variables, tables}` (как в `game_engine_snapshot`, но только изменённое).
pub fn game_engine_drain_state_delta(handle: u32) -> String {
    ensure_panic_hook();
    match with_engine(handle, |engine| {
        let delta = engine.drain_state_delta();
        serde_json::json!({
            "variables": delta.variables,
            "tables": delta.tables,
        })
        .to_string()
    }) {
        Ok(result) => result,
        Err(EngineError::Poisoned | EngineError::Panicked) => POISON_MARKER.to_string(),
        Err(EngineError::NotFound) => NOT_FOUND_MARKER.to_string(),
    }
}

/// Собрать и очистить аудио-команды, накопленные скриптами. Возвращает JSON
/// `{"commands": [...]}` — очередь команд в каноническом формате клиента
/// (`playSound`/`stopSound`/`playMusic`/`stopMusic`/`pauseResume`/
/// `fadeOut`/`fadeIn`). Команды применяются ПО ПОРЯДКУ — несколько звуков
/// за одно исполнение скрипта больше не теряются.
pub fn game_engine_drain_audio(handle: u32) -> String {
    ensure_panic_hook();
    match with_engine(handle, |engine| {
        let delta = engine.drain_audio_commands();
        serde_json::json!({"commands": delta.commands}).to_string()
    }) {
        Ok(result) => result,
        Err(EngineError::Poisoned | EngineError::Panicked) => POISON_MARKER.to_string(),
        Err(EngineError::NotFound) => NOT_FOUND_MARKER.to_string(),
    }
}

/// Собрать и очистить внешние системные команды (`open_link` и т.п.).
/// Возвращает JSON `{"commands": [...]}` — очередь команд, которые выполняет
/// клиент (например, открытие ссылки через url_launcher).
pub fn game_engine_drain_external(handle: u32) -> String {
    ensure_panic_hook();
    match with_engine(handle, |engine| {
        let commands = engine.drain_external_commands();
        serde_json::json!({"commands": commands}).to_string()
    }) {
        Ok(result) => result,
        Err(EngineError::Poisoned | EngineError::Panicked) => POISON_MARKER.to_string(),
        Err(EngineError::NotFound) => NOT_FOUND_MARKER.to_string(),
    }
}

/// Слить очередь шагов пейсинга от блоков `wait`. Возвращает JSON-массив
/// шагов `{ms, variables, tables, audio}`: клиент публикует снапшот
/// промежуточного состояния + проигрывает аудио шага, затем ждёт `ms`
/// (паритет: эталон мутировал state между `await Future.delayed`, и
/// условные видимости картинок видели каждый промежуточный кадр).
/// Команды без снапшотов (старые записи) приходят с пустыми полями.
pub fn game_engine_drain_delay_queue(handle: u32) -> String {
    ensure_panic_hook();
    match with_engine(handle, |engine| {
        let steps = engine.drain_delay_steps();
        serde_json::to_string(&steps).unwrap_or_else(|e| {
            eprintln!("[RUST] drain_delay_queue: serde error: {e}");
            "[]".into()
        })
    }) {
        Ok(result) => result,
        Err(EngineError::Poisoned | EngineError::Panicked) => POISON_MARKER.to_string(),
        Err(EngineError::NotFound) => NOT_FOUND_MARKER.to_string(),
    }
}

// ---------------------------------------------------------------------------
// Лёгкие методы: some sync (tiny JSON, no I/O), some async (may trigger
// http_request with 15 s timeout → must not block UI thread).
// ---------------------------------------------------------------------------

/// Раскрыть следующий айтем. Возвращает JSON `NextStep`.
///
/// Async (без `#[frb(sync)]`): выполняется в worker-потоке FRB, а не на
/// UI-потоке. Детaч `Mutex` — `onContentAppear` с `http_request` не блокирует
/// FRB-воркер на 15с.
pub fn game_engine_next_item(handle: u32) -> String {
    ensure_panic_hook();
    match with_engine_detached(handle, |engine| match engine.next_item() {
        NextStep::Item(item) => {
            serde_json::json!({"kind": "item", "item": (*item).to_json()}).to_string()
        }
        NextStep::Transition(node) => {
            serde_json::json!({"kind": "transition", "node": node}).to_string()
        }
        NextStep::Done => serde_json::json!({"kind": "done"}).to_string(),
    }) {
        Ok(result) => result,
        Err(EngineError::Poisoned | EngineError::Panicked) => POISON_MARKER.to_string(),
        Err(EngineError::NotFound) => NOT_FOUND_MARKER.to_string(),
    }
}

/// Проверить видимость айтема по behaviours (без side-effects).
/// `item_json` — JSON `ContentItem`. Возвращает `"true"` или `"false"`.
/// `allow_mutation` — разрешить `set_variable` внутри condition-блоков
/// (true для первого прохода, false для реактивной переоценки).
#[frb(sync)]
pub fn game_engine_evaluate_visibility(
    handle: u32,
    item_json: String,
    allow_mutation: bool,
) -> String {
    ensure_panic_hook();
    match with_engine(handle, |engine| {
        let item = mnd_core::models::ContentItem::from_json(
            &serde_json::from_str(&item_json).unwrap_or_default(),
        );
        engine.evaluate_visibility(&item, allow_mutation)
    }) {
        Ok(visible) => visible.to_string(),
        Err(EngineError::Poisoned | EngineError::Panicked) => POISON_MARKER.to_string(),
        Err(EngineError::NotFound) => NOT_FOUND_MARKER.to_string(),
    }
}

/// Синхронизировать внешние переменные в состояние движка (pacing-снапшот).
/// Используется клиентом для передачи промежуточных значений из `_internal_delay_queue`
/// в движок, чтобы `evaluate_visibility` видел корректные кадры анимации.
#[frb(sync)]
pub fn game_engine_apply_external_variables(handle: u32, variables_json: String) {
    ensure_panic_hook();
    match with_engine(handle, |engine| {
        let map: serde_json::Map<String, serde_json::Value> =
            serde_json::from_str(&variables_json).unwrap_or_default();
        engine.apply_external_variables(&map);
    }) {
        Ok(()) => {}
        Err(e) => eprintln!("[RUST] apply_external_variables: error {e:?}"),
    }
}

/// Восстановить переменные движка после pacing-цикла.
/// Откатывает изменения, сделанные через `game_engine_apply_external_variables`,
/// возвращая движок к реальному состоянию до применения промежуточных снапшотов.
#[frb(sync)]
pub fn game_engine_restore_after_pacing(handle: u32) {
    ensure_panic_hook();
    match with_engine(handle, |engine| {
        engine.restore_after_pacing();
    }) {
        Ok(()) => {}
        Err(e) => eprintln!("[RUST] restore_after_pacing: error {e:?}"),
    }
}

/// Установить переменную напрямую в состояние движка (минуя скрипты).
///
/// Используется для мутаций, инициированных Dart-клиентом
/// (например, сохранение значения input поля).
/// `key` — имя переменной, `value_json` — JSON-сериализованное значение.
#[frb(sync)]
pub fn game_engine_set_state_variable(handle: u32, key: String, value_json: String) {
    ensure_panic_hook();
    match with_engine(handle, |engine| {
        let value: serde_json::Value =
            serde_json::from_str(&value_json).unwrap_or(serde_json::Value::Null);
        engine.set_state_variable(&key, value);
    }) {
        Ok(()) => {}
        Err(e) => eprintln!("[RUST] set_state_variable: error {e:?}"),
    }
}

/// Забрать переход, который диспетчер `onDataChange` выдал вне границы шага.
///
/// Прямая мутация из Dart (`game_engine_set_state_variable`) не имеет канала
/// возврата: переход остаётся висеть в движке до ближайшего шага. Клиент
/// обязан опросить его сразу после мутации, иначе смена ноды дождётся первого
/// действия игрока. Пустая строка — перехода нет.
#[frb(sync)]
pub fn game_engine_take_pending_transition(handle: u32) -> String {
    ensure_panic_hook();
    with_engine(handle, |engine| {
        engine.take_pending_transition().unwrap_or_default()
    })
    .unwrap_or_default()
}

/// Выполнить поведение айтема (action/reveal).
/// `item_json` — JSON `ContentItem`, `event` — тип события (`"onPress"`/
/// `"onReveal"`/`"onSubmit"`). Возвращает id узла перехода либо пустую
/// строку (перехода нет).
///
/// Async + detached: `with_engine_detached` не держит `Mutex` во время
/// `http_request` (15с) — UI не фризится при нажатии.
pub fn game_engine_execute_behaviour(handle: u32, item_json: String, event: String) -> String {
    ensure_panic_hook();
    match with_engine_detached(handle, |engine| {
        let item = mnd_core::models::ContentItem::from_json(
            &serde_json::from_str(&item_json).unwrap_or_default(),
        );
        engine.execute_behaviour(&item, &event).unwrap_or_default()
    }) {
        Ok(result) => result,
        Err(EngineError::Poisoned | EngineError::Panicked) => POISON_MARKER.to_string(),
        Err(EngineError::NotFound) => NOT_FOUND_MARKER.to_string(),
    }
}

/// Обработать нажатие. `item_json` — JSON `ContentItem`.
/// Возвращает id узла перехода либо пустую строку (перехода нет).
///
/// Async + detached: критично для онлайн-блоков — нажатие не должно
/// висеть внутри `Mutex<GameEngine>`.
pub fn game_engine_handle_interaction(
    handle: u32,
    item_json: String,
    trigger_ref: String,
) -> String {
    ensure_panic_hook();
    match with_engine_detached(handle, |engine| {
        let item = mnd_core::models::ContentItem::from_json(
            &serde_json::from_str(&item_json).unwrap_or_default(),
        );
        engine
            .handle_interaction(&item, &trigger_ref)
            .unwrap_or_default()
    }) {
        Ok(result) => result,
        Err(EngineError::Poisoned | EngineError::Panicked) => POISON_MARKER.to_string(),
        Err(EngineError::NotFound) => NOT_FOUND_MARKER.to_string(),
    }
}

/// Резолвить целевой узел (`=expression`). Возвращает id узла либо пустую
/// строку (не резолвится).
#[frb(sync)]
pub fn game_engine_resolve_target(handle: u32, raw: String) -> String {
    ensure_panic_hook();
    match with_engine(handle, |engine| {
        engine.resolve_target_node_id(&raw).unwrap_or_default()
    }) {
        Ok(result) => result,
        Err(EngineError::Poisoned | EngineError::Panicked) => POISON_MARKER.to_string(),
        Err(EngineError::NotFound) => NOT_FOUND_MARKER.to_string(),
    }
}

/// Вычислить выражение. Возвращает JSON-строку результата.
#[frb(sync)]
pub fn game_engine_evaluate(handle: u32, input_json: String) -> String {
    ensure_panic_hook();
    match with_engine(handle, |engine| engine.evaluate_expression(&input_json)) {
        Ok(result) => result,
        Err(EngineError::Poisoned | EngineError::Panicked) => POISON_MARKER.to_string(),
        Err(EngineError::NotFound) => NOT_FOUND_MARKER.to_string(),
    }
}

/// Один тик таймера: выполнить запланированный re-invoke функции
/// (`script_path`, `entry`). Возвращает JSON `{"ran": bool, "transition": ...}`.
///
/// Async + detached: таймерный скрипт может содержать `http_request`.
pub fn game_engine_run_scheduled_timer(handle: u32, script_path: String, entry: String) -> String {
    ensure_panic_hook();
    match with_engine_detached(handle, |engine| {
        let pending = engine
            .pending_timers()
            .iter()
            .any(|t| t.script_path == script_path && t.entry == entry);
        let transition = engine.run_scheduled_timer(&script_path, &entry);
        serde_json::json!({
            "ran": pending,
            "transition": transition,
        })
        .to_string()
    }) {
        Ok(result) => result,
        Err(EngineError::Poisoned | EngineError::Panicked) => POISON_MARKER.to_string(),
        Err(EngineError::NotFound) => NOT_FOUND_MARKER.to_string(),
    }
}

/// Удалить слот по id.
#[frb(sync)]
pub fn game_engine_delete_save(handle: u32, slot_id: String) {
    ensure_panic_hook();
    // Возврат void: ошибку poison логируем, но не можем доставить в Dart.
    if let Err(error) = with_engine(handle, |engine| engine.delete_save(&slot_id)) {
        match error {
            EngineError::Poisoned => log_engine_poisoned(handle),
            EngineError::NotFound | EngineError::Panicked => {}
        }
    }
}

/// Список всех типов блоков скриптового движка.
///
/// Не требует движка (статический реестр). Возвращает JSON-массив
/// `[{name: "assign_variable", aliases: ["создать_переменную", ...]}, ...]`.
/// Используется редактором для построения UI-списка блоков без правок Dart.
#[frb(sync)]
pub fn game_engine_list_block_types() -> String {
    mnd_core::blocks::list_block_types_json().to_string()
}

// ---------------------------------------------------------------------------
// Вспомогательные
// ---------------------------------------------------------------------------

fn parse_array<T>(json: &str, f: impl Fn(&Value) -> T) -> Vec<T> {
    let v: Value = serde_json::from_str(json).unwrap_or(Value::Null);
    match v {
        Value::Array(arr) => arr.iter().map(f).collect(),
        Value::Object(obj) => obj
            .get("nodes")
            .and_then(Value::as_array)
            .map(|a| a.iter().map(f).collect())
            .unwrap_or_default(),
        _ => Vec::new(),
    }
}

fn node_view_to_json(view: &mnd_core::engine::NodeView) -> String {
    let node_json: Value = serde_json::from_str(&view.node_json).unwrap_or(Value::Null);
    serde_json::json!({
        "nodeId": view.node_id,
        "title": view.title,
        "presentationId": view.presentation_id,
        "node": node_json,
        "revealedItems": view.revealed_items.iter().map(|i| i.to_json()).collect::<Vec<_>>(),
        "hudPanels": view.hud_panels.iter().map(|i| i.to_json()).collect::<Vec<_>>(),
        "backgroundImageId": view.background_image_id,
        "backgroundVideoId": view.background_video_id,
        "backgroundAudio": view.background_audio.as_ref().map(|a| {
            serde_json::json!({ "audioId": a.audio_id, "volume": a.volume })
        }),
        "timer": view.timer.as_ref().map(|t| {
            serde_json::json!({ "duration": t.duration, "defaultActionNodeId": t.default_action_node_id })
        }),
        "transition": view.transition,
    })
    .to_string()
}

// ---------------------------------------------------------------------------
// Тесты реестра (poison-путь)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn minimal_init(quest_id: &str) -> GameEngineInit {
        GameEngineInit {
            quest_id: quest_id.into(),
            config_json: serde_json::json!({
                "id": quest_id, "title": "Q", "version": "1.0.0", "startNodeId": "n1"
            })
            .to_string(),
            nodes_json: serde_json::json!({
                "nodes": [{
                    "id": "n1", "title": "Start",
                    "content": { "items": [{"type": "text", "id": "a", "text": "hello"}] }
                }]
            })
            .to_string(),
            templates_json: "[]".into(),
            platform_os: "linux".into(),
            is_web: false,
            embedded_scripts: HashMap::new(),
            quest_root: None,
        }
    }

    #[test]
    fn poisoned_engine_returns_marker_instead_of_continuing() {
        let handle = game_engine_new(minimal_init("q1"));

        // Отравляем мьютекс движка паникой, удерживающей lock.
        {
            let entry = registry().lock().unwrap().get(&handle).unwrap().clone();
            let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                let _guard = entry.lock().unwrap();
                panic!("poison on purpose");
            }));
        }

        // Мьютекс отравлен: вызовы не продолжают работу, а возвращают маркер.
        assert_eq!(game_engine_next_item(handle), POISON_MARKER);
        assert_eq!(
            game_engine_start_new(handle, None),
            Some(POISON_MARKER.to_string())
        );

        game_engine_dispose(handle);
    }

    /// Нода с `items` однотипных текстовых айтемов: черед `next_item` проходит
    /// их все и возвращает `done`.
    fn wide_init(quest_id: &str, items: usize) -> GameEngineInit {
        let list: Vec<Value> = (0..items)
            .map(|i| serde_json::json!({ "type": "text", "id": format!("row-{i}"), "text": "t" }))
            .collect();
        GameEngineInit {
            quest_id: quest_id.into(),
            config_json: serde_json::json!({
                "id": quest_id, "title": "Q", "version": "1.0.0", "startNodeId": "n1"
            })
            .to_string(),
            nodes_json: serde_json::json!({
                "nodes": [{
                    "id": "n1", "title": "Start",
                    "content": { "items": list }
                }]
            })
            .to_string(),
            templates_json: "[]".into(),
            platform_os: "linux".into(),
            is_web: false,
            embedded_scripts: HashMap::new(),
            quest_root: None,
        }
    }

    /// `{"kind":"item","item":{"id":…}}` → Some(id); `done`/`transition` → None.
    fn emitted_id(result: &str) -> Option<String> {
        let value: Value = serde_json::from_str(result).ok()?;
        if value.get("kind")?.as_str()? != "item" {
            return None;
        }
        value
            .get("item")?
            .get("id")?
            .as_str()
            .map(|s| s.to_string())
    }

    #[test]
    fn overlapping_next_item_calls_never_emit_the_same_row_twice() {
        // #211 «дублируются ряды в инвентаре»: `with_engine_detached` пишет
        // обратно свой клон движка. Два перекрывающихся вызова без гейта
        // стартуют с одного курсора, и второй затирает прогресс первого —
        // тот же ряд отдаётся повторно, а часть рядов теряется.
        const ROWS: usize = 300;
        let handle = game_engine_new(wide_init("q_reveal_race", ROWS));
        game_engine_start_new(handle, None).expect("нода n1 должна запуститься");
        let emitted: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));

        let mut workers = Vec::new();
        for _ in 0..2 {
            let emitted = emitted.clone();
            workers.push(std::thread::spawn(move || loop {
                let result = game_engine_next_item(handle);
                let Some(id) = emitted_id(&result) else {
                    break;
                };
                emitted.lock().unwrap().push(id);
            }));
        }
        for worker in workers {
            worker.join().unwrap();
        }

        let ids = emitted.lock().unwrap();
        let unique: std::collections::HashSet<&String> = ids.iter().collect();
        assert_eq!(
            unique.len(),
            ids.len(),
            "движок отдал {} рядов, уникальных {}, дубли = потерянный курсор раскрытия",
            ids.len(),
            unique.len()
        );
        assert_eq!(
            ids.len(),
            ROWS,
            "ряды потеряны: движок отдал меньше, чем их в ноде"
        );
        game_engine_dispose(handle);
    }

    #[test]
    fn execute_behaviour_does_not_rewind_the_reveal_cursor() {
        // Тот же класс, но в форме реального экрана: `next_item` раскрывает
        // строку за строкой, а `GameContainerWidget` параллельно крутит
        // onAppear-скрипты детей через `execute_behaviour`. Второй вызов
        // ничего не раскрывает, но пишет обратно клон со СТАРЫМ курсором —
        // ряд выходит дважды (у тестера и «троился»).
        const ROWS: usize = 300;
        let handle = game_engine_new(wide_init("q_behaviour_race", ROWS));
        game_engine_start_new(handle, None).expect("нода n1 должна запуститься");
        let emitted: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));

        let revealer = {
            let emitted = emitted.clone();
            std::thread::spawn(move || loop {
                let result = game_engine_next_item(handle);
                let Some(id) = emitted_id(&result) else {
                    break;
                };
                emitted.lock().unwrap().push(id);
            })
        };
        let behaviour = std::thread::spawn(move || {
            let item = serde_json::json!({ "type": "text", "id": "row-1" }).to_string();
            for _ in 0..400 {
                game_engine_execute_behaviour(handle, item.clone(), "onReveal".to_string());
            }
        });

        revealer.join().unwrap();
        behaviour.join().unwrap();

        let ids = emitted.lock().unwrap();
        let unique: std::collections::HashSet<&String> = ids.iter().collect();
        assert_eq!(
            unique.len(),
            ids.len(),
            "onAppear-скрипт откатил курсор раскрытия: {} рядов, уникальных {}",
            ids.len(),
            unique.len()
        );
        assert_eq!(
            ids.len(),
            ROWS,
            "часть рядов не раскрылась вовсе (потеря обновления движка)"
        );
        game_engine_dispose(handle);
    }
}
