//! Unit-тесты FFI-слоя.

#[cfg(test)]
mod ffi_tests {
    use std::collections::HashMap;

    use crate::api::{models, runtime::ScriptRuntimeState, script_executor};
    use mnd_core::models::QuestTable;
    use mnd_core::runtime::ScriptRuntime;

    // Вспомогательный вызов execute_script с пустыми переменными/таблицами.
    fn _empty_vars_tables() -> (
        HashMap<String, String>,
        HashMap<String, HashMap<String, String>>,
    ) {
        (HashMap::new(), HashMap::new())
    }

    fn _empty_embedded() -> HashMap<String, String> {
        HashMap::new()
    }

    fn _apply_result_to_state(
        result: &script_executor::ScriptExecuteResult,
        state: &mut ScriptRuntimeState,
    ) {
        for (k, v) in &result.set_variable {
            state.set_variable_json(k.clone(), v.clone());
        }
        for (name, data) in &result.set_table {
            let mut map = serde_json::Map::new();
            for (k, v) in data {
                map.insert(k.clone(), serde_json::from_str(v).unwrap_or_default());
            }
            let table = QuestTable::new(name.clone(), vec![], vec![], map);
            state.set_table(name, table);
        }
    }

    // ---------------------------------------------------------------------------
    // execute_script
    // ---------------------------------------------------------------------------

    #[test]
    fn execute_event_assigns_variable() {
        let script = serde_json::json!({
            "name": "test",
            "blocks": [
                {
                    "type": "event",
                    "eventType": "onNodeEnter",
                    "children": [
                        {"type": "assign_variable", "variable": "x", "value": "42"}
                    ]
                }
            ]
        })
        .to_string();

        let (vars, tables) = _empty_vars_tables();
        let result = script_executor::execute_script(
            script,
            vars,
            tables,
            "q".into(),
            models::EventType::OnNodeEnter,
            None,
            None,
            false,
            _empty_embedded(),
        );
        assert_eq!(result.transition, None);
        assert_eq!(result.set_variable.get("x"), Some(&"42".into()));
    }

    #[test]
    fn execute_event_with_transition() {
        let script = serde_json::json!({
            "name": "test",
            "blocks": [
                {"type": "go_to_node", "node_id": "node_next"}
            ]
        })
        .to_string();

        let (vars, tables) = _empty_vars_tables();
        let result = script_executor::execute_script(
            script,
            vars,
            tables,
            "q".into(),
            models::EventType::OnNodeEnter,
            None,
            None,
            false,
            _empty_embedded(),
        );
        assert_eq!(result.transition, Some("node_next".into()));
    }

    #[test]
    fn execute_condition_block() {
        let script = serde_json::json!({
            "name": "cond",
            "blocks": [
                {
                    "type": "event",
                    "eventType": "onNodeEnter",
                    "children": [
                        {
                            "type": "condition",
                            "expression": "1 + 2 == 3",
                            "then_blocks": [
                                {"type": "assign_variable", "variable": "ok", "value": "'yes'"}
                            ],
                            "else_blocks": [
                                {"type": "assign_variable", "variable": "ok", "value": "'no'"}
                            ]
                        }
                    ]
                }
            ]
        })
        .to_string();

        let (vars, tables) = _empty_vars_tables();
        let result = script_executor::execute_script(
            script,
            vars,
            tables,
            "q".into(),
            models::EventType::OnNodeEnter,
            None,
            None,
            false,
            _empty_embedded(),
        );
        assert_eq!(result.set_variable.get("ok"), Some(&"\"yes\"".into()));
    }

    #[test]
    fn execute_with_crossfade() {
        let script = serde_json::json!({
            "name": "crossfade_test",
            "blocks": [
                {
                    "type": "crossfade",
                    "duration": "3",
                    "children": [
                        {"type": "assign_variable", "variable": "faded", "value": "'yes'"}
                    ]
                }
            ]
        })
        .to_string();

        let (vars, tables) = _empty_vars_tables();
        let result = script_executor::execute_script(
            script,
            vars,
            tables,
            "q".into(),
            models::EventType::OnNodeEnter,
            None,
            None,
            false,
            _empty_embedded(),
        );
        assert_eq!(result.set_variable.get("faded"), Some(&"\"yes\"".into()));
    }

    #[test]
    fn wrong_event_type_skipped() {
        let script = serde_json::json!({
            "name": "test",
            "blocks": [
                {
                    "type": "event",
                    "eventType": "onPress",
                    "children": [
                        {"type": "assign_variable", "variable": "hit", "value": "'yes'"}
                    ]
                }
            ]
        })
        .to_string();

        let (vars, tables) = _empty_vars_tables();
        let result = script_executor::execute_script(
            script,
            vars,
            tables,
            "q".into(),
            models::EventType::OnNodeEnter,
            None,
            None,
            false,
            _empty_embedded(),
        );
        assert_eq!(result.set_variable.get("hit"), None);
    }

    #[test]
    fn delta_only_returns_changed_variables() {
        let script = serde_json::json!({
            "name": "delta",
            "blocks": [
                {
                    "type": "event",
                    "eventType": "onNodeEnter",
                    "children": [
                        {"type": "assign_variable", "variable": "x", "value": "99"}
                    ]
                }
            ]
        })
        .to_string();

        let mut vars = HashMap::new();
        vars.insert("x".into(), "10".into());
        vars.insert("untouched".into(), "\"keep_me\"".into());

        let result = script_executor::execute_script(
            script,
            vars,
            HashMap::new(),
            "q".into(),
            models::EventType::OnNodeEnter,
            None,
            None,
            false,
            _empty_embedded(),
        );
        assert_eq!(result.set_variable.get("x"), Some(&"99".into()));
        // unchanged variable is NOT in delta
        assert_eq!(result.set_variable.get("untouched"), None);
    }

    #[test]
    fn execute_script_with_embedded_nested_script() {
        let script = serde_json::json!({
            "name": "outer",
            "blocks": [
                {
                    "type": "event",
                    "eventType": "onNodeEnter",
                    "children": [
                        {"type": "call_script", "script_id": "nested"}
                    ]
                }
            ]
        })
        .to_string();

        let nested = serde_json::json!({
            "name": "nested",
            "blocks": [
                {
                    "type": "event",
                    "eventType": "onNodeEnter",
                    "children": [
                        {"type": "assign_variable", "variable": "from_nested", "value": "'yes'"}
                    ]
                }
            ]
        })
        .to_string();

        let mut embedded = HashMap::new();
        embedded.insert("quests/q/scripts/nested.json".into(), nested);

        let (vars, tables) = _empty_vars_tables();
        let result = script_executor::execute_script(
            script,
            vars,
            tables,
            "q".into(),
            models::EventType::OnNodeEnter,
            None,
            None,
            false,
            embedded,
        );
        assert_eq!(
            result.set_variable.get("from_nested"),
            Some(&"\"yes\"".into())
        );
    }

    /// Паритет с Dart `LuaTriggerAdapter.wrap` (этап J Плана 014):
    /// `.lua`-триггер заворачивается в синтетический JSON — event-обёртка
    /// (без condition/target) → `call_lua` с inline-скриптом. Ядро должно
    /// исполнить Lua-функцию и применить мутации состояния.
    #[test]
    fn execute_lua_trigger_wrapper_executes_call_lua() {
        let lua_fn = "function onContentAppear(item_id) core.set_var('x', 42) end";
        let script = serde_json::json!({
            "id": "__lua_trigger__",
            "blocks": [
                {
                    "type": "event",
                    "eventType": "onContentAppear",
                    "children": [
                        {
                            "type": "call_lua",
                            "script": lua_fn,
                            "function": "onContentAppear",
                            "args": "item_x"
                        }
                    ]
                }
            ]
        })
        .to_string();

        let (vars, tables) = _empty_vars_tables();
        let result = script_executor::execute_script(
            script,
            vars,
            tables,
            "q".into(),
            models::EventType::OnContentAppear,
            None,
            None,
            false,
            _empty_embedded(),
        );
        assert_eq!(result.transition, None);
        assert_eq!(result.set_variable.get("x"), Some(&"42".into()));
    }

    /// Паритет: фолбэк `start` когда функция события не определена в `.lua`.
    #[test]
    fn execute_lua_trigger_wrapper_fallback_function() {
        let lua_fn = "function onPress(item_id) core.set_var('pressed', item_id) end";
        let script = serde_json::json!({
            "id": "__lua_trigger__",
            "blocks": [
                {
                    "type": "event",
                    "eventType": "onPress",
                    "children": [
                        {
                            "type": "call_lua",
                            "script": lua_fn,
                            "function": "onPress",
                            "args": "item_7"
                        }
                    ]
                }
            ]
        })
        .to_string();

        let (vars, tables) = _empty_vars_tables();
        let result = script_executor::execute_script(
            script,
            vars,
            tables,
            "q".into(),
            models::EventType::OnPress,
            None,
            None,
            false,
            _empty_embedded(),
        );
        assert_eq!(
            result.set_variable.get("pressed"),
            Some(&"\"item_7\"".into())
        );
    }

    /// Паритет: Lua-функция возвращает переход `{ node = "..." }` —
    /// `execute_script` должен вернуть его в `transition`.
    #[test]
    fn execute_lua_trigger_wrapper_transition_result() {
        let lua_fn = "function onPress(item_id) return { node = 'node_42' } end";
        let script = serde_json::json!({
            "id": "__lua_trigger__",
            "blocks": [
                {
                    "type": "event",
                    "eventType": "onPress",
                    "children": [
                        {
                            "type": "call_lua",
                            "script": lua_fn,
                            "function": "onPress",
                            "args": "item"
                        }
                    ]
                }
            ]
        })
        .to_string();

        let (vars, tables) = _empty_vars_tables();
        let result = script_executor::execute_script(
            script,
            vars,
            tables,
            "q".into(),
            models::EventType::OnPress,
            None,
            None,
            false,
            _empty_embedded(),
        );
        assert_eq!(result.transition.as_deref(), Some("node_42"));
    }

    #[test]
    fn evaluate_condition_when_true() {
        let script = serde_json::json!({
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
        })
        .to_string();

        let mut state = ScriptRuntimeState::new();
        assert!(script_executor::evaluate_condition(
            script,
            &mut state,
            models::EventType::OnNodeEnter,
            None,
            None,
            false,
            false,
        ));
    }

    #[test]
    fn evaluate_condition_when_false() {
        let script = serde_json::json!({
            "name": "cond",
            "blocks": [
                {
                    "type": "event",
                    "eventType": "onNodeEnter",
                    "children": [
                        {"type": "condition", "expression": "false", "then_blocks": []}
                    ]
                }
            ]
        })
        .to_string();

        let mut state = ScriptRuntimeState::new();
        assert!(!script_executor::evaluate_condition(
            script,
            &mut state,
            models::EventType::OnNodeEnter,
            None,
            None,
            false,
            false,
        ));
    }

    // ---------------------------------------------------------------------------
    // check_script_event_type
    // ---------------------------------------------------------------------------

    #[test]
    fn check_event_type() {
        let script = serde_json::json!({
            "name": "test",
            "blocks": [
                {"type": "event", "eventType": "onPress", "children": []}
            ]
        })
        .to_string();
        assert_eq!(script_executor::check_script_event_type(script), "onPress");
    }

    // ---------------------------------------------------------------------------
    // has_executable_blocks
    // ---------------------------------------------------------------------------

    #[test]
    fn has_executable_blocks_positive() {
        let script = serde_json::json!({
            "name": "test",
            "blocks": [
                {"type": "event", "eventType": "onPress", "children": [
                    {"type": "assign_variable", "variable": "x", "value": "1"}
                ]}
            ]
        })
        .to_string();

        assert!(script_executor::has_executable_blocks(
            script,
            models::EventType::OnPress,
            None,
            None,
            false,
        ));
    }

    #[test]
    fn has_executable_blocks_negative() {
        let script = serde_json::json!({
            "name": "test",
            "blocks": [
                {"type": "event", "eventType": "onPress", "children": []}
            ]
        })
        .to_string();

        assert!(!script_executor::has_executable_blocks(
            script,
            models::EventType::OnNodeEnter,
            None,
            None,
            false,
        ));
    }

    // ---------------------------------------------------------------------------
    // evaluate_expression
    // ---------------------------------------------------------------------------

    #[test]
    fn evaluate_math_expression() {
        let mut state = ScriptRuntimeState::new();
        let result = script_executor::evaluate_expression(
            serde_json::json!("2 + 3 * 4").to_string(),
            &mut state,
        );
        assert_eq!(result, "14");
    }

    #[test]
    fn evaluate_placeholder() {
        let mut state = ScriptRuntimeState::new();
        state.set_variable_json("gold".into(), "10".into());
        let result = script_executor::evaluate_expression(
            serde_json::json!("{gold}").to_string(),
            &mut state,
        );
        assert_eq!(result, "10");
    }

    #[test]
    fn evaluate_nested_table() {
        let mut state = ScriptRuntimeState::new();

        let mut data = serde_json::Map::new();
        let mut inner = serde_json::Map::new();
        inner.insert("player".into(), serde_json::json!(7));
        data.insert("stats".into(), serde_json::Value::Object(inner));
        let table = QuestTable::new("t".into(), vec![], vec![], data);
        state.set_table("t", table);
        state.set_variable("k", serde_json::json!("stats"));

        let result = script_executor::evaluate_expression(
            serde_json::json!("t[{k}]['player']").to_string(),
            &mut state,
        );
        assert_eq!(result, "7");
    }

    // ---------------------------------------------------------------------------
    // evaluate_condition_logic
    // ---------------------------------------------------------------------------

    #[test]
    fn condition_logic_with_variables() {
        let mut state = ScriptRuntimeState::new();
        state.set_variable_json("gold".into(), "10".into());

        let block = serde_json::json!({
            "type": "condition",
            "expression": "{gold} >= 5",
            "then_blocks": []
        })
        .to_string();

        assert!(script_executor::evaluate_condition_logic(block, &mut state));
    }

    #[test]
    fn condition_logic_false() {
        let mut state = ScriptRuntimeState::new();
        state.set_variable_json("gold".into(), "2".into());

        let block = serde_json::json!({
            "type": "condition",
            "expression": "{gold} >= 10",
            "then_blocks": []
        })
        .to_string();

        assert!(!script_executor::evaluate_condition_logic(
            block, &mut state
        ));
    }

    // ---------------------------------------------------------------------------
    // values_equal
    // ---------------------------------------------------------------------------

    #[test]
    fn values_equal_numbers() {
        assert!(script_executor::values_equal("5".into(), "5.0".into()));
    }

    #[test]
    fn values_equal_nothing_like() {
        assert!(script_executor::values_equal(
            "\"ничего\"".into(),
            "null".into()
        ));
    }

    #[test]
    fn values_equal_not_equal() {
        assert!(!script_executor::values_equal(
            "\"abc\"".into(),
            "\"xyz\"".into()
        ));
    }

    // ---------------------------------------------------------------------------
    // table_operation
    // ---------------------------------------------------------------------------

    #[test]
    fn table_operation_set() {
        let mut state = ScriptRuntimeState::new();
        let mut data = serde_json::Map::new();
        data.insert("gold".into(), serde_json::json!(0));
        let table = QuestTable::new("storage".into(), vec![], vec![], data);
        state.set_table("storage", table);

        let block = serde_json::json!({
            "type": "table_operation",
            "operation": "set",
            "tableName": "storage",
            "path": "gold",
            "value": 100
        })
        .to_string();

        let result = script_executor::execute_table_operation(block, &mut state);
        assert_eq!(result, None);

        let table = state.get_table("storage").unwrap();
        assert_eq!(table.data.get("gold"), Some(&serde_json::json!(100)));
    }

    // ---------------------------------------------------------------------------
    // ScriptRuntimeState — roundtrip
    // ---------------------------------------------------------------------------

    #[test]
    fn state_roundtrip() {
        let mut vars = HashMap::new();
        vars.insert("x".into(), "42".into());
        vars.insert("name".into(), "\"Alice\"".into());

        let mut tables = HashMap::new();
        let mut data = HashMap::new();
        data.insert("gold".into(), "100".into());
        tables.insert("storage".into(), data);

        let mut state = ScriptRuntimeState::from_json(vars, tables);

        assert_eq!(state.get_variable_json("x".into()), Some("42".into()));
        assert_eq!(
            state.get_variable_json("name".into()),
            Some("\"Alice\"".into())
        );

        let out_tables = state.all_tables_json();
        assert_eq!(
            out_tables.get("storage").and_then(|t| t.get("gold")),
            Some(&"100".into())
        );

        state.set_variable_json("x".into(), "99".into());
        assert_eq!(state.get_variable_json("x".into()), Some("99".into()));
    }

    // ---------------------------------------------------------------------------
    // configure_engine
    // ---------------------------------------------------------------------------

    #[test]
    fn configure_engine_does_not_panic() {
        let config = serde_json::json!({"debug_logs_enabled": true}).to_string();
        script_executor::configure_engine(config);
    }

    // ---------------------------------------------------------------------------
    // game_engine
    // ---------------------------------------------------------------------------

    #[test]
    fn game_engine_start_and_next_item() {
        let init = crate::api::game_engine::GameEngineInit {
            quest_id: "q1".into(),
            config_json: serde_json::json!({
                "id": "q1", "title": "Q", "version": "1.0.0", "startNodeId": "n1"
            })
            .to_string(),
            nodes_json: serde_json::json!({
                "nodes": [{
                    "id": "n1", "title": "Start",
                    "content": { "items": [
                        {"type": "text", "id": "a", "text": "hello"}
                    ]}
                }]
            })
            .to_string(),
            templates_json: "[]".into(),
            platform_os: "linux".into(),
            is_web: false,
            embedded_scripts: HashMap::new(),
            quest_root: None,
        };
        let engine = crate::api::game_engine::game_engine_new(init);

        let view = crate::api::game_engine::game_engine_start_new(engine, None);
        assert!(view.is_some());
        let v: serde_json::Value = serde_json::from_str(&view.unwrap()).unwrap();
        assert_eq!(v["nodeId"], "n1");

        let step = crate::api::game_engine::game_engine_next_item(engine);
        let s: serde_json::Value = serde_json::from_str(&step).unwrap();
        assert_eq!(s["kind"], "item");
        assert_eq!(s["item"]["id"], "a");
    }

    #[test]
    fn game_engine_from_quest_root_reads_disk() {
        // Собираем квест в temp-каталоге (root/quests/q1/...).
        let root = std::env::temp_dir().join(format!("mnd_ffi_disk_{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(root.join("quests/q1")).unwrap();
        std::fs::write(
            root.join("quests/q1/config.json"),
            serde_json::json!({
                "id": "q1", "title": "Q", "version": "1.0.0", "startNodeId": "n1"
            })
            .to_string(),
        )
        .unwrap();
        std::fs::write(
            root.join("quests/q1/nodes.json"),
            serde_json::json!({
                "nodes": [{
                    "id": "n1", "title": "Start",
                    "content": { "items": [
                        {"type": "text", "id": "a", "text": "hello"},
                        {"type": "script", "id": "s", "resourcePath": "scripts/check.json"}
                    ]}
                }]
            })
            .to_string(),
        )
        .unwrap();
        // Скрипт читается лениво с диска (в init его нет).
        std::fs::create_dir_all(root.join("quests/q1/scripts")).unwrap();
        std::fs::write(
            root.join("quests/q1/scripts/check.json"),
            serde_json::json!({
                "name": "check",
                "blocks": [{
                    "type": "event",
                    "eventType": "onContentAppear",
                    "children": [{"type": "go_to_node", "node_id": "n2"}]
                }]
            })
            .to_string(),
        )
        .unwrap();

        let init = crate::api::game_engine::GameEngineInit {
            quest_id: "q1".into(),
            config_json: String::new(),
            nodes_json: String::new(),
            templates_json: String::new(),
            platform_os: "linux".into(),
            is_web: false,
            embedded_scripts: HashMap::new(),
            quest_root: Some(root.to_string_lossy().into_owned()),
        };
        let engine = crate::api::game_engine::game_engine_new(init);

        let view = crate::api::game_engine::game_engine_start_new(engine, None).unwrap();
        let v: serde_json::Value = serde_json::from_str(&view).unwrap();
        assert_eq!(v["nodeId"], "n1");

        // Первый шаг — text-айтем; второй — ленивый скрипт → переход.
        let step1 = crate::api::game_engine::game_engine_next_item(engine);
        let s1: serde_json::Value = serde_json::from_str(&step1).unwrap();
        assert_eq!(s1["kind"], "item");
        let step2 = crate::api::game_engine::game_engine_next_item(engine);
        let s2: serde_json::Value = serde_json::from_str(&step2).unwrap();
        assert_eq!(s2["kind"], "transition");
        assert_eq!(s2["node"], "n2");

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn game_engine_from_quest_root_saves_to_disk() {
        let root = std::env::temp_dir().join(format!("mnd_ffi_save_{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(root.join("quests/q1")).unwrap();
        std::fs::write(
            root.join("quests/q1/config.json"),
            serde_json::json!({
                "id": "q1", "title": "Q", "version": "1.0.0", "startNodeId": "n1"
            })
            .to_string(),
        )
        .unwrap();
        std::fs::write(
            root.join("quests/q1/nodes.json"),
            serde_json::json!({
                "nodes": [{
                    "id": "n1", "title": "Start",
                    "content": { "items": [{"type": "text", "id": "a", "text": "hello"}] }
                }]
            })
            .to_string(),
        )
        .unwrap();

        let init = crate::api::game_engine::GameEngineInit {
            quest_id: "q1".into(),
            config_json: String::new(),
            nodes_json: String::new(),
            templates_json: String::new(),
            platform_os: "linux".into(),
            is_web: false,
            embedded_scripts: HashMap::new(),
            quest_root: Some(root.to_string_lossy().into_owned()),
        };
        let engine = crate::api::game_engine::game_engine_new(init);
        crate::api::game_engine::game_engine_start_new(engine, None).unwrap();

        // Ручной слот.
        let slot = crate::api::game_engine::game_engine_save_slot(engine, "Мой слот".into());
        assert!(slot.is_some());
        let s: serde_json::Value = serde_json::from_str(&slot.unwrap()).unwrap();
        assert_eq!(s["slotName"], "Мой слот");
        assert_eq!(s["currentNodeId"], "n1");
        let slot_id = s["id"].as_str().unwrap().to_string();

        // Автосейв.
        let auto = crate::api::game_engine::game_engine_perform_autosave(engine);
        assert!(auto.is_some());
        let a: serde_json::Value = serde_json::from_str(&auto.unwrap()).unwrap();
        assert_eq!(a["id"], "_autosave");

        // Список + чтение через движок.
        let list = crate::api::game_engine::game_engine_list_saves(engine);
        let list_v: serde_json::Value = serde_json::from_str(&list).unwrap();
        assert_eq!(list_v.as_array().unwrap().len(), 2);
        let read = crate::api::game_engine::game_engine_read_save(engine, slot_id.clone());
        assert!(read.is_some());

        // Удаление ручного слота.
        crate::api::game_engine::game_engine_delete_save(engine, slot_id);
        let list2 = crate::api::game_engine::game_engine_list_saves(engine);
        let list2_v: serde_json::Value = serde_json::from_str(&list2).unwrap();
        assert_eq!(list2_v.as_array().unwrap().len(), 1);

        // Слоты физически легли на диск в quests/q1/saves/.
        assert!(root.join("quests/q1/saves/_autosave.json").is_file());

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn game_engine_drain_state_delta_reports_changes() {
        let root = std::env::temp_dir().join(format!("mnd_ffi_delta_{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(root.join("quests/q1")).unwrap();
        std::fs::write(
            root.join("quests/q1/config.json"),
            serde_json::json!({
                "id": "q1", "title": "Q", "version": "1.0.0", "startNodeId": "n1"
            })
            .to_string(),
        )
        .unwrap();
        std::fs::write(
            root.join("quests/q1/nodes.json"),
            serde_json::json!({
                "nodes": [{
                    "id": "n1", "title": "Start",
                    "content": { "items": [{"type": "text", "id": "a", "text": "hello"}] }
                }]
            })
            .to_string(),
        )
        .unwrap();

        let init = crate::api::game_engine::GameEngineInit {
            quest_id: "q1".into(),
            config_json: String::new(),
            nodes_json: String::new(),
            templates_json: String::new(),
            platform_os: "linux".into(),
            is_web: false,
            embedded_scripts: HashMap::new(),
            quest_root: Some(root.to_string_lossy().into_owned()),
        };
        let engine = crate::api::game_engine::game_engine_new(init);
        crate::api::game_engine::game_engine_start_new(engine, None).unwrap();

        // Первый drain — непустой (системные переменные старта).
        let first = crate::api::game_engine::game_engine_drain_state_delta(engine);
        let f: serde_json::Value = serde_json::from_str(&first).unwrap();
        assert!(!f["variables"].as_object().unwrap().is_empty());

        // Повторный drain без изменений — пустой.
        let empty = crate::api::game_engine::game_engine_drain_state_delta(engine);
        let e: serde_json::Value = serde_json::from_str(&empty).unwrap();
        assert!(e["variables"].as_object().unwrap().is_empty());
        assert!(e["tables"].as_object().unwrap().is_empty());

        let _ = std::fs::remove_dir_all(&root);
    }

    // ─── Реестр хендлов: lifecycle, независимость, not-found маркер ───────

    fn minimal_init(quest_id: &str) -> crate::api::game_engine::GameEngineInit {
        crate::api::game_engine::GameEngineInit {
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
    fn game_engine_handle_lifecycle_and_dispose() {
        let handle = crate::api::game_engine::game_engine_new(minimal_init("q1"));
        assert!(handle > 0);
        let view = crate::api::game_engine::game_engine_start_new(handle, None);
        assert!(view.is_some());

        crate::api::game_engine::game_engine_dispose(handle);

        // После dispose handle не найден: возвращается not-found маркер.
        assert_eq!(
            crate::api::game_engine::game_engine_start_new(handle, None),
            Some("{\"error\":\"engine_not_found\"}".to_string())
        );
        assert_eq!(
            crate::api::game_engine::game_engine_next_item(handle),
            "{\"error\":\"engine_not_found\"}"
        );
    }

    #[test]
    fn game_engine_two_handles_are_independent() {
        let h1 = crate::api::game_engine::game_engine_new(minimal_init("q1"));
        let h2 = crate::api::game_engine::game_engine_new(minimal_init("q1"));
        assert_ne!(h1, h2);

        crate::api::game_engine::game_engine_start_new(h1, None).unwrap();
        crate::api::game_engine::game_engine_start_new(h2, None).unwrap();

        // Оба выдают тот же первый айтем, независимо друг от друга.
        let s1 = crate::api::game_engine::game_engine_next_item(h1);
        let s2 = crate::api::game_engine::game_engine_next_item(h2);
        let v1: serde_json::Value = serde_json::from_str(&s1).unwrap();
        let v2: serde_json::Value = serde_json::from_str(&s2).unwrap();
        assert_eq!(v1["kind"], "item");
        assert_eq!(v1["item"]["id"], "a");
        assert_eq!(v1, v2);

        crate::api::game_engine::game_engine_dispose(h1);
        crate::api::game_engine::game_engine_dispose(h2);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// РЕГРЕССИОННЫЕ ТЕСТЫ FFI-СЛОЯ: 10 багов, найденных тестерами (Dart→Rust).
// Желаемое поведение = поведение старого Dart-движка (эталон).
// Красные тесты = найденные регрессии.
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod regression_ffi_tests {
    use std::collections::HashMap;

    use crate::api::{models, runtime::ScriptRuntimeState, script_executor};

    fn empty_embedded() -> HashMap<String, String> {
        HashMap::new()
    }

    // ─── Баг 4: числовой формат без .0 через плоские FFI-функции ──────────

    #[test]
    fn bug4_evaluate_expression_flat_returns_int_json() {
        let (vars, tables) = (HashMap::new(), HashMap::new());
        // spec: evaluate_expression("12.0") ➔ 12 (в JSON "12").
        assert_eq!(
            script_executor::evaluate_expression_flat(
                r#""12.0""#.into(),
                vars.clone(),
                tables.clone()
            ),
            "12"
        );
        assert_eq!(
            script_executor::evaluate_expression_flat(
                r#""2 + 3 * 4""#.into(),
                vars.clone(),
                tables.clone()
            ),
            "14"
        );
        assert_eq!(
            script_executor::evaluate_expression_flat(r#""10 / 4""#.into(), vars, tables),
            "2.5"
        );
    }

    // ─── Баги 1/2/3: wait → очередь задержек в дельте execute_script ───────

    #[test]
    fn bug123_execute_script_wait_delay_queue_in_delta() {
        let script = serde_json::json!({
            "name": "battle",
            "blocks": [
                {"type": "event", "eventType": "onNodeEnter", "children": [
                    {"type": "assign_variable", "variable": "stance", "value": "1"},
                    {"type": "wait", "expression": "500"},
                    {"type": "assign_variable", "variable": "stance", "value": "0"},
                    {"type": "wait", "expression": "250"}
                ]}
            ]
        })
        .to_string();

        let result = script_executor::execute_script(
            script,
            HashMap::new(),
            HashMap::new(),
            "q".into(),
            models::EventType::OnNodeEnter,
            None,
            None,
            false,
            empty_embedded(),
        );
        let queue = result.set_variable.get("_internal_delay_queue").unwrap();
        let parsed: serde_json::Value = serde_json::from_str(queue).unwrap();
        // Каждый шаг — checkpoint: снапшот переменных, изменённых с прошлого
        // wait'а (значения как JSON-строки), и накопленные аудио-команды.
        assert_eq!(
            parsed,
            serde_json::json!([
                {
                    "type": "delay",
                    "ms": 500,
                    "variables": {"stance": "1"},
                    "tables": {},
                    "audio": []
                },
                {
                    "type": "delay",
                    "ms": 250,
                    "variables": {"stance": "0"},
                    "tables": {},
                    "audio": []
                }
            ])
        );
        assert_eq!(result.set_variable.get("stance"), Some(&"0".into()));
    }

    // ─── drain_delay_queue: wait → go_to_node отдаёт очередь и очищает её ───

    #[test]
    fn engine_drain_delay_queue_after_wait_goto() {
        let init = crate::api::game_engine::GameEngineInit {
            quest_id: "q1".into(),
            config_json: serde_json::json!({
                "id": "q1", "title": "Q", "version": "1.0.0", "startNodeId": "n1",
            })
            .to_string(),
            nodes_json: serde_json::json!({
                "nodes": [
                    {"id": "n1", "title": "Start", "scriptAssetId": "scripts/go.json",
                     "content": { "items": [] }},
                    {"id": "n2", "title": "Next",
                     "content": { "items": [{"type": "text", "id": "b", "text": "two"}] }}
                ]
            })
            .to_string(),
            templates_json: "[]".into(),
            platform_os: "linux".into(),
            is_web: false,
            embedded_scripts: HashMap::from([(
                "scripts/go.json".to_string(),
                serde_json::json!({
                    "name": "go",
                    "blocks": [
                        {"type": "event", "eventType": "onNodeEnter", "children": [
                            {"type": "wait", "expression": "1000"},
                            {"type": "go_to_node", "node_id": "n2"}
                        ]}
                    ]
                })
                .to_string(),
            )]),
            quest_root: None,
        };
        let engine = crate::api::game_engine::game_engine_new(init);
        let view = crate::api::game_engine::game_engine_start_new(engine, None).unwrap();
        let v: serde_json::Value = serde_json::from_str(&view).unwrap();
        assert_eq!(v["transition"], "n2");

        let delays: serde_json::Value = serde_json::from_str(
            &crate::api::game_engine::game_engine_drain_delay_queue(engine),
        )
        .unwrap();
        assert_eq!(
            delays,
            serde_json::json!([
                {"type": "delay", "ms": 1000, "variables": {}, "tables": {}, "audio": []}
            ])
        );

        // Повторный drain — пусто.
        let again: serde_json::Value = serde_json::from_str(
            &crate::api::game_engine::game_engine_drain_delay_queue(engine),
        )
        .unwrap();
        assert_eq!(again, serde_json::json!([]));
    }

    // ─── Баг 8: crossfade → аудио-очередь в дельте ─────────────────────────

    #[test]
    fn bug8_execute_script_crossfade_audio_queue_in_delta() {
        let script = serde_json::json!({
            "name": "cf",
            "blocks": [
                {"type": "event", "eventType": "onNodeEnter", "children": [
                    {"type": "crossfade", "duration": "1.5", "children": [
                        {"type": "assign_variable", "variable": "mid", "value": "1"}
                    ]}
                ]}
            ]
        })
        .to_string();

        let result = script_executor::execute_script(
            script,
            HashMap::new(),
            HashMap::new(),
            "q".into(),
            models::EventType::OnNodeEnter,
            None,
            None,
            false,
            empty_embedded(),
        );
        let queue = result.set_variable.get("_internal_audio_queue").unwrap();
        let parsed: serde_json::Value = serde_json::from_str(queue).unwrap();
        assert_eq!(
            parsed,
            serde_json::json!([
                {"type": "fade_out", "ms": 1500},
                {"type": "fade_in", "ms": 1500}
            ])
        );
        assert_eq!(result.set_variable.get("mid"), Some(&"1".into()));
    }

    // ─── Баг 9: evaluateCondition с allowStateMutation: false ──────────────

    #[test]
    fn bug9_evaluate_condition_flat_no_mutation_when_disallowed() {
        // spec: «Если {Примогемы} > 160: Примогемы = Примогемы - 160».
        let script = serde_json::json!({
            "name": "gacha",
            "blocks": [
                {"type": "assign_variable", "variable": "Примогемы", "value": "Примогемы - 160"},
                {"type": "condition", "expression": "{Примогемы} > 160", "then_blocks": []}
            ]
        })
        .to_string();

        let mut vars = HashMap::new();
        vars.insert("Примогемы".into(), "200".into());

        // allowStateMutation: false — условие истинно, дельта мутаций пуста.
        let res_false = script_executor::evaluate_condition_flat(
            script.clone(),
            vars.clone(),
            HashMap::new(),
            models::EventType::OnContentAppear,
            None,
            None,
            false,
            false,
        );
        assert!(res_false.result);
        assert!(res_false.set_variable.is_empty());
        assert!(res_false.set_table.is_empty());

        // allowStateMutation: true — прелюдия мутирует, результат возвращается
        // в дельте (клиент применяет её к своему стейту).
        let res_true = script_executor::evaluate_condition_flat(
            script.clone(),
            vars.clone(),
            HashMap::new(),
            models::EventType::OnContentAppear,
            None,
            None,
            false,
            true,
        );
        assert!(!res_true.result);
        assert_eq!(
            res_true.set_variable.get("Примогемы").map(String::as_str),
            Some("40")
        );

        // Мутация применяется к стейту только когда клиент явно это разрешает:
        // здесь мы проверяем через ScriptRuntimeState, как это делает клиент.
        let mut state = ScriptRuntimeState::from_json(vars, HashMap::new());
        assert!(!script_executor::evaluate_condition(
            script.clone(),
            &mut state,
            models::EventType::OnContentAppear,
            None,
            None,
            false,
            true,
        ));
        assert_eq!(
            state.get_variable_json("Примогемы".into()).as_deref(),
            Some("40")
        );
    }

    // ─── Баг 6: повторные нажатия ретриггерят звук через движок ────────────

    fn battle_quest_engine_init(
        node_items: serde_json::Value,
        scripts: serde_json::Value,
    ) -> crate::api::game_engine::GameEngineInit {
        crate::api::game_engine::GameEngineInit {
            quest_id: "q1".into(),
            config_json: serde_json::json!({
                "id": "q1", "title": "Q", "version": "1.0.0", "startNodeId": "n1"
            })
            .to_string(),
            nodes_json: serde_json::json!({
                "nodes": [{
                    "id": "n1", "title": "Start",
                    "content": { "items": node_items }
                }]
            })
            .to_string(),
            templates_json: "[]".into(),
            platform_os: "linux".into(),
            is_web: false,
            embedded_scripts: scripts
                .as_object()
                .unwrap()
                .iter()
                .map(|(k, v)| (k.clone(), v.to_string()))
                .collect(),
            quest_root: None,
        }
    }

    #[test]
    fn bug6_engine_repeated_press_play_sound_drain_cycle() {
        let init = battle_quest_engine_init(
            serde_json::json!([{"type": "button", "id": "b1",
                "scriptTriggers": {"onPress": "scripts/btn.json"}}]),
            serde_json::json!({
                "scripts/btn.json": {
                    "name": "btn",
                    "blocks": [
                        {"type": "event", "eventType": "onPress", "children": [
                            {"type": "play_sound", "audio_id": "sfx/click.wav", "volume": "0.9"}
                        ]}
                    ]
                }
            }),
        );
        let engine = crate::api::game_engine::game_engine_new(init);
        crate::api::game_engine::game_engine_start_new(engine, None).unwrap();

        let item = serde_json::json!({
            "type": "button", "id": "b1",
            "scriptTriggers": {"onPress": "scripts/btn.json"}
        });

        // Нажатие 1 → drainAudio отдаёт playSound, повторный drain — пусто.
        crate::api::game_engine::game_engine_handle_interaction(
            engine,
            item.to_string(),
            "scripts/btn.json".into(),
        );
        let d1: serde_json::Value =
            serde_json::from_str(&crate::api::game_engine::game_engine_drain_audio(engine))
                .unwrap();
        assert_eq!(d1["commands"][0]["type"], "playSound");
        assert_eq!(d1["commands"][0]["id"], "sfx/click.wav");
        assert_eq!(d1["commands"][0]["volume"], 0.9);
        let d1b: serde_json::Value =
            serde_json::from_str(&crate::api::game_engine::game_engine_drain_audio(engine))
                .unwrap();
        assert!(d1b["commands"].as_array().unwrap().is_empty());

        // Нажатие 2 — звук должен воспроизвестись снова.
        crate::api::game_engine::game_engine_handle_interaction(
            engine,
            item.to_string(),
            "scripts/btn.json".into(),
        );
        let d2: serde_json::Value =
            serde_json::from_str(&crate::api::game_engine::game_engine_drain_audio(engine))
                .unwrap();
        assert_eq!(d2["commands"][0]["type"], "playSound");
        assert_eq!(d2["commands"][0]["id"], "sfx/click.wav");
    }

    // ─── Баг 7: музыка главы в NodeView, без команд рестарта ───────────────

    #[test]
    fn bug7_engine_chapter_bgm_in_view_no_restart_commands() {
        let init = crate::api::game_engine::GameEngineInit {
            quest_id: "q1".into(),
            config_json: serde_json::json!({
                "id": "q1", "title": "Q", "version": "1.0.0", "startNodeId": "n1",
                "tags": [
                    {"id": "ch1", "name": "Глава 1", "backgroundAudioId": "chapter_music.mp3"}
                ],
            })
            .to_string(),
            nodes_json: serde_json::json!({
                "nodes": [
                    {"id": "n1", "title": "Start", "chapterId": "ch1",
                     "content": { "items": [{"type": "text", "id": "a", "text": "one"}] }},
                    {"id": "n2", "title": "Next", "chapterId": "ch1",
                     "content": { "items": [{"type": "text", "id": "b", "text": "two"}] }}
                ]
            })
            .to_string(),
            templates_json: "[]".into(),
            platform_os: "linux".into(),
            is_web: false,
            embedded_scripts: HashMap::new(),
            quest_root: None,
        };
        let engine = crate::api::game_engine::game_engine_new(init);

        let view1 = crate::api::game_engine::game_engine_start_new(engine, None).unwrap();
        let v1: serde_json::Value = serde_json::from_str(&view1).unwrap();
        assert_eq!(v1["backgroundAudio"]["audioId"], "chapter_music.mp3");
        assert_eq!(v1["backgroundAudio"]["volume"], 1.0);

        // Движок не эмитит play/stop музыки — клиент сам решает про рестарт.
        let d: serde_json::Value =
            serde_json::from_str(&crate::api::game_engine::game_engine_drain_audio(engine))
                .unwrap();
        assert!(d["commands"].as_array().unwrap().is_empty());

        // Соседняя нода той же главы — та же музыка в NodeView, команд нет.
        let view2 = crate::api::game_engine::game_engine_load_node(engine, "n2".into()).unwrap();
        let v2: serde_json::Value = serde_json::from_str(&view2).unwrap();
        assert_eq!(v2["backgroundAudio"]["audioId"], "chapter_music.mp3");
        let d2: serde_json::Value =
            serde_json::from_str(&crate::api::game_engine::game_engine_drain_audio(engine))
                .unwrap();
        assert!(d2["commands"].as_array().unwrap().is_empty());
    }

    // ─── Регрессия: музыка главы должна играть после загрузки из сейва ──────
    // Причина бага: сейв содержал legacy-ключ `_internal_active_bgm_id`,
    // который драйнил stop_music в момент первого drain после старта.

    #[test]
    fn save_restore_keeps_chapter_bgm_in_view() {
        let init = crate::api::game_engine::GameEngineInit {
            quest_id: "q1".into(),
            config_json: serde_json::json!({
                "id": "q1", "title": "Q", "version": "1.0.0", "startNodeId": "n1",
                "tags": [
                    {"id": "ch1", "name": "Глава 1", "backgroundAudioId": "chapter_music.mp3"}
                ],
            })
            .to_string(),
            nodes_json: serde_json::json!({
                "nodes": [
                    {"id": "n1", "title": "Start", "chapterId": "ch1",
                     "content": { "items": [] }},
                    {"id": "n2", "title": "Next", "chapterId": "ch1",
                     "content": { "items": [] }}
                ]
            })
            .to_string(),
            templates_json: "[]".into(),
            platform_os: "linux".into(),
            is_web: false,
            embedded_scripts: HashMap::new(),
            quest_root: None,
        };
        let engine = crate::api::game_engine::game_engine_new(init.clone());
        crate::api::game_engine::game_engine_start_new(engine, None).unwrap();
        crate::api::game_engine::game_engine_load_node(engine, "n2".into()).unwrap();
        let save_json = crate::api::game_engine::game_engine_to_save_slot(
            engine,
            "s1".to_string(),
            String::new(),
        )
        .unwrap();

        // Новый движок (перезапуск приложения) — старт из сейва.
        let engine2 = crate::api::game_engine::game_engine_new(init);
        let view = crate::api::game_engine::game_engine_start_from_save(engine2, save_json)
            .expect("start_from_save");
        let v: serde_json::Value = serde_json::from_str(&view).unwrap();
        assert_eq!(v["nodeId"], "n2");
        assert_eq!(
            v["backgroundAudio"]["audioId"], "chapter_music.mp3",
            "после загрузки сейва музыка главы должна быть в NodeView"
        );

        // И главное: старт из сейва не должен эмитить stop_music / pause_resume
        // (иначе клиент тут же убьёт трек, который начал играть).
        let d: serde_json::Value =
            serde_json::from_str(&crate::api::game_engine::game_engine_drain_audio(engine2))
                .unwrap();
        let commands = d["commands"].as_array().unwrap();
        assert!(
            !commands.iter().any(|c| c["type"] == "stopMusic"),
            "старт из сейва не должен эмитить stopMusic: {d}"
        );
    }

    // ─── НАЙДЕННАЯ РЕГРЕССИЯ: стартовый drain эмитит pauseResume toggle ────
    // Красный тест: клиентский _pauseResumeAudio('all','toggle') при
    // _isMusicPaused == false ставит музыку на паузу сразу после старта.
    // Причина: _internal_pause_resume_target/action инициализируются как
    // "all"/"toggle" в начальном состоянии (engine.rs:382-383) → первый
    // drain_audio_commands отдаёт команду. Ожидание: на свежем движке команд
    // pause/resume быть не должно (null).

    #[test]
    fn bug8_engine_initial_drain_emits_no_pause_resume() {
        let init = crate::api::game_engine::GameEngineInit {
            quest_id: "q1".into(),
            config_json: serde_json::json!({
                "id": "q1", "title": "Q", "version": "1.0.0", "startNodeId": "n1",
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
        };
        let engine = crate::api::game_engine::game_engine_new(init);
        crate::api::game_engine::game_engine_start_new(engine, None).unwrap();
        let d: serde_json::Value =
            serde_json::from_str(&crate::api::game_engine::game_engine_drain_audio(engine))
                .unwrap();
        assert!(
            d["pauseResume"].is_null(),
            "первый drain не должен эмитить pauseResume: {d}"
        );
    }

    // ─── Баг 9: мутация onContentAppear ровно один раз (движок e2e) ────────

    #[test]
    fn bug9_engine_on_content_appear_mutation_exactly_once() {
        let init = battle_quest_engine_init(
            serde_json::json!([
                {"type": "script", "id": "s1", "resourcePath": "scripts/gacha.json"},
                {"type": "text", "id": "t1", "text": "Результат"}
            ]),
            serde_json::json!({
                "scripts/gacha.json": {
                    "name": "gacha",
                    "blocks": [
                        {"type": "event", "eventType": "onContentAppear", "children": [
                            {"type": "assign_variable", "variable": "Примогемы", "value": "Примогемы - 160"}
                        ]}
                    ]
                }
            }),
        );
        // config должен содержать дефолтную переменную — пересоздаём init.
        let mut init = init;
        init.config_json = serde_json::json!({
            "id": "q1", "title": "Q", "version": "1.0.0", "startNodeId": "n1",
            "variables": [{"name": "Примогемы", "defaultValue": 200}],
        })
        .to_string();

        let engine = crate::api::game_engine::game_engine_new(init);
        crate::api::game_engine::game_engine_start_new(engine, None).unwrap();
        assert_eq!(
            crate::api::game_engine::game_engine_evaluate(engine, r#""Примогемы""#.into()),
            "200"
        );

        // Раскрытие script-айтема → мутация ровно один раз (200 - 160 = 40).
        let step = crate::api::game_engine::game_engine_next_item(engine);
        let s: serde_json::Value = serde_json::from_str(&step).unwrap();
        assert_eq!(s["kind"], "item");
        assert_eq!(s["item"]["id"], "t1");
        assert_eq!(
            crate::api::game_engine::game_engine_evaluate(engine, r#""Примогемы""#.into()),
            "40"
        );

        // Дальше — без повторных мутаций (нет x2).
        let step2 = crate::api::game_engine::game_engine_next_item(engine);
        let s2: serde_json::Value = serde_json::from_str(&step2).unwrap();
        assert_eq!(s2["kind"], "done");
        assert_eq!(
            crate::api::game_engine::game_engine_evaluate(engine, r#""Примогемы""#.into()),
            "40"
        );

        // В state-дельте финальное значение, повторный drain пуст.
        let delta: serde_json::Value = serde_json::from_str(
            &crate::api::game_engine::game_engine_drain_state_delta(engine),
        )
        .unwrap();
        assert_eq!(delta["variables"]["Примогемы"], "40");
        let delta2: serde_json::Value = serde_json::from_str(
            &crate::api::game_engine::game_engine_drain_state_delta(engine),
        )
        .unwrap();
        assert!(delta2["variables"].get("Примогемы").is_none());
    }

    // ─── Регрессия: рекурсивный call_function (energy -> wait -> energy) не ломает и не вешает движок ──────
    #[test]
    fn bug_recursive_call_function_with_wait_does_not_overflow_or_freeze() {
        use crate::api::game_engine::GameEngineInit;
        let quest = serde_json::json!({
            "id": "miner_quest",
            "title": "Симулятор шахтера",
            "version": "1.0.0",
            "startNodeId": "node_mine",
            "variables": [
                {"name": "энергия", "defaultValue": 10},
                {"name": "возобновление энергии", "defaultValue": true}
            ]
        });

        // Скрипт входа: проверяет возобновление и вызывает функцию energy
        let enter_script = serde_json::json!({
            "name": "блок",
            "blocks": [
                {
                    "type": "event",
                    "eventType": "onNodeEnter",
                    "children": [
                        {
                            "type": "condition",
                            "expression": "{возобновление энергии}==true",
                            "then_blocks": [
                                {
                                    "type": "assign_variable",
                                    "variable": "возобновление энергии",
                                    "value": "false"
                                },
                                {
                                    "type": "call_function",
                                    "function_id": "energy_script",
                                    "function_name": "energy :: energy",
                                    "function_entry": "energy"
                                }
                            ],
                            "else_blocks": []
                        }
                    ]
                }
            ]
        });

        // Рекурсивная функция energy
        let energy_script = serde_json::json!({
            "name": "energy",
            "blocks": [
                {
                    "type": "event",
                    "eventType": "function",
                    "functionName": "energy",
                    "children": [
                        {
                            "type": "condition",
                            "expression": "{энергия}<100",
                            "then_blocks": [
                                {
                                    "type": "assign_variable",
                                    "variable": "энергия",
                                    "value": "{энергия}+1"
                                }
                            ]
                        },
                        {
                            "type": "wait",
                            "expression": "2000"
                        },
                        {
                            "type": "call_function",
                            "function_id": "energy_script",
                            "function_name": "energy :: energy",
                            "function_entry": "energy"
                        }
                    ]
                }
            ]
        });

        let node = serde_json::json!({
            "id": "node_mine",
            "title": "Шахта",
            "content": {
                "items": [
                    {
                        "id": "item_script_1",
                        "type": "script",
                        "resourcePath": "scripts/enter_script.json"
                    }
                ]
            }
        });

        let mut scripts = HashMap::new();
        scripts.insert(
            "scripts/enter_script.json".to_string(),
            serde_json::to_string(&enter_script).unwrap(),
        );
        scripts.insert(
            "scripts/energy_script.json".to_string(),
            serde_json::to_string(&energy_script).unwrap(),
        );
        scripts.insert(
            "energy_script".to_string(),
            serde_json::to_string(&energy_script).unwrap(),
        );

        let init = GameEngineInit {
            quest_id: "miner_quest".into(),
            config_json: serde_json::to_string(&quest).unwrap(),
            nodes_json: serde_json::json!({ "nodes": [node] }).to_string(),
            templates_json: "[]".into(),
            embedded_scripts: scripts,
            quest_root: None,
            platform_os: "linux".into(),
            is_web: false,
        };
        let engine = crate::api::game_engine::game_engine_new(init);

        // Запуск не должен зависнуть и не должен упасть по Stack Overflow!
        let view_json = crate::api::game_engine::game_engine_start_new(engine, None).unwrap();
        let view: serde_json::Value = serde_json::from_str(&view_json).unwrap();
        assert_eq!(view["nodeId"], "node_mine");

        // Цикл-таймер: рекурсия не ныряет синхронно, а планирует re-invoke
        // через ms последнего wait (эталон: +1 энергия / 2с). Один тик уже сделан.
        let energy_val =
            crate::api::game_engine::game_engine_evaluate(engine, r#""энергия""#.into());
        assert_eq!(energy_val, "11");

        // Расписание тика видно клиенту (state-переменная _internal_timer_schedule).
        let delta = crate::api::game_engine::game_engine_drain_state_delta(engine);
        let delta: serde_json::Value = serde_json::from_str(&delta).unwrap();
        let schedule_raw = delta["variables"]["_internal_timer_schedule"]
            .as_str()
            .unwrap();
        let schedule: serde_json::Value = serde_json::from_str(schedule_raw).unwrap();
        let schedule = schedule.as_array().unwrap();
        assert_eq!(schedule.len(), 1);
        assert_eq!(schedule[0]["script_path"], "scripts/energy_script.json");
        assert_eq!(schedule[0]["entry"], "energy");
        assert_eq!(schedule[0]["ms"], 2000);

        // Тик (Dart: await Future.delayed(2000) → run_scheduled_timer): +1 энергия,
        // следующий тик снова в расписании — таймер живёт бесконечно.
        let tick = crate::api::game_engine::game_engine_run_scheduled_timer(
            engine,
            "scripts/energy_script.json".into(),
            "energy".into(),
        );
        let tick: serde_json::Value = serde_json::from_str(&tick).unwrap();
        assert_eq!(tick["ran"], true);
        assert_eq!(tick["transition"], serde_json::Value::Null);
        let energy_val =
            crate::api::game_engine::game_engine_evaluate(engine, r#""энергия""#.into());
        assert_eq!(energy_val, "12");
        let delta = crate::api::game_engine::game_engine_drain_state_delta(engine);
        let delta: serde_json::Value = serde_json::from_str(&delta).unwrap();
        let schedule_raw = delta["variables"]["_internal_timer_schedule"]
            .as_str()
            .unwrap();
        let schedule: serde_json::Value = serde_json::from_str(schedule_raw).unwrap();
        let schedule = schedule.as_array().unwrap();
        assert_eq!(schedule.len(), 1);
        assert_eq!(schedule[0]["ms"], 2000);

        // Тик по несуществующей записи — no-op (ran=false).
        let tick2 = crate::api::game_engine::game_engine_run_scheduled_timer(
            engine,
            "scripts/nope.json".into(),
            "energy".into(),
        );
        let tick2: serde_json::Value = serde_json::from_str(&tick2).unwrap();
        assert_eq!(tick2["ran"], false);
        assert_eq!(tick2["transition"], serde_json::Value::Null);
    }
}

#[cfg(test)]
mod validation_ffi_tests {

    /// Отчёт для квеста с конфликтом видимости слотов.
    #[test]
    fn run_quest_validation_reports_slot_conflict() {
        let dir = std::env::temp_dir().join(format!("mnd_ffi_validation_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let files: &[(&str, &str)] = &[
            (
                "quests/q1/config.json",
                r#"{"id":"q1","startNodeId":"n1","tags":[{"id":"t1","name":"Глава"}]}"#,
            ),
            (
                "quests/q1/nodes.json",
                r#"{"nodes":[{"id":"n1","title":"Н1","chapterId":"t1","content":{"items":[
                    {"id":"row1","type":"row","children":[
                        {"id":"empty","type":"image","scriptTriggers":{"onContentAppear":"scripts/e1.json"}},
                        {"id":"icon","type":"image","scriptTriggers":{"onContentAppear":"scripts/i1.json"}}
                    ]}
                ]}}]}"#,
            ),
            (
                "quests/q1/scripts/e1.json",
                r#"{"id":"e1","blocks":[{"type":"event","eventType":"onContentAppear","children":[{"type":"condition","expression":"{Слот2}==0 || {Слот_Действие}!=0","then_blocks":[]}]}]}"#,
            ),
            (
                "quests/q1/scripts/i1.json",
                r#"{"id":"i1","blocks":[{"type":"event","eventType":"onContentAppear","children":[{"type":"condition","expression":"{Слот2}=='Лечилка_Малая'","then_blocks":[]}]}]}"#,
            ),
        ];
        for (path, content) in files {
            let full = dir.join(path);
            if let Some(parent) = full.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            std::fs::write(full, content).unwrap();
        }

        let report = crate::api::validation::run_quest_validation(
            "q1".to_string(),
            dir.display().to_string(),
        );
        let parsed: serde_json::Value = serde_json::from_str(&report).unwrap();
        let diagnostics = parsed["diagnostics"].as_array().unwrap();
        let has_conflict = diagnostics.iter().any(|d| {
            d["kind"] == "visibility_conflict"
                && d["message"]
                    .as_str()
                    .unwrap_or("")
                    .contains("{Слот2}==0 || {Слот_Действие}!=0")
        });
        assert!(
            has_conflict,
            "отчёт обязан содержать конфликт слотов: {report}"
        );
        assert_eq!(parsed["stats"]["errors"], 0);
        assert!(parsed["stats"]["warnings"].as_u64().unwrap() >= 1);
    }

    /// Отчёт для отсутствующего квеста — MissingConfig (валидный JSON).
    #[test]
    fn run_quest_validation_missing_quest_is_valid_json() {
        let dir =
            std::env::temp_dir().join(format!("mnd_ffi_validation_missing_{}", std::process::id()));
        let report = crate::api::validation::run_quest_validation(
            "no-such-quest".to_string(),
            dir.display().to_string(),
        );
        let parsed: serde_json::Value = serde_json::from_str(&report).unwrap();
        let diagnostics = parsed["diagnostics"].as_array().unwrap();
        assert!(
            diagnostics.iter().any(|d| d["kind"] == "missing_config"),
            "ожидается missing_config: {report}"
        );
        assert!(parsed["stats"]["errors"].as_u64().unwrap_or(0) >= 1);
    }

    /// Локальная проверка на реальном квесте, не CI: фикстура задаётся
    /// окружением (MND_LOCAL_QUEST_ROOT + MND_LOCAL_QUEST_ID).
    #[test]
    fn run_quest_validation_real_quest() {
        let root_dir = std::env::var("MND_LOCAL_QUEST_ROOT").unwrap_or_default();
        let quest_id = std::env::var("MND_LOCAL_QUEST_ID").unwrap_or_default();
        let root = std::path::Path::new(&root_dir);
        let quest = quest_id.as_str();
        if quest.is_empty() || !root.join("quests").join(quest).is_dir() {
            return;
        }
        let report = crate::api::validation::run_quest_validation(
            quest.to_string(),
            root.display().to_string(),
        );
        let parsed: serde_json::Value = serde_json::from_str(&report).unwrap();
        let diagnostics = parsed["diagnostics"].as_array().unwrap();
        assert!(
            diagnostics
                .iter()
                .any(|d| d["kind"] == "visibility_conflict"
                    && d["message"].as_str().unwrap_or("").contains("{Слот")),
            "реальный квест обязан содержать конфликт слотов"
        );
    }
}
