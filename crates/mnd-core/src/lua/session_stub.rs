//! Заглушка Lua-сессии для сборок без `mlua` (веб: `--no-default-features`).
//!
//! Повторяет сигнатуры `mlua_session`, но не умеет исполнять скрипты: Lua — это
//! C, а браузер её не получает. Ошибка возвращается нарочно текстом, который
//! видит игрок, — молча пропустить блок значило бы «квест сломался, почему —
//! непонятно».

use serde_json::Value;

use crate::runtime::ScriptRuntime;

/// Тот же тип, что и в нативной сборке, но без состояния VM.
pub struct LuaSession;

impl LuaSession {
    pub fn new() -> Self {
        LuaSession
    }

    pub fn exec_source(
        &mut self,
        _state: &mut dyn ScriptRuntime,
        _script: &str,
    ) -> Result<(), String> {
        Err("Lua в этой сборке недоступен — откройте квест в приложении".to_string())
    }

    pub fn call_function(
        &mut self,
        _state: &mut dyn ScriptRuntime,
        _script: Option<&str>,
        function_name: &str,
        _args: Value,
    ) -> Result<Option<String>, String> {
        Err(format!(
            "Lua в этой сборке недоступен (функция '{function_name}') — откройте квест в приложении"
        ))
    }
}

impl Default for LuaSession {
    fn default() -> Self {
        Self::new()
    }
}
