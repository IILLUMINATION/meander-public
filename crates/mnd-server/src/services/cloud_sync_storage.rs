//! Port of `cloud_sync_storage.ts` — physical storage for cloud-sync quests.
//!
//! Layout: `<CLOUD_SYNC_ROOT>/<userId>/<questId>.mnd`
//! Paths are anchored to `AppState::cfg.cloud_sync_root` so tests can use a
//! temporary directory without changing process-wide globals.

use std::path::PathBuf;
use std::sync::LazyLock;

use regex::Regex;
use sha2::{Digest, Sha256};
use tokio::fs;
use uuid::Uuid;

use crate::error::ApiError;
use crate::state::AppState;

static USER_ID_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[0-9a-fA-F-]{32,40}$").expect("user id regex"));
static QUEST_ID_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[a-zA-Z0-9_-]{1,128}$").expect("quest id regex"));

fn user_dir(state: &AppState, user_id: &str) -> Result<PathBuf, ApiError> {
    if !USER_ID_RE.is_match(user_id) {
        return Err(ApiError::bad_request("Invalid user id for storage"));
    }
    Ok(state.cfg.cloud_sync_root.join(user_id))
}

fn safe_quest_id(quest_id: &str) -> Result<String, ApiError> {
    let clean = quest_id.replace(
        |c: char| !matches!(c, 'a'..='z' | 'A'..='Z' | '0'..='9' | '-' | '_'),
        "_",
    );
    if QUEST_ID_RE.is_match(&clean) {
        Ok(clean)
    } else {
        Err(ApiError::bad_request("Invalid quest id for storage"))
    }
}

pub fn quest_file_path(
    state: &AppState,
    user_id: &str,
    quest_id: &str,
) -> Result<PathBuf, ApiError> {
    Ok(user_dir(state, user_id)?.join(format!("{}.mnd", safe_quest_id(quest_id)?)))
}

#[derive(Debug, Clone)]
pub struct QuestFileInfo {
    pub path: String,
    pub size: usize,
    pub fingerprint: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha256_hex_known_value() {
        assert_eq!(
            sha256_hex(b"hello"),
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        );
    }

    #[test]
    fn safe_quest_id_cleans_unsafe_chars() {
        assert_eq!(safe_quest_id("my quest/file").unwrap(), "my_quest_file");
        assert!(safe_quest_id("").is_err());
        assert!(safe_quest_id(&"a".repeat(129)).is_err());
    }
}

pub async fn write_quest_file(
    state: &AppState,
    user_id: &str,
    quest_id: &str,
    data: &[u8],
) -> Result<QuestFileInfo, ApiError> {
    let dir = user_dir(state, user_id)?;
    fs::create_dir_all(&dir).await?;
    let file_path = quest_file_path(state, user_id, quest_id)?;
    let tmp_name = format!("tmp-{}", chrono::Utc::now().timestamp_millis());
    let tmp_path = file_path.with_extension(&tmp_name);

    fs::write(&tmp_path, data).await?;
    fs::rename(&tmp_path, &file_path).await?;

    let relative = file_path
        .strip_prefix(&state.cfg.cloud_sync_root)
        .unwrap_or(&file_path)
        .to_path_buf()
        .to_string_lossy()
        .into_owned();

    Ok(QuestFileInfo {
        path: relative,
        size: data.len(),
        fingerprint: sha256_hex(data),
    })
}

pub async fn read_quest_stream(
    state: &AppState,
    user_id: &str,
    quest_id: &str,
) -> Result<(tokio::fs::File, u64), ApiError> {
    let file_path = quest_file_path(state, user_id, quest_id)?;
    let meta = fs::metadata(&file_path).await?;
    if !meta.is_file() {
        return Err(ApiError::not_found("Quest file not found"));
    }
    let file = fs::File::open(&file_path).await?;
    Ok((file, meta.len()))
}

pub async fn delete_quest_file(state: &AppState, user_id: &str, quest_id: &str) {
    if let Ok(path) = quest_file_path(state, user_id, quest_id) {
        let _ = fs::remove_file(path).await;
    }
}

pub async fn quest_file_exists(state: &AppState, user_id: &str, quest_id: &str) -> bool {
    match quest_file_path(state, user_id, quest_id) {
        Ok(path) => fs::metadata(path)
            .await
            .map(|m| m.is_file())
            .unwrap_or(false),
        Err(_) => false,
    }
}

pub fn sha256_hex(data: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(data);
    format!("{:x}", hasher.finalize())
}

/// Remove the entire user directory (used by archive, purge, account deletion).
pub async fn delete_all_user_files(state: &AppState, user_id: Uuid) -> std::io::Result<()> {
    let dir = state.cfg.cloud_sync_root.join(user_id.to_string());
    match tokio::fs::remove_dir_all(&dir).await {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e),
    }
}
