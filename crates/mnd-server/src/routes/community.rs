//! `/api/community` — public community lists, search and featured feeds.
//!
//! Port of `backend/src/routes/community.ts`.

use std::collections::HashMap;
use std::sync::Arc;

use axum::{
    Router,
    extract::{Path, Query, State},
    routing::get,
};
use serde_json::{Map, Value};
use uuid::Uuid;

use crate::auth::OptionalAuth;
use crate::error::{ApiError, ApiResult, ok_json};
use crate::json::{parse_int, pg_row_to_json, rows_to_json};
use crate::state::AppState;

const ACTIVE_WINDOW_DAYS: i64 = 7;
const ONLINE_LIMIT_MAX: i64 = 50;

pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        .route("/online", get(online_users))
        .route("/top", get(top_authors))
        .route("/feed", get(global_feed))
        .route("/post/{id}", get(single_post))
}

async fn online_users(
    State(state): State<Arc<AppState>>,
    Query(q): Query<HashMap<String, String>>,
) -> ApiResult {
    let requested = parse_int(q.get("limit").map(|s| s.as_str())).unwrap_or(20);
    let limit = requested.clamp(1, ONLINE_LIMIT_MAX);

    let rows = sqlx::query(
        "SELECT id, full_name, avatar_url, last_seen_at,
                cosmetics ->> 'name_style' AS name_style, cosmetics AS cosmetics
         FROM profiles
         WHERE is_blocked = FALSE
           AND last_seen_at > NOW() - ($2 || ' days')::INTERVAL
         ORDER BY last_seen_at DESC NULLS LAST
         LIMIT $1",
    )
    .bind(limit)
    .bind(ACTIVE_WINDOW_DAYS.to_string())
    .fetch_all(&state.db)
    .await?;

    ok_json(rows_to_json(&rows))
}

async fn top_authors(
    State(state): State<Arc<AppState>>,
    Query(q): Query<HashMap<String, String>>,
) -> ApiResult {
    let limit = parse_int(q.get("limit").map(|s| s.as_str())).unwrap_or(10);
    let type_ = q.get("type").map(|s| s.as_str()).unwrap_or("followers");

    let (select_fields, order_by) = match type_ {
        "followers" => (
            "(SELECT COUNT(*)::int FROM user_followers WHERE user_id = p.id) as metric_count",
            "ORDER BY metric_count DESC NULLS LAST",
        ),
        "likes" => (
            "(SELECT COALESCE(SUM(like_count), 0)::int FROM quests WHERE author_id = p.id) as metric_count",
            "ORDER BY metric_count DESC NULLS LAST",
        ),
        "quests" => (
            "(SELECT COUNT(*)::int FROM quests WHERE author_id = p.id) as metric_count",
            "ORDER BY metric_count DESC NULLS LAST",
        ),
        _ => return Err(ApiError::bad_request("Invalid type parameter")),
    };

    let sql = format!(
        "SELECT p.id, p.full_name, p.avatar_url, p.streak_count, p.is_verified, p.role,
                p.cosmetics->>'name_style' AS name_style, p.cosmetics AS cosmetics,
                {select_fields}
         FROM profiles p
         WHERE true
         {order_by}
         LIMIT $1"
    );

    let rows = sqlx::query(&sql).bind(limit).fetch_all(&state.db).await?;
    ok_json(rows_to_json(&rows))
}

async fn global_feed(
    State(state): State<Arc<AppState>>,
    auth: OptionalAuth,
    Query(q): Query<HashMap<String, String>>,
) -> ApiResult {
    let limit = parse_int(q.get("limit").map(|s| s.as_str())).unwrap_or(20);
    let offset = parse_int(q.get("offset").map(|s| s.as_str())).unwrap_or(0);
    let filter = q.get("filter").map(|s| s.as_str()).unwrap_or("all");
    let viewer_id: Option<Uuid> = auth.id();

    if filter == "following" && viewer_id.is_none() {
        return Err(ApiError::unauthorized(
            "Unauthorized to view following feed",
        ));
    }

    let mut where_clause = "ap.is_active = true AND ap.forum_id IS NULL".to_string();

    if filter == "following" {
        where_clause.push_str(
            " AND ap.author_id IN (SELECT user_id FROM user_followers WHERE follower_id = $3)",
        );
    }

    where_clause.push_str(
        " AND NOT EXISTS (
            SELECT 1 FROM user_blocks ub
            WHERE ub.user_id = $3 AND ub.blocked_id = ap.author_id
        )",
    );

    let sql = format!(
        "SELECT
           ap.id, ap.author_id, ap.content, ap.title, ap.created_at, ap.updated_at,
           ap.likes_count, ap.is_active, ap.interest_score, ap.views_count,
           ap.media_urls, ap.tags,
           (SELECT COUNT(*) FROM author_post_comments WHERE post_id = ap.id AND is_active = true) as comments_count,
           p.full_name as author_name,
           p.avatar_url as author_avatar_url,
           p.cosmetics->>'name_style' as author_name_style, p.cosmetics AS author_cosmetics,
           p.is_verified as author_is_verified,
           EXISTS (
             SELECT 1 FROM author_post_likes apl
             WHERE apl.post_id = ap.id AND apl.user_id = $3
           ) as is_liked_by_viewer
         FROM author_posts ap
         JOIN profiles p ON p.id = ap.author_id
         WHERE {where_clause}
         ORDER BY (COALESCE(ap.interest_score, 50) + ap.likes_count * 15) / POWER(EXTRACT(EPOCH FROM (NOW() - ap.created_at))/3600 + 2, 1.5) DESC, ap.created_at DESC
         LIMIT $1 OFFSET $2::bigint"
    );

    let rows = sqlx::query(&sql)
        .bind(limit)
        .bind(offset)
        .bind(viewer_id)
        .fetch_all(&state.db)
        .await?;

    let posts: Vec<Value> = rows
        .iter()
        .map(|r| normalize_post(pg_row_to_json(r)))
        .collect();
    ok_json(Value::Array(posts))
}

async fn single_post(
    State(state): State<Arc<AppState>>,
    auth: OptionalAuth,
    Path(raw_id): Path<String>,
) -> ApiResult {
    let post_id = match Uuid::parse_str(&raw_id) {
        Ok(id) => id,
        Err(_) => return Err(ApiError::bad_request("Invalid post ID format")),
    };
    let viewer_id: Option<Uuid> = auth.id();

    let rows = sqlx::query(
        "SELECT
           ap.id, ap.author_id, ap.content, ap.created_at, ap.updated_at,
           ap.likes_count, ap.is_active, ap.interest_score, ap.views_count,
           ap.media_urls, ap.tags,
           (SELECT COUNT(*) FROM author_post_comments WHERE post_id = ap.id AND is_active = true) as comments_count,
           p.full_name as author_name,
           p.avatar_url as author_avatar_url,
           p.cosmetics->>'name_style' as author_name_style, p.cosmetics AS author_cosmetics,
           p.is_verified as author_is_verified,
           EXISTS (
             SELECT 1 FROM author_post_likes apl
             WHERE apl.post_id = ap.id AND apl.user_id = $2
           ) as is_liked_by_viewer
         FROM author_posts ap
         JOIN profiles p ON p.id = ap.author_id
         WHERE ap.id = $1 AND ap.is_active = true
           AND NOT EXISTS (
             SELECT 1 FROM user_blocks ub
             WHERE ub.user_id = $2::uuid AND ub.blocked_id = ap.author_id
           )",
    )
    .bind(post_id)
    .bind(viewer_id)
    .fetch_all(&state.db)
    .await?;

    let row = match rows.into_iter().next() {
        Some(row) => row,
        None => return Err(ApiError::not_found("Post not found")),
    };

    ok_json(normalize_post(pg_row_to_json(&row)))
}

fn normalize_post(mut value: Value) -> Value {
    let map = match value.as_object_mut() {
        Some(map) => map,
        None => return value,
    };

    if let Some(v) = map.get("comments_count") {
        map.insert(
            "comments_count".to_string(),
            Value::Number(value_to_i64(v).into()),
        );
    }
    if let Some(v) = map.get("likes_count") {
        map.insert(
            "likes_count".to_string(),
            Value::Number(value_to_i64(v).into()),
        );
    }
    if let Some(v) = map.get("views_count") {
        map.insert(
            "views_count".to_string(),
            Value::Number(value_to_i64(v).into()),
        );
    }
    if let Some(v) = map.get("media_urls") {
        if v.is_null() {
            map.insert("media_urls".to_string(), Value::Array(vec![]));
        }
    }
    if let Some(v) = map.get("tags") {
        if v.is_null() {
            map.insert("tags".to_string(), Value::Array(vec![]));
        }
    }

    Value::Object(Map::from_iter(map.clone()))
}

fn value_to_i64(v: &Value) -> i64 {
    match v {
        Value::Number(n) => n.as_i64().unwrap_or(0),
        Value::String(s) => s.parse().unwrap_or(0),
        _ => 0,
    }
}
