#![allow(clippy::too_many_lines)]

//! Подкоманды редактирования квеста (`mnd-cli quest …`).
//!
//! Все операции делегируются [`mnd_core::quest_build::QuestBuilder`],
//! чтобы не было прямой правки JSON в CLI.
//!
//! Интерфейс рассчитан на автоматического автора (генератор): любая команда
//! либо печатает один JSON-объект (`--json`), либо короткий текст для
//! человека; ссылки на ноды/скрипты/главы принимаются по названию, а не
//! только по uuid; код возврата — 1, если запись не произошла.

use std::io::Read;
use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use clap::{Args, Subcommand};
use serde_json::{Value, json};

use mnd_core::quest_build::{
    ApplyOptions, ItemKind, ItemPatch, ItemSpec, NodeEdit, NodeSpec, QuestBuilder, ResourceKind,
    ScriptEvent,
};
use mnd_core::validation::analyze_quest;

/// Верхнеуровневые подкоманды `quest`.
#[derive(Subcommand)]
pub enum QuestCmd {
    /// Создать новый квест.
    New(QuestNew),
    /// Применить декларативный план (JSON) одной транзакцией.
    #[command(
        after_help = "План описывает главы/ноды/скрипты/таблицы/переменные одним \
документом; ссылки — по названию. Формат: `mnd-cli quest spec`."
    )]
    Apply(QuestApply),
    /// Показать ноду, скрипт или дерево квеста.
    Show(QuestShow),
    /// Описание формата квеста и плана (JSON).
    Spec,
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

/// Общий контекст выполнения: корень хранилища, квест и режим вывода.
pub struct Ctx<'a> {
    pub root: &'a str,
    pub quest_id: Option<&'a str>,
    pub json: bool,
}

impl Ctx<'_> {
    fn qid(&self, local: Option<&str>) -> Result<String> {
        local
            .map(str::to_string)
            .or_else(|| self.quest_id.map(str::to_string))
            .with_context(|| "не задан --quest-id (глобально или для подкоманды)")
    }

    fn open(&self, quest_id: &str) -> Result<QuestBuilder> {
        let root = self.root;
        QuestBuilder::open(std::path::Path::new(root), quest_id)
            .with_context(|| format!("не удалось открыть квест {quest_id} в {root}/quests/"))
    }

    /// Один JSON-объект или строка для человека.
    fn emit(&self, value: &Value, human: impl Into<String>) {
        if self.json {
            println!("{}", serde_json::to_string_pretty(value).unwrap());
        } else {
            println!("{}", human.into());
        }
    }
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
    /// Пустой каркас: без главы и без ноды «Начало» (для последующего `apply`).
    #[arg(long)]
    empty: bool,
}

#[derive(Args)]
pub struct QuestApply {
    /// Путь к JSON-плану, `-` — stdin.
    #[arg(long)]
    file: String,
    /// Показать, что изменилось бы, ничего не записывая.
    #[arg(long)]
    dry_run: bool,
    /// Писать, даже если валидатор нашёл ошибки.
    #[arg(long)]
    force: bool,
    /// ID квеста. Если не задан — берётся из глобального `--quest-id`.
    #[arg(long)]
    quest_id: Option<String>,
}

#[derive(Args)]
pub struct QuestShow {
    /// Нода: id, префикс id или название.
    #[arg(long, conflicts_with = "script")]
    node: Option<String>,
    /// Скрипт: id, имя или `scripts/<id>.json`.
    #[arg(long)]
    script: Option<String>,
    /// ID квеста. Если не задан — берётся из глобального `--quest-id`.
    #[arg(long)]
    quest_id: Option<String>,
}

#[derive(Args)]
pub struct QuestValidate {
    /// ID квеста. Если не задан — берётся из глобального `--quest-id`.
    #[arg(long)]
    quest_id: Option<String>,
    /// Считать предупреждения ошибкой (для CI): код выхода 1 при любом
    /// замечании, а не только при ошибке.
    #[arg(long)]
    strict: bool,
}

#[derive(Args)]
pub struct QuestInfo {
    /// ID квеста. Если не задан — берётся из глобального `--quest-id`.
    #[arg(long)]
    quest_id: Option<String>,
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
    /// ID главы. Если не задан — генерируется uuid v4.
    #[arg(long)]
    id: Option<String>,
    /// ID квеста. Если не задан — берётся из глобального `--quest-id`.
    #[arg(long)]
    quest_id: Option<String>,
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
    /// ID ноды. Если не задан — генерируется uuid v4.
    #[arg(long)]
    id: Option<String>,
    /// Глава: id или название. Если не задана — первая глава.
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
}

#[derive(Args)]
pub struct NodeButton {
    /// ID ноды.
    #[arg(long)]
    node: String,
    /// Текст кнопки.
    #[arg(long)]
    text: String,
    /// Скрипт: id или имя.
    #[arg(long)]
    script: String,
    /// ID квеста. Если не задан — берётся из глобального `--quest-id`.
    #[arg(long)]
    quest_id: Option<String>,
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
    /// Скрипт: id, имя или `scripts/<id>.json`.
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
    /// ID скрипта. Если не задан — генерируется uuid v4.
    #[arg(long)]
    id: Option<String>,
    /// Событие скрипта.
    #[arg(long, value_parser = parse_script_event, default_value = "onPress")]
    event: ScriptEvent,
    /// ID квеста. Если не задан — берётся из глобального `--quest-id`.
    #[arg(long)]
    quest_id: Option<String>,
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
    /// Целевая нода: id или название.
    #[arg(long)]
    node: String,
}

#[derive(Args)]
pub struct ScriptAddBlock {
    /// Скрипт: id, имя или `scripts/<id>.json`.
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
    /// Имена строк через запятую. Если не заданы — берутся индексы.
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
}

/// Выполнить подкоманду. Возвращает код возврата (0 — успех, 1 — отказ).
pub fn run_quest_cmd(cmd: QuestCmd, ctx: &Ctx) -> Result<i32> {
    match cmd {
        QuestCmd::New(args) => cmd_new(args, ctx)?,
        QuestCmd::Apply(args) => return cmd_apply(args, ctx),
        QuestCmd::Show(args) => cmd_show(args, ctx)?,
        QuestCmd::Spec => println!(
            "{}",
            serde_json::to_string_pretty(&mnd_core::quest_spec::describe()).unwrap()
        ),
        QuestCmd::Validate(args) => return cmd_validate(args, ctx),
        QuestCmd::Info(args) => cmd_info(args, ctx)?,
        QuestCmd::Chapter(ChapterCmd::Add(args)) => cmd_chapter_add(args, ctx)?,
        QuestCmd::Node(NodeCmd::Add(args)) => cmd_node_add(args, ctx)?,
        QuestCmd::Node(NodeCmd::Set(args)) => cmd_node_set(args, ctx)?,
        QuestCmd::Node(NodeCmd::Text(args)) => cmd_node_text(args, ctx)?,
        QuestCmd::Node(NodeCmd::Image(args)) => cmd_node_image(args, ctx)?,
        QuestCmd::Node(NodeCmd::Button(args)) => cmd_node_button(args, ctx)?,
        QuestCmd::Node(NodeCmd::Row(args)) => cmd_node_row(args, ctx)?,
        QuestCmd::Node(NodeCmd::ItemSet(args)) => cmd_node_item_set(args, ctx)?,
        QuestCmd::Node(NodeCmd::ItemRemove(args)) => cmd_node_item_remove(args, ctx)?,
        QuestCmd::Script(ScriptCmd::New(args)) => cmd_script_new(args, ctx)?,
        QuestCmd::Script(ScriptCmd::SetImage(args)) => cmd_script_set_image(args, ctx)?,
        QuestCmd::Script(ScriptCmd::Assign(args)) => cmd_script_assign(args, ctx)?,
        QuestCmd::Script(ScriptCmd::Wait(args)) => cmd_script_wait(args, ctx)?,
        QuestCmd::Script(ScriptCmd::Goto(args)) => cmd_script_goto(args, ctx)?,
        QuestCmd::Script(ScriptCmd::AddBlock(args)) => cmd_script_add_block(args, ctx)?,
        QuestCmd::Table(TableCmd::Set(args)) => cmd_table_set(args, ctx)?,
        QuestCmd::Var(VarCmd::Set(args)) => cmd_var_set(args, ctx)?,
        QuestCmd::Resource(ResourceCmd::Add(args)) => cmd_resource_add(args, ctx)?,
    }
    Ok(0)
}

// ---------------------------------------------------------------------------
// Команды
// ---------------------------------------------------------------------------

fn cmd_new(args: QuestNew, ctx: &Ctx) -> Result<()> {
    // Глобальный `--quest-id` тоже принимаем: иначе один и тот же флаг в
    // одной позиции означает «создать с этим id», а в другой — молча
    // игнорируется, и квест создаётся с чужим uuid.
    let quest_id = args
        .quest_id
        .or_else(|| ctx.quest_id.map(str::to_string))
        .unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    let qb = if args.empty {
        QuestBuilder::create_empty(
            &quest_id,
            std::path::Path::new(ctx.root),
            &args.title,
            args.author.as_deref(),
        )
    } else {
        QuestBuilder::create(
            &quest_id,
            std::path::Path::new(ctx.root),
            &args.title,
            args.author.as_deref(),
            args.chapter.as_deref(),
        )
    }
    .with_context(|| "не удалось создать квест")?;
    let info = qb.info();
    let start = info["startNodeId"].as_str().unwrap_or("").to_string();
    let chapter = info["chapters"]
        .as_array()
        .and_then(|a| a.first())
        .and_then(|c| c["id"].as_str())
        .unwrap_or("")
        .to_string();
    ctx.emit(
        &json!({
            "ok": true,
            "questId": quest_id,
            "startNodeId": start,
            "chapterId": chapter,
        }),
        format!("Квест создан: {quest_id}\nСтартовая нода: {start}"),
    );
    Ok(())
}

fn cmd_apply(args: QuestApply, ctx: &Ctx) -> Result<i32> {
    let quest_id = ctx.qid(args.quest_id.as_deref())?;
    let qb = ctx.open(&quest_id)?;
    let raw = if args.file == "-" {
        let mut buf = String::new();
        std::io::stdin().read_to_string(&mut buf)?;
        buf
    } else {
        std::fs::read_to_string(&args.file)
            .with_context(|| format!("не удалось прочитать {}", args.file))?
    };
    let plan: Value =
        serde_json::from_str(&raw).with_context(|| format!("{} — не JSON", args.file))?;

    let opts = ApplyOptions {
        dry_run: args.dry_run,
        force: args.force,
    };
    let report = qb.apply(&plan, &opts).with_context(|| "план не применён")?;
    let ok = report.ok && (args.dry_run || report.applied);

    if ctx.json {
        println!("{}", serde_json::to_string_pretty(&report).unwrap());
    } else {
        print_apply_human(&report, args.dry_run);
    }
    Ok(if ok { 0 } else { 1 })
}

fn print_apply_human(report: &mnd_core::quest_plan::ApplyReport, dry_run: bool) {
    let mut lines = Vec::new();
    let head = if dry_run {
        "Проверка плана (ничего не записано)"
    } else if report.applied {
        "План применён"
    } else {
        "План не применён"
    };
    lines.push(head.to_string());
    for (label, list) in [
        ("создано глав", &report.created.chapters),
        ("создано нод", &report.created.nodes),
        ("создано скриптов", &report.created.scripts),
        ("обновлено нод", &report.updated.nodes),
        ("обновлено скриптов", &report.updated.scripts),
        ("удалено нод", &report.deleted.nodes),
        ("удалено скриптов", &report.deleted.scripts),
    ] {
        if list.is_empty() {
            continue;
        }
        lines.push(format!("  {label}: {}", list.len()));
        for item in list {
            if item.title.is_empty() {
                lines.push(format!("    {}", item.id));
            } else {
                lines.push(format!("    {} [{}]", item.title, item.id));
            }
        }
    }
    for name in &report.updated.tables {
        lines.push(format!("  таблица «{name}» обновлена"));
    }
    for name in &report.updated.variables {
        lines.push(format!("  переменная «{name}» обновлена"));
    }
    if report.applied {
        lines.push(format!("  файлов записано: {}", report.files.len()));
    }
    for issue in &report.issues {
        lines.push(format!("  ✗ {}: {}", issue.path, issue.message));
    }
    for d in &report.diagnostics {
        let mark = if matches!(d.severity, mnd_core::validation::Severity::Error) {
            "✗"
        } else {
            "!"
        };
        lines.push(format!("  {mark} {}", d.message));
        if let Some(hint) = &d.fix_hint {
            lines.push(format!("    → {hint}"));
        }
    }
    println!("{}", lines.join("\n"));
}

fn cmd_show(args: QuestShow, ctx: &Ctx) -> Result<()> {
    let quest_id = ctx.qid(args.quest_id.as_deref())?;
    let qb = ctx.open(&quest_id)?;

    if let Some(node_ref) = args.node {
        let node_id = qb.resolve_node(&node_ref)?;
        let body = qb.node_body_json(&node_id)?;
        if ctx.json {
            println!("{}", serde_json::to_string_pretty(&body).unwrap());
        } else {
            println!("{}", render_node(&body));
        }
        return Ok(());
    }
    if let Some(script_ref) = args.script {
        let script_id = qb.resolve_script(&script_ref)?;
        let body = qb.script_json(&script_id)?;
        if ctx.json {
            println!("{}", serde_json::to_string_pretty(&body).unwrap());
        } else {
            println!("{}", render_script(&body));
        }
        return Ok(());
    }

    let tree = qb.tree();
    if ctx.json {
        println!("{}", serde_json::to_string_pretty(&tree).unwrap());
    } else {
        println!("{}", render_tree(&tree));
    }
    Ok(())
}

fn render_node(body: &Value) -> String {
    let mut out = Vec::new();
    out.push(format!(
        "Нода «{}» [{}]",
        body["title"].as_str().unwrap_or(""),
        body["id"].as_str().unwrap_or("")
    ));
    out.push(format!(
        "  глава: {}  позиция: {},{}",
        body["chapterId"].as_str().unwrap_or(""),
        body["x"].as_f64().unwrap_or(0.0),
        body["y"].as_f64().unwrap_or(0.0)
    ));
    for key in ["backgroundAssetId", "backgroundAudioId", "scriptAssetId"] {
        if let Some(value) = body[key].as_str() {
            out.push(format!("  {key}: {value}"));
        }
    }
    out.push("  содержимое:".to_string());
    let items = body["content"]["items"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    for item in &items {
        out.push(format!("    {}", describe_item(item, 0)));
    }
    out.join("\n")
}

fn describe_item(item: &Value, depth: usize) -> String {
    let pad = "  ".repeat(depth);
    let kind = item["type"].as_str().unwrap_or("?");
    let id = item["id"].as_str().unwrap_or("");
    let text = item["text"]
        .as_str()
        .map(|t| truncate(t, 60))
        .or_else(|| item["resourcePath"].as_str().map(|s| s.to_string()))
        .unwrap_or_default();
    let script = item["scriptAssetId"]
        .as_str()
        .map(|s| format!("  script={s}"))
        .unwrap_or_default();
    let mut line = format!("{pad}[{kind}] {id}  {text}{script}");
    if let Some(children) = item["children"].as_array() {
        for child in children {
            line.push('\n');
            line.push_str(&describe_item(child, depth + 1));
        }
    }
    line
}

fn truncate(text: &str, limit: usize) -> String {
    let flat = text.replace('\n', " ");
    if flat.chars().count() <= limit {
        return flat;
    }
    let cut: String = flat.chars().take(limit).collect();
    format!("{cut}…")
}

fn render_script(body: &Value) -> String {
    let mut out = Vec::new();
    out.push(format!(
        "Скрипт «{}» [{}]",
        body["name"].as_str().unwrap_or(""),
        body["id"].as_str().unwrap_or("")
    ));
    for block in body["blocks"].as_array().cloned().unwrap_or_default() {
        out.push(format!("  {}", describe_block(&block, 1)));
    }
    out.join("\n")
}

fn describe_block(block: &Value, depth: usize) -> String {
    let pad = "  ".repeat(depth);
    let kind = block["type"].as_str().unwrap_or("?");
    let mut extras = Vec::new();
    for key in [
        "node_id",
        "script_id",
        "item_id",
        "variable",
        "value",
        "expression",
        "mode",
        "url",
        "text",
    ] {
        if let Some(value) = block.get(key) {
            if value.is_string() {
                let raw = value.as_str().unwrap_or("");
                if !raw.is_empty() {
                    extras.push(format!("{key}={}", truncate(raw, 40)));
                }
            } else if !value.is_null() {
                extras.push(format!("{key}={value}"));
            }
        }
    }
    let mut line = format!("{pad}[{kind}] {}", extras.join(" "));
    for key in ["children", "then_blocks", "else_blocks"] {
        if let Some(list) = block[key].as_array() {
            for child in list {
                line.push('\n');
                line.push_str(&describe_block(child, depth + 1));
            }
        }
    }
    line.trim_end().to_string()
}

fn render_tree(tree: &Value) -> String {
    let mut out = Vec::new();
    out.push(format!(
        "Квест «{}» [{}]",
        tree["title"].as_str().unwrap_or(""),
        tree["questId"].as_str().unwrap_or("")
    ));
    if let Some(start) = tree["startNodeId"].as_str() {
        out.push(format!("  старт: {start}"));
    }
    for chapter in tree["chapters"].as_array().cloned().unwrap_or_default() {
        out.push(format!(
            "Глава «{}» [{}]",
            chapter["name"].as_str().unwrap_or(""),
            chapter["id"].as_str().unwrap_or("")
        ));
        for node in chapter["nodes"].as_array().cloned().unwrap_or_default() {
            out.push(format!(
                "  [{kind}] {id} «{title}» — {items} айтемов",
                kind = if node["isStart"].as_bool().unwrap_or(false) {
                    "START"
                } else {
                    "NODE"
                },
                id = node["id"].as_str().unwrap_or(""),
                title = node["title"].as_str().unwrap_or(""),
                items = node["items"].as_u64().unwrap_or(0)
            ));
        }
    }
    out.push("Скрипты:".to_string());
    for script in tree["scripts"].as_array().cloned().unwrap_or_default() {
        out.push(format!(
            "  {} «{}» — {} блоков",
            script["id"].as_str().unwrap_or(""),
            script["name"].as_str().unwrap_or(""),
            script["blocks"].as_u64().unwrap_or(0)
        ));
    }
    if let Some(tables) = tree["tables"].as_array() {
        out.push("Таблицы:".to_string());
        for table in tables {
            out.push(format!(
                "  «{}» — {} колонок, {} строк",
                table["name"].as_str().unwrap_or(""),
                table["columns"].as_u64().unwrap_or(0),
                table["rows"].as_u64().unwrap_or(0)
            ));
        }
    }
    if let Some(vars) = tree["variables"].as_array() {
        out.push("Переменные:".to_string());
        for var in vars {
            out.push(format!(
                "  {} = {}",
                var["name"].as_str().unwrap_or(""),
                var["defaultValue"]
            ));
        }
    }
    out.join("\n")
}

fn cmd_validate(args: QuestValidate, ctx: &Ctx) -> Result<i32> {
    let quest_id = ctx.qid(args.quest_id.as_deref())?;
    let report = analyze_quest(&quest_id, ctx.root);
    let errors = report.stats.errors;
    let warnings = report.stats.warnings;
    let failed = errors > 0 || (args.strict && warnings > 0);

    if ctx.json {
        println!("{}", serde_json::to_string_pretty(&report).unwrap());
    } else {
        let mut out = Vec::new();
        out.push(format!(
            "Нод: {}, айтемов: {}, скриптов: {}, шаблонов: {}. Ошибок: {errors}, предупреждений: {warnings}",
            report.stats.nodes,
            report.stats.items,
            report.stats.scripts,
            report.stats.templates
        ));
        for d in &report.diagnostics {
            let mark = if matches!(d.severity, mnd_core::validation::Severity::Error) {
                "✗"
            } else {
                "!"
            };
            // Где именно: без этого автор ищет проблему по всему квесту.
            let mut where_parts: Vec<String> = Vec::new();
            if let Some(node) = d.node_id.as_deref().filter(|n| !n.is_empty()) {
                where_parts.push(format!("нода {node}"));
            }
            if let Some(item) = d.item_id.as_deref().filter(|i| !i.is_empty()) {
                where_parts.push(format!("элемент {item}"));
            }
            if let Some(path) = d.script_path.as_deref().filter(|p| !p.is_empty()) {
                where_parts.push(format!("скрипт {path}"));
            }
            let location = if where_parts.is_empty() {
                String::new()
            } else {
                format!(" ({})", where_parts.join(", "))
            };
            out.push(format!(
                "  {mark} [{}]{location} {}",
                d.kind.as_str(),
                d.message
            ));
            if let Some(hint) = &d.fix_hint {
                out.push(format!("      → {hint}"));
            }
        }
        if errors == 0 {
            out.push("Ошибок нет.".to_string());
        }
        if args.strict && errors == 0 && warnings > 0 {
            out.push("--strict: предупреждения считаются ошибкой.".to_string());
        }
        println!("{}", out.join("\n"));
    }
    Ok(if failed { 1 } else { 0 })
}

fn cmd_info(args: QuestInfo, ctx: &Ctx) -> Result<()> {
    let quest_id = ctx.qid(args.quest_id.as_deref())?;
    let qb = ctx.open(&quest_id)?;
    let tree = qb.tree();
    if ctx.json {
        println!("{}", serde_json::to_string_pretty(&tree).unwrap());
    } else {
        println!("{}", render_tree(&tree));
    }
    Ok(())
}

fn cmd_chapter_add(args: ChapterAdd, ctx: &Ctx) -> Result<()> {
    let quest_id = ctx.qid(args.quest_id.as_deref())?;
    let qb = ctx.open(&quest_id)?;
    let id = qb
        .add_chapter(&args.name, args.id.as_deref())
        .with_context(|| "не удалось добавить главу")?;
    ctx.emit(
        &json!({"ok": true, "id": id, "name": args.name}),
        format!("Добавлена глава: {id}"),
    );
    Ok(())
}

fn cmd_node_add(args: NodeAdd, ctx: &Ctx) -> Result<()> {
    let quest_id = ctx.qid(args.quest_id.as_deref())?;
    let qb = ctx.open(&quest_id)?;
    let chapter_id = match args.chapter.as_deref() {
        Some(raw) => Some(qb.resolve_chapter(raw)?),
        None => None,
    };
    let spec = NodeSpec {
        title: args.title.clone(),
        chapter_id,
        x: args.x,
        y: args.y,
        start: args.start,
        id: args.id,
    };
    let id = qb
        .add_node(&spec)
        .with_context(|| "не удалось добавить ноду")?;
    ctx.emit(
        &json!({"ok": true, "id": id, "title": args.title}),
        format!("Добавлена нода: {id}"),
    );
    Ok(())
}

fn cmd_node_set(args: NodeSet, ctx: &Ctx) -> Result<()> {
    let quest_id = ctx.qid(args.quest_id.as_deref())?;
    if args.title.is_none()
        && args.chapter.is_none()
        && args.x.is_none()
        && args.y.is_none()
        && !args.start
    {
        bail!("нечего менять: задайте --title/--chapter/--x/--y/--start");
    }
    let qb = ctx.open(&quest_id)?;
    let node_id = qb.resolve_node(&args.node)?;
    let chapter_id = match args.chapter.as_deref() {
        Some(raw) => Some(qb.resolve_chapter(raw)?),
        None => None,
    };
    let edit = NodeEdit {
        title: args.title,
        chapter_id,
        x: args.x,
        y: args.y,
        start: args.start.then_some(true),
    };
    qb.update_node(&node_id, &edit)
        .with_context(|| format!("не удалось изменить ноду {node_id}"))?;
    ctx.emit(
        &json!({"ok": true, "id": node_id, "updated": true}),
        format!("Нода {node_id} изменена"),
    );
    Ok(())
}

fn cmd_node_text(args: NodeText, ctx: &Ctx) -> Result<()> {
    let quest_id = ctx.qid(args.quest_id.as_deref())?;
    let qb = ctx.open(&quest_id)?;
    let node_id = qb.resolve_node(&args.node)?;
    let spec = ItemSpec {
        kind: ItemKind::Text,
        text: Some(args.text),
        ..Default::default()
    };
    let id = qb
        .add_item(&node_id, &spec)
        .with_context(|| "не удалось добавить текст")?;
    ctx.emit(
        &json!({"ok": true, "id": id, "type": "text", "node": node_id}),
        format!("Добавлен текстовый айтем: {id}"),
    );
    Ok(())
}

fn cmd_node_image(args: NodeImage, ctx: &Ctx) -> Result<()> {
    let quest_id = ctx.qid(args.quest_id.as_deref())?;
    let qb = ctx.open(&quest_id)?;
    let node_id = qb.resolve_node(&args.node)?;
    let spec = ItemSpec {
        kind: ItemKind::Image,
        source: Some(args.source),
        ..Default::default()
    };
    let id = qb
        .add_item(&node_id, &spec)
        .with_context(|| "не удалось добавить картинку")?;
    ctx.emit(
        &json!({"ok": true, "id": id, "type": "image", "node": node_id}),
        format!("Добавлен айтем-картинка: {id}"),
    );
    Ok(())
}

fn cmd_node_button(args: NodeButton, ctx: &Ctx) -> Result<()> {
    let quest_id = ctx.qid(args.quest_id.as_deref())?;
    let qb = ctx.open(&quest_id)?;
    let node_id = qb.resolve_node(&args.node)?;
    let script_id = qb.resolve_script(&args.script)?;
    let spec = ItemSpec {
        kind: ItemKind::Button,
        text: Some(args.text),
        script_id: Some(script_id.clone()),
        ..Default::default()
    };
    let id = qb
        .add_item(&node_id, &spec)
        .with_context(|| "не удалось добавить кнопку")?;
    ctx.emit(
        &json!({"ok": true, "id": id, "type": "button", "node": node_id, "script": script_id}),
        format!("Добавлена кнопка: {id}"),
    );
    Ok(())
}

fn cmd_node_row(args: NodeRow, ctx: &Ctx) -> Result<()> {
    let quest_id = ctx.qid(args.quest_id.as_deref())?;
    let qb = ctx.open(&quest_id)?;
    let node_id = qb.resolve_node(&args.node)?;
    let spec = ItemSpec {
        kind: ItemKind::Row,
        children: args.children,
        ..Default::default()
    };
    let id = qb
        .add_item(&node_id, &spec)
        .with_context(|| "не удалось добавить ряд")?;
    ctx.emit(
        &json!({"ok": true, "id": id, "type": "row", "node": node_id}),
        format!("Добавлен ряд: {id}"),
    );
    Ok(())
}

fn cmd_node_item_set(args: NodeItemSet, ctx: &Ctx) -> Result<()> {
    let quest_id = ctx.qid(args.quest_id.as_deref())?;
    let qb = ctx.open(&quest_id)?;
    let node_id = qb.resolve_node(&args.node)?;
    let script_id = match args.script.as_deref() {
        Some(raw) => Some(qb.resolve_script(raw)?),
        None => None,
    };
    let patch = ItemPatch {
        text: args.text,
        source: args.source,
        script_id,
    };
    qb.update_item(&node_id, &args.item, &patch)
        .with_context(|| format!("не удалось изменить айтем {}", args.item))?;
    ctx.emit(
        &json!({"ok": true, "id": args.item, "node": node_id, "updated": true}),
        format!("Айтем {} изменён", args.item),
    );
    Ok(())
}

fn cmd_node_item_remove(args: NodeItemRemove, ctx: &Ctx) -> Result<()> {
    let quest_id = ctx.qid(args.quest_id.as_deref())?;
    let qb = ctx.open(&quest_id)?;
    let node_id = qb.resolve_node(&args.node)?;
    qb.remove_item(&node_id, &args.item)
        .with_context(|| format!("не удалось удалить айтем {}", args.item))?;
    ctx.emit(
        &json!({"ok": true, "id": args.item, "node": node_id, "removed": true}),
        format!("Айтем {} удалён", args.item),
    );
    Ok(())
}

fn cmd_script_new(args: ScriptNew, ctx: &Ctx) -> Result<()> {
    let quest_id = ctx.qid(args.quest_id.as_deref())?;
    let qb = ctx.open(&quest_id)?;
    let id = qb
        .create_script(&args.name, args.event, args.id.as_deref())
        .with_context(|| "не удалось создать скрипт")?;
    ctx.emit(
        &json!({"ok": true, "id": id, "name": args.name}),
        format!("Создан скрипт: {id}"),
    );
    Ok(())
}

fn script_id(qb: &QuestBuilder, raw: &str) -> Result<String> {
    qb.resolve_script(raw).map_err(anyhow::Error::from)
}

fn cmd_script_set_image(args: ScriptSetImage, ctx: &Ctx) -> Result<()> {
    let quest_id = ctx.qid(args.common.quest_id.as_deref())?;
    let qb = ctx.open(&quest_id)?;
    let script = script_id(&qb, &args.common.script)?;
    qb.set_image_block(&script, &args.item, &args.source)
        .with_context(|| "не удалось добавить блок set_image")?;
    ctx.emit(
        &json!({"ok": true, "script": script, "block": "set_image"}),
        format!("Блок set_image добавлен в {script}"),
    );
    Ok(())
}

fn cmd_script_assign(args: ScriptAssign, ctx: &Ctx) -> Result<()> {
    let quest_id = ctx.qid(args.common.quest_id.as_deref())?;
    let qb = ctx.open(&quest_id)?;
    let script = script_id(&qb, &args.common.script)?;
    let value: Value = serde_json::from_str(&args.value).with_context(|| {
        format!(
            "значение «{}» — не JSON (строка должна быть в кавычках)",
            args.value
        )
    })?;
    qb.assign_block(&script, &args.var, &value)
        .with_context(|| "не удалось добавить блок assign_variable")?;
    ctx.emit(
        &json!({"ok": true, "script": script, "block": "assign_variable", "variable": args.var}),
        format!("Блок assign_variable добавлен в {script}"),
    );
    Ok(())
}

fn cmd_script_wait(args: ScriptWait, ctx: &Ctx) -> Result<()> {
    let quest_id = ctx.qid(args.common.quest_id.as_deref())?;
    let qb = ctx.open(&quest_id)?;
    let script = script_id(&qb, &args.common.script)?;
    qb.wait_block(&script, args.ms)
        .with_context(|| "не удалось добавить блок wait")?;
    ctx.emit(
        &json!({"ok": true, "script": script, "block": "wait", "ms": args.ms}),
        format!("Блок wait добавлен в {script}"),
    );
    Ok(())
}

fn cmd_script_goto(args: ScriptGoto, ctx: &Ctx) -> Result<()> {
    let quest_id = ctx.qid(args.common.quest_id.as_deref())?;
    let qb = ctx.open(&quest_id)?;
    let script = script_id(&qb, &args.common.script)?;
    let node_id = qb.resolve_node(&args.node)?;
    qb.goto_block(&script, &node_id)
        .with_context(|| "не удалось добавить блок go_to_node")?;
    ctx.emit(
        &json!({"ok": true, "script": script, "block": "go_to_node", "node": node_id}),
        format!("Блок go_to_node добавлен в {script}"),
    );
    Ok(())
}

fn cmd_script_add_block(args: ScriptAddBlock, ctx: &Ctx) -> Result<()> {
    let quest_id = ctx.qid(args.quest_id.as_deref())?;
    let qb = ctx.open(&quest_id)?;
    let script = script_id(&qb, &args.script)?;
    let block: Value =
        serde_json::from_str(&args.json).with_context(|| "не удалось распарсить JSON блока")?;
    qb.add_block(&script, block)
        .with_context(|| "не удалось добавить блок")?;
    ctx.emit(
        &json!({"ok": true, "script": script, "added": true}),
        format!("Блок добавлен в {script}"),
    );
    Ok(())
}

fn cmd_table_set(args: TableSet, ctx: &Ctx) -> Result<()> {
    let quest_id = ctx.qid(args.quest_id.as_deref())?;
    let qb = ctx.open(&quest_id)?;

    let rows: Vec<Value> = if args.rows_json == "-" {
        let mut buf = String::new();
        std::io::stdin().read_to_string(&mut buf)?;
        serde_json::from_str(&buf)
            .with_context(|| "не удалось распарсить rows-json из stdin (нужен массив объектов)")?
    } else {
        let content = std::fs::read_to_string(&args.rows_json)
            .with_context(|| format!("не удалось прочитать {}", args.rows_json))?;
        serde_json::from_str(&content)
            .with_context(|| format!("{} — не массив объектов строк", args.rows_json))?
    };

    let row_names = args
        .row_names
        .unwrap_or_else(|| (0..rows.len()).map(|i| i.to_string()).collect::<Vec<_>>());

    qb.set_table(&args.name, &args.columns, &row_names, &rows)
        .with_context(|| "не удалось установить таблицу")?;
    ctx.emit(
        &json!({"ok": true, "table": args.name, "rows": rows.len()}),
        format!("Таблица '{}' установлена", args.name),
    );
    Ok(())
}

fn cmd_var_set(args: VarSet, ctx: &Ctx) -> Result<()> {
    let quest_id = ctx.qid(args.quest_id.as_deref())?;
    let qb = ctx.open(&quest_id)?;
    let value: Value = serde_json::from_str(&args.value).with_context(|| {
        format!(
            "значение «{}» — не JSON (строка должна быть в кавычках)",
            args.value
        )
    })?;
    qb.set_variable(&args.name, value)
        .with_context(|| "не удалось установить переменную")?;
    ctx.emit(
        &json!({"ok": true, "variable": args.name}),
        format!("Переменная '{}' установлена", args.name),
    );
    Ok(())
}

fn cmd_resource_add(args: ResourceAdd, ctx: &Ctx) -> Result<()> {
    let quest_id = ctx.qid(args.quest_id.as_deref())?;
    let qb = ctx.open(&quest_id)?;
    let path = qb
        .add_resource(&args.file, args.name.as_deref(), args.kind)
        .with_context(|| "не удалось добавить ресурс")?;
    ctx.emit(
        &json!({"ok": true, "path": path}),
        format!("Ресурс добавлен: {path}"),
    );
    Ok(())
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
