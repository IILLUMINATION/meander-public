//! `/profiles` routes — port of `backend/src/routes/profiles.ts`.
//!
//! Covers profile read/update, avatars, banners, cosmetics, rewards progress,
//! playtime, follows, settings (including GitHub sync) and FCM tokens.

use std::collections::HashSet;
use std::sync::Arc;

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::routing::{get, post};
use chrono::{DateTime, Utc};
use serde_json::{Map, Value, json};
use uuid::Uuid;

use crate::auth::{AuthUser, OptionalAuth};
use crate::error::{ApiError, ApiResult, ok_json};
use crate::extractors::Body;
use crate::json::rows_to_json;
use crate::services::achievements::award_achievement;
use crate::services::cosmetics::{
    cosmetic_slot, cosmetic_tier, equipped_for, find_missing_grants, legacy_banner_style,
    list_grants, validate_equipped,
};
use crate::services::image_host::{
    ImageError, accepts_image_part_mime, extension_of, save_uploaded_image,
};
use crate::services::notifications::{NewNotification, create_notification};
use crate::services::rewards::{grant_due_rewards, reward_progress};
use crate::services::sync_settings_crypto::{decrypt_token, encrypt_token};
use crate::services::visibility::is_staff;
use crate::state::AppState;

// ========================================================================
//  Profile: banner/social validation
// ========================================================================

const ALLOWED_BANNER_IDS: &[&str] = &[
    "beige",
    "forest",
    "royal_purple",
    "sunset",
    "ocean",
    "rose",
    "cyber",
    "mono",
    "aurora",
];

const ALLOWED_SOCIAL_PLATFORMS: &[&str] = &[
    "telegram",
    "youtube",
    "vk",
    "instagram",
    "twitter",
    "x",
    "github",
    "boosty",
    "discord",
    "website",
    "tiktok",
];

const MAX_SOCIAL_LINKS: usize = 8;
const MAX_URL_LENGTH: usize = 500;

fn validate_banner_style(value: &Value) -> Result<Option<Value>, String> {
    if value.is_null() {
        return Ok(None);
    }
    let obj = value.as_object().ok_or("banner_style must be an object")?;
    let ty = obj
        .get("type")
        .and_then(Value::as_str)
        .ok_or("banner_style.type must be \"preset\"")?;
    if ty != "preset" {
        return Err("banner_style.type must be \"preset\"".into());
    }
    let id = obj
        .get("id")
        .and_then(Value::as_str)
        .ok_or_else(|| format!("banner_style.id is not allowed"))?;
    if !ALLOWED_BANNER_IDS.contains(&id) {
        return Err(format!("banner_style.id \"{}\" is not allowed", id));
    }
    Ok(Some(json!({"type": "preset", "id": id})))
}

fn validate_social_links(value: &Value) -> Result<Vec<Map<String, Value>>, String> {
    if value.is_null() {
        return Ok(Vec::new());
    }
    let arr = value.as_array().ok_or("social_links must be an array")?;
    if arr.len() > MAX_SOCIAL_LINKS {
        return Err(format!(
            "social_links exceeds maximum ({})",
            MAX_SOCIAL_LINKS
        ));
    }
    let mut result = Vec::new();
    for item in arr {
        let obj = item.as_object();
        let Some(obj) = obj else { continue };
        let platform = obj
            .get("platform")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_ascii_lowercase()
            .trim()
            .to_string();
        let url = obj
            .get("url")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim()
            .to_string();
        if !ALLOWED_SOCIAL_PLATFORMS.contains(&platform.as_str()) {
            return Err(format!("social_links: unknown platform \"{}\"", platform));
        }
        if url.is_empty() || url.len() > MAX_URL_LENGTH {
            return Err(format!("social_links: invalid url for \"{}\"", platform));
        }
        if !url.starts_with("http://") && !url.starts_with("https://") {
            return Err("social_links: url must start with http:// or https://".into());
        }
        let mut m = Map::new();
        m.insert("platform".into(), json!(platform));
        m.insert("url".into(), json!(url));
        result.push(m);
    }
    Ok(result)
}

// ========================================================================
//  Helpers
// ========================================================================

fn pool_busy(err: sqlx::Error) -> ApiError {
    match &err {
        sqlx::Error::PoolTimedOut | sqlx::Error::PoolClosed => ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "Сервер занят, попробуйте чуть позже",
        ),
        _ => err.into(),
    }
}

fn too_many_redeems() -> ApiError {
    ApiError::new(
        StatusCode::TOO_MANY_REQUESTS,
        "Слишком много попыток. Попробуйте позже.",
    )
}

fn is_avatar_extension(ext: &str) -> bool {
    matches!(ext, ".jpg" | ".jpeg" | ".png" | ".webp")
}

fn avatar_standing_hint() -> String {
    "Аватар доступен, когда в сообществе есть история: 5 подписчиков, ".to_string()
        + "опубликованный квест, 3 отзыва, стрик 5 дней или 3 часа в играх."
}

// ========================================================================
//  Routes: sync settings
// ========================================================================

fn parse_profile_id(raw: &str) -> Result<Uuid, ApiError> {
    Uuid::parse_str(raw).map_err(|_| ApiError::bad_request("Invalid ID format"))
}

async fn get_sync_settings(State(state): State<Arc<AppState>>, auth: AuthUser) -> ApiResult {
    let row = sqlx::query(
        "SELECT github_enabled, github_owner, github_repo, github_branch, github_root_path, \
         github_token_ciphertext, github_token_iv, github_token_tag \
         FROM profile_sync_settings WHERE user_id = $1",
    )
    .bind(auth.id)
    .fetch_optional(&state.db)
    .await?;

    let response = if let Some(row) = row {
        use sqlx::Row;
        let enabled: bool = row.try_get("github_enabled")?;
        let owner: Option<String> = row.try_get("github_owner")?;
        let repo: Option<String> = row.try_get("github_repo")?;
        let branch: Option<String> = row.try_get("github_branch")?;
        let root_path: Option<String> = row.try_get("github_root_path")?;
        let ciphertext: Option<String> = row.try_get("github_token_ciphertext")?;
        let iv: Option<String> = row.try_get("github_token_iv")?;
        let tag: Option<String> = row.try_get("github_token_tag")?;

        let token = decrypt_token(ciphertext.as_deref(), iv.as_deref(), tag.as_deref())?;

        json!({
            "github": {
                "enabled": enabled,
                "token": token,
                "owner": owner.unwrap_or_default(),
                "repo": repo.unwrap_or_default(),
                "branch": branch.unwrap_or_else(|| "main".into()),
                "rootPath": root_path.unwrap_or_else(|| "meander-sync".into()),
            }
        })
    } else {
        json!({
            "github": {
                "enabled": false,
                "token": "",
                "owner": "",
                "repo": "",
                "branch": "main",
                "rootPath": "meander-sync",
            }
        })
    };

    ok_json(response)
}

async fn post_sync_settings(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Body(body): Body,
) -> ApiResult {
    let github = body.get("github").cloned().unwrap_or_else(|| json!({}));
    let github = github
        .as_object()
        .ok_or_else(|| ApiError::bad_request("github must be an object"))?;

    let enabled = github
        .get("enabled")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let owner = github
        .get("owner")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim();
    let repo = github
        .get("repo")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim();
    let branch = github
        .get("branch")
        .and_then(Value::as_str)
        .unwrap_or("main")
        .trim();
    let branch = if branch.is_empty() { "main" } else { branch };
    let root_path = github
        .get("rootPath")
        .and_then(Value::as_str)
        .unwrap_or("meander-sync")
        .trim();
    let root_path = if root_path.is_empty() {
        "meander-sync"
    } else {
        root_path
    };
    let token_raw = github
        .get("token")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();

    if owner.len() > 100 || repo.len() > 150 || branch.len() > 100 || root_path.len() > 200 {
        return Err(ApiError::bad_request("Sync settings fields are too long"));
    }

    if enabled && (owner.is_empty() || repo.is_empty() || branch.is_empty()) {
        return Err(ApiError::bad_request(
            "Owner/repo/branch are required when sync is enabled",
        ));
    }

    let encrypted = if token_raw.trim().is_empty() {
        json!({"ciphertext": "", "iv": "", "tag": ""})
    } else {
        let enc = encrypt_token(&token_raw)?;
        json!({"ciphertext": enc.ciphertext, "iv": enc.iv, "tag": enc.tag})
    };

    let row = sqlx::query(
        "INSERT INTO profile_sync_settings ( \
            user_id, github_enabled, github_owner, github_repo, github_branch, github_root_path, \
            github_token_ciphertext, github_token_iv, github_token_tag, updated_at \
        ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,NOW()) \
        ON CONFLICT (user_id) DO UPDATE SET \
            github_enabled = EXCLUDED.github_enabled, \
            github_owner = EXCLUDED.github_owner, \
            github_repo = EXCLUDED.github_repo, \
            github_branch = EXCLUDED.github_branch, \
            github_root_path = EXCLUDED.github_root_path, \
            github_token_ciphertext = EXCLUDED.github_token_ciphertext, \
            github_token_iv = EXCLUDED.github_token_iv, \
            github_token_tag = EXCLUDED.github_token_tag, \
            updated_at = NOW() \
        RETURNING github_enabled, github_owner, github_repo, github_branch, github_root_path",
    )
    .bind(auth.id)
    .bind(enabled)
    .bind(if owner.is_empty() { None } else { Some(owner) })
    .bind(if repo.is_empty() { None } else { Some(repo) })
    .bind(branch)
    .bind(root_path)
    .bind(encrypted.get("ciphertext").and_then(Value::as_str))
    .bind(encrypted.get("iv").and_then(Value::as_str))
    .bind(encrypted.get("tag").and_then(Value::as_str))
    .fetch_one(&state.db)
    .await?;

    use sqlx::Row;
    ok_json(json!({
        "success": true,
        "github": {
            "enabled": row.try_get::<bool, _>("github_enabled")?,
            "owner": row.try_get::<Option<String>, _>("github_owner")?.unwrap_or_default(),
            "repo": row.try_get::<Option<String>, _>("github_repo")?.unwrap_or_default(),
            "branch": row.try_get::<Option<String>, _>("github_branch")?.unwrap_or_else(|| "main".into()),
            "rootPath": row.try_get::<Option<String>, _>("github_root_path")?.unwrap_or_else(|| "meander-sync".into()),
        }
    }))
}

// ========================================================================
//  Routes: author notification settings
// ========================================================================

async fn get_author_notifs_settings(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
) -> ApiResult {
    let row = sqlx::query(
        "SELECT author_notifs_mode, author_notifs_exceptions FROM profiles WHERE id = $1",
    )
    .bind(auth.id)
    .fetch_optional(&state.db)
    .await?;

    let Some(row) = row else {
        return Err(ApiError::not_found("Profile not found"));
    };

    use sqlx::Row;
    let mode: Option<String> = row.try_get("author_notifs_mode")?;
    let exceptions: Option<Vec<Uuid>> = row.try_get("author_notifs_exceptions")?;
    ok_json(json!({
        "mode": mode.unwrap_or_else(|| "all".into()),
        "exceptions": exceptions.unwrap_or_default(),
    }))
}

async fn post_author_notifs_settings(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Body(body): Body,
) -> ApiResult {
    let mode = body.get("mode").and_then(Value::as_str).unwrap_or("");
    let Some(exceptions_val) = body.get("exceptions") else {
        return Err(ApiError::bad_request("Exceptions must be an array"));
    };
    if !exceptions_val.is_array() {
        return Err(ApiError::bad_request("Exceptions must be an array"));
    }
    let exceptions = exceptions_val.as_array().unwrap();

    if mode != "all" && mode != "none" {
        return Err(ApiError::bad_request("Invalid mode"));
    }

    let valid_exceptions: Vec<Uuid> = exceptions
        .iter()
        .filter_map(|v| v.as_str().and_then(|s| Uuid::parse_str(s).ok()))
        .collect();

    sqlx::query(
        "UPDATE profiles SET author_notifs_mode = $1, author_notifs_exceptions = $2 WHERE id = $3",
    )
    .bind(mode)
    .bind(&valid_exceptions)
    .bind(auth.id)
    .execute(&state.db)
    .await?;

    ok_json(json!({
        "success": true,
        "mode": mode,
        "exceptions": valid_exceptions,
    }))
}

// ========================================================================
//  Routes: cosmetics
// ========================================================================

async fn get_cosmetics_mine(State(state): State<Arc<AppState>>, auth: AuthUser) -> ApiResult {
    let (equipped, granted) = tokio::try_join!(
        async { Ok::<_, ApiError>(equipped_for(&state, auth.id).await) },
        async { Ok::<_, ApiError>(list_grants(&state, auth.id).await) },
    )?;

    let equipped = Value::Object(equipped);
    ok_json(json!({"equipped": equipped, "granted": granted}))
}

// ========================================================================
//  Routes: profile by id
// ========================================================================

async fn get_profile(
    State(state): State<Arc<AppState>>,
    auth: OptionalAuth,
    Path(id): Path<String>,
) -> ApiResult {
    let id = parse_profile_id(&id)?;
    let row = sqlx::query(
        "SELECT \
            p.id, p.full_name, p.avatar_url, p.created_at, p.bio, \
            p.is_verified, p.role, p.ad_free_until, \
            p.streak_count, p.last_activity_date, p.last_seen_at, \
            p.banner_style, p.social_links, p.show_nsfw, p.cosmetics, \
            p.quiet_hours_enabled, p.timezone_offset, \
            p.total_playtime_seconds, \
            (SELECT COUNT(*)::int FROM user_followers WHERE user_id = p.id) as followers_count, \
            (SELECT COUNT(*)::int FROM user_followers WHERE follower_id = p.id) as following_count, \
            (SELECT COALESCE(SUM(like_count), 0)::int FROM quests WHERE author_id = p.id) as total_likes, \
            (SELECT COALESCE(SUM(downloads_count), 0)::int FROM quests WHERE author_id = p.id) as total_downloads, \
            (SELECT COALESCE(SUM(playtime_seconds), 0)::int FROM user_quest_playtime WHERE user_id = p.id) as total_quests_playtime_seconds \
        FROM profiles p WHERE p.id = $1;",
    )
    .bind(id)
    .fetch_optional(&state.db)
    .await?;

    let Some(row) = row else {
        return Err(ApiError::not_found("Profile not found"));
    };

    let mut value = crate::json::pg_row_to_json(&row);

    let is_owner_or_staff = auth.id() == Some(id) || is_staff(&state, auth.id()).await;
    if !is_owner_or_staff {
        if let Value::Object(ref mut map) = value {
            for key in [
                "role",
                "last_seen_at",
                "timezone_offset",
                "quiet_hours_enabled",
                "show_nsfw",
                "ad_free_until",
                "total_playtime_seconds",
                "total_quests_playtime_seconds",
            ] {
                map.remove(key);
            }
        }
    }

    ok_json(value)
}

// ========================================================================
//  Routes: update streak
// ========================================================================

async fn update_streak(State(state): State<Arc<AppState>>, auth: AuthUser) -> ApiResult {
    let mut tx = state.db.begin().await.map_err(pool_busy)?;

    let row = sqlx::query(
        "SELECT streak_count, last_activity_date FROM profiles WHERE id = $1 FOR UPDATE",
    )
    .bind(auth.id)
    .fetch_optional(&mut *tx)
    .await?;

    let Some(row) = row else {
        tx.rollback().await.ok();
        return Err(ApiError::not_found("User not found"));
    };

    use sqlx::Row;
    let streak_count: Option<i32> = row.try_get("streak_count")?;
    let last_activity_date: Option<chrono::NaiveDate> = row.try_get("last_activity_date")?;

    let now = Utc::now();
    let today = now.date_naive();

    let new_streak: i32;
    let updated: bool;

    if let Some(last) = last_activity_date {
        if last == today {
            new_streak = streak_count.unwrap_or(0);
            updated = false;
        } else if last == today.pred_opt().unwrap_or(last) {
            new_streak = streak_count.unwrap_or(0) + 1;
            updated = true;
        } else {
            new_streak = 1;
            updated = true;
        }
    } else {
        new_streak = 1;
        updated = true;
    }

    if updated {
        sqlx::query("UPDATE profiles SET streak_count = $1, last_activity_date = $2 WHERE id = $3")
            .bind(new_streak)
            .bind(today)
            .bind(auth.id)
            .execute(&mut *tx)
            .await?;
    }

    tx.commit().await.map_err(pool_busy)?;

    ok_json(json!({
        "success": true,
        "streak_updated": updated,
        "current_streak": new_streak,
    }))
}

// ========================================================================
//  Route: update my profile
// ========================================================================

/// Node has no `GET /profiles/me`; Express falls through to `/:id`, which
/// rejects the literal `me` with the same validation error.
async fn me_as_id() -> ApiResult {
    Err(ApiError::bad_request("Invalid ID format"))
}

async fn update_profile(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Body(body): Body,
) -> ApiResult {
    let mut fragments: Vec<String> = Vec::new();
    // Keep a separate counter for SQL parameters; values are bound in order.
    let mut idx: usize = 1;

    // full_name
    let full_name = body.get("full_name").cloned();
    if full_name.is_some() {
        fragments.push(format!("full_name = ${}", idx));
        idx += 1;
    }

    // bio
    let bio = body.get("bio").cloned();
    if bio.is_some() {
        fragments.push(format!("bio = ${}", idx));
        idx += 1;
    }

    // banner_style
    let banner_style = if body.get("banner_style").is_some() {
        let value = body.get("banner_style").unwrap();
        match validate_banner_style(value) {
            Ok(opt) => {
                fragments.push(format!("banner_style = ${}::jsonb", idx));
                idx += 1;
                Some(opt)
            }
            Err(msg) => return Err(ApiError::bad_request(msg)),
        }
    } else {
        None
    };

    // social_links
    let social_links = if body.get("social_links").is_some() {
        let value = body.get("social_links").unwrap();
        match validate_social_links(value) {
            Ok(list) => {
                fragments.push(format!("social_links = ${}::jsonb", idx));
                idx += 1;
                Some(list)
            }
            Err(msg) => return Err(ApiError::bad_request(msg)),
        }
    } else {
        None
    };

    // cosmetics
    let mut legacy_banner: Option<Value> = None;
    let cosmetics = if body.get("cosmetics").is_some() {
        let value = body.get("cosmetics").unwrap();
        match validate_equipped(value) {
            Ok(equipped) => {
                let ids: Vec<String> = equipped
                    .values()
                    .filter_map(|v| match v {
                        Value::String(s) => Some(s.clone()),
                        _ => None,
                    })
                    .filter(|s| !s.is_empty())
                    .collect();
                let missing = find_missing_grants(&state, auth.id, &ids).await;
                if !missing.is_empty() {
                    return Err(ApiError::forbidden(format!(
                        "Нет права на оформление: {}",
                        missing.join(", ")
                    )));
                }
                if let Some(legacy) = legacy_banner_style(&equipped) {
                    legacy_banner = Some(legacy);
                    fragments.push(format!("banner_style = ${}::jsonb", idx + 1));
                }
                fragments.push(format!("cosmetics = ${}::jsonb", idx));
                idx += if legacy_banner.is_some() { 2 } else { 1 };
                Some(Value::Object(equipped))
            }
            Err(msg) => return Err(ApiError::bad_request(msg)),
        }
    } else {
        None
    };

    // show_nsfw
    let show_nsfw = if body.get("show_nsfw").is_some() {
        let b = json_bool(body.get("show_nsfw"));
        fragments.push(format!("show_nsfw = ${}", idx));
        idx += 1;
        Some(b)
    } else {
        None
    };

    // quiet_hours_enabled
    let quiet_hours_enabled = if body.get("quiet_hours_enabled").is_some() {
        let b = json_bool(body.get("quiet_hours_enabled"));
        fragments.push(format!("quiet_hours_enabled = ${}", idx));
        idx += 1;
        Some(b)
    } else {
        None
    };

    // timezone_offset
    let timezone_offset = if body.get("timezone_offset").is_some() {
        let n = json_i64(body.get("timezone_offset")).unwrap_or(0);
        fragments.push(format!("timezone_offset = ${}", idx));
        idx += 1;
        Some(n)
    } else {
        None
    };

    if fragments.is_empty() {
        return Err(ApiError::bad_request("No fields to update"));
    }

    let sql = format!(
        "UPDATE profiles SET {} WHERE id = ${} RETURNING *",
        fragments.join(", "),
        idx
    );

    let mut q = sqlx::query(&sql);
    if let Some(v) = full_name {
        q = q.bind(v);
    }
    if let Some(v) = bio {
        q = q.bind(v);
    }
    if let Some(v) = banner_style {
        q = q.bind(v);
    }
    if let Some(v) = social_links {
        q = q.bind(Value::Array(v.into_iter().map(Value::Object).collect()));
    }
    // Order: cosmetics then legacy banner, because that's how fragments were generated.
    if let Some(cos) = cosmetics {
        q = q.bind(cos);
    }
    if let Some(legacy) = legacy_banner {
        q = q.bind(legacy);
    }
    if let Some(b) = show_nsfw {
        q = q.bind(b);
    }
    if let Some(b) = quiet_hours_enabled {
        q = q.bind(b);
    }
    if let Some(n) = timezone_offset {
        q = q.bind(n);
    }
    q = q.bind(auth.id);

    let row = q.fetch_one(&state.db).await?;
    ok_json(crate::json::pg_row_to_json(&row))
}

// ========================================================================
//  Routes: avatar upload
// ========================================================================

const AVATAR_MAX_BYTES: usize = 2 * 1024 * 1024;
const AVATAR_MIN_ACCOUNT_AGE_DAYS: f64 = 7.0;
const AVATAR_CHANGES_PER_DAY: i64 = 3;
const AVATAR_STANDING_FOLLOWERS: i64 = 5;
const AVATAR_STANDING_PUBLISHED: i64 = 1;
const AVATAR_STANDING_REVIEWS: i64 = 3;
const AVATAR_STREAK_DAYS: i32 = 5;
const AVATAR_STANDING_SECONDS: i64 = 3 * 3600;

async fn has_avatar_standing(state: &AppState, user_id: Uuid) -> Result<bool, ApiError> {
    let row = sqlx::query(
        "SELECT \
            (SELECT COUNT(*)::int FROM user_followers WHERE user_id = p.id) AS followers, \
            (SELECT COUNT(*)::int FROM quests WHERE author_id = p.id AND status = 'published') AS published, \
            (SELECT COUNT(*)::int FROM reviews WHERE author_id = p.id) AS reviews, \
            p.streak_count, \
            p.total_playtime_seconds \
        FROM profiles p WHERE p.id = $1",
    )
    .bind(user_id)
    .fetch_optional(&state.db)
    .await?;

    let Some(row) = row else { return Ok(false) };
    use sqlx::Row;
    let followers: i64 = row.try_get("followers")?;
    let published: i64 = row.try_get("published")?;
    let reviews: i64 = row.try_get("reviews")?;
    let streak: Option<i32> = row.try_get("streak_count")?;
    let playtime: Option<i64> = row.try_get("total_playtime_seconds")?;

    Ok(followers >= AVATAR_STANDING_FOLLOWERS
        || published >= AVATAR_STANDING_PUBLISHED
        || reviews >= AVATAR_STANDING_REVIEWS
        || streak.unwrap_or(0) >= AVATAR_STREAK_DAYS
        || playtime.unwrap_or(0) >= AVATAR_STANDING_SECONDS)
}

async fn log_avatar_change(
    state: &AppState,
    user_id: Uuid,
    avatar_url: &str,
    verdict: &str,
    reason: &str,
) {
    let _ = sqlx::query(
        "INSERT INTO avatar_changes (user_id, avatar_url, verdict, reason) VALUES ($1, $2, $3, $4)",
    )
    .bind(user_id)
    .bind(avatar_url)
    .bind(verdict)
    .bind(reason)
    .execute(&state.db)
    .await;
}

async fn upload_avatar(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    request: axum::extract::Request,
) -> ApiResult {
    let form = match crate::extractors::upload_form(request, &state, AVATAR_MAX_BYTES).await {
        Ok(form) => form,
        Err(crate::extractors::UploadFormError::TooLarge) => {
            return Err(ApiError::bad_request(
                "Картинка больше 2 МБ — выберите меньшую",
            ));
        }
        Err(crate::extractors::UploadFormError::BadJson) => {
            return Err(ApiError::bad_request("Bad JSON format"));
        }
        Err(crate::extractors::UploadFormError::Multipart(message)) => {
            return Err(ApiError::bad_request(message));
        }
    };

    if form.files.iter().any(|f| f.field != "file") {
        // `uploadAvatarFile` turns multer's LIMIT_UNEXPECTED_FILE into 400.
        return Err(ApiError::bad_request("Too many files"));
    }
    let Some(file) = form.file("file") else {
        return Err(ApiError::bad_request("Прикрепите файл картинки"));
    };

    let ext = extension_of(&file.file_name);
    if !is_avatar_extension(&ext) || !accepts_image_part_mime(file.content_type.as_deref()) {
        return Err(ApiError::bad_request("Можно загрузить jpg, png или webp"));
    }

    let me = sqlx::query(
        "SELECT created_at, role, is_blocked, is_verified, \
            google_id, yandex_id, telegram_id, apple_id \
        FROM profiles WHERE id = $1",
    )
    .bind(auth.id)
    .fetch_optional(&state.db)
    .await?;

    let Some(me) = me else {
        return Err(ApiError::not_found("Профиль не найден"));
    };

    use sqlx::Row;
    let created_at: DateTime<Utc> = me.try_get("created_at")?;
    let role: Option<String> = me.try_get("role")?;
    let is_blocked: bool = me.try_get("is_blocked")?;
    let is_verified: bool = me.try_get("is_verified")?;
    let google_id: Option<String> = me.try_get("google_id")?;
    let yandex_id: Option<String> = me.try_get("yandex_id")?;
    let telegram_id: Option<String> = me.try_get("telegram_id")?;
    let apple_id: Option<String> = me.try_get("apple_id")?;

    if is_blocked {
        return Err(ApiError::forbidden(
            "Профиль заблокирован — аватар недоступен",
        ));
    }

    let is_staff = matches!(role.as_deref(), Some("admin") | Some("moderator"));

    if !is_staff {
        let age_days = (Utc::now() - created_at).num_milliseconds() as f64 / 86_400_000.0;
        if age_days < AVATAR_MIN_ACCOUNT_AGE_DAYS {
            return Err(ApiError::forbidden(format!(
                "Свой аватар можно ставить через {} дней после регистрации",
                AVATAR_MIN_ACCOUNT_AGE_DAYS as i64
            )));
        }

        let linked = google_id.is_some()
            || yandex_id.is_some()
            || telegram_id.is_some()
            || apple_id.is_some();
        if !linked && !is_verified {
            return Err(ApiError::forbidden(
                "Аватар доступен аккаунтам со входом через Google, Яндекс, Telegram или Apple",
            ));
        }

        let recent: i64 = sqlx::query_scalar(
            "SELECT count(*)::int FROM avatar_changes \
             WHERE user_id = $1 AND verdict = 'approved' AND created_at > NOW() - INTERVAL '24 hours'",
        )
        .bind(auth.id)
        .fetch_one(&state.db)
        .await?;

        if recent >= AVATAR_CHANGES_PER_DAY {
            return Err(ApiError::new(
                StatusCode::TOO_MANY_REQUESTS,
                format!(
                    "Менять аватар можно не чаще {} раз в сутки",
                    AVATAR_CHANGES_PER_DAY
                ),
            ));
        }

        if !has_avatar_standing(&state, auth.id).await? {
            return Err(ApiError::forbidden(avatar_standing_hint()));
        }
    }

    let bytes = tokio::fs::read(&file.path).await?;
    let url = match save_uploaded_image(
        &state.cfg.public_dir.join("uploads"),
        &bytes,
        &file.file_name,
        &state.cfg.base_url,
    ) {
        Ok(url) => url,
        Err(ImageError::Unsupported(_)) => {
            return Err(ApiError::new(
                StatusCode::UNSUPPORTED_MEDIA_TYPE,
                "Это не похоже на картинку — поддерживаются jpg, png и webp",
            ));
        }
        Err(ImageError::Save(msg)) => return Err(ApiError::internal(msg)),
    };

    sqlx::query("UPDATE profiles SET avatar_url = $1, avatar_custom = TRUE WHERE id = $2")
        .bind(&url)
        .bind(auth.id)
        .execute(&state.db)
        .await?;

    log_avatar_change(&state, auth.id, &url, "approved", "Проверка ИИ отключена").await;
    award_achievement(&state, auth.id, "profile_pic").await;

    ok_json(json!({"success": true, "avatar_url": url}))
}

// ========================================================================
//  Routes: rewards
// ========================================================================

async fn get_my_rewards(State(state): State<Arc<AppState>>, auth: AuthUser) -> ApiResult {
    let granted_now = grant_due_rewards(&state, auth.id).await;
    let progress = reward_progress(&state, auth.id).await;

    let rules: Vec<Value> = progress
        .as_array()
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .map(|item| {
            let rule = item.get("rule").cloned().unwrap_or(json!({}));
            json!({
                "id": rule.get("id"),
                "metric": rule.get("metric"),
                "threshold": rule.get("threshold"),
                "title": rule.get("title"),
                "hint": rule.get("hint"),
                "cosmetics": rule.get("cosmetics"),
                "current": item.get("current"),
                "done": item.get("done"),
                "granted_at": item.get("granted_at"),
            })
        })
        .collect();

    ok_json(json!({"granted_now": granted_now, "rules": rules}))
}

// ========================================================================
//  Routes: promo redeem
// ========================================================================

async fn redeem_promo(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Body(body): Body,
) -> ApiResult {
    let code = body
        .get("code")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim();
    if code.is_empty() {
        return Err(ApiError::bad_request("Code is required"));
    }

    // Rate-limit key follows the Node redeemer: by authenticated user.
    let decision = state.limiter.hit(
        format!("redeem_{}", auth.id),
        10,
        std::time::Duration::from_secs(15 * 60),
    );
    if !decision.allowed {
        return Err(too_many_redeems());
    }

    let mut tx = state.db.begin().await.map_err(pool_busy)?;

    let promo =
        sqlx::query("SELECT * FROM promo_codes WHERE code = $1 AND is_active = TRUE FOR UPDATE")
            .bind(code)
            .fetch_optional(&mut *tx)
            .await?;

    let Some(promo) = promo else {
        tx.rollback().await.ok();
        return Err(ApiError::bad_request("Неверный или недоступный код"));
    };

    use sqlx::Row;
    let current_uses: i32 = promo.try_get("current_uses")?;
    let max_uses: i32 = promo.try_get("max_uses")?;
    if current_uses >= max_uses {
        tx.rollback().await.ok();
        return Err(ApiError::bad_request("Неверный или недоступный код"));
    }

    let already_used: bool =
        sqlx::query("SELECT 1 FROM promo_code_usages WHERE user_id = $1 AND code = $2")
            .bind(auth.id)
            .bind(code)
            .fetch_optional(&mut *tx)
            .await?
            .is_some();

    if already_used {
        tx.rollback().await.ok();
        return Err(ApiError::bad_request("Неверный или недоступный код"));
    }

    sqlx::query("UPDATE promo_codes SET current_uses = current_uses + 1 WHERE code = $1")
        .bind(code)
        .execute(&mut *tx)
        .await?;

    sqlx::query("INSERT INTO promo_code_usages (user_id, code) VALUES ($1, $2)")
        .bind(auth.id)
        .bind(code)
        .execute(&mut *tx)
        .await?;

    let days_duration: i32 = promo.try_get("days_duration")?;
    let updated = sqlx::query(
        "UPDATE profiles SET ad_free_until = ( \
            CASE WHEN ad_free_until > NOW() THEN ad_free_until + ($1 || ' days')::INTERVAL \
            ELSE NOW() + ($1 || ' days')::INTERVAL END \
        ) WHERE id = $2 RETURNING *",
    )
    .bind(days_duration)
    .bind(auth.id)
    .fetch_one(&mut *tx)
    .await?;

    let cosmetic_ids: Vec<String> = promo.try_get("cosmetic_ids").unwrap_or_default();
    let mut granted_cosmetics: Vec<String> = Vec::new();
    for id in cosmetic_ids {
        let slot = cosmetic_slot(&id);
        let tier = cosmetic_tier(&id);
        let Some(slot) = slot else { continue };
        let tier = tier.unwrap_or("common");

        sqlx::query(
            "INSERT INTO user_cosmetics (user_id, cosmetic_id, slot, tier, source, reason, expires_at) \
             VALUES ($1, $2, $3, $4, 'promo', $5, NULL) \
             ON CONFLICT (user_id, cosmetic_id) DO UPDATE SET \
                 source = 'promo', reason = EXCLUDED.reason, expires_at = NULL",
        )
        .bind(auth.id)
        .bind(&id)
        .bind(slot)
        .bind(tier)
        .bind(&code)
        .execute(&mut *tx)
        .await?;

        granted_cosmetics.push(id);
    }

    tx.commit().await.map_err(pool_busy)?;

    let mut parts: Vec<String> = Vec::new();
    if days_duration > 0 {
        parts.push(format!("Премиум активирован на {} дней", days_duration));
    }
    if !granted_cosmetics.is_empty() {
        parts.push(format!(
            "Выдано оформление: {}",
            granted_cosmetics.join(", ")
        ));
    }

    let message = if parts.is_empty() {
        "Код активирован".to_string()
    } else {
        parts.join(". ")
    };
    ok_json(json!({
        "success": true,
        "message": message,
        "cosmetics": granted_cosmetics,
        "user": crate::json::pg_row_to_json(&updated),
    }))
}

// ========================================================================
//  Routes: follow
// ========================================================================

async fn toggle_follow(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(target_user_id): Path<String>,
) -> ApiResult {
    let target_user_id = parse_profile_id(&target_user_id)?;
    if target_user_id == auth.id {
        return Err(ApiError::bad_request("Cannot follow yourself"));
    }

    let outcome: ApiResult = async {
        let existing =
            sqlx::query("SELECT 1 FROM user_followers WHERE user_id = $1 AND follower_id = $2")
                .bind(target_user_id)
                .bind(auth.id)
                .fetch_optional(&state.db)
                .await?;

        let is_following: bool;
        if existing.is_some() {
            sqlx::query("DELETE FROM user_followers WHERE user_id = $1 AND follower_id = $2")
                .bind(target_user_id)
                .bind(auth.id)
                .execute(&state.db)
                .await?;
            is_following = false;
        } else {
            sqlx::query("INSERT INTO user_followers (user_id, follower_id) VALUES ($1, $2)")
                .bind(target_user_id)
                .bind(auth.id)
                .execute(&state.db)
                .await?;
            is_following = true;

            create_notification(
                &state,
                NewNotification {
                    user_id: target_user_id,
                    actor_id: Some(auth.id),
                    kind: "user_follow",
                    quest_id: None,
                    review_id: None,
                    payload: None,
                },
            )
            .await;

            let follow_count: i64 =
                sqlx::query_scalar("SELECT COUNT(*) FROM user_followers WHERE follower_id = $1")
                    .bind(auth.id)
                    .fetch_one(&state.db)
                    .await?;

            if follow_count >= 5 {
                award_achievement(&state, auth.id, "social_butterfly").await;
            }
        }

        ok_json(json!({"success": true, "isFollowing": is_following}))
    }
    .await;

    outcome.map_err(|err| {
        tracing::error!(error = %err, "follow toggle failed");
        ApiError::internal("Server error toggling follow")
    })
}

// ========================================================================
//  Routes: user's quests / reviews
// ========================================================================

async fn get_user_quests(
    State(state): State<Arc<AppState>>,
    auth: OptionalAuth,
    Path(id): Path<String>,
) -> ApiResult {
    let id = parse_profile_id(&id)?;
    let mut query = String::from(
        "SELECT q.*, p.full_name AS author_name, p.is_verified AS author_is_verified, \
            p.cosmetics->>'name_style' as author_name_style, p.cosmetics AS author_cosmetics, \
            (SELECT AVG(r.rating)::text FROM ratings r WHERE r.quest_id = q.id) AS average_rating \
        FROM quests q \
        LEFT JOIN profiles p ON q.author_id = p.id \
        WHERE q.author_id = $1",
    );
    if auth.id() != Some(id) {
        query.push_str(" AND q.status = 'published'");
    }
    query.push_str(" ORDER BY q.created_at DESC");

    let rows = sqlx::query(&query).bind(id).fetch_all(&state.db).await?;
    ok_json(rows_to_json(&rows))
}

async fn get_user_reviews(State(state): State<Arc<AppState>>, Path(id): Path<String>) -> ApiResult {
    let id = parse_profile_id(&id)?;
    let rows = sqlx::query(
        "SELECT r.*, q.title as quest_title, p.full_name as author_name, \
            p.avatar_url as author_avatar_url, \
            p.cosmetics->>'name_style' as author_name_style, p.cosmetics AS author_cosmetics \
        FROM reviews r \
        JOIN quests q ON r.quest_id = q.id \
        JOIN profiles p ON r.author_id = p.id \
        WHERE r.author_id = $1 AND r.status = 'approved' \
        ORDER BY r.created_at DESC",
    )
    .bind(id)
    .fetch_all(&state.db)
    .await?;

    ok_json(rows_to_json(&rows))
}

async fn is_following(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(profile_user_id): Path<String>,
) -> ApiResult {
    let profile_user_id = parse_profile_id(&profile_user_id)?;
    let exists =
        sqlx::query("SELECT 1 FROM user_followers WHERE user_id = $1 AND follower_id = $2")
            .bind(profile_user_id)
            .bind(auth.id)
            .fetch_optional(&state.db)
            .await?;

    ok_json(json!({"isFollowing": exists.is_some()}))
}

// ========================================================================
//  Routes: play history
// ========================================================================

const PLAY_HISTORY_WINDOW_DAYS: i32 = 91;

async fn build_play_history(state: &AppState, user_id: Uuid) -> Result<Value, ApiError> {
    let items = sqlx::query(
        "SELECT uqp.quest_id, uqp.playtime_seconds AS seconds, uqp.last_played_at, \
            q.title, q.preview_image_url, q.status, q.author_id, \
            p.full_name AS author_name, \
            p.cosmetics ->> 'name_style' AS author_name_style, p.cosmetics AS author_cosmetics, \
            COALESCE(d.days, 0)::int AS days \
        FROM user_quest_playtime uqp \
        JOIN quests q ON q.id = uqp.quest_id \
        LEFT JOIN profiles p ON p.id = q.author_id \
        LEFT JOIN ( \
            SELECT quest_id, count(*) AS days FROM playtime_daily \
            WHERE user_id = $1 GROUP BY quest_id \
        ) d ON d.quest_id = uqp.quest_id \
        WHERE uqp.user_id = $1 \
        ORDER BY uqp.last_played_at DESC \
        LIMIT 500",
    )
    .bind(user_id)
    .fetch_all(&state.db)
    .await?;

    let totals = sqlx::query(
        "SELECT COALESCE(sum(playtime_seconds), 0)::bigint AS total_seconds, count(*)::int AS quests_played \
        FROM user_quest_playtime WHERE user_id = $1",
    )
    .bind(user_id)
    .fetch_one(&state.db)
    .await?;

    let days = sqlx::query(
        "SELECT count(DISTINCT day)::int AS active_days FROM playtime_daily WHERE user_id = $1",
    )
    .bind(user_id)
    .fetch_one(&state.db)
    .await?;

    let activity_rows = sqlx::query(
        "SELECT day::text AS day, sum(seconds)::bigint AS seconds \
        FROM playtime_daily \
        WHERE user_id = $1 AND day >= CURRENT_DATE - ($2::int - 1) \
        GROUP BY day ORDER BY day",
    )
    .bind(user_id)
    .bind(PLAY_HISTORY_WINDOW_DAYS)
    .fetch_all(&state.db)
    .await?;

    use sqlx::Row;
    let total_seconds: i64 = totals.try_get("total_seconds")?;
    let quests_played: i32 = totals.try_get("quests_played")?;
    let active_days: i32 = days.try_get("active_days")?;

    let items_json: Vec<Value> = items
        .iter()
        .map(|r| crate::json::pg_row_to_json(r))
        .collect();

    let activity: Vec<Value> = activity_rows
        .iter()
        .map(|r| {
            let day: String = r.try_get("day").unwrap_or_default();
            let seconds: i64 = r.try_get("seconds").unwrap_or(0);
            json!({"day": day, "seconds": seconds})
        })
        .collect();

    Ok(json!({
        "items": items_json,
        "activity": activity,
        "summary": {
            "total_seconds": total_seconds,
            "quests_played": quests_played,
            "active_days": active_days,
            "window_days": PLAY_HISTORY_WINDOW_DAYS,
        }
    }))
}

async fn get_my_playhistory(State(state): State<Arc<AppState>>, auth: AuthUser) -> ApiResult {
    ok_json(build_play_history(&state, auth.id).await?)
}

async fn get_user_playhistory(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> ApiResult {
    let id = parse_profile_id(&id)?;
    ok_json(build_play_history(&state, id).await?)
}

// ========================================================================
//  Routes: achievements
// ========================================================================

async fn get_user_achievements(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> ApiResult {
    let id = parse_profile_id(&id)?;
    let rows = sqlx::query(
        "SELECT ua.achieved_at, a.* FROM user_achievements ua \
        JOIN achievements a ON ua.achievement_id = a.id \
        WHERE ua.user_id = $1",
    )
    .bind(id)
    .fetch_all(&state.db)
    .await?;

    ok_json(rows_to_json(&rows))
}

// ========================================================================
//  Routes: FCM token
// ========================================================================

async fn post_fcm_token(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Body(body): Body,
) -> ApiResult {
    let token = body
        .get("token")
        .and_then(Value::as_str)
        .map(|s| s.trim())
        .filter(|s| !s.is_empty());

    sqlx::query("UPDATE profiles SET fcm_token = $1 WHERE id = $2")
        .bind(token)
        .bind(auth.id)
        .execute(&state.db)
        .await?;

    ok_json(json!({"success": true}))
}

// ========================================================================
//  Routes: playtime sync
// ========================================================================

async fn sync_playtime(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Body(body): Body,
) -> ApiResult {
    const MAX_ALLOWABLE_SYNC_SECONDS: i64 = 70 * 60;
    const SYNC_GRACE_SECONDS: i64 = 120;

    let mut tx = state.db.begin().await.map_err(pool_busy)?;

    let row = sqlx::query("SELECT playtime_last_sync_at FROM profiles WHERE id = $1 FOR UPDATE")
        .bind(auth.id)
        .fetch_optional(&mut *tx)
        .await?;

    use sqlx::Row;
    let last_sync_at: Option<DateTime<Utc>> =
        row.and_then(|r| r.try_get("playtime_last_sync_at").ok());

    let budget = if let Some(last) = last_sync_at {
        let elapsed = (Utc::now() - last).num_seconds();
        MAX_ALLOWABLE_SYNC_SECONDS.min((elapsed + SYNC_GRACE_SECONDS).max(0))
    } else {
        MAX_ALLOWABLE_SYNC_SECONDS
    };

    // total_app_time
    if let Some(total_app_time) = body.get("total_app_time").and_then(Value::as_f64) {
        let safe = (total_app_time as i64).min(budget).max(0);
        if safe > 0 {
            sqlx::query(
                "UPDATE profiles SET total_playtime_seconds = COALESCE(total_playtime_seconds, 0) + $1 WHERE id = $2",
            )
            .bind(safe)
            .bind(auth.id)
            .execute(&mut *tx)
            .await?;
        }
    }

    let mut quest_budget = budget;
    let today = Utc::now().format("%Y-%m-%d").to_string();

    if let Some(quest_times) = body.get("quest_times").and_then(Value::as_object) {
        let quest_ids: Vec<Uuid> = quest_times
            .keys()
            .filter_map(|k| Uuid::parse_str(k).ok())
            .collect();

        if !quest_ids.is_empty() {
            let existing: Vec<Uuid> =
                sqlx::query_scalar("SELECT id FROM quests WHERE id = ANY($1::uuid[])")
                    .bind(&quest_ids)
                    .fetch_all(&mut *tx)
                    .await?;
            let existing_set: HashSet<Uuid> = existing.into_iter().collect();

            for (quest_id, playtime_val) in quest_times {
                let Ok(quest_id) = Uuid::parse_str(quest_id) else {
                    continue;
                };
                if !existing_set.contains(&quest_id) {
                    continue;
                }
                let Some(playtime) = playtime_val.as_f64() else {
                    continue;
                };
                if playtime <= 0.0 {
                    continue;
                }
                let safe = (playtime as i64).min(quest_budget).max(0);
                if safe <= 0 {
                    continue;
                }
                quest_budget -= safe;

                sqlx::query(
                    "INSERT INTO user_quest_playtime (user_id, quest_id, playtime_seconds, last_played_at) \
                     VALUES ($1, $2, $3, NOW()) \
                     ON CONFLICT (user_id, quest_id) DO UPDATE SET \
                        playtime_seconds = user_quest_playtime.playtime_seconds + EXCLUDED.playtime_seconds, \
                        last_played_at = NOW()",
                )
                .bind(auth.id)
                .bind(quest_id)
                .bind(safe)
                .execute(&mut *tx)
                .await?;

                sqlx::query(
                    "INSERT INTO playtime_daily (user_id, quest_id, day, seconds) \
                     VALUES ($1, $2, $3::date, $4) \
                     ON CONFLICT (user_id, quest_id, day) DO UPDATE SET \
                        seconds = playtime_daily.seconds + EXCLUDED.seconds",
                )
                .bind(auth.id)
                .bind(quest_id)
                .bind(&today)
                .bind(safe)
                .execute(&mut *tx)
                .await?;
            }
        }
    }

    sqlx::query("UPDATE profiles SET playtime_last_sync_at = NOW() WHERE id = $1")
        .bind(auth.id)
        .execute(&mut *tx)
        .await?;

    tx.commit().await.map_err(pool_busy)?;

    ok_json(json!({"success": true}))
}

// ========================================================================
//  Tests for pure profile validation logic
// ========================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn banner_style_accepts_allowed_presets() {
        let value = json!({"type": "preset", "id": "aurora"});
        let result = validate_banner_style(&value).unwrap();
        assert_eq!(result, Some(json!({"type": "preset", "id": "aurora"})));
    }

    #[test]
    fn banner_style_rejects_unknown_id() {
        let value = json!({"type": "preset", "id": "nope"});
        assert!(validate_banner_style(&value).is_err());
    }

    #[test]
    fn banner_style_null_is_null() {
        assert_eq!(validate_banner_style(&Value::Null).unwrap(), None);
    }

    #[test]
    fn social_links_validates_and_lowercases() {
        let value = json!([
            {"platform": "Telegram", "url": "https://t.me/test"},
            {"platform": "GITHUB", "url": "  https://github.com/test  "}
        ]);
        let result = validate_social_links(&value).unwrap();
        assert_eq!(result.len(), 2);
        assert_eq!(result[0]["platform"], "telegram");
        assert_eq!(result[1]["url"], "https://github.com/test");
    }

    #[test]
    fn social_links_rejects_bad_protocol() {
        let value = json!([{"platform": "website", "url": "ftp://example.com"}]);
        assert!(validate_social_links(&value).is_err());
    }

    #[test]
    fn social_links_rejects_unknown_platform() {
        let value = json!([{"platform": "fb", "url": "https://fb.com/x"}]);
        assert!(validate_social_links(&value).is_err());
    }

    #[test]
    fn social_links_skips_non_objects() {
        let value = json!([null, {"platform": "website", "url": "https://x.dev"}, 42]);
        let result = validate_social_links(&value).unwrap();
        assert_eq!(result.len(), 1);
    }

    #[test]
    fn avatar_extensions_match_node() {
        assert!(is_avatar_extension(".jpg"));
        assert!(is_avatar_extension(".jpeg"));
        assert!(is_avatar_extension(".png"));
        assert!(is_avatar_extension(".webp"));
        assert!(!is_avatar_extension(".gif"));
        assert!(!is_avatar_extension(""));
    }
}

// ========================================================================
//  Router
// ========================================================================

pub fn router() -> Router<Arc<AppState>> {
    let avatar_router = Router::new()
        .route("/me/avatar", post(upload_avatar))
        // Node allowed file parts up to 2 MB; raise the plain body limit to match.
        .layer(DefaultBodyLimit::max(AVATAR_MAX_BYTES + 1024));

    Router::new()
        // sync settings
        .route(
            "/sync-settings",
            get(get_sync_settings).post(post_sync_settings),
        )
        // author notification settings
        .route(
            "/author-notifs-settings",
            get(get_author_notifs_settings).post(post_author_notifs_settings),
        )
        // cosmetics
        .route("/cosmetics/mine", get(get_cosmetics_mine))
        // my profile
        .route(
            "/me",
            post(update_profile)
                .get(me_as_id)
                .fallback(crate::method_not_found),
        )
        .route("/update-streak", post(update_streak))
        .route("/me/rewards", get(get_my_rewards))
        .route("/me/playhistory", get(get_my_playhistory))
        // avatar upload (body limit raised)
        .merge(avatar_router)
        // promo
        .route("/redeem", post(redeem_promo))
        // follow
        .route("/{id}/follow", post(toggle_follow))
        // public / profile-scoped
        .route("/{id}", get(get_profile))
        .route("/{id}/quests", get(get_user_quests))
        .route("/{id}/reviews", get(get_user_reviews))
        .route("/{id}/is-following", get(is_following))
        .route("/{id}/playhistory", get(get_user_playhistory))
        .route("/{id}/achievements", get(get_user_achievements))
        // misc
        .route("/fcm-token", post(post_fcm_token))
        .route("/playtime-sync", post(sync_playtime))
}

/// `Body::i64` semantics for a value already destructured out of `Body`.
fn json_i64(value: Option<&Value>) -> Option<i64> {
    match value? {
        Value::Number(n) => n.as_i64(),
        Value::String(raw) => raw.trim().parse().ok(),
        _ => None,
    }
}

/// `Body::bool` semantics for a value already destructured out of `Body`.
fn json_bool(value: Option<&Value>) -> bool {
    match value {
        Some(Value::Bool(flag)) => *flag,
        Some(Value::String(raw)) => raw == "true" || raw == "1",
        _ => false,
    }
}
