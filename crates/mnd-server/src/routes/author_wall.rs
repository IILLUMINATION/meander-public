//! `/api/author-walls` — author wall posts, comments, likes, media uploads and
//! review replies. Port of `routes/author-wall.ts`.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, LazyLock};

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, Query, State};
use axum::http::StatusCode;
use axum::routing::{get, post, put};
use regex::Regex;
use serde_json::{Value, json};
use sqlx::Row;
use tokio::io::AsyncReadExt;
use uuid::Uuid;

use crate::auth::{AuthUser, OptionalAuth};
use crate::error::{ApiError, ApiResult, missing_field, ok_created, ok_json};
use crate::extractors::Body;
use crate::json::{parse_int, pg_row_to_json, rows_to_json};
use crate::services::gating::get_karma_and_limits;
use crate::services::image_host::{
    ImageError, accepts_image_part_mime, extension_of, save_uploaded_image,
};
use crate::services::moderation::moderate_wall_post;
use crate::services::notifications::{
    NewNotification, create_bulk_notifications, create_notification,
};
use crate::state::AppState;

const POST_IMAGE_MAX_BYTES: usize = 10 * 1024 * 1024;
const POST_IMAGE_EXTENSIONS: &[&str] = &[".jpg", ".jpeg", ".png", ".webp", ".gif"];
const MAX_POST_LENGTH: usize = 5000;
const MAX_COMMENT_LENGTH: usize = 2000;

static TAG_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"#[a-zA-Zа-яА-ЯёЁ0-9_]+").expect("tag regex"));
static MARKDOWN_IMG_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"!\[.*?\]\((https?://.*?)\)").expect("markdown image regex"));

pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        .route(
            "/upload-media",
            post(upload_media).layer(DefaultBodyLimit::max(POST_IMAGE_MAX_BYTES)),
        )
        .route("/posts/{post_id}/view", post(view_post))
        .route("/{author_id}/posts", get(list_posts).post(create_post))
        .route(
            "/posts/{post_id}",
            get(get_post).put(update_post).delete(delete_post),
        )
        .route("/posts/{post_id}/like", post(like_post))
        .route(
            "/posts/{post_id}/comments",
            get(list_comments).post(create_comment),
        )
        .route(
            "/comments/{comment_id}",
            put(update_comment).delete(delete_comment),
        )
        .route("/comments/{comment_id}/like", post(like_comment))
        .route("/posts/{post_id}/report", post(report_post))
        .route("/comments/{comment_id}/report", post(report_comment))
        .route(
            "/quests/{quest_id}/reviews/{review_id}/reply",
            post(reply_review),
        )
}

// ============================================================
// Helpers
// ============================================================

fn extract_media_urls(body: &Body) -> Vec<String> {
    match body.0.get("media_urls") {
        Some(Value::Array(items)) => items
            .iter()
            .filter_map(|v| v.as_str().map(|s| s.to_string()))
            .collect(),
        _ => Vec::new(),
    }
}

fn extract_tags(content: &str) -> Vec<String> {
    let mut tags = Vec::new();
    let mut seen = HashSet::new();
    for m in TAG_RE.find_iter(content) {
        let tag = m.as_str()[1..].to_lowercase();
        if seen.insert(tag.clone()) {
            tags.push(tag);
        }
    }
    tags
}

fn extract_markdown_images(content: &str) -> Vec<String> {
    MARKDOWN_IMG_RE
        .captures_iter(content)
        .filter_map(|c| c.get(1).map(|m| m.as_str().to_string()))
        .collect()
}

fn dedup_strings_keep_order(items: &[String]) -> Vec<String> {
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for item in items {
        if seen.insert(item.clone()) {
            out.push(item.clone());
        }
    }
    out
}

fn as_count(value: Value) -> Value {
    match value {
        Value::String(s) => s.parse::<i64>().map(|n| json!(n)).unwrap_or(Value::Null),
        Value::Number(_) => value,
        _ => Value::Null,
    }
}

fn clean_post_value(value: Value) -> Value {
    let mut obj = match value {
        Value::Object(m) => m,
        other => return other,
    };
    for key in ["comments_count", "likes_count", "views_count"] {
        if let Some(v) = obj.remove(key) {
            obj.insert(key.to_string(), as_count(v));
        }
    }
    if obj.get("media_urls").is_none() || obj.get("media_urls") == Some(&Value::Null) {
        obj.insert("media_urls".to_string(), Value::Array(vec![]));
    }
    if obj.get("tags").is_none() || obj.get("tags") == Some(&Value::Null) {
        obj.insert("tags".to_string(), Value::Array(vec![]));
    }
    Value::Object(obj)
}

async fn check_blocked(
    state: &AppState,
    viewer_id: Option<Uuid>,
    author_id: Uuid,
) -> Result<bool, ApiError> {
    let Some(viewer_id) = viewer_id else {
        return Ok(false);
    };
    let blocked: Option<i32> =
        sqlx::query_scalar("SELECT 1 FROM user_blocks WHERE user_id = $1 AND blocked_id = $2")
            .bind(viewer_id)
            .bind(author_id)
            .fetch_optional(&state.db)
            .await?;
    Ok(blocked.is_some())
}

async fn post_stats(state: &AppState, post_id: Uuid) -> Result<(i64, i64), ApiError> {
    sqlx::query_as(
        "SELECT likes_count::bigint, (SELECT COUNT(*)::bigint FROM author_post_comments WHERE post_id = $1 AND is_active = true) as comments_count FROM author_posts WHERE id = $1"
    )
    .bind(post_id)
    .fetch_one(&state.db)
    .await
    .map_err(|e| e.into())
}

async fn emit_post_stats(state: &AppState, post_id: Uuid) {
    if let Ok((likes, comments)) = post_stats(state, post_id).await {
        state.emit_to_room(
            &format!("post_{post_id}"),
            "post_stats_updated",
            json!({"postId": post_id.to_string(), "likes_count": likes, "comments_count": comments}),
        );
    }
}

async fn post_author_id(state: &AppState, post_id: Uuid) -> Option<Uuid> {
    sqlx::query_scalar::<_, Uuid>("SELECT author_id FROM author_posts WHERE id = $1")
        .bind(post_id)
        .fetch_optional(&state.db)
        .await
        .ok()
        .flatten()
}

async fn fetch_post_for_emit(state: &AppState, author_id: Uuid, post_id: Uuid) -> Option<Value> {
    let rows = sqlx::query(
        r#"
        SELECT p.id, p.content, p.created_at, p.likes_count, p.views_count, p.media_urls,
               p.tags, p.interest_score,
               (SELECT COUNT(*) FROM author_post_comments WHERE post_id = p.id AND is_active = true) as comments_count,
               pr.full_name as author_name, pr.avatar_url as author_avatar_url, p.author_id,
               pr.cosmetics->>'name_style' as author_name_style, pr.cosmetics AS author_cosmetics,
               pr.is_verified as author_is_verified,
               EXISTS(SELECT 1 FROM user_followers WHERE follower_id = $1 AND user_id = p.author_id) as is_following,
               false as is_liked
        FROM author_posts p
        JOIN profiles pr ON p.author_id = pr.id
        WHERE p.id = $2
        "#
    )
    .bind(author_id)
    .bind(post_id)
    .fetch_all(&state.db)
    .await
    .ok()?;
    rows_to_json(&rows).as_array()?.first().cloned()
}

async fn notify_followers(state: &Arc<AppState>, author_id: Uuid, post_id: Uuid) {
    let follower_rows = sqlx::query("SELECT follower_id FROM user_followers WHERE user_id = $1")
        .bind(author_id)
        .fetch_all(&state.db)
        .await
        .unwrap_or_default();
    let follower_ids: Vec<Uuid> = follower_rows
        .iter()
        .filter_map(|r| r.try_get::<Uuid, _>("follower_id").ok())
        .collect();
    if !follower_ids.is_empty() {
        create_bulk_notifications(
            state,
            &follower_ids,
            Some(author_id),
            "wall_post_new",
            None,
            None,
            Some(json!({"postId": post_id.to_string()})),
        )
        .await;
    }
}

async fn moderate_new_post(
    state: &Arc<AppState>,
    post: Value,
    content: String,
    all_media: Vec<String>,
) {
    let Some(post_id) = post
        .get("id")
        .and_then(|v| v.as_str())
        .and_then(|s| Uuid::parse_str(s).ok())
    else {
        return;
    };
    let Some(author_id) = post
        .get("author_id")
        .and_then(|v| v.as_str())
        .and_then(|s| Uuid::parse_str(s).ok())
    else {
        return;
    };

    let verdict = moderate_wall_post(&content, &all_media);

    if verdict.needs_review {
        let _ = sqlx::query(
            "INSERT INTO reports (reporter_id, reported_type, reported_id, reason, description, status) VALUES ($1, 'wall_post', $2, 'AUTO_FLAGGED_FOR_REVIEW', $3, 'pending')"
        )
        .bind(author_id)
        .bind(post_id)
        .bind(format!("Пост на стене помечен правилами на ручную проверку: {}", verdict.reason))
        .execute(&state.db)
        .await;
    }

    if !verdict.approved {
        let _ = sqlx::query("UPDATE author_posts SET is_active = false WHERE id = $1")
            .bind(post_id)
            .execute(&state.db)
            .await;
    } else {
        let _ = sqlx::query("UPDATE author_posts SET interest_score = $1 WHERE id = $2")
            .bind(verdict.interest_score)
            .bind(post_id)
            .execute(&state.db)
            .await;

        if let Some(payload) = fetch_post_for_emit(state, author_id, post_id).await {
            state.emit_to_room(&format!("post_{post_id}"), "new_wall_post", payload.clone());
            state.emit_to_user(&author_id.to_string(), "new_wall_post", payload);
        }

        notify_followers(state, author_id, post_id).await;
    }
}

async fn moderate_edited_post(
    state: &Arc<AppState>,
    post_id: Uuid,
    user_id: Uuid,
    content: String,
    all_media: Vec<String>,
) {
    let verdict = moderate_wall_post(&content, &all_media);
    if verdict.needs_review {
        let _ = sqlx::query(
            "INSERT INTO reports (reporter_id, reported_type, reported_id, reason, description, status) VALUES ($1, 'wall_post', $2, 'AUTO_FLAGGED_FOR_REVIEW', $3, 'pending')"
        )
        .bind(user_id)
        .bind(post_id)
        .bind(format!("Отредактированный пост помечен правилами на ручную проверку: {}", verdict.reason))
        .execute(&state.db)
        .await;
    }
    if !verdict.approved {
        let _ = sqlx::query("UPDATE author_posts SET is_active = false WHERE id = $1")
            .bind(post_id)
            .execute(&state.db)
            .await;
    } else {
        let _ = sqlx::query("UPDATE author_posts SET interest_score = $1 WHERE id = $2")
            .bind(verdict.interest_score)
            .bind(post_id)
            .execute(&state.db)
            .await;
    }
}

// ============================================================
// Media upload
// ============================================================

async fn upload_media(
    State(state): State<Arc<AppState>>,
    _auth: AuthUser,
    request: axum::extract::Request,
) -> ApiResult {
    let form = match crate::extractors::upload_form(request, &state, POST_IMAGE_MAX_BYTES).await {
        Ok(form) => form,
        Err(crate::extractors::UploadFormError::TooLarge) => {
            return Err(ApiError::new(
                StatusCode::PAYLOAD_TOO_LARGE,
                "Фото не больше 10 МБ",
            ));
        }
        Err(crate::extractors::UploadFormError::BadJson) => {
            return Err(ApiError::bad_request("Bad JSON format"));
        }
        Err(crate::extractors::UploadFormError::Multipart(message)) => {
            return Err(ApiError::bad_request(message));
        }
    };

    let Some(file) = form.file("file") else {
        return Err(ApiError::bad_request("Файл не дошёл до сервера"));
    };

    let ext = extension_of(&file.file_name);
    if ext.is_empty() || !POST_IMAGE_EXTENSIONS.contains(&ext.as_str()) {
        return Err(ApiError::bad_request(
            "Можно прикрепить jpg, png, webp или gif",
        ));
    }
    if !accepts_image_part_mime(file.content_type.as_deref()) {
        return Err(ApiError::bad_request(
            "Можно прикрепить jpg, png, webp или gif",
        ));
    }

    let mut bytes = Vec::new();
    let mut f = tokio::fs::File::open(&file.path)
        .await
        .map_err(|e| ApiError::internal(format!("Не удалось сохрузить фото: {e}")))?;
    f.read_to_end(&mut bytes)
        .await
        .map_err(|e| ApiError::internal(format!("Не удалось сохрузить фото: {e}")))?;

    match save_uploaded_image(
        &state.cfg.public_dir.join("uploads"),
        &bytes,
        &file.file_name,
        &state.cfg.base_url,
    ) {
        Ok(url) => ok_json(json!({ "url": url })),
        Err(ImageError::Unsupported(_)) => Err(ApiError::new(
            StatusCode::UNSUPPORTED_MEDIA_TYPE,
            "Это не похоже на картинку — поддерживаются jpg, png, webp и gif",
        )),
        Err(ImageError::Save(_)) => Err(ApiError::internal("Не удалось сохранить фото")),
    }
}

// ============================================================
// Posts
// ============================================================

async fn view_post(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(post_id): Path<String>,
) -> ApiResult {
    let post_id =
        Uuid::parse_str(&post_id).map_err(|_| ApiError::bad_request("Invalid post ID"))?;

    let mut tx = state.db.begin().await?;
    let inserted = sqlx::query(
        "INSERT INTO author_post_views (post_id, user_id) VALUES ($1, $2) ON CONFLICT (post_id, user_id) DO NOTHING RETURNING *"
    )
    .bind(post_id)
    .bind(auth.id)
    .fetch_optional(&mut *tx)
    .await?;

    if inserted.is_some() {
        sqlx::query("UPDATE author_posts SET views_count = views_count + 1 WHERE id = $1")
            .bind(post_id)
            .execute(&mut *tx)
            .await?;
    }
    tx.commit().await?;

    ok_json(json!({"success": true, "new_view": inserted.is_some()}))
}

async fn list_posts(
    State(state): State<Arc<AppState>>,
    auth: OptionalAuth,
    Path(author_id): Path<String>,
    Query(q): Query<HashMap<String, String>>,
) -> ApiResult {
    let author_id = Uuid::parse_str(&author_id)
        .map_err(|_| ApiError::bad_request("Invalid author ID format"))?;

    if check_blocked(&state, auth.id(), author_id).await? {
        return ok_json(json!([]));
    }

    let limit = parse_int(q.get("limit").map(|s| s.as_str()))
        .unwrap_or(20)
        .clamp(1, 100);
    let offset = parse_int(q.get("offset").map(|s| s.as_str()))
        .unwrap_or(0)
        .max(0);

    let rows = sqlx::query(
        r#"
        SELECT ap.id, ap.author_id, ap.content, ap.title, ap.created_at, ap.updated_at,
               ap.likes_count, ap.is_active, ap.interest_score, ap.views_count,
               ap.media_urls, ap.tags,
               (SELECT COUNT(*) FROM author_post_comments WHERE post_id = ap.id AND is_active = true) as comments_count,
               p.full_name as author_name, p.avatar_url as author_avatar_url,
               p.cosmetics->>'name_style' as author_name_style, p.cosmetics AS author_cosmetics,
               p.is_verified as author_is_verified,
               EXISTS (SELECT 1 FROM author_post_likes apl WHERE apl.post_id = ap.id AND apl.user_id = $3) as is_liked_by_viewer
        FROM author_posts ap
        JOIN profiles p ON p.id = ap.author_id
        WHERE ap.author_id = $1 AND ap.is_active = true
        ORDER BY ap.created_at DESC
        LIMIT $2 OFFSET $4
        "#
    )
    .bind(author_id)
    .bind(limit)
    .bind(auth.id())
    .bind(offset)
    .fetch_all(&state.db)
    .await?;

    let mut posts = rows_to_json(&rows);
    if let Value::Array(arr) = &mut posts {
        for post in arr {
            *post = clean_post_value(post.take());
        }
    }
    ok_json(posts)
}

async fn create_post(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(author_id): Path<String>,
    body: Body,
) -> ApiResult {
    let author_id = Uuid::parse_str(&author_id)
        .map_err(|_| ApiError::bad_request("Invalid author ID format"))?;

    if author_id != auth.id {
        return Err(ApiError::forbidden(
            "Only the author can post on their wall",
        ));
    }

    let content = body.str("content").unwrap_or("").trim();
    if content.is_empty() {
        return Err(missing_field("Content"));
    }
    if content.chars().count() > MAX_POST_LENGTH {
        return Err(ApiError::bad_request(format!(
            "Пост не длиннее {MAX_POST_LENGTH} символов"
        )));
    }

    let limits = get_karma_and_limits(&state, auth.id).await;
    if limits.post_cooldown_min > 0 {
        let recent = sqlx::query_scalar::<_, Uuid>(
            "SELECT id FROM author_posts WHERE author_id = $1 AND created_at > NOW() - $2 * INTERVAL '1 minute' LIMIT 1"
        )
        .bind(author_id)
        .bind(limits.post_cooldown_min)
        .fetch_optional(&state.db)
        .await?;
        if recent.is_some() {
            return Err(ApiError::new(
                StatusCode::TOO_MANY_REQUESTS,
                format!(
                    "Пожалуйста, подождите {} минут перед публикацией следующего поста.",
                    limits.post_cooldown_min
                ),
            ));
        }
    }

    let tags = extract_tags(content);
    let media_urls = extract_media_urls(&body);
    let markdown_imgs = extract_markdown_images(content);
    let all_media = dedup_strings_keep_order(&[media_urls.clone(), markdown_imgs].concat());

    let row = sqlx::query(
        "INSERT INTO author_posts (author_id, content, media_urls, tags) VALUES ($1, $2, $3, $4) RETURNING *"
    )
    .bind(author_id)
    .bind(content)
    .bind(json!(media_urls))
    .bind(&tags)
    .fetch_one(&state.db)
    .await?;

    let post = pg_row_to_json(&row);
    let response = post.clone();

    let state_bg = state.clone();
    let content_bg = content.to_string();
    tokio::spawn(async move {
        moderate_new_post(&state_bg, post, content_bg, all_media).await;
    });

    ok_created(response)
}

async fn update_post(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(post_id): Path<String>,
    body: Body,
) -> ApiResult {
    let post_id =
        Uuid::parse_str(&post_id).map_err(|_| ApiError::internal("Internal server error"))?;

    let content = body.str("content").unwrap_or("").trim();
    if content.is_empty() {
        return Err(missing_field("Content"));
    }
    if content.chars().count() > MAX_POST_LENGTH {
        return Err(ApiError::bad_request(format!(
            "Пост не длиннее {MAX_POST_LENGTH} символов"
        )));
    }

    let post = sqlx::query("SELECT author_id FROM author_posts WHERE id = $1")
        .bind(post_id)
        .fetch_optional(&state.db)
        .await?;
    let row = post.ok_or_else(|| ApiError::not_found("Post not found"))?;
    let author_id: Uuid = row.try_get("author_id")?;
    if author_id != auth.id {
        return Err(ApiError::forbidden("Forbidden"));
    }

    let tags = extract_tags(content);
    let media_urls = extract_media_urls(&body);
    let markdown_imgs = extract_markdown_images(content);
    let all_media = dedup_strings_keep_order(&[media_urls.clone(), markdown_imgs].concat());

    let row = sqlx::query(
        "UPDATE author_posts SET content = $1, media_urls = $2, tags = $3 WHERE id = $4 RETURNING *"
    )
    .bind(content)
    .bind(json!(media_urls))
    .bind(&tags)
    .bind(post_id)
    .fetch_one(&state.db)
    .await?;

    let response = pg_row_to_json(&row);

    let state_bg = state.clone();
    let content_bg = content.to_string();
    tokio::spawn(async move {
        moderate_edited_post(&state_bg, post_id, auth.id, content_bg, all_media).await;
    });

    ok_json(response)
}

async fn delete_post(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(post_id): Path<String>,
) -> ApiResult {
    let post_id =
        Uuid::parse_str(&post_id).map_err(|_| ApiError::internal("Internal server error"))?;

    let post = sqlx::query("SELECT author_id FROM author_posts WHERE id = $1")
        .bind(post_id)
        .fetch_optional(&state.db)
        .await?;
    let row = post.ok_or_else(|| ApiError::not_found("Post not found"))?;
    let author_id: Uuid = row.try_get("author_id")?;
    if author_id != auth.id {
        return Err(ApiError::forbidden("Forbidden"));
    }

    sqlx::query("UPDATE author_posts SET is_active = false WHERE id = $1")
        .bind(post_id)
        .execute(&state.db)
        .await?;

    ok_json(json!({"success": true}))
}

async fn like_post(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(post_id): Path<String>,
) -> ApiResult {
    let post_id =
        Uuid::parse_str(&post_id).map_err(|_| ApiError::internal("Internal server error"))?;

    let existing =
        sqlx::query("SELECT 1 FROM author_post_likes WHERE post_id = $1 AND user_id = $2")
            .bind(post_id)
            .bind(auth.id)
            .fetch_optional(&state.db)
            .await?;

    if existing.is_some() {
        let _ = sqlx::query("DELETE FROM author_post_likes WHERE post_id = $1 AND user_id = $2")
            .bind(post_id)
            .bind(auth.id)
            .execute(&state.db)
            .await;
        let _ = sqlx::query(
            "UPDATE author_posts SET likes_count = GREATEST(likes_count - 1, 0) WHERE id = $1",
        )
        .bind(post_id)
        .execute(&state.db)
        .await;
        emit_post_stats(&state, post_id).await;
        ok_json(json!({"liked": false}))
    } else {
        let _ = sqlx::query("INSERT INTO author_post_likes (post_id, user_id) VALUES ($1, $2)")
            .bind(post_id)
            .bind(auth.id)
            .execute(&state.db)
            .await;
        let _ = sqlx::query("UPDATE author_posts SET likes_count = likes_count + 1 WHERE id = $1")
            .bind(post_id)
            .execute(&state.db)
            .await;
        emit_post_stats(&state, post_id).await;

        if let Some(author_id) = post_author_id(&state, post_id).await
            && author_id != auth.id
        {
            let _ = create_notification(
                &state,
                NewNotification {
                    user_id: author_id,
                    actor_id: Some(auth.id),
                    kind: "wall_post_like",
                    quest_id: None,
                    review_id: None,
                    payload: Some(json!({"postId": post_id.to_string()})),
                },
            )
            .await;
        }
        ok_json(json!({"liked": true}))
    }
}

// ============================================================
// Comments
// ============================================================

async fn get_post(
    State(state): State<Arc<AppState>>,
    auth: OptionalAuth,
    Path(post_id): Path<String>,
) -> ApiResult {
    let post_id =
        Uuid::parse_str(&post_id).map_err(|_| ApiError::internal("Internal server error"))?;

    let rows = sqlx::query(
        r#"
        SELECT p.id, p.author_id, p.content, p.title, p.forum_id, p.created_at, p.updated_at,
               p.likes_count, p.is_active, p.interest_score, p.views_count,
               p.media_urls, p.tags,
               (SELECT COUNT(*) FROM author_post_comments WHERE post_id = p.id AND is_active = true) as comments_count,
               pr.full_name as author_name, pr.avatar_url as author_avatar_url,
               pr.cosmetics->>'name_style' as author_name_style, pr.cosmetics AS author_cosmetics,
               pr.is_verified as author_is_verified,
               EXISTS(SELECT 1 FROM user_followers WHERE follower_id = $2 AND user_id = p.author_id) as is_following,
               EXISTS(SELECT 1 FROM author_post_likes WHERE post_id = p.id AND user_id = $2) as is_liked
        FROM author_posts p
        JOIN profiles pr ON pr.id = p.author_id
        WHERE p.id = $1 AND p.is_active = true
        "#
    )
    .bind(post_id)
    .bind(auth.id())
    .fetch_all(&state.db)
    .await?;

    if rows.is_empty() {
        return Err(ApiError::not_found("Post not found"));
    }

    let mut value = pg_row_to_json(&rows[0]);
    value = clean_post_value(value);
    ok_json(value)
}

async fn list_comments(
    State(state): State<Arc<AppState>>,
    auth: OptionalAuth,
    Path(post_id): Path<String>,
) -> ApiResult {
    let post_id =
        Uuid::parse_str(&post_id).map_err(|_| ApiError::internal("Internal server error"))?;

    let full_sql = r#"
        SELECT apc.*, p.full_name as user_name, p.avatar_url as user_avatar_url,
               p.cosmetics->>'name_style' as user_name_style, p.cosmetics AS user_cosmetics,
               EXISTS (SELECT 1 FROM author_post_comment_likes apcl WHERE apcl.comment_id = apc.id AND apcl.user_id = $2) as is_liked_by_viewer
        FROM author_post_comments apc
        JOIN profiles p ON p.id = apc.user_id
        WHERE apc.post_id = $1 AND apc.is_active = true
        ORDER BY apc.created_at ASC
        "#;

    let fallback_sql = r#"
        SELECT apc.id, apc.post_id, apc.user_id, apc.content, apc.created_at, apc.likes_count,
               null as parent_id, p.full_name as user_name, p.avatar_url as user_avatar_url,
               p.cosmetics->>'name_style' as user_name_style, p.cosmetics AS user_cosmetics,
               EXISTS (SELECT 1 FROM author_post_comment_likes apcl WHERE apcl.comment_id = apc.id AND apcl.user_id = $2) as is_liked_by_viewer
        FROM author_post_comments apc
        JOIN profiles p ON p.id = apc.user_id
        WHERE apc.post_id = $1 AND apc.is_active = true
        ORDER BY apc.created_at ASC
        "#;

    let rows = match sqlx::query(full_sql)
        .bind(post_id)
        .bind(auth.id())
        .fetch_all(&state.db)
        .await
    {
        Ok(rows) => rows,
        Err(sqlx::Error::Database(db)) if db.code().as_deref() == Some("42703") => {
            sqlx::query(fallback_sql)
                .bind(post_id)
                .bind(auth.id())
                .fetch_all(&state.db)
                .await?
        }
        Err(e) => return Err(e.into()),
    };

    ok_json(rows_to_json(&rows))
}

async fn create_comment(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(post_id): Path<String>,
    body: Body,
) -> ApiResult {
    let post_id =
        Uuid::parse_str(&post_id).map_err(|_| ApiError::bad_request("Invalid post ID"))?;

    let content = body.str("content").unwrap_or("").trim();
    if content.is_empty() {
        return Err(missing_field("Content"));
    }
    if content.chars().count() > MAX_COMMENT_LENGTH {
        return Err(ApiError::bad_request(format!(
            "Комментарий не длиннее {MAX_COMMENT_LENGTH} символов"
        )));
    }

    let post = sqlx::query("SELECT is_active FROM author_posts WHERE id = $1")
        .bind(post_id)
        .fetch_optional(&state.db)
        .await?;
    match post {
        Some(row) if row.try_get::<bool, _>("is_active").unwrap_or(false) => {}
        _ => return Err(ApiError::not_found("Post not found")),
    }

    let limits = get_karma_and_limits(&state, auth.id).await;
    if limits.comment_cooldown_sec > 0 {
        let recent = sqlx::query_scalar::<_, Uuid>(
            "SELECT id FROM author_post_comments WHERE user_id = $1 AND created_at > NOW() - $2 * INTERVAL '1 second' LIMIT 1"
        )
        .bind(auth.id)
        .bind(limits.comment_cooldown_sec)
        .fetch_optional(&state.db)
        .await?;
        if recent.is_some() {
            return Err(ApiError::new(
                StatusCode::TOO_MANY_REQUESTS,
                format!(
                    "Вы комментируете слишком часто. Подождите {} сек.",
                    limits.comment_cooldown_sec
                ),
            ));
        }
    }

    let parent_id = body.str("parentId").and_then(|s| Uuid::parse_str(s).ok());

    let full_sql = "INSERT INTO author_post_comments (post_id, user_id, content, parent_id) VALUES ($1, $2, $3, $4) RETURNING *";
    let fallback_sql = "INSERT INTO author_post_comments (post_id, user_id, content) VALUES ($1, $2, $3) RETURNING *";

    let row = match sqlx::query(full_sql)
        .bind(post_id)
        .bind(auth.id)
        .bind(content)
        .bind(parent_id)
        .fetch_one(&state.db)
        .await
    {
        Ok(row) => row,
        Err(sqlx::Error::Database(db)) if db.code().as_deref() == Some("42703") => {
            sqlx::query(fallback_sql)
                .bind(post_id)
                .bind(auth.id)
                .bind(content)
                .fetch_one(&state.db)
                .await?
        }
        Err(e) => return Err(e.into()),
    };

    let comment = pg_row_to_json(&row);

    // Notify author of the post or parent comment.
    if let Some(parent_id) = parent_id {
        if let Some(parent_row) =
            sqlx::query("SELECT user_id FROM author_post_comments WHERE id = $1")
                .bind(parent_id)
                .fetch_optional(&state.db)
                .await?
        {
            let parent_author_id: Uuid = parent_row.try_get("user_id")?;
            if parent_author_id != auth.id {
                let _ = create_notification(
                    &state,
                    NewNotification {
                        user_id: parent_author_id,
                        actor_id: Some(auth.id),
                        kind: "wall_post_comment_reply",
                        quest_id: None,
                        review_id: None,
                        payload: Some(json!({
                            "postId": post_id.to_string(),
                            "commentId": comment["id"].as_str(),
                            "parentId": parent_id.to_string(),
                        })),
                    },
                )
                .await;
            }
        }
    } else if let Some(author_id) = post_author_id(&state, post_id).await
        && author_id != auth.id
    {
        let _ = create_notification(
            &state,
            NewNotification {
                user_id: author_id,
                actor_id: Some(auth.id),
                kind: "wall_post_comment",
                quest_id: None,
                review_id: None,
                payload: Some(json!({
                    "postId": post_id.to_string(),
                    "commentId": comment["id"].as_str(),
                })),
            },
        )
        .await;
    }

    state.emit_to_room(&format!("post_{post_id}"), "new_comment", comment.clone());
    emit_post_stats(&state, post_id).await;

    ok_created(comment)
}

async fn update_comment(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(comment_id): Path<String>,
    body: Body,
) -> ApiResult {
    let comment_id =
        Uuid::parse_str(&comment_id).map_err(|_| ApiError::internal("Internal server error"))?;

    let content = body.str("content").unwrap_or("").trim();
    if content.is_empty() {
        return Err(missing_field("Content"));
    }
    if content.chars().count() > MAX_COMMENT_LENGTH {
        return Err(ApiError::bad_request(format!(
            "Комментарий не длиннее {MAX_COMMENT_LENGTH} символов"
        )));
    }

    let comment = sqlx::query("SELECT user_id FROM author_post_comments WHERE id = $1")
        .bind(comment_id)
        .fetch_optional(&state.db)
        .await?;
    let row = comment.ok_or_else(|| ApiError::not_found("Comment not found"))?;
    let user_id: Uuid = row.try_get("user_id")?;
    if user_id != auth.id {
        return Err(ApiError::forbidden("Forbidden"));
    }

    let row = sqlx::query("UPDATE author_post_comments SET content = $1 WHERE id = $2 RETURNING *")
        .bind(content)
        .bind(comment_id)
        .fetch_one(&state.db)
        .await?;

    ok_json(pg_row_to_json(&row))
}

async fn delete_comment(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(comment_id): Path<String>,
) -> ApiResult {
    let comment_id =
        Uuid::parse_str(&comment_id).map_err(|_| ApiError::internal("Internal server error"))?;

    let comment = sqlx::query("SELECT user_id, post_id FROM author_post_comments WHERE id = $1")
        .bind(comment_id)
        .fetch_optional(&state.db)
        .await?;
    let row = comment.ok_or_else(|| ApiError::not_found("Comment not found"))?;
    let user_id: Uuid = row.try_get("user_id")?;
    if user_id != auth.id {
        return Err(ApiError::forbidden("Forbidden"));
    }
    let post_id: Uuid = row.try_get("post_id")?;

    sqlx::query("UPDATE author_post_comments SET is_active = false WHERE id = $1")
        .bind(comment_id)
        .execute(&state.db)
        .await?;

    emit_post_stats(&state, post_id).await;

    ok_json(json!({"success": true}))
}

async fn like_comment(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(comment_id): Path<String>,
) -> ApiResult {
    let comment_id =
        Uuid::parse_str(&comment_id).map_err(|_| ApiError::internal("Internal server error"))?;

    let existing = sqlx::query(
        "SELECT 1 FROM author_post_comment_likes WHERE comment_id = $1 AND user_id = $2",
    )
    .bind(comment_id)
    .bind(auth.id)
    .fetch_optional(&state.db)
    .await?;

    if existing.is_some() {
        let _ = sqlx::query(
            "DELETE FROM author_post_comment_likes WHERE comment_id = $1 AND user_id = $2",
        )
        .bind(comment_id)
        .bind(auth.id)
        .execute(&state.db)
        .await;
        let _ = sqlx::query("UPDATE author_post_comments SET likes_count = GREATEST(likes_count - 1, 0) WHERE id = $1")
            .bind(comment_id)
            .execute(&state.db)
            .await;
        ok_json(json!({"liked": false}))
    } else {
        let _ = sqlx::query(
            "INSERT INTO author_post_comment_likes (comment_id, user_id) VALUES ($1, $2)",
        )
        .bind(comment_id)
        .bind(auth.id)
        .execute(&state.db)
        .await;
        let _ = sqlx::query(
            "UPDATE author_post_comments SET likes_count = likes_count + 1 WHERE id = $1",
        )
        .bind(comment_id)
        .execute(&state.db)
        .await;
        ok_json(json!({"liked": true}))
    }
}

// ============================================================
// Reports
// ============================================================

async fn report_post(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(post_id): Path<String>,
    body: Body,
) -> ApiResult {
    let post_id =
        Uuid::parse_str(&post_id).map_err(|_| ApiError::internal("Internal server error"))?;

    let reason = body.str("reason").unwrap_or("").trim();
    if reason.is_empty() {
        return Err(missing_field("Reason"));
    }

    sqlx::query(
        "INSERT INTO author_post_reports (post_id, reporter_id, reason) VALUES ($1, $2, $3) ON CONFLICT (post_id, reporter_id) DO NOTHING"
    )
    .bind(post_id)
    .bind(auth.id)
    .bind(reason)
    .execute(&state.db)
    .await?;

    ok_json(json!({"success": true}))
}

async fn report_comment(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(comment_id): Path<String>,
    body: Body,
) -> ApiResult {
    let comment_id =
        Uuid::parse_str(&comment_id).map_err(|_| ApiError::internal("Internal server error"))?;

    let reason = body.str("reason").unwrap_or("").trim();
    if reason.is_empty() {
        return Err(missing_field("Reason"));
    }

    sqlx::query(
        "INSERT INTO author_post_comment_reports (comment_id, reporter_id, reason) VALUES ($1, $2, $3) ON CONFLICT (comment_id, reporter_id) DO NOTHING"
    )
    .bind(comment_id)
    .bind(auth.id)
    .bind(reason)
    .execute(&state.db)
    .await?;

    ok_json(json!({"success": true}))
}

// ============================================================
// Review replies
// ============================================================

async fn reply_review(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path((quest_id, review_id)): Path<(String, String)>,
    body: Body,
) -> ApiResult {
    let text = body.str("text").unwrap_or("").trim();
    if text.is_empty() {
        return Err(missing_field("Text"));
    }

    // Node passes both ids straight into a UUID query, so a malformed id is an
    // SQL error caught by the route's generic handler.
    let quest_id =
        Uuid::parse_str(&quest_id).map_err(|_| ApiError::internal("Internal server error"))?;
    let review_id =
        Uuid::parse_str(&review_id).map_err(|_| ApiError::internal("Internal server error"))?;

    let quest = sqlx::query("SELECT author_id, title FROM quests WHERE id = $1")
        .bind(quest_id)
        .fetch_optional(&state.db)
        .await
        .map_err(|_| ApiError::internal("Internal server error"))?;
    let quest = quest.ok_or_else(|| ApiError::not_found("Quest not found"))?;
    let quest_author_id: Uuid = quest
        .try_get("author_id")
        .map_err(|_| ApiError::internal("Internal server error"))?;
    let title: String = quest
        .try_get("title")
        .map_err(|_| ApiError::internal("Internal server error"))?;

    if quest_author_id != auth.id {
        return Err(ApiError::forbidden(
            "Only the quest author can reply to reviews",
        ));
    }

    let result = sqlx::query(
        "UPDATE reviews SET author_reply = $1, author_reply_at = NOW() WHERE id = $2 AND quest_id = $3 RETURNING id, author_id"
    )
    .bind(text)
    .bind(review_id)
    .bind(quest_id)
    .fetch_optional(&state.db)
    .await
    .map_err(|_| ApiError::internal("Internal server error"))?;

    let row = result.ok_or_else(|| ApiError::not_found("Review not found"))?;
    let review_author_id: Uuid = row
        .try_get("author_id")
        .map_err(|_| ApiError::internal("Internal server error"))?;

    if review_author_id != auth.id {
        let _ = create_notification(
            &state,
            NewNotification {
                user_id: review_author_id,
                actor_id: Some(auth.id),
                kind: "review_reply",
                quest_id: Some(quest_id),
                review_id: Some(review_id),
                payload: Some(json!({"title": title})),
            },
        )
        .await;
    }

    ok_json(json!({"success": true}))
}

// ============================================================
// Unit tests for pure helpers
// ============================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_tags_and_dedups() {
        let text = "Hello #World and #world #Привет #tag123!";
        let tags = extract_tags(text);
        assert_eq!(tags, vec!["world", "привет", "tag123"]);
    }

    #[test]
    fn extracts_markdown_images() {
        let text = "![alt](https://example.com/a.png) and ![](http://x.com/b.jpg)";
        let urls = extract_markdown_images(text);
        assert_eq!(
            urls,
            vec!["https://example.com/a.png", "http://x.com/b.jpg"]
        );
    }

    #[test]
    fn dedup_preserves_order() {
        let a = vec!["a".into(), "b".into(), "a".into(), "c".into()];
        assert_eq!(dedup_strings_keep_order(&a), vec!["a", "b", "c"]);
    }

    #[test]
    fn clean_post_parses_counts_and_defaults_arrays() {
        let mut obj = serde_json::Map::new();
        obj.insert("comments_count".into(), Value::String("5".into()));
        obj.insert("likes_count".into(), Value::Number(12.into()));
        obj.insert("media_urls".into(), Value::Null);
        let value = clean_post_value(Value::Object(obj));
        let obj = value.as_object().unwrap();
        assert_eq!(obj["comments_count"], json!(5));
        assert_eq!(obj["likes_count"], json!(12));
        assert_eq!(obj["media_urls"], json!([]));
        assert_eq!(obj["tags"], json!([]));
    }
}
