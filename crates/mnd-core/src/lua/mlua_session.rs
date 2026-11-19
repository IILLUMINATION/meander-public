//! Реализация [`LuaSession`] поверх `mlua`. Только нативные сборки: см. [`crate::lua::session_stub`].
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicU64, Ordering},
};
use std::time::Instant;

use mlua::{Function, HookTriggers, Lua, LuaOptions, StdLib, Table, Value as LuaValue, VmState};
use serde_json::{Map, Value, json};

use crate::blocks::set_top_panel::TOP_PANEL_HIDDEN_VAR;
use crate::blocks::set_visible::{Mode as VisibilityMode, apply_mode};
use crate::executor::{ITEM_HIDDEN_VAR, ITEM_SOURCE_VAR, value_to_string};
use crate::models::QuestTable;
use crate::runtime::ScriptRuntime;

/// Библиотеки, которые видит скрипт квеста.
///
/// Набор собран по принципу «только вычисления над своими данными»: ни
/// файлов, ни процессов, ни загрузчика модулей. `io` и `package`/`require` в
/// состояние не грузятся вообще — на них держалась дыра «скачанный квест
/// читает `~/.ssh` и грузит чужой .lua с диска». `os` загружается, но его
/// таблица собирается заново в [`LuaSession::lock_down_stdlib`]: остаются
/// только часы и дата. `debug` mlua не отдаёт в безопасном режиме.
const SAFE_STDLIB_BITS: [StdLib; 6] = [
    StdLib::COROUTINE,
    StdLib::TABLE,
    StdLib::STRING,
    StdLib::UTF8,
    StdLib::MATH,
    StdLib::OS,
];

/// Собрать [`SAFE_STDLIB_BITS`] в один набор (битовое «или» из `mlua` не
/// `const`, поэтому набор склеивается функцией, а не константой).
fn safe_stdlib() -> StdLib {
    SAFE_STDLIB_BITS
        .into_iter()
        .reduce(|acc, lib| acc | lib)
        .expect("набор библиотек не пуст")
}

/// Потолок памяти Lua-состояния квеста. Без него `string.rep('x', 400 МБ)` из
/// скачанного квеста съедает память процесса: ОС убивает приложение целиком, а
/// не одну сцену. 32 МБ — с запасом больше любой разумной игровой таблицы.
const MAX_LUA_MEMORY_BYTES: usize = 32 * 1024 * 1024;

/// Потолок реального времени одного вызова. Счётчик инструкций ловит циклы, но
/// одна C-функция (`string.rep`, `string.find` с патологическим паттерном)
/// может занять много времени между двумя проверками; часы ставят предел и
/// этому.
const MAX_LUA_CALL_MILLIS: u128 = 2_000;

/// Сколько служебных команд (звук, внешние команды) один вызов может положить
/// в очередь. Блоки кладут единицы; скрипт в цикле — сколько успеет за 10 млн
/// инструкций, то есть десятки тысяч команд клиенту.
const MAX_EFFECTS_PER_CALL: usize = 256;

/// Потолок текстового аргумента `core.*` (id ассета, id айтема, имя ноды).
const MAX_ARG_TEXT_LEN: usize = 512;

/// Потолок имени переменной/таблицы и слота сохранения.
const MAX_NAME_LEN: usize = 128;

/// Потолок JSON-значения `core.set_var` — переменная не должна раздувать сейв.
const MAX_VARIABLE_JSON_BYTES: usize = 64 * 1024;

/// Потолок JSON-значения `core.set_table` — таблица крупнее, чем переменная.
const MAX_TABLE_JSON_BYTES: usize = 512 * 1024;

/// Сколько строк `core.log` держим за вызов и какой длины.
const MAX_LOG_LINES: usize = 100;
const MAX_LOG_LINE_LEN: usize = 500;

/// Префикс служебных каналов движка. Писать в них из Lua нельзя: через
/// `core.set_var('_internal_external_commands', …)` скрипт клал в очередь
/// `open_link` в обход фильтра URL и `save_operation` в обход блока.
const RESERVED_VAR_PREFIX: &str = "_internal";

/// Сколько инструкций VM между двумя срабатываниями счётчика. Меньше — дороже
/// на каждом кадре, больше — грубее потолок.
const LUA_INSTRUCTION_CHUNK: u64 = 1000;

/// Потолок инструкций на один вызов блока `call_lua`. Без него
/// `while true do end` из скачанного квеста навечно вешает поток движка:
/// UI замирает, FFI-вызов не возвращается. 10 млн — это заведомо больше
/// любой разумной игровой формулы и ~0.1 с, то есть заметный, но не
/// убивающий игру тормоз вместо зависания.
const MAX_LUA_INSTRUCTIONS: u64 = 10_000_000;

/// Потолок вложенности при переносе значения между Lua и JSON. Циклическая
/// таблица (`t.self = t`) иначе уходит в бесконечную рекурсию, а она
/// заканчивается не ошибкой, а переполнением стека и abort процесса.
const MAX_LUA_VALUE_DEPTH: u32 = 32;

/// Очередь аудио-команд одного исполнения. Ключ совпадает с
/// `executor::push_audio_command`: клиент разбирает один и тот же канал и для
/// блоков, и для Lua.
const AUDIO_QUEUE_VAR: &str = "_internal_audio_queue";

/// Очередь внешних команд (`open_link`) — тот же ключ, что у блока.
const EXTERNAL_COMMANDS_VAR: &str = "_internal_external_commands";

/// Снимок состояния, с которым работает Lua в одном вызове блока.
#[derive(Clone, Default)]
struct LuaStateSnapshot {
    variables: Map<String, Value>,
    /// Таблицы: имя → `QuestTable.to_json()`.
    tables: Map<String, Value>,
}

/// Мост «Lua ↔ runtime»: хранится в сессии, заполняется на каждый вызов.
#[derive(Default)]
struct LuaBridge {
    snapshot: Option<LuaStateSnapshot>,
    /// Переход, запрошенный `core.go_to`. Отдельно от снимка: функция-триггер
    /// обычно ничего не возвращает, а уйти в узел ей надо уметь — у блока
    /// `go_to_node` для этого собственный возврат.
    transition: Option<String>,
    /// Строки `core.log` текущего вызова: журнал движка забирает их после
    /// возврата функции ([`LuaSession::take_logs`]).
    logs: Vec<String>,
}

/// Снимок доступен только во время вызова блока: вне движка (`snapshot == None`)
/// `core.*`-эффекты молча no-op, а не падают — Lua-функцию мог позвать и
/// посторонний код.
fn with_snapshot<T>(
    bridge: &Arc<Mutex<LuaBridge>>,
    f: impl FnOnce(&mut LuaStateSnapshot) -> T,
) -> Option<T> {
    let mut guard = bridge.lock().unwrap();
    guard.snapshot.as_mut().map(f)
}

impl LuaStateSnapshot {
    fn from_state(state: &dyn ScriptRuntime) -> Self {
        Self {
            variables: state.all_variables().clone(),
            tables: state
                .all_tables()
                .iter()
                .map(|(name, t)| (name.clone(), t.to_json()))
                .collect(),
        }
    }

    /// Очередь служебной переменной — аналог `executor::push_effect`, только на
    /// снимке: живой runtime получит значение тем же диффом, что и переменные.
    ///
    /// `false` — очередь этого вызова уже полна: скрипт в цикле иначе засыплет
    /// клиент десятками тысяч команд.
    fn push_effect(&mut self, key: &str, value: Value) -> bool {
        let mut queue = match self.variables.remove(key) {
            Some(Value::Array(items)) => items,
            _ => Vec::new(),
        };
        if queue.len() >= MAX_EFFECTS_PER_CALL {
            self.variables.insert(key.to_string(), Value::Array(queue));
            return false;
        }
        queue.push(value);
        self.variables.insert(key.to_string(), Value::Array(queue));
        true
    }

    /// Прямая запись служебной переменной (одноразовые слоты вроде громкости).
    fn set_effect(&mut self, key: &str, value: Value) {
        self.variables.insert(key.to_string(), value);
    }

    /// Карта переопределений контента `{itemId: значение}` — тот же канал, что
    /// у блоков `set_image` и `set_visible`.
    fn override_map(&mut self, key: &str) -> &mut Map<String, Value> {
        let entry = self
            .variables
            .entry(key.to_string())
            .or_insert_with(|| Value::Object(Map::new()));
        if !entry.is_object() {
            *entry = Value::Object(Map::new());
        }
        entry
            .as_object_mut()
            .expect("переопределения контента — объект")
    }

    /// Применить снимок к runtime: только изменённые ключи (дифф), чтобы
    /// не перезаписывать без нужды и не отмечать всё в dirty-наборах.
    fn apply_to(&self, state: &mut dyn ScriptRuntime) {
        for (k, v) in &self.variables {
            let changed = match state.get_variable(k) {
                Some(cur) => cur != v,
                None => true,
            };
            if changed {
                state.set_variable(k, v.clone());
            }
        }
        for (name, json) in &self.tables {
            let changed = match state.get_table(name) {
                Some(cur) => cur.to_json() != *json,
                None => true,
            };
            if changed {
                state.set_table(name, QuestTable::from_json(json));
            }
        }
    }
}

/// Lua-сессия квеста (L3A). Не `Send`/`Sync` — живёт в одном потоке движка.
pub struct LuaSession {
    lua: Lua,
    bridge: Arc<Mutex<LuaBridge>>,
    /// Счётчик инструкций, накопленных с начала текущего вызова блока.
    instructions: Arc<AtomicU64>,
    /// Начало текущего вызова: второй предел рядом со счётчиком инструкций.
    started: Arc<Mutex<Instant>>,
}

impl LuaSession {
    pub fn new() -> Self {
        // Песочница собрана из белого списка, а не из «всех безопасных с
        // последующей зачисткой»: `io`, `package`, `require`, `loadfile`,
        // `dofile` в состояние вообще не попадают, поэтому их нельзя вернуть
        // ни `require`-ом, ни `package.loaded`, ни метатаблицами.
        let lua =
            Lua::new_with(safe_stdlib(), LuaOptions::default()).expect("создать Lua-состояние");
        lua.set_memory_limit(MAX_LUA_MEMORY_BYTES)
            .expect("ограничить память Lua");
        let bridge = Arc::new(Mutex::new(LuaBridge::default()));
        let instructions = Arc::new(AtomicU64::new(0));
        let started = Arc::new(Mutex::new(Instant::now()));

        // Глобальный хук (не thread-хук): он же достаётся coroutine-потокам,
        // созданным после установки. Ошибка из хук-колбэка mlua пробрасывает
        // её как обычную ошибку Lua, то есть блок просто завершается с
        // ошибкой вместо вечной зависки движка. `pcall` её не глотает —
        // проверено тестом `pcall_does_not_swallow_the_instruction_limit`.
        let counter = instructions.clone();
        let clock = started.clone();
        lua.set_global_hook(
            HookTriggers::new().every_nth_instruction(LUA_INSTRUCTION_CHUNK as u32),
            move |_lua, _debug| {
                let spent =
                    counter.fetch_add(LUA_INSTRUCTION_CHUNK, Ordering::Relaxed) + LUA_INSTRUCTION_CHUNK;
                if spent > MAX_LUA_INSTRUCTIONS {
                    return Err(mlua::Error::runtime(format!(
                        "слишком много инструкций Lua (>{MAX_LUA_INSTRUCTIONS}) — похоже на бесконечный цикл"
                    )));
                }
                let elapsed = clock.lock().unwrap().elapsed().as_millis();
                if elapsed > MAX_LUA_CALL_MILLIS {
                    return Err(mlua::Error::runtime(format!(
                        "Lua-скрипт работает дольше {MAX_LUA_CALL_MILLIS} мс — прерван"
                    )));
                }
                Ok(VmState::Continue)
            },
        )
        .expect("установить хук лимита инструкций");

        let session = Self {
            lua,
            bridge,
            instructions,
            started,
        };
        session.install_core_api();
        session
    }

    /// Отметить начало вызова: и счётчик инструкций, и часы.
    fn begin_call(&self) {
        self.instructions.store(0, Ordering::Relaxed);
        *self.started.lock().unwrap() = Instant::now();
    }

    /// Забрать строки `core.log` текущего вызова. Движок отдаёт их своему
    /// журналу сразу после возврата функции (`call_lua`), а не копит в сессии.
    pub fn take_logs(&self) -> Vec<String> {
        std::mem::take(&mut self.bridge.lock().unwrap().logs)
    }

    /// Зарегистрировать `core.*` (белый список; один раз при создании).
    fn install_core_api(&self) {
        let get_var = {
            let bridge = self.bridge.clone();
            self.lua
                .create_function(move |lua, name: String| -> Result<LuaValue, mlua::Error> {
                    // Служебные каналы движка наружу не отдаём: там очередь
                    // эффектов и токены, а не данные автора.
                    if is_reserved_name(&name) {
                        return Ok(LuaValue::Nil);
                    }
                    let Some(snapshot) = &bridge.lock().unwrap().snapshot else {
                        return Ok(LuaValue::Nil);
                    };
                    let value = snapshot
                        .variables
                        .get(&name)
                        .cloned()
                        .unwrap_or(Value::Null);
                    json_to_lua(lua, &value)
                })
                .expect("create get_var")
        };
        let set_var = {
            let bridge = self.bridge.clone();
            self.lua
                .create_function(
                    move |_, (name, value): (String, LuaValue)| -> Result<bool, mlua::Error> {
                        check_name(&name, "core.set_var")?;
                        let json = lua_to_json(value);
                        check_json_size(&json, MAX_VARIABLE_JSON_BYTES, "core.set_var")?;
                        if let Some(snapshot) = &mut bridge.lock().unwrap().snapshot {
                            snapshot.variables.insert(name, json);
                        }
                        Ok(true)
                    },
                )
                .expect("create set_var")
        };
        let get_table = {
            let bridge = self.bridge.clone();
            self.lua
                .create_function(move |lua, name: String| -> Result<LuaValue, mlua::Error> {
                    let Some(snapshot) = &bridge.lock().unwrap().snapshot else {
                        return Ok(LuaValue::Nil);
                    };
                    let value = snapshot.tables.get(&name).cloned().unwrap_or(Value::Null);
                    json_to_lua(lua, &value)
                })
                .expect("create get_table")
        };
        let set_table = {
            let bridge = self.bridge.clone();
            self.lua
                .create_function(
                    move |_, (name, value): (String, LuaValue)| -> Result<bool, mlua::Error> {
                        check_name(&name, "core.set_table")?;
                        let json = lua_to_json(value);
                        check_json_size(&json, MAX_TABLE_JSON_BYTES, "core.set_table")?;
                        if let Some(snapshot) = &mut bridge.lock().unwrap().snapshot {
                            snapshot.tables.insert(name, json);
                        }
                        Ok(true)
                    },
                )
                .expect("create set_table")
        };
        let log = {
            let bridge = self.bridge.clone();
            self.lua
                .create_function(
                    move |_, args: mlua::Variadic<LuaValue>| -> Result<(), mlua::Error> {
                        let mut line = String::new();
                        for (index, value) in args.iter().enumerate() {
                            if index > 0 {
                                line.push('\t');
                            }
                            line.push_str(&arg_text(Some(value)));
                        }
                        let mut guard = bridge.lock().unwrap();
                        if guard.logs.len() < MAX_LOG_LINES {
                            guard.logs.push(truncate_chars(line, MAX_LOG_LINE_LEN));
                        }
                        Ok(())
                    },
                )
                .expect("create log")
        };

        let go_to = {
            let bridge = self.bridge.clone();
            self.lua
                .create_function(
                    move |_, args: mlua::Variadic<LuaValue>| -> Result<bool, mlua::Error> {
                        let node = arg_text(args.first()).trim().to_string();
                        if node.is_empty() || node.chars().count() > MAX_ARG_TEXT_LEN {
                            return Ok(false);
                        }
                        bridge.lock().unwrap().transition = Some(node);
                        Ok(true)
                    },
                )
                .expect("create go_to")
        };
        let play_sound = {
            let bridge = self.bridge.clone();
            self.lua
                .create_function(
                    move |_, args: mlua::Variadic<LuaValue>| -> Result<bool, mlua::Error> {
                        let audio_id = arg_text(args.first());
                        if audio_id.is_empty() || audio_id.chars().count() > MAX_ARG_TEXT_LEN {
                            return Ok(false);
                        }
                        let volume = arg_num(args.get(1)).unwrap_or(1.0).clamp(0.0, 1.0);
                        Ok(pushed(
                            &bridge,
                            AUDIO_QUEUE_VAR,
                            json!({"type": "play_sound", "audio_id": audio_id, "volume": volume}),
                        ))
                    },
                )
                .expect("create play_sound")
        };
        let stop_sound = {
            let bridge = self.bridge.clone();
            self.lua
                .create_function(
                    move |_, args: mlua::Variadic<LuaValue>| -> Result<bool, mlua::Error> {
                        let target = {
                            let raw = arg_text(args.first());
                            if raw.is_empty() {
                                "all".to_string()
                            } else {
                                raw
                            }
                        };
                        Ok(pushed(
                            &bridge,
                            AUDIO_QUEUE_VAR,
                            json!({"type": "stop_sound", "target": target}),
                        ))
                    },
                )
                .expect("create stop_sound")
        };
        let play_music = {
            let bridge = self.bridge.clone();
            self.lua
                .create_function(
                    move |_, args: mlua::Variadic<LuaValue>| -> Result<bool, mlua::Error> {
                        let audio_id = arg_text(args.first());
                        if audio_id.is_empty() || audio_id.chars().count() > MAX_ARG_TEXT_LEN {
                            return Ok(false);
                        }
                        let opts = args.get(1);
                        let volume = arg_num(opts_field(opts, "volume").as_ref())
                            .unwrap_or(1.0)
                            .clamp(0.0, 1.0);
                        let loop_ = arg_bool(opts_field(opts, "loop").as_ref(), true);
                        let global = arg_bool(opts_field(opts, "global").as_ref(), false);
                        let queued = pushed(
                            &bridge,
                            AUDIO_QUEUE_VAR,
                            json!({
                                "type": "play_music",
                                "audio_id": audio_id,
                                "loop": loop_,
                                "volume": volume,
                                "global": global,
                            }),
                        );
                        // Слот активной скриптовой музыки: без него трек не
                        // возобновляется после загрузки сейва — блок `play_music`
                        // пишет те же три ключа.
                        with_snapshot(&bridge, |snapshot| {
                            snapshot.set_effect("_internal_active_script_bgm_id", json!(audio_id));
                            snapshot
                                .set_effect("_internal_active_script_bgm_volume", json!(volume));
                            snapshot.set_effect("_internal_active_script_bgm_loop", json!(loop_));
                        });
                        Ok(queued)
                    },
                )
                .expect("create play_music")
        };
        let stop_music = {
            let bridge = self.bridge.clone();
            self.lua
                .create_function(
                    move |_, _args: mlua::Variadic<LuaValue>| -> Result<bool, mlua::Error> {
                        let queued =
                            pushed(&bridge, AUDIO_QUEUE_VAR, json!({"type": "stop_music"}));
                        with_snapshot(&bridge, |snapshot| {
                            for key in [
                                "_internal_active_script_bgm_id",
                                "_internal_active_script_bgm_volume",
                                "_internal_active_script_bgm_loop",
                            ] {
                                snapshot.set_effect(key, Value::Null);
                            }
                        });
                        Ok(queued)
                    },
                )
                .expect("create stop_music")
        };
        let pause_resume = {
            let bridge = self.bridge.clone();
            self.lua
                .create_function(
                    move |_, args: mlua::Variadic<LuaValue>| -> Result<bool, mlua::Error> {
                        let target = {
                            let raw = arg_text(args.first());
                            if raw.is_empty() {
                                "all".to_string()
                            } else {
                                raw
                            }
                        };
                        let action = {
                            let raw = arg_text(args.get(1));
                            if raw.is_empty() {
                                "toggle".to_string()
                            } else {
                                raw
                            }
                        };
                        Ok(pushed(
                            &bridge,
                            AUDIO_QUEUE_VAR,
                            json!({"type": "pause_resume", "target": target, "action": action}),
                        ))
                    },
                )
                .expect("create pause_resume")
        };
        let set_volume = {
            let bridge = self.bridge.clone();
            self.lua
                .create_function(
                    move |_, args: mlua::Variadic<LuaValue>| -> Result<bool, mlua::Error> {
                        let target = {
                            let raw = arg_text(args.first());
                            if raw.is_empty() {
                                "contentAudio".to_string()
                            } else {
                                raw
                            }
                        };
                        let volume = arg_num(args.get(1)).unwrap_or(1.0).clamp(0.0, 1.0);
                        Ok(with_snapshot(&bridge, |snapshot| match target.as_str() {
                            "contentAudio" => {
                                snapshot.set_effect("_internal_node_content_volume", json!(volume));
                            }
                            "tagAudio" => {
                                snapshot.set_effect("_internal_tag_volume", json!(volume));
                            }
                            // Как блок: неизвестный адресат — ничего не меняем.
                            _ => {}
                        })
                        .is_some())
                    },
                )
                .expect("create set_volume")
        };
        let set_blur = {
            let bridge = self.bridge.clone();
            self.lua
                .create_function(
                    move |_, args: mlua::Variadic<LuaValue>| -> Result<bool, mlua::Error> {
                        let blur = arg_num(args.first()).unwrap_or(10.0);
                        Ok(with_snapshot(&bridge, |snapshot| {
                            snapshot.set_effect("_internal_background_blur", json!(blur));
                        })
                        .is_some())
                    },
                )
                .expect("create set_blur")
        };
        let set_item_visible = {
            let bridge = self.bridge.clone();
            self.lua
                .create_function(
                    move |_, args: mlua::Variadic<LuaValue>| -> Result<bool, mlua::Error> {
                        let item_id = arg_text(args.first()).trim().to_string();
                        let mode_raw = lua_to_json(args.get(1).cloned().unwrap_or(LuaValue::Nil));
                        let Some(mode) = VisibilityMode::from_raw(Some(&mode_raw)) else {
                            return Ok(false);
                        };
                        if item_id.is_empty() || item_id.chars().count() > MAX_NAME_LEN {
                            return Ok(false);
                        }
                        // apply_mode — та же функция, что у блока: «скрыть»
                        // сохраняет место, «убрать» схлопывает ряд, toggle умеет
                        // только прятать с сохранением места.
                        Ok(with_snapshot(&bridge, |snapshot| {
                            apply_mode(snapshot.override_map(ITEM_HIDDEN_VAR), &item_id, mode);
                        })
                        .is_some())
                    },
                )
                .expect("create set_item_visible")
        };
        let set_item_image = {
            let bridge = self.bridge.clone();
            self.lua
                .create_function(
                    move |_, args: mlua::Variadic<LuaValue>| -> Result<bool, mlua::Error> {
                        let item_id = arg_text(args.first()).trim().to_string();
                        let source = arg_text(args.get(1)).trim().to_string();
                        if item_id.is_empty()
                            || item_id.chars().count() > MAX_NAME_LEN
                            || source.is_empty()
                            || source.chars().count() > MAX_ARG_TEXT_LEN
                        {
                            return Ok(false);
                        }
                        Ok(with_snapshot(&bridge, |snapshot| {
                            snapshot
                                .override_map(ITEM_SOURCE_VAR)
                                .insert(item_id, json!(source));
                        })
                        .is_some())
                    },
                )
                .expect("create set_item_image")
        };
        let open_link = {
            let bridge = self.bridge.clone();
            self.lua
                .create_function(
                    move |_, args: mlua::Variadic<LuaValue>| -> Result<bool, mlua::Error> {
                        let url = arg_text(args.first()).trim().to_string();
                        if url.is_empty() || url.chars().count() > MAX_ARG_TEXT_LEN {
                            return Ok(false);
                        }
                        // Белый список сети — тот же фильтр, что у блока.
                        if crate::network_safety::check_url(&url).is_err() {
                            return Ok(false);
                        }
                        Ok(pushed(
                            &bridge,
                            EXTERNAL_COMMANDS_VAR,
                            json!({"type": "open_link", "url": url}),
                        ))
                    },
                )
                .expect("create open_link")
        };

        let set_top_panel = {
            let bridge = self.bridge.clone();
            self.lua
                .create_function(
                    move |_, args: mlua::Variadic<LuaValue>| -> Result<bool, mlua::Error> {
                        let raw = lua_to_json(args.first().cloned().unwrap_or(LuaValue::Nil));
                        // Режимы те же, что у блока set_top_panel: show/hide/toggle.
                        let Some(mode) = VisibilityMode::from_raw(Some(&raw)) else {
                            return Ok(false);
                        };
                        Ok(with_snapshot(&bridge, |snapshot| {
                            let hidden = match mode {
                                VisibilityMode::Show => false,
                                VisibilityMode::Hidden | VisibilityMode::Gone => true,
                                VisibilityMode::Toggle => !matches!(
                                    snapshot.variables.get(TOP_PANEL_HIDDEN_VAR),
                                    Some(Value::Bool(true))
                                ),
                            };
                            snapshot.set_effect(TOP_PANEL_HIDDEN_VAR, Value::Bool(hidden));
                        })
                        .is_some())
                    },
                )
                .expect("create set_top_panel")
        };
        // Половины блока `crossfade`: блок оборачивает ими детей, а из Lua
        // сценарий сам решает, что происходит между затуханием и возвратом.
        let fade = |kind: &'static str, api: &'static str| {
            let bridge = self.bridge.clone();
            self.lua
                .create_function(
                    move |_, args: mlua::Variadic<LuaValue>| -> Result<bool, mlua::Error> {
                        let seconds = arg_num(args.first()).unwrap_or(2.0).clamp(0.0, 60.0);
                        let ms = (seconds * 1000.0).round() as i64;
                        Ok(pushed(
                            &bridge,
                            AUDIO_QUEUE_VAR,
                            json!({"type": kind, "ms": ms}),
                        ))
                    },
                )
                .unwrap_or_else(|e| panic!("create {api}: {e}"))
        };
        let fade_out = fade("fade_out", "fade_out");
        let fade_in = fade("fade_in", "fade_in");

        // Сохранения — те же внешние команды, что у блока `save_operation`.
        let save_command = |build: fn(String) -> Option<Value>, api: &'static str| {
            let bridge = self.bridge.clone();
            self.lua
                .create_function(
                    move |_, args: mlua::Variadic<LuaValue>| -> Result<bool, mlua::Error> {
                        let slot = arg_text(args.first()).trim().to_string();
                        if slot.chars().count() > MAX_NAME_LEN {
                            return Ok(false);
                        }
                        match build(slot) {
                            Some(command) => Ok(pushed(&bridge, EXTERNAL_COMMANDS_VAR, command)),
                            None => Ok(false),
                        }
                    },
                )
                .unwrap_or_else(|e| panic!("create {api}: {e}"))
        };
        let save_game = save_command(
            |slot| {
                let slot = if slot.is_empty() {
                    "Сохранение".to_string()
                } else {
                    slot
                };
                Some(json!({"type": "save_game", "slotName": slot}))
            },
            "save_game",
        );
        let open_saves = save_command(|_slot| Some(json!({"type": "open_saves"})), "open_saves");
        let load_save = save_command(
            |slot| {
                Some(if slot.is_empty() {
                    json!({"type": "open_saves"})
                } else {
                    json!({"type": "load_save", "slotName": slot})
                })
            },
            "load_save",
        );
        let delete_save = save_command(
            |slot| {
                // Как блок: без имени слота удалять нечего.
                if slot.is_empty() {
                    None
                } else {
                    Some(json!({"type": "delete_save", "slotName": slot}))
                }
            },
            "delete_save",
        );

        let core = self.lua.create_table().expect("create core table");
        core.set("get_var", get_var).expect("core.get_var");
        core.set("set_var", set_var).expect("core.set_var");
        core.set("get_table", get_table).expect("core.get_table");
        core.set("set_table", set_table).expect("core.set_table");
        for (name, func) in [
            ("go_to", go_to),
            ("play_sound", play_sound),
            ("stop_sound", stop_sound),
            ("play_music", play_music),
            ("stop_music", stop_music),
            ("pause_resume", pause_resume),
            ("set_volume", set_volume),
            ("set_blur", set_blur),
            ("set_item_visible", set_item_visible),
            ("set_item_image", set_item_image),
            ("set_top_panel", set_top_panel),
            ("fade_out", fade_out),
            ("fade_in", fade_in),
            ("open_link", open_link),
            ("save_game", save_game),
            ("open_saves", open_saves),
            ("load_save", load_save),
            ("delete_save", delete_save),
            ("log", log),
        ] {
            core.set(name, func)
                .unwrap_or_else(|e| panic!("core.{name}: {e}"));
        }
        self.lua.globals().set("core", core).expect("globals core");

        self.lock_down_stdlib();
    }

    /// Дозакрыть то, что приходит вместе с базовой библиотекой, и собрать
    /// безопасный `os` руками.
    ///
    /// Библиотек `io`/`package`/`debug` в состоянии нет вообще (см.
    /// [`safe_stdlib`]), но базовые глобалы `load`, `dofile`, `loadfile`,
    /// `require` живут в `_G` всегда — их выкидываем. `load` возвращаем
    /// урезанным: только текстовые чанки (байткод из чужого квеста — это
    /// данные, которые VM разбирает намного сложнее, чем исходник).
    fn lock_down_stdlib(&self) {
        let globals = self.lua.globals();
        for name in ["io", "package", "debug", "require", "dofile", "loadfile"] {
            let _ = globals.set(name, LuaValue::Nil);
        }
        // `os` — заново: часы и дата без процессов, файлов и окружения.
        if let Ok(os) = globals.get::<Table>("os")
            && let Ok(safe) = self.lua.create_table()
        {
            for name in ["time", "clock", "date", "difftime"] {
                if let Ok(value) = os.get::<LuaValue>(name) {
                    let _ = safe.set(name, value);
                }
            }
            let _ = globals.set("os", safe);
        }
        // `string.dump` отдаёт байткод — обратной дороги к нему нет.
        if let Ok(string) = globals.get::<Table>("string") {
            let _ = string.set("dump", LuaValue::Nil);
        }
        // `load`: та же сигнатура, но mode принудительно текстовый.
        if self
            .lua
            .load(
                r#"
local raw_load = load
load = function(chunk, chunkname, mode, env)
    if type(chunk) == "string" and chunk:sub(1, 1) == "\27" then
        return nil, "binary chunks are disabled in the quest sandbox"
    end
    if env ~= nil then
        return raw_load(chunk, chunkname, "t", env)
    end
    return raw_load(chunk, chunkname, "t")
end
"#,
            )
            .set_name("sandbox")
            .exec()
            .is_err()
        {
            // Не должно случиться: `load` есть всегда. Если случилось —
            // состояние без `load` безопаснее, чем с необёрнутым.
            let _ = globals.set("load", LuaValue::Nil);
        }
    }

    /// Исполнить исходник, не вызывая функцию — «подключение» скрипта.
    ///
    /// Так глобальный (квестовый) Lua-скрипт доживает до скриптов любой ноды:
    /// его `function …` становятся глобалами сессии. Изменения состояния,
    /// сделанные кодом верхнего уровня, применяются тем же диффом, что и в
    /// `call_function`.
    pub fn exec_source(
        &mut self,
        state: &mut dyn ScriptRuntime,
        script: &str,
    ) -> Result<(), String> {
        if script.trim().is_empty() {
            return Ok(());
        }
        self.begin_call();
        let snapshot = LuaStateSnapshot::from_state(state);
        *self.bridge.lock().unwrap() = LuaBridge {
            snapshot: Some(snapshot),
            ..LuaBridge::default()
        };
        let exec = self
            .lua
            .load(script)
            .exec()
            .map_err(|e| format!("script: {e}"));
        if let Some(snapshot) = self.bridge.lock().unwrap().snapshot.clone() {
            snapshot.apply_to(state);
        }
        self.bridge.lock().unwrap().snapshot = None;
        exec
    }

    /// Выполнить Lua-функцию блока `call_lua`.
    ///
    /// `script` — inline Lua-код (может быть пустым, если функция уже
    /// зарегистрирована в этой сессии). `args` — JSON-значение: массив
    /// распаковывается в аргументы функции, любое другое значение
    /// передаётся единственным аргументом.
    ///
    /// Возвращает переход, если функция вызвала `core.go_to` или вернула
    /// таблицу с ключом `node` / `go_to_node` (строка).
    pub fn call_function(
        &mut self,
        state: &mut dyn ScriptRuntime,
        script: Option<&str>,
        function_name: &str,
        args: Value,
    ) -> Result<Option<String>, String> {
        // 1. Снимок текущего состояния — то, что видит core.*.
        self.begin_call();
        let snapshot = LuaStateSnapshot::from_state(state);
        *self.bridge.lock().unwrap() = LuaBridge {
            snapshot: Some(snapshot),
            ..LuaBridge::default()
        };

        // 2. Inline-скрипт: повторный exec идемпотентен (функции
        //    переопределяются, состояние Lua вне core.* не сохраняется).
        if let Some(script) = script
            && !script.trim().is_empty()
        {
            self.lua
                .load(script)
                .exec()
                .map_err(|e| format!("script: {e}"))?;
        }

        // 3. Вызов функции.
        let func: Function = self
            .lua
            .globals()
            .get::<Function>(function_name)
            .map_err(|_| format!("функция '{function_name}' не найдена"))?;

        let call_args = args_to_multi(&self.lua, &args)?;
        let result: LuaValue = func
            .call(call_args)
            .map_err(|e| format!("{function_name}: {e}"))?;

        // 4. Применить изменения состояния диффом.
        let (applied, explicit_transition) = {
            let mut guard = self.bridge.lock().unwrap();
            (guard.snapshot.clone(), guard.transition.take())
        };
        if let Some(snapshot) = applied {
            snapshot.apply_to(state);
        }
        self.bridge.lock().unwrap().snapshot = None;

        // 5. Переход: явный `core.go_to` важнее возврата функции — автор мог
        //    вернуть таблицу с итогами, а уйти попросить отдельно.
        if explicit_transition.is_some() {
            return Ok(explicit_transition);
        }
        Ok(transition_from_lua_result(&result))
    }
}

impl Default for LuaSession {
    fn default() -> Self {
        Self::new()
    }
}

/// Append одной команды в очередь на снимке. `false` — вызов вне движка,
/// снимка нет, команде негде лечь.
fn pushed(bridge: &Arc<Mutex<LuaBridge>>, key: &str, command: Value) -> bool {
    with_snapshot(bridge, |snapshot| snapshot.push_effect(key, command)) == Some(true)
}

/// Аргумент как текст: число и булев `tostring`-ом, nil — пустая строка.
/// Блоки читают те же поля через `value_to_string`, поэтому разбор одинаков.
fn arg_text(value: Option<&LuaValue>) -> String {
    match value {
        None | Some(LuaValue::Nil) => String::new(),
        Some(v) => value_to_string(&lua_to_json(v.clone())),
    }
}

/// Имя служебного канала движка: `_internal…`. Через них ходят команды
/// клиенту (ссылки, сохранения, звук), поэтому из скрипта туда писать нельзя.
fn is_reserved_name(name: &str) -> bool {
    name.starts_with(RESERVED_VAR_PREFIX)
}

/// Проверить имя переменной/таблицы: непустое, не служебное, не бесконечное.
fn check_name(name: &str, api: &str) -> Result<(), mlua::Error> {
    if name.trim().is_empty() {
        return Err(mlua::Error::runtime(format!("{api}: пустое имя")));
    }
    if is_reserved_name(name) {
        return Err(mlua::Error::runtime(format!(
            "{api}: имя '{name}' зарезервировано движком"
        )));
    }
    if name.chars().count() > MAX_NAME_LEN {
        return Err(mlua::Error::runtime(format!(
            "{api}: имя длиннее {MAX_NAME_LEN} символов"
        )));
    }
    Ok(())
}

/// Потолок JSON-значения: иначе одна переменная раздувает сейв и память.
fn check_json_size(value: &Value, max: usize, api: &str) -> Result<(), mlua::Error> {
    let size = serde_json::to_string(value).map_or(usize::MAX, |raw| raw.len());
    if size > max {
        return Err(mlua::Error::runtime(format!(
            "{api}: значение больше потолка ({size} > {max} байт)"
        )));
    }
    Ok(())
}

/// Обрезать строку по символам (не по байтам — иначе рвём UTF-8).
fn truncate_chars(text: String, max: usize) -> String {
    if text.chars().count() <= max {
        return text;
    }
    let mut out: String = text.chars().take(max).collect();
    out.push('…');
    out
}

/// Аргумент как число: строку пробуем распарсить (автор мог подать «0.5»),
/// остальное — None, чтобы вызывающий подставил блоковый дефолт.
fn arg_num(value: Option<&LuaValue>) -> Option<f64> {
    match value? {
        LuaValue::Integer(i) => Some(*i as f64),
        LuaValue::Number(n) => Some(*n),
        LuaValue::String(s) => s.to_string_lossy().trim().parse().ok(),
        _ => None,
    }
}

/// Аргумент-переключатель: nil или неверный тип — дефолт блока.
fn arg_bool(value: Option<&LuaValue>, default: bool) -> bool {
    match value {
        Some(LuaValue::Boolean(b)) => *b,
        _ => default,
    }
}

/// Поле таблицы опций: `core.play_music('ид', { loop = false })`.
fn opts_field(value: Option<&LuaValue>, key: &str) -> Option<LuaValue> {
    match value? {
        LuaValue::Table(table) => table.get::<LuaValue>(key).ok(),
        _ => None,
    }
}

/// Переход из результата Lua-функции: таблица `{ node = "..." }` или
/// `{ go_to_node = "..." }`.
fn transition_from_lua_result(result: &LuaValue) -> Option<String> {
    let LuaValue::Table(t) = result else {
        return None;
    };
    t.get::<String>("node")
        .ok()
        .filter(|s| !s.is_empty())
        .or_else(|| t.get::<String>("go_to_node").ok())
        .filter(|s| !s.is_empty())
}

/// JSON-аргументы → MultiValue для Lua-вызова.
fn args_to_multi(lua: &Lua, args: &Value) -> Result<mlua::MultiValue, String> {
    match args {
        Value::Array(items) => {
            let mut multi = mlua::MultiValue::new();
            for item in items {
                multi.push_back(json_to_lua(lua, item).map_err(|e| e.to_string())?);
            }
            Ok(multi)
        }
        other => {
            let mut multi = mlua::MultiValue::new();
            multi.push_back(json_to_lua(lua, other).map_err(|e| e.to_string())?);
            Ok(multi)
        }
    }
}

/// serde_json → Lua value.
pub fn json_to_lua(lua: &Lua, v: &Value) -> Result<LuaValue, mlua::Error> {
    json_to_lua_depth(lua, v, 0)
}

fn json_to_lua_depth(lua: &Lua, v: &Value, depth: u32) -> Result<LuaValue, mlua::Error> {
    if depth > MAX_LUA_VALUE_DEPTH {
        return Ok(LuaValue::Nil);
    }
    Ok(match v {
        Value::Null => LuaValue::Nil,
        Value::Bool(b) => LuaValue::Boolean(*b),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                LuaValue::Integer(i)
            } else {
                LuaValue::Number(n.as_f64().unwrap_or(0.0))
            }
        }
        Value::String(s) => LuaValue::String(lua.create_string(s)?),
        Value::Array(items) => {
            let t = lua.create_table()?;
            for (i, item) in items.iter().enumerate() {
                t.raw_set(i + 1, json_to_lua_depth(lua, item, depth + 1)?)?;
            }
            LuaValue::Table(t)
        }
        Value::Object(map) => {
            let t = lua.create_table()?;
            for (k, val) in map {
                t.raw_set(k.clone(), json_to_lua_depth(lua, val, depth + 1)?)?;
            }
            LuaValue::Table(t)
        }
    })
}

/// Lua value → serde_json (таблицы: integer-ключи → массив, иначе объект).
pub fn lua_to_json(v: LuaValue) -> Value {
    lua_to_json_depth(v, 0)
}

fn lua_to_json_depth(v: LuaValue, depth: u32) -> Value {
    if depth > MAX_LUA_VALUE_DEPTH {
        return Value::Null;
    }
    match v {
        LuaValue::Nil => Value::Null,
        LuaValue::Boolean(b) => Value::Bool(b),
        LuaValue::Integer(i) => Value::from(i),
        LuaValue::Number(n) => Value::from(n),
        LuaValue::String(s) => Value::String(s.to_string_lossy().to_string()),
        LuaValue::Table(t) => table_to_json(&t, depth).unwrap_or(Value::Null),
        _ => Value::Null,
    }
}

fn table_to_json(t: &Table, depth: u32) -> Result<Value, mlua::Error> {
    let mut seq: Vec<(i64, Value)> = Vec::new();
    let mut map: Map<String, Value> = Map::new();

    // `for_each` — сырой `next`, без метаметода `__pairs`: конвертация не
    // должна исполнять чужой код и не может «соврать» о содержимом.
    t.for_each::<LuaValue, LuaValue>(|k, val| {
        let json = lua_to_json_depth(val, depth + 1);
        match k {
            LuaValue::Integer(i) if i >= 1 => seq.push((i, json)),
            // Нечисловые и «нулевые» ключи в JSON-объект по строке: раньше они
            // молча пропадали, и таблица теряла данные на сохранении.
            LuaValue::Integer(i) => {
                map.insert(i.to_string(), json);
            }
            LuaValue::Number(n) => {
                map.insert(n.to_string(), json);
            }
            LuaValue::String(s) => {
                map.insert(s.to_string_lossy().to_string(), json);
            }
            LuaValue::Boolean(b) => {
                map.insert(b.to_string(), json);
            }
            // Ключ-таблица/функция/поток в JSON не представим — пропускаем.
            _ => {}
        }
        Ok(())
    })?;

    let contiguous = seq
        .iter()
        .enumerate()
        .all(|(i, (key, _))| *key == i as i64 + 1);
    if map.is_empty() && !seq.is_empty() && contiguous {
        seq.sort_by_key(|(i, _)| *i);
        return Ok(Value::Array(seq.into_iter().map(|(_, v)| v).collect()));
    }
    // Смешанная таблица: массива в JSON нет, но и терять половину нельзя —
    // отдаём объект, где числовые ключи тоже стали строками.
    for (i, v) in seq {
        map.insert(i.to_string(), v);
    }
    Ok(Value::Object(map))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runtime::InMemoryScriptRuntimeState;
    use serde_json::json;

    /// Общий помощник: прогнать тело функции и вернуть состояние.
    fn run(body: &str) -> InMemoryScriptRuntimeState {
        let mut session = LuaSession::new();
        let mut state = InMemoryScriptRuntimeState::default();
        let script = format!("function probe() {body} end");
        session
            .call_function(&mut state, Some(&script), "probe", Value::Null)
            .expect("скрипт должен отработать");
        state
    }

    #[test]
    fn sandbox_has_no_files_processes_or_module_loader() {
        // Регрессия дыры: скачанный квест читал `io.open('/etc/hostname')`,
        // вытягивал `os.getenv('HOME')` и грузил чужой .lua через
        // `package.path`/`require`. Ничего из этого в песочнице нет.
        let s = run("core.set_var('io', type(io))
             core.set_var('package', type(package))
             core.set_var('require', type(require))
             core.set_var('dofile', type(dofile))
             core.set_var('loadfile', type(loadfile))
             core.set_var('debug', type(debug))
             core.set_var('dump', type(string.dump))
             core.set_var('execute', type(os.execute))
             core.set_var('getenv', type(os.getenv))
             core.set_var('remove', type(os.remove))
             core.set_var('tmpname', type(os.tmpname))
             core.set_var('time', type(os.time))
             core.set_var('date', type(os.date))");
        for name in [
            "io", "package", "require", "dofile", "loadfile", "debug", "dump", "execute", "getenv",
            "remove", "tmpname",
        ] {
            assert_eq!(
                s.get_variable(name),
                Some(&json!("nil")),
                "{name} доступен из Lua"
            );
        }
        // Часы и дата остаются: авторам нужны даты событий.
        assert_eq!(s.get_variable("time"), Some(&json!("function")));
        assert_eq!(s.get_variable("date"), Some(&json!("function")));
    }

    #[test]
    fn load_accepts_text_chunks_but_not_bytecode() {
        let s = run(
            "local fn, err = load(string.char(27) .. 'Lua' .. string.rep(string.char(0), 8))
             core.set_var('binary_blocked', fn == nil)
             core.set_var('binary_error', tostring(err))
             local ok = load('return 40 + 2')
             core.set_var('text_value', ok())",
        );
        assert_eq!(s.get_variable("binary_blocked"), Some(&json!(true)));
        assert_eq!(s.get_variable("text_value"), Some(&json!(42)));
    }

    #[test]
    fn quest_script_cannot_forge_engine_channels() {
        // Служебные каналы движка (`_internal_*`) — не данные автора: через
        // них ходят ссылки наружу, сохранения и звук. Раньше
        // `core.set_var('_internal_external_commands', {...})` обходил
        // фильтр URL и сам блок `save_operation`.
        let mut session = LuaSession::new();
        let mut state = InMemoryScriptRuntimeState::default();
        session
            .call_function(
                &mut state,
                Some(
                    "function probe()
                         local ok = pcall(core.set_var, '_internal_external_commands', {{type = 'open_link', url = 'file:///etc/passwd'}})
                         core.set_var('write_blocked', not ok)
                         local ok_table = pcall(core.set_table, '_internal_tables', {})
                         core.set_var('table_blocked', not ok_table)
                         core.set_var('read_hidden', tostring(core.get_var('_internal_audio_queue')))
                     end",
                ),
                "probe",
                Value::Null,
            )
            .expect("pcall гасит запрет, сам вызов проходит");
        assert_eq!(state.get_variable("write_blocked"), Some(&json!(true)));
        assert_eq!(state.get_variable("table_blocked"), Some(&json!(true)));
        assert_eq!(state.get_variable("read_hidden"), Some(&json!("nil")));
        assert_eq!(
            state.get_variable("_internal_external_commands"),
            None,
            "запрещённая запись всё-таки легла в канал"
        );
    }

    #[test]
    fn memory_bomb_stops_at_the_limit_instead_of_the_process() {
        let mut session = LuaSession::new();
        let mut state = InMemoryScriptRuntimeState::default();
        let err = session
            .call_function(
                &mut state,
                Some(
                    "function probe() local t = {} for i = 1, 8 do t[i] = string.rep('x', 8 * 1024 * 1024) end end",
                ),
                "probe",
                Value::Null,
            )
            .expect_err("выделение сверх потолка должно стать ошибкой Lua");
        assert!(err.contains("memory"), "не та ошибка: {err}");
    }

    #[test]
    fn oversized_values_and_names_are_rejected() {
        let mut session = LuaSession::new();
        let mut state = InMemoryScriptRuntimeState::default();
        session
            .call_function(
                &mut state,
                Some(
                    "function probe()
                         local big = pcall(core.set_var, 'huge', string.rep('x', 100 * 1024))
                         core.set_var('big_blocked', not big)
                         local long_name = pcall(core.set_var, string.rep('n', 500), 1)
                         core.set_var('name_blocked', not long_name)
                         core.set_var('empty_blocked', not pcall(core.set_var, '', 1))
                     end",
                ),
                "probe",
                Value::Null,
            )
            .expect("pcall не пропускает ошибку наружу");
        assert_eq!(state.get_variable("big_blocked"), Some(&json!(true)));
        assert_eq!(state.get_variable("name_blocked"), Some(&json!(true)));
        assert_eq!(state.get_variable("empty_blocked"), Some(&json!(true)));
        assert_eq!(state.get_variable("huge"), None);
    }

    #[test]
    fn effect_queues_are_bounded_per_call() {
        // Без потолка один цикл кладёт в очередь клиента десятки тысяч команд.
        let mut session = LuaSession::new();
        let mut state = InMemoryScriptRuntimeState::default();
        session
            .call_function(
                &mut state,
                Some(
                    "function probe()
                         local placed = 0
                         for i = 1, 400 do if core.play_sound('hit') then placed = placed + 1 end end
                         core.set_var('placed', placed)
                     end",
                ),
                "probe",
                Value::Null,
            )
            .unwrap();
        let queued = state
            .get_variable("_internal_audio_queue")
            .and_then(Value::as_array)
            .expect("очередь звука");
        assert_eq!(queued.len(), MAX_EFFECTS_PER_CALL);
        assert_eq!(
            state.get_variable("placed"),
            Some(&json!(MAX_EFFECTS_PER_CALL))
        );
    }

    #[test]
    fn pcall_does_not_swallow_the_instruction_limit() {
        // Иначе `while true do pcall(f) end` обходил бы потолок инструкций.
        let mut session = LuaSession::new();
        let mut state = InMemoryScriptRuntimeState::default();
        let err = session
            .call_function(
                &mut state,
                Some(
                    "function probe() local pc = pcall while true do pc(function() local x = 1 end) end end",
                ),
                "probe",
                Value::Null,
            )
            .expect_err("цикл с pcall обязан прерваться");
        assert!(err.contains("инструкц"), "не та ошибка: {err}");
    }

    #[test]
    fn mixed_table_keys_survive_the_conversion() {
        // Раньше `{1, 2, a = 1}` превращалось в `{a = 1}`: числовые элементы
        // сбрасывались, как только в таблице встречался строковый ключ.
        let s = run("core.set_var('mixed', {10, 20, a = 'x'})
             core.set_var('sparse', {[0] = 'zero', [2] = 'two'})
             core.set_var('plain', {7, 8, 9})");
        assert_eq!(
            s.get_variable("mixed"),
            Some(&json!({"1": 10, "2": 20, "a": "x"}))
        );
        assert_eq!(
            s.get_variable("sparse"),
            Some(&json!({"0": "zero", "2": "two"}))
        );
        assert_eq!(s.get_variable("plain"), Some(&json!([7, 8, 9])));
    }

    #[test]
    fn core_set_top_panel_writes_the_block_channel() {
        let mut session = LuaSession::new();
        let mut state = InMemoryScriptRuntimeState::default();
        session
            .call_function(
                &mut state,
                Some(
                    "function probe()
                         core.set_top_panel('hide')
                         core.set_var('after_hide', 1)
                         core.set_top_panel('toggle')
                         core.set_var('after_toggle', 1)
                         core.set_top_panel('мусор')
                     end",
                ),
                "probe",
                Value::Null,
            )
            .unwrap();
        // hide → спрятана, затем toggle → снова видна.
        assert_eq!(
            state.get_variable(TOP_PANEL_HIDDEN_VAR),
            Some(&json!(false))
        );
        assert!(state.get_variable("after_toggle").is_some());
    }

    #[test]
    fn fade_and_save_reuse_block_commands() {
        let mut session = LuaSession::new();
        let mut state = InMemoryScriptRuntimeState::default();
        session
            .call_function(
                &mut state,
                Some(
                    "function probe()
                         core.fade_out(1.5)
                         core.fade_in(0.5)
                         core.save_game('Перед боссом')
                         core.open_saves()
                         core.load_save('Перед боссом')
                         core.delete_save('')
                     end",
                ),
                "probe",
                Value::Null,
            )
            .unwrap();
        assert_eq!(
            state.get_variable("_internal_audio_queue"),
            Some(&json!([
                {"type": "fade_out", "ms": 1500},
                {"type": "fade_in", "ms": 500},
            ]))
        );
        assert_eq!(
            state.get_variable("_internal_external_commands"),
            Some(&json!([
                {"type": "save_game", "slotName": "Перед боссом"},
                {"type": "open_saves"},
                {"type": "load_save", "slotName": "Перед боссом"},
            ])),
            "delete_save без слота ничего не кладёт в очередь"
        );
    }

    #[test]
    fn core_log_reaches_the_engine_log() {
        let mut session = LuaSession::new();
        let mut state = InMemoryScriptRuntimeState::default();
        session
            .call_function(
                &mut state,
                Some("function probe() core.log('hp', 12, {a = 1}) core.log('вторая строка') end"),
                "probe",
                Value::Null,
            )
            .unwrap();
        let logs = session.take_logs();
        assert_eq!(logs.len(), 2);
        assert!(logs[0].starts_with("hp\t12\t"), "не та строка: {}", logs[0]);
        assert_eq!(logs[1], "вторая строка");
        // Забрали один раз — второй раз журнал пуст.
        assert!(session.take_logs().is_empty());
    }

    #[test]
    fn infinite_loop_is_interrupted_not_hung() {
        let mut session = LuaSession::new();
        let mut s = InMemoryScriptRuntimeState::default();
        let err = session
            .call_function(
                &mut s,
                Some("function spin() local i = 0 while true do i = i + 1 end end"),
                "spin",
                Value::Null,
            )
            .expect_err("бесконечный цикл должен прерваться, а не занять поток движка навсегда");
        assert!(err.contains("инструкц"), "не та ошибка: {err}");
    }

    #[test]
    fn ordinary_loop_still_runs() {
        // Потолок не должен ломать честные скрипты: 300k итераций — штатно.
        let mut session = LuaSession::new();
        let mut s = InMemoryScriptRuntimeState::default();
        session
            .call_function(
                &mut s,
                Some("function sum() local acc = 0 for i = 1, 300000 do acc = acc + i end core.set_var('acc', acc) end"),
                "sum",
                Value::Null,
            )
            .unwrap();
        assert_eq!(s.get_variable("acc"), Some(&json!(45_000_150_000_i64)));
    }

    #[test]
    fn cyclic_table_does_not_overflow_stack() {
        let mut session = LuaSession::new();
        let mut s = InMemoryScriptRuntimeState::default();
        session
            .call_function(
                &mut s,
                Some(
                    "function cyc() local t = { name = 'метка' } t.self = t core.set_var('cyc', t) end",
                ),
                "cyc",
                Value::Null,
            )
            .unwrap();

        let mut node = s.get_variable("cyc").cloned().unwrap();
        assert_eq!(node.get("name"), Some(&json!("метка")));
        // Цикл обрезается на потолке глубины: цепочка self конечна и
        // заканчивается null, а не abort процесса переполнением стека.
        for _ in 0..MAX_LUA_VALUE_DEPTH + 5 {
            let next = match node.get("self") {
                Some(v) if v.is_object() => v.clone(),
                _ => {
                    assert_eq!(node.get("self"), Some(&Value::Null));
                    return;
                }
            };
            node = next;
        }
        panic!("циклическая таблица развернулась глубже потолка");
    }

    #[test]
    fn core_table_roundtrip_preserves_structure() {
        let mut session = LuaSession::new();
        let mut s = InMemoryScriptRuntimeState::default();
        session
            .call_function(
                &mut s,
                Some(
                    "function mk() core.set_var('obj', { a = 1, b = 'x', c = { 10, 20 } }) return core.get_var('obj') end",
                ),
                "mk",
                Value::Null,
            )
            .unwrap();
        let obj = s.get_variable("obj").cloned().unwrap();
        assert_eq!(obj.get("a"), Some(&json!(1)));
        assert_eq!(obj.get("b"), Some(&json!("x")));
        assert_eq!(obj.get("c"), Some(&json!([10, 20])));
    }

    #[test]
    fn every_registered_core_function_is_offered_by_completion() {
        // Автодополнение и рантайм расходятся молча: проверка по живому
        // реестру, а не по второму списку в тесте.
        let session = LuaSession::new();
        let core: Table = session.lua.globals().get("core").expect("core таблица");
        let mut registered: Vec<String> = Vec::new();
        for pair in core.pairs::<String, LuaValue>() {
            let (name, _) = pair.expect("ключ core.*");
            registered.push(name);
        }
        registered.sort();
        let mut documented = crate::lua::completion::CORE_API.to_vec();
        documented.sort();
        assert_eq!(
            registered, documented,
            "core.* в рантайме и в автодополнении разъехались"
        );
    }

    #[test]
    fn core_effects_land_on_the_same_channels_as_blocks() {
        // Паритет проверяется не «Lua-функция существует», а тем, что клиент
        // получает побайтово ту же команду, что дала бы кнопка-блок.
        let mut session = LuaSession::new();
        let mut s = InMemoryScriptRuntimeState::default();
        let transition = session
            .call_function(
                &mut s,
                Some(
                    "function f() \
                         core.play_sound('hit', 0.4) \
                         core.play_music('boss_theme', { volume = 0.5, loop = false, global = true }) \
                         core.set_item_visible('btn', 'hide') \
                         core.set_item_image('pic', 'res/images/cat.png') \
                         core.set_volume('contentAudio', 0.3) \
                         core.set_blur(12) \
                         core.open_link('https://example.com/quest') \
                         core.go_to('узел-2') \
                     end",
                ),
                "f",
                Value::Null,
            )
            .expect("эффекты не должны ронять вызов");
        assert_eq!(transition.as_deref(), Some("узел-2"));

        assert_eq!(
            s.get_variable("_internal_audio_queue"),
            Some(&json!([
                {"type": "play_sound", "audio_id": "hit", "volume": 0.4},
                {"type": "play_music", "audio_id": "boss_theme", "loop": false, "volume": 0.5, "global": true},
            ]))
        );
        // Слот активной скриптовой музыки попадает в сейв — как у блока.
        assert_eq!(
            s.get_variable("_internal_active_script_bgm_id"),
            Some(&json!("boss_theme"))
        );
        assert_eq!(
            s.get_variable("_internal_active_script_bgm_volume"),
            Some(&json!(0.5))
        );
        assert_eq!(
            s.get_variable("_internal_active_script_bgm_loop"),
            Some(&json!(false))
        );

        assert_eq!(
            s.get_variable(ITEM_HIDDEN_VAR),
            Some(&json!({"btn": "hidden"}))
        );
        assert_eq!(
            s.get_variable(ITEM_SOURCE_VAR),
            Some(&json!({"pic": "res/images/cat.png"}))
        );
        assert_eq!(
            s.get_variable("_internal_node_content_volume"),
            Some(&json!(0.3))
        );
        // Число, не целое: блок пишет f64, и клиенту важен именно тип числа.
        assert_eq!(
            s.get_variable("_internal_background_blur"),
            Some(&json!(12.0))
        );
        assert_eq!(
            s.get_variable("_internal_external_commands"),
            Some(&json!([{"type": "open_link", "url": "https://example.com/quest"}]))
        );
    }

    #[test]
    fn core_set_item_visible_reuses_block_mode_semantics() {
        let mut session = LuaSession::new();
        let mut s = InMemoryScriptRuntimeState::default();
        session
            .call_function(
                &mut s,
                Some(
                    "function f() \
                         core.set_item_visible('a', 'gone') \
                         core.set_item_visible('b', 'переключить') \
                         core.set_item_visible('c', false) \
                         core.set_item_visible('d', 'мусор') \
                     end",
                ),
                "f",
                Value::Null,
            )
            .unwrap();
        let overrides = s.get_variable(ITEM_HIDDEN_VAR).cloned().unwrap();
        assert_eq!(overrides.get("a"), Some(&json!("gone")));
        // toggle прятает с сохранением места, а не схлопывает ряд.
        assert_eq!(overrides.get("b"), Some(&json!("hidden")));
        // Булево — старый формат блока: false значит «убран».
        assert_eq!(overrides.get("c"), Some(&json!("gone")));
        // Нераспознанный режим — ничего не записано, ровно как в блоке.
        assert_eq!(overrides.get("d"), None);
    }

    #[test]
    fn core_open_link_blocks_the_same_urls_the_block_blocks() {
        let mut session = LuaSession::new();
        let mut s = InMemoryScriptRuntimeState::default();
        session
            .call_function(
                &mut s,
                Some(
                    "function f() \
                         core.set_var('ok', core.open_link('http://127.0.0.1:8080/admin')) \
                         core.set_var('scheme', core.open_link('file:///etc/passwd')) \
                         core.set_var('good', core.open_link('https://example.com')) \
                     end",
                ),
                "f",
                Value::Null,
            )
            .unwrap();
        assert_eq!(s.get_variable("ok"), Some(&json!(false)));
        assert_eq!(s.get_variable("scheme"), Some(&json!(false)));
        assert_eq!(s.get_variable("good"), Some(&json!(true)));
        assert_eq!(
            s.get_variable("_internal_external_commands"),
            Some(&json!([{"type": "open_link", "url": "https://example.com"}])),
            "заблокированная ссылка не должна лечь в очередь"
        );
    }

    #[test]
    fn core_go_to_wins_over_returned_table() {
        let mut session = LuaSession::new();
        let mut s = InMemoryScriptRuntimeState::default();
        let transition = session
            .call_function(
                &mut s,
                Some("function f() core.go_to('явный') return { node = 'из возврата' } end"),
                "f",
                Value::Null,
            )
            .unwrap();
        assert_eq!(transition.as_deref(), Some("явный"));
    }

    #[test]
    fn lua_double_equal_numbers_not_flattened_to_int() {
        let mut session = LuaSession::new();
        let mut s = InMemoryScriptRuntimeState::default();
        session
            .call_function(
                &mut s,
                Some("function f(x) core.set_var('v', x) end"),
                "f",
                Value::from(2.5),
            )
            .unwrap();
        assert_eq!(s.get_variable("v"), Some(&json!(2.5)));
    }
}
