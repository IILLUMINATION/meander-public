//! Background job bodies. Each function is best-effort and never panics.

use std::sync::Arc;

use sqlx::Row;

use crate::services::achievements::award_achievement;
use crate::state::AppState;

/// What the Node checker looked at, in one round trip per user.
async fn check_user_achievements(state: &Arc<AppState>, user_id: uuid::Uuid) {
    let row = sqlx::query(
        "SELECT (SELECT COUNT(*) FROM quests WHERE author_id = $1 AND status = 'published') AS published,
                (SELECT COUNT(*) FROM quest_votes WHERE user_id = $1 AND is_like = TRUE) AS likes,
                (SELECT COUNT(*) FROM quest_downloads WHERE user_id = $1) AS downloads,
                (SELECT COUNT(*) FROM reviews WHERE author_id = $1) AS reviews",
    )
    .bind(user_id)
    .fetch_one(&state.db)
    .await;

    let row = match row {
        Ok(row) => row,
        Err(err) => {
            tracing::error!(error = %err, user = %user_id, "Error checking achievements");
            return;
        }
    };

    let published: i64 = row.get("published");
    let likes: i64 = row.get("likes");
    let downloads: i64 = row.get("downloads");
    let reviews: i64 = row.get("reviews");

    if published >= 1 {
        let _ = award_achievement(state, user_id, "publisher_debut").await;
    }
    if likes >= 20 {
        let _ = award_achievement(state, user_id, "generous").await;
    }
    if downloads >= 1 {
        let _ = award_achievement(state, user_id, "first_step").await;
    }
    if downloads >= 10 {
        let _ = award_achievement(state, user_id, "bookworm").await;
    }
    if downloads >= 50 {
        let _ = award_achievement(state, user_id, "library_keeper").await;
    }
    if reviews >= 1 {
        let _ = award_achievement(state, user_id, "critic_bronze").await;
    }
}

pub async fn run_achievement_checker(state: &Arc<AppState>) {
    let users = sqlx::query_scalar::<_, uuid::Uuid>("SELECT id FROM profiles")
        .fetch_all(&state.db)
        .await;

    match users {
        Ok(users) => {
            for user_id in &users {
                check_user_achievements(state, *user_id).await;
            }
            tracing::info!(users = users.len(), "Achievement check completed");
        }
        Err(err) => tracing::error!(error = %err, "Error in achievement checker cycle"),
    }
}

pub async fn run_cloud_sync_cleanup(state: &Arc<AppState>) {
    if let Err(err) = crate::services::cloud_sync_cleanup::run_cloud_sync_cleanup(state).await {
        tracing::error!(error = %err, "[cloud-cleanup] run failed");
    }
}

pub async fn run_account_deletion_sweep(state: &Arc<AppState>) {
    let _ = crate::services::account_deletion::run_account_deletion_sweep(state).await;
}

pub async fn run_cosmetic_expiry_sweep(state: &Arc<AppState>) {
    match crate::services::cosmetics::sweep_expired_cosmetics(state).await {
        0 => {}
        cleared => tracing::info!(cleared, "Cosmetics expired and cleared"),
    }
}

pub async fn run_reward_sweep(state: &Arc<AppState>) {
    let _ = crate::services::rewards::sweep_reward_ladder(state).await;
}
