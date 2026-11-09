//! `/quests` — publication, catalogue, per-quest actions and analytics.
//! Port of `routes/quests.ts`.
//!
//! Publication order matters and follows the Node route: declared-size gate,
//! multipart parsing, ownership, file sanitising/hashing, archive analysis,
//! moderation, staging copy, transaction, then the file takes its permanent
//! place only after COMMIT.

use std::collections::HashMap;
use std::path::{Path as FsPath, PathBuf};
use std::sync::Arc;

use axum::body::to_bytes;
use axum::extract::{FromRequest, Multipart, Path, Query, State};
use axum::http::{HeaderMap, HeaderName, HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use sqlx::Row;
use uuid::Uuid;

use crate::auth::{AdminUser, AuthUser, OptionalAuth};
use crate::error::{
    ApiError, ApiResult, multer_error, ok_created, ok_json, payload_too_large, upload_error,
};
use crate::extractors::{Body, FormData, collect_multipart};
use crate::json::pg_row_to_json;
use crate::services::achievements::award_achievement;
use crate::services::image_host::save_uploaded_image;
use crate::services::market_query::{MarketListOptions, bind_params};
use crate::services::market_tiers::{
    MARKET_TIER_DEMO, MARKET_TIER_MODERATED, MARKET_TIER_ON_REPUBLISH_SQL, parse_market_tier,
    parse_market_tier_json, tier_for_new_quest,
};
use crate::services::moderation::moderate_quest_content;
use crate::services::moderation::moderate_review;
use crate::services::notifications::{
    NewNotification, create_bulk_notifications_tx, create_notification,
};
use crate::services::publish_errors::{
    VERIFIED_USER_MAX_FILE_SIZE_BYTES, archive_unreadable, content_rejected,
    declared_size_rejection, duplicate_file, file_too_large, missing_quest_file,
    ownership_conflict, size_limit_for, unexpected,
};
use crate::services::quest_analytics::{clamp_days, get_author_analytics, get_quest_analytics};
use crate::services::quest_genres::{
    QUEST_GENRE_IDS, genres_from_form_value, normalize_genre_id, normalize_quest_genres,
};
use crate::services::quest_language::normalize_quest_language;
use crate::services::quest_scan::{analyze_quest_zip, publish_decision};
use crate::services::quest_stream;
use crate::services::visibility::{can_see_unpublished, is_admin, is_staff};
use crate::state::AppState;

const TEMP_DIR_NAME: &str = "meander_uploads";
const QUEST_UPDATE_NOTIFY_COOLDOWN_HOURS: i64 = 12;

pub fn router(state: Arc<AppState>) -> Router<Arc<AppState>> {
    // Обычные маршруты `/quests` под общим на quest-лимитом (60/15мин аноним).
    // Потоковая выдача квеста живёт ОТДЕЛЬНО (`stream_router`): ленивая
    // подгрузка ресурсов — это десятки-сотни запросов на один квест, под
    // общим лимитом она бы упиралась в 429.
    let limited = Router::new()
        .route(
            "/",
            post(publish)
                .layer(axum::extract::DefaultBodyLimit::max(
                    VERIFIED_USER_MAX_FILE_SIZE_BYTES as usize,
                ))
                .get(list),
        )
        .route("/liked-genres", get(liked_genres))
        .route("/genres", get(genres))
        .route("/featured", get(featured))
        .route("/activity/recent", get(recent_activity))
        .route("/analytics/author", get(author_analytics))
        .route("/{id}", get(quest_detail).delete(delete_quest))
        .route("/{id}/vote", post(vote))
        .route("/{id}/view", post(view))
        .route("/{id}/download", post(download))
        .route("/{id}/file", get(quest_file))
        .route("/{id}/admin/action", post(admin_action))
        .route("/{id}/analytics", get(quest_analytics))
        .route("/{id}/reviews", get(reviews))
        .route("/{id}/screenshots", get(screenshots))
        .route("/{id}/my-vote", get(my_vote))
        .route("/{id}/my-review", get(my_review))
        .route("/{id}/rate", post(rate))
        .route("/{id}/review", post(review))
        .layer(axum::middleware::from_fn_with_state(
            state,
            crate::middleware::quest_rate_limit,
        ));
    limited.merge(stream_router())
}

/// Потоковая раздача квеста: манифест, boot-бандл и ленивые записи.
///
/// Отдельно от [`router`], чтобы не попадать под общий quest-лимит.
pub fn stream_router() -> Router<Arc<AppState>> {
    Router::new()
        .route("/{id}/manifest", get(quest_manifest))
        .route("/{id}/boot", get(quest_boot))
        // Манифест называет бандл `boot.mnd` — для клиента, который берёт имя
        // из манифеста, тот же обработчик доступен и по этому пути.
        .route("/{id}/boot.mnd", get(quest_boot))
        .route("/{id}/entry/{*path}", get(quest_entry))
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// Removes HTML tags and trims — stored-XSS protection identical to the Node
/// `stripHtml`.
fn strip_html(raw: &str) -> String {
    // `/<[^>]*>/g`: a `<` without a closing `>` stays in the text, unlike a
    // depth counter, which would swallow the rest of the string.
    let chars: Vec<char> = raw.chars().collect();
    let mut out = String::with_capacity(raw.len());
    let mut index = 0;
    while index < chars.len() {
        if chars[index] == '<'
            && let Some(offset) = chars[index + 1..].iter().position(|c| *c == '>')
        {
            index += offset + 2;
            continue;
        }
        out.push(chars[index]);
        index += 1;
    }
    out.trim().to_string()
}

fn sanitize_text(raw: &str, max_length: usize) -> String {
    strip_html(raw).chars().take(max_length).collect()
}

fn public_download_url(base_url: &str, quest_id: &str) -> String {
    format!(
        "{}/quests/{}/file",
        base_url.trim_end_matches('/'),
        quest_id
    )
}

/// `withPublicDownloadUrl`: rewrites the download link and hides the
/// moderation note unless the caller is the author or staff.
fn with_public_download_url(mut row: Value, base_url: &str, privileged: bool) -> Value {
    let Some(object) = row.as_object_mut() else {
        return row;
    };
    if let Some(id) = object.get("id").and_then(Value::as_str) {
        object.insert(
            "download_url".into(),
            Value::String(public_download_url(base_url, id)),
        );
    }
    if !privileged {
        object.remove("moderator_comment");
    }
    row
}

fn parse_id(raw: &str) -> Result<Uuid, ApiError> {
    Uuid::parse_str(raw).map_err(|_| ApiError::bad_request("Invalid ID format"))
}

fn bool_field(form: &FormData, key: &str) -> bool {
    form.str(key) == Some("true")
}

/// Strips the 8-byte `MND_ZIP_` header a launcher prepends to the archive.
fn sanitize_quest_file(path: &FsPath) -> std::io::Result<()> {
    use std::io::{Read, Seek, SeekFrom, Write};
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)?;
    let mut header = [0u8; 8];
    let read = file.read(&mut header)?;
    if read == 8 && &header == b"MND_ZIP_" {
        tracing::info!(file = %path.display(), "Detected MND_ZIP_ header. Stripping");
        file.seek(SeekFrom::Start(8))?;
        let mut rest = Vec::new();
        file.read_to_end(&mut rest)?;
        drop(file);
        let mut out = std::fs::File::create(path)?;
        out.write_all(&rest)?;
        out.flush()?;
    }
    Ok(())
}

fn sha256_file(path: &FsPath) -> std::io::Result<String> {
    use std::io::Read;
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 64 * 1024];
    loop {
        let read = file.read(&mut buf)?;
        if read == 0 {
            break;
        }
        hasher.update(&buf[..read]);
    }
    Ok(hex::encode(hasher.finalize()))
}

/// Removes referenced paths when the handler returns, however it returns.
struct Cleanup(Vec<PathBuf>);

impl Cleanup {
    fn new() -> Self {
        Self(Vec::new())
    }

    fn push(&mut self, path: impl Into<PathBuf>) {
        self.0.push(path.into());
    }
}

impl Drop for Cleanup {
    fn drop(&mut self) {
        for path in &self.0 {
            let _ = std::fs::remove_file(path);
        }
    }
}

fn allowed_upload_part(file: &crate::extractors::UploadedFile) -> bool {
    let ext = crate::services::image_host::extension_of(&file.file_name);
    let mime = file
        .content_type
        .as_deref()
        .unwrap_or("")
        .to_ascii_lowercase();
    match file.field.as_str() {
        "questFile" => {
            matches!(ext.as_str(), ".mnd" | ".zip")
                && matches!(
                    mime.as_str(),
                    "application/octet-stream" | "application/zip" | "application/x-zip-compressed"
                )
        }
        "cover" | "screenshots" => {
            matches!(ext.as_str(), ".jpg" | ".jpeg" | ".png" | ".webp")
                && matches!(
                    mime.as_str(),
                    "" | "application/octet-stream"
                        | "binary/octet-stream"
                        | "image/jpeg"
                        | "image/jpg"
                        | "image/pjpeg"
                        | "image/png"
                        | "image/webp"
                )
        }
        _ => false,
    }
}

// ---------------------------------------------------------------------------
// POST /quests — publication
// ---------------------------------------------------------------------------

async fn publish(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    headers: HeaderMap,
    ip: crate::middleware::ClientIp,
    request: axum::extract::Request,
) -> ApiResult {
    let user_id = auth.id;

    // Node mounts `uploadLimiter` in front of `POST /quests` (five per hour per
    // author) before multer touches the body.
    let (allowed, decision) =
        crate::middleware::upload_allowed(&state, Some(&user_id.to_string()), &ip.0);
    if !allowed {
        return Ok(crate::middleware::too_many(
            crate::ratelimit::policy::UPLOAD_MESSAGE,
            decision,
        ));
    }
    let content_type = headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_ascii_lowercase();
    let temp_dir = std::env::temp_dir().join(TEMP_DIR_NAME);
    let _ = std::fs::create_dir_all(&temp_dir);
    let quests_dir = state.cfg.public_dir.join("quests_files");
    let uploads_dir = state.cfg.public_dir.join("uploads");
    let base_url = state.cfg.base_url.clone();

    // Size gate before the body is parsed: a 200 MB package must not reach the
    // disk only to hear "limit 100 MB". A failed role lookup does not block —
    // the size is checked again after the file is written.
    let content_length = headers
        .get(header::CONTENT_LENGTH)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<u64>().ok());
    let verified_for_gate =
        sqlx::query_scalar::<_, Option<bool>>("SELECT is_verified FROM profiles WHERE id = $1")
            .bind(user_id)
            .fetch_optional(&state.db)
            .await;
    match verified_for_gate {
        Ok(profile) => {
            let limit = size_limit_for(profile.flatten() == Some(true));
            if let Some(rejection) = declared_size_rejection(content_length, limit) {
                tracing::info!(
                    size_mb = rejection
                        .details
                        .get("size_mb")
                        .and_then(|v| v.as_f64())
                        .unwrap_or(0.0),
                    "Publish size rejected before body parsing"
                );
                return Err(rejection.to_api_error());
            }
        }
        Err(err) => tracing::error!(error = %err, "Publish size gate failed"),
    }

    // Express parses JSON/urlencoded bodies globally and lets `multer` pass
    // other content types through; the route then answers "quest file
    // required". Only multipart reaches the file pipeline, and malformed
    // multipart is a 500 there, exactly like `multer`'s error middleware.
    let form = if crate::is_multipart_content_type(&content_type) {
        let multipart = Multipart::from_request(request, &state)
            .await
            .map_err(|_| {
                let message = if content_type.contains("boundary=") {
                    "Multipart: Unexpected end of form"
                } else {
                    "Multipart: Boundary not found"
                };
                ApiError::internal(message).with_original(message)
            })?;
        collect_multipart(multipart, VERIFIED_USER_MAX_FILE_SIZE_BYTES as usize).await?
    } else {
        let bytes = to_bytes(request.into_body(), 1024 * 1024)
            .await
            .map_err(|_| payload_too_large())?;
        if crate::is_json_content_type(&content_type) && !bytes.is_empty() {
            match serde_json::from_slice::<Value>(&bytes) {
                Ok(value) if value.is_object() || value.is_array() => {}
                _ => return Err(ApiError::bad_request("Bad JSON format")),
            }
        }
        return Err(missing_quest_file().to_api_error());
    };

    for file in &form.files {
        if file.field != "questFile" && file.field != "cover" && file.field != "screenshots" {
            return Err(multer_error("Unexpected file field"));
        }
        if !allowed_upload_part(file) {
            let message = match file.field.as_str() {
                "questFile" => "Invalid quest file type",
                _ => "Invalid image file type",
            };
            return Err(upload_error(message));
        }
    }

    let user_check = sqlx::query("SELECT is_blocked FROM profiles WHERE id = $1")
        .bind(user_id)
        .fetch_optional(&state.db)
        .await
        .map_err(|err| unexpected(&err))?;
    let Some(user_row) = user_check else {
        return Err(ApiError::not_found("User not found"));
    };
    if user_row
        .try_get::<Option<bool>, _>("is_blocked")
        .ok()
        .flatten()
        == Some(true)
    {
        return Err(ApiError::forbidden(
            "Your account is blocked. You cannot publish quests.",
        ));
    }

    let title = sanitize_text(form.str("title").unwrap_or(""), 200);
    let description = sanitize_text(form.str("description").unwrap_or(""), 5000);
    let version = sanitize_text(form.str("version").unwrap_or(""), 50);
    let is_demo = bool_field(&form, "is_demo") || bool_field(&form, "demo");
    let is_nsfw = bool_field(&form, "is_nsfw");
    let quest_language = normalize_quest_language(form.str("language"));

    // Genres: the field arrives as a JSON string, a plain string or repeated
    // fields. Old clients sent `category` only.
    let mut selected = if form.strings("genres").len() > 1 {
        normalize_quest_genres(
            &Value::Array(
                form.strings("genres")
                    .into_iter()
                    .map(Value::String)
                    .collect(),
            ),
            3,
        )
    } else {
        genres_from_form_value(form.str("genres"))
    };
    if selected.is_empty()
        && let Some(category) = form.str("category")
    {
        selected = normalize_quest_genres(&Value::String(category.to_string()), 3);
    }
    if selected.is_empty() {
        selected = vec!["adventure".to_string()];
    }
    let main_category = selected[0].clone();

    let quest_id = form
        .str("id")
        .and_then(|raw| Uuid::parse_str(raw).ok())
        .unwrap_or_else(Uuid::new_v4);
    tracing::info!(quest_id = %quest_id, "Processing upload");

    // A foreign id in the body is not a right to update: the file lives at
    // static/downloads/<id>.mnd and the copy below would overwrite someone
    // else's quest before any transaction check had a chance to run.
    let owner: Option<Uuid> = sqlx::query_scalar("SELECT author_id FROM quests WHERE id = $1")
        .bind(quest_id)
        .fetch_optional(&state.db)
        .await
        .map_err(|err| unexpected(&err))?;
    if let Some(owner) = owner
        && owner != user_id
        && !is_admin(&state, user_id).await
    {
        return Err(ownership_conflict().to_api_error());
    }

    let Some(quest_file_index) = form.files.iter().position(|f| f.field == "questFile") else {
        return Err(missing_quest_file().to_api_error());
    };

    let verified: Option<bool> =
        sqlx::query_scalar("SELECT is_verified FROM profiles WHERE id = $1")
            .bind(user_id)
            .fetch_optional(&state.db)
            .await
            .map_err(|err| unexpected(&err))?;
    let size_limit = size_limit_for(verified == Some(true));
    let quest_size = form.files[quest_file_index].size as u64;
    if quest_size > size_limit {
        return Err(file_too_large(quest_size, size_limit).to_api_error());
    }

    let quest_path = form.files[quest_file_index].path.clone();
    sanitize_quest_file(&quest_path).map_err(|err| unexpected(&err))?;
    let hash = sha256_file(&quest_path).map_err(|err| unexpected(&err))?;

    let duplicate: Option<Uuid> =
        sqlx::query_scalar("SELECT id FROM quests WHERE file_hash = $1 AND author_id != $2")
            .bind(&hash)
            .bind(user_id)
            .fetch_optional(&state.db)
            .await
            .map_err(|err| unexpected(&err))?;
    if duplicate.is_some() {
        return Err(duplicate_file().to_api_error());
    }

    let mut cleanup = Cleanup::new();
    let analysis = match analyze_quest_zip(&quest_path, &temp_dir) {
        Ok(analysis) => analysis,
        Err(reason) => {
            tracing::warn!(error = %reason, "Quest archive unreadable");
            return Err(archive_unreadable(&reason).to_api_error());
        }
    };
    for image in &analysis.images {
        cleanup.push(image.clone());
    }

    let moderation =
        if !analysis.full_text.is_empty() || !description.is_empty() || !title.is_empty() {
            let result = moderate_quest_content(&title, &description, &analysis.full_text);
            if result.is_hard_reject {
                return Err(content_rejected(&result.reason).to_api_error());
            }
            Some(result)
        } else {
            None
        };
    let decision = publish_decision(moderation.as_ref(), analysis.text_scan_failed);

    // The permanent copy is staged: a rejected publication used to overwrite
    // the file of a quest already in the store.
    let perm_file_name = format!("{quest_id}.mnd");
    let perm_file_path = quests_dir.join(&perm_file_name);
    let staging_path = quests_dir.join(format!("{perm_file_name}.staging"));
    cleanup.push(staging_path.clone());
    std::fs::copy(&quest_path, &staging_path).map_err(|err| unexpected(&err))?;

    let download_url = format!(
        "{}/static/downloads/{perm_file_name}",
        base_url.trim_end_matches('/')
    );

    let mut preview_image_url: Option<String> = None;
    if let Some(cover) = form.files.iter().find(|f| f.field == "cover") {
        match tokio::fs::read(&cover.path).await {
            Ok(bytes) => {
                match save_uploaded_image(&uploads_dir, &bytes, &cover.file_name, &base_url) {
                    Ok(url) => preview_image_url = Some(url),
                    Err(err) => tracing::error!(error = %err, "Cover upload failed"),
                }
            }
            Err(err) => tracing::error!(error = %err, "Cover upload failed"),
        }
    }

    let mut screenshot_urls: Vec<String> = Vec::new();
    for shot in form.files.iter().filter(|f| f.field == "screenshots") {
        match tokio::fs::read(&shot.path).await {
            Ok(bytes) => {
                match save_uploaded_image(&uploads_dir, &bytes, &shot.file_name, &base_url) {
                    Ok(url) => screenshot_urls.push(url),
                    Err(err) => tracing::error!(error = %err, "Screenshot upload failed"),
                }
            }
            Err(err) => tracing::error!(error = %err, "Screenshot upload failed"),
        }
    }

    let mut tx = state.db.begin().await.map_err(|err| unexpected(&err))?;

    let existing_owner: Option<Uuid> =
        sqlx::query_scalar("SELECT author_id FROM quests WHERE id = $1")
            .bind(quest_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(|err| unexpected(&err))?;
    let is_new_quest = existing_owner.is_none();
    if let Some(owner) = existing_owner
        && owner != user_id
        && !is_admin(&state, user_id).await
    {
        return Err(ownership_conflict().to_api_error());
    }

    let upsert = format!(
        "INSERT INTO quests (
            id, title, description, author_id, download_url, preview_image_url,
            version, node_count, estimated_playtime, quest_size_bytes,
            status, updated_at, moderator_comment, category, genres, file_hash, is_demo, is_nsfw,
            market_tier
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11::quest_status, NOW(), $12, $13, $14, $15, $16, $17, $18)
        ON CONFLICT (id) DO UPDATE SET
            title=EXCLUDED.title,
            description=EXCLUDED.description,
            download_url=EXCLUDED.download_url,
            preview_image_url=COALESCE(EXCLUDED.preview_image_url, quests.preview_image_url),
            version=EXCLUDED.version,
            node_count=EXCLUDED.node_count,
            estimated_playtime=EXCLUDED.estimated_playtime,
            quest_size_bytes=EXCLUDED.quest_size_bytes,
            updated_at=NOW(),
            status=$11::quest_status,
            moderator_comment=$12,
            category=$13,
            genres=$14,
            file_hash=$15,
            is_demo=EXCLUDED.is_demo,
            is_nsfw=EXCLUDED.is_nsfw,
            market_tier={MARKET_TIER_ON_REPUBLISH_SQL}
        RETURNING *"
    );

    let published = sqlx::query(&upsert)
        .bind(quest_id)
        .bind(&title)
        .bind(&description)
        .bind(user_id)
        .bind(&download_url)
        .bind(preview_image_url.as_deref())
        .bind(&version)
        .bind(analysis.node_count as i32)
        .bind(analysis.estimated_playtime as i32)
        .bind(quest_size as i64)
        .bind(decision.status)
        .bind(&decision.moderator_comment)
        .bind(&main_category)
        .bind(&selected)
        .bind(&hash)
        .bind(is_demo)
        .bind(is_nsfw)
        .bind(tier_for_new_quest(is_demo))
        .fetch_one(&mut *tx)
        .await
        .map_err(|err| unexpected(&err))?;

    // The language is a separate UPDATE: only new clients send the field. No
    // field means "old client, keep the label"; an empty field clears it.
    if form.fields.contains_key("language") {
        sqlx::query("UPDATE quests SET language = $1 WHERE id = $2")
            .bind(quest_language.as_deref())
            .bind(quest_id)
            .execute(&mut *tx)
            .await
            .map_err(|err| unexpected(&err))?;
    }

    sqlx::query("DELETE FROM quest_screenshots WHERE quest_id = $1")
        .bind(quest_id)
        .execute(&mut *tx)
        .await
        .map_err(|err| unexpected(&err))?;
    for (index, url) in screenshot_urls.iter().enumerate() {
        sqlx::query(
            "INSERT INTO quest_screenshots (quest_id, image_url, sort_order) VALUES ($1, $2, $3)",
        )
        .bind(quest_id)
        .bind(url)
        .bind(index as i32)
        .execute(&mut *tx)
        .await
        .map_err(|err| unexpected(&err))?;
    }

    sqlx::query("UPDATE profiles SET last_published_at = NOW() WHERE id = $1")
        .bind(user_id)
        .execute(&mut *tx)
        .await
        .map_err(|err| unexpected(&err))?;

    let published_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM quests WHERE author_id = $1 AND status = 'published'",
    )
    .bind(user_id)
    .fetch_one(&mut *tx)
    .await
    .map_err(|err| unexpected(&err))?;
    if published_count == 1 {
        award_achievement(&state, user_id, "publisher_debut").await;
    }

    if decision.status == "published" {
        let follower_ids: Vec<Uuid> =
            sqlx::query_scalar("SELECT follower_id FROM user_followers WHERE user_id = $1")
                .bind(user_id)
                .fetch_all(&mut *tx)
                .await
                .map_err(|err| unexpected(&err))?;

        let payload = json!({ "title": title, "version": version, "is_demo": is_demo });
        if is_new_quest {
            create_bulk_notifications_tx(
                &state,
                &mut tx,
                &follower_ids,
                Some(user_id),
                "quest_published",
                Some(quest_id),
                None,
                Some(payload),
            )
            .await;
        } else {
            // Anti-spam: update notifications at most once per quest every
            // twelve hours.
            let recent: Option<i32> = sqlx::query_scalar(
                "SELECT 1 FROM notifications
                  WHERE quest_id = $1
                    AND type = 'quest_updated'
                    AND created_at > NOW() - make_interval(hours => $2::int)
                  LIMIT 1",
            )
            .bind(quest_id)
            .bind(QUEST_UPDATE_NOTIFY_COOLDOWN_HOURS as i32)
            .fetch_optional(&mut *tx)
            .await
            .map_err(|err| unexpected(&err))?;

            if recent.is_none() {
                let download_ids: Vec<Uuid> =
                    sqlx::query_scalar("SELECT user_id FROM quest_downloads WHERE quest_id = $1")
                        .bind(quest_id)
                        .fetch_all(&mut *tx)
                        .await
                        .map_err(|err| unexpected(&err))?;
                let mut recipients: Vec<Uuid> = follower_ids.clone();
                for id in download_ids {
                    if !recipients.contains(&id) {
                        recipients.push(id);
                    }
                }
                create_bulk_notifications_tx(
                    &state,
                    &mut tx,
                    &recipients,
                    Some(user_id),
                    "quest_updated",
                    Some(quest_id),
                    None,
                    Some(payload),
                )
                .await;
            } else {
                tracing::info!(quest_id = %quest_id, "Skipped quest_updated (cooldown)");
            }
        }
    }

    tx.commit().await.map_err(|err| unexpected(&err))?;

    // The file takes its permanent place only for a committed publication.
    std::fs::rename(&staging_path, &perm_file_path).map_err(|err| unexpected(&err))?;

    // Артефакты потоковой раздачи (манифест + boot) собираем сразу, чтобы
    // первый запрос веб-плеера не платил за разбор архива. Ошибка не должна
    // валить публикацию: артефакты дособерутся при первом обращении.
    {
        let artifacts_dir = quests_dir.clone();
        match tokio::task::spawn_blocking(move || {
            crate::services::quest_stream::load_or_build_manifest(&artifacts_dir, quest_id)
        })
        .await
        {
            Ok(Ok(_)) => {}
            Ok(Err(reason)) => {
                tracing::warn!(error = %reason, quest_id = %quest_id, "quest stream artifacts failed");
            }
            Err(err) => {
                tracing::error!(error = %err, "quest stream artifacts task panicked");
            }
        }
    }

    if decision.status == "published" {
        // Meander Cloud tier recompute, best-effort and not blocking the answer.
        let tier_state = state.clone();
        tokio::spawn(async move {
            if let Err(err) =
                crate::services::cloud_sync_tier::recompute_tier(&tier_state, user_id).await
            {
                tracing::error!(error = %err, "[cloud-sync] tier recompute failed");
            }
        });
    }

    let mut body = pg_row_to_json(&published);
    if let Some(object) = body.as_object_mut() {
        object.insert(
            "message".into(),
            Value::String("Published successfully".into()),
        );
    }
    ok_created(body)
}

// ---------------------------------------------------------------------------
// Votes, views, downloads
// ---------------------------------------------------------------------------

async fn vote(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(id): Path<String>,
    Body(body): Body,
) -> ApiResult {
    let quest_id = parse_id(&id)?;
    let user_id = auth.id;
    let action = body.get("action").map(value_to_string).unwrap_or_default();
    // pg casts a text parameter to boolean, so "true"/"false" behaved like the
    // booleans in Node; keep that tolerance.
    let is_like = body.get("is_like").and_then(|value| match value {
        Value::Bool(flag) => Some(*flag),
        Value::String(raw) if raw == "true" => Some(true),
        Value::String(raw) if raw == "false" => Some(false),
        _ => None,
    });

    let result: Result<Value, ApiError> = async {
        let previous: Option<bool> = sqlx::query_scalar(
            "SELECT is_like FROM quest_votes WHERE quest_id = $1 AND user_id = $2",
        )
        .bind(quest_id)
        .bind(user_id)
        .fetch_optional(&state.db)
        .await?;
        let previous_is_like = previous == Some(true);

        if action == "remove" {
            sqlx::query("DELETE FROM quest_votes WHERE quest_id = $1 AND user_id = $2")
                .bind(quest_id)
                .bind(user_id)
                .execute(&state.db)
                .await?;
        } else {
            sqlx::query(
                "INSERT INTO quest_votes (quest_id, user_id, is_like) VALUES ($1, $2, $3)
                 ON CONFLICT (quest_id, user_id) DO UPDATE SET is_like = $3, created_at = NOW()",
            )
            .bind(quest_id)
            .bind(user_id)
            .bind(is_like)
            .execute(&state.db)
            .await?;
            if is_like == Some(true) {
                let likes_by_user: i64 = sqlx::query_scalar(
                    "SELECT COUNT(*) FROM quest_votes WHERE user_id = $1 AND is_like = TRUE",
                )
                .bind(user_id)
                .fetch_one(&state.db)
                .await?;
                if likes_by_user >= 20 {
                    award_achievement(&state, user_id, "generous").await;
                }
            }
        }

        if action != "remove" && is_like == Some(true) && !previous_is_like {
            let quest: Option<(Uuid, Option<String>)> =
                sqlx::query_as("SELECT author_id, title FROM quests WHERE id = $1")
                    .bind(quest_id)
                    .fetch_optional(&state.db)
                    .await?;
            if let Some((author_id, title)) = quest
                && author_id != user_id
            {
                create_notification(
                    &state,
                    NewNotification {
                        user_id: author_id,
                        actor_id: Some(user_id),
                        kind: "quest_like",
                        quest_id: Some(quest_id),
                        review_id: None,
                        payload: Some(json!({ "title": title })),
                    },
                )
                .await;
            }
        }

        let likes: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM quest_votes WHERE quest_id = $1 AND is_like = TRUE",
        )
        .bind(quest_id)
        .fetch_one(&state.db)
        .await?;
        let dislikes: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM quest_votes WHERE quest_id = $1 AND is_like = FALSE",
        )
        .bind(quest_id)
        .fetch_one(&state.db)
        .await?;
        sqlx::query(
            "UPDATE quests SET like_count = $1::int, dislike_count = $2::int WHERE id = $3",
        )
        .bind(likes)
        .bind(dislikes)
        .bind(quest_id)
        .execute(&state.db)
        .await?;

        Ok(json!({ "success": true, "likes": likes, "dislikes": dislikes }))
    }
    .await;

    match result {
        Ok(value) => ok_json(value),
        Err(err) => {
            tracing::error!(error = %err.error, "vote error");
            Err(ApiError::internal("Vote error"))
        }
    }
}

/// One row per (quest, person, day); the author's own views are not counted,
/// and repeat opens within 30 seconds do not inflate the counter.
async fn view(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(id): Path<String>,
) -> ApiResult {
    let quest_id = parse_id(&id)?;
    let user_id = auth.id;
    let today = chrono::Utc::now().format("%Y-%m-%d").to_string();

    let result = sqlx::query(
        "INSERT INTO quest_views (quest_id, user_id, day, views, last_view_at)
         SELECT $1, $2, $3::date, 1, NOW()
           FROM quests q
          WHERE q.id = $1 AND q.author_id <> $2
         ON CONFLICT (quest_id, user_id, day) DO UPDATE
            SET views = quest_views.views +
                    (CASE WHEN NOW() - quest_views.last_view_at >= INTERVAL '30 seconds'
                          THEN 1 ELSE 0 END),
                last_view_at = NOW()",
    )
    .bind(quest_id)
    .bind(user_id)
    .bind(&today)
    .execute(&state.db)
    .await;

    match result {
        Ok(_) => ok_json(json!({ "success": true })),
        Err(err) => {
            tracing::error!(error = %err, "quest view");
            Err(ApiError::internal("Server error"))
        }
    }
}

async fn download(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(id): Path<String>,
) -> ApiResult {
    let quest_id = parse_id(&id)?;
    let user_id = auth.id;

    let result: Result<(), ApiError> = async {
        let existing: Option<bool> = sqlx::query_scalar(
            "SELECT TRUE FROM quest_downloads WHERE user_id = $1 AND quest_id = $2",
        )
        .bind(user_id)
        .bind(quest_id)
        .fetch_optional(&state.db)
        .await?;
        if existing.is_none() {
            sqlx::query("INSERT INTO quest_downloads (user_id, quest_id) VALUES ($1, $2)")
                .bind(user_id)
                .bind(quest_id)
                .execute(&state.db)
                .await?;
            sqlx::query("UPDATE quests SET downloads_count = downloads_count + 1 WHERE id = $1")
                .bind(quest_id)
                .execute(&state.db)
                .await?;

            award_achievement(&state, user_id, "first_step").await;

            let download_count: i64 =
                sqlx::query_scalar("SELECT COUNT(*) FROM quest_downloads WHERE user_id = $1")
                    .bind(user_id)
                    .fetch_one(&state.db)
                    .await?;
            if download_count >= 10 {
                award_achievement(&state, user_id, "bookworm").await;
            }
            if download_count >= 50 {
                award_achievement(&state, user_id, "library_keeper").await;
            }
        }
        Ok(())
    }
    .await;

    match result {
        Ok(()) => ok_json(json!({ "success": true })),
        Err(err) => {
            tracing::error!(error = %err.error, "quest download");
            Err(ApiError::internal("Server error"))
        }
    }
}

async fn delete_quest(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(id): Path<String>,
) -> ApiResult {
    let quest_id = parse_id(&id)?;

    let owner: Option<Uuid> = sqlx::query_scalar("SELECT author_id FROM quests WHERE id = $1")
        .bind(quest_id)
        .fetch_optional(&state.db)
        .await
        .map_err(|err| {
            tracing::error!(error = %err, "Quest delete lookup failed");
            ApiError::internal("Delete failed")
        })?;
    let Some(owner) = owner else {
        return Err(ApiError::not_found("Quest not found"));
    };
    if owner != auth.id && !is_admin(&state, auth.id).await {
        return Err(ApiError::forbidden("Forbidden"));
    }

    let file_path = state
        .cfg
        .public_dir
        .join("quests_files")
        .join(format!("{quest_id}.mnd"));
    let _ = std::fs::remove_file(file_path);
    // Артефакты потоковой раздачи: манифест, boot-бандл и распакованные
    // по требованию записи — иначе остаются сиротами после удаления.
    let quests_dir = state.cfg.public_dir.join("quests_files");
    let _ = std::fs::remove_file(crate::services::quest_stream::manifest_path(&quests_dir, quest_id));
    let _ = std::fs::remove_file(crate::services::quest_stream::boot_path(&quests_dir, quest_id));
    let _ = std::fs::remove_dir_all(crate::services::quest_stream::extracted_dir(&quests_dir, quest_id));

    match sqlx::query("DELETE FROM quests WHERE id = $1")
        .bind(quest_id)
        .execute(&state.db)
        .await
    {
        Ok(_) => ok_json(json!({ "message": "Quest deleted" })),
        Err(err) => {
            tracing::error!(error = %err, "Quest delete failed");
            Err(ApiError::internal("Delete failed"))
        }
    }
}

async fn quest_file(
    State(state): State<Arc<AppState>>,
    OptionalAuth(auth): OptionalAuth,
    Path(id): Path<String>,
    request: axum::extract::Request,
) -> ApiResult {
    let quest_id = parse_id(&id)?;
    let quests_dir = visible_quests_dir(&state, auth.as_ref().map(|u| u.id), quest_id).await?;
    let file_path = quest_stream::mnd_path(&quests_dir, quest_id);
    crate::routes::static_files::file_response(
        &file_path,
        request.headers(),
        "public, max-age=0",
        QUEST_FILE_NOT_FOUND,
        "application/octet-stream",
    )
    .await
}

// ---------------------------------------------------------------------------
// Streaming delivery: manifest + boot + lazy entries
// ---------------------------------------------------------------------------

/// Сообщение то же, что у скачивания файла: различать «нет квеста» и «нет
/// прав» наружу незачем.
const QUEST_FILE_NOT_FOUND: &str = "Quest file not found";

/// Каталог `quests_files` и гейт видимости: опубликованный квест — всем,
/// неопубликованный — только автору/админу. Общий для `/file`, `/manifest`,
/// `/boot` и `/entry`, чтобы правила доступа не разъезжались.
async fn visible_quests_dir(
    state: &Arc<AppState>,
    viewer: Option<Uuid>,
    quest_id: Uuid,
) -> Result<PathBuf, ApiError> {
    let meta = sqlx::query("SELECT status, author_id FROM quests WHERE id = $1")
        .bind(quest_id)
        .fetch_optional(&state.db)
        .await?;
    let Some(meta) = meta else {
        return Err(ApiError::not_found(QUEST_FILE_NOT_FOUND));
    };
    let author_id: Uuid = meta.get("author_id");
    let status = crate::json::text_col(&meta, "status").unwrap_or_default();
    if status != "published" && !can_see_unpublished(state, viewer, Some(author_id)).await {
        return Err(ApiError::not_found(QUEST_FILE_NOT_FOUND));
    }
    let quests_dir = state.cfg.public_dir.join("quests_files");
    if !quest_stream::mnd_path(&quests_dir, quest_id).is_file() {
        return Err(ApiError::not_found(QUEST_FILE_NOT_FOUND));
    }
    Ok(quests_dir)
}

/// Манифест, а при его отсутствии — сборка артефактов. Работа с диском и
/// распаковкой ZIP уходит в blocking-пул: чтение всего архива не должно
/// занимать async-поток.
async fn ensure_stream_artifacts(quests_dir: PathBuf, quest_id: Uuid) -> Result<Value, ApiError> {
    tokio::task::spawn_blocking(move || quest_stream::load_or_build_manifest(&quests_dir, quest_id))
        .await
        .map_err(|err| {
            tracing::error!(error = %err, "quest stream task panicked");
            ApiError::internal("Server error")
        })?
        .map_err(|reason| {
            tracing::warn!(error = %reason, quest_id = %quest_id, "quest stream artifacts failed");
            ApiError::not_found(QUEST_FILE_NOT_FOUND)
        })
}

fn apply_stream_headers(response: &mut Response, etag: Option<&str>) {
    let headers = response.headers_mut();
    headers.insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("public, max-age=300"),
    );
    if let Some(etag) = etag
        && let Ok(value) = HeaderValue::from_str(etag)
    {
        headers.insert(header::ETAG, value);
    }
    headers.insert(
        HeaderName::from_static("cross-origin-resource-policy"),
        HeaderValue::from_static("same-origin"),
    );
}

fn weak_etag_match(headers: &HeaderMap, etag: &str) -> bool {
    headers
        .get(header::IF_NONE_MATCH)
        .and_then(|v| v.to_str().ok())
        .map(|raw| {
            raw.split(',')
                .any(|part| part.trim().trim_start_matches("W/") == etag.trim_start_matches("W/"))
        })
        .unwrap_or(false)
}

/// `GET /quests/{id}/manifest` — список записей архива и хеш содержимого.
async fn quest_manifest(
    State(state): State<Arc<AppState>>,
    OptionalAuth(auth): OptionalAuth,
    Path(id): Path<String>,
    request: axum::extract::Request,
) -> ApiResult {
    let quest_id = parse_id(&id)?;
    let quests_dir = visible_quests_dir(&state, auth.as_ref().map(|u| u.id), quest_id).await?;
    let manifest = ensure_stream_artifacts(quests_dir, quest_id).await?;

    let etag = format!(
        "\"{}\"",
        manifest
            .get("contentHash")
            .and_then(Value::as_str)
            .unwrap_or_default()
    );
    if weak_etag_match(request.headers(), &etag) {
        let mut response = Response::new(axum::body::Body::empty());
        *response.status_mut() = StatusCode::NOT_MODIFIED;
        apply_stream_headers(&mut response, Some(&etag));
        return Ok(response);
    }

    let body = serde_json::to_vec(&manifest).unwrap_or_else(|_| b"{}".to_vec());
    let mut response = Response::new(axum::body::Body::from(body));
    response.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/json"),
    );
    apply_stream_headers(&mut response, Some(&etag));
    Ok(response)
}

/// `GET /quests/{id}/boot` — маленький архив с текстовой частью квеста.
async fn quest_boot(
    State(state): State<Arc<AppState>>,
    OptionalAuth(auth): OptionalAuth,
    Path(id): Path<String>,
    request: axum::extract::Request,
) -> ApiResult {
    let quest_id = parse_id(&id)?;
    let quests_dir = visible_quests_dir(&state, auth.as_ref().map(|u| u.id), quest_id).await?;
    ensure_stream_artifacts(quests_dir.clone(), quest_id).await?;

    let boot = quest_stream::boot_path(&quests_dir, quest_id);
    let mut response = crate::routes::static_files::file_response(
        &boot,
        request.headers(),
        "public, max-age=300",
        QUEST_FILE_NOT_FOUND,
        "application/octet-stream",
    )
    .await?;
    let etag = response
        .headers()
        .get(header::ETAG)
        .and_then(|v| v.to_str().ok())
        .map(str::to_string);
    apply_stream_headers(&mut response, etag.as_deref());
    Ok(response)
}

/// `GET /quests/{id}/entry/{*path}` — одна запись архива по требованию.
async fn quest_entry(
    State(state): State<Arc<AppState>>,
    OptionalAuth(auth): OptionalAuth,
    Path((id, entry_path)): Path<(String, String)>,
    request: axum::extract::Request,
) -> ApiResult {
    let quest_id = parse_id(&id)?;
    let quests_dir = visible_quests_dir(&state, auth.as_ref().map(|u| u.id), quest_id).await?;
    let content_type = quest_stream::content_type_for(&entry_path);

    let path = tokio::task::spawn_blocking(move || {
        quest_stream::ensure_entry(&quests_dir, quest_id, &entry_path)
    })
    .await
    .map_err(|err| {
        tracing::error!(error = %err, "quest entry task panicked");
        ApiError::internal("Server error")
    })?
    .map_err(|reason| {
        tracing::warn!(error = %reason, "quest entry failed");
        ApiError::not_found(QUEST_FILE_NOT_FOUND)
    })?;

    let mut response = crate::routes::static_files::file_response(
        &path,
        request.headers(),
        "public, max-age=300",
        QUEST_FILE_NOT_FOUND,
        content_type,
    )
    .await?;
    // `file_response` уже поставил ETag/Last-Modified/Cache-Control; здесь
    // только CORS-режим страницы под COEP.
    response.headers_mut().insert(
        HeaderName::from_static("cross-origin-resource-policy"),
        HeaderValue::from_static("same-origin"),
    );
    Ok(response)
}

// ---------------------------------------------------------------------------
// Catalogue
// ---------------------------------------------------------------------------

async fn viewer_show_nsfw(state: &Arc<AppState>, viewer: Option<Uuid>) -> bool {
    let Some(viewer) = viewer else {
        return false;
    };
    match sqlx::query_scalar::<_, bool>("SELECT show_nsfw FROM profiles WHERE id = $1")
        .bind(viewer)
        .fetch_optional(&state.db)
        .await
    {
        Ok(value) => value.unwrap_or(false),
        Err(err) => {
            tracing::warn!(error = %err, "show_nsfw lookup failed");
            false
        }
    }
}

async fn list(
    State(state): State<Arc<AppState>>,
    OptionalAuth(auth): OptionalAuth,
    Query(query): Query<HashMap<String, String>>,
) -> ApiResult {
    let show_nsfw = viewer_show_nsfw(&state, auth.as_ref().map(|u| u.id)).await;

    // Old clients filter by labels ("Fantasy") while the database stores ids.
    // "All" and unknown values stay as-is — the SQL handles them.
    let category = query
        .get("category")
        .map(|raw| normalize_genre_id(&Value::String(raw.clone())).unwrap_or_else(|| raw.clone()));
    let tier = query
        .get("tier")
        .and_then(|raw| parse_market_tier(Some(raw)));
    let limit = query
        .get("limit")
        .and_then(|raw| raw.parse::<i64>().ok())
        .map(|value| value.clamp(1, 50));
    let offset = query
        .get("offset")
        .and_then(|raw| raw.parse::<i64>().ok())
        .unwrap_or(0)
        .max(0);

    let options = MarketListOptions {
        search: query.get("search").cloned(),
        category,
        show_nsfw,
        viewer_id: auth.as_ref().map(|u| u.id),
        tier,
        limit,
        offset,
    };
    let (text, params) = options.build();

    match bind_params(sqlx::query(&text), params)
        .fetch_all(&state.db)
        .await
    {
        Ok(rows) => {
            let body: Vec<Value> = rows
                .iter()
                .map(|row| {
                    with_public_download_url(pg_row_to_json(row), &state.cfg.base_url, false)
                })
                .collect();
            ok_json(Value::Array(body))
        }
        Err(err) => {
            tracing::error!(error = %err, "GET /quests Search failed");
            Err(ApiError::internal("Search failed"))
        }
    }
}

async fn liked_genres(State(state): State<Arc<AppState>>, auth: AuthUser) -> ApiResult {
    let result = sqlx::query(
        "SELECT DISTINCT unnest(q.genres) as genre
           FROM quest_votes qv
           JOIN quests q ON q.id = qv.quest_id
          WHERE qv.user_id = $1 AND qv.is_like = TRUE",
    )
    .bind(auth.id)
    .fetch_all(&state.db)
    .await;

    match result {
        Ok(rows) => {
            let genres: Vec<Value> = rows
                .iter()
                .filter_map(|row| row.try_get::<Option<String>, _>("genre").ok().flatten())
                .map(Value::String)
                .collect();
            ok_json(Value::Array(genres))
        }
        Err(err) => {
            tracing::error!(error = %err, "GET /quests/liked-genres failed");
            Err(ApiError::internal("Failed to load liked genres"))
        }
    }
}

/// Public genre directory: canonical ids only; the client draws its own labels.
async fn genres() -> Response {
    let body = json!({
        "genres": QUEST_GENRE_IDS.iter().map(|g| json!(g)).collect::<Vec<_>>()
    });
    let mut response = Json(body).into_response();
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("public, max-age=86400"),
    );
    response
}

async fn featured(
    State(state): State<Arc<AppState>>,
    OptionalAuth(auth): OptionalAuth,
    Query(query): Query<HashMap<String, String>>,
) -> ApiResult {
    let show_nsfw = viewer_show_nsfw(&state, auth.as_ref().map(|u| u.id)).await;
    let limit = query
        .get("limit")
        .and_then(|raw| raw.parse::<i64>().ok())
        .map(|value| value.clamp(1, 200));
    let offset = query
        .get("offset")
        .and_then(|raw| raw.parse::<i64>().ok())
        .unwrap_or(0)
        .max(0);

    let mut sql = String::from(
        "SELECT mq.*, mq.average_rating::text AS average_rating, (SELECT COALESCE(SUM(v.views), 0)::int FROM quest_views v WHERE v.quest_id = mq.id) AS views_count, p.cosmetics ->> 'name_style' AS author_name_style, p.cosmetics AS author_cosmetics FROM market_quests mq LEFT JOIN profiles p ON p.id = mq.author_id WHERE mq.status = 'published' AND mq.is_featured = TRUE",
    );
    if !show_nsfw {
        sql.push_str(" AND mq.is_nsfw = FALSE");
    }
    sql.push_str(
        " AND NOT EXISTS (SELECT 1 FROM user_blocks ub WHERE ub.user_id = $1 AND ub.blocked_id = mq.author_id)",
    );
    sql.push_str(" ORDER BY mq.market_tier ASC, mq.created_at DESC");

    let mut next = 2;
    if limit.is_some() {
        sql.push_str(&format!(" LIMIT ${next}"));
        next += 1;
    }
    if offset > 0 {
        sql.push_str(&format!(" OFFSET ${next}"));
    }

    let mut request = sqlx::query(&sql).bind(auth.as_ref().map(|u| u.id));
    if let Some(limit) = limit {
        request = request.bind(limit);
    }
    if offset > 0 {
        request = request.bind(offset);
    }

    match request.fetch_all(&state.db).await {
        Ok(rows) => {
            let body: Vec<Value> = rows
                .iter()
                .map(|row| {
                    with_public_download_url(pg_row_to_json(row), &state.cfg.base_url, false)
                })
                .collect();
            ok_json(Value::Array(body))
        }
        Err(err) => {
            tracing::error!(error = %err, "GET /quests/featured failed");
            Err(ApiError::internal("Failed to load featured quests"))
        }
    }
}

const RECENT_ACTIVITY_SQL: &str = "
WITH recent_activity AS (
    SELECT
        concat('publish:', q.id, ':', extract(epoch FROM q.created_at)::bigint) AS id,
        'quest_published'::text AS event_type,
        q.created_at,
        q.author_id AS actor_id,
        actor.full_name AS actor_name,
        actor.avatar_url AS actor_avatar_url,
        actor.is_verified AS actor_is_verified,
        actor.cosmetics ->> 'name_style' AS actor_name_style, actor.cosmetics AS actor_cosmetics,
        actor.cosmetics ->> 'avatar_frame' AS actor_avatar_frame,
        q.id AS quest_id,
        q.title AS quest_title,
        q.author_id AS target_user_id,
        actor.full_name AS target_user_name
    FROM quests q
    JOIN profiles actor ON actor.id = q.author_id
    WHERE q.status = 'published'
      AND (q.is_nsfw = FALSE OR $1 = TRUE)
    UNION ALL
    SELECT
        concat('like:', qv.quest_id, ':', qv.user_id, ':', extract(epoch FROM qv.created_at)::bigint) AS id,
        'quest_like'::text AS event_type,
        qv.created_at,
        qv.user_id AS actor_id,
        actor.full_name AS actor_name,
        actor.avatar_url AS actor_avatar_url,
        actor.is_verified AS actor_is_verified,
        actor.cosmetics ->> 'name_style' AS actor_name_style, actor.cosmetics AS actor_cosmetics,
        actor.cosmetics ->> 'avatar_frame' AS actor_avatar_frame,
        q.id AS quest_id,
        q.title AS quest_title,
        q.author_id AS target_user_id,
        target.full_name AS target_user_name
    FROM quest_votes qv
    JOIN quests q ON q.id = qv.quest_id
    JOIN profiles actor ON actor.id = qv.user_id
    JOIN profiles target ON target.id = q.author_id
    WHERE qv.is_like = TRUE
      AND q.status = 'published'
      AND (q.is_nsfw = FALSE OR $1 = TRUE)
    UNION ALL
    SELECT
        concat('review:', r.id) AS id,
        'quest_review'::text AS event_type,
        r.created_at,
        r.author_id AS actor_id,
        actor.full_name AS actor_name,
        actor.avatar_url AS actor_avatar_url,
        actor.is_verified AS actor_is_verified,
        actor.cosmetics ->> 'name_style' AS actor_name_style, actor.cosmetics AS actor_cosmetics,
        actor.cosmetics ->> 'avatar_frame' AS actor_avatar_frame,
        q.id AS quest_id,
        q.title AS quest_title,
        q.author_id AS target_user_id,
        target.full_name AS target_user_name
    FROM reviews r
    JOIN quests q ON q.id = r.quest_id
    JOIN profiles actor ON actor.id = r.author_id
    JOIN profiles target ON target.id = q.author_id
    WHERE r.status = 'approved'
      AND q.status = 'published'
      AND (q.is_nsfw = FALSE OR $1 = TRUE)
    UNION ALL
    SELECT
        concat('follow:', uf.user_id, ':', uf.follower_id, ':', extract(epoch FROM uf.created_at)::bigint) AS id,
        'user_follow'::text AS event_type,
        uf.created_at,
        uf.follower_id AS actor_id,
        actor.full_name AS actor_name,
        actor.avatar_url AS actor_avatar_url,
        actor.is_verified AS actor_is_verified,
        actor.cosmetics ->> 'name_style' AS actor_name_style, actor.cosmetics AS actor_cosmetics,
        actor.cosmetics ->> 'avatar_frame' AS actor_avatar_frame,
        q.id AS quest_id,
        q.title AS quest_title,
        uf.user_id AS target_user_id,
        target.full_name AS target_user_name
    FROM user_followers uf
    JOIN profiles actor ON actor.id = uf.follower_id
    JOIN profiles target ON target.id = uf.user_id
    LEFT JOIN LATERAL (
        SELECT id, title
        FROM quests
        WHERE author_id = uf.follower_id AND status = 'published'
        ORDER BY created_at DESC
        LIMIT 1
    ) q ON TRUE
)
SELECT * FROM recent_activity ra
WHERE NOT EXISTS (
    SELECT 1 FROM user_blocks ub
    WHERE ub.user_id = $3::uuid
      AND (ub.blocked_id = ra.actor_id OR ub.blocked_id = ra.target_user_id)
)
ORDER BY created_at DESC
LIMIT $2";

async fn recent_activity(
    State(state): State<Arc<AppState>>,
    OptionalAuth(auth): OptionalAuth,
    Query(query): Query<HashMap<String, String>>,
) -> ApiResult {
    let show_nsfw = viewer_show_nsfw(&state, auth.as_ref().map(|u| u.id)).await;
    let limit = query
        .get("limit")
        .and_then(|raw| raw.parse::<i64>().ok())
        .map(|value| value.clamp(1, 50))
        .unwrap_or(20);

    match sqlx::query(RECENT_ACTIVITY_SQL)
        .bind(show_nsfw)
        .bind(limit)
        .bind(auth.as_ref().map(|u| u.id))
        .fetch_all(&state.db)
        .await
    {
        Ok(rows) => {
            tracing::debug!(
                rows = rows.len(),
                user = ?auth.as_ref().map(|u| u.id),
                "RecentActivity loaded"
            );
            ok_json(Value::Array(
                rows.iter().map(pg_row_to_json).collect::<Vec<_>>(),
            ))
        }
        Err(err) => {
            tracing::error!(error = %err, "RecentActivity failed");
            Err(ApiError::internal("Failed to load recent activity"))
        }
    }
}

// ---------------------------------------------------------------------------
// Admin actions on one quest
// ---------------------------------------------------------------------------

async fn admin_action(
    State(state): State<Arc<AppState>>,
    AdminUser(auth): AdminUser,
    Path(id): Path<String>,
    Body(body): Body,
) -> ApiResult {
    let quest_id = parse_id(&id)?;
    let action = body.get("action").map(value_to_string).unwrap_or_default();
    let value = body.get("value").cloned().unwrap_or(Value::Null);

    let result: Result<Response, ApiError> = async {
        match action.as_str() {
            "set_demo" => {
                let is_demo = value == Value::Bool(true);
                let row = sqlx::query(
                    "UPDATE quests
                        SET is_demo = $1,
                            market_tier = CASE WHEN $1 THEN $3 ELSE $4 END,
                            updated_at = NOW()
                      WHERE id = $2 RETURNING *",
                )
                .bind(is_demo)
                .bind(quest_id)
                .bind(MARKET_TIER_DEMO)
                .bind(MARKET_TIER_MODERATED)
                .fetch_optional(&state.db)
                .await?;
                match row {
                    Some(row) => ok_json(pg_row_to_json(&row)),
                    None => Err(ApiError::not_found("Quest not found")),
                }
            }
            "set_market_tier" => {
                let Some(tier) = parse_market_tier_json(&value) else {
                    return Err(ApiError::bad_request("Invalid market tier"));
                };
                let row = sqlx::query(
                    "UPDATE quests
                        SET market_tier = $1, is_demo = ($1 = $3), updated_at = NOW()
                      WHERE id = $2 RETURNING *",
                )
                .bind(tier)
                .bind(quest_id)
                .bind(MARKET_TIER_DEMO)
                .fetch_optional(&state.db)
                .await?;
                match row {
                    Some(row) => ok_json(pg_row_to_json(&row)),
                    None => Err(ApiError::not_found("Quest not found")),
                }
            }
            "set_nsfw" => {
                let row = sqlx::query(
                    "UPDATE quests SET is_nsfw = $1, updated_at = NOW() WHERE id = $2 RETURNING *",
                )
                .bind(value == Value::Bool(true))
                .bind(quest_id)
                .fetch_optional(&state.db)
                .await?;
                match row {
                    Some(row) => ok_json(pg_row_to_json(&row)),
                    None => Err(ApiError::not_found("Quest not found")),
                }
            }
            "set_featured" => {
                let row = sqlx::query(
                    "UPDATE quests SET is_featured = $1, updated_at = NOW() WHERE id = $2 RETURNING *",
                )
                .bind(value == Value::Bool(true))
                .bind(quest_id)
                .fetch_optional(&state.db)
                .await?;
                match row {
                    Some(row) => ok_json(pg_row_to_json(&row)),
                    None => Err(ApiError::not_found("Quest not found")),
                }
            }
            "set_status" => {
                let next_status = value_to_string(&value);
                if !matches!(next_status.as_str(), "published" | "in_review" | "rejected") {
                    return Err(ApiError::bad_request("Invalid status"));
                }
                let row = sqlx::query(
                    "UPDATE quests SET status = $1::quest_status, updated_at = NOW() WHERE id = $2 RETURNING *",
                )
                .bind(&next_status)
                .bind(quest_id)
                .fetch_optional(&state.db)
                .await?;
                let Some(row) = row else {
                    return Err(ApiError::not_found("Quest not found"));
                };

                // A status change from the admin sheet used to be silent: the
                // author learned about "rejected" only in "my publications".
                let author_id: Option<Uuid> = row.try_get("author_id").ok();
                if let Some(author_id) = author_id {
                    if next_status == "published" || next_status == "rejected" {
                        let title: Option<String> = row.try_get("title").ok();
                        let state_for_notify = state.clone();
                        let kind = if next_status == "published" {
                            "quest_approved"
                        } else {
                            "quest_rejected"
                        };
                        create_notification(
                            &state_for_notify,
                            NewNotification {
                                user_id: author_id,
                                actor_id: Some(auth.id),
                                kind,
                                quest_id: Some(quest_id),
                                review_id: None,
                                payload: Some(json!({ "title": title })),
                            },
                        )
                        .await;
                    }

                    let tier_state = state.clone();
                    tokio::spawn(async move {
                        if let Err(err) = crate::services::cloud_sync_tier::recompute_tier(
                            &tier_state,
                            author_id,
                        )
                        .await
                        {
                            tracing::error!(
                                error = %err,
                                "[cloud-sync] tier recompute on status change failed"
                            );
                        }
                    });
                }
                ok_json(pg_row_to_json(&row))
            }
            _ => Err(ApiError::bad_request("Unknown admin action")),
        }
    }
    .await;

    result.map_err(|err| {
        // Node's try/catch only turns thrown (database/runtime) failures into
        // 500 "Server error"; the explicit 400/404 replies inside the try are
        // returned as-is. Keep that distinction.
        if err.status.is_client_error() {
            return err;
        }
        tracing::error!(error = %err.error, "[QuestAdminAction] failed");
        ApiError::internal("Server error")
    })
}

fn value_to_string(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

// ---------------------------------------------------------------------------
// Analytics
// ---------------------------------------------------------------------------

async fn author_analytics(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Query(query): Query<HashMap<String, String>>,
) -> ApiResult {
    let days = clamp_days(query.get("days").map(String::as_str), 30);
    match get_author_analytics(&state.db, auth.id, days).await {
        Ok(value) => ok_json(value),
        Err(err) => {
            tracing::error!(error = %err.error, "[AuthorAnalytics] failed");
            Err(ApiError::internal("Server error"))
        }
    }
}

async fn quest_analytics(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(id): Path<String>,
    Query(query): Query<HashMap<String, String>>,
) -> ApiResult {
    let quest_id = parse_id(&id)?;
    let days = clamp_days(query.get("days").map(String::as_str), 30);

    let owner: Option<Uuid> = sqlx::query_scalar("SELECT author_id FROM quests WHERE id = $1")
        .bind(quest_id)
        .fetch_optional(&state.db)
        .await?;
    let Some(owner) = owner else {
        return Err(ApiError::not_found("Quest not found"));
    };
    if owner != auth.id && !is_admin(&state, auth.id).await {
        return Err(ApiError::forbidden("Статистику видит только автор квеста"));
    }

    match get_quest_analytics(&state.db, quest_id, days).await {
        Ok(Some(value)) => ok_json(value),
        Ok(None) => Err(ApiError::not_found("Quest not found")),
        Err(err) => {
            tracing::error!(error = %err.error, "[QuestAnalytics] failed");
            Err(ApiError::internal("Server error"))
        }
    }
}

// ---------------------------------------------------------------------------
// Quest detail and per-quest reads
// ---------------------------------------------------------------------------

async fn can_view_quest(
    state: &Arc<AppState>,
    viewer: Option<Uuid>,
    quest_id: Uuid,
) -> Result<bool, ApiError> {
    let row = sqlx::query("SELECT status, author_id FROM quests WHERE id = $1")
        .bind(quest_id)
        .fetch_optional(&state.db)
        .await?;
    let Some(row) = row else { return Ok(false) };
    let status = crate::json::text_col(&row, "status").unwrap_or_default();
    if status == "published" {
        return Ok(true);
    }
    let author_id: Uuid = row.get("author_id");
    Ok(can_see_unpublished(state, viewer, Some(author_id)).await)
}

async fn quest_detail(
    State(state): State<Arc<AppState>>,
    OptionalAuth(auth): OptionalAuth,
    Path(id): Path<String>,
) -> ApiResult {
    let quest_id = parse_id(&id)?;
    let user_id = auth.as_ref().map(|u| u.id);

    let result: Result<Value, ApiError> = async {
        // A blocked author is unreachable by direct link too, otherwise a feed
        // bypass would return the same quest through a saved id.
        if let Some(user_id) = user_id {
            let blocked: Option<i32> = sqlx::query_scalar(
                "SELECT 1 FROM user_blocks ub
                   JOIN quests q ON q.author_id = ub.blocked_id
                  WHERE ub.user_id = $1 AND q.id = $2",
            )
            .bind(user_id)
            .bind(quest_id)
            .fetch_optional(&state.db)
            .await?;
            if blocked.is_some() {
                return Ok(json!({ "error": "Quest not found or access denied" }));
            }
        }

        let row = sqlx::query(
            "SELECT mq.*, mq.average_rating::text AS average_rating, (SELECT COALESCE(SUM(v.views), 0)::int FROM quest_views v WHERE v.quest_id = mq.id) AS views_count, p.cosmetics ->> 'name_style' AS author_name_style, p.cosmetics AS author_cosmetics FROM market_quests mq LEFT JOIN profiles p ON p.id = mq.author_id WHERE mq.id = $1",
        )
        .bind(quest_id)
        .fetch_optional(&state.db)
        .await?;

        let Some(row) = row else {
            // Unpublished quests are served to their author from `quests`.
            let raw = sqlx::query(
                "SELECT q.*, (SELECT COALESCE(SUM(v.views), 0)::int
                                FROM quest_views v WHERE v.quest_id = q.id) AS views_count
                   FROM quests q WHERE q.id = $1",
            )
            .bind(quest_id)
            .fetch_optional(&state.db)
            .await?;
            if let Some(raw) = raw {
                let author_id: Uuid = raw.get("author_id");
                if can_see_unpublished(&state, user_id, Some(author_id)).await {
                    return Ok(with_public_download_url(
                        pg_row_to_json(&raw),
                        &state.cfg.base_url,
                        true,
                    ));
                }
            }
            return Ok(json!({ "error": "Quest not found or access denied" }));
        };

        let author_id: Uuid = row.get("author_id");
        let status = crate::json::text_col(&row, "status").unwrap_or_default();
        let privileged = can_see_unpublished(&state, user_id, Some(author_id)).await;
        if status != "published" && !privileged {
            return Ok(json!({ "error": "Quest not found or access denied" }));
        }

        Ok(with_public_download_url(
            pg_row_to_json(&row),
            &state.cfg.base_url,
            privileged,
        ))
    }
    .await;

    match result {
        Ok(value) if value.get("error").is_some() => {
            Err(ApiError::not_found("Quest not found or access denied"))
        }
        Ok(value) => ok_json(value),
        Err(err) => {
            tracing::error!(error = %err.error, "GET /quests/:id failed");
            Err(ApiError::internal("Failed to load quest details"))
        }
    }
}

async fn reviews(
    State(state): State<Arc<AppState>>,
    OptionalAuth(auth): OptionalAuth,
    Path(id): Path<String>,
) -> ApiResult {
    let quest_id = parse_id(&id)?;
    if !can_view_quest(&state, auth.as_ref().map(|u| u.id), quest_id).await? {
        return Err(ApiError::not_found("Quest not found"));
    }

    match sqlx::query(
        "SELECT r.*, p.full_name as author_name, p.avatar_url as author_avatar_url, p.cosmetics->>'name_style' as author_name_style, p.cosmetics AS author_cosmetics, rt.rating as rating
           FROM reviews r
           JOIN profiles p ON r.author_id = p.id
           LEFT JOIN ratings rt ON (r.quest_id = rt.quest_id AND r.author_id = rt.user_id)
          WHERE r.quest_id = $1 AND r.status = 'approved'
          ORDER BY r.created_at DESC",
    )
    .bind(quest_id)
    .fetch_all(&state.db)
    .await
    {
        Ok(rows) => ok_json(Value::Array(
            rows.iter().map(pg_row_to_json).collect::<Vec<_>>(),
        )),
        Err(err) => {
            tracing::error!(error = %err, "Failed to load reviews");
            Err(ApiError::internal("Failed to load reviews"))
        }
    }
}

async fn screenshots(
    State(state): State<Arc<AppState>>,
    OptionalAuth(auth): OptionalAuth,
    Path(id): Path<String>,
) -> ApiResult {
    let quest_id = parse_id(&id)?;
    if !can_view_quest(&state, auth.as_ref().map(|u| u.id), quest_id).await? {
        return Err(ApiError::not_found("Quest not found"));
    }

    match sqlx::query("SELECT * FROM quest_screenshots WHERE quest_id = $1 ORDER BY sort_order")
        .bind(quest_id)
        .fetch_all(&state.db)
        .await
    {
        Ok(rows) => ok_json(Value::Array(
            rows.iter().map(pg_row_to_json).collect::<Vec<_>>(),
        )),
        Err(err) => {
            tracing::error!(error = %err, "Failed to load screenshots");
            Err(ApiError::internal("Failed to load screenshots"))
        }
    }
}

async fn my_vote(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(id): Path<String>,
) -> ApiResult {
    let quest_id = parse_id(&id)?;
    match sqlx::query("SELECT is_like FROM quest_votes WHERE quest_id = $1 AND user_id = $2")
        .bind(quest_id)
        .bind(auth.id)
        .fetch_optional(&state.db)
        .await
    {
        Ok(Some(row)) => {
            let is_like: bool = row.get("is_like");
            ok_json(json!({ "is_like": is_like }))
        }
        Ok(None) => ok_json(json!({})),
        Err(err) => {
            tracing::error!(error = %err, "Failed to load vote");
            Err(ApiError::internal("Failed to load vote"))
        }
    }
}

async fn my_review(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(id): Path<String>,
) -> ApiResult {
    let quest_id = parse_id(&id)?;
    let result: Result<Value, ApiError> = async {
        let rating: Option<i16> =
            sqlx::query_scalar("SELECT rating FROM ratings WHERE quest_id = $1 AND user_id = $2")
                .bind(quest_id)
                .bind(auth.id)
                .fetch_optional(&state.db)
                .await?;
        let text: Option<String> = sqlx::query_scalar(
            "SELECT text_content FROM reviews WHERE quest_id = $1 AND author_id = $2",
        )
        .bind(quest_id)
        .bind(auth.id)
        .fetch_optional(&state.db)
        .await?;

        // `undefined` keys disappear from the Node answer, so a missing rating
        // means an absent key rather than a null one.
        let mut body = Map::new();
        if let Some(rating) = rating {
            body.insert("rating".into(), json!(rating));
        }
        if let Some(text) = text {
            body.insert("text_content".into(), json!(text));
        }
        Ok(Value::Object(body))
    }
    .await;

    match result {
        Ok(value) => ok_json(value),
        Err(err) => {
            tracing::error!(error = %err.error, "Failed to load review data");
            Err(ApiError::internal("Failed to load review data"))
        }
    }
}

// ---------------------------------------------------------------------------
// Rating and review
// ---------------------------------------------------------------------------

/// `Number(value)` for the shapes a JSON/form body can produce.
fn js_number(value: Option<&Value>) -> Option<f64> {
    match value? {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => {
            let trimmed = s.trim();
            if trimmed.is_empty() {
                Some(0.0)
            } else {
                trimmed.parse::<f64>().ok()
            }
        }
        Value::Bool(b) => Some(if *b { 1.0 } else { 0.0 }),
        Value::Null => Some(0.0),
        _ => None,
    }
}

async fn rate(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(id): Path<String>,
    Body(body): Body,
) -> ApiResult {
    let quest_id = parse_id(&id)?;

    // The value used to go straight into INSERT: the CHECK/FK failure became a
    // 500, which the client renders as "server maintenance" instead of "the
    // quest is gone".
    let value = js_number(body.get("rating"));
    let Some(rating) = value.filter(|v| v.fract() == 0.0 && (1.0..=5.0).contains(v)) else {
        return Err(ApiError::bad_request(
            "Rating must be an integer from 1 to 5",
        ));
    };
    let rating = rating as i32;

    let exists: Option<Uuid> = sqlx::query_scalar("SELECT id FROM quests WHERE id = $1")
        .bind(quest_id)
        .fetch_optional(&state.db)
        .await
        .map_err(|err| {
            tracing::error!(error = %err, "rating quest lookup failed");
            ApiError::internal("Server error")
        })?;
    if exists.is_none() {
        return Err(ApiError::not_found("Quest not found"));
    }

    match sqlx::query(
        "INSERT INTO ratings (quest_id, user_id, rating) VALUES ($1, $2, $3)
         ON CONFLICT (quest_id, user_id) DO UPDATE SET rating = $3, created_at = NOW()",
    )
    .bind(quest_id)
    .bind(auth.id)
    .bind(rating)
    .execute(&state.db)
    .await
    {
        Ok(_) => ok_json(json!({ "success": true })),
        Err(err) => {
            tracing::error!(error = %err, "rating insert failed");
            Err(ApiError::internal("Server error"))
        }
    }
}

async fn review(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(id): Path<String>,
    Body(body): Body,
) -> ApiResult {
    let quest_id = parse_id(&id)?;
    let text_content = body
        .get("text_content")
        .and_then(Value::as_str)
        .map(str::to_string);

    let fail = |err: sqlx::Error, context: &str| {
        tracing::error!(error = %err, context, "review failed");
        ApiError::internal("Server error")
    };

    let user_check: Option<Option<bool>> =
        sqlx::query_scalar("SELECT is_blocked FROM profiles WHERE id = $1")
            .bind(auth.id)
            .fetch_optional(&state.db)
            .await
            .map_err(|err| fail(err, "review user lookup"))?;
    let Some(blocked) = user_check else {
        return Err(ApiError::not_found("User not found"));
    };
    if blocked == Some(true) {
        return Err(ApiError::forbidden(
            "Your account is blocked. You cannot post reviews.",
        ));
    }

    if let Some(text) = text_content
        .as_ref()
        .filter(|t| t.trim().chars().count() > 2)
    {
        let quest_author: Option<Uuid> =
            sqlx::query_scalar("SELECT author_id FROM quests WHERE id = $1")
                .bind(quest_id)
                .fetch_optional(&state.db)
                .await
                .map_err(|err| fail(err, "review quest lookup"))?;
        let allow_ads = quest_author == Some(auth.id) || is_staff(&state, Some(auth.id)).await;
        let verdict = moderate_review(text, allow_ads);
        if !verdict.approved {
            return Err(ApiError::bad_request(format!(
                "Review not allowed: {}",
                verdict.reason
            )));
        }
    }

    let existing: Option<Uuid> =
        sqlx::query_scalar("SELECT id FROM reviews WHERE quest_id = $1 AND author_id = $2")
            .bind(quest_id)
            .bind(auth.id)
            .fetch_optional(&state.db)
            .await
            .map_err(|err| fail(err, "review existing lookup"))?;

    let mut is_new_review = false;
    let review_id: Option<Uuid> = match existing {
        Some(id) => {
            sqlx::query(
                "UPDATE reviews SET text_content = $1, status = 'approved', created_at = NOW() WHERE id = $2",
            )
            .bind(text_content.as_deref())
            .bind(id)
            .execute(&state.db)
            .await
            .map_err(|err| fail(err, "review update"))?;
            Some(id)
        }
        None => {
            let inserted: Option<Uuid> = sqlx::query_scalar(
                "INSERT INTO reviews (id, quest_id, author_id, text_content, status)
                 VALUES (gen_random_uuid(), $1, $2, $3, 'approved') RETURNING id",
            )
            .bind(quest_id)
            .bind(auth.id)
            .bind(text_content.as_deref())
            .fetch_optional(&state.db)
            .await
            .map_err(|err| fail(err, "review insert"))?;
            is_new_review = true;
            award_achievement(&state, auth.id, "critic_bronze").await;
            inserted
        }
    };

    if is_new_review {
        let quest: Option<(Uuid, Option<String>)> =
            sqlx::query_as("SELECT author_id, title FROM quests WHERE id = $1")
                .bind(quest_id)
                .fetch_optional(&state.db)
                .await
                .map_err(|err| fail(err, "review quest author lookup"))?;
        if let Some((author_id, title)) = quest
            && author_id != auth.id
        {
            create_notification(
                &state,
                NewNotification {
                    user_id: author_id,
                    actor_id: Some(auth.id),
                    kind: "quest_review",
                    quest_id: Some(quest_id),
                    review_id,
                    payload: Some(json!({ "title": title })),
                },
            )
            .await;
        }
    }

    ok_json(json!({ "success": true, "status": "approved" }))
}
#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::StatusCode;

    /// `Router::route`/`merge` паникуют на конфликте путей: сборка таблицы
    /// маршрутов и есть проверка, что потоковые маршруты не пересекаются с
    /// обычными `/quests`.
    #[tokio::test]
    async fn streaming_routes_build_without_conflicts() {
        let _ = router(crate::state::AppState::for_tests());
    }

    #[test]
    fn strip_html_matches_the_node_regex() {
        assert_eq!(strip_html("  <b>bold</b> text  "), "bold text");
        assert_eq!(strip_html("a < b"), "a < b");
        assert_eq!(strip_html("<script>alert(1)</script>"), "alert(1)");
        assert_eq!(strip_html("a <b>c"), "a c");
    }

    #[test]
    fn sanitize_text_caps_length_after_stripping() {
        assert_eq!(sanitize_text("<i>abcdef</i>", 3), "abc");
        assert_eq!(sanitize_text("", 200), "");
    }

    #[test]
    fn download_urls_follow_the_public_route() {
        assert_eq!(
            public_download_url("https://m.example/", "q-1"),
            "https://m.example/quests/q-1/file"
        );
        let row = json!({"id": "q-1", "download_url": "old", "moderator_comment": "note"});
        let public = with_public_download_url(row.clone(), "https://m.example", false);
        assert_eq!(
            public["download_url"],
            json!("https://m.example/quests/q-1/file")
        );
        assert!(public.get("moderator_comment").is_none());

        let privileged = with_public_download_url(row, "https://m.example", true);
        assert_eq!(privileged["moderator_comment"], json!("note"));
    }

    #[test]
    fn rating_numbers_follow_javascript_coercion() {
        assert_eq!(js_number(Some(&json!(3))), Some(3.0));
        assert_eq!(js_number(Some(&json!("4"))), Some(4.0));
        assert_eq!(js_number(Some(&json!(" 5 "))), Some(5.0));
        assert_eq!(js_number(Some(&json!(true))), Some(1.0));
        assert_eq!(js_number(Some(&json!(""))), Some(0.0));
        assert_eq!(js_number(Some(&Value::Null)), Some(0.0));
        assert_eq!(js_number(Some(&json!("x"))), None);
        assert_eq!(js_number(None), None);
    }

    #[test]
    fn invalid_id_format_is_a_client_error() {
        let err = parse_id("not-a-uuid").unwrap_err();
        assert_eq!(err.status, StatusCode::BAD_REQUEST);
        assert_eq!(err.error, "Invalid ID format");
        assert!(parse_id("00000000-0000-4000-8000-000000000000").is_ok());
    }
}
