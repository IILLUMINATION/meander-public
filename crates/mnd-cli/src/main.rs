//! Консольный headless-раннер и редактор квестов Meander.
//!
//! Загружает квест с диска через `GameEngine::from_disk()`, исполняет
//! команды из stdin или файла скрипта, выводит раскрытые айтемы,
//! переходы и текущее состояние переменных. Также позволяет создавать
//! и редактировать квесты через подкоманду `quest`.
//!
//! ```bash
//! # Показать все айтемы стартовой ноды
//! mnd-cli --quest-root ~/quests --quest-id <uuid> reveal
//!
//! # Создать квест из терминала
//! mnd-cli --quest-root ~/quests quest new --title "Новый квест"
//! ```

use std::io::{BufRead, Write};

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use colored::Colorize;
use mnd_core::engine::{GameEngine, NextStep};
use serde_json::Value;

mod quest_cmds;

/// Консольный раннер и редактор квестов Meander.
#[derive(Parser)]
#[command(name = "mnd-cli", version, about)]
struct Cli {
    /// Корень хранилища квестов (папка с `quests/`).
    #[arg(long, default_value = ".")]
    quest_root: String,

    /// ID квеста (uuid-каталог внутри `quests/`). Необязателен;
    /// обязателен для старых команд `reveal|run|repl`, а новые подкоманды
    /// `quest …` могут принимать `--quest-id` локально.
    #[arg(long)]
    quest_id: Option<String>,

    /// Сейв-слот для загрузки (вместо новой игры).
    #[arg(long)]
    save_slot: Option<String>,

    /// Машиночитаемый вывод: один JSON-объект на stdout, ошибки — тоже JSON.
    #[arg(long, global = true)]
    json: bool,

    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Раскрыть все айтемы стартовой ноды и выйти.
    Reveal,
    /// Выполнить скрипт команд из файла (одна команда на строку).
    Run {
        /// Путь к файлу скрипта. Без — читает stdin.
        file: Option<String>,
    },
    /// Интерактивный REPL-режим.
    Repl,
    /// Создание и редактирование квеста.
    #[command(subcommand)]
    Quest(quest_cmds::QuestCmd),
}

struct Session {
    engine: GameEngine,
    /// Накопитель событий для `--json`: печатать в stdout в этом режиме
    /// нельзя, иначе получится текст с JSON.
    trace: Option<Vec<Value>>,
}

impl Session {
    fn new(quest_root: &str, quest_id: &str) -> Result<Self> {
        let engine = GameEngine::from_disk(quest_id, quest_root)
            .with_context(|| format!("квест {quest_id} не найден в {quest_root}/quests/"))?;
        Ok(Self {
            engine,
            trace: None,
        })
    }

    fn tracing(quest_root: &str, quest_id: &str) -> Result<Self> {
        let mut session = Self::new(quest_root, quest_id)?;
        session.trace = Some(Vec::new());
        Ok(session)
    }

    fn note(&mut self, value: Value) {
        if let Some(trace) = self.trace.as_mut() {
            trace.push(value);
        }
    }

    fn quiet(&self) -> bool {
        self.trace.is_some()
    }

    fn start(&mut self, save_slot: Option<&str>) -> Result<()> {
        let view = if let Some(slot_name) = save_slot {
            let saves = self.engine.list_saves();
            let save = saves
                .iter()
                .find(|s| s.slot_name == slot_name)
                .with_context(|| format!("сейв '{slot_name}' не найден"))?;
            self.engine
                .start_from_save(save)
                .context("не удалось загрузить сейв")?
        } else {
            self.engine
                .start_new(None)
                .context("не удалось начать новую игру")?
        };

        self.note(serde_json::json!({
            "event": "start",
            "nodeId": view.node_id,
            "title": view.title,
            "backgroundImage": view.background_image_id,
            "transition": view.transition,
        }));
        if self.quiet() {
            if let Some(t) = view.transition.clone() {
                self.note(serde_json::json!({"event": "transition", "nodeId": t}));
            }
            return Ok(());
        }

        println!(
            "{} {}{}{}",
            "▶".green().bold(),
            "Нода: ".dimmed(),
            view.title.bold(),
            format!("  [{}]", view.node_id).dimmed()
        );
        if let Some(bg) = &view.background_image_id {
            println!("  {} {}", "🖼".dimmed(), bg.dimmed());
        }
        if let Some(audio) = &view.background_audio {
            println!(
                "  {} {} (vol: {})",
                "♫".dimmed(),
                audio.audio_id.dimmed(),
                audio.volume
            );
        }
        if let Some(timer) = &view.timer {
            println!(
                "  {} {}s → {}",
                "⏱".dimmed(),
                timer.duration,
                timer.default_action_node_id.dimmed()
            );
        }
        if let Some(t) = view.transition {
            println!("  {} → {}", "↳".yellow(), t.yellow());
        }
        Ok(())
    }

    /// Раскрыть все оставшиеся айтемы, выводя каждый.
    fn reveal_all(&mut self) -> Result<()> {
        loop {
            match self.engine.next_item() {
                NextStep::Item(item) => {
                    let ci = &*item;
                    let text = ci
                        .text
                        .as_deref()
                        .unwrap_or_else(|| ci.content_markdown.as_deref().unwrap_or(""));
                    self.note(serde_json::json!({
                        "event": "reveal",
                        "itemId": ci.id,
                        "type": ci.item_type,
                        "text": text,
                        "resourcePath": ci.resource_path,
                    }));
                    if self.quiet() {
                        continue;
                    }
                    let type_str = format!("[{}]", ci.item_type).dimmed();
                    let id_str = format!("({})", ci.id).dimmed();
                    println!("  {} {} {}", type_str, text, id_str);
                }
                NextStep::Transition(node_id) => {
                    self.note(serde_json::json!({"event": "transition", "nodeId": node_id}));
                    if !self.quiet() {
                        println!("  {} → {}", "↳".yellow(), node_id.yellow());
                    }
                    break;
                }
                NextStep::Done => break,
            }
        }
        Ok(())
    }

    /// Найти айтем текущей ноды по id, а если такого нет — по тексту.
    ///
    /// Текст удобнее id, когда сценарий пишет человек или ИИ по сценарию
    /// квеста: id айтема меняется при каждом применении плана.
    fn resolve_item(&self, target: &str) -> Result<String, String> {
        if self.engine.item_json_by_id(target).is_some() {
            return Ok(target.to_string());
        }
        let matched: Vec<Value> = self
            .engine
            .current_items()
            .into_iter()
            .filter(|item| item.get("text").and_then(Value::as_str) == Some(target))
            .collect();
        match matched.as_slice() {
            [only] => match only.get("id").and_then(Value::as_str) {
                Some(id) => Ok(id.to_string()),
                None => Err(self.unknown_item_message(target)),
            },
            [] => Err(self.unknown_item_message(target)),
            many => {
                let ids: Vec<&str> = many
                    .iter()
                    .filter_map(|item| item.get("id").and_then(Value::as_str))
                    .collect();
                Err(format!(
                    "айтемов с текстом «{target}» несколько — нажимайте по id: {}",
                    ids.join(", ")
                ))
            }
        }
    }

    /// Что вообще можно нажать в текущей ноде: только айтемы с триггером —
    /// остальные (текст, картинки) движок не исполнит.
    fn unknown_item_message(&self, target: &str) -> String {
        let listed: Vec<String> = self
            .engine
            .current_items()
            .iter()
            .filter(|item| {
                let has_behaviour = item
                    .get("behaviours")
                    .and_then(Value::as_array)
                    .is_some_and(|list| !list.is_empty());
                let has_legacy = item
                    .get("scriptTriggers")
                    .and_then(Value::as_object)
                    .is_some_and(|map| !map.is_empty());
                has_behaviour || has_legacy
            })
            .filter_map(|item| {
                let id = item.get("id").and_then(Value::as_str)?;
                let text = item.get("text").and_then(Value::as_str).unwrap_or("");
                Some(format!("«{text}» ({id})"))
            })
            .collect();
        if listed.is_empty() {
            format!("айтем «{target}» не найден: в текущей ноде нет нажимаемых айтемов")
        } else {
            format!(
                "айтем «{target}» не найден в текущей ноде; нажимаемые: {}",
                listed.join(", ")
            )
        }
    }

    /// Нажать айтем по id или тексту (кнопка/айтем со скриптом).
    ///
    /// Работает без отрисовки: ядро находит JSON айтема в текущей ноде и
    /// исполняет его `onPress`. Если скрипт увёл игру дальше — печатаем и
    /// грузим новую ноду, чтобы `press` в скрипте команд вёл себя как в игре.
    fn press(&mut self, target: &str) -> Result<()> {
        // Кавычки необязательны, но привычны: `press "Шагнуть на мост"`.
        let target = target.trim();
        let target = target
            .strip_prefix('"')
            .and_then(|rest| rest.strip_suffix('"'))
            .unwrap_or(target)
            .trim();
        if target.is_empty() {
            bail!("press: укажите id или текст айтема (см. reveal)");
        }
        let item_id = self.resolve_item(target).map_err(|e| anyhow::anyhow!(e))?;
        let transition = self.engine.press_item(&item_id);
        self.note(serde_json::json!({
            "event": "press",
            "itemId": item_id,
            "transition": transition,
        }));
        if self.quiet() {
            if let Some(node_id) = &transition
                && let Some(view) = self.engine.load_node(node_id)
            {
                self.note(serde_json::json!({
                    "event": "transition",
                    "nodeId": node_id,
                    "title": view.title,
                }));
            }
            return Ok(());
        }
        match &transition {
            Some(node_id) => {
                println!("{} {}", "↳".yellow(), node_id.yellow());
                match self.engine.load_node(node_id) {
                    Some(view) => {
                        println!("{} {}", "▶".green().bold(), view.title.bold());
                    }
                    None => println!(
                        "  {} нода '{node_id}' не найдена — квест остался на месте",
                        "!".red()
                    ),
                }
            }
            None => println!("{}", "перехода нет".dimmed()),
        }
        Ok(())
    }

    fn print_state(&mut self) {
        let vars = self.engine.all_variables().clone();
        if vars.is_empty() {
            return;
        }
        // Итоговое состояние и так уходит в `emit_trace`, дублировать его в
        // событиях незачем.
        if self.quiet() {
            return;
        }
        println!("{}", "Переменные:".dimmed());
        let mut keys: Vec<&str> = vars.keys().map(|s| s.as_str()).collect();
        keys.sort();
        for k in keys {
            if k.starts_with("_internal") || k == "ID" || k == "LastID" {
                continue;
            }
            let v = &vars[k];
            let val_str = if v.is_string() {
                v.as_str().unwrap().to_string()
            } else if v.is_number() {
                v.as_f64()
                    .map(|f| {
                        if f.fract() == 0.0 {
                            format!("{:.0}", f)
                        } else {
                            format!("{f}")
                        }
                    })
                    .unwrap_or_else(|| v.to_string())
            } else if v.is_boolean() {
                v.as_bool().unwrap().to_string()
            } else {
                v.to_string()
            };
            println!("  {} = {}", k, val_str);
        }
        // Источники картинок, назначенные блоком «Сменить картинку»: без них
        // headless-проверка скриптов молчит о самом частом сценарии.
        if let Some(sources) = vars
            .get("_internal_item_sources")
            .and_then(Value::as_object)
            && !sources.is_empty()
        {
            println!("{}", "Источники айтемов (set_image):".dimmed());
            let mut ids: Vec<&String> = sources.keys().collect();
            ids.sort();
            for id in ids {
                let src = sources[id].as_str().unwrap_or("");
                println!("  {} = {}", id, src);
            }
        }
    }
}

fn main() {
    let cli = Cli::parse();
    let json = cli.json;
    let code = match run(cli) {
        Ok(code) => code,
        Err(err) => {
            if json {
                // Один объект на stdout: парсер не должен разбирать текст.
                println!(
                    "{}",
                    serde_json::to_string_pretty(&serde_json::json!({
                        "ok": false,
                        "error": {
                            "message": format!("{err}"),
                            "detail": err
                                .chain()
                                .skip(1)
                                .map(|e| e.to_string())
                                .collect::<Vec<_>>(),
                        }
                    }))
                    .unwrap()
                );
            } else {
                eprintln!("{}: {err}", "ошибка".red().bold());
                for cause in err.chain().skip(1) {
                    eprintln!("  {} {cause}", "причина:".dimmed());
                }
            }
            1
        }
    };
    if code != 0 {
        std::process::exit(code);
    }
}

fn run(cli: Cli) -> Result<i32> {
    let quest_cmd = cli.quest_id.as_deref();
    let root = cli.quest_root;
    let save_slot = cli.save_slot;
    let ctx = quest_cmds::Ctx {
        root: &root,
        quest_id: quest_cmd,
        json: cli.json,
    };

    let code = match cli.command {
        Command::Quest(cmd) => quest_cmds::run_quest_cmd(cmd, &ctx)?,
        Command::Reveal => {
            let quest_id =
                quest_cmd.ok_or_else(|| anyhow::anyhow!("--quest-id обязателен для reveal"))?;
            let mut session = if ctx.json {
                Session::tracing(&root, quest_id)?
            } else {
                Session::new(&root, quest_id)?
            };
            session.start(save_slot.as_deref())?;
            session.reveal_all()?;
            session.print_state();
            emit_trace(session);
            0
        }
        Command::Run { file } => {
            let quest_id =
                quest_cmd.ok_or_else(|| anyhow::anyhow!("--quest-id обязателен для run"))?;
            let mut session = if ctx.json {
                Session::tracing(&root, quest_id)?
            } else {
                Session::new(&root, quest_id)?
            };
            session.start(save_slot.as_deref())?;
            let reader: Box<dyn BufRead> = if let Some(path) = file {
                let f = std::fs::File::open(&path)
                    .with_context(|| format!("не могу открыть {path}"))?;
                Box::new(std::io::BufReader::new(f))
            } else {
                Box::new(std::io::BufReader::new(std::io::stdin()))
            };
            run_script(&mut session, reader)?;
            session.print_state();
            emit_trace(session);
            0
        }
        Command::Repl => {
            let quest_id =
                quest_cmd.ok_or_else(|| anyhow::anyhow!("--quest-id обязателен для repl"))?;
            let mut session = Session::new(&root, quest_id)?;
            session.start(save_slot.as_deref())?;
            repl(&mut session)?;
            0
        }
    };
    Ok(code)
}

/// В `--json` печатает трассу прогона: события по порядку + итоговые
/// переменные и таблицы. Это единственный способ проверить ветку скрипта без
/// отрисовки.
fn emit_trace(session: Session) {
    let Some(events) = session.trace else {
        return;
    };
    let snapshot = session.engine.current_state_snapshot();
    let tables: serde_json::Map<String, Value> = snapshot
        .tables
        .iter()
        .map(|(name, raw)| {
            (
                name.clone(),
                serde_json::from_str::<Value>(raw).unwrap_or(Value::Null),
            )
        })
        .collect();
    let variables: serde_json::Map<String, Value> = snapshot
        .variables
        .iter()
        .map(|(name, raw)| {
            (
                name.clone(),
                serde_json::from_str::<Value>(raw).unwrap_or(Value::Null),
            )
        })
        .collect();
    println!(
        "{}",
        serde_json::json!({
            "ok": true,
            "finalNodeId": snapshot.current_node_id,
            "events": events,
            "variables": variables,
            "tables": tables,
        })
    );
}

fn run_script(session: &mut Session, reader: impl BufRead) -> Result<()> {
    for (line_no, line) in reader.lines().enumerate() {
        let line = line?;
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }

        let (cmd, args) = trimmed
            .split_once(char::is_whitespace)
            .unwrap_or((trimmed, ""));
        let args = args.trim();

        match cmd {
            "reveal" | "r" => {
                session.reveal_all()?;
            }
            "press" | "p" => {
                session.press(args)?;
            }
            "state" | "s" => {
                session.print_state();
            }
            "load" | "l" => {
                let view = session
                    .engine
                    .load_node(args)
                    .with_context(|| format!("нода '{args}' не найдена"))?;
                println!("{} {}", "▶".green().bold(), view.title.bold());
                if let Some(t) = view.transition {
                    println!("  {} → {}", "↳".yellow(), t.yellow());
                }
            }
            "transition" | "t" => {
                let node_id = session
                    .engine
                    .resolve_target_node_id(args)
                    .context("не удалось разрешить переход")?;
                let view = session
                    .engine
                    .load_node(&node_id)
                    .with_context(|| format!("нода '{node_id}' не найдена"))?;
                println!("{} {}", "▶".green().bold(), view.title.bold());
                if let Some(t) = view.transition {
                    println!("  {} → {}", "↳".yellow(), t.yellow());
                }
            }
            unknown => {
                eprintln!(
                    "{}: неизвестная команда '{}' (reveal, press, state, load, transition)",
                    format!("строка {line_no}").red(),
                    unknown
                );
            }
        }
    }
    Ok(())
}

fn repl(session: &mut Session) -> Result<()> {
    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout();

    println!(
        "{}  {}",
        "mnd-cli".green().bold(),
        "reveal | press <id> | state | load <node> | transition <expr> | quit".dimmed()
    );

    loop {
        print!("{} ", ">".bold());
        stdout.flush()?;

        let mut line = String::new();
        if stdin.read_line(&mut line)? == 0 {
            break; // EOF
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        if trimmed == "quit" || trimmed == "exit" || trimmed == "q" {
            break;
        }

        let (cmd, args) = trimmed
            .split_once(char::is_whitespace)
            .unwrap_or((trimmed, ""));
        let args = args.trim();

        match cmd {
            "reveal" | "r" => {
                if let Err(e) = session.reveal_all() {
                    eprintln!("{} {e}", "ошибка:".red());
                }
            }
            "press" | "p" => {
                if let Err(e) = session.press(args) {
                    eprintln!("{} {e}", "ошибка:".red());
                }
            }
            "state" | "s" => {
                session.print_state();
            }
            "load" | "l" => match session.engine.load_node(args) {
                Some(view) => {
                    println!("{} {}", "▶".green().bold(), view.title.bold());
                    if let Some(t) = view.transition {
                        println!("  {} → {}", "↳".yellow(), t.yellow());
                    }
                }
                None => eprintln!("{} нода '{args}' не найдена", "ошибка:".red()),
            },
            other => {
                eprintln!("{} неизвестная команда '{other}'", "ошибка:".red());
            }
        }
    }
    Ok(())
}
