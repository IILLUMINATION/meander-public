//! Access rules for direct messages, forums and karma — port of `gating.ts`.
//!
//! All thresholds live here rather than in routes: two routes counting tenure
//! differently is a hole, not a typo.

use serde_json::Value;
use uuid::Uuid;

use crate::state::AppState;

/// Team service account; the system chat is an ordinary DM with it.
pub const SYSTEM_USER_ID: &str = "00000000-0000-0000-0000-000000000001";

pub struct DmRules {
    pub min_account_age_days_for_new_thread: f64,
    pub min_playtime_hours_for_new_thread: f64,
    pub max_new_threads_per_day: i64,
    pub max_messages_per_day: i64,
    pub message_cooldown_sec: i64,
    pub max_body_chars: usize,
}

pub const DM_RULES: DmRules = DmRules {
    min_account_age_days_for_new_thread: 3.0,
    min_playtime_hours_for_new_thread: 1.0,
    max_new_threads_per_day: 20,
    max_messages_per_day: 200,
    message_cooldown_sec: 60,
    max_body_chars: 2000,
};

pub struct Standing {
    pub followers: i64,
    pub published: i64,
    pub reviews: i64,
    pub streak_days: i64,
    pub playtime_hours: f64,
}

const STANDING: Standing = Standing {
    followers: 5,
    published: 1,
    reviews: 3,
    streak_days: 5,
    playtime_hours: 3.0,
};

#[derive(Debug, Clone)]
pub struct Tenure {
    pub role: String,
    pub account_age_days: f64,
    pub playtime_hours: f64,
    pub followers: i64,
    pub published: i64,
    pub reviews: i64,
    pub streak: i64,
    pub is_blocked: bool,
}

pub async fn get_tenure(state: &AppState, user_id: Uuid) -> Option<Tenure> {
    use sqlx::Row;
    let row = sqlx::query(
        "SELECT
            p.role,
            p.is_blocked,
            (EXTRACT(EPOCH FROM (NOW() - p.created_at)) / 86400)::float8 AS account_age_days,
            (COALESCE(p.total_playtime_seconds, 0) / 3600.0)::float8 AS playtime_hours,
            COALESCE(p.streak_count, 0) AS streak_count,
            (SELECT COUNT(*)::int FROM user_followers f WHERE f.user_id = p.id) AS followers,
            (SELECT COUNT(*)::int FROM quests q
              WHERE q.author_id = p.id AND q.status = 'published') AS published,
            (SELECT COUNT(*)::int FROM reviews r WHERE r.author_id = p.id) AS reviews
           FROM profiles p WHERE p.id = $1",
    )
    .bind(user_id)
    .fetch_optional(&state.db)
    .await
    .ok()
    .flatten()?;

    Some(Tenure {
        role: row
            .try_get::<Option<String>, _>("role")
            .ok()
            .flatten()
            .unwrap_or_else(|| "user".into()),
        account_age_days: row
            .try_get::<Option<f64>, _>("account_age_days")
            .ok()
            .flatten()
            .unwrap_or(0.0),
        playtime_hours: row
            .try_get::<Option<f64>, _>("playtime_hours")
            .ok()
            .flatten()
            .unwrap_or(0.0),
        followers: row
            .try_get::<Option<i32>, _>("followers")
            .ok()
            .flatten()
            .unwrap_or(0) as i64,
        published: row
            .try_get::<Option<i32>, _>("published")
            .ok()
            .flatten()
            .unwrap_or(0) as i64,
        reviews: row
            .try_get::<Option<i32>, _>("reviews")
            .ok()
            .flatten()
            .unwrap_or(0) as i64,
        streak: row
            .try_get::<Option<i32>, _>("streak_count")
            .ok()
            .flatten()
            .unwrap_or(0) as i64,
        is_blocked: row
            .try_get::<Option<bool>, _>("is_blocked")
            .ok()
            .flatten()
            .unwrap_or(false),
    })
}

pub fn is_staff(tenure: &Tenure) -> bool {
    tenure.role == "admin" || tenure.role == "moderator"
}

pub fn has_community_standing(tenure: &Tenure) -> bool {
    tenure.followers >= STANDING.followers
        || tenure.published >= STANDING.published
        || tenure.reviews >= STANDING.reviews
        || tenure.streak >= STANDING.streak_days
        || tenure.playtime_hours >= STANDING.playtime_hours
}

pub struct ForumRules {
    pub min_account_age_days_to_create: f64,
    pub max_created_by_day: i64,
    pub max_name_chars: usize,
    pub max_description_chars: usize,
    pub max_title_chars: usize,
    pub max_body_chars: usize,
}

pub const FORUM_RULES: ForumRules = ForumRules {
    min_account_age_days_to_create: 7.0,
    max_created_by_day: 2,
    max_name_chars: 60,
    max_description_chars: 600,
    max_title_chars: 200,
    max_body_chars: 8000,
};

#[derive(Debug, Clone, Copy)]
pub struct KarmaLimits {
    pub karma: i64,
    pub post_cooldown_min: i64,
    pub comment_cooldown_sec: i64,
}

pub async fn get_karma_and_limits(state: &AppState, user_id: Uuid) -> KarmaLimits {
    use sqlx::Row;
    let profile = sqlx::query("SELECT role, is_verified FROM profiles WHERE id = $1")
        .bind(user_id)
        .fetch_optional(&state.db)
        .await
        .ok()
        .flatten();
    let Some(profile) = profile else {
        return KarmaLimits {
            karma: 0,
            post_cooldown_min: 30,
            comment_cooldown_sec: 10,
        };
    };
    let role: Option<String> = profile.try_get("role").ok();
    let verified: Option<bool> = profile.try_get("is_verified").ok().flatten();
    if role.as_deref() == Some("admin") || verified == Some(true) {
        return KarmaLimits {
            karma: 9999,
            post_cooldown_min: 0,
            comment_cooldown_sec: 0,
        };
    }

    let followers: i64 =
        sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM user_followers WHERE user_id = $1")
            .bind(user_id)
            .fetch_one(&state.db)
            .await
            .unwrap_or(0);
    let likes: i64 = sqlx::query_scalar::<_, i64>(
        "SELECT COALESCE(SUM(like_count), 0)::bigint FROM quests WHERE author_id = $1",
    )
    .bind(user_id)
    .fetch_one(&state.db)
    .await
    .unwrap_or(0);

    let karma = followers * 2 + likes;
    let post_cooldown_min = if karma >= 50 {
        1
    } else if karma >= 10 {
        10
    } else {
        30
    };
    KarmaLimits {
        karma,
        post_cooldown_min,
        comment_cooldown_sec: if karma >= 5 { 0 } else { 10 },
    }
}

pub fn can_create_forum(tenure: &Tenure) -> bool {
    is_staff(tenure)
        || tenure.account_age_days >= FORUM_RULES.min_account_age_days_to_create
        || tenure.published >= STANDING.published
}

pub async fn get_forums_created_by_day(state: &AppState, user_id: Uuid) -> i64 {
    sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*)::bigint FROM forums
          WHERE creator_id = $1 AND created_at > date_trunc('day', NOW())",
    )
    .bind(user_id)
    .fetch_one(&state.db)
    .await
    .unwrap_or(0)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DmPrivacyMode {
    Everyone,
    Standing,
    Following,
    Nobody,
}

impl DmPrivacyMode {
    fn parse(raw: Option<&str>) -> Self {
        match raw {
            Some("standing") => Self::Standing,
            Some("following") => Self::Following,
            Some("nobody") => Self::Nobody,
            _ => Self::Everyone,
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub struct DmPrivacy {
    pub mode: DmPrivacyMode,
    pub min_playtime_hours: f64,
    pub min_account_age_days: f64,
}

pub async fn get_dm_privacy(state: &AppState, user_id: Uuid) -> DmPrivacy {
    let raw: Option<Value> =
        sqlx::query_scalar("SELECT dm_privacy FROM profiles WHERE id = $1 AND id <> $2")
            .bind(user_id)
            .bind(Uuid::parse_str(SYSTEM_USER_ID).ok())
            .fetch_optional(&state.db)
            .await
            .ok()
            .flatten();

    let raw = raw.unwrap_or(Value::Null);
    let num = |key: &str, max: f64| -> f64 {
        match raw.get(key).and_then(Value::as_f64) {
            Some(n) if n.is_finite() && n > 0.0 => n.min(max),
            _ => 0.0,
        }
    };
    DmPrivacy {
        mode: DmPrivacyMode::parse(raw.get("mode").and_then(Value::as_str)),
        min_playtime_hours: num("min_playtime_hours", 1000.0),
        min_account_age_days: num("min_account_age_days", 3650.0),
    }
}

async fn is_blocked_either_way(state: &AppState, a: Uuid, b: Uuid) -> bool {
    sqlx::query_scalar::<_, i32>(
        "SELECT 1 FROM user_blocks
          WHERE (user_id = $1 AND blocked_id = $2)
             OR (user_id = $2 AND blocked_id = $1)
          LIMIT 1",
    )
    .bind(a)
    .bind(b)
    .fetch_optional(&state.db)
    .await
    .ok()
    .flatten()
    .is_some()
}

async fn is_following(state: &AppState, followed_id: Uuid, follower_id: Uuid) -> bool {
    sqlx::query_scalar::<_, i32>(
        "SELECT 1 FROM user_followers WHERE user_id = $1 AND follower_id = $2 LIMIT 1",
    )
    .bind(followed_id)
    .bind(follower_id)
    .fetch_optional(&state.db)
    .await
    .ok()
    .flatten()
    .is_some()
}

#[derive(Debug, Clone)]
pub struct Gate {
    pub ok: bool,
    pub status: u16,
    pub error: Option<String>,
}

fn deny(status: u16, error: impl Into<String>) -> Gate {
    Gate {
        ok: false,
        status,
        error: Some(error.into()),
    }
}

pub async fn has_peer_reply(state: &AppState, thread_id: Uuid, me: Uuid) -> bool {
    sqlx::query_scalar::<_, i32>(
        "SELECT 1 FROM dm_messages
          WHERE thread_id = $1 AND sender_id <> $2 AND deleted_at IS NULL
          LIMIT 1",
    )
    .bind(thread_id)
    .bind(me)
    .fetch_optional(&state.db)
    .await
    .ok()
    .flatten()
    .is_some()
}

/// Checks run in this order on purpose: a block or a closed inbox is a refusal
/// without discussion, and all thresholds disappear once the recipient replied.
pub async fn check_dm_permission(
    state: &AppState,
    sender_id: Uuid,
    recipient_id: Uuid,
    peer_replied: bool,
) -> Gate {
    if recipient_id.to_string() == SYSTEM_USER_ID {
        return deny(403, "Это аккаунт команды — он не читает личные сообщения.");
    }
    if is_blocked_either_way(state, sender_id, recipient_id).await {
        return deny(403, "Вы не можете писать друг другу.");
    }

    let (sender, recipient) = tokio::join!(
        get_tenure(state, sender_id),
        get_tenure(state, recipient_id)
    );
    let Some(sender) = sender else {
        return deny(401, "Профиль не найден");
    };
    let Some(recipient) = recipient else {
        return deny(404, "Получатель не найден");
    };
    if sender.is_blocked {
        return deny(403, "Профиль заблокирован");
    }
    if recipient.is_blocked {
        return deny(403, "Профиль получателя недоступен");
    }

    let privacy = get_dm_privacy(state, recipient_id).await;
    if privacy.mode == DmPrivacyMode::Nobody {
        return deny(403, "Человек закрыл личные сообщения.");
    }

    if !peer_replied {
        if privacy.mode == DmPrivacyMode::Following
            && !is_following(state, recipient_id, sender_id).await
        {
            return deny(
                403,
                "Получатель принимает сообщения только от тех, на кого подписан.",
            );
        }
        if privacy.mode == DmPrivacyMode::Standing && !has_community_standing(&sender) {
            return deny(
                403,
                "Получатель принимает сообщения только от участников с историей в сообществе.",
            );
        }
        if privacy.min_account_age_days > 0.0
            && sender.account_age_days < privacy.min_account_age_days
        {
            return deny(
                403,
                format!(
                    "Аккаунту должно быть не меньше {} дней.",
                    privacy.min_account_age_days.round() as i64
                ),
            );
        }
        if privacy.min_playtime_hours > 0.0 && sender.playtime_hours < privacy.min_playtime_hours {
            return deny(
                403,
                format!(
                    "Нужно наиграть не меньше {} ч.",
                    privacy.min_playtime_hours.round() as i64
                ),
            );
        }

        if !is_staff(&sender) && !has_community_standing(&sender) {
            let old_enough =
                sender.account_age_days >= DM_RULES.min_account_age_days_for_new_thread;
            let played_enough = sender.playtime_hours >= DM_RULES.min_playtime_hours_for_new_thread;
            if !old_enough && !played_enough {
                return deny(
                    403,
                    format!(
                        "Начать переписку можно через {} дня после регистрации или наиграв {} ч в квестах.",
                        DM_RULES.min_account_age_days_for_new_thread as i64,
                        DM_RULES.min_playtime_hours_for_new_thread as i64
                    ),
                );
            }
        }
    }

    Gate {
        ok: true,
        status: 200,
        error: None,
    }
}

pub async fn get_dm_usage_today(state: &AppState, user_id: Uuid) -> (i64, i64) {
    use sqlx::Row;
    let row = sqlx::query(
        "SELECT
            (SELECT COUNT(DISTINCT m.thread_id)::int FROM dm_messages m
              JOIN dm_threads t ON t.id = m.thread_id
              WHERE m.sender_id = $1 AND m.created_at > date_trunc('day', NOW())
                AND t.user_a <> $2) AS threads,
            (SELECT COUNT(*)::int FROM dm_messages
              WHERE sender_id = $1 AND created_at > date_trunc('day', NOW())) AS messages",
    )
    .bind(user_id)
    .bind(Uuid::parse_str(SYSTEM_USER_ID).ok())
    .fetch_one(&state.db)
    .await;

    match row {
        Ok(row) => (
            row.try_get::<Option<i32>, _>("threads")
                .ok()
                .flatten()
                .unwrap_or(0) as i64,
            row.try_get::<Option<i32>, _>("messages")
                .ok()
                .flatten()
                .unwrap_or(0) as i64,
        ),
        Err(_) => (0, 0),
    }
}

pub async fn seconds_until_next_message(
    state: &AppState,
    thread_id: Uuid,
    user_id: Uuid,
    tenure: &Tenure,
) -> i64 {
    if is_staff(tenure) || has_community_standing(tenure) {
        return 0;
    }
    let waited: Option<i64> = sqlx::query_scalar(
        "SELECT EXTRACT(EPOCH FROM (NOW() - MAX(created_at)))::int
           FROM dm_messages
          WHERE thread_id = $1 AND sender_id = $2 AND deleted_at IS NULL",
    )
    .bind(thread_id)
    .bind(user_id)
    .fetch_optional(&state.db)
    .await
    .ok()
    .flatten();

    match waited {
        Some(waited) => (DM_RULES.message_cooldown_sec - waited).max(0),
        None => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tenure(role: &str) -> Tenure {
        Tenure {
            role: role.into(),
            account_age_days: 0.0,
            playtime_hours: 0.0,
            followers: 0,
            published: 0,
            reviews: 0,
            streak: 0,
            is_blocked: false,
        }
    }

    #[test]
    fn staff_can_create_forums_without_age() {
        assert!(can_create_forum(&tenure("admin")));
        assert!(can_create_forum(&tenure("moderator")));
        assert!(!can_create_forum(&tenure("user")));
    }

    #[test]
    fn standing_is_any_single_threshold() {
        let mut t = tenure("user");
        assert!(!has_community_standing(&t));
        t.followers = 5;
        assert!(has_community_standing(&t));
        let mut t = tenure("user");
        t.playtime_hours = 3.0;
        assert!(has_community_standing(&t));
        let mut t = tenure("user");
        t.reviews = 3;
        assert!(has_community_standing(&t));
    }
}
