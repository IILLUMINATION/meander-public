//! Форумы — полка для постов сообщества.
//!
//! Порт `backend/src/routes/forums.ts`. Сохранены пути, статусы, тексты ошибок
//! и JSON-поля; модерация постов идёт через `services::moderation`, а права —
//! через `services::gating`.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, LazyLock};

use axum::Router;
use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::routing::{get, post};
use regex::Regex;
use serde_json::{Value, json};
use sqlx::Row;
use uuid::Uuid;

use crate::auth::{AuthUser, OptionalAuth};
use crate::error::{ApiError, ApiResult, ok_created, ok_json};
use crate::extractors::Body;
use crate::json::{parse_int, pg_row_to_json, rows_to_json};
use crate::services::gating::{
    FORUM_RULES, Tenure, can_create_forum, get_forums_created_by_day, get_karma_and_limits,
    get_tenure, is_staff,
};
use crate::services::moderation::moderate_wall_post;
use crate::services::notifications::{NewNotification, create_notification};
use crate::state::AppState;

const AUTHOR_FIELDS: &str = "a.id, a.full_name, a.avatar_url, a.cosmetics, a.role, a.is_verified";

static HASHTAG_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"#[a-zA-Zа-яА-ЯёЁ0-9_]+").expect("hashtag regex"));

static MARKDOWN_IMAGE_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"!\[.*?\]\((https?://[^)]+)\)").expect("markdown image regex"));

/// Русско-латинская транслитерация слага из Node-версии.
/// `None` означает «оставить символ как есть», `Some("")` — удалить.
fn translit(ch: char) -> Option<&'static str> {
    match ch {
        'а' => Some("a"),
        'б' => Some("b"),
        'в' => Some("v"),
        'г' => Some("g"),
        'д' => Some("d"),
        'е' => Some("e"),
        'ё' => Some("yo"),
        'ж' => Some("zh"),
        'з' => Some("z"),
        'и' => Some("i"),
        'й' => Some("y"),
        'к' => Some("k"),
        'л' => Some("l"),
        'м' => Some("m"),
        'н' => Some("n"),
        'о' => Some("o"),
        'п' => Some("p"),
        'р' => Some("r"),
        'с' => Some("s"),
        'т' => Some("t"),
        'у' => Some("u"),
        'ф' => Some("f"),
        'х' => Some("h"),
        'ц' => Some("c"),
        'ч' => Some("ch"),
        'ш' => Some("sh"),
        'щ' => Some("sch"),
        'ъ' => Some(""),
        'ы' => Some("y"),
        'ь' => Some(""),
        'э' => Some("e"),
        'ю' => Some("yu"),
        'я' => Some("ya"),
        _ => None,
    }
}

static SLUG_SEP_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"-+").expect("slug separator regex"));

fn slugify(name: &str) -> String {
    let mut latin = String::with_capacity(name.len() * 2);
    for ch in name.to_lowercase().chars() {
        match translit(ch) {
            Some(repl) => latin.push_str(repl),
            None => latin.push(ch),
        }
    }
    let mut latin: String = latin
        .chars()
        .map(|ch| if ch.is_ascii_alphanumeric() { ch } else { '-' })
        .collect();
    latin = SLUG_SEP_RE.replace_all(&latin, "-").into_owned();
    latin = latin.trim_matches('-').to_string();
    if latin.len() > 32 {
        latin.truncate(32);
        latin = latin.trim_end_matches('-').to_string();
    }
    if latin.len() >= 3 {
        latin
    } else {
        String::new()
    }
}

fn clamp_int(raw: Option<&str>, fallback: i64, max: i64) -> i64 {
    parse_int(raw)
        .filter(|&n| n > 0)
        .map(|n| n.min(max))
        .unwrap_or(fallback)
}

struct Access {
    creator_id: Uuid,
    is_restricted: bool,
    member_role: Option<String>,
    joined: bool,
    banned: bool,
}

async fn find_forum(
    state: &AppState,
    slug: &str,
) -> Result<Option<sqlx::postgres::PgRow>, ApiError> {
    let row = sqlx::query(
        "SELECT f.id, f.slug, f.name, f.description, f.kind, f.quest_id, f.is_restricted,
                f.creator_id, f.created_at, q.title AS quest_title,
                (SELECT COUNT(*)::int FROM forum_members m WHERE m.forum_id = f.id) AS member_count,
                (SELECT COUNT(*)::int FROM author_posts ap
                  WHERE ap.forum_id = f.id AND ap.is_active = true) AS topics_count
           FROM forums f
           LEFT JOIN quests q ON q.id = f.quest_id
          WHERE f.slug = $1 AND f.is_active = true",
    )
    .bind(slug)
    .fetch_optional(&state.db)
    .await?;
    Ok(row)
}

async fn get_access(
    state: &AppState,
    forum_id: Uuid,
    user_id: Uuid,
) -> Result<Option<Access>, ApiError> {
    let Some(row) = sqlx::query(
        "SELECT f.creator_id, f.is_restricted, f.kind, f.slug,
                m.role AS member_role, m.joined_at, b.created_at AS banned_at
           FROM forums f
           LEFT JOIN forum_members m ON m.forum_id = f.id AND m.user_id = $2
           LEFT JOIN forum_bans b ON b.forum_id = f.id AND b.user_id = $2
          WHERE f.id = $1",
    )
    .bind(forum_id)
    .bind(user_id)
    .fetch_optional(&state.db)
    .await?
    else {
        return Ok(None);
    };

    Ok(Some(Access {
        creator_id: row.try_get("creator_id")?,
        is_restricted: row.try_get("is_restricted")?,
        member_role: row.try_get("member_role")?,
        joined: row
            .try_get::<Option<chrono::DateTime<chrono::Utc>>, _>("joined_at")?
            .is_some(),
        banned: row
            .try_get::<Option<chrono::DateTime<chrono::Utc>>, _>("banned_at")?
            .is_some(),
    }))
}

fn is_forum_mod(access: &Access, tenure: &Tenure, user_id: Uuid) -> bool {
    is_staff(tenure) || access.creator_id == user_id || access.member_role.as_deref() == Some("mod")
}

async fn require_mod(
    state: &AppState,
    slug: &str,
    user_id: Uuid,
) -> Result<(sqlx::postgres::PgRow, Access, Tenure), ApiError> {
    let Some(forum) = find_forum(state, slug).await? else {
        return Err(ApiError::not_found("Сообщество не найдено"));
    };
    let Some(tenure) = get_tenure(state, user_id).await else {
        return Err(ApiError::unauthorized("Профиль не найден"));
    };
    let Some(access) = get_access(state, forum.try_get::<Uuid, _>("id")?, user_id).await? else {
        return Err(ApiError::not_found("Сообщество не найдено"));
    };
    if !is_forum_mod(&access, &tenure, user_id) {
        return Err(ApiError::forbidden(
            "Это право только у создателя форума, его модератора или админа",
        ));
    }
    Ok((forum, access, tenure))
}

// =======================================================================
//  КАТАЛОГ
// =======================================================================
async fn list_forums(
    State(state): State<Arc<AppState>>,
    auth: OptionalAuth,
    Query(q): Query<HashMap<String, String>>,
) -> ApiResult {
    let viewer = auth.id();
    let scope = q.get("scope").map(String::as_str).unwrap_or("all");
    let sort = q.get("sort").map(String::as_str).unwrap_or("active");
    let search = q.get("q").and_then(|v| {
        let trimmed = v.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(format!("%{}%", trimmed.to_lowercase()))
        }
    });
    let limit = clamp_int(q.get("limit").map(String::as_str), 30, 100);
    let offset = clamp_int(q.get("offset").map(String::as_str), 0, 100000);

    if scope == "mine" && viewer.is_none() {
        return Err(ApiError::unauthorized("Нужно войти в аккаунт"));
    }

    let order = match sort {
        "popular" => "member_count DESC, topics_count DESC",
        "new" => "f.created_at DESC",
        _ => "last_activity_at DESC NULLS LAST, member_count DESC",
    };

    let rows = sqlx::query(&format!(
        "SELECT f.id, f.slug, f.name, f.description, f.kind, f.quest_id, f.is_restricted,
                f.created_at,
                (SELECT COUNT(*)::int FROM forum_members m WHERE m.forum_id = f.id) AS member_count,
                (SELECT COUNT(*)::int FROM author_posts ap
                  WHERE ap.forum_id = f.id AND ap.is_active = true) AS topics_count,
                (SELECT MAX(ap2.created_at) FROM author_posts ap2
                  WHERE ap2.forum_id = f.id AND ap2.is_active = true) AS last_activity_at,
                c.id AS creator_id, c.full_name AS creator_name, c.avatar_url AS creator_avatar_url,
                c.cosmetics AS creator_cosmetics, c.role AS creator_role,
                (EXISTS (SELECT 1 FROM forum_members j
                          WHERE j.forum_id = f.id AND j.user_id = $1::uuid)) AS joined
           FROM forums f
           JOIN profiles c ON c.id = f.creator_id
          WHERE f.is_active = true
            AND ($2::text IS NULL OR lower(f.name) LIKE $2 OR lower(f.slug) LIKE $2)
            AND ($3 <> 'mine' OR EXISTS (SELECT 1 FROM forum_members j2
                          WHERE j2.forum_id = f.id AND j2.user_id = $1::uuid))
          ORDER BY {}
          LIMIT $4 OFFSET $5",
        order
    ))
    .bind(viewer)
    .bind(search)
    .bind(scope)
    .bind(limit)
    .bind(offset)
    .fetch_all(&state.db)
    .await?;

    ok_json(json!({ "forums": rows_to_json(&rows) }))
}

// =======================================================================
//  ОБСУЖДЕНИЕ КВЕСТА
// =======================================================================
async fn quest_forum(
    State(state): State<Arc<AppState>>,
    _auth: OptionalAuth,
    Path(quest_id): Path<String>,
) -> ApiResult {
    let quest_id =
        Uuid::parse_str(&quest_id).map_err(|_| ApiError::bad_request("Некорректный квест"))?;

    let quest =
        sqlx::query("SELECT id, title, description, status, author_id FROM quests WHERE id = $1")
            .bind(quest_id)
            .fetch_optional(&state.db)
            .await?;

    let Some(quest) = quest else {
        return Err(ApiError::not_found("Квест не найден"));
    };
    let status = crate::json::text_col(&quest, "status").unwrap_or_default();
    if status != "published" {
        return Err(ApiError::forbidden(
            "Обсуждение открывается после публикации",
        ));
    }

    let existing = sqlx::query("SELECT id, slug FROM forums WHERE quest_id = $1")
        .bind(quest_id)
        .fetch_optional(&state.db)
        .await?;

    if let Some(row) = existing {
        let forum_id: Uuid = row.try_get("id")?;
        let slug: String = row.try_get("slug")?;
        return ok_json(json!({ "forum_id": forum_id, "slug": slug }));
    }

    let title: String = quest.try_get("title")?;
    let description: Option<String> = quest.try_get("description")?;
    let author_id: Uuid = quest.try_get("author_id")?;
    let slug = format!(
        "quest-{}",
        quest_id
            .as_hyphenated()
            .to_string()
            .split('-')
            .next()
            .unwrap_or("")
    );
    let name = format!(
        "Обсуждение: {}",
        title
            .chars()
            .take(FORUM_RULES.max_name_chars)
            .collect::<String>()
    );
    let description = description.map(|d| {
        d.chars()
            .take(FORUM_RULES.max_description_chars)
            .collect::<String>()
    });

    let created = sqlx::query(
        "INSERT INTO forums (slug, name, description, kind, quest_id, creator_id)
         VALUES ($1, $2, $3, 'quest', $4, $5)
         ON CONFLICT (quest_id) DO UPDATE SET quest_id = EXCLUDED.quest_id
         RETURNING id, slug",
    )
    .bind(&slug)
    .bind(&name)
    .bind(description.as_deref())
    .bind(quest_id)
    .bind(author_id)
    .fetch_one(&state.db)
    .await?;

    let forum_id: Uuid = created.try_get("id")?;
    let forum_slug: String = created.try_get("slug")?;

    let _ = sqlx::query(
        "INSERT INTO forum_members (forum_id, user_id, role) VALUES ($1, $2, 'mod')
         ON CONFLICT (forum_id, user_id) DO NOTHING",
    )
    .bind(forum_id)
    .bind(author_id)
    .execute(&state.db)
    .await?;

    ok_json(json!({ "forum_id": forum_id, "slug": forum_slug }))
}

// =======================================================================
//  ГОРЯЧИЕ ОБСУЖДЕНИЯ
// =======================================================================
async fn hot_topics(
    State(state): State<Arc<AppState>>,
    auth: OptionalAuth,
    Query(q): Query<HashMap<String, String>>,
) -> ApiResult {
    let viewer = auth.id();
    let limit = clamp_int(q.get("limit").map(String::as_str), 12, 25);

    let rows = sqlx::query(
        "SELECT ap.id, ap.title, ap.content, ap.created_at,
                ap.likes_count, ap.media_urls, ap.tags,
                co.comment_count AS comments_count,
                f.slug AS forum_slug, f.name AS forum_name, f.kind AS forum_kind,
                a.id AS author_id, a.full_name AS author_name, a.avatar_url AS author_avatar_url,
                a.cosmetics AS author_cosmetics, a.role AS author_role, a.is_verified AS author_is_verified,
                (EXISTS (SELECT 1 FROM author_post_likes l
                          WHERE l.post_id = ap.id AND l.user_id = $1::uuid)) AS is_liked_by_viewer
           FROM author_posts ap
           JOIN profiles a ON a.id = ap.author_id
           JOIN forums f ON f.id = ap.forum_id
           CROSS JOIN LATERAL (
               SELECT COUNT(*)::int AS comment_count
                 FROM author_post_comments c
                WHERE c.post_id = ap.id AND c.is_active = true
           ) co
          WHERE ap.is_active = true AND f.is_active = true
            AND ap.created_at > now() - INTERVAL '14 days'
          ORDER BY (ap.likes_count + co.comment_count * 2) DESC, ap.created_at DESC
          LIMIT $2",
    )
    .bind(viewer)
    .bind(limit)
    .fetch_all(&state.db)
    .await?;

    ok_json(json!({ "topics": rows_to_json(&rows) }))
}

// =======================================================================
//  СОЗДАНИЕ
// =======================================================================
async fn create_forum(State(state): State<Arc<AppState>>, auth: AuthUser, body: Body) -> ApiResult {
    let me = auth.id;
    let name = body.str("name").unwrap_or("").trim();
    let description = body.str("description").unwrap_or("").trim();
    let requested_slug = body.str("slug").unwrap_or("").trim().to_lowercase();

    if name.len() < 3 {
        return Err(ApiError::bad_request("Название короче 3 символов"));
    }
    if name.len() > FORUM_RULES.max_name_chars {
        return Err(ApiError::bad_request(format!(
            "Название длиннее {} символов",
            FORUM_RULES.max_name_chars
        )));
    }
    if description.len() > FORUM_RULES.max_description_chars {
        return Err(ApiError::bad_request(format!(
            "Описание длиннее {} символов",
            FORUM_RULES.max_description_chars
        )));
    }

    let Some(tenure) = get_tenure(&state, me).await else {
        return Err(ApiError::unauthorized("Профиль не найден"));
    };
    if !can_create_forum(&tenure) {
        return Err(ApiError::forbidden(format!(
            "Сообщество может создать тот, кто с нами {} дней или уже публиковал квест.",
            FORUM_RULES.min_account_age_days_to_create as i64
        )));
    }
    if !is_staff(&tenure)
        && get_forums_created_by_day(&state, me).await >= FORUM_RULES.max_created_by_day
    {
        return Err(ApiError::new(
            StatusCode::TOO_MANY_REQUESTS,
            format!(
                "За сутки можно создать {} сообщества.",
                FORUM_RULES.max_created_by_day
            ),
        ));
    }

    let base = if !requested_slug.is_empty()
        && Regex::new(r"^[a-z0-9][a-z0-9_-]{2,39}$")
            .unwrap()
            .is_match(&requested_slug)
    {
        requested_slug
    } else {
        let generated = slugify(name);
        if generated.is_empty() {
            format!(
                "forum-{}",
                me.as_hyphenated()
                    .to_string()
                    .split('-')
                    .next()
                    .unwrap_or("")
            )
        } else {
            generated
        }
    };

    let taken = sqlx::query("SELECT 1 FROM forums WHERE slug = $1")
        .bind(&base)
        .fetch_optional(&state.db)
        .await?;
    if taken.is_some() {
        return Err(ApiError::conflict(format!(
            "Сообщество с адресом {} уже есть. Придумай другой.",
            base
        )));
    }

    let is_restricted = body.bool("is_restricted").unwrap_or(false);
    let description_opt = if description.is_empty() {
        None
    } else {
        Some(description)
    };

    let created = sqlx::query(
        "INSERT INTO forums (slug, name, description, kind, creator_id, is_restricted)
         VALUES ($1, $2, $3, 'user', $4, $5)
         ON CONFLICT (slug) DO NOTHING
         RETURNING id, slug, name, description, kind, is_restricted, created_at",
    )
    .bind(&base)
    .bind(name)
    .bind(description_opt)
    .bind(me)
    .bind(is_restricted)
    .fetch_optional(&state.db)
    .await?;

    let Some(forum) = created else {
        return Err(ApiError::conflict(format!(
            "Сообщество с адресом {} уже есть. Придумай другой.",
            base
        )));
    };

    let forum_id: Uuid = forum.try_get("id")?;
    let _ = sqlx::query(
        "INSERT INTO forum_members (forum_id, user_id, role) VALUES ($1, $2, 'mod')
         ON CONFLICT (forum_id, user_id) DO NOTHING",
    )
    .bind(forum_id)
    .bind(me)
    .execute(&state.db)
    .await?;

    ok_created(pg_row_to_json(&forum))
}

// =======================================================================
//  ЛОББИ
// =======================================================================
async fn get_forum(
    State(state): State<Arc<AppState>>,
    auth: OptionalAuth,
    Path(slug): Path<String>,
) -> ApiResult {
    let viewer = auth.id();
    let Some(forum) = find_forum(&state, &slug).await? else {
        return Err(ApiError::not_found("Сообщество не найдено"));
    };
    let forum_id: Uuid = forum.try_get("id")?;

    let mods = sqlx::query(&format!(
        "SELECT {}, m.role AS forum_role, m.joined_at
           FROM forum_members m JOIN profiles a ON a.id = m.user_id
          WHERE m.forum_id = $1 AND m.role = 'mod'
          ORDER BY m.joined_at ASC
          LIMIT 20",
        AUTHOR_FIELDS
    ))
    .bind(forum_id)
    .fetch_all(&state.db)
    .await?;

    let access: Option<Access> = if let Some(user_id) = viewer {
        get_access(&state, forum_id, user_id).await?
    } else {
        None
    };

    let mut forum_json = pg_row_to_json(&forum);
    if let Value::Object(map) = &mut forum_json {
        map.insert(
            "joined".to_string(),
            Value::Bool(access.as_ref().map_or(false, |a| a.joined)),
        );
        map.insert(
            "banned".to_string(),
            Value::Bool(access.as_ref().map_or(false, |a| a.banned)),
        );
    }

    ok_json(json!({
        "forum": forum_json,
        "mods": rows_to_json(&mods),
    }))
}

async fn patch_forum(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(slug): Path<String>,
    body: Body,
) -> ApiResult {
    let me = auth.id;
    let Some(forum) = find_forum(&state, &slug).await? else {
        return Err(ApiError::not_found("Сообщество не найдено"));
    };
    let forum_id: Uuid = forum.try_get("id")?;

    let Some(tenure) = get_tenure(&state, me).await else {
        return Err(ApiError::unauthorized("Профиль не найден"));
    };
    let Some(access) = get_access(&state, forum_id, me).await? else {
        return Err(ApiError::not_found("Сообщество не найдено"));
    };
    if !is_forum_mod(&access, &tenure, me) {
        return Err(ApiError::forbidden(
            "Настройки форума меняет его создатель, модератор форума или админ",
        ));
    }

    let name = body.str("name").map(str::trim);
    let description = body.str("description").map(str::trim);

    if let Some(name) = name {
        if name.len() < 3 || name.len() > FORUM_RULES.max_name_chars {
            return Err(ApiError::bad_request(format!(
                "Название должно быть от 3 до {} символов",
                FORUM_RULES.max_name_chars
            )));
        }
    }
    if let Some(description) = description {
        if description.len() > FORUM_RULES.max_description_chars {
            return Err(ApiError::bad_request(format!(
                "Описание длиннее {} символов",
                FORUM_RULES.max_description_chars
            )));
        }
    }

    let is_restricted = body.bool("is_restricted");

    let updated = sqlx::query(
        "UPDATE forums SET
            name = COALESCE($2, name),
            description = COALESCE($3, description),
            is_restricted = COALESCE($4, is_restricted)
          WHERE id = $1
          RETURNING id, slug, name, description, is_restricted",
    )
    .bind(forum_id)
    .bind(name)
    .bind(description)
    .bind(is_restricted)
    .fetch_one(&state.db)
    .await?;

    ok_json(pg_row_to_json(&updated))
}

// =======================================================================
//  УЧАСТИЕ
// =======================================================================
/// `/quest/<x>` is both the quest-forum route and `/<slug>/<x>` for a forum
/// whose slug is literally `quest`. Express skips the GET-only quest route for
/// other methods and reaches the slug routes; axum stops at the static match,
/// so dispatch those few methods to the slug handlers explicitly.
async fn quest_slug_fallback(
    State(state): State<Arc<AppState>>,
    method: axum::http::Method,
    uri: axum::http::Uri,
    auth: Result<AuthUser, ApiError>,
    body: Body,
) -> ApiResult {
    let slug = uri.path().rsplit('/').next().unwrap_or("").to_owned();
    match (method.as_str(), slug.as_str()) {
        ("POST", "join") => join_forum(State(state), auth?, Path("quest".to_owned())).await,
        ("DELETE", "join") => leave_forum(State(state), auth?, Path("quest".to_owned())).await,
        ("POST", "report") => {
            report_forum(State(state), auth?, Path("quest".to_owned()), body).await
        }
        ("POST", "posts") => {
            create_topic(State(state), auth?, Path("quest".to_owned()), body).await
        }
        _ => Ok(crate::express_not_found(&method, &uri.path().to_owned())),
    }
}

async fn join_forum(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(slug): Path<String>,
) -> ApiResult {
    let me = auth.id;
    let Some(forum) = find_forum(&state, &slug).await? else {
        return Err(ApiError::not_found("Сообщество не найдено"));
    };
    let forum_id: Uuid = forum.try_get("id")?;

    let Some(access) = get_access(&state, forum_id, me).await? else {
        return Err(ApiError::not_found("Сообщество не найдено"));
    };
    if access.banned {
        return Err(ApiError::forbidden("Вас ограничили в этом сообществе"));
    }

    let _ = sqlx::query(
        "INSERT INTO forum_members (forum_id, user_id) VALUES ($1, $2)
         ON CONFLICT (forum_id, user_id) DO NOTHING",
    )
    .bind(forum_id)
    .bind(me)
    .execute(&state.db)
    .await?;

    let member_count: i32 = forum.try_get("member_count")?;
    ok_json(json!({ "success": true, "member_count": member_count + 1 }))
}

async fn leave_forum(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(slug): Path<String>,
) -> ApiResult {
    let me = auth.id;
    let Some(forum) = find_forum(&state, &slug).await? else {
        return Err(ApiError::not_found("Сообщество не найдено"));
    };
    let forum_id: Uuid = forum.try_get("id")?;
    let creator_id: Uuid = forum.try_get("creator_id")?;

    if creator_id == me {
        let Some(tenure) = get_tenure(&state, me).await else {
            return Err(ApiError::unauthorized("Профиль не найден"));
        };
        if !is_staff(&tenure) {
            return Err(ApiError::bad_request(
                "Создатель может только передать форум модератору",
            ));
        }
    }

    let _ = sqlx::query("DELETE FROM forum_members WHERE forum_id = $1 AND user_id = $2")
        .bind(forum_id)
        .bind(me)
        .execute(&state.db)
        .await?;

    ok_json(json!({ "success": true }))
}

// =======================================================================
//  МОДЕРАЦИЯ ФОРУМА
// =======================================================================
async fn ban_user(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path((slug, target)): Path<(String, String)>,
    body: Body,
) -> ApiResult {
    let me = auth.id;
    let target = Uuid::parse_str(&target)
        .map_err(|_| ApiError::bad_request("Некорректный идентификатор"))?;

    let (forum, _access, tenure) = require_mod(&state, &slug, me).await?;
    let forum_id: Uuid = forum.try_get("id")?;
    let creator_id: Uuid = forum.try_get("creator_id")?;
    let forum_name: String = forum.try_get("name")?;
    let forum_slug: String = forum.try_get("slug")?;

    if tenure.role != "admin" && target == creator_id {
        return Err(ApiError::forbidden("Создателя форума забанить нельзя"));
    }

    let reason = body
        .str("reason")
        .map(|s| s.chars().take(300).collect::<String>());

    let _ = sqlx::query(
        "INSERT INTO forum_bans (forum_id, user_id, banned_by, reason)
         VALUES ($1, $2, $3, $4)
         ON CONFLICT (forum_id, user_id) DO UPDATE SET reason = EXCLUDED.reason, banned_by = EXCLUDED.banned_by",
    )
    .bind(forum_id)
    .bind(target)
    .bind(me)
    .bind(&reason)
    .execute(&state.db)
    .await?;

    let _ = sqlx::query("DELETE FROM forum_members WHERE forum_id = $1 AND user_id = $2")
        .bind(forum_id)
        .bind(target)
        .execute(&state.db)
        .await?;

    let _ = create_notification(
        &state,
        NewNotification {
            user_id: target,
            actor_id: Some(me),
            kind: "forum_ban",
            quest_id: None,
            review_id: None,
            payload: Some(json!({
                "forum": forum_name,
                "forum_slug": forum_slug,
                "reason": reason,
            })),
        },
    )
    .await;

    ok_json(json!({ "success": true }))
}

async fn unban_user(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path((slug, target)): Path<(String, String)>,
) -> ApiResult {
    let me = auth.id;
    let target = Uuid::parse_str(&target)
        .map_err(|_| ApiError::bad_request("Некорректный идентификатор"))?;

    let (forum, _access, _tenure) = require_mod(&state, &slug, me).await?;
    let forum_id: Uuid = forum.try_get("id")?;

    let _ = sqlx::query("DELETE FROM forum_bans WHERE forum_id = $1 AND user_id = $2")
        .bind(forum_id)
        .bind(target)
        .execute(&state.db)
        .await?;

    ok_json(json!({ "success": true }))
}

async fn list_bans(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(slug): Path<String>,
) -> ApiResult {
    let me = auth.id;
    let (forum, _access, _tenure) = require_mod(&state, &slug, me).await?;
    let forum_id: Uuid = forum.try_get("id")?;

    let rows = sqlx::query(&format!(
        "SELECT {}, b.reason, b.created_at AS banned_at
           FROM forum_bans b JOIN profiles a ON a.id = b.user_id
          WHERE b.forum_id = $1
          ORDER BY b.created_at DESC
          LIMIT 50",
        AUTHOR_FIELDS
    ))
    .bind(forum_id)
    .fetch_all(&state.db)
    .await?;

    ok_json(json!({ "bans": rows_to_json(&rows) }))
}

async fn assign_moderator(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path((slug, target)): Path<(String, String)>,
) -> ApiResult {
    let me = auth.id;
    let target = Uuid::parse_str(&target)
        .map_err(|_| ApiError::bad_request("Некорректный идентификатор"))?;

    let Some(forum) = find_forum(&state, &slug).await? else {
        return Err(ApiError::not_found("Сообщество не найдено"));
    };
    let forum_id: Uuid = forum.try_get("id")?;
    let creator_id: Uuid = forum.try_get("creator_id")?;

    if creator_id != me {
        let Some(tenure) = get_tenure(&state, me).await else {
            return Err(ApiError::unauthorized("Профиль не найден"));
        };
        if !is_staff(&tenure) {
            return Err(ApiError::forbidden(
                "Модератора назначает только создатель форума",
            ));
        }
    }

    let _ = sqlx::query(
        "INSERT INTO forum_members (forum_id, user_id, role) VALUES ($1, $2, 'mod')
         ON CONFLICT (forum_id, user_id) DO UPDATE SET role = 'mod'",
    )
    .bind(forum_id)
    .bind(target)
    .execute(&state.db)
    .await?;

    ok_json(json!({ "success": true }))
}

async fn report_forum(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(slug): Path<String>,
    body: Body,
) -> ApiResult {
    let me = auth.id;
    let reason = body.str("reason").unwrap_or("").trim();
    if reason.is_empty() {
        return Err(ApiError::bad_request("Опишите, что не так"));
    }

    let Some(forum) = find_forum(&state, &slug).await? else {
        return Err(ApiError::not_found("Сообщество не найдено"));
    };
    let forum_id: Uuid = forum.try_get("id")?;

    let duplicate = sqlx::query(
        "SELECT 1 FROM reports
          WHERE reporter_id = $1 AND reported_type = 'forum' AND reported_id = $2 AND status = 'pending'",
    )
    .bind(me)
    .bind(forum_id)
    .fetch_optional(&state.db)
    .await?;

    if duplicate.is_some() {
        return ok_json(json!({ "success": true, "already": true }));
    }

    let _ = sqlx::query(
        "INSERT INTO reports (reporter_id, reported_type, reported_id, reason, description, status)
         VALUES ($1, 'forum', $2, $3, $4, 'pending')",
    )
    .bind(me)
    .bind(forum_id)
    .bind("USER_REPORT")
    .bind(reason.chars().take(500).collect::<String>())
    .execute(&state.db)
    .await?;

    ok_json(json!({ "success": true }))
}

// =======================================================================
//  ТОПИКИ
// =======================================================================
async fn list_topics(
    State(state): State<Arc<AppState>>,
    auth: OptionalAuth,
    Path(slug): Path<String>,
    Query(q): Query<HashMap<String, String>>,
) -> ApiResult {
    let viewer = auth.id();
    let sort = match q.get("sort").map(String::as_str) {
        Some("top") => "ap.likes_count DESC, ap.created_at DESC",
        Some("discussed") => "comments_count DESC, ap.created_at DESC",
        _ => "ap.created_at DESC",
    };
    let limit = clamp_int(q.get("limit").map(String::as_str), 25, 50);
    let offset = clamp_int(q.get("offset").map(String::as_str), 0, 100000);

    let Some(forum) = find_forum(&state, &slug).await? else {
        return Err(ApiError::not_found("Сообщество не найдено"));
    };
    let forum_id: Uuid = forum.try_get("id")?;

    let rows = sqlx::query(&format!(
        "SELECT ap.id, ap.title, ap.content, ap.created_at, ap.updated_at, ap.forum_id,
                ap.likes_count, ap.media_urls, ap.tags, ap.interest_score,
                (SELECT COUNT(*)::int FROM author_post_comments c
                  WHERE c.post_id = ap.id AND c.is_active = true) AS comments_count,
                a.id AS author_id, a.full_name AS author_name, a.avatar_url AS author_avatar_url,
                a.cosmetics AS author_cosmetics, a.role AS author_role, a.is_verified AS author_is_verified,
                (EXISTS (SELECT 1 FROM author_post_likes l
                          WHERE l.post_id = ap.id AND l.user_id = $1::uuid)) AS is_liked_by_viewer
           FROM author_posts ap
           JOIN profiles a ON a.id = ap.author_id
          WHERE ap.forum_id = $2 AND ap.is_active = true
            AND NOT EXISTS (
              SELECT 1 FROM user_blocks ub
              WHERE ub.user_id = $1::uuid AND ub.blocked_id = ap.author_id
            )
          ORDER BY {}
          LIMIT $3 OFFSET $4",
        sort
    ))
    .bind(viewer)
    .bind(forum_id)
    .bind(limit)
    .bind(offset)
    .fetch_all(&state.db)
    .await?;

    ok_json(json!({
        "forum_id": forum_id,
        "slug": slug,
        "topics": rows_to_json(&rows),
    }))
}

async fn create_topic(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(slug): Path<String>,
    body: Body,
) -> ApiResult {
    let me = auth.id;

    let title = body.str("title").unwrap_or("").trim();
    let content = body.str("content").unwrap_or("").trim();
    let media_urls: Vec<String> = body
        .array("media_urls")
        .into_iter()
        .filter_map(|v| v.as_str().map(|s| s.to_string()))
        .take(6)
        .collect();

    if title.is_empty() {
        return Err(ApiError::bad_request("У обсуждения должен быть заголовок"));
    }
    if title.len() > FORUM_RULES.max_title_chars {
        return Err(ApiError::bad_request(format!(
            "Заголовок длиннее {} символов",
            FORUM_RULES.max_title_chars
        )));
    }
    if content.is_empty() {
        return Err(ApiError::bad_request("Пустой топик"));
    }
    if content.len() > FORUM_RULES.max_body_chars {
        return Err(ApiError::bad_request(format!(
            "Сообщение длиннее {} символов",
            FORUM_RULES.max_body_chars
        )));
    }

    let Some(forum) = find_forum(&state, &slug).await? else {
        return Err(ApiError::not_found("Сообщество не найдено"));
    };
    let forum_id: Uuid = forum.try_get("id")?;
    let forum_slug: String = forum.try_get("slug")?;

    let Some(tenure) = get_tenure(&state, me).await else {
        return Err(ApiError::unauthorized("Профиль не найден"));
    };
    let Some(access) = get_access(&state, forum_id, me).await? else {
        return Err(ApiError::not_found("Сообщество не найдено"));
    };
    if access.banned {
        return Err(ApiError::forbidden("Вас ограничили в этом сообществе"));
    }
    if access.is_restricted && !access.joined && !is_forum_mod(&access, &tenure, me) {
        return Err(ApiError::forbidden(
            "В этом сообществе пишут только участники — вступите, чтобы задать вопрос",
        ));
    }

    let limits = get_karma_and_limits(&state, me).await;
    if limits.post_cooldown_min > 0 {
        let recent = sqlx::query(
            "SELECT 1 FROM author_posts
              WHERE author_id = $1 AND created_at > NOW() - $2::INTERVAL
              LIMIT 1",
        )
        .bind(me)
        .bind(format!("{} minutes", limits.post_cooldown_min))
        .fetch_optional(&state.db)
        .await?;
        if recent.is_some() {
            return Err(ApiError::new(
                StatusCode::TOO_MANY_REQUESTS,
                format!(
                    "Следующее обсуждение можно через {} мин.",
                    limits.post_cooldown_min
                ),
            ));
        }
    }

    let mut tags = Vec::new();
    let mut seen = HashSet::new();
    for m in HASHTAG_RE.find_iter(content) {
        let t = m.as_str();
        if t.len() > 1 {
            let normalized = t[1..].to_lowercase();
            if seen.insert(normalized.clone()) {
                tags.push(normalized);
            }
        }
    }

    let media_json = json!(media_urls);
    let inserted = sqlx::query(
        "INSERT INTO author_posts (author_id, content, media_urls, tags, forum_id, title)
         VALUES ($1, $2, $3, $4, $5, $6)
         RETURNING id, author_id, title, content, created_at, likes_count, forum_id",
    )
    .bind(me)
    .bind(content)
    .bind(media_json)
    .bind(&tags)
    .bind(forum_id)
    .bind(title)
    .fetch_one(&state.db)
    .await?;

    let post_id: Uuid = inserted.try_get("id")?;

    let _ = sqlx::query(
        "INSERT INTO forum_members (forum_id, user_id) VALUES ($1, $2)
         ON CONFLICT (forum_id, user_id) DO NOTHING",
    )
    .bind(forum_id)
    .bind(me)
    .execute(&state.db)
    .await?;

    let post_json = pg_row_to_json(&inserted);

    // Фон-модерация, как у постов стены: публикуем сразу, потом разбираем.
    let state_spawn = Arc::clone(&state);
    let content_owned = content.to_string();
    let media_spawn = media_urls;
    tokio::spawn(async move {
        let mut combined: HashSet<String> = media_spawn.into_iter().collect();
        for caps in MARKDOWN_IMAGE_RE.captures_iter(&content_owned) {
            if let Some(url) = caps.get(1) {
                combined.insert(url.as_str().to_string());
            }
        }
        let urls: Vec<String> = combined.into_iter().collect();
        let verdict = moderate_wall_post(&content_owned, &urls);

        let result = if verdict.needs_review {
            sqlx::query(
                "INSERT INTO reports (reporter_id, reported_type, reported_id, reason, description, status)
                 VALUES ($1, 'wall_post', $2, 'AUTO_FLAGGED_FOR_REVIEW', $3, 'pending')",
            )
            .bind(me)
            .bind(post_id)
            .bind(format!(
                "Топик форума {} помечен на ручной разбор: {}",
                forum_slug, verdict.reason
            ))
            .execute(&state_spawn.db)
            .await
        } else if !verdict.approved {
            sqlx::query("UPDATE author_posts SET is_active = false WHERE id = $1")
                .bind(post_id)
                .execute(&state_spawn.db)
                .await
        } else {
            sqlx::query("UPDATE author_posts SET interest_score = $1 WHERE id = $2")
                .bind(verdict.interest_score)
                .bind(post_id)
                .execute(&state_spawn.db)
                .await
        };

        if let Err(err) = result {
            tracing::error!(error = %err, "forum topic moderation failed");
        }
    });

    ok_created(post_json)
}

async fn remove_topic(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path((slug, post_id)): Path<(String, String)>,
    body: Body,
) -> ApiResult {
    let me = auth.id;
    let post_id = Uuid::parse_str(&post_id)
        .map_err(|_| ApiError::bad_request("Некорректный идентификатор"))?;

    let (forum, _access, _tenure) = require_mod(&state, &slug, me).await?;
    let forum_id: Uuid = forum.try_get("id")?;
    let forum_name: String = forum.try_get("name")?;
    let forum_slug: String = forum.try_get("slug")?;

    let removed = sqlx::query(
        "UPDATE author_posts SET is_active = false
          WHERE id = $1 AND forum_id = $2 AND is_active = true
          RETURNING id, author_id",
    )
    .bind(post_id)
    .bind(forum_id)
    .fetch_optional(&state.db)
    .await?;

    let Some(removed) = removed else {
        return Err(ApiError::not_found(
            "Топик уже удалён или не из этого сообщества",
        ));
    };
    let author_id: Uuid = removed.try_get("author_id")?;

    let reason = body
        .str("reason")
        .map(|s| s.chars().take(300).collect::<String>())
        .unwrap_or_else(|| "без причины".to_string());

    let _ = sqlx::query(
        "INSERT INTO reports (reporter_id, reported_type, reported_id, reason, description, status)
         VALUES ($1, 'wall_post', $2, 'MODERATOR_REMOVED', $3, 'resolved')",
    )
    .bind(me)
    .bind(post_id)
    .bind(format!(
        "Удалён модератором форума {}: {}",
        forum_slug, reason
    ))
    .execute(&state.db)
    .await?;

    let title = body
        .str("topic_title")
        .map(|s| s.chars().take(200).collect::<String>());
    let _ = create_notification(
        &state,
        NewNotification {
            user_id: author_id,
            actor_id: Some(me),
            kind: "forum_topic_removed",
            quest_id: None,
            review_id: None,
            payload: Some(json!({
                "forum": forum_name,
                "forum_slug": forum_slug,
                "title": title,
            })),
        },
    )
    .await;

    ok_json(json!({ "success": true }))
}

pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        // static-ish routes first
        .route(
            "/quest/{questId}",
            get(quest_forum).fallback(quest_slug_fallback),
        )
        .route("/topics/hot", get(hot_topics))
        .route("/", get(list_forums).post(create_forum))
        // slug-scoped routes
        .route("/{slug}", get(get_forum).patch(patch_forum))
        .route("/{slug}/join", post(join_forum).delete(leave_forum))
        .route("/{slug}/bans", get(list_bans))
        .route("/{slug}/ban/{userId}", post(ban_user).delete(unban_user))
        .route("/{slug}/moderators/{userId}", post(assign_moderator))
        .route("/{slug}/report", post(report_forum))
        .route("/{slug}/posts", get(list_topics).post(create_topic))
        .route("/{slug}/posts/{postId}/remove", post(remove_topic))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slugify_transliterates_russian() {
        assert_eq!(slugify("Гоблины"), "gobliny");
        assert_eq!(slugify("Привет, мир!"), "privet-mir");
        assert_eq!(slugify("ёжик"), "yozhik");
    }

    #[test]
    fn slugify_rejects_short_result() {
        assert!(slugify("ab").is_empty());
    }

    #[test]
    fn slugify_collapse_separators() {
        assert_eq!(slugify("a--b___c"), "a-b-c");
    }

    #[test]
    fn clamp_int_rejects_invalid() {
        assert_eq!(clamp_int(Some("abc"), 5, 100), 5);
        assert_eq!(clamp_int(Some("-3"), 5, 100), 5);
        assert_eq!(clamp_int(Some("0"), 5, 100), 5);
        assert_eq!(clamp_int(Some("50"), 5, 12), 12);
        assert_eq!(clamp_int(Some("8"), 5, 12), 8);
    }

    #[test]
    fn hashtag_extraction_dedupes_and_lowercases() {
        let text = "Привет #Мир и #мир #Test!";
        let mut tags = Vec::new();
        let mut seen = HashSet::new();
        for m in HASHTAG_RE.find_iter(text) {
            let t = m.as_str();
            let normalized = t[1..].to_lowercase();
            if seen.insert(normalized.clone()) {
                tags.push(normalized);
            }
        }
        assert_eq!(tags, vec!["мир", "test"]);
    }
}
