//! Потоковая раздача квеста: манифест, boot-бандл и ленивая выдача записей.
//!
//! Квест на диске лежит монолитом `<id>.mnd` (потоковый ZIP, см.
//! `mnd-core::quest_archive`). Для веб-плеера рядом строятся два артефакта:
//!
//! * `<id>.manifest.json` — список записей архива (путь, размер, sha256,
//!   признак `boot`), хеш содержимого и формат нод;
//! * `<id>.boot.mnd` — маленький архив только с текстовой частью:
//!   `config.json`, монолитный `nodes.json`, `res/templates.json`,
//!   `res/metadata.json`, `res/button_presets.json`, `scripts/**`,
//!   `_internal_scripts/**`, `res/fonts/**`.
//!
//! Всё остальное (картинки, звук, видео) выдаётся по требованию: запись
//! распаковывается при первом запросе в `<id>.d/<путь>` (temp + rename) и
//! дальше отдаётся статикой. Диск не дублируется целиком — материализуется
//! только то, что реально запросили.
//!
//! Шифрованные архивы (`MND_ENC2`/`MND_SEC_`) потоково не разбираются: клиент
//! их и так не открывает, поэтому такие квесты отдают 404 и остаются на
//! полной загрузке.

use std::fs::{self, File};
use std::io::{BufReader, BufWriter, Read, Seek, SeekFrom, Write};
use std::path::{Component, Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use uuid::Uuid;

const HEADER_ZIP: &[u8; 8] = b"MND_ZIP_";
const HEADER_SEC: &[u8; 8] = b"MND_SEC_";
const HEADER_ENC2: &[u8; 8] = b"MND_ENC2";

/// Версия формата манифеста. Клиент проверяет её и не берётся за чужие.
pub const MANIFEST_VERSION: u32 = 1;
/// Имя boot-архива внутри манифеста (рядом с `.mnd`).
pub const BOOT_NAME: &str = "boot.mnd";

const HASH_BUF: usize = 64 * 1024;

// ── пути артефактов ───────────────────────────────────────────────────────

/// `<quests_dir>/<id>.mnd`
pub fn mnd_path(quests_dir: &Path, quest_id: Uuid) -> PathBuf {
    quests_dir.join(format!("{quest_id}.mnd"))
}

/// `<quests_dir>/<id>.manifest.json`
pub fn manifest_path(quests_dir: &Path, quest_id: Uuid) -> PathBuf {
    quests_dir.join(format!("{quest_id}.manifest.json"))
}

/// `<quests_dir>/<id>.boot.mnd`
pub fn boot_path(quests_dir: &Path, quest_id: Uuid) -> PathBuf {
    quests_dir.join(format!("{quest_id}.boot.mnd"))
}

/// `<quests_dir>/<id>.d` — распакованные по требованию записи.
pub fn extracted_dir(quests_dir: &Path, quest_id: Uuid) -> PathBuf {
    quests_dir.join(format!("{quest_id}.d"))
}

fn temp_sibling(dest: &Path) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let name = dest
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("tmp")
        .to_string();
    dest.with_file_name(format!(".{name}.tmp.{}.{nanos}", std::process::id()))
}

// ── классификация записей ─────────────────────────────────────────────────

/// Записи, которые не отдаём наружу никогда (локальные сейвы и сессия
/// редактора — не часть квеста).
pub fn is_excluded(path: &str) -> bool {
    path.starts_with("saves/") || path == "editor_session.json"
}

/// Текстовая часть квеста, необходимая движку до первого кадра.
pub fn is_boot_entry(path: &str) -> bool {
    matches!(
        path,
        "config.json"
            | "nodes.json"
            | "nodes/nodes.json"
            | "res/templates.json"
            | "res/metadata.json"
            | "res/button_presets.json"
    ) || path.starts_with("scripts/")
        || path.starts_with("_internal_scripts/")
        || path.starts_with("res/fonts/")
}

/// Группа ресурса для манифеста и для приоритетов предзагрузки на клиенте.
pub fn kind_of(path: &str) -> &'static str {
    if path == "config.json" {
        return "config";
    }
    if path == "nodes.json" || path.starts_with("nodes/") {
        return "node";
    }
    if path == "res/templates.json" {
        return "template";
    }
    if path == "res/metadata.json" || path == "res/button_presets.json" {
        return "metadata";
    }
    if path.starts_with("scripts/") || path.starts_with("_internal_scripts/") {
        return "script";
    }
    if path.starts_with("res/images/") {
        return "image";
    }
    if path.starts_with("res/audio/") {
        return "audio";
    }
    if path.starts_with("res/videos/") {
        return "video";
    }
    if path.starts_with("res/fonts/") {
        return "font";
    }
    match extension(path).as_str() {
        "png" | "jpg" | "jpeg" | "webp" | "gif" | "bmp" | "avif" | "heic" | "heif" => "image",
        "mp3" | "wav" | "ogg" | "m4a" | "flac" | "aac" | "opus" => "audio",
        "mp4" | "webm" | "mkv" | "mov" | "avi" => "video",
        "ttf" | "otf" | "woff" | "woff2" => "font",
        "json" => "data",
        _ => "other",
    }
}

/// `Content-Type` для ленивой выдачи записи. `&'static str`, потому что так
/// требует `static_files::file_response`.
pub fn content_type_for(path: &str) -> &'static str {
    match extension(path).as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "webp" => "image/webp",
        "gif" => "image/gif",
        "bmp" => "image/bmp",
        "avif" => "image/avif",
        "mp3" => "audio/mpeg",
        "wav" => "audio/wav",
        "ogg" => "audio/ogg",
        "m4a" => "audio/mp4",
        "flac" => "audio/flac",
        "aac" => "audio/aac",
        "opus" => "audio/opus",
        "mp4" => "video/mp4",
        "webm" => "video/webm",
        "mkv" => "video/x-matroska",
        "mov" => "video/quicktime",
        "ttf" => "font/ttf",
        "otf" => "font/otf",
        "woff" => "font/woff",
        "woff2" => "font/woff2",
        "json" => "application/json",
        "lua" | "txt" | "md" => "text/plain; charset=utf-8",
        _ => "application/octet-stream",
    }
}

fn extension(path: &str) -> String {
    path.rsplit_once('.')
        .map(|(_, e)| e.to_ascii_lowercase())
        .unwrap_or_default()
}

/// Нормализует относительный путь записи и защищает от выхода за каталог.
///
/// Возвращает путь с прямыми слешами без ведущего `/`, либо `None` для
/// абсолютных путей, `..`, пустых и «специальных» компонент.
pub fn sanitize_rel(raw: &str) -> Option<String> {
    let unified = raw.replace('\\', "/");
    let trimmed = unified.trim_start_matches('/');
    if trimmed.is_empty() {
        return None;
    }
    let mut out = PathBuf::new();
    for component in Path::new(trimmed).components() {
        match component {
            Component::Normal(part) => out.push(part),
            _ => return None,
        }
    }
    out.to_str().map(|s| s.replace('\\', "/"))
}

/// Есть ли запись в манифесте (единственный источник правды о содержимом).
pub fn manifest_has_entry(manifest: &Value, entry_path: &str) -> bool {
    manifest
        .get("entries")
        .and_then(Value::as_array)
        .map(|entries| {
            entries.iter().any(|entry| {
                entry.get("path").and_then(Value::as_str) == Some(entry_path)
            })
        })
        .unwrap_or(false)
}

// ── чтение/запись ZIP ─────────────────────────────────────────────────────

/// Открывает `.mnd` как ZIP, пропуская 8-байтовый заголовок `MND_ZIP_`.
///
/// Голый zip (без заголовка) тоже принимается: так лежат архивы каталога.
fn open_zip(path: &Path) -> Result<zip::ZipArchive<BufReader<File>>, String> {
    let mut file = File::open(path).map_err(|e| format!("открытие архива: {e}"))?;
    let mut header = [0u8; 8];
    let read = file
        .read(&mut header)
        .map_err(|e| format!("чтение заголовка: {e}"))?;

    let start = if read == 8 && &header == HEADER_ZIP {
        8
    } else if read == 8 && (&header == HEADER_SEC || &header == HEADER_ENC2) {
        return Err("защищённый архив: потоковая раздача недоступна".into());
    } else {
        0
    };

    file.seek(SeekFrom::Start(start))
        .map_err(|e| format!("позиционирование архива: {e}"))?;
    zip::ZipArchive::new(BufReader::new(file)).map_err(|e| format!("архив не читается: {e}"))
}

/// Список записей архива: `(путь, размер, sha256 содержимого)`, кроме
/// служебных (`saves/`, `editor_session.json`).
fn collect_entries(mnd: &Path) -> Result<Vec<(String, u64, String)>, String> {
    let mut archive = open_zip(mnd)?;
    let mut out = Vec::new();
    let mut buf = vec![0u8; HASH_BUF];
    for index in 0..archive.len() {
        let mut entry = archive
            .by_index(index)
            .map_err(|e| format!("запись {index}: {e}"))?;
        if entry.is_dir() {
            continue;
        }
        let Some(name) = sanitize_rel(entry.name()) else {
            continue;
        };
        if is_excluded(&name) {
            continue;
        }
        let mut hasher = Sha256::new();
        loop {
            let read = entry
                .read(&mut buf)
                .map_err(|e| format!("чтение {name}: {e}"))?;
            if read == 0 {
                break;
            }
            hasher.update(&buf[..read]);
        }
        out.push((name, entry.size(), hex::encode(hasher.finalize())));
    }
    out.sort_by(|a, b| a.0.cmp(&b.0));
    Ok(out)
}

/// Хеш содержимого архива: стабильная сводка записей (путь+размер+sha256).
fn content_hash(entries: &[(String, u64, String)]) -> String {
    let mut hasher = Sha256::new();
    for (path, size, sha) in entries {
        hasher.update(path.as_bytes());
        hasher.update([0]);
        hasher.update(size.to_le_bytes());
        hasher.update(sha.as_bytes());
        hasher.update(b"\n");
    }
    hex::encode(hasher.finalize())
}

/// Собирает монолитный `nodes.json` из per-node раскладки
/// (`nodes/index.json` + `nodes/<id>.json`), как это делает экспортёр в
/// `mnd-core` для старых плееров и веб-версии.
fn per_node_document(archive: &mut zip::ZipArchive<BufReader<File>>) -> Option<Value> {
    let index: Value = {
        let mut entry = archive.by_name("nodes/index.json").ok()?;
        let mut text = String::new();
        entry.read_to_string(&mut text).ok()?;
        serde_json::from_str(&text).ok()?
    };
    let summaries = index.get("nodes")?.as_array()?;

    let mut nodes = Vec::with_capacity(summaries.len());
    for summary in summaries {
        let body = summary
            .get("id")
            .and_then(Value::as_str)
            .and_then(|id| {
                let mut entry = archive.by_name(&format!("nodes/{id}.json")).ok()?;
                let mut text = String::new();
                entry.read_to_string(&mut text).ok()?;
                serde_json::from_str::<Value>(&text).ok()
            });
        nodes.push(body.unwrap_or_else(|| summary.clone()));
    }

    let mut out = serde_json::Map::new();
    out.insert("nodes".to_string(), Value::Array(nodes));
    if let Some(groups) = index.get("groups") {
        out.insert("groups".to_string(), groups.clone());
    }
    if let Some(comments) = index.get("comments") {
        out.insert("comments".to_string(), comments.clone());
    }
    Some(Value::Object(out))
}

// ── сборка артефактов ─────────────────────────────────────────────────────

/// Разбирает архив и строит `manifest.json` + `boot.mnd`.
///
/// Идемпотентно и безопасно при гонке: оба файла пишутся во временный рядом
/// и переименовываются (atomic rename), содержимое детерминировано.
pub fn build_artifacts(quests_dir: &Path, quest_id: Uuid) -> Result<Value, String> {
    let mnd = mnd_path(quests_dir, quest_id);
    if !mnd.is_file() {
        return Err("архив квеста не найден".into());
    }

    let entries = collect_entries(&mnd)?;
    let per_node = entries.iter().any(|(path, _, _)| path == "nodes/index.json")
        && !entries.iter().any(|(path, _, _)| path == "nodes.json");

    let manifest = json!({
        "version": MANIFEST_VERSION,
        "questId": quest_id.to_string(),
        "contentHash": content_hash(&entries),
        "format": if per_node { "per-node" } else { "legacy" },
        "boot": BOOT_NAME,
        "entries": entries
            .iter()
            .map(|(path, size, sha)| json!({
                "path": path,
                "kind": kind_of(path),
                "size": size,
                "sha256": sha,
                "boot": is_boot_entry(path),
            }))
            .collect::<Vec<_>>(),
    });

    fs::create_dir_all(quests_dir).map_err(|e| format!("каталог артефактов: {e}"))?;
    // Артефакты пересобираются только когда изменился архив: распакованные
    // записи прошлой версии квеста больше не актуальны.
    let _ = fs::remove_dir_all(extracted_dir(quests_dir, quest_id));

    let manifest_file = manifest_path(quests_dir, quest_id);
    let manifest_tmp = temp_sibling(&manifest_file);
    let text = serde_json::to_vec(&manifest).map_err(|e| format!("манифест: {e}"))?;
    fs::write(&manifest_tmp, &text).map_err(|e| format!("запись манифеста: {e}"))?;
    fs::rename(&manifest_tmp, &manifest_file).map_err(|e| format!("публикация манифеста: {e}"))?;

    let boot_file = boot_path(quests_dir, quest_id);
    let boot_tmp = temp_sibling(&boot_file);
    // Монолит нод внутри архива: веб-плеер читает только `nodes.json`, а на
    // диске канонический файл импорта — `nodes/nodes.json`.
    let nodes_source = if entries.iter().any(|(path, _, _)| path == "nodes.json") {
        Some("nodes.json")
    } else if entries
        .iter()
        .any(|(path, _, _)| path == "nodes/nodes.json")
    {
        Some("nodes/nodes.json")
    } else {
        None
    };
    write_boot_bundle(&mnd, &boot_tmp, per_node, nodes_source)?;
    fs::rename(&boot_tmp, &boot_file).map_err(|e| format!("публикация boot: {e}"))?;

    Ok(manifest)
}

/// Пишет boot-архив: `MND_ZIP_` + zip только с текстовыми записями.
///
/// Монолит нод всегда выходит под именем `nodes.json`: для per-node квеста он
/// синтезируется из индекса и тел, для legacy — копируется из архива (в том
/// числе из канонического `nodes/nodes.json`). Веб-плеер читает только это имя.
fn write_boot_bundle(
    mnd: &Path,
    dest: &Path,
    per_node: bool,
    nodes_source: Option<&str>,
) -> Result<(), String> {
    let tmp_zip = temp_sibling(dest);
    {
        let mut archive = open_zip(mnd)?;
        let per_node_doc = if per_node {
            per_node_document(&mut archive)
        } else {
            None
        };

        let file = File::create(&tmp_zip).map_err(|e| format!("boot zip: {e}"))?;
        let mut zip = zip::ZipWriter::new(BufWriter::new(file));
        let options =
            zip::write::FileOptions::default().compression_method(zip::CompressionMethod::Deflated);

        let monolith: Vec<u8> = if per_node {
            let doc = per_node_doc.as_ref().ok_or_else(|| {
                "per-node квест: nodes/index.json не читается".to_string()
            })?;
            serde_json::to_vec(doc).map_err(|e| format!("nodes.json в boot: {e}"))?
        } else if let Some(name) = nodes_source {
            let mut entry = archive
                .by_name(name)
                .map_err(|e| format!("{name} в boot: {e}"))?;
            let mut bytes = Vec::new();
            entry
                .read_to_end(&mut bytes)
                .map_err(|e| format!("{name} в boot: {e}"))?;
            bytes
        } else {
            Vec::new()
        };
        if !monolith.is_empty() {
            zip.start_file::<_, ()>("nodes.json", options)
                .map_err(|e| format!("nodes.json в boot: {e}"))?;
            zip.write_all(&monolith)
                .map_err(|e| format!("nodes.json в boot: {e}"))?;
        }

        for index in 0..archive.len() {
            let mut entry = archive
                .by_index(index)
                .map_err(|e| format!("запись {index}: {e}"))?;
            if entry.is_dir() {
                continue;
            }
            let Some(name) = sanitize_rel(entry.name()) else {
                continue;
            };
            // Все файлы нод уже свернуты в один `nodes.json` выше.
            if name == "nodes.json" || name.starts_with("nodes/") {
                continue;
            }
            if !is_boot_entry(&name) || is_excluded(&name) {
                continue;
            }
            zip.start_file::<_, ()>(&name, options)
                .map_err(|e| format!("{name} в boot: {e}"))?;
            std::io::copy(&mut entry, &mut zip).map_err(|e| format!("{name} в boot: {e}"))?;
        }
        zip.finish().map_err(|e| format!("финализация boot: {e}"))?;
    }

    // Заголовок `MND_ZIP_` дописывается при копировании: смещения внутри zip
    // считаются от его начала и префикс их бы сдвинул.
    let boot_tmp = temp_sibling(dest);
    {
        let mut src = BufReader::new(File::open(&tmp_zip).map_err(|e| format!("boot zip: {e}"))?);
        let mut dst =
            BufWriter::new(File::create(&boot_tmp).map_err(|e| format!("boot: {e}"))?);
        dst.write_all(HEADER_ZIP).map_err(|e| format!("boot: {e}"))?;
        std::io::copy(&mut src, &mut dst).map_err(|e| format!("boot: {e}"))?;
        dst.flush().map_err(|e| format!("boot: {e}"))?;
    }
    fs::rename(&boot_tmp, dest).map_err(|e| format!("публикация boot: {e}"))?;
    let _ = fs::remove_file(&tmp_zip);
    Ok(())
}

/// Возвращает манифест, строя артефакты, если их нет или они старше архива.
pub fn load_or_build_manifest(quests_dir: &Path, quest_id: Uuid) -> Result<Value, String> {
    let mnd = mnd_path(quests_dir, quest_id);
    if !mnd.is_file() {
        return Err("архив квеста не найден".into());
    }
    let manifest_file = manifest_path(quests_dir, quest_id);
    let boot_file = boot_path(quests_dir, quest_id);
    if is_fresh(&manifest_file, &mnd)
        && is_fresh(&boot_file, &mnd)
        && let Ok(text) = fs::read_to_string(&manifest_file)
        && let Ok(value) = serde_json::from_str::<Value>(&text)
    {
        return Ok(value);
    }
    build_artifacts(quests_dir, quest_id)
}

fn is_fresh(artifact: &Path, source: &Path) -> bool {
    let Ok(artifact_meta) = fs::metadata(artifact) else {
        return false;
    };
    let Ok(source_meta) = fs::metadata(source) else {
        return false;
    };
    match (artifact_meta.modified(), source_meta.modified()) {
        // `>=`: артефакты пишутся сразу после архива и могут совпасть в mtime.
        (Ok(a), Ok(s)) => a >= s,
        _ => false,
    }
}

/// Материализует одну запись архива в `<id>.d/<path>` (при первом запросе).
pub fn ensure_entry(quests_dir: &Path, quest_id: Uuid, entry_path: &str) -> Result<PathBuf, String> {
    let Some(rel) = sanitize_rel(entry_path) else {
        return Err("недопустимый путь записи".into());
    };
    if is_excluded(&rel) {
        return Err("запись недоступна для выдачи".into());
    }
    let dest = extracted_dir(quests_dir, quest_id).join(&rel);
    let mnd = mnd_path(quests_dir, quest_id);
    // Запись годится, только если распакована из текущего архива: после
    // повторной публикации квеста старая копия не должна выдаваться.
    if dest.is_file() && is_fresh(&dest, &mnd) {
        return Ok(dest);
    }

    let mut archive = open_zip(&mnd)?;
    // Ищем по нормализованному имени: архивы с Windows-путями хранят
    // обратные слеши, а манифест и запросы используют прямые.
    let mut found = None;
    for index in 0..archive.len() {
        let name = archive
            .by_index(index)
            .map_err(|e| format!("запись {index}: {e}"))?
            .name()
            .to_string();
        if sanitize_rel(&name).as_deref() == Some(rel.as_str()) {
            found = Some(index);
            break;
        }
    }
    let Some(index) = found else {
        return Err(format!("запись не найдена: {rel}"));
    };
    let mut entry = archive
        .by_index(index)
        .map_err(|e| format!("запись {rel}: {e}"))?;
    if entry.is_dir() {
        return Err("запись — каталог".into());
    }

    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("каталог записи: {e}"))?;
    }
    let tmp = temp_sibling(&dest);
    {
        let mut out = BufWriter::new(File::create(&tmp).map_err(|e| format!("запись: {e}"))?);
        std::io::copy(&mut entry, &mut out).map_err(|e| format!("распаковка {rel}: {e}"))?;
        out.flush().map_err(|e| format!("распаковка {rel}: {e}"))?;
    }
    // Гонка двух параллельных запросов одной записи безобидна: temp+rename
    // идемпотентны, побеждает последний.
    fs::rename(&tmp, &dest).map_err(|e| format!("публикация {rel}: {e}"))?;
    Ok(dest)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "mnd_stream_test_{tag}_{}_{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// Собирает `.mnd` (`MND_ZIP_` + zip) из пар (путь, содержимое).
    fn write_mnd(dest: &Path, files: &[(&str, &[u8])]) {
        let tmp = temp_sibling(dest);
        {
            let file = File::create(&tmp).unwrap();
            let mut zip = zip::ZipWriter::new(BufWriter::new(file));
            let options = zip::write::FileOptions::default()
                .compression_method(zip::CompressionMethod::Deflated);
            for (name, bytes) in files {
                zip.start_file::<_, ()>(*name, options).unwrap();
                zip.write_all(bytes).unwrap();
            }
            zip.finish().unwrap();
        }
        let mut src = BufReader::new(File::open(&tmp).unwrap());
        let mut dst = BufWriter::new(File::create(dest).unwrap());
        dst.write_all(HEADER_ZIP).unwrap();
        std::io::copy(&mut src, &mut dst).unwrap();
        dst.flush().unwrap();
        let _ = fs::remove_file(&tmp);
    }

    fn read_boot(boot: &Path) -> Vec<(String, Vec<u8>)> {
        let raw = fs::read(boot).unwrap();
        assert_eq!(&raw[..8], HEADER_ZIP);
        let mut archive =
            zip::ZipArchive::new(std::io::Cursor::new(raw[8..].to_vec())).unwrap();
        (0..archive.len())
            .map(|i| {
                let mut entry = archive.by_index(i).unwrap();
                let name = entry.name().to_string();
                let mut bytes = Vec::new();
                entry.read_to_end(&mut bytes).unwrap();
                (name, bytes)
            })
            .collect()
    }

    #[test]
    fn sanitize_rejects_traversal() {
        assert_eq!(sanitize_rel("res/images/a.png").as_deref(), Some("res/images/a.png"));
        assert_eq!(sanitize_rel("/res/a.png").as_deref(), Some("res/a.png"));
        assert!(sanitize_rel("../secrets").is_none());
        assert!(sanitize_rel("res/../../x").is_none());
        assert!(sanitize_rel("").is_none());
    }

    #[test]
    fn boot_classification() {
        assert!(is_boot_entry("config.json"));
        assert!(is_boot_entry("nodes.json"));
        assert!(is_boot_entry("scripts/abc.json"));
        assert!(is_boot_entry("res/fonts/x.ttf"));
        assert!(is_boot_entry("res/templates.json"));
        assert!(!is_boot_entry("res/images/a.png"));
        assert!(!is_boot_entry("nodes/index.json"));
        assert!(is_excluded("saves/1.json"));
        assert!(is_excluded("editor_session.json"));
    }

    #[test]
    fn legacy_archive_builds_manifest_and_boot() {
        let dir = temp_dir("legacy");
        let id = Uuid::new_v4();
        let mnd = mnd_path(&dir, id);
        write_mnd(
            &mnd,
            &[
                ("config.json", br#"{"id":"q","startNodeId":"start"}"#),
                ("nodes.json", br#"{"nodes":[{"id":"start"}]}"#),
                ("res/templates.json", b"[]"),
                ("scripts/s1.json", br#"{"blocks":[]}"#),
                ("res/images/bg.png", b"PNGDATA"),
                ("res/audio/theme.mp3", b"MP3DATA"),
                ("saves/1.json", b"{}"),
            ],
        );

        let manifest = build_artifacts(&dir, id).unwrap();
        assert_eq!(manifest["version"], MANIFEST_VERSION);
        assert_eq!(manifest["format"], "legacy");

        let paths: Vec<&str> = manifest["entries"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| e["path"].as_str().unwrap())
            .collect();
        assert!(paths.contains(&"config.json"));
        assert!(paths.contains(&"res/images/bg.png"));
        // Локальные сейвы наружу не отдаём.
        assert!(!paths.contains(&"saves/1.json"));

        let image = manifest["entries"]
            .as_array()
            .unwrap()
            .iter()
            .find(|e| e["path"] == "res/images/bg.png")
            .unwrap();
        assert_eq!(image["kind"], "image");
        assert_eq!(image["boot"], false);
        assert_eq!(image["size"], 7);

        let boot = read_boot(&boot_path(&dir, id));
        let boot_names: Vec<&str> = boot.iter().map(|(n, _)| n.as_str()).collect();
        assert!(boot_names.contains(&"config.json"));
        assert!(boot_names.contains(&"nodes.json"));
        assert!(boot_names.contains(&"scripts/s1.json"));
        assert!(!boot_names.contains(&"res/images/bg.png"));
        assert!(!boot_names.contains(&"res/audio/theme.mp3"));

        // Повторный вызов переиспользует готовый манифест.
        let again = load_or_build_manifest(&dir, id).unwrap();
        assert_eq!(again["contentHash"], manifest["contentHash"]);
    }

    #[test]
    fn per_node_archive_synthesizes_monolith_in_boot() {
        let dir = temp_dir("pernode");
        let id = Uuid::new_v4();
        let mnd = mnd_path(&dir, id);
        write_mnd(
            &mnd,
            &[
                ("config.json", br#"{"id":"q"}"#),
                ("res/templates.json", b"[]"),
                (
                    "nodes/index.json",
                    br#"{"format_version":2,"nodes":[{"id":"a","title":"A"},{"id":"b","title":"B"}],"groups":[]}"#,
                ),
                ("nodes/a.json", br#"{"id":"a","content":{"items":[]}}"#),
                ("nodes/b.json", br#"{"id":"b","content":{"items":[]}}"#),
                ("res/images/a.png", b"IMG"),
            ],
        );

        let manifest = build_artifacts(&dir, id).unwrap();
        assert_eq!(manifest["format"], "per-node");

        let boot = read_boot(&boot_path(&dir, id));
        let names: Vec<&str> = boot.iter().map(|(n, _)| n.as_str()).collect();
        assert!(names.contains(&"nodes.json"), "boot должен нести монолит");
        assert!(!names.contains(&"nodes/index.json"));
        assert!(!names.contains(&"nodes/a.json"));

        let nodes_bytes = boot
            .iter()
            .find(|(n, _)| n == "nodes.json")
            .map(|(_, b)| b.clone())
            .unwrap();
        let doc: Value = serde_json::from_slice(&nodes_bytes).unwrap();
        let ids: Vec<&str> = doc["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .map(|n| n["id"].as_str().unwrap())
            .collect();
        assert_eq!(ids, vec!["a", "b"]);
    }

    #[test]
    fn entry_materialized_on_demand_and_traversal_blocked() {
        let dir = temp_dir("entry");
        let id = Uuid::new_v4();
        let mnd = mnd_path(&dir, id);
        write_mnd(
            &mnd,
            &[
                ("config.json", b"{}"),
                ("res/images/bg.png", b"PNGDATA"),
            ],
        );
        build_artifacts(&dir, id).unwrap();

        let path = ensure_entry(&dir, id, "res/images/bg.png").unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"PNGDATA");
        // Второй вызов берёт уже распакованное.
        let again = ensure_entry(&dir, id, "res/images/bg.png").unwrap();
        assert_eq!(again, path);

        assert!(ensure_entry(&dir, id, "../../etc/passwd").is_err());
        assert!(ensure_entry(&dir, id, "res/missing.png").is_err());
    }

    #[test]
    fn boot_canonicalizes_nested_nodes_monolith() {
        let dir = temp_dir("nested_nodes");
        let id = Uuid::new_v4();
        let mnd = mnd_path(&dir, id);
        write_mnd(
            &mnd,
            &[
                ("config.json", b"{}"),
                ("nodes/nodes.json", br#"{"nodes":[{"id":"solo"}]}"#),
                ("res/images/bg.png", b"PNGDATA"),
            ],
        );

        let manifest = build_artifacts(&dir, id).unwrap();
        assert_eq!(manifest["format"], "legacy");

        let boot = read_boot(&boot_path(&dir, id));
        let nodes = boot
            .iter()
            .find(|(n, _)| n == "nodes.json")
            .expect("boot должен нести монолит под каноническим именем");
        assert_eq!(nodes.1, br#"{"nodes":[{"id":"solo"}]}"#);
        assert!(!boot.iter().any(|(n, _)| n == "nodes/nodes.json"));
        assert!(!boot.iter().any(|(n, _)| n == "res/images/bg.png"));
    }

    #[test]
    fn entries_with_windows_separators_are_found() {
        let dir = temp_dir("winpaths");
        let id = Uuid::new_v4();
        let mnd = mnd_path(&dir, id);
        write_mnd(
            &mnd,
            &[
                ("config.json", b"{}"),
                (r"res\images\bg.png", b"PNGDATA"),
            ],
        );

        let manifest = build_artifacts(&dir, id).unwrap();
        let paths: Vec<&str> = manifest["entries"]
            .as_array()
            .unwrap()
            .iter()
            .map(|e| e["path"].as_str().unwrap())
            .collect();
        assert!(paths.contains(&"res/images/bg.png"));

        let path = ensure_entry(&dir, id, "res/images/bg.png").unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"PNGDATA");
    }

    #[test]
    fn republished_archive_invalidates_extracted_entries() {
        let dir = temp_dir("republish");
        let id = Uuid::new_v4();
        let mnd = mnd_path(&dir, id);
        write_mnd(&mnd, &[("res/images/bg.png", b"OLD")]);
        build_artifacts(&dir, id).unwrap();
        let path = ensure_entry(&dir, id, "res/images/bg.png").unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"OLD");

        // Повторная публикация сдвигает mtime архива вперёд: распакованная
        // копия обязана перестать считаться актуальной.
        write_mnd(&mnd, &[("res/images/bg.png", b"NEWBYTES")]);
        let ahead = SystemTime::now() + std::time::Duration::from_secs(1);
        File::options()
            .write(true)
            .open(&mnd)
            .unwrap()
            .set_times(fs::FileTimes::new().set_modified(ahead))
            .unwrap();

        let path = ensure_entry(&dir, id, "res/images/bg.png").unwrap();
        assert_eq!(fs::read(&path).unwrap(), b"NEWBYTES");
    }

    #[test]
    fn encrypted_archive_is_refused() {
        let dir = temp_dir("enc");
        let id = Uuid::new_v4();
        let mnd = mnd_path(&dir, id);
        let mut bytes = HEADER_ENC2.to_vec();
        bytes.extend_from_slice(&[0u8; 64]);
        fs::write(&mnd, bytes).unwrap();
        assert!(build_artifacts(&dir, id).is_err());
    }
}
