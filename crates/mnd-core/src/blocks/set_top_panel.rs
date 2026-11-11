//! Блок `set_top_panel` — скрыть или вернуть верхнюю панель игры.
//!
//! Панель (назад, громкость, сохранение, загрузка) нужна не всегда: на
//! катсцене или в сцене-заставке она закрывает картинку и предлагает игроку
//! «сохраниться» посреди кульминации. Автор задаёт стартовое состояние
//! настройкой квеста `hideTopPanel`, а этот блок меняет его по ходу сюжета.
//!
//! Как и `set_blur`, движок не трогает UI напрямую: он пишет служебную
//! переменную `_internal_top_panel_hidden`, которую читает плеер. Значение
//! попадает в сейв, поэтому панель, спрятанная перед переходом, остаётся
//! спрятанной и после загрузки — как и любой другой эффект сцены.

use crate::blocks::set_visible::Mode;
use crate::blocks::{BlockContext, BlockHandler};
use crate::executor::ExecutorError;
use serde_json::Value;

/// Служебная переменная: `true` — панель скрыта. Её же читает плеер.
pub const TOP_PANEL_HIDDEN_VAR: &str = "_internal_top_panel_hidden";

pub struct SetTopPanel;

fn is_hidden(state: &dyn crate::runtime::ScriptRuntime) -> bool {
    matches!(
        state.get_variable(TOP_PANEL_HIDDEN_VAR),
        Some(Value::Bool(true))
    )
}

impl BlockHandler for SetTopPanel {
    fn block_type(&self) -> &'static str {
        "set_top_panel"
    }

    fn execute(&self, ctx: &mut BlockContext<'_>) -> Result<Option<String>, ExecutorError> {
        let raw_mode = ctx
            .block
            .get("mode")
            .or_else(|| ctx.block.get("режим"))
            .or_else(|| ctx.block.get("visible"))
            .or_else(|| ctx.block.get("видим"));
        // Режимы те же, что у `set_visible`: «показать / скрыть / переключить».
        let Some(mode) = Mode::from_raw(raw_mode) else {
            ctx.executor
                .log("⚠️ set_top_panel без режима — ждём show / hide / toggle");
            return Ok(None);
        };
        let next_hidden = match mode {
            Mode::Show => false,
            // «Убрать» для панели значит то же, что «скрыть»: панель не
            // занимает место в раскладке, схлопывать нечего.
            Mode::Hidden | Mode::Gone => true,
            Mode::Toggle => !is_hidden(ctx.game_state),
        };
        ctx.game_state
            .set_variable(TOP_PANEL_HIDDEN_VAR, Value::Bool(next_hidden));
        ctx.executor.log(&format!(
            "🪟 set_top_panel: {} → {}",
            mode.as_str(),
            if next_hidden {
                "скрыта"
            } else {
                "видна"
            }
        ));
        Ok(None)
    }
}
