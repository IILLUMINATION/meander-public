//! Background jobs started with the server (cron in `app.ts`). Each job is a
//! plain `tokio` loop; failures are logged and the loop continues.

use std::sync::Arc;
use std::time::Duration;

use crate::state::AppState;

pub fn spawn_all(state: Arc<AppState>) {
    let s = state.clone();
    tokio::spawn(async move {
        // Achievement checker: every 10 minutes, first run after 10.
        loop {
            tokio::time::sleep(Duration::from_secs(10 * 60)).await;
            crate::cron_jobs::run_achievement_checker(&s).await;
        }
    });

    let s = state.clone();
    tokio::spawn(async move {
        // Cloud-sync cleanup: daily, first run after 5 minutes.
        tokio::time::sleep(Duration::from_secs(5 * 60)).await;
        loop {
            crate::cron_jobs::run_cloud_sync_cleanup(&s).await;
            tokio::time::sleep(Duration::from_secs(24 * 60 * 60)).await;
        }
    });

    let s = state.clone();
    tokio::spawn(async move {
        // Account deletion sweep: hourly, first pass six minutes after start
        // so it does not compete with startup.
        tokio::time::sleep(Duration::from_secs(6 * 60)).await;
        loop {
            crate::cron_jobs::run_account_deletion_sweep(&s).await;
            tokio::time::sleep(Duration::from_secs(60 * 60)).await;
        }
    });

    let s = state.clone();
    tokio::spawn(async move {
        // Cosmetic expiry: every 10 minutes.
        loop {
            crate::cron_jobs::run_cosmetic_expiry_sweep(&s).await;
            tokio::time::sleep(Duration::from_secs(10 * 60)).await;
        }
    });

    let s = state.clone();
    tokio::spawn(async move {
        // Reward sweep: every 15 minutes, first pass immediately.
        loop {
            crate::cron_jobs::run_reward_sweep(&s).await;
            tokio::time::sleep(Duration::from_secs(15 * 60)).await;
        }
    });

    // Rate-limiter window pruning.
    let s = state.clone();
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(15 * 60)).await;
            s.limiter.prune(Duration::from_secs(60 * 60));
        }
    });
}
