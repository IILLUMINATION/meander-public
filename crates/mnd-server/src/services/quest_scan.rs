//! Quest package analysis and the moderation verdict — port of `quest_scan.ts`.
//!
//! Enumerable rules only: what counts as readable game text and how a publish
//! ends. Kept apart from the route so it can be tested without a database,
//! multer or any HTTP stack.

use std::io::Read;
use std::path::Path;

use serde_json::Value;
use uuid::Uuid;

const BODY_SCAN_CHAR_BUDGET: usize = 200_000;
const MAX_NODES_JSON_SIZE: u64 = 10 * 1024 * 1024;
const MAX_IMAGE_SIZE: u64 = 10 * 1024 * 1024;
const MAX_TOTAL_EXTRACTED: u64 = 100 * 1024 * 1024;
const MAX_ENTRIES: usize = 20_000;

const WORDS_PER_MINUTE: f64 = 250.0;
const SECONDS_PER_IMAGE: f64 = 3.0;
const SECONDS_DECISION: f64 = 2.0;
const BRANCHING_FACTOR: f64 = 0.15;

#[derive(Debug, Default)]
pub struct ZipAnalysis {
    pub full_text: String,
    pub images: Vec<std::path::PathBuf>,
    pub node_count: usize,
    pub estimated_playtime: i64,
    /// The game text could not be read (oversized, broken JSON, no `nodes`
    /// array, or no `nodes.json` at all). Such a quest cannot be auto-approved.
    pub text_scan_failed: bool,
}

/// Blocked markup signatures and the magic bytes expected per extension.
fn is_safe_image_buffer(buf: &[u8], ext: &str) -> bool {
    const BLOCKED: [&[u8]; 4] = [b"<svg", b"<?xm", b"<!DO", b"<htm"];
    for sig in BLOCKED {
        if buf.starts_with(sig) {
            tracing::warn!("Zip image blocked: markup signature");
            return false;
        }
    }

    let expected: &[u8] = match ext.to_ascii_lowercase().as_str() {
        ".jpg" | ".jpeg" => &[0xff, 0xd8, 0xff],
        ".png" => &[0x89, 0x50, 0x4e, 0x47],
        ".gif" => &[0x47, 0x49, 0x46],
        ".webp" => &[0x52, 0x49, 0x46, 0x46],
        _ => return false,
    };
    buf.len() >= expected.len() && buf.starts_with(expected)
}

/// `parseInt` semantics: optional sign, then leading digits.
fn parse_leading_int(raw: &str) -> f64 {
    let trimmed = raw.trim_start();
    let bytes = trimmed.as_bytes();
    let mut end = 0;
    if bytes.first() == Some(&b'-') || bytes.first() == Some(&b'+') {
        end = 1;
    }
    let digits_start = end;
    while end < bytes.len() && bytes[end].is_ascii_digit() {
        end += 1;
    }
    if end == digits_start {
        return 0.0;
    }
    trimmed[..end].parse().unwrap_or(0.0)
}

fn image_extension(name: &str) -> Option<String> {
    let lower = name.to_ascii_lowercase();
    [".jpg", ".jpeg", ".png", ".gif", ".webp"]
        .iter()
        .find(|ext| lower.ends_with(*ext))
        .map(|ext| ext.to_string())
}

fn calc_playtime(nodes: &[Value]) -> i64 {
    let mut total_seconds = 0.0f64;

    for node in nodes {
        total_seconds += SECONDS_DECISION;
        let items = node
            .get("content")
            .and_then(|c| c.get("items"))
            .and_then(Value::as_array);
        let Some(items) = items else { continue };
        for item in items {
            match item.get("type").and_then(Value::as_str) {
                Some("text") => {
                    let text = item.get("text").and_then(Value::as_str).unwrap_or("");
                    let words = text.split_whitespace().count();
                    total_seconds += (words as f64 / WORDS_PER_MINUTE) * 60.0;
                }
                Some("image") => total_seconds += SECONDS_PER_IMAGE,
                Some("timer") => {
                    total_seconds +=
                        parse_leading_int(item.get("text").and_then(Value::as_str).unwrap_or("0"));
                }
                _ => {}
            }
        }
    }

    let estimated_minutes = (total_seconds * BRANCHING_FACTOR / 60.0).round() as i64;
    estimated_minutes.max(1)
}

/// Reads at most `limit` bytes; returns `None` when the entry exceeds it.
fn read_limited<R: Read>(reader: &mut R, limit: u64) -> std::io::Result<Option<Vec<u8>>> {
    let mut buf = Vec::new();
    reader.take(limit + 1).read_to_end(&mut buf)?;
    if buf.len() as u64 > limit {
        return Ok(None);
    }
    Ok(Some(buf))
}

fn append_node_text(full_text: &mut String, node: &Value) {
    if full_text.chars().count() >= BODY_SCAN_CHAR_BUDGET {
        return;
    }
    let title = node.get("title").and_then(Value::as_str).unwrap_or("");
    full_text.push('[');
    full_text.push_str(title);
    full_text.push_str("]\n");
    if let Some(items) = node
        .get("content")
        .and_then(|c| c.get("items"))
        .and_then(Value::as_array)
    {
        for item in items {
            if let Some(text) = item.get("text").and_then(Value::as_str)
                && !text.is_empty()
            {
                full_text.push_str(text);
                full_text.push('\n');
            }
        }
    }
}

pub fn analyze_quest_zip(file_path: &Path, temp_dir: &Path) -> Result<ZipAnalysis, String> {
    let file = std::fs::File::open(file_path).map_err(|err| err.to_string())?;
    let mut archive = zip::ZipArchive::new(file).map_err(|err| err.to_string())?;

    let mut result = ZipAnalysis {
        estimated_playtime: 5,
        ..Default::default()
    };
    let mut total_extracted: u64 = 0;
    let mut entry_count = 0usize;
    let mut saw_nodes_json = false;

    for index in 0..archive.len() {
        let mut entry = archive.by_index(index).map_err(|err| err.to_string())?;
        let name = entry.name().to_string();
        if name.ends_with('/') || name.starts_with("__MACOSX") {
            continue;
        }

        entry_count += 1;
        if entry_count > MAX_ENTRIES {
            return Err(format!("Zip contains too many entries (>{MAX_ENTRIES})"));
        }

        if name.ends_with("nodes.json") {
            saw_nodes_json = true;
            let Ok(Some(buf)) = read_limited(&mut entry, MAX_NODES_JSON_SIZE) else {
                // Oversized or unreadable nodes.json: moderation cannot see the
                // text, so the publication must not be auto-approved.
                result.text_scan_failed = true;
                continue;
            };
            match serde_json::from_slice::<Value>(&buf) {
                Ok(data) => match data.get("nodes").and_then(Value::as_array) {
                    Some(nodes) => {
                        result.node_count = nodes.len();
                        result.estimated_playtime = calc_playtime(nodes);
                        for node in nodes {
                            append_node_text(&mut result.full_text, node);
                        }
                    }
                    None => result.text_scan_failed = true,
                },
                Err(err) => {
                    tracing::error!(error = %err, "Error parsing nodes.json inside zip");
                    result.text_scan_failed = true;
                }
            }
            continue;
        }

        if result.images.len() < 3 {
            let Some(ext) = image_extension(&name) else {
                continue;
            };
            if entry.compressed_size() > MAX_IMAGE_SIZE {
                tracing::warn!(entry = %name, size = entry.compressed_size(), "Skipping oversized zip entry");
                continue;
            }
            let Ok(Some(buf)) = read_limited(&mut entry, MAX_IMAGE_SIZE) else {
                tracing::warn!(entry = %name, "Image too large in zip");
                continue;
            };
            if buf.len() as u64 >= MAX_IMAGE_SIZE {
                tracing::warn!(entry = %name, "Image too large in zip");
                continue;
            }
            total_extracted += buf.len() as u64;
            if total_extracted > MAX_TOTAL_EXTRACTED {
                tracing::warn!("Total extracted size exceeded, skipping remaining images");
                continue;
            }
            if !is_safe_image_buffer(&buf, &ext) {
                tracing::warn!(entry = %name, "Rejected unsafe image in zip");
                continue;
            }
            let image_path = temp_dir.join(format!("internal_{}{}", Uuid::new_v4(), ext));
            if let Err(err) = std::fs::write(&image_path, &buf) {
                tracing::error!(error = %err, "Error extracting image");
                continue;
            }
            result.images.push(image_path);
        }
    }

    if !saw_nodes_json {
        // An archive without nodes.json is not "clean", it is "nothing to read".
        result.text_scan_failed = true;
    }
    Ok(result)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PublishDecision {
    pub status: &'static str,
    pub moderator_comment: String,
}

/// Unreadable text is not "clean": disputed work goes to people.
pub fn publish_decision(
    moderation: Option<&crate::services::moderation::ModerationResult>,
    text_scan_failed: bool,
) -> PublishDecision {
    if let Some(m) = moderation
        && !m.approved
    {
        return PublishDecision {
            status: "in_review",
            moderator_comment: format!("Flag: {}", m.reason),
        };
    }
    if text_scan_failed {
        return PublishDecision {
            status: "in_review",
            moderator_comment: "Flag: текст игры не прочитан модерацией".to_string(),
        };
    }
    PublishDecision {
        status: "published",
        moderator_comment: "Auto-approved".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    /// Minimal stored (uncompressed) ZIP writer — the same shape the Node tests
    /// build, so fixtures need no extra crate.
    fn build_zip(entries: &[(&str, &[u8])]) -> Vec<u8> {
        let mut out = Vec::new();
        let mut central = Vec::new();
        let mut offset = 0u32;
        for (name, data) in entries {
            let crc = crc32(data);
            let mut local = Vec::new();
            local.extend_from_slice(&0x0403_4b50u32.to_le_bytes());
            local.extend_from_slice(&20u16.to_le_bytes());
            local.extend_from_slice(&0u16.to_le_bytes());
            local.extend_from_slice(&0u16.to_le_bytes());
            local.extend_from_slice(&0u16.to_le_bytes());
            local.extend_from_slice(&0u16.to_le_bytes());
            local.extend_from_slice(&crc.to_le_bytes());
            local.extend_from_slice(&(data.len() as u32).to_le_bytes());
            local.extend_from_slice(&(data.len() as u32).to_le_bytes());
            local.extend_from_slice(&(name.len() as u16).to_le_bytes());
            local.extend_from_slice(&0u16.to_le_bytes());
            out.extend_from_slice(&local);
            out.extend_from_slice(name.as_bytes());
            out.extend_from_slice(data);

            let mut dir = Vec::new();
            dir.extend_from_slice(&0x0201_4b50u32.to_le_bytes());
            dir.extend_from_slice(&20u16.to_le_bytes());
            dir.extend_from_slice(&20u16.to_le_bytes());
            dir.extend_from_slice(&0u16.to_le_bytes());
            dir.extend_from_slice(&0u16.to_le_bytes());
            dir.extend_from_slice(&0u16.to_le_bytes());
            dir.extend_from_slice(&0u16.to_le_bytes());
            dir.extend_from_slice(&crc.to_le_bytes());
            dir.extend_from_slice(&(data.len() as u32).to_le_bytes());
            dir.extend_from_slice(&(data.len() as u32).to_le_bytes());
            dir.extend_from_slice(&(name.len() as u16).to_le_bytes());
            dir.extend_from_slice(&0u16.to_le_bytes());
            dir.extend_from_slice(&0u16.to_le_bytes());
            dir.extend_from_slice(&0u16.to_le_bytes());
            dir.extend_from_slice(&0u16.to_le_bytes());
            dir.extend_from_slice(&0u32.to_le_bytes());
            dir.extend_from_slice(&offset.to_le_bytes());
            central.extend_from_slice(&dir);
            central.extend_from_slice(name.as_bytes());

            offset += local.len() as u32 + name.len() as u32 + data.len() as u32;
        }
        let central_len = central.len() as u32;
        out.extend_from_slice(&central);
        out.extend_from_slice(&0x0605_4b50u32.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
        out.extend_from_slice(&(entries.len() as u16).to_le_bytes());
        out.extend_from_slice(&central_len.to_le_bytes());
        out.extend_from_slice(&offset.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out
    }

    fn crc32(data: &[u8]) -> u32 {
        let mut crc = 0xffff_ffffu32;
        for byte in data {
            crc ^= *byte as u32;
            for _ in 0..8 {
                crc = if crc & 1 != 0 {
                    (crc >> 1) ^ 0xedb8_8320
                } else {
                    crc >> 1
                };
            }
        }
        !crc
    }

    fn write_zip(entries: &[(&str, &[u8])]) -> (tempfile::TempDir, std::path::PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("quest.zip");
        let mut f = std::fs::File::create(&path).unwrap();
        f.write_all(&build_zip(entries)).unwrap();
        (dir, path)
    }

    const GOOD_NODES: &str = r#"{"nodes":[
        {"title":"Лес","content":{"items":[{"type":"text","text":"Тропа уходит между сосен."}]}},
        {"title":"Избушка","content":{"items":[{"type":"text","text":"На столе записка."}]}}
    ]}"#;

    #[test]
    fn good_nodes_json_is_read() {
        let (dir, path) = write_zip(&[("nodes.json", GOOD_NODES.as_bytes())]);
        let r = analyze_quest_zip(&path, dir.path()).unwrap();
        assert!(!r.text_scan_failed);
        assert_eq!(r.node_count, 2);
        assert!(r.full_text.contains("Тропа уходит между сосен"));
        assert!(r.estimated_playtime >= 1);
    }

    #[test]
    fn archive_without_nodes_is_unread() {
        let (dir, path) = write_zip(&[("data.txt", b"what is inside")]);
        let r = analyze_quest_zip(&path, dir.path()).unwrap();
        assert!(r.text_scan_failed);
        assert_eq!(r.full_text, "");
    }

    #[test]
    fn broken_or_shapeless_nodes_is_unread() {
        for payload in [r#"{"nodes": ["#, r#"{"nodes": {}}"#] {
            let (dir, path) = write_zip(&[("nodes.json", payload.as_bytes())]);
            let r = analyze_quest_zip(&path, dir.path()).unwrap();
            assert!(r.text_scan_failed, "{payload}");
        }
    }

    #[test]
    fn decision_prefers_moderation_over_scan_failure() {
        use crate::services::content_rules::Severity;
        use crate::services::moderation::ModerationResult;
        let rejected = ModerationResult {
            approved: false,
            reason: "мат в названии".into(),
            is_hard_reject: false,
            quality_score: 0,
            needs_review: true,
            severity: Severity::Low,
        };
        assert_eq!(
            publish_decision(None, false),
            PublishDecision {
                status: "published",
                moderator_comment: "Auto-approved".into()
            }
        );
        assert_eq!(
            publish_decision(None, true),
            PublishDecision {
                status: "in_review",
                moderator_comment: "Flag: текст игры не прочитан модерацией".into()
            }
        );
        assert_eq!(
            publish_decision(Some(&rejected), true),
            PublishDecision {
                status: "in_review",
                moderator_comment: "Flag: мат в названии".into()
            }
        );
    }
}
