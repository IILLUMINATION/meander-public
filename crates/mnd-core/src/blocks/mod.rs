//! Реестр блоков скриптового движка.
//!
//! Каждый тип блока — отдельный модуль, реализующий [`BlockHandler`].
//! Новый блок добавляется в три шага:
//! 1. Создать файл `blocks/my_block.rs`
//! 2. Реализовать `BlockHandler` для своего типа
//! 3. Добавить запись в `registry()`
//!
//! Ядро (`executor.rs`) больше не содержит гигантского `match` —
//! только диспетчеризацию через реестр.

use std::sync::{Arc, Mutex};

use serde_json::{Map, Value};

use crate::executor::{
    ExecutionController, ExecutorError, ScriptExecutor, evaluate_expression, value_to_string,
};
use crate::expression::to_num;
use crate::lua::LuaSession;
use crate::runtime::ScriptRuntime;

// ---------------------------------------------------------------------------
// Modules
// ---------------------------------------------------------------------------

mod assign_variable;
mod audio;
mod call_function;
mod call_lua;
mod call_script;
mod comment;
mod condition;
mod crossfade;
mod for_each;
mod go_to_node;
mod http_request;
mod open_link;
mod save_operation;
mod set_blur;
mod set_image;
mod set_top_panel;
// pub(crate): валидатор скриптов сверяет режим с тем же списком, что и блок.
pub(crate) mod set_visible;
mod set_volume;
mod table_operation;
mod wait_block;
mod while_block;

// ---------------------------------------------------------------------------
// Context
// ---------------------------------------------------------------------------

/// Контекст исполнения одного блока: все необходимые ссылки и хелперы.
pub struct BlockContext<'a> {
    /// Исполнитель (для доступа к `execute_block_recursively`, `log`, ленивой
    /// загрузке скриптов и т.д.).
    pub executor: &'a ScriptExecutor,
    /// JSON-представление блока (прямой доступ к полям).
    pub block: &'a Map<String, Value>,
    /// Мутабельное состояние скриптов (переменные, таблицы, dirty-трекинг).
    pub game_state: &'a mut dyn ScriptRuntime,
    /// Контроллер исполнения (лимит шагов, стек вызовов, wait-таймеры).
    pub controller: &'a mut ExecutionController,
    /// ID квеста (для резолва вложенных скриптов по путям).
    pub quest_id: &'a str,
    /// Lazily created Lua session (shared across blocks in same script).
    pub lua: &'a mut Option<Arc<Mutex<LuaSession>>>,
}

impl<'a> BlockContext<'a> {
    /// Рекурсивно исполнить вложенные блоки (например, `children` у
    /// `crossfade` или `then_blocks`/`else_blocks` у `condition`).
    pub fn execute_children(
        &mut self,
        children: Vec<Value>,
    ) -> Result<Option<String>, ExecutorError> {
        for child in children {
            if let Some(child_map) = child.as_object()
                && let Some(res) = self.executor.execute_block_recursively(
                    child_map,
                    self.game_state,
                    self.controller,
                    self.quest_id,
                    self.lua,
                )?
            {
                return Ok(Some(res));
            }
        }
        Ok(None)
    }

    /// Вычислить выражение из поля блока.
    pub fn eval_expr(&mut self, raw: Option<&Value>) -> Value {
        evaluate_expression(raw.cloned(), self.game_state)
    }

    /// Прочитать строковое поле блока (с фоллбэком).
    pub fn string_field(&self, keys: &[&str], default: &str) -> String {
        for k in keys {
            if let Some(v) = self.block.get(*k) {
                return value_to_string(v);
            }
        }
        default.to_string()
    }

    /// Прочитать числовое поле блока как f64.
    pub fn num_field(&mut self, keys: &[&str], default: f64) -> f64 {
        for k in keys {
            if let Some(v) = self.block.get(*k) {
                if let Some(n) = v.as_f64() {
                    return n;
                }
                let evaluated = evaluate_expression(Some(v.clone()), self.game_state);
                if let Some(n) = to_num(&evaluated) {
                    return n;
                }
            }
        }
        default
    }

    /// Вычислить громкость (f64 0.0–1.0).
    pub fn eval_volume(&mut self, default: f64) -> f64 {
        let raw = self
            .block
            .get("volume")
            .cloned()
            .unwrap_or(serde_json::json!(default));
        let evaluated = self.eval_expr(Some(&raw));
        evaluated
            .as_f64()
            .or_else(|| value_to_string(&evaluated).parse::<f64>().ok())
            .unwrap_or(default)
            .clamp(0.0, 1.0)
    }
}

// ---------------------------------------------------------------------------
// Trait
// ---------------------------------------------------------------------------

/// Обработчик одного типа блока скрипта.
///
/// Каждый тип блока (`assign_variable`, `condition`, …) реализует этот трейт.
/// Сигнатура совпадает с бывшим `match`-рукавом в `execute_block_recursively`.
pub trait BlockHandler: Send + Sync {
    /// Имя типа блока (ключ поля `type` в JSON).
    fn block_type(&self) -> &'static str;

    /// Исполнить блок. Возвращает:
    /// - `Ok(None)` — блок выполнен, перехода нет.
    /// - `Ok(Some(node_id))` — блок вызвал переход (`go_to_node`).
    /// - `Err(...)` — ошибка исполнения.
    fn execute(&self, ctx: &mut BlockContext<'_>) -> Result<Option<String>, ExecutorError>;
}

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

/// Категория блока для UI-группировки (редактор).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BlockCategory {
    Variable,
    Data,
    Flow,
    Script,
    Audio,
    Network,
    Comment,
}

impl BlockCategory {
    pub fn as_str(&self) -> &'static str {
        match self {
            BlockCategory::Variable => "variable",
            BlockCategory::Data => "data",
            BlockCategory::Flow => "flow",
            BlockCategory::Script => "script",
            BlockCategory::Audio => "audio",
            BlockCategory::Network => "network",
            BlockCategory::Comment => "comment",
        }
    }
}

type HandlerMap = Vec<(BlockInfo, Box<dyn BlockHandler>)>;

/// Публичное описание блока — для `mnd-cli quest spec` и справки.
///
/// Собирается из того же реестра, что и исполнение, поэтому список не может
/// разойтись с реально поддерживаемыми блоками.
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BlockCatalogEntry {
    pub name: &'static str,
    pub title: &'static str,
    pub aliases: &'static [&'static str],
    pub category: &'static str,
}

/// Все блоки скриптов, которые понимает движок.
pub fn catalog() -> Vec<BlockCatalogEntry> {
    registry()
        .iter()
        .map(|(info, _)| BlockCatalogEntry {
            name: info.name,
            title: info.display_name,
            aliases: info.aliases,
            category: info.category.as_str(),
        })
        .collect()
}

/// Метаданные блока для UI редактора.
struct BlockInfo {
    name: &'static str,
    display_name: &'static str,
    aliases: &'static [&'static str],
    category: BlockCategory,
}

macro_rules! block {
    ($name:expr, $display:expr, $aliases:expr, $category:ident, $handler:expr) => {
        (
            BlockInfo {
                name: $name,
                display_name: $display,
                aliases: $aliases,
                category: BlockCategory::$category,
            },
            Box::new($handler),
        )
    };
}

/// Все зарегистрированные обработчики блоков.
///
/// Каждый элемент: `(BlockInfo, handler)`.
/// Алиасы — русские имена и вариации (например, `"задержка"` для `"wait"`).
fn registry() -> &'static HandlerMap {
    static REG: std::sync::OnceLock<HandlerMap> = std::sync::OnceLock::new();
    REG.get_or_init(|| {
        vec![
            block!(
                "assign_variable",
                "Переменная",
                &["создать_переменную", "изменить_переменную"],
                Variable,
                assign_variable::AssignVariable
            ),
            block!(
                "table_operation",
                "Данные",
                &[],
                Data,
                table_operation::TableOperation
            ),
            block!(
                "set_image",
                "Сменить картинку",
                &[],
                Data,
                set_image::SetImage
            ),
            block!(
                "set_visible",
                "Скрыть / убрать / показать",
                &["видимость"],
                Data,
                set_visible::SetVisible
            ),
            block!(
                "condition",
                "Условие",
                &["условие"],
                Flow,
                condition::Condition
            ),
            block!("go_to_node", "Переход", &[], Flow, go_to_node::GoToNode),
            block!("wait", "Задержка", &["задержка"], Flow, wait_block::Wait),
            block!(
                "for_each",
                "Цикл (таблица)",
                &["при_каждом"],
                Flow,
                for_each::ForEach
            ),
            block!(
                "while",
                "Цикл (пока)",
                &["while_loop", "пока"],
                Flow,
                while_block::WhileLoop
            ),
            block!(
                "call_script",
                "Скрипт",
                &[],
                Script,
                call_script::CallScript
            ),
            block!(
                "call_function",
                "Функция",
                &[],
                Script,
                call_function::CallFunction
            ),
            block!("call_lua", "Lua", &[], Script, call_lua::CallLua),
            block!(
                "set_top_panel",
                "Верхняя панель",
                &["верхняя_панель", "set_panel"],
                Data,
                set_top_panel::SetTopPanel
            ),
            block!("set_volume", "Громкость", &[], Audio, set_volume::SetVolume),
            block!("set_blur", "Размытие", &[], Audio, set_blur::SetBlur),
            block!("play_sound", "Звук", &[], Audio, audio::PlaySound),
            block!("stop_sound", "Стоп звук", &[], Audio, audio::StopSound),
            block!("play_music", "Музыка", &[], Audio, audio::PlayMusic),
            block!("stop_music", "Стоп музыка", &[], Audio, audio::StopMusic),
            block!("pause_resume", "Пауза", &[], Audio, audio::PauseResume),
            block!("crossfade", "Кроссфейд", &[], Audio, crossfade::Crossfade),
            block!(
                "save_operation",
                "Сохранения",
                &["save", "сохранение"],
                Data,
                save_operation::SaveOperation
            ),
            block!(
                "open_link",
                "Открыть ссылку",
                &[],
                Network,
                open_link::OpenLink
            ),
            block!(
                "http_request",
                "HTTP-запрос",
                &[],
                Network,
                http_request::HttpRequest
            ),
            block!(
                "comment",
                "Комментарий",
                &["комментарий"],
                Comment,
                comment::Comment
            ),
        ]
    })
}

/// Найти обработчик по имени типа блока.
/// Человекочитаемое имя типа блока («Переход») для текстов диагностики.
pub fn display_name(block_type: &str) -> Option<&'static str> {
    for (info, _) in registry() {
        if info.name == block_type || info.aliases.contains(&block_type) {
            return Some(info.display_name);
        }
    }
    None
}

pub fn find_handler(block_type: &str) -> Option<&'static dyn BlockHandler> {
    for (info, handler) in registry() {
        if info.name == block_type || info.aliases.contains(&block_type) {
            return Some(handler.as_ref());
        }
    }
    None
}

/// Все зарегистрированные типы блоков в виде JSON.
///
/// Возвращает `[{name, displayName, aliases, category}, ...]`.
/// Используется редактором для авто-построения UI-списка блоков без правок Dart.
pub fn list_block_types_json() -> serde_json::Value {
    let list: Vec<serde_json::Value> = registry()
        .iter()
        .map(|(info, _)| {
            serde_json::json!({
                "name": info.name,
                "displayName": info.display_name,
                "aliases": info.aliases,
                "category": info.category.as_str(),
            })
        })
        .collect();
    serde_json::Value::Array(list)
}

/// Выполнить блок через реестр обработчиков.
///
/// Вызывается из `ScriptExecutor::execute_block_recursively` вместо
/// гигантского `match`.
pub fn dispatch(ctx: &mut BlockContext<'_>) -> Result<Option<String>, ExecutorError> {
    ctx.controller.tick()?;

    let block_type = ctx
        .block
        .get("type")
        .or_else(|| ctx.block.get("действие"))
        .and_then(Value::as_str);

    match block_type.and_then(find_handler) {
        Some(handler) => handler.execute(ctx),
        None => Ok(None),
    }
}
