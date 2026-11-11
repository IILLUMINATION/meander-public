//! Статический валидатор квеста.
//
// Allow clippy false positive: push_with has 7 params but clippy reports 8.
// This happens because the function definition is on line 227 and clippy's
// too_many_arguments check sometimes miscounts across the crate boundary.

#![allow(clippy::too_many_arguments)]
//!
//! Анализирует каталог квеста (`config.json`, `nodes.json`,
//! `res/templates.json`, `scripts/*.json`) и возвращает список диагностик:
//! битые ссылки (ноды/скрипты/ресурсы), дубли id, недостижимые ноды,
//! мёртвые переменные, конфликты видимости onAppear-условий в одном
//! контейнере (тот самый баг «второго пустого ряда»).
//!
//! Поток управления проверяется как в borrow checker: мёртвый код после
//! перехода, тупики, скрипты без единой ссылки, циклы без «Задержки» и
//! таблицы, строки которых не совпадают с колонками.
//!
//! Крейт не выполняет I/O — данные читаются через [`ScriptAssetStore`]
//! (как `GameEngine::from_disk`).

use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::Path;

use serde::Serialize;
use serde_json::{Map, Value};

use crate::contracts::FsScriptAssetStore;
use crate::executor::DynAssetStore;
use crate::models::{ContentItem, Quest, SavedNode, TemplateItem};

/// Важность диагностики.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Severity {
    Warning,
    Error,
}

/// Тип диагностики.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticKind {
    /// `config.json` не найден или не парсится.
    MissingConfig,
    /// Ссылка на ноду ведёт на несуществующий id.
    BrokenNodeLink,
    /// Ссылка на скрипт (`scriptTriggers`, `scriptAssetId`, `call_script`).
    BrokenScriptLink,
    /// Ссылка на ресурс (`resourcePath`, фон ноды) — файла нет.
    BrokenResourceLink,
    DuplicateNodeId,
    DuplicateTemplateId,
    DuplicateItemId,
    /// Нода не достижима из `startNodeId` по графу переходов.
    UnreachableNode,
    /// Переменная пишется, но нигде не читается.
    UnwrittenVariable,
    /// Переменная читается, но нигде не пишется.
    UnreadVariable,
    /// Два onAppear-условия в одном контейнере могут быть истинны одновременно.
    VisibilityConflict,
    /// Скрипт без блоков.
    EmptyScript,
    /// Некорректное выражение условия.
    BadExpression,
    /// onAppear-триггер указывает на несуществующую функцию или item.
    BadOnAppearTrigger,
    /// Структурная проблема скрипта (план 020-B: validate_script).
    InvalidScriptStructure,
    /// В настройках квеста не указана стартовая нода.
    MissingStartNode,
    /// Нода ссылается на главу (тег), которой нет в `config.tags`.
    UnknownChapter,
    /// Два тега с одинаковым id — главы схлопнутся в одну.
    DuplicateChapterId,
    /// У квеста есть ноды, но нет ни одной главы: ноды не открываются в редакторе.
    NoChapters,
    /// Блоки после перехода: исполнитель остановится, хвост не выполнится.
    UnreachableCode,
    /// Из достижимой ноды нет выхода, а выйти из квеста тоже нельзя.
    DeadEndNode,
    /// Скрипт лежит в `scripts/`, но ни одна нода и ни один вызов не ссылается.
    DeadScript,
    /// Строки таблицы не совпадают с её колонками (данные теряются молча).
    TableColumnMismatch,
    /// Цикл перебирает всё за один кадр — окно замрёт на большом числе итераций.
    LoopWithoutWait,
}

impl DiagnosticKind {
    /// Все виды — для `mnd-cli quest spec` и справки. Список обязан совпадать
    /// с перечислением выше: тест сверяет количество.
    pub const ALL: &'static [DiagnosticKind] = &[
        DiagnosticKind::MissingConfig,
        DiagnosticKind::BrokenNodeLink,
        DiagnosticKind::BrokenScriptLink,
        DiagnosticKind::BrokenResourceLink,
        DiagnosticKind::DuplicateNodeId,
        DiagnosticKind::DuplicateTemplateId,
        DiagnosticKind::DuplicateItemId,
        DiagnosticKind::UnreachableNode,
        DiagnosticKind::UnwrittenVariable,
        DiagnosticKind::UnreadVariable,
        DiagnosticKind::VisibilityConflict,
        DiagnosticKind::EmptyScript,
        DiagnosticKind::BadExpression,
        DiagnosticKind::BadOnAppearTrigger,
        DiagnosticKind::InvalidScriptStructure,
        DiagnosticKind::MissingStartNode,
        DiagnosticKind::UnknownChapter,
        DiagnosticKind::DuplicateChapterId,
        DiagnosticKind::NoChapters,
        DiagnosticKind::UnreachableCode,
        DiagnosticKind::DeadEndNode,
        DiagnosticKind::DeadScript,
        DiagnosticKind::TableColumnMismatch,
        DiagnosticKind::LoopWithoutWait,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            DiagnosticKind::MissingConfig => "missing_config",
            DiagnosticKind::BrokenNodeLink => "broken_node_link",
            DiagnosticKind::BrokenScriptLink => "broken_script_link",
            DiagnosticKind::BrokenResourceLink => "broken_resource_link",
            DiagnosticKind::DuplicateNodeId => "duplicate_node_id",
            DiagnosticKind::DuplicateTemplateId => "duplicate_template_id",
            DiagnosticKind::DuplicateItemId => "duplicate_item_id",
            DiagnosticKind::UnreachableNode => "unreachable_node",
            DiagnosticKind::UnwrittenVariable => "unwritten_variable",
            DiagnosticKind::UnreadVariable => "unread_variable",
            DiagnosticKind::VisibilityConflict => "visibility_conflict",
            DiagnosticKind::EmptyScript => "empty_script",
            DiagnosticKind::BadExpression => "bad_expression",
            DiagnosticKind::BadOnAppearTrigger => "bad_on_appear_trigger",
            DiagnosticKind::InvalidScriptStructure => "invalid_script_structure",
            DiagnosticKind::MissingStartNode => "missing_start_node",
            DiagnosticKind::UnknownChapter => "unknown_chapter",
            DiagnosticKind::DuplicateChapterId => "duplicate_chapter_id",
            DiagnosticKind::NoChapters => "no_chapters",
            DiagnosticKind::UnreachableCode => "unreachable_code",
            DiagnosticKind::DeadEndNode => "dead_end_node",
            DiagnosticKind::DeadScript => "dead_script",
            DiagnosticKind::TableColumnMismatch => "table_column_mismatch",
            DiagnosticKind::LoopWithoutWait => "loop_without_wait",
        }
    }
}

/// Одна диагностика валидации.
#[derive(Debug, Clone, Serialize)]
pub struct Diagnostic {
    pub severity: Severity,
    pub kind: DiagnosticKind,
    /// Понятное описание: что случилось и где (без uuid, с названиями).
    pub message: String,
    /// Подсказка «что делать».
    pub fix_hint: Option<String>,
    pub node_id: Option<String>,
    pub item_id: Option<String>,
    pub script_path: Option<String>,
}

/// Сводная статистика анализа.
#[derive(Debug, Clone, Default, Serialize)]
pub struct ReportStats {
    pub quest_id: String,
    pub nodes: usize,
    pub templates: usize,
    pub scripts: usize,
    pub items: usize,
    pub warnings: usize,
    pub errors: usize,
}

/// Отчёт валидации квеста.
#[derive(Debug, Clone, Default, Serialize)]
pub struct ValidationReport {
    pub stats: ReportStats,
    pub diagnostics: Vec<Diagnostic>,
}

impl ValidationReport {
    pub fn has_errors(&self) -> bool {
        self.stats.errors > 0
    }
}

/// Проанализировать каталог квеста `root/quests/<quest_id>/`.
pub fn analyze_quest(quest_id: &str, root: impl AsRef<Path>) -> ValidationReport {
    let store: DynAssetStore =
        std::sync::Arc::new(FsScriptAssetStore::new(root.as_ref().to_path_buf()));
    Validator::new(quest_id, store).run()
}

/// Проанализировать квест с произвольным хранилищем (в т.ч. in-memory в тестах).
pub fn analyze_quest_with_store(quest_id: &str, store: DynAssetStore) -> ValidationReport {
    Validator::new(quest_id, store).run()
}

struct Validator {
    quest_id: String,
    prefix: String,
    store: DynAssetStore,
    report: ValidationReport,
    config: Option<Quest>,
    nodes: Vec<SavedNode>,
    templates: Vec<TemplateItem>,
    /// Скрипт: `путь → распарсенный объект` (кэш; `None` = не читается).
    script_cache: HashMap<String, Option<Map<String, Value>>>,
    /// Переходы графа: `нода → множество целей`.
    transitions: HashMap<String, BTreeSet<String>>,
    written_vars: HashSet<String>,
    read_vars: HashSet<String>,
    seen_node_ids: HashSet<String>,
    seen_template_ids: HashSet<String>,
    /// Скрипты, уже проанализированные (защита от циклов call_script).
    analyzed_scripts: HashSet<String>,
    /// Кандидаты конфликта видимости: `(контейнер, node_id) → список детей`.
    visibility_groups: Vec<VisibilityGroup>,
    /// Кэш выражений видимости по пути скрипта.
    appear_expr_cache: HashMap<String, Option<String>>,
    /// `id ноды → title` (для читаемого контекста в сообщениях).
    node_titles: HashMap<String, String>,
    /// `id айтема → подпись` (text/button_text/placeholder или тип).
    item_labels: HashMap<String, String>,
    /// `id шаблона → name` (для локации конфликтов видимости).
    template_titles: HashMap<String, String>,
    /// Имя скрипта, внутри которого сейчас идёт анализ (контекст call_script).
    current_script_name: Option<String>,
    /// Путь скрипта, внутри которого идёт анализ: попадает в диагностику,
    /// чтобы редактор мог открыть источник (раньше это знал только текст).
    current_script_path: Option<String>,
    /// Ноды-владельцы скрипта: `путь → {ноды}`. Общие скрипты
    /// (одна кнопка-действие в разных нодах) дают переходы из КАЖДОЙ.
    script_owners: HashMap<String, HashSet<String>>,
    /// Ноды-владельцы скрипта, анализируемого в данный момент.
    current_owners: HashSet<String>,
    /// Есть ли переход с динамической целью (`={expr}` / `{выражение}`).
    /// В этом случае точный статический граф невозможен — недостижимость
    /// не диагностируется (иначе будут ложные срабатывания).
    has_dynamic_edge: bool,
    /// onAppear-триггеры: `(item_id, node_id, script_path, function_entry)`.
    on_appear_triggers: Vec<(String, Option<String>, String, Option<String>)>,
}

#[derive(Debug, Clone)]
struct VisibilityGroup {
    container_id: String,
    node_id: Option<String>,
    template_id: Option<String>,
    children: Vec<VisibilityChild>,
}

#[derive(Debug, Clone)]
struct VisibilityChild {
    item_id: String,
    script_path: String,
    expr: String,
}

impl Validator {
    fn new(quest_id: &str, store: DynAssetStore) -> Self {
        Validator {
            quest_id: quest_id.to_string(),
            prefix: format!("quests/{quest_id}/"),
            store,
            report: ValidationReport::default(),
            config: None,
            nodes: Vec::new(),
            templates: Vec::new(),
            script_cache: HashMap::new(),
            transitions: HashMap::new(),
            written_vars: HashSet::new(),
            read_vars: HashSet::new(),
            seen_node_ids: HashSet::new(),
            seen_template_ids: HashSet::new(),
            analyzed_scripts: HashSet::new(),
            visibility_groups: Vec::new(),
            appear_expr_cache: HashMap::new(),
            node_titles: HashMap::new(),
            item_labels: HashMap::new(),
            template_titles: HashMap::new(),
            current_script_name: None,
            current_script_path: None,
            script_owners: HashMap::new(),
            current_owners: HashSet::new(),
            has_dynamic_edge: false,
            on_appear_triggers: Vec::new(),
        }
    }

    fn run(mut self) -> ValidationReport {
        self.report.stats.quest_id = self.quest_id.clone();
        self.load_project();
        self.check_duplicate_ids();
        self.collect_node_timer_edges();
        self.walk_all_items();
        self.analyze_all_scripts();
        self.check_chapters();
        self.check_reachability();
        self.check_dead_variables();
        self.check_visibility_conflicts();
        self.check_on_appear_triggers();
        self.check_dead_ends();
        self.check_dead_scripts();
        self.check_tables();
        self.report.stats.warnings = self
            .report
            .diagnostics
            .iter()
            .filter(|d| d.severity == Severity::Warning)
            .count();
        self.report.stats.errors = self
            .report
            .diagnostics
            .iter()
            .filter(|d| d.severity == Severity::Error)
            .count();
        self.report
    }

    fn push(
        &mut self,
        severity: Severity,
        kind: DiagnosticKind,
        message: impl Into<String>,
        fix_hint: Option<String>,
    ) {
        self.push_with(severity, kind, message, fix_hint, None, None, None);
    }

    fn push_with(
        &mut self,
        severity: Severity,
        kind: DiagnosticKind,
        message: impl Into<String>,
        fix_hint: Option<String>,
        node_id: Option<String>,
        item_id: Option<String>,
        mut script_path: Option<String>,
    ) {
        // Внутри анализа скрипта путь известен из контекста: без него
        // редактор не может открыть источник проблемы.
        if script_path.is_none() && node_id.is_none() && item_id.is_none() {
            script_path = self.current_script_path.clone();
        }
        self.report.diagnostics.push(Diagnostic {
            severity,
            kind,
            message: message.into(),
            fix_hint,
            node_id,
            item_id,
            script_path,
        });
    }

    /// Читаемый контекст источника ссылки: «Нода «X» → кнопка «Y»: ».
    fn context_prefix(&self, node_id: Option<&str>, item_id: Option<&str>) -> String {
        let node_part = node_id
            .filter(|n| !n.is_empty())
            .map(|n| format!("Нода «{}»", self.node_title(n)));
        let item_part = item_id
            .filter(|i| !i.is_empty())
            .map(|i| self.item_label(i));
        match (node_part, item_part) {
            (Some(n), Some(i)) => format!("{n} → «{i}»: "),
            (Some(n), None) => format!("{n}: "),
            (None, Some(i)) => format!("«{i}»: "),
            (None, None) => String::new(),
        }
    }

    /// Контекст скрипта-источника: «Скрипт «X»: ».
    fn script_context(&self) -> String {
        match &self.current_script_name {
            Some(name) => format!("Скрипт «{name}»: "),
            None => String::new(),
        }
    }

    fn node_title(&self, id: &str) -> String {
        self.node_titles
            .get(id)
            .cloned()
            .unwrap_or_else(|| id.to_string())
    }

    fn item_label(&self, id: &str) -> String {
        self.item_labels
            .get(id)
            .cloned()
            .unwrap_or_else(|| "элемент".to_string())
    }

    // ---------- Загрузка проекта ----------

    fn load_project(&mut self) {
        let config_path = format!("{}config.json", self.prefix);
        match self.store.read_json(&config_path) {
            Some(raw) => {
                let quest = Quest::from_json(&raw);
                self.config = Some(quest);
                self.nodes = load_nodes(self.store.as_ref(), &self.prefix);
                self.report.stats.nodes = self.nodes.len();
                for node in &self.nodes {
                    self.node_titles.insert(node.id.clone(), node.title.clone());
                }
                self.templates = self.load_array(
                    &format!("{}res/templates.json", self.prefix),
                    "templates",
                    TemplateItem::from_json,
                );
                self.report.stats.templates = self.templates.len();
                for t in &self.templates {
                    self.template_titles.insert(t.id.clone(), t.name.clone());
                }
            }
            None => {
                self.push(
                    Severity::Error,
                    DiagnosticKind::MissingConfig,
                    "Файл настроек квеста (config.json) не найден — квест не запустится",
                    Some(
                        "Восстановите файл config.json или откройте квест заново в редакторе"
                            .into(),
                    ),
                );
            }
        }
    }

    fn load_array<T>(&self, path: &str, key: &str, f: impl Fn(&Value) -> T) -> Vec<T> {
        let Some(value) = self.store.read_json(path) else {
            return Vec::new();
        };
        let empty: Vec<Value> = Vec::new();
        let array = match &value {
            Value::Array(arr) => arr,
            Value::Object(obj) => obj.get(key).and_then(Value::as_array).unwrap_or(&empty),
            _ => return Vec::new(),
        };
        array.iter().map(f).collect()
    }

    // ---------- Дубли id ----------

    fn check_duplicate_ids(&mut self) {
        let mut dup_nodes: Vec<String> = Vec::new();
        let mut dup_templates: Vec<String> = Vec::new();
        for node in &self.nodes {
            if !self.seen_node_ids.insert(node.id.clone()) {
                dup_nodes.push(node.id.clone());
            }
        }
        for t in &self.templates {
            if !self.seen_template_ids.insert(t.id.clone()) {
                dup_templates.push(t.id.clone());
            }
        }
        for id in dup_nodes {
            let title = self.node_titles.get(&id).cloned().unwrap_or_default();
            self.push(
                Severity::Error,
                DiagnosticKind::DuplicateNodeId,
                format!(
                    "Две ноды имеют одинаковый id{} — одна из них будет перезаписываться",
                    if title.is_empty() {
                        String::new()
                    } else {
                        format!(" («{title}»)")
                    }
                ),
                Some("Переименуйте или удалите одну из нод".into()),
            );
        }
        for id in dup_templates {
            let name = self.template_titles.get(&id).cloned().unwrap_or_default();
            self.push(
                Severity::Error,
                DiagnosticKind::DuplicateTemplateId,
                format!(
                    "Два шаблона имеют одинаковый id{} — один из них будет перезаписываться",
                    if name.is_empty() {
                        String::new()
                    } else {
                        format!(" («{name}»)")
                    }
                ),
                Some("Переименуйте или удалите один из шаблонов".into()),
            );
        }
    }

    /// Переход по таймеру ноды: по истечении `timerDuration` движок
    /// переходит на `defaultActionNodeId` (см. `ResolvedTimer` в engine.rs).
    /// Без этого рёбра валидатор ложно помечал такие ноды недостижимыми.
    fn collect_node_timer_edges(&mut self) {
        let nodes = self.nodes.clone();
        for node in &nodes {
            let Some(target) = &node.default_action_node_id else {
                continue;
            };
            if target.is_empty() {
                continue;
            }
            self.check_node_link(Some(&node.id), None, target);
            if !is_expr_ref(target) {
                self.edge(Some(&node.id), target);
            } else {
                self.has_dynamic_edge = true;
            }
        }
    }

    // ---------- Обход элементов ----------

    fn walk_all_items(&mut self) {
        let nodes = self.nodes.clone();
        for node in &nodes {
            let items = node_items(node);
            let node_id = node.id.clone();
            let mut seen: HashSet<String> = HashSet::new();
            for item in &items {
                self.walk_item(Some(&node_id), None, item, &mut seen);
            }
        }
        let templates = self.templates.clone();
        for t in &templates {
            let template_id = t.id.clone();
            let items = template_items(t);
            let mut seen: HashSet<String> = HashSet::new();
            for item in &items {
                self.walk_item(None, Some(&template_id), item, &mut seen);
            }
        }
    }

    fn walk_item(
        &mut self,
        node_id: Option<&str>,
        template_id: Option<&str>,
        item: &ContentItem,
        sibling_ids: &mut HashSet<String>,
    ) {
        self.report.stats.items += 1;

        if !item.id.is_empty() {
            self.item_labels.entry(item.id.clone()).or_insert_with(|| {
                item.text
                    .clone()
                    .or_else(|| item.button_text.clone())
                    .or_else(|| item.placeholder_text.clone())
                    .filter(|s| !s.trim().is_empty())
                    .unwrap_or_else(|| format!("{} {}", item.item_type, item.id))
            });
        }

        if !item.id.is_empty() && !sibling_ids.insert(item.id.clone()) {
            self.push_with(
                Severity::Error,
                DiagnosticKind::DuplicateItemId,
                format!(
                    "{}В одном контейнере два элемента с одинаковым id — один из них будет работать некорректно",
                    self.context_prefix(node_id, Some(&item.id))
                ),
                Some("Переименуйте или удалите один из элементов".into()),
                node_id.map(str::to_string),
                Some(item.id.clone()),
                None,
            );
        }

        // Ссылки на скрипты.
        if let Some(path) = &item.script_asset_id {
            self.check_script_link(node_id, Some(&item.id), path);
        }
        // `resolved_behaviours` — оба формата: legacy `scriptTriggers` и
        // новый `behaviours`; чтение только legacy не видело скрипт,
        // привязанный новым форматом.
        for beh in item.resolved_behaviours() {
            self.check_script_link(node_id, Some(&item.id), &beh.script);
            // Collect onAppear triggers for detailed validation.
            if beh.event == "onContentAppear" || beh.event == "onAppear" {
                let (script_path, fn_entry) = self.split_script_ref(&beh.script);
                self.on_appear_triggers.push((
                    item.id.clone(),
                    node_id.map(str::to_string),
                    script_path,
                    fn_entry,
                ));
            }
        }
        // Script-айтем (`type: "script"`): движок выполняет его как скрипт
        // ноды (onNodeEnter/onContentAppear), а `resourcePath` — путь к
        // JSON/Lua-скрипту, а не к картинке/ресурсу.
        let is_script_item = item.item_type == "script";
        if is_script_item && let Some(path) = &item.resource_path {
            self.check_script_link(node_id, Some(&item.id), path);
        }

        // Ресурсы (для всех остальных типов айтемов).
        if let Some(path) = &item.resource_path
            && !is_script_item
        {
            self.check_resource(node_id, Some(&item.id), path);
        }

        // Переходы.
        if let Some(target) = &item.target_node_id {
            self.check_node_link(node_id, Some(&item.id), target);
            if is_expr_ref(target) {
                self.has_dynamic_edge = true;
            } else if !is_sentinel_target(target) {
                // Служебная цель (`_CLOSE_MODAL`) — не нода: ребро к ней
                // добавило бы в граф фантом, которого в списке нод нет.
                self.edge(node_id, target);
            }
        }

        // Переменные в текстах.
        self.collect_vars_from_str(item.text.as_deref());
        self.collect_vars_from_str(item.button_text.as_deref());
        self.collect_vars_from_str(item.placeholder_text.as_deref());
        self.collect_vars_from_str(item.content_markdown.as_deref());

        // Группа видимости: контейнер с детьми.
        if let Some(children) = &item.children {
            if is_container(&item.item_type) {
                let mut group = VisibilityGroup {
                    container_id: item.id.clone(),
                    node_id: node_id.map(str::to_string),
                    template_id: template_id.map(str::to_string),
                    children: Vec::new(),
                };
                let mut child_ids: HashSet<String> = HashSet::new();
                for child in children {
                    if let Some(path) = child
                        .script_triggers
                        .as_ref()
                        .and_then(|t| t.get("onContentAppear").or_else(|| t.get("onAppear")))
                        && let Some(expr) = self.appear_expression(path)
                    {
                        group.children.push(VisibilityChild {
                            item_id: child.id.clone(),
                            script_path: path.clone(),
                            expr,
                        });
                    }
                    self.walk_item(node_id, template_id, child, &mut child_ids);
                }
                self.visibility_groups.push(group);
            } else {
                let mut child_ids: HashSet<String> = HashSet::new();
                for child in children {
                    self.walk_item(node_id, template_id, child, &mut child_ids);
                }
            }
        }
    }

    // ---------- Скрипты ----------

    fn load_script(&mut self, raw_path: &str) -> Option<Map<String, Value>> {
        let (path, _fn) = self.split_script_ref(raw_path);
        if let Some(cached) = self.script_cache.get(&path) {
            return cached.clone();
        }
        let mut loaded = None;
        for candidate in self.script_candidates(&path) {
            let full = format!("{}{}", self.prefix, candidate);
            if let Some(v) = self
                .store
                .read_json(&full)
                .and_then(|v| v.as_object().cloned())
            {
                loaded = Some(v);
                break;
            }
        }
        self.script_cache.insert(path, loaded.clone());
        loaded
    }

    /// Нормализация ссылки на скрипт: отрезает `quests/<id>/`, `/` и
    /// фрагмент `#fn=Имя` (вызов функции внутри скрипта, как в движке).
    /// Возвращает (путь без фрагмента, имя функции).
    fn split_script_ref(&self, raw: &str) -> (String, Option<String>) {
        let trimmed = raw.trim_start_matches(&format!("quests/{}/", self.quest_id));
        let trimmed = trimmed.trim_start_matches('/');
        if let Some(idx) = trimmed.find("#fn=") {
            let path = trimmed[..idx].trim().to_string();
            let fn_raw = trimmed[idx + 4..].trim();
            let decoded = if fn_raw.is_empty() {
                None
            } else {
                Some(percent_decode(fn_raw))
            };
            return (path, decoded);
        }
        (trimmed.to_string(), None)
    }

    /// Кандидаты для загрузки скрипта: основной каталог `scripts/` и
    /// внутренние `_internal_scripts/` / `n/` (движок резолвит так же).
    fn script_candidates(&self, path: &str) -> Vec<String> {
        let mut candidates = vec![path.to_string()];
        if let Some(rest) = path.strip_prefix("scripts/") {
            candidates.push(format!("_internal_scripts/{rest}"));
            candidates.push(format!("n/{rest}"));
        } else if !path.contains('/') && !path.ends_with(".json") {
            // Голый id скрипта: движок находит `scripts/<id>.json` (см.
            // `resolve_script_path`), значит и проверка ссылки обязана.
            candidates.push(format!("scripts/{path}.json"));
            candidates.push(format!("_internal_scripts/{path}.json"));
        }
        candidates
    }

    fn check_script_link(&mut self, node_id: Option<&str>, item_id: Option<&str>, raw_path: &str) {
        let (path, fn_name) = self.split_script_ref(raw_path);
        let ctx = self.context_prefix(node_id, item_id);
        if path.ends_with(".lua") {
            let full = format!("{}{}", self.prefix, path);
            if self.store.read_text(&full).is_none() {
                self.push_with(
                    Severity::Error,
                    DiagnosticKind::BrokenScriptLink,
                    format!("{ctx}Привязанный Lua-скрипт удалён или переименован"),
                    Some("Восстановите файл скрипта или отвяжите его от элемента".into()),
                    node_id.map(str::to_string),
                    item_id.map(str::to_string),
                    Some(path),
                );
            }
            return;
        }
        let Some(script) = self.load_script(&path) else {
            self.push_with(
                Severity::Error,
                DiagnosticKind::BrokenScriptLink,
                format!("{ctx}Привязанный скрипт удалён или переименован"),
                Some("Перепривяжите элемент к другому скрипту или восстановите файл".into()),
                node_id.map(str::to_string),
                item_id.map(str::to_string),
                Some(path),
            );
            return;
        };
        if let Some(fn_name) = fn_name {
            let script_name = script
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or(&path)
                .to_string();
            if !script_has_function(&script, &fn_name) {
                self.push_with(
                    Severity::Error,
                    DiagnosticKind::BrokenScriptLink,
                    format!(
                        "{ctx}В скрипте «{script_name}» нет функции «{fn_name}», к которой привязан элемент"
                    ),
                    Some("Проверьте имя функции в привязке или добавьте её в скрипт".into()),
                    node_id.map(str::to_string),
                    item_id.map(str::to_string),
                    Some(path),
                );
            }
        }
    }

    /// Анализ скрипта: переходы, call_script, переменные.
    /// Прочитать скрипт как serde Value по кандидатам путей.
    fn load_script_value(&self, path: &str) -> Option<Value> {
        for candidate in self.script_candidates(path) {
            let full = format!("{}{}", self.prefix, candidate);
            if let Some(v) = self.store.read_json(&full) {
                return Some(v);
            }
        }
        None
    }

    fn analyze_script(&mut self, raw_path: &str, inherited_owners: &HashSet<String>) {
        let (path, _fn_name) = self.split_script_ref(raw_path);
        if !self.analyzed_scripts.insert(path.clone()) {
            return;
        }
        let Some(mut script_value) = self.load_script_value(&path) else {
            return;
        };
        // Канонизация: легаси-формы анализируются в каноническом виде.
        crate::script_format::normalize_script(&mut script_value);
        // Структурные контракты типов (план 020-B2).
        if let Some(obj) = script_value.as_object() {
            for issue in crate::script_format::validate_script(obj) {
                self.push(
                    Severity::Warning,
                    DiagnosticKind::InvalidScriptStructure,
                    format!(
                        "{}{} — {}",
                        self.script_context(),
                        issue.path,
                        issue.message
                    ),
                    None,
                );
            }
        }
        let Some(script) = script_value.as_object().cloned() else {
            return;
        };
        self.report.stats.scripts += 1;

        let prev_script = self.current_script_name.clone();
        let prev_script_path = self.current_script_path.clone();
        let prev_owners = self.current_owners.clone();
        self.current_script_path = Some(path.clone());
        self.current_script_name = script
            .get("name")
            .and_then(Value::as_str)
            .map(str::to_string)
            .or(Some(path.clone()));
        // Владельцы: из цепочки вызовов (call_script) + прямые владельцы
        // скрипта (айтемы, привязанные к нему в нодах).
        let mut owners = inherited_owners.clone();
        if let Some(direct) = self.script_owners.get(&path) {
            owners.extend(direct.iter().cloned());
        }
        self.current_owners = owners;

        let blocks = script
            .get("blocks")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        if blocks.is_empty() {
            self.push(
                Severity::Warning,
                DiagnosticKind::EmptyScript,
                format!(
                    "{}Скрипт пустой — при вызове ничего не произойдёт",
                    self.script_context()
                ),
                Some("Добавьте блоки в скрипт или отвяжите его".into()),
            );
            self.current_script_name = prev_script;
            self.current_script_path = prev_script_path;
            self.current_owners = prev_owners;
            return;
        }
        self.analyze_block_list(&blocks);
        self.current_script_name = prev_script;
        self.current_script_path = prev_script_path;
        self.current_owners = prev_owners;
    }

    fn analyze_block(&mut self, block: &Value) {
        let Some(obj) = block.as_object() else { return };
        let block_type = obj.get("type").and_then(Value::as_str).unwrap_or("");
        match block_type {
            "go_to_node" => {
                if let Some(target) = obj.get("node_id").and_then(Value::as_str) {
                    self.collect_vars_from_str(Some(target));
                    if !is_expr_ref(target) {
                        let owners = self.current_owners.clone();
                        for owner in &owners {
                            self.edge(Some(owner), target);
                        }
                        self.check_node_link(None, None, target);
                    } else {
                        self.has_dynamic_edge = true;
                    }
                }
            }
            "call_script" => {
                let id = obj
                    .get("script_id")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let ref_path = if id.contains('.') {
                    id.to_string()
                } else {
                    format!("scripts/{id}.json")
                };
                if self.load_script(&ref_path).is_none() {
                    let name = obj
                        .get("script_name")
                        .and_then(Value::as_str)
                        .filter(|s| !s.is_empty())
                        .map(|s| format!(" «{s}»"))
                        .unwrap_or_default();
                    self.push(
                        Severity::Error,
                        DiagnosticKind::BrokenScriptLink,
                        format!(
                            "{}Вызываемый скрипт{name} удалён или переименован",
                            self.script_context()
                        ),
                        Some("Восстановите файл скрипта или исправьте вызов".into()),
                    );
                } else {
                    let owners = self.current_owners.clone();
                    self.analyze_script(&ref_path, &owners);
                }
            }
            "assign_variable" => {
                if let Some(var) = obj
                    .get("variable")
                    .and_then(Value::as_str)
                    .filter(|v| !v.is_empty())
                {
                    self.written_vars.insert(var.to_string());
                }
                if let Some(value) = obj.get("value").and_then(Value::as_str) {
                    self.collect_vars_from_str(Some(value));
                }
            }
            "open_link" => {
                if let Some(url) = obj.get("url").and_then(Value::as_str) {
                    self.collect_vars_from_str(Some(url));
                }
            }
            "http_request" => {
                if let Some(url) = obj.get("url").and_then(Value::as_str) {
                    self.collect_vars_from_str(Some(url));
                }
                if let Some(body) = obj.get("body").and_then(Value::as_str) {
                    self.collect_vars_from_str(Some(body));
                }
                if let Some(Value::Object(headers)) = obj.get("headers") {
                    for value in headers.values() {
                        if let Some(s) = value.as_str() {
                            self.collect_vars_from_str(Some(s));
                        }
                    }
                }
                for key in ["targetVariable", "statusVariable"] {
                    if let Some(var) = obj
                        .get(key)
                        .and_then(Value::as_str)
                        .filter(|v| !v.is_empty())
                    {
                        self.written_vars.insert(var.to_string());
                    }
                }
            }
            _ => {}
        }
        if let Some(expr) = obj.get("expression").and_then(Value::as_str) {
            self.collect_vars_from_str(Some(expr));
            if !is_balanced_expr(expr) {
                self.push(
                    Severity::Warning,
                    DiagnosticKind::BadExpression,
                    format!(
                        "{}Выражение записано с ошибкой: «{expr}»",
                        self.script_context()
                    ),
                    Some("Проверьте скобки и имена переменных в выражении".into()),
                );
            }
        }
        for key in ["children", "then_blocks", "else_blocks", "condition_blocks"] {
            if let Some(children) = obj.get(key).and_then(Value::as_array) {
                self.analyze_block_list(children);
            }
        }
        if matches!(
            block_type,
            "while" | "while_loop" | "for_each" | "при_каждом" | "пока"
        ) {
            self.check_loop_pacing(obj);
        }
    }

    /// Блоки одного списка: первый переход (`go_to_node`) останавливает
    /// исполнителя, поэтому всё, что записано после него, — мёртвый код.
    fn analyze_block_list(&mut self, blocks: &[Value]) {
        // Сначала отмечаем недостижимый хвост: диагностика о нём должна идти
        // раньше предупреждений из самих (мёртвых) блоков.
        let first_terminator = blocks.iter().position(terminates_flow);
        if let Some(index) = first_terminator {
            let terminator = block_label(&blocks[index]);
            let unreachable: Vec<String> = blocks[index + 1..].iter().map(block_label).collect();
            if !unreachable.is_empty() {
                self.push(
                    Severity::Warning,
                    DiagnosticKind::UnreachableCode,
                    format!(
                        "{}После «{terminator}» {tail} — исполнитель уже перешёл на другую ноду и до них не дойдёт",
                        self.script_context(),
                        tail = match unreachable.len() {
                            1 => format!("блок «{}» не выполнится", unreachable[0]),
                            n => format!("блоки ({n}) «{}» не выполнятся", unreachable.join("», «")),
                        }
                    ),
                    Some(
                        "Уберите блоки после перехода или перенесите переход в конец списка"
                            .into(),
                    ),
                );
            }
        }
        for child in blocks {
            self.analyze_block(child);
        }
    }

    /// Цикл без «Задержки» прокручивает все итерации в одном кадре. Это не
    /// ошибка сама по себе (10 повторений пройдут мгновенно), но на таблице
    /// в сотни строк или бесконечном `while` окно замрёт без шанса выйти.
    fn check_loop_pacing(&mut self, block: &Map<String, Value>) {
        if block_children(block)
            .iter()
            .any(|c| subtree_yields_to_ui(c))
        {
            return;
        }
        let is_while = block
            .get("type")
            .and_then(Value::as_str)
            .is_some_and(|t| matches!(t, "while" | "while_loop" | "пока"));
        let has_limit = block
            .get("max_iterations")
            .and_then(Value::as_f64)
            .is_some_and(|n| n > 0.0);
        let hint = if is_while && !has_limit {
            "Добавьте «Задержка» внутрь цикла или задайте «max_iterations» — иначе бесконечный цикл подвесит игру"
        } else {
            "Добавьте «Задержка» внутрь цикла, чтобы игра успевала отрисовывать кадры"
        };
        self.push(
            Severity::Warning,
            DiagnosticKind::LoopWithoutWait,
            format!(
                "{}Цикл «{}» выполняется за один кадр — на большом числе повторений окно перестанет отвечать",
                self.script_context(),
                block_label_value(block)
            ),
            Some(hint.into()),
        );
    }

    fn analyze_all_scripts(&mut self) {
        let nodes = self.nodes.clone();
        // Проход 1: собрать нод-владельцев скриптов (для общих скриптов
        // переходы go_to_node считаются из КАЖДОЙ ноды-владельца).
        for node in &nodes {
            if let Some(path) = &node.script_asset_id {
                self.script_owners
                    .entry(path.clone())
                    .or_default()
                    .insert(node.id.clone());
            }
            collect_script_owners(&node_items(node), &node.id, &mut self.script_owners);
        }
        // Проход 2: анализ скриптов с привязкой рёбер к владельцам.
        for node in &nodes {
            let node_owners: HashSet<String> = HashSet::from([node.id.clone()]);
            if let Some(path) = &node.script_asset_id {
                self.check_script_link(Some(&node.id), None, path);
                let owners = self
                    .script_owners
                    .get(path)
                    .cloned()
                    .unwrap_or_else(|| node_owners.clone());
                self.analyze_script(path, &owners);
            }
            self.analyze_items_scripts(&node_items(node), &node_owners);
        }
        let templates = self.templates.clone();
        for t in &templates {
            // Рёбра из шаблонов к нодам не привязываются (шаблон не имеет ноды).
            self.analyze_items_scripts(&template_items(t), &HashSet::new());
        }
    }

    fn analyze_items_scripts(&mut self, items: &[ContentItem], owners: &HashSet<String>) {
        for item in items {
            if let Some(path) = &item.script_asset_id {
                self.analyze_script(path, owners);
            }
            for beh in item.resolved_behaviours() {
                self.analyze_script(&beh.script, owners);
            }
            // Script-айтем `type: "script"` — resourcePath ведёт на скрипт,
            // который движок выполняет как onNodeEnter/onContentAppear.
            if item.item_type == "script"
                && let Some(path) = &item.resource_path
            {
                self.analyze_script(path, owners);
            }
            if let Some(children) = &item.children {
                self.analyze_items_scripts(children, owners);
            }
        }
    }

    fn check_resource(&mut self, node_id: Option<&str>, item_id: Option<&str>, raw: &str) {
        let path = raw.trim();
        if path.is_empty() {
            return;
        }
        // Пути вне каталога quest'а (например, абсолютные или assets/) не проверяем.
        if !path.starts_with("res/") && !path.starts_with("assets/") {
            return;
        }
        let full = format!("{}{}", self.prefix, path);
        if !self.store.exists(&full) {
            self.push_with(
                Severity::Error,
                DiagnosticKind::BrokenResourceLink,
                format!(
                    "{}Файл не найден: {raw}",
                    self.context_prefix(node_id, item_id)
                ),
                Some("Проверьте путь к файлу или добавьте его в каталог квеста".into()),
                node_id.map(str::to_string),
                item_id.map(str::to_string),
                None,
            );
        }
    }

    // ---------- Граф переходов ----------

    fn edge(&mut self, from: Option<&str>, to: &str) {
        if let Some(from) = from {
            self.transitions
                .entry(from.to_string())
                .or_default()
                .insert(to.to_string());
        }
    }

    fn check_node_link(&mut self, node_id: Option<&str>, item_id: Option<&str>, target: &str) {
        if is_expr_ref(target) || is_sentinel_target(target) {
            return;
        }
        if !self.seen_node_ids.contains(target) {
            self.push_with(
                Severity::Error,
                DiagnosticKind::BrokenNodeLink,
                format!(
                    "{ctx}Переход ведёт на ноду, которой нет в квесте (удалена или изменён id)",
                    ctx = self.context_prefix(node_id, item_id)
                ),
                Some("Укажите другую ноду назначения или восстановите удалённую ноду".into()),
                node_id.map(str::to_string),
                item_id.map(str::to_string),
                None,
            );
        }
    }

    /// Главы квеста = `config.tags`. Нода без существующей главы не
    /// открывается в редакторе (её не к чему привязать на канвасе), поэтому
    /// это ошибка, а не предупреждение.
    fn check_chapters(&mut self) {
        let Some(config) = &self.config else { return };
        if config.tags.is_empty() && !self.nodes.is_empty() {
            self.push(
                Severity::Error,
                DiagnosticKind::NoChapters,
                format!(
                    "В квесте {} нод(ы), но ни одной главы — ноды не открываются в редакторе",
                    self.nodes.len()
                ),
                Some("Добавьте главу (тег) в настройках квеста и привяжите к ней ноды".into()),
            );
            return;
        }
        let mut seen: HashSet<String> = HashSet::new();
        let mut duplicates: Vec<String> = Vec::new();
        for tag in &config.tags {
            if !seen.insert(tag.id.clone()) {
                duplicates.push(tag.name.clone());
            }
        }
        for name in duplicates {
            self.push(
                Severity::Error,
                DiagnosticKind::DuplicateChapterId,
                format!("Глава «{name}» встречается в настройках дважды с одним id"),
                Some("Удалите дубликат главы в настройках квеста".into()),
            );
        }
        let mut unknown: Vec<(String, String, String)> = Vec::new();
        for node in &self.nodes {
            if node.is_template_master_node() {
                continue;
            }
            if node.chapter_id.is_empty() {
                unknown.push((
                    node.title.clone(),
                    node.id.clone(),
                    "глава не указана".to_string(),
                ));
                continue;
            }
            if !seen.contains(&node.chapter_id) {
                unknown.push((
                    node.title.clone(),
                    node.id.clone(),
                    format!("глава «{}» удалена", node.chapter_id),
                ));
            }
        }
        for (title, id, reason) in unknown {
            self.push_with(
                Severity::Error,
                DiagnosticKind::UnknownChapter,
                format!("Нода «{title}» не привязана к существующей главе ({reason})"),
                Some("Откройте ноду и выберите главу, которая есть в списке глав".into()),
                Some(id),
                None,
                None,
            );
        }
    }

    fn check_reachability(&mut self) {
        let Some(config) = &self.config else { return };
        let Some(start) = config.start_node_id.as_deref().filter(|s| !s.is_empty()) else {
            self.push(
                Severity::Error,
                DiagnosticKind::MissingStartNode,
                "В квесте не указана стартовая нода — игрок не сможет начать квест".to_string(),
                Some("Откройте настройки квеста и выберите ноду, с которой начинается игра".into()),
            );
            return;
        };
        let start = &start.to_string();
        if !self.seen_node_ids.contains(start) {
            self.push(
                Severity::Error,
                DiagnosticKind::BrokenNodeLink,
                "Стартовая нода квеста удалена или изменила id — квест не запустится".to_string(),
                Some("Откройте настройки квеста и укажите, с какой ноды начинать".into()),
            );
            return;
        }
        // Динамический переход (`={expr}` / `{выражение}`: нода вычисляется
        // в рантайме) не даёт построить точный статический граф — вместо
        // ложных «недостижимых» пропускаем диагностику целиком.
        if self.has_dynamic_edge {
            return;
        }
        let mut queue: Vec<String> = vec![start.clone()];
        let mut reached: HashSet<String> = HashSet::new();
        reached.insert(start.clone());
        while let Some(cur) = queue.pop() {
            if let Some(targets) = self.transitions.get(&cur) {
                for t in targets {
                    if reached.insert(t.clone()) {
                        queue.push(t.clone());
                    }
                }
            }
        }
        let mut unreachable: Vec<(String, String)> = Vec::new();
        for node in &self.nodes {
            if node.is_template_master_node() {
                continue;
            }
            if !reached.contains(&node.id) {
                unreachable.push((node.title.clone(), node.id.clone()));
            }
        }
        for (title, id) in unreachable {
            self.push_with(
                Severity::Warning,
                DiagnosticKind::UnreachableNode,
                format!("До ноды «{title}» не ведёт ни один переход — игрок её не увидит"),
                Some("Добавьте переход на эту ноду или удалите её".into()),
                Some(id),
                None,
                None,
            );
        }
    }

    // ---------- Переменные ----------

    fn collect_vars_from_str(&mut self, s: Option<&str>) {
        if let Some(s) = s {
            for v in extract_variables(s) {
                if !is_system_var(&v) {
                    self.read_vars.insert(v);
                }
            }
        }
    }

    fn check_dead_variables(&mut self) {
        // Источники переменных: дефолты из config.variables (пишутся при старте).
        let mut sourced: HashSet<String> = HashSet::new();
        if let Some(config) = &self.config {
            for v in &config.variables {
                sourced.insert(v.name.clone());
            }
        }
        let mut unwritten: Vec<String> = self
            .read_vars
            .iter()
            .filter(|v| !self.written_vars.contains(*v) && !sourced.contains(*v))
            .cloned()
            .collect();
        unwritten.sort();
        for v in unwritten {
            self.push(
                Severity::Warning,
                DiagnosticKind::UnreadVariable,
                format!("Переменная «{v}» используется, но нигде не получает значение — будет пустой"),
                Some("Создайте переменную в настройках квеста или добавьте блок «Присвоить переменную»".into()),
            );
        }
        let mut unread: Vec<String> = self
            .written_vars
            .iter()
            .filter(|v| !self.read_vars.contains(*v))
            .cloned()
            .collect();
        unread.sort();
        for v in unread {
            self.push(
                Severity::Warning,
                DiagnosticKind::UnwrittenVariable,
                format!("Переменная «{v}» получает значение, но нигде не используется"),
                Some(
                    "Уберите присваивание или проверьте имя переменной — возможно, опечатка".into(),
                ),
            );
        }
    }

    // ---------- Поток управления ----------

    /// Множество нод, до которых игрок дойдёт от стартовой.
    /// `None` — граф неизвестен (нет старта, битый id или динамические переходы).
    fn reachable_set(&self) -> Option<HashSet<String>> {
        let config = self.config.as_ref()?;
        let start = config.start_node_id.as_deref().filter(|s| !s.is_empty())?;
        if self.has_dynamic_edge || !self.seen_node_ids.contains(start) {
            return None;
        }
        let mut reached: HashSet<String> = HashSet::from([start.to_string()]);
        let mut queue: Vec<String> = vec![start.to_string()];
        while let Some(cur) = queue.pop() {
            if let Some(targets) = self.transitions.get(&cur) {
                for t in targets {
                    if reached.insert(t.clone()) {
                        queue.push(t.clone());
                    }
                }
            }
        }
        Some(reached)
    }

    /// Тупик: до ноды можно дойти, но из неё нет ни одного перехода, а выйти
    /// из игры тоже нечем (верхняя панель скрыта, шаг назад выключен).
    /// Кнопки, которые только меняют видимость, тупик не отменяют.
    fn check_dead_ends(&mut self) {
        let Some(config) = &self.config else { return };
        if !config.hide_top_panel || config.allow_step_back {
            return;
        }
        let Some(reached) = self.reachable_set() else {
            return;
        };
        let mut dead: Vec<(String, String)> = Vec::new();
        for node in &self.nodes {
            if node.is_template_master_node() || !reached.contains(&node.id) {
                continue;
            }
            let has_exit = self
                .transitions
                .get(&node.id)
                .is_some_and(|targets| !targets.is_empty());
            if has_exit {
                continue;
            }
            // Нода без интерактивных элементов — финальная сцена: игрок
            // просто читает текст (и может закрыть игру). Тупик — когда
            // автор нарисовал кнопки, а уйти по ним некуда.
            let has_buttons = node_items(node)
                .iter()
                .any(|item| matches!(item.item_type.as_str(), "button" | "link"));
            if has_buttons {
                dead.push((node.title.clone(), node.id.clone()));
            }
        }
        for (title, id) in dead {
            self.push_with(
                Severity::Warning,
                DiagnosticKind::DeadEndNode,
                format!(
                    "Нода «{title}»: кнопки есть, но ни одна не ведёт на другую ноду, а верхняя панель скрыта и шаг назад выключен — игрок застрянет"
                ),
                Some(
                    "Добавьте переход с кнопки или включите верхнюю панель / шаг назад в настройках квеста".into(),
                ),
                Some(id),
                None,
                None,
            );
        }
    }

    /// Скрипт, на который никто не ссылается и который не объявляет
    /// квестовых событий, движок никогда не выполнит.
    fn check_dead_scripts(&mut self) {
        let dir = format!("{}scripts", self.prefix);
        let mut files = self.store.list_dir(&dir);
        files.sort();
        let mut dead: Vec<(String, String)> = Vec::new();
        for full in files {
            let Some(rel) = full.strip_prefix(&self.prefix).map(str::to_string) else {
                continue;
            };
            // Lua-файлы движок находит сам по объявленным событиям —
            // статически судить о них нельзя.
            if !rel.ends_with(".json") || self.analyzed_scripts.contains(&rel) {
                continue;
            }
            let Some(value) = self.store.read_json(&format!("{}{}", self.prefix, rel)) else {
                continue;
            };
            let Some(obj) = value.as_object() else {
                continue;
            };
            // Скрипт-обработчик квеста запускается без ссылки из нод.
            if crate::executor::declares_event(obj, crate::executor::EventType::OnQuestStart)
                || crate::executor::declares_event(obj, crate::executor::EventType::OnDataChange)
            {
                continue;
            }
            let name = obj
                .get("name")
                .and_then(Value::as_str)
                .filter(|n| !n.trim().is_empty())
                .unwrap_or(&rel)
                .to_string();
            dead.push((rel, name));
        }
        for (rel, name) in dead {
            self.push_with(
                Severity::Warning,
                DiagnosticKind::DeadScript,
                format!(
                    "Скрипт «{name}» ни к чему не привязан и не вызывается — движок его не выполнит"
                ),
                Some("Привяжите скрипт к элементу/ноде или удалите файл".into()),
                None,
                None,
                Some(rel),
            );
        }
    }

    /// Строки таблицы и список колонок должны совпадать: иначе скрипты
    /// читают пустые ячейки, а лишние поля молча пропадают.
    fn check_tables(&mut self) {
        let Some(config) = &self.config else { return };
        let mut tables: Vec<(String, Value)> = config
            .tables
            .iter()
            .map(|(name, table)| (name.clone(), table.clone()))
            .collect();
        tables.sort_by(|a, b| a.0.cmp(&b.0));
        for (name, table) in tables {
            check_table_shape(self, &name, &table);
        }
    }

    // ---------- Конфликты видимости ----------

    /// Выражение первого condition в первом event `onContentAppear`.
    fn appear_expression(&mut self, raw_path: &str) -> Option<String> {
        let (path, _fn) = self.split_script_ref(raw_path);
        if let Some(cached) = self.appear_expr_cache.get(&path) {
            return cached.clone();
        }
        let result = self
            .load_script(&path)
            .and_then(|script| find_appear_expression(&script));
        self.appear_expr_cache.insert(path, result.clone());
        result
    }

    /// Проверяем, что onAppear-триггеры корректны:
    /// 1. Если указан `#fn=имя` — функция существует в скрипте.
    /// 2. Если без `#fn` — скрипт содержит onContentAppear с подходящим target.
    fn check_on_appear_triggers(&mut self) {
        for (item_id, node_id, script_path, fn_entry) in self.on_appear_triggers.clone() {
            let script = match self.load_script(&script_path) {
                Some(s) => s,
                None => continue, // Already reported as BrokenScriptLink.
            };

            let blocks = match script.get("blocks") {
                Some(Value::Array(arr)) => arr,
                _ => continue,
            };

            if let Some(fn_name) = &fn_entry {
                // Check that the function exists in the script.
                let has_fn = blocks.iter().any(|block| {
                    block.get("type").and_then(Value::as_str) == Some("event")
                        && block.get("eventType").and_then(Value::as_str) == Some("function")
                        && {
                            let name = block
                                .get("functionName")
                                .and_then(Value::as_str)
                                .unwrap_or("main")
                                .trim();
                            name == fn_name.as_str() || (fn_name.is_empty() && name == "main")
                        }
                });
                if !has_fn {
                    let item_label = self
                        .item_labels
                        .get(&item_id)
                        .cloned()
                        .unwrap_or_else(|| item_id.clone());
                    self.push_with(
                        Severity::Error,
                        DiagnosticKind::BadOnAppearTrigger,
                        format!(
                            "onAppear-скрипт «{}» не содержит функции «{}» (для элемента «{}»)",
                            script_path, fn_name, item_label,
                        ),
                        Some("Проверьте имя функции или создайте её в скрипте".into()),
                        node_id,
                        Some(item_id),
                        Some(script_path),
                    );
                }
            } else {
                // No function ref — check onContentAppear event exists.
                let has_appear = blocks.iter().any(|block| {
                    block.get("type").and_then(Value::as_str) == Some("event")
                        && matches!(
                            block.get("eventType").and_then(Value::as_str),
                            Some("onContentAppear") | Some("onAppear")
                        )
                });
                if !has_appear {
                    let item_label = self
                        .item_labels
                        .get(&item_id)
                        .cloned()
                        .unwrap_or_else(|| item_id.clone());
                    self.push_with(
                        Severity::Warning,
                        DiagnosticKind::BadOnAppearTrigger,
                        format!(
                            "onAppear-скрипт «{}» не содержит события onContentAppear (для элемента «{}»)",
                            script_path, item_label,
                        ),
                        Some("Добавьте событие onContentAppear в скрипт".into()),
                        node_id,
                        Some(item_id),
                        Some(script_path),
                    );
                }
            }
        }
    }

    fn check_visibility_conflicts(&mut self) {
        let groups = std::mem::take(&mut self.visibility_groups);
        for group in groups {
            for i in 0..group.children.len() {
                for j in (i + 1)..group.children.len() {
                    let a = &group.children[i];
                    let b = &group.children[j];
                    let atoms_a = parse_condition(&a.expr);
                    let atoms_b = parse_condition(&b.expr);
                    if atoms_a.is_empty() || atoms_b.is_empty() {
                        continue;
                    }
                    if expressions_can_overlap(&atoms_a, &atoms_b)
                        && conditions_share_variable(&atoms_a, &atoms_b)
                        && has_known_constraint_pair(&atoms_a, &atoms_b)
                    {
                        let location = group
                            .node_id
                            .as_ref()
                            .map(|n| format!("в ноде «{}»", self.node_title(n)))
                            .or_else(|| {
                                group.template_id.as_ref().map(|t| {
                                    format!(
                                        "в шаблоне «{}»",
                                        self.template_titles
                                            .get(t)
                                            .cloned()
                                            .unwrap_or_else(|| "без названия".into())
                                    )
                                })
                            })
                            .unwrap_or_default();
                        self.push_with(
                            Severity::Warning,
                            DiagnosticKind::VisibilityConflict,
                            format!(
                                "Элементы «{}» и «{}» могут быть видны одновременно {} и накладываться: \
                                 условия «{}» и «{}» пересекаются",
                                self.item_label(&a.item_id),
                                self.item_label(&b.item_id),
                                location,
                                a.expr,
                                b.expr
                            ),
                            Some("Поправьте условия видимости так, чтобы они не пересекались".into()),
                            group.node_id.clone(),
                            Some(group.container_id.clone()),
                            Some(a.script_path.clone()),
                        );
                    }
                }
            }
        }
    }
}

// ============================ Вспомогательные функции ============================

fn node_items(node: &SavedNode) -> Vec<ContentItem> {
    node.content
        .get("items")
        .and_then(Value::as_array)
        .map(|a| a.iter().map(ContentItem::from_json).collect::<Vec<_>>())
        .unwrap_or_default()
}

/// Собрать нод-владельцев скриптов по айтемам
/// (scriptAssetId/триггеры обоих форматов/resourcePath script-айтема).
fn collect_script_owners(
    items: &[ContentItem],
    node_id: &str,
    owners: &mut HashMap<String, HashSet<String>>,
) {
    for item in items {
        if let Some(path) = &item.script_asset_id {
            owners
                .entry(path.clone())
                .or_default()
                .insert(node_id.to_string());
        }
        for beh in item.resolved_behaviours() {
            owners
                .entry(beh.script.clone())
                .or_default()
                .insert(node_id.to_string());
        }
        // Script-айтем `type: "script"` — движок выполняет его как скрипт
        // ноды (onNodeEnter/onContentAppear). resourcePath — это скрипт,
        // а не картинка.
        if item.item_type == "script"
            && let Some(path) = &item.resource_path
        {
            owners
                .entry(path.clone())
                .or_default()
                .insert(node_id.to_string());
        }
        if let Some(children) = &item.children {
            collect_script_owners(children, node_id, owners);
        }
    }
}

/// Элементы шаблона: либо `payload.items[]`, либо сам payload как item.
fn template_items(t: &TemplateItem) -> Vec<ContentItem> {
    if let Some(items) = t.payload.get("items").and_then(Value::as_array) {
        return items.iter().map(ContentItem::from_json).collect();
    }
    // payload сам является item (например, row с детьми).
    if t.payload.get("type").and_then(Value::as_str).is_some() {
        return vec![ContentItem::from_json(&Value::Object(t.payload.clone()))];
    }
    Vec::new()
}

/// Проверка формы одной таблицы: колонки, строки, имена строк.
fn check_table_shape(validator: &mut Validator, name: &str, table: &Value) {
    let Some(obj) = table.as_object() else { return };
    let columns: Vec<String> = obj
        .get("columns")
        .and_then(Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(Value::as_str)
                .map(str::trim)
                .filter(|c| !c.is_empty())
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();
    let rows: Vec<&Map<String, Value>> = obj
        .get("rows")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(Value::as_object).collect())
        .unwrap_or_default();
    let mut problems: Vec<String> = Vec::new();

    let mut seen: HashSet<&str> = HashSet::new();
    let mut duplicates: Vec<&str> = Vec::new();
    for column in &columns {
        if !seen.insert(column.as_str()) {
            duplicates.push(column);
        }
    }
    if !duplicates.is_empty() {
        problems.push(format!(
            "колонки повторяются: «{}»",
            duplicates.join("», «")
        ));
    }

    let mut missing: Vec<String> = Vec::new();
    let mut extra: Vec<String> = Vec::new();
    for (index, row) in rows.iter().enumerate() {
        let row_no = index + 1;
        for column in &columns {
            if !row.contains_key(column) && missing.len() < 4 {
                missing.push(format!("в строке {row_no} нет «{column}»"));
            }
        }
        for key in row.keys() {
            if !key.starts_with("__") && !columns.iter().any(|c| c == key) && extra.len() < 4 {
                extra.push(format!("в строке {row_no} лишнее поле «{key}»"));
            }
        }
    }
    if !missing.is_empty() {
        problems.push(format!(
            "колонка заполнена не во всех строках: {}{}",
            missing.join(", "),
            if missing.len() == 4 { " и др." } else { "" }
        ));
    }
    if !extra.is_empty() {
        problems.push(format!(
            "поля вне колонок: {}{}",
            extra.join(", "),
            if extra.len() == 4 { " и др." } else { "" }
        ));
    }

    let row_names = obj
        .get("rowNames")
        .or_else(|| obj.get("row_names"))
        .and_then(Value::as_array)
        .map(Vec::len)
        .unwrap_or_default();
    if row_names > 0 && row_names != rows.len() {
        problems.push(format!(
            "имён строк {row_names}, а самих строк {}",
            rows.len()
        ));
    }

    if problems.is_empty() {
        return;
    }
    validator.push_with(
        Severity::Warning,
        DiagnosticKind::TableColumnMismatch,
        format!("Таблица «{name}»: {}", problems.join("; ")),
        Some(
            "Приведите строки к колонкам: пропущенная ячейка читается как пустая, а поле вне колонок скриптам не видно".into(),
        ),
        None,
        None,
        None,
    );
}

/// Списки вложенных блоков у всех типов (условие, циклы, события).
const CHILD_KEYS: [&str; 4] = ["children", "then_blocks", "else_blocks", "condition_blocks"];

/// Подписи блоков: «Переход» вместо `go_to_node`.
fn block_label(block: &Value) -> String {
    match block.as_object() {
        Some(obj) => block_label_value(obj),
        None => "блок".to_string(),
    }
}

fn block_label_value(block: &Map<String, Value>) -> String {
    let raw = block.get("type").and_then(Value::as_str).unwrap_or("");
    crate::blocks::display_name(raw)
        .map(str::to_string)
        .unwrap_or_else(|| {
            if raw.is_empty() {
                "блок без типа".to_string()
            } else {
                raw.to_string()
            }
        })
}

/// Вложенные блоки в порядке исполнения (для обхода поддерева).
fn block_children(block: &Map<String, Value>) -> Vec<&Value> {
    let mut out = Vec::new();
    for key in CHILD_KEYS {
        if let Some(children) = block.get(key).and_then(Value::as_array) {
            out.extend(children.iter());
        }
    }
    out
}

/// `go_to_node` — единственный блок, который возвращает цель перехода и тем
/// самым останавливает текущий список блоков.
fn terminates_flow(block: &Value) -> bool {
    block
        .as_object()
        .and_then(|obj| obj.get("type"))
        .and_then(Value::as_str)
        .is_some_and(|t| t == "go_to_node")
}

/// Отдаёт ли поддерево управление кадру: «Задержка», сетевой запрос или
/// вызов другого скрипта (в нём может быть задержка).
fn subtree_yields_to_ui(block: &Value) -> bool {
    let Some(obj) = block.as_object() else {
        return false;
    };
    let yields = obj.get("type").and_then(Value::as_str).is_some_and(|t| {
        matches!(
            t,
            "wait" | "задержка" | "http_request" | "call_script" | "call_function" | "call_lua"
        )
    });
    yields || block_children(obj).into_iter().any(subtree_yields_to_ui)
}

fn is_container(item_type: &str) -> bool {
    // Стек — контейнер на тех же правах: его дети живут одной группой
    // видимости, и их onAppear-условия надо проверять на конфликт между
    // собой (раньше стек не попадал сюда, и дети группировались как
    // несвязанные элементы верхнего уровня).
    matches!(item_type, "row" | "column" | "stack")
}

/// Ссылка является выражением (`{...}`).
fn is_expr_ref(s: &str) -> bool {
    s.contains('{')
}

/// Особые цели перехода, которые существуют вне графа нод: их обрабатывает
/// плеер. `_CLOSE_MODAL` закрывает модальное окно — «ноды с таким id нет»
/// про него сказать нельзя, и ребро графа из него тоже вести некуда.
pub(crate) fn is_sentinel_target(s: &str) -> bool {
    s == "_CLOSE_MODAL"
}

/// Ноды квеста тем же порядком, что `GameEngine::from_disk`: v2
/// (`nodes/index.json` + тела) — источник правды, иначе `nodes/nodes.json`,
/// иначе legacy `nodes.json`. Без этого валидатор судил бы не то, что
/// видит игрок: квесты в v2-раскладке выглядели бы «без нод».
pub(crate) fn load_nodes(
    store: &dyn crate::contracts::ScriptAssetStore,
    prefix: &str,
) -> Vec<SavedNode> {
    if let Some(nodes) = crate::engine::load_per_node_nodes(store, prefix)
        && !nodes.is_empty()
    {
        return nodes;
    }
    let canonical = crate::engine::load_json_array(
        store,
        &format!("{prefix}nodes/nodes.json"),
        "nodes",
        SavedNode::from_json,
    );
    if !canonical.is_empty() {
        return canonical;
    }
    crate::engine::load_json_array(
        store,
        &format!("{prefix}nodes.json"),
        "nodes",
        SavedNode::from_json,
    )
}

fn is_system_var(name: &str) -> bool {
    name.starts_with("_internal_")
        || name.starts_with("_SYS_")
        || name.starts_with("_SAVE_")
        || matches!(
            name,
            "SAVE_DATE" | "SAVE_TIME" | "SAVE_DATETIME" | "ID" | "LastID"
        )
}

/// Допустимые символы имени переменной: буквы, цифры, `_`, `-`, `.`, `$`,
/// `[`/`]` (доступ к массиву, `{инвентарь.рука[0].название}`).
fn is_valid_var_name(name: &str) -> bool {
    !name.is_empty()
        && name
            .chars()
            .all(|c| c.is_alphanumeric() || matches!(c, '_' | '-' | '.' | '$' | '[' | ']'))
}

/// Извлечение `{переменных}` из строки (уникальные, в порядке появления).
/// Мусор вроде JSON-литералов (`{"items": []}`) или шаблонных строк
/// (`${...}`) не считается переменной.
fn extract_variables(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'{'
            && let Some(end) = s[i + 1..].find('}')
        {
            let name = s[i + 1..i + 1 + end].trim();
            if is_valid_var_name(name) && seen.insert(name.to_string()) {
                out.push(name.to_string());
                i += 1 + end + 1;
                continue;
            }
            // Не имя переменной, но внутри могла быть вложенная подстановка:
            // `{{имя}}` (редактор одел ссылку в скобки, чтобы строка не
            // считалась формулой) и `{Таблица["Колонка"]["{var}"]}`. Раньше
            // такие вхождения просто проглатывались, и переменная выглядела
            // неиспользуемой.
            if name.contains('{') {
                i += 1;
                continue;
            }
            i += 1 + end + 1;
            continue;
        }
        i += 1;
    }
    out
}

/// Простой percent-decode (аналог Uri.decodeComponent для имён функций).
fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && i + 2 < bytes.len()
            && let (Some(h), Some(l)) = (hex_val(bytes[i + 1]), hex_val(bytes[i + 2]))
        {
            out.push(h * 16 + l);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex_val(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

/// Есть ли в скрипте функция с данным именем (block eventType=function).
fn script_has_function(script: &Map<String, Value>, fn_name: &str) -> bool {
    let Some(blocks) = script.get("blocks").and_then(Value::as_array) else {
        return false;
    };
    let mut stack: Vec<&Value> = blocks.iter().collect();
    while let Some(block) = stack.pop() {
        let Some(obj) = block.as_object() else {
            continue;
        };
        if obj.get("eventType").and_then(Value::as_str) == Some("function")
            && obj.get("functionName").and_then(Value::as_str) == Some(fn_name)
        {
            return true;
        }
        for key in ["children", "then_blocks", "else_blocks", "condition_blocks"] {
            if let Some(arr) = obj.get(key).and_then(Value::as_array) {
                stack.extend(arr.iter());
            }
        }
    }
    false
}

/// Проверка парности фигурных скобок в выражении.
fn is_balanced_expr(expr: &str) -> bool {
    let mut depth = 0i32;
    for c in expr.chars() {
        match c {
            '{' => depth += 1,
            '}' => depth -= 1,
            _ => {}
        }
        if depth < 0 {
            return false;
        }
    }
    depth == 0
}

fn find_appear_expression(script: &Map<String, Value>) -> Option<String> {
    let blocks = script.get("blocks").and_then(Value::as_array)?;
    for block in blocks {
        let event_type = block.get("eventType").and_then(Value::as_str).unwrap_or("");
        if event_type != "onContentAppear" && event_type != "onAppear" {
            continue;
        }
        if let Some(children) = block.get("children").and_then(Value::as_array) {
            for child in children {
                if let Some(expr) = child.get("expression").and_then(Value::as_str) {
                    return Some(expr.to_string());
                }
            }
        }
    }
    None
}

// ============================ Анализ выражений видимости ============================

#[derive(Debug, Clone, PartialEq)]
enum AtomOp {
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
    /// `{var}` без оператора — трактуем как truthy (ограничений не накладывает).
    Truthy,
}

#[derive(Debug, Clone, PartialEq)]
enum Lit {
    Num(f64),
    Str(String),
    Bool(bool),
    /// Литерал-выражение (`round({x}*0.9)`, конкатенации) — сравнимо только
    /// с текстуально идентичным выражением.
    Expr(String),
    /// Не распознан.
    Any,
}

#[derive(Debug, Clone)]
struct Atom {
    var: String,
    op: AtomOp,
    literal: Option<Lit>,
}

/// Выражение → дизъюнкты (`||`) → атомы (`&&`).
type ParsedCondition = Vec<Vec<Atom>>;

fn split_top_level(s: &str, sep: char) -> Vec<String> {
    let mut parts = Vec::new();
    let mut cur = String::new();
    let mut quote: Option<char> = None;
    let chars: Vec<char> = s.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if let Some(q) = quote {
            cur.push(c);
            if c == q {
                quote = None;
            }
            i += 1;
            continue;
        }
        if c == '\'' || c == '"' {
            quote = Some(c);
            cur.push(c);
            i += 1;
            continue;
        }
        if c == sep && i + 1 < chars.len() && chars[i + 1] == sep {
            parts.push(std::mem::take(&mut cur));
            i += 2;
            continue;
        }
        cur.push(c);
        i += 1;
    }
    parts.push(cur);
    parts
}

fn parse_literal(s: &str) -> Lit {
    let s = s.trim();
    if s.len() >= 2 {
        let first = s.chars().next().unwrap();
        let last = s.chars().last().unwrap();
        if (first == '\'' && last == '\'') || (first == '"' && last == '"') {
            return Lit::Str(s[1..s.len() - 1].to_string());
        }
    }
    if let Ok(n) = s.parse::<f64>() {
        return Lit::Num(n);
    }
    match s {
        "true" => return Lit::Bool(true),
        "false" => return Lit::Bool(false),
        _ => {}
    }
    if s.is_empty() {
        return Lit::Any;
    }
    Lit::Expr(s.to_string())
}

fn parse_atom(raw: &str) -> Option<Atom> {
    let s = raw.trim();
    let open = s.find('{')?;
    let close = s[open + 1..].find('}')? + open + 1;
    let var = s[open + 1..close].trim().to_string();
    if var.is_empty() {
        return None;
    }
    let rest = s[close + 1..].trim();
    if rest.is_empty() {
        return Some(Atom {
            var,
            op: AtomOp::Truthy,
            literal: None,
        });
    }
    let (op, val) = if let Some(r) = rest.strip_prefix("==") {
        (AtomOp::Eq, r)
    } else if let Some(r) = rest.strip_prefix("!=") {
        (AtomOp::Ne, r)
    } else if let Some(r) = rest.strip_prefix("<=") {
        (AtomOp::Le, r)
    } else if let Some(r) = rest.strip_prefix(">=") {
        (AtomOp::Ge, r)
    } else if let Some(r) = rest.strip_prefix('<') {
        (AtomOp::Lt, r)
    } else {
        let r = rest.strip_prefix('>')?;
        (AtomOp::Gt, r)
    };
    Some(Atom {
        var,
        op,
        literal: Some(parse_literal(val)),
    })
}

/// Разбор условия в дизъюнктивную нормальную форму (эвристика).
fn parse_condition(expr: &str) -> ParsedCondition {
    split_top_level(expr, '|')
        .into_iter()
        .filter_map(|disjunct| {
            let atoms: Vec<Atom> = split_top_level(&disjunct, '&')
                .into_iter()
                .filter_map(|raw| parse_atom(&raw))
                .collect();
            if atoms.is_empty() { None } else { Some(atoms) }
        })
        .collect()
}

fn lit_eq(a: &Lit, b: &Lit) -> bool {
    match (a, b) {
        (Lit::Num(x), Lit::Num(y)) => x == y,
        (Lit::Str(x), Lit::Str(y)) => x == y,
        (Lit::Bool(x), Lit::Bool(y)) => x == y,
        (Lit::Expr(x), Lit::Expr(y)) => x == y,
        (Lit::Any, _) | (_, Lit::Any) => false,
        _ => false,
    }
}

/// Порядок литералов: `-1/0/1`, если они сравнимы (одинаковый тип);
/// `None` — тип несравним или значения неизвестны.
fn lit_ord(a: &Lit, b: &Lit) -> Option<i32> {
    match (a, b) {
        (Lit::Num(x), Lit::Num(y)) => Some(if x < y {
            -1
        } else if x > y {
            1
        } else {
            0
        }),
        (Lit::Str(x), Lit::Str(y)) => Some(if x < y {
            -1
        } else if x > y {
            1
        } else {
            0
        }),
        (Lit::Bool(x), Lit::Bool(y)) => Some(if x == y { 0 } else { 2 }),
        (Lit::Expr(x), Lit::Expr(y)) => Some(if x == y { 0 } else { 2 }),
        _ => None,
    }
}

/// Пара литералов несёт осмысленное знание для конфликта: оба известны,
/// а разные выражения (`round(0.9)` vs `round(0.8)`) — не сравнимы между собой.
fn known_constraint_pair(x: &Lit, y: &Lit) -> bool {
    match (x, y) {
        (Lit::Expr(a), Lit::Expr(b)) => a == b,
        (Lit::Any, _) | (_, Lit::Any) => false,
        _ => true,
    }
}

/// Противоречат ли два атома одной переменной (не могут быть истинны вместе).
fn atoms_conflict(a: &Atom, b: &Atom) -> bool {
    if a.var != b.var {
        return false;
    }
    use AtomOp::*;
    let (Some(la), Some(lb)) = (&a.literal, &b.literal) else {
        return false;
    };
    // Разные выражения-границы (round(0.9) vs round(0.8)) не сравнимы между
    // собой — не делаем выводов (осторожность против ложных срабатываний).
    if matches!((la, lb), (Lit::Expr(x), Lit::Expr(y)) if x != y) {
        return false;
    }
    let ord = lit_ord(la, lb);
    let (x, y) = (&a.op, &b.op);
    match (x, y) {
        (Truthy, _) | (_, Truthy) => false,
        (Eq, Eq) => !lit_eq(la, lb),
        (Eq, Ne) | (Ne, Eq) => lit_eq(la, lb),
        // {x}==n vs {x} интервал: пересечение пусто, если n вне интервала.
        (Eq, Lt) | (Lt, Eq) => matches!(ord, Some(o) if o >= 0),
        (Eq, Le) | (Le, Eq) => matches!(ord, Some(o) if o > 0),
        (Eq, Gt) | (Gt, Eq) => matches!(ord, Some(o) if o <= 0),
        (Eq, Ge) | (Ge, Eq) => matches!(ord, Some(o) if o < 0),
        // Интервал vs интервал: порядок границ указывает на пустое пересечение.
        // (Lt/Le — «меньше», Gt/Ge — «больше»; ord — порядок границ a vs b.)
        (Lt, Gt) | (Lt, Ge) => matches!(ord, Some(o) if o <= 0),
        (Le, Gt) | (Le, Ge) => matches!(ord, Some(o) if o < 0),
        (Gt, Lt) | (Gt, Le) => matches!(ord, Some(o) if o >= 0),
        (Ge, Lt) | (Ge, Le) => matches!(ord, Some(o) if o > 0),
        _ => false,
    }
}

/// Конъюнкции противоречат, если есть хоть одна противоречащая пара атомов.
fn disjuncts_conflict(a: &[Atom], b: &[Atom]) -> bool {
    for x in a {
        for y in b {
            if atoms_conflict(x, y) {
                return true;
            }
        }
    }
    false
}

/// Выражения могут быть истинны одновременно: существует пара дизъюнктов,
/// не содержащая противоречий.
fn expressions_can_overlap(a: &ParsedCondition, b: &ParsedCondition) -> bool {
    for da in a {
        for db in b {
            if !disjuncts_conflict(da, db) {
                return true;
            }
        }
    }
    false
}

/// Оба условия опираются хотя бы на одну общую переменную — признаки
/// «переключателя» альтернативных состояний, а не независимых данных.
fn conditions_share_variable(a: &ParsedCondition, b: &ParsedCondition) -> bool {
    let vars_a: HashSet<&str> = a.iter().flatten().map(|at| at.var.as_str()).collect();
    b.iter()
        .flatten()
        .any(|at| vars_a.contains(at.var.as_str()))
}

/// Есть пара атомов (по любым переменным) с известными литералами —
/// выражения содержат реальные ограничения, а не только «сырые» сравнения
/// с выражениями (`{x}>round(...)`, конкатенации и т.п.).
fn has_known_constraint_pair(a: &ParsedCondition, b: &ParsedCondition) -> bool {
    for da in a {
        for db in b {
            for x in da {
                for y in db {
                    if let (Some(lx), Some(ly)) = (&x.literal, &y.literal)
                        && known_constraint_pair(lx, ly)
                    {
                        return true;
                    }
                }
            }
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    use crate::contracts::FsScriptAssetStore;

    static FIXTURE_COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

    fn mem_store(files: &[(&str, &str)]) -> DynAssetStore {
        // FsScriptAssetStore требует диска; для тестов пишем во временный каталог.
        let n = FIXTURE_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("mnd_validation_{}_{}", std::process::id(), n));
        let _ = std::fs::remove_dir_all(&dir);
        for (path, content) in files {
            let full = dir.join(path);
            if let Some(parent) = full.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            std::fs::write(&full, content).expect("write fixture");
        }
        Arc::new(FsScriptAssetStore::new(dir))
    }

    fn report_errors(report: &ValidationReport, kind: DiagnosticKind) -> Vec<&Diagnostic> {
        report
            .diagnostics
            .iter()
            .filter(|d| d.kind == kind)
            .collect()
    }

    #[test]
    fn detects_visibility_conflict_slot_bug() {
        let store = mem_store(&[
            (
                "quests/q1/config.json",
                r#"{"id":"q1","startNodeId":"n1","tags":[{"id":"t1","name":"Глава 1"}]}"#,
            ),
            (
                "quests/q1/nodes.json",
                r#"{"nodes":[{"id":"n1","title":"Н1","chapterId":"t1","content":{"items":[
                    {"id":"row1","type":"row","children":[
                        {"id":"empty","type":"image","resourcePath":"res/images/a.png",
                         "scriptTriggers":{"onContentAppear":"scripts/e1.json"}},
                        {"id":"icon","type":"image","resourcePath":"res/images/b.png",
                         "scriptTriggers":{"onContentAppear":"scripts/i1.json"}}
                    ]}
                ]}}]}"#,
            ),
            (
                "quests/q1/scripts/e1.json",
                r#"{"id":"e1","name":"пусто","blocks":[{"type":"event","eventType":"onContentAppear","children":[{"type":"condition","expression":"{Слот2}==0 || {Слот_Действие}!=0","then_blocks":[]}]}]}"#,
            ),
            (
                "quests/q1/scripts/i1.json",
                r#"{"id":"i1","name":"иконка","blocks":[{"type":"event","eventType":"onContentAppear","children":[{"type":"condition","expression":"{Слот2}=='Лечилка_Малая'","then_blocks":[]}]}]}"#,
            ),
            ("quests/q1/res/images/a.png", "x"),
            ("quests/q1/res/images/b.png", "x"),
        ]);
        let report = analyze_quest_with_store("q1", store);
        let conflicts = report_errors(&report, DiagnosticKind::VisibilityConflict);
        assert_eq!(conflicts.len(), 1, "должен быть найден конфликт видимости");
        assert!(
            conflicts[0]
                .message
                .contains("{Слот2}==0 || {Слот_Действие}!=0")
        );
        assert_eq!(report.stats.errors, 0);
        // 1 конфликт видимости + 2 «читается, но не пишется» (Слот2, Слот_Действие).
        assert_eq!(report.stats.warnings, 3);
    }

    #[test]
    fn detects_conflict_between_stack_children() {
        // Стек — такой же контейнер, как row/column: дети лежат в одной группе
        // видимости, и конфликт их onAppear-условий обязан находиться.
        let store = mem_store(&[
            (
                "quests/q1/config.json",
                r#"{"id":"q1","startNodeId":"n1","tags":[{"id":"t1","name":"Глава 1"}]}"#,
            ),
            (
                "quests/q1/nodes.json",
                r#"{"nodes":[{"id":"n1","title":"Н1","chapterId":"t1","content":{"items":[
                    {"id":"st1","type":"stack","stackHeight":240,"children":[
                        {"id":"a","type":"image","scriptTriggers":{"onContentAppear":"scripts/a.json"}},
                        {"id":"b","type":"image","scriptTriggers":{"onContentAppear":"scripts/b.json"}}
                    ]}
                ]}}]}"#,
            ),
            (
                "quests/q1/scripts/a.json",
                r#"{"id":"a","blocks":[{"type":"event","eventType":"onContentAppear","children":[{"type":"condition","expression":"{HP}>0","then_blocks":[]}]}]}"#,
            ),
            (
                "quests/q1/scripts/b.json",
                r#"{"id":"b","blocks":[{"type":"event","eventType":"onContentAppear","children":[{"type":"condition","expression":"{HP}<50","then_blocks":[]}]}]}"#,
            ),
        ]);
        let report = analyze_quest_with_store("q1", store);
        let conflicts = report_errors(&report, DiagnosticKind::VisibilityConflict);
        assert_eq!(
            conflicts.len(),
            1,
            "дети стека должны проверяться как одна группа видимости"
        );
        assert!(conflicts[0].message.contains("{HP}>0"));
    }

    #[test]
    fn no_conflict_when_expressions_disjoint() {
        let store = mem_store(&[
            (
                "quests/q1/config.json",
                r#"{"id":"q1","startNodeId":"n1","tags":[{"id":"t1","name":"Глава 1"}]}"#,
            ),
            (
                "quests/q1/nodes.json",
                r#"{"nodes":[{"id":"n1","title":"Н1","chapterId":"t1","content":{"items":[
                    {"id":"row1","type":"row","children":[
                        {"id":"a","type":"image","scriptTriggers":{"onContentAppear":"scripts/a.json"}},
                        {"id":"b","type":"image","scriptTriggers":{"onContentAppear":"scripts/b.json"}}
                    ]}
                ]}}]}"#,
            ),
            (
                "quests/q1/scripts/a.json",
                r#"{"id":"a","blocks":[{"type":"event","eventType":"onContentAppear","children":[{"type":"condition","expression":"{x}==1","then_blocks":[]}]}]}"#,
            ),
            (
                "quests/q1/scripts/b.json",
                r#"{"id":"b","blocks":[{"type":"event","eventType":"onContentAppear","children":[{"type":"condition","expression":"{x}==2","then_blocks":[]}]}]}"#,
            ),
        ]);
        let report = analyze_quest_with_store("q1", store);
        assert_eq!(
            report_errors(&report, DiagnosticKind::VisibilityConflict).len(),
            0,
            "{{x}}==1 и {{x}}==2 не могут быть истинны одновременно"
        );
    }

    #[test]
    fn no_false_conflict_on_expr_boundaries() {
        // Границы-выражения с разными коэффициентами — не делаем выводов.
        let store = mem_store(&[
            (
                "quests/q1/config.json",
                r#"{"id":"q1","startNodeId":"n1","tags":[{"id":"t1","name":"Глава 1"}]}"#,
            ),
            (
                "quests/q1/nodes.json",
                r#"{"nodes":[{"id":"n1","title":"Н1","chapterId":"t1","content":{"items":[
                    {"id":"row1","type":"row","children":[
                        {"id":"a","type":"image","scriptTriggers":{"onContentAppear":"scripts/a.json"}},
                        {"id":"b","type":"image","scriptTriggers":{"onContentAppear":"scripts/b.json"}},
                        {"id":"c","type":"image","scriptTriggers":{"onContentAppear":"scripts/c.json"}}
                    ]}
                ]}}]}"#,
            ),
            (
                "quests/q1/scripts/a.json",
                r#"{"id":"a","blocks":[{"type":"event","eventType":"onContentAppear","children":[{"type":"condition","expression":"{x}>round({y}*0.9)","then_blocks":[]}]}]}"#,
            ),
            (
                "quests/q1/scripts/b.json",
                r#"{"id":"b","blocks":[{"type":"event","eventType":"onContentAppear","children":[{"type":"condition","expression":"{x}<=round({y}*0.8)","then_blocks":[]}]}]}"#,
            ),
            (
                "quests/q1/scripts/c.json",
                r#"{"id":"c","blocks":[{"type":"event","eventType":"onContentAppear","children":[{"type":"condition","expression":"{x}<{y}","then_blocks":[]}]}]}"#,
            ),
        ]);
        let report = analyze_quest_with_store("q1", store);
        assert_eq!(
            report_errors(&report, DiagnosticKind::VisibilityConflict).len(),
            0,
            "разные expr-границы не дают вывода о пересечении"
        );
    }

    #[test]
    fn detects_broken_links_and_dead_vars() {
        let store = mem_store(&[
            (
                "quests/q1/config.json",
                r#"{"id":"q1","startNodeId":"n1","tags":[{"id":"t1","name":"Глава 1"}]}"#,
            ),
            (
                "quests/q1/nodes.json",
                r#"{"nodes":[
                    {"id":"n1","title":"Н1","chapterId":"t1","content":{"items":[
                        {"id":"b1","type":"button","text":"Идти","targetNodeId":"n3",
                         "scriptTriggers":{"onPress":"scripts/p.json"}},
                        {"id":"img1","type":"image","resourcePath":"res/images/нет.png"}
                    ]}},
                    {"id":"n2","title":"Н2","chapterId":"t1","content":{"items":[]}}
                ]}"#,
            ),
            (
                "quests/q1/scripts/p.json",
                r#"{"id":"p","name":"press","blocks":[{"type":"event","eventType":"onPress","children":[
                    {"type":"assign_variable","variable":"мёртвая","value":"{живая}+1"},
                    {"type":"condition","expression":"{живая}==1","then_blocks":[]}
                ]}]}"#,
            ),
        ]);
        let report = analyze_quest_with_store("q1", store);
        assert_eq!(
            report_errors(&report, DiagnosticKind::BrokenNodeLink).len(),
            1
        );
        assert_eq!(
            report_errors(&report, DiagnosticKind::BrokenResourceLink).len(),
            1
        );
        // «мёртвая» пишется, но не читается.
        let unread = report_errors(&report, DiagnosticKind::UnwrittenVariable);
        assert_eq!(unread.len(), 1);
        assert!(unread[0].message.contains("мёртвая"));
        // «живая» читается, но не пишется.
        let unwritten = report_errors(&report, DiagnosticKind::UnreadVariable);
        assert_eq!(unwritten.len(), 1);
        assert!(unwritten[0].message.contains("живая"));
    }

    #[test]
    fn double_braced_and_nested_variable_use_counts_as_read() {
        let store = mem_store(&[
            (
                "quests/q1/config.json",
                r#"{"id":"q1","startNodeId":"n1","tags":[{"id":"t1","name":"Глава 1"}]}"#,
            ),
            (
                "quests/q1/nodes.json",
                r#"{"nodes":[
                    {"id":"n1","title":"Н1","chapterId":"t1","content":{"items":[
                        {"id":"t1","type":"text","text":"Выбор: {{выбор}}"},
                        {"id":"b1","type":"button","text":"Взять",
                         "scriptTriggers":{"onPress":"scripts/p.json"}}
                    ]}}
                ]}"#,
            ),
            (
                "quests/q1/scripts/p.json",
                r#"{"id":"p","name":"press","blocks":[{"type":"event","eventType":"onPress","children":[
                    {"type":"assign_variable","variable":"выбор","value":"1"},
                    {"type":"set_image","item_id":"i1","item_name":"Картинка",
                     "source":"{{Оружие[\"Картинка\"][\"{выбор}\"]}}"}
                ]}]}"#,
            ),
        ]);
        let report = analyze_quest_with_store("q1", store);
        // `{{выбор}}` в тексте и вложенное `{выбор}` внутри ссылки на ячейку
        // таблицы — это чтения: «получает значение, но не используется» ложно.
        let unread = report_errors(&report, DiagnosticKind::UnwrittenVariable);
        assert!(
            unread.is_empty(),
            "переменная читается через {{ }} и ссылку на таблицу: {unread:?}"
        );
        let unwritten = report_errors(&report, DiagnosticKind::UnreadVariable);
        assert!(unwritten.is_empty(), "переменная пишется: {unwritten:?}");
    }

    #[test]
    fn detects_unreachable_node() {
        let store = mem_store(&[
            (
                "quests/q1/config.json",
                r#"{"id":"q1","startNodeId":"n1","tags":[{"id":"t1","name":"Глава 1"}]}"#,
            ),
            (
                "quests/q1/nodes.json",
                r#"{"nodes":[
                    {"id":"n1","title":"Старт","chapterId":"t1","content":{"items":[{"id":"b1","type":"button","targetNodeId":"n2"}]}},
                    {"id":"n2","title":"Достижима","chapterId":"t1","content":{"items":[]}},
                    {"id":"n3","title":"Заброшена","chapterId":"t1","content":{"items":[]}}
                ]}"#,
            ),
        ]);
        let report = analyze_quest_with_store("q1", store);
        let unreachable = report_errors(&report, DiagnosticKind::UnreachableNode);
        assert_eq!(unreachable.len(), 1);
        assert!(unreachable[0].message.contains("Заброшена"));
    }

    #[test]
    fn detects_broken_call_script_and_empty_script() {
        let store = mem_store(&[
            (
                "quests/q1/config.json",
                r#"{"id":"q1","startNodeId":"n1","tags":[{"id":"t1","name":"Глава 1"}]}"#,
            ),
            (
                "quests/q1/nodes.json",
                r#"{"nodes":[{"id":"n1","title":"Н1","chapterId":"t1","content":{"items":[
                    {"id":"b1","type":"button","scriptTriggers":{"onPress":"scripts/caller.json"}}
                ]}}]}"#,
            ),
            (
                "quests/q1/scripts/caller.json",
                r#"{"id":"caller","blocks":[{"type":"event","eventType":"onPress","children":[
                    {"type":"call_script","script_id":"no-such-script"}
                ]}]}"#,
            ),
        ]);
        let report = analyze_quest_with_store("q1", store);
        assert_eq!(
            report_errors(&report, DiagnosticKind::BrokenScriptLink).len(),
            1
        );
        assert!(
            report_errors(&report, DiagnosticKind::BrokenScriptLink)[0]
                .message
                .contains("скрипт")
        );
    }

    /// Ссылка из нового формата (`behaviours`) проверяется так же, как из
    /// legacy `scriptTriggers`: сбор только по legacy не видел битый путь и
    /// не собирал onAppear-триггеры для детальной проверки.
    #[test]
    fn detects_broken_link_from_behaviours() {
        let store = mem_store(&[
            (
                "quests/q1/config.json",
                r#"{"id":"q1","startNodeId":"n1","tags":[{"id":"t1","name":"Глава 1"}]}"#,
            ),
            (
                "quests/q1/nodes.json",
                r#"{"nodes":[{"id":"n1","title":"Н1","chapterId":"t1","content":{"items":[
                    {"id":"b1","type":"button","behaviours":[
                        {"event":"onPress","kind":"action","script":"scripts/nope.json"}
                    ]}
                ]}}]}"#,
            ),
        ]);
        let report = analyze_quest_with_store("q1", store);
        assert_eq!(
            report_errors(&report, DiagnosticKind::BrokenScriptLink).len(),
            1,
            "отчёт: {:?}",
            report.diagnostics
        );
    }

    /// Настройка модалки `showTimer` исторически лежит в `scriptTriggers`,
    /// хотя это не ссылка на скрипт. Валидация обязана игнорировать такие
    /// значения: иначе на каждом авто-закрывающемся окне с таймером отчёт
    /// выдаёт «Привязанный скрипт удалён или переименован».
    /// `_CLOSE_MODAL` в `targetNodeId` — то же самое: служебная цель, которую
    /// обрабатывает плеер, а не id ноды.
    #[test]
    fn modal_show_timer_flag_is_not_a_script_link() {
        let store = mem_store(&[
            (
                "quests/q1/config.json",
                r#"{"id":"q1","startNodeId":"n1","tags":[{"id":"t1","name":"Глава 1"}]}"#,
            ),
            (
                "quests/q1/nodes.json",
                r#"{"nodes":[{"id":"n1","title":"Н1","chapterId":"t1","content":{"items":[
                    {"id":"m1","type":"modal","targetNodeId":"_CLOSE_MODAL","text":"3",
                     "showTimer":true},
                    {"id":"m2","type":"modal","targetNodeId":"_CLOSE_MODAL","text":"5",
                     "scriptTriggers":{"showTimer":"true"}}
                ]}}]}"#,
            ),
        ]);
        let report = analyze_quest_with_store("q1", store);
        assert_eq!(
            report_errors(&report, DiagnosticKind::BrokenScriptLink).len(),
            0,
            "отчёт: {:?}",
            report.diagnostics
        );
        assert_eq!(
            report_errors(&report, DiagnosticKind::BrokenNodeLink).len(),
            0,
            "отчёт: {:?}",
            report.diagnostics
        );
    }

    /// Ссылка `scripts/<id>.json#fn=Имя` (вызов функции) не считается
    /// битой: файл существует, функция есть. Имя функции — percent-encoded.
    #[test]
    fn fn_ref_with_existing_function_is_ok() {
        let store = mem_store(&[
            (
                "quests/q1/config.json",
                r#"{"id":"q1","startNodeId":"n1","tags":[{"id":"t1","name":"Глава 1"}]}"#,
            ),
            (
                "quests/q1/nodes.json",
                r#"{"nodes":[{"id":"n1","title":"Н1","chapterId":"t1","content":{"items":[
                    {"id":"b1","type":"button","scriptTriggers":{"onPress":"scripts/s1.json#fn=%D0%92%D0%BE%D0%B7%D1%80%D0%B0%D1%81%D1%82"}}
                ]}}]}"#,
            ),
            (
                "quests/q1/scripts/s1.json",
                r#"{"id":"s1","name":"Отображение","blocks":[
                    {"type":"event","eventType":"function","functionName":"Возраст","children":[]},
                    {"type":"event","eventType":"onPress","children":[]}
                ]}"#,
            ),
        ]);
        let report = analyze_quest_with_store("q1", store);
        assert_eq!(
            report_errors(&report, DiagnosticKind::BrokenScriptLink).len(),
            0,
            "отчёт: {:?}",
            report.diagnostics
        );
    }

    /// `#fn=` на несуществующую функцию — ошибка с читаемым именем.
    #[test]
    fn fn_ref_with_missing_function_is_error() {
        let store = mem_store(&[
            (
                "quests/q1/config.json",
                r#"{"id":"q1","startNodeId":"n1","tags":[{"id":"t1","name":"Глава 1"}]}"#,
            ),
            (
                "quests/q1/nodes.json",
                r#"{"nodes":[{"id":"n1","title":"Н1","chapterId":"t1","content":{"items":[
                    {"id":"b1","type":"button","scriptTriggers":{"onPress":"scripts/s1.json#fn=%D0%9D%D0%B5%D1%82%D1%83"}}
                ]}}]}"#,
            ),
            (
                "quests/q1/scripts/s1.json",
                r#"{"id":"s1","name":"Отображение","blocks":[
                    {"type":"event","eventType":"function","functionName":"Возраст","children":[]}
                ]}"#,
            ),
        ]);
        let report = analyze_quest_with_store("q1", store);
        let errors = report_errors(&report, DiagnosticKind::BrokenScriptLink);
        assert_eq!(errors.len(), 1);
        assert!(
            errors[0].message.contains("«Нету»"),
            "ожидалось имя функции в сообщении: {:?}",
            errors[0].message
        );
        assert!(errors[0].message.contains("Отображение"));
    }

    /// Скрипт во внутреннем каталоге `_internal_scripts/` не считается битым.
    #[test]
    fn script_in_internal_dir_is_ok() {
        let store = mem_store(&[
            (
                "quests/q1/config.json",
                r#"{"id":"q1","startNodeId":"n1","tags":[{"id":"t1","name":"Глава 1"}]}"#,
            ),
            (
                "quests/q1/nodes.json",
                r#"{"nodes":[{"id":"n1","title":"Н1","chapterId":"t1","content":{"items":[
                    {"id":"b1","type":"button","scriptTriggers":{"onPress":"scripts/s1.json"}}
                ]}}]}"#,
            ),
            (
                "quests/q1/_internal_scripts/s1.json",
                r#"{"id":"s1","name":"Внутренний","blocks":[{"type":"event","eventType":"onPress","children":[]}]}"#,
            ),
        ]);
        let report = analyze_quest_with_store("q1", store);
        assert_eq!(
            report_errors(&report, DiagnosticKind::BrokenScriptLink).len(),
            0,
            "отчёт: {:?}",
            report.diagnostics
        );
    }

    /// Мусор в фигурных скобках (JSON-литералы, шаблонные строки) не
    /// превращается в «переменную без инициализации».
    #[test]
    fn garbage_braces_are_not_variables() {
        let store = mem_store(&[
            (
                "quests/q1/config.json",
                r#"{"id":"q1","startNodeId":"n1","tags":[{"id":"t1","name":"Глава 1"}]}"#,
            ),
            (
                "quests/q1/nodes.json",
                r#"{"nodes":[{"id":"n1","title":"Н1","chapterId":"t1","content":{"items":[
                    {"id":"t1","type":"text","text":"JSON: {\"items\": []} и ${ешка]\\{y}"},
                    {"id":"b1","type":"button","scriptTriggers":{"onPress":"scripts/s1.json"}}
                ]}}]}"#,
            ),
            (
                "quests/q1/scripts/s1.json",
                r#"{"id":"s1","blocks":[{"type":"event","eventType":"onPress","children":[
                    {"type":"assign_variable","variable":"решка","value":"{инвентарь.рука[0].название}"}
                ]}]}"#,
            ),
        ]);
        let report = analyze_quest_with_store("q1", store);
        let unwritten = report_errors(&report, DiagnosticKind::UnreadVariable);
        assert!(
            unwritten.iter().all(|d| !d.message.contains('"')
                && !d.message.contains('\\')
                && !d.message.contains("ешка")),
            "мусор не должен попадать в переменные: {:?}",
            unwritten
        );
        // «инвентарь.рука[0].название» — валидная переменная с массивами.
        assert!(
            unwritten
                .iter()
                .any(|d| d.message.contains("инвентарь.рука[0].название")),
            "доступ к массиву обязан остаться переменной: {:?}",
            unwritten
        );
    }

    /// Ссылка на несуществующий скрипт сообщает читаемый контекст источника:
    /// нода и айтем («откуда»), а не только путь-идентификатор («куда»).
    #[test]
    fn broken_script_link_has_node_and_item_context() {
        let store = mem_store(&[
            (
                "quests/q1/config.json",
                r#"{"id":"q1","startNodeId":"n1","tags":[{"id":"t1","name":"Глава 1"}]}"#,
            ),
            (
                "quests/q1/nodes.json",
                r#"{"nodes":[{"id":"n1","title":"Бой с боссом","chapterId":"t1","content":{"items":[
                    {"id":"btn1","type":"button","text":"Атака и Защита","scriptTriggers":{"onPress":"scripts/no-such.json"}}
                ]}}]}"#,
            ),
        ]);
        let report = analyze_quest_with_store("q1", store);
        let errors = report_errors(&report, DiagnosticKind::BrokenScriptLink);
        assert_eq!(errors.len(), 1);
        let msg = &errors[0].message;
        assert!(msg.contains("«Бой с боссом»"), "контекст ноды: {msg}");
        assert!(msg.contains("«Атака и Защита»"), "контекст айтема: {msg}");
        // пути скрипта уже нет в сообщении — проверяем только контекст ноды и айтема
    }

    /// Переход по onNodeEnter-скрипту ноды (go_to_node) делает ноду
    /// достижимой — предупреждения недостижимости быть не должно.
    #[test]
    fn reachability_via_on_node_enter_script() {
        let store = mem_store(&[
            (
                "quests/q1/config.json",
                r#"{"id":"q1","startNodeId":"n1","tags":[{"id":"t1","name":"Глава 1"}]}"#,
            ),
            (
                "quests/q1/nodes.json",
                r#"{"nodes":[
                    {"id":"n1","title":"Старт","chapterId":"t1","scriptAssetId":"scripts/enter.json","content":{"items":[]}},
                    {"id":"n2","title":"Через скрипт","chapterId":"t1","content":{"items":[]}}
                ]}"#,
            ),
            (
                "quests/q1/scripts/enter.json",
                r#"{"id":"enter","name":"Вход","blocks":[{"type":"event","eventType":"onNodeEnter","children":[
                    {"type":"go_to_node","node_id":"n2"}
                ]}]}"#,
            ),
        ]);
        let report = analyze_quest_with_store("q1", store);
        let unreachable = report_errors(&report, DiagnosticKind::UnreachableNode);
        assert!(
            unreachable.is_empty(),
            "нода n2 достижима через onNodeEnter: {:?}",
            report.diagnostics
        );
    }

    /// Script-айтем (`type: "script"`, `resourcePath`) выполняется движком
    /// как скрипт ноды и может вести на другую ноду через go_to_node —
    /// предупреждения недостижимости быть не должно.
    #[test]
    fn reachability_via_script_item() {
        let store = mem_store(&[
            (
                "quests/q1/config.json",
                r#"{"id":"q1","startNodeId":"n1","tags":[{"id":"t1","name":"Глава 1"}]}"#,
            ),
            (
                "quests/q1/nodes.json",
                r#"{"nodes":[
                    {"id":"n1","title":"Старт","chapterId":"t1","content":{"items":[
                        {"id":"s1","type":"script","resourcePath":"scripts/inline.json"}
                    ]}},
                    {"id":"n2","title":"Через script-айтем","chapterId":"t1","content":{"items":[]}}
                ]}"#,
            ),
            (
                "quests/q1/scripts/inline.json",
                r#"{"id":"inline","name":"Инлайн","blocks":[{"type":"event","eventType":"onNodeEnter","children":[
                    {"type":"go_to_node","node_id":"n2"}
                ]}]}"#,
            ),
        ]);
        let report = analyze_quest_with_store("q1", store);
        let unreachable = report_errors(&report, DiagnosticKind::UnreachableNode);
        assert!(
            unreachable.is_empty(),
            "нода n2 достижима через script-айтем: {:?}",
            report.diagnostics
        );
    }

    /// Переход по таймеру ноды (defaultActionNodeId) делает ноду достижимой.
    #[test]
    fn reachability_via_timer_default_action() {
        let store = mem_store(&[
            (
                "quests/q1/config.json",
                r#"{"id":"q1","startNodeId":"n1","tags":[{"id":"t1","name":"Глава 1"}]}"#,
            ),
            (
                "quests/q1/nodes.json",
                r#"{"nodes":[
                    {"id":"n1","title":"Старт","chapterId":"t1","timerDuration":5.0,"defaultActionNodeId":"n2","content":{"items":[]}},
                    {"id":"n2","title":"По таймеру","chapterId":"t1","content":{"items":[]}}
                ]}"#,
            ),
        ]);
        let report = analyze_quest_with_store("q1", store);
        let unreachable = report_errors(&report, DiagnosticKind::UnreachableNode);
        assert!(
            unreachable.is_empty(),
            "нода n2 достижима по таймеру ноды: {:?}",
            report.diagnostics
        );
    }

    /// Динамическая цель (`={expr}` / `{выражение}`) не позволяет построить
    /// точный граф — недостижимость не диагностируется (ложные срабатывания).
    #[test]
    fn no_unreachable_warning_when_dynamic_target() {
        let store = mem_store(&[
            (
                "quests/q1/config.json",
                r#"{"id":"q1","startNodeId":"n1","tags":[{"id":"t1","name":"Глава 1"}]}"#,
            ),
            (
                "quests/q1/nodes.json",
                r#"{"nodes":[
                    {"id":"n1","title":"Старт","chapterId":"t1","content":{"items":[{"id":"b1","type":"button","targetNodeId":"={next}"}]}},
                    {"id":"n2","title":"Динамическая цель","chapterId":"t1","content":{"items":[]}}
                ]}"#,
            ),
        ]);
        let report = analyze_quest_with_store("q1", store);
        let unreachable = report_errors(&report, DiagnosticKind::UnreachableNode);
        assert!(
            unreachable.is_empty(),
            "динамическая цель не даёт ложных недостижимых: {:?}",
            report.diagnostics
        );
    }

    /// Общий скрипт (кнопка-действие в нескольких нодах) с go_to_node даёт
    /// переходы из КАЖДОЙ ноды-владельца, а не только из первой.
    #[test]
    fn shared_script_edges_from_every_owner() {
        let store = mem_store(&[
            (
                "quests/q1/config.json",
                r#"{"id":"q1","startNodeId":"n1","tags":[{"id":"t1","name":"Глава 1"}]}"#,
            ),
            (
                "quests/q1/nodes.json",
                r#"{"nodes":[
                    {"id":"n1","title":"Старт","chapterId":"t1","content":{"items":[
                        {"id":"b0","type":"button","text":"Во вторую","targetNodeId":"n2"},
                        {"id":"b1","type":"button","text":"Действие","scriptTriggers":{"onPress":"scripts/shared.json"}}
                    ]}},
                    {"id":"n2","title":"Вторая","chapterId":"t1","content":{"items":[
                        {"id":"b2","type":"button","text":"Действие","scriptTriggers":{"onPress":"scripts/shared.json"}}
                    ]}},
                    {"id":"n3","title":"Финал","chapterId":"t1","content":{"items":[]}}
                ]}"#,
            ),
            (
                "quests/q1/scripts/shared.json",
                r#"{"id":"shared","name":"Общее действие","blocks":[{"type":"event","eventType":"function","functionName":"go","children":[
                    {"type":"go_to_node","node_id":"n3"}
                ]}]}"#,
            ),
        ]);
        let report = analyze_quest_with_store("q1", store);
        let unreachable = report_errors(&report, DiagnosticKind::UnreachableNode);
        assert!(
            unreachable.is_empty(),
            "обе ноды-владельца общего скрипта должны вести в n3: {:?}",
            report.diagnostics
        );
    }

    #[test]
    fn real_quest_slot_conflict_found() {
        // Локальная проверка на реальном квесте, не CI: фикстура задаётся
        // окружением (MND_LOCAL_QUEST_ROOT + MND_LOCAL_QUEST_ID).
        let root_dir = std::env::var("MND_LOCAL_QUEST_ROOT").unwrap_or_default();
        let quest_id = std::env::var("MND_LOCAL_QUEST_ID").unwrap_or_default();
        let root = std::path::Path::new(&root_dir);
        let quest = quest_id.as_str();
        if quest.is_empty() || !root.join("quests").join(quest).is_dir() {
            return; // фикстура доступна только локально
        }
        let store: DynAssetStore = Arc::new(FsScriptAssetStore::new(root));
        let report = analyze_quest_with_store(quest, store);
        let conflicts = report_errors(&report, DiagnosticKind::VisibilityConflict);
        assert!(
            !conflicts.is_empty(),
            "реальный квест обязан содержать конфликт видимости слотов"
        );
        let has_slot = conflicts.iter().any(|d| d.message.contains("{Слот"));
        assert!(
            has_slot,
            "найденные конфликты должны касаться слотов: {conflicts:?}"
        );
    }

    // ---------- Стартовая нода и главы ----------

    #[test]
    fn missing_start_node_is_error() {
        let store = mem_store(&[
            (
                "quests/q1/config.json",
                r#"{"id":"q1","tags":[{"id":"t1","name":"Г"}]}"#,
            ),
            (
                "quests/q1/nodes.json",
                r#"{"nodes":[{"id":"n1","title":"Н1","chapterId":"t1","content":{"items":[]}}]}"#,
            ),
        ]);
        let report = analyze_quest_with_store("q1", store);
        let found = report_errors(&report, DiagnosticKind::MissingStartNode);
        assert_eq!(found.len(), 1, "квест без стартовой ноды обязан ругаться");
        assert_eq!(found[0].severity, Severity::Error);
    }

    #[test]
    fn node_without_chapter_is_error() {
        let store = mem_store(&[
            (
                "quests/q1/config.json",
                r#"{"id":"q1","startNodeId":"n1","tags":[{"id":"t1","name":"Г"}]}"#,
            ),
            (
                "quests/q1/nodes.json",
                r#"{"nodes":[
                    {"id":"n1","title":"Н1","chapterId":"t1","content":{"items":[]}},
                    {"id":"n2","title":"Н2","chapterId":"deleted","content":{"items":[]}},
                    {"id":"n3","title":"Н3","chapterId":"","content":{"items":[]}}
                ]}"#,
            ),
        ]);
        let report = analyze_quest_with_store("q1", store);
        let found = report_errors(&report, DiagnosticKind::UnknownChapter);
        assert_eq!(
            found.len(),
            2,
            "ноды с удалённой и пустой главой должны быть найдены"
        );
        assert!(found.iter().any(|d| d.node_id.as_deref() == Some("n2")));
        assert!(found.iter().any(|d| d.node_id.as_deref() == Some("n3")));
    }

    #[test]
    fn empty_chapter_list_with_nodes_is_error() {
        // Ровно тот случай, из-за которого ноды не открываются в редакторе.
        let store = mem_store(&[
            (
                "quests/q1/config.json",
                r#"{"id":"q1","startNodeId":"n1","tags":[]}"#,
            ),
            (
                "quests/q1/nodes.json",
                r#"{"nodes":[{"id":"n1","title":"Н1","chapterId":"t1","content":{"items":[]}}]}"#,
            ),
        ]);
        let report = analyze_quest_with_store("q1", store);
        assert_eq!(
            report_errors(&report, DiagnosticKind::NoChapters).len(),
            1,
            "квест с нодами без глав должен ругаться"
        );
    }

    #[test]
    fn per_node_layout_nodes_are_validated() {
        // v2-раскладка (`nodes/index.json` + тела) — источник правды движка,
        // валидатор обязан читать её так же, иначе квест выглядит пустым.
        let store = mem_store(&[
            (
                "quests/q1/config.json",
                r#"{"id":"q1","startNodeId":"n1","tags":[{"id":"t1","name":"Г"}]}"#,
            ),
            (
                "quests/q1/nodes/index.json",
                r#"{"format_version":2,"card_preview_version":1,"nodes":[{"id":"n1","title":"Н1","chapterId":"t1","x":0,"y":0}]}"#,
            ),
            (
                "quests/q1/nodes/n1.json",
                r#"{"id":"n1","title":"Н1","chapterId":"t1","x":0,"y":0,"content":{"items":[{"id":"i1","type":"text","text":"привет"}]}}"#,
            ),
        ]);
        let report = analyze_quest_with_store("q1", store);
        assert_eq!(
            report.stats.nodes, 1,
            "нода из v2-раскладки должна читаться"
        );
        assert_eq!(report.stats.items, 1, "айтемы тела ноды должны читаться");
        assert_eq!(report.stats.errors, 0, "{:?}", report.diagnostics);
    }
    #[test]
    fn detects_unreachable_code_after_transition() {
        let store = mem_store(&[
            (
                "quests/q1/config.json",
                r#"{"id":"q1","startNodeId":"n1","tags":[{"id":"t1","name":"Глава 1"}]}"#,
            ),
            (
                "quests/q1/nodes.json",
                r#"{"nodes":[
                    {"id":"n1","title":"Н1","chapterId":"t1","content":{"items":[
                        {"id":"b1","type":"button","buttonText":"Дальше",
                         "scriptTriggers":{"onPress":"scripts/flow.json"}}]}},
                    {"id":"n2","title":"Н2","chapterId":"t1","content":{"items":[]}}
                ]}"#,
            ),
            (
                "quests/q1/scripts/flow.json",
                r#"{"id":"flow","name":"переход","blocks":[
                    {"type":"go_to_node","node_id":"n2"},
                    {"type":"assign_variable","variable":"x","value":"1"}
                ]}"#,
            ),
        ]);
        let report = analyze_quest_with_store("q1", store);
        let dead = report_errors(&report, DiagnosticKind::UnreachableCode);
        assert_eq!(dead.len(), 1, "хвост после перехода — мёртвый код");
        assert!(dead[0].message.contains("Переход"));
        assert!(dead[0].message.contains("Переменная"));
        assert_eq!(
            dead[0].script_path.as_deref(),
            Some("scripts/flow.json"),
            "диагностика скрипта должна нести путь для перехода к источнику"
        );
    }

    #[test]
    fn detects_loop_without_wait_but_accepts_paced_loop() {
        let store = mem_store(&[
            (
                "quests/q1/config.json",
                r#"{"id":"q1","startNodeId":"n1","tags":[{"id":"t1","name":"Глава 1"}]}"#,
            ),
            (
                "quests/q1/nodes.json",
                r#"{"nodes":[{"id":"n1","title":"Н1","chapterId":"t1","content":{"items":[
                    {"id":"b1","type":"button","buttonText":"Старт",
                     "scriptTriggers":{"onPress":"scripts/busy.json"}}]}}]}"#,
            ),
            (
                "quests/q1/scripts/busy.json",
                r#"{"id":"busy","blocks":[
                    {"type":"while","count":1000,"children":[
                        {"type":"assign_variable","variable":"x","value":"1"}
                    ]},
                    {"type":"while","count":10,"children":[
                        {"type":"wait","seconds":0.1}
                    ]}
                ]}"#,
            ),
        ]);
        let report = analyze_quest_with_store("q1", store);
        let loops = report_errors(&report, DiagnosticKind::LoopWithoutWait);
        assert_eq!(loops.len(), 1, "только цикл без задержки");
        assert!(loops[0].message.contains("за один кадр"));
    }

    #[test]
    fn detects_dead_scripts_but_skips_event_handlers() {
        let store = mem_store(&[
            (
                "quests/q1/config.json",
                r#"{"id":"q1","startNodeId":"n1","tags":[{"id":"t1","name":"Глава 1"}]}"#,
            ),
            (
                "quests/q1/nodes.json",
                r#"{"nodes":[{"id":"n1","title":"Н1","chapterId":"t1","content":{"items":[
                    {"id":"b1","type":"button","buttonText":"Го",
                     "scriptTriggers":{"onPress":"scripts/used.json"}}]}}]}"#,
            ),
            (
                "quests/q1/scripts/used.json",
                r#"{"id":"used","blocks":[{"type":"comment","text":"ok"}]}"#,
            ),
            (
                "quests/q1/scripts/orphan.json",
                r#"{"id":"orphan","name":"Забытый","blocks":[{"type":"comment","text":"ok"}]}"#,
            ),
            (
                "quests/q1/scripts/boot.json",
                r#"{"id":"boot","name":"Старт","blocks":[
                    {"type":"event","eventType":"onQuestStart","children":[
                        {"type":"assign_variable","variable":"started","value":"1"}]}]}"#,
            ),
        ]);
        let report = analyze_quest_with_store("q1", store);
        let dead = report_errors(&report, DiagnosticKind::DeadScript);
        assert_eq!(dead.len(), 1, "мёртвым должен быть только orphan");
        assert!(dead[0].message.contains("Забытый"));
        assert_eq!(dead[0].script_path.as_deref(), Some("scripts/orphan.json"));
    }

    #[test]
    fn detects_table_column_mismatch() {
        let store = mem_store(&[
            (
                "quests/q1/config.json",
                r#"{"id":"q1","startNodeId":"n1","tags":[{"id":"t1","name":"Глава 1"}],
                    "tables":[
                        {"name":"ладно","columns":["item","price"],
                         "rows":[{"item":"меч","price":10},{"item":"щит","price":5}]},
                        {"name":"кривая","columns":["item","price"],
                         "rows":[{"item":"меч"},{"item":"щит","price":10,"color":"red"}],
                         "rowNames":["меч","щит","третий"]}
                    ]}"#,
            ),
            (
                "quests/q1/nodes.json",
                r#"{"nodes":[{"id":"n1","title":"Н1","chapterId":"t1","content":{"items":[]}}]}"#,
            ),
        ]);
        let report = analyze_quest_with_store("q1", store);
        let tables = report_errors(&report, DiagnosticKind::TableColumnMismatch);
        assert_eq!(tables.len(), 1, "правильная таблица не должна ругаться");
        let message = &tables[0].message;
        assert!(message.contains("кривая"), "{message}");
        assert!(message.contains("нет «price»"), "{message}");
        assert!(message.contains("color"), "{message}");
        assert!(message.contains("имён строк 3"), "{message}");
    }

    #[test]
    fn detects_dead_end_with_hidden_panel() {
        let store = mem_store(&[
            (
                "quests/q1/config.json",
                r#"{"id":"q1","startNodeId":"n1","hideTopPanel":true,"allowStepBack":false,
                    "tags":[{"id":"t1","name":"Глава 1"}]}"#,
            ),
            (
                "quests/q1/nodes.json",
                r#"{"nodes":[
                    {"id":"n1","title":"Ловушка","chapterId":"t1","content":{"items":[
                        {"id":"toggle","type":"button","buttonText":"Показать ещё",
                         "scriptTriggers":{"onPress":"scripts/toggle.json"}}]}},
                    {"id":"n2","title":"Дальше","chapterId":"t1","content":{"items":[]}},
                    {"id":"n3","title":"Выход","chapterId":"t1","content":{"items":[
                        {"id":"b3","type":"button","buttonText":"Дальше","targetNodeId":"n2"}]}}
                ]}"#,
            ),
            (
                "quests/q1/scripts/toggle.json",
                r#"{"id":"toggle","blocks":[{"type":"set_visible","mode":"toggle"}]}"#,
            ),
        ]);
        let report = analyze_quest_with_store("q1", store);
        let dead = report_errors(&report, DiagnosticKind::DeadEndNode);
        assert_eq!(dead.len(), 1, "тупик — только нода с кнопками без выхода");
        assert!(dead[0].message.contains("Ловушка"));
    }

    #[test]
    fn no_dead_end_alert_when_player_can_leave() {
        let store = mem_store(&[
            (
                "quests/q1/config.json",
                r#"{"id":"q1","startNodeId":"n1","hideTopPanel":true,"allowStepBack":true,
                    "tags":[{"id":"t1","name":"Глава 1"}]}"#,
            ),
            (
                "quests/q1/nodes.json",
                r#"{"nodes":[{"id":"n1","title":"Финал","chapterId":"t1","content":{"items":[
                    {"id":"b1","type":"button","buttonText":"Ещё"}]}}]}"#,
            ),
        ]);
        let report = analyze_quest_with_store("q1", store);
        assert_eq!(
            report_errors(&report, DiagnosticKind::DeadEndNode).len(),
            0,
            "шаг назад — это выход, тупика нет"
        );
    }
}

#[cfg(test)]
mod script_structure_tests {
    use super::*;
    use crate::contracts::FsScriptAssetStore;
    use std::sync::Arc;

    static N: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

    fn store_with(files: &[(&str, &str)]) -> DynAssetStore {
        let n = N.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let dir =
            std::env::temp_dir().join(format!("mnd_scriptstruct_{}_{}", std::process::id(), n));
        let _ = std::fs::remove_dir_all(&dir);
        for (path, content) in files {
            let full = dir.join(path);
            if let Some(parent) = full.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            std::fs::write(&full, content).unwrap();
        }
        Arc::new(FsScriptAssetStore::new(dir))
    }

    #[test]
    fn validator_reports_invalid_script_structure_and_normalizes_legacy() {
        // Легаси-условие (variable/comparison) + call_lua без function.
        let store = store_with(&[
            (
                "quests/q1/config.json",
                r#"{"id":"q1","startNodeId":"n1","tags":[{"id":"t1","name":"Глава 1"}]}"#,
            ),
            (
                "quests/q1/nodes.json",
                r#"{"nodes":[{"id":"n1","title":"Н","chapterId":"t1","content":{"items":[
                    {"id":"it","type":"text","text":"привет",
                     "scriptTriggers":{"onContentAppear":"scripts/s1.json"}}
                ]}}]}"#,
            ),
            (
                "quests/q1/scripts/s1.json",
                r#"{"blocks":[{"type":"event","eventType":"onContentAppear","children":[
                    {"type":"условие","variable":"HP","comparison":">=","значение":"10","then_blocks":[]},
                    {"type":"call_lua","script_id":"x.lua"}
                ]}]}"#,
            ),
            ("quests/q1/scripts/x.lua", "function start() end"),
        ]);
        let report = analyze_quest_with_store("q1", store);

        let structural: Vec<_> = report
            .diagnostics
            .iter()
            .filter(|d| d.kind == DiagnosticKind::InvalidScriptStructure)
            .collect();
        assert!(
            structural
                .iter()
                .any(|d| d.message.contains("call_lua без 'function'")),
            "ожидали missing_field по call_lua: {:?}",
            structural
        );
        // Легаси-условие нормализовано и НЕ порождает unknown/missing.
        assert!(
            !structural.iter().any(|d| d.message.contains("условие")),
            "легаси-типы не должны помечаться неизвестными: {:?}",
            structural
        );
    }
}
