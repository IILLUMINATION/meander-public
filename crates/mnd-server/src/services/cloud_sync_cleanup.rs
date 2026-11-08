//! Port of `cloud_sync_cleanup.ts` — background cleanup stages for cloud-sync.
//!
//! Stages use `cloud_sync_quotas.cleanup_stage`:
//!   active -> warning -> archived -> purged.

use std::sync::Arc;
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use sqlx::Row;
use uuid::Uuid;

use crate::error::ApiError;
use crate::services::cloud_sync_storage::delete_all_user_files;
use crate::state::AppState;

const WARNING_AFTER_DAYS: i64 = 83;
const ARCHIVE_AFTER_DAYS: i64 = 90;
const PURGE_AFTER_DAYS: i64 = 365;

/// A returning user leaves the warning/archived states.
pub async fn reset_cleanup_stage_on_activity(state: &Arc<AppState>, user_id: Uuid) {
    if let Err(err) = sqlx::query(
        "UPDATE cloud_sync_quotas
            SET cleanup_stage = CASE
                    WHEN cleanup_stage IN ('warning', 'archived') THEN 'active'
                    ELSE cleanup_stage
                END,
                updated_at = now()
          WHERE user_id = $1",
    )
    .bind(user_id)
    .execute(&state.db)
    .await
    {
        tracing::debug!(error = %err, "cleanup stage reset failed");
    }
}

async fn apply_warnings(state: &AppState) -> Result<i64, ApiError> {
    let rows = sqlx::query(
        "UPDATE cloud_sync_quotas q
            SET cleanup_stage = 'warning',
                cleanup_at    = now(),
                updated_at    = now()
           FROM profiles p
          WHERE p.id = q.user_id
            AND q.cleanup_stage = 'active'
            AND p.last_seen_at IS NOT NULL
            AND p.last_seen_at < now() - $1::interval
          RETURNING q.user_id",
    )
    .bind(format!("{} days", WARNING_AFTER_DAYS))
    .fetch_all(&state.db)
    .await?;

    Ok(rows.len() as i64)
}

async fn apply_archive(state: &AppState) -> Result<(i64, i64), ApiError> {
    let candidates = sqlx::query(
        "SELECT q.user_id
           FROM cloud_sync_quotas q
           JOIN profiles p ON p.id = q.user_id
          WHERE q.cleanup_stage IN ('active', 'warning')
            AND p.last_seen_at IS NOT NULL
            AND p.last_seen_at < now() - $1::interval",
    )
    .bind(format!("{} days", ARCHIVE_AFTER_DAYS))
    .fetch_all(&state.db)
    .await?;

    let mut archived: i64 = 0;
    let mut failed: i64 = 0;

    for row in candidates {
        let user_id: Uuid = match row.try_get("user_id") {
            Ok(v) => v,
            Err(_) => {
                failed += 1;
                continue;
            }
        };

        match archive_one(state, user_id).await {
            Ok(()) => archived += 1,
            Err(err) => {
                tracing::error!(error = %err, user_id = %user_id, "[cloud-cleanup] archive failed");
                failed += 1;
            }
        }
    }

    Ok((archived, failed))
}

async fn archive_one(state: &AppState, user_id: Uuid) -> Result<(), ApiError> {
    sqlx::query(
        "UPDATE cloud_sync_quests
            SET deleted_at = now(),
                size_bytes = 0,
                fingerprint = NULL,
                storage_path = '',
                updated_at = now()
          WHERE user_id = $1
            AND source = 'user'
            AND deleted_at IS NULL",
    )
    .bind(user_id)
    .execute(&state.db)
    .await?;

    let _ = delete_all_user_files(state, user_id).await;

    sqlx::query(
        "UPDATE cloud_sync_quotas
            SET cleanup_stage = 'archived',
                cleanup_at    = now(),
                updated_at    = now()
          WHERE user_id = $1",
    )
    .bind(user_id)
    .execute(&state.db)
    .await?;

    let _ = sqlx::query(
        "INSERT INTO cloud_sync_audit (user_id, action, detail)
         VALUES ($1, 'archive', $2::jsonb)",
    )
    .bind(user_id)
    .bind(json!({
        "reason": "inactive_for_days",
        "days": ARCHIVE_AFTER_DAYS,
    }))
    .execute(&state.db)
    .await;

    Ok(())
}

async fn apply_purge(state: &AppState) -> Result<(i64, i64), ApiError> {
    let candidates = sqlx::query(
        "SELECT q.user_id
           FROM cloud_sync_quotas q
           JOIN profiles p ON p.id = q.user_id
          WHERE q.cleanup_stage = 'archived'
            AND p.last_seen_at IS NOT NULL
            AND p.last_seen_at < now() - $1::interval
            AND NOT EXISTS (
                SELECT 1 FROM quests qm
                 WHERE qm.author_id = q.user_id AND qm.status = 'published'
            )",
    )
    .bind(format!("{} days", PURGE_AFTER_DAYS))
    .fetch_all(&state.db)
    .await?;

    let mut purged: i64 = 0;
    let mut failed: i64 = 0;

    for row in candidates {
        let user_id: Uuid = match row.try_get("user_id") {
            Ok(v) => v,
            Err(_) => {
                failed += 1;
                continue;
            }
        };

        match purge_one(state, user_id).await {
            Ok(()) => purged += 1,
            Err(err) => {
                tracing::error!(error = %err, user_id = %user_id, "[cloud-cleanup] purge failed");
                failed += 1;
            }
        }
    }

    Ok((purged, failed))
}

async fn purge_one(state: &AppState, user_id: Uuid) -> Result<(), ApiError> {
    sqlx::query("DELETE FROM cloud_sync_quests WHERE user_id = $1")
        .bind(user_id)
        .execute(&state.db)
        .await?;

    sqlx::query(
        "UPDATE cloud_sync_quotas
            SET cleanup_stage = 'purged',
                cleanup_at    = now(),
                used_bytes    = 0,
                used_quests   = 0,
                updated_at    = now()
          WHERE user_id = $1",
    )
    .bind(user_id)
    .execute(&state.db)
    .await?;

    let _ = delete_all_user_files(state, user_id).await;

    let _ = sqlx::query(
        "INSERT INTO cloud_sync_audit (user_id, action, detail)
         VALUES ($1, 'purge', $2::jsonb)",
    )
    .bind(user_id)
    .bind(json!({
        "reason": "inactive_for_days",
        "days": PURGE_AFTER_DAYS,
    }))
    .execute(&state.db)
    .await;

    Ok(())
}

/// Run all cleanup stages sequentially and return a report.
pub async fn run_cloud_sync_cleanup(state: &Arc<AppState>) -> Result<Value, ApiError> {
    let t0 = Instant::now();
    let warned = apply_warnings(state).await.unwrap_or(0);
    let (archived, mut failed) = apply_archive(state).await.unwrap_or((0, 0));
    let (purged, failed2) = apply_purge(state).await.unwrap_or((0, 0));
    failed += failed2;
    let duration_ms = t0.elapsed().as_millis() as i64;

    let total = warned + archived + purged + failed;
    if total > 0 {
        tracing::info!(
            "[cloud-cleanup] warned={} archived={} purged={} failed={} in {}ms",
            warned,
            archived,
            purged,
            failed,
            duration_ms
        );
    }

    Ok(json!({
        "warned": warned,
        "archived": archived,
        "purged": purged,
        "failed": failed,
        "durationMs": duration_ms,
    }))
}

/// Start the periodic cleanup task. Default interval is 24 hours.
pub fn start_cloud_sync_cleanup_cron(state: Arc<AppState>, interval: Duration) {
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(5 * 60)).await;
        loop {
            let _ = run_cloud_sync_cleanup(&state).await;
            tokio::time::sleep(interval).await;
        }
    });

    tracing::info!(
        "[cloud-cleanup] cron started, interval={} day(s)",
        interval.as_secs_f64() / 86400.0
    );
}
