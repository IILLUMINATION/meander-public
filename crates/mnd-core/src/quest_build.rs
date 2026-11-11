//! Программное создание и редактирование квеста через файловое хранилище.
//!
//! Единственный модуль ядра, который умеет писать квест. Все записи идут
//! через [`crate::quest_store::FsQuestStore`] — прямая правка JSON запрещена
//! правилом безопасности.

#![allow(clippy::too_many_lines)]

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use serde_json::{Map, Value, json};
use uuid::Uuid;

use crate::models::SavedNode;
use crate::quest_plan::ApplyReport;
use crate::quest_store::{FsQuestStore, MetaMutation, StoreOp};
use crate::script_format;

/// Ошибка, возвращаемая операциями [`QuestBuilder`].
#[derive(Debug)]
pub enum BuildError {
    NotFound(String),
    /// Ссылка не разрешилась: сообщение уже содержит варианты, поэтому
    /// префикс «не найдено» только мешает.
    RefNotFound(String),
    NotAQuest(String),
    Invalid(String),
    UnsupportedLayout(String),
    Io(String),
}

impl std::fmt::Display for BuildError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BuildError::NotFound(s) => write!(f, "не найдено: {s}"),
            BuildError::RefNotFound(s) => write!(f, "{s}"),
            BuildError::NotAQuest(s) => write!(f, "не квест: {s}"),
            BuildError::Invalid(s) => write!(f, "некорректные данные: {s}"),
            BuildError::UnsupportedLayout(s) => write!(f, "раскладка не поддерживается: {s}"),
            BuildError::Io(s) => write!(f, "ошибка ввода/вывода: {s}"),
        }
    }
}

impl std::error::Error for BuildError {}

/// Вид контент-айтема.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ItemKind {
    #[default]
    Text,
    Image,
    Button,
    Row,
}

/// Событие скрипта.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScriptEvent {
    OnPress,
    OnEnter,
    OnAppear,
}

/// Тип игрового ресурса.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResourceKind {
    Image,
    Audio,
    Video,
    Font,
}

impl ResourceKind {
    fn folder(&self) -> &'static str {
        match self {
            ResourceKind::Image => "images",
            ResourceKind::Audio => "audio",
            ResourceKind::Video => "videos",
            ResourceKind::Font => "fonts",
        }
    }
}

/// Спецификация новой ноды.
#[derive(Debug, Clone)]
pub struct NodeSpec {
    pub title: String,
    pub chapter_id: Option<String>,
    pub x: Option<f64>,
    pub y: Option<f64>,
    pub start: bool,
    /// Явный id: нужен генератору для повторяемых прогонов и ссылок вперёд.
    pub id: Option<String>,
}

/// Правка существующего айтема: `None` — поле не менять.
#[derive(Debug, Clone, Default)]
pub struct ItemPatch {
    pub text: Option<String>,
    pub source: Option<String>,
    pub script_id: Option<String>,
}

/// Правка существующей ноды: `None` — поле не менять.
#[derive(Debug, Clone, Default)]
pub struct NodeEdit {
    pub title: Option<String>,
    pub chapter_id: Option<String>,
    pub x: Option<f64>,
    pub y: Option<f64>,
    pub start: Option<bool>,
}

/// Параметры применения плана.
#[derive(Debug, Clone, Copy, Default)]
pub struct ApplyOptions {
    /// Только проверить и показать, что изменилось бы.
    pub dry_run: bool,
    /// Писать, даже если валидатор нашёл ошибки.
    pub force: bool,
}

/// Спецификация нового контент-айтема.
#[derive(Debug, Clone, Default)]
pub struct ItemSpec {
    pub kind: ItemKind,
    pub text: Option<String>,
    pub source: Option<String>,
    pub script_id: Option<String>,
    pub children: Vec<String>,
    pub id: Option<String>,
}

/// Конструктор/редактор квеста.
pub struct QuestBuilder {
    store: FsQuestStore,
    quest_id: String,
    root: PathBuf,
}

impl QuestBuilder {
    /// Открыть существующий квест. Требуется `quests/<quest_id>/config.json`.
    pub fn open(root: &Path, quest_id: &str) -> Result<Self, BuildError> {
        let builder = Self {
            store: FsQuestStore::new(root),
            quest_id: quest_id.to_string(),
            root: root.to_path_buf(),
        };
        if !builder.store.exists(&builder.config_path()) {
            return Err(BuildError::NotAQuest(format!(
                "{}/{}",
                builder.quest_dir(),
                "config.json"
            )));
        }
        Ok(builder)
    }

    /// Создать новый квест с одной главой и стартовой нодой «Начало».
    pub fn create(
        quest_id: &str,
        root: &Path,
        title: &str,
        author: Option<&str>,
        chapter_name: Option<&str>,
    ) -> Result<Self, BuildError> {
        Self::create_with_defaults(quest_id, root, title, author, chapter_name, true)
    }

    /// Создать пустой квест: без главы и без ноды.
    ///
    /// Нужен генератору, который сразу применяет план: заготовка «Начало» и
    /// «Глава 1» остались бы в квесте мусором и давали предупреждения
    /// валидатора. Главы/ноды/старт добавляет `apply`.
    pub fn create_empty(
        quest_id: &str,
        root: &Path,
        title: &str,
        author: Option<&str>,
    ) -> Result<Self, BuildError> {
        Self::create_with_defaults(quest_id, root, title, author, None, false)
    }

    /// Создать новый квест.
    ///
    /// `with_defaults: false` — пустой каркас: ни главы, ни ноды, старт не
    /// задан. Валидатор такой квест ругает (`NoChapters`, `MissingStartNode`),
    /// поэтому пустой квест имеет смысл только вместе с последующим `apply`.
    pub fn create_with_defaults(
        quest_id: &str,
        root: &Path,
        title: &str,
        author: Option<&str>,
        chapter_name: Option<&str>,
        with_defaults: bool,
    ) -> Result<Self, BuildError> {
        let builder = Self {
            store: FsQuestStore::new(root),
            quest_id: quest_id.to_string(),
            root: root.to_path_buf(),
        };
        if builder.store.exists(&builder.config_path()) {
            return Err(BuildError::Invalid(format!(
                "квест {quest_id} уже существует"
            )));
        }

        let now = iso8601_now();
        let chapter_id = Uuid::new_v4().to_string();
        let start_node_id = Uuid::new_v4().to_string();
        let chapter_name = chapter_name.unwrap_or("Глава 1");

        let tags = if with_defaults {
            json!([{
                "id": chapter_id,
                "name": chapter_name,
                "cameraState": {"offsetX": 0.0, "offsetY": 0.0, "scale": 1.0}
            }])
        } else {
            json!([])
        };
        let start_field = if with_defaults {
            json!(start_node_id)
        } else {
            Value::Null
        };

        let config = json!({
            "id": quest_id,
            "title": title,
            "author": author,
            "description": null,
            "version": "1.0.0",
            "startNodeId": start_field,
            "backgroundAssetId": null,
            "dimBackground": true,
            "hideNodeTitles": false,
            "hideTopPanel": false,
            "allowStepBack": false,
            "nodeTransitionMode": "none",
            "scriptEngineMode": "new",
            "pluginDependencies": [],
            "tags": tags,
            "nodes": [],
            "connections": [],
            "variables": [],
            "tables": [],
            "created": now,
            "updated": now,
            "lastEditedAt": now,
            "lastOpened": now,
            "genres": []
        });

        let start_node = json!({
            "id": start_node_id,
            "title": "Начало",
            "chapterId": chapter_id,
            "x": 0.0,
            "y": 0.0,
            "color": 4280492835_i64,
            "backgroundAudioVolume": 1.0,
            "content": {"items": [{
                "id": Uuid::new_v4().to_string(),
                "type": "text",
                "text": "Начало",
                "flex": 1_i64,
                "animateIn": true,
                "isHidden": false,
                "isIncoming": true,
                "locked": false,
                "rowTextAlignment": "center",
                "textFit": "auto",
                "volume": 1.0,
                "wrapText": true,
                "crossAxisAlignment": "center"
            }]}
        });

        // Индекс v2: previews не собираем — редактор дособерёт сам.
        let index = if with_defaults {
            make_v2_index(std::slice::from_ref(&start_node), Map::new())
        } else {
            make_v2_index(&[], Map::new())
        };

        // Те же каталоги, что создаёт редактор: редактор ресурсов и экспорт
        // рассчитывают, что папки уже есть, и падают на «нет каталога».
        for folder in ["res/images", "res/audio", "res/videos", "res/fonts"] {
            builder
                .store
                .create_dir(&format!("quests/{quest_id}/{folder}"))
                .map_err(store_err)?;
        }

        builder
            .store
            .write_json(&builder.config_path(), &config)
            .map_err(store_err)?;
        if with_defaults {
            builder
                .store
                .write_json(&builder.node_body_path(&start_node_id), &start_node)
                .map_err(store_err)?;
        }
        builder
            .store
            .write_json(&builder.index_path(), &index)
            .map_err(store_err)?;

        Ok(builder)
    }

    pub fn quest_id(&self) -> &str {
        &self.quest_id
    }

    /// Применить декларативный план (см. [`crate::quest_plan`]).
    ///
    /// План разбирается и разрешается целиком в памяти, проверяется
    /// валидатором на «состоянии после записи» и только потом пишется одной
    /// транзакцией. Ошибки плана или валидатора возвращаются в отчёте, а не
    /// как исключение: вызывающий должен увидеть сразу всё, что не так.
    pub fn apply(&self, plan: &Value, opts: &ApplyOptions) -> Result<ApplyReport, BuildError> {
        self.ensure_v2_layout()?;
        let parsed = crate::quest_plan::parse_plan(plan)?;
        let mut outcome =
            crate::quest_plan::build_plan(&self.store, &self.quest_id, &parsed, opts.dry_run)?;

        if !outcome.report.issues.is_empty() {
            outcome.report.ok = false;
            outcome.report.applied = false;
            outcome.report.dry_run = opts.dry_run;
            return Ok(outcome.report);
        }

        let validation = crate::quest_plan::validate_outcome(&self.root, &self.quest_id, &outcome);
        outcome.report.diagnostics = validation.diagnostics.clone();
        let blocked = validation.has_errors() && !opts.force;
        outcome.report.ok = !crate::quest_plan::has_errors(&outcome.report);
        outcome.report.dry_run = opts.dry_run;

        if opts.dry_run || blocked {
            outcome.report.applied = false;
            return Ok(outcome.report);
        }

        crate::quest_plan::write_outcome(&self.store, &self.quest_id, &outcome)?;
        outcome.report.applied = true;
        Ok(outcome.report)
    }

    /// Добавить главу (тег). Возвращает id тега.
    pub fn add_chapter(&self, name: &str, id: Option<&str>) -> Result<String, BuildError> {
        if name.trim().is_empty() {
            return Err(BuildError::Invalid("имя главы не может быть пустым".into()));
        }
        let id = id
            .map(|s| s.to_string())
            .unwrap_or_else(|| Uuid::new_v4().to_string());

        let mut config = self.load_config_object()?;
        let tags = config
            .entry("tags")
            .or_insert_with(|| Value::Array(vec![]))
            .as_array_mut()
            .ok_or_else(|| BuildError::Invalid("tags не массив".into()))?;

        let existing_ids: HashSet<String> = tags
            .iter()
            .filter_map(|t| t.get("id").and_then(Value::as_str).map(String::from))
            .collect();
        if existing_ids.contains(&id) {
            return Err(BuildError::Invalid(format!("глава с id '{id}' уже есть")));
        }

        tags.push(json!({
            "id": id,
            "name": name,
            "cameraState": {"offsetX": 0.0, "offsetY": 0.0, "scale": 1.0}
        }));

        config.insert("updated".into(), Value::String(iso8601_now()));
        config.insert("lastEditedAt".into(), Value::String(iso8601_now()));

        self.store
            .write_json(&self.config_path(), &Value::Object(config))
            .map_err(store_err)?;
        Ok(id)
    }

    /// Добавить ноду. Возвращает id ноды.
    pub fn add_node(&self, spec: &NodeSpec) -> Result<String, BuildError> {
        if spec.title.trim().is_empty() {
            return Err(BuildError::Invalid(
                "название ноды не может быть пустым".into(),
            ));
        }

        let mut config = self.load_config_object()?;
        let chapter_id = match &spec.chapter_id {
            Some(cid) => {
                let tags = config
                    .get("tags")
                    .and_then(Value::as_array)
                    .unwrap_or(&Vec::new())
                    .clone();
                if !tags
                    .iter()
                    .any(|t| t.get("id").and_then(Value::as_str) == Some(cid))
                {
                    return Err(BuildError::Invalid(format!("глава '{cid}' не найдена")));
                }
                cid.clone()
            }
            None => {
                let tags = config
                    .get("tags")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                let first = tags
                    .first()
                    .and_then(|t| t.get("id").and_then(Value::as_str).map(String::from));
                first.ok_or_else(|| BuildError::Invalid("нет глав для привязки ноды".into()))?
            }
        };

        let id = spec
            .id
            .clone()
            .unwrap_or_else(|| Uuid::new_v4().to_string());
        // id становится именем файла: слеши и `..` недопустимы, повтор запрещён.
        if id.contains('/') || id.contains('\\') || id.contains("..") {
            return Err(BuildError::Invalid(format!(
                "id ноды «{id}» не может содержать слеши или «..»"
            )));
        }
        if self.store.exists(&self.node_body_path(&id)) {
            return Err(BuildError::Invalid(format!("нода с id '{id}' уже есть")));
        }
        let x = spec.x.unwrap_or(0.0);
        let y = spec.y.unwrap_or(0.0);

        let mut body = Map::new();
        body.insert("id".into(), Value::String(id.clone()));
        body.insert("title".into(), Value::String(spec.title.clone()));
        body.insert("chapterId".into(), Value::String(chapter_id));
        body.insert("x".into(), json!(x));
        body.insert("y".into(), json!(y));
        body.insert("color".into(), json!(4280492835_i64));
        body.insert("backgroundAudioVolume".into(), json!(1.0));
        body.insert("content".into(), json!({"items": []}));

        let nodes_dir = format!("quests/{}/nodes", self.quest_id);
        let body_path = format!("{nodes_dir}/{id}.json");

        // Обновляем индекс: пишем тело и перезаписываем индекс одной транзакцией.
        let mut index = self.load_index_object()?;
        let summaries = index
            .entry("nodes")
            .or_insert_with(|| Value::Array(vec![]))
            .as_array_mut()
            .ok_or_else(|| BuildError::Invalid("index.nodes не массив".into()))?;
        summaries.push(summary_from_body(&body));

        if spec.start {
            config.insert("startNodeId".into(), Value::String(id.clone()));
        }
        config.insert("updated".into(), Value::String(iso8601_now()));
        config.insert("lastEditedAt".into(), Value::String(iso8601_now()));

        self.store
            .transact(&[
                StoreOp::WriteJson {
                    rel: self.config_path(),
                    value: Value::Object(config),
                },
                StoreOp::WriteJson {
                    rel: body_path,
                    value: Value::Object(body.clone()),
                },
                StoreOp::WriteJson {
                    rel: self.index_path(),
                    value: Value::Object(index),
                },
            ])
            .map_err(store_err)?;

        Ok(id)
    }

    /// Добавить айтем в ноду.
    pub fn add_item(&self, node_id: &str, spec: &ItemSpec) -> Result<String, BuildError> {
        let mut body = self.load_node_body_object(node_id)?;
        let items = body
            .get_mut("content")
            .and_then(|c| c.get_mut("items"))
            .and_then(Value::as_array_mut)
            .ok_or_else(|| BuildError::Invalid(format!("у ноды {node_id} нет content.items")))?;

        let id = spec
            .id
            .clone()
            .unwrap_or_else(|| Uuid::new_v4().to_string());

        // Проверка уникальности id айтема внутри ноды.
        if items
            .iter()
            .any(|it| it.get("id").and_then(Value::as_str) == Some(&id))
        {
            return Err(BuildError::Invalid(format!(
                "айтем '{id}' уже есть в ноде {node_id}"
            )));
        }

        if spec.children.iter().any(|c| c.is_empty()) {
            return Err(BuildError::Invalid(
                "id ребёнка ряда не может быть пустым".into(),
            ));
        }

        let mut item = default_item_map(&id, spec.kind);
        match spec.kind {
            ItemKind::Text => {
                let text = spec.text.clone().filter(|s| !s.is_empty()).ok_or_else(|| {
                    BuildError::Invalid("текстовый айтем должен содержать text".into())
                })?;
                item.insert("text".into(), Value::String(text));
            }
            ItemKind::Image => {
                let src = spec
                    .source
                    .clone()
                    .filter(|s| !s.is_empty())
                    .ok_or_else(|| {
                        BuildError::Invalid("айтем-картинка должен содержать source".into())
                    })?;
                item.insert("resourcePath".into(), Value::String(src));
            }
            ItemKind::Button => {
                let text =
                    spec.text.clone().filter(|s| !s.is_empty()).ok_or_else(|| {
                        BuildError::Invalid("кнопка должна содержать text".into())
                    })?;
                let script_id = spec
                    .script_id
                    .clone()
                    .filter(|s| !s.is_empty())
                    .ok_or_else(|| {
                        BuildError::Invalid("кнопка должна ссылаться на script_id".into())
                    })?;
                let script_path = format!("scripts/{script_id}.json");
                if !self.store.exists(&self.rel_in_quest(&script_path)) {
                    return Err(BuildError::NotFound(format!("скрипт {script_id}")));
                }
                item.insert("text".into(), Value::String(text));
                item.insert(
                    "behaviours".into(),
                    json!([{"event": "onPress", "script": script_path}]),
                );
            }
            ItemKind::Row => {
                let to_move: HashSet<String> = spec.children.iter().cloned().collect();
                if to_move.is_empty() {
                    return Err(BuildError::Invalid(
                        "ряд требует хотя бы одного ребёнка".into(),
                    ));
                }
                if to_move.len() != spec.children.len() {
                    return Err(BuildError::Invalid(
                        "повторяющиеся id в children ряда".into(),
                    ));
                }

                let mut moved = Vec::with_capacity(spec.children.len());
                let mut kept = Vec::new();
                let mut found = HashSet::new();
                for it in items.drain(..) {
                    // id копируем сразу: `it` дальше перемещается в `moved`/`kept`.
                    let it_id = it
                        .get("id")
                        .and_then(Value::as_str)
                        .map(str::to_string)
                        .unwrap_or_default();
                    if to_move.contains(&it_id) && !found.contains(&it_id) {
                        found.insert(it_id);
                        moved.push(it);
                    } else {
                        kept.push(it);
                    }
                }

                if found.len() != to_move.len() {
                    let missing: Vec<String> = spec
                        .children
                        .iter()
                        .filter(|c| !found.contains(*c))
                        .cloned()
                        .collect();
                    return Err(BuildError::NotFound(format!(
                        "не найдены айтемы для ряда: {}",
                        missing.join(", ")
                    )));
                }

                // Порядок детей в ряду — порядок, заданный в spec.children.
                let ordered: Vec<Value> = spec
                    .children
                    .iter()
                    .map(|cid| {
                        moved
                            .iter()
                            .find(|it| it.get("id").and_then(Value::as_str) == Some(cid))
                            .cloned()
                            .unwrap_or(Value::Null)
                    })
                    .collect();
                item.insert("children".into(), Value::Array(ordered));
                *items = kept;
                // Ряд вставляем на место первого перемещённого айтема.
                let first = spec
                    .children
                    .first()
                    .and_then(|cid| {
                        items
                            .iter()
                            .position(|it| it.get("id").and_then(Value::as_str) == Some(cid))
                    })
                    .unwrap_or(items.len());
                items.insert(first, Value::Object(item.clone()));
                // Пересобираем index, чтобы отразить изменения.
                self.write_node_body_and_index(node_id, body)?;
                return Ok(id);
            }
        }

        items.push(Value::Object(item));
        self.write_node_body_and_index(node_id, body)?;
        Ok(id)
    }

    /// Изменить существующий айтем ноды (текст, картинка, привязанный скрипт).
    ///
    /// Нужен там, где айтем уже создан: пересоздание сменило бы id, а его
    /// держат скрипты (`set_image`), поэтому правка идёт по месту.
    pub fn update_item(
        &self,
        node_id: &str,
        item_id: &str,
        patch: &ItemPatch,
    ) -> Result<(), BuildError> {
        if patch.text.is_none() && patch.source.is_none() && patch.script_id.is_none() {
            return Err(BuildError::Invalid(
                "нечего менять: задайте text, source или script".into(),
            ));
        }
        let mut body = self.load_node_body_object(node_id)?;
        let items = body
            .get_mut("content")
            .and_then(|c| c.get_mut("items"))
            .and_then(Value::as_array_mut)
            .ok_or_else(|| BuildError::Invalid(format!("у ноды {node_id} нет content.items")))?;
        // Ищем и внутри рядов: айтемы в ряду — обычное дело, и правка
        // «по верхнему уровню» их бы не находила.
        let item = find_item_mut(items, item_id)
            .ok_or_else(|| BuildError::NotFound(format!("айтем {item_id} в ноде {node_id}")))?;
        let obj = item
            .as_object_mut()
            .ok_or_else(|| BuildError::Invalid(format!("айтем {item_id} не объект")))?;

        if let Some(text) = &patch.text {
            obj.insert("text".into(), Value::String(text.clone()));
        }
        if let Some(source) = &patch.source {
            obj.insert("resourcePath".into(), Value::String(source.clone()));
        }
        if let Some(script_id) = &patch.script_id {
            if !self.store.exists(&self.script_path(script_id)) {
                return Err(BuildError::RefNotFound(format!(
                    "скрипт «{script_id}» не найден — список: `mnd-cli quest show`"
                )));
            }
            let event = if obj.get("type").and_then(Value::as_str) == Some("input") {
                "onSubmit"
            } else {
                "onPress"
            };
            set_item_trigger(obj, event, &format!("scripts/{script_id}.json"));
        }

        self.write_node_body_and_index(node_id, body)?;
        Ok(())
    }

    /// Удалить айтем ноды (вместе с его местом в ряду-родителе).
    pub fn remove_item(&self, node_id: &str, item_id: &str) -> Result<(), BuildError> {
        let mut body = self.load_node_body_object(node_id)?;
        let items = body
            .get_mut("content")
            .and_then(|c| c.get_mut("items"))
            .and_then(Value::as_array_mut)
            .ok_or_else(|| BuildError::Invalid(format!("у ноды {node_id} нет content.items")))?;

        if !drop_item(items, item_id) {
            return Err(BuildError::NotFound(format!(
                "айтем {item_id} в ноде {node_id}"
            )));
        }
        self.write_node_body_and_index(node_id, body)?;
        Ok(())
    }

    /// Тело ноды целиком (для `quest show`). Нода ищется по точному id.
    pub fn node_body_json(&self, node_id: &str) -> Result<Value, BuildError> {
        self.load_node_body_object(node_id)
            .map(Value::Object)
            .map_err(|_| BuildError::NotFound(format!("нода '{node_id}' не найдена")))
    }

    /// Тело скрипта целиком (для `quest show --script`).
    pub fn script_json(&self, script_id: &str) -> Result<Value, BuildError> {
        self.load_script_object(script_id)
            .map(Value::Object)
            .map_err(|_| BuildError::NotFound(format!("скрипт '{script_id}' не найден")))
    }

    /// Обзор квеста: главы с нодами, скрипты, таблицы, переменные.
    ///
    /// Отличается от [`Self::info`] тем, что группирует ноды по главам и
    /// даёт счётчики контента — то, что нужно, чтобы понять структуру квеста,
    /// не открывая каждый файл.
    pub fn tree(&self) -> Value {
        let config = self
            .store
            .read_json(&self.config_path())
            .unwrap_or(Value::Null);
        let start = config
            .get("startNodeId")
            .and_then(Value::as_str)
            .map(str::to_string);
        let nodes = self.load_node_bodies().unwrap_or_default();

        let mut chapters = Vec::new();
        for tag in config
            .get("tags")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default()
        {
            let id = tag.get("id").and_then(Value::as_str).unwrap_or("");
            let list: Vec<Value> = nodes
                .iter()
                .filter(|(node, _)| node.chapter_id == id)
                .map(|(node, body)| {
                    json!({
                        "id": node.id,
                        "title": node.title,
                        "items": body
                            .get("content")
                            .and_then(|c| c.get("items"))
                            .and_then(Value::as_array)
                            .map(Vec::len)
                            .unwrap_or(0),
                        "isStart": Some(node.id.as_str()) == start.as_deref(),
                    })
                })
                .collect();
            chapters.push(json!({
                "id": id,
                "name": tag.get("name").and_then(Value::as_str).unwrap_or(""),
                "nodes": list,
            }));
        }
        // Ноды без главы тоже видны: иначе они теряются из обзора.
        let orphans: Vec<Value> = nodes
            .iter()
            .filter(|(node, _)| {
                !chapters
                    .iter()
                    .any(|c| c["id"].as_str() == Some(node.chapter_id.as_str()))
            })
            .map(|(node, _)| {
                json!({
                    "id": node.id,
                    "title": node.title,
                    "chapterId": node.chapter_id,
                    "isStart": Some(node.id.as_str()) == start.as_deref(),
                })
            })
            .collect();

        let scripts: Vec<Value> = self
            .store
            .list_files(&self.rel_in_quest("scripts"), Some("json"))
            .into_iter()
            .map(|file| {
                let id = file.trim_end_matches(".json").to_string();
                let body = self
                    .store
                    .read_json(&self.script_path(&id))
                    .unwrap_or(Value::Null);
                let blocks = body
                    .get("blocks")
                    .and_then(Value::as_array)
                    .map(|blocks| {
                        blocks
                            .iter()
                            .filter(|b| b.get("type").and_then(Value::as_str) == Some("event"))
                            .flat_map(|b| {
                                b.get("children")
                                    .and_then(Value::as_array)
                                    .cloned()
                                    .unwrap_or_default()
                            })
                            .count()
                    })
                    .unwrap_or(0);
                json!({
                    "id": id,
                    "name": body.get("name").and_then(Value::as_str).unwrap_or(""),
                    "event": body
                        .get("blocks")
                        .and_then(Value::as_array)
                        .and_then(|b| b.first())
                        .and_then(|b| b.get("eventType"))
                        .and_then(Value::as_str)
                        .unwrap_or(""),
                    "blocks": blocks,
                })
            })
            .collect();

        let tables: Vec<Value> = config
            .get("tables")
            .and_then(Value::as_array)
            .map(|tables| {
                tables
                    .iter()
                    .map(|t| {
                        json!({
                            "name": t.get("name").and_then(Value::as_str).unwrap_or(""),
                            "columns": t
                                .get("columns")
                                .and_then(Value::as_array)
                                .map(Vec::len)
                                .unwrap_or(0),
                            "rows": t
                                .get("rows")
                                .and_then(Value::as_array)
                                .map(Vec::len)
                                .unwrap_or(0),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();

        json!({
            "questId": self.quest_id,
            "title": config.get("title").and_then(Value::as_str).unwrap_or(""),
            "author": config.get("author").cloned().unwrap_or(Value::Null),
            "startNodeId": start,
            "chapters": chapters,
            "orphanNodes": orphans,
            "scripts": scripts,
            "tables": tables,
            "variables": config.get("variables").cloned().unwrap_or(json!([])),
        })
    }

    /// Ссылка на ноду: id, уникальный префикс id или название.
    pub fn resolve_node(&self, raw: &str) -> Result<String, BuildError> {
        self.resolver()?.node(raw).map_err(BuildError::RefNotFound)
    }

    /// Ссылка на скрипт: id, имя, `scripts/<id>.json`.
    pub fn resolve_script(&self, raw: &str) -> Result<String, BuildError> {
        self.resolver()?
            .script(raw)
            .map_err(BuildError::RefNotFound)
    }

    /// Ссылка на главу: id или название.
    pub fn resolve_chapter(&self, raw: &str) -> Result<String, BuildError> {
        self.resolver()?
            .chapter(raw)
            .map_err(BuildError::RefNotFound)
    }

    fn resolver(&self) -> Result<crate::quest_plan::RefResolver, BuildError> {
        self.ensure_v2_layout()?;
        let nodes = self
            .load_node_bodies()?
            .into_iter()
            .map(|(node, _)| (node.id.clone(), node.title.clone()))
            .collect();
        let scripts = self
            .store
            .list_files(&self.rel_in_quest("scripts"), Some("json"))
            .into_iter()
            .map(|file| {
                let id = file.trim_end_matches(".json").to_string();
                let name = self
                    .store
                    .read_json(&self.script_path(&id))
                    .and_then(|v| v.get("name").and_then(Value::as_str).map(str::to_string))
                    .unwrap_or_default();
                (id, name)
            })
            .collect();
        let config = self.load_config_object()?;
        let chapters = config
            .get("tags")
            .and_then(Value::as_array)
            .map(|tags| {
                tags.iter()
                    .filter_map(|t| {
                        Some((
                            t.get("id").and_then(Value::as_str)?.to_string(),
                            t.get("name").and_then(Value::as_str)?.to_string(),
                        ))
                    })
                    .collect()
            })
            .unwrap_or_default();
        Ok(crate::quest_plan::RefResolver::new(
            nodes, scripts, chapters,
        ))
    }

    /// Установить стартовую ноду.
    pub fn set_start_node(&self, node_id: &str) -> Result<(), BuildError> {
        let _ = self.load_node_body_object(node_id)?;
        let mut config = self.load_config_object()?;
        config.insert("startNodeId".into(), Value::String(node_id.to_string()));
        config.insert("updated".into(), Value::String(iso8601_now()));
        config.insert("lastEditedAt".into(), Value::String(iso8601_now()));
        self.store
            .write_json(&self.config_path(), &Value::Object(config))
            .map_err(store_err)?;
        Ok(())
    }

    /// Изменить поля существующей ноды (заголовок, глава, позиция, старт).
    ///
    /// Отдельная команда вместо «удалить и создать»: id ноды держат
    /// переходы, скрипты и сейвы, и пересоздание порвало бы их.
    pub fn update_node(&self, node_id: &str, edit: &NodeEdit) -> Result<(), BuildError> {
        let mut body = self.load_node_body_object(node_id)?;

        if let Some(title) = &edit.title {
            if title.trim().is_empty() {
                return Err(BuildError::Invalid(
                    "название ноды не может быть пустым".into(),
                ));
            }
            body.insert("title".into(), Value::String(title.clone()));
        }
        if let Some(chapter_id) = &edit.chapter_id {
            let config = self.load_config_object()?;
            let tags = config
                .get("tags")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            if !tags
                .iter()
                .any(|t| t.get("id").and_then(Value::as_str) == Some(chapter_id.as_str()))
            {
                return Err(BuildError::Invalid(format!(
                    "глава '{chapter_id}' не найдена"
                )));
            }
            body.insert("chapterId".into(), Value::String(chapter_id.clone()));
        }
        if let Some(x) = edit.x {
            body.insert("x".into(), json!(x));
        }
        if let Some(y) = edit.y {
            body.insert("y".into(), json!(y));
        }

        let mut index = self.load_index_object()?;
        let summaries = index
            .entry("nodes")
            .or_insert_with(|| Value::Array(vec![]))
            .as_array_mut()
            .ok_or_else(|| BuildError::Invalid("index.nodes не массив".into()))?;
        // Правку накладываем на существующую сводку, а не заменяем её: в
        // сводке живут `preview` и другие поля редактора, которых нет в теле
        // ноды, и пересборка с нуля их бы снесла.
        let existing = summaries
            .iter()
            .position(|s| s.get("id").and_then(Value::as_str) == Some(node_id));
        match existing {
            Some(pos) => {
                let merged = merge_summary(&summaries[pos], &body);
                summaries[pos] = merged;
            }
            None => summaries.push(summary_from_body(&body)),
        }

        let mut ops = vec![
            StoreOp::WriteJson {
                rel: self.node_body_path(node_id),
                value: Value::Object(body),
            },
            StoreOp::WriteJson {
                rel: self.index_path(),
                value: Value::Object(index),
            },
        ];

        if edit.start == Some(true) {
            let mut config = self.load_config_object()?;
            config.insert("startNodeId".into(), Value::String(node_id.to_string()));
            config.insert("updated".into(), Value::String(iso8601_now()));
            config.insert("lastEditedAt".into(), Value::String(iso8601_now()));
            ops.push(StoreOp::WriteJson {
                rel: self.config_path(),
                value: Value::Object(config),
            });
        }

        self.store.transact(&ops).map_err(store_err)?;
        Ok(())
    }

    /// Создать новый скрипт с одним event-блоком.
    pub fn create_script(
        &self,
        name: &str,
        event: ScriptEvent,
        id: Option<&str>,
    ) -> Result<String, BuildError> {
        if name.trim().is_empty() {
            return Err(BuildError::Invalid(
                "имя скрипта не может быть пустым".into(),
            ));
        }
        let id = id
            .map(|s| s.to_string())
            .unwrap_or_else(|| Uuid::new_v4().to_string());
        let path = self.script_path(&id);
        if self.store.exists(&path) {
            return Err(BuildError::Invalid(format!("скрипт {id} уже существует")));
        }
        let event_type = event_type_string(event);
        let script = json!({
            "id": id,
            "name": name,
            "blocks": [{
                "type": "event",
                "eventType": event_type,
                "id": Uuid::new_v4().to_string(),
                "collapsed": false,
                "children": []
            }]
        });
        self.validate_script_or_err(&script)?;
        self.store.write_json(&path, &script).map_err(store_err)?;
        Ok(id)
    }

    /// Добавить блок к первому event-блоку скрипта.
    pub fn add_block(&self, script_id: &str, block: Value) -> Result<(), BuildError> {
        let mut script = self.load_script_object(script_id)?;
        let blocks = script
            .get_mut("blocks")
            .and_then(Value::as_array_mut)
            .ok_or_else(|| BuildError::Invalid(format!("у скрипта {script_id} нет blocks")))?;
        let first = blocks
            .iter_mut()
            .find(|b| {
                b.get("type")
                    .and_then(Value::as_str)
                    .is_some_and(|t| t == script_format::types::EVENT)
            })
            .ok_or_else(|| BuildError::Invalid(format!("в скрипте {script_id} нет event-блока")))?;
        let children = first
            .get_mut("children")
            .and_then(Value::as_array_mut)
            .ok_or_else(|| {
                BuildError::Invalid(format!("event-блок скрипта {script_id} без children"))
            })?;
        children.push(block);

        self.validate_script_or_err(&Value::Object(script.clone()))?;
        self.store
            .write_json(&self.script_path(script_id), &Value::Object(script))
            .map_err(store_err)?;
        Ok(())
    }

    /// Добавить блок `set_image`.
    pub fn set_image_block(
        &self,
        script_id: &str,
        item_id: &str,
        source: &str,
    ) -> Result<(), BuildError> {
        if item_id.trim().is_empty() {
            return Err(BuildError::Invalid("item_id не может быть пустым".into()));
        }
        if source.trim().is_empty() {
            return Err(BuildError::Invalid("source не может быть пустым".into()));
        }
        let block = json!({
            "type": "set_image",
            "item_id": item_id,
            "item_name": item_id,
            "source": source
        });
        self.add_block(script_id, block)
    }

    /// Добавить блок `assign_variable`.
    pub fn assign_block(
        &self,
        script_id: &str,
        variable: &str,
        value: &Value,
    ) -> Result<(), BuildError> {
        if variable.trim().is_empty() {
            return Err(BuildError::Invalid(
                "имя переменной не может быть пустым".into(),
            ));
        }
        let block = json!({
            "type": "assign_variable",
            "variable": variable,
            "value": value
        });
        self.add_block(script_id, block)
    }

    /// Добавить блок `wait`.
    pub fn wait_block(&self, script_id: &str, ms: u64) -> Result<(), BuildError> {
        let block = json!({
            "type": "wait",
            "expression": ms.to_string()
        });
        self.add_block(script_id, block)
    }

    /// Добавить блок `go_to_node`.
    pub fn goto_block(&self, script_id: &str, node_id: &str) -> Result<(), BuildError> {
        let _ = self.load_node_body_object(node_id)?;
        let block = json!({
            "type": "go_to_node",
            "node_id": node_id
        });
        self.add_block(script_id, block)
    }

    /// Установить таблицу в config.
    pub fn set_table(
        &self,
        name: &str,
        columns: &[String],
        row_names: &[String],
        rows: &[Value],
    ) -> Result<(), BuildError> {
        if name.trim().is_empty() {
            return Err(BuildError::Invalid(
                "имя таблицы не может быть пустым".into(),
            ));
        }
        if row_names.len() != rows.len() {
            return Err(BuildError::Invalid(format!(
                "количество row_names ({}) не совпадает с rows ({})",
                row_names.len(),
                rows.len()
            )));
        }
        if columns.is_empty() {
            return Err(BuildError::Invalid(
                "таблица должна иметь хотя бы одну колонку".into(),
            ));
        }

        let mut config = self.load_config_object()?;
        let tables = config
            .entry("tables")
            .or_insert_with(|| Value::Array(vec![]))
            .as_array_mut()
            .ok_or_else(|| BuildError::Invalid("tables не массив".into()))?;

        // Удаляем старую таблицу с таким именем.
        tables.retain(|t| {
            t.get("name")
                .and_then(Value::as_str)
                .is_some_and(|n| n != name)
        });

        tables.push(json!({
            "name": name,
            "folderPath": "/",
            "columns": columns,
            "rowNames": row_names,
            "rows": rows,
            "data": {}
        }));

        config.insert("updated".into(), Value::String(iso8601_now()));
        config.insert("lastEditedAt".into(), Value::String(iso8601_now()));
        self.store
            .write_json(&self.config_path(), &Value::Object(config))
            .map_err(store_err)?;
        Ok(())
    }

    /// Установить переменную в config.
    pub fn set_variable(&self, name: &str, default: Value) -> Result<(), BuildError> {
        if name.trim().is_empty() {
            return Err(BuildError::Invalid(
                "имя переменной не может быть пустым".into(),
            ));
        }
        let mut config = self.load_config_object()?;
        let variables = config
            .entry("variables")
            .or_insert_with(|| Value::Array(vec![]))
            .as_array_mut()
            .ok_or_else(|| BuildError::Invalid("variables не массив".into()))?;

        variables.retain(|v| {
            v.get("name")
                .and_then(Value::as_str)
                .is_some_and(|n| n != name)
        });
        variables.push(json!({"name": name, "defaultValue": default}));

        config.insert("updated".into(), Value::String(iso8601_now()));
        config.insert("lastEditedAt".into(), Value::String(iso8601_now()));
        self.store
            .write_json(&self.config_path(), &Value::Object(config))
            .map_err(store_err)?;
        Ok(())
    }

    /// Добавить игровой ресурс: копирует файл и регистрирует в metadata.json.
    pub fn add_resource(
        &self,
        file: &Path,
        name: Option<&str>,
        kind: ResourceKind,
    ) -> Result<String, BuildError> {
        if !file.is_file() {
            return Err(BuildError::NotFound(format!("файл {}", file.display())));
        }
        let ext = file
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_lowercase();
        let resource_id = Uuid::new_v4().to_string();
        let filename = if ext.is_empty() {
            resource_id.clone()
        } else {
            format!("{resource_id}.{ext}")
        };
        let folder = kind.folder();
        let rel = format!("quests/{}/res/{folder}/{filename}", self.quest_id);
        let target = self.root.join(&rel);

        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| BuildError::Io(format!("mkdir {}: {e}", parent.display())))?;
        }
        std::fs::copy(file, &target).map_err(|e| {
            BuildError::Io(format!(
                "copy {} -> {}: {e}",
                file.display(),
                target.display()
            ))
        })?;

        // Ключ метаданных — имя файла на диске: по нему библиотека ресурсов
        // сопоставляет запись с файлом. Имя исходного файла тут не годится.
        let meta_key = filename.clone();
        let display_name = name
            .filter(|s| !s.is_empty())
            .map(|s| s.to_string())
            .unwrap_or_else(|| meta_key.clone());

        self.store
            .metadata_mutate(
                &self.quest_id,
                &[MetaMutation::Set {
                    key: meta_key,
                    value: json!({
                        "folder": "/",
                        "name": display_name,
                        "resourceId": resource_id
                    }),
                }],
            )
            .map_err(store_err)?;

        Ok(format!("res/{folder}/{filename}"))
    }

    /// Сводная информация по квесту.
    pub fn info(&self) -> Value {
        let config = self
            .store
            .read_json(&self.config_path())
            .unwrap_or(Value::Object(Map::new()));
        let title = config
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let start_node_id = config
            .get("startNodeId")
            .and_then(Value::as_str)
            .map(|s| Value::String(s.to_string()))
            .unwrap_or(Value::Null);

        let nodes = self.load_node_bodies().unwrap_or_default();

        // Для глав считаем количество нод.
        let mut counts: HashMap<String, usize> = HashMap::new();
        for (n, _) in &nodes {
            *counts.entry(n.chapter_id.clone()).or_insert(0) += 1;
        }
        let mut chapters = Vec::new();
        if let Some(tags) = config.get("tags").and_then(Value::as_array) {
            for tag in tags {
                let id = tag.get("id").and_then(Value::as_str).unwrap_or("");
                let name = tag.get("name").and_then(Value::as_str).unwrap_or("");
                chapters.push(json!({
                    "id": id,
                    "name": name,
                    "nodeCount": counts.get(id).copied().unwrap_or(0)
                }));
            }
        }

        let nodes_json: Vec<Value> = nodes
            .iter()
            .map(|(n, body)| {
                let items_len = body
                    .get("content")
                    .and_then(|c| c.get("items"))
                    .and_then(Value::as_array)
                    .map(|a| a.len())
                    .unwrap_or(0);
                json!({
                    "id": n.id.clone(),
                    "title": n.title.clone(),
                    "chapterId": n.chapter_id.clone(),
                    "x": n.x,
                    "y": n.y,
                    "items": items_len
                })
            })
            .collect();

        let mut scripts = Vec::new();
        let script_dir = format!("quests/{}/scripts", self.quest_id);
        let mut names = self.store.list_files(&script_dir, Some("json"));
        names.sort();
        for name in names {
            let id = name.trim_end_matches(".json");
            let value = self
                .store
                .read_json(&format!("{script_dir}/{name}"))
                .unwrap_or(Value::Null);
            let blocks = value
                .get("blocks")
                .and_then(Value::as_array)
                .map(|a| a.len())
                .unwrap_or(0);
            scripts.push(json!({
                "id": id,
                "name": value.get("name").and_then(Value::as_str).unwrap_or(id),
                "blocks": blocks
            }));
        }

        let tables = config
            .get("tables")
            .cloned()
            .unwrap_or(Value::Array(vec![]));
        let variables = config
            .get("variables")
            .cloned()
            .unwrap_or(Value::Array(vec![]));

        json!({
            "questId": self.quest_id,
            "title": title,
            "startNodeId": start_node_id,
            "chapters": chapters,
            "nodes": nodes_json,
            "scripts": scripts,
            "tables": tables,
            "variables": variables
        })
    }

    // -------------------------------------------------------------------------
    // --- Внутренние helpers ---
    // -------------------------------------------------------------------------

    fn quest_dir(&self) -> String {
        format!("quests/{}", self.quest_id)
    }

    fn config_path(&self) -> String {
        format!("{}/config.json", self.quest_dir())
    }

    fn index_path(&self) -> String {
        format!("{}/nodes/index.json", self.quest_dir())
    }

    fn node_body_path(&self, node_id: &str) -> String {
        format!("{}/nodes/{node_id}.json", self.quest_dir())
    }

    fn script_path(&self, script_id: &str) -> String {
        format!("{}/scripts/{script_id}.json", self.quest_dir())
    }

    fn rel_in_quest(&self, rel: &str) -> String {
        format!("{}/{rel}", self.quest_dir())
    }

    fn load_config_object(&self) -> Result<Map<String, Value>, BuildError> {
        self.store
            .read_json(&self.config_path())
            .and_then(|v| v.as_object().cloned())
            .ok_or_else(|| BuildError::NotFound(self.config_path()))
    }

    fn load_index_object(&self) -> Result<Map<String, Value>, BuildError> {
        match self.store.read_json(&self.index_path()) {
            Some(Value::Object(map)) => Ok(map),
            Some(_) => Err(BuildError::UnsupportedLayout(format!(
                "{} не объект",
                self.index_path()
            ))),
            None => {
                // Пытаемся мигрировать легаси-монолит.
                self.migrate_legacy_nodes()?;
                self.store
                    .read_json(&self.index_path())
                    .and_then(|v| v.as_object().cloned())
                    .ok_or_else(|| {
                        BuildError::UnsupportedLayout(format!(
                            "не удалось создать {}",
                            self.index_path()
                        ))
                    })
            }
        }
    }

    fn load_node_body_object(&self, node_id: &str) -> Result<Map<String, Value>, BuildError> {
        self.ensure_v2_layout()?;
        self.store
            .read_json(&self.node_body_path(node_id))
            .and_then(|v| v.as_object().cloned())
            .ok_or_else(|| {
                BuildError::RefNotFound(format!(
                    "нода «{node_id}» не найдена — список: `mnd-cli quest show`"
                ))
            })
    }

    fn load_script_object(&self, script_id: &str) -> Result<Map<String, Value>, BuildError> {
        self.store
            .read_json(&self.script_path(script_id))
            .and_then(|v| v.as_object().cloned())
            .ok_or_else(|| {
                BuildError::RefNotFound(format!(
                    "скрипт «{script_id}» не найден — список: `mnd-cli quest show`"
                ))
            })
    }

    /// Убедиться, что у квеста v2-раскладка: если индекса нет, мигрировать.
    fn ensure_v2_layout(&self) -> Result<(), BuildError> {
        if self.store.exists(&self.index_path()) {
            return Ok(());
        }
        self.migrate_legacy_nodes()
    }

    /// Миграция монолитных nodes.json|nodes/nodes.json в v2.
    /// Перед разбиением сохраняет бэкап в nodes/migration-backup.json.
    fn migrate_legacy_nodes(&self) -> Result<(), BuildError> {
        if self.store.exists(&self.index_path()) {
            return Ok(());
        }

        let mut bodies: Vec<Value> = Vec::new();
        let fallback = format!("{}/nodes/nodes.json", self.quest_dir());
        let legacy = format!("{}/nodes.json", self.quest_dir());

        if let Some(Value::Object(mut obj)) = self.store.read_json(&fallback) {
            if let Some(Value::Array(arr)) = obj.remove("nodes") {
                bodies = arr;
            } else {
                bodies = vec![Value::Object(obj)];
            }
        } else if let Some(Value::Object(mut obj)) = self.store.read_json(&legacy) {
            if let Some(Value::Array(arr)) = obj.remove("nodes") {
                bodies = arr;
            } else {
                bodies = vec![Value::Object(obj)];
            }
        }

        if bodies.is_empty() {
            return Err(BuildError::UnsupportedLayout(format!(
                "нет ни {}, ни {}, ни nodes/index.json",
                fallback, legacy
            )));
        }

        // Бэкап: ровно один файл, в котором список исходных нод.
        let backup = format!("{}/nodes/migration-backup.json", self.quest_dir());
        let backup_content = json!({"nodes": bodies.clone()});

        // Пишем тела и индекс одной транзакцией.
        let mut ops = Vec::with_capacity(bodies.len() + 2);
        ops.push(StoreOp::WriteJson {
            rel: backup,
            value: backup_content,
        });

        let mut valid_bodies = Vec::new();
        for body in &bodies {
            let Some(obj) = body.as_object() else {
                return Err(BuildError::Invalid(format!(
                    "элемент nodes не объект: {}",
                    serde_json::to_string(body).unwrap_or_default()
                )));
            };
            let id = obj
                .get("id")
                .and_then(Value::as_str)
                .ok_or_else(|| BuildError::Invalid("нода без id в монолите".into()))?
                .to_string();
            valid_bodies.push(body.clone());
            ops.push(StoreOp::WriteJson {
                rel: self.node_body_path(&id),
                value: body.clone(),
            });
        }

        let index = make_v2_index(&valid_bodies, Map::new());
        ops.push(StoreOp::WriteJson {
            rel: self.index_path(),
            value: index,
        });

        self.store.transact(&ops).map_err(store_err)?;
        Ok(())
    }

    fn load_node_bodies(&self) -> NodeBodies {
        self.ensure_v2_layout()?;
        let index = self
            .store
            .read_json(&self.index_path())
            .ok_or_else(|| BuildError::NotFound(self.index_path()))?;
        let summaries = index
            .get("nodes")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let mut out = Vec::with_capacity(summaries.len());
        for summary in summaries {
            let id = summary
                .get("id")
                .and_then(Value::as_str)
                .ok_or_else(|| BuildError::Invalid("сводка ноды без id".into()))?;
            let body = self
                .store
                .read_json(&self.node_body_path(id))
                .and_then(|v| v.as_object().cloned())
                .ok_or_else(|| BuildError::NotFound(format!("nodes/{id}.json")))?;
            let node = SavedNode::from_json(&Value::Object(body.clone()));
            out.push((node, body));
        }
        Ok(out)
    }

    /// Записать тело ноды и пересобрать её сводку в индексе.
    fn write_node_body_and_index(
        &self,
        node_id: &str,
        body: Map<String, Value>,
    ) -> Result<(), BuildError> {
        let mut index = self.load_index_object()?;
        let summaries = index
            .get_mut("nodes")
            .and_then(Value::as_array_mut)
            .ok_or_else(|| BuildError::Invalid("index.nodes не массив".into()))?;
        let pos = summaries
            .iter()
            .position(|s| s.get("id").and_then(Value::as_str) == Some(node_id));
        match pos {
            Some(i) => {
                let merged = merge_summary(&summaries[i], &body);
                summaries[i] = merged;
            }
            None => summaries.push(summary_from_body(&body)),
        }

        self.store
            .transact(&[
                StoreOp::WriteJson {
                    rel: self.node_body_path(node_id),
                    value: Value::Object(body),
                },
                StoreOp::WriteJson {
                    rel: self.index_path(),
                    value: Value::Object(index),
                },
            ])
            .map_err(store_err)?;
        Ok(())
    }

    fn validate_script_or_err(&self, script: &Value) -> Result<(), BuildError> {
        let obj = script
            .as_object()
            .ok_or_else(|| BuildError::Invalid("скрипт не является объектом".into()))?;
        let issues = script_format::validate_script(obj);
        if issues
            .iter()
            .any(|i| matches!(i.severity, script_format::Severity::Error))
        {
            // Собираем первые сообщения в одну строку.
            let msg = issues
                .iter()
                .filter(|i| matches!(i.severity, script_format::Severity::Error))
                .map(|i| format!("{}: {}", i.path, i.message))
                .collect::<Vec<_>>()
                .join("; ");
            return Err(BuildError::Invalid(format!(
                "ошибки валидации скрипта: {msg}"
            )));
        }
        Ok(())
    }
}

fn default_item_map(id: &str, kind: ItemKind) -> Map<String, Value> {
    let mut map = Map::new();
    map.insert("id".into(), Value::String(id.to_string()));
    map.insert(
        "type".into(),
        Value::String(
            match kind {
                ItemKind::Text => "text",
                ItemKind::Image => "image",
                ItemKind::Button => "button",
                ItemKind::Row => "row",
            }
            .into(),
        ),
    );
    map.insert("flex".into(), json!(1_i64));
    map.insert("animateIn".into(), json!(true));
    map.insert("isHidden".into(), json!(false));
    map.insert("isIncoming".into(), json!(true));
    map.insert("locked".into(), json!(false));
    map.insert("rowTextAlignment".into(), Value::String("center".into()));
    map.insert("textFit".into(), Value::String("auto".into()));
    map.insert("volume".into(), json!(1.0));
    map.insert("wrapText".into(), json!(true));
    map.insert("crossAxisAlignment".into(), Value::String("center".into()));
    map
}

/// Тело ноды вместе с разобранной моделью — как их отдаёт чтение с диска.
type NodeBodies = Result<Vec<(SavedNode, Map<String, Value>)>, BuildError>;

/// Прописать айтему действие-скрипт так, как его исполняет движок.
///
/// Движок читает `behaviours` (новый формат) и legacy `scriptTriggers`.
/// Поле `scriptAssetId` у айтема не исполняется вообще — именно на нём легко
/// «собрать» кнопку, которая в редакторе выглядит живой, а в игре молчит.
/// Прежний триггер того же события заменяется, остальные события сохраняются.
pub(crate) fn set_item_trigger(item: &mut Map<String, Value>, event: &str, script_path: &str) {
    let mut list: Vec<Value> = item
        .get("behaviours")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    list.retain(|b| b.get("event").and_then(Value::as_str) != Some(event));
    list.push(json!({"event": event, "script": script_path}));
    item.insert("behaviours".into(), Value::Array(list));
    if let Some(triggers) = item
        .get_mut("scriptTriggers")
        .and_then(Value::as_object_mut)
    {
        triggers.remove(event);
    }
}

/// Найти айтем по id, включая вложенные в ряды и стеки.
fn find_item_mut<'a>(items: &'a mut [Value], item_id: &str) -> Option<&'a mut Value> {
    if let Some(pos) = items
        .iter()
        .position(|it| it.get("id").and_then(Value::as_str) == Some(item_id))
    {
        return items.get_mut(pos);
    }
    for item in items.iter_mut() {
        if let Some(children) = item.get_mut("children").and_then(Value::as_array_mut)
            && let Some(found) = find_item_mut(children, item_id)
        {
            return Some(found);
        }
    }
    None
}

/// Удалить айтем по id, включая вложенные в ряды и стеки.
fn drop_item(items: &mut Vec<Value>, item_id: &str) -> bool {
    if let Some(pos) = items
        .iter()
        .position(|it| it.get("id").and_then(Value::as_str) == Some(item_id))
    {
        items.remove(pos);
        return true;
    }
    for item in items.iter_mut() {
        if let Some(children) = item.get_mut("children").and_then(Value::as_array_mut)
            && drop_item(children, item_id)
        {
            return true;
        }
    }
    false
}

/// Сводка ноды для индекса с сохранением полей, которых нет в теле
/// (`preview` и прочие редакторские): пересборка с нуля их бы снесла.
fn merge_summary(existing: &Value, body: &Map<String, Value>) -> Value {
    let mut summary = existing.clone();
    let Some(obj) = summary.as_object_mut() else {
        return summary_from_body(body);
    };
    obj.remove("content");
    for (key, value) in body {
        if key == "content" {
            continue;
        }
        obj.insert(key.clone(), value.clone());
    }
    summary
}

fn summary_from_body(body: &Map<String, Value>) -> Value {
    let mut summary = body.clone();
    summary.remove("content");
    summary.insert("type".into(), Value::String("node".into()));
    Value::Object(summary)
}

fn make_v2_index(bodies: &[Value], extra: Map<String, Value>) -> Value {
    let mut map = extra.clone();
    map.insert("format_version".into(), json!(2_i64));
    // Rust не собирает превью — редактор пересоберёт card_preview_version != 1 сам.
    map.insert("card_preview_version".into(), json!(0_i64));
    let summaries: Vec<Value> = bodies
        .iter()
        .filter_map(|b| b.as_object().map(summary_from_body))
        .collect();
    map.insert("nodes".into(), Value::Array(summaries));
    // Гарантируем presence groups/comments/edges, если их ещё нет.
    map.entry("groups".to_string())
        .or_insert_with(|| Value::Array(vec![]));
    map.entry("comments".to_string())
        .or_insert_with(|| Value::Array(vec![]));
    map.entry("edges".to_string())
        .or_insert_with(|| Value::Array(vec![]));
    Value::Object(map)
}

fn event_type_string(event: ScriptEvent) -> &'static str {
    match event {
        ScriptEvent::OnPress => "onPress",
        ScriptEvent::OnEnter => "onNodeEnter",
        ScriptEvent::OnAppear => "onContentAppear",
    }
}

fn store_err(e: crate::quest_store::StoreError) -> BuildError {
    BuildError::Io(e.to_string())
}

/// ISO-8601 без часового пояса с миллисекундами.
pub(crate) fn iso8601_now() -> String {
    let nanos = crate::time::unix_now_nanos();
    let secs = (nanos / 1_000_000_000) as i64;
    let ms = ((nanos / 1_000_000) % 1000) as u32;
    let (y, m, d) = civil_from_days(secs / 86400);
    let rem = secs % 86400;
    let hour = (rem / 3600) as u32;
    let min = ((rem % 3600) / 60) as u32;
    let sec = (rem % 60) as u32;
    format!("{y:04}-{m:02}-{d:02}T{hour:02}:{min:02}:{sec:02}.{ms:03}")
}

/// Перевод дней с 1970-01-01 в (year, month, day).
/// Алгоритм Howard Hinnant, повторяется здесь, чтобы не зависеть от private
/// деталей engine.rs.
fn civil_from_days(z: i64) -> (i64, i64, i64) {
    let z = z + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::io::Write;

    fn tmp_store() -> (PathBuf, FsQuestStore) {
        let dir = tempfile::tempdir().unwrap().keep();
        (dir.clone(), FsQuestStore::new(&dir))
    }

    #[test]
    fn create_info_and_validation_is_clean() {
        let (root, _) = tmp_store();
        let qb = QuestBuilder::create("q1", &root, "Тест", Some("Автор"), Some("Глава 1")).unwrap();
        let info = qb.info();
        assert_eq!(info["questId"], "q1");
        assert_eq!(info["title"], "Тест");
        assert!(!info["startNodeId"].as_str().unwrap().is_empty());
        assert_eq!(info["chapters"].as_array().unwrap().len(), 1);
        assert_eq!(info["nodes"].as_array().unwrap().len(), 1);
        for folder in ["images", "audio", "videos", "fonts"] {
            assert!(
                root.join(format!("quests/q1/res/{folder}")).is_dir(),
                "каталог res/{folder} должен создаваться вместе с квестом"
            );
        }

        let report = crate::validation::analyze_quest("q1", &root);
        assert!(
            !report.has_errors(),
            "create → validate не должен иметь ошибок: {:?}",
            report.diagnostics
        );
        assert!(
            report
                .diagnostics
                .iter()
                .all(|d| d.kind != crate::validation::DiagnosticKind::MissingStartNode)
        );
        assert!(
            report
                .diagnostics
                .iter()
                .all(|d| d.kind != crate::validation::DiagnosticKind::NoChapters)
        );
    }

    #[test]
    fn item_patch_updates_in_place_and_removal_drops_from_row() {
        let (root, _) = tmp_store();
        let qb = QuestBuilder::create("q4", &root, "Тест 4", None, Some("Глава 1")).unwrap();
        let node_id = qb.info()["startNodeId"].as_str().unwrap().to_string();

        let script_id = qb
            .create_script("Скрипт", ScriptEvent::OnPress, None)
            .unwrap();
        let button = qb
            .add_item(
                &node_id,
                &ItemSpec {
                    kind: ItemKind::Button,
                    text: Some("Старый текст".into()),
                    script_id: Some(script_id.clone()),
                    ..Default::default()
                },
            )
            .unwrap();
        let image = qb
            .add_item(
                &node_id,
                &ItemSpec {
                    kind: ItemKind::Image,
                    source: Some("res/images/a.png".into()),
                    ..Default::default()
                },
            )
            .unwrap();
        let row = qb
            .add_item(
                &node_id,
                &ItemSpec {
                    kind: ItemKind::Row,
                    children: vec![button.clone(), image.clone()],
                    ..Default::default()
                },
            )
            .unwrap();

        qb.update_item(
            &node_id,
            &button,
            &ItemPatch {
                text: Some("Новый текст".into()),
                source: None,
                script_id: None,
            },
        )
        .unwrap();
        // id айтема не меняется: на него ссылаются блоки `set_image`.
        assert_eq!(button.len(), 36);

        let body: Value = serde_json::from_str(
            &std::fs::read_to_string(root.join(format!("quests/q4/nodes/{node_id}.json"))).unwrap(),
        )
        .unwrap();
        let items = body["content"]["items"].as_array().unwrap();
        let row_item = items
            .iter()
            .find(|it| it["id"] == row)
            .expect("ряд должен остаться на месте");
        assert_eq!(row_item["children"].as_array().unwrap().len(), 2);
        let btn = row_item["children"]
            .as_array()
            .unwrap()
            .iter()
            .find(|it| it["id"] == button)
            .unwrap();
        assert_eq!(btn["text"], "Новый текст");

        // Удаление вложенного айтема не трогает ряд целиком.
        qb.remove_item(&node_id, &image).unwrap();
        let body: Value = serde_json::from_str(
            &std::fs::read_to_string(root.join(format!("quests/q4/nodes/{node_id}.json"))).unwrap(),
        )
        .unwrap();
        let items = body["content"]["items"].as_array().unwrap();
        let row_item = items.iter().find(|it| it["id"] == row).unwrap();
        let children = row_item["children"].as_array().unwrap();
        assert_eq!(children.len(), 1);
        assert_eq!(children[0]["id"], button);

        // Несуществующий айтем — ошибка, нода не портится.
        assert!(qb.remove_item(&node_id, &image).is_err());
    }

    #[test]
    fn update_node_changes_fields_and_keeps_preview() {
        let (root, _) = tmp_store();
        let qb = QuestBuilder::create("q3", &root, "Тест 3", None, Some("Глава 1")).unwrap();
        let node_id = qb.info()["startNodeId"].as_str().unwrap().to_string();

        // Редактор уже сложил превью карточки в сводку индекса: правка ноды
        // обязана его сохранить, иначе карточка на канвасе опустеет.
        let index_path = root.join("quests/q3/nodes/index.json");
        let mut index: Value =
            serde_json::from_str(&std::fs::read_to_string(&index_path).unwrap()).unwrap();
        index["nodes"][0]["preview"] = json!("данные-превью");
        std::fs::write(&index_path, serde_json::to_string(&index).unwrap()).unwrap();

        let chapter = qb.add_chapter("Глава 2", None).unwrap();
        qb.update_node(
            &node_id,
            &NodeEdit {
                title: Some("Новое имя".into()),
                chapter_id: Some(chapter.clone()),
                x: Some(42.0),
                y: Some(24.0),
                start: Some(true),
            },
        )
        .unwrap();

        assert_eq!(qb.info()["startNodeId"].as_str().unwrap(), node_id);

        let body: Value = serde_json::from_str(
            &std::fs::read_to_string(root.join(format!("quests/q3/nodes/{node_id}.json"))).unwrap(),
        )
        .unwrap();
        assert_eq!(body["title"], "Новое имя");
        assert_eq!(body["chapterId"], chapter);
        assert_eq!(body["x"], 42.0);
        assert_eq!(body["y"], 24.0);

        let index: Value =
            serde_json::from_str(&std::fs::read_to_string(&index_path).unwrap()).unwrap();
        assert_eq!(index["nodes"][0]["title"], "Новое имя");
        assert_eq!(index["nodes"][0]["preview"], "данные-превью");
        assert_eq!(index["nodes"][0]["chapterId"], chapter);

        // Несуществующая глава — ошибка, нода не портится.
        assert!(
            qb.update_node(
                &node_id,
                &NodeEdit {
                    chapter_id: Some("нет-такой".into()),
                    ..Default::default()
                },
            )
            .is_err()
        );
    }

    #[test]
    fn add_chapter_node_item_table_variable_and_resource() {
        let (root, _) = tmp_store();
        let qb = QuestBuilder::create("q2", &root, "Тест 2", None, None).unwrap();

        let chapter_id = qb.add_chapter("Глава 2", None).unwrap();
        let node_id = qb
            .add_node(&NodeSpec {
                title: "Сцена 2".into(),
                chapter_id: Some(chapter_id.clone()),
                x: Some(100.0),
                y: Some(200.0),
                start: false,
                id: None,
            })
            .unwrap();

        let text_id = qb
            .add_item(
                &node_id,
                &ItemSpec {
                    kind: ItemKind::Text,
                    text: Some("Привет".into()),
                    ..Default::default()
                },
            )
            .unwrap();
        assert!(!text_id.is_empty());

        // Кнопка со скриптом.
        let script_id = qb
            .create_script("Далее", ScriptEvent::OnPress, None)
            .unwrap();
        qb.goto_block(&script_id, qb.info()["startNodeId"].as_str().unwrap())
            .unwrap();
        let _btn_id = qb
            .add_item(
                &node_id,
                &ItemSpec {
                    kind: ItemKind::Button,
                    text: Some("Далее".into()),
                    script_id: Some(script_id.clone()),
                    ..Default::default()
                },
            )
            .unwrap();

        qb.set_table(
            "loot",
            &["name".into(), "weight".into()],
            &["меч".into(), "щит".into()],
            &[json!(["меч", 10]), json!(["щит", 5])],
        )
        .unwrap();

        qb.set_variable("gold", json!(100)).unwrap();

        // Ресурс.
        let img = root.join("tmp.png");
        {
            let mut f = std::fs::File::create(&img).unwrap();
            f.write_all(b"PNG").unwrap();
        }
        let res_path = qb
            .add_resource(&img, Some("Картинка"), ResourceKind::Image)
            .unwrap();
        assert!(res_path.starts_with("res/images/"));

        let report = crate::validation::analyze_quest("q2", &root);
        assert!(!report.has_errors(), "{:?}", report.diagnostics);
    }

    #[test]
    fn add_item_to_missing_node_does_not_modify_files() {
        let (root, store) = tmp_store();
        let qb = QuestBuilder::create("q3", &root, "Тест 3", None, None).unwrap();

        // Снимаем mtime конфига.
        let config_abs = store.resolve(&qb.config_path()).unwrap();
        let before = std::fs::metadata(&config_abs).unwrap().modified().unwrap();

        let err = qb
            .add_item(
                "missing-node",
                &ItemSpec {
                    kind: ItemKind::Text,
                    text: Some("x".into()),
                    ..Default::default()
                },
            )
            .unwrap_err();
        assert!(matches!(
            err,
            BuildError::NotFound(_) | BuildError::RefNotFound(_)
        ));

        let after = std::fs::metadata(&config_abs).unwrap().modified().unwrap();
        assert_eq!(before, after, "ошибка add_item не должна трогать файлы");
    }

    #[test]
    fn legacy_monolith_migration_keeps_nodes() {
        let (root, store) = tmp_store();
        let quest_dir = root.join("quests/q4");
        std::fs::create_dir_all(&quest_dir).unwrap();

        let config = json!({
            "id": "q4",
            "title": "Легаси",
            "version": "1.0.0",
            "startNodeId": "n1",
            "tags": [{"id": "t1", "name": "Г"}],
            "variables": [],
            "tables": []
        });
        store.write_json("quests/q4/config.json", &config).unwrap();
        store
            .write_json(
                "quests/q4/nodes.json",
                &json!({"nodes": [
                    {"id":"n1","title":"Н1","chapterId":"t1","x":0,"y":0,"content":{"items":[]}},
                    {"id":"n2","title":"Н2","chapterId":"t1","x":10,"y":10,"content":{"items":[]}}
                ]}),
            )
            .unwrap();

        let qb = QuestBuilder::open(&root, "q4").unwrap();
        let info = qb.info();
        assert_eq!(info["nodes"].as_array().unwrap().len(), 2);

        assert!(store.exists("quests/q4/nodes/index.json"));
        assert!(store.exists("quests/q4/nodes/migration-backup.json"));

        let report = crate::validation::analyze_quest("q4", &root);
        assert!(!report.has_errors(), "{:?}", report.diagnostics);
    }
}
