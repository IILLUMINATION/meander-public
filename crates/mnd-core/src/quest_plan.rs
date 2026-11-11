//! Декларативный план квеста: один JSON-документ описывает главы, ноды,
//! скрипты, таблицы и переменные, а ядро приводит квест к этому состоянию.
//!
//! Зачем отдельно от [`crate::quest_build::QuestBuilder`]: построчные команды
//! удобны человеку, который видит результат на экране, и неудобны генератору
//! (человеку-редактору тоже): нужно помнить uuid каждой ноды, соблюдать
//! порядок вызовов и повторять одну и ту же операцию после любой ошибки. План
//! принимает названия вместо uuid, разрешает ссылки вперёд (кнопка может
//! ссылаться на скрипт, объявленный ниже) и пишется одной транзакцией.
//!
//! Правила, на которых держится предсказуемость:
//! - объект ищется по `id`, иначе по названию (`title`/`name`); не найден —
//!   создаётся;
//! - `items` у ноды заменяют её содержимое целиком: повторное применение
//!   плана даёт ровно описанное состояние, а не дубли;
//! - неизвестное поле в плане — ошибка, а не молчаливый пропуск;
//! - всё, что не удалось разрешить, собирается списком до записи на диск.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use uuid::Uuid;

use crate::contracts::{FsScriptAssetStore, ScriptAssetStore};
use crate::executor::DynAssetStore;
use crate::models::QuestTable;
use crate::quest_build::BuildError;
use crate::quest_store::{FsQuestStore, StoreOp};
use crate::script_format;
use crate::validation::Diagnostic;

// ---------------------------------------------------------------------------
// Документ плана
// ---------------------------------------------------------------------------

/// План целиком. Все поля необязательны — пустой план ничего не меняет.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct ApplyPlan {
    /// Метаданные квеста и стартовая нода.
    #[serde(default)]
    pub quest: Option<PlanQuest>,
    #[serde(default)]
    pub chapters: Vec<PlanChapter>,
    #[serde(default)]
    pub nodes: Vec<PlanNode>,
    #[serde(default)]
    pub scripts: Vec<PlanScript>,
    #[serde(default)]
    pub tables: Vec<PlanTable>,
    #[serde(default)]
    pub variables: Vec<PlanVariable>,
    /// Что удалить (по ссылке — id, уникальному префиксу или названию).
    #[serde(default)]
    pub delete: Option<PlanDelete>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct PlanQuest {
    pub title: Option<String>,
    pub author: Option<String>,
    pub description: Option<String>,
    /// Стартовая нода: ссылка на ноду этого плана или существующую.
    #[serde(alias = "start_node")]
    pub start_node: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct PlanChapter {
    pub id: Option<String>,
    pub name: String,
    /// Масштаб камеры главы на канвасе.
    pub camera_scale: Option<f64>,
}

/// Нода в плане. Отсутствующие поля у существующей ноды не меняются.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct PlanNode {
    pub id: Option<String>,
    /// Название ноды. Для новой ноды обязательно, для существующей — по нему
    /// нода и находится, если `id` не задан.
    #[serde(default)]
    pub title: String,
    /// Глава: id или название.
    pub chapter: Option<String>,
    pub x: Option<f64>,
    pub y: Option<f64>,
    /// Сделать ноду стартовой.
    pub start: Option<bool>,
    /// Фоновая картинка: путь `res/…`, файл на диске или имя ресурса.
    #[serde(alias = "background_image")]
    pub background_image: Option<String>,
    /// Фоновая музыка: то же.
    #[serde(alias = "background_audio")]
    pub background_audio: Option<String>,
    #[serde(alias = "background_audio_volume")]
    pub background_audio_volume: Option<f64>,
    /// Скрипт, который запускается при входе в ноду (id или имя).
    pub script: Option<String>,
    /// Цвет карточки на канвасе (ARGB как в редакторе).
    pub color: Option<i64>,
    /// Таймер ноды в секундах; `timerNode` — куда вести по истечении.
    pub timer: Option<f64>,
    #[serde(alias = "timer_node")]
    pub timer_node: Option<String>,
    /// Содержимое ноды. Заданный список заменяет текущее содержимое целиком,
    /// поэтому повторный `apply` не плодит дубли.
    pub items: Option<Vec<Value>>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct PlanScript {
    pub id: Option<String>,
    #[serde(default)]
    pub name: String,
    /// `onPress` (по умолчанию), `onEnter`, `onAppear` или `onQuestStart`.
    pub event: Option<String>,
    /// Блоки внутри event-блока. Заданный список заменяет прежние блоки.
    pub blocks: Option<Vec<Value>>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct PlanTable {
    pub name: String,
    #[serde(default)]
    pub columns: Vec<String>,
    /// Строки как объекты «колонка → значение».
    #[serde(default)]
    pub rows: Vec<Value>,
    /// Имена строк (по порядку); пустая строка — доступа по имени нет.
    #[serde(default, alias = "row_names")]
    pub row_names: Vec<String>,
    /// Key-value данные, видимые скриптам.
    #[serde(default)]
    pub data: Option<Map<String, Value>>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct PlanVariable {
    pub name: String,
    /// Значение по умолчанию: число, строка, `true`/`false`, объект или null.
    #[serde(default)]
    pub default: Value,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct PlanDelete {
    #[serde(default)]
    pub nodes: Vec<String>,
    #[serde(default)]
    pub scripts: Vec<String>,
}

// ---------------------------------------------------------------------------
// Отчёт
// ---------------------------------------------------------------------------

/// Ошибка в самом плане: найдена до записи, с путём внутри документа.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanIssue {
    pub path: String,
    pub message: String,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ObjectRef {
    pub id: String,
    pub title: String,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Changes {
    pub chapters: Vec<ObjectRef>,
    pub nodes: Vec<ObjectRef>,
    pub scripts: Vec<ObjectRef>,
    pub tables: Vec<String>,
    pub variables: Vec<String>,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ApplyReport {
    pub ok: bool,
    pub applied: bool,
    pub dry_run: bool,
    pub quest_id: String,
    pub start_node_id: Option<String>,
    pub created: Changes,
    pub updated: Changes,
    pub deleted: Changes,
    /// Файлы квеста, которые изменены (относительно каталога квеста).
    pub files: Vec<String>,
    pub issues: Vec<PlanIssue>,
    pub diagnostics: Vec<Diagnostic>,
}

impl ApplyReport {
    fn error_count(&self) -> usize {
        self.diagnostics
            .iter()
            .filter(|d| matches!(d.severity, crate::validation::Severity::Error))
            .count()
    }
}

// ---------------------------------------------------------------------------
// Ссылки по названию
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy)]
enum RefKind {
    Node,
    Script,
    Chapter,
}

impl RefKind {
    fn noun(self) -> &'static str {
        match self {
            RefKind::Node => "нода",
            RefKind::Script => "скрипт",
            RefKind::Chapter => "глава",
        }
    }
}

/// Реестр «id ↔ название» по текущему квесту и всему, что добавляет план.
#[derive(Debug, Default)]
struct Registry {
    nodes: Vec<(String, String)>,
    scripts: Vec<(String, String)>,
    chapters: Vec<(String, String)>,
}

impl Registry {
    fn list(&self, kind: RefKind) -> &[(String, String)] {
        match kind {
            RefKind::Node => &self.nodes,
            RefKind::Script => &self.scripts,
            RefKind::Chapter => &self.chapters,
        }
    }

    fn list_mut(&mut self, kind: RefKind) -> &mut Vec<(String, String)> {
        match kind {
            RefKind::Node => &mut self.nodes,
            RefKind::Script => &mut self.scripts,
            RefKind::Chapter => &mut self.chapters,
        }
    }

    fn register(&mut self, kind: RefKind, id: &str, name: &str) {
        let list = self.list_mut(kind);
        if let Some(entry) = list.iter_mut().find(|(existing, _)| existing == id) {
            entry.1 = name.to_string();
        } else {
            list.push((id.to_string(), name.to_string()));
        }
    }

    fn rename(&mut self, kind: RefKind, id: &str, name: &str) {
        if let Some(entry) = self.list_mut(kind).iter_mut().find(|(e, _)| e == id) {
            entry.1 = name.to_string();
        }
    }

    /// Найти id по ссылке: точный id → уникальный префикс → точное название →
    /// название без учёта регистра.
    ///
    /// Человекочитаемые названия — основной путь для плана: генератор не
    /// должен жонглировать uuid, а uuid остаётся удобным для точечных правок.
    fn resolve(&self, kind: RefKind, raw: &str) -> Result<String, String> {
        let needle = raw.trim();
        if needle.is_empty() {
            return Err(format!("пустая ссылка на {}", kind.noun()));
        }
        let list = self.list(kind);
        let exact = list.iter().find(|(id, _)| id == needle);
        if let Some((id, _)) = exact {
            return Ok(id.clone());
        }
        if needle.len() >= 4 {
            let lower = needle.to_lowercase();
            let by_prefix: Vec<&(String, String)> = list
                .iter()
                .filter(|(id, _)| id.to_lowercase().starts_with(&lower))
                .collect();
            match by_prefix.len() {
                1 => return Ok(by_prefix[0].0.clone()),
                n if n > 1 => {
                    return Err(format!(
                        "ссылка «{needle}» подходит к нескольким {}: {}",
                        kind.noun(),
                        describe(&by_prefix)
                    ));
                }
                _ => {}
            }
        }
        let by_name: Vec<&(String, String)> =
            list.iter().filter(|(_, name)| name == needle).collect();
        match by_name.len() {
            1 => return Ok(by_name[0].0.clone()),
            n if n > 1 => {
                return Err(format!(
                    "название «{needle}» носят несколько {}: {} — укажите id",
                    kind.noun(),
                    describe(&by_name)
                ));
            }
            _ => {}
        }
        let lower = needle.to_lowercase();
        let by_lower: Vec<&(String, String)> = list
            .iter()
            .filter(|(_, name)| name.to_lowercase() == lower)
            .collect();
        match by_lower.len() {
            1 => Ok(by_lower[0].0.clone()),
            _ => {
                let known = list
                    .iter()
                    .take(12)
                    .map(|(_, name)| format!("«{name}»"))
                    .collect::<Vec<_>>();
                let hint = if known.is_empty() {
                    "список пуст".to_string()
                } else {
                    format!("известные: {}", known.join(", "))
                };
                Err(format!("{} «{needle}» не найдена ({hint})", kind.noun()))
            }
        }
    }
}

/// Публичный резолвер ссылок: id, уникальный префикс id или название.
///
/// Нужен командам CLI, которые принимают `--node`, `--script`, `--chapter`:
/// человек и генератор пишут «Старт», а не uuid.
pub struct RefResolver {
    reg: Registry,
}

impl RefResolver {
    pub fn new(
        nodes: Vec<(String, String)>,
        scripts: Vec<(String, String)>,
        chapters: Vec<(String, String)>,
    ) -> Self {
        Self {
            reg: Registry {
                nodes,
                scripts,
                chapters,
            },
        }
    }

    pub fn node(&self, raw: &str) -> Result<String, String> {
        self.reg.resolve(RefKind::Node, raw)
    }

    pub fn script(&self, raw: &str) -> Result<String, String> {
        // Ссылку вида `scripts/<id>.json` тоже принимаем: именно так она
        // хранится в JSON квеста, и её копируют из `quest show`.
        let trimmed = raw.trim();
        let stripped = trimmed
            .strip_prefix("scripts/")
            .or_else(|| trimmed.strip_prefix("_internal_scripts/"))
            .unwrap_or(trimmed);
        let bare = stripped.strip_suffix(".json").unwrap_or(stripped);
        self.reg.resolve(RefKind::Script, bare)
    }

    pub fn chapter(&self, raw: &str) -> Result<String, String> {
        self.reg.resolve(RefKind::Chapter, raw)
    }
}

fn describe(list: &[&(String, String)]) -> String {
    list.iter()
        .take(6)
        .map(|(id, name)| format!("«{name}» ({id})"))
        .collect::<Vec<_>>()
        .join(", ")
}

// ---------------------------------------------------------------------------
// Наложение изменений поверх реального квеста (для валидатора)
// ---------------------------------------------------------------------------

/// Хранилище «как будет после записи»: подменяет изменённые файлы, остальное
/// берёт с диска. Нужно, чтобы проверить план валидатором до записи.
pub struct OverlayStore {
    base: DynAssetStore,
    overrides: HashMap<String, Value>,
    virtual_files: HashSet<String>,
    deleted: HashSet<String>,
}

impl OverlayStore {
    pub fn new(
        base: DynAssetStore,
        overrides: HashMap<String, Value>,
        virtual_files: HashSet<String>,
        deleted: HashSet<String>,
    ) -> Self {
        Self {
            base,
            overrides,
            virtual_files,
            deleted,
        }
    }
}

impl ScriptAssetStore for OverlayStore {
    fn exists(&self, path: &str) -> bool {
        if self.deleted.contains(path) {
            return false;
        }
        self.overrides.contains_key(path)
            || self.virtual_files.contains(path)
            || self.base.exists(path)
    }

    fn read_json(&self, path: &str) -> Option<Value> {
        if self.deleted.contains(path) {
            return None;
        }
        self.overrides
            .get(path)
            .cloned()
            .or_else(|| self.base.read_json(path))
    }

    fn read_text(&self, path: &str) -> Option<String> {
        if self.deleted.contains(path) {
            return None;
        }
        self.base.read_text(path)
    }

    fn list_dir(&self, rel_dir: &str) -> Vec<String> {
        // Базовое хранилище отдаёт полные пути (`quests/<id>/scripts/x.json`),
        // поэтому и добавки кладём в том же виде.
        let prefix = format!("{}/", rel_dir.trim_end_matches('/'));
        let mut out: Vec<String> = self
            .base
            .list_dir(rel_dir)
            .into_iter()
            .filter(|path| !self.deleted.contains(path))
            .collect();
        for path in self.overrides.keys().chain(self.virtual_files.iter()) {
            if let Some(rest) = path.strip_prefix(&prefix)
                && !rest.contains('/')
                && !out.iter().any(|existing| existing == path)
            {
                out.push(path.clone());
            }
        }
        out.sort();
        out
    }
}

// ---------------------------------------------------------------------------
// Сборка
// ---------------------------------------------------------------------------

/// Пути внутри квеста — те же, что использует [`crate::quest_build::QuestBuilder`].
#[derive(Debug, Clone)]
pub(crate) struct Paths {
    pub dir: String,
}

impl Paths {
    pub fn config(&self) -> String {
        format!("{}/config.json", self.dir)
    }
    pub fn index(&self) -> String {
        format!("{}/nodes/index.json", self.dir)
    }
    pub fn node(&self, id: &str) -> String {
        format!("{}/nodes/{id}.json", self.dir)
    }
    pub fn script(&self, id: &str) -> String {
        format!("{}/scripts/{id}.json", self.dir)
    }
    pub fn scripts_dir(&self) -> String {
        format!("{}/scripts", self.dir)
    }
}

/// Результат сборки: файлы квеста в том виде, в каком они будут записаны.
pub(crate) struct PlanOutcome {
    pub report: ApplyReport,
    pub files: Vec<(String, Value)>,
    pub deletes: Vec<String>,
    /// Файлы ресурсов, которые надо скопировать в квест до записи.
    pub imports: Vec<(PathBuf, String)>,
    pub virtual_files: Vec<String>,
}

struct PlanCtx<'a> {
    store: &'a FsQuestStore,
    paths: &'a Paths,
    dry_run: bool,
    issues: Vec<PlanIssue>,
    imports: Vec<(PathBuf, String)>,
    virtual_files: Vec<String>,
    counter: usize,
}

impl PlanCtx<'_> {
    fn issue(&mut self, path: impl Into<String>, message: impl Into<String>) {
        self.issues.push(PlanIssue {
            path: path.into(),
            message: message.into(),
        });
    }

    /// Разрешить ссылку на ресурс: путь `res/…`, файл на диске или имя из
    /// библиотеки. Возвращает путь, который попадёт в JSON айтема или ноды.
    fn media(&mut self, raw: &str, fallback_kind: &str, path: &str) -> Option<String> {
        let raw = raw.trim();
        if raw.is_empty() {
            self.issue(path, "пустая ссылка на ресурс");
            return None;
        }
        if raw.starts_with("res/") {
            if self.dry_run || self.store.exists(&format!("{}/{}", self.paths.dir, raw)) {
                return Some(raw.to_string());
            }
            self.issue(
                path,
                format!("файла «{raw}» нет в квесте — скопируйте его или укажите путь к файлу"),
            );
            return None;
        }
        let candidate = Path::new(raw);
        if candidate.is_file() {
            let ext = candidate
                .extension()
                .and_then(|e| e.to_str())
                .unwrap_or("")
                .to_lowercase();
            let folder = match fallback_kind {
                "audio" => "audio",
                "video" => "videos",
                _ => "images",
            };
            self.counter += 1;
            let name = if ext.is_empty() {
                format!("pending-{}-{}", self.counter, Uuid::new_v4())
            } else {
                format!("{}.{ext}", Uuid::new_v4())
            };
            let rel = format!("res/{folder}/{name}");
            // Файл появится только после записи, но валидатор уже сейчас должен
            // видеть его на месте — иначе любой план с картинкой падал бы с
            // «файл не найден».
            self.virtual_files
                .push(format!("{}/{}", self.paths.dir, rel));
            if !self.dry_run {
                self.imports.push((candidate.to_path_buf(), rel.clone()));
            }
            return Some(rel);
        }
        // Имя из библиотеки ресурсов: metadata.json знает ключ-файл по имени.
        if let Some(found) = self.find_resource_by_name(raw) {
            return Some(found);
        }
        self.issue(
            path,
            format!(
                "ресурс «{raw}» не найден: нет файла с таким путём и нет ресурса с таким именем"
            ),
        );
        None
    }

    fn find_resource_by_name(&self, name: &str) -> Option<String> {
        let meta = self
            .store
            .read_json(&format!("{}/res/metadata.json", self.paths.dir))?;
        let obj = meta.as_object()?;
        for (key, entry) in obj {
            let entry_name = entry
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or_default();
            if entry_name != name {
                continue;
            }
            let ext = key.rsplit('.').next().unwrap_or("").to_lowercase();
            let folder = match ext.as_str() {
                "png" | "jpg" | "jpeg" | "webp" | "gif" | "svg" => "images",
                "mp3" | "ogg" | "wav" | "m4a" | "flac" => "audio",
                "mp4" | "webm" | "mov" => "videos",
                "ttf" | "otf" => "fonts",
                _ => "images",
            };
            return Some(format!("res/{folder}/{key}"));
        }
        None
    }
}

/// Собрать изменения квеста по плану, ничего не записывая.
pub(crate) fn build_plan(
    store: &FsQuestStore,
    quest_id: &str,
    plan: &ApplyPlan,
    dry_run: bool,
) -> Result<PlanOutcome, BuildError> {
    let paths = Paths {
        dir: format!("quests/{quest_id}"),
    };

    let mut config = store
        .read_json(&paths.config())
        .and_then(|v| v.as_object().cloned())
        .ok_or_else(|| BuildError::NotAQuest(paths.config()))?;
    let mut index = store
        .read_json(&paths.index())
        .and_then(|v| v.as_object().cloned())
        .ok_or_else(|| BuildError::UnsupportedLayout(format!("{} не объект", paths.index())))?;

    // Тела нод — в порядке индекса: этот порядок редактор показывает на канвасе.
    let mut node_order: Vec<String> = index
        .get("nodes")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|s| s.get("id").and_then(Value::as_str).map(str::to_string))
                .collect()
        })
        .unwrap_or_default();
    let mut node_bodies: BTreeMap<String, Map<String, Value>> = BTreeMap::new();
    for id in &node_order {
        if let Some(obj) = store
            .read_json(&paths.node(id))
            .and_then(|v| v.as_object().cloned())
        {
            node_bodies.insert(id.clone(), obj);
        }
    }

    let mut scripts: BTreeMap<String, Map<String, Value>> = BTreeMap::new();
    for file in store.list_files(&paths.scripts_dir(), Some("json")) {
        let id = file.trim_end_matches(".json").to_string();
        if let Some(obj) = store
            .read_json(&paths.script(&id))
            .and_then(|v| v.as_object().cloned())
        {
            scripts.insert(id, obj);
        }
    }

    let mut reg = Registry::default();
    for id in &node_order {
        if let Some(body) = node_bodies.get(id) {
            reg.register(
                RefKind::Node,
                id,
                body.get("title").and_then(Value::as_str).unwrap_or(""),
            );
        }
    }
    for (id, script) in &scripts {
        reg.register(
            RefKind::Script,
            id,
            script.get("name").and_then(Value::as_str).unwrap_or(""),
        );
    }
    if let Some(tags) = config.get("tags").and_then(Value::as_array) {
        for tag in tags {
            let id = tag.get("id").and_then(Value::as_str).unwrap_or_default();
            let name = tag.get("name").and_then(Value::as_str).unwrap_or_default();
            reg.register(RefKind::Chapter, id, name);
        }
    }

    let mut report = ApplyReport {
        quest_id: quest_id.to_string(),
        start_node_id: config
            .get("startNodeId")
            .and_then(Value::as_str)
            .map(str::to_string),
        ..Default::default()
    };
    let mut ctx = PlanCtx {
        store,
        paths: &paths,
        dry_run,
        issues: Vec::new(),
        imports: Vec::new(),
        virtual_files: Vec::new(),
        counter: 0,
    };

    // ── 1. Метаданные квеста ────────────────────────────────────────────
    if let Some(quest) = &plan.quest {
        if let Some(title) = &quest.title {
            if title.trim().is_empty() {
                ctx.issue("quest.title", "название квеста не может быть пустым");
            } else {
                config.insert("title".into(), json!(title));
            }
        }
        if let Some(author) = &quest.author {
            config.insert("author".into(), json!(author));
        }
        if let Some(description) = &quest.description {
            config.insert("description".into(), json!(description));
        }
    }

    // ── 2. Главы ────────────────────────────────────────────────────────
    let mut tags: Vec<Value> = config
        .get("tags")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    for (i, chapter) in plan.chapters.iter().enumerate() {
        let path = format!("chapters[{i}].name");
        if chapter.name.trim().is_empty() {
            ctx.issue(path, "название главы не может быть пустым");
            continue;
        }
        let existing = match &chapter.id {
            Some(id) => tags
                .iter()
                .position(|t| t.get("id").and_then(Value::as_str) == Some(id.as_str())),
            None => tags
                .iter()
                .position(|t| t.get("name").and_then(Value::as_str) == Some(chapter.name.trim())),
        };
        match existing {
            Some(pos) => {
                let id = tags[pos]
                    .get("id")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string();
                if let Some(obj) = tags[pos].as_object_mut() {
                    obj.insert("name".into(), json!(chapter.name.trim()));
                    if let Some(scale) = chapter.camera_scale
                        && let Some(camera) =
                            obj.get_mut("cameraState").and_then(Value::as_object_mut)
                    {
                        camera.insert("scale".into(), json!(scale));
                    }
                }
                reg.rename(RefKind::Chapter, &id, chapter.name.trim());
                report.updated.chapters.push(ObjectRef {
                    id,
                    title: chapter.name.clone(),
                });
            }
            None => {
                let id = chapter
                    .id
                    .clone()
                    .unwrap_or_else(|| Uuid::new_v4().to_string());
                let mut camera = json!({"offsetX": 0.0, "offsetY": 0.0, "scale": 1.0});
                if let Some(scale) = chapter.camera_scale
                    && let Some(obj) = camera.as_object_mut()
                {
                    obj.insert("scale".into(), json!(scale));
                }
                tags.push(json!({
                    "id": id,
                    "name": chapter.name.trim(),
                    "cameraState": camera,
                }));
                reg.register(RefKind::Chapter, &id, chapter.name.trim());
                report.created.chapters.push(ObjectRef {
                    id,
                    title: chapter.name.clone(),
                });
            }
        }
    }
    // Главы живут в config.tags; без записи обратно новые главы есть только
    // в реестре и валидатор считает привязку ноды битой.
    config.insert("tags".into(), Value::Array(tags));

    // ── 3. Ноды: сначала распределяем id, чтобы работали ссылки вперёд ───
    struct NodeSlot {
        index: usize,
        id: String,
        is_new: bool,
    }
    let mut slots: Vec<NodeSlot> = Vec::new();
    for (i, node) in plan.nodes.iter().enumerate() {
        let path = format!("nodes[{i}]");
        let title = node.title.trim();
        if title.is_empty() && node.id.is_none() {
            ctx.issue(
                format!("{path}.title"),
                "у ноды нужно название (или id существующей ноды)",
            );
            continue;
        }
        let found = match &node.id {
            Some(id) => node_bodies.contains_key(id).then(|| id.clone()),
            None => {
                let matches: Vec<String> = reg
                    .nodes
                    .iter()
                    .filter(|(_, name)| name == title)
                    .map(|(id, _)| id.clone())
                    .collect();
                match matches.len() {
                    1 => Some(matches[0].clone()),
                    0 => None,
                    _ => {
                        ctx.issue(
                            format!("{path}.title"),
                            format!(
                                "название «{title}» носят несколько нод ({}): укажите id",
                                matches.join(", ")
                            ),
                        );
                        continue;
                    }
                }
            }
        };
        match found {
            Some(id) => {
                if !title.is_empty() {
                    reg.rename(RefKind::Node, &id, title);
                }
                slots.push(NodeSlot {
                    index: i,
                    id,
                    is_new: false,
                });
            }
            None => {
                let id = node
                    .id
                    .clone()
                    .unwrap_or_else(|| Uuid::new_v4().to_string());
                reg.register(RefKind::Node, &id, title);
                slots.push(NodeSlot {
                    index: i,
                    id,
                    is_new: true,
                });
            }
        }
    }
    // Одноимённые ноды в самом плане — почти наверняка ошибка генератора.
    {
        let mut seen: HashMap<&str, usize> = HashMap::new();
        for slot in &slots {
            let node = &plan.nodes[slot.index];
            if node.title.trim().is_empty() {
                continue;
            }
            if let Some(prev) = seen.insert(node.title.trim(), slot.index) {
                ctx.issue(
                    format!("nodes[{}.title", slot.index),
                    format!(
                        "название «{}» уже занято нодой nodes[{prev}] этого плана",
                        node.title.trim()
                    ),
                );
            }
        }
    }

    // ── 4. Скрипты: так же распределяем id ─────────────────────────────
    struct ScriptSlot {
        index: usize,
        id: String,
        is_new: bool,
    }
    let mut script_slots: Vec<ScriptSlot> = Vec::new();
    for (i, script) in plan.scripts.iter().enumerate() {
        let path = format!("scripts[{i}]");
        let name = script.name.trim();
        if name.is_empty() && script.id.is_none() {
            ctx.issue(
                format!("{path}.name"),
                "у скрипта нужно имя (или id существующего скрипта)",
            );
            continue;
        }
        let found = match &script.id {
            Some(id) => scripts.contains_key(id).then(|| id.clone()),
            None => {
                let matches: Vec<String> = reg
                    .scripts
                    .iter()
                    .filter(|(_, script_name)| script_name == name)
                    .map(|(id, _)| id.clone())
                    .collect();
                match matches.len() {
                    1 => Some(matches[0].clone()),
                    0 => None,
                    _ => {
                        ctx.issue(
                            format!("{path}.name"),
                            format!(
                                "имя «{name}» носят несколько скриптов ({}): укажите id",
                                matches.join(", ")
                            ),
                        );
                        continue;
                    }
                }
            }
        };
        match found {
            Some(id) => {
                if !name.is_empty() {
                    reg.rename(RefKind::Script, &id, name);
                }
                script_slots.push(ScriptSlot {
                    index: i,
                    id,
                    is_new: false,
                });
            }
            None => {
                let id = script
                    .id
                    .clone()
                    .unwrap_or_else(|| Uuid::new_v4().to_string());
                reg.register(RefKind::Script, &id, name);
                script_slots.push(ScriptSlot {
                    index: i,
                    id,
                    is_new: true,
                });
            }
        }
    }

    // ── 5. Тела нод ─────────────────────────────────────────────────────
    let mut new_start: Option<String> = None;
    for slot in &slots {
        let node = &plan.nodes[slot.index];
        let path = format!("nodes[{}]", slot.index);
        let mut body = node_bodies.remove(&slot.id).unwrap_or_else(|| {
            let mut map = Map::new();
            map.insert("id".into(), json!(slot.id));
            map.insert("backgroundAudioVolume".into(), json!(1.0));
            map.insert("content".into(), json!({"items": []}));
            map
        });

        if !node.title.trim().is_empty() {
            body.insert("title".into(), json!(node.title.trim()));
        }
        if let Some(chapter) = &node.chapter {
            if let Some(id) = resolve_with(
                &reg,
                &mut ctx,
                RefKind::Chapter,
                chapter,
                &format!("{path}.chapter"),
            ) {
                body.insert("chapterId".into(), json!(id));
            }
        } else if !body.contains_key("chapterId")
            && let Some((first, _)) = reg.chapters.first()
        {
            body.insert("chapterId".into(), json!(first));
        }
        if let Some(x) = node.x {
            body.insert("x".into(), json!(x));
        } else if !body.contains_key("x") {
            body.insert("x".into(), json!(0.0));
        }
        if let Some(y) = node.y {
            body.insert("y".into(), json!(y));
        } else if !body.contains_key("y") {
            body.insert("y".into(), json!(0.0));
        }
        if let Some(color) = node.color.or_else(|| {
            body.get("color")
                .and_then(Value::as_i64)
                .or(Some(4_280_492_835))
        }) {
            body.insert("color".into(), json!(color));
        }
        if let Some(image) = &node.background_image
            && let Some(rel) = ctx.media(image, "image", &format!("{path}.backgroundImage"))
        {
            body.insert("backgroundAssetId".into(), json!(rel));
        }
        if let Some(audio) = &node.background_audio
            && let Some(rel) = ctx.media(audio, "audio", &format!("{path}.backgroundAudio"))
        {
            body.insert("backgroundAudioId".into(), json!(rel));
        }
        if let Some(volume) = node.background_audio_volume {
            body.insert("backgroundAudioVolume".into(), json!(volume));
        }
        if let Some(script) = &node.script
            && let Some(id) = resolve_with(
                &reg,
                &mut ctx,
                RefKind::Script,
                script,
                &format!("{path}.script"),
            )
        {
            body.insert("scriptAssetId".into(), json!(script_ref(&id)));
        }
        if let Some(timer) = node.timer {
            body.insert("timerDuration".into(), json!(timer));
        }
        if let Some(target) = &node.timer_node
            && let Some(id) = resolve_with(
                &reg,
                &mut ctx,
                RefKind::Node,
                target,
                &format!("{path}.timerNode"),
            )
        {
            body.insert("defaultActionNodeId".into(), json!(id));
        }

        if let Some(items) = &node.items {
            let mut built = Vec::with_capacity(items.len());
            for (k, item) in items.iter().enumerate() {
                if let Some(value) = build_item(item, &format!("{path}.items[{k}]"), &mut ctx, &reg)
                {
                    built.push(value);
                }
            }
            body.insert("content".into(), json!({"items": built}));
        } else if !body.contains_key("content") {
            body.insert("content".into(), json!({"items": []}));
        }

        if node.start == Some(true) {
            new_start = Some(slot.id.clone());
        }

        if slot.is_new {
            node_order.push(slot.id.clone());
            report.created.nodes.push(ObjectRef {
                id: slot.id.clone(),
                title: node.title.clone(),
            });
        } else {
            report.updated.nodes.push(ObjectRef {
                id: slot.id.clone(),
                title: node.title.clone(),
            });
        }
        node_bodies.insert(slot.id.clone(), body);
    }

    // ── 6. Скрипты ──────────────────────────────────────────────────────
    for slot in &script_slots {
        let script = &plan.scripts[slot.index];
        let path = format!("scripts[{}]", slot.index);
        let mut body = scripts.remove(&slot.id).unwrap_or_else(|| {
            json!({
                "id": slot.id,
                "name": script.name,
                "blocks": [],
            })
            .as_object()
            .cloned()
            .unwrap_or_default()
        });
        if !script.name.trim().is_empty() {
            body.insert("name".into(), json!(script.name.trim()));
        }
        let event_type = match script.event.as_deref() {
            None => None,
            Some(raw) => match normalize_event(raw) {
                Some(t) => Some(t),
                None => {
                    ctx.issue(
                        format!("{path}.event"),
                        format!(
                            "неизвестное событие «{raw}»: onPress|onEnter|onAppear|onQuestStart"
                        ),
                    );
                    None
                }
            },
        };
        let event_type = event_type.unwrap_or_else(|| "onPress".to_string());

        if let Some(blocks) = &script.blocks {
            let mut resolved = Vec::with_capacity(blocks.len());
            for (k, block) in blocks.iter().enumerate() {
                if let Some(value) = rewrite_block(
                    block,
                    &format!("{path}.blocks[{k}]"),
                    &mut ctx,
                    &reg,
                    &node_bodies,
                ) {
                    resolved.push(value);
                }
            }
            body.insert(
                "blocks".into(),
                json!([{
                    "type": "event",
                    "eventType": event_type,
                    "id": Uuid::new_v4().to_string(),
                    "collapsed": false,
                    "children": resolved,
                }]),
            );
        } else if !body.contains_key("blocks") {
            body.insert(
                "blocks".into(),
                json!([{
                    "type": "event",
                    "eventType": event_type,
                    "id": Uuid::new_v4().to_string(),
                    "collapsed": false,
                    "children": [],
                }]),
            );
        }

        let script_value = Value::Object(body.clone());
        if let Value::Object(obj) = &script_value {
            let issues = script_format::validate_script(obj);
            for issue in issues
                .into_iter()
                .filter(|i| matches!(i.severity, script_format::Severity::Error))
            {
                ctx.issue(format!("{path}.blocks.{}", issue.path), issue.message);
            }
        }

        if slot.is_new {
            report.created.scripts.push(ObjectRef {
                id: slot.id.clone(),
                title: script.name.clone(),
            });
        } else {
            report.updated.scripts.push(ObjectRef {
                id: slot.id.clone(),
                title: script.name.clone(),
            });
        }
        scripts.insert(slot.id.clone(), body);
    }

    // ── 7. Таблицы и переменные ─────────────────────────────────────────
    let mut tables: Vec<Value> = config
        .get("tables")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    for (i, table) in plan.tables.iter().enumerate() {
        let path = format!("tables[{i}]");
        if table.name.trim().is_empty() {
            ctx.issue(format!("{path}.name"), "у таблицы должно быть имя");
            continue;
        }
        if table.columns.is_empty() {
            ctx.issue(
                format!("{path}.columns"),
                "таблица должна иметь хотя бы одну колонку",
            );
            continue;
        }
        if !table.row_names.is_empty() && table.row_names.len() != table.rows.len() {
            ctx.issue(
                format!("{path}.rowNames"),
                format!(
                    "имён строк {} , а строк {} — списки должны совпадать",
                    table.row_names.len(),
                    table.rows.len()
                ),
            );
            continue;
        }
        let mut rows = Vec::with_capacity(table.rows.len());
        for (k, row) in table.rows.iter().enumerate() {
            match row {
                Value::Object(obj) => rows.push(Value::Object(obj.clone())),
                Value::Array(cells) => {
                    // Допускаем и позиционную запись строки: [значение1, …].
                    if cells.len() > table.columns.len() {
                        ctx.issue(
                            format!("{path}.rows[{k}]"),
                            format!(
                                "в строке {} значений, а колонок {}",
                                cells.len(),
                                table.columns.len()
                            ),
                        );
                        continue;
                    }
                    let mut obj = Map::new();
                    for (c, value) in cells.iter().enumerate() {
                        obj.insert(table.columns[c].clone(), value.clone());
                    }
                    rows.push(Value::Object(obj));
                }
                other => ctx.issue(
                    format!("{path}.rows[{k}]"),
                    format!("строка должна быть объектом или массивом, а не {other}"),
                ),
            }
        }
        let mut model = QuestTable::from_json(&json!({
            "name": table.name.trim(),
            "columns": table.columns,
            "rows": rows,
            "rowNames": table.row_names,
            "data": table.data.clone().unwrap_or_default(),
        }));
        model.data = table.data.clone().unwrap_or_default();
        let value = model.to_json();
        tables.retain(|t| t.get("name").and_then(Value::as_str) != Some(table.name.trim()));
        tables.push(value);
        report.updated.tables.push(table.name.clone());
    }
    config.insert("tables".into(), Value::Array(tables));

    let mut variables: Vec<Value> = config
        .get("variables")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    for (i, variable) in plan.variables.iter().enumerate() {
        let name = variable.name.trim();
        if name.is_empty() {
            ctx.issue(
                format!("variables[{i}].name"),
                "у переменной должно быть имя",
            );
            continue;
        }
        variables.retain(|v| v.get("name").and_then(Value::as_str) != Some(name));
        variables.push(json!({"name": name, "defaultValue": variable.default}));
        report.updated.variables.push(name.to_string());
    }
    config.insert("variables".into(), Value::Array(variables));

    // ── 8. Стартовая нода ───────────────────────────────────────────────
    let start_ref = plan
        .quest
        .as_ref()
        .and_then(|q| q.start_node.clone())
        .or(new_start);
    if let Some(start) = start_ref
        && let Some(id) = resolve_with(&reg, &mut ctx, RefKind::Node, &start, "quest.startNode")
    {
        config.insert("startNodeId".into(), json!(id));
        report.start_node_id = Some(id);
    }

    // ── 9. Удаления ─────────────────────────────────────────────────────
    let mut deletes: Vec<String> = Vec::new();
    let mut removed_nodes: HashSet<String> = HashSet::new();
    let mut removed_scripts: HashSet<String> = HashSet::new();
    if let Some(delete) = &plan.delete {
        for (i, raw) in delete.nodes.iter().enumerate() {
            if let Some(id) = resolve_with(
                &reg,
                &mut ctx,
                RefKind::Node,
                raw,
                &format!("delete.nodes[{i}]"),
            ) {
                if config
                    .get("startNodeId")
                    .and_then(Value::as_str)
                    .is_some_and(|s| s == id)
                {
                    ctx.issue(
                        format!("delete.nodes[{i}]"),
                        "нельзя удалить стартовую ноду — сначала назначьте другую",
                    );
                    continue;
                }
                removed_nodes.insert(id);
            }
        }
        for (i, raw) in delete.scripts.iter().enumerate() {
            if let Some(id) = resolve_with(
                &reg,
                &mut ctx,
                RefKind::Script,
                raw,
                &format!("delete.scripts[{i}]"),
            ) {
                removed_scripts.insert(id);
            }
        }
    }
    for id in &removed_nodes {
        node_bodies.remove(id);
        node_order.retain(|n| n != id);
        deletes.push(paths.node(id));
        report.deleted.nodes.push(ObjectRef {
            id: id.clone(),
            title: String::new(),
        });
    }
    for id in &removed_scripts {
        scripts.remove(id);
        deletes.push(paths.script(id));
        report.deleted.scripts.push(ObjectRef {
            id: id.clone(),
            title: String::new(),
        });
    }

    if !ctx.issues.is_empty() {
        report.issues = ctx.issues;
        report.ok = false;
        return Ok(PlanOutcome {
            report,
            files: Vec::new(),
            deletes: Vec::new(),
            imports: Vec::new(),
            virtual_files: Vec::new(),
        });
    }

    // ── 10. Файлы ───────────────────────────────────────────────────────
    config.insert("updated".into(), json!(iso8601_now()));
    config.insert("lastEditedAt".into(), json!(iso8601_now()));

    // Индекс: сохраняем служебные поля (группы, комментарии, рёбра, превью).
    let old_summaries: HashMap<String, Value> = index
        .get("nodes")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|s| {
                    s.get("id")
                        .and_then(Value::as_str)
                        .map(|id| (id.to_string(), s.clone()))
                })
                .collect()
        })
        .unwrap_or_default();
    let summaries: Vec<Value> = node_order
        .iter()
        .filter_map(|id| node_bodies.get(id))
        .map(|body| {
            let mut summary = old_summaries
                .get(body.get("id").and_then(Value::as_str).unwrap_or_default())
                .cloned()
                .unwrap_or_else(|| Value::Object(Map::new()));
            if let Some(obj) = summary.as_object_mut() {
                obj.remove("content");
                for (key, value) in body {
                    if key == "content" {
                        continue;
                    }
                    obj.insert(key.clone(), value.clone());
                }
                obj.insert("type".into(), json!("node"));
            }
            summary
        })
        .collect();
    index.insert("nodes".into(), Value::Array(summaries));
    index.insert("format_version".into(), json!(2));
    index
        .entry("groups".to_string())
        .or_insert_with(|| Value::Array(vec![]));
    index
        .entry("comments".to_string())
        .or_insert_with(|| Value::Array(vec![]));
    index
        .entry("edges".to_string())
        .or_insert_with(|| Value::Array(vec![]));

    let mut files: Vec<(String, Value)> = Vec::new();
    files.push((paths.config(), Value::Object(config)));
    files.push((paths.index(), Value::Object(index)));
    for (id, body) in &node_bodies {
        files.push((paths.node(id), Value::Object(body.clone())));
    }
    for (id, script) in &scripts {
        files.push((paths.script(id), Value::Object(script.clone())));
    }

    report.files = files
        .iter()
        .map(|(p, _)| rel_to_quest(&paths.dir, p))
        .collect();
    report.ok = true;
    Ok(PlanOutcome {
        report,
        files,
        deletes,
        imports: ctx.imports,
        virtual_files: ctx.virtual_files,
    })
}

fn rel_to_quest(dir: &str, path: &str) -> String {
    path.strip_prefix(&format!("{dir}/"))
        .unwrap_or(path)
        .to_string()
}

/// Канонический вид ссылки на скрипт в JSON квеста — путь файла, а не голый
/// uuid: так его читает и редактор, и валидатор, и экспорт.
fn script_ref(script_id: &str) -> String {
    format!("scripts/{script_id}.json")
}

/// Разрешить ссылку через реестр, записав ошибку в контекст.
fn resolve_with(
    reg: &Registry,
    ctx: &mut PlanCtx<'_>,
    kind: RefKind,
    raw: &str,
    path: &str,
) -> Option<String> {
    match reg.resolve(kind, raw) {
        Ok(id) => Some(id),
        Err(message) => {
            ctx.issue(path, message);
            None
        }
    }
}

fn normalize_event(raw: &str) -> Option<String> {
    Some(
        match raw.trim() {
            "onPress" | "press" => "onPress",
            "onEnter" | "onNodeEnter" => "onNodeEnter",
            "onAppear" | "onContentAppear" => "onContentAppear",
            "onQuestStart" | "questStart" => "onQuestStart",
            _ => return None,
        }
        .to_string(),
    )
}

// ---------------------------------------------------------------------------
// Айтемы и блоки
// ---------------------------------------------------------------------------

/// Собрать айтем из JSON плана.
///
/// Поля пишутся как в самом квесте (`text`, `resourcePath`, `scriptAssetId`),
/// плюс два сокращения, которые избавляют генератор от copy-paste путей:
/// `"image": "<файл|res/…|имя>"` и `"script": "<id или имя>"`.
fn build_item(raw: &Value, path: &str, ctx: &mut PlanCtx<'_>, reg: &Registry) -> Option<Value> {
    let obj = match raw {
        Value::Object(obj) => obj.clone(),
        other => {
            ctx.issue(path, format!("айтем должен быть объектом, а не {other}"));
            return None;
        }
    };
    let kind = obj
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or("text")
        .to_string();
    let id = obj
        .get("id")
        .and_then(Value::as_str)
        .map(str::to_string)
        .unwrap_or_else(|| Uuid::new_v4().to_string());

    let mut item = default_item_map(&id, &kind);
    for (key, value) in &obj {
        if matches!(
            key.as_str(),
            "image" | "script" | "audio" | "children" | "id"
        ) {
            continue;
        }
        item.insert(key.clone(), value.clone());
    }
    if let Some(image) = obj.get("image").and_then(Value::as_str)
        && let Some(rel) = ctx.media(image, "image", &format!("{path}.image"))
    {
        item.insert("resourcePath".into(), json!(rel));
    }
    if let Some(audio) = obj.get("audio").and_then(Value::as_str)
        && let Some(rel) = ctx.media(audio, "audio", &format!("{path}.audio"))
    {
        item.insert("resourcePath".into(), json!(rel));
    }
    if let Some(script) = obj.get("script").and_then(Value::as_str) {
        match reg.resolve(RefKind::Script, script) {
            Ok(script_id) => {
                // Кнопка/поле ввода исполняют скрипт из behaviours; нажатие —
                // у всех типов, кроме input (там отправка — onSubmit).
                let event = if kind == "input" {
                    "onSubmit"
                } else {
                    "onPress"
                };
                crate::quest_build::set_item_trigger(&mut item, event, &script_ref(&script_id));
            }
            Err(message) => ctx.issue(format!("{path}.script"), message),
        }
    }
    if let Some(children) = obj.get("children") {
        match children {
            Value::Array(list) => {
                let mut built = Vec::with_capacity(list.len());
                for (k, child) in list.iter().enumerate() {
                    if let Some(value) =
                        build_item(child, &format!("{path}.children[{k}]"), ctx, reg)
                    {
                        built.push(value);
                    }
                }
                item.insert("children".into(), Value::Array(built));
            }
            other => ctx.issue(
                format!("{path}.children"),
                format!("children должен быть массивом, а не {other}"),
            ),
        }
    } else if matches!(kind.as_str(), "row" | "stack") {
        item.insert("children".into(), Value::Array(vec![]));
    }
    Some(Value::Object(item))
}

/// Базовые поля айтема — те же, что ставит редактор, чтобы превью и плеер
/// не зависели от отсутствующих ключей.
fn default_item_map(id: &str, kind: &str) -> Map<String, Value> {
    let mut map = Map::new();
    map.insert("id".into(), Value::String(id.to_string()));
    map.insert("type".into(), Value::String(kind.to_string()));
    map.insert("flex".into(), json!(1));
    map.insert("animateIn".into(), json!(true));
    map.insert("isHidden".into(), json!(false));
    map.insert("isIncoming".into(), json!(true));
    map.insert("locked".into(), json!(false));
    map.insert("rowTextAlignment".into(), json!("center"));
    map.insert("textFit".into(), json!("auto"));
    map.insert("volume".into(), json!(1.0));
    map.insert("wrapText".into(), json!(true));
    map.insert("crossAxisAlignment".into(), json!("center"));
    if matches!(kind, "text" | "button" | "input") {
        map.insert("text".into(), json!(""));
    }
    map
}

/// Переписать блок: подставить id вместо названий и развернуть сокращения.
fn rewrite_block(
    raw: &Value,
    path: &str,
    ctx: &mut PlanCtx<'_>,
    reg: &Registry,
    nodes: &BTreeMap<String, Map<String, Value>>,
) -> Option<Value> {
    let obj = match raw {
        Value::Object(obj) => obj.clone(),
        other => {
            ctx.issue(path, format!("блок должен быть объектом, а не {other}"));
            return None;
        }
    };

    // Сокращения: {"goto": "Нода"} и {"call": "Скрипт"}.
    if obj.len() == 1 {
        if let Some(target) = obj.get("goto").and_then(Value::as_str) {
            let id = resolve_with(reg, ctx, RefKind::Node, target, &format!("{path}.goto"))?;
            return Some(json!({"type": "go_to_node", "node_id": id}));
        }
        if let Some(target) = obj.get("call").and_then(Value::as_str) {
            let id = resolve_with(reg, ctx, RefKind::Script, target, &format!("{path}.call"))?;
            return Some(json!({"type": "call_script", "script_id": id}));
        }
    }

    let mut block = obj.clone();
    let block_type = block
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    if block_type.is_empty() {
        ctx.issue(format!("{path}.type"), "у блока нет поля type");
        return None;
    }

    match block_type.as_str() {
        "go_to_node" => {
            let target = block
                .get("node_id")
                .or_else(|| block.get("nodeId"))
                .and_then(Value::as_str)
                .map(str::to_string);
            match target {
                Some(target) => {
                    let id =
                        resolve_with(reg, ctx, RefKind::Node, &target, &format!("{path}.node_id"))?;
                    block.insert("node_id".into(), json!(id));
                }
                None => ctx.issue(format!("{path}.node_id"), "go_to_node без целевой ноды"),
            }
        }
        "call_script" => {
            let target = block
                .get("script_id")
                .or_else(|| block.get("scriptId"))
                .and_then(Value::as_str)
                .map(str::to_string);
            match target {
                Some(target) => {
                    let id = resolve_with(
                        reg,
                        ctx,
                        RefKind::Script,
                        &target,
                        &format!("{path}.script_id"),
                    )?;
                    block.insert("script_id".into(), json!(script_ref(&id)));
                }
                None => ctx.issue(format!("{path}.script_id"), "call_script без скрипта"),
            }
        }
        "set_image" => {
            if let Some(item_id) = block.get("item_id").and_then(Value::as_str) {
                let known = nodes.values().any(|node| {
                    node.get("content")
                        .and_then(|c| c.get("items"))
                        .and_then(Value::as_array)
                        .is_some_and(|items| item_exists(items, item_id))
                });
                if !known {
                    ctx.issue(
                        format!("{path}.item_id"),
                        format!("айтема «{item_id}» нет ни в одной ноде квеста"),
                    );
                }
            } else {
                ctx.issue(format!("{path}.item_id"), "set_image без item_id");
            }
            if let Some(source) = block
                .get("source")
                .and_then(Value::as_str)
                .map(str::to_string)
                && let Some(rel) = ctx.media(&source, "image", &format!("{path}.source"))
            {
                block.insert("source".into(), json!(rel));
            }
        }
        _ => {}
    }

    // Вложенные блоки: event.children, condition.then/else, циклы.
    for key in ["children", "then_blocks", "else_blocks", "blocks"] {
        let Some(value) = block.get(key).cloned() else {
            continue;
        };
        if let Value::Array(list) = value {
            let mut built = Vec::with_capacity(list.len());
            for (k, child) in list.iter().enumerate() {
                if let Some(value) =
                    rewrite_block(child, &format!("{path}.{key}[{k}]"), ctx, reg, nodes)
                {
                    built.push(value);
                }
            }
            block.insert(key.to_string(), Value::Array(built));
        }
    }
    Some(Value::Object(block))
}

fn item_exists(items: &[Value], item_id: &str) -> bool {
    items.iter().any(|item| {
        item.get("id").and_then(Value::as_str) == Some(item_id)
            || item
                .get("children")
                .and_then(Value::as_array)
                .is_some_and(|children| item_exists(children, item_id))
    })
}

fn iso8601_now() -> String {
    crate::quest_build::iso8601_now()
}

/// Прочитать план из JSON-значения.
pub fn parse_plan(value: &Value) -> Result<ApplyPlan, BuildError> {
    serde_json::from_value(value.clone())
        .map_err(|e| BuildError::Invalid(format!("план не разобран: {e}")))
}

/// Файлы квеста, созданные копированием (ресурсы), — для отчёта.
pub(crate) fn import_resources(
    store: &FsQuestStore,
    quest_id: &str,
    imports: &[(PathBuf, String)],
) -> Result<Vec<String>, BuildError> {
    let mut done = Vec::new();
    for (source, rel) in imports {
        let abs = format!("quests/{quest_id}/{rel}");
        let target = store
            .resolve(&abs)
            .map_err(|e| BuildError::Io(e.to_string()))?;
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| BuildError::Io(format!("mkdir {}: {e}", parent.display())))?;
        }
        std::fs::copy(source, &target).map_err(|e| {
            BuildError::Io(format!(
                "copy {} -> {}: {e}",
                source.display(),
                target.display()
            ))
        })?;
        let file_name = rel.rsplit('/').next().unwrap_or(rel).to_string();
        store
            .metadata_mutate(
                quest_id,
                &[crate::quest_store::MetaMutation::Set {
                    key: file_name.clone(),
                    value: json!({
                        "folder": "/",
                        "name": source
                            .file_stem()
                            .and_then(|s| s.to_str())
                            .unwrap_or(&file_name),
                        "resourceId": Uuid::new_v4().to_string(),
                    }),
                }],
            )
            .map_err(|e| BuildError::Io(e.to_string()))?;
        done.push(file_name);
    }
    Ok(done)
}

/// Применить готовые файлы плана к диску.
pub(crate) fn write_outcome(
    store: &FsQuestStore,
    quest_id: &str,
    outcome: &PlanOutcome,
) -> Result<(), BuildError> {
    let mut ops: Vec<StoreOp> = outcome
        .files
        .iter()
        .map(|(rel, value)| StoreOp::WriteJson {
            rel: rel.clone(),
            value: value.clone(),
        })
        .collect();
    for rel in &outcome.deletes {
        ops.push(StoreOp::Remove { rel: rel.clone() });
    }
    if !outcome.imports.is_empty() {
        import_resources(store, quest_id, &outcome.imports)?;
    }
    store
        .transact(&ops)
        .map_err(|e| BuildError::Io(e.to_string()))?;
    Ok(())
}

/// Проверить план валидатором до записи: подменить изменённые файлы и
/// прогнать анализ по получившемуся состоянию.
pub(crate) fn validate_outcome(
    root: &Path,
    quest_id: &str,
    outcome: &PlanOutcome,
) -> crate::validation::ValidationReport {
    let base: DynAssetStore = std::sync::Arc::new(FsScriptAssetStore::new(root.to_path_buf()));
    let overrides: HashMap<String, Value> = outcome.files.iter().cloned().collect();
    let deleted: HashSet<String> = outcome.deletes.iter().cloned().collect();
    let virtual_files: HashSet<String> = outcome.virtual_files.iter().cloned().collect();
    let store: DynAssetStore =
        std::sync::Arc::new(OverlayStore::new(base, overrides, virtual_files, deleted));
    crate::validation::analyze_quest_with_store(quest_id, store)
}

/// Ошибок в отчёте (используется CLI для кода возврата).
pub fn has_errors(report: &ApplyReport) -> bool {
    report.error_count() > 0 || !report.issues.is_empty()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::quest_build::{ApplyOptions, QuestBuilder};
    use crate::validation::analyze_quest;

    fn new_quest() -> (PathBuf, QuestBuilder) {
        let root = tempfile::tempdir().unwrap().keep();
        let builder =
            QuestBuilder::create("q1", &root, "Тест", Some("Автор"), Some("Глава 1")).unwrap();
        (root, builder)
    }

    fn apply(builder: &QuestBuilder, plan: Value) -> ApplyReport {
        builder
            .apply(&plan, &ApplyOptions::default())
            .expect("план должен применяться")
    }

    fn plan_text() -> Value {
        json!({
            "quest": {"startNode": "Старт"},
            "chapters": [{"name": "Пролог"}, {"name": "Эпилог"}],
            "nodes": [
                {
                    "title": "Старт",
                    "chapter": "Пролог",
                    "items": [
                        {"type": "text", "text": "Ты просыпаешься."},
                        {"type": "button", "text": "Идти", "script": "Идём вперёд"}
                    ]
                },
                {
                    "title": "Финал",
                    "chapter": "Эпилог",
                    "items": [{"type": "text", "text": "Конец."}]
                }
            ],
            "scripts": [
                {
                    "name": "Идём вперёд",
                    "event": "onPress",
                    "blocks": [
                        {"type": "assign_variable", "variable": "шагов", "value": "1"},
                        {"goto": "Финал"}
                    ]
                }
            ],
            "tables": [
                {"name": "предметы", "columns": ["name", "price"],
                 "rows": [["Меч", 10], ["Щит", 5]], "row_names": ["меч", "щит"]}
            ],
            "variables": [{"name": "золото", "default": 100}]
        })
    }

    #[test]
    fn apply_creates_quest_with_titles_as_references() {
        let (root, builder) = new_quest();
        let report = apply(&builder, plan_text());
        assert!(
            report.ok,
            "issues: {:?}; диагностика: {:?}",
            report.issues, report.diagnostics
        );
        assert!(report.applied);
        assert_eq!(report.created.nodes.len(), 2);
        assert_eq!(report.created.scripts.len(), 1);
        assert_eq!(report.created.chapters.len(), 2);

        let validation = analyze_quest("q1", &root);
        assert!(
            !validation.has_errors(),
            "валидатор: {:?}",
            validation.diagnostics
        );

        // Стартовая нода — по названию, кнопка привязана к скрипту.
        let info = builder.info();
        let start = info["startNodeId"].as_str().unwrap();
        let nodes = info["nodes"].as_array().unwrap();
        let start_node = nodes
            .iter()
            .find(|n| n["id"] == start)
            .expect("стартовая нода есть");
        assert_eq!(start_node["title"], "Старт");
        assert_eq!(start_node["items"], 2);
    }

    #[test]
    fn apply_is_idempotent_for_content() {
        let (_root, builder) = new_quest();
        apply(&builder, plan_text());
        let second = apply(&builder, plan_text());
        assert!(second.ok);
        assert!(second.created.nodes.is_empty());
        assert_eq!(second.updated.nodes.len(), 2);

        let info = builder.info();
        // «Начало» из создания квеста + «Старт» и «Финал» из плана.
        assert_eq!(info["nodes"].as_array().unwrap().len(), 3);
        assert_eq!(info["scripts"].as_array().unwrap().len(), 1);
        assert_eq!(info["tables"].as_array().unwrap().len(), 1);
        // Повторный apply не должен размножать таблицы и переменные.
        assert_eq!(info["variables"].as_array().unwrap().len(), 1);
        assert_eq!(info["chapters"].as_array().unwrap().len(), 3);
    }

    #[test]
    fn unknown_reference_is_reported_without_writing() {
        let (root, builder) = new_quest();
        let before = builder.info();
        let report = apply(
            &builder,
            json!({"nodes": [{"title": "Новая", "chapter": "Нет такой главы"}]}),
        );
        assert!(!report.ok);
        assert!(!report.applied);
        assert!(!report.issues.is_empty());
        assert!(
            report.issues[0].message.contains("не найдена"),
            "{:?}",
            report.issues
        );
        // Диск не тронут: ноды не появились.
        let after = builder.info();
        assert_eq!(
            before["nodes"].as_array().unwrap().len(),
            after["nodes"].as_array().unwrap().len()
        );
        assert!(analyze_quest("q1", &root).diagnostics.is_empty());
    }

    #[test]
    fn unknown_field_in_plan_is_an_error() {
        let (_root, builder) = new_quest();
        let err = builder
            .apply(
                &json!({"nodes": [{"title": "X", "bigText": "опечатка"}]}),
                &ApplyOptions::default(),
            )
            .unwrap_err();
        assert!(matches!(err, BuildError::Invalid(_)), "{err:?}");
    }

    #[test]
    fn broken_goto_is_caught_before_write() {
        let (_root, builder) = new_quest();
        let report = apply(
            &builder,
            json!({"scripts": [{"name": "Сломанный", "blocks": [{"goto": "Нет такой ноды"}]}]}),
        );
        assert!(!report.ok);
        assert!(!report.applied);
    }

    #[test]
    fn deleting_node_requires_fixing_references_in_same_plan() {
        let (_root, builder) = new_quest();
        apply(&builder, plan_text());

        // Сначала только удаление: скрипт всё ещё ведёт на «Финал», это
        // ошибка валидатора, и план не пишется.
        let blocked = apply(&builder, json!({"delete": {"nodes": ["Финал"]}}));
        assert!(!blocked.ok);
        assert!(!blocked.applied);
        assert!(
            blocked
                .diagnostics
                .iter()
                .any(|d| d.kind == crate::validation::DiagnosticKind::BrokenNodeLink),
            "{:?}",
            blocked.diagnostics
        );

        // Удаление вместе с правкой скрипта — один план, одна транзакция.
        let report = apply(
            &builder,
            json!({
                "delete": {"nodes": ["Финал"]},
                "scripts": [{"name": "Идём вперёд", "blocks": [{"goto": "Старт"}]}]
            }),
        );
        assert!(report.ok, "{:?}", report.diagnostics);
        assert_eq!(report.deleted.nodes.len(), 1);
        // «Начало» и «Старт».
        assert_eq!(builder.info()["nodes"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn button_from_plan_is_pressed_by_engine() {
        // Регрессия: скрипт, записанный в `scriptAssetId`, движок не исполняет —
        // кнопка в редакторе выглядит живой, а нажатие ничего не делает.
        let (root, builder) = new_quest();
        let report = apply(&builder, plan_text());
        assert!(report.ok, "{:?} {:?}", report.issues, report.diagnostics);

        let mut engine = crate::engine::GameEngine::from_disk("q1", &root).unwrap();
        engine.start_new(None).unwrap();
        let node_before = engine.current_state_snapshot().current_node_id;
        let button = engine
            .current_items()
            .into_iter()
            .find(|item| item.get("text").and_then(Value::as_str) == Some("Идти"))
            .expect("кнопка из плана есть в ноде");
        let id = button["id"].as_str().unwrap().to_string();
        let next = engine.press_item(&id).expect("нажатие должно дать переход");
        assert_ne!(Some(next), node_before);
        assert_eq!(
            engine.all_variables().get("шагов").and_then(Value::as_f64),
            Some(1.0)
        );
    }

    #[test]
    fn start_node_cannot_be_deleted() {
        let (_root, builder) = new_quest();
        apply(&builder, plan_text());
        let report = apply(&builder, json!({"delete": {"nodes": ["Старт"]}}));
        assert!(!report.ok);
        assert!(
            report.issues[0].message.contains("стартовую"),
            "{:?}",
            report.issues
        );
    }
}
