//! `/notifications` — personal notification feed.
//! Port of `backend/src/routes/notifications.ts`.

use std::collections::HashMap;
use std::sync::Arc;

use axum::extract::{Path, Query, State};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde_json::json;
use sqlx::Row;
use uuid::Uuid;

use crate::auth::AuthUser;
use crate::error::{ApiError, ApiResult, ok_json};
use crate::json::{parse_int, rows_to_json};
use crate::state::AppState;

pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        .route("/", get(list_notifications))
        .route("/unread-count", get(unread_count))
        .route("/{id}/read", post(mark_read))
        .route("/{id}/archive", post(archive))
}

async fn list_notifications(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Query(query): Query<HashMap<String, String>>,
) -> ApiResult {
    let archived = query.get("archived").map(|v| v.as_str()) == Some("true");
    let limit = parse_int(query.get("limit").map(String::as_str))
        .map(|v| v.clamp(1, 200))
        .unwrap_or(50);
    let offset = parse_int(query.get("offset").map(String::as_str))
        .map(|v| v.max(0))
        .unwrap_or(0);

    let rows = sqlx::query(
        "SELECT
            n.id,
            n.user_id,
            n.actor_id,
            n.type,
            n.quest_id,
            n.review_id,
            n.payload,
            n.payload->>'postId' AS post_id,
            n.created_at,
            n.read_at,
            n.archived_at,
            a.full_name AS actor_name,
            a.avatar_url AS actor_avatar_url,
            a.cosmetics ->> 'name_style' AS actor_name_style, a.cosmetics AS actor_cosmetics,
            a.cosmetics ->> 'avatar_frame' AS actor_avatar_frame,
            q.title AS quest_title,
            q.preview_image_url AS quest_preview_image_url
         FROM notifications n
         LEFT JOIN profiles a ON a.id = n.actor_id
         LEFT JOIN quests q ON q.id = n.quest_id
         WHERE n.user_id = $1
           AND CASE WHEN $4::bool THEN n.archived_at IS NOT NULL ELSE n.archived_at IS NULL END
         ORDER BY n.created_at DESC
         LIMIT $2 OFFSET $3",
    )
    .bind(auth.id)
    .bind(limit)
    .bind(offset)
    .bind(archived)
    .fetch_all(&state.db)
    .await?;

    Ok(Json(rows_to_json(&rows)).into_response())
}

async fn unread_count(State(state): State<Arc<AppState>>, auth: AuthUser) -> ApiResult {
    let row = sqlx::query(
        "SELECT COUNT(*)::int AS count
         FROM notifications
         WHERE user_id = $1
           AND archived_at IS NULL
           AND read_at IS NULL",
    )
    .bind(auth.id)
    .fetch_one(&state.db)
    .await?;

    let count: i32 = row.try_get("count")?;
    ok_json(json!({"count": count}))
}

async fn mark_read(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(id): Path<String>,
) -> ApiResult {
    let id = parse_notification_id(&id)?;

    sqlx::query(
        "UPDATE notifications SET read_at = COALESCE(read_at, NOW())
         WHERE id = $1 AND user_id = $2",
    )
    .bind(id)
    .bind(auth.id)
    .execute(&state.db)
    .await?;

    ok_json(json!({"success": true}))
}

async fn archive(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(id): Path<String>,
) -> ApiResult {
    let id = parse_notification_id(&id)?;

    sqlx::query(
        "UPDATE notifications
         SET archived_at = NOW(), read_at = COALESCE(read_at, NOW())
         WHERE id = $1 AND user_id = $2",
    )
    .bind(id)
    .bind(auth.id)
    .execute(&state.db)
    .await?;

    ok_json(json!({"success": true}))
}

fn parse_notification_id(id: &str) -> Result<Uuid, ApiError> {
    Uuid::parse_str(id).map_err(|_| ApiError::bad_request("Invalid ID format"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn notification_id_validation() {
        assert!(parse_notification_id("not-a-uuid").is_err());
        assert!(parse_notification_id("550e8400-e29b-41d4-a716-446655440000").is_ok());
    }
}
