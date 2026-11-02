//! Блок `save_operation` — управление сохранениями из сценария.
//!
//! Движок не пишет на диск сам: он кладёт команду в очередь
//! `_internal_external_commands`, а клиент (Flutter-плеер) выполняет её через
//! свой `SaveGameService`. Так один и тот же квест работает и в приложении,
//! и в standalone-плеере, и не получает ФС-доступ из wasm.

use crate::blocks::{BlockContext, BlockHandler};
use crate::executor::{ExecutorError, interpolate_placeholders_raw, push_effect};

pub struct SaveOperation;

impl BlockHandler for SaveOperation {
    fn block_type(&self) -> &'static str {
        "save_operation"
    }

    fn execute(&self, ctx: &mut BlockContext<'_>) -> Result<Option<String>, ExecutorError> {
        let operation = ctx
            .string_field(&["operation", "op"], "save")
            .trim()
            .to_lowercase();
        let raw_slot = ctx.string_field(&["slotName", "slot", "name"], "");
        let slot = interpolate_placeholders_raw(&raw_slot, ctx.game_state)
            .trim()
            .to_string();

        let command = match operation.as_str() {
            "save" | "create" => serde_json::json!({
                "type": "save_game",
                "slotName": if slot.is_empty() { "Сохранение" } else { &slot },
            }),
            "open" | "list" => serde_json::json!({"type": "open_saves"}),
            "load" => {
                if slot.is_empty() {
                    ctx.executor.log("⚠️ save_operation: load без имени слота — открываю список");
                    serde_json::json!({"type": "open_saves"})
                } else {
                    serde_json::json!({"type": "load_save", "slotName": slot})
                }
            }
            "delete" => {
                if slot.is_empty() {
                    ctx.executor.log("⚠️ save_operation: delete без имени слота — пропуск");
                    return Ok(None);
                }
                serde_json::json!({"type": "delete_save", "slotName": slot})
            }
            _ => {
                ctx.executor
                    .log(&format!("⚠️ save_operation: неизвестная операция «{operation}»"));
                return Ok(None);
            }
        };

        push_effect(ctx.game_state, "_internal_external_commands", command);
        Ok(None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::executor::{EventType, ScriptExecutor};
    use crate::runtime::ScriptRuntime;
    use serde_json::json;
    use std::collections::HashMap;

    fn state() -> crate::runtime::InMemoryScriptRuntimeState {
        crate::runtime::InMemoryScriptRuntimeState::new(None, None)
    }

    fn run(block: serde_json::Value, state: &mut impl ScriptRuntime) {
        let script = json!({"blocks": [block]});
        ScriptExecutor::new()
            .execute(
                script.as_object().unwrap(),
                state,
                "q",
                EventType::OnNodeEnter,
                &None,
                &None,
                false,
                &mut None,
            )
            .unwrap();
    }

    #[test]
    fn save_operation_pushes_command_with_interpolated_slot() {
        let mut s = state();
        s.set_variable("hero", json!("Аня"));
        run(
            json!({
                "type": "save_operation",
                "operation": "save",
                "slotName": "слот {hero}",
            }),
            &mut s,
        );
        let queue = s
            .get_variable("_internal_external_commands")
            .cloned()
            .unwrap();
        assert_eq!(
            queue,
            json!([{"type": "save_game", "slotName": "слот Аня"}])
        );
    }

    #[test]
    fn load_without_slot_opens_saves_screen() {
        let mut s = state();
        run(
            json!({"type": "save_operation", "operation": "load"}),
            &mut s,
        );
        let queue = s
            .get_variable("_internal_external_commands")
            .cloned()
            .unwrap();
        assert_eq!(queue, json!([{"type": "open_saves"}]));
    }

    #[test]
    fn unknown_operation_is_noop() {
        let mut s = state();
        run(
            json!({"type": "save_operation", "operation": "explode"}),
            &mut s,
        );
        assert!(s
            .get_variable("_internal_external_commands")
            .is_none_or(|v| v.as_array().is_some_and(Vec::is_empty)));
    }
}