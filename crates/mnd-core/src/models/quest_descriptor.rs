//! Модель дескриптора квеста (`Quest`).

use serde_json::{Map, Value, json};

/// Всегда нормализуем в новый движок: легаси-режим удалён.
pub const SCRIPT_ENGINE_MODE_NEW: &str = "new";

pub fn normalize_script_engine_mode(_raw: Option<&str>) -> String {
    SCRIPT_ENGINE_MODE_NEW.to_string()
}

fn string_or_null(v: Option<&Value>) -> Option<String> {
    let s = v?.as_str()?.trim();
    if s.is_empty() {
        None
    } else {
        Some(s.to_string())
    }
}

fn string_or_fallback(v: Option<&Value>, fallback: &str) -> String {
    string_or_null(v).unwrap_or_else(|| fallback.to_string())
}

/// Парсинг даты по аналогии с `DateTime.tryParse` (ISO 8601).
fn parse_date(v: Option<&Value>) -> Option<String> {
    let s = v?.as_str()?;
    // Dart DateTime.tryParse принимает ISO 8601; храним оригинальную строку
    // (сериализация сохраняет формат). Валидируем минимально.
    if s.trim().is_empty() {
        return None;
    }
    // Простейшая валидация: должен содержать '-' или быть RFC3339-подобным.
    if s.contains('-')
        || s.chars()
            .all(|c| c.is_ascii_digit() || c == ':' || c == 'T' || c == 'Z' || c == '.')
    {
        Some(s.to_string())
    } else {
        None
    }
}

/// Тег/глава квеста (для фоновых ассетов ноды).
///
/// Паритет: `packages/mnd_player/lib/providers/tag_provider.dart` (Tag).
#[derive(Debug, Clone, PartialEq)]
pub struct QuestTag {
    pub id: String,
    pub name: String,
    pub background_asset_id: Option<String>,
    pub background_audio_id: Option<String>,
}

impl QuestTag {
    pub fn from_json(json: &Value) -> Self {
        let obj = json.as_object().cloned().unwrap_or_default();
        QuestTag {
            id: obj
                .get("id")
                .and_then(Value::as_str)
                .map(str::to_string)
                .unwrap_or_default(),
            name: obj
                .get("name")
                .and_then(Value::as_str)
                .map(str::to_string)
                .unwrap_or_default(),
            background_asset_id: obj
                .get("backgroundAssetId")
                .and_then(Value::as_str)
                .map(str::to_string),
            background_audio_id: obj
                .get("backgroundAudioId")
                .and_then(Value::as_str)
                .map(str::to_string),
        }
    }
}

/// Дефолтная переменная квеста из `config.json` → `variables`.
#[derive(Debug, Clone, PartialEq)]
pub struct QuestVariable {
    pub name: String,
    pub default_value: Option<Value>,
}

impl QuestVariable {
    pub fn from_json(json: &Value) -> Self {
        let obj = json.as_object().cloned().unwrap_or_default();
        QuestVariable {
            name: obj
                .get("name")
                .and_then(Value::as_str)
                .map(str::to_string)
                .unwrap_or_default(),
            default_value: obj.get("defaultValue").cloned(),
        }
    }
}

/// Дескриптор квеста.
///
/// Паритет: `packages/mnd_core/lib/models/quest_descriptor.dart`.
#[derive(Debug, Clone, PartialEq)]
pub struct Quest {
    pub id: String,
    pub title: String,
    pub image_url: Option<String>,
    pub author: Option<String>,
    pub description: Option<String>,
    pub start_node_id: Option<String>,
    pub password: Option<String>,
    pub created: Option<String>,
    pub last_opened: Option<String>,
    pub version: Option<String>,
    pub background_asset_id: Option<String>,
    pub local_preview_path: Option<String>,
    pub screenshot_files: Option<Vec<String>>,
    pub dim_background: bool,
    pub hide_node_titles: bool,
    /// Не показывать верхнюю панель игры (назад/сохранить/загрузить/громкость).
    /// Скрипты могут вернуть её блоком `set_top_panel`.
    pub hide_top_panel: bool,
    pub genres: Vec<String>,
    pub default_text_fit: String,
    pub is_read_only: bool,
    pub is_market_downloaded: bool,
    pub market_quest_id: Option<String>,
    pub custom_font_file_name: Option<String>,
    pub wrap_button_text: bool,
    /// Паритет: `musicInBackground` в `quest_descriptor.dart`.
    /// Продолжать ли аудио при сворачивании приложения (по умолчанию — нет).
    pub music_in_background: bool,
    pub node_transition_mode: String,
    pub script_engine_mode: String,
    pub is_corrupted: bool,
    pub load_error: Option<String>,
    pub plugin_dependencies: Vec<String>,
    pub allow_open_content: bool,
    /// Язык, на котором написан квест (`config.language`). `None` — автор не
    /// указал. Паритет: `language` в `quest_descriptor.dart`.
    pub language: Option<String>,
    pub tags: Vec<QuestTag>,
    /// Дефолтные переменные (`config.variables` → `[{name, defaultValue}]`).
    pub variables: Vec<QuestVariable>,
    /// Дефолтные таблицы (`config.tables` → `[{name, ...}]`).
    pub tables: Map<String, Value>,
}

impl Quest {
    pub fn from_json(json: &Value) -> Self {
        let obj = json.as_object().cloned().unwrap_or_default();

        let is_dimmed = obj
            .get("dimBackground")
            .and_then(Value::as_bool)
            .unwrap_or(true);
        let is_titles_hidden = obj
            .get("hideNodeTitles")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let is_top_panel_hidden = obj
            .get("hideTopPanel")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let text_fit = obj
            .get("defaultTextFit")
            .and_then(Value::as_str)
            .unwrap_or("scale")
            .to_string();
        let read_only = obj
            .get("isReadOnly")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let is_market_downloaded = obj
            .get("isMarketDownloaded")
            .and_then(Value::as_bool)
            .or_else(|| obj.get("isFromMarket").and_then(Value::as_bool))
            .unwrap_or(false);
        let market_quest_id = obj
            .get("marketQuestId")
            .and_then(Value::as_str)
            .map(str::to_string);
        let button_wrap_text = obj
            .get("wrapButtonText")
            .and_then(Value::as_bool)
            .unwrap_or(true);
        let music_in_background = obj
            .get("musicInBackground")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let transition_mode = obj
            .get("nodeTransitionMode")
            .and_then(Value::as_str)
            .unwrap_or("none")
            .to_string();
        let script_engine_mode = normalize_script_engine_mode(
            obj.get("scriptEngineMode")
                .and_then(Value::as_str)
                .or_else(|| obj.get("scriptEngine").and_then(Value::as_str)),
        );
        let plugin_deps = obj
            .get("pluginDependencies")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter_map(Value::as_str)
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default();
        let allow_open_content = obj
            .get("allowOpenContent")
            .and_then(Value::as_bool)
            .unwrap_or(false);

        let tags = obj
            .get("tags")
            .and_then(Value::as_array)
            .map(|a| a.iter().map(QuestTag::from_json).collect())
            .unwrap_or_default();

        let variables = obj
            .get("variables")
            .and_then(Value::as_array)
            .map(|a| a.iter().map(QuestVariable::from_json).collect())
            .unwrap_or_default();

        let tables = obj
            .get("tables")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter_map(|t| {
                        t.as_object()
                            .and_then(|o| o.get("name"))
                            .and_then(Value::as_str)
                            .map(|name| (name.to_string(), t.clone()))
                    })
                    .collect::<Map<_, _>>()
            })
            .unwrap_or_default();

        let mut loaded_genres: Vec<String> = Vec::new();
        if let Some(Value::Array(list)) = obj.get("genres") {
            loaded_genres = list
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect();
        } else if let Some(cat) = obj.get("category").and_then(Value::as_str) {
            loaded_genres.push(cat.to_string());
        }

        let screenshot_files = obj
            .get("screenshot_files")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter_map(Value::as_str)
                    .map(str::to_string)
                    .collect()
            });

        Quest {
            id: string_or_fallback(obj.get("id"), ""),
            title: string_or_fallback(obj.get("title"), "Без названия"),
            image_url: string_or_null(obj.get("imageUrl")),
            author: string_or_null(obj.get("author")),
            description: string_or_null(obj.get("description")),
            start_node_id: string_or_null(obj.get("startNodeId")),
            password: string_or_null(obj.get("password")),
            created: parse_date(obj.get("created")),
            last_opened: parse_date(obj.get("lastOpened")),
            version: string_or_null(obj.get("version")),
            background_asset_id: string_or_null(obj.get("backgroundAssetId")),
            local_preview_path: string_or_null(obj.get("localPreviewPath")),
            screenshot_files,
            dim_background: is_dimmed,
            hide_node_titles: is_titles_hidden,
            hide_top_panel: is_top_panel_hidden,
            genres: loaded_genres,
            default_text_fit: text_fit,
            is_read_only: read_only,
            is_market_downloaded,
            market_quest_id,
            custom_font_file_name: string_or_null(obj.get("customFontFileName")),
            wrap_button_text: button_wrap_text,
            music_in_background,
            node_transition_mode: transition_mode,
            script_engine_mode,
            is_corrupted: obj
                .get("isCorrupted")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            load_error: string_or_null(obj.get("loadError")),
            plugin_dependencies: plugin_deps,
            allow_open_content,
            language: string_or_null(obj.get("language")),
            tags,
            variables,
            tables,
        }
    }

    pub fn to_json(&self) -> Value {
        let mut map = Map::new();
        map.insert("id".into(), json!(self.id));
        map.insert("title".into(), json!(self.title));
        map.insert("imageUrl".into(), json!(self.image_url));
        map.insert("author".into(), json!(self.author));
        map.insert("description".into(), json!(self.description));
        map.insert("startNodeId".into(), json!(self.start_node_id));
        map.insert("password".into(), json!(self.password));
        map.insert("created".into(), json!(self.created));
        map.insert("lastOpened".into(), json!(self.last_opened));
        map.insert("version".into(), json!(self.version));
        map.insert("dimBackground".into(), json!(self.dim_background));
        map.insert("hideNodeTitles".into(), json!(self.hide_node_titles));
        map.insert("hideTopPanel".into(), json!(self.hide_top_panel));
        map.insert("genres".into(), json!(self.genres));
        map.insert("defaultTextFit".into(), json!(self.default_text_fit));
        map.insert("isReadOnly".into(), json!(self.is_read_only));
        map.insert(
            "isMarketDownloaded".into(),
            json!(self.is_market_downloaded),
        );
        map.insert("allowOpenContent".into(), json!(self.allow_open_content));
        if self.market_quest_id.is_some() {
            map.insert("marketQuestId".into(), json!(self.market_quest_id));
        }
        if self.language.is_some() {
            map.insert("language".into(), json!(self.language));
        }
        map.insert("wrapButtonText".into(), json!(self.wrap_button_text));
        map.insert("musicInBackground".into(), json!(self.music_in_background));
        map.insert(
            "nodeTransitionMode".into(),
            json!(self.node_transition_mode),
        );
        map.insert("scriptEngineMode".into(), json!(self.script_engine_mode));
        map.insert("pluginDependencies".into(), json!(self.plugin_dependencies));
        map.insert(
            "category".into(),
            json!(self.genres.first().cloned().unwrap_or_default()),
        );
        if self.background_asset_id.is_some() {
            map.insert("backgroundAssetId".into(), json!(self.background_asset_id));
        }
        if self.screenshot_files.is_some() {
            map.insert("screenshot_files".into(), json!(self.screenshot_files));
        }
        if self.custom_font_file_name.is_some() {
            map.insert(
                "customFontFileName".into(),
                json!(self.custom_font_file_name),
            );
        }
        if !self.tags.is_empty() {
            map.insert(
                "tags".into(),
                json!(
                    self.tags
                        .iter()
                        .map(|t| {
                            json!({
                                "id": t.id,
                                "name": t.name,
                                "backgroundAssetId": t.background_asset_id,
                                "backgroundAudioId": t.background_audio_id,
                            })
                        })
                        .collect::<Vec<_>>()
                ),
            );
        }
        // Дефолты автора: без этих ключей round-trip (`from_json` → `to_json`)
        // молча лишал квест переменных и таблиц — тот же класс бага, что и
        // стирание ключей ноды при сохранении.
        if !self.variables.is_empty() {
            map.insert(
                "variables".into(),
                json!(
                    self.variables
                        .iter()
                        .map(|v| json!({ "name": v.name, "defaultValue": v.default_value }))
                        .collect::<Vec<_>>()
                ),
            );
        }
        if !self.tables.is_empty() {
            map.insert(
                "tables".into(),
                Value::Array(self.tables.values().cloned().collect()),
            );
        }
        Value::Object(map)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn language_round_trip() {
        let q = Quest::from_json(&json!({
            "id": "q1",
            "title": "Квест",
            "language": " ja ",
        }));
        assert_eq!(q.language.as_deref(), Some("ja"));
        assert_eq!(q.to_json()["language"], "ja");
        assert_eq!(
            Quest::from_json(&q.to_json()).language.as_deref(),
            Some("ja")
        );
    }

    #[test]
    fn language_absent_stays_absent() {
        let q = Quest::from_json(&json!({ "id": "q1", "title": "Квест" }));
        assert!(q.language.is_none());
        assert!(q.to_json().get("language").is_none());

        let blank = Quest::from_json(&json!({ "id": "q1", "language": "   " }));
        assert!(blank.language.is_none());
        assert!(blank.to_json().get("language").is_none());
    }
}
