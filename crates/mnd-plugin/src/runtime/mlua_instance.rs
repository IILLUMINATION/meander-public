//! Реализация [`PluginInstance`] поверх `mlua`: песочница, API `mnd.*` и сбор
//! «исхода» вызова. Общие типы останнего — в `crate::runtime`, там же и
//! веб-заглушка (`stub`), поднимающая ту же сигнатуру без Lua.

use std::sync::{Arc, Mutex};

use mlua::{
    Function, HookTriggers, Lua, LuaOptions, MultiValue, StdLib, Table, Value as LuaValue, VmState,
};
use serde_json::{Map, Value};

use mnd_core::lua::{json_to_lua, lua_to_json};

use super::{
    ActiveCall, Bridge, CallContext, EmittedEvent, InvocationOutcome, LogEntry, LogLevel,
    PluginError,
};
use crate::events;
use crate::manifest::PluginManifest;
use crate::policy::{Limits, Permission, Policy};
use crate::spec;

/// Глобальное имя реестра подписок, заведённых `mnd.on`.
const HANDLERS_REGISTRY: &str = "__mnd_handlers";

/// За скольки VM-инструкций срабатывает ловушка циклов.
const INSTRUCTION_BATCH: u32 = 2_000;

/// Экземпляр плагина: манифест + политика + своё Lua-состояние.
pub struct PluginInstance {
    manifest: PluginManifest,
    policy: Policy,
    lua: Lua,
    bridge: Arc<Mutex<Bridge>>,
    /// Потраченные VM-инструкции текущего вызова.
    spent: Arc<Mutex<u64>>,
    instruction_budget: u64,
}

impl PluginInstance {
    /// Собрать плагин: проверить манифест, поднять песочницу, загрузить код.
    ///
    /// `source` — содержимое `entry`-файла (читает клиент), `storage` —
    /// ранее сохранённый снимок хранилища. Ошибкой считается только то, без
    /// чего плагин не запускается; ошибки внутри хуков возвращаются в
    /// [`InvocationOutcome::error`].
    pub fn new(
        manifest: PluginManifest,
        source: &str,
        storage: Option<Value>,
    ) -> Result<Self, PluginError> {
        let mut errors = manifest.validate().err().unwrap_or_default();
        let (policy, permission_errors) = Policy::from_names(&manifest.permissions);
        errors.extend(permission_errors);
        if !errors.is_empty() {
            return Err(PluginError(errors));
        }

        let limits = policy.limits().clone();
        // Только вычисления и данные: `base` (обязательная) без `load`/`dofile`,
        // и `os`/`io`/`debug`/`package` сюда не входят.
        let lua = Lua::new_with(
            StdLib::TABLE | StdLib::STRING | StdLib::MATH,
            LuaOptions::default(),
        )
        .map_err(|e| PluginError(vec![format!("Lua-состояние не поднялось: {e}")]))?;
        lua.set_memory_limit(limits.lua_memory_bytes)
            .map_err(|e| PluginError(vec![format!("память плагина не ограничена: {e}")]))?;

        let instance = Self {
            manifest,
            policy,
            lua,
            bridge: Arc::new(Mutex::new(Bridge {
                active: None,
                storage: match storage {
                    Some(Value::Object(map)) => map,
                    _ => Map::new(),
                },
                storage_dirty: false,
            })),
            spent: Arc::new(Mutex::new(0)),
            instruction_budget: limits.max_instructions_per_call,
        };

        instance.install_sandbox();
        instance.install_api();
        instance.install_loop_guard();

        if let Err(e) = instance
            .lua
            .load(source)
            .set_name(instance.manifest.entry.clone())
            .exec()
        {
            return Err(PluginError(vec![format!(
                "{}: '{}' не загрузилось: {e}",
                instance.manifest.id, instance.manifest.entry
            )]));
        }
        Ok(instance)
    }

    pub fn manifest(&self) -> &PluginManifest {
        &self.manifest
    }

    pub fn id(&self) -> &str {
        &self.manifest.id
    }

    pub fn policy(&self) -> &Policy {
        &self.policy
    }

    /// Снимок хранилища плагина — клиент сохраняет его под своим ключом.
    pub fn storage(&self) -> Value {
        Value::Object(self.bridge.lock().unwrap().storage.clone())
    }

    /// Вызывать ли плагин на это событие: декларация в манифесте или живой
    /// `mnd.on(...)`.
    pub fn subscribes_to(&self, event: &str) -> bool {
        self.manifest.hooks.iter().any(|h| h == event) || self.has_registered_handler(event)
    }

    /// Выполнить хуки события. Ошибку не возвращает — она в исходе.
    pub fn invoke_event(
        &mut self,
        event: &str,
        payload: Value,
        context: &CallContext,
    ) -> InvocationOutcome {
        if !events::is_declareable(event) {
            return InvocationOutcome::failed(
                &self.manifest.id,
                format!(
                    "события '{event}' нет в EventContract v{} и это не custom.*",
                    crate::EVENT_CONTRACT_VERSION
                ),
            );
        }
        if !self.subscribes_to(event) {
            return InvocationOutcome::empty(&self.manifest.id);
        }
        let handlers = self.handlers_for(event);
        self.begin(event, &payload, context);
        let arg = json_to_lua(&self.lua, &payload).unwrap_or(LuaValue::Nil);
        let mut outcome = InvocationOutcome::empty(&self.manifest.id);
        for handler in &handlers {
            if let Err(e) = handler.call::<LuaValue>((arg.clone(),)) {
                outcome.error = Some(format!("{}: {e}", self.manifest.id));
                break;
            }
        }
        self.finish(&mut outcome);
        outcome
    }

    /// Прямой вызов функции плагина (кнопка слота, пункт меню, тип контента).
    /// `args`: массив распаковывается в позиционные аргументы, остальное —
    /// один аргумент; он же доступен как `mnd.payload`.
    pub fn call_function(
        &mut self,
        name: &str,
        args: Value,
        context: &CallContext,
    ) -> InvocationOutcome {
        let Ok(function) = self.lua.globals().get::<Function>(name) else {
            return InvocationOutcome::failed(
                &self.manifest.id,
                format!("функция '{name}' не найдена"),
            );
        };
        self.begin("", &args, context);
        let mut outcome = InvocationOutcome::empty(&self.manifest.id);
        match args_to_lua(&self.lua, &args) {
            Ok(multi) => {
                if let Err(e) = function.call::<LuaValue>(multi) {
                    outcome.error = Some(format!("{name}: {e}"));
                }
            }
            Err(e) => outcome.error = Some(e),
        }
        self.finish(&mut outcome);
        outcome
    }

    fn has_registered_handler(&self, event: &str) -> bool {
        self.handler_list(event)
            .map(|list| list.raw_len() > 0)
            .unwrap_or(false)
    }

    fn handler_list(&self, event: &str) -> Result<Table, mlua::Error> {
        let registry = self.lua.globals().get::<Table>(HANDLERS_REGISTRY)?;
        registry.get::<Table>(event)
    }

    /// Обработчики события: подписанные `mnd.on`, затем соглашение
    /// `on_<event>` (оно осмысленно только для событий движка — имя
    /// `on_custom.foo` не является Lua-идентификатором).
    fn handlers_for(&self, event: &str) -> Vec<Function> {
        let mut handlers = Vec::new();
        if let Ok(list) = self.handler_list(event) {
            handlers.extend(
                list.pairs::<LuaValue, Function>()
                    .flatten()
                    .map(|(_, handler)| handler),
            );
        }
        if events::is_known(event)
            && let Ok(handler) = self
                .lua
                .globals()
                .get::<Function>(events::handler_name(event))
        {
            handlers.push(handler);
        }
        handlers
    }

    /// Запретить загрузку нового кода и вывод мимо логов.
    fn install_sandbox(&self) {
        let globals = self.lua.globals();
        for name in [
            "load", "loadfile", "dofile", "require", "getfenv", "setfenv", "print",
        ] {
            let _ = globals.set(name, LuaValue::Nil);
        }
        // В выбранном наборе stdlib этих таблиц нет; обнуляем на случай
        // изменений в будущих версиях mlua/Lua.
        for name in ["os", "io", "package", "debug"] {
            let _ = globals.set(name, LuaValue::Nil);
        }
        // `string.dump` отдаёт байткод: загрузить его обратно нельзя (`load`
        // выключен), но и отдавать наружу незачем.
        if let Ok(string) = globals.get::<mlua::Table>("string") {
            let _ = string.set("dump", LuaValue::Nil);
        }
        let registry = self.lua.create_table().expect("реестр хуков");
        let _ = globals.set(HANDLERS_REGISTRY, registry);
    }

    fn install_api(&self) {
        let mnd = self.lua.create_table().expect("таблица mnd");
        let _ = mnd.set("pluginId", self.manifest.id.clone());
        let _ = mnd.set("pluginName", self.manifest.name.clone());
        let _ = mnd.set("contractVersion", crate::EVENT_CONTRACT_VERSION);

        self.install_log(&mnd);
        self.install_vars(&mnd);
        self.install_ui(&mnd);
        self.install_game(&mnd);
        self.install_audio(&mnd);
        self.install_storage(&mnd);
        self.install_events_api(&mnd);

        self.lua.globals().set("mnd", mnd).expect("globals mnd");
    }

    /// Ловушка бесконечных циклов: раз в `INSTRUCTION_BATCH` инструкций
    /// сравниваем расход с бюджетом и прерываем вызов ошибкой.
    fn install_loop_guard(&self) {
        let spent = self.spent.clone();
        let budget = self.instruction_budget;
        let installed = self.lua.set_hook(
            HookTriggers::new().every_nth_instruction(INSTRUCTION_BATCH),
            move |_, _| {
                let used = {
                    let mut spent = spent.lock().unwrap();
                    *spent += INSTRUCTION_BATCH as u64;
                    *spent
                };
                if used > budget {
                    return Err(mlua::Error::RuntimeError(format!(
                        "превышен бюджет Lua-инструкций за вызов ({budget})"
                    )));
                }
                Ok(VmState::Continue)
            },
        );
        debug_assert!(installed.is_ok(), "ловушка циклов не поставлена");
    }

    /// `mnd.log.info/warn/error(text)`
    fn install_log(&self, mnd: &Table) {
        let log = self.lua.create_table().expect("mnd.log");
        for level in [LogLevel::Info, LogLevel::Warn, LogLevel::Error] {
            let bridge = self.bridge.clone();
            let plugin_id = self.manifest.id.clone();
            let max_logs = self.policy.limits().max_logs_per_call;
            let name = match level {
                LogLevel::Info => "info",
                LogLevel::Warn => "warn",
                LogLevel::Error => "error",
            };
            let handler = self
                .lua
                .create_function(move |_, text: String| {
                    let mut bridge = bridge.lock().unwrap();
                    let Some(active) = bridge.active.as_mut() else {
                        return Ok(());
                    };
                    if active.logs.len() >= max_logs {
                        return Err(mlua::Error::RuntimeError(format!(
                            "mnd.log: лимит {max_logs} записей за вызов"
                        )));
                    }
                    active.logs.push(LogEntry {
                        plugin_id: plugin_id.clone(),
                        level,
                        text,
                    });
                    Ok(())
                })
                .expect("функция mnd.log");
            let _ = log.set(name, handler);
        }
        let _ = mnd.set("log", log);
    }

    /// `mnd.vars.get/set/has/keys` — переменные квеста (право `quest`).
    /// Запись сразу видна последующим чтениям этого же вызова, а наружу
    /// уходит только факт записи (дифф), а не весь снимок.
    fn install_vars(&self, mnd: &Table) {
        let vars = self.lua.create_table().expect("mnd.vars");

        let get = {
            let bridge = self.bridge.clone();
            let policy = self.policy.clone();
            self.lua
                .create_function(move |lua, name: String| -> Result<LuaValue, mlua::Error> {
                    require(&policy, Permission::Quest, "mnd.vars.get")?;
                    let value = {
                        let bridge = bridge.lock().unwrap();
                        bridge
                            .active
                            .as_ref()
                            .and_then(|active| active.vars.get(&name))
                            .cloned()
                            .unwrap_or(Value::Null)
                    };
                    json_to_lua(lua, &value)
                })
                .expect("mnd.vars.get")
        };

        let set = {
            let bridge = self.bridge.clone();
            let policy = self.policy.clone();
            let limits = self.policy.limits().clone();
            self.lua
                .create_function(
                    move |_, (name, value): (String, LuaValue)| -> Result<(), mlua::Error> {
                        require(&policy, Permission::Quest, "mnd.vars.set")?;
                        let json = lua_to_json(value);
                        check_json_size(&json, limits.max_storage_value_len, "mnd.vars.set")?;
                        let mut bridge = bridge.lock().unwrap();
                        let Some(active) = bridge.active.as_mut() else {
                            return Err(outside_call("mnd.vars.set"));
                        };
                        active.var_writes.insert(name.clone(), json.clone());
                        active.vars.insert(name, json);
                        Ok(())
                    },
                )
                .expect("mnd.vars.set")
        };

        let has = {
            let bridge = self.bridge.clone();
            let policy = self.policy.clone();
            self.lua
                .create_function(move |_, name: String| -> Result<bool, mlua::Error> {
                    require(&policy, Permission::Quest, "mnd.vars.has")?;
                    let bridge = bridge.lock().unwrap();
                    Ok(bridge
                        .active
                        .as_ref()
                        .is_some_and(|active| active.vars.contains_key(&name)))
                })
                .expect("mnd.vars.has")
        };

        let keys = {
            let bridge = self.bridge.clone();
            let policy = self.policy.clone();
            self.lua
                .create_function(move |lua, _: ()| -> Result<LuaValue, mlua::Error> {
                    require(&policy, Permission::Quest, "mnd.vars.keys")?;
                    let names: Vec<Value> = {
                        let bridge = bridge.lock().unwrap();
                        bridge
                            .active
                            .as_ref()
                            .map(|active| {
                                active
                                    .vars
                                    .keys()
                                    .map(|k| Value::String(k.clone()))
                                    .collect()
                            })
                            .unwrap_or_default()
                    };
                    json_to_lua(lua, &Value::Array(names))
                })
                .expect("mnd.vars.keys")
        };

        let _ = vars.set("get", get);
        let _ = vars.set("set", set);
        let _ = vars.set("has", has);
        let _ = vars.set("keys", keys);
        let _ = mnd.set("vars", vars);
    }

    /// `mnd.ui.toast/render/close` — декларативный UI (право `ui`).
    fn install_ui(&self, mnd: &Table) {
        let ui = self.lua.create_table().expect("mnd.ui");

        let toast = {
            let bridge = self.bridge.clone();
            let policy = self.policy.clone();
            let limits = self.policy.limits().clone();
            self.lua
                .create_function(
                    move |_, (text, duration): (String, Option<u32>)| -> Result<(), mlua::Error> {
                        require(&policy, Permission::Ui, "mnd.ui.toast")?;
                        check_len(&text, limits.max_text_len, "mnd.ui.toast")?;
                        push_command(
                            &bridge,
                            &limits,
                            "toast",
                            &[
                                ("text", Value::String(text)),
                                ("durationMs", Value::from(duration.unwrap_or(3000) as i64)),
                            ],
                        )
                    },
                )
                .expect("mnd.ui.toast")
        };

        let render = {
            let bridge = self.bridge.clone();
            let policy = self.policy.clone();
            let limits = self.policy.limits().clone();
            let manifest = self.manifest.clone();
            self.lua
                .create_function(
                    move |_, (target, spec_value): (String, LuaValue)| -> Result<(), mlua::Error> {
                        require(&policy, Permission::Ui, "mnd.ui.render")?;
                        check_target(&manifest, &target)?;
                        let widget_spec = lua_to_json(spec_value);
                        spec::validate(&widget_spec, &limits).map_err(spec_error)?;
                        push_command(
                            &bridge,
                            &limits,
                            "render",
                            &[("target", Value::String(target)), ("spec", widget_spec)],
                        )
                    },
                )
                .expect("mnd.ui.render")
        };

        let close = {
            let bridge = self.bridge.clone();
            let policy = self.policy.clone();
            let limits = self.policy.limits().clone();
            self.lua
                .create_function(move |_, target: String| -> Result<(), mlua::Error> {
                    require(&policy, Permission::Ui, "mnd.ui.close")?;
                    push_command(
                        &bridge,
                        &limits,
                        "close",
                        &[("target", Value::String(target))],
                    )
                })
                .expect("mnd.ui.close")
        };

        let _ = ui.set("toast", toast);
        let _ = ui.set("render", render);
        let _ = ui.set("close", close);
        let _ = mnd.set("ui", ui);
    }

    /// `mnd.game.go(node)` — переход по нодам (право `navigation`).
    fn install_game(&self, mnd: &Table) {
        let game = self.lua.create_table().expect("mnd.game");
        let goto = {
            let bridge = self.bridge.clone();
            let policy = self.policy.clone();
            let limits = self.policy.limits().clone();
            self.lua
                .create_function(move |_, node: String| -> Result<(), mlua::Error> {
                    require(&policy, Permission::Navigation, "mnd.game.go")?;
                    check_len(&node, limits.max_text_len, "mnd.game.go")?;
                    push_command(
                        &bridge,
                        &limits,
                        "goto_node",
                        &[("node", Value::String(node))],
                    )
                })
                .expect("mnd.game.go")
        };
        let _ = game.set("go", goto);
        let _ = mnd.set("game", game);
    }

    /// `mnd.audio.play/stop` — звук через плеер (право `audio`).
    fn install_audio(&self, mnd: &Table) {
        let audio = self.lua.create_table().expect("mnd.audio");

        let play = {
            let bridge = self.bridge.clone();
            let policy = self.policy.clone();
            let limits = self.policy.limits().clone();
            self.lua
                .create_function(
                    move |_, (asset, volume): (String, Option<f64>)| -> Result<(), mlua::Error> {
                        require(&policy, Permission::Audio, "mnd.audio.play")?;
                        check_len(&asset, limits.max_text_len, "mnd.audio.play")?;
                        push_command(
                            &bridge,
                            &limits,
                            "play_sound",
                            &[
                                ("asset", Value::String(asset)),
                                ("volume", Value::from(volume.unwrap_or(1.0).clamp(0.0, 1.0))),
                            ],
                        )
                    },
                )
                .expect("mnd.audio.play")
        };

        let stop = {
            let bridge = self.bridge.clone();
            let policy = self.policy.clone();
            let limits = self.policy.limits().clone();
            self.lua
                .create_function(move |_, asset: Option<String>| -> Result<(), mlua::Error> {
                    require(&policy, Permission::Audio, "mnd.audio.stop")?;
                    let fields: Vec<(&str, Value)> = match asset {
                        Some(asset) => vec![("asset", Value::String(asset))],
                        None => Vec::new(),
                    };
                    push_command(&bridge, &limits, "stop_audio", &fields)
                })
                .expect("mnd.audio.stop")
        };

        let _ = audio.set("play", play);
        let _ = audio.set("stop", stop);
        let _ = mnd.set("audio", audio);
    }

    /// `mnd.storage.*` — собственное хранилище (право `storage`). Персист
    /// обеспечивает клиент: хост отдаёт снимок, когда `storageDirty`.
    fn install_storage(&self, mnd: &Table) {
        let storage = self.lua.create_table().expect("mnd.storage");

        let get = {
            let bridge = self.bridge.clone();
            let policy = self.policy.clone();
            self.lua
                .create_function(move |lua, key: String| -> Result<LuaValue, mlua::Error> {
                    require(&policy, Permission::Storage, "mnd.storage.get")?;
                    let value = {
                        let bridge = bridge.lock().unwrap();
                        bridge.storage.get(&key).cloned().unwrap_or(Value::Null)
                    };
                    json_to_lua(lua, &value)
                })
                .expect("mnd.storage.get")
        };

        let set = {
            let bridge = self.bridge.clone();
            let policy = self.policy.clone();
            let limits = self.policy.limits().clone();
            self.lua
                .create_function(
                    move |_, (key, value): (String, LuaValue)| -> Result<(), mlua::Error> {
                        require(&policy, Permission::Storage, "mnd.storage.set")?;
                        check_len(&key, 128, "mnd.storage.set")?;
                        let json = lua_to_json(value);
                        check_json_size(&json, limits.max_storage_value_len, "mnd.storage.set")?;
                        let mut bridge = bridge.lock().unwrap();
                        if !bridge.storage.contains_key(&key)
                            && bridge.storage.len() >= limits.max_storage_keys
                        {
                            return Err(mlua::Error::RuntimeError(format!(
                                "mnd.storage: лимит {} ключей",
                                limits.max_storage_keys
                            )));
                        }
                        bridge.storage.insert(key, json);
                        bridge.storage_dirty = true;
                        Ok(())
                    },
                )
                .expect("mnd.storage.set")
        };

        let delete = {
            let bridge = self.bridge.clone();
            let policy = self.policy.clone();
            self.lua
                .create_function(move |_, key: String| -> Result<(), mlua::Error> {
                    require(&policy, Permission::Storage, "mnd.storage.delete")?;
                    let mut bridge = bridge.lock().unwrap();
                    if bridge.storage.remove(&key).is_some() {
                        bridge.storage_dirty = true;
                    }
                    Ok(())
                })
                .expect("mnd.storage.delete")
        };

        let keys = {
            let bridge = self.bridge.clone();
            let policy = self.policy.clone();
            self.lua
                .create_function(move |lua, _: ()| -> Result<LuaValue, mlua::Error> {
                    require(&policy, Permission::Storage, "mnd.storage.keys")?;
                    let list: Vec<Value> = {
                        let bridge = bridge.lock().unwrap();
                        bridge
                            .storage
                            .keys()
                            .map(|k| Value::String(k.clone()))
                            .collect()
                    };
                    json_to_lua(lua, &Value::Array(list))
                })
                .expect("mnd.storage.keys")
        };

        let _ = storage.set("get", get);
        let _ = storage.set("set", set);
        let _ = storage.set("delete", delete);
        let _ = storage.set("keys", keys);
        let _ = mnd.set("storage", storage);
    }

    /// `mnd.on/emit/cancel` — подписка, рассылка и отмена поведения по умолчанию.
    fn install_events_api(&self, mnd: &Table) {
        let on = {
            let lua = self.lua.clone();
            let manifest = self.manifest.clone();
            self.lua
                .create_function(move |_, (event, handler): (String, Function)| {
                    if !events::is_declareable(&event) {
                        return Err(mlua::Error::RuntimeError(format!(
                            "mnd.on: '{event}' не событие EventContract v{} и не custom.*",
                            crate::EVENT_CONTRACT_VERSION
                        )));
                    }
                    if !manifest.hooks.iter().any(|hook| hook == &event) {
                        return Err(mlua::Error::RuntimeError(format!(
                            "mnd.on: хук '{event}' не объявлен в манифесте"
                        )));
                    }
                    let globals = lua.globals();
                    let registry = match globals.get::<Table>(HANDLERS_REGISTRY) {
                        Ok(table) => table,
                        Err(_) => {
                            let table = lua.create_table()?;
                            globals.set(HANDLERS_REGISTRY, table.clone())?;
                            table
                        }
                    };
                    let list = match registry.get::<Table>(event.as_str()) {
                        Ok(list) => list,
                        Err(_) => {
                            let list = lua.create_table()?;
                            registry.set(event.as_str(), list.clone())?;
                            list
                        }
                    };
                    list.raw_set(list.raw_len() + 1, handler)?;
                    Ok(())
                })
                .expect("mnd.on")
        };

        let emit = {
            let bridge = self.bridge.clone();
            let policy = self.policy.clone();
            let limits = self.policy.limits().clone();
            self.lua
                .create_function(
                    move |_,
                          (event, payload): (String, Option<LuaValue>)|
                          -> Result<(), mlua::Error> {
                        require(&policy, Permission::Events, "mnd.emit")?;
                        if !events::is_declareable(&event) {
                            return Err(mlua::Error::RuntimeError(format!(
                                "mnd.emit: '{event}' — ожидается имя EventContract или custom.*"
                            )));
                        }
                        let json = lua_to_json(payload.unwrap_or(LuaValue::Nil));
                        check_json_size(&json, limits.max_payload_len, "mnd.emit")?;
                        let mut bridge = bridge.lock().unwrap();
                        let Some(active) = bridge.active.as_mut() else {
                            return Err(outside_call("mnd.emit"));
                        };
                        if active.emits.len() >= limits.max_commands_per_call {
                            return Err(mlua::Error::RuntimeError(format!(
                                "mnd.emit: лимит {} событий за вызов",
                                limits.max_commands_per_call
                            )));
                        }
                        active.emits.push(EmittedEvent {
                            event,
                            payload: json,
                        });
                        Ok(())
                    },
                )
                .expect("mnd.emit")
        };

        let cancel = {
            let bridge = self.bridge.clone();
            self.lua
                .create_function(move |_, _: ()| -> Result<(), mlua::Error> {
                    let mut bridge = bridge.lock().unwrap();
                    let Some(active) = bridge.active.as_mut() else {
                        return Err(outside_call("mnd.cancel"));
                    };
                    if !active.event.is_empty() && !events::is_cancelable(&active.event) {
                        return Err(mlua::Error::RuntimeError(format!(
                            "mnd.cancel: событие '{}' не отменяемо",
                            active.event
                        )));
                    }
                    active.cancel = true;
                    Ok(())
                })
                .expect("mnd.cancel")
        };

        let _ = mnd.set("on", on);
        let _ = mnd.set("emit", emit);
        let _ = mnd.set("cancel", cancel);
    }

    /// Открыть вызов: обнулить бюджет, показать входные данные плагину.
    fn begin(&self, event: &str, payload: &Value, context: &CallContext) {
        *self.spent.lock().unwrap() = 0;
        if let Ok(mnd) = self.lua.globals().get::<Table>("mnd") {
            let _ = mnd.set("event", event.to_string());
            let _ = mnd.set("questId", context.quest_id.to_string());
            let _ = mnd.set("nodeId", context.node_id.to_string());
            let _ = mnd.set("now", context.now_ms);
            let _ = mnd.set(
                "payload",
                json_to_lua(&self.lua, payload).unwrap_or(LuaValue::Nil),
            );
        }
        let mut bridge = self.bridge.lock().unwrap();
        bridge.active = Some(ActiveCall {
            event: event.to_string(),
            vars: context.vars.clone(),
            var_writes: Map::new(),
            commands: Vec::new(),
            logs: Vec::new(),
            emits: Vec::new(),
            cancel: false,
        });
    }

    /// Закрыть вызов: забрать накопленное и почистить состояние.
    fn finish(&self, outcome: &mut InvocationOutcome) {
        let mut bridge = self.bridge.lock().unwrap();
        let Some(active) = bridge.active.take() else {
            return;
        };
        outcome.commands = active.commands;
        outcome.var_writes = active.var_writes;
        outcome.logs = active.logs;
        outcome.emits = active.emits;
        outcome.cancel = active.cancel;
        outcome.storage_dirty = bridge.storage_dirty;
        bridge.storage_dirty = false;
        if let Ok(mnd) = self.lua.globals().get::<Table>("mnd") {
            let _ = mnd.set("payload", LuaValue::Nil);
        }
        *self.spent.lock().unwrap() = 0;
    }
}

/// Проверка разрешения. Отказ — ошибка в Lua, а не тихий пропуск.
fn require(policy: &Policy, permission: Permission, api: &str) -> Result<(), mlua::Error> {
    if policy.allows(permission) {
        Ok(())
    } else {
        Err(mlua::Error::RuntimeError(format!(
            "{api}: нет разрешения '{}'",
            permission.name()
        )))
    }
}

fn outside_call(api: &str) -> mlua::Error {
    mlua::Error::RuntimeError(format!("{api}: вызов вне контекста хука"))
}

fn spec_error(errors: Vec<String>) -> mlua::Error {
    mlua::Error::RuntimeError(format!("виджет-спек отклонён: {}", errors.join("; ")))
}

fn push_command(
    bridge: &Arc<Mutex<Bridge>>,
    limits: &Limits,
    kind: &str,
    fields: &[(&str, Value)],
) -> Result<(), mlua::Error> {
    let mut bridge = bridge.lock().unwrap();
    let Some(active) = bridge.active.as_mut() else {
        return Err(outside_call(kind));
    };
    if active.commands.len() >= limits.max_commands_per_call {
        return Err(mlua::Error::RuntimeError(format!(
            "команд: лимит {} за вызов",
            limits.max_commands_per_call
        )));
    }
    let mut object = Map::new();
    object.insert("kind".into(), Value::String(kind.into()));
    for (key, value) in fields {
        object.insert((*key).into(), value.clone());
    }
    active.commands.push(Value::Object(object));
    Ok(())
}

fn check_len(text: &str, max: usize, api: &str) -> Result<(), mlua::Error> {
    if text.chars().count() > max {
        return Err(mlua::Error::RuntimeError(format!(
            "{api}: длина больше лимита {max}"
        )));
    }
    Ok(())
}

fn check_json_size(value: &Value, max: usize, api: &str) -> Result<(), mlua::Error> {
    let size = serde_json::to_string(value).map_or(usize::MAX, |raw| raw.len());
    if size > max {
        return Err(mlua::Error::RuntimeError(format!(
            "{api}: значение больше лимита ({size} > {max} байт)"
        )));
    }
    Ok(())
}

/// Мишень `ui.render`: `slot:<объявленный слот>` | `item:<id>` | `screen`.
fn check_target(manifest: &PluginManifest, target: &str) -> Result<(), mlua::Error> {
    if target == "screen" {
        return Ok(());
    }
    if let Some(id) = target.strip_prefix("slot:") {
        return if manifest.slots.iter().any(|slot| slot.id == id) {
            Ok(())
        } else {
            Err(mlua::Error::RuntimeError(format!(
                "mnd.ui.render: слот '{id}' не объявлен в манифесте"
            )))
        };
    }
    if target
        .strip_prefix("item:")
        .is_some_and(|id| !id.is_empty())
    {
        return Ok(());
    }
    Err(mlua::Error::RuntimeError(format!(
        "mnd.ui.render: мишень '{target}' — ожидается slot:…, item:… или screen"
    )))
}

/// Аргументы вызова: массив распаковывается в позиционные аргументы.
fn args_to_lua(lua: &Lua, args: &Value) -> Result<MultiValue, String> {
    let mut multi = MultiValue::new();
    match args {
        Value::Array(items) => {
            for item in items {
                multi.push_back(json_to_lua(lua, item).map_err(|e| e.to_string())?);
            }
        }
        other => multi.push_back(json_to_lua(lua, other).map_err(|e| e.to_string())?),
    }
    Ok(multi)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::{ContentTypeDecl, FieldDecl, FieldKind, SlotDecl};
    use serde_json::json;

    fn manifest(permissions: &[&str], hooks: &[&str]) -> PluginManifest {
        PluginManifest {
            id: "com.example.t".into(),
            name: "T".into(),
            version: "1.0.0".into(),
            sdk: crate::SDK_VERSION.into(),
            entry: "main.lua".into(),
            description: None,
            author: None,
            icon: None,
            tags: vec![],
            permissions: permissions.iter().map(|s| s.to_string()).collect(),
            hooks: hooks.iter().map(|s| s.to_string()).collect(),
            content_types: vec![ContentTypeDecl {
                id: "counter".into(),
                name: "Счётчик".into(),
                description: None,
                icon: None,
                fields: vec![FieldDecl {
                    key: "step".into(),
                    label: "Шаг".into(),
                    kind: FieldKind::Number,
                    default: Some(json!(1)),
                    options: vec![],
                    min: None,
                    max: None,
                    hint: None,
                }],
                preview: None,
            }],
            slots: vec![SlotDecl {
                id: "topRight".into(),
                area: "hud".into(),
                priority: 0,
            }],
        }
    }

    fn build(
        permissions: &[&str],
        hooks: &[&str],
        source: &str,
    ) -> Result<PluginInstance, PluginError> {
        PluginInstance::new(manifest(permissions, hooks), source, None)
    }

    fn empty() -> Map<String, Value> {
        Map::new()
    }

    fn context(vars: &Map<String, Value>) -> CallContext<'_> {
        CallContext {
            quest_id: "q1",
            node_id: "start",
            vars,
            now_ms: 1000,
        }
    }

    /// Плагин обязан был НЕ собраться: возвращаем текст ошибки.
    fn build_error(permissions: &[&str], hooks: &[&str], source: &str, what: &str) -> PluginError {
        match build(permissions, hooks, source) {
            Ok(_) => panic!("{what}: плагин собрался, хотя не должен"),
            Err(e) => e,
        }
    }

    fn direct(plugin: &mut PluginInstance, name: &str) -> InvocationOutcome {
        plugin.call_function(name, Value::Null, &context(&empty()))
    }

    #[test]
    fn sandbox_has_no_io_os_or_code_loading() {
        let source = r#"
        function probe()
          mnd.vars.set('io', type(io))
          mnd.vars.set('os', type(os))
          mnd.vars.set('pkg', type(package))
          mnd.vars.set('dbg', type(debug))
          mnd.vars.set('load', type(load))
          mnd.vars.set('require', type(require))
          mnd.vars.set('print', type(print))
          mnd.vars.set('math', type(math.floor))
          mnd.vars.set('string', type(string.format))
          mnd.vars.set('table', type(table.concat))
        end"#;
        let mut plugin = build(&["quest"], &[], source).unwrap();
        let outcome = direct(&mut plugin, "probe");
        assert_eq!(outcome.error, None, "{:?}", outcome.error);
        let written = |key: &str| outcome.var_writes.get(key).cloned();
        assert_eq!(written("io"), Some(json!("nil")));
        assert_eq!(written("os"), Some(json!("nil")));
        assert_eq!(written("pkg"), Some(json!("nil")));
        assert_eq!(written("dbg"), Some(json!("nil")));
        assert_eq!(written("load"), Some(json!("nil")));
        assert_eq!(written("require"), Some(json!("nil")));
        assert_eq!(written("print"), Some(json!("nil")));
        // вычисления остаются: плагин — не «только вызовы API»
        assert_eq!(written("math"), Some(json!("function")));
        assert_eq!(written("string"), Some(json!("function")));
        assert_eq!(written("table"), Some(json!("function")));
    }

    #[test]
    fn permission_denial_is_an_error_not_a_silent_skip() {
        let mut plugin = build(&[], &[], "function f() mnd.ui.toast('нет прав') end").unwrap();
        let outcome = direct(&mut plugin, "f");
        let error = outcome.error.expect("ошибка должна быть");
        assert!(error.contains("нет разрешения 'ui'"), "{error}");
        assert!(outcome.commands.is_empty());
    }

    #[test]
    fn commands_keep_call_order() {
        let source = r#"
        function f()
          mnd.ui.toast('привет', 500)
          mnd.ui.render('slot:topRight', { type = 'text', text = 'HP 10' })
          mnd.audio.play('door.mp3', 0.5)
          mnd.game.go('end')
        end"#;
        let mut plugin = build(&["ui", "audio", "navigation"], &[], source).unwrap();
        let outcome = direct(&mut plugin, "f");
        assert_eq!(outcome.error, None, "{:?}", outcome.error);
        assert_eq!(outcome.commands.len(), 4);
        assert_eq!(outcome.commands[0]["kind"], json!("toast"));
        assert_eq!(outcome.commands[0]["text"], json!("привет"));
        assert_eq!(outcome.commands[0]["durationMs"], json!(500));
        assert_eq!(outcome.commands[1]["target"], json!("slot:topRight"));
        assert_eq!(outcome.commands[2]["kind"], json!("play_sound"));
        assert_eq!(outcome.commands[2]["volume"], json!(0.5));
        assert_eq!(outcome.commands[3]["node"], json!("end"));
    }

    #[test]
    fn invalid_spec_and_unknown_slot_are_rejected() {
        let source = r#"
        function badSlot()
          mnd.ui.render('slot:nope', { type = 'text', text = 'x' })
        end
        function badType()
          mnd.ui.render('slot:topRight', { type = 'definitely-not-a-widget' })
        end
        function codeInProp()
          mnd.ui.render('slot:topRight', { type = 'button', onPress = 'os.execute("x")' })
        end"#;
        let mut plugin = build(&["ui"], &[], source).unwrap();
        let outcome = direct(&mut plugin, "badSlot");
        assert!(outcome.error.expect("слот").contains("не объявлен"));
        let outcome = direct(&mut plugin, "badType");
        assert!(outcome.error.expect("тип").contains("виджет-спек"));
        let outcome = direct(&mut plugin, "codeInProp");
        assert!(
            outcome.error.expect("обработчик").contains("виджет-спек"),
            "значение onPress должно быть именем функции, а не кодом"
        );
    }

    #[test]
    fn var_writes_are_last_value_and_do_not_touch_the_caller_snapshot() {
        let source = r#"
        function f()
          mnd.vars.set('hp', mnd.vars.get('hp') - 1)
          mnd.vars.set('hp', mnd.vars.get('hp') - 1)
          mnd.vars.set('seen', true)
        end"#;
        let mut plugin = build(&["quest"], &[], source).unwrap();
        let mut initial = Map::new();
        initial.insert("hp".into(), json!(5));
        let outcome = plugin.call_function("f", Value::Null, &context(&initial));
        assert_eq!(outcome.error, None, "{:?}", outcome.error);
        assert_eq!(outcome.var_writes.get("hp"), Some(&json!(3)));
        assert_eq!(outcome.var_writes.get("seen"), Some(&json!(true)));
        // снимок вызывающего не мутируется
        assert_eq!(initial.get("hp"), Some(&json!(5)));
    }

    #[test]
    fn storage_roundtrips_and_marks_dirty_once() {
        let source = r#"
        function put() mnd.storage.set('seen', { a = 1, b = { 'x' } }) end
        function read() mnd.vars.set('a', mnd.storage.get('seen').a) end
        function drop() mnd.storage.delete('seen') end"#;
        let mut plugin = build(&["storage", "quest"], &[], source).unwrap();
        let outcome = direct(&mut plugin, "put");
        assert_eq!(outcome.error, None, "{:?}", outcome.error);
        assert!(outcome.storage_dirty);
        let stored = plugin.storage();
        assert_eq!(stored["seen"]["a"], json!(1));
        assert_eq!(stored["seen"]["b"][0], json!("x"));

        let outcome = direct(&mut plugin, "read");
        assert_eq!(outcome.var_writes.get("a"), Some(&json!(1)));
        assert!(!outcome.storage_dirty, "чтение не делает хранилище грязным");

        let outcome = direct(&mut plugin, "drop");
        assert!(outcome.storage_dirty);
        assert_eq!(plugin.storage(), json!({}));
    }

    #[test]
    fn restored_storage_is_visible_to_the_plugin() {
        let mut manifest = manifest(&["storage"], &[]);
        manifest.permissions.push("quest".into());
        let mut plugin = PluginInstance::new(
            manifest,
            "function f() mnd.vars.set('x', mnd.storage.get('counter')) end",
            Some(json!({ "counter": 7 })),
        )
        .unwrap();
        let outcome = direct(&mut plugin, "f");
        assert_eq!(outcome.var_writes.get("x"), Some(&json!(7)));
    }

    #[test]
    fn hooks_run_from_mnd_on_and_from_the_conventional_name() {
        let source = r#"
        mnd.on('item_press', function(payload)
          mnd.vars.set('lastItem', payload.itemId)
        end)
        function on_node_enter(payload)
          mnd.vars.set('entered', payload.nodeId)
        end"#;
        let mut plugin = build(&["quest"], &["item_press", "node_enter"], source).unwrap();
        let outcome = plugin.invoke_event(
            "item_press",
            json!({ "itemId": "key", "nodeId": "start" }),
            &context(&empty()),
        );
        assert_eq!(outcome.error, None, "{:?}", outcome.error);
        assert_eq!(outcome.var_writes.get("lastItem"), Some(&json!("key")));

        let outcome = plugin.invoke_event(
            "node_enter",
            json!({ "nodeId": "door" }),
            &context(&empty()),
        );
        assert_eq!(outcome.error, None, "{:?}", outcome.error);
        assert_eq!(outcome.var_writes.get("entered"), Some(&json!("door")));

        // неподписанное событие вообще не вызывается
        let outcome = plugin.invoke_event("quest_end", json!({}), &context(&empty()));
        assert!(outcome.var_writes.is_empty() && outcome.error.is_none());
    }

    #[test]
    fn mnd_on_needs_a_declared_hook_and_a_real_event() {
        let error = build_error(
            &[],
            &["node_enter"],
            "mnd.on('quest_end', function() end)",
            "хук не объявлен",
        );
        assert!(
            error.0.iter().any(|e| e.contains("не объявлен")),
            "{error:?}"
        );

        let error = build_error(
            &[],
            &["node_enter"],
            "mnd.on('nope', function() end)",
            "нет такого события",
        );
        assert!(
            error.0.iter().any(|e| e.contains("EventContract")),
            "{error:?}"
        );
    }

    #[test]
    fn custom_events_can_be_declared_subscribed_and_emitted() {
        let source = r#"
        mnd.on('custom.combo', function(payload)
          mnd.vars.set('combo', payload.name)
          mnd.emit('custom.comboDone', { name = payload.name })
        end)"#;
        let mut plugin = build(&["quest", "events"], &["custom.combo"], source).unwrap();
        let outcome = plugin.invoke_event(
            "custom.combo",
            json!({ "name": "lock+key" }),
            &context(&empty()),
        );
        assert_eq!(outcome.error, None, "{:?}", outcome.error);
        assert_eq!(outcome.var_writes.get("combo"), Some(&json!("lock+key")));
        assert_eq!(outcome.emits.len(), 1);
        assert_eq!(outcome.emits[0].event, "custom.comboDone");
        assert_eq!(outcome.emits[0].payload, json!({ "name": "lock+key" }));
    }

    #[test]
    fn cancel_works_only_on_cancelable_events() {
        let source = r#"
        function on_node_enter() mnd.cancel() end
        function on_item_press() mnd.cancel() end"#;
        let mut plugin = build(&[], &["node_enter", "item_press"], source).unwrap();
        let outcome =
            plugin.invoke_event("node_enter", json!({ "nodeId": "x" }), &context(&empty()));
        assert!(outcome.cancel, "{:?}", outcome.error);

        let outcome =
            plugin.invoke_event("item_press", json!({ "nodeId": "x" }), &context(&empty()));
        assert!(!outcome.cancel);
        assert!(
            outcome
                .error
                .as_deref()
                .is_some_and(|e| e.contains("не отменяемо")),
            "{:?}",
            outcome.error
        );
    }

    #[test]
    fn infinite_loop_is_cut_by_the_instruction_budget() {
        let mut plugin = build(&["quest"], &[], "function f() while true do end end").unwrap();
        let outcome = direct(&mut plugin, "f");
        let error = outcome.error.expect("бюджет инструкций");
        assert!(error.contains("бюджет Lua-инструкций"), "{error}");
    }

    #[test]
    fn loop_in_plugin_source_is_cut_at_load_time() {
        let error = build_error(
            &[],
            &[],
            "while true do end",
            "бесконечный цикл на загрузке",
        );
        assert!(
            error.0.iter().any(|e| e.contains("бюджет Lua-инструкций")),
            "{error:?}"
        );
    }

    #[test]
    fn command_and_log_limits_are_enforced() {
        let source = r#"
        function spam() for i = 1, 500 do mnd.ui.toast('t') end end
        function noisy() for i = 1, 500 do mnd.log.info('текст') end end"#;
        let mut plugin = build(&["ui", "quest"], &[], source).unwrap();
        let outcome = direct(&mut plugin, "spam");
        assert_eq!(outcome.commands.len(), 64, "команд не больше лимита");
        assert!(outcome.error.expect("лимит команд").contains("лимит"));

        let outcome = direct(&mut plugin, "noisy");
        assert_eq!(outcome.logs.len(), 100);
        assert!(outcome.error.expect("лимит логов").contains("лимит"));
    }

    #[test]
    fn text_and_value_size_limits_are_enforced() {
        let mut plugin = build(&["ui", "quest"], &[], "function f(s) mnd.ui.toast(s) end").unwrap();
        let long = "а".repeat(2001);
        let outcome = plugin.call_function("f", json!([long]), &context(&empty()));
        assert!(
            outcome.error.as_deref().is_some_and(|e| e.contains("длин")),
            "{:?}",
            outcome.error
        );

        let mut plugin =
            build(&["quest"], &[], "function f(v) mnd.vars.set('big', v) end").unwrap();
        let big = Value::String("б".repeat(20_000));
        let outcome = plugin.call_function("f", json!([big]), &context(&empty()));
        assert!(
            outcome
                .error
                .as_deref()
                .is_some_and(|e| e.contains("больше лимита")),
            "{:?}",
            outcome.error
        );
    }

    #[test]
    fn api_outside_a_call_is_an_error() {
        // `mnd.cancel` до begin() — активный вызова нет.
        let plugin = build(&[], &[], "function f() end").unwrap();
        let bridge = plugin.bridge.clone();
        let lua = &plugin.lua;
        let cancel: Function = lua
            .globals()
            .get::<Table>("mnd")
            .unwrap()
            .get("cancel")
            .unwrap();
        assert!(cancel.call::<()>(()).is_err());
        assert!(bridge.lock().unwrap().active.is_none());
    }

    #[test]
    fn plugin_can_read_engine_provided_vars_and_its_identity() {
        let source = r#"
        function f()
          mnd.vars.set('id', mnd.pluginId)
          mnd.vars.set('quest', mnd.questId)
          mnd.vars.set('node', mnd.nodeId)
          mnd.vars.set('event', mnd.event)
          mnd.vars.set('now', mnd.now)
          mnd.vars.set('gold', mnd.vars.get('gold'))
        end"#;
        let mut plugin = build(&["quest"], &[], source).unwrap();
        let mut initial = Map::new();
        initial.insert("gold".into(), json!(42));
        let outcome = plugin.call_function("f", Value::Null, &context(&initial));
        assert_eq!(outcome.error, None, "{:?}", outcome.error);
        assert_eq!(outcome.var_writes.get("id"), Some(&json!("com.example.t")));
        assert_eq!(outcome.var_writes.get("quest"), Some(&json!("q1")));
        assert_eq!(outcome.var_writes.get("node"), Some(&json!("start")));
        assert_eq!(outcome.var_writes.get("event"), Some(&json!("")));
        assert_eq!(outcome.var_writes.get("now"), Some(&json!(1000)));
        assert_eq!(outcome.var_writes.get("gold"), Some(&json!(42)));
    }

    #[test]
    fn missing_function_and_unknown_event_are_reported_not_panicked() {
        let mut plugin = build(&[], &[], "function f() end").unwrap();
        let outcome = direct(&mut plugin, "нетТакойФункции");
        assert!(outcome.error.expect("нет функции").contains("не найдена"));
        let outcome = plugin.invoke_event("nope", json!({}), &context(&empty()));
        assert!(
            outcome
                .error
                .expect("нет события")
                .contains("EventContract")
        );
    }
}
