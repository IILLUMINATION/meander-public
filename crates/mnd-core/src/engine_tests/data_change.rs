//! Событие «При изменении данных» — диспетчер, который мониторит указанные
//! автором пути и запускается, как только они меняются.
//!
//! Реестра нет: движок сам находит блоки `onDataChange` в скриптах `scripts/`
//! и текущей ноды (та же раскопка, что у `onQuestStart`). Изменения собираются
//! в пачку за игровой шаг и прогоняются на границе шага — не на каждом
//! присваивании внутри скрипта.

use super::*;
use serde_json::{Value, json};

static FIXTURE_COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

fn fixture_root(files: &[(&str, &str)]) -> std::path::PathBuf {
    let n = FIXTURE_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let root = std::env::temp_dir().join(format!("mnd_data_change_{}_{}", std::process::id(), n));
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

fn script_node(id: &str, title: &str, script: &str) -> Value {
    json!({
        "id": id, "title": title, "content": { "items": [] },
        "scriptAssetId": script,
    })
}

/// Блок события «При изменении данных» с подпиской на `paths`.
fn watch_block(paths: Value, children: Vec<Value>) -> Value {
    json!({
        "type": "event", "eventType": "onDataChange",
        "title": "При изменении данных",
        "watchPaths": paths,
        "children": children,
    })
}

/// Скрипт из одного блока подписки.
fn watch_script(paths: Value, children: Vec<Value>) -> String {
    json!({ "blocks": [watch_block(paths, children)] }).to_string()
}

/// `крюк = <значение>` — маркер срабатывания.
fn assign(variable: &str, value: Value) -> Value {
    json!({ "type": "assign_variable", "variable": variable, "value": value })
}

/// `крюк += 1` — счётчик срабатываний.
fn bump(variable: &str, value: Value) -> Value {
    json!({
        "type": "assign_variable", "variable": variable,
        "value": value, "операция": "прибавить",
    })
}

fn num(state: &InMemoryScriptRuntimeState, name: &str) -> Option<f64> {
    state.get_variable(name).and_then(Value::as_f64)
}

fn text(id: &str, title: &str) -> Value {
    json!({ "id": id, "title": title, "content": { "items": [
        {"id": format!("{id}-a"), "type": "text", "text": "…"}
    ] } })
}

/// Подписка вида «как её написал бы автор» — для проверок матчинга без скрипта.
fn watch_for(paths: &[&str]) -> DataWatch {
    DataWatch {
        script_path: "scripts/watch.json".to_string(),
        is_lua: false,
        block: None,
        paths: paths
            .iter()
            .flat_map(|p| crate::runtime::watch_path_forms(p))
            .collect(),
    }
}

fn rendered(tokens: &[Vec<String>]) -> Vec<String> {
    tokens.iter().map(|t| t.join(".")).collect()
}

/// Таблица-сетка: ряды из пар (столбец, значение).
fn grid(name: &str, columns: &[&str], rows: &[&[(&str, i64)]]) -> QuestTable {
    QuestTable::new(
        name.to_string(),
        columns.iter().map(|c| c.to_string()).collect(),
        rows.iter()
            .map(|row| {
                row.iter()
                    .map(|(column, value)| (column.to_string(), json!(*value)))
                    .collect::<Map<String, Value>>()
            })
            .collect(),
        Map::new(),
    )
}

/// Таблица key-value — то, что мутирует блок «Данные».
fn kv(name: &str, entries: &[(&str, i64)]) -> QuestTable {
    QuestTable::new(
        name.to_string(),
        Vec::new(),
        Vec::new(),
        entries
            .iter()
            .map(|(key, value)| (key.to_string(), json!(*value)))
            .collect(),
    )
}

/// Граница шага без собственного токена изменения: служебная переменная.
fn pump(engine: &mut GameEngine) {
    engine.set_state_variable("_шаг_диспетчера", json!(1));
}

// ─── Переменные ─────────────────────────────────────────────────────────

#[test]
fn watch_fires_when_watched_variable_changes() {
    let nodes = nodes_json(vec![plain_node("n1", "Start")]);
    let dispatch = watch_script(json!(["Золото"]), vec![assign("крюк", json!(1))]);

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/dispatch.json", &dispatch),
    ]);

    engine.start_new(None).expect("старт");
    // Негативный контроль: сам по себе вход в ноду подписку не запускает.
    assert_eq!(num(&engine.state, "крюк"), None);

    engine.set_state_variable("Золото", json!(10));
    assert_eq!(num(&engine.state, "крюк"), Some(1.0));

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn unwatched_variable_does_not_fire() {
    let nodes = nodes_json(vec![plain_node("n1", "Start")]);
    let dispatch = watch_script(json!(["Золото"]), vec![assign("крюк", json!(1))]);

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/dispatch.json", &dispatch),
    ]);

    engine.start_new(None).expect("старт");
    engine.set_state_variable("Серебро", json!(10));
    assert_eq!(num(&engine.state, "крюк"), None);

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn one_block_can_watch_several_variables() {
    let nodes = nodes_json(vec![plain_node("n1", "Start")]);
    let dispatch = watch_script(json!(["Золото", "Репутация"]), vec![bump("крюк", json!(1))]);

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/dispatch.json", &dispatch),
    ]);

    engine.start_new(None).expect("старт");
    engine.set_state_variable("Золото", json!(5));
    assert_eq!(num(&engine.state, "крюк"), Some(1.0));
    engine.set_state_variable("Репутация", json!(7));
    assert_eq!(num(&engine.state, "крюк"), Some(2.0));
    // Негативный контроль: третья переменная этого блока не касается.
    engine.set_state_variable("Сила", json!(9));
    assert_eq!(num(&engine.state, "крюк"), Some(2.0));

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn watch_paths_accept_comma_separated_string() {
    // Черновик подписки мог приехать одной строкой вместо массива.
    let nodes = nodes_json(vec![plain_node("n1", "Start")]);
    let dispatch = watch_script(json!("Золото, Репутация"), vec![bump("крюк", json!(1))]);

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/dispatch.json", &dispatch),
    ]);

    engine.start_new(None).expect("старт");
    engine.set_state_variable("Золото", json!(5));
    engine.set_state_variable("Репутация", json!(7));
    assert_eq!(num(&engine.state, "крюк"), Some(2.0));
    engine.set_state_variable("Сила", json!(9));
    assert_eq!(num(&engine.state, "крюк"), Some(2.0));

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn same_value_rewrite_does_not_fire() {
    let nodes = nodes_json(vec![plain_node("n1", "Start")]);
    let dispatch = watch_script(json!(["Золото"]), vec![assign("крюк", json!(1))]);

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/dispatch.json", &dispatch),
    ]);

    engine.start_new(None).expect("старт");
    engine.set_state_variable("Золото", json!(10));
    assert_eq!(num(&engine.state, "крюк"), Some(1.0));

    // «Сбросили маркер» — и повторная запись того же значения.
    engine.state.set_variable("крюк", json!(0));
    engine.set_state_variable("Золото", json!(10));
    assert_eq!(num(&engine.state, "крюк"), Some(0.0));

    // Негативный контроль внутри теста: другое значение — другое событие.
    engine.set_state_variable("Золото", json!(11));
    assert_eq!(num(&engine.state, "крюк"), Some(1.0));

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn quest_start_writes_do_not_fire() {
    // Диспетчер ловит изменения игрока, а инициализация квеста — нет.
    let nodes = nodes_json(vec![plain_node("n1", "Start")]);
    let boot = json!({
        "blocks": [
            {"type": "event", "eventType": "onQuestStart", "children": [
                assign("Золото", json!(5))
            ]}
        ]
    })
    .to_string();
    let dispatch = watch_script(json!(["Золото"]), vec![bump("крюк", json!(1))]);

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/boot.json", &boot),
        ("quests/q1/scripts/dispatch.json", &dispatch),
    ]);

    engine.start_new(None).expect("старт");
    assert_eq!(num(&engine.state, "Золото"), Some(5.0));
    assert_eq!(num(&engine.state, "крюк"), None);

    // Негативный контроль: то же значение руками игрока — событие есть.
    engine.set_state_variable("Золото", json!(6));
    assert_eq!(num(&engine.state, "крюк"), Some(1.0));

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn service_and_engine_owned_variables_do_not_fire() {
    // Грубая подписка не должна превращаться в дубль onNodeEnter: движок пишет
    // `ID`/`LastID` и `_internal_*` на каждом входе в ноду.
    let nodes = nodes_json(vec![
        plain_node("n1", "Start"),
        plain_node("n2", "Вторая нода"),
    ]);
    // Маркер пишем литералом: грубая подписка ловит и собственную запись, а
    // повтор того же значения токена не даёт — каскад гаснет сам.
    let dispatch = watch_script(json!(["*"]), vec![assign("крюк", json!(1))]);

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/dispatch.json", &dispatch),
    ]);

    engine.start_new(None).expect("старт");
    engine.load_node("n2").expect("нода n2");
    assert_eq!(num(&engine.state, "крюк"), None);

    engine.set_state_variable("ID", json!("n3"));
    engine.set_state_variable("_internal_play_sound_id", json!("sfx"));
    assert_eq!(num(&engine.state, "крюк"), None);

    // Негативный контроль: авторская переменная по-прежнему ловится.
    engine.set_state_variable("Золото", json!(1));
    assert_eq!(num(&engine.state, "крюк"), Some(1.0));

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn coarse_watch_fires_on_any_change() {
    let nodes = nodes_json(vec![plain_node("n1", "Start")]);
    let dispatch = watch_script(json!(["*"]), vec![assign("крюк", json!(1))]);

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/dispatch.json", &dispatch),
    ]);

    engine.start_new(None).expect("старт");
    assert_eq!(num(&engine.state, "крюк"), None);
    engine.set_state_variable("что_угодно", json!(1));
    assert_eq!(num(&engine.state, "крюк"), Some(1.0));

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn title_without_event_type_is_enough() {
    // Старые скрипты хранят событие только в `title`.
    let nodes = nodes_json(vec![plain_node("n1", "Start")]);
    let dispatch = json!({
        "blocks": [
            {"type": "event", "title": "При изменении данных", "watchPaths": ["Золото"],
             "children": [assign("крюк", json!(1))]}
        ]
    })
    .to_string();

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/dispatch.json", &dispatch),
    ]);

    engine.start_new(None).expect("старт");
    engine.set_state_variable("Золото", json!(10));
    assert_eq!(num(&engine.state, "крюк"), Some(1.0));

    let _ = std::fs::remove_dir_all(&root);
}

// ─── Что видит обработчик ───────────────────────────────────────────────

#[test]
fn handler_reads_changed_paths() {
    let nodes = nodes_json(vec![plain_node("n1", "Start")]);
    let dispatch = watch_script(
        json!(["Золото"]),
        vec![
            assign("первый_путь", json!("_changed_path")),
            assign("все_пути", json!("_changed_paths")),
        ],
    );

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/dispatch.json", &dispatch),
    ]);

    engine.start_new(None).expect("старт");
    engine.set_state_variable("Золото", json!(10));
    assert_eq!(
        engine.state.get_variable("первый_путь").cloned(),
        Some(json!("Золото"))
    );
    let all = engine.state.get_variable("все_пути").cloned().unwrap();
    assert_eq!(all, json!(["Золото"]));

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn several_changes_arrive_in_one_batch() {
    let nodes = nodes_json(vec![plain_node("n1", "Start")]);
    let dispatch = watch_script(
        json!(["Золото", "Репутация"]),
        vec![
            assign("первый_путь", json!("_changed_path")),
            assign("все_пути", json!("_changed_paths")),
        ],
    );

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/dispatch.json", &dispatch),
    ]);

    engine.start_new(None).expect("старт");
    engine.state.set_variable("Золото", json!(1));
    engine.state.set_variable("Репутация", json!(2));
    pump(&mut engine);

    let all = engine.state.get_variable("все_пути").cloned().unwrap();
    assert_eq!(all.as_array().map(|a| a.len()), Some(2));
    // Негативный контроль: блок вызван один раз на пачку, а не дважды.
    assert_eq!(
        engine.state.get_variable("первый_путь").cloned(),
        Some(json!("Золото"))
    );

    let _ = std::fs::remove_dir_all(&root);
}

// ─── Таблицы ────────────────────────────────────────────────────────────

#[test]
fn table_data_key_watch_fires() {
    let nodes = nodes_json(vec![plain_node("n1", "Start")]);
    let dispatch = watch_script(json!(["лавка.цена"]), vec![assign("крюк", json!(1))]);

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/dispatch.json", &dispatch),
    ]);

    engine.start_new(None).expect("старт");
    engine.state.set_table("лавка", kv("лавка", &[("цена", 1)]));
    engine.state.reset_changed_paths();
    engine.state.set_table("лавка", kv("лавка", &[("цена", 5)]));
    pump(&mut engine);

    assert_eq!(num(&engine.state, "крюк"), Some(1.0));
    assert_eq!(
        engine.state.get_variable("_changed_path").cloned(),
        Some(json!("table.лавка.цена"))
    );

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn other_data_key_does_not_fire() {
    let nodes = nodes_json(vec![plain_node("n1", "Start")]);
    let dispatch = watch_script(json!(["лавка.цена"]), vec![assign("крюк", json!(1))]);

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/dispatch.json", &dispatch),
    ]);

    engine.start_new(None).expect("старт");
    engine
        .state
        .set_table("лавка", kv("лавка", &[("цена", 1), ("хлеб", 1)]));
    engine.state.reset_changed_paths();
    engine
        .state
        .set_table("лавка", kv("лавка", &[("цена", 1), ("хлеб", 9)]));
    pump(&mut engine);

    assert_eq!(num(&engine.state, "крюк"), None);

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn table_tokens_are_granular_and_cells_are_one_based() {
    // Движок отдаёт таблицу целиком, поэтому «что изменилось» восстанавливает
    // дифф: он доходит до ячейки и не оставляет промежуточных ступеней,
    // иначе подписка на одну ячейку ловила бы весь столбец.
    let mut state = InMemoryScriptRuntimeState::default();
    state.set_table(
        "лавка",
        grid("лавка", &["цена", "вес"], &[&[("цена", 1), ("вес", 10)]]),
    );
    state.reset_changed_paths();
    state.set_table(
        "лавка",
        grid("лавка", &["цена", "вес"], &[&[("цена", 7), ("вес", 10)]]),
    );

    let tokens = state.drain_changed_paths();
    let paths = rendered(&tokens);
    assert_eq!(paths, vec!["table.лавка.цена.1".to_string()]);

    let price = watch_for(&["лавка.цена"]);
    let cell = watch_for(&["лавка.цена.1"]);
    let table = watch_for(&["лавка"]);
    assert!(data_watch_fires(&cell, &tokens));
    assert!(data_watch_fires(&price, &tokens));
    assert!(data_watch_fires(&table, &tokens));
    assert!(!data_watch_fires(&watch_for(&["лавка.цена.2"]), &tokens));
    assert!(!data_watch_fires(&watch_for(&["лавка.вес"]), &tokens));

    // Смена состава столбцов — это вся сетка, грубый токен `*`.
    state.set_table("лавка", grid("лавка", &["цена"], &[&[("цена", 7)]]));
    let paths = rendered(&state.drain_changed_paths());
    assert!(
        paths.contains(&"table.лавка.*".to_string()),
        "изменение столбцов должно дать токен сетки: {paths:?}"
    );
}

#[test]
fn huge_grid_falls_back_to_the_whole_table() {
    // Больше MAX_TABLE_DIFF_CELLS ячеек — дифф рядов не идёт, подписка любого
    // уровня внутри таблицы обязана сработать на страховочном грубом токене.
    // Столбцы разные, чтобы ряд отличался значением, а не последним ключом.
    let columns: Vec<String> = (0..20).map(|c| format!("к{c}")).collect();
    let shelf = |values: &Vec<Vec<i64>>| {
        QuestTable::new(
            "полка".to_string(),
            columns.clone(),
            values
                .iter()
                .map(|row| {
                    row.iter()
                        .enumerate()
                        .map(|(c, value)| (columns[c].clone(), json!(*value)))
                        .collect::<Map<String, Value>>()
                })
                .collect(),
            Map::new(),
        )
    };
    let rows: Vec<Vec<i64>> = (0..25)
        .map(|r| (0..20).map(|c| (r * 20 + c) as i64).collect())
        .collect();

    let mut state = InMemoryScriptRuntimeState::default();
    state.set_table("полка", shelf(&rows));
    let mut changed = rows.clone();
    changed[3][7] = 999;
    state.reset_changed_paths();
    state.set_table("полка", shelf(&changed));

    let tokens = state.drain_changed_paths();
    let paths = rendered(&tokens);
    assert_eq!(paths, vec!["table.полка".to_string()]);
    assert!(data_watch_fires(&watch_for(&["полка.к7.4"]), &tokens));
    assert!(data_watch_fires(&watch_for(&["полка"]), &tokens));
    // Негативный контроль: чужая таблица не ловится.
    assert!(!data_watch_fires(&watch_for(&["иной.ц"]), &tokens));
}

#[test]
fn wildcard_watch_catches_any_key_of_the_table() {
    // `лавка.*` — подписка на весь набор ключей таблицы.
    let tokens = vec![vec![
        "table".to_string(),
        "лавка".to_string(),
        "цена".to_string(),
    ]];
    assert!(data_watch_fires(&watch_for(&["лавка.*"]), &tokens));
    // Негативный контроль: `*` подставляет только собственный хвост.
    assert!(!data_watch_fires(
        &watch_for(&["лавка.*"]),
        &[vec![
            "table".to_string(),
            "полка".to_string(),
            "цена".to_string(),
        ]]
    ));
}

#[test]
fn key_watch_catches_the_coarse_grid_token() {
    // Дифф не смог локализовать изменение → грубый токен `table.лавка.*`.
    // Подписка на конкретный ключ обязана его поймать, иначе фильтр терял бы
    // реальные изменения сетки.
    let coarse = vec!["table".to_string(), "лавка".to_string(), "*".to_string()];
    assert!(data_watch_fires(
        &watch_for(&["лавка.цена"]),
        std::slice::from_ref(&coarse)
    ));
    assert!(data_watch_fires(
        &watch_for(&["лавка"]),
        std::slice::from_ref(&coarse)
    ));
    assert!(!data_watch_fires(&watch_for(&["полка.цена"]), &[coarse]));
}

#[test]
fn coarse_watch_matches_table_change() {
    let nodes = nodes_json(vec![plain_node("n1", "Start")]);
    let dispatch = watch_script(json!(["*"]), vec![assign("крюк", json!(1))]);

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/dispatch.json", &dispatch),
    ]);

    engine.start_new(None).expect("старт");
    engine.state.set_table("лавка", kv("лавка", &[("цена", 1)]));
    engine.state.reset_changed_paths();
    engine.state.set_table("лавка", kv("лавка", &[("цена", 5)]));
    pump(&mut engine);

    assert_eq!(num(&engine.state, "крюк"), Some(1.0));

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn authored_wildcard_watch_fires_on_any_table_key() {
    // Автор пишет `лавка.*` — подписка на весь набор ключей таблицы.
    let nodes = nodes_json(vec![plain_node("n1", "Start")]);
    let dispatch = watch_script(json!(["лавка.*"]), vec![assign("крюк", json!(1))]);

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/dispatch.json", &dispatch),
    ]);

    engine.start_new(None).expect("старт");
    engine.state.set_table("лавка", kv("лавка", &[("цена", 1)]));
    engine.state.set_table("полка", kv("полка", &[("цена", 1)]));
    engine.state.reset_changed_paths();
    engine.state.set_table("полка", kv("полка", &[("цена", 9)]));
    pump(&mut engine);
    // Негативный контроль: чужая таблица под `*` не считается.
    assert_eq!(num(&engine.state, "крюк"), None);

    engine.state.set_table("лавка", kv("лавка", &[("цена", 5)]));
    pump(&mut engine);
    assert_eq!(num(&engine.state, "крюк"), Some(1.0));

    let _ = std::fs::remove_dir_all(&root);
}

// ─── Каскад и переходы ──────────────────────────────────────────────────

#[test]
fn self_feeding_watch_is_stopped_by_the_guard() {
    // Подписка пишет в свою же переменную: без потолка волн это вечный цикл.
    let nodes = nodes_json(vec![plain_node("n1", "Start")]);
    let dispatch = watch_script(json!(["Золото"]), vec![bump("Золото", json!(1))]);

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/dispatch.json", &dispatch),
    ]);

    engine.start_new(None).expect("старт");
    engine.set_state_variable("Золото", json!(1));
    // Одна волна = одно срабатывание; четыре волны — плюс MAX_DATA_WATCH_ROUNDS.
    assert_eq!(num(&engine.state, "Золото"), Some(1.0 + 4.0));

    // Негативный контроль: подписка, которая пишет в сторону, гаснет за волну.
    let calm = watch_script(json!(["Золото"]), vec![bump("крюк", json!(1))]);
    let (mut second, root2) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/dispatch.json", &calm),
    ]);
    second.start_new(None).expect("старт");
    second.set_state_variable("Золото", json!(10));
    assert_eq!(num(&second.state, "Золото"), Some(10.0));
    assert_eq!(num(&second.state, "крюк"), Some(1.0));

    let _ = std::fs::remove_dir_all(&root);
    let _ = std::fs::remove_dir_all(&root2);
}

#[test]
fn dispatcher_transition_waits_for_the_next_boundary() {
    // Прямая мутация из клиента не умеет возвращать переход — он не должен
    // теряться и обязан дожить до ближайшей границы шага.
    let nodes = nodes_json(vec![text("n1", "Start"), plain_node("n2", "Куда")]);
    let dispatch = watch_script(
        json!(["Золото"]),
        vec![json!({ "type": "go_to_node", "node_id": "n2" })],
    );

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/dispatch.json", &dispatch),
    ]);

    engine.start_new(None).expect("старт");
    engine.set_state_variable("Золото", json!(10));
    assert_eq!(engine.take_pending_transition(), Some("n2".to_string()));
    // Негативный контроль: переход забирается один раз.
    assert_eq!(engine.take_pending_transition(), None);

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn pending_transition_is_delivered_on_the_next_step() {
    let nodes = nodes_json(vec![text("n1", "Start"), plain_node("n2", "Куда")]);
    let dispatch = watch_script(
        json!(["Золото"]),
        vec![json!({ "type": "go_to_node", "node_id": "n2" })],
    );

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/dispatch.json", &dispatch),
    ]);

    engine.start_new(None).expect("старт");
    engine.set_state_variable("Золото", json!(10));
    // Игрок идёт дальше по ноде — и получает переход диспетчера.
    assert!(matches!(engine.next_item(), NextStep::Transition(target) if target == "n2"));
    // Негативный контроль: второй шаг уже пуст.
    assert!(!matches!(engine.next_item(), NextStep::Transition(_)));

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn data_change_can_override_transition_from_the_same_action() {
    let item_json = json!({
        "id": "damage", "type": "button",
        "scriptTriggers": { "onPress": "scripts/damage.json" }
    });
    let nodes = nodes_json(vec![
        json!({ "id": "n1", "title": "Start", "content": { "items": [item_json] } }),
        plain_node("n2", "После удара"),
        plain_node("n3", "Смерть"),
    ]);
    let config = json!({
        "id": "q1", "title": "Q", "version": "2.0.0", "startNodeId": "n1",
        "variables": [
            { "name": "HP", "defaultValue": 100 },
            { "name": "Лог", "defaultValue": "" }
        ]
    })
    .to_string();
    let damage = json!({
        "blocks": [{
            "type": "event", "eventType": "onPress",
            "children": [
                assign("HP", json!("{HP}-100")),
                json!({ "type": "go_to_node", "node_id": "n2" })
            ]
        }]
    })
    .to_string();
    let dispatch = watch_script(
        json!(["HP"]),
        vec![json!({
            "type": "condition", "expression": "{HP}<=0",
            "then_blocks": [
                assign("Лог", json!("Скрипт не работает")),
                json!({ "type": "go_to_node", "node_id": "n3" })
            ],
            "else_blocks": [assign("Лог", json!("Жив"))]
        })],
    );

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/damage.json", &damage),
        ("quests/q1/scripts/dispatch.json", &dispatch),
    ]);

    engine.start_new(None).expect("старт");
    assert_eq!(engine.press_item("damage"), Some("n3".to_string()));
    assert_eq!(num(&engine.state, "HP"), Some(0.0));
    assert_eq!(
        engine.state.get_variable("Лог"),
        Some(&json!("Скрипт не работает"))
    );

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn action_transition_survives_when_data_change_condition_is_false() {
    let item_json = json!({
        "id": "damage", "type": "button",
        "scriptTriggers": { "onPress": "scripts/damage.json" }
    });
    let nodes = nodes_json(vec![
        json!({ "id": "n1", "title": "Start", "content": { "items": [item_json] } }),
        plain_node("n2", "После удара"),
        plain_node("n3", "Смерть"),
    ]);
    let config = json!({
        "id": "q1", "title": "Q", "version": "2.0.0", "startNodeId": "n1",
        "variables": [
            { "name": "HP", "defaultValue": 100 },
            { "name": "Лог", "defaultValue": "" }
        ]
    })
    .to_string();
    let damage = json!({
        "blocks": [{
            "type": "event", "eventType": "onPress",
            "children": [
                assign("HP", json!("{HP}-10")),
                json!({ "type": "go_to_node", "node_id": "n2" })
            ]
        }]
    })
    .to_string();
    let dispatch = watch_script(
        json!(["HP"]),
        vec![json!({
            "type": "condition", "expression": "{HP}<=0",
            "then_blocks": [json!({ "type": "go_to_node", "node_id": "n3" })],
            "else_blocks": [assign("Лог", json!("Жив"))]
        })],
    );

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/damage.json", &damage),
        ("quests/q1/scripts/dispatch.json", &dispatch),
    ]);

    engine.start_new(None).expect("старт");
    assert_eq!(engine.press_item("damage"), Some("n2".to_string()));
    assert_eq!(num(&engine.state, "HP"), Some(90.0));
    assert_eq!(engine.state.get_variable("Лог"), Some(&json!("Жив")));

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn data_change_can_override_transition_from_node_enter() {
    let nodes = nodes_json(vec![
        script_node("n1", "Start", "nodes/enter.json"),
        plain_node("n2", "После входа"),
        plain_node("n3", "Смерть"),
    ]);
    let config = json!({
        "id": "q1", "title": "Q", "version": "2.0.0", "startNodeId": "n1",
        "variables": [
            { "name": "HP", "defaultValue": 100 },
            { "name": "Лог", "defaultValue": "" }
        ]
    })
    .to_string();
    let enter = json!({
        "blocks": [{
            "type": "event", "eventType": "onNodeEnter",
            "children": [
                assign("HP", json!(0)),
                json!({ "type": "go_to_node", "node_id": "n2" })
            ]
        }]
    })
    .to_string();
    let dispatch = watch_script(
        json!(["HP"]),
        vec![json!({
            "type": "condition", "expression": "{HP}<=0",
            "then_blocks": [
                assign("Лог", json!("Смерть")),
                json!({ "type": "go_to_node", "node_id": "n3" })
            ]
        })],
    );

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/nodes/enter.json", &enter),
        ("quests/q1/scripts/dispatch.json", &dispatch),
    ]);

    let view = engine.start_new(None).expect("старт");
    assert_eq!(view.transition, Some("n3".to_string()));
    assert_eq!(num(&engine.state, "HP"), Some(0.0));
    assert_eq!(engine.state.get_variable("Лог"), Some(&json!("Смерть")));

    let _ = std::fs::remove_dir_all(&root);
}

// ─── Область действия подписок ──────────────────────────────────────────

#[test]
fn node_watch_only_works_while_its_node_is_active() {
    // Скрипт вне `scripts/` видим только той ноде, что на него ссылается.
    let nodes = nodes_json(vec![
        script_node("n1", "Start", "nodes/watch.json"),
        plain_node("n2", "Куда"),
    ]);
    let watcher = watch_script(json!(["Золото"]), vec![bump("крюк", json!(1))]);

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/nodes/watch.json", &watcher),
    ]);

    engine.start_new(None).expect("старт");
    engine.set_state_variable("Золото", json!(1));
    assert_eq!(num(&engine.state, "крюк"), Some(1.0));

    // Негативный контроль: ушла нода — ушла и её подписка.
    engine.load_node("n2").expect("нода n2");
    engine.set_state_variable("Золото", json!(2));
    assert_eq!(num(&engine.state, "крюк"), Some(1.0));

    // Вернулись — подписка снова собрана.
    engine.load_node("n1").expect("нода n1");
    engine.set_state_variable("Золото", json!(3));
    assert_eq!(num(&engine.state, "крюк"), Some(2.0));

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn script_without_data_event_is_not_a_watch() {
    // Раскопка собирает только блоки `onDataChange`: скрипт ноды без такого
    // блока остаётся обычным onNodeEnter и на изменения не зовётся.
    let nodes = nodes_json(vec![script_node("n1", "Start", "nodes/other.json")]);
    let other = json!({
        "blocks": [
            {"type": "event", "eventType": "onNodeEnter", "children": [
                assign("крюк", json!(1))
            ]}
        ]
    })
    .to_string();

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/nodes/other.json", &other),
    ]);

    // Нодовый скрипт живой: onNodeEnter отработал при загрузке.
    engine.start_new(None).expect("старт");
    assert_eq!(num(&engine.state, "крюк"), Some(1.0));

    engine.state.set_variable("крюк", json!(0));
    engine.set_state_variable("Золото", json!(10));
    pump(&mut engine);
    assert_eq!(num(&engine.state, "крюк"), Some(0.0));

    let _ = std::fs::remove_dir_all(&root);
}

// ─── Lua ────────────────────────────────────────────────────────────────

#[test]
fn lua_dispatcher_is_called_on_changes() {
    let nodes = nodes_json(vec![plain_node("n1", "Start")]);
    let dispatch = "function onDataChange(paths)\n  core.set_var('крюк', 1)\nend\n";

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/dispatch.lua", dispatch),
    ]);

    engine.start_new(None).expect("старт");
    assert_eq!(num(&engine.state, "крюк"), None);
    engine.set_state_variable("Золото", json!(10));
    assert_eq!(num(&engine.state, "крюк"), Some(1.0));

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn lua_library_without_data_hook_stays_quiet() {
    let nodes = nodes_json(vec![plain_node("n1", "Start")]);
    let lib = "function onNodeEnter()\n  core.set_var('крюк', 1)\nend\n";

    let (mut engine, root) = engine_from_files(&[
        ("quests/q1/config.json", &config()),
        ("quests/q1/nodes.json", &nodes),
        ("quests/q1/scripts/lib.lua", lib),
    ]);

    engine.start_new(None).expect("старт");
    engine.set_state_variable("Золото", json!(10));
    assert_eq!(num(&engine.state, "крюк"), None);

    let _ = std::fs::remove_dir_all(&root);
}
