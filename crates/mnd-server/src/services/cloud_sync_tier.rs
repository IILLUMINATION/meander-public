//! Port of `cloud_sync_tier.ts` — tier configuration & auto-recompute service.
//!
//! Tiers mirror `backend/src/services/cloud_sync_tier.ts` and the
//! `cloud_sync_quotas_tier_chk` CHECK constraint.

use chrono::{DateTime, Duration, Utc};
use serde_json::{Value, json};
use sqlx::Row;
use uuid::Uuid;

use crate::error::ApiError;
use crate::state::AppState;

const MB: u64 = 1024 * 1024;
const GB: u64 = 1024 * MB;

#[derive(Debug, Clone, Copy)]
pub struct TierConfig {
    pub name: &'static str,
    /// Per-file size limit (maxQuestBytes).
    pub max_file_bytes: u64,
    /// How many user-source files are allowed (maxQuests).
    pub max_files: i64,
    /// Total bytes across user files (maxBytes).
    pub max_total_bytes: u64,
    /// Market-ref slot limit (maxRefs).
    pub max_refs: i64,
}

const NONE: TierConfig = TierConfig {
    name: "none",
    max_file_bytes: 0,
    max_files: 0,
    max_total_bytes: 0,
    max_refs: 0,
};
const STARTER: TierConfig = TierConfig {
    name: "starter",
    max_file_bytes: 5 * MB,
    max_files: 3,
    max_total_bytes: 25 * MB,
    max_refs: 10,
};
const FREE: TierConfig = TierConfig {
    name: "free",
    max_file_bytes: 15 * MB,
    max_files: 10,
    max_total_bytes: 100 * MB,
    max_refs: 50,
};
const CREATOR: TierConfig = TierConfig {
    name: "creator",
    max_file_bytes: 30 * MB,
    max_files: 50,
    max_total_bytes: 500 * MB,
    max_refs: 200,
};
const PRO: TierConfig = TierConfig {
    name: "pro",
    max_file_bytes: 100 * MB,
    max_files: 200,
    max_total_bytes: 2 * GB,
    max_refs: 2000,
};
const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;

const ADMIN: TierConfig = TierConfig {
    name: "admin",
    max_file_bytes: 1 * GB,
    max_files: 1_000_000,
    max_total_bytes: MAX_SAFE_INTEGER,
    max_refs: 1_000_000,
};

const TIERS: &[TierConfig] = &[NONE, STARTER, FREE, CREATOR, PRO, ADMIN];

pub fn tier_config(name: &str) -> &'static TierConfig {
    TIERS
        .iter()
        .find(|t| t.name.eq_ignore_ascii_case(name))
        .unwrap_or(&NONE)
}

struct UserMetrics {
    is_verified: bool,
    is_admin: bool,
    is_blocked: bool,
    account_age_days: i64,
    published_count: i64,
    total_likes: i64,
    followers_count: i64,
    has_any_activity: bool,
}

async fn load_user_metrics(
    state: &AppState,
    user_id: Uuid,
) -> Result<Option<UserMetrics>, ApiError> {
    let profile = sqlx::query(
        "SELECT role, is_verified, is_blocked, created_at
           FROM profiles WHERE id = $1",
    )
    .bind(user_id)
    .fetch_optional(&state.db)
    .await?;

    let row = match profile {
        Some(r) => r,
        None => return Ok(None),
    };

    let created_at: DateTime<Utc> = row.try_get("created_at")?;
    let age = Utc::now().signed_duration_since(created_at);
    let account_age_days = age.num_days().max(0);

    let agg = sqlx::query(
        "SELECT
            COALESCE((SELECT COUNT(*) FROM quests
                       WHERE author_id = $1 AND status = 'published'), 0)::bigint AS published_count,
            COALESCE((SELECT SUM(like_count) FROM quests
                       WHERE author_id = $1 AND status = 'published'), 0)::bigint AS total_likes,
            COALESCE((SELECT COUNT(*) FROM user_followers
                       WHERE user_id = $1), 0)::bigint AS followers_count,
            COALESCE((SELECT COUNT(*) FROM quest_votes
                       WHERE user_id = $1 LIMIT 1), 0)::bigint AS any_vote,
            COALESCE((SELECT COUNT(*) FROM reviews
                       WHERE author_id = $1 LIMIT 1), 0)::bigint AS any_review",
    )
    .bind(user_id)
    .fetch_one(&state.db)
    .await?;

    let published_count: i64 = agg.try_get("published_count")?;
    let total_likes: i64 = agg.try_get("total_likes")?;
    let followers_count: i64 = agg.try_get("followers_count")?;
    let any_vote: i64 = agg.try_get("any_vote")?;
    let any_review: i64 = agg.try_get("any_review")?;

    let role: Option<String> = row.try_get("role")?;
    let is_admin = role.as_deref() == Some("admin");
    let is_verified: Option<bool> = row.try_get("is_verified")?;
    let is_blocked: Option<bool> = row.try_get("is_blocked")?;

    Ok(Some(UserMetrics {
        is_admin,
        is_verified: is_verified.unwrap_or(false),
        is_blocked: is_blocked.unwrap_or(false),
        account_age_days,
        published_count,
        total_likes,
        followers_count,
        has_any_activity: published_count > 0 || any_vote > 0 || any_review > 0,
    }))
}

fn compute_auto_tier(m: &UserMetrics) -> &'static TierConfig {
    if m.is_blocked {
        return &NONE;
    }
    if m.is_admin {
        return &ADMIN;
    }
    if m.published_count >= 3 || m.is_verified || m.total_likes >= 50 || m.followers_count >= 50 {
        return &CREATOR;
    }
    if m.published_count >= 1 {
        return &FREE;
    }
    if m.account_age_days >= 7 && m.has_any_activity {
        return &STARTER;
    }
    &NONE
}

async fn apply_tier(
    state: &AppState,
    user_id: Uuid,
    tier: &'static TierConfig,
    reason: &str,
    granted_by: Option<Uuid>,
    expires_at: Option<DateTime<Utc>>,
) -> Result<(), ApiError> {
    let before =
        sqlx::query_scalar::<_, String>("SELECT tier FROM cloud_sync_quotas WHERE user_id = $1")
            .bind(user_id)
            .fetch_optional(&state.db)
            .await?;

    sqlx::query(
        "INSERT INTO cloud_sync_quotas (
            user_id, tier, max_bytes, max_quests, max_quest_bytes, max_refs,
            granted_reason, granted_by, granted_at, expires_at, updated_at
         ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, now(), $9, now())
         ON CONFLICT (user_id) DO UPDATE SET
            tier            = EXCLUDED.tier,
            max_bytes       = EXCLUDED.max_bytes,
            max_quests      = EXCLUDED.max_quests,
            max_quest_bytes = EXCLUDED.max_quest_bytes,
            max_refs        = EXCLUDED.max_refs,
            granted_reason  = EXCLUDED.granted_reason,
            granted_by      = EXCLUDED.granted_by,
            granted_at      = EXCLUDED.granted_at,
            expires_at      = EXCLUDED.expires_at,
            updated_at      = now()",
    )
    .bind(user_id)
    .bind(tier.name)
    .bind(tier.max_total_bytes as i64)
    .bind(tier.max_files as i32)
    .bind(tier.max_file_bytes as i64)
    .bind(tier.max_refs as i32)
    .bind(reason)
    .bind(granted_by)
    .bind(expires_at)
    .execute(&state.db)
    .await?;

    if before.as_deref() != Some(tier.name) {
        let _ = sqlx::query(
            "INSERT INTO cloud_sync_audit (user_id, action, detail)
             VALUES ($1, 'tier_change', $2::jsonb)",
        )
        .bind(user_id)
        .bind(json!({
            "from": before,
            "to": tier.name,
            "reason": reason,
        }))
        .execute(&state.db)
        .await;
    }

    let _ = sqlx::query("SELECT recompute_cloud_sync_usage($1::uuid)")
        .bind(user_id)
        .execute(&state.db)
        .await;

    Ok(())
}

/// Returns the effective tier stored for a user, recomputing if none exists.
pub async fn effective_tier(state: &AppState, user_id: Uuid) -> Result<String, ApiError> {
    let stored: Option<String> =
        sqlx::query_scalar("SELECT tier FROM cloud_sync_quotas WHERE user_id = $1")
            .bind(user_id)
            .fetch_optional(&state.db)
            .await?;

    match stored {
        Some(t) => Ok(t),
        None => Ok(recompute_tier(state, user_id).await?),
    }
}

/// Recompute tier (skips manual `pro`/`admin` unless they were auto-assigned).
pub async fn recompute_tier(state: &AppState, user_id: Uuid) -> Result<String, ApiError> {
    let current =
        sqlx::query("SELECT tier, granted_reason FROM cloud_sync_quotas WHERE user_id = $1")
            .bind(user_id)
            .fetch_optional(&state.db)
            .await?;

    if let Some(row) = current {
        let tier: String = row.try_get("tier")?;
        let granted_reason: Option<String> = row.try_get("granted_reason")?;
        if (tier == "pro" || tier == "admin") && granted_reason.as_deref() != Some("auto") {
            return Ok(tier);
        }
    }

    match load_user_metrics(state, user_id).await? {
        Some(metrics) => {
            let target = compute_auto_tier(&metrics);
            apply_tier(state, user_id, target, "auto", None, None).await?;
            Ok(target.name.to_string())
        }
        None => Ok("none".to_string()),
    }
}

/// Public API: grant tier with an optional expiration delta in days.
pub async fn grant_tier(
    state: &AppState,
    user_id: Uuid,
    tier: &str,
    days: Option<i32>,
    source: &str,
) -> Result<(), ApiError> {
    let cfg = tier_config(tier);
    let expires_at = days.map(|d| Utc::now() + Duration::days(d as i64));
    apply_tier(state, user_id, cfg, source, None, expires_at).await
}

/// Internal variant that records who granted and an absolute expiry.
pub async fn grant_tier_by(
    state: &AppState,
    user_id: Uuid,
    tier: &str,
    reason: &str,
    granted_by: Option<Uuid>,
    expires_at: Option<DateTime<Utc>>,
) -> Result<(), ApiError> {
    let cfg = tier_config(tier);
    apply_tier(state, user_id, cfg, reason, granted_by, expires_at).await
}

/// Build the array of upgrade hints returned by `/cloud-sync/quota`.
pub async fn build_upgrade_hints(state: &AppState, user_id: Uuid) -> Result<Value, ApiError> {
    let metrics = match load_user_metrics(state, user_id).await? {
        Some(m) => m,
        None => return Ok(json!([])),
    };

    let current_tier = effective_tier(state, user_id).await?;

    let mut hints: Vec<Value> = Vec::new();

    if current_tier == "none" {
        if metrics.account_age_days < 7 {
            hints.push(json!({
                "target": "starter",
                "text": format!("Аккаунту {} дн. — через {} дн. получите 25 МБ.", metrics.account_age_days, 7 - metrics.account_age_days),
                "progress": metrics.account_age_days as f64 / 7.0,
            }));
        }
        if !metrics.has_any_activity {
            hints.push(json!({
                "target": "starter",
                "text": "Поставьте лайк, оставьте отзыв или опубликуйте квест.",
            }));
        }
        hints.push(json!({
            "target": "free",
            "text": "Опубликуйте свой первый квест — 100 МБ.",
        }));
    }

    if current_tier == "starter" || current_tier == "none" {
        if metrics.published_count == 0 {
            hints.push(json!({
                "target": "free",
                "text": "Опубликуйте 1 квест — получите 100 МБ.",
            }));
        }
    }

    if current_tier == "free" || current_tier == "starter" {
        let need = 3_i64.saturating_sub(metrics.published_count);
        if need > 0 {
            hints.push(json!({
                "target": "creator",
                "text": format!("Опубликуйте ещё {} квест(а) — 500 МБ.", need),
                "progress": (metrics.published_count as f64 / 3.0).min(1.0),
            }));
        }

        let need_likes = 50_i64.saturating_sub(metrics.total_likes);
        if need_likes > 0 {
            hints.push(json!({
                "target": "creator",
                "text": format!("Соберите ещё {} лайков на квестах — 500 МБ.", need_likes),
                "progress": (metrics.total_likes as f64 / 50.0).min(1.0),
            }));
        }

        let need_followers = 50_i64.saturating_sub(metrics.followers_count);
        if need_followers > 0 {
            hints.push(json!({
                "target": "creator",
                "text": format!("Наберите ещё {} подписчиков — 500 МБ.", need_followers),
                "progress": (metrics.followers_count as f64 / 50.0).min(1.0),
            }));
        }

        if !metrics.is_verified {
            hints.push(json!({
                "target": "creator",
                "text": "Пройдите верификацию профиля — 500 МБ.",
            }));
        }
    }

    if current_tier == "creator" {
        hints.push(json!({
            "target": "pro",
            "text": "Pro доступен через подписку или промокод — 2 ГБ.",
        }));
    }

    Ok(json!(hints))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_tier_configs() {
        assert_eq!(tier_config("starter").max_total_bytes, 25 * 1024 * 1024);
        assert_eq!(tier_config("ADMIN").name, "admin");
        assert_eq!(tier_config("invalid").name, "none");
    }

    #[test]
    fn auto_tier_promotes_by_metrics() {
        let blocked = UserMetrics {
            is_verified: false,
            is_admin: false,
            is_blocked: true,
            account_age_days: 30,
            published_count: 10,
            total_likes: 100,
            followers_count: 100,
            has_any_activity: true,
        };
        assert_eq!(compute_auto_tier(&blocked).name, "none");

        let admin = UserMetrics {
            is_verified: false,
            is_admin: true,
            is_blocked: false,
            account_age_days: 30,
            published_count: 0,
            total_likes: 0,
            followers_count: 0,
            has_any_activity: false,
        };
        assert_eq!(compute_auto_tier(&admin).name, "admin");

        let creator = UserMetrics {
            is_verified: true,
            is_admin: false,
            is_blocked: false,
            account_age_days: 30,
            published_count: 0,
            total_likes: 0,
            followers_count: 0,
            has_any_activity: true,
        };
        assert_eq!(compute_auto_tier(&creator).name, "creator");

        let starter = UserMetrics {
            is_verified: false,
            is_admin: false,
            is_blocked: false,
            account_age_days: 7,
            published_count: 0,
            total_likes: 0,
            followers_count: 0,
            has_any_activity: true,
        };
        assert_eq!(compute_auto_tier(&starter).name, "starter");

        let fresh = UserMetrics {
            is_verified: false,
            is_admin: false,
            is_blocked: false,
            account_age_days: 1,
            published_count: 0,
            total_likes: 0,
            followers_count: 0,
            has_any_activity: false,
        };
        assert_eq!(compute_auto_tier(&fresh).name, "none");
    }
}
