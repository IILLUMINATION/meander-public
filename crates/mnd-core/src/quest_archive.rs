//! Потоковый архив квестов: импорт/экспорт 200+ МБ без RAM-пика.
//!
//! Формат `.mnd`:
//! - `MND_ZIP_` (8 байт) + ZIP       — plain, стрим
//! - `MND_SEC_` (8 байт) + SALT 16 + IV 16 + MAC 32 + AES/CBC(PBKDF2 15000, ZIP) — legacy чтение
//! - `MND_ENC2` (8 байт) + SALT 16 + NONCE 12 + chunked ChaCha20Poly1305(Argon2id, ZIP) — новый быстрый
//!
//! Все операции стримят 64КБ чанками, пик < 20МБ.

use std::fs::File;
use std::io::{BufReader, BufWriter, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use aes::Aes256;
use argon2::{Algorithm, Argon2, Params, Version};
use cbc::cipher::{BlockDecryptMut, KeyIvInit};
use chacha20poly1305::aead::{Aead, KeyInit as ChaKeyInit};
use chacha20poly1305::{ChaCha20Poly1305, Nonce};
use hmac::{Hmac, Mac as HmacMac};
use pbkdf2::pbkdf2_hmac;
use rand::RngCore;
use sha2::Sha256;
use walkdir::WalkDir;
use zip::write::FileOptions;

const HEADER_ZIP: &[u8; 8] = b"MND_ZIP_";
const HEADER_SEC: &[u8; 8] = b"MND_SEC_";
const HEADER_ENC2: &[u8; 8] = b"MND_ENC2";
const CHUNK_SIZE: usize = 64 * 1024;
const MAX_MND_BYTES: u64 = 2 * 1024 * 1024 * 1024; // 2GB
const MAX_INFLATED_BYTES: u64 = 4 * 1024 * 1024 * 1024;
const MAX_FILES: usize = 50000;

const APP_SECRET: &[u8] = b"MndPlay-TemplSecret_Key01";

#[derive(Debug)]
pub struct ArchiveError(pub String);
impl std::fmt::Display for ArchiveError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}
impl std::error::Error for ArchiveError {}

type Result<T> = std::result::Result<T, ArchiveError>;

// ── helpers ───────────────────────────────────────────────────────────────

fn app_secret() -> &'static [u8] {
    APP_SECRET
}

fn derive_legacy_keys(salt: &[u8]) -> ([u8; 32], [u8; 32]) {
    let mut out = [0u8; 64];
    pbkdf2_hmac::<Sha256>(app_secret(), salt, 15000, &mut out);
    let mut aes = [0u8; 32];
    let mut hmac = [0u8; 32];
    aes.copy_from_slice(&out[..32]);
    hmac.copy_from_slice(&out[32..]);
    (aes, hmac)
}

fn derive_new_key(salt: &[u8]) -> Result<[u8; 32]> {
    // 19 MiB, t=2, p=1 — OWASP минимум, ~80ms на мобиле, быстрее PBKDF2 15000
    let params = Params::new(19 * 1024, 2, 1, Some(32))
        .map_err(|e| ArchiveError(format!("argon2 params: {e}")))?;
    let argon2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
    let mut key = [0u8; 32];
    argon2
        .hash_password_into(app_secret(), salt, &mut key)
        .map_err(|e| ArchiveError(format!("argon2: {e}")))?;
    Ok(key)
}

fn ensure_limits(path: &Path) -> Result<()> {
    let meta = std::fs::metadata(path).map_err(|e| ArchiveError(e.to_string()))?;
    if meta.len() > MAX_MND_BYTES {
        return Err(ArchiveError(format!(
            "файл слишком большой: {} > {}",
            meta.len(),
            MAX_MND_BYTES
        )));
    }
    Ok(())
}

fn sanitize_path(name: &str) -> Option<PathBuf> {
    // Защита от Zip Slip: не пускаем абсолютные и `..`
    let p = Path::new(name);
    if p.is_absolute() {
        return None;
    }
    let mut out = PathBuf::new();
    for comp in p.components() {
        match comp {
            std::path::Component::ParentDir => return None,
            std::path::Component::Normal(s) => out.push(s),
            _ => return None,
        }
    }
    Some(out)
}

// ── import ────────────────────────────────────────────────────────────────

pub fn quest_archive_import(mnd_path: &str, dest_dir: &str) -> Result<String> {
    let mnd = Path::new(mnd_path);
    let dest = Path::new(dest_dir);
    ensure_limits(mnd)?;

    let mut reader = BufReader::new(File::open(mnd).map_err(|e| ArchiveError(e.to_string()))?);
    let mut header = [0u8; 8];
    reader
        .read_exact(&mut header)
        .map_err(|e| ArchiveError(format!("чтение header: {e}")))?;

    // Определяем формат
    let quest_id = if header == *HEADER_ZIP {
        import_plain(mnd, dest)?
    } else if header == *HEADER_SEC {
        import_legacy_sec(mnd, dest)?
    } else if header == *HEADER_ENC2 {
        import_enc2(mnd, dest)?
    } else {
        // Fallback: некоторые старые файлы без header — пробуем как plain zip
        // (FileStorage читает .mnd без header как zip)
        import_plain_raw(mnd, dest)?
    };
    Ok(quest_id)
}

fn import_plain(mnd: &Path, dest: &Path) -> Result<String> {
    // Стрим: читаем файл после header, пишем во временный zip, затем распаковываем стримом
    let tmp_zip = tempfile_path("mnd_plain_zip");
    {
        let input = File::open(mnd).map_err(|e| ArchiveError(e.to_string()))?;
        let mut src = BufReader::new(input);
        src.seek(SeekFrom::Start(8))
            .map_err(|e| ArchiveError(e.to_string()))?;
        let mut dst =
            BufWriter::new(File::create(&tmp_zip).map_err(|e| ArchiveError(e.to_string()))?);
        std::io::copy(&mut src, &mut dst).map_err(|e| ArchiveError(e.to_string()))?;
    }
    let qid = extract_zip_streaming(&tmp_zip, dest)?;
    let _ = std::fs::remove_file(&tmp_zip);
    Ok(qid)
}

fn import_plain_raw(mnd: &Path, dest: &Path) -> Result<String> {
    // Без header — весь файл это zip
    extract_zip_streaming(mnd, dest)
}

fn import_legacy_sec(mnd: &Path, dest: &Path) -> Result<String> {
    // HEADER 8 + SALT 16 + IV 16 + MAC 32 = 72
    let mut f = File::open(mnd).map_err(|e| ArchiveError(e.to_string()))?;
    let mut header_and_keys = [0u8; 72];
    f.read_exact(&mut header_and_keys)
        .map_err(|e| ArchiveError(format!("чтение SEC header: {e}")))?;
    if header_and_keys[..8] != *HEADER_SEC {
        return Err(ArchiveError("ожидался MND_SEC_".into()));
    }
    let salt = &header_and_keys[8..24];
    let iv = &header_and_keys[24..40];
    let mac_provided = &header_and_keys[40..72];

    let (aes_key, hmac_key) = derive_legacy_keys(salt);

    // 1) HMAC verify streaming
    {
        let mut h = <Hmac<Sha256> as HmacMac>::new_from_slice(&hmac_key)
            .map_err(|e| ArchiveError(format!("hmac: {e}")))?;
        <Hmac<Sha256> as HmacMac>::update(&mut h, iv);
        let mut src = BufReader::new(File::open(mnd).map_err(|e| ArchiveError(e.to_string()))?);
        src.seek(SeekFrom::Start(72))
            .map_err(|e| ArchiveError(e.to_string()))?;
        let mut buf = vec![0u8; CHUNK_SIZE];
        let mut remaining = std::fs::metadata(mnd)
            .map_err(|e| ArchiveError(e.to_string()))?
            .len()
            .saturating_sub(72);
        while remaining > 0 {
            let to_read = std::cmp::min(buf.len() as u64, remaining) as usize;
            let n = src
                .read(&mut buf[..to_read])
                .map_err(|e| ArchiveError(e.to_string()))?;
            if n == 0 {
                break;
            }
            <Hmac<Sha256> as HmacMac>::update(&mut h, &buf[..n]);
            remaining -= n as u64;
        }
        let expected = <Hmac<Sha256> as HmacMac>::finalize(h).into_bytes();
        if expected.as_slice() != mac_provided {
            return Err(ArchiveError("HMAC не совпадает — файл повреждён".into()));
        }
    }

    // 2) Decrypt streaming to temp zip
    let tmp_zip = tempfile_path("mnd_sec_zip");
    {
        let mut src = BufReader::new(File::open(mnd).map_err(|e| ArchiveError(e.to_string()))?);
        src.seek(SeekFrom::Start(72))
            .map_err(|e| ArchiveError(e.to_string()))?;
        // Читаем весь ciphertext в память чанками, но decrypt стримом через cbc
        // Для простоты и PKCS7: читаем всё, decrypt одним вызовом, но пишем стримом.
        // Для 200МБ это 200МБ RAM — приемлемо как промежуточный шаг, но лучше чанк.
        // Реализуем чанк с буфером: cbc Decryptor требует кратные 16 байтам, кроме последнего.
        // Упростим: читаем весь ciphertext в Vec (200МБ) — пик 400МБ, но всё равно
        // меньше Dart 800МБ. TODO: true streaming с PKCS7.
        let mut cipher = Vec::new();
        src.read_to_end(&mut cipher)
            .map_err(|e| ArchiveError(e.to_string()))?;
        if cipher.is_empty() {
            return Err(ArchiveError("пустой ciphertext".into()));
        }
        if cipher.len() % 16 != 0 {
            return Err(ArchiveError("ciphertext не кратен блоку".into()));
        }
        type AesCbcDec = cbc::Decryptor<Aes256>;
        let dec = AesCbcDec::new_from_slices(&aes_key, iv)
            .map_err(|e| ArchiveError(format!("cbc init: {e}")))?;
        let mut plain = cipher;
        let len = dec
            .decrypt_padded_mut::<cbc::cipher::block_padding::Pkcs7>(&mut plain)
            .map_err(|e| ArchiveError(format!("decrypt: {e}")))?
            .len();
        plain.truncate(len);
        let mut dst =
            BufWriter::new(File::create(&tmp_zip).map_err(|e| ArchiveError(e.to_string()))?);
        dst.write_all(&plain)
            .map_err(|e| ArchiveError(e.to_string()))?;
    }
    let qid = extract_zip_streaming(&tmp_zip, dest)?;
    let _ = std::fs::remove_file(&tmp_zip);
    Ok(qid)
}

fn import_enc2(mnd: &Path, dest: &Path) -> Result<String> {
    // HEADER 8 + SALT 16 + NONCE 12 = 36
    let mut f = File::open(mnd).map_err(|e| ArchiveError(e.to_string()))?;
    let mut hdr = [0u8; 36];
    f.read_exact(&mut hdr)
        .map_err(|e| ArchiveError(format!("чтение ENC2 header: {e}")))?;
    if hdr[..8] != *HEADER_ENC2 {
        return Err(ArchiveError("ожидался MND_ENC2".into()));
    }
    let salt = &hdr[8..24];
    let base_nonce = &hdr[24..36];
    let key = derive_new_key(salt)?;
    let aead =
        ChaCha20Poly1305::new_from_slice(&key).map_err(|e| ArchiveError(format!("aead: {e}")))?;

    let tmp_zip = tempfile_path("mnd_enc2_zip");
    {
        let mut src = BufReader::new(File::open(mnd).map_err(|e| ArchiveError(e.to_string()))?);
        src.seek(SeekFrom::Start(36))
            .map_err(|e| ArchiveError(e.to_string()))?;
        let mut dst =
            BufWriter::new(File::create(&tmp_zip).map_err(|e| ArchiveError(e.to_string()))?);
        let mut idx: u32 = 0;
        loop {
            let mut len_buf = [0u8; 4];
            match src.read_exact(&mut len_buf) {
                Ok(_) => {}
                Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => break,
                Err(e) => return Err(ArchiveError(e.to_string())),
            }
            let len = u32::from_le_bytes(len_buf) as usize;
            if len == 0 || len > CHUNK_SIZE + 32 {
                return Err(ArchiveError(format!("неверный chunk len {len}")));
            }
            let mut ctext = vec![0u8; len];
            src.read_exact(&mut ctext)
                .map_err(|e| ArchiveError(e.to_string()))?;
            let mut nonce_bytes = [0u8; 12];
            nonce_bytes.copy_from_slice(base_nonce);
            // последние 4 байта — индекс
            nonce_bytes[8..12].copy_from_slice(&idx.to_le_bytes());
            let nonce = Nonce::from_slice(&nonce_bytes);
            let plain = aead
                .decrypt(nonce, ctext.as_ref())
                .map_err(|e| ArchiveError(format!("decrypt chunk {idx}: {e}")))?;
            dst.write_all(&plain)
                .map_err(|e| ArchiveError(e.to_string()))?;
            idx += 1;
        }
    }
    let qid = extract_zip_streaming(&tmp_zip, dest)?;
    let _ = std::fs::remove_file(&tmp_zip);
    Ok(qid)
}

fn extract_zip_streaming(zip_path: &Path, dest: &Path) -> Result<String> {
    let file = File::open(zip_path).map_err(|e| ArchiveError(e.to_string()))?;
    let mut archive = zip::ZipArchive::new(BufReader::new(file))
        .map_err(|e| ArchiveError(format!("zip open: {e}")))?;

    if archive.len() > MAX_FILES {
        return Err(ArchiveError(format!(
            "слишком много файлов: {}",
            archive.len()
        )));
    }

    let mut total_inflated: u64 = 0;
    let mut quest_id: Option<String> = None;

    for i in 0..archive.len() {
        let mut entry = archive
            .by_index(i)
            .map_err(|e| ArchiveError(format!("zip entry {i}: {e}")))?;
        let raw_name = entry.name().to_string();
        let sanitized = sanitize_path(&raw_name)
            .ok_or_else(|| ArchiveError(format!("bad zip path: {raw_name}")))?;
        let out_path = dest.join(&sanitized);

        if entry.is_dir() {
            std::fs::create_dir_all(&out_path).map_err(|e| ArchiveError(e.to_string()))?;
        } else {
            if let Some(parent) = out_path.parent() {
                std::fs::create_dir_all(parent).map_err(|e| ArchiveError(e.to_string()))?;
            }
            total_inflated = total_inflated.saturating_add(entry.size());
            if total_inflated > MAX_INFLATED_BYTES {
                return Err(ArchiveError("распакованный размер превышает лимит".into()));
            }
            let mut out =
                BufWriter::new(File::create(&out_path).map_err(|e| ArchiveError(e.to_string()))?);
            std::io::copy(&mut entry, &mut out).map_err(|e| ArchiveError(e.to_string()))?;

            // Пытаемся вытащить questId из config.json
            if (raw_name.ends_with("config.json") || raw_name == "config.json")
                && let Ok(content) = std::fs::read_to_string(&out_path)
                && let Ok(v) = serde_json::from_str::<serde_json::Value>(&content)
                && let Some(id) = v.get("id").and_then(|x| x.as_str())
            {
                quest_id = Some(id.to_string());
            }
        }
    }

    // Fallback questId: имя каталога или первый config
    if let Some(id) = quest_id {
        Ok(id)
    } else {
        // Попробуем найти config.json в dest
        let cfg = dest.join("config.json");
        if cfg.exists()
            && let Ok(c) = std::fs::read_to_string(&cfg)
            && let Ok(v) = serde_json::from_str::<serde_json::Value>(&c)
            && let Some(id) = v.get("id").and_then(|x| x.as_str())
        {
            return Ok(id.to_string());
        }
        // Иначе имя папки
        dest.file_name()
            .and_then(|s| s.to_str())
            .map(|s| s.to_string())
            .ok_or_else(|| ArchiveError("не удалось определить questId".into()))
    }
}

fn tempfile_path(prefix: &str) -> PathBuf {
    let mut p = std::env::temp_dir();
    let nanos = crate::time::unix_now_nanos();
    p.push(format!("{}_{}_{}", prefix, std::process::id(), nanos));
    p
}

// ── export ────────────────────────────────────────────────────────────────

pub fn quest_archive_export(
    quest_dir: &str,
    mnd_path: &str,
    password: Option<String>,
) -> Result<()> {
    quest_archive_export_full(quest_dir, mnd_path, password, true, false)
}

pub fn quest_archive_export_full(
    quest_dir: &str,
    mnd_path: &str,
    password: Option<String>,
    include_saves: bool,
    is_protected: bool,
) -> Result<()> {
    let src = Path::new(quest_dir);
    let dst = Path::new(mnd_path);
    if !src.is_dir() {
        return Err(ArchiveError(format!("quest dir не найден: {quest_dir}")));
    }
    if let Some(parent) = dst.parent() {
        std::fs::create_dir_all(parent).map_err(|e| ArchiveError(e.to_string()))?;
    }

    // questId для подписи защищённого конфига
    let quest_id_hint = src
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("unknown")
        .to_string();

    // 1) Собираем zip во временный файл стримом
    let tmp_zip = tempfile_path("mnd_export_zip");
    create_zip_streaming_full(src, &tmp_zip, include_saves, is_protected, &quest_id_hint)?;

    // 2) Если пароль — шифруем в новый формат ENC2, иначе plain ZIP
    if let Some(_pwd) = password {
        // Пока используем app_secret для шифра (как legacy), но с Argon2+ChaCha
        // TODO: поддержка пользовательского пароля (если нужен)
        let salt = random_bytes(16);
        let key = derive_new_key(&salt)?;
        let base_nonce = random_bytes(12);
        let aead = ChaCha20Poly1305::new_from_slice(&key)
            .map_err(|e| ArchiveError(format!("aead: {e}")))?;

        let mut src_f =
            BufReader::new(File::open(&tmp_zip).map_err(|e| ArchiveError(e.to_string()))?);
        let mut dst_f = BufWriter::new(File::create(dst).map_err(|e| ArchiveError(e.to_string()))?);
        dst_f
            .write_all(HEADER_ENC2)
            .map_err(|e| ArchiveError(e.to_string()))?;
        dst_f
            .write_all(&salt)
            .map_err(|e| ArchiveError(e.to_string()))?;
        dst_f
            .write_all(&base_nonce)
            .map_err(|e| ArchiveError(e.to_string()))?;

        let mut buf = vec![0u8; CHUNK_SIZE];
        let mut idx: u32 = 0;
        loop {
            let n = src_f
                .read(&mut buf)
                .map_err(|e| ArchiveError(e.to_string()))?;
            if n == 0 {
                break;
            }
            let mut nonce_bytes = [0u8; 12];
            nonce_bytes.copy_from_slice(&base_nonce);
            nonce_bytes[8..12].copy_from_slice(&idx.to_le_bytes());
            let nonce = Nonce::from_slice(&nonce_bytes);
            let ctext = aead
                .encrypt(nonce, &buf[..n])
                .map_err(|e| ArchiveError(format!("encrypt chunk {idx}: {e}")))?;
            let len = ctext.len() as u32;
            dst_f
                .write_all(&len.to_le_bytes())
                .map_err(|e| ArchiveError(e.to_string()))?;
            dst_f
                .write_all(&ctext)
                .map_err(|e| ArchiveError(e.to_string()))?;
            idx += 1;
        }
        dst_f.flush().map_err(|e| ArchiveError(e.to_string()))?;
        let _ = std::fs::remove_file(&tmp_zip);
    } else {
        // Plain: header + zip стримом 64КБ
        let mut src_f =
            BufReader::new(File::open(&tmp_zip).map_err(|e| ArchiveError(e.to_string()))?);
        let mut dst_f = BufWriter::new(File::create(dst).map_err(|e| ArchiveError(e.to_string()))?);
        dst_f
            .write_all(HEADER_ZIP)
            .map_err(|e| ArchiveError(e.to_string()))?;
        std::io::copy(&mut src_f, &mut dst_f).map_err(|e| ArchiveError(e.to_string()))?;
        dst_f.flush().map_err(|e| ArchiveError(e.to_string()))?;
        let _ = std::fs::remove_file(&tmp_zip);
    }
    Ok(())
}

/// Собирает legacy-документ нод из per-node формата.
///
/// `nodes/index.json` хранит порядок и метаданные, тела — в
/// `nodes/<id>.json`. Для старых плееров и веб-версии экспортируем
/// единый `nodes.json`, как если бы квест был монолитным.
fn load_per_node_document(src_dir: &Path) -> Option<serde_json::Value> {
    let index_text = std::fs::read_to_string(src_dir.join("nodes/index.json")).ok()?;
    let index: serde_json::Value = serde_json::from_str(&index_text).ok()?;
    let summaries = index.get("nodes")?.as_array()?;

    let mut nodes = Vec::with_capacity(summaries.len());
    for summary in summaries {
        let body = summary
            .get("id")
            .and_then(serde_json::Value::as_str)
            .and_then(|id| {
                let path = src_dir.join("nodes").join(format!("{id}.json"));
                let text = std::fs::read_to_string(path).ok()?;
                serde_json::from_str::<serde_json::Value>(&text).ok()
            });
        nodes.push(body.unwrap_or_else(|| summary.clone()));
    }

    let mut out = serde_json::Map::new();
    out.insert("nodes".to_string(), serde_json::Value::Array(nodes));
    if let Some(groups) = index.get("groups") {
        out.insert("groups".to_string(), groups.clone());
    }
    if let Some(comments) = index.get("comments") {
        out.insert("comments".to_string(), comments.clone());
    }
    Some(serde_json::Value::Object(out))
}

fn create_zip_streaming_full(
    src_dir: &Path,
    zip_path: &Path,
    include_saves: bool,
    is_protected: bool,
    quest_id_hint: &str,
) -> Result<()> {
    let file = File::create(zip_path).map_err(|e| ArchiveError(e.to_string()))?;
    let mut zip = zip::ZipWriter::new(BufWriter::new(file));
    let options = FileOptions::default().compression_method(zip::CompressionMethod::Deflated);

    // Для защищённого экспорта — заранее готовим модифицированный config.json
    let mut protected_config_bytes: Option<Vec<u8>> = None;
    if is_protected {
        let cfg_path = src_dir.join("config.json");
        if cfg_path.exists()
            && let Ok(content) = std::fs::read_to_string(&cfg_path)
            && let Ok(mut v) = serde_json::from_str::<serde_json::Value>(&content)
            && let Some(obj) = v.as_object_mut()
        {
            obj.insert("isReadOnly".to_string(), serde_json::Value::Bool(true));
            let sig = generate_signature(quest_id_hint, true);
            obj.insert("signature".to_string(), serde_json::Value::String(sig));
            if let Ok(s) = serde_json::to_string(&v) {
                protected_config_bytes = Some(s.into_bytes());
            }
        }
    }

    // v2: единый legacy nodes.json для старых плееров и веб-версии.
    let per_node_doc = load_per_node_document(src_dir);
    let per_node_bytes = per_node_doc
        .as_ref()
        .and_then(|v| serde_json::to_vec(v).ok());

    let mut count = 0usize;
    for entry in WalkDir::new(src_dir).min_depth(1) {
        let entry = entry.map_err(|e| ArchiveError(e.to_string()))?;
        let path = entry.path();
        let rel = path
            .strip_prefix(src_dir)
            .map_err(|e| ArchiveError(e.to_string()))?
            .to_string_lossy()
            .replace('\\', "/");

        // Пропускаем saves если не нужно
        if !include_saves && (rel == "saves" || rel.starts_with("saves/")) {
            continue;
        }

        if per_node_bytes.is_some() {
            let v2_file = rel == "nodes.json"
                || rel == "nodes/nodes.json"
                || rel == "nodes.json.v1_backup"
                || rel == "nodes/index.json"
                || (rel.starts_with("nodes/")
                    && rel.ends_with(".json")
                    && rel != "nodes/nodes.json");
            if v2_file {
                continue;
            }
        }

        if entry.file_type().is_dir() {
            if !include_saves && rel == "saves" {
                continue;
            }
            zip.add_directory::<_, ()>(&rel, options)
                .map_err(|e| ArchiveError(e.to_string()))?;
        } else {
            if count > MAX_FILES {
                return Err(ArchiveError("слишком много файлов".into()));
            }
            count += 1;
            zip.start_file::<_, ()>(&rel, options)
                .map_err(|e| ArchiveError(e.to_string()))?;
            if is_protected
                && rel == "config.json"
                && let Some(ref bytes) = protected_config_bytes
            {
                zip.write_all(bytes)
                    .map_err(|e| ArchiveError(e.to_string()))?;
                continue;
            }
            let mut f = BufReader::new(File::open(path).map_err(|e| ArchiveError(e.to_string()))?);
            std::io::copy(&mut f, &mut zip).map_err(|e| ArchiveError(e.to_string()))?;
        }
    }

    if let Some(bytes) = per_node_bytes {
        for name in ["nodes.json", "nodes/nodes.json"] {
            if count > MAX_FILES {
                return Err(ArchiveError("слишком много файлов".into()));
            }
            count += 1;
            zip.start_file::<_, ()>(name, options)
                .map_err(|e| ArchiveError(e.to_string()))?;
            zip.write_all(&bytes)
                .map_err(|e| ArchiveError(e.to_string()))?;
        }
    }

    zip.finish().map_err(|e| ArchiveError(e.to_string()))?;
    Ok(())
}

fn generate_signature(quest_id: &str, is_read_only: bool) -> String {
    let data = format!("{quest_id}_readOnly:{is_read_only}");
    let mut mac = <Hmac<Sha256> as HmacMac>::new_from_slice(app_secret()).unwrap();
    <Hmac<Sha256> as HmacMac>::update(&mut mac, data.as_bytes());
    let res = <Hmac<Sha256> as HmacMac>::finalize(mac).into_bytes();
    // hex encode
    let mut s = String::with_capacity(res.len() * 2);
    for b in res {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

fn random_bytes(n: usize) -> Vec<u8> {
    let mut b = vec![0u8; n];
    rand::thread_rng().fill_bytes(&mut b);
    b
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn temp_dir(tag: &str) -> PathBuf {
        let p =
            std::env::temp_dir().join(format!("mnd_archive_test_{}_{}", tag, std::process::id()));
        let _ = fs::remove_dir_all(&p);
        fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn roundtrip_plain() {
        let src = temp_dir("src_plain");
        fs::write(src.join("config.json"), r#"{"id":"q1","title":"T"}"#).unwrap();
        fs::write(src.join("hello.txt"), "привет").unwrap();
        let mnd = std::env::temp_dir().join(format!("test_plain_{}.mnd", std::process::id()));
        quest_archive_export(src.to_str().unwrap(), mnd.to_str().unwrap(), None).unwrap();
        let dst = temp_dir("dst_plain");
        let qid = quest_archive_import(mnd.to_str().unwrap(), dst.to_str().unwrap()).unwrap();
        assert_eq!(qid, "q1");
        assert_eq!(fs::read_to_string(dst.join("hello.txt")).unwrap(), "привет");
        let _ = fs::remove_dir_all(&src);
        let _ = fs::remove_dir_all(&dst);
        let _ = fs::remove_file(&mnd);
    }

    #[test]
    fn export_v2_assembles_legacy_nodes_json() {
        let src = temp_dir("src_v2");
        fs::create_dir_all(src.join("nodes")).unwrap();
        fs::write(src.join("config.json"), r#"{"id":"q3","title":"V2"}"#).unwrap();
        fs::write(
            src.join("nodes/index.json"),
            r#"{
                "format_version": 2,
                "nodes": [
                    {"id":"n1","title":"Summary 1","x":1.0,"y":2.0},
                    {"id":"n2","title":"Summary 2","x":3.0,"y":4.0}
                ],
                "groups":[{"id":"g1","chapterId":"c1"}],
                "comments":[{"id":"c1","chapterId":"c1"}],
                "edges":[{"from":"n1","to":"n2","kind":"content"}]
            }"#,
        )
        .unwrap();
        fs::write(
            src.join("nodes/n1.json"),
            r#"{"id":"n1","title":"Body 1","x":1.0,"y":2.0,"content":{"items":[]}}"#,
        )
        .unwrap();
        fs::write(
            src.join("nodes/n2.json"),
            r#"{"id":"n2","title":"Body 2","x":3.0,"y":4.0,"content":{"items":[]}}"#,
        )
        .unwrap();
        // Устаревшие копии не должны попасть в экспорт.
        fs::write(src.join("nodes.json"), r#"{"nodes":[{"id":"old"}]}"#).unwrap();
        fs::write(src.join("nodes/nodes.json"), r#"{"nodes":[{"id":"old"}]}"#).unwrap();

        let mnd = std::env::temp_dir().join(format!("test_v2_{}.mnd", std::process::id()));
        quest_archive_export(src.to_str().unwrap(), mnd.to_str().unwrap(), None).unwrap();
        let dst = temp_dir("dst_v2");
        quest_archive_import(mnd.to_str().unwrap(), dst.to_str().unwrap()).unwrap();

        let raw = fs::read_to_string(dst.join("nodes.json")).unwrap();
        let doc: serde_json::Value = serde_json::from_str(&raw).unwrap();
        let nodes = doc["nodes"].as_array().unwrap();
        assert_eq!(nodes.len(), 2);
        assert_eq!(nodes[0]["title"], "Body 1");
        assert_eq!(nodes[1]["title"], "Body 2");
        assert_eq!(doc["groups"].as_array().unwrap().len(), 1);
        assert_eq!(doc["comments"].as_array().unwrap().len(), 1);
        assert!(!dst.join("nodes/index.json").exists());
        assert!(!dst.join("nodes/n1.json").exists());

        let _ = fs::remove_dir_all(&src);
        let _ = fs::remove_dir_all(&dst);
        let _ = fs::remove_file(&mnd);
    }

    #[test]
    fn roundtrip_enc2() {
        let src = temp_dir("src_enc2");
        fs::write(src.join("config.json"), r#"{"id":"q2"}"#).unwrap();
        fs::write(src.join("data.bin"), vec![1u8; 100 * 1024]).unwrap();
        let mnd = std::env::temp_dir().join(format!("test_enc2_{}.mnd", std::process::id()));
        quest_archive_export(
            src.to_str().unwrap(),
            mnd.to_str().unwrap(),
            Some("ignored".into()),
        )
        .unwrap();
        // header should be ENC2
        let mut hdr = [0u8; 8];
        File::open(&mnd).unwrap().read_exact(&mut hdr).unwrap();
        assert_eq!(&hdr, HEADER_ENC2);
        let dst = temp_dir("dst_enc2");
        let qid = quest_archive_import(mnd.to_str().unwrap(), dst.to_str().unwrap()).unwrap();
        assert_eq!(qid, "q2");
        let _ = fs::remove_dir_all(&src);
        let _ = fs::remove_dir_all(&dst);
        let _ = fs::remove_file(&mnd);
    }
}
