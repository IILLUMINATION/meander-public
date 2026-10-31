use super::*;

fn config(quest_id: &str) -> Quest {
    Quest::from_json(&serde_json::json!({
        "id": quest_id,
        "title": "Test Quest",
        "version": "2.0.0",
        "startNodeId": "node_1",
        "backgroundAssetId": "quest_bg.png",
    }))
}

fn node(id: &str, title: &str, items: Vec<Value>) -> SavedNode {
    SavedNode::from_json(&serde_json::json!({
        "id": id,
        "title": title,
        "content": { "items": items },
    }))
}

fn simple_engine(quest_id: &str, nodes: Vec<SavedNode>) -> GameEngine {
    GameEngine::new(
        quest_id.to_string(),
        config(quest_id),
        nodes,
        vec![],
        GameEngineConfig::default(),
    )
}

#[test]
fn start_new_sets_system_vars_and_loads_start_node() {
    let nodes = vec![node(
        "node_1",
        "Start",
        vec![serde_json::json!({ "type": "text", "id": "it1", "text": "Hi" })],
    )];
    let mut engine = simple_engine("q1", nodes);
    let view = engine.start_new(None).unwrap();

    assert_eq!(view.node_id, "node_1");
    assert_eq!(view.title, "Start");
    // системные переменные
    assert_eq!(
        engine.state.get_variable("_SYS_QUEST_VERSION"),
        Some(&serde_json::Value::from("2.0.0"))
    );
    assert_eq!(
        engine.state.get_variable("_SYS_PLATFORM"),
        Some(&serde_json::Value::from(""))
    );
}

#[test]
fn start_new_leaves_background_blur_unset() {
    let nodes = vec![node(
        "node_1",
        "Start",
        vec![serde_json::json!({ "type": "text", "id": "a", "text": "one" })],
    )];
    let mut engine = simple_engine("q1", nodes);
    engine.start_new(None).unwrap();

    // Канал эффектов размытия пуст, пока скрипт его не тронул: иначе движок
    // сеет 10.0 сам и поле `backgroundBlur` ноды становится недостижимым.
    assert_eq!(engine.state.get_variable("_internal_background_blur"), None);
}

#[test]
fn start_from_save_drops_legacy_background_blur() {
    let nodes = vec![
        node("node_1", "Start", vec![]),
        node("node_2", "Next", vec![]),
    ];
    let mut engine = simple_engine("q1", nodes.clone());
    engine.start_new(None).unwrap();
    // Движок до фикса сеял 10.0 — в старом сейве он лежит как обычная
    // переменная и продолжал бы перебивать поле `backgroundBlur` ноды.
    engine
        .state
        .set_variable("_internal_background_blur", serde_json::json!(10.0));
    engine.load_node("node_2").unwrap();
    let save = engine.to_save_slot("s1").unwrap();

    let mut revived = simple_engine("q1", nodes);
    revived.start_from_save(&save).unwrap();
    assert_eq!(
        revived.state.get_variable("_internal_background_blur"),
        Some(&serde_json::Value::Null),
        "сейв не должен приносить размытие, которого скрипт не задавал"
    );
}

#[test]
fn next_item_reveals_items_in_order() {
    let nodes = vec![node(
        "node_1",
        "Start",
        vec![
            serde_json::json!({ "type": "text", "id": "a", "text": "one" }),
            serde_json::json!({ "type": "text", "id": "b", "text": "two" }),
        ],
    )];
    let mut engine = simple_engine("q1", nodes);
    engine.start_new(None).unwrap();

    match engine.next_item() {
        NextStep::Item(item) => assert_eq!(item.id, "a"),
        other => panic!("expected item, got {other:?}"),
    }
    match engine.next_item() {
        NextStep::Item(item) => assert_eq!(item.id, "b"),
        other => panic!("expected item, got {other:?}"),
    }
    matches!(engine.next_item(), NextStep::Done);
}

#[test]
fn script_item_triggers_transition_and_is_not_rendered() {
    let script_json = serde_json::json!({
        "name": "t",
        "blocks": [{"type": "go_to_node", "node_id": "node_2"}]
    });
    let nodes = vec![
        node(
            "node_1",
            "Start",
            vec![
                serde_json::json!({"type": "script", "id": "s1", "resourcePath": "scripts/jump.json"}),
                serde_json::json!({"type": "text", "id": "never", "text": "nope"}),
            ],
        ),
        node("node_2", "Second", vec![]),
    ];
    let mut scripts = HashMap::new();
    scripts.insert("scripts/jump.json".to_string(), script_json);
    let mut engine = GameEngine::new(
        "q1".to_string(),
        config("q1"),
        nodes,
        vec![],
        GameEngineConfig {
            platform: PlatformInfo::default(),
            embedded_scripts: scripts,
            asset_store: None,
            save_store: None,
        },
    );
    engine.start_new(None).unwrap();

    match engine.next_item() {
        NextStep::Transition(target) => assert_eq!(target, "node_2"),
        other => panic!("expected transition, got {other:?}"),
    }
}

#[test]
fn node_script_transition_on_enter() {
    let script_json = serde_json::json!({
        "name": "t",
        "blocks": [{"type": "go_to_node", "node_id": "node_3"}]
    });
    let nodes = vec![
        SavedNode::from_json(&serde_json::json!({
            "id": "node_1",
            "title": "Start",
            "content": { "items": [] },
            "scriptAssetId": "enter.json",
        })),
        node("node_3", "Third", vec![]),
    ];
    let mut scripts = HashMap::new();
    scripts.insert("enter.json".to_string(), script_json);
    let mut engine = GameEngine::new(
        "q1".to_string(),
        config("q1"),
        nodes,
        vec![],
        GameEngineConfig {
            platform: PlatformInfo::default(),
            embedded_scripts: scripts,
            asset_store: None,
            save_store: None,
        },
    );
    let view = engine.start_new(None).unwrap();
    assert_eq!(view.transition, Some("node_3".to_string()));
}

#[test]
fn interaction_executes_on_press_script() {
    let script_json = serde_json::json!({
        "name": "btn",
        "blocks": [
            {"type": "event", "eventType": "onPress", "children": [
                {"type": "assign_variable", "variable": "gold", "value": "10"}
            ]}
        ]
    });
    let nodes = vec![node("node_1", "Start", vec![])];
    let mut scripts = HashMap::new();
    scripts.insert("scripts/btn.json".to_string(), script_json);
    let mut engine = GameEngine::new(
        "q1".to_string(),
        config("q1"),
        nodes,
        vec![],
        GameEngineConfig {
            platform: PlatformInfo::default(),
            embedded_scripts: scripts,
            asset_store: None,
            save_store: None,
        },
    );
    engine.start_new(None).unwrap();

    let item = ContentItem::from_json(&serde_json::json!({
        "type": "button",
        "id": "b1",
        "scriptTriggers": {"onPress": "scripts/btn.json"}
    }));
    let result = engine.handle_interaction(&item, "scripts/btn.json");
    assert_eq!(result, None); // assign не даёт переход
    let v = engine.state.get_variable("gold").unwrap();
    assert_eq!(v, &serde_json::Value::from(10));
}

#[test]
fn resolve_target_expression() {
    let nodes = vec![node("node_1", "Start", vec![])];
    let mut engine = simple_engine("q1", nodes);
    engine.start_new(None).unwrap();
    engine
        .state
        .set_variable("next", serde_json::Value::from("node_9"));

    assert_eq!(
        engine.resolve_target_node_id("static_node"),
        Some("static_node".into())
    );
    assert_eq!(
        engine.resolve_target_node_id("={next}"),
        Some("node_9".into())
    );
}

#[test]
fn start_new_loads_default_variables_from_config() {
    let cfg = Quest::from_json(&serde_json::json!({
        "id": "q1",
        "title": "Q",
        "version": "1.0.0",
        "startNodeId": "node_1",
        "variables": [
            {"name": "playerName", "defaultValue": "Алиса"},
            {"name": "gold", "defaultValue": 100},
        ],
        "tables": [
            {
                "name": "inventory",
                "columns": ["item"],
                "rows": [{"item": "меч"}],
                "data": {"weapon": "sword"},
            }
        ],
    }));
    let nodes = vec![node("node_1", "Start", vec![])];
    let mut engine = GameEngine::new(
        "q1".to_string(),
        cfg,
        nodes,
        vec![],
        GameEngineConfig::default(),
    );
    engine.start_new(None).unwrap();

    // Дефолтная строка.
    assert_eq!(
        engine.state.get_variable("playerName"),
        Some(&serde_json::Value::from("Алиса"))
    );
    // Дефолтное число.
    assert_eq!(
        engine.state.get_variable("gold"),
        Some(&serde_json::Value::from(100))
    );
    // Дефолтная таблица.
    let table = engine.state.get_table("inventory").unwrap();
    assert_eq!(
        table.data.get("weapon"),
        Some(&serde_json::Value::from("sword"))
    );
}

#[test]
fn from_disk_loads_quest_and_lazy_scripts() {
    use std::fs;

    // Собираем квест на временном «диске»: root/quests/q1/{config,nodes}.
    let root = std::env::temp_dir().join(format!("mnd_engine_disk_{}", uuid_v4()));
    fs::create_dir_all(root.join("quests/q1")).unwrap();

    fs::write(
        root.join("quests/q1/config.json"),
        serde_json::json!({
            "id": "q1", "title": "Q", "version": "1.0.0", "startNodeId": "n1"
        })
        .to_string(),
    )
    .unwrap();
    fs::write(
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
    // Скрипт НЕ передаём в движок — он должен быть прочитан лениво с диска.
    fs::create_dir_all(root.join("quests/q1/scripts")).unwrap();
    fs::write(
        root.join("quests/q1/scripts/check.json"),
        serde_json::json!({
            "name": "check",
            "scriptTriggers": {
                "onContentAppear": "scripts/check.json"
            },
            "blocks": [{
                "type": "event",
                "eventType": "onContentAppear",
                "children": [
                    {"type": "go_to_node", "node_id": "n2"}
                ]
            }]
        })
        .to_string(),
    )
    .unwrap();

    let mut engine = GameEngine::from_disk("q1", &root).expect("движок создан");
    let view = engine.start_new(None).unwrap();
    assert_eq!(view.node_id, "n1");

    // Первый шаг — text-айтем.
    let step = engine.next_item();
    assert!(matches!(step, NextStep::Item(_)));

    // Второй шаг — script-айтем читается по требованию → переход на n2.
    let step = engine.next_item();
    assert!(matches!(step, NextStep::Transition(ref n) if n == "n2"));

    // Очистка временной директории (уникальный id — безопасно).
    let _ = fs::remove_dir_all(&root);
    let _ = root;
}

#[test]
fn from_disk_missing_config_is_none() {
    let root = std::env::temp_dir().join(format!("mnd_engine_none_{}", uuid_v4()));
    let engine = GameEngine::from_disk("q1", &root);
    assert!(engine.is_none());
}

#[test]
fn from_disk_reads_canonical_nodes_when_legacy_missing() {
    use std::fs;

    let root = std::env::temp_dir().join(format!("mnd_engine_canonical_{}", uuid_v4()));
    fs::create_dir_all(root.join("quests/q1/nodes")).unwrap();
    fs::write(
        root.join("quests/q1/config.json"),
        serde_json::json!({
            "id": "q1", "title": "Q", "version": "1.0.0", "startNodeId": "n1"
        })
        .to_string(),
    )
    .unwrap();
    fs::write(
        root.join("quests/q1/nodes/nodes.json"),
        serde_json::json!({
            "nodes": [{"id": "n1", "title": "Canonical", "content": {"items": []}}]
        })
        .to_string(),
    )
    .unwrap();

    let mut engine = GameEngine::from_disk("q1", &root).expect("движок создан");
    let view = engine.start_new(None).unwrap();
    assert_eq!(view.node_id, "n1");

    let _ = fs::remove_dir_all(&root);
}

#[test]
fn from_disk_reads_per_node_index_and_bodies() {
    use std::fs;

    let root = std::env::temp_dir().join(format!("mnd_engine_v2_{}", uuid_v4()));
    fs::create_dir_all(root.join("quests/q1/nodes")).unwrap();
    fs::write(
        root.join("quests/q1/config.json"),
        serde_json::json!({
            "id": "q1", "title": "Q", "version": "1.0.0", "startNodeId": "n1"
        })
        .to_string(),
    )
    .unwrap();
    fs::write(
        root.join("quests/q1/nodes/index.json"),
        serde_json::json!({
            "format_version": 2,
            "nodes": [
                {"id": "n1", "title": "Index title", "chapterId": "c1", "x": 1.0, "y": 2.0},
                {"id": "n2", "title": "Second", "chapterId": "c1", "x": 3.0, "y": 4.0}
            ],
            "edges": [],
            "groups": [],
            "comments": []
        })
        .to_string(),
    )
    .unwrap();
    fs::write(
        root.join("quests/q1/nodes/n1.json"),
        serde_json::json!({
            "id": "n1", "title": "Body title", "chapterId": "c1", "x": 1.0, "y": 2.0,
            "content": {"items": [{"type": "text", "id": "t1", "text": "v2 body"}]}
        })
        .to_string(),
    )
    .unwrap();
    fs::write(
        root.join("quests/q1/nodes/n2.json"),
        serde_json::json!({
            "id": "n2", "title": "Second", "chapterId": "c1", "x": 3.0, "y": 4.0,
            "content": {"items": []}
        })
        .to_string(),
    )
    .unwrap();

    let mut engine = GameEngine::from_disk("q1", &root).expect("движок создан");
    let view = engine.start_new(None).unwrap();
    assert_eq!(view.node_id, "n1");
    assert_eq!(view.title, "Body title");

    let _ = fs::remove_dir_all(&root);
}

#[test]
fn from_disk_v2_missing_body_falls_back_to_legacy() {
    use std::fs;

    let root = std::env::temp_dir().join(format!("mnd_engine_v2_fallback_{}", uuid_v4()));
    fs::create_dir_all(root.join("quests/q1/nodes")).unwrap();
    fs::write(
        root.join("quests/q1/config.json"),
        serde_json::json!({
            "id": "q1", "title": "Q", "version": "1.0.0", "startNodeId": "n1"
        })
        .to_string(),
    )
    .unwrap();
    fs::write(
        root.join("quests/q1/nodes/index.json"),
        serde_json::json!({
            "format_version": 2,
            "nodes": [{"id": "n1", "title": "Summary", "chapterId": "c1"}],
            "edges": [], "groups": [], "comments": []
        })
        .to_string(),
    )
    .unwrap();
    fs::write(
        root.join("quests/q1/nodes.json"),
        serde_json::json!({
            "nodes": [{"id": "n1", "title": "Legacy", "content": {"items": []}}]
        })
        .to_string(),
    )
    .unwrap();

    let mut engine = GameEngine::from_disk("q1", &root).expect("движок создан");
    let view = engine.start_new(None).unwrap();
    assert_eq!(view.title, "Legacy");

    let _ = fs::remove_dir_all(&root);
}

#[test]
fn from_disk_empty_canonical_falls_back_to_legacy() {
    use std::fs;

    let root = std::env::temp_dir().join(format!("mnd_engine_empty_canonical_{}", uuid_v4()));
    fs::create_dir_all(root.join("quests/q1/nodes")).unwrap();
    fs::write(
        root.join("quests/q1/config.json"),
        serde_json::json!({
            "id": "q1", "title": "Q", "version": "1.0.0", "startNodeId": "n1"
        })
        .to_string(),
    )
    .unwrap();
    // canonical есть, но пустой — как после сбоя редактора.
    fs::write(
        root.join("quests/q1/nodes/nodes.json"),
        serde_json::json!({"nodes": []}).to_string(),
    )
    .unwrap();
    fs::write(
        root.join("quests/q1/nodes.json"),
        serde_json::json!({
            "nodes": [{"id": "n1", "title": "Legacy", "content": {"items": []}}]
        })
        .to_string(),
    )
    .unwrap();

    let mut engine = GameEngine::from_disk("q1", &root).expect("движок создан");
    let view = engine.start_new(None).unwrap();
    assert_eq!(view.node_id, "n1");

    let _ = fs::remove_dir_all(&root);
}

#[test]
fn from_disk_call_lua_reads_lua_file_and_inline() {
    use std::fs;

    // Квест на «диске» с onNodeEnter-скриптом, который вызывает Lua
    // из файла (script_id) и inline-блок.
    let root = std::env::temp_dir().join(format!("mnd_engine_lua_{}", uuid_v4()));
    fs::create_dir_all(root.join("quests/q1/scripts")).unwrap();

    fs::write(
        root.join("quests/q1/config.json"),
        serde_json::json!({
            "id": "q1", "title": "Q", "version": "1.0.0", "startNodeId": "n1"
        })
        .to_string(),
    )
    .unwrap();
    fs::write(
        root.join("quests/q1/nodes.json"),
        serde_json::json!({
            "nodes": [{
                "id": "n1", "title": "Start",
                "content": { "items": [
                    {"type": "script", "id": "s", "resourcePath": "scripts/entry.json"}
                ]}
            }]
        })
        .to_string(),
    )
    .unwrap();
    // .lua файл на диске — читается движком через read_text.
    fs::write(
        root.join("quests/q1/scripts/start.lua"),
        "function start()\n  core.set_var('from_file', 42)\nend\n",
    )
    .unwrap();
    fs::write(
        root.join("quests/q1/scripts/entry.json"),
        serde_json::json!({
            "name": "entry",
            "scriptTriggers": {
                "onNodeEnter": "scripts/entry.json"
            },
            "blocks": [{
                "type": "event",
                "eventType": "onNodeEnter",
                "children": [
                    {"type": "call_lua", "script_id": "start.lua", "function": "start"},
                    {"type": "call_lua", "function": "inline_fn",
                     "script": "function inline_fn() core.set_var('from_inline', 'yes') return { node = 'n2' } end"}
                ]
            }]
        })
        .to_string(),
    )
    .unwrap();

    let mut engine = GameEngine::from_disk("q1", &root).expect("движок создан");
    let view = engine.start_new(None).unwrap();
    // Inline-блок вернул переход { node = 'n2' }.
    assert_eq!(view.transition.as_deref(), Some("n2"));
    // Переменные из .lua-файла и inline-блока применены.
    assert_eq!(
        engine.state.get_variable("from_file"),
        Some(&serde_json::Value::from(42))
    );
    assert_eq!(
        engine.state.get_variable("from_inline"),
        Some(&serde_json::Value::from("yes"))
    );

    let _ = fs::remove_dir_all(&root);
}

#[test]
fn from_disk_lua_as_node_script_asset_id() {
    use std::fs;

    // `scriptAssetId` ноды указывает на `.lua`: функция события
    // `onNodeEnter` вызывается при загрузке ноды.
    let root = std::env::temp_dir().join(format!("mnd_engine_lua_enter_{}", uuid_v4()));
    fs::create_dir_all(root.join("quests/q1/scripts")).unwrap();

    fs::write(
        root.join("quests/q1/config.json"),
        serde_json::json!({
            "id": "q1", "title": "Q", "version": "1.0.0", "startNodeId": "n1"
        })
        .to_string(),
    )
    .unwrap();
    fs::write(
        root.join("quests/q1/nodes.json"),
        serde_json::json!({ "nodes": [
            { "id": "n1", "title": "Start", "content": { "items": [] }, "scriptAssetId": "scripts/enter.lua" },
            { "id": "n2", "title": "Next", "content": { "items": [] } }
        ]})
        .to_string(),
    )
    .unwrap();
    fs::write(
        root.join("quests/q1/scripts/enter.lua"),
        "function onNodeEnter() core.set_var('entered', true) return { node = 'n2' } end\n",
    )
    .unwrap();

    let mut engine = GameEngine::from_disk("q1", &root).expect("движок создан");
    let view = engine.start_new(None).unwrap();
    assert_eq!(view.transition.as_deref(), Some("n2"));
    assert_eq!(
        engine.state.get_variable("entered"),
        Some(&serde_json::Value::Bool(true))
    );

    let _ = fs::remove_dir_all(&root);
}

#[test]
fn from_disk_lua_as_item_script_trigger_on_press() {
    use std::fs;

    // `scriptTriggers.onPress` айтема указывает на `.lua`: `onPress`
    // вызывается при нажатии, контекст (item id) передаётся аргументом.
    let root = std::env::temp_dir().join(format!("mnd_engine_lua_press_{}", uuid_v4()));
    fs::create_dir_all(root.join("quests/q1/scripts")).unwrap();

    fs::write(
        root.join("quests/q1/config.json"),
        serde_json::json!({
            "id": "q1", "title": "Q", "version": "1.0.0", "startNodeId": "n1"
        })
        .to_string(),
    )
    .unwrap();
    fs::write(
        root.join("quests/q1/nodes.json"),
        serde_json::json!({ "nodes": [
            { "id": "n1", "title": "Start", "content": { "items": [] } }
        ]})
        .to_string(),
    )
    .unwrap();
    fs::write(
        root.join("quests/q1/scripts/btn.lua"),
        "function onPress(item_id) core.set_var('pressed_item', item_id) core.set_var('pressed', true) end\n",
    )
    .unwrap();

    let mut engine = GameEngine::from_disk("q1", &root).expect("движок создан");
    engine.start_new(None).unwrap();

    let item = ContentItem::from_json(&serde_json::json!({
        "type": "button",
        "id": "b1",
        "scriptTriggers": {"onPress": "scripts/btn.lua"}
    }));
    let result = engine.handle_interaction(&item, "scripts/btn.lua");
    assert_eq!(result, None); // нет перехода
    assert_eq!(
        engine.state.get_variable("pressed"),
        Some(&serde_json::Value::Bool(true))
    );
    assert_eq!(
        engine.state.get_variable("pressed_item"),
        Some(&serde_json::Value::from("b1"))
    );

    let _ = fs::remove_dir_all(&root);
}

#[test]
fn placeholder_resolves_to_default_variable() {
    let cfg = Quest::from_json(&serde_json::json!({
        "id": "q1",
        "title": "Q",
        "version": "1.0.0",
        "startNodeId": "node_1",
        "variables": [{"name": "hero", "defaultValue": "Артур"}],
    }));
    let nodes = vec![node("node_1", "Start", vec![])];
    let mut engine = GameEngine::new(
        "q1".to_string(),
        cfg,
        nodes,
        vec![],
        GameEngineConfig::default(),
    );
    engine.start_new(None).unwrap();

    // Плейсхолдер {hero} резолвится в значение по быстрому пути.
    let result = crate::executor::evaluate_expression(
        Some(serde_json::Value::String("{hero}".to_string())),
        &mut engine.state,
    );
    assert_eq!(result, serde_json::Value::from("Артур"));
}

#[test]
fn drain_state_delta_reports_only_changes() {
    let nodes = vec![node(
        "node_1",
        "Start",
        vec![serde_json::json!({ "type": "text", "id": "it1", "text": "Hi" })],
    )];
    let mut engine = simple_engine("q1", nodes);
    engine.start_new(None).unwrap();

    // Первый drain: всё, установленное при старте (системные + дефолтные) — непусто.
    let first = engine.drain_state_delta();
    assert!(first.variables.contains_key("_SYS_QUEST_VERSION"));

    // Второй drain без изменений — пусто.
    let empty = engine.drain_state_delta();
    assert!(empty.variables.is_empty());
    assert!(empty.tables.is_empty());

    // Изменили одну переменную — в дельте только она.
    engine.state.set_variable("hp", Value::from(7.0));
    let second = engine.drain_state_delta();
    assert_eq!(second.variables.len(), 1);
    assert_eq!(second.variables.get("hp"), Some(&"7.0".to_string()));

    // После drain снова пусто.
    let third = engine.drain_state_delta();
    assert!(third.variables.is_empty());
}

#[test]
fn to_save_slot_collects_state_without_writing() {
    let mut engine = simple_engine("q1", vec![node("node_1", "Start", vec![])]);
    engine.start_new(None).unwrap();
    engine.state.set_variable("hp", Value::from(42.0));

    let slot = engine.to_save_slot("reload").unwrap();
    assert_eq!(slot.slot_name, "reload");
    assert_eq!(slot.current_node_id, "node_1");
    assert_eq!(slot.variables.get("hp"), Some(&Value::from(42.0)));
    assert_ne!(slot.id, "");
    assert!(engine.list_saves().is_empty());
}

#[test]
fn to_save_slot_at_overrides_current_node() {
    let mut engine = simple_engine("q1", vec![node("node_1", "Start", vec![])]);
    engine.start_new(None).unwrap();
    engine.state.set_variable("hp", Value::from(42.0));

    let slot = engine.to_save_slot_at("reload", "node_9").unwrap();
    assert_eq!(slot.current_node_id, "node_9");
    assert_eq!(slot.variables.get("hp"), Some(&Value::from(42.0)));
}

#[test]
fn to_save_slot_none_unless_started() {
    let engine = simple_engine("q1", vec![node("node_1", "Start", vec![])]);
    assert!(engine.to_save_slot("x").is_none());
    assert!(engine.to_save_slot_at("x", "node_1").is_some());
}

#[test]
fn for_each_iterates_table_rows_and_sets_column_variables() {
    let cfg = Quest::from_json(&serde_json::json!({
        "id": "q_fe", "title": "ForEach Test", "startNodeId": "start",
        "variables": [],
        "tables": [
            {
                "name": "enemies",
                "columns": ["name", "hp"],
                "rows": [
                    {"name": "Goblin", "hp": "10"},
                    {"name": "Orc", "hp": "25"},
                    {"name": "Dragon", "hp": "100"}
                ],
                "data": {}
            }
        ]
    }));
    let n = node(
        "start",
        "Start",
        vec![serde_json::json!({
            "type": "text", "id": "msg", "text": "Fight!"
        })],
    );
    let mut engine = GameEngine::new(
        "q_fe".into(),
        cfg,
        vec![n],
        vec![],
        GameEngineConfig::default(),
    );
    engine.start_new(None);

    let block = &serde_json::json!({
        "type": "for_each",
        "table": "enemies",
        "var_prefix": "mob",
        "index_variable": "idx",
        "children": [{
            "type": "assign_variable",
            "variable": "last_name",
            "value": "mob_name"
        }]
    })
    .as_object()
    .unwrap()
    .clone();

    let exec = ScriptExecutor::new();
    let mut lua = None;
    let mut ctrl = crate::executor::ExecutionController::default();
    let res = exec.execute_block_recursively(block, &mut engine.state, &mut ctrl, "q_fe", &mut lua);
    assert!(res.is_ok(), "for_each should succeed: {:?}", res.err());
    // After iterating 3 rows, last_name should be "Dragon" (from last row)
    assert_eq!(
        engine.state.get_variable("last_name"),
        Some(&serde_json::json!("Dragon"))
    );
    assert_eq!(
        engine.state.get_variable("mob_name"),
        Some(&serde_json::json!("Dragon"))
    );
    assert_eq!(
        engine.state.get_variable("mob_hp"),
        Some(&serde_json::json!("100"))
    );
    assert_eq!(
        engine.state.get_variable("idx"),
        Some(&serde_json::json!(2))
    );
}

/// Дефолты движка должны совпадать с подсказками редактора (`row`, `i`):
/// автор пишет `{row_name}` и получает их. НЕГАТИВНЫЙ КОНТРОЛЬ: до правки
/// префиксом служило имя таблицы → `enemies_name`, а `{row_name}` в тексте
/// оставалось неразведённым — «цикл по таблице не работает».
#[test]
fn for_each_defaults_match_editor_placeholders() {
    let cfg = Quest::from_json(&serde_json::json!({
        "id": "q_fe2", "title": "ForEach defaults", "startNodeId": "start",
        "variables": [],
        "tables": [{
            "name": "enemies", "columns": ["name"],
            "rows": [{"name": "Goblin"}, {"name": "Orc"}], "data": {}
        }]
    }));
    let n = node("start", "Start", vec![]);
    let mut engine = GameEngine::new(
        "q_fe2".into(),
        cfg,
        vec![n],
        vec![],
        GameEngineConfig::default(),
    );
    engine.start_new(None);

    // Поля есть, но пустые — как их сохраняет редактор, когда автор
    // ничего не вводил.
    let block = serde_json::json!({
        "type": "for_each",
        "table": "enemies",
        "var_prefix": "",
        "index_variable": "   ",
        "children": [{
            "type": "assign_variable",
            "variable": "rows_seen",
            "value": "1"
        }]
    })
    .as_object()
    .unwrap()
    .clone();

    let exec = ScriptExecutor::new();
    let mut lua = None;
    let mut ctrl = crate::executor::ExecutionController::default();
    exec.execute_block_recursively(&block, &mut engine.state, &mut ctrl, "q_fe2", &mut lua)
        .expect("for_each без префикса не должен падать");

    assert_eq!(
        engine.state.get_variable("row_name"),
        Some(&serde_json::json!("Orc")),
        "пустой префикс не должен порождать переменные вида `_name`"
    );
    assert_eq!(
        engine.state.get_variable("i"),
        Some(&serde_json::json!(1)),
        "счётчик по умолчанию называется i, а не enemies_index"
    );
}

#[test]
fn set_image_writes_source_override_into_state() {
    let mut engine = simple_engine("q_si", vec![node("node_1", "Start", vec![])]);
    engine.start_new(None);
    engine
        .state
        .set_variable("pic", serde_json::json!("res/images/cat.png"));

    let exec = ScriptExecutor::new();
    let mut lua = None;
    let mut ctrl = crate::executor::ExecutionController::default();

    let mut run = |block: Value, engine: &mut GameEngine| {
        exec.execute_block_recursively(
            block.as_object().unwrap(),
            &mut engine.state,
            &mut ctrl,
            "q_si",
            &mut lua,
        )
    };

    // Источник — шаблон: `{pic}` раскрывается значением переменной.
    run(
        serde_json::json!({"type": "set_image", "item_id": "img", "source": "{pic}"}),
        &mut engine,
    )
    .unwrap();
    assert_eq!(
        engine.state.get_variable("_internal_item_sources"),
        Some(&serde_json::json!({"img": "res/images/cat.png"}))
    );

    // Второй айтем не затирает первый.
    run(
        serde_json::json!({"type": "set_image", "item_id": "icon", "source": "закат"}),
        &mut engine,
    )
    .unwrap();
    assert_eq!(
        engine.state.get_variable("_internal_item_sources"),
        Some(&serde_json::json!({
            "img": "res/images/cat.png",
            "icon": "закат",
        }))
    );

    // Пустой источник — пропуск: картинку нельзя выключить «в никуда».
    run(
        serde_json::json!({"type": "set_image", "item_id": "img", "source": "  "}),
        &mut engine,
    )
    .unwrap();
    assert_eq!(
        engine
            .state
            .get_variable("_internal_item_sources")
            .and_then(|v| v.get("icon"))
            .and_then(|v| v.as_str()),
        Some("закат")
    );
}

#[test]
fn set_visible_writes_hidden_override_into_state() {
    let mut engine = simple_engine("q_sv", vec![node("node_1", "Start", vec![])]);
    engine.start_new(None);

    let exec = ScriptExecutor::new();
    let mut lua = None;
    let mut ctrl = crate::executor::ExecutionController::default();

    let mut run = |block: Value, engine: &mut GameEngine| {
        exec.execute_block_recursively(
            block.as_object().unwrap(),
            &mut engine.state,
            &mut ctrl,
            "q_sv",
            &mut lua,
        )
    };
    let hidden = |engine: &GameEngine| -> Value {
        engine
            .state
            .get_variable("_internal_item_hidden")
            .cloned()
            .unwrap_or(Value::Null)
    };

    run(
        serde_json::json!({"type": "set_visible", "item_id": "photo", "mode": "hide"}),
        &mut engine,
    )
    .unwrap();
    assert_eq!(hidden(&engine), serde_json::json!({"photo": "hidden"}));

    // Второй айтем не затирает первый, а show пишет "visible", а не удаляет
    // ключ: «показано» тоже переопределение — оно перекрывает сейв.
    run(
        serde_json::json!({"type": "set_visible", "item_id": "hud", "mode": "show"}),
        &mut engine,
    )
    .unwrap();
    assert_eq!(
        hidden(&engine),
        serde_json::json!({"photo": "hidden", "hud": "visible"})
    );

    // toggle считает от текущего значения.
    run(
        serde_json::json!({"type": "set_visible", "item_id": "photo", "mode": "toggle"}),
        &mut engine,
    )
    .unwrap();
    assert_eq!(
        hidden(&engine).get("photo"),
        Some(&serde_json::json!("visible"))
    );

    // «убрать» — второй способ спрятать: айтем выходит из раскладки.
    run(
        serde_json::json!({"type": "set_visible", "item_id": "photo", "mode": "remove"}),
        &mut engine,
    )
    .unwrap();
    assert_eq!(
        hidden(&engine).get("photo"),
        Some(&serde_json::json!("gone"))
    );

    // Русская запись полей — те же самые поля, что читает блок.
    run(
        serde_json::json!({"type": "set_visible", "айтем": "photo", "режим": "скрыть"}),
        &mut engine,
    )
    .unwrap();
    assert_eq!(
        hidden(&engine).get("photo"),
        Some(&serde_json::json!("hidden"))
    );

    // Ни айтема, ни режима — тишина: карта не меняется.
    run(
        serde_json::json!({"type": "set_visible", "item_id": "photo"}),
        &mut engine,
    )
    .unwrap();
    assert_eq!(
        hidden(&engine).get("photo"),
        Some(&serde_json::json!("hidden"))
    );
    run(
        serde_json::json!({"type": "set_visible", "mode": "hide"}),
        &mut engine,
    )
    .unwrap();
    assert_eq!(
        hidden(&engine),
        serde_json::json!({"photo": "hidden", "hud": "visible"})
    );
}

#[test]
fn block_types_json_is_valid() {
    let json = crate::blocks::list_block_types_json();
    let arr = json.as_array().expect("should be array");
    assert!(arr.len() >= 20, "expected >=20 blocks, got {}", arr.len());
    for entry in arr {
        let name = entry["name"].as_str().expect("should have name");
        let display = entry["displayName"]
            .as_str()
            .expect("should have displayName");
        let category = entry["category"].as_str().expect("should have category");
        assert!(!name.is_empty(), "name should not be empty");
        assert!(
            !display.is_empty(),
            "displayName of {} should not be empty",
            name
        );
        assert!(
            matches!(
                category,
                "variable" | "data" | "flow" | "script" | "audio" | "network" | "comment"
            ),
            "unknown category '{}' for block {}",
            category,
            name
        );
    }
}

#[test]
fn while_loop_iterates_while_condition_true() {
    use crate::executor::ExecutionController;

    let cfg = Quest::from_json(&serde_json::json!({
        "id": "q_wl", "title": "While Test", "startNodeId": "start",
        "variables": [],
        "tables": []
    }));
    let n = node("start", "Start", vec![]);
    let mut engine = GameEngine::new(
        "q_wl".into(),
        cfg,
        vec![n],
        vec![],
        GameEngineConfig::default(),
    );
    engine.start_new(None);

    let exec = ScriptExecutor::new();
    let mut lua = None;
    let mut ctrl = ExecutionController::default();

    // Set counter
    let block_init = &serde_json::json!({
        "type": "assign_variable", "variable": "i", "value": "0"
    })
    .as_object()
    .unwrap()
    .clone();
    exec.execute_block_recursively(block_init, &mut engine.state, &mut ctrl, "q_wl", &mut lua)
        .unwrap();

    // while i < 3: i = i + 1
    let block_while = &serde_json::json!({
        "type": "while",
        "expression": "i < 3",
        "children": [{
            "type": "assign_variable",
            "variable": "i",
            "value": "i + 1"
        }]
    })
    .as_object()
    .unwrap()
    .clone();
    let res =
        exec.execute_block_recursively(block_while, &mut engine.state, &mut ctrl, "q_wl", &mut lua);
    assert!(res.is_ok(), "while should succeed: {:?}", res.err());
    let i_val = engine
        .state
        .get_variable("i")
        .and_then(|v| v.as_f64())
        .unwrap_or(-1.0);
    assert_eq!(i_val, 3.0, "while loop should run 3 iterations");
}
