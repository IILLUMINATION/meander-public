//! Игровой движок верхнего уровня: геймлуп квеста.
//!
//! [`GameEngine`] инкапсулирует всю оркестрацию, ранее жившую в клиенте
//! (`game_screen_provider.dart` / `game_screen.dart`): запуск сессии,
//! загрузку ноды, поштучное раскрытие контента, обработку нажатий,
//! системные переменные и резолюцию шаблонных инстансов.
//!
//! I/O вынесен за пределы движка: клиент загружает сырые JSON
//! (config/nodes/templates) и передаёт в [`GameEngine::new`]; вложенные
//! скрипты резолвятся по встроенному map (`embedded_scripts`).

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use serde_json::{Map, Value, json};

use crate::contracts::{DynSaveStore, FsScriptAssetStore, ScriptAssetStore};
use crate::executor::{DynAssetStore, EventType, ScriptExecutor};
use crate::lua::LuaSession;
use crate::models::{
    ContentItem, ContentTrigger, Quest, QuestTable, SaveSlot, SavedNode, TemplateItem,
};

/// Принудительно выставить LC_NUMERIC=C для mpv/libmpv (требует C-локаль, иначе
/// `Non-C locale detected` → abort). Безопасно звать многократно, процесс-глобально.
fn ensure_c_numeric_locale() {
    // В веб-сборке mpv нет, как нет и libc: функция выродилась в no-op, чтобы
    // вызов в движке оставался на одном месте для всех платформ.
    #[cfg(feature = "posix-locale")]
    // SAFETY: setlocale с константной строкой "C" — thread-safe на старте, до
    // конкурентного создания mpv-плееров. Нулевой возврат игнорируем.
    unsafe {
        // `c"C"` → *const c_char, LC_NUMERIC = 1 (POSIX)
        libc::setlocale(libc::LC_NUMERIC, c"C".as_ptr());
    }
}
use crate::runtime::{InMemoryScriptRuntimeState, ScriptRuntime};
use crate::script_format;

/// Информация о платформе для системной переменной `_SYS_PLATFORM`.
#[derive(Debug, Clone, Default)]
pub struct PlatformInfo {
    pub os: String,
    pub is_web: bool,
}

/// Конфигурация сессии движка.
#[derive(Clone, Default)]
pub struct GameEngineConfig {
    pub platform: PlatformInfo,
    /// Вложенные скрипты: путь (`scripts/<id>.json` или `_internal_scripts/<id>.json`)
    /// → распарсенный JSON. Используются блоками `call_script`/`call_function`.
    pub embedded_scripts: HashMap<String, Value>,
    /// Хранилище ассетов квеста. Когда задано, движок читает скрипты
    /// (и, при создании из `quest_root`, весь квест) напрямую
    /// по требованию — без предварительного бандлинга в клиенте.
    pub asset_store: Option<DynAssetStore>,
    /// Хранилище сейвов квеста. Когда задано, движок сам пишет/читает
    /// слоты (`save_slot`/`perform_autosave`/…), а клиент ничего не знает
    /// о том, где и как хранятся сейвы.
    pub save_store: Option<DynSaveStore>,
}

/// Разрешённое фоновое аудио ноды.
#[derive(Debug, Clone)]
pub struct ResolvedAudio {
    pub audio_id: String,
    pub volume: f64,
}

/// Разрешённый таймер ноды.
#[derive(Debug, Clone)]
pub struct ResolvedTimer {
    pub duration: f64,
    pub default_action_node_id: String,
}

/// Представление раскрытой ноды, возвращаемое клиенту для рендера.
#[derive(Debug, Clone)]
pub struct NodeView {
    pub node_id: String,
    pub title: String,
    pub presentation_id: String,
    /// Полный JSON ноды (после резолюции шаблонов) — для UI-полей
    /// (toolbar, itemSpacing, таймер и т.д.).
    pub node_json: String,
    pub revealed_items: Vec<ContentItem>,
    pub hud_panels: Vec<ContentItem>,
    pub background_image_id: Option<String>,
    pub background_video_id: Option<String>,
    pub background_audio: Option<ResolvedAudio>,
    pub timer: Option<ResolvedTimer>,
    /// Переход, если скрипты ноды сразу ведут на другую ноду.
    pub transition: Option<String>,
}

/// Результат шага раскрытия (`next_item`).
#[derive(Debug, Clone)]
pub enum NextStep {
    /// Очередной контент-айтем для отображения.
    Item(Box<ContentItem>),
    /// Переход на другую ноду.
    Transition(String),
    /// Все айтемы раскрыты.
    Done,
}

/// Команда проигрывания звукового эффекта.
#[derive(Debug, Clone)]
pub struct PlaySoundCmd {
    pub id: String,
    pub volume: f64,
}

/// Команда проигрывания фоновой музыки.
#[derive(Debug, Clone)]
pub struct PlayMusicCmd {
    pub id: String,
    pub loop_: bool,
    pub volume: f64,
    pub global: bool,
}

/// Команда паузы/возобновления.
#[derive(Debug, Clone)]
pub struct PauseResumeCmd {
    pub target: String,
    pub action: String,
}

/// Дельта аудио-команд, накопленных скриптами.
///
/// Очередь (`commands`) — сырые JSON-объекты канонического формата:
/// `{"type": "play_sound", "audioId": …, "volume": …}`,
/// `{"type": "stop_sound", "target": …}`,
/// `{"type": "play_music", "audioId": …, "loop": …, "volume": …, "global": …}`,
/// `{"type": "stop_music"}`,
/// `{"type": "pause_resume", "target": …, "action": …}`,
/// `{"type": "fade_out", "ms": …}`, `{"type": "fade_in", "ms": …}`.
/// Клиент применяет команды ПО ПОРЯДКУ: синхронное исполнение нескольких
/// `play_sound` подряд не должно терять звуки (паритет: Dart-эталон
/// доставлял каждый звук в своей точке `await`).
#[derive(Debug, Clone, Default)]
pub struct AudioCommandDelta {
    pub commands: Vec<Value>,
}

/// Игровой движок одной активной сессии квеста.
#[derive(Clone)]
pub struct GameEngine {
    quest_id: String,
    quest_version: String,
    config: Quest,
    nodes: HashMap<String, SavedNode>,
    templates: HashMap<String, TemplateItem>,
    embedded_scripts: HashMap<String, Value>,
    asset_store: Option<DynAssetStore>,
    save_store: Option<DynSaveStore>,
    platform: PlatformInfo,

    state: InMemoryScriptRuntimeState,
    current_node_id: Option<String>,
    revealed_count: usize,
    revealed_items: Vec<ContentItem>,
    hud_panels: Vec<ContentItem>,
    /// Lua-сессия квеста (L3A, блок `call_lua`): лениво создаётся при первом
    /// использовании, живёт всю сессию (сохраняет inline-функции автора).
    lua: Option<Arc<Mutex<LuaSession>>>,
    /// Подписки `onDataChange`, собранные из скриптов текущей ноды и квеста.
    /// Перестраиваются на каждом входе в ноду — автору не нужно нигде
    /// регистрировать скрипт-«диспетчер».
    data_watches: Vec<DataWatch>,
    /// Переход, который подписка выдала там, где движок не умеет его вернуть
    /// (прямая мутация переменной из клиента). Дожидается ближайшей границы
    /// шага, а не теряется молча.
    pending_transition: Option<String>,
}

/// Спецификация запланированного тика таймера (цикл-функция со `wait`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TimerSpec {
    pub script_path: String,
    pub entry: String,
    pub ms: i64,
}

/// Подписка на изменение данных — один блок события «при изменении данных».
#[derive(Debug, Clone)]
struct DataWatch {
    script_path: String,
    is_lua: bool,
    /// event-блок JSON-скрипта; у `.lua` фильтра не разобрать по тексту.
    block: Option<Map<String, Value>>,
    /// Нормализованные пути подписки. Пусто = любое изменение данных.
    paths: Vec<Vec<String>>,
}

/// Потолок каскада `onDataChange`: подписка, которая сама пишет в подписанную
/// переменную, иначе крутится до конца игры. Четыре волны хватает цепочке
/// «проверка → начисление → флаг» и не даёт зависнуть на самоповторе.
const MAX_DATA_WATCH_ROUNDS: usize = 4;

/// Токен изменения в человекочитаемом виде (`table.лавка.цена.3`).
fn render_change_path(path: &[String]) -> String {
    path.join(".")
}

/// Затронута ли подписка пачкой изменений.
fn data_watch_fires(watch: &DataWatch, changed: &[Vec<String>]) -> bool {
    if watch.paths.is_empty() {
        return true;
    }
    changed.iter().any(|token| {
        watch
            .paths
            .iter()
            .any(|form| crate::runtime::watch_path_matches(form, token))
    })
}

impl GameEngine {
    pub fn new(
        quest_id: String,
        config: Quest,
        nodes: Vec<SavedNode>,
        templates: Vec<TemplateItem>,
        extra: GameEngineConfig,
    ) -> Self {
        ensure_c_numeric_locale();
        let nodes_map = nodes.into_iter().map(|n| (n.id.clone(), n)).collect();
        let templates_map = templates.into_iter().map(|t| (t.id.clone(), t)).collect();
        let quest_version = config
            .version
            .clone()
            .unwrap_or_else(|| "1.0.0".to_string());
        GameEngine {
            quest_id,
            quest_version,
            config,
            nodes: nodes_map,
            templates: templates_map,
            embedded_scripts: extra.embedded_scripts,
            asset_store: extra.asset_store,
            save_store: extra.save_store,
            platform: extra.platform,
            state: InMemoryScriptRuntimeState::default(),
            current_node_id: None,
            revealed_count: 0,
            revealed_items: Vec::new(),
            hud_panels: Vec::new(),
            lua: None,
            data_watches: Vec::new(),
            pending_transition: None,
        }
    }

    /// Создать движок из каталога квеста на диске.
    ///
    /// Читает `config.json`, `nodes.json` и `res/templates.json` через
    /// `ScriptAssetStore` (root = каталог документов приложения, пути
    /// `quests/<quest_id>/...`). Скрипты движок дочитывает по требованию.
    /// Возвращает `None`, если `config.json` не найден.
    pub fn from_disk(quest_id: &str, root: impl AsRef<std::path::Path>) -> Option<Self> {
        let root = root.as_ref().to_path_buf();
        let store: DynAssetStore = std::sync::Arc::new(FsScriptAssetStore::new(root.clone()));
        let save_store: DynSaveStore =
            std::sync::Arc::new(crate::contracts::FsSaveStore::new(root));
        let prefix = format!("quests/{quest_id}/");

        let config = Quest::from_json(&store.read_json(&format!("{prefix}config.json"))?);
        // Два исторических места: канонический nodes/nodes.json (импорт) и
        // legacy nodes.json (редактор). Читаем канонический первым; если он
        // пуст/отсутствует — legacy. Это не даёт «пустому» файлу одной из
        // копий спрятать стартовую ноду.
        let mut nodes = load_json_array(
            store.as_ref(),
            &format!("{prefix}nodes/nodes.json"),
            "nodes",
            SavedNode::from_json,
        );
        if nodes.is_empty() {
            nodes = load_json_array(
                store.as_ref(),
                &format!("{prefix}nodes.json"),
                "nodes",
                SavedNode::from_json,
            );
        }
        let templates = load_json_array(
            store.as_ref(),
            &format!("{prefix}res/templates.json"),
            "templates",
            TemplateItem::from_json,
        );

        Some(Self::new(
            quest_id.to_string(),
            config,
            nodes,
            templates,
            GameEngineConfig {
                platform: PlatformInfo::default(),
                asset_store: Some(store.clone()),
                save_store: Some(save_store),
                ..Default::default()
            },
        ))
    }

    /// Версия квеста (для `_SYS_QUEST_VERSION`).
    pub fn quest_version(&self) -> &str {
        &self.quest_version
    }

    fn script_asset_path(&self, raw: &str) -> String {
        let trimmed = raw.trim_start_matches(&format!("quests/{}/", self.quest_id));
        let trimmed = trimmed.trim_start_matches('/');
        trimmed.to_string()
    }

    fn load_script(&self, raw_path: &str) -> Option<Map<String, Value>> {
        let normalized = self.script_asset_path(raw_path);
        if let Some(script) = self
            .embedded_scripts
            .get(&normalized)
            .or_else(|| self.embedded_scripts.get(raw_path))
            .and_then(|v| v.as_object().cloned())
        {
            return Some(script_format::normalized_clone(&script));
        }
        // Ленивое чтение через asset store (полный путь quests/<id>/...).
        let full_path = format!("quests/{}/{}", self.quest_id, normalized);
        self.asset_store
            .as_ref()
            .and_then(|s| s.read_json(&full_path))
            .or_else(|| {
                self.asset_store
                    .as_ref()
                    .and_then(|s| s.read_json(raw_path))
            })
            .and_then(|v| v.as_object().cloned())
            .map(|script| script_format::normalized_clone(&script))
    }

    /// Создать исполнитель с зависимостями движка (вложенные скрипты +
    /// ленивый asset store).
    fn new_executor(&self) -> ScriptExecutor {
        let mut exec = ScriptExecutor::new().with_embedded_scripts(self.embedded_scripts.clone());
        if let Some(store) = &self.asset_store {
            exec = exec.with_asset_store(store.clone());
        }
        exec
    }

    /// Выполнить скрипт по пути, применяя мутации к внутреннему состоянию.
    /// Возвращает переход (`go_to_node`), если есть.
    fn execute_script_file(
        &mut self,
        raw_path: &str,
        event_type: EventType,
        function_name: Option<&str>,
        content_item_id: Option<&str>,
    ) -> Option<String> {
        // Снапшоты pacing'а покрывают только мутации ВНУТРИ этого скрипта:
        // накопленное до входа (defaults, ID/LastID, _internal_*) уходит
        // в финальную дельту и не должно дублироваться в wait-шагах.
        let _ = self.state.take_pacing_snapshot_variables();
        let _ = self.state.take_pacing_snapshot_tables();
        let script = self.load_script(raw_path)?;
        let exec = self.new_executor();
        exec.execute(
            &script,
            &mut self.state,
            &self.quest_id,
            event_type,
            &function_name.map(str::to_string),
            &content_item_id.map(str::to_string),
            false,
            &mut self.lua,
        )
        .ok()
        .flatten()
    }

    /// Lua-триггер по пути к `.lua`-файлу.
    ///
    /// `scriptAssetId`/`scriptTriggers`/`resourcePath` могут указывать на
    /// `.lua` вместо JSON-скрипта. Тогда читаем исходник и вызываем функцию
    /// по соглашению: имя = тип события (`onNodeEnter`/`onPress`/
    /// `onContentAppear`), фолбэк на `start`. Возвращает переход, если
    /// функция вернула `{ node = … }` / `{ go_to_node = … }`.
    fn execute_lua_file(
        &mut self,
        raw_path: &str,
        event: EventType,
        content_item_id: Option<&str>,
    ) -> Option<String> {
        self.call_lua_entry(raw_path, lua_fn_name(event), content_item_id, true)
    }

    /// Вызвать функцию `.lua` по имени, передав ей готовый аргумент.
    fn call_lua_fn(
        &mut self,
        raw_path: &str,
        fn_name: &str,
        arg: Value,
        allow_start_fallback: bool,
    ) -> Option<String> {
        let script = self.read_lua_text(raw_path)?;
        // Инициализация (при необходимости) и вызов функции события.
        if self.lua.is_none() {
            self.lua = Some(Arc::new(Mutex::new(LuaSession::new())));
        }
        let fn_name = fn_name.to_string();
        let mut session = self.lua.as_ref().expect("lua").lock().expect("lua lock");
        let result = session.call_function(
            &mut self.state,
            Some(script.as_str()),
            &fn_name,
            arg.clone(),
        );
        match result {
            Ok(Some(t)) => Some(t),
            Ok(None) => None,
            Err(_) if allow_start_fallback && fn_name != "start" => session
                .call_function(&mut self.state, Some(script.as_str()), "start", arg)
                .ok()
                .flatten(),
            Err(_) => None,
        }
    }

    /// Вызвать точку входа `.lua` по имени функции.
    ///
    /// `allow_start_fallback` — legacy-соглашение для ссылок из ноды: функция
    /// события не найдена → зовём `start`. При автораскопке квестовых
    /// скриптов фолбэк выключен, иначе `start` любого файла считался бы
    /// стартом квеста.
    fn call_lua_entry(
        &mut self,
        raw_path: &str,
        fn_name: &str,
        content_item_id: Option<&str>,
        allow_start_fallback: bool,
    ) -> Option<String> {
        let arg = content_item_id
            .map(|id| Value::String(id.to_string()))
            .unwrap_or(Value::Null);
        self.call_lua_fn(raw_path, fn_name, arg, allow_start_fallback)
    }

    fn is_lua_path(&self, raw_path: &str) -> bool {
        let trimmed = raw_path.trim();
        trimmed.ends_with(".lua")
            || trimmed
                .rsplit('/')
                .next()
                .is_some_and(|f| f.ends_with(".lua"))
    }

    /// Прочитать `.lua`-исходник кандидатными путями (как executor::load_lua_text).
    fn read_lua_text(&self, raw_path: &str) -> Option<String> {
        let raw = raw_path.trim();
        if raw.is_empty() {
            return None;
        }
        let mut candidates = vec![raw.to_string()];
        for p in &[
            format!("quests/{}/scripts/{}.lua", self.quest_id, raw),
            format!("quests/{}/scripts/{}", self.quest_id, raw),
            format!("quests/{}/{}.lua", self.quest_id, raw),
            format!("quests/{}/{}", self.quest_id, raw),
        ] {
            if !candidates.contains(p) {
                candidates.push(p.clone());
            }
        }
        let store = self.asset_store.as_ref()?;
        for candidate in candidates {
            if let Some(text) = store.read_text(&candidate) {
                return Some(text);
            }
        }
        None
    }

    /// Установить дефолтные переменные для новой игры.
    fn apply_defaults(&mut self) {
        // _internal_* переменные аудио и эффектов.
        //
        // Размытие фона сюда НЕ вписываем: отсутствие переменной означает
        // «скрипт размытие не трогал», и тогда плеер берёт значение с самой
        // ноды. Дефолт 10.0 живёт на стороне плеера; если сеять его здесь,
        // канал эффектов всегда «активен» и перебивает настройку ноды.
        let defaults: Vec<(&str, Value)> = vec![
            ("_internal_node_content_volume", Value::from(1.0)),
            ("_internal_tag_volume", Value::from(1.0)),
            ("_internal_play_sound_id", Value::Null),
            ("_internal_play_sound_volume", Value::from(1.0)),
            ("_internal_stop_sound_target", Value::Null),
            ("_internal_play_music_id", Value::Null),
            ("_internal_play_music_volume", Value::from(1.0)),
            ("_internal_play_music_loop", Value::from(true)),
            ("_internal_play_music_global", Value::from(false)),
            ("_internal_stop_music", Value::from(false)),
            ("_internal_pause_resume_target", Value::Null),
            ("_internal_pause_resume_action", Value::Null),
            ("_internal_crossfade_fade_out", Value::Null),
            ("_internal_crossfade_fade_in", Value::Null),
            ("_internal_delay_queue", Value::Array(vec![])),
            ("ID", Value::from("")),
            ("LastID", Value::from("")),
            (
                "_SYS_QUEST_VERSION",
                Value::from(self.quest_version.clone()),
            ),
        ];
        for (k, v) in defaults {
            self.state.set_variable(k, v);
        }

        // Дефолтные переменные автора из config.variables.
        for var in &self.config.variables {
            if var.name.is_empty() {
                continue;
            }
            self.state
                .set_variable(&var.name, var.default_value.clone().unwrap_or(Value::Null));
        }

        // Дефолтные таблицы из config.tables.
        for (name, table_json) in &self.config.tables {
            let table = QuestTable::from_json(table_json);
            self.state.set_table(name, table);
        }
    }

    /// Все скрипты квеста: файлы из `scripts/` на диске плюс ключи
    /// `embedded_scripts` (web/FFI-путь, где nothing лежит на ФС).
    ///
    /// Пути нормализованы к корню квеста и отсортированы по имени: порядка
    /// «как в реестре» больше нет, автор задаёт последовательность вызовами
    /// из стартовой ноды.
    fn quest_script_paths(&self) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        if let Some(store) = &self.asset_store {
            let dir = format!("quests/{}/scripts", self.quest_id);
            out.extend(
                store
                    .list_dir(&dir)
                    .into_iter()
                    .map(|p| self.script_asset_path(&p)),
            );
        }
        for key in self.embedded_scripts.keys() {
            let normalized = self.script_asset_path(key);
            if normalized.starts_with("scripts/") {
                out.push(normalized);
            }
        }
        out.sort();
        out.dedup();
        out
    }

    /// Квестовые скрипты (AutoLoad ищется по объявлению события).
    ///
    /// `run_start_blocks == true` (новая игра) исполняет те скрипты, что
    /// объявляют «при запуске квеста». Lua-исходники подключаются всегда —
    /// иначе ноды не увидят функции библиотеки автора; при загрузке сейва
    /// стартовые блоки НЕ запускаются, иначе присвоение в стартовом скрипте
    /// затёрло бы сохранённый прогресс.
    ///
    /// Возвращает переход, если скрипт попросил `core.go_to` (или вернул
    /// `{node=…}`): движок стартует с этой ноды.
    fn run_quest_scripts(&mut self, run_start_blocks: bool) -> Option<String> {
        let mut transition = None;
        for path in self.quest_script_paths() {
            if path.trim().is_empty() {
                continue;
            }
            if self.is_lua_path(&path) {
                let declares_start = self
                    .read_lua_text(&path)
                    .map(|text| crate::executor::lua_source_declares(&text, "onQuestStart"))
                    .unwrap_or(false);
                if run_start_blocks && declares_start {
                    if let Some(next) = self.call_lua_entry(&path, "onQuestStart", None, false) {
                        transition = Some(next);
                    }
                } else {
                    self.load_lua_source(&path);
                }
                continue;
            }
            if !run_start_blocks {
                continue;
            }
            let Some(script) = self.load_script(&path) else {
                continue;
            };
            if !declares_event(&script, EventType::OnQuestStart) {
                continue;
            }
            if let Some(next) = self.execute_script_file(&path, EventType::OnQuestStart, None, None)
            {
                transition = Some(next);
            }
        }
        transition
    }

    /// Скрипты, которые движок может исполнить в этой ноде: её ассет и
    /// inline script-айтемы. Их подписки `onDataChange` видны только пока
    /// нода активна — ноде не нужно регистрироваться где-то вне себя.
    fn node_script_paths(node: &SavedNode) -> Vec<String> {
        let mut out = Vec::new();
        if let Some(id) = node.script_asset_id.as_deref() {
            let id = id.trim();
            if !id.is_empty() {
                out.push(id.to_string());
            }
        }
        let items = node
            .content
            .get("items")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        for item in items.iter().filter_map(Value::as_object) {
            if item.get("type").and_then(Value::as_str) != Some("script") {
                continue;
            }
            let raw = item
                .get("resourcePath")
                .and_then(Value::as_str)
                .unwrap_or("")
                .trim();
            if !raw.is_empty() {
                out.push(raw.to_string());
            }
        }
        out
    }

    /// Собрать подписки `onDataChange`: скрипты квеста из `scripts/` плюс
    /// скрипты текущей ноды.
    ///
    /// Реестра автор не ведёт — движок сам читает объявление события в файле
    /// (как с `onQuestStart`). Поэтому «диспетчер» — обычный скрипт в
    /// `scripts/`, и подключать его в настройках квеста не нужно.
    fn rebuild_data_watches(&mut self, node: Option<&SavedNode>) {
        let mut paths = self.quest_script_paths();
        if let Some(node) = node {
            for raw in Self::node_script_paths(node) {
                let normalized = self.script_asset_path(&raw);
                if !normalized.is_empty() && !paths.contains(&normalized) {
                    paths.push(normalized);
                }
            }
        }

        let mut watches = Vec::new();
        for path in paths {
            if self.is_lua_path(&path) {
                let declares = self
                    .read_lua_text(&path)
                    .map(|text| crate::executor::lua_source_declares(&text, "onDataChange"))
                    .unwrap_or(false);
                if declares {
                    // Lua-фильтр по путям из текста ненадёжен: функция получает
                    // всю пачку изменений и разбирается сама.
                    watches.push(DataWatch {
                        script_path: path,
                        is_lua: true,
                        block: None,
                        paths: Vec::new(),
                    });
                }
                continue;
            }
            let Some(script) = self.load_script(&path) else {
                continue;
            };
            for block in crate::executor::event_blocks_for(&script, EventType::OnDataChange) {
                let mut forms: Vec<Vec<String>> = Vec::new();
                for raw in crate::executor::watch_paths_of(&block) {
                    for form in crate::runtime::watch_path_forms(&raw) {
                        if !forms.contains(&form) {
                            forms.push(form);
                        }
                    }
                }
                watches.push(DataWatch {
                    script_path: path.clone(),
                    is_lua: false,
                    block: Some(block),
                    paths: forms,
                });
            }
        }
        self.data_watches = watches;
    }

    /// Граница игрового шага: прогнать подписки, затронутые накопленными
    /// изменениями, и собрать их каскад.
    ///
    /// Вызывается из точек, где клиент что-то сделал (вошёл в ноду, раскрыл
    /// айтем, нажал, тик таймера, прямая мутация), — а не из середины скрипта:
    /// иначе одна подписанная переменная запускала бы обработчик на каждое
    /// присваивание. Возвращает переход, если скрипт подписки попросил уйти
    /// на другую ноду.
    fn flush_data_changes(&mut self) -> Option<String> {
        let mut transition = None;
        let mut round = 0usize;
        loop {
            let changed = self.state.drain_changed_paths();
            if changed.is_empty() {
                break;
            }
            if !self.data_watches.is_empty() {
                let matched: Vec<DataWatch> = self
                    .data_watches
                    .iter()
                    .filter(|watch| data_watch_fires(watch, &changed))
                    .cloned()
                    .collect();
                for watch in matched {
                    if let Some(next) = self.run_data_watch(&watch, &changed) {
                        transition = Some(next);
                    }
                }
            }
            round += 1;
            if round >= MAX_DATA_WATCH_ROUNDS {
                let pending = self.state.drain_changed_paths().len();
                if pending > 0 {
                    eprintln!(
                        "[Rust/mnd-core] onDataChange: каскад прерван на {MAX_DATA_WATCH_ROUNDS} волне ({pending} изменений не обработано) — скрипт подписки, вероятно, пишет в свою же переменную"
                    );
                }
                break;
            }
        }
        transition
    }

    /// Граница игрового шага для публичных точек движка.
    ///
    /// Переход от самого действия важнее диспетчера (нода всё равно уходит),
    /// а накопленные без него изменения прогоняются через подписки.
    fn after_step(&mut self, transition: Option<String>) -> Option<String> {
        if transition.is_some() {
            self.state.reset_changed_paths();
            return transition;
        }
        if let Some(pending) = self.pending_transition.take() {
            return Some(pending);
        }
        self.flush_data_changes()
    }

    /// Исполнить одну подписку: только её блоки, а не весь файл.
    ///
    /// Скрипт-обёртка из одного event-блока — тот же приём, что в
    /// `script_has_event`: исполнитель видит ровно одно событие и берёт его
    /// children. Автору видно, что именно изменилось, через `{_changed_path}`
    /// и `{_changed_paths}`.
    fn run_data_watch(&mut self, watch: &DataWatch, changed: &[Vec<String>]) -> Option<String> {
        let rendered: Vec<Value> = changed
            .iter()
            .map(|path| Value::String(render_change_path(path)))
            .collect();
        if watch.is_lua {
            return self.call_lua_fn(
                &watch.script_path,
                "onDataChange",
                Value::Array(rendered.clone()),
                false,
            );
        }
        let block = watch.block.clone()?;
        self.state.set_variable(
            "_changed_path",
            rendered.first().cloned().unwrap_or(Value::Null),
        );
        self.state
            .set_variable("_changed_paths", Value::Array(rendered));
        let script = json!({ "name": watch.script_path, "blocks": [block] });
        let script_map = script.as_object().cloned()?;
        let exec = self.new_executor();
        exec.execute(
            &script_map,
            &mut self.state,
            &self.quest_id,
            EventType::OnDataChange,
            &None,
            &None,
            false,
            &mut self.lua,
        )
        .ok()
        .flatten()
    }

    /// Исполнить `.lua` без вызова точки входа — только зарегистрировать
    /// функции автора в Lua-сессии квеста.
    fn load_lua_source(&mut self, raw_path: &str) {
        let Some(script) = self.read_lua_text(raw_path) else {
            return;
        };
        if self.lua.is_none() {
            self.lua = Some(Arc::new(Mutex::new(LuaSession::new())));
        }
        let Some(session) = self.lua.as_ref().map(Arc::clone) else {
            return;
        };
        if let Ok(mut guard) = session.lock() {
            let _ = guard.exec_source(&mut self.state, &script);
        }
    }

    /// Запустить новую игру: дефолтные переменные + стартовая нода.
    pub fn start_new(&mut self, start_node_id: Option<&str>) -> Option<NodeView> {
        ensure_c_numeric_locale();
        self.apply_defaults();
        // Сброс переменных сохранения (новая игра — не из слота)
        self.state
            .set_variable("SAVE_DATE", Value::String(String::new()));
        self.state
            .set_variable("SAVE_TIME", Value::String(String::new()));
        self.state
            .set_variable("SAVE_DATETIME", Value::String(String::new()));
        self.state
            .set_variable("_SAVE_DATE", Value::String(String::new()));
        self.state
            .set_variable("_SAVE_TIME", Value::String(String::new()));
        self.state
            .set_variable("_SAVE_DATETIME", Value::String(String::new()));
        // Квестовые скрипты — до первой ноды, чтобы их функции и переменные
        // были видны скриптам любой ноды.
        let script_target = self.run_quest_scripts(true);
        let caller = start_node_id.map(str::to_string).filter(|s| !s.is_empty());
        // Запуск конкретной ноды (редактор, «играть с этой») важнее, чем
        // переход из скрипта. Плеер же прокидывает `config.startNodeId` тем же
        // аргументом — это не явная просьба, а дефолт автора, и его скрипт
        // имеет право перебить.
        let explicit = caller
            .clone()
            .filter(|id| Some(id.clone()) != self.config.start_node_id);
        let target = explicit
            .or_else(|| script_target.filter(|t| !t.is_empty()))
            .or(caller)
            .or_else(|| self.config.start_node_id.clone())
            .unwrap_or_default();
        if target.is_empty() {
            return None;
        }
        self.load_node(&target)
    }

    /// Запустить из сейва.
    pub fn start_from_save(&mut self, save: &SaveSlot) -> Option<NodeView> {
        ensure_c_numeric_locale();
        self.apply_defaults();
        for (k, v) in &save.variables {
            self.state.set_variable(k, v.clone());
        }
        // Переменные даты/времени загруженного сейва (для использования в текстах/скриптах)
        // Формат save.saved_at: "2026-09-03T14:20:30.123" (ISO8601 Dart)
        let (save_date, save_time, save_datetime) = if save.saved_at.is_empty() {
            (String::new(), String::new(), String::new())
        } else if let Some(t_pos) = save.saved_at.find('T') {
            let date = save.saved_at[..t_pos].to_string();
            let time_raw = &save.saved_at[t_pos + 1..];
            let time_no_ms = time_raw.split('.').next().unwrap_or(time_raw);
            let time_no_z = time_no_ms.trim_end_matches('Z').to_string();
            (date.clone(), time_no_z.clone(), save.saved_at.clone())
        } else {
            // нет T — считаем всё датой
            (save.saved_at.clone(), String::new(), save.saved_at.clone())
        };
        for key in ["SAVE_DATE", "_SAVE_DATE"] {
            self.state
                .set_variable(key, Value::String(save_date.clone()));
        }
        for key in ["SAVE_TIME", "_SAVE_TIME"] {
            self.state
                .set_variable(key, Value::String(save_time.clone()));
        }
        for key in ["SAVE_DATETIME", "_SAVE_DATETIME"] {
            self.state
                .set_variable(key, Value::String(save_datetime.clone()));
        }
        // Сейв может содержать стейл-очередь задержек из прошлой сессии —
        // задержки одноразовые и покрыты моментом сохранения.
        self.state
            .set_variable("_internal_delay_queue", Value::Array(vec![]));
        // То же про канал размытия: сейвы старых сборок несут в себе 10.0,
        // который движок сеял сам. Без сброса он означал бы «скрипт задал
        // размытие» и вечно перебивал поле ноды. Это состояние рендера, а не
        // прогресс игрока: onNodeEnter загружаемой ноды выполнится сразу и
        // задаст канал заново, если он квесту нужен.
        self.state
            .set_variable("_internal_background_blur", Value::Null);
        for (name, table_json) in &save.tables {
            let table = QuestTable::from_json(table_json);
            self.state.set_table(name, table);
        }
        // Скрипты квеста при загрузке только подключаются: Lua-функции автора
        // должны быть видны нодам, а `onQuestStart` не запускается — иначе
        // присвоение в стартовом скрипте затёрло бы сохранённый прогресс.
        self.run_quest_scripts(false);
        let target = save.current_node_id.clone();
        if target.is_empty() {
            return None;
        }
        self.load_node(&target)
    }

    /// Обновить системные переменные при входе на ноду.
    fn update_system_variables(&mut self, node_id: &str) {
        let now = crate::time::unix_now_secs();
        // Простой расчёт локальных компонентов по UNIX-таймстампу (без chrono).
        // Дни с 1970-01-01; Civil algorithm для даты.
        let days = (now / 86400) as i64;
        let secs_of_day = now % 86400;
        let hour = secs_of_day / 3600;
        let minute = (secs_of_day % 3600) / 60;
        let (year, month, day) = civil_from_days(days);
        let weekday = ((days + 4).rem_euclid(7)) as u32; // 1970-01-01 = четверг (0=Пн)

        let current_id = self
            .state
            .get_variable("ID")
            .and_then(|v| v.as_str())
            .map(str::to_string)
            .unwrap_or_default();

        if !current_id.is_empty() && current_id != node_id {
            self.state.set_variable("LastID", Value::from(current_id));
        } else if current_id.is_empty() {
            self.state.set_variable("LastID", Value::from(""));
        }
        self.state.set_variable("ID", Value::from(node_id));

        self.state
            .set_variable("_SYS_HOUR", Value::from(hour as i64));
        self.state
            .set_variable("_SYS_MINUTE", Value::from(minute as i64));
        self.state
            .set_variable("_SYS_WEEKDAY", Value::from(weekday as i64));
        self.state.set_variable("_SYS_DAY", Value::from(day));
        self.state.set_variable("_SYS_MONTH", Value::from(month));
        self.state.set_variable("_SYS_YEAR", Value::from(year));
        self.state.set_variable(
            "_SYS_QUEST_VERSION",
            Value::from(self.quest_version.clone()),
        );
        self.state
            .set_variable("_SYS_PLATFORM", Value::from(self.platform.os.clone()));
    }

    /// Загрузить ноду: выполнить onNodeEnter-скрипты, разрешить контент.
    pub fn load_node(&mut self, node_id: &str) -> Option<NodeView> {
        let raw = self.nodes.get(node_id)?.clone();
        let resolved = self.resolve_node(raw);

        self.current_node_id = Some(node_id.to_string());
        self.revealed_count = 0;
        self.revealed_items.clear();

        self.update_system_variables(node_id);

        // Диспетчер данных: пересобрать подписки этой ноды и выбросить
        // изменения, накопленные инициализацией (дефолты квеста, восстановление
        // сохранения). Подписка ловит изменения игрока, а не загрузку квеста.
        self.state.reset_changed_paths();
        self.rebuild_data_watches(Some(&resolved));

        // HUD-панели.
        let mut huds = Vec::new();
        let raw_items = resolved
            .content
            .get("items")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        for item in raw_items {
            let ci = ContentItem::from_json(&item);
            if ci.item_type == "hud_panel" {
                huds.push(self.resolve_item_tree(ci));
            }
        }
        self.hud_panels = huds.clone();

        // Скрипт-ассет ноды (onNodeEnter) — JSON или `.lua`.
        let mut transition = None;
        if let Some(script_id) = resolved.script_asset_id.clone()
            && !script_id.is_empty()
        {
            transition = if self.is_lua_path(&script_id) {
                self.execute_lua_file(&script_id, EventType::OnNodeEnter, None)
            } else {
                self.execute_script_file(&script_id, EventType::OnNodeEnter, None, None)
            };
        }

        // Inline onNodeEnter script-айтемы.
        if transition.is_none()
            && let Some(next) = self.run_inline_scripts(&resolved, EventType::OnNodeEnter)
        {
            transition = Some(next);
        }

        // Фоновое изображение/видео/аудио + таймер.
        let background_image_id = self.resolve_background_image(&resolved);
        let background_video_id = self.resolve_background_video(&resolved);
        let background_audio = self.resolve_background_audio(&resolved);
        let timer = resolved.timer_duration.filter(|d| *d > 0.0).and_then(|d| {
            resolved
                .default_action_node_id
                .clone()
                .map(|node| ResolvedTimer {
                    duration: d,
                    default_action_node_id: node,
                })
        });

        // Граница шага: onNodeEnter мог наработать изменений. Если нода
        // уходит по переходу, диспетчер не запускаем — накопленное сгорает.
        if transition.is_none() {
            transition = self.flush_data_changes();
        } else {
            self.state.reset_changed_paths();
        }

        Some(NodeView {
            node_id: node_id.to_string(),
            title: resolved.title.clone(),
            presentation_id: uuid_v4(),
            node_json: serde_json::to_string(&resolved.to_json()).unwrap_or_else(|_| "{}".into()),
            revealed_items: Vec::new(),
            hud_panels: huds,
            background_image_id,
            background_video_id,
            background_audio,
            timer,
            transition,
        })
    }

    /// Выполнить inline script-айтемы ноды для события.
    fn run_inline_scripts(&mut self, node: &SavedNode, event_type: EventType) -> Option<String> {
        let items = node.content.get("items")?.as_array()?;
        for item in items {
            let obj = item.as_object()?;
            if obj.get("type").and_then(Value::as_str) != Some("script") {
                continue;
            }
            let resource_path = obj.get("resourcePath")?.as_str()?;
            if resource_path.is_empty() {
                continue;
            }
            let script = self.load_script(resource_path)?;
            if !script_has_event(&script, event_type) {
                continue;
            }
            if let Some(next) = self.execute_script_file(resource_path, event_type, None, None) {
                return Some(next);
            }
        }
        None
    }

    /// Раскрыть следующий контент-айтем.
    ///
    /// Выполняет autorun-поведения (onReveal/onAppear execute) и возвращает
    /// ВСЕ айтемы (включая скрытые). Фильтрация видимости — дело клиента
    /// (ConditionalContentWrapper), чтобы скрытые айтемы могли стать видимыми
    /// при изменении состояния без повторного reveal.
    pub fn next_item(&mut self) -> NextStep {
        let Some(current_id) = self.current_node_id.clone() else {
            return NextStep::Done;
        };
        let Some(node) = self.nodes.get(&current_id).cloned() else {
            return NextStep::Done;
        };
        let node = self.resolve_node(node);
        let Some(items) = node.content.get("items").and_then(Value::as_array) else {
            return NextStep::Done;
        };

        loop {
            let idx = self.revealed_count;
            if idx >= items.len() {
                return NextStep::Done;
            }
            self.revealed_count += 1;

            let raw = &items[idx];
            let mut ci = ContentItem::from_json(raw);

            if self.tree_has_linked(&ci) {
                ci = self.resolve_item_tree(ci);
            }
            if ci.item_type == "script" {
                if let Some(resource_path) = ci.resource_path.clone()
                    && !resource_path.is_empty()
                {
                    let next = if self.is_lua_path(&resource_path) {
                        self.execute_lua_file(&resource_path, EventType::OnContentAppear, None)
                    } else {
                        self.execute_script_file(
                            &resource_path,
                            EventType::OnContentAppear,
                            None,
                            None,
                        )
                    };
                    if let Some(next) = self.after_step(next) {
                        return NextStep::Transition(next);
                    }
                }
                // script-айтем не рендерится — идём дальше.
                continue;
            }

            // Autorun: выполнить onReveal/onAppear execute блоки. Паритет Dart:
            // `ScriptExecutor.execute` в `_processOnAppearScript`.
            // Переход пробрасываем сразу.
            if let Some(next) = self.execute_behaviour(&ci, "onReveal") {
                return NextStep::Transition(next);
            }

            // Отдаём ВСЕ айтемы. Видимость проверяется клиентом реактивно
            // (ConditionalContentWrapper → evaluate_visibility).
            self.revealed_items.push(ci.clone());
            return NextStep::Item(Box::new(ci));
        }
    }

    /// Обработать нажатие на айтем: вернуть переход, если скрипт даёт его.
    /// Запланированные тики таймеров (`_internal_timer_schedule`).
    pub fn pending_timers(&self) -> Vec<TimerSpec> {
        let Some(Value::Array(arr)) = self.state.get_variable("_internal_timer_schedule").cloned()
        else {
            return Vec::new();
        };
        arr.iter()
            .filter_map(|v| {
                Some(TimerSpec {
                    script_path: v.get("script_path")?.as_str()?.to_string(),
                    entry: v.get("entry")?.as_str()?.to_string(),
                    ms: v.get("ms")?.as_i64()?,
                })
            })
            .collect()
    }

    /// Один тик таймера: выполнить запланированный re-invoke функции
    /// (`script_path`, `entry`). Убирает запись из расписания, исполняет
    /// функцию заново (цикл внутри неё запланирует следующий тик).
    /// Возвращает переход (`go_to_node`), если был. Задержки тика покрыты
    /// самим таймером, поэтому `_internal_delay_queue` сбрасывается.
    pub fn run_scheduled_timer(&mut self, script_path: &str, entry: &str) -> Option<String> {
        let schedule = self.state.get_variable("_internal_timer_schedule").cloned();
        let mut arr = match schedule {
            Some(Value::Array(a)) => a,
            _ => Vec::new(),
        };
        let idx = arr.iter().position(|v| {
            v.get("script_path").and_then(Value::as_str) == Some(script_path)
                && v.get("entry").and_then(Value::as_str) == Some(entry)
        })?;
        // Сначала грузим скрипт: если он пропал, расписание не трогаем.
        let script = self.load_script(script_path)?;
        arr.remove(idx);
        self.state
            .set_variable("_internal_timer_schedule", Value::Array(arr));
        let exec = self.new_executor();
        let transition = if entry == "*" {
            exec.execute_script_tick(
                &script,
                &mut self.state,
                &self.quest_id,
                script_path,
                &mut self.lua,
            )
        } else {
            exec.execute_function_tick(
                &script,
                &mut self.state,
                &self.quest_id,
                script_path,
                entry,
                &mut self.lua,
            )
        }
        .ok()
        .flatten();
        self.state
            .set_variable("_internal_delay_queue", Value::Array(vec![]));
        self.after_step(transition)
    }

    /// Слить очередь задержек (`_internal_delay_queue`), накопленную блоками
    /// `wait` за последнее исполнение скриптов, и очистить её. Возвращает
    /// ПОЛНЫЕ шаги пейсинга: каждый — `{ms, variables, tables, audio}`, где
    /// `variables`/`tables` — снапшот промежуточных состояний, накопленных к
    /// этому `wait` (клиент публикует их ПЕРЕД ожиданием; без них условные
    /// видимости картинок видят только финальное значение — анимация атаки
    /// «перескакивает» промежуточные кадры), а `audio` — звуки, накопленные
    /// между предыдущим checkpoint'ом и этим. Паритет эталона, где `wait` был
    /// `await Future.delayed(ms)` между видимыми мутациями state.
    pub fn drain_delay_steps(&mut self) -> Vec<Value> {
        let Some(Value::Array(arr)) = self.state.get_variable("_internal_delay_queue").cloned()
        else {
            return Vec::new();
        };
        let steps: Vec<Value> = arr
            .into_iter()
            .filter_map(|mut v| {
                let ms = v.get("ms").and_then(Value::as_i64).unwrap_or(0);
                if ms <= 0 {
                    return None;
                }
                // Аудио-команды шага — в канонический формат клиента.
                if let Some(Value::Array(arr)) = v.get("audio").cloned() {
                    let normalized: Vec<Value> = arr.iter().map(normalize_audio_command).collect();
                    if let Some(obj) = v.as_object_mut() {
                        obj.insert("audio".into(), Value::Array(normalized));
                    }
                }
                Some(v)
            })
            .collect();
        self.state
            .set_variable("_internal_delay_queue", Value::Array(vec![]));
        steps
    }

    /// Совместимый шим: суммарные ms очереди (для старых вызовов/тестов).
    pub fn drain_delay_queue(&mut self) -> Vec<i64> {
        self.drain_delay_steps()
            .iter()
            .filter_map(|v| v.get("ms").and_then(Value::as_i64))
            .collect()
    }

    /// Проверить видимость айтема по behaviours.
    ///
    /// Проверяет condition-блоки поведения (kind=visibility или legacy onAppear).
    ///
    /// - `allow_mutation=true` — первый проход: разрешает `set_variable` внутри
    ///   condition-блоков (паритет Dart `evaluateCondition(allowStateMutation: true)`).
    /// - `allow_mutation=false` — реактивная переоценка при изменении переменных.
    ///
    /// Для обратной совместимости: если behaviours нет, проверяет старый onAppear.
    pub fn evaluate_visibility(&mut self, item: &ContentItem, allow_mutation: bool) -> bool {
        let behaviours = item.resolved_behaviours();

        // Ищем behaviour с kind=visibility (или legacy onAppear без kind).
        let vis_behaviours: Vec<_> = behaviours
            .iter()
            .filter(|b| b.kind == "visibility" || (b.event == "onAppear" && b.kind == "action"))
            .collect();

        if vis_behaviours.is_empty() {
            return true; // нет условий видимости — показываем
        }

        for beh in vis_behaviours {
            let (script_path, function_entry) = parse_trigger_ref(&beh.script);
            if script_path.is_empty() {
                continue;
            }

            // .lua триггер всегда видим (нет condition-блоков).
            if self.is_lua_path(&script_path) {
                continue;
            }

            let Some(script) = self.load_script(&script_path) else {
                continue;
            };

            // Функция-триггер (`#fn=`): паритет старого Dart
            // `_processOnAppearScript` — событие ищем по типу `function`,
            // иначе function-блок не совпадёт ни с одним event-типом и
            // видимость молча пропустится («фантомный» элемент).
            let event_type = if function_entry.is_some() {
                EventType::Function
            } else {
                match beh.event.as_str() {
                    "onAppear" => EventType::OnContentAppear,
                    "onPress" => EventType::OnPress,
                    _ => EventType::OnContentAppear,
                }
            };

            if !has_executable_blocks(
                &script,
                event_type,
                function_entry.as_deref(),
                Some(&item.id),
            ) {
                continue;
            }

            let visible = crate::executor::evaluate_condition(
                &script,
                &mut self.state,
                event_type,
                &function_entry,
                &Some(item.id.clone()),
                false, // no target mismatch fallback for visibility
                allow_mutation,
            );

            if !visible {
                return false;
            }
        }

        true
    }

    /// Применить внешние переменные к состоянию движка.
    ///
    /// Используется для синхронизации pacing-снапшотов из `_internal_delay_queue`
    /// с движком, чтобы `evaluate_visibility` видел промежуточные значения
    /// (например, смену кадров анимации через `Вр_Img='ВПА'` → `wait` → `Вр_Img='—'`).
    ///
    /// **Важно**: не мутирует dirty-трекинг (переменные вставляются напрямую
    /// в `self.state.variables`, минуя `set_variable`), иначе `drain_state_delta`
    /// вернёт искажённую дельту. Оригинальные значения сохраняются в
    /// `self.state.pacing_overrides` для восстановления через `restore_after_pacing`.
    pub fn apply_external_variables(&mut self, variables: &serde_json::Map<String, Value>) {
        for (name, raw) in variables {
            let value: Value = if raw.is_string() {
                let s = raw.as_str().unwrap();
                serde_json::from_str(s).unwrap_or_else(|_| Value::String(s.to_string()))
            } else {
                raw.clone()
            };
            // Сохранить оригинал единожды (первый pacing-шаг).
            let original = self.state.variables().get(name).cloned();
            self.state
                .pacing_overrides_mut()
                .entry(name.clone())
                .or_insert(original);
            // Вставить напрямую, без грязного трекинга.
            self.state.variables_mut().insert(name.clone(), value);
        }
    }

    /// Восстановить переменные, перезаписанные через `apply_external_variables`.
    /// Вызывается после завершения pacing-цикла, чтобы движок вернулся к
    /// реальному состоянию (до применения промежуточных снапшотов).
    pub fn restore_after_pacing(&mut self) {
        let overrides = std::mem::take(self.state.pacing_overrides_mut());
        for (name, original) in overrides {
            match original {
                Some(val) => {
                    self.state.variables_mut().insert(name, val);
                }
                None => {
                    self.state.variables_mut().remove(&name);
                }
            }
        }
    }
    /// Установить переменную напрямую в состояние движка (минуя скриптовый
    /// исполнитель). Используется для мутаций, инициированных Dart-клиентом
    /// (например, `_onInputSubmitted`).
    ///
    /// Переменная помечается как dirty — попадёт в `drain_state_delta`.
    pub fn set_state_variable(&mut self, name: &str, value: serde_json::Value) {
        self.state.set_variable(name, value);
        // Прямая мутация клиента — тоже игровое изменение, диспетчер обязан
        // отработать. Вернуть переход отсюда нельзя, он ждёт ближайшей
        // границы шага.
        if let Some(next) = self.flush_data_changes() {
            self.pending_transition = Some(next);
        }
    }

    /// Забрать переход, который диспетчер выдал вне границы шага.
    ///
    /// Прямая мутация из клиента (`set_state_variable`) не имеет канала
    /// возврата, поэтому переход зависает в `pending_transition` и живёт до
    /// ближайшей границы. Клиент обязан проверить это поле после шага.
    pub fn take_pending_transition(&mut self) -> Option<String> {
        self.pending_transition.take()
    }

    /// Все переменные текущего состояния (read-only).
    pub fn all_variables(&self) -> &serde_json::Map<String, Value> {
        self.state.all_variables()
    }

    /// Выполнить behaviour айтема; на исходе — граница шага диспетчера.
    pub fn execute_behaviour(&mut self, item: &ContentItem, event: &str) -> Option<String> {
        let transition = self.execute_behaviour_inner(item, event);
        self.after_step(transition)
    }

    ///
    /// - `event` — тип события для поиска behaviour (`onPress`, `onReveal`
    ///   и т.д.).
    /// - Возвращает переход (`go_to_node`) или None.
    /// - Поддерживает fallback-цепочку для старых скриптов.
    fn execute_behaviour_inner(&mut self, item: &ContentItem, event: &str) -> Option<String> {
        let behaviours = item.resolved_behaviours();

        // Найти подходящий behaviour для события.
        let matching: Vec<&ContentTrigger> = behaviours
            .iter()
            .filter(|b| {
                b.event == event
                    || (event == "onReveal" && b.event == "onAppear" && b.kind == "action")
            })
            .collect();

        if matching.is_empty() {
            return None;
        }

        for beh in matching {
            let (script_path, function_entry) = parse_trigger_ref(&beh.script);
            if script_path.is_empty() {
                continue;
            }

            // lua-триггер
            if self.is_lua_path(&script_path) {
                let lua_event = behaviour_event_to_engine_event(&beh.event);
                if let Some(transition) =
                    self.execute_lua_file(&script_path, lua_event, Some(&item.id))
                {
                    return Some(transition);
                }
                continue;
            }

            let Some(script) = self.load_script(&script_path) else {
                continue;
            };

            if let Some(fn_entry) = &function_entry {
                if !has_executable_blocks(
                    &script,
                    EventType::Function,
                    Some(fn_entry),
                    Some(&item.id),
                ) {
                    continue;
                }
                if let Some(transition) = self.execute_script_file(
                    &script_path,
                    EventType::Function,
                    Some(fn_entry),
                    Some(&item.id),
                ) {
                    return Some(transition);
                }
                continue;
            }

            let primary_event = behaviour_event_to_engine_event(&beh.event);

            if has_executable_blocks(&script, primary_event, None, Some(&item.id)) {
                if let Some(transition) =
                    self.execute_script_file(&script_path, primary_event, None, Some(&item.id))
                {
                    return Some(transition);
                }
                continue;
            }

            // Fallback-цепочка (паритет Dart `_executeButtonScript`).
            let declared = check_script_event_type(&script);
            let attempted = [primary_event.name().to_string()];
            let mut candidates = vec![declared, EventType::OnNodeEnter, EventType::OnContentAppear];
            candidates.retain(|c| !attempted.contains(&c.name().to_string()));
            // dedup по имени события (иначе declared==OnNodeEnter дублируется)
            let mut deduped: Vec<EventType> = Vec::new();
            for c in candidates {
                if !deduped.iter().any(|e: &EventType| e.name() == c.name()) {
                    deduped.push(c);
                }
            }
            candidates = deduped;

            for event_type in candidates {
                let allow_fallback = event_type == EventType::OnContentAppear;
                if !has_executable_blocks_allow(
                    &script,
                    event_type,
                    None,
                    Some(&item.id),
                    allow_fallback,
                ) {
                    continue;
                }
                let exec = self.new_executor();
                let next = exec
                    .execute(
                        &script,
                        &mut self.state,
                        &self.quest_id,
                        event_type,
                        &None,
                        &Some(item.id.clone()),
                        allow_fallback,
                        &mut self.lua,
                    )
                    .ok()
                    .flatten();
                // первый подходящий кандидат — исполняем и возвращаем (даже None)
                return next;
            }
        }

        None
    }

    /// Обработать нажатие; на исходе — граница шага диспетчера.
    pub fn handle_interaction(&mut self, item: &ContentItem, trigger_ref: &str) -> Option<String> {
        let transition = self.handle_interaction_inner(item, trigger_ref);
        self.after_step(transition)
    }

    fn handle_interaction_inner(
        &mut self,
        item: &ContentItem,
        trigger_ref: &str,
    ) -> Option<String> {
        if trigger_ref.is_empty() {
            return None;
        }
        // Парсинг TriggerReference: `path/to/script.json#fn=entry`.
        let (script_path, function_entry) = parse_trigger_ref(trigger_ref);

        // `.lua`-триггер: читаем файл и вызываем функцию события (или `start`).
        if self.is_lua_path(&script_path) {
            return self.execute_lua_file(&script_path, EventType::OnPress, Some(&item.id));
        }

        if let Some(fn_entry) = &function_entry {
            // function-ref
            let script = self.load_script(&script_path)?;
            if !has_executable_blocks(&script, EventType::Function, Some(fn_entry), Some(&item.id))
            {
                return None;
            }
            return self.execute_script_file(
                &script_path,
                EventType::Function,
                Some(fn_entry),
                Some(&item.id),
            );
        }

        let script = self.load_script(&script_path)?;

        if has_executable_blocks(&script, EventType::OnPress, None, Some(&item.id)) {
            return self.execute_script_file(
                &script_path,
                EventType::OnPress,
                None,
                Some(&item.id),
            );
        }

        // Fallback-цепочка (паритет Dart `_executeButtonScript`).
        let declared = check_script_event_type(&script);
        let attempted = [EventType::OnPress.name().to_string()];
        let mut candidates = vec![declared, EventType::OnNodeEnter, EventType::OnContentAppear];
        // удаляем дубли + уже attempted (дедуп, иначе onNodeEnter дублируется и скрипт исполнится дважды)
        candidates.retain(|c| !attempted.contains(&c.name().to_string()));
        // dedup по имени события
        let mut deduped: Vec<EventType> = Vec::new();
        for c in candidates {
            if !deduped.iter().any(|e: &EventType| e.name() == c.name()) {
                deduped.push(c);
            }
        }
        candidates = deduped;

        for event_type in candidates {
            let allow_fallback = event_type == EventType::OnContentAppear;
            if !has_executable_blocks_allow(
                &script,
                event_type,
                None,
                Some(&item.id),
                allow_fallback,
            ) {
                continue;
            }
            let exec = self.new_executor();
            let next = exec
                .execute(
                    &script,
                    &mut self.state,
                    &self.quest_id,
                    event_type,
                    &None,
                    &Some(item.id.clone()),
                    allow_fallback,
                    &mut self.lua,
                )
                .ok()
                .flatten();
            // Исполнили первый подходящий кандидат — возвращаем результат (даже None), не идём дальше
            return next;
        }
        None
    }

    /// Вычислить выражение на текущем состоянии. Возвращает JSON-строку.
    pub fn evaluate_expression(&self, input_json: &str) -> String {
        let input: serde_json::Value = serde_json::from_str(input_json).unwrap_or_default();
        let result = executor_evaluate(input, &self.state);
        serde_json::to_string(&result).unwrap_or_else(|_| "null".into())
    }

    /// Резолвить целевой узел (`=expression` или `{var}` → значение).
    ///
    /// Паритет Dart `_resolveTargetNodeId`:
    /// - `=expr` → вычисляет выражение
    /// - `{...}` → вычисляет выражение (переменная в фигурных скобках)
    /// - иначе → литеральный id ноды
    pub fn resolve_target_node_id(&self, raw: &str) -> Option<String> {
        let expression: String = if let Some(rest) = raw.strip_prefix('=') {
            rest.trim().to_string()
        } else if raw.contains('{') && raw.contains('}') {
            raw.trim().to_string()
        } else {
            return Some(raw.to_string());
        };
        if expression.is_empty() {
            return None;
        }
        let input = serde_json::Value::String(expression);
        let result = executor_evaluate(input, &self.state);
        match result {
            serde_json::Value::Null => None,
            serde_json::Value::String(s) if s.is_empty() => None,
            other => Some(value_to_string(&other)),
        }
    }

    /// Сохранить текущее состояние в произвольный слот.
    ///
    /// Возвращает созданный слот, либо `None`, если хранилище не задано
    /// или игра ещё не начата (нет текущей ноды).
    pub fn save_current_slot(&self, slot_name: &str) -> Option<SaveSlot> {
        let store = self.save_store.as_ref()?;
        let slot = self.to_save_slot(slot_name)?;
        store.write(&slot);
        Some(slot)
    }

    /// Собрать `SaveSlot` из текущего состояния без записи в хранилище.
    ///
    /// Возвращает `None`, если игра ещё не начата. Позволяет клиенту
    /// восстановить сессию (например, при пересоздании движка после
    /// редактирования) без знания внутренней сериализации сейва.
    pub fn to_save_slot(&self, slot_name: &str) -> Option<SaveSlot> {
        let current_node_id = self.current_node_id.as_deref()?;
        Some(SaveSlot::create_new(
            self.quest_id.clone(),
            slot_name.to_string(),
            current_node_id.to_string(),
            self.state.all_variables().clone(),
            tables_to_map(&self.state),
        ))
    }

    /// Собрать `SaveSlot` из текущего состояния с явным переопределением
    /// текущей ноды (для восстановления после пересоздания движка).
    pub fn to_save_slot_at(&self, slot_name: &str, current_node_id: &str) -> Option<SaveSlot> {
        Some(SaveSlot::create_new(
            self.quest_id.clone(),
            slot_name.to_string(),
            current_node_id.to_string(),
            self.state.all_variables().clone(),
            tables_to_map(&self.state),
        ))
    }

    /// Автосохранение: перезаписывает системный слот `_autosave`.
    pub fn perform_autosave(&self) -> Option<SaveSlot> {
        let store = self.save_store.as_ref()?;
        self.current_node_id.as_deref()?;
        let mut slot = self.to_save_slot("Автосохранение")?;
        slot.id = crate::services::SaveGameService::AUTOSAVE_ID.to_string();
        store.write(&slot);
        Some(slot)
    }

    /// Список сейв-слотов квеста (пусто, если хранилище не задано).
    pub fn list_saves(&self) -> Vec<SaveSlot> {
        self.save_store
            .as_ref()
            .map(|s| s.list(&self.quest_id))
            .unwrap_or_default()
    }

    /// Прочитать конкретный слот.
    pub fn read_save(&self, slot_id: &str) -> Option<SaveSlot> {
        self.save_store.as_ref()?.read(&self.quest_id, slot_id)
    }

    /// Удалить слот.
    pub fn delete_save(&self, slot_id: &str) {
        if let Some(store) = self.save_store.as_ref() {
            store.delete(&self.quest_id, slot_id);
        }
    }

    /// Снапшот текущего состояния (для автосейва).
    pub fn current_state_snapshot(&self) -> GameStateSnapshot {
        let variables = self
            .state
            .all_variables()
            .iter()
            .map(|(k, v)| {
                (
                    k.clone(),
                    serde_json::to_string(v).unwrap_or_else(|_| "null".into()),
                )
            })
            .collect();
        let tables = self
            .state
            .all_tables()
            .iter()
            .map(|(name, t)| {
                (
                    name.clone(),
                    serde_json::to_string(&t.to_json()).unwrap_or_else(|_| "null".into()),
                )
            })
            .collect();
        GameStateSnapshot {
            current_node_id: self.current_node_id.clone(),
            variables,
            tables,
        }
    }

    /// Собрать и очистить аудио-команды, накопленные скриптами.
    ///
    /// Команды копятся в `_internal_audio_queue` (несколько команд за одно
    /// исполнение не теряются — паритет: Dart-эталон доставлял каждую в своей
    /// точке `await`). Клиент применяет их по порядку. Команды, оказавшиеся
    /// между блоками `wait`, прибиваются к pacing-шагам `_internal_delay_queue`
    /// и здесь уже не появляются. Формат на выходе — канонический для клиента:
    /// `{"type": "playSound", "id": …, "volume": …}` и т.д.
    pub fn drain_audio_commands(&mut self) -> AudioCommandDelta {
        let queued = self.state.get_variable("_internal_audio_queue").cloned();
        self.state
            .set_variable("_internal_audio_queue", Value::Array(Vec::new()));
        let commands = match queued {
            Some(Value::Array(arr)) => arr.iter().map(normalize_audio_command).collect(),
            _ => Vec::new(),
        };
        AudioCommandDelta { commands }
    }

    /// Собрать и очистить внешние системные команды (`open_link` и т.п.),
    /// накопленные скриптами. Аналог [`GameEngine::drain_audio_commands`], но
    /// для не-аудио I/O, которое выполняет клиент (например, открытие ссылки
    /// в браузере через `url_launcher`). Формат — сырые JSON-объекты:
    /// `{"type": "open_link", "url": "…"}`.
    pub fn drain_external_commands(&mut self) -> Vec<Value> {
        let queued = self
            .state
            .get_variable("_internal_external_commands")
            .cloned();
        self.state
            .set_variable("_internal_external_commands", Value::Array(Vec::new()));
        match queued {
            Some(Value::Array(arr)) => arr,
            _ => Vec::new(),
        }
    }

    /// Собрать и очистить дельту изменённого состояния.
    ///
    /// Возвращает только переменные/таблицы, изменённые с момента прошлого
    /// вызова (набор dirty-имён ведёт [`InMemoryScriptRuntimeState`]). Клиент
    /// применяет её точечно к своему зеркалу `gameStateProvider` вместо
    /// полного пересоздания снапшота.
    pub fn drain_state_delta(&mut self) -> StateDelta {
        let dirty_vars = self.state.drain_dirty_variables();
        let dirty_tables = self.state.drain_dirty_tables();

        let variables = dirty_vars
            .into_iter()
            .filter_map(|name| {
                let v = self.state.get_variable(&name)?;
                Some((
                    name,
                    serde_json::to_string(v).unwrap_or_else(|_| "null".into()),
                ))
            })
            .collect();

        let tables = dirty_tables
            .into_iter()
            .filter_map(|name| {
                let t = self.state.get_table(&name)?;
                Some((
                    name,
                    serde_json::to_string(&t.to_json()).unwrap_or_else(|_| "null".into()),
                ))
            })
            .collect();

        StateDelta { variables, tables }
    }

    // --- Резолюция шаблонов ---

    fn tree_has_linked(&self, item: &ContentItem) -> bool {
        if item.is_template_instance() {
            return true;
        }
        let Some(children) = &item.children else {
            return false;
        };
        children.iter().any(|c| self.tree_has_linked(c))
    }

    fn resolve_item_tree(&self, item: ContentItem) -> ContentItem {
        self.resolve_item_tree_inner(&mut std::collections::HashSet::new(), item)
    }

    /// Паритет Dart `resolveTree(_, visited:)` — гард от циклических ссылок
    /// шаблонов (инстанс ссылается сам на себя или образует цикл): без него
    /// рекурсия ушла бы в бесконечность. При цикле айтем возвращается как есть.
    fn resolve_item_tree_inner(
        &self,
        visited: &mut std::collections::HashSet<String>,
        item: ContentItem,
    ) -> ContentItem {
        if item.is_template_instance() {
            let Some(r) = item
                .template_ref
                .clone()
                .filter(|r| visited.insert(r.clone()))
            else {
                return item;
            };
            let expanded = self.resolve_content_item(&item);
            // `r` остаётся в set на время рекурсии детей: ловится самоцикл.
            let new_children = expanded.children.clone().map(|cs| {
                cs.into_iter()
                    .map(|c| self.resolve_item_tree_inner(visited, c))
                    .collect()
            });
            visited.remove(&r);
            if new_children.is_none() {
                return expanded;
            }
            return with_children(expanded, new_children);
        }
        let children = item.children.clone();
        if children.is_none() {
            return item;
        }
        // ВАЖНО: дети резолвятся тем же visited-сетом (`_inner`), а не
        // `resolve_item_tree` с новым пустым сетом — иначе гард цикла
        // рвётся на каждом НЕ-шаблонном контейнере: шаблон → контейнер →
        // инстанс того же шаблона уходит в бесконечную рекурсию
        // (stack overflow → abort процесса без Dart-ошибки).
        let new_children = children.map(|cs| {
            cs.into_iter()
                .map(|c| self.resolve_item_tree_inner(visited, c))
                .collect()
        });
        with_children(item, new_children)
    }

    fn resolve_node(&self, instance: SavedNode) -> SavedNode {
        if !instance.is_template_instance() {
            return instance;
        }
        let Some(master) = instance
            .template_ref
            .as_ref()
            .and_then(|r| self.templates.get(r))
        else {
            return instance;
        };
        if master.payload.is_empty() {
            return instance;
        }
        let mut expanded = SavedNode::from_json(&Value::Object(master.payload.clone()));

        // Раскрываем items в payload ноды.
        let fixed_content = expand_content_map(expanded.content.clone(), &instance.id);
        expanded.content = fixed_content;
        expanded.id = instance.id.clone();
        expanded.chapter_id = instance.chapter_id.clone();
        expanded.x = instance.x;
        expanded.y = instance.y;
        expanded.default_action_node_id = None;
        expanded.template_ref = instance.template_ref.clone();
        expanded.template_version = Some(master.content_version);
        expanded
    }

    fn resolve_content_item(&self, instance: &ContentItem) -> ContentItem {
        if !instance.is_template_instance() {
            return instance.clone();
        }
        let Some(master) = instance
            .template_ref
            .as_ref()
            .and_then(|r| self.templates.get(r))
        else {
            return instance.clone();
        };
        let master_item = ContentItem::from_json(&Value::Object(master.payload.clone()));
        // _expandContentItem: деривация id всех потомков + обход linked-детей.
        let expanded = self.expand_content_item(&master_item, &instance.id, "$");
        // _mergeTopLevel: данные инстанса поверх мастера.
        let mut merged = expanded;
        merged.id = instance.id.clone();
        merged.flex = instance.flex;
        merged.is_hidden = instance.is_hidden;
        merged.background_color_value = instance.background_color_value;
        merged.template_ref = instance.template_ref.clone();
        merged.template_version = merged.template_version.or(instance.template_version);
        merged
    }

    /// Рекурсивно деривировать id потомков мастера (паритет `_expandContentItem`).
    fn expand_content_item(
        &self,
        master: &ContentItem,
        instance_id: &str,
        seed_path: &str,
    ) -> ContentItem {
        let children = master.children.clone().map(|cs| {
            cs.iter()
                .enumerate()
                .map(|(i, c)| {
                    self.expand_content_item(c, instance_id, &format!("{seed_path}.children[{i}]"))
                })
                .collect()
        });
        let modal_buttons = master.modal_buttons.clone().map(|bs| {
            bs.iter()
                .enumerate()
                .map(|(i, b)| {
                    let mut b = b.clone();
                    b.id =
                        derive_template_id(instance_id, &format!("{seed_path}.modalButtons[{i}]"));
                    b
                })
                .collect()
        });
        let mut item = master.clone();
        item.id = derive_template_id(instance_id, seed_path);
        item.children = children;
        item.modal_buttons = modal_buttons;
        item
    }

    fn resolve_background_image(&self, node: &SavedNode) -> Option<String> {
        if node
            .background_asset_id
            .as_deref()
            .is_some_and(|s| !s.trim().is_empty())
        {
            return node.background_asset_id.clone();
        }
        if let Some(tag) = self.config.tags.iter().find(|t| t.id == node.chapter_id)
            && let Some(id) = tag.background_asset_id.as_deref()
            && !id.trim().is_empty()
        {
            return Some(id.to_string());
        }
        self.config.background_asset_id.clone()
    }

    fn resolve_background_video(&self, node: &SavedNode) -> Option<String> {
        if node
            .background_video_asset_id
            .as_deref()
            .is_some_and(|s| !s.trim().is_empty())
        {
            return node.background_video_asset_id.clone();
        }
        // fallback to backgroundAssetId if it looks like video (extension check)
        if let Some(id) = node.background_asset_id.as_deref()
            && !id.trim().is_empty()
            && {
                let lower = id.to_ascii_lowercase();
                lower.ends_with(".mp4")
                    || lower.ends_with(".mov")
                    || lower.ends_with(".webm")
                    || lower.ends_with(".mkv")
                    || lower.ends_with(".avi")
                    || lower.ends_with(".m4v")
            }
        {
            return Some(id.to_string());
        }
        None
    }

    fn resolve_background_audio(&self, node: &SavedNode) -> Option<ResolvedAudio> {
        if node
            .background_audio_id
            .as_deref()
            .is_some_and(|s| !s.trim().is_empty())
        {
            return Some(ResolvedAudio {
                audio_id: node.background_audio_id.clone()?,
                volume: node.background_audio_volume.unwrap_or(1.0),
            });
        }
        if let Some(tag) = self.config.tags.iter().find(|t| t.id == node.chapter_id)
            && let Some(id) = tag
                .background_audio_id
                .as_deref()
                .filter(|s| !s.trim().is_empty())
        {
            return Some(ResolvedAudio {
                audio_id: id.to_string(),
                volume: 1.0,
            });
        }
        None
    }
}

/// Снапшот состояния для сериализации (автосейв/слот).
#[derive(Debug, Clone, Default)]
pub struct GameStateSnapshot {
    pub current_node_id: Option<String>,
    /// Переменные: имя → JSON-строка значения.
    pub variables: HashMap<String, String>,
    /// Таблицы: имя → JSON-строка полной таблицы (`QuestTable.to_json()`).
    /// Сохраняет `columns`/`rows`/`data` без потерь (паритет со старым сейвом).
    pub tables: HashMap<String, String>,
}

/// Дельта состояния: только переменные/таблицы, изменённые с момента
/// последнего `drain_state_delta`. Формат значений — как в [`GameStateSnapshot`]
/// (JSON-строки), чтобы клиент декодировал уже знакомым способом.
#[derive(Debug, Clone, Default)]
pub struct StateDelta {
    /// Переменные: имя → JSON-строка значения.
    pub variables: HashMap<String, String>,
    /// Таблицы: имя → JSON-строка полной таблицы.
    pub tables: HashMap<String, String>,
}

// ---------------------------------------------------------------------------
// Вспомогательные функции (без I/O)
// ---------------------------------------------------------------------------

/// UUID v4 (без внешней зависимости — используем uuid crate из models).
fn uuid_v4() -> String {
    uuid::Uuid::new_v4().to_string()
}

/// Прочитать JSON-массив документов из asset store.
///
/// Поддерживает и `{ "nodes": [...] }`, и голый массив. Пустой массив —
/// если файла нет или он повреждён.
fn load_json_array<T>(
    store: &dyn ScriptAssetStore,
    path: &str,
    key: &str,
    f: impl Fn(&Value) -> T,
) -> Vec<T> {
    let Some(value) = store.read_json(path) else {
        return Vec::new();
    };
    let empty: Vec<serde_json::Value> = Vec::new();
    let array = match &value {
        Value::Array(arr) => arr,
        Value::Object(obj) => obj.get(key).and_then(Value::as_array).unwrap_or(&empty),
        _ => return Vec::new(),
    };
    array.iter().map(f).collect()
}

/// Таблицы runtime-состояния в виде `имя → QuestTable.to_json()`.
fn tables_to_map(state: &InMemoryScriptRuntimeState) -> Map<String, Value> {
    state
        .all_tables()
        .iter()
        .map(|(name, t)| (name.clone(), t.to_json()))
        .collect()
}

/// Безкавычечное строковое представление значения (паритет Dart `.toString()`).
fn value_to_string(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

/// Парсинг trigger reference: `path#fn=entry`.
fn parse_trigger_ref(raw: &str) -> (String, Option<String>) {
    let text = raw.trim();
    if text.is_empty() {
        return (String::new(), None);
    }
    if let Some(idx) = text.find("#fn=") {
        let script = text[..idx].trim().to_string();
        let fn_raw = text[idx + 4..].trim();
        if fn_raw.is_empty() {
            return (script, None);
        }
        let decoded = percent_decode(fn_raw);
        return (script, Some(decoded));
    }
    (text.to_string(), None)
}

/// Простой percent-decode (аналог Uri.decodeComponent для fn-имён).
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
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).to_string()
}

fn hex_val(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

/// Событие скрипта через делегат `executor`.
fn check_script_event_type(script: &Map<String, Value>) -> EventType {
    crate::executor::check_script_event_type(script)
}

/// Объявляет ли скрипт событие явным блоком (без фолбэка плоского скрипта).
fn declares_event(script: &Map<String, Value>, event: EventType) -> bool {
    crate::executor::declares_event(script, event)
}

/// Имя Lua-функции, которую движок зовёт для события.
fn lua_fn_name(event: EventType) -> &'static str {
    match event {
        EventType::OnQuestStart => "onQuestStart",
        EventType::OnNodeEnter => "onNodeEnter",
        EventType::OnPress => "onPress",
        EventType::OnContentAppear => "onContentAppear",
        EventType::Function => "start",
        EventType::OnDataChange => "onDataChange",
    }
}

/// Behaviour-событие → EventType движка.
fn behaviour_event_to_engine_event(event: &str) -> EventType {
    match event {
        "onPress" => EventType::OnPress,
        "onAppear" | "onReveal" => EventType::OnContentAppear,
        "onSubmit" => EventType::OnPress,
        _ => EventType::OnContentAppear,
    }
}

/// Нормализовать аудио-команду из внутреннего формата исполнителя
/// (`{"type": "play_sound", "audio_id": …, …}`) в канонический формат
/// клиента (`{"type": "playSound", "id": …, "volume": …}`), который ждёт
/// `game_screen_provider` (`_applyAudioCommands`). Неизвестные типы
/// проходят как есть.
fn normalize_audio_command(cmd: &Value) -> Value {
    let obj = match cmd.as_object() {
        Some(o) => o,
        None => return cmd.clone(),
    };
    match obj.get("type").and_then(Value::as_str).unwrap_or("") {
        "play_sound" => json!({
            "type": "playSound",
            "id": obj.get("audio_id").cloned().unwrap_or(Value::Null),
            "volume": obj.get("volume").cloned().unwrap_or(json!(1.0)),
        }),
        "stop_sound" => json!({
            "type": "stopSound",
            "target": obj.get("target").cloned().unwrap_or(json!("all")),
        }),
        "play_music" => json!({
            "type": "playMusic",
            "id": obj.get("audio_id").cloned().unwrap_or(Value::Null),
            "loop": obj.get("loop").cloned().unwrap_or(json!(true)),
            "volume": obj.get("volume").cloned().unwrap_or(json!(1.0)),
            "global": obj.get("global").cloned().unwrap_or(json!(false)),
        }),
        "stop_music" => json!({"type": "stopMusic"}),
        "pause_resume" => json!({
            "type": "pauseResume",
            "target": obj.get("target").cloned().unwrap_or(json!("all")),
            "action": obj.get("action").cloned().unwrap_or(json!("toggle")),
        }),
        "fade_out" => json!({
            "type": "fadeOut",
            "ms": obj.get("ms").cloned().unwrap_or(Value::Null),
        }),
        "fade_in" => json!({
            "type": "fadeIn",
            "ms": obj.get("ms").cloned().unwrap_or(Value::Null),
        }),
        _ => cmd.clone(),
    }
}

fn has_executable_blocks(
    script: &Map<String, Value>,
    event: EventType,
    function_name: Option<&str>,
    content_item_id: Option<&str>,
) -> bool {
    crate::executor::has_executable_blocks_for_event(
        script,
        event,
        &function_name.map(str::to_string),
        &content_item_id.map(str::to_string),
        false,
    )
}

fn has_executable_blocks_allow(
    script: &Map<String, Value>,
    event: EventType,
    function_name: Option<&str>,
    content_item_id: Option<&str>,
    allow_fallback: bool,
) -> bool {
    crate::executor::has_executable_blocks_for_event(
        script,
        event,
        &function_name.map(str::to_string),
        &content_item_id.map(str::to_string),
        allow_fallback,
    )
}

fn script_has_event(script: &Map<String, Value>, event: EventType) -> bool {
    let Some(blocks) = script.get("blocks").and_then(Value::as_array) else {
        return false;
    };
    for block in blocks {
        let Some(obj) = block.as_object() else {
            continue;
        };
        if obj.get("type").and_then(Value::as_str) != Some("event") {
            continue;
        }
        // тип события через один блок.
        let script_for_block = {
            let mut m = Map::new();
            m.insert("blocks".to_string(), Value::Array(vec![block.clone()]));
            m
        };
        if check_script_event_type(&script_for_block) == event {
            return true;
        }
    }
    false
}

/// Выполнить выражение над состоянием (падение на built-in evaluator).
fn executor_evaluate(input: Value, state: &InMemoryScriptRuntimeState) -> Value {
    crate::executor::evaluate_expression(Some(input), &mut state.clone())
}

fn with_children(item: ContentItem, children: Option<Vec<ContentItem>>) -> ContentItem {
    let mut item = item;
    item.children = children;
    item
}

/// Раскрыть items в content-мапе ноды (для linked-инстансов).
fn expand_content_map(content: Map<String, Value>, instance_id: &str) -> Map<String, Value> {
    let Some(items) = content.get("items").and_then(Value::as_array) else {
        return content;
    };
    let mut fixed = Vec::with_capacity(items.len());
    for (i, raw) in items.iter().enumerate() {
        if raw.is_object() {
            let mut ci = ContentItem::from_json(raw);
            let path = format!("$.items[{i}]");
            ci.id = derive_template_id(instance_id, &path);
            fixed.push(ci.to_json());
        } else {
            fixed.push(raw.clone());
        }
    }
    let mut result = content;
    result.insert("items".to_string(), Value::Array(fixed));
    result
}

/// Деривация id linked-инстанса (шаблон): sha1(instanceId|path) → `tpl_<16 hex>`.
fn derive_template_id(instance_id: &str, path: &str) -> String {
    use sha1::{Digest, Sha1};
    let raw = format!("{instance_id}|{path}");
    let hash = Sha1::digest(raw.as_bytes());
    let hex = hash.iter().map(|b| format!("{b:02x}")).collect::<String>();
    format!("tpl_{}", &hex[..16.min(hex.len())])
}

/// Civil date algorithm (Howard Hinnant) — дни с 1970-01-01 → (year, month, day).
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
    (if m <= 2 { y + 1 } else { y }, m, d)
}

#[cfg(test)]
#[path = "engine_tests/basic.rs"]
mod tests;

#[cfg(test)]
#[path = "engine_tests/audio.rs"]
mod audio_tests;

#[cfg(test)]
#[path = "engine_tests/regression.rs"]
mod regression_engine_tests;

#[cfg(test)]
#[path = "engine_tests/stat_double.rs"]
mod stat_double_tests;

#[cfg(test)]
#[path = "engine_tests/quest_scripts.rs"]
mod quest_scripts_tests;

#[cfg(test)]
#[path = "engine_tests/save_bgm.rs"]
mod save_bgm_tests;

#[cfg(test)]
#[path = "engine_tests/data_change.rs"]
mod data_change_tests;
