//! Блок `set_visible` — спрятать, убрать или показать элемент контента по
//! команде скрипта.
//!
//! Триггер видимости описывает *условие* («пока `{f} == true`»), а тут нужен
//! императивный жест: «в этот момент сцены — фото в сторону». Особенно для
//! слоёв внутри стека, до которых движок с условиями не доходит.
//!
//! «Не видно» — два разных поведения, как в CSS и Godot:
//! * `скрыть` — айтем сохраняет своё место: ряд не схлопывается, соседи стоят
//!   там, где автор их положил;
//! * `убрать` — айтем выходит из раскладки, соседи подтягиваются.
//!
//! Как и `set_image`, ядро не трогает модель контента: оно пишет
//! переопределения в служебную переменную `_internal_item_hidden`
//! (`{itemId: "hidden" | "gone" | "visible"}`), а клиент читает её при сборке
//! айтема. Значение живёт в состоянии игры — попадает в сейв и восстанавливается
//! из него, так что спрятанное остаётся спрятанным после перезапуска.
//!
//! Совместимость: `hide`/`скрыть` до разделения умели только схлопывать ряд, и
//! старый сейв с `{itemId: true}` до сих пор значит «убран». Слово «скрыть»
//! автор, который пишет блок от руки сегодня, употребляет в новом смысле —
//! место остаётся занятым; кому нужно схлопывание, тот пишет «убрать».

use crate::blocks::{BlockContext, BlockHandler};
use crate::executor::{ExecutorError, ITEM_HIDDEN_VAR, value_to_string};
use serde_json::{Map, Value};

/// Что делать с видимостью. `mode` принимает и русскую запись — редактор
/// пишет каноническую, а автор квеста мог написать блок от руки.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Mode {
    Show,
    /// Не видно, но место в расладке занято.
    Hidden,
    /// Не видно и вне раскладки: соседи подтягиваются.
    Gone,
    Toggle,
}

/// Что лежит в состоянии игры. Отдельно от [`Mode`]: тот описывает действие,
/// эти три — значение, которое после действия осталось.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Stored {
    Visible,
    Hidden,
    Gone,
}

impl Stored {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Stored::Visible => "visible",
            Stored::Hidden => "hidden",
            Stored::Gone => "gone",
        }
    }

    fn label(self) -> &'static str {
        match self {
            Stored::Visible => "виден",
            Stored::Hidden => "скрыт, место занято",
            Stored::Gone => "убран",
        }
    }

    /// Строки — текущий формат, bool — сейвы, записанные до разделения
    /// «скрыть/убрать»: там единственное «не видно» ряд именно схлопывало.
    fn from_value(raw: &Value) -> Option<Stored> {
        match raw {
            Value::Bool(true) => Some(Stored::Gone),
            Value::Bool(false) => Some(Stored::Visible),
            other => match value_to_string(other).trim().to_lowercase().as_str() {
                "visible" | "shown" => Some(Stored::Visible),
                "hidden" => Some(Stored::Hidden),
                "gone" => Some(Stored::Gone),
                _ => None,
            },
        }
    }
}

impl Mode {
    pub(crate) fn from_raw(raw: Option<&Value>) -> Option<Mode> {
        match raw? {
            Value::Bool(true) => Some(Mode::Show),
            Value::Bool(false) => Some(Mode::Gone),
            Value::Null => None,
            other => match value_to_string(other).trim().to_lowercase().as_str() {
                "show" | "показать" | "видим" | "visible" | "true" | "1" => {
                    Some(Mode::Show)
                }
                "hide" | "скрыть" | "спрятать" | "невидим" | "hidden" => {
                    Some(Mode::Hidden)
                }
                "gone" | "remove" | "erase" | "collapse" | "убрать" | "стереть" | "схлопнуть"
                | "false" | "0" => Some(Mode::Gone),
                "toggle" | "переключить" => Some(Mode::Toggle),
                _ => None,
            },
        }
    }

    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Mode::Show => "показать",
            Mode::Hidden => "скрыть",
            Mode::Gone => "убрать",
            Mode::Toggle => "переключить",
        }
    }
}

/// Проверка для валидатора скриптов: опознан ли режим. Единый источник
/// допустимых значений — `Mode::from_raw`, а не второй список строк.
pub(crate) fn mode_recognized(raw: Option<&Value>) -> bool {
    Mode::from_raw(raw).is_some()
}

/// Применить режим к карте переопределений `{itemId: "visible"|"hidden"|"gone"}`
/// и вернуть, чем значение стало. Общая для блока `set_visible` и Lua-хоста
/// (`core.set_item_visible`): «что значит скрыть / убрать / переключить» не
/// должно завестись второй раз в другом месте — включая чтение старых
/// сейвов, где значение лежало булевым.
pub(crate) fn apply_mode(overrides: &mut Map<String, Value>, item_id: &str, mode: Mode) -> Stored {
    let current = overrides
        .get(item_id)
        .and_then(Stored::from_value)
        .unwrap_or(Stored::Visible);
    let next = match mode {
        Mode::Show => Stored::Visible,
        Mode::Hidden => Stored::Hidden,
        Mode::Gone => Stored::Gone,
        // Переключение отвечает на «показать или нет», а не на «каким из
        // двух способов спрятать»: прятать оно будет с сохранением места.
        Mode::Toggle => match current {
            Stored::Visible => Stored::Hidden,
            Stored::Hidden | Stored::Gone => Stored::Visible,
        },
    };
    overrides.insert(
        item_id.to_string(),
        Value::String(next.as_str().to_string()),
    );
    next
}

pub struct SetVisible;

impl BlockHandler for SetVisible {
    fn block_type(&self) -> &'static str {
        "set_visible"
    }

    fn execute(&self, ctx: &mut BlockContext<'_>) -> Result<Option<String>, ExecutorError> {
        let item_id = ctx
            .string_field(&["item_id", "айтем"], "")
            .trim()
            .to_string();
        let raw_mode = ctx
            .block
            .get("mode")
            .or_else(|| ctx.block.get("режим"))
            .or_else(|| ctx.block.get("visible"))
            .or_else(|| ctx.block.get("видим"));
        let Some(mode) = Mode::from_raw(raw_mode) else {
            if !item_id.is_empty() {
                ctx.executor
                    .log("⚠️ set_visible без режима — ждём show / hide / remove / toggle");
            }
            return Ok(None);
        };
        if item_id.is_empty() {
            ctx.executor.log("⚠️ set_visible без айтема — пропуск");
            return Ok(None);
        }

        let mut overrides = match ctx.game_state.get_variable(ITEM_HIDDEN_VAR).cloned() {
            Some(Value::Object(map)) => map,
            _ => Map::new(),
        };
        // Как и `set_image`: адресат из мастера шаблона должен прилететь и в
        // копии — иначе спрятанное в мастере остаётся на экране в инстансах.
        let mut targets = ctx
            .executor
            .item_targets(&item_id)
            .cloned()
            .unwrap_or_default();
        if !targets.contains(&item_id) {
            targets.push(item_id.clone());
        }
        let mut next = Stored::Visible;
        for target in &targets {
            next = apply_mode(&mut overrides, target, mode);
        }
        ctx.game_state
            .set_variable(ITEM_HIDDEN_VAR, Value::Object(overrides));
        ctx.executor.log(&format!(
            "👁 set_visible {item_id}: {} → {}",
            mode.as_str(),
            next.label()
        ));
        Ok(None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mode_parses_english_and_russian_spellings() {
        for (raw, expected) in [
            (Value::String("hide".into()), Some(Mode::Hidden)),
            (Value::String("СКРЫТЬ".into()), Some(Mode::Hidden)),
            (Value::String("show".into()), Some(Mode::Show)),
            (Value::String("убрать".into()), Some(Mode::Gone)),
            (Value::String("remove".into()), Some(Mode::Gone)),
            (Value::String("переключить".into()), Some(Mode::Toggle)),
            (Value::Bool(false), Some(Mode::Gone)),
            (Value::Bool(true), Some(Mode::Show)),
            (Value::Null, None),
            (Value::String("мусор".into()), None),
        ] {
            assert_eq!(Mode::from_raw(Some(&raw)), expected, "{raw:?}");
        }
        assert_eq!(Mode::from_raw(None), None);
    }

    #[test]
    fn mode_label_for_log_is_russian() {
        assert_eq!(Mode::Hidden.as_str(), "скрыть");
        assert_eq!(Mode::Gone.as_str(), "убрать");
    }

    #[test]
    fn stored_reads_bool_of_old_saves_as_gone() {
        assert_eq!(Stored::from_value(&Value::Bool(true)), Some(Stored::Gone));
        assert_eq!(
            Stored::from_value(&Value::Bool(false)),
            Some(Stored::Visible)
        );
        assert_eq!(
            Stored::from_value(&Value::String("hidden".into())),
            Some(Stored::Hidden)
        );
        assert_eq!(Stored::from_value(&Value::String("да".into())), None);
    }
}
