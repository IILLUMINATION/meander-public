//! Notifications: insert, push and the system-chat mirror — port of
//! `notifications.ts` and `system_chat.ts`.
//!
//! `create_notification` is intentionally forgiving: a modal notification must
//! never fail the request that caused it. Push and chat mirroring are spawned
//! as detached tasks, as in Node.

use std::sync::Arc;

use serde_json::{Map, Value, json};
use sqlx::PgConnection;
use uuid::Uuid;

use crate::services::fcm::{build_push_from_notification, send_push_to_user};
use crate::services::gating::{DM_RULES, SYSTEM_USER_ID};
use crate::services::system_chat::mirror_to_system_chat;
use crate::state::AppState;

#[derive(Debug, Clone)]
pub struct NewNotification<'a> {
    pub user_id: Uuid,
    pub actor_id: Option<Uuid>,
    pub kind: &'a str,
    pub quest_id: Option<Uuid>,
    pub review_id: Option<Uuid>,
    pub payload: Option<Value>,
}

const AUTHOR_EVENT_TYPES: [&str; 3] = ["quest_published", "quest_updated", "wall_post_new"];
const PUSH_DEBOUNCE_MINUTES: i64 = 5;
const QUIET_START_HOUR: u32 = 22;
const QUIET_END_HOUR: u32 = 8;

async fn author_muted(
    conn_or_pool: &AppState,
    user_id: Uuid,
    actor_id: Uuid,
    kind: &str,
    conn: Option<&mut PgConnection>,
) -> bool {
    if !AUTHOR_EVENT_TYPES.contains(&kind) {
        return false;
    }

    use sqlx::Row;
    let row = if let Some(conn) = conn {
        sqlx::query(
            "SELECT author_notifs_mode, author_notifs_exceptions FROM profiles WHERE id = $1",
        )
        .bind(user_id)
        .fetch_optional(&mut *conn)
        .await
    } else {
        sqlx::query(
            "SELECT author_notifs_mode, author_notifs_exceptions FROM profiles WHERE id = $1",
        )
        .bind(user_id)
        .fetch_optional(&conn_or_pool.db)
        .await
    };

    let Ok(Some(row)) = row else {
        return false;
    };
    let mode: Option<String> = row.try_get("author_notifs_mode").ok();
    let exceptions: Option<Vec<Uuid>> = row.try_get("author_notifs_exceptions").ok().flatten();
    let has_exception = exceptions.unwrap_or_default().contains(&actor_id);
    match mode.as_deref() {
        Some("all") if has_exception => true,
        Some("none") if !has_exception => true,
        _ => false,
    }
}

pub async fn create_notification(state: &Arc<AppState>, n: NewNotification<'_>) -> bool {
    // Node skips self-notifications before touching the database.
    if n.actor_id == Some(n.user_id) {
        return false;
    }
    if let Some(actor_id) = n.actor_id {
        if author_muted(state, n.user_id, actor_id, n.kind, None).await {
            return false;
        }
    }

    let inserted = sqlx::query(
        "INSERT INTO notifications
            (user_id, actor_id, type, quest_id, review_id, payload)
          VALUES ($1, $2, $3, $4, $5, $6)",
    )
    .bind(n.user_id)
    .bind(n.actor_id)
    .bind(n.kind)
    .bind(n.quest_id)
    .bind(n.review_id)
    .bind(n.payload.as_ref())
    .execute(&state.db)
    .await;

    if let Err(err) = inserted {
        tracing::error!(error = %err, "notification insert failed");
        return false;
    }

    let push_state = state.clone();
    let kind = n.kind.to_string();
    let payload = n.payload.clone();
    let actor_id = n.actor_id;
    let quest_id = n.quest_id;
    let review_id = n.review_id;
    let user_id = n.user_id;
    tokio::spawn(async move {
        send_push_for_notification(
            &push_state,
            user_id,
            actor_id,
            &kind,
            payload,
            quest_id,
            review_id,
        )
        .await;
    });

    let chat_state = state.clone();
    let chat_kind = n.kind.to_string();
    let chat_payload = n.payload.clone();
    tokio::spawn(async move {
        mirror_to_system_chat(
            &chat_state,
            &[user_id],
            actor_id,
            &chat_kind,
            chat_payload.as_ref(),
        )
        .await;
    });

    true
}

/// Same insert inside a caller's transaction.
pub async fn create_notification_tx(
    state: &Arc<AppState>,
    conn: &mut PgConnection,
    n: NewNotification<'_>,
) -> bool {
    if n.actor_id == Some(n.user_id) {
        return false;
    }
    if let Some(actor_id) = n.actor_id {
        if author_muted(state, n.user_id, actor_id, n.kind, Some(&mut *conn)).await {
            return false;
        }
    }

    let inserted = sqlx::query(
        "INSERT INTO notifications
            (user_id, actor_id, type, quest_id, review_id, payload)
          VALUES ($1, $2, $3, $4, $5, $6)",
    )
    .bind(n.user_id)
    .bind(n.actor_id)
    .bind(n.kind)
    .bind(n.quest_id)
    .bind(n.review_id)
    .bind(n.payload.as_ref())
    .execute(&mut *conn)
    .await;

    if let Err(err) = inserted {
        tracing::error!(error = %err, "notification insert failed in transaction");
        return false;
    }

    let push_state = state.clone();
    let kind = n.kind.to_string();
    let payload = n.payload.clone();
    let actor_id = n.actor_id;
    let quest_id = n.quest_id;
    let review_id = n.review_id;
    let user_id = n.user_id;
    tokio::spawn(async move {
        send_push_for_notification(
            &push_state,
            user_id,
            actor_id,
            &kind,
            payload,
            quest_id,
            review_id,
        )
        .await;
    });

    let chat_state = state.clone();
    let chat_kind = n.kind.to_string();
    let chat_payload = n.payload.clone();
    tokio::spawn(async move {
        mirror_to_system_chat(
            &chat_state,
            &[user_id],
            actor_id,
            &chat_kind,
            chat_payload.as_ref(),
        )
        .await;
    });

    true
}

pub async fn create_bulk_notifications(
    state: &Arc<AppState>,
    user_ids: &[Uuid],
    actor_id: Option<Uuid>,
    kind: &str,
    quest_id: Option<Uuid>,
    review_id: Option<Uuid>,
    payload: Option<Value>,
) -> u64 {
    let Ok(mut conn) = state.db.acquire().await else {
        return 0;
    };
    create_bulk_notifications_with_conn(
        state, &mut conn, user_ids, actor_id, kind, quest_id, review_id, payload,
    )
    .await
}

/// Same insert as [`create_bulk_notifications`], but inside the caller's
/// transaction. `POST /quests` must write follower notifications before the
/// quest row is committed, exactly like Node passing its `PoolClient`.
pub async fn create_bulk_notifications_tx(
    state: &Arc<AppState>,
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    user_ids: &[Uuid],
    actor_id: Option<Uuid>,
    kind: &str,
    quest_id: Option<Uuid>,
    review_id: Option<Uuid>,
    payload: Option<Value>,
) -> u64 {
    create_bulk_notifications_with_conn(
        state, &mut *tx, user_ids, actor_id, kind, quest_id, review_id, payload,
    )
    .await
}

#[allow(clippy::too_many_arguments)]
async fn create_bulk_notifications_with_conn(
    state: &Arc<AppState>,
    conn: &mut PgConnection,
    user_ids: &[Uuid],
    actor_id: Option<Uuid>,
    kind: &str,
    quest_id: Option<Uuid>,
    review_id: Option<Uuid>,
    payload: Option<Value>,
) -> u64 {
    let mut recipients: Vec<Uuid> = Vec::new();
    for id in user_ids {
        if actor_id == Some(*id) {
            continue;
        }
        if !recipients.contains(id) {
            recipients.push(*id);
        }
    }
    if recipients.is_empty() {
        return 0;
    }

    if let Some(actor_id) = actor_id {
        if AUTHOR_EVENT_TYPES.contains(&kind) {
            use sqlx::Row;
            let rows = sqlx::query(
                "SELECT id, author_notifs_mode, author_notifs_exceptions
                   FROM profiles WHERE id = ANY($1)",
            )
            .bind(&recipients)
            .fetch_all(&mut *conn)
            .await
            .unwrap_or_default();

            recipients.retain(|user_id| {
                let Some(row) = rows
                    .iter()
                    .find(|r| r.try_get::<Uuid, _>("id").ok().as_ref() == Some(user_id))
                else {
                    return true;
                };
                let mode: Option<String> = row.try_get("author_notifs_mode").ok();
                let exceptions: Vec<Uuid> = row
                    .try_get::<Option<Vec<Uuid>>, _>("author_notifs_exceptions")
                    .ok()
                    .flatten()
                    .unwrap_or_default();
                let has_exception = exceptions.contains(&actor_id);
                let mode = mode.unwrap_or_else(|| "all".into());
                !((mode == "all" && has_exception) || (mode == "none" && !has_exception))
            });
        }
    }
    if recipients.is_empty() {
        return 0;
    }

    let result = sqlx::query(
        "INSERT INTO notifications (user_id, actor_id, type, quest_id, review_id, payload)
         SELECT unnest($1::uuid[]), $2, $3, $4, $5, $6",
    )
    .bind(&recipients)
    .bind(actor_id)
    .bind(kind)
    .bind(quest_id)
    .bind(review_id)
    .bind(payload.as_ref())
    .execute(&mut *conn)
    .await;

    if let Err(err) = result {
        tracing::error!(error = %err, "bulk notification insert failed");
        return 0;
    }

    for user_id in &recipients {
        let state = state.clone();
        let kind = kind.to_string();
        let payload = payload.clone();
        let user_id = *user_id;
        tokio::spawn(async move {
            send_push_for_notification(
                &state, user_id, actor_id, &kind, payload, quest_id, review_id,
            )
            .await;
        });
    }

    let count = recipients.len() as u64;
    let chat_state = state.clone();
    let chat_kind = kind.to_string();
    let chat_payload = payload.clone();
    let chat_recipients = recipients.clone();
    tokio::spawn(async move {
        mirror_to_system_chat(
            &chat_state,
            &chat_recipients,
            actor_id,
            &chat_kind,
            chat_payload.as_ref(),
        )
        .await;
    });

    count
}

async fn is_quiet_hours(state: &AppState, user_id: Uuid) -> bool {
    use sqlx::Row;
    let row =
        sqlx::query("SELECT quiet_hours_enabled, timezone_offset FROM profiles WHERE id = $1")
            .bind(user_id)
            .fetch_optional(&state.db)
            .await;
    let Ok(Some(row)) = row else {
        return false;
    };
    let enabled: Option<bool> = row.try_get("quiet_hours_enabled").ok().flatten();
    let offset: Option<i32> = row.try_get("timezone_offset").ok().flatten();
    if enabled != Some(true) {
        return false;
    }
    let Some(offset) = offset else {
        return false;
    };
    let now = chrono::Utc::now();
    let user_hour = ((now.timestamp() + i64::from(offset) * 60).rem_euclid(86400) / 3600) as u32;
    user_hour >= QUIET_START_HOUR || user_hour < QUIET_END_HOUR
}

/// Resolves the actor name, debounces, checks quiet hours, then emits the
/// socket event and the push. Never throws.
async fn send_push_for_notification(
    state: &Arc<AppState>,
    user_id: Uuid,
    actor_id: Option<Uuid>,
    kind: &str,
    payload: Option<Value>,
    quest_id: Option<Uuid>,
    review_id: Option<Uuid>,
) {
    // The insert just happened, so more than one row means a recent duplicate.
    let recent: Option<i32> = sqlx::query_scalar(
        "SELECT 1 FROM notifications
          WHERE user_id = $1 AND actor_id IS NOT DISTINCT FROM $2 AND type = $3
            AND created_at > NOW() - make_interval(mins => $4)
          LIMIT 2 OFFSET 1",
    )
    .bind(user_id)
    .bind(actor_id)
    .bind(kind)
    .bind(PUSH_DEBOUNCE_MINUTES)
    .fetch_optional(&state.db)
    .await
    .ok()
    .flatten();
    if recent.is_some() {
        tracing::debug!(%user_id, kind, "[FCM] debounced push");
        return;
    }

    if is_quiet_hours(state, user_id).await {
        tracing::debug!(%user_id, "[FCM] quiet hours — push skipped");
        return;
    }

    let actor_name: Option<String> = match actor_id {
        Some(actor_id) => sqlx::query_scalar("SELECT full_name FROM profiles WHERE id = $1")
            .bind(actor_id)
            .fetch_optional(&state.db)
            .await
            .ok()
            .flatten()
            .filter(|name: &String| !name.is_empty()),
        None => None,
    };

    let Some(push) = build_push_from_notification(kind, payload.as_ref(), actor_name.as_deref())
    else {
        return;
    };

    // Deep-link payload consumed by the Flutter client.
    let mut data = Map::new();
    data.insert("type".into(), Value::String(kind.to_string()));
    if let Some(actor_id) = actor_id {
        data.insert("actorId".into(), Value::String(actor_id.to_string()));
    }
    let quest_from_payload = payload
        .as_ref()
        .and_then(|p| p.get("questId"))
        .and_then(Value::as_str)
        .map(str::to_string);
    if let Some(q) = quest_from_payload.or_else(|| quest_id.map(|q| q.to_string())) {
        data.insert("questId".into(), Value::String(q));
    }
    if let Some(post_id) = payload
        .as_ref()
        .and_then(|p| p.get("postId"))
        .and_then(Value::as_str)
    {
        data.insert("postId".into(), Value::String(post_id.into()));
    }
    if let Some(slug) = payload.as_ref().and_then(|p| p.get("forum_slug")).map(|v| {
        v.as_str()
            .map(str::to_string)
            .unwrap_or_else(|| v.to_string())
    }) {
        data.insert("forumSlug".into(), Value::String(slug));
    }
    let review_from_payload = payload
        .as_ref()
        .and_then(|p| p.get("reviewId"))
        .and_then(Value::as_str)
        .map(str::to_string);
    if let Some(r) = review_from_payload.or_else(|| review_id.map(|r| r.to_string())) {
        data.insert("reviewId".into(), Value::String(r));
    }

    state.emit_to_user(
        &user_id.to_string(),
        "new_notification",
        json!({"title": push.title, "body": push.body, "data": Value::Object(data.clone())}),
    );

    let data_value = Value::Object(data);
    send_push_to_user(state, user_id, &push, Some(data_value)).await;
}

/// Amount of characters a mirrored DM body may carry.
pub fn system_chat_body_limit() -> usize {
    DM_RULES.max_body_chars
}

/// Ensures the system user id parses; used by routes that compare ids.
pub fn system_user_id() -> Option<Uuid> {
    Uuid::parse_str(SYSTEM_USER_ID).ok()
}
