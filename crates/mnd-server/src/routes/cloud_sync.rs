//! Port of `backend/src/routes/cloud_sync.ts`.
//!
//! Mounted at `/cloud-sync`. All routes require authorization. Bodies are
//! accepted as JSON (≤5 MB) or raw `application/octet-stream` (≤200 MB).

use std::sync::Arc;
use std::time::Duration;

use axum::body::to_bytes;
use axum::extract::{DefaultBodyLimit, Path, Request, State};
use axum::http::{HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post, put};
use axum::{Json, Router};
use chrono::{DateTime, Utc};
use serde_json::{Value, json};
use sqlx::Row;
use tokio_util::io::ReaderStream;
use uuid::Uuid;

use crate::auth::{AdminUser, AuthUser};
use crate::error::{ApiError, ApiResult, ok_json, payload_too_large};
use crate::extractors::Body;
use crate::json::{opt_ts, ts};
use crate::services::cloud_sync_cleanup::run_cloud_sync_cleanup;
use crate::services::cloud_sync_storage::{delete_quest_file, read_quest_stream, write_quest_file};
use crate::services::cloud_sync_tier::{
    build_upgrade_hints, grant_tier_by, recompute_tier, tier_config,
};
use crate::state::AppState;

const MAX_JSON_BYTES: usize = 5 * 1024 * 1024;
const MAX_BINARY_BYTES: usize = 200 * 1024 * 1024;

pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        .route("/quota", get(get_quota))
        .route("/quests", get(list_quests))
        .route("/quests/{quest_id}/check", post(check_quest))
        .route("/quests/{quest_id}", put(put_quest))
        .route("/quests/{quest_id}", get(download_quest))
        .route("/quests/{quest_id}", delete(delete_quest))
        .route("/admin/grant", post(admin_grant))
        .route("/admin/recompute", post(admin_recompute))
        .route("/admin/cleanup", post(admin_cleanup))
        .layer(DefaultBodyLimit::max(MAX_BINARY_BYTES))
}

// -----------------------------------------------------------------------------
//  Rate limit helper
// -----------------------------------------------------------------------------
fn check_limit(
    state: &AppState,
    user_id: &Uuid,
    name: &str,
    max: u64,
    window: Duration,
) -> Option<Response> {
    let key = format!("cs_{name}_{user_id}");
    let decision = state.limiter.hit(key, max, window);
    if !decision.allowed {
        let mut resp = (
            StatusCode::TOO_MANY_REQUESTS,
            Json(json!({"error": "Too many requests"})),
        )
            .into_response();
        let headers = resp.headers_mut();
        let mut set = |h: &'static str, v: String| {
            if let Ok(value) = HeaderValue::from_str(&v) {
                headers.insert(h, value);
            }
        };
        set("ratelimit-limit", decision.limit.to_string());
        set("ratelimit-remaining", decision.remaining.to_string());
        set("ratelimit-reset", decision.reset_secs.to_string());
        return Some(resp);
    }
    None
}

// -----------------------------------------------------------------------------
//  Quota helpers
// -----------------------------------------------------------------------------
struct QuotaRow {
    tier: String,
    used_bytes: i64,
    max_bytes: i64,
    max_quests: i32,
    max_quest_bytes: i64,
    max_refs: i32,
    granted_reason: Option<String>,
    expires_at: Option<DateTime<Utc>>,
}

async fn ensure_quota_row(state: &AppState, user_id: Uuid) -> Result<QuotaRow, ApiError> {
    let row = sqlx::query(
        "SELECT tier, used_bytes, max_bytes, max_quests,
                max_quest_bytes, max_refs, granted_reason, expires_at
           FROM cloud_sync_quotas WHERE user_id = $1",
    )
    .bind(user_id)
    .fetch_optional(&state.db)
    .await?;

    if let Some(r) = row {
        return Ok(map_quota_row(&r)?);
    }

    recompute_tier(state, user_id).await?;

    let row = sqlx::query(
        "SELECT tier, used_bytes, max_bytes, max_quests,
                max_quest_bytes, max_refs, granted_reason, expires_at
           FROM cloud_sync_quotas WHERE user_id = $1",
    )
    .bind(user_id)
    .fetch_optional(&state.db)
    .await?
    .ok_or_else(|| ApiError::internal("Failed to create cloud sync quota"))?;

    Ok(map_quota_row(&row)?)
}

fn map_quota_row(r: &sqlx::postgres::PgRow) -> Result<QuotaRow, ApiError> {
    Ok(QuotaRow {
        tier: r.try_get("tier")?,
        used_bytes: r.try_get("used_bytes")?,
        max_bytes: r.try_get("max_bytes")?,
        max_quests: r.try_get("max_quests")?,
        max_quest_bytes: r.try_get("max_quest_bytes")?,
        max_refs: r.try_get("max_refs")?,
        granted_reason: r.try_get("granted_reason")?,
        expires_at: r.try_get("expires_at")?,
    })
}

#[derive(Default)]
struct Counts {
    user: i64,
    #[allow(dead_code)]
    user_bytes: i64,
    ref_count: i64,
}

async fn load_counts(state: &AppState, user_id: Uuid) -> Result<Counts, ApiError> {
    let row = sqlx::query(
        "SELECT
            COALESCE(SUM(CASE WHEN source = 'user' THEN 1 ELSE 0 END), 0)::bigint AS user_cnt,
            COALESCE(SUM(CASE WHEN source = 'user' THEN size_bytes ELSE 0 END), 0)::bigint AS user_bytes,
            COALESCE(SUM(CASE WHEN source = 'market_ref' THEN 1 ELSE 0 END), 0)::bigint AS ref_cnt
         FROM cloud_sync_quests
         WHERE user_id = $1 AND deleted_at IS NULL",
    )
    .bind(user_id)
    .fetch_one(&state.db)
    .await?;

    Ok(Counts {
        user: row.try_get("user_cnt")?,
        user_bytes: row.try_get("user_bytes")?,
        ref_count: row.try_get("ref_cnt")?,
    })
}

async fn audit(
    state: &AppState,
    user_id: Uuid,
    quest_id: Option<&str>,
    action: &str,
    bytes: Option<i64>,
    detail: Option<Value>,
) {
    let _ = sqlx::query(
        "INSERT INTO cloud_sync_audit (user_id, quest_id, action, bytes, detail)
         VALUES ($1, $2, $3, $4, $5::jsonb)",
    )
    .bind(user_id)
    .bind(quest_id)
    .bind(action)
    .bind(bytes)
    .bind(detail)
    .execute(&state.db)
    .await;
}

fn parse_size(value: Option<&Value>) -> i64 {
    match value {
        Some(Value::Number(n)) => n.as_i64().unwrap_or(0),
        Some(Value::String(s)) => s.parse().unwrap_or(0),
        _ => 0,
    }
}

// -----------------------------------------------------------------------------
//  GET /cloud-sync/quota
// -----------------------------------------------------------------------------
async fn get_quota(State(state): State<Arc<AppState>>, auth: AuthUser) -> ApiResult {
    if let Some(resp) = check_limit(&state, &auth.id, "quota", 300, Duration::from_secs(3600)) {
        return Ok(resp);
    }

    ensure_quota_row(&state, auth.id).await?;
    recompute_tier(&state, auth.id).await?;
    let q = ensure_quota_row(&state, auth.id).await?;
    let counts = load_counts(&state, auth.id).await?;
    let hints = build_upgrade_hints(&state, auth.id).await?;

    ok_json(json!({
        "tier": q.tier,
        "usedBytes": q.used_bytes,
        "usedQuests": counts.user,
        "usedRefs": counts.ref_count,
        "maxBytes": q.max_bytes,
        "maxQuests": q.max_quests,
        "maxQuestBytes": q.max_quest_bytes,
        "maxRefs": q.max_refs,
        "grantedReason": q.granted_reason,
        "expiresAt": opt_ts(q.expires_at),
        "upgradeHints": hints,
    }))
}

// -----------------------------------------------------------------------------
//  GET /cloud-sync/quests
// -----------------------------------------------------------------------------
async fn list_quests(State(state): State<Arc<AppState>>, auth: AuthUser) -> ApiResult {
    if let Some(resp) = check_limit(&state, &auth.id, "list", 200, Duration::from_secs(3600)) {
        return Ok(resp);
    }

    let rows = sqlx::query(
        "SELECT q.quest_id, q.title, q.source, q.size_bytes, q.fingerprint,
                q.market_quest_id, q.market_version, q.updated_at,
                mq.status::text AS market_status,
                mq.version AS market_current_version
           FROM cloud_sync_quests q
      LEFT JOIN quests mq ON mq.id = q.market_quest_id
          WHERE q.user_id = $1 AND q.deleted_at IS NULL
          ORDER BY q.updated_at DESC",
    )
    .bind(auth.id)
    .fetch_all(&state.db)
    .await?;

    let mut list: Vec<Value> = Vec::new();
    for row in rows {
        let quest_id: String = row.try_get("quest_id")?;
        let title: String = row.try_get("title")?;
        let source: String = row.try_get("source")?;
        let size: i64 = row.try_get("size_bytes")?;
        let fingerprint: Option<String> = row.try_get("fingerprint")?;
        let market_quest_id: Option<Uuid> = row.try_get("market_quest_id")?;
        let market_version: Option<String> = row.try_get("market_version")?;
        let updated_at: DateTime<Utc> = row.try_get("updated_at")?;
        let market_status: Option<String> = row.try_get("market_status")?;
        let market_current_version: Option<String> = row.try_get("market_current_version")?;

        let is_ref = source == "market_ref";
        let market_available = is_ref && market_status.as_deref() == Some("published");

        let mut obj = json!({
            "questId": quest_id,
            "title": title,
            "source": source,
            "size": size,
            "fingerprint": fingerprint,
            "updatedAt": ts(updated_at),
            "downloadPath": format!("/cloud-sync/quests/{quest_id}"),
        });

        if let Some(mq) = market_quest_id {
            if let Value::Object(ref mut map) = obj {
                map.insert("marketQuestId".to_string(), Value::String(mq.to_string()));
            }
        }
        if let Some(v) = market_version {
            if let Value::Object(ref mut map) = obj {
                map.insert("marketVersion".to_string(), Value::String(v));
            }
        }
        if let Some(v) = market_current_version {
            if let Value::Object(ref mut map) = obj {
                map.insert("marketCurrentVersion".to_string(), Value::String(v));
            }
        }
        if is_ref {
            if let Value::Object(ref mut map) = obj {
                map.insert("marketAvailable".to_string(), Value::Bool(market_available));
            }
        }

        list.push(obj);
    }

    ok_json(json!(list))
}

// -----------------------------------------------------------------------------
//  POST /cloud-sync/quests/:quest_id/check
// -----------------------------------------------------------------------------
async fn check_quest(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(quest_id): Path<String>,
    body: Body,
) -> ApiResult {
    if let Some(resp) = check_limit(&state, &auth.id, "check", 600, Duration::from_secs(3600)) {
        return Ok(resp);
    }

    let fingerprint = body.str("fingerprint").unwrap_or("");
    if fingerprint.len() < 8 {
        return Err(ApiError::bad_request("fingerprint required"));
    }
    let requested_size = parse_size(body.get("size"));

    let q = ensure_quota_row(&state, auth.id).await?;
    let counts = load_counts(&state, auth.id).await?;

    let existing = sqlx::query(
        "SELECT source, size_bytes, fingerprint, market_quest_id, market_version, updated_at
           FROM cloud_sync_quests
          WHERE user_id = $1 AND quest_id = $2 AND deleted_at IS NULL",
    )
    .bind(auth.id)
    .bind(&quest_id)
    .fetch_optional(&state.db)
    .await?;

    let mut supports_market_ref = false;
    if let Some(market_ref) = body.get("marketRef").and_then(Value::as_object) {
        if let Some(Value::String(mq)) = market_ref.get("marketQuestId") {
            if let Ok(uuid) = Uuid::parse_str(mq) {
                let status = sqlx::query_scalar::<_, String>(
                    "SELECT status::text FROM quests WHERE id = $1",
                )
                .bind(uuid)
                .fetch_optional(&state.db)
                .await?;
                supports_market_ref = status.as_deref() == Some("published");
            }
        }
    }

    // Identical fingerprint already on the server.
    if let Some(row) = existing.as_ref() {
        let fp: Option<String> = row.try_get("fingerprint")?;
        if fp.as_deref() == Some(fingerprint) {
            let updated_at: DateTime<Utc> = row.try_get("updated_at")?;
            return ok_json(json!({
                "exists": true,
                "sameFingerprint": true,
                "wouldExceedQuota": false,
                "supportsMarketRef": supports_market_ref,
                "recommendation": "skip",
                "remoteFingerprint": fp,
                "remoteUpdatedAt": ts(updated_at),
            }));
        }
    }

    let exists = existing.is_some();
    let (remote_fp, remote_updated) = if let Some(row) = existing.as_ref() {
        (
            row.try_get::<Option<String>, _>("fingerprint")?,
            row.try_get::<Option<DateTime<Utc>>, _>("updated_at")?,
        )
    } else {
        (None, None)
    };

    if supports_market_ref {
        let is_ref = existing
            .as_ref()
            .map(|r| {
                let s: String = r.try_get("source")?;
                Ok::<_, sqlx::Error>(s == "market_ref")
            })
            .transpose()?
            .unwrap_or(false);
        let would_need_ref_slot = !exists || !is_ref;
        let ref_overflow =
            would_need_ref_slot && counts.ref_count >= q.max_refs as i64 && q.tier != "admin";

        return ok_json(json!({
            "exists": exists,
            "sameFingerprint": false,
            "wouldExceedQuota": ref_overflow,
            "supportsMarketRef": true,
            "recommendation": if ref_overflow { "none" } else { "market_ref" },
            "reason": if ref_overflow { Some("ref_quota_exceeded") } else { None::<&str> },
            "remoteFingerprint": remote_fp,
            "remoteUpdatedAt": remote_updated.map(ts),
        }));
    }

    if q.tier == "none" || q.max_bytes == 0 {
        return ok_json(json!({
            "exists": exists,
            "sameFingerprint": false,
            "wouldExceedQuota": true,
            "supportsMarketRef": false,
            "recommendation": "none",
            "reason": "no_quota",
            "remoteFingerprint": remote_fp,
            "remoteUpdatedAt": remote_updated.map(ts),
        }));
    }

    if requested_size > q.max_quest_bytes {
        return ok_json(json!({
            "exists": exists,
            "sameFingerprint": false,
            "wouldExceedQuota": true,
            "supportsMarketRef": false,
            "recommendation": "none",
            "reason": "file_too_large",
            "remoteFingerprint": remote_fp,
            "remoteUpdatedAt": remote_updated.map(ts),
        }));
    }

    let old_size = existing
        .as_ref()
        .map(|r| {
            let source: String = r.try_get("source")?;
            let size: i64 = r.try_get("size_bytes")?;
            Ok::<_, sqlx::Error>(if source == "user" { size } else { 0 })
        })
        .transpose()?
        .unwrap_or(0);

    let projected = q.used_bytes - old_size + requested_size;
    let bytes_overflow = projected > q.max_bytes;
    let slots_overflow = !exists && counts.user >= q.max_quests as i64 && q.tier != "admin";
    let would_exceed = bytes_overflow || slots_overflow;

    let reason = if bytes_overflow {
        Some("bytes_quota_exceeded")
    } else if slots_overflow {
        Some("quest_quota_exceeded")
    } else {
        None::<&str>
    };

    ok_json(json!({
        "exists": exists,
        "sameFingerprint": false,
        "wouldExceedQuota": would_exceed,
        "supportsMarketRef": false,
        "recommendation": if would_exceed { "none" } else { "upload" },
        "reason": reason,
        "remoteFingerprint": remote_fp,
        "remoteUpdatedAt": remote_updated.map(ts),
    }))
}

// -----------------------------------------------------------------------------
//  PUT /cloud-sync/quests/:quest_id
// -----------------------------------------------------------------------------
async fn put_quest(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(quest_id): Path<String>,
    req: Request,
) -> ApiResult {
    if let Some(resp) = check_limit(&state, &auth.id, "upload", 300, Duration::from_secs(3600)) {
        return Ok(resp);
    }

    if quest_id.is_empty() || quest_id.len() > 128 {
        return Err(ApiError::bad_request("invalid quest id"));
    }

    let q = ensure_quota_row(&state, auth.id).await?;
    let counts = load_counts(&state, auth.id).await?;

    let content_type = req
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_ascii_lowercase();

    // ----- Market-ref branch (JSON) -----
    if crate::is_json_content_type(&content_type) {
        let cached = req
            .extensions()
            .get::<crate::extractors::ParsedBody>()
            .map(|parsed| parsed.0.clone());
        let body: Value = match cached {
            Some(value) => value,
            None => {
                let limit = MAX_JSON_BYTES;
                let encoding = crate::body_encoding(&content_type).unwrap_or(None);
                let bytes = to_bytes(req.into_body(), limit)
                    .await
                    .map_err(|_| payload_too_large())?;
                if bytes.is_empty() {
                    json!({})
                } else {
                    let text = crate::decode_body(&bytes, encoding);
                    match serde_json::from_str::<Value>(&text) {
                        Ok(value) if value.is_object() || value.is_array() => value,
                        _ => return Err(ApiError::bad_request("Bad JSON format")),
                    }
                }
            }
        };

        let title = body
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim();
        if title.is_empty() {
            return Err(ApiError::bad_request("title required"));
        }
        let market_quest_id = match body.get("marketQuestId").and_then(Value::as_str) {
            Some(s) => Uuid::parse_str(s)
                .map_err(|_| ApiError::bad_request("marketQuestId must be uuid"))?,
            None => return Err(ApiError::bad_request("marketQuestId must be uuid")),
        };

        if q.tier == "none" {
            return Err(ApiError::forbidden("no_quota"));
        }

        let status =
            sqlx::query_scalar::<_, String>("SELECT status::text FROM quests WHERE id = $1")
                .bind(market_quest_id)
                .fetch_optional(&state.db)
                .await?;
        if status.as_deref() != Some("published") {
            return Err(ApiError::not_found("market quest not available"));
        }

        let existing = sqlx::query(
            "SELECT source FROM cloud_sync_quests
              WHERE user_id = $1 AND quest_id = $2 AND deleted_at IS NULL",
        )
        .bind(auth.id)
        .bind(&quest_id)
        .fetch_optional(&state.db)
        .await?;

        let exists = existing.is_some();
        let was_user = existing
            .map(|r| {
                let s: String = r.try_get("source")?;
                Ok::<_, sqlx::Error>(s == "user")
            })
            .transpose()?
            .unwrap_or(false);

        if !exists && counts.ref_count >= q.max_refs as i64 && q.tier != "admin" {
            return Err(ApiError::forbidden("ref_quota_exceeded"));
        }

        if was_user {
            delete_quest_file(&state, &auth.id.to_string(), &quest_id).await;
        }

        let market_version = body
            .get("marketVersion")
            .and_then(Value::as_str)
            .map(|s| s.to_string());

        sqlx::query(
            "INSERT INTO cloud_sync_quests (
                user_id, quest_id, title, source, size_bytes, fingerprint,
                storage_path, market_quest_id, market_version,
                created_at, updated_at
             ) VALUES ($1,$2,$3,'market_ref',0,NULL,'',$4,$5, now(), now())
             ON CONFLICT (user_id, quest_id) DO UPDATE SET
                title           = EXCLUDED.title,
                source          = 'market_ref',
                size_bytes      = 0,
                fingerprint     = NULL,
                storage_path    = '',
                market_quest_id = EXCLUDED.market_quest_id,
                market_version  = EXCLUDED.market_version,
                deleted_at      = NULL,
                updated_at      = now()",
        )
        .bind(auth.id)
        .bind(&quest_id)
        .bind(&title[..title.len().min(200)])
        .bind(market_quest_id)
        .bind(&market_version)
        .execute(&state.db)
        .await?;

        audit(
            &state,
            auth.id,
            Some(&quest_id),
            "ref_create",
            Some(0),
            Some(json!({
                "marketQuestId": market_quest_id.to_string(),
                "marketVersion": market_version,
            })),
        )
        .await;

        return ok_json(json!({
            "questId": quest_id,
            "source": "market_ref",
            "size": 0,
            "marketQuestId": market_quest_id.to_string(),
            "marketVersion": market_version,
        }));
    }

    // ----- Binary upload branch -----
    let raw_title = req
        .headers()
        .get("x-title")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("Без названия");
    let title_encoding = req
        .headers()
        .get("x-title-encoding")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    let mut title = if title_encoding == "percent" {
        percent_decode(raw_title)
    } else {
        raw_title.to_string()
    };
    title.truncate(200);

    let client_fingerprint = req
        .headers()
        .get("x-fingerprint")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_string();

    let bytes = to_bytes(req.into_body(), MAX_BINARY_BYTES)
        .await
        .map_err(|_| payload_too_large())?;

    if bytes.is_empty() {
        return Err(ApiError::bad_request(
            "binary .mnd body required (application/octet-stream)",
        ));
    }
    let size = bytes.len();

    if q.tier == "none" || q.max_bytes == 0 {
        return Err(ApiError::forbidden("no_quota"));
    }
    if size as i64 > q.max_quest_bytes {
        return Err(ApiError::new(
            StatusCode::PAYLOAD_TOO_LARGE,
            "file_too_large",
        ));
    }

    let existing = sqlx::query(
        "SELECT source, size_bytes FROM cloud_sync_quests
          WHERE user_id = $1 AND quest_id = $2 AND deleted_at IS NULL",
    )
    .bind(auth.id)
    .bind(&quest_id)
    .fetch_optional(&state.db)
    .await?;

    let exists = existing.is_some();
    let old_size = existing
        .map(|r| {
            let source: String = r.try_get("source")?;
            let old: i64 = r.try_get("size_bytes")?;
            Ok::<_, sqlx::Error>(if source == "user" { old } else { 0 })
        })
        .transpose()?
        .unwrap_or(0);

    let projected = q.used_bytes - old_size + size as i64;
    if projected > q.max_bytes && q.tier != "admin" {
        return Err(ApiError::new(
            StatusCode::PAYLOAD_TOO_LARGE,
            "bytes_quota_exceeded",
        ));
    }
    if !exists && counts.user >= q.max_quests as i64 && q.tier != "admin" {
        return Err(ApiError::forbidden("quest_quota_exceeded"));
    }

    let _ = client_fingerprint; // intentionally unused after this; Node only logs a mismatch.

    let written = write_quest_file(&state, &auth.id.to_string(), &quest_id, &bytes).await?;
    let size_i64: i64 = i64::try_from(size).map_err(|_| ApiError::bad_request("file too large"))?;

    sqlx::query(
        "INSERT INTO cloud_sync_quests (
            user_id, quest_id, title, source, size_bytes, fingerprint,
            storage_path, market_quest_id, market_version,
            created_at, updated_at
         ) VALUES ($1,$2,$3,'user',$4,$5,$6,NULL,NULL, now(), now())
         ON CONFLICT (user_id, quest_id) DO UPDATE SET
            title           = EXCLUDED.title,
            source          = 'user',
            size_bytes      = EXCLUDED.size_bytes,
            fingerprint     = EXCLUDED.fingerprint,
            storage_path    = EXCLUDED.storage_path,
            market_quest_id = NULL,
            market_version  = NULL,
            deleted_at      = NULL,
            updated_at      = now()",
    )
    .bind(auth.id)
    .bind(&quest_id)
    .bind(&title)
    .bind(size_i64)
    .bind(&written.fingerprint)
    .bind(&written.path)
    .execute(&state.db)
    .await?;

    audit(
        &state,
        auth.id,
        Some(&quest_id),
        "upload",
        Some(size_i64),
        Some(json!({ "fingerprint": written.fingerprint })),
    )
    .await;

    ok_json(json!({
        "questId": quest_id,
        "source": "user",
        "size": size_i64,
        "fingerprint": written.fingerprint,
    }))
}

fn percent_decode(raw: &str) -> String {
    let bytes = raw.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(byte) = u8::from_str_radix(&raw[i + 1..i + 3], 16) {
                out.push(byte);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

// -----------------------------------------------------------------------------
//  GET /cloud-sync/quests/:quest_id
// -----------------------------------------------------------------------------
async fn download_quest(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(quest_id): Path<String>,
) -> ApiResult {
    if let Some(resp) = check_limit(&state, &auth.id, "download", 300, Duration::from_secs(3600)) {
        return Ok(resp);
    }

    let row = sqlx::query(
        "SELECT q.source, q.size_bytes, q.fingerprint, q.market_quest_id,
                mq.download_url, mq.status::text AS market_status
           FROM cloud_sync_quests q
      LEFT JOIN quests mq ON mq.id = q.market_quest_id
          WHERE q.user_id = $1 AND q.quest_id = $2 AND q.deleted_at IS NULL",
    )
    .bind(auth.id)
    .bind(&quest_id)
    .fetch_optional(&state.db)
    .await?;

    let row = match row {
        Some(r) => r,
        None => return Err(ApiError::not_found("not found")),
    };

    let source: String = row.try_get("source")?;

    if source == "market_ref" {
        let download_url: Option<String> = row.try_get("download_url")?;
        let market_status: Option<String> = row.try_get("market_status")?;
        if download_url.is_none() || market_status.as_deref() != Some("published") {
            return Err(ApiError::new(StatusCode::GONE, "market_quest_unavailable"));
        }
        let url = download_url.unwrap();
        audit(
            &state,
            auth.id,
            Some(&quest_id),
            "download",
            None,
            Some(json!({ "via": "market_ref" })),
        )
        .await;
        return Ok((
            StatusCode::FOUND,
            [(
                header::LOCATION,
                HeaderValue::from_str(&url)
                    .map_err(|_| ApiError::internal("invalid redirect url"))?,
            )],
            Json(json!({})),
        )
            .into_response());
    }

    let fingerprint: Option<String> = row.try_get("fingerprint")?;
    let (file, size) = read_quest_stream(&state, &auth.id.to_string(), &quest_id).await?;
    let stream = ReaderStream::new(file);
    let body = axum::body::Body::from_stream(stream);
    let mut resp = Response::new(body);

    resp.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/octet-stream"),
    );
    resp.headers_mut().insert(
        header::CONTENT_LENGTH,
        HeaderValue::from_str(&size.to_string()).expect("numeric header"),
    );
    if let Some(fp) = fingerprint {
        if let Ok(value) = HeaderValue::from_str(&fp) {
            resp.headers_mut().insert("x-fingerprint", value);
        }
    }

    audit(
        &state,
        auth.id,
        Some(&quest_id),
        "download",
        Some(size as i64),
        Some(json!({ "via": "user" })),
    )
    .await;

    Ok(resp)
}

// -----------------------------------------------------------------------------
//  DELETE /cloud-sync/quests/:quest_id
// -----------------------------------------------------------------------------
async fn delete_quest(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(quest_id): Path<String>,
) -> ApiResult {
    let row = sqlx::query(
        "SELECT source, size_bytes FROM cloud_sync_quests
          WHERE user_id = $1 AND quest_id = $2 AND deleted_at IS NULL",
    )
    .bind(auth.id)
    .bind(&quest_id)
    .fetch_optional(&state.db)
    .await?;

    let row = match row {
        Some(r) => r,
        None => return Err(ApiError::not_found("not found")),
    };

    let source: String = row.try_get("source")?;
    let size: i64 = row.try_get("size_bytes")?;

    sqlx::query(
        "UPDATE cloud_sync_quests SET deleted_at = now(), updated_at = now()
          WHERE user_id = $1 AND quest_id = $2",
    )
    .bind(auth.id)
    .bind(&quest_id)
    .execute(&state.db)
    .await?;

    if source == "user" {
        delete_quest_file(&state, &auth.id.to_string(), &quest_id).await;
    }

    audit(
        &state,
        auth.id,
        Some(&quest_id),
        "delete",
        Some(size),
        Some(json!({ "source": source })),
    )
    .await;

    sqlx::query("DELETE FROM cloud_sync_quests WHERE user_id = $1 AND quest_id = $2")
        .bind(auth.id)
        .bind(&quest_id)
        .execute(&state.db)
        .await?;

    ok_json(json!({ "ok": true }))
}

// -----------------------------------------------------------------------------
//  Admin endpoints
// -----------------------------------------------------------------------------
async fn admin_grant(
    State(state): State<Arc<AppState>>,
    AdminUser(admin): AdminUser,
    body: Body,
) -> ApiResult {
    let user_id = match body.str("userId").and_then(|s| Uuid::parse_str(s).ok()) {
        Some(u) => u,
        None => return Err(ApiError::bad_request("userId uuid")),
    };
    let tier = body.str("tier").unwrap_or("");
    if tier_config(tier).name == "none" && tier != "none" {
        return Err(ApiError::bad_request("invalid tier"));
    }
    let reason = body.str("reason").unwrap_or("manual");
    let expires_at = body
        .str("expiresAt")
        .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
        .map(|dt| dt.with_timezone(&Utc));
    let days = body.i64("days").map(|d| d as i32);
    let effective_expires =
        expires_at.or(days.map(|d| Utc::now() + chrono::Duration::days(d as i64)));

    grant_tier_by(
        &state,
        user_id,
        tier,
        reason,
        Some(admin.id),
        effective_expires,
    )
    .await?;

    ok_json(json!({ "ok": true }))
}

async fn admin_recompute(
    State(state): State<Arc<AppState>>,
    AdminUser(_admin): AdminUser,
    body: Body,
) -> ApiResult {
    let user_id = match body.str("userId").and_then(|s| Uuid::parse_str(s).ok()) {
        Some(u) => u,
        None => return Err(ApiError::bad_request("userId uuid")),
    };
    let tier = recompute_tier(&state, user_id).await?;
    ok_json(json!({ "ok": true, "tier": tier }))
}

async fn admin_cleanup(
    State(state): State<Arc<AppState>>,
    AdminUser(_admin): AdminUser,
) -> ApiResult {
    let report = run_cloud_sync_cleanup(&state).await?;
    let mut obj = json!({"ok": true});
    if let Value::Object(ref mut map) = obj {
        if let Value::Object(rep) = report {
            for (k, v) in rep {
                map.insert(k, v);
            }
        }
    }
    ok_json(obj)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percent_decode_roundtrip() {
        assert_eq!(
            percent_decode("%D0%9F%D1%80%D0%B8%D0%B2%D0%B5%D1%82"),
            "Привет"
        );
        assert_eq!(percent_decode("hello+world"), "hello+world");
        assert_eq!(percent_decode("%2F%3F"), "/?");
    }
}
