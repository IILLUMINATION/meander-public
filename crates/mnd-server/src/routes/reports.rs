//! `/reports` — user reports and admin resolution.
//!
//! Port of `backend/src/routes/reports.ts`. Validation, error texts and admin-only
//! transitions are reproduced verbatim.

use std::path::PathBuf;
use std::sync::Arc;

use axum::{
    Router,
    extract::{Path, Query, State},
    routing::{get, post},
};
use serde_json::json;
use sqlx::Row;
use uuid::Uuid;

use crate::auth::{AdminUser, AuthUser};
use crate::error::{ApiError, ApiResult, ok_created, ok_json};
use crate::extractors::Body;
use crate::json::{pg_row_to_json, rows_to_json};
use crate::state::AppState;

const REPORTED_TYPES: &[&str] = &[
    "quest",
    "review",
    "user",
    "wall_post",
    "wall_comment",
    "asset",
    "music",
    "message",
];

pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        .route("/", post(create_report))
        .route("/admin", get(list_reports))
        .route("/admin/{id}/resolve", post(resolve_report))
}

async fn create_report(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    body: Body,
) -> ApiResult {
    let user_id = auth.id;

    // Node's `if (!reported_type)` treats `""`, `null`, `false` and `0` as
    // missing; every other JSON value is coerced by `pg` when it reaches a text
    // column. `Body::str` only accepts strings, so coerce explicitly.
    let reported_type = match js_truthy_text(body.get("reported_type")) {
        Some(v) => v,
        None => return Err(ApiError::bad_request("Missing required fields")),
    };
    let reported_id_raw = match js_truthy_text(body.get("reported_id")) {
        Some(v) => v,
        None => return Err(ApiError::bad_request("Missing required fields")),
    };
    let reason = match js_truthy_text(body.get("reason")) {
        Some(v) => v,
        None => return Err(ApiError::bad_request("Missing required fields")),
    };

    if !REPORTED_TYPES.contains(&reported_type.as_str()) {
        return Err(ApiError::bad_request("Invalid reported_type"));
    }

    let reported_id = match Uuid::parse_str(&reported_id_raw) {
        Ok(id) => id,
        Err(_) => return Err(ApiError::bad_request("Invalid reported_id format")),
    };

    if reported_type == "user" && reported_id_raw == user_id.to_string() {
        return Err(ApiError::bad_request("Cannot report yourself"));
    }

    check_reported_exists(&state, &reported_type, reported_id, user_id).await?;

    let existing = sqlx::query(
        "SELECT id FROM reports
         WHERE reporter_id = $1 AND reported_type = $2 AND reported_id = $3 AND status = 'pending'",
    )
    .bind(user_id)
    .bind(&reported_type)
    .bind(reported_id)
    .fetch_optional(&state.db)
    .await?;

    if existing.is_some() {
        return Err(ApiError::bad_request("You have already reported this item"));
    }

    let row = sqlx::query(
        "INSERT INTO reports (reporter_id, reported_type, reported_id, reason, description, status)
         VALUES ($1, $2, $3, $4, $5, 'pending')
         RETURNING *",
    )
    .bind(user_id)
    .bind(reported_type)
    .bind(reported_id)
    .bind(&reason)
    .bind(js_truthy_text(body.get("description")))
    .fetch_one(&state.db)
    .await?;

    ok_created(json!({"success": true, "report": pg_row_to_json(&row)}))
}

/// JavaScript `Boolean(value)` for a JSON value, rendered the way `pg`
/// stringifies it for a text column.
fn js_truthy_text(value: Option<&serde_json::Value>) -> Option<String> {
    use serde_json::Value;
    match value? {
        Value::Null => None,
        Value::Bool(false) => None,
        Value::Bool(true) => Some("true".into()),
        Value::Number(n) if n.as_f64() == Some(0.0) => None,
        Value::Number(n) => Some(n.to_string()),
        Value::String(s) if s.is_empty() => None,
        Value::String(s) => Some(s.clone()),
        other => Some(other.to_string()),
    }
}

async fn check_reported_exists(
    state: &Arc<AppState>,
    reported_type: &str,
    reported_id: Uuid,
    reporter_id: Uuid,
) -> Result<(), ApiError> {
    match reported_type {
        "quest" => {
            if sqlx::query("SELECT id FROM quests WHERE id = $1")
                .bind(reported_id)
                .fetch_optional(&state.db)
                .await?
                .is_none()
            {
                return Err(ApiError::not_found("Quest not found"));
            }
        }
        "review" => {
            if sqlx::query("SELECT id FROM reviews WHERE id = $1")
                .bind(reported_id)
                .fetch_optional(&state.db)
                .await?
                .is_none()
            {
                return Err(ApiError::not_found("Review not found"));
            }
        }
        "user" => {
            if sqlx::query("SELECT id FROM profiles WHERE id = $1")
                .bind(reported_id)
                .fetch_optional(&state.db)
                .await?
                .is_none()
            {
                return Err(ApiError::not_found("User not found"));
            }
        }
        "wall_post" => {
            if sqlx::query("SELECT id FROM author_posts WHERE id = $1")
                .bind(reported_id)
                .fetch_optional(&state.db)
                .await?
                .is_none()
            {
                return Err(ApiError::not_found("Post not found"));
            }
        }
        "wall_comment" => {
            if sqlx::query("SELECT id FROM author_post_comments WHERE id = $1")
                .bind(reported_id)
                .fetch_optional(&state.db)
                .await?
                .is_none()
            {
                return Err(ApiError::not_found("Comment not found"));
            }
        }
        "asset" => {
            if sqlx::query("SELECT id FROM market_assets WHERE id = $1")
                .bind(reported_id)
                .fetch_optional(&state.db)
                .await?
                .is_none()
            {
                return Err(ApiError::not_found("Asset not found"));
            }
        }
        "music" => {
            if sqlx::query("SELECT id FROM music_tracks WHERE id = $1")
                .bind(reported_id)
                .fetch_optional(&state.db)
                .await?
                .is_none()
            {
                return Err(ApiError::not_found("Track not found"));
            }
        }
        "message" => {
            let row = sqlx::query(
                "SELECT m.id, m.sender_id
                   FROM dm_messages m
                   JOIN dm_threads t ON t.id = m.thread_id
                  WHERE m.id = $1
                    AND m.deleted_at IS NULL
                    AND (t.user_a = $2 OR t.user_b = $2)",
            )
            .bind(reported_id)
            .bind(reporter_id)
            .fetch_optional(&state.db)
            .await?;

            match row {
                None => return Err(ApiError::not_found("Message not found")),
                Some(row) => {
                    let sender_id: Uuid = row.try_get("sender_id")?;
                    if sender_id == reporter_id {
                        return Err(ApiError::bad_request("Cannot report your own message"));
                    }
                }
            }
        }
        _ => return Err(ApiError::bad_request("Invalid reported_type")),
    }

    Ok(())
}

async fn list_reports(
    State(state): State<Arc<AppState>>,
    _admin: AdminUser,
    Query(query): Query<std::collections::HashMap<String, String>>,
) -> ApiResult {
    let status = query.get("status").map(|s| s.as_str()).unwrap_or("pending");

    let rows = sqlx::query(
        r#"SELECT
            r.*,
            reporter.full_name as reporter_name,
            reporter.avatar_url as reporter_avatar,
            CASE
                WHEN r.reported_type = 'quest' THEN q.title
                WHEN r.reported_type = 'review' THEN rev.text_content
                WHEN r.reported_type = 'user' THEN reported_user.full_name
                WHEN r.reported_type = 'wall_post' THEN ap.content
                WHEN r.reported_type = 'wall_comment' THEN apc.content
                WHEN r.reported_type = 'asset' THEN ma.title
                WHEN r.reported_type = 'music' THEN mt.title
                WHEN r.reported_type = 'message' THEN dm.body
            END as reported_item_title,
            CASE
                WHEN r.reported_type = 'quest' THEN q.author_id
                WHEN r.reported_type = 'review' THEN rev.author_id
                WHEN r.reported_type = 'user' THEN r.reported_id
                WHEN r.reported_type = 'wall_post' THEN ap.author_id
                WHEN r.reported_type = 'wall_comment' THEN apc.user_id
                WHEN r.reported_type = 'asset' THEN ma.author_id
                WHEN r.reported_type = 'music' THEN mt.author_id
                WHEN r.reported_type = 'message' THEN dm.sender_id
            END as reported_user_id,
            CASE
                WHEN r.reported_type = 'quest' THEN q_author.full_name
                WHEN r.reported_type = 'review' THEN rev_author.full_name
                WHEN r.reported_type = 'user' THEN reported_user.full_name
                WHEN r.reported_type = 'wall_post' THEN ap_author.full_name
                WHEN r.reported_type = 'wall_comment' THEN apc_author.full_name
                WHEN r.reported_type = 'asset' THEN ma_author.full_name
                WHEN r.reported_type = 'music' THEN mt_author.full_name
                WHEN r.reported_type = 'message' THEN dm_sender.full_name
            END as reported_user_name
        FROM reports r
        LEFT JOIN profiles reporter ON r.reporter_id = reporter.id
        LEFT JOIN quests q ON r.reported_type = 'quest' AND r.reported_id = q.id
        LEFT JOIN profiles q_author ON q.author_id = q_author.id
        LEFT JOIN reviews rev ON r.reported_type = 'review' AND r.reported_id = rev.id
        LEFT JOIN profiles rev_author ON rev.author_id = rev_author.id
        LEFT JOIN profiles reported_user ON r.reported_type = 'user' AND r.reported_id = reported_user.id
        LEFT JOIN author_posts ap ON r.reported_type = 'wall_post' AND r.reported_id = ap.id
        LEFT JOIN profiles ap_author ON ap.author_id = ap_author.id
        LEFT JOIN author_post_comments apc ON r.reported_type = 'wall_comment' AND r.reported_id = apc.id
        LEFT JOIN profiles apc_author ON apc.user_id = apc_author.id
        LEFT JOIN market_assets ma ON r.reported_type = 'asset' AND r.reported_id = ma.id
        LEFT JOIN profiles ma_author ON ma.author_id = ma_author.id
        LEFT JOIN music_tracks mt ON r.reported_type = 'music' AND r.reported_id = mt.id
        LEFT JOIN profiles mt_author ON mt.author_id = mt_author.id
        LEFT JOIN dm_messages dm ON r.reported_type = 'message' AND r.reported_id = dm.id
        LEFT JOIN profiles dm_sender ON dm.sender_id = dm_sender.id
        WHERE r.status = $1
        ORDER BY r.created_at DESC"#,
    )
    .bind(status)
    .fetch_all(&state.db)
    .await?;

    ok_json(rows_to_json(&rows))
}

async fn resolve_report(
    State(state): State<Arc<AppState>>,
    admin: AdminUser,
    Path(raw_id): Path<String>,
    body: Body,
) -> ApiResult {
    let report_id = match Uuid::parse_str(&raw_id) {
        Ok(id) => id,
        Err(_) => return Err(ApiError::bad_request("Invalid ID format")),
    };

    let action = body.str("action").unwrap_or("");
    let block_user = body.bool("block_user").unwrap_or(false);

    if action != "delete" && action != "dismiss" {
        return Err(ApiError::bad_request(
            "Invalid action. Must be 'delete' or 'dismiss'",
        ));
    }

    let mut tx = state.db.begin().await?;

    let report = sqlx::query("SELECT * FROM reports WHERE id = $1 AND status = 'pending'")
        .bind(report_id)
        .fetch_optional(&mut *tx)
        .await?;

    let report = match report {
        Some(row) => row,
        None => return Err(ApiError::not_found("Report not found or already resolved")),
    };

    let reported_type: String = report.try_get("reported_type")?;
    let reported_id: Uuid = report.try_get("reported_id")?;
    let mut user_to_block: Option<Uuid> = None;

    if action == "delete" {
        let dirs = &state.cfg.public_dir;
        match reported_type.as_str() {
            "quest" => {
                let row = sqlx::query("SELECT author_id FROM quests WHERE id = $1")
                    .bind(reported_id)
                    .fetch_optional(&mut *tx)
                    .await?;
                if let Some(row) = row {
                    user_to_block = row.try_get::<Option<Uuid>, _>("author_id")?;
                }

                let quest_file = dirs.join("quests_files").join(format!("{reported_id}.mnd"));
                let _ = tokio::fs::remove_file(&quest_file).await;

                sqlx::query("DELETE FROM quests WHERE id = $1")
                    .bind(reported_id)
                    .execute(&mut *tx)
                    .await?;
            }
            "review" => {
                let row = sqlx::query("SELECT author_id FROM reviews WHERE id = $1")
                    .bind(reported_id)
                    .fetch_optional(&mut *tx)
                    .await?;
                if let Some(row) = row {
                    user_to_block = row.try_get::<Option<Uuid>, _>("author_id")?;
                }
                sqlx::query("DELETE FROM reviews WHERE id = $1")
                    .bind(reported_id)
                    .execute(&mut *tx)
                    .await?;
            }
            "user" => {
                user_to_block = Some(reported_id);
            }
            "wall_post" => {
                let row = sqlx::query("SELECT author_id FROM author_posts WHERE id = $1")
                    .bind(reported_id)
                    .fetch_optional(&mut *tx)
                    .await?;
                if let Some(row) = row {
                    user_to_block = row.try_get::<Option<Uuid>, _>("author_id")?;
                }
                sqlx::query("DELETE FROM author_posts WHERE id = $1")
                    .bind(reported_id)
                    .execute(&mut *tx)
                    .await?;
            }
            "wall_comment" => {
                let row = sqlx::query("SELECT user_id FROM author_post_comments WHERE id = $1")
                    .bind(reported_id)
                    .fetch_optional(&mut *tx)
                    .await?;
                if let Some(row) = row {
                    user_to_block = row.try_get::<Option<Uuid>, _>("user_id")?;
                }
                sqlx::query("DELETE FROM author_post_comments WHERE id = $1")
                    .bind(reported_id)
                    .execute(&mut *tx)
                    .await?;
            }
            "asset" => {
                let row = sqlx::query("SELECT author_id FROM market_assets WHERE id = $1")
                    .bind(reported_id)
                    .fetch_optional(&mut *tx)
                    .await?;
                if let Some(row) = row {
                    user_to_block = row.try_get::<Option<Uuid>, _>("author_id")?;
                }
                sqlx::query("DELETE FROM market_assets WHERE id = $1")
                    .bind(reported_id)
                    .execute(&mut *tx)
                    .await?;
                delete_stored_media(&dirs.join("assets_files"), reported_id).await;
            }
            "music" => {
                let row = sqlx::query("SELECT author_id FROM music_tracks WHERE id = $1")
                    .bind(reported_id)
                    .fetch_optional(&mut *tx)
                    .await?;
                if let Some(row) = row {
                    user_to_block = row.try_get::<Option<Uuid>, _>("author_id")?;
                }
                sqlx::query("DELETE FROM music_tracks WHERE id = $1")
                    .bind(reported_id)
                    .execute(&mut *tx)
                    .await?;
                delete_stored_media(&dirs.join("music_files"), reported_id).await;
            }
            "message" => {
                let row = sqlx::query("SELECT sender_id FROM dm_messages WHERE id = $1")
                    .bind(reported_id)
                    .fetch_optional(&mut *tx)
                    .await?;
                if let Some(row) = row {
                    user_to_block = row.try_get::<Option<Uuid>, _>("sender_id")?;
                }
                sqlx::query("UPDATE dm_messages SET body = '', deleted_at = NOW() WHERE id = $1")
                    .bind(reported_id)
                    .execute(&mut *tx)
                    .await?;
            }
            _ => {}
        }

        if block_user {
            if let Some(user_id) = user_to_block {
                sqlx::query(
                    "UPDATE profiles SET is_blocked = TRUE, token_version = token_version + 1 WHERE id = $1",
                )
                .bind(user_id)
                .execute(&mut *tx)
                .await?;
            }
        }
    }

    let new_status = if action == "delete" {
        "resolved"
    } else {
        "dismissed"
    };
    sqlx::query(
        "UPDATE reports SET status = $1, resolved_by = $2, resolved_at = NOW() WHERE id = $3",
    )
    .bind(new_status)
    .bind(admin.0.id)
    .bind(report_id)
    .execute(&mut *tx)
    .await?;

    tx.commit().await?;

    ok_json(json!({
        "success": true,
        "message": format!("Report {}", new_status),
    }))
}

async fn delete_stored_media(dir: &PathBuf, id: Uuid) {
    if !dir.is_dir() {
        return;
    }
    let prefix = format!("{id}.");

    let mut entries = match tokio::fs::read_dir(dir).await {
        Ok(entries) => entries,
        Err(_) => return,
    };

    while let Ok(Some(entry)) = entries.next_entry().await {
        let name = match entry.file_name().into_string() {
            Ok(name) => name,
            Err(_) => continue,
        };
        if name.starts_with(&prefix) {
            let _ = tokio::fs::remove_file(entry.path()).await;
        }
    }
}
