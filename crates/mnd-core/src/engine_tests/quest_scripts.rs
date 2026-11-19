//! Квестовые скрипты: движок сам находит файлы в `scripts/`, которые
//! объявляют событие «при запуске квеста». Реестра `globalScripts` больше нет.
//!
//! `onQuestStart` выполняется при начале новой игры; при загрузке из сейва
//! Lua-файлы только подключаются (функции автора должны быть видны нодам),
//! а стартовые блоки не запускаются.

use super::*;
use serde_json::{Value, json};

static FIXTURE_COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// Каталог-фикстура: пишет файлы во временный каталог, отдаёт его root.
fn fixture_root(files: &[(&str, &str)]) -> std::path::PathBuf {
    let n = FIXTURE_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let root = std::env::temp_dir().join(format!("mnd_quest_scripts_{}_{}", std::process::id(), n));
    let _ = std::fs::remove_dir_all(&root);
    for (path, content) in files {
        let full = root.join(path);
        if let Some(parent) = full.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        std::fs::write(&full, content).expect("write fixture");
    }
    root
}

/// Квест на «диске» из файлов фикстуры.
fn engine_from_files(files: &[(&str, &str)]) -> (GameEngine, std::path::PathBuf) {
    let root = fixture_root(files);
    (
        GameEngine::from_disk("q1", &root).expect("движок создан"),
        root,
    )
}

fn config() -> String {
    json!({
        "id": "q1", "title": "Q", "version": "2.0.0", "startNodeId": "n1",
    })
    .to_string()
}

fn nodes_json(nodes: Vec<Value>) -> String {
    json!({ "nodes": nodes }).to_string()
}

fn plain_node(id: &str, title: &str) -> Value {
    json!({ "id": id, "title": title, "content": { "items": [] } })
}

fn script_node(id: &str, title: &str, lua: &str) -> Value {
    json!({
        "id": id, "title": title, "content": { "items": [] },
        "scriptAssetId": lua,
    })
}

fn num(state: &InMemoryScriptRuntimeState, name: &str) -> Option<f64> {
    state.get_variable(name).and_then(Value::as_f64)
}

/// Стартовый блок в визуальном скрипте.
fn start_block(variable: &str, value: i64) -> Value {
    json!({
        "blocks": [
            {"type": "event", "eventType": "onQuestStart", "children": [
                {"type": "assign_variable", "variable": variable, "value": value}
            ]}
        ]
    })
}

// ─── Раскопка каталога scripts/ ─────────────────────────────────────────

#[test]
fn quest_script_with_start_event_runs_before_first_node() {
    let nodes = nodes_json(vec![plain_node("n1", "Start")]);
    let boot = start_block("boot", 7).to_string();

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/boot.json", &boot),
    ]);

    let view = engine.start_new(None).expect("старт");
    assert_eq!(view.node_id, "n1");
    assert_eq!(num(&engine.state, "boot"), Some(7.0));

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn quest_start_title_is_enough_for_discovery() {
    // Старые скрипты хранят событие только в `title` — «При запуске квеста».
    let nodes = nodes_json(vec![plain_node("n1", "Start")]);
    let boot = json!({
        "blocks": [
            {"type": "event", "title": "При запуске квеста", "children": [
                {"type": "assign_variable", "variable": "boot", "value": 3}
            ]}
        ]
    })
    .to_string();

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/boot.json", &boot),
    ]);

    engine.start_new(None).expect("старт");
    assert_eq!(num(&engine.state, "boot"), Some(3.0));

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn script_without_start_event_is_not_run_at_boot() {
    // Ключевое отличие от реестра AutoLoad: голый «тело»-скрипт больше не
    // считается стартовым. Он вызывается только по ссылке из ноды.
    // Негативный контроль: с фолбэком «плоского скрипта» boot=5 появился бы.
    let nodes = nodes_json(vec![plain_node("n1", "Start")]);
    let body = json!({
        "blocks": [{"type": "assign_variable", "variable": "boot", "value": 5}]
    })
    .to_string();
    let other_event = json!({
        "blocks": [
            {"type": "event", "eventType": "onNodeEnter", "children": [
                {"type": "assign_variable", "variable": "entered", "value": 1}
            ]}
        ]
    });

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/body.json", &body.to_string()),
        ("quests/q1/scripts/other.json", &other_event.to_string()),
    ]);

    engine.start_new(None).expect("старт");
    assert!(engine.state.get_variable("boot").is_none());
    assert!(engine.state.get_variable("entered").is_none());

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn scripts_outside_the_scripts_dir_are_not_discovered() {
    let nodes = nodes_json(vec![plain_node("n1", "Start")]);
    let stray = start_block("boot", 4).to_string();

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/res/stray.json", &stray),
    ]);

    engine.start_new(None).expect("старт");
    assert!(engine.state.get_variable("boot").is_none());

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn quest_scripts_run_in_sorted_order() {
    // Порядка «как в реестре» нет: алфавит по имени файла детерминирован.
    let nodes = nodes_json(vec![plain_node("n1", "Start")]);
    let a = start_block("seed", 1).to_string();
    let b = "function onQuestStart()\n\
             \x20 core.set_var('seed', (core.get_var('seed') or 0) + 10)\nend\n";

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/a.json", &a),
        ("quests/q1/scripts/b.lua", b),
    ]);

    engine.start_new(None).expect("старт");
    // 11 — визуальный отработал раньше Lua. Обратный порядок дал бы 10.
    assert_eq!(num(&engine.state, "seed"), Some(11.0));

    let _ = std::fs::remove_dir_all(&root);
}

// ─── Lua ────────────────────────────────────────────────────────────────

#[test]
fn lua_start_hook_runs_and_its_functions_are_visible_to_node_scripts() {
    let nodes = nodes_json(vec![script_node("n1", "Start", "scripts/enter.lua")]);
    let globals = "function onQuestStart()\n  core.set_var('booted', 1)\nend\n\n\
                   function quest_double(n)\n  core.set_var('doubled', n * 2)\nend\n";
    let enter = "function onNodeEnter()\n  quest_double(21)\nend\n";

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/globals.lua", globals),
        ("quests/q1/scripts/enter.lua", enter),
    ]);

    let view = engine.start_new(None).expect("старт");
    assert_eq!(view.node_id, "n1");
    assert_eq!(num(&engine.state, "booted"), Some(1.0));
    assert_eq!(num(&engine.state, "doubled"), Some(42.0));

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn quest_lua_cannot_reach_the_host_nor_forge_engine_commands() {
    // Регрессия дыр: из скачанного квеста Lua читала файлы хоста, вытягивала
    // окружение, грузила чужой .lua с диска и писала `_internal_*` команды в
    // обход фильтров движка. Сцена при этом обязана играться как обычно.
    let nodes = nodes_json(vec![script_node("n1", "Start", "scripts/evil.lua")]);
    let evil = "function onQuestStart()\n                    core.set_var('io_type', type(io))\n                    core.set_var('env_type', type(os.getenv))\n                    core.set_var('require_type', type(require))\n                    core.set_var('loadfile_type', type(loadfile))\n                end\n\n                function onNodeEnter()\n                    local ok = pcall(core.set_var, '_internal_external_commands',\n                        { { type = 'open_link', url = 'file:///etc/passwd' } })\n                    core.set_var('forge_blocked', not ok)\n                    core.set_var('scene_runs', true)\n                end\n";

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/evil.lua", evil),
    ]);

    let view = engine.start_new(None).expect("старт");
    assert_eq!(view.node_id, "n1");
    assert_eq!(engine.state.get_variable("io_type"), Some(&json!("nil")));
    assert_eq!(engine.state.get_variable("env_type"), Some(&json!("nil")));
    assert_eq!(
        engine.state.get_variable("require_type"),
        Some(&json!("nil"))
    );
    assert_eq!(
        engine.state.get_variable("loadfile_type"),
        Some(&json!("nil"))
    );
    assert_eq!(
        engine.state.get_variable("forge_blocked"),
        Some(&json!(true))
    );
    assert_eq!(engine.state.get_variable("scene_runs"), Some(&json!(true)));
    let queued = engine
        .state
        .get_variable("_internal_external_commands")
        .cloned()
        .unwrap_or(Value::Null);
    assert!(
        !queued.to_string().contains("open_link"),
        "подделанная команда всё-таки легла в очередь: {queued}"
    );

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn lua_library_without_start_hook_is_connected_but_not_invoked() {
    // Фолбэк «нет функции события → зовём start» остаётся у ссылок из ноды,
    // но при раскопке он запускал бы каждый файл квеста.
    let nodes = nodes_json(vec![plain_node("n1", "Start")]);
    let lib = "function start()\n  core.set_var('booted', 1)\nend\n";

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/lib.lua", lib),
    ]);

    engine.start_new(None).expect("старт");
    assert!(engine.state.get_variable("booted").is_none());

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn start_from_save_connects_quest_lua_without_running_the_hook() {
    let nodes = nodes_json(vec![
        plain_node("n1", "Start"),
        script_node("n2", "Next", "scripts/enter.lua"),
    ]);
    let globals = "function onQuestStart()\n  core.set_var('coins', 0)\nend\n\n\
                   function announce()\n  local c = core.get_var('announced') or 0\n\
                   core.set_var('announced', c + 1)\nend\n";
    let enter = "function onNodeEnter()\n  announce()\nend\n";
    let cfg = config();
    let files = [
        ("quests/q1/config.json", cfg.as_str()),
        ("quests/q1/nodes.json", nodes.as_str()),
        ("quests/q1/scripts/globals.lua", globals),
        ("quests/q1/scripts/enter.lua", enter),
    ];

    // Новая игра: хук обнуляет монеты, игрок «зарабатывает» 77, уходит на n2.
    let (mut first, root) = engine_from_files(&files);
    first.start_new(None).expect("старт");
    assert_eq!(num(&first.state, "coins"), Some(0.0));
    first.state.set_variable("coins", json!(77));
    first.load_node("n2").expect("нода n2");
    assert_eq!(num(&first.state, "announced"), Some(1.0));
    let save = first.to_save_slot("s1").expect("сейв");

    // Загрузка: `onQuestStart` НЕ запускается (иначе прогресс обнулён),
    // но файл подключён — функция `announce` из него вызывается нодой.
    let mut revived = GameEngine::from_disk("q1", &root).expect("второй движок");
    let view = revived.start_from_save(&save).expect("старт из сейва");
    assert_eq!(view.node_id, "n2");
    assert_eq!(num(&revived.state, "coins"), Some(77.0));
    assert_eq!(num(&revived.state, "announced"), Some(2.0));

    let _ = std::fs::remove_dir_all(&root);
}

// ─── Переход из стартового скрипта ──────────────────────────────────────

fn boot_with_goto(target: &str) -> String {
    json!({
        "blocks": [
            {"type": "event", "eventType": "onQuestStart", "children": [
                {"type": "assign_variable", "variable": "boot", "value": 2},
                {"type": "go_to_node", "node_id": target}
            ]}
        ]
    })
    .to_string()
}

#[test]
fn quest_script_transition_selects_the_start_node() {
    let nodes = nodes_json(vec![
        plain_node("n1", "Start"),
        plain_node("n2", "Prologue"),
    ]);
    let boot = boot_with_goto("n2");

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/boot.json", &boot),
    ]);

    let view = engine.start_new(None).expect("старт");
    assert_eq!(view.node_id, "n2");
    assert_eq!(num(&engine.state, "boot"), Some(2.0));

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn explicit_start_node_wins_over_script_transition() {
    let nodes = nodes_json(vec![
        plain_node("n1", "Start"),
        plain_node("n2", "Prologue"),
        plain_node("n3", "Chosen"),
    ]);
    let boot = boot_with_goto("n2");

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/boot.json", &boot),
    ]);

    // «Играть с этой ноды» в редакторе важнее решения скрипта.
    let view = engine.start_new(Some("n3")).expect("старт");
    assert_eq!(view.node_id, "n3");
    assert_eq!(num(&engine.state, "boot"), Some(2.0));

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn passing_the_config_start_node_is_not_an_explicit_override() {
    let nodes = nodes_json(vec![
        plain_node("n1", "Start"),
        plain_node("n2", "Prologue"),
    ]);
    let boot = boot_with_goto("n2");

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/boot.json", &boot),
    ]);

    // Плеер всегда передаёт `config.startNodeId` тем же аргументом. Если
    // принимать его за явную просьбу, переход из скрипта не сработал бы.
    let view = engine.start_new(Some("n1")).expect("старт");
    assert_eq!(view.node_id, "n2");

    let _ = std::fs::remove_dir_all(&root);
}

// ─── Толерантность и сериализация ───────────────────────────────────────

#[test]
fn unreadable_script_in_the_directory_does_not_break_start() {
    let nodes = nodes_json(vec![plain_node("n1", "Start")]);
    let globals = "function onQuestStart()\n  core.set_var('booted', 1)\nend\n";

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/broken.json", "{ это не json"),
        ("quests/q1/scripts/notes.txt", "черновики"),
        ("quests/q1/scripts/globals.lua", globals),
    ]);

    let view = engine.start_new(None).expect("старт");
    assert_eq!(view.node_id, "n1");
    assert_eq!(num(&engine.state, "booted"), Some(1.0));

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn quest_json_roundtrip_keeps_author_defaults_and_drops_the_old_registry() {
    // Экспорт .qst идёт через `Quest::to_json`: `globalScripts` больше не
    // часть модели — старый ключ молча теряется при пересохранении, а
    // квестовые скрипты движок находит по объявленному событию.
    let quest = Quest::from_json(&json!({
        "id": "q1", "title": "Q", "version": "2.0.0", "startNodeId": "n1",
        "globalScripts": ["scripts/globals.lua", "scripts/boot.json"],
        "variables": [{"name": "hp", "defaultValue": 100}],
        "tables": [{"name": "inventory", "columns": ["item"], "rows": [["sword"]]}],
    }));

    let dumped = quest.to_json();
    assert_eq!(dumped.get("globalScripts"), None);
    assert_eq!(dumped["variables"][0]["name"], "hp");
    assert_eq!(dumped["variables"][0]["defaultValue"], 100);
    assert_eq!(dumped["tables"][0]["name"], "inventory");

    let revived = Quest::from_json(&dumped);
    assert_eq!(revived.variables, quest.variables);
    assert_eq!(revived.tables, quest.tables);
}

#[test]
fn declares_event_requires_an_explicit_start_block() {
    // Негативный контроль предиката раскопки: фолбэк плоского скрипта из
    // `has_executable_blocks_for_event` здесь недопустим.
    let flat: Map<String, Value> = serde_json::from_value(json!({
        "blocks": [{"type": "assign_variable", "variable": "boot", "value": 1}]
    }))
    .unwrap();
    assert!(!crate::executor::declares_event(
        &flat,
        EventType::OnQuestStart
    ));

    let declared: Map<String, Value> = serde_json::from_value(start_block("boot", 1)).unwrap();
    assert!(crate::executor::declares_event(
        &declared,
        EventType::OnQuestStart
    ));
    assert!(!crate::executor::declares_event(
        &declared,
        EventType::OnNodeEnter
    ));
}

#[test]
fn lua_source_declares_matches_whole_identifiers_only() {
    assert!(crate::executor::lua_source_declares(
        "function onQuestStart() end",
        "onQuestStart"
    ));
    assert!(crate::executor::lua_source_declares(
        "M.onQuestStart = function() end",
        "onQuestStart"
    ));
    // Подстрока в чужом имени — не объявление. Ложное срабатывание на
    // упоминание в комментарии безопасно: движок зовёт функцию по имени, а
    // её отсутствие не запускает `start` (см. предыдущий тест).
    assert!(!crate::executor::lua_source_declares(
        "function onQuestStarted() end",
        "onQuestStart"
    ));
    assert!(!crate::executor::lua_source_declares(
        "local quest = { start = 1 }",
        "onQuestStart"
    ));
}
