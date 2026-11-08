//! Push notifications via Firebase Cloud Messaging (HTTP v1).
//!
//! `firebase-admin` is replaced by two small pieces: an OAuth2 service-account
//! grant (RS256 JWT → access token, cached until shortly before expiry) and a
//! single `messages:send` call. Missing credentials are not fatal — pushes are
//! best-effort, exactly as in the Node backend.

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use serde::Deserialize;
use serde_json::{Value, json};
use tokio::sync::RwLock;
use uuid::Uuid;

use crate::state::AppState;

const FCM_SCOPE: &str = "https://www.googleapis.com/auth/firebase.messaging";
const TOKEN_ENDPOINT: &str = "https://oauth2.googleapis.com/token";

#[derive(Default)]
pub struct FcmCache {
    access: RwLock<Option<(String, Instant)>>,
    warned: AtomicBool,
}

#[derive(Debug, Deserialize)]
struct ServiceAccount {
    project_id: String,
    client_email: String,
    private_key: String,
}

#[derive(Debug, Clone)]
pub struct PushMessage {
    pub title: String,
    pub body: String,
}

fn credentials_path(state: &AppState) -> Option<PathBuf> {
    if let Some(path) = state.cfg.firebase_credentials.clone() {
        return Some(path);
    }
    let candidates = [
        "meander-39f48-firebase-adminsdk-fbsvc-aa87191011.json",
        "backend/meander-39f48-firebase-adminsdk-fbsvc-aa87191011.json",
        "../meander-39f48-firebase-adminsdk-fbsvc-aa87191011.json",
    ];
    candidates.iter().map(PathBuf::from).find(|p| p.exists())
}

async fn access_token(state: &AppState, account: &ServiceAccount) -> Option<String> {
    if let Some((token, expires)) = state.fcm.access.read().await.as_ref() {
        if Instant::now() < *expires {
            return Some(token.clone());
        }
    }

    let now = chrono::Utc::now().timestamp();
    let claims = json!({
        "iss": account.client_email,
        "scope": FCM_SCOPE,
        "aud": TOKEN_ENDPOINT,
        "iat": now,
        "exp": now + 3600,
    });
    let key = jsonwebtoken::EncodingKey::from_rsa_pem(account.private_key.as_bytes()).ok()?;
    let assertion = jsonwebtoken::encode(
        &jsonwebtoken::Header::new(jsonwebtoken::Algorithm::RS256),
        &claims,
        &key,
    )
    .ok()?;

    let response = state
        .http
        .post(TOKEN_ENDPOINT)
        .form(&[
            ("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer"),
            ("assertion", assertion.as_str()),
        ])
        .send()
        .await
        .ok()?
        .error_for_status()
        .ok()?;
    let body: Value = response.json().await.ok()?;
    let token = body.get("access_token")?.as_str()?.to_string();
    let ttl = body
        .get("expires_in")
        .and_then(Value::as_i64)
        .unwrap_or(3600)
        .max(120);
    *state.fcm.access.write().await = Some((
        token.clone(),
        Instant::now() + Duration::from_secs((ttl - 60) as u64),
    ));
    Some(token)
}

fn load_account(state: &AppState) -> Option<ServiceAccount> {
    let path = credentials_path(state);
    let Some(path) = path else {
        if !state.fcm.warned.swap(true, Ordering::Relaxed) {
            tracing::warn!("[FCM] no service-account JSON found — pushes are disabled");
        }
        return None;
    };
    match std::fs::read_to_string(&path)
        .ok()
        .and_then(|raw| serde_json::from_str::<ServiceAccount>(&raw).ok())
    {
        Some(account) => Some(account),
        None => {
            if !state.fcm.warned.swap(true, Ordering::Relaxed) {
                tracing::warn!(path = %path.display(), "[FCM] credentials are unreadable — pushes are disabled");
            }
            None
        }
    }
}

pub fn ensure_initialized(state: &AppState) -> bool {
    load_account(state).is_some()
}

/// Sends a push to the user's stored device token. Returns false when skipped.
pub async fn send_push_to_user(
    state: &Arc<AppState>,
    user_id: Uuid,
    message: &PushMessage,
    data: Option<Value>,
) -> bool {
    let Some(account) = load_account(state) else {
        return false;
    };

    let token: Option<Option<String>> =
        sqlx::query_scalar("SELECT fcm_token FROM profiles WHERE id = $1")
            .bind(user_id)
            .fetch_optional(&state.db)
            .await
            .ok();
    let Some(fcm_token) = token.flatten() else {
        tracing::debug!(%user_id, "[FCM] no device token");
        return false;
    };

    let Some(access) = access_token(state, &account).await else {
        tracing::warn!("[FCM] could not obtain an access token");
        return false;
    };

    let payload = json!({
        "message": {
            "token": fcm_token,
            "notification": { "title": message.title, "body": message.body },
            "data": data.unwrap_or_else(|| json!({})),
            "android": {
                "priority": "high",
                "notification": { "channelId": "meander_notifications", "sound": "default" }
            }
        }
    });

    let url = format!(
        "https://fcm.googleapis.com/v1/projects/{}/messages:send",
        account.project_id
    );
    match state
        .http
        .post(url)
        .bearer_auth(access)
        .json(&payload)
        .send()
        .await
    {
        Ok(response) if response.status().is_success() => {
            tracing::info!(%user_id, title = %message.title, "[FCM] push sent");
            true
        }
        Ok(response) => {
            let status = response.status();
            let body = response.text().await.unwrap_or_default();
            // An unregistered device token is cleared so the next send works.
            if body.contains("UNREGISTERED") || body.contains("INVALID_ARGUMENT") {
                let _ = sqlx::query("UPDATE profiles SET fcm_token = NULL WHERE id = $1")
                    .bind(user_id)
                    .execute(&state.db)
                    .await;
                tracing::info!(%user_id, "[FCM] stale token cleared");
            } else {
                tracing::warn!(%user_id, %status, body = %body, "[FCM] send failed");
            }
            false
        }
        Err(err) => {
            tracing::warn!(error = %err, "[FCM] send request failed");
            false
        }
    }
}

/// The in-app notification types that also trigger a push, with their texts.
pub fn build_push_from_notification(
    notification_type: &str,
    payload: Option<&Value>,
    actor_name: Option<&str>,
) -> Option<PushMessage> {
    // JS checks `actorName ? ... : ...`, so an empty full_name is "unknown".
    let actor_name = actor_name.filter(|name| !name.is_empty());
    let title_of = |v: Option<&Value>| {
        v.and_then(|p| p.get("title"))
            .and_then(Value::as_str)
            .map(str::to_string)
    };
    let build = |title: &str, body: String| {
        Some(PushMessage {
            title: title.to_string(),
            body,
        })
    };

    match notification_type {
        "quest_like" => build(
            "Новый лайк ❤️",
            match actor_name {
                Some(name) => format!("{name} оценил(а) ваш квест"),
                None => "Кому-то понравился ваш квест".into(),
            },
        ),
        "quest_review" => build(
            "Новый отзыв 📝",
            match actor_name {
                Some(name) => format!("{name} оставил(а) отзыв на ваш квест"),
                None => "Новый отзыв на ваш квест".into(),
            },
        ),
        "quest_published" => {
            let quest_title = title_of(payload);
            build(
                "📚 Новый квест",
                match (actor_name, quest_title.as_deref()) {
                    (Some(name), Some(q)) => format!("{name} опубликовал(а) квест «{q}»"),
                    (Some(name), None) => format!("{name} опубликовал(а) новый квест"),
                    (None, Some(q)) => format!("Вышел новый квест «{q}»"),
                    (None, None) => "Вышел новый квест от автора, на которого вы подписаны".into(),
                },
            )
        }
        "quest_updated" => {
            let quest_title = title_of(payload);
            build(
                "🔄 Обновление квеста",
                match (actor_name, quest_title.as_deref()) {
                    (Some(name), Some(q)) => format!("{name} обновил(а) квест «{q}»"),
                    (Some(name), None) => format!("{name} обновил(а) квест"),
                    (None, Some(q)) => format!("Обновился квест «{q}»"),
                    (None, None) => "Обновился квест".into(),
                },
            )
        }
        "quest_approved" => {
            let quest_title = title_of(payload);
            build(
                "🎉 Квест опубликован!",
                match quest_title.as_deref() {
                    Some(q) => format!("Ваш квест \"{q}\" прошёл модерацию!"),
                    None => "Ваш квест прошёл модерацию".into(),
                },
            )
        }
        "quest_rejected" => {
            let quest_title = title_of(payload);
            build(
                "Квест отклонён",
                match quest_title.as_deref() {
                    Some(q) => {
                        format!("Модератор отклонил квест \"{q}\" — причина в «Мои публикации»")
                    }
                    None => "Модератор отклонил ваш квест, причина в «Мои публикации»".into(),
                },
            )
        }
        "user_follow" => build(
            "Новый подписчик 👋",
            match actor_name {
                Some(name) => format!("{name} подписался(ась) на вас"),
                None => "У вас новый подписчик".into(),
            },
        ),
        "wall_post_new" => build(
            "Новый пост 📰",
            match actor_name {
                Some(name) => format!("{name} опубликовал(а) новый пост"),
                None => "Новый пост от автора".into(),
            },
        ),
        "wall_post_like" => build(
            "Новый лайк на пост ❤️",
            match actor_name {
                Some(name) => format!("{name} оценил(а) ваш пост"),
                None => "Кому-то понравился ваш пост".into(),
            },
        ),
        "wall_post_comment" => build(
            "Новый комментарий 💬",
            match actor_name {
                Some(name) => format!("{name} прокомментировал(а) ваш пост"),
                None => "У вашего поста новый комментарий".into(),
            },
        ),
        "review_reply" => build(
            "Ответ разработчика 💬",
            match actor_name {
                Some(name) => format!("{name} ответил(а) на ваш отзыв"),
                None => "Автор ответил на ваш отзыв".into(),
            },
        ),
        "dm_message" => {
            let preview: String = payload
                .and_then(|p| p.get("preview"))
                .map(|v| v.as_str().unwrap_or(&v.to_string()).to_string())
                .unwrap_or_default()
                .chars()
                .take(90)
                .collect();
            let body = if preview.is_empty() {
                format!("{}: личное сообщение", actor_name.unwrap_or("Кто-то"))
            } else if let Some(name) = actor_name {
                format!("{name}: {preview}")
            } else {
                preview
            };
            build("Новое сообщение", body)
        }
        "forum_ban" => {
            let forum = payload.and_then(|p| p.get("forum")).and_then(Value::as_str);
            build(
                "Ограничение в сообществе",
                match forum {
                    Some(forum) => format!("В сообществе «{forum}» вам закрыли публикации"),
                    None => "В одном из сообществ вам закрыли публикации".into(),
                },
            )
        }
        "forum_topic_removed" => {
            let forum = payload.and_then(|p| p.get("forum")).and_then(Value::as_str);
            build(
                "Топик удалён",
                match forum {
                    Some(forum) => format!("Модератор сообщества «{forum}» удалил ваш топик"),
                    None => "Модератор сообщества удалил ваш топик".into(),
                },
            )
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn push_texts_match_node() {
        let m = build_push_from_notification("quest_like", None, Some("Аня")).unwrap();
        assert_eq!(m.title, "Новый лайк ❤️");
        assert_eq!(m.body, "Аня оценил(а) ваш квест");

        let m =
            build_push_from_notification("quest_published", Some(&json!({"title": "Тени"})), None)
                .unwrap();
        assert_eq!(m.body, "Вышел новый квест «Тени»");

        assert!(build_push_from_notification("unknown_type", None, None).is_none());
    }

    #[test]
    fn dm_preview_is_capped() {
        let long = "x".repeat(300);
        let m = build_push_from_notification(
            "dm_message",
            Some(&json!({"preview": long})),
            Some("Боб"),
        )
        .unwrap();
        assert!(m.body.chars().count() <= "Боб: ".len() + 90);
    }
}
