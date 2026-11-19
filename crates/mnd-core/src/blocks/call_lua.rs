//! Блок `call_lua` — вызов Lua-функции.

use std::sync::{Arc, Mutex};

use crate::blocks::{BlockContext, BlockHandler};
use crate::executor::ExecutorError;
use crate::lua::LuaSession;

pub struct CallLua;

impl BlockHandler for CallLua {
    fn block_type(&self) -> &'static str {
        "call_lua"
    }

    fn execute(&self, ctx: &mut BlockContext<'_>) -> Result<Option<String>, ExecutorError> {
        let function_name = ctx
            .block
            .get("function")
            .and_then(serde_json::Value::as_str)
            .map(str::trim)
            .unwrap_or_default();
        if function_name.is_empty() {
            return Err(ExecutorError::Lua(
                "блок call_lua без поля 'function'".into(),
            ));
        }

        let script_id = ctx
            .block
            .get("script_id")
            .and_then(serde_json::Value::as_str);
        let has_script_id = script_id.is_some_and(|s| !s.trim().is_empty());
        let script = if has_script_id {
            ctx.executor
                .load_lua_text(ctx.quest_id, script_id.unwrap_or_default())
        } else {
            ctx.block
                .get("script")
                .and_then(serde_json::Value::as_str)
                .map(String::from)
        };
        if has_script_id && script.is_none() {
            return Err(ExecutorError::Lua(format!(
                "файл .lua не найден: '{}'",
                script_id.unwrap_or_default()
            )));
        }

        let args = match ctx
            .block
            .get("args")
            .cloned()
            .unwrap_or(serde_json::Value::Null)
        {
            serde_json::Value::String(s) => {
                serde_json::from_str(&s).unwrap_or(serde_json::Value::String(s))
            }
            other => other,
        };

        if ctx.lua.is_none() {
            *ctx.lua = Some(Arc::new(Mutex::new(LuaSession::new())));
        }
        let mut session = ctx
            .lua
            .as_ref()
            .expect("lua создана")
            .lock()
            .expect("lua lock");
        let result = session.call_function(ctx.game_state, script.as_deref(), function_name, args);
        // `core.log` — единственный способ увидеть, что происходит внутри
        // скрипта: строки уходят в журнал движка рядом с логами блоков.
        for line in session.take_logs() {
            ctx.executor.log(&format!("🖨️ {line}"));
        }
        result.map_err(ExecutorError::Lua)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::executor::{EventType, ScriptExecutor};
    use crate::runtime::InMemoryScriptRuntimeState;
    use serde_json::json;

    #[test]
    fn core_log_lines_reach_the_engine_log() {
        // `core.log` — единственный канал «посмотреть, что внутри»: строка
        // обязана оказаться в журнале рядом с логами блоков, иначе автор
        // отлаживает скрипт вслепую.
        let logs = Arc::new(Mutex::new(Vec::<String>::new()));
        let sink = logs.clone();
        let mut state = InMemoryScriptRuntimeState::default();
        let mut lua = None;
        let block = json!({
            "blocks": [{
                "type": "call_lua",
                "function": "start",
                "script": "function start() core.log('привет', 7, {hp = 3}) end"
            }]
        });
        ScriptExecutor::new()
            .with_logger(Some(Box::new(move |message: &str| {
                sink.lock().unwrap().push(message.to_string());
            })))
            .execute(
                block.as_object().unwrap(),
                &mut state,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut lua,
            )
            .unwrap();
        let joined = logs.lock().unwrap().join("\n");
        assert!(
            joined.contains("привет\t7\t{\"hp\":3}"),
            "строки core.log нет в журнале: {joined}"
        );
    }

    #[test]
    fn error_inside_script_still_flushes_its_log() {
        let logs = Arc::new(Mutex::new(Vec::<String>::new()));
        let sink = logs.clone();
        let mut state = InMemoryScriptRuntimeState::default();
        let mut lua = None;
        let block = json!({
            "blocks": [{
                "type": "call_lua",
                "function": "start",
                "script": "function start() core.log('до ошибки') error('бум') end"
            }]
        });
        // Ошибку внутри `call_lua` исполнитель превращает в запись журнала,
        // но строки, напечатанные до неё, обязаны дойти до автора.
        ScriptExecutor::new()
            .with_logger(Some(Box::new(move |message: &str| {
                sink.lock().unwrap().push(message.to_string());
            })))
            .execute(
                block.as_object().unwrap(),
                &mut state,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut lua,
            )
            .unwrap();
        let joined = logs.lock().unwrap().join("\n");
        assert!(joined.contains("до ошибки"), "лог потерялся: {joined}");
        assert!(
            joined.contains("бум"),
            "ошибка не попала в журнал: {joined}"
        );
    }
}
