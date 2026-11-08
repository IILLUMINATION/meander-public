//! Achievement awarding — port of `achievements.ts`. Best-effort by design: a
//! failed award must never fail the request that earned it.

use uuid::Uuid;

use crate::state::AppState;

pub async fn award_achievement(state: &AppState, user_id: Uuid, achievement_id: &str) -> bool {
    match sqlx::query(
        "INSERT INTO user_achievements (user_id, achievement_id)
         VALUES ($1, $2)
         ON CONFLICT (user_id, achievement_id) DO NOTHING
         RETURNING user_id",
    )
    .bind(user_id)
    .bind(achievement_id)
    .fetch_optional(&state.db)
    .await
    {
        Ok(Some(_)) => {
            tracing::info!(%user_id, achievement_id, "achievement unlocked");
            true
        }
        Ok(None) => false,
        Err(err) => {
            tracing::error!(error = %err, achievement_id, "failed to award achievement");
            false
        }
    }
}
