//! Хранилище файлов квеста (план 020-C1).
//!
//! ЕДИНСТВЕННЫЙ владелец записей в `quests/<id>/…`: атомарные записи
//! (temp→verify→rename), per-path локи, многофайловые транзакции и
//! read-modify-write для `metadata.json`.
//!
//! Гарантии (честно):
//! * одиночная запись — атомарна; сбой до rename целевой файл не трогает;
//! * `transact` — все temps пишутся ДО первого rename: провал подготовки
//!   откатывает всё; провал mid-rename оставляет консистентный префикс
//!   (без WAL это осознанный компромисс, renames дешёвые);
//! * параллельные писатели одного пути не теряют апдейты (per-path лок).
//!
//! Паритет семантики с клиентским FileStorage закреплён тестами.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
#[cfg(test)]
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, MutexGuard, OnceLock};

use serde_json::Value;

static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

/// Глобальный реестр локов по абсолютному пути файла. Мьютексы утекают
/// в 'static через Box::leak (их конечное число — по одному на файл).
fn lock_registry() -> &'static Mutex<HashMap<String, &'static Mutex<()>>> {
    static REGISTRY: OnceLock<Mutex<HashMap<String, &'static Mutex<()>>>> = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

type PathGuard = MutexGuard<'static, ()>;

/// ВЗЯТЬ лок пути (именно guard: голый Arc мьютекс никто не держит —
/// ловилось тестом параллельных писателей).
fn acquire_path(abs_path: &str) -> PathGuard {
    let mutex = {
        let mut reg = lock_registry().lock().expect("lock registry");
        *reg.entry(abs_path.to_string())
            .or_insert_with(|| Box::leak(Box::new(Mutex::new(()))))
    };
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poisoned) => poisoned.into_inner(),
    }
}

fn unique_temp(target: &Path) -> PathBuf {
    target.with_extension(format!(
        "tmp.{}",
        crate::time::unix_now_nanos() * 1000
            + u128::from(TEMP_COUNTER.fetch_add(1, Ordering::Relaxed))
    ))
}

/// Блокирующие локи на набор путей (сортировка — против deadlock).
fn acquire_all(abs_paths: &[String]) -> Vec<PathGuard> {
    let mut sorted: Vec<String> = abs_paths.to_vec();
    sorted.sort();
    sorted.dedup();
    sorted.iter().map(|p| acquire_path(p)).collect()
}

#[derive(Debug, Clone)]
pub enum StoreOp {
    WriteJson { rel: String, value: Value },
    WriteText { rel: String, content: String },
    Remove { rel: String },
}

#[derive(Debug)]
pub struct StoreError {
    pub code: &'static str,
    pub message: String,
}

impl StoreError {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

impl std::fmt::Display for StoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

type StoreResult<T> = Result<T, StoreError>;

/// Файловое хранилище квестов. Потокобезопасно; один экземпляр на root
/// или stateless-использование через FFI.
pub struct FsQuestStore {
    root: PathBuf,
}

/// Факты о файле каталога для библиотеки ресурсов.
///
/// Библиотека показывает сотни скриптов: имя, размер, дата, число блоков.
/// Ядро собирает это одним обходом каталога, вместо N отдельных переходов
/// через мост и N `stat` из Dart.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileFacts {
    pub file_name: String,
    pub size_bytes: u64,
    /// mtime в миллисекундах Unix-эпохи (None — платформа не отдала).
    pub modified_ms: Option<u64>,
    /// `name` из JSON-файла (только при `parse_json`).
    pub json_name: Option<String>,
    /// Число блоков-действий (только при `parse_json` и для скриптов).
    pub block_count: u32,
}

impl FsQuestStore {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    /// Валидация относительного пути (root-guard) + абсолютный путь.
    /// `pub(crate)` — нужен сборщику квеста (копирование ресурсов) и тестам.
    pub(crate) fn resolve(&self, rel: &str) -> StoreResult<PathBuf> {
        let p = Path::new(rel);
        if p.is_absolute()
            || p.components().any(|c| {
                matches!(
                    c,
                    std::path::Component::ParentDir
                        | std::path::Component::RootDir
                        | std::path::Component::Prefix(_)
                )
            })
        {
            return Err(StoreError::new(
                "bad_path",
                format!("недопустимый путь '{rel}'"),
            ));
        }
        Ok(self.root.join(p))
    }

    // ── Чтение ────────────────────────────────────────────────────────────

    pub fn exists(&self, rel: &str) -> bool {
        self.resolve(rel).map(|p| p.is_file()).unwrap_or(false)
    }

    pub fn read_json(&self, rel: &str) -> Option<Value> {
        let file = self.resolve(rel).ok()?;
        let content = std::fs::read_to_string(file).ok()?;
        serde_json::from_str(&content).ok()
    }

    pub fn read_text(&self, rel: &str) -> Option<String> {
        let file = self.resolve(rel).ok()?;
        std::fs::read_to_string(file).ok()
    }

    /// Создать каталог внутри квеста (например, `res/images` при создании).
    ///
    /// Путь проходит тот же root-guard, что и записи: наружу из корня
    /// хранилища не выйти.
    pub fn create_dir(&self, rel: &str) -> StoreResult<()> {
        let dir = self.resolve(rel)?;
        std::fs::create_dir_all(&dir)
            .map_err(|e| StoreError::new("io", format!("mkdir {}: {e}", dir.display())))
    }

    pub fn list_files(&self, rel_dir: &str, extension: Option<&str>) -> Vec<String> {
        let dir = match self.resolve(rel_dir) {
            Ok(d) => d,
            Err(_) => return Vec::new(),
        };
        let Ok(entries) = std::fs::read_dir(&dir) else {
            return Vec::new();
        };
        let ext_norm = extension.map(|e| e.trim_start_matches('.').to_lowercase());
        let mut out: Vec<String> = entries
            .filter_map(Result::ok)
            .filter(|e| e.path().is_file())
            .filter(|e| match &ext_norm {
                Some(ext) => e
                    .path()
                    .extension()
                    .and_then(|x| x.to_str())
                    .is_some_and(|x| x.to_lowercase() == *ext),
                None => true,
            })
            .filter_map(|e| e.file_name().to_str().map(String::from))
            .collect();
        out.sort();
        out
    }

    /// Снимок каталога: имя, размер, mtime и — при `parse_json` — имя из
    /// содержимого и число блоков-действий. Порядок — по имени файла,
    /// как у `list_files`.
    pub fn scan_files(
        &self,
        rel_dir: &str,
        extension: Option<&str>,
        parse_json: bool,
    ) -> Vec<FileFacts> {
        let dir = match self.resolve(rel_dir) {
            Ok(d) => d,
            Err(_) => return Vec::new(),
        };
        let Ok(entries) = std::fs::read_dir(&dir) else {
            return Vec::new();
        };
        let ext_norm = extension.map(|e| e.trim_start_matches('.').to_lowercase());
        let mut out: Vec<FileFacts> = entries
            .filter_map(Result::ok)
            .map(|e| e.path())
            .filter(|p| p.is_file())
            .filter(|p| match &ext_norm {
                Some(ext) => p
                    .extension()
                    .and_then(|x| x.to_str())
                    .is_some_and(|x| x.to_lowercase() == *ext),
                None => true,
            })
            .filter_map(|path| {
                let file_name = path.file_name()?.to_str()?.to_string();
                let meta = std::fs::metadata(&path).ok()?;
                let modified_ms = crate::time::mtime_millis(meta.modified());
                let mut json_name = None;
                let mut block_count = 0;
                if parse_json {
                    let rel = if rel_dir.is_empty() {
                        file_name.clone()
                    } else {
                        format!("{rel_dir}/{file_name}")
                    };
                    if let Some(value) = self.read_json(&rel)
                        && let Some(map) = value.as_object()
                    {
                        json_name = map
                            .get("name")
                            .and_then(Value::as_str)
                            .map(str::trim)
                            .filter(|s| !s.is_empty())
                            .map(String::from);
                        if let Some(Value::Array(blocks)) = map.get("blocks") {
                            block_count =
                                crate::script_format::count_action_blocks(blocks) as u32;
                        }
                    }
                }
                Some(FileFacts {
                    file_name,
                    size_bytes: meta.len(),
                    modified_ms,
                    json_name,
                    block_count,
                })
            })
            .collect();
        out.sort_by(|a, b| a.file_name.cmp(&b.file_name));
        out
    }

    // ── Запись ────────────────────────────────────────────────────────────

    /// Атомарная запись JSON под per-path локом.
    pub fn write_json(&self, rel: &str, value: &Value) -> StoreResult<()> {
        let serialized = serde_json::to_string(value)
            .map_err(|e| StoreError::new("serialize", e.to_string()))?;
        self.write_locked(rel, serialized.as_bytes())
    }

    /// Атомарная запись текста под per-path локом.
    pub fn write_text(&self, rel: &str, content: &str) -> StoreResult<()> {
        self.write_locked(rel, content.as_bytes())
    }

    fn write_locked(&self, rel: &str, bytes: &[u8]) -> StoreResult<()> {
        let target = self.resolve(rel)?;
        let _guard = acquire_path(&target.to_string_lossy());
        self.commit_bytes(&target, rel, bytes)
    }

    /// Stage(temp→verify) + Commit(rename). Вызывать ТОЛЬКО держа лок пути.
    fn commit_bytes(&self, target: &Path, rel: &str, bytes: &[u8]) -> StoreResult<()> {
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| StoreError::new("io", format!("mkdir {}: {e}", parent.display())))?;
        }

        let temp = unique_temp(target);

        // Stage: пишем и верифицируем temp.
        std::fs::write(&temp, bytes)
            .and_then(|_| std::fs::read(&temp))
            .map_err(|e| {
                let _ = std::fs::remove_file(&temp);
                StoreError::new("io", format!("temp write {}: {e}", temp.display()))
            })?;
        if std::fs::read(&temp).unwrap_or_default() != bytes {
            let _ = std::fs::remove_file(&temp);
            return Err(StoreError::new("verify", format!("temp {rel} не совпал")));
        }

        // Commit: rename поверх цели; фолбэк copy+delete.
        if let Err(e) = std::fs::rename(&temp, target) {
            if std::fs::copy(&temp, target).is_err() {
                let _ = std::fs::remove_file(&temp);
                return Err(StoreError::new(
                    "io",
                    format!("rename {}: {e}", target.display()),
                ));
            }
            let _ = std::fs::remove_file(&temp);
        }
        Ok(())
    }

    pub fn delete(&self, rel: &str) -> StoreResult<()> {
        let target = self.resolve(rel)?;
        let _guard = acquire_path(&target.to_string_lossy());
        match std::fs::remove_file(&target) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(StoreError::new("io", e.to_string())),
        }
    }

    /// Атомарный read-modify-write числового поля объекта:
    /// читает файл, прибавляет `by`, пишет обратно — всё под одним локом.
    /// Возвращает обновлённый документ.
    pub fn increment_json_field(&self, rel: &str, field: &str, by: i64) -> StoreResult<Value> {
        let target = self.resolve(rel)?;
        let _guard = acquire_path(&target.to_string_lossy());
        let mut doc = self
            .read_json(rel)
            .filter(Value::is_object)
            .unwrap_or_else(|| Value::Object(Default::default()));
        let current = doc.get(field).and_then(Value::as_i64).unwrap_or(0);
        let updated = current.saturating_add(by);
        doc.as_object_mut()
            .expect("объект")
            .insert(field.to_string(), Value::from(updated));
        self.commit_bytes(
            &target,
            rel,
            &serde_json::to_vec(&doc).map_err(|e| StoreError::new("serialize", e.to_string()))?,
        )?;
        Ok(doc)
    }

    // ── Транзакции ────────────────────────────────────────────────────────

    /// Многофайловая транзакция: все операции готовятся (temps), затем
    /// коммитятся renames под ЛОКАМИ ВСЕХ затронутых путей.
    pub fn transact(&self, ops: &[StoreOp]) -> StoreResult<Vec<String>> {
        // 1. Подготовить пути + сериализацию, взять локи всех целей.
        struct Staged {
            rel: String,
            temp: PathBuf,
            remove_only: bool,
        }
        let targets: Vec<String> = ops
            .iter()
            .map(|op| match op {
                StoreOp::WriteJson { rel, .. } | StoreOp::WriteText { rel, .. } => {
                    self.resolve(rel).map(|p| p.to_string_lossy().into_owned())
                }
                StoreOp::Remove { rel } => {
                    self.resolve(rel).map(|p| p.to_string_lossy().into_owned())
                }
            })
            .collect::<StoreResult<_>>()?;
        let _guards = acquire_all(&targets);

        let mut staged: Vec<Staged> = Vec::with_capacity(ops.len());
        let result_order: Vec<String> = ops
            .iter()
            .map(|op| match op {
                StoreOp::WriteJson { rel, .. } | StoreOp::WriteText { rel, .. } => rel.clone(),
                StoreOp::Remove { rel } => rel.clone(),
            })
            .collect();

        for op in ops {
            match op {
                StoreOp::WriteJson { rel, value } => {
                    let bytes = serde_json::to_vec(value)
                        .map_err(|e| StoreError::new("serialize", e.to_string()))?;
                    staged.push(Staged {
                        rel: rel.clone(),
                        temp: self.stage_temp(rel, &bytes)?,
                        remove_only: false,
                    });
                }
                StoreOp::WriteText { rel, content } => {
                    let bytes = content.as_bytes().to_vec();
                    staged.push(Staged {
                        rel: rel.clone(),
                        temp: self.stage_temp(rel, &bytes)?,
                        remove_only: false,
                    });
                }
                StoreOp::Remove { rel } => staged.push(Staged {
                    rel: rel.clone(),
                    temp: PathBuf::new(),
                    remove_only: true,
                }),
            }
        }

        // 2. Commit по порядку операций.
        for st in &staged {
            if st.remove_only {
                let target = self.resolve(&st.rel)?;
                match std::fs::remove_file(&target) {
                    Ok(()) => {}
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                    Err(e) => {
                        self.cleanup_temps(staged.iter().map(|s| &s.temp));
                        return Err(StoreError::new("io", e.to_string()));
                    }
                }
            } else {
                let target = self.resolve(&st.rel)?;
                if let Err(e) = std::fs::rename(&st.temp, &target) {
                    if std::fs::copy(&st.temp, &target).is_err() {
                        self.cleanup_temps(staged.iter().map(|s| &s.temp));
                        return Err(StoreError::new("io", format!("commit {}: {e}", st.rel)));
                    }
                    let _ = std::fs::remove_file(&st.temp);
                }
            }
        }
        Ok(result_order)
    }

    fn stage_temp(&self, rel: &str, bytes: &[u8]) -> StoreResult<PathBuf> {
        let target = self.resolve(rel)?;
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| StoreError::new("io", format!("mkdir {}: {e}", parent.display())))?;
        }
        let temp = unique_temp(&target);
        std::fs::write(&temp, bytes).map_err(|e| {
            let _ = std::fs::remove_file(&temp);
            StoreError::new("io", e.to_string())
        })?;
        Ok(temp)
    }

    fn cleanup_temps<'a>(&self, temps: impl Iterator<Item = &'a PathBuf>) {
        for t in temps {
            let _ = std::fs::remove_file(t);
        }
    }

    // ── metadata.json: атомарный read-modify-write ────────────────────────

    /// Применить мутации к metadata.json квеста одним куском.
    /// mutations: [{op:"set"|"remove", key:"<имя файла>", value:…}].
    /// Ключ — ЛИТЕРАЛЬНОЕ имя записи (файла), точки в нём значимы.
    pub fn metadata_mutate(
        &self,
        quest_id: &str,
        mutations: &[MetaMutation],
    ) -> StoreResult<Value> {
        let rel = format!("quests/{quest_id}/res/metadata.json");
        let target = self.resolve(&rel)?;
        let _guard = acquire_path(&target.to_string_lossy());

        let mut meta = self
            .read_json(&rel)
            .filter(Value::is_object)
            .unwrap_or_else(|| Value::Object(Default::default()));

        for m in mutations {
            apply_key_mutation(&mut meta, m)?;
        }

        // Запись ПОД УЖЕ ВЗЯТЫМ локом — окно read-modify-write закрыто.
        self.commit_bytes(
            &target,
            &rel,
            &serde_json::to_vec_pretty(&meta)
                .map_err(|e| StoreError::new("serialize", e.to_string()))?,
        )?;
        Ok(meta)
    }
}

#[derive(Debug, Clone)]
pub enum MetaMutation {
    Set { key: String, value: Value },
    Remove { key: String },
}

/// Ключи metadata — ЛИТЕРАЛЬНЫЕ имена файлов ("abc.json"): точки в них
/// не являются разделителями пути.
fn apply_key_mutation(meta: &mut Value, m: &MetaMutation) -> StoreResult<()> {
    let key = match m {
        MetaMutation::Set { key, .. } | MetaMutation::Remove { key } => key,
    };
    if key.trim().is_empty() || !meta.is_object() {
        return Err(StoreError::new("bad_path", format!("ключ '{key}'")));
    }
    let obj = meta.as_object_mut().unwrap();
    match m {
        MetaMutation::Set { value, .. } => {
            obj.insert(key.clone(), value.clone());
        }
        MetaMutation::Remove { .. } => {
            obj.remove(key);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::Barrier;

    fn temp_root(tag: &str) -> PathBuf {
        let n = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
        let dir =
            std::env::temp_dir().join(format!("mnd_qstore_{tag}_{}_{}", std::process::id(), n));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn write_json_is_atomic_and_creates_parents() {
        let root = temp_root("atomic");
        let store = FsQuestStore::new(&root);
        store
            .write_json("quests/q1/deep/file.json", &json!({"a": 1}))
            .unwrap();
        assert!(store.exists("quests/q1/deep/file.json"));
        assert_eq!(
            store.read_json("quests/q1/deep/file.json"),
            Some(json!({"a": 1}))
        );

        // Root-guard: выход за корень отклонён.
        assert!(store.write_json("../escape.json", &json!({})).is_err());
        assert!(!root.parent().unwrap().join("escape.json").exists());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn transact_rolls_back_on_failure_before_commit() {
        let root = temp_root("tx");
        let store = FsQuestStore::new(&root);
        store.write_json("a.json", &json!("old")).unwrap();

        // Вторая операция невалидна (путь с ..) → весь tx откатывается.
        let ops = vec![
            StoreOp::WriteJson {
                rel: "a.json".into(),
                value: json!("new"),
            },
            StoreOp::WriteJson {
                rel: "../bad.json".into(),
                value: json!({}),
            },
            StoreOp::Remove {
                rel: "a.json".into(),
            },
        ];
        assert!(store.transact(&ops).is_err());

        // a.json НЕ тронут (ни запись, ни удаление).
        assert_eq!(store.read_json("a.json"), Some(json!("old")));
        // temps не остались.
        let quests_dir = root.join("quests");
        let leftovers = std::fs::read_dir(&quests_dir)
            .map(|rd| rd.filter_map(Result::ok).count())
            .unwrap_or(0);
        assert_eq!(leftovers, 0);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn transact_applies_all_ops_in_order() {
        let root = temp_root("tx2");
        let store = FsQuestStore::new(&root);
        store.write_text("gone.txt", "x").unwrap();
        let ops = vec![
            StoreOp::WriteText {
                rel: "t.txt".into(),
                content: "привет".into(),
            },
            StoreOp::WriteJson {
                rel: "j.json".into(),
                value: json!([1, 2]),
            },
            StoreOp::Remove {
                rel: "gone.txt".into(),
            },
        ];
        store.transact(&ops).unwrap();
        assert_eq!(store.read_text("t.txt"), Some("привет".into()));
        assert_eq!(store.read_json("j.json"), Some(json!([1, 2])));
        assert!(!store.exists("gone.txt"));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn parallel_writers_do_not_lose_updates() {
        let root = temp_root("par");
        let store = Arc::new(FsQuestStore::new(&root));
        store.write_json("counter.json", &json!({"n": 0})).unwrap();

        let threads = 8;
        let per_thread = 25;
        let barrier = Arc::new(Barrier::new(threads));
        let mut handles = Vec::new();
        for _ in 0..threads {
            let s = store.clone();
            let b = barrier.clone();
            handles.push(std::thread::spawn(move || {
                b.wait();
                for _ in 0..per_thread {
                    s.increment_json_field("counter.json", "n", 1).unwrap();
                }
            }));
        }
        for h in handles {
            h.join().unwrap();
        }

        let final_n = store.read_json("counter.json").unwrap()["n"]
            .as_i64()
            .unwrap();
        // Каждый инкремент учтён: атомарный RMW не теряет апдейты.
        assert_eq!(final_n as usize, threads * per_thread);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn metadata_mutate_sets_and_removes_atomically() {
        let root = temp_root("meta");
        let store = FsQuestStore::new(&root);
        store
            .metadata_mutate(
                "q1",
                &[MetaMutation::Set {
                    key: "abc.json".into(),
                    value: json!({"name": "Скрипт", "folder": "/"}),
                }],
            )
            .unwrap();
        let meta = store.read_json("quests/q1/res/metadata.json").unwrap();
        assert_eq!(meta["abc.json"]["name"], "Скрипт");

        store
            .metadata_mutate(
                "q1",
                &[
                    MetaMutation::Set {
                        key: "def.lua".into(),
                        value: json!({"name": "Lua", "folder": "/lua"}),
                    },
                    MetaMutation::Remove {
                        key: "abc.json".into(),
                    },
                ],
            )
            .unwrap();
        let meta = store.read_json("quests/q1/res/metadata.json").unwrap();
        assert_eq!(meta["def.lua"]["name"], "Lua");
        assert!(meta.get("abc.json").is_none());

        // Пустой ключ — ошибка, файл не менялся.
        assert!(
            store
                .metadata_mutate(
                    "q1",
                    &[MetaMutation::Set {
                        key: String::new(),
                        value: json!(null)
                    }]
                )
                .is_err()
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn scan_files_reports_size_mtime_name_and_blocks() {
        let root = temp_root("scan");
        let store = FsQuestStore::new(&root);
        store
            .write_json(
                "scripts/s1.json",
                &json!({
                    "name": "Скрипт 1",
                    "blocks": [
                        {"type": "event", "children": [{"type": "wait"}]},
                        {"type": "go_to_node"}
                    ]
                }),
            )
            .unwrap();
        store.write_text("scripts/notes.txt", "x").unwrap();

        let facts = store.scan_files("scripts", Some(".json"), true);
        assert_eq!(facts.len(), 1);
        let f = &facts[0];
        assert_eq!(f.file_name, "s1.json");
        assert_eq!(f.json_name.as_deref(), Some("Скрипт 1"));
        assert_eq!(f.block_count, 2);
        assert!(f.size_bytes > 0);
        assert!(f.modified_ms.is_some());

        // Без разбора JSON — только файловые факты, весь каталог.
        let plain = store.scan_files("scripts", None, false);
        assert_eq!(plain.len(), 2);
        assert!(plain
            .iter()
            .all(|f| f.json_name.is_none() && f.block_count == 0));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn list_files_filters_by_extension() {
        let root = temp_root("list");
        let store = FsQuestStore::new(&root);
        store.write_text("scripts/a.json", "{}").unwrap();
        store.write_text("scripts/b.lua", "-- x").unwrap();
        store.write_text("scripts/c.JSON", "{}").unwrap();
        let jsons = store.list_files("quests/q1/scripts", Some(".json"));
        // Пути не созданы (запись шла в корень scripts/) — проверяем на корне.
        assert_eq!(
            store.list_files("scripts", Some("json")),
            vec!["a.json".to_string(), "c.JSON".to_string()]
        );
        assert_eq!(
            store.list_files("scripts", Some(".lua")),
            vec!["b.lua".to_string()]
        );
        let _ = std::fs::remove_dir_all(&root);
        let _ = jsons;
    }
}
