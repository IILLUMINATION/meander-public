//! `/api/messages` — direct messages, blocks and team-news broadcast.
//! Port of `backend/src/routes/messages.ts`.

use std::sync::Arc;
use std::time::Duration;

use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::routing::{delete, get, post};
use axum::{Json, Router};
use chrono::Utc;
use serde_json::{Value, json};
use sqlx::Row;
use uuid::Uuid;

use crate::auth::AuthUser;
use crate::error::{ApiError, ApiResult, ok_created, ok_json};
use crate::extractors::Body;
use crate::json::{parse_int, pg_row_to_json, rows_to_json};
use crate::services::gating::{
    DM_RULES, DmPrivacyMode, SYSTEM_USER_ID, check_dm_permission, get_dm_privacy,
    get_dm_usage_today, get_tenure, has_peer_reply, is_staff, seconds_until_next_message,
};
use crate::services::notifications::{NewNotification, create_notification, system_user_id};
use crate::state::AppState;

pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        .route("/threads", get(list_threads))
        .route("/threads/peer/{peer_id}", get(get_thread_by_peer))
        .route("/threads/{id}", get(get_thread).post(send_message))
        .route("/threads/{id}/read", post(mark_read))
        .route("/threads/{id}/mute", post(mute_thread))
        .route("/threads/{id}", delete(hide_thread))
        .route("/privacy", get(get_privacy).put(put_privacy))
        .route("/blocks", get(list_blocks))
        .route("/blocks/{user_id}", post(block_user).delete(unblock_user))
        .route("/system", get(get_system_thread))
        .route("/system/broadcast", post(broadcast_system_news))
}

fn is_user_id(value: &str) -> bool {
    value == SYSTEM_USER_ID || Uuid::parse_str(value).is_ok()
}

fn parse_user_id(value: &str) -> Option<Uuid> {
    if value == SYSTEM_USER_ID {
        Uuid::parse_str(SYSTEM_USER_ID).ok()
    } else {
        Uuid::parse_str(value).ok()
    }
}

fn parse_thread_id(raw: &str) -> Result<Uuid, ApiError> {
    Uuid::parse_str(raw).map_err(|_| ApiError::bad_request("Некорректный идентификатор"))
}

async fn ensure_thread(state: &AppState, me: Uuid, peer: Uuid) -> Result<Uuid, ApiError> {
    let (user_a, user_b) = if me.to_string() < peer.to_string() {
        (me, peer)
    } else {
        (peer, me)
    };

    let row = sqlx::query(
        "INSERT INTO dm_threads (user_a, user_b)
         VALUES ($1, $2)
         ON CONFLICT (user_a, user_b) DO UPDATE SET user_a = EXCLUDED.user_a
         RETURNING id",
    )
    .bind(user_a)
    .bind(user_b)
    .fetch_one(&state.db)
    .await?;

    let thread_id: Uuid = row.try_get("id")?;

    sqlx::query(
        "INSERT INTO dm_thread_state (thread_id, user_id)
         VALUES ($1, $2), ($1, $3)
         ON CONFLICT (thread_id, user_id) DO NOTHING",
    )
    .bind(thread_id)
    .bind(user_a)
    .bind(user_b)
    .execute(&state.db)
    .await?;

    Ok(thread_id)
}

async fn list_threads(State(state): State<Arc<AppState>>, auth: AuthUser) -> ApiResult {
    let rows = sqlx::query(
        "SELECT t.id AS thread_id,
                t.last_message_at,
                p.id AS peer_id, p.full_name AS peer_name, p.avatar_url AS peer_avatar_url,
                p.cosmetics AS peer_cosmetics, p.role AS peer_role, p.last_seen_at AS peer_last_seen_at,
                last.body AS last_body, last.sender_id AS last_sender_id, last.kind AS last_kind,
                (st.muted_at IS NOT NULL) AS muted,
                (SELECT COUNT(*)::int FROM dm_messages c
                  WHERE c.thread_id = t.id AND c.deleted_at IS NULL AND c.sender_id <> $1
                    AND c.created_at > COALESCE(st.last_read_at, 'epoch'::timestamptz)) AS unread
           FROM dm_threads t
           JOIN LATERAL (SELECT p.id, p.full_name, p.avatar_url, p.cosmetics, p.role, p.last_seen_at
                          FROM profiles p
                          WHERE p.id = (CASE WHEN t.user_a = $1 THEN t.user_b ELSE t.user_a END)) p ON TRUE
           LEFT JOIN dm_thread_state st ON st.thread_id = t.id AND st.user_id = $1
           LEFT JOIN LATERAL (SELECT body, sender_id, kind FROM dm_messages m
                               WHERE m.thread_id = t.id AND m.deleted_at IS NULL
                               ORDER BY m.created_at DESC LIMIT 1) last ON TRUE
          WHERE (t.user_a = $1 OR t.user_b = $1)
            AND st.hidden_at IS NULL
          ORDER BY t.last_message_at DESC NULLS LAST, t.created_at DESC
          LIMIT 200",
    )
    .bind(auth.id)
    .fetch_all(&state.db)
    .await?;

    ok_json(json!({
        "threads": rows_to_json(&rows),
        "system_user_id": SYSTEM_USER_ID,
    }))
}

async fn get_thread_by_peer(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(peer_id): Path<String>,
) -> ApiResult {
    if !is_user_id(&peer_id) {
        return Err(ApiError::bad_request("Некорректный идентификатор"));
    }

    let peer_uuid = match parse_user_id(&peer_id) {
        Some(id) => id,
        None => return Err(ApiError::bad_request("Некорректный идентификатор")),
    };

    let rows = sqlx::query(
        "SELECT t.id AS thread_id,
                p.id AS peer_id, p.full_name AS peer_name, p.avatar_url AS peer_avatar_url,
                p.cosmetics AS peer_cosmetics, p.role AS peer_role, p.last_seen_at AS peer_last_seen_at,
                (st.muted_at IS NOT NULL) AS muted
           FROM profiles p
           LEFT JOIN dm_threads t
             ON (t.user_a = $1 AND t.user_b = p.id) OR (t.user_b = $1 AND t.user_a = p.id)
           LEFT JOIN dm_thread_state st ON st.thread_id = t.id AND st.user_id = $1
          WHERE p.id = $2",
    )
    .bind(auth.id)
    .bind(peer_uuid)
    .fetch_all(&state.db)
    .await?;

    if rows.is_empty() {
        return Err(ApiError::not_found("Человек не найден"));
    }

    Ok(Json(pg_row_to_json(&rows[0])).into_response())
}

async fn get_thread(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(thread_id): Path<String>,
    Query(query): Query<std::collections::HashMap<String, String>>,
) -> ApiResult {
    let thread_id = parse_thread_id(&thread_id)?;
    let member =
        sqlx::query("SELECT 1 FROM dm_threads WHERE id = $1 AND (user_a = $2 OR user_b = $2)")
            .bind(thread_id)
            .bind(auth.id)
            .fetch_optional(&state.db)
            .await?;

    if member.is_none() {
        return Err(ApiError::not_found("Диалог не найден"));
    }

    let before = query
        .get("before")
        .and_then(|s| s.parse::<chrono::DateTime<chrono::Utc>>().ok());
    let limit = parse_int(query.get("limit").map(String::as_str))
        .unwrap_or(50)
        .min(100);

    let messages = sqlx::query(
        "SELECT id, thread_id, sender_id, body, kind, created_at
           FROM dm_messages
          WHERE thread_id = $1 AND deleted_at IS NULL
            AND ($2::timestamptz IS NULL OR created_at < $2::timestamptz)
          ORDER BY created_at DESC
          LIMIT $3",
    )
    .bind(thread_id)
    .bind(before)
    .bind(limit as i32)
    .fetch_all(&state.db)
    .await?;

    sqlx::query(
        "INSERT INTO dm_thread_state (thread_id, user_id, last_read_at)
         VALUES ($1, $2, NOW())
         ON CONFLICT (thread_id, user_id) DO UPDATE SET last_read_at = NOW(), hidden_at = NULL",
    )
    .bind(thread_id)
    .bind(auth.id)
    .execute(&state.db)
    .await?;

    let mut msgs: Vec<Value> = messages.iter().map(pg_row_to_json).collect();
    msgs.reverse();

    ok_json(json!({
        "thread_id": thread_id,
        "has_more": messages.len() as i64 == limit,
        "messages": msgs,
    }))
}

async fn send_message(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(peer_id): Path<String>,
    Body(body): Body,
) -> ApiResult {
    let peer_uuid = match parse_user_id(&peer_id) {
        Some(id) => id,
        None => return Err(ApiError::bad_request("Некорректный получатель")),
    };

    if peer_uuid == auth.id {
        return Err(ApiError::bad_request("Себе писать нельзя"));
    }

    let body_text = body
        .get("body")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim();
    if body_text.is_empty() {
        return Err(ApiError::bad_request("Пустое сообщение"));
    }
    if body_text.chars().count() > DM_RULES.max_body_chars {
        return Err(ApiError::bad_request(format!(
            "Сообщение длиннее {} символов",
            DM_RULES.max_body_chars
        )));
    }

    let decision = state.limiter.hit(
        format!("dm:send:{}", auth.id),
        120,
        Duration::from_secs(3600),
    );
    if !decision.allowed {
        return Err(ApiError::new(
            StatusCode::TOO_MANY_REQUESTS,
            "Слишком много отправлений. Попробуй позже.",
        ));
    }

    let found = sqlx::query(
        "SELECT id FROM dm_threads
          WHERE (user_a = $1 AND user_b = $2) OR (user_a = $2 AND user_b = $1)",
    )
    .bind(auth.id)
    .bind(peer_uuid)
    .fetch_all(&state.db)
    .await?;

    let is_new_thread = found.is_empty();
    let thread_id = if is_new_thread {
        None
    } else {
        Some(found[0].try_get::<Uuid, _>("id")?)
    };

    let peer_replied = if let Some(thread_id) = thread_id {
        has_peer_reply(&state, thread_id, auth.id).await
    } else {
        false
    };

    let gate = check_dm_permission(&state, auth.id, peer_uuid, peer_replied).await;
    if !gate.ok {
        return Err(ApiError::new(
            StatusCode::from_u16(gate.status).unwrap_or(StatusCode::FORBIDDEN),
            gate.error.unwrap_or_else(|| "Отправка запрещена".into()),
        ));
    }

    let tenure = get_tenure(&state, auth.id).await;
    if tenure.is_none() {
        return Err(ApiError::unauthorized("Профиль не найден"));
    }
    let tenure = tenure.unwrap();

    if !is_staff(&tenure) {
        let (threads_today, messages_today) = get_dm_usage_today(&state, auth.id).await;
        if is_new_thread && threads_today >= DM_RULES.max_new_threads_per_day {
            return Err(ApiError::new(
                StatusCode::TOO_MANY_REQUESTS,
                format!(
                    "За сутки можно начать {} новых переписок.",
                    DM_RULES.max_new_threads_per_day
                ),
            ));
        }
        if messages_today >= DM_RULES.max_messages_per_day {
            return Err(ApiError::new(
                StatusCode::TOO_MANY_REQUESTS,
                format!(
                    "Дневной лимит сообщений ({}) исчерпан.",
                    DM_RULES.max_messages_per_day
                ),
            ));
        }
        if let Some(thread_id) = thread_id
            && !peer_replied
        {
            let wait = seconds_until_next_message(&state, thread_id, auth.id, &tenure).await;
            if wait > 0 {
                return Err(ApiError::new(
                    StatusCode::TOO_MANY_REQUESTS,
                    format!("Следующее сообщение можно через {wait} с."),
                ));
            }
        }
    }

    let thread_id = if let Some(thread_id) = thread_id {
        thread_id
    } else {
        ensure_thread(&state, auth.id, peer_uuid).await?
    };

    let inserted = sqlx::query(
        "INSERT INTO dm_messages (thread_id, sender_id, body)
         VALUES ($1, $2, $3)
         RETURNING id, thread_id, sender_id, body, kind, created_at",
    )
    .bind(thread_id)
    .bind(auth.id)
    .bind(body_text)
    .fetch_one(&state.db)
    .await?;

    sqlx::query("UPDATE dm_threads SET last_message_at = NOW() WHERE id = $1")
        .bind(thread_id)
        .execute(&state.db)
        .await?;

    sqlx::query(
        "INSERT INTO dm_thread_state (thread_id, user_id, last_read_at)
         VALUES ($1, $2, NOW())
         ON CONFLICT (thread_id, user_id) DO UPDATE SET last_read_at = NOW(), hidden_at = NULL",
    )
    .bind(thread_id)
    .bind(auth.id)
    .execute(&state.db)
    .await?;

    let message = pg_row_to_json(&inserted);
    let payload = json!({
        "thread_id": thread_id,
        "message": &message,
        "is_new_thread": is_new_thread,
    });

    state.emit_to_user(&auth.id.to_string(), "dm_message", payload.clone());
    state.emit_to_user(&peer_uuid.to_string(), "dm_message", payload);

    if let Err(err) = notify_peer_of_message(&state, thread_id, auth.id, peer_uuid, body_text).await
    {
        tracing::error!(error = %err, "dm push notification failed");
    }

    ok_created(json!({
        "thread_id": thread_id,
        "message": message,
    }))
}

async fn notify_peer_of_message(
    state: &Arc<AppState>,
    thread_id: Uuid,
    sender_id: Uuid,
    recipient_id: Uuid,
    body: &str,
) -> Result<(), ApiError> {
    let muted: Option<bool> = sqlx::query_scalar(
        "SELECT muted_at IS NOT NULL FROM dm_thread_state WHERE thread_id = $1 AND user_id = $2",
    )
    .bind(thread_id)
    .bind(recipient_id)
    .fetch_optional(&state.db)
    .await?;

    if muted.unwrap_or(false) {
        return Ok(());
    }

    let preview: String = body.chars().take(160).collect();
    create_notification(
        state,
        NewNotification {
            user_id: recipient_id,
            actor_id: Some(sender_id),
            kind: "dm_message",
            quest_id: None,
            review_id: None,
            payload: Some(json!({
                "thread_id": thread_id.to_string(),
                "preview": preview,
            })),
        },
    )
    .await;

    Ok(())
}

async fn mark_read(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(thread_id): Path<String>,
) -> ApiResult {
    let thread_id = parse_thread_id(&thread_id)?;
    let updated = sqlx::query(
        "INSERT INTO dm_thread_state (thread_id, user_id, last_read_at)
         SELECT $1, $2, NOW() FROM dm_threads WHERE id = $1 AND (user_a = $2 OR user_b = $2)
         ON CONFLICT (thread_id, user_id) DO UPDATE SET last_read_at = NOW()
         RETURNING thread_id",
    )
    .bind(thread_id)
    .bind(auth.id)
    .fetch_optional(&state.db)
    .await?;

    if updated.is_none() {
        return Err(ApiError::not_found("Диалог не найден"));
    }

    ok_json(json!({"success": true}))
}

async fn mute_thread(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(thread_id): Path<String>,
    Body(body): Body,
) -> ApiResult {
    let thread_id = parse_thread_id(&thread_id)?;
    let muted = body.get("muted").and_then(Value::as_bool) != Some(false);
    let muted_at: Option<chrono::DateTime<Utc>> = if muted { Some(Utc::now()) } else { None };

    let updated = sqlx::query(
        "INSERT INTO dm_thread_state (thread_id, user_id, muted_at)
         SELECT $1, $2, $3::timestamptz
           FROM dm_threads WHERE id = $1 AND (user_a = $2 OR user_b = $2)
         ON CONFLICT (thread_id, user_id) DO UPDATE SET muted_at = EXCLUDED.muted_at
         RETURNING thread_id",
    )
    .bind(thread_id)
    .bind(auth.id)
    .bind(muted_at)
    .fetch_optional(&state.db)
    .await?;

    if updated.is_none() {
        return Err(ApiError::not_found("Диалог не найден"));
    }

    ok_json(json!({"success": true, "muted": muted}))
}

async fn hide_thread(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(thread_id): Path<String>,
) -> ApiResult {
    let thread_id = parse_thread_id(&thread_id)?;
    let updated = sqlx::query(
        "INSERT INTO dm_thread_state (thread_id, user_id, hidden_at)
         SELECT $1, $2, NOW() FROM dm_threads WHERE id = $1 AND (user_a = $2 OR user_b = $2)
         ON CONFLICT (thread_id, user_id) DO UPDATE SET hidden_at = NOW()
         RETURNING thread_id",
    )
    .bind(thread_id)
    .bind(auth.id)
    .fetch_optional(&state.db)
    .await?;

    if updated.is_none() {
        return Err(ApiError::not_found("Диалог не найден"));
    }

    ok_json(json!({"success": true}))
}

async fn get_privacy(State(state): State<Arc<AppState>>, auth: AuthUser) -> ApiResult {
    let privacy = get_dm_privacy(&state, auth.id).await;
    ok_json(json!({
        "mode": privacy_mode_str(privacy.mode),
        "min_playtime_hours": crate::json::js_number(privacy.min_playtime_hours),
        "min_account_age_days": crate::json::js_number(privacy.min_account_age_days),
    }))
}

async fn put_privacy(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Body(body): Body,
) -> ApiResult {
    let mode = match body.get("mode").and_then(Value::as_str) {
        Some("everyone") => DmPrivacyMode::Everyone,
        Some("standing") => DmPrivacyMode::Standing,
        Some("following") => DmPrivacyMode::Following,
        Some("nobody") => DmPrivacyMode::Nobody,
        _ => return Err(ApiError::bad_request("Неизвестный режим")),
    };

    let hours = body
        .get("min_playtime_hours")
        .and_then(|v| v.as_f64())
        .unwrap_or(0.0);
    let days = body
        .get("min_account_age_days")
        .and_then(|v| v.as_f64())
        .unwrap_or(0.0);

    if hours > 1000.0 || days > 3650.0 {
        return Err(ApiError::bad_request("Слишком большой порог"));
    }

    fn clean(v: f64, max: f64) -> f64 {
        if v.is_finite() && v > 0.0 {
            v.floor().min(max)
        } else {
            0.0
        }
    }

    sqlx::query("UPDATE profiles SET dm_privacy = $2 WHERE id = $1")
        .bind(auth.id)
        .bind(json!({
            "mode": privacy_mode_str(mode),
            "min_playtime_hours": clean(hours, 1000.0),
            "min_account_age_days": clean(days, 3650.0),
        }))
        .execute(&state.db)
        .await?;

    ok_json(json!({"success": true}))
}

async fn list_blocks(State(state): State<Arc<AppState>>, auth: AuthUser) -> ApiResult {
    let rows = sqlx::query(
        "SELECT p.id, p.full_name, p.avatar_url, p.cosmetics, p.role, p.last_seen_at,
                b.created_at AS blocked_at
           FROM user_blocks b
           JOIN profiles p ON p.id = b.blocked_id
          WHERE b.user_id = $1
          ORDER BY b.created_at DESC",
    )
    .bind(auth.id)
    .fetch_all(&state.db)
    .await?;

    ok_json(json!({"blocked": rows_to_json(&rows)}))
}

async fn block_user(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(user_id): Path<String>,
) -> ApiResult {
    let target = match parse_user_id(&user_id) {
        Some(id) => id,
        None => return Err(ApiError::bad_request("Некорректный идентификатор")),
    };

    if target == auth.id {
        return Err(ApiError::bad_request("Себя заблокировать нельзя"));
    }

    let system_id = system_user_id();
    if system_id == Some(target) {
        return Err(ApiError::bad_request(
            "Аккаунт команды заблокировать нельзя",
        ));
    }

    sqlx::query(
        "INSERT INTO user_blocks (user_id, blocked_id) VALUES ($1, $2)
         ON CONFLICT DO NOTHING",
    )
    .bind(auth.id)
    .bind(target)
    .execute(&state.db)
    .await?;

    ok_json(json!({"success": true}))
}

async fn unblock_user(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Path(user_id): Path<String>,
) -> ApiResult {
    let target = match parse_user_id(&user_id) {
        Some(id) => id,
        None => return Err(ApiError::bad_request("Некорректный идентификатор")),
    };

    sqlx::query("DELETE FROM user_blocks WHERE user_id = $1 AND blocked_id = $2")
        .bind(auth.id)
        .bind(target)
        .execute(&state.db)
        .await?;

    ok_json(json!({"success": true}))
}

async fn get_system_thread(State(state): State<Arc<AppState>>, auth: AuthUser) -> ApiResult {
    let system_id = system_user_id().ok_or_else(|| ApiError::internal("system user id"))?;
    let thread_id = ensure_thread(&state, auth.id, system_id).await?;
    ok_json(json!({"thread_id": thread_id}))
}

async fn broadcast_system_news(
    State(state): State<Arc<AppState>>,
    auth: AuthUser,
    Body(body): Body,
) -> ApiResult {
    let body_text = body
        .get("body")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim();
    if body_text.is_empty() {
        return Err(ApiError::bad_request("Пустое сообщение"));
    }
    if body_text.chars().count() > DM_RULES.max_body_chars {
        return Err(ApiError::bad_request(format!(
            "Новость длиннее {} символов",
            DM_RULES.max_body_chars
        )));
    }

    let decision = state.limiter.hit(
        format!("dm:broadcast:{}", auth.id),
        10,
        Duration::from_secs(86400),
    );
    if !decision.allowed {
        return Err(ApiError::new(
            StatusCode::TOO_MANY_REQUESTS,
            "Too many requests",
        ));
    }

    let tenure = get_tenure(&state, auth.id).await;
    if tenure.as_ref().is_none_or(|t| !is_staff(t)) {
        return Err(ApiError::forbidden(
            "Новость команды может публиковать только админ",
        ));
    }

    let system_id = system_user_id().ok_or_else(|| ApiError::internal("system user id"))?;

    let user_count = sqlx::query("SELECT COUNT(*)::int AS n FROM profiles WHERE id <> $1::uuid")
        .bind(system_id)
        .fetch_one(&state.db)
        .await?;
    let count: i32 = user_count.try_get("n")?;
    let limit = (count as i64 + 10).min(50000);

    sqlx::query(
        "INSERT INTO dm_threads (user_a, user_b)
         SELECT $1::uuid, id FROM profiles WHERE id <> $1::uuid
         ORDER BY id LIMIT $2
         ON CONFLICT (user_a, user_b) DO NOTHING",
    )
    .bind(system_id)
    .bind(limit as i64)
    .execute(&state.db)
    .await?;

    let inserted = sqlx::query(
        "WITH peers AS (
            SELECT t.id AS thread_id, t.user_b AS user_id
              FROM dm_threads t
             WHERE t.user_a = $1::uuid AND t.user_b <> $2::uuid
         ), written AS (
            INSERT INTO dm_messages (thread_id, sender_id, body, kind)
            SELECT thread_id, $1::uuid, $3, 'news' FROM peers
            RETURNING 1
         )
         UPDATE dm_threads t SET last_message_at = NOW()
           FROM peers WHERE t.id = peers.thread_id
         RETURNING (SELECT COUNT(*) FROM written) AS delivered",
    )
    .bind(system_id)
    .bind(auth.id)
    .bind(body_text)
    .fetch_one(&state.db)
    .await?;
    let delivered: i64 = inserted.try_get("delivered")?;

    sqlx::query(
        "INSERT INTO notifications (user_id, actor_id, type, payload)
         SELECT t.user_b, $1::uuid, 'system_news', $3::jsonb
           FROM dm_threads t WHERE t.user_a = $1::uuid",
    )
    .bind(system_id)
    .bind(auth.id)
    .bind(json!({"title": "Новости Meander", "body": body_text}))
    .execute(&state.db)
    .await?;

    let recipients = sqlx::query("SELECT user_b FROM dm_threads WHERE user_a = $1")
        .bind(system_id)
        .fetch_all(&state.db)
        .await?;

    let payload = json!({
        "title": "Новости Meander",
        "body": body_text,
        "data": {"type": "system_news"},
    });

    for row in recipients {
        if let Ok(user_id) = row.try_get::<Uuid, _>("user_b") {
            state.emit_to_user(&user_id.to_string(), "new_notification", payload.clone());
        }
    }

    ok_json(json!({
        "success": true,
        "delivered": delivered,
    }))
}

fn privacy_mode_str(mode: DmPrivacyMode) -> &'static str {
    match mode {
        DmPrivacyMode::Everyone => "everyone",
        DmPrivacyMode::Standing => "standing",
        DmPrivacyMode::Following => "following",
        DmPrivacyMode::Nobody => "nobody",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_user_id_accepts_system_and_uuid() {
        assert!(is_user_id(SYSTEM_USER_ID));
        assert!(is_user_id("a1a2a3a4-a5a6-b7b8-c9c0-d1d2d3d4d5d6"));
        assert!(!is_user_id("not-a-uuid"));
        assert!(!is_user_id(""));
    }

    #[test]
    fn parse_user_id_returns_system_uuid_constant() {
        let id = parse_user_id(SYSTEM_USER_ID).unwrap();
        assert_eq!(id.to_string(), SYSTEM_USER_ID);
    }

    #[test]
    fn privacy_mode_str_round_trip() {
        assert_eq!(privacy_mode_str(DmPrivacyMode::Everyone), "everyone");
        assert_eq!(privacy_mode_str(DmPrivacyMode::Nobody), "nobody");
    }
}
