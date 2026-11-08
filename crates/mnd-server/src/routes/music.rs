//! Music tracks: upload, list, download, votes and reviews.
//! Port of `backend/src/routes/music.ts`.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use axum::body::Body as AxumBody;
use axum::extract::{Path, Query, State};
use axum::http::{HeaderValue, StatusCode, header};
use axum::response::Response;
use axum::{Router, routing::get, routing::post};
use chrono::Utc;
use regex::Regex;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sqlx::Row;
use tokio::fs;
use tokio_util::io::ReaderStream;
use uuid::Uuid;

use crate::auth::{AuthUser, OptionalAuth};
use crate::error::{ApiError, ApiResult, ok_created, ok_json};
use crate::extractors::Body;
use crate::extractors::FormData;
use crate::json::{parse_int, parse_uuid, pg_row_to_json, rows_to_json};
use crate::services::achievements::award_achievement;
use crate::services::image_host::save_uploaded_image;
use crate::services::moderation::moderate_review;
use crate::services::notifications::{NewNotification, create_notification};
use crate::services::visibility::{can_see_unpublished, is_staff};
use crate::state::AppState;

const UPLOAD_LIMIT: usize = 100 * 1024 * 1024;

const ALLOWED_AUDIO_EXTS: &[&str] = &[".mp3", ".wav", ".ogg", ".m4a", ".flac", ".aac"];
const ALLOWED_COVER_EXTS: &[&str] = &[".jpg", ".jpeg", ".png", ".webp"];

static HTML_TAG_RE: std::sync::LazyLock<Regex> =
    std::sync::LazyLock::new(|| Regex::new(r"<[^>]*>").expect("static regex"));

fn sanitize_text(s: &str, max_len: usize) -> String {
    let cleaned = HTML_TAG_RE.replace_all(s, "");
    cleaned.trim().chars().take(max_len).collect()
}

fn music_storage_dir(state: &AppState) -> PathBuf {
    state.cfg.public_dir.join("music_files")
}

fn music_file_url(state: &AppState, id: Uuid) -> String {
    format!(
        "{}/music/{}/file",
        state.cfg.base_url.trim_end_matches('/'),
        id
    )
}

async fn hash_file(path: &std::path::Path) -> Result<String, ApiError> {
    let bytes = fs::read(path).await?;
    Ok(hex::encode(Sha256::digest(&bytes)))
}

fn content_type_for_audio(ext: &str) -> &'static str {
    match ext {
        ".mp3" => "audio/mpeg",
        ".wav" => "audio/wav",
        ".ogg" => "audio/ogg",
        ".m4a" => "audio/mp4",
        ".flac" => "audio/flac",
        ".aac" => "audio/aac",
        _ => "application/octet-stream",
    }
}

fn parse_genres(form: &FormData, fallback: Option<&str>) -> Vec<String> {
    let mut out = Vec::new();
    match form.value("genres") {
        Value::Array(arr) => {
            for v in arr {
                if let Some(s) = v.as_str() {
                    let cleaned = sanitize_text(s, 100);
                    if !cleaned.is_empty() && !out.contains(&cleaned) {
                        out.push(cleaned);
                    }
                }
            }
        }
        Value::String(s) => {
            if let Ok(Value::Array(arr)) = serde_json::from_str::<Value>(&s) {
                for v in arr {
                    if let Some(s) = v.as_str() {
                        let cleaned = sanitize_text(s, 100);
                        if !cleaned.is_empty() && !out.contains(&cleaned) {
                            out.push(cleaned);
                        }
                    }
                }
            }
        }
        _ => {}
    }
    if out.is_empty() {
        if let Some(f) = fallback {
            let cleaned = sanitize_text(f, 100);
            if !cleaned.is_empty() {
                out.push(cleaned);
            }
        }
    }
    out
}

async fn upload_track(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    request: axum::extract::Request,
) -> ApiResult {
    let form = match crate::extractors::upload_form(request, &state, UPLOAD_LIMIT).await {
        Ok(form) => form,
        Err(crate::extractors::UploadFormError::TooLarge) => {
            return Err(crate::error::payload_too_large());
        }
        Err(crate::extractors::UploadFormError::BadJson) => {
            return Err(ApiError::bad_request("Bad JSON format"));
        }
        Err(crate::extractors::UploadFormError::Multipart(message)) => {
            return Err(crate::error::multer_error(message));
        }
    };
    // multer rejects unknown parts and filtered files before the handler runs.
    for file in &form.files {
        let ext = crate::services::image_host::extension_of(&file.file_name);
        match file.field.as_str() {
            "musicFile" if !ALLOWED_AUDIO_EXTS.contains(&ext.as_str()) => {
                return Err(crate::error::upload_error("Invalid music file type"));
            }
            "cover" if !ALLOWED_COVER_EXTS.contains(&ext.as_str()) => {
                return Err(crate::error::upload_error("Invalid image file type"));
            }
            "musicFile" | "cover" => {}
            _ => return Err(crate::error::multer_error("Unexpected file field")),
        }
    }
    let music_file = form
        .file("musicFile")
        .ok_or_else(|| ApiError::bad_request("musicFile is required"))?;
    let cover_file = form.file("cover");

    let user_id = auth.id;

    // Blocked check + 5 uploads per hour. Node wraps both queries in one
    // try/catch and only logs failures, so a database hiccup must not block
    // the upload.
    match sqlx::query_scalar::<_, bool>("SELECT is_blocked FROM profiles WHERE id = $1")
        .bind(user_id)
        .fetch_optional(&state.db)
        .await
    {
        Ok(Some(true)) => return Err(ApiError::forbidden("You are blocked")),
        Ok(_) => {
            match sqlx::query_scalar::<_, i64>(
                "SELECT COUNT(*) FROM music_tracks WHERE author_id = $1 AND created_at > NOW() - INTERVAL '1 hour'",
            )
            .bind(user_id)
            .fetch_optional(&state.db)
            .await
            {
                Ok(Some(count)) if count >= 5 => {
                    return Err(ApiError::new(
                        StatusCode::TOO_MANY_REQUESTS,
                        "Too many uploads. Max 5 per hour.",
                    ));
                }
                Ok(_) => {}
                Err(err) => tracing::warn!(error = %err, "[music] spam check failed"),
            }
        }
        Err(err) => tracing::warn!(error = %err, "[music] spam check failed"),
    }

    // Validate file extension for the main audio file.
    let ext = music_file
        .file_name
        .rsplit('.')
        .next()
        .map(|s| format!(".{}", s.to_ascii_lowercase()))
        .unwrap_or_else(|| ".mp3".to_string());
    if !ALLOWED_AUDIO_EXTS.contains(&ext.as_str()) {
        return Err(crate::error::upload_error("Invalid music file type"));
    }

    let title = sanitize_text(form.str("title").unwrap_or(""), 200);
    let performer = sanitize_text(form.str("performer").unwrap_or(""), 200);
    let genre = form
        .str("genre")
        .map(|s| sanitize_text(s, 100))
        .filter(|s| !s.is_empty());
    let license = sanitize_text(form.str("license").unwrap_or("CC-BY"), 500);
    let description = form
        .str("description")
        .map(|s| sanitize_text(s, 2000))
        .filter(|s| !s.is_empty());
    let genres = parse_genres(&form, genre.as_deref());

    if title.is_empty() {
        return Err(ApiError::bad_request("title is required"));
    }
    if performer.is_empty() {
        return Err(ApiError::bad_request("performer is required"));
    }
    if license.is_empty() {
        return Err(ApiError::bad_request("license is required"));
    }

    let id = Uuid::new_v4();
    let dest_name = format!("{}{}", id, ext);
    let dest_path = music_storage_dir(&state).join(&dest_name);
    fs::create_dir_all(music_storage_dir(&state)).await?;
    fs::copy(&music_file.path, &dest_path).await?;

    let file_hash = hash_file(&dest_path).await?;
    let file_size = fs::metadata(&dest_path).await?.len() as i64;

    // Global hash deduplication; Node only logs lookup failures.
    if let Ok(Some(_dup_id)) =
        sqlx::query_scalar::<_, Uuid>("SELECT id FROM music_tracks WHERE file_hash = $1 LIMIT 1")
            .bind(&file_hash)
            .fetch_optional(&state.db)
            .await
    {
        let _ = fs::remove_file(&dest_path).await;
        return Err(ApiError::conflict("Duplicate file (already uploaded)"));
    }

    let mut cover_url: Option<String> = None;
    if let Some(cover) = cover_file {
        // Cover extension check.
        let cover_ext = cover
            .file_name
            .rsplit('.')
            .next()
            .map(|s| format!(".{}", s.to_ascii_lowercase()))
            .unwrap_or_default();
        if !ALLOWED_COVER_EXTS.contains(&cover_ext.as_str()) {
            return Err(crate::error::upload_error("Invalid image file type"));
        }
        match fs::read(&cover.path).await {
            Ok(bytes) => {
                let uploads_dir = state.cfg.public_dir.join("uploads");
                match save_uploaded_image(
                    &uploads_dir,
                    &bytes,
                    &cover.file_name,
                    &state.cfg.base_url,
                ) {
                    Ok(url) => cover_url = Some(url),
                    Err(err) => {
                        tracing::warn!(error = %err, "[music] cover upload failed");
                    }
                }
            }
            Err(err) => {
                tracing::warn!(error = %err, "[music] cover read failed");
            }
        }
    }

    let file_url = music_file_url(&state, id);
    let now = Utc::now();
    let row = sqlx::query(
        "INSERT INTO music_tracks \
         (id, title, performer, description, genre, genres, file_url, cover_url, license, file_hash, file_size_bytes, status, author_id, created_at, updated_at) \
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, 'in_review', $12, $13, $13) \
         RETURNING *",
    )
    .bind(id)
    .bind(&title)
    .bind(&performer)
    .bind(description.as_deref())
    .bind(genre.as_deref().or(genres.first().map(String::as_str)))
    .bind(&genres)
    .bind(&file_url)
    .bind(cover_url.as_deref())
    .bind(&license)
    .bind(&file_hash)
    .bind(file_size)
    .bind(user_id)
    .bind(now)
    .fetch_one(&state.db)
    .await?;

    let author = sqlx::query(
        "SELECT full_name, is_verified, cosmetics->>'name_style' AS name_style, cosmetics FROM profiles WHERE id = $1",
    )
    .bind(user_id)
    .fetch_optional(&state.db)
    .await?;

    let mut out = pg_row_to_json(&row);
    if let Value::Object(ref mut map) = out {
        if let Some(Value::String(name)) = author.as_ref().and_then(|r| {
            let row = pg_row_to_json(r);
            row.get("full_name").cloned()
        }) {
            map.insert("author_name".to_string(), Value::String(name));
        } else {
            map.insert("author_name".to_string(), Value::Null);
        }
        map.insert(
            "author_is_verified".to_string(),
            author
                .as_ref()
                .and_then(|r| r.try_get::<bool, _>("is_verified").ok())
                .map(Value::Bool)
                .unwrap_or(Value::Bool(false)),
        );
        map.insert(
            "author_name_style".to_string(),
            author
                .as_ref()
                .and_then(|r| r.try_get::<Option<String>, _>("name_style").ok().flatten())
                .map(Value::String)
                .unwrap_or(Value::Null),
        );
        map.insert(
            "author_cosmetics".to_string(),
            author
                .as_ref()
                .and_then(|r| r.try_get::<Value, _>("cosmetics").ok())
                .unwrap_or(Value::Null),
        );
        map.insert("download_url".to_string(), Value::String(file_url.clone()));
        map.insert("file_url".to_string(), Value::String(file_url));
    }

    ok_created(out)
}

async fn list_music(
    State(state): State<Arc<AppState>>,
    _auth: OptionalAuth,
    Query(params): Query<HashMap<String, String>>,
) -> ApiResult {
    let search = params.get("search").map(|s| s.as_str()).unwrap_or("");
    let genre = params.get("genre").map(|s| s.as_str()).unwrap_or("");
    let limit = parse_int(params.get("limit").map(|s| s.as_str()))
        .map(|v| v.clamp(1, 200))
        .unwrap_or(50) as i64;
    let offset = parse_int(params.get("offset").map(|s| s.as_str()))
        .map(|v| v.max(0))
        .unwrap_or(0) as i64;

    let mut where_clauses = vec!["status = 'published'".to_string()];
    let mut args: Vec<(i32, String)> = Vec::new();
    let mut idx = 1;
    if !search.is_empty() {
        where_clauses.push(format!("(title ILIKE ${idx} OR performer ILIKE ${idx})"));
        args.push((idx, format!("%{}%", search)));
        idx += 1;
    }
    if !genre.is_empty() {
        where_clauses.push(format!("(genre = ${idx} OR ${idx} = ANY(genres))"));
        args.push((idx, genre.to_string()));
        idx += 1;
    }
    let where_sql = where_clauses.join(" AND ");
    let sql = format!(
        "SELECT m.*, p.full_name AS author_name, p.is_verified AS author_is_verified, \
         p.cosmetics->>'name_style' AS author_name_style, p.cosmetics AS author_cosmetics \
         FROM music_tracks m LEFT JOIN profiles p ON m.author_id = p.id \
         WHERE {where_sql} ORDER BY m.created_at DESC LIMIT ${idx} OFFSET ${}",
        idx + 1
    );

    let mut query = sqlx::query(&sql);
    for (_, value) in args {
        query = query.bind(value);
    }
    query = query.bind(limit).bind(offset);
    let rows = query.fetch_all(&state.db).await?;

    let items = rows
        .iter()
        .map(|r| {
            let mut obj = pg_row_to_json(r);
            if let Value::Object(ref mut map) = obj {
                if let Some(Value::String(id)) = map.get("id").cloned() {
                    if let Ok(uuid) = Uuid::parse_str(&id) {
                        let url = music_file_url(&state, uuid);
                        map.insert("download_url".to_string(), Value::String(url.clone()));
                        map.insert("file_url".to_string(), Value::String(url));
                    }
                }
            }
            obj
        })
        .collect::<Vec<_>>();

    ok_json(json!(items))
}

async fn get_music(
    State(state): State<Arc<AppState>>,
    auth: OptionalAuth,
    Path(id): Path<String>,
) -> ApiResult {
    let id = parse_uuid(Some(&id)).ok_or_else(|| ApiError::bad_request("Invalid id"))?;
    let row = sqlx::query(
        "SELECT m.*, p.full_name AS author_name, p.is_verified AS author_is_verified, \
         p.cosmetics->>'name_style' AS author_name_style, p.cosmetics AS author_cosmetics \
         FROM music_tracks m LEFT JOIN profiles p ON m.author_id = p.id \
         WHERE m.id = $1",
    )
    .bind(id)
    .fetch_optional(&state.db)
    .await?;

    let row = row.ok_or_else(|| ApiError::not_found("Not found"))?;
    let author_id: Option<Uuid> = row.try_get("author_id").ok();
    let status = crate::json::text_col(&row, "status");
    if status.as_deref() != Some("published")
        && !can_see_unpublished(&state, auth.0.map(|u| u.id), author_id).await
    {
        return Err(ApiError::forbidden("Not published"));
    }

    let mut out = pg_row_to_json(&row);
    if let Value::Object(ref mut map) = out {
        let url = music_file_url(&state, id);
        map.insert("download_url".to_string(), Value::String(url.clone()));
        map.insert("file_url".to_string(), Value::String(url));
    }
    ok_json(out)
}

async fn stream_music(
    State(state): State<Arc<AppState>>,
    auth: OptionalAuth,
    Path(id): Path<String>,
) -> ApiResult {
    let id = parse_uuid(Some(&id)).ok_or_else(|| ApiError::bad_request("Invalid id"))?;
    let row = sqlx::query("SELECT status, author_id FROM music_tracks WHERE id = $1")
        .bind(id)
        .fetch_optional(&state.db)
        .await?;
    let row = row.ok_or_else(|| ApiError::not_found("Not found"))?;
    let status = crate::json::text_col(&row, "status");
    let author_id: Option<Uuid> = row.try_get("author_id").ok();
    if status.as_deref() != Some("published")
        && !can_see_unpublished(&state, auth.0.map(|u| u.id), author_id).await
    {
        return Err(ApiError::forbidden("Not published"));
    }

    let mut entries = fs::read_dir(music_storage_dir(&state)).await?;
    let mut matched: Option<String> = None;
    while let Some(entry) = entries.next_entry().await? {
        let name = entry.file_name().to_string_lossy().to_string();
        if name.starts_with(&format!("{}.", id)) {
            matched = Some(name);
            break;
        }
    }
    let name = matched.ok_or_else(|| ApiError::not_found("File not found on storage"))?;
    let full = music_storage_dir(&state).join(&name);

    let ext = name.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
    let content_type = content_type_for_audio(&format!(".{}", ext));
    let disposition = if content_type.starts_with("audio/") {
        format!("inline; filename=\"{}\"", name)
    } else {
        format!("attachment; filename=\"{}\"", name)
    };

    let file = fs::File::open(&full).await?;
    let metadata = file.metadata().await?;
    let stream = ReaderStream::new(file);
    let body = AxumBody::from_stream(stream);

    let mut resp = Response::new(body);
    resp.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_str(content_type)
            .unwrap_or_else(|_| HeaderValue::from_static("application/octet-stream")),
    );
    resp.headers_mut().insert(
        header::X_CONTENT_TYPE_OPTIONS,
        HeaderValue::from_static("nosniff"),
    );
    resp.headers_mut().insert(
        header::CONTENT_DISPOSITION,
        HeaderValue::from_str(&disposition)
            .unwrap_or_else(|_| HeaderValue::from_static("attachment")),
    );
    resp.headers_mut().insert(
        header::CONTENT_LENGTH,
        HeaderValue::from_str(&metadata.len().to_string())
            .unwrap_or_else(|_| HeaderValue::from_static("0")),
    );
    Ok(resp)
}

async fn delete_music(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(id): Path<String>,
) -> ApiResult {
    let id = parse_uuid(Some(&id)).ok_or_else(|| ApiError::bad_request("Invalid id"))?;
    let row = sqlx::query("SELECT author_id FROM music_tracks WHERE id = $1")
        .bind(id)
        .fetch_optional(&state.db)
        .await?;
    let row = row.ok_or_else(|| ApiError::not_found("Not found"))?;
    let author_id: Option<Uuid> = row.try_get("author_id").ok();

    let is_admin = sqlx::query_scalar::<_, String>("SELECT role FROM profiles WHERE id = $1")
        .bind(auth.id)
        .fetch_optional(&state.db)
        .await?
        .map(|r| r == "admin")
        .unwrap_or(false);

    if author_id != Some(auth.id) && !is_admin {
        return Err(ApiError::forbidden("Forbidden"));
    }

    sqlx::query("DELETE FROM music_tracks WHERE id = $1")
        .bind(id)
        .execute(&state.db)
        .await?;

    let mut entries = fs::read_dir(music_storage_dir(&state)).await?;
    while let Some(entry) = entries.next_entry().await? {
        let name = entry.file_name().to_string_lossy().to_string();
        if name.starts_with(&format!("{}.", id)) {
            let _ = fs::remove_file(entry.path()).await;
            break;
        }
    }

    ok_json(json!({"ok": true}))
}

async fn admin_action_music(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(id): Path<String>,
    body: Body,
) -> ApiResult {
    let id = parse_uuid(Some(&id)).ok_or_else(|| ApiError::bad_request("Invalid id"))?;

    let is_admin = sqlx::query_scalar::<_, String>("SELECT role FROM profiles WHERE id = $1")
        .bind(auth.id)
        .fetch_optional(&state.db)
        .await?
        .map(|r| r == "admin")
        .unwrap_or(false);
    if !is_admin {
        return Err(ApiError::forbidden("Admin only"));
    }

    let action = body.str("action").unwrap_or("");
    if action != "set_status" {
        return Err(ApiError::bad_request("Unknown action"));
    }
    let value = body.str("value").unwrap_or("");
    if !matches!(value, "published" | "in_review" | "rejected") {
        return Err(ApiError::bad_request("Invalid status"));
    }

    sqlx::query(
        "UPDATE music_tracks SET status = $1::music_status, updated_at = NOW() WHERE id = $2",
    )
    .bind(value)
    .bind(id)
    .execute(&state.db)
    .await?;

    let row = sqlx::query(
        "SELECT m.*, p.full_name AS author_name, p.is_verified AS author_is_verified, \
         p.cosmetics->>'name_style' AS author_name_style, p.cosmetics AS author_cosmetics \
         FROM music_tracks m LEFT JOIN profiles p ON m.author_id = p.id \
         WHERE m.id = $1",
    )
    .bind(id)
    .fetch_one(&state.db)
    .await?;

    let author_id: Option<Uuid> = row.try_get("author_id").ok();
    let title: Option<String> = row.try_get("title").ok();
    if let Some(uid) = author_id {
        let kind = match value {
            "published" => "music_published",
            "rejected" => "music_rejected",
            _ => "",
        };
        if !kind.is_empty() {
            let payload = title.as_ref().map(|t| json!({"title": t}));
            let _ = create_notification(
                &state,
                NewNotification {
                    user_id: uid,
                    actor_id: Some(auth.id),
                    kind,
                    quest_id: None,
                    review_id: None,
                    payload,
                },
            )
            .await;
        }
    }

    ok_json(pg_row_to_json(&row))
}

async fn vote_music(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(id): Path<String>,
    body: Body,
) -> ApiResult {
    let id = parse_uuid(Some(&id)).ok_or_else(|| ApiError::bad_request("Invalid ID format"))?;

    let action = body.str("action").unwrap_or("");
    let is_like = body.bool("is_like").unwrap_or(false);

    let outcome: ApiResult = async {
        let existing: Option<bool> = sqlx::query_scalar(
            "SELECT is_like FROM music_votes WHERE music_id = $1 AND user_id = $2",
        )
        .bind(id)
        .bind(auth.id)
        .fetch_optional(&state.db)
        .await?;

        if action == "remove" {
            sqlx::query("DELETE FROM music_votes WHERE music_id = $1 AND user_id = $2")
                .bind(id)
                .bind(auth.id)
                .execute(&state.db)
                .await?;
        } else {
            sqlx::query(
                "INSERT INTO music_votes (music_id, user_id, is_like) VALUES ($1, $2, $3) \
             ON CONFLICT (music_id, user_id) DO UPDATE SET is_like = $3, created_at = NOW()",
            )
            .bind(id)
            .bind(auth.id)
            .bind(is_like)
            .execute(&state.db)
            .await?;

            if is_like && existing != Some(true) {
                let likes: Option<i64> = sqlx::query_scalar(
                    "SELECT COUNT(*) FROM music_votes WHERE user_id = $1 AND is_like = TRUE",
                )
                .bind(auth.id)
                .fetch_optional(&state.db)
                .await
                .ok()
                .flatten();
                if likes.unwrap_or(0) >= 20 {
                    let _ = award_achievement(&state, auth.id, "generous").await;
                }
            }
        }

        let likes: Option<i64> = sqlx::query_scalar(
            "SELECT COUNT(*) FROM music_votes WHERE music_id = $1 AND is_like = TRUE",
        )
        .bind(id)
        .fetch_optional(&state.db)
        .await?;
        let dislikes: Option<i64> = sqlx::query_scalar(
            "SELECT COUNT(*) FROM music_votes WHERE music_id = $1 AND is_like = FALSE",
        )
        .bind(id)
        .fetch_optional(&state.db)
        .await?;

        let likes_i32 = likes.unwrap_or(0) as i32;
        let dislikes_i32 = dislikes.unwrap_or(0) as i32;
        let _ = sqlx::query(
            "UPDATE music_tracks SET like_count = $1, dislike_count = $2 WHERE id = $3",
        )
        .bind(likes_i32)
        .bind(dislikes_i32)
        .bind(id)
        .execute(&state.db)
        .await;

        ok_json(json!({
            "success": true,
            "likes": likes.unwrap_or(0),
            "dislikes": dislikes.unwrap_or(0),
        }))
    }
    .await;

    outcome.map_err(|err| {
        tracing::error!(error = %err, "music vote");
        ApiError::internal("Vote error")
    })
}

async fn my_vote_music(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(id): Path<String>,
) -> ApiResult {
    let id = parse_uuid(Some(&id)).ok_or_else(|| ApiError::bad_request("Invalid ID format"))?;
    let row = sqlx::query("SELECT is_like FROM music_votes WHERE music_id = $1 AND user_id = $2")
        .bind(id)
        .bind(auth.id)
        .fetch_optional(&state.db)
        .await?;
    match row {
        Some(r) => ok_json(pg_row_to_json(&r)),
        None => ok_json(json!({})),
    }
}

async fn list_reviews_music(
    State(state): State<Arc<AppState>>,
    _auth: OptionalAuth,
    Path(id): Path<String>,
) -> ApiResult {
    let id = parse_uuid(Some(&id)).ok_or_else(|| ApiError::bad_request("Invalid ID format"))?;
    let rows = sqlx::query(
        "SELECT r.*, p.full_name AS author_name, p.avatar_url AS author_avatar_url, \
         p.cosmetics->>'name_style' AS author_name_style, p.cosmetics AS author_cosmetics \
         FROM music_reviews r JOIN profiles p ON r.author_id = p.id \
         WHERE r.music_id = $1 AND r.status = 'approved' ORDER BY r.created_at DESC",
    )
    .bind(id)
    .fetch_all(&state.db)
    .await?;
    ok_json(rows_to_json(&rows))
}

async fn my_review_music(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(id): Path<String>,
) -> ApiResult {
    let id = parse_uuid(Some(&id)).ok_or_else(|| ApiError::bad_request("Invalid ID format"))?;
    let row = sqlx::query(
        "SELECT text_content, status FROM music_reviews WHERE music_id = $1 AND author_id = $2",
    )
    .bind(id)
    .bind(auth.id)
    .fetch_optional(&state.db)
    .await?;
    match row {
        Some(r) => {
            let text: String = r.try_get("text_content").unwrap_or_default();
            let status = crate::json::text_col(&r, "status").unwrap_or_default();
            ok_json(json!({
                "rating": 0,
                "text": text,
                "text_content": text,
                "status": status,
            }))
        }
        None => ok_json(json!({})),
    }
}

async fn post_review_music(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(id): Path<String>,
    body: Body,
) -> ApiResult {
    let id = parse_uuid(Some(&id)).ok_or_else(|| ApiError::bad_request("Invalid ID format"))?;
    let text_content = body.str("text_content").unwrap_or("");

    let blocked: Option<bool> = sqlx::query_scalar("SELECT is_blocked FROM profiles WHERE id = $1")
        .bind(auth.id)
        .fetch_optional(&state.db)
        .await?;
    if blocked == Some(true) {
        return Err(ApiError::forbidden("Blocked"));
    }

    if text_content.trim().chars().count() > 2 {
        let author_id: Option<Uuid> =
            sqlx::query_scalar("SELECT author_id FROM music_tracks WHERE id = $1")
                .bind(id)
                .fetch_optional(&state.db)
                .await?;
        let allow_ads = Some(auth.id) == author_id || is_staff(&state, Some(auth.id)).await;
        let verdict = moderate_review(text_content, allow_ads);
        if !verdict.approved {
            return Err(ApiError::bad_request(format!(
                "Review not allowed: {}",
                verdict.reason
            )));
        }
    }

    let existing: Option<Uuid> =
        sqlx::query_scalar("SELECT id FROM music_reviews WHERE music_id = $1 AND author_id = $2")
            .bind(id)
            .bind(auth.id)
            .fetch_optional(&state.db)
            .await?;

    let review_id = if let Some(rid) = existing {
        sqlx::query(
            "UPDATE music_reviews SET text_content = $1, status = 'approved', created_at = NOW() WHERE id = $2 RETURNING id",
        )
        .bind(text_content)
        .bind(rid)
        .fetch_one(&state.db)
        .await?;
        rid
    } else {
        let row = sqlx::query(
            "INSERT INTO music_reviews (id, music_id, author_id, text_content, status) \
             VALUES (gen_random_uuid(), $1, $2, $3, 'approved') RETURNING id",
        )
        .bind(id)
        .bind(auth.id)
        .bind(text_content)
        .fetch_one(&state.db)
        .await?;
        let rid: Uuid = row.try_get("id")?;
        let _ = award_achievement(&state, auth.id, "critic_bronze").await;
        rid
    };

    ok_json(json!({
        "success": true,
        "status": "approved",
        "id": review_id.to_string(),
    }))
}

pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        .route("/", get(list_music).post(upload_track))
        .route("/{id}", get(get_music).delete(delete_music))
        .route("/{id}/file", get(stream_music))
        .route("/{id}/admin/action", post(admin_action_music))
        .route("/{id}/vote", post(vote_music))
        .route("/{id}/my-vote", get(my_vote_music))
        .route("/{id}/reviews", get(list_reviews_music))
        .route("/{id}/my-review", get(my_review_music))
        .route("/{id}/review", post(post_review_music))
        .layer(axum::extract::DefaultBodyLimit::max(UPLOAD_LIMIT))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sanitize_strips_html_and_truncates() {
        assert_eq!(sanitize_text("<b>Hello</b> world", 100), "Hello world");
        assert_eq!(sanitize_text(" short ", 4), "shor");
    }

    #[test]
    fn parse_genres_reads_json_string_and_uses_fallback() {
        let mut form = FormData::default();
        form.fields
            .insert("genres".to_string(), vec!["[\"rock\",\"pop\"]".to_string()]);
        assert_eq!(
            parse_genres(&form, None),
            vec!["rock".to_string(), "pop".to_string()]
        );
        assert_eq!(
            parse_genres(&form, Some("folk")),
            vec!["rock".to_string(), "pop".to_string()]
        );

        let empty = FormData::default();
        assert_eq!(parse_genres(&empty, Some("folk")), vec!["folk".to_string()]);
    }

    #[test]
    fn content_type_for_audio_respects_extension() {
        assert_eq!(content_type_for_audio(".mp3"), "audio/mpeg");
        assert_eq!(content_type_for_audio(".flac"), "audio/flac");
        assert_eq!(
            content_type_for_audio(".unknown"),
            "application/octet-stream"
        );
    }
}
