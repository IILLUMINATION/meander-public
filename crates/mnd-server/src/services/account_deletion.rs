//! Port of `account_deletion.ts`.
//!
//! Deletes accounts whose grace period has expired. All row-level cleanup is
//! handled by `ON DELETE CASCADE` / `SET NULL`; this module only drives the
//! `DELETE FROM profiles`, cleans cloud-sync files, and writes the audit row.

use std::sync::Arc;

use serde_json::{Value, json};
use sqlx::Row;
use uuid::Uuid;

use crate::error::ApiError;
use crate::state::AppState;

use super::cloud_sync_storage::delete_all_user_files;

const BATCH_LIMIT: i64 = 20;

fn purge_enabled() -> bool {
    matches!(
        std::env::var("ACCOUNT_DELETION_PURGE").ok().map(|s| s.trim().to_string()),
        Some(s) if s == "1"
    )
}

async fn find_ready(state: &AppState) -> Vec<Uuid> {
    sqlx::query(
        "SELECT id::text
           FROM profiles
          WHERE deletion_purge_at IS NOT NULL
            AND deletion_purge_at <= now()
          ORDER BY deletion_purge_at
          LIMIT $1",
    )
    .bind(BATCH_LIMIT)
    .fetch_all(&state.db)
    .await
    .map(|rows| {
        rows.iter()
            .filter_map(|r| {
                r.try_get::<String, _>("id")
                    .ok()
                    .and_then(|s| Uuid::parse_str(&s).ok())
            })
            .collect()
    })
    .unwrap_or_default()
}

async fn purge_account(state: &AppState, user_id: Uuid) -> Result<bool, ApiError> {
    // Файлы в облаке синхронизации — вне транзакции.
    if let Err(e) = delete_all_user_files(state, user_id).await {
        tracing::error!(user_id = %user_id, error = %e, "[account-deletion] files cleanup failed");
    }

    let mut tx = state.db.begin().await?;

    let locked = sqlx::query(
        "SELECT id
           FROM profiles
          WHERE id = $1
            AND deletion_purge_at IS NOT NULL
            AND deletion_purge_at <= now()
          FOR UPDATE",
    )
    .bind(user_id)
    .fetch_optional(&mut *tx)
    .await?;

    if locked.is_none() {
        tx.rollback().await?;
        return Ok(false);
    }

    let audit_id: Option<i64> = sqlx::query(
        "SELECT id
           FROM account_deletion_audit
          WHERE user_id = $1
            AND resolved_at IS NULL
          ORDER BY requested_at DESC
          LIMIT 1",
    )
    .bind(user_id)
    .fetch_optional(&mut *tx)
    .await
    .ok()
    .flatten()
    .and_then(|r| r.try_get::<i64, _>("id").ok());

    let deleted = sqlx::query("DELETE FROM profiles WHERE id = $1")
        .bind(user_id)
        .execute(&mut *tx)
        .await?;

    if let Some(audit_id) = audit_id {
        let rows_affected = json!({"profile_deleted": deleted.rows_affected()});
        let _ = sqlx::query(
            "UPDATE account_deletion_audit
                SET resolved_at   = now(),
                    outcome       = 'purged',
                    user_id       = NULL,
                    rows_affected = $2::jsonb
              WHERE id = $1",
        )
        .bind(audit_id)
        .bind(rows_affected)
        .execute(&mut *tx)
        .await;
    }

    tx.commit().await?;
    Ok(deleted.rows_affected() > 0)
}

/// Одна волна: считает готовые заявки и, если включено, удаляет их.
pub async fn run_account_deletion_sweep(state: &Arc<AppState>) -> Value {
    let start = std::time::Instant::now();
    let enforced = purge_enabled();
    let mut purged = 0usize;
    let mut failed = 0usize;

    let ids = find_ready(state).await;
    let ready = ids.len();

    if ready > 0 && !enforced {
        tracing::warn!(
            "[account-deletion] {} заявок созрело, но ACCOUNT_DELETION_PURGE != 1 — ничего не удаляем",
            ready
        );
    }

    if enforced {
        for id in ids {
            match purge_account(state, id).await {
                Ok(true) => purged += 1,
                Ok(false) => {}
                Err(e) => {
                    failed += 1;
                    tracing::error!(user_id = %id, error = %e, "[account-deletion] purge failed");
                }
            }
        }
    }

    let duration_ms = start.elapsed().as_millis() as u64;
    if ready + purged + failed > 0 {
        tracing::info!(
            "[account-deletion] ready={} purged={} failed={} enforced={} in {}ms",
            ready,
            purged,
            failed,
            enforced,
            duration_ms
        );
    }

    json!({
        "ready": ready,
        "purged": purged,
        "failed": failed,
        "enforced": enforced,
        "durationMs": duration_ms,
    })
}
