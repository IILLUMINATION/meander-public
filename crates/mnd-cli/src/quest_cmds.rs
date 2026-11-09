#![allow(clippy::too_many_lines)]

//! Подкоманды редактирования квеста (`mnd-cli quest …`).
//!
//! Все операции делегируются [`mnd_core::quest_build::QuestBuilder`],
//! чтобы не было прямой правки JSON в CLI.

use std::io::Read;
use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use clap::{Args, Subcommand};
use serde_json::{Value, json};

use mnd_core::quest_build::{
    ItemKind, ItemPatch, ItemSpec, NodeEdit, NodeSpec, QuestBuilder, ResourceKind, ScriptEvent,
};
use mnd_core::validation::analyze_quest;

/// Верхнеуровневые подкоманды `quest`.
#[derive(Subcommand)]
pub enum QuestCmd {
    /// Создать новый квест.
    New(QuestNew),
    /// Провалидировать квест.
    Validate(QuestValidate),
    /// Вывести сводную информацию о квесте.
    Info(QuestInfo),
    /// Управление главами.
    #[command(subcommand)]
    Chapter(ChapterCmd),
    /// Управление нодами и их контентом.
    #[command(subcommand)]
    Node(NodeCmd),
    /// Управление скриптами.
    #[command(subcommand)]
    Script(ScriptCmd),
    /// Управление таблицами.
    #[command(subcommand)]
    Table(TableCmd),
    /// Управление переменными.
    #[command(subcommand)]
    Var(VarCmd),
    /// Управление ресурсами.
    #[command(subcommand)]
    Resource(ResourceCmd),
}

#[derive(Args)]
pub struct QuestNew {
    /// Название квеста.
    #[arg(long)]
    title: String,
    /// ID квеста (если не задан — генерируется uuid v4).
    #[arg(long)]
    quest_id: Option<String>,
    /// Автор.
    #[arg(long)]
    author: Option<String>,
    /// Имя первой главы.
    #[arg(long)]
    chapter: Option<String>,
    /// Вывести результат как JSON.
    #[arg(long)]
    json: bool,
}

#[derive(Args)]
pub struct QuestValidate {
    /// ID квеста. Если не задан — берётся из глобального `--quest-id`.
    #[arg(long)]
    quest_id: Option<String>,
    /// Вывести результат как JSON.
    #[arg(long)]
    json: bool,
}

#[derive(Args)]
pub struct QuestInfo {
    /// ID квеста. Если не задан — берётся из глобального `--quest-id`.
    #[arg(long)]
    quest_id: Option<String>,
    /// Вывести результат как JSON.
    #[arg(long)]
    json: bool,
}

#[derive(Subcommand)]
pub enum ChapterCmd {
    /// Добавить главу.
    Add(ChapterAdd),
}

#[derive(Args)]
pub struct ChapterAdd {
    /// Название главы.
    #[arg(long)]
    name: String,
    /// ID главы. Если не задан — генерируется.uuid v4.
    #[arg(long)]
    id: Option<String>,
    /// ID квеста. Если не задан — берётся из глобального `--quest-id`.
    #[arg(long)]
    quest_id: Option<String>,
    /// Вывести результат как JSON.
    #[arg(long)]
    json: bool,
}

#[derive(Subcommand)]
pub enum NodeCmd {
    /// Добавить ноду.
    Add(NodeAdd),
    /// Изменить существующую ноду (название, глава, координаты, старт).
    Set(NodeSet),
    /// Добавить текстовый айтем.
    Text(NodeText),
    /// Добавить картинку.
    Image(NodeImage),
    /// Добавить кнопку.
    Button(NodeButton),
    /// Добавить ряд (row) и переместить в него существующие айтемы.
    Row(NodeRow),
    /// Изменить существующий айтем.
    ItemSet(NodeItemSet),
    /// Удалить айтем.
    ItemRemove(NodeItemRemove),
}

#[derive(Args)]
pub struct NodeAdd {
    /// Название ноды.
    #[arg(long)]
    title: String,
    /// ID главы. Если не задан — используется первая глава.
    #[arg(long)]
    chapter: Option<String>,
    /// Сделать эту ноду стартовой.
    #[arg(long)]
    start: bool,
    /// Координата X на канвасе.
    #[arg(long)]
    x: Option<f64>,
    /// Координата Y на канвасе.
    #[arg(long)]
    y: Option<f64>,
    /// ID квеста. Если не задан — берётся из глобального `--quest-id`.
    #[arg(long)]
    quest_id: Option<String>,
    /// Вывести результат как JSON.
    #[arg(long)]
    json: bool,
}

#[derive(Args)]
pub struct NodeSet {
    /// ID ноды.
    #[arg(long)]
    node: String,
    /// Новое название ноды.
    #[arg(long)]
    title: Option<String>,
    /// Новый ID главы.
    #[arg(long)]
    chapter: Option<String>,
    /// Сделать ноду стартовой.
    #[arg(long)]
    start: bool,
    /// Новая координата X на канвасе.
    #[arg(long)]
    x: Option<f64>,
    /// Новая координата Y на канвасе.
    #[arg(long)]
    y: Option<f64>,
    /// ID квеста. Если не задан — берётся из глобального `--quest-id`.
    #[arg(long)]
    quest_id: Option<String>,
    /// Вывести результат как JSON.
    #[arg(long)]
    json: bool,
}

#[derive(Args)]
pub struct NodeItemSet {
    /// ID ноды.
    #[arg(long)]
    node: String,
    /// ID айтема.
    #[arg(long)]
    item: String,
    /// Новый текст.
    #[arg(long)]
    text: Option<String>,
    /// Новый путь/ссылка на ресурс (для айтема-картинки).
    #[arg(long)]
    source: Option<String>,
    /// ID скрипта, который запускает айтем (для кнопки).
    #[arg(long)]
    script: Option<String>,
    /// ID квеста. Если не задан — берётся из глобального `--quest-id`.
    #[arg(long)]
    quest_id: Option<String>,
    /// Вывести результат как JSON.
    #[arg(long)]
    json: bool,
}

#[derive(Args)]
pub struct NodeItemRemove {
    /// ID ноды.
    #[arg(long)]
    node: String,
    /// ID айтема.
    #[arg(long)]
    item: String,
    /// ID квеста. Если не задан — берётся из глобального `--quest-id`.
    #[arg(long)]
    quest_id: Option<String>,
    /// Вывести результат как JSON.
    #[arg(long)]
    json: bool,
}

#[derive(Args)]
pub struct NodeText {
    /// ID ноды.
    #[arg(long)]
    node: String,
    /// Текст айтема.
    #[arg(long)]
    text: String,
    /// ID квеста. Если не задан — берётся из глобального `--quest-id`.
    #[arg(long)]
    quest_id: Option<String>,
    /// Вывести результат как JSON.
    #[arg(long)]
    json: bool,
}

#[derive(Args)]
pub struct NodeImage {
    /// ID ноды.
    #[arg(long)]
    node: String,
    /// Путь или uuid ресурса.
    #[arg(long)]
    source: String,
    /// ID квеста. Если не задан — берётся из глобального `--quest-id`.
    #[arg(long)]
    quest_id: Option<String>,
    /// Вывести результат как JSON.
    #[arg(long)]
    json: bool,
}

#[derive(Args)]
pub struct NodeButton {
    /// ID ноды.
    #[arg(long)]
    node: String,
    /// Текст кнопки.
    #[arg(long)]
    text: String,
    /// ID скрипта.
    #[arg(long)]
    script: String,
    /// ID квеста. Если не задан — берётся из глобального `--quest-id`.
    #[arg(long)]
    quest_id: Option<String>,
    /// Вывести результат как JSON.
    #[arg(long)]
    json: bool,
}

#[derive(Args)]
pub struct NodeRow {
    /// ID ноды.
    #[arg(long)]
    node: String,
    /// ID дочерних айтемов через запятую.
    #[arg(long, value_delimiter = ',')]
    children: Vec<String>,
    /// ID квеста. Если не задан — берётся из глобального `--quest-id`.
    #[arg(long)]
    quest_id: Option<String>,
    /// Вывести результат как JSON.
    #[arg(long)]
    json: bool,
}

#[derive(Subcommand)]
pub enum ScriptCmd {
    /// Создать новый скрипт.
    New(ScriptNew),
    /// Добавить блок set_image.
    SetImage(ScriptSetImage),
    /// Добавить блок assign_variable.
    Assign(ScriptAssign),
    /// Добавить блок wait.
    Wait(ScriptWait),
    /// Добавить блок go_to_node.
    Goto(ScriptGoto),
    /// Добавить произвольный блок из JSON.
    AddBlock(ScriptAddBlock),
}

#[derive(Args)]
pub struct ScriptCommon {
    /// ID скрипта.
    #[arg(long)]
    script: String,
    /// ID квеста. Если не задан — берётся из глобального `--quest-id`.
    #[arg(long)]
    quest_id: Option<String>,
}

#[derive(Args)]
pub struct ScriptNew {
    /// Имя скрипта.
    #[arg(long)]
    name: String,
    /// Событие скрипта.
    #[arg(long, value_parser = parse_script_event, default_value = "onPress")]
    event: ScriptEvent,
    /// ID квеста. Если не задан — берётся из глобального `--quest-id`.
    #[arg(long)]
    quest_id: Option<String>,
    /// Вывести результат как JSON.
    #[arg(long)]
    json: bool,
}

#[derive(Args)]
pub struct ScriptSetImage {
    #[command(flatten)]
    common: ScriptCommon,
    /// ID айтема.
    #[arg(long)]
    item: String,
    /// Источник картинки.
    #[arg(long)]
    source: String,
}

#[derive(Args)]
pub struct ScriptAssign {
    #[command(flatten)]
    common: ScriptCommon,
    /// Имя переменной.
    #[arg(long)]
    var: String,
    /// Значение как JSON (число, строка в кавычках и т.п.).
    #[arg(long)]
    value: String,
}

#[derive(Args)]
pub struct ScriptWait {
    #[command(flatten)]
    common: ScriptCommon,
    /// Задержка в миллисекундах.
    #[arg(long)]
    ms: u64,
}

#[derive(Args)]
pub struct ScriptGoto {
    #[command(flatten)]
    common: ScriptCommon,
    /// ID целевой ноды.
    #[arg(long)]
    node: String,
}

#[derive(Args)]
pub struct ScriptAddBlock {
    /// ID скрипта.
    #[arg(long)]
    script: String,
    /// JSON блока.
    #[arg(long)]
    json: String,
    /// ID квеста. Если не задан — берётся из глобального `--quest-id`.
    #[arg(long)]
    quest_id: Option<String>,
}

#[derive(Subcommand)]
pub enum TableCmd {
    /// Установить таблицу.
    Set(TableSet),
}

#[derive(Args)]
pub struct TableSet {
    /// Имя таблицы.
    #[arg(long)]
    name: String,
    /// Колонки через запятую.
    #[arg(long, value_delimiter = ',')]
    columns: Vec<String>,
    /// Имена строк через запятую. Если не заданы — генерируются индексы.
    #[arg(long, value_delimiter = ',')]
    row_names: Option<Vec<String>>,
    /// Путь к файлу с JSON-массивом строк, или `-` для stdin.
    #[arg(long)]
    rows_json: String,
    /// ID квеста. Если не задан — берётся из глобального `--quest-id`.
    #[arg(long)]
    quest_id: Option<String>,
}

#[derive(Subcommand)]
pub enum VarCmd {
    /// Установить переменную.
    Set(VarSet),
}

#[derive(Args)]
pub struct VarSet {
    /// Имя переменной.
    #[arg(long)]
    name: String,
    /// Значение как JSON.
    #[arg(long)]
    value: String,
    /// ID квеста. Если не задан — берётся из глобального `--quest-id`.
    #[arg(long)]
    quest_id: Option<String>,
}

#[derive(Subcommand)]
pub enum ResourceCmd {
    /// Добавить ресурс.
    Add(ResourceAdd),
}

#[derive(Args)]
pub struct ResourceAdd {
    /// Путь к файлу.
    #[arg(long)]
    file: PathBuf,
    /// Имя в библиотеке ресурсов.
    #[arg(long)]
    name: Option<String>,
    /// Тип ресурса.
    #[arg(long, value_parser = parse_resource_kind, default_value = "image")]
    kind: ResourceKind,
    /// ID квеста. Если не задан — берётся из глобального `--quest-id`.
    #[arg(long)]
    quest_id: Option<String>,
    /// Вывести результат как JSON.
    #[arg(long)]
    json: bool,
}

pub fn run_quest_cmd(cmd: QuestCmd, quest_root: &str, global_qid: Option<&str>) -> Result<()> {
    match cmd {
        QuestCmd::New(args) => cmd_new(args, quest_root, global_qid)?,
        QuestCmd::Validate(args) => cmd_validate(args, quest_root, global_qid)?,
        QuestCmd::Info(args) => cmd_info(args, quest_root, global_qid)?,
        QuestCmd::Chapter(ChapterCmd::Add(args)) => cmd_chapter_add(args, quest_root, global_qid)?,
        QuestCmd::Node(NodeCmd::Add(args)) => cmd_node_add(args, quest_root, global_qid)?,
        QuestCmd::Node(NodeCmd::Set(args)) => cmd_node_set(args, quest_root, global_qid)?,
        QuestCmd::Node(NodeCmd::Text(args)) => cmd_node_text(args, quest_root, global_qid)?,
        QuestCmd::Node(NodeCmd::Image(args)) => cmd_node_image(args, quest_root, global_qid)?,
        QuestCmd::Node(NodeCmd::Button(args)) => cmd_node_button(args, quest_root, global_qid)?,
        QuestCmd::Node(NodeCmd::Row(args)) => cmd_node_row(args, quest_root, global_qid)?,
        QuestCmd::Node(NodeCmd::ItemSet(args)) => cmd_node_item_set(args, quest_root, global_qid)?,
        QuestCmd::Node(NodeCmd::ItemRemove(args)) => {
            cmd_node_item_remove(args, quest_root, global_qid)?
        }
        QuestCmd::Script(ScriptCmd::New(args)) => cmd_script_new(args, quest_root, global_qid)?,
        QuestCmd::Script(ScriptCmd::SetImage(args)) => {
            cmd_script_set_image(args, quest_root, global_qid)?;
        }
        QuestCmd::Script(ScriptCmd::Assign(args)) => {
            cmd_script_assign(args, quest_root, global_qid)?;
        }
        QuestCmd::Script(ScriptCmd::Wait(args)) => {
            cmd_script_wait(args, quest_root, global_qid)?;
        }
        QuestCmd::Script(ScriptCmd::Goto(args)) => {
            cmd_script_goto(args, quest_root, global_qid)?;
        }
        QuestCmd::Script(ScriptCmd::AddBlock(args)) => {
            cmd_script_add_block(args, quest_root, global_qid)?;
        }
        QuestCmd::Table(TableCmd::Set(args)) => cmd_table_set(args, quest_root, global_qid)?,
        QuestCmd::Var(VarCmd::Set(args)) => cmd_var_set(args, quest_root, global_qid)?,
        QuestCmd::Resource(ResourceCmd::Add(args)) => {
            cmd_resource_add(args, quest_root, global_qid)?
        }
    }
    Ok(())
}

fn resolve_quest_id(local: Option<&str>, global: Option<&str>) -> Result<String> {
    local
        .map(|s| s.to_string())
        .or_else(|| global.map(String::from))
        .with_context(|| "не задан --quest-id (глобально или для подкоманды)")
}

fn open_builder(quest_root: &str, quest_id: &str) -> Result<QuestBuilder> {
    QuestBuilder::open(std::path::Path::new(quest_root), quest_id)
        .with_context(|| format!("не удалось открыть квест {quest_id} в {quest_root}/quests/"))
}

fn cmd_new(args: QuestNew, quest_root: &str, global_qid: Option<&str>) -> Result<()> {
    // Глобальный `--quest-id` тоже принимаем: иначе один и тот же флаг в
    // одной позиции означает «создать с этим id», а в другой — молча
    // игнорируется, и квест создаётся с чужим uuid.
    let quest_id = args
        .quest_id
        .or_else(|| global_qid.map(str::to_string))
        .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    let qb = QuestBuilder::create(
        &quest_id,
        std::path::Path::new(quest_root),
        &args.title,
        args.author.as_deref(),
        args.chapter.as_deref(),
    )
    .with_context(|| "не удалось создать квест")?;
    let info = qb.info();
    if args.json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "questId": info["questId"],
                "startNodeId": info["startNodeId"]
            }))
            .unwrap()
        );
    } else {
        println!("Квест создан: {}", quest_id);
        println!(
            "Стартовая нода: {}",
            info["startNodeId"].as_str().unwrap_or("")
        );
    }
    Ok(())
}

fn cmd_validate(args: QuestValidate, quest_root: &str, global_qid: Option<&str>) -> Result<()> {
    let quest_id = resolve_quest_id(args.quest_id.as_deref(), global_qid)?;
    let report = analyze_quest(&quest_id, quest_root);

    if args.json {
        println!("{}", serde_json::to_string_pretty(&report).unwrap());
    } else {
        println!("Статистика: {:?}", report.stats);
        for d in &report.diagnostics {
            println!("[{:?}/{:?}] {}", d.severity, d.kind, d.message);
        }
    }

    if report.has_errors() {
        bail!("валидатор нашёл ошибки");
    }
    Ok(())
}

fn cmd_info(args: QuestInfo, quest_root: &str, global_qid: Option<&str>) -> Result<()> {
    let quest_id = resolve_quest_id(args.quest_id.as_deref(), global_qid)?;
    let qb = open_builder(quest_root, &quest_id)?;
    let info = qb.info();
    if args.json {
        println!("{}", serde_json::to_string_pretty(&info).unwrap());
    } else {
        println!("Квест: {}", info["title"].as_str().unwrap_or(""));
        println!("ID: {}", info["questId"].as_str().unwrap_or(""));
        println!(
            "Стартовая нода: {}",
            info["startNodeId"].as_str().unwrap_or("")
        );
        println!("\nГлавы:");
        for ch in info["chapters"].as_array().unwrap_or(&Vec::new()) {
            let id = ch["id"].as_str().unwrap_or("");
            let name = ch["name"].as_str().unwrap_or("");
            let count = ch["nodeCount"].as_u64().unwrap_or(0);
            println!("  [{}] {} ({} нод)", id, name, count);
        }
        println!("\nНоды:");
        for n in info["nodes"].as_array().unwrap_or(&Vec::new()) {
            let id = n["id"].as_str().unwrap_or("");
            let title = n["title"].as_str().unwrap_or("");
            let chapter = n["chapterId"].as_str().unwrap_or("");
            let items = n["items"].as_u64().unwrap_or(0);
            println!(
                "  [{}] {} (глава {}, айтемов: {})",
                id, title, chapter, items
            );
        }
        println!("\nСкрипты:");
        for s in info["scripts"].as_array().unwrap_or(&Vec::new()) {
            let id = s["id"].as_str().unwrap_or("");
            let name = s["name"].as_str().unwrap_or("");
            let blocks = s["blocks"].as_u64().unwrap_or(0);
            println!("  [{}] {} ({} блоков)", id, name, blocks);
        }
        if let Some(tables) = info["tables"].as_array() {
            println!("\nТаблицы: {}", tables.len());
        }
        if let Some(vars) = info["variables"].as_array() {
            println!("Переменные: {}", vars.len());
        }
    }
    Ok(())
}

fn cmd_chapter_add(args: ChapterAdd, quest_root: &str, global_qid: Option<&str>) -> Result<()> {
    let quest_id = resolve_quest_id(args.quest_id.as_deref(), global_qid)?;
    let qb = open_builder(quest_root, &quest_id)?;
    let id = qb
        .add_chapter(&args.name, args.id.as_deref())
        .with_context(|| "не удалось добавить главу")?;
    if args.json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({"id": id})).unwrap()
        );
    } else {
        println!("Добавлена глава: {id}");
    }
    Ok(())
}

fn cmd_node_add(args: NodeAdd, quest_root: &str, global_qid: Option<&str>) -> Result<()> {
    let quest_id = resolve_quest_id(args.quest_id.as_deref(), global_qid)?;
    let qb = open_builder(quest_root, &quest_id)?;
    let spec = NodeSpec {
        title: args.title,
        chapter_id: args.chapter,
        x: args.x,
        y: args.y,
        start: args.start,
    };
    let id = qb
        .add_node(&spec)
        .with_context(|| "не удалось добавить ноду")?;
    if args.json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({"id": id})).unwrap()
        );
    } else {
        println!("Добавлена нода: {id}");
    }
    Ok(())
}

fn cmd_node_item_set(args: NodeItemSet, quest_root: &str, global_qid: Option<&str>) -> Result<()> {
    let quest_id = resolve_quest_id(args.quest_id.as_deref(), global_qid)?;
    let qb = open_builder(quest_root, &quest_id)?;
    let patch = ItemPatch {
        text: args.text,
        source: args.source,
        script_id: args.script,
    };
    qb.update_item(&args.node, &args.item, &patch)
        .with_context(|| format!("не удалось изменить айтем {}", args.item))?;
    if args.json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({"id": args.item, "updated": true})).unwrap()
        );
    } else {
        println!("Айтем {} изменён", args.item);
    }
    Ok(())
}

fn cmd_node_item_remove(
    args: NodeItemRemove,
    quest_root: &str,
    global_qid: Option<&str>,
) -> Result<()> {
    let quest_id = resolve_quest_id(args.quest_id.as_deref(), global_qid)?;
    let qb = open_builder(quest_root, &quest_id)?;
    qb.remove_item(&args.node, &args.item)
        .with_context(|| format!("не удалось удалить айтем {}", args.item))?;
    if args.json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({"id": args.item, "removed": true})).unwrap()
        );
    } else {
        println!("Айтем {} удалён", args.item);
    }
    Ok(())
}

fn cmd_node_set(args: NodeSet, quest_root: &str, global_qid: Option<&str>) -> Result<()> {
    let quest_id = resolve_quest_id(args.quest_id.as_deref(), global_qid)?;
    if args.title.is_none()
        && args.chapter.is_none()
        && args.x.is_none()
        && args.y.is_none()
        && !args.start
    {
        bail!("нечего менять: задайте --title/--chapter/--x/--y/--start");
    }
    let qb = open_builder(quest_root, &quest_id)?;
    let edit = NodeEdit {
        title: args.title,
        chapter_id: args.chapter,
        x: args.x,
        y: args.y,
        start: args.start.then_some(true),
    };
    qb.update_node(&args.node, &edit)
        .with_context(|| format!("не удалось изменить ноду {}", args.node))?;
    if args.json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({"id": args.node, "updated": true})).unwrap()
        );
    } else {
        println!("Нода {} изменена", args.node);
    }
    Ok(())
}

fn cmd_node_text(args: NodeText, quest_root: &str, global_qid: Option<&str>) -> Result<()> {
    let quest_id = resolve_quest_id(args.quest_id.as_deref(), global_qid)?;
    let qb = open_builder(quest_root, &quest_id)?;
    let spec = ItemSpec {
        kind: ItemKind::Text,
        text: Some(args.text),
        ..Default::default()
    };
    let id = qb
        .add_item(&args.node, &spec)
        .with_context(|| "не удалось добавить текст")?;
    print_id(id, args.json, "текстовый айтем");
    Ok(())
}

fn cmd_node_image(args: NodeImage, quest_root: &str, global_qid: Option<&str>) -> Result<()> {
    let quest_id = resolve_quest_id(args.quest_id.as_deref(), global_qid)?;
    let qb = open_builder(quest_root, &quest_id)?;
    let spec = ItemSpec {
        kind: ItemKind::Image,
        source: Some(args.source),
        ..Default::default()
    };
    let id = qb
        .add_item(&args.node, &spec)
        .with_context(|| "не удалось добавить картинку")?;
    print_id(id, args.json, "айтем-картинку");
    Ok(())
}

fn cmd_node_button(args: NodeButton, quest_root: &str, global_qid: Option<&str>) -> Result<()> {
    let quest_id = resolve_quest_id(args.quest_id.as_deref(), global_qid)?;
    let qb = open_builder(quest_root, &quest_id)?;
    let spec = ItemSpec {
        kind: ItemKind::Button,
        text: Some(args.text),
        script_id: Some(args.script),
        ..Default::default()
    };
    let id = qb
        .add_item(&args.node, &spec)
        .with_context(|| "не удалось добавить кнопку")?;
    print_id(id, args.json, "кнопку");
    Ok(())
}

fn cmd_node_row(args: NodeRow, quest_root: &str, global_qid: Option<&str>) -> Result<()> {
    let quest_id = resolve_quest_id(args.quest_id.as_deref(), global_qid)?;
    let qb = open_builder(quest_root, &quest_id)?;
    let spec = ItemSpec {
        kind: ItemKind::Row,
        children: args.children,
        ..Default::default()
    };
    let id = qb
        .add_item(&args.node, &spec)
        .with_context(|| "не удалось добавить ряд")?;
    print_id(id, args.json, "ряд");
    Ok(())
}

fn cmd_script_new(args: ScriptNew, quest_root: &str, global_qid: Option<&str>) -> Result<()> {
    let quest_id = resolve_quest_id(args.quest_id.as_deref(), global_qid)?;
    let qb = open_builder(quest_root, &quest_id)?;
    let id = qb
        .create_script(&args.name, args.event, None)
        .with_context(|| "не удалось создать скрипт")?;
    if args.json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({"id": id})).unwrap()
        );
    } else {
        println!("Создан скрипт: {id}");
    }
    Ok(())
}

fn cmd_script_set_image(
    args: ScriptSetImage,
    quest_root: &str,
    global_qid: Option<&str>,
) -> Result<()> {
    let quest_id = resolve_quest_id(args.common.quest_id.as_deref(), global_qid)?;
    let qb = open_builder(quest_root, &quest_id)?;
    qb.set_image_block(&args.common.script, &args.item, &args.source)
        .with_context(|| "не удалось добавить блок set_image")?;
    Ok(())
}

fn cmd_script_assign(args: ScriptAssign, quest_root: &str, global_qid: Option<&str>) -> Result<()> {
    let quest_id = resolve_quest_id(args.common.quest_id.as_deref(), global_qid)?;
    let qb = open_builder(quest_root, &quest_id)?;
    let value: Value = serde_json::from_str(&args.value)
        .with_context(|| format!("не удалось распарсить значение '{}'", args.value))?;
    qb.assign_block(&args.common.script, &args.var, &value)
        .with_context(|| "не удалось добавить блок assign_variable")?;
    Ok(())
}

fn cmd_script_wait(args: ScriptWait, quest_root: &str, global_qid: Option<&str>) -> Result<()> {
    let quest_id = resolve_quest_id(args.common.quest_id.as_deref(), global_qid)?;
    let qb = open_builder(quest_root, &quest_id)?;
    qb.wait_block(&args.common.script, args.ms)
        .with_context(|| "не удалось добавить блок wait")?;
    Ok(())
}

fn cmd_script_goto(args: ScriptGoto, quest_root: &str, global_qid: Option<&str>) -> Result<()> {
    let quest_id = resolve_quest_id(args.common.quest_id.as_deref(), global_qid)?;
    let qb = open_builder(quest_root, &quest_id)?;
    qb.goto_block(&args.common.script, &args.node)
        .with_context(|| "не удалось добавить блок go_to_node")?;
    Ok(())
}

fn cmd_script_add_block(
    args: ScriptAddBlock,
    quest_root: &str,
    global_qid: Option<&str>,
) -> Result<()> {
    let quest_id = resolve_quest_id(args.quest_id.as_deref(), global_qid)?;
    let qb = open_builder(quest_root, &quest_id)?;
    let block: Value =
        serde_json::from_str(&args.json).with_context(|| "не удалось распарсить JSON блока")?;
    qb.add_block(&args.script, block)
        .with_context(|| "не удалось добавить блок")?;
    Ok(())
}

fn cmd_table_set(args: TableSet, quest_root: &str, global_qid: Option<&str>) -> Result<()> {
    let quest_id = resolve_quest_id(args.quest_id.as_deref(), global_qid)?;
    let qb = open_builder(quest_root, &quest_id)?;

    let rows: Vec<Value> = if args.rows_json == "-" {
        let mut buf = String::new();
        std::io::stdin().read_to_string(&mut buf)?;
        serde_json::from_str(&buf).with_context(|| "не удалось распарсить rows-json из stdin")?
    } else {
        let content = std::fs::read_to_string(&args.rows_json)
            .with_context(|| format!("не удалось прочитать {}", args.rows_json))?;
        serde_json::from_str(&content)
            .with_context(|| format!("не удалось распарсить {}", args.rows_json))?
    };

    let row_names = args
        .row_names
        .unwrap_or_else(|| (0..rows.len()).map(|i| i.to_string()).collect::<Vec<_>>());

    qb.set_table(&args.name, &args.columns, &row_names, &rows)
        .with_context(|| "не удалось установить таблицу")?;
    println!("Таблица '{}' установлена", args.name);
    Ok(())
}

fn cmd_var_set(args: VarSet, quest_root: &str, global_qid: Option<&str>) -> Result<()> {
    let quest_id = resolve_quest_id(args.quest_id.as_deref(), global_qid)?;
    let qb = open_builder(quest_root, &quest_id)?;
    let value: Value = serde_json::from_str(&args.value)
        .with_context(|| format!("не удалось распарсить значение '{}'", args.value))?;
    qb.set_variable(&args.name, value)
        .with_context(|| "не удалось установить переменную")?;
    println!("Переменная '{}' установлена", args.name);
    Ok(())
}

fn cmd_resource_add(args: ResourceAdd, quest_root: &str, global_qid: Option<&str>) -> Result<()> {
    let quest_id = resolve_quest_id(args.quest_id.as_deref(), global_qid)?;
    let qb = open_builder(quest_root, &quest_id)?;
    let path = qb
        .add_resource(&args.file, args.name.as_deref(), args.kind)
        .with_context(|| "не удалось добавить ресурс")?;
    if args.json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({"path": path})).unwrap()
        );
    } else {
        println!("Ресурс добавлен: {path}");
    }
    Ok(())
}

fn print_id(id: String, as_json: bool, label: &str) {
    if as_json {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({"id": id})).unwrap()
        );
    } else {
        println!("Добавлен {label}: {id}");
    }
}

fn parse_script_event(s: &str) -> Result<ScriptEvent, String> {
    match s {
        "onPress" => Ok(ScriptEvent::OnPress),
        "onEnter" => Ok(ScriptEvent::OnEnter),
        "onAppear" => Ok(ScriptEvent::OnAppear),
        _ => Err(format!(
            "неизвестное событие '{s}': ожидалось onPress|onEnter|onAppear"
        )),
    }
}

fn parse_resource_kind(s: &str) -> Result<ResourceKind, String> {
    match s {
        "image" => Ok(ResourceKind::Image),
        "audio" => Ok(ResourceKind::Audio),
        "video" => Ok(ResourceKind::Video),
        "font" => Ok(ResourceKind::Font),
        _ => Err(format!(
            "неизвестный тип ресурса '{s}': ожидалось image|audio|video|font"
        )),
    }
}
