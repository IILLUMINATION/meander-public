//! System-chat mirror — port of `system_chat.ts`.
//!
//! Bell notifications stay as they are; the same event also becomes a message
//! in the team dialog, which is where people look to understand what happened
//! to their account. The text is the push body, so the two channels cannot tell
//! the story differently. DM privacy and cooldowns do not apply: the sender is
//! the service account itself.

use std::sync::Arc;

use serde_json::Value;
use uuid::Uuid;

use crate::services::fcm::build_push_from_notification;
use crate::services::gating::{DM_RULES, SYSTEM_USER_ID};
use crate::state::AppState;

pub async fn mirror_to_system_chat(
    state: &Arc<AppState>,
    user_ids: &[Uuid],
    actor_id: Option<Uuid>,
    kind: &str,
    payload: Option<&Value>,
) {
    // A team-news broadcast already exists in chats; a private message must not
    // leak into a third channel.
    if kind == "system_news" || kind == "dm_message" {
        return;
    }

    let system_id = match Uuid::parse_str(SYSTEM_USER_ID) {
        Ok(id) => id,
        Err(_) => return,
    };
    let mut recipients: Vec<Uuid> = Vec::new();
    for id in user_ids {
        if *id != system_id && !recipients.contains(id) {
            recipients.push(*id);
        }
    }
    if recipients.is_empty() {
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

    let Some(notice) = build_push_from_notification(kind, payload, actor_name.as_deref()) else {
        return;
    };
    let body: String = notice.body.chars().take(DM_RULES.max_body_chars).collect();

    if let Err(err) = sqlx::query(
        "WITH threads AS (
            INSERT INTO dm_threads (user_a, user_b)
            SELECT $1::uuid, u FROM (SELECT DISTINCT unnest($2::uuid[]) AS u) x WHERE u <> $1::uuid
            ON CONFLICT (user_a, user_b) DO UPDATE SET user_a = EXCLUDED.user_a
            RETURNING id, user_b
         ), written AS (
            INSERT INTO dm_messages (thread_id, sender_id, body, kind)
            SELECT id, $1::uuid, $3, $4 FROM threads
            RETURNING 1
         )
         UPDATE dm_threads t SET last_message_at = NOW()
           FROM threads WHERE t.id = threads.id",
    )
    .bind(system_id)
    .bind(&recipients)
    .bind(&body)
    .bind(kind)
    .execute(&state.db)
    .await
    {
        tracing::warn!(error = %err, "system chat mirror failed");
    }
}
